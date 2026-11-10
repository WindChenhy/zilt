//! 受限文件访问（v0.1.16 起；v0.1.19 扩到全量操作 + 多根目录 + scope 授权）。
//!
//! 设计原则：所有路径都相对某个 scope 根目录解析，并拒绝逃逸（`..`、绝对路径、
//! 盘符、UNC、NUL 字节）。capability 只需声明 `"fs:documents/**"` 之类的 scope 模式，
//! 不需要逐路径授权。
//!
//! scope 名单对齐 Tauri `BaseDirectory` 的 Windows 子集。
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Scope = enum {
    /// `%LOCALAPPDATA%\<app_id>`
    app_data,
    /// `%APPDATA%\<app_id>`
    app_config,
    /// `%LOCALAPPDATA%\<app_id>\cache`
    app_cache,
    /// `%USERPROFILE%`
    home,
    desktop,
    documents,
    downloads,
    pictures,
    videos,
    /// `%TEMP%`
    temp,
    /// 应用 exe 所在目录（只读语义，不做强制）
    exe,

    pub fn fromName(text: []const u8) !Scope {
        const eql = std.mem.eql;
        if (eql(u8, text, "appData") or eql(u8, text, "app_data")) return .app_data;
        if (eql(u8, text, "appConfig") or eql(u8, text, "app_config")) return .app_config;
        if (eql(u8, text, "appCache") or eql(u8, text, "app_cache")) return .app_cache;
        if (eql(u8, text, "home")) return .home;
        if (eql(u8, text, "desktop")) return .desktop;
        if (eql(u8, text, "documents") or eql(u8, text, "document")) return .documents;
        if (eql(u8, text, "downloads") or eql(u8, text, "download")) return .downloads;
        if (eql(u8, text, "pictures") or eql(u8, text, "picture")) return .pictures;
        if (eql(u8, text, "videos") or eql(u8, text, "video")) return .videos;
        if (eql(u8, text, "temp") or eql(u8, text, "tmp")) return .temp;
        if (eql(u8, text, "exe") or eql(u8, text, "resource")) return .exe;
        return error.UnknownScope;
    }

    /// 规范名（用于 scope 字符串与 ACL 匹配，统一 camelCase）。
    pub fn name(self: Scope) []const u8 {
        return switch (self) {
            .app_data => "appData",
            .app_config => "appConfig",
            .app_cache => "appCache",
            .home => "home",
            .desktop => "desktop",
            .documents => "documents",
            .downloads => "downloads",
            .pictures => "pictures",
            .videos => "videos",
            .temp => "temp",
            .exe => "exe",
        };
    }

    /// 是否为应用私有目录（默认授权；无需在 capability 里显式声明）。
    pub fn isAppPrivate(self: Scope) bool {
        return self == .app_data or self == .app_config or self == .app_cache;
    }
};

/// 系统根目录名 → 相对 USERPROFILE 的子目录（null = 非用户目录）。
pub fn userSubdir(scope: Scope) ?[]const u8 {
    return switch (scope) {
        .home => "",
        .desktop => "Desktop",
        .documents => "Documents",
        .downloads => "Downloads",
        .pictures => "Pictures",
        .videos => "Videos",
        else => null,
    };
}

pub const Limits = struct {
    max_read: usize = 32 * 1024 * 1024,
    max_write: usize = 32 * 1024 * 1024,
};

/// 相对路径安全检查：拒绝空路径、绝对路径、盘符、UNC、`..` 段、NUL。
pub fn isSafeRelative(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (rel.len > 1024) return false;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return false;

    // 绝对路径 / UNC / 正斜杠开头
    if (rel[0] == '\\' or rel[0] == '/') return false;
    // 盘符（C:、C:\）
    if (rel.len >= 2 and rel[1] == ':') return false;

    var it = std.mem.tokenizeAny(u8, rel, "\\/");
    var any = false;
    while (it.next()) |seg| {
        any = true;
        if (std.mem.eql(u8, seg, "..")) return false;
        if (std.mem.eql(u8, seg, ".")) return false;
    }
    return any;
}

/// 拼接 scope 根与相对路径；不安全路径返回 error.PathEscape。
pub fn joinChecked(alloc: Allocator, root: []const u8, rel: []const u8) ![]u8 {
    if (!isSafeRelative(rel)) return error.PathEscape;
    const normalized = try alloc.dupe(u8, rel);
    defer alloc.free(normalized);
    // 统一用反斜杠（Windows），前端传正斜杠也能工作
    for (normalized) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ root, normalized });
}

/// 把 (scope, 相对路径) 规范化为 ACL 资源串：`documents/notes/a.txt`。
pub fn resourceString(alloc: Allocator, scope: Scope, rel: []const u8) ![]u8 {
    const normalized = try alloc.dupe(u8, rel);
    defer alloc.free(normalized);
    for (normalized) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ scope.name(), normalized });
}

