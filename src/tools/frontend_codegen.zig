//! 前端资产 codegen（build.zig 执行期调用）：
//! 遍历前端 dist 目录（win32 FindFirstFile，自包含实现）→ 生成 zilt-assets 模块
//! （@embedFile 相对路径表 + payload 副本）。
//!
//! 设计要点（对标 tauri-codegen，见 docs/research/frontend-integration.md §4.2）：
//!  - 遍历结果按路径排序 → 生成文件内容确定 → zig 缓存命中（资产未变不重编）
//!  - 内建排除：node_modules/.git/zig-cache 等（防误嵌，Tauri build.rs 同款防御）
//!  - dist 缺失 → 空资产表 + 生成文件内注释警告（应用可构建，运行时 404）
//!  - 资产预压缩（Phase C，对标 tauri-codegen brotli）：>gzip_min_size 且 gzip
//!    收益 ≥10% 的文件附 .gz 变体（std.compress.flate，输出确定）→ 运行时按
//!    Accept-Encoding 直接下发 + Content-Encoding: gzip

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
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.c) BOOL;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;

/// 递归建目录（'/' 或 '' 分段）。
pub fn ensureDirDeep(alloc: std.mem.Allocator, path: []const u8) !void {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' or path[i] == '\\') {
            if (i > 0 and path[i - 1] != ':') {
                const part = path[0..i];
                const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, part) catch continue;
                defer alloc.free(pw);
                _ = CreateDirectoryW(pw.ptr, null);
            }
        }
    }
    const pw = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(pw);
    _ = CreateDirectoryW(pw.ptr, null);
}

/// 写文件（覆盖；成功 true）。构建期 payload 落盘用。
pub fn writeFilePayload(alloc: std.mem.Allocator, path: []const u8, data: []const u8) bool {
    const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(pw);
    const GENERIC_WRITE: DWORD = 0x40000000;
    const CREATE_ALWAYS: DWORD = 2;
    const f = CreateFileW(pw.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0x80, null);
    if (f == INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(f);
    var total: usize = 0;
    while (total < data.len) {
        var got: DWORD = 0;
        const chunk: DWORD = @intCast(@min(data.len - total, 1 << 30));
        if (WriteFile(f, data.ptr + total, chunk, &got, null) == 0 or got == 0) return false;
        total += got;
    }
    return true;
}

/// 相对路径拼接（'/' 分隔；b.path() 用）。
pub fn fsJoinRel(alloc: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, rel });
}

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

/// 构建期状态：内容寻址资产目录（build.zig 填充）
pub var payload_dir_buf: ?[]const u8 = null;

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

