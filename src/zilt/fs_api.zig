//! 受限文件访问（v0.1.16 官方周边 API：fs）。
//!
//! 设计原则：所有路径都相对某个 scope 根目录解析，并拒绝逃逸（`..`、绝对路径、
//! 盘符、UNC、NUL 字节）。这样 capability 只需要声明 "fs:app_data" 之类的 scope，
//! 而不需要逐路径授权。
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Scope = enum {
    /// `%LOCALAPPDATA%\<app_id>`
    app_data,
    /// `%APPDATA%\<app_id>`
    app_config,
    /// `%LOCALAPPDATA%\<app_id>\cache`
    app_cache,

    pub fn fromName(name: []const u8) !Scope {
        const eql = std.mem.eql;
        if (eql(u8, name, "appData") or eql(u8, name, "app_data")) return .app_data;
        if (eql(u8, name, "appConfig") or eql(u8, name, "app_config")) return .app_config;
        if (eql(u8, name, "appCache") or eql(u8, name, "app_cache")) return .app_cache;
        return error.UnknownScope;
    }
};

pub const Limits = struct {
    max_read: usize = 8 * 1024 * 1024,
    max_write: usize = 8 * 1024 * 1024,
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