/// glob 匹配（`*` 不跨段，`**` 跨段，`?` 单字符）。
/// 用于 capability scope：`"fs:documents/**"` 匹配 `documents/a/b.txt`。
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    return globMatchAt(pattern, 0, text, 0);
}

fn globMatchAt(pat: []const u8, pi_in: usize, txt: []const u8, ti_in: usize) bool {
    var pi = pi_in;
    var ti = ti_in;
    while (pi < pat.len) {
        if (pat[pi] == '*') {
            const double = pi + 1 < pat.len and pat[pi + 1] == '*';
            const skip: usize = if (double) 2 else 1;
            // 吞掉连续的 *（`***` 等价 `**`）
            var next = pi + skip;
            while (next < pat.len and pat[next] == '*') : (next += 1) {}
            if (next == pat.len) {
                // 尾部 ** 匹配剩余全部；尾部 * 只匹配本段（不跨 /）
                if (double) return true;
                return std.mem.indexOfScalar(u8, txt[ti..], '/') == null;
            }
            var k = ti;
            while (k <= txt.len) : (k += 1) {
                if (globMatchAt(pat, next, txt, k)) return true;
                // 单 * 不跨 '/'；** 可跨
                if (!double and k < txt.len and txt[k] == '/') return false;
            }
            return false;
        }
        if (ti >= txt.len) return false;
        if (pat[pi] == '?') {
            if (txt[ti] == '/') return false;
            pi += 1;
            ti += 1;
            continue;
        }
        if (pat[pi] != txt[ti]) return false;
        pi += 1;
        ti += 1;
    }
    return ti == txt.len;
}

const testing = std.testing;

test "path safety rejects escapes" {
    try testing.expect(isSafeRelative("settings.json"));
    try testing.expect(isSafeRelative("logs\\2026\\a.txt"));
    try testing.expect(isSafeRelative("nested/dir/file.bin"));

    try testing.expect(!isSafeRelative(""));
    try testing.expect(!isSafeRelative("..\\evil.txt"));
    try testing.expect(!isSafeRelative("a\\..\\b"));
    try testing.expect(!isSafeRelative("/etc/passwd"));
    try testing.expect(!isSafeRelative("C:\\Windows\\system32"));
    try testing.expect(!isSafeRelative("\\\\server\\share"));
    try testing.expect(!isSafeRelative("a\x00b"));
    try testing.expect(!isSafeRelative("./a"));
}

test "join normalizes separators and rejects escape" {
    const joined = try joinChecked(testing.allocator, "C:\\root", "a/b/c.txt");
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("C:\\root\\a\\b\\c.txt", joined);

    try testing.expectError(error.PathEscape, joinChecked(testing.allocator, "C:\\root", "..\\x"));
}

test "v0.1.19: scope names (camel + snake)" {
    try testing.expectEqual(Scope.app_data, try Scope.fromName("appData"));
    try testing.expectEqual(Scope.app_data, try Scope.fromName("app_data"));
    try testing.expectEqual(Scope.documents, try Scope.fromName("document"));
    try testing.expectEqual(Scope.downloads, try Scope.fromName("downloads"));
    try testing.expectEqual(Scope.exe, try Scope.fromName("resource"));
    try testing.expectError(error.UnknownScope, Scope.fromName("nope"));
    try testing.expectEqualStrings("appConfig", Scope.app_config.name());
    try testing.expect(Scope.app_data.isAppPrivate());
    try testing.expect(!Scope.documents.isAppPrivate());
}

test "v0.1.19: resource string normalizes separators" {
    const a = try resourceString(testing.allocator, .documents, "notes\\a.txt");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("documents/notes/a.txt", a);
    const b = try resourceString(testing.allocator, .app_data, "store.json");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("appData/store.json", b);
}

test "v0.1.19: glob matching" {
    try testing.expect(globMatch("documents/**", "documents/a/b.txt"));
    try testing.expect(globMatch("documents/**", "documents/a.txt"));
    try testing.expect(globMatch("documents/*", "documents/a.txt"));
    try testing.expect(!globMatch("documents/*", "documents/a/b.txt"));
    try testing.expect(globMatch("**", "anything/at/all"));
    try testing.expect(globMatch("appData/**", "appData/logs/2026/11/10.log"));
    try testing.expect(globMatch("downloads/*.zip", "downloads/a.zip"));
    try testing.expect(!globMatch("downloads/*.zip", "downloads/a.rar"));
    try testing.expect(globMatch("documents/report-??.md", "documents/report-01.md"));
    try testing.expect(!globMatch("documents/report-??.md", "documents/report-1.md"));
    try testing.expect(!globMatch("documents/**", "downloads/a.txt"));
}
