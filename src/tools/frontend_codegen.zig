//! 前端资产 codegen（build.zig 执行期调用）：
//! 遍历前端 dist 目录（win32 FindFirstFile，自包含实现）→ 生成 zilt-assets 模块
//! （@embedFile 相对路径表 + payload 副本）。
//!
//! 设计要点（对标 tauri-codegen，见 docs/research/frontend-integration.md §4.2）：
//!  - 遍历结果按路径排序 → 生成文件内容确定 → zig 缓存命中（资产未变不重编）
//!  - 内建排除：node_modules/.git/zig-cache 等（防误嵌，Tauri build.rs 同款防御）
//!  - dist 缺失 → 空资产表 + 生成文件内注释警告（应用可构建，运行时 404）

const std = @import("std");

// ---- 自包含 win32 助手（build runner 宿主环境） ----

const DWORD = u32;
const BOOL = i32;
const HANDLE = *anyopaque;
const LPCWSTR = [*:0]const u16;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub extern "kernel32" fn FindFirstFileW(lpFileName: LPCWSTR, lpFindFileData: *WIN32_FIND_DATAW) callconv(.c) HANDLE;
pub extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.c) BOOL;
pub extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn CreateDirectoryW(lpPathName: LPCWSTR, lpSecurityAttributes: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn RemoveDirectoryW(lpPathName: LPCWSTR) callconv(.c) BOOL;
pub extern "kernel32" fn DeleteFileW(lpFileName: LPCWSTR) callconv(.c) BOOL;
pub extern "kernel32" fn CreateFileW(lpFileName: LPCWSTR, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?*anyopaque) callconv(.c) HANDLE;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: LPCWSTR, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.c) DWORD;

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
const FILE_ATTRIBUTE_REPARSE_POINT: DWORD = 0x400;

/// 排除的目录/文件名（任一路径段命中即跳过）。
pub const default_excludes = [_][]const u8{
    "node_modules", ".git",      "zig-cache", ".zig-cache", "zig-out",
    "src-tauri",    ".DS_Store", "Thumbs.db", "desktop.ini",
};

/// 递归收集文件相对路径（'/' 分隔，无前导 ./，按字典序排序）。
pub fn collectFiles(
    alloc: std.mem.Allocator,
    root: []const u8,
    excludes: []const []const u8,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |it| alloc.free(it);
        list.deinit(alloc);
    }
    try walk(alloc, root, "", excludes, &list, 0);
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return list.toOwnedSlice(alloc);
}

fn walk(
    alloc: std.mem.Allocator,
    root: []const u8,
    rel_prefix: []const u8,
    excludes: []const []const u8,
    list: *std.ArrayList([]const u8),
    depth: u8,
) !void {
    if (depth > 16) return;
    const pattern = try joinPath(alloc, root, "*");
    defer alloc.free(pattern);
    const pattern_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pattern);
    defer alloc.free(pattern_w);

    var wfd: WIN32_FIND_DATAW = undefined;
    const h = FindFirstFileW(pattern_w.ptr, &wfd);
    if (h == INVALID_HANDLE_VALUE) return; // 目录不存在 → 空

    defer _ = FindClose(h);

    while (true) {
        const name_len = std.mem.indexOfScalar(u16, &wfd.cFileName, 0) orelse wfd.cFileName.len;
        if (name_len > 0 and wfd.cFileName[0] != '.') {
            if (std.unicode.utf16LeToUtf8Alloc(alloc, wfd.cFileName[0..name_len])) |name| {
                defer alloc.free(name);
                const excluded = for (excludes) |e| {
                    if (std.ascii.eqlIgnoreCase(name, e)) break true;
                } else false;
                const is_dir = (wfd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                const is_reparse = (wfd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;

                if (!excluded and !is_reparse) {
                    if (is_dir) {
                        const sub_rel = if (rel_prefix.len == 0)
                            try alloc.dupe(u8, name)
                        else
                            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel_prefix, name });
                        defer alloc.free(sub_rel);
                        const sub_abs = try joinPath(alloc, root, name);
                        defer alloc.free(sub_abs);
                        try walk(alloc, sub_abs, sub_rel, excludes, list, depth + 1);
                    } else {
                        const rel = if (rel_prefix.len == 0)
                            try alloc.dupe(u8, name)
                        else
                            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel_prefix, name });
                        try list.append(alloc, rel);
                    }
                }
            } else |_| {}
        }
        if (FindNextFileW(h, &wfd) == 0) break;
    }
}

fn joinPath(alloc: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ base, name });
}

/// 生成 zilt-assets/assets.zig 源码（payload 相对路径与 collectFiles 顺序一致）。
pub fn generateAssetsZig(alloc: std.mem.Allocator, files: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    if (files.len == 0) {
        try out.appendSlice(alloc, "// 警告：前端 dist 目录为空或不存在——先运行前端构建（zig build frontend）。\n");
    }
    try out.appendSlice(alloc, "// 由 build.zig 资产 codegen 自动生成（排序稳定，勿手改）。\nconst zilt = @import(\"zilt\");\n\npub const assets = [_]zilt.Asset{\n");
    for (files) |rel| {
        const url = try urlPath(alloc, rel);
        defer alloc.free(url);
        const esc = try zigEscape(alloc, url);
        defer alloc.free(esc);
        try out.print(alloc, "    .{{ .path = \"{s}\", .content = @embedFile(\"payload/{s}\") }},\n", .{ esc, rel });
    }
    try out.appendSlice(alloc, "};\n");
    return out.toOwnedSlice(alloc);
}