/// 生成 zilt-assets/assets.zig 源码（payload 相对路径与 collectFiles 顺序一致；
/// gz_flags[i] 为 true 的条目只嵌 .gz 字节并标记 encoding=.gzip（Tauri 式缩 exe，
/// 服务端惰性解压后以 identity 下发）。
pub fn generateAssetsZig(alloc: std.mem.Allocator, files: []const []const u8, gz_flags: []const bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    if (files.len == 0) {
        try out.appendSlice(alloc, "// 警告：前端 dist 目录为空或不存在——先运行前端构建（zig build frontend）。\n");
    }
    try out.appendSlice(alloc, "// 由 build.zig 资产 codegen 自动生成（排序稳定，勿手改）。\nconst zilt = @import(\"zilt\");\n\npub const assets = [_]zilt.Asset{\n");
    for (files, 0..) |rel, i| {
        const url = try urlPath(alloc, rel);
        defer alloc.free(url);
        const esc = try zigEscape(alloc, url);
        defer alloc.free(esc);
        if (i < gz_flags.len and gz_flags[i]) {
            try out.print(alloc, "    .{{ .path = \"{s}\", .content = @embedFile(\"payload/{s}.gz\"), .encoding = .gzip }},\n", .{ esc, rel });
        } else {
            try out.print(alloc, "    .{{ .path = \"{s}\", .content = @embedFile(\"payload/{s}\") }},\n", .{ esc, rel });
        }
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

// ---------------------------------------------------------------------------
// 资产预压缩（Phase C；tauri-codegen brotli 的 flate 对应物）
// ---------------------------------------------------------------------------

/// 小于该值的文件不预压缩（收益抵不过元数据/解压开销）。
pub const gzip_min_size = 8 * 1024;

/// gzip 变体是否值得附带：压缩后体积需减少 ≥10%（图片等已压缩格式自然落选）。
pub fn gzipWorthwhile(raw_len: usize, gz_len: usize) bool {
    return gz_len * 10 < raw_len * 9;
}

/// gzip 预压缩（std.compress.flate，gzip 容器；相同输入输出确定 → 缓存友好）。
pub fn gzipCompress(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try aw.ensureTotalCapacity(256); // Compress.init 断言 output.buffer.len > 8
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&aw.writer, &window, .gzip, .default);
    _ = try comp.writer.writeAll(raw);
    try comp.finish();
    return alloc.dupe(u8, aw.written());
}

/// gzip 解压（运行时回退路径：客户端不接受 gzip 时还原原始字节）。
pub fn gzipDecompress(alloc: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const n = try dec.reader.streamRemaining(&aw.writer);
    const out = try alloc.dupe(u8, aw.written());
    std.debug.assert(n == out.len);
    return out;
}

/// 读取整个文件（构建期压缩输入；失败返回 null）。自包含 win32 实现。
pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return null;
    defer alloc.free(w);
    const GENERIC_READ: DWORD = 0x80000000;
    const OPEN_EXISTING: DWORD = 3;
    const FILE_SHARE_READ_WRITE: DWORD = 1 | 2;
    const f = CreateFileW(w.ptr, GENERIC_READ, FILE_SHARE_READ_WRITE, null, OPEN_EXISTING, 0, null);
    if (f == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(f);
    var size: i64 = 0;
    if (GetFileSizeEx(f, &size) == 0) return null;
    if (size <= 0 or size > 512 * 1024 * 1024) return null;
    const buf = alloc.alloc(u8, @intCast(size)) catch return null;
    var off: usize = 0;
    while (off < buf.len) {
        var got: DWORD = 0;
        if (ReadFile(f, buf.ptr + off, @intCast(buf.len - off), &got, null) == 0 or got == 0) {
            alloc.free(buf);
            return null;
        }
        off += got;
    }
    return buf;
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

    const src = try generateAssetsZig(alloc, files, &.{ false, false });
    defer alloc.free(src);
    try testing.expect(std.mem.indexOf(u8, src, ".path = \"/index.html\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "@embedFile(\"payload/index.html\")") != null);
    try testing.expect(std.mem.indexOf(u8, src, "@import(\"zilt\")") != null);
}

test "gzipCompress/gzipDecompress: magic + 往返 + 确定性" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var raw: std.ArrayList(u8) = .empty;
    for (0..500) |i| {
        try raw.print(alloc, "zilt asset line {d}: the quick brown fox jumps over the lazy dog\n", .{i});
    }

    const gz1 = try gzipCompress(alloc, raw.items);
    const gz2 = try gzipCompress(alloc, raw.items);
    try testing.expect(gz1.len > 2);
    try testing.expectEqual(@as(u8, 0x1f), gz1[0]); // gzip magic
    try testing.expectEqual(@as(u8, 0x8b), gz1[1]);
    try testing.expect(gzipWorthwhile(raw.items.len, gz1.len));
    try testing.expectEqualSlices(u8, gz1, gz2); // 确定性（缓存友好）

    const back = try gzipDecompress(alloc, gz1);
    try testing.expectEqualSlices(u8, raw.items, back);
}

test "gzipWorthwhile: 已压缩格式落选" {
    // 随机样式的数据（近似不可压）→ gzip 不省 10% → 不附带
    var raw: [8193]u8 = undefined;
    var x: u32 = 12345;
    for (&raw, 0..) |*b, i| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 16);
        _ = i;
    }
    const gz = try gzipCompress(testing.allocator, &raw);
    defer testing.allocator.free(gz);
    try testing.expect(!gzipWorthwhile(raw.len, gz.len));
}

test "generateAssetsZig: gz_flags 控制存储编码" {
    const files = [_][]const u8{ "a.js", "big.js" };
    const src = try generateAssetsZig(testing.allocator, &files, &.{ false, true });
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, ".path = \"/a.js\", .content = @embedFile(\"payload/a.js\") }") != null);
    try testing.expect(std.mem.indexOf(u8, src, ".content = @embedFile(\"payload/big.js.gz\"), .encoding = .gzip }") != null);
    // 压缩条目不再嵌原始字节（单份拷贝，缩 exe）
    try testing.expect(std.mem.indexOf(u8, src, "@embedFile(\"payload/big.js\")") == null);
}

test "readFileAlloc: 往返（真实临时文件）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const pid = std.os.windows.GetCurrentProcessId();
    const root = try std.fmt.allocPrint(alloc, "{s}\\zilt-rf-{d}", .{ try tempRoot(alloc), pid });
    defer alloc.free(root);
    try mkDir(root);
    const path = try std.fmt.allocPrint(alloc, "{s}\\data.bin", .{root});
    defer alloc.free(path);
    const payload = "bin\x00ary\xff bytes";
    try writeFileTree(path, payload);
    defer cleanupTree(alloc, root);

    const got = readFileAlloc(alloc, path) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, payload, got);
    try testing.expect(readFileAlloc(alloc, try std.fmt.allocPrint(alloc, "{s}\\missing.bin", .{root})) == null);
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