/// 相对路径 → URL 路径（'/' 分隔，'/' 开头）。
pub fn urlPath(alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
    const out = try std.fmt.allocPrint(alloc, "/{s}", .{rel});
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Zig 字符串字面量转义（" \ 与控制字符）。
pub fn zigEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// dist 相对路径与 rel 拼接（'\' 分隔，供 addCopyFile 的子路径）。
pub fn fsJoin(alloc: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, rel);
    for (out) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ base, out });
}

var temp_w_buf = [5:0]u16{ 'T', 'E', 'M', 'P', 0 };

fn tempRoot(alloc: std.mem.Allocator) ![]u8 {
    const temp_w: LPCWSTR = @ptrCast(&temp_w_buf);
    const need = GetEnvironmentVariableW(temp_w, null, 0);
    if (need == 0) return alloc.dupe(u8, "C:" ++ bs ++ "Windows" ++ bs ++ "Temp");
    const buf = try alloc.alloc(u16, need + 1);
    defer alloc.free(buf);
    const got = GetEnvironmentVariableW(temp_w, buf.ptr, @intCast(need + 1));
    if (got == 0 or got > need) return alloc.dupe(u8, "C:" ++ bs ++ "Windows" ++ bs ++ "Temp");
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..got]);
}

const bs = "\\"; // 单个反斜杠（Zig 转义）

// ---------------------------------------------------------------------------
// 测试（zig build test-tools）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "zigEscape" {
    const e = try zigEscape(testing.allocator, "a\"b\\c");
    defer testing.allocator.free(e);
    try testing.expectEqualStrings("a\\\"b\\\\c", e);
}

test "urlPath: 反斜杠转正斜杠 + 前导斜杠" {
    const u = try urlPath(testing.allocator, "assets\\index.js");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("/assets/index.js", u);
}

test "collectFiles: 排序 + 排除 + 递归（真实临时目录）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const pid = std.os.windows.GetCurrentProcessId();
    const root = try std.fmt.allocPrint(alloc, "{s}\\zilt-cg-{d}", .{ try tempRoot(alloc), pid });
    defer alloc.free(root);

    try mkDir(root);
    try mkDir(try std.fmt.allocPrint(alloc, "{s}\\assets", .{root}));
    try mkDir(try std.fmt.allocPrint(alloc, "{s}\\node_modules", .{root}));
    try writeFileTree(try std.fmt.allocPrint(alloc, "{s}\\index.html", .{root}), "<html></html>");
    try writeFileTree(try std.fmt.allocPrint(alloc, "{s}\\assets\\app.js", .{root}), "console.log(1)");
    try writeFileTree(try std.fmt.allocPrint(alloc, "{s}\\node_modules\\x.js", .{root}), "junk");
    defer cleanupTree(alloc, root);

    const files = try collectFiles(alloc, root, &default_excludes);
    defer {
        for (files) |f| alloc.free(f);
        alloc.free(files);
    }
    try testing.expectEqual(@as(usize, 2), files.len); // node_modules 被排除
    try testing.expectEqualStrings("assets/app.js", files[0]); // 排序稳定
    try testing.expectEqualStrings("index.html", files[1]);

    const src = try generateAssetsZig(alloc, files);
    defer alloc.free(src);
    try testing.expect(std.mem.indexOf(u8, src, ".path = \"/index.html\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "@embedFile(\"payload/index.html\")") != null);
    try testing.expect(std.mem.indexOf(u8, src, "@import(\"zilt\")") != null);
}

fn mkDir(path: []const u8) !void {
    const w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, path);
    defer testing.allocator.free(w);
    _ = CreateDirectoryW(w.ptr, null);
}

fn cleanupTree(alloc: std.mem.Allocator, root: []const u8) void {
    const names = [_][]const u8{
        "index.html", "assets\\app.js", "node_modules\\x.js",
    };
    for (names) |n| {
        const p = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ root, n }) catch continue;
        defer alloc.free(p);
        const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, p) catch continue;
        defer alloc.free(pw);
        _ = DeleteFileW(pw.ptr);
    }
    const subs = [_][]const u8{ "assets", "node_modules" };
    for (subs) |n| {
        const p = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ root, n }) catch continue;
        defer alloc.free(p);
        const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, p) catch continue;
        defer alloc.free(pw);
        _ = RemoveDirectoryW(pw.ptr);
    }
    const rw = std.unicode.utf8ToUtf16LeAllocZ(alloc, root) catch return;
    defer alloc.free(rw);
    _ = RemoveDirectoryW(rw.ptr);
}

fn writeFileTree(path: []const u8, data: []const u8) !void {
    const w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, path);
    defer testing.allocator.free(w);
    const GENERIC_WRITE: DWORD = 0x40000000;
    const CREATE_ALWAYS: DWORD = 2;
    const f = CreateFileW(w.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0x80, null);
    if (f == INVALID_HANDLE_VALUE) return error.TestUnexpectedResult;
    defer _ = CloseHandle(f);
    var written: DWORD = 0;
    _ = WriteFile(f, data.ptr, @intCast(data.len), &written, null);
}

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;
