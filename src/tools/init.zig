//! `zig build init` 项目创建工具：
//!   zilt-init [-t vanilla|vue|react|svelte] [-n 项目名] [-d 目标目录]
//! 产出独立可构建的项目：
//!   - vendored 框架源码（src/zilt/**，从本仓库复制——项目完全自包含）
//!   - 共享壳（templates/_common：build.zig/main.zig/commands 等，.tmpl 占位符替换）
//!   - 模板前端（templates/<t>/frontend/**）
//!   - 模板专属 project.zig（frontend 段按模板差异生成）

const std = @import("std");

const DWORD = u32;
const BOOL = i32;
const HANDLE = *anyopaque;
const LPCWSTR = [*:0]const u16;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub extern "kernel32" fn FindFirstFileW(lpFileName: LPCWSTR, lpFindFileData: *FindData) callconv(.c) HANDLE;
pub extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *FindData) callconv(.c) BOOL;
pub extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn CreateDirectoryW(lpPathName: LPCWSTR, lpSecurityAttributes: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn CreateFileW(lpFileName: LPCWSTR, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?*anyopaque) callconv(.c) HANDLE;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.c) BOOL;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: LPCWSTR, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.c) DWORD;
pub extern "bcrypt" fn BCryptGenRandom(hAlgorithm: ?*anyopaque, pBuffer: [*]u8, cbBuffer: u32, dwFlags: u32) callconv(.c) i32;
pub extern "kernel32" fn GetTickCount64() callconv(.c) u64;

pub const FILETIME = extern struct { dwLowDateTime: DWORD, dwHighDateTime: DWORD };
pub const FindData = extern struct {
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
const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const OPEN_EXISTING: DWORD = 3;
const CREATE_ALWAYS: DWORD = 2;

const alloc = std.heap.page_allocator;
const BS = "\\"; // 单个反斜杠

pub const templates_available = [_][]const u8{ "vanilla", "vue", "react", "svelte" };

fn getEnv(alloc2: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
    const nw = std.unicode.utf8ToUtf16LeAllocZ(alloc2, name) catch return null;
    defer alloc2.free(nw);
    const need = GetEnvironmentVariableW(nw.ptr, null, 0);
    if (need == 0) return null;
    const buf = alloc2.alloc(u16, need + 1) catch return null;
    defer alloc2.free(buf);
    const got = GetEnvironmentVariableW(nw.ptr, buf.ptr, @intCast(need + 1));
    if (got == 0 or got > need) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc2, buf[0..got]) catch null;
}

pub fn main() !void {
    // 0.17 build 无 b.args——参数经环境变量：ZILT_INIT_TEMPLATE / ZILT_INIT_NAME / ZILT_INIT_DEST
    const template: []const u8 = getEnv(alloc, "ZILT_INIT_TEMPLATE") orelse "vanilla";
    const name: []const u8 = getEnv(alloc, "ZILT_INIT_NAME") orelse "my-zilt-app";
    const dest: ?[]const u8 = getEnv(alloc, "ZILT_INIT_DEST");

    var ok = false;
    for (templates_available) |t| {
        if (std.mem.eql(u8, t, template)) ok = true;
    }
    if (!ok) {
        std.debug.print("error: 未知模板 '{s}'（可选：", .{template});
        for (templates_available, 0..) |t, j| {
            std.debug.print("{s}{s}", .{ t, if (j + 1 < templates_available.len) "/" else "" });
        }
        std.debug.print("）\n", .{});
        return error.UnknownTemplate;
    }
    if (!validName(name)) {
        std.debug.print("error: 项目名只能包含字母/数字/-/_\n", .{});
        return error.BadName;
    }

    const dest_dir = dest orelse try alloc.dupe(u8, name);
    const dest_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, dest_dir);
    _ = CreateDirectoryW(dest_w.ptr, null); // 已存在则报错由后续目录创建兜底

    // 1) vendored 框架源码与工具（项目完全自包含）
    try copyTree("src/zilt", try join3(dest_dir, "src", "zilt"), false);
    try copyTree("src/tools", try join3(dest_dir, "src", "tools"), false);

    // 2) 共享壳（.tmpl 占位符替换）
    try copyTree("templates/_common", dest_dir, true);

    // 3) 模板前端 + 模板专属 project.zig（frontend 段按模板差异）
    const tmpl_root = try join2("templates", template);
    try copyTree(try join2(tmpl_root, "frontend"), try join2(dest_dir, "frontend"), false);
    {
        const pz_data = try readFile(try join2(tmpl_root, "project.zig.tmpl"));
        defer alloc.free(pz_data);
        const replaced = try replacePlaceholders(alloc, pz_data);
        defer alloc.free(replaced);
        try writeFile(try join3(dest_dir, "src", "project.zig"), replaced);
    }

    std.debug.print(
        \\✓ 项目已创建: {s}（模板 {s}）
        \\
        \\下一步:
        \\  cd {s}
        \\  npm install            （或 pnpm/bun install；vanilla 模板无需）
        \\  zig build frontend     （构建前端到 frontend/dist）
        \\  zig build run          （运行：资产已嵌入 exe）
        \\  zig build dev          （开发：spawn dev server → 直连 HMR）
        \\
    , .{ dest_dir, template, dest_dir });
}

fn utf8(w: [*:0]u16) []u8 {
    return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(w)) catch "";
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// build.zig.zon 的 name 字段（合法标识符）：小写、非字母数字转 _、数字开头加前缀。
pub fn zonNameAlloc(alloc2: std.mem.Allocator, name: []const u8) ![]u8 {
    const fixed = zonName(name);
    const len = std.mem.indexOfScalar(u8, &fixed, 0) orelse fixed.len;
    return alloc2.dupe(u8, fixed[0..len]);
}

/// build.zig.zon 的 name 字段（合法标识符）：小写、非字母数字转 _、数字开头加前缀。
pub fn zonName(name: []const u8) [64]u8 {
    var out: [64]u8 = undefined;
    var n: usize = 0;
    for (name) |c| {
        if (n >= out.len) break;
        const lower = std.ascii.toLower(c);
        out[n] = if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) lower else '_';
        n += 1;
    }
    if (n == 0 or (out[0] >= '0' and out[0] <= '9')) {
        // 前移插入 "app" 前缀
        const prefix = "app";
        if (n + prefix.len < out.len) {
            std.mem.copyBackwards(u8, out[prefix.len..][0..n], out[0..n]);
            @memcpy(out[0..prefix.len], prefix);
            n += prefix.len;
        }
    }
    for (out[n..]) |*c| c.* = 0;
    return out;
}

/// 递归复制。replace=true 时：.tmpl 文件做占位符替换并去掉后缀。
fn copyTree(src: []const u8, dst: []const u8, replace: bool) !void {
    mkDir(dst);
    const pattern = try join2(src, "*");
    const pattern_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pattern);
    defer alloc.free(pattern_w);

    var fd: FindData = undefined;
    const h = FindFirstFileW(pattern_w.ptr, &fd);
    if (h == INVALID_HANDLE_VALUE) return error.SourceMissing;
    defer _ = FindClose(h);

    while (true) {
        const name_len = std.mem.indexOfScalar(u16, &fd.cFileName, 0) orelse fd.cFileName.len;
        const is_dot = name_len == 1 and fd.cFileName[0] == '.';
        const is_dotdot = name_len == 2 and fd.cFileName[0] == '.' and fd.cFileName[1] == '.';
        if (name_len > 0 and !is_dot and !is_dotdot) {
            const name = utf8(@ptrCast(&fd.cFileName));
            defer alloc.free(name);
            const is_dir = (fd.dwFileAttributes & 0x10) != 0;

            const src_path = try join2(src, name);
            const dst_path = try join2(dst, name);
            if (is_dir) {
                try copyTree(src_path, dst_path, replace);
            } else if (replace and std.mem.endsWith(u8, name, ".tmpl")) {
                const out_name = name[0 .. name.len - 5];
                const out_path = try join2(dst, out_name);
                const data = try readFile(src_path);
                defer alloc.free(data);
                const replaced = try replacePlaceholders(alloc, data);
                defer alloc.free(replaced);
                try writeFile(out_path, replaced);
            } else {
                const data = try readFile(src_path);
                defer alloc.free(data);
                try writeFile(dst_path, data);
            }
        }
        if (FindNextFileW(h, &fd) == 0) break;
    }
}

/// 占位符替换（Zig shell 文件）。
pub fn replacePlaceholders(alloc2: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc2);
    var i: usize = 0;
    while (i < data.len) {
        if (std.mem.startsWith(u8, data[i..], "{{")) {
            const end = std.mem.indexOfPos(u8, data, i, "}}") orelse {
                try out.append(alloc2, data[i]);
                i += 1;
                continue;
            };
            const key = data[i + 2 .. end];
            if (std.mem.eql(u8, key, "APP_NAME")) {
                try out.appendSlice(alloc2, app_name_value);
            } else if (std.mem.eql(u8, key, "APP_ID")) {
                try out.appendSlice(alloc2, app_id_value);
            } else if (std.mem.eql(u8, key, "VERSION")) {
                try out.appendSlice(alloc2, version_value);
            } else if (std.mem.eql(u8, key, "ZON_NAME")) {
                const zn = zonName(app_name_value);
                try out.appendSlice(alloc2, zn[0..std.mem.indexOfScalar(u8, &zn, 0) orelse zn.len]);
            } else if (std.mem.eql(u8, key, "FINGERPRINT")) {
                // Zig 包指纹：高 32 位随机 id（1..0xfffffffe），低 32 位 = crc32(zon name)
                var fp: [8]u8 = undefined;
                if (BCryptGenRandom(null, fp[0..4], 4, 2) != 0) {
                    const tick = GetTickCount64();
                    @memcpy(fp[0..4], @as(*const [4]u8, @ptrCast(&tick)));
                }
                var id = std.mem.readInt(u32, fp[0..4], .little);
                if (id == 0 or id == 0xffffffff) id = 0x12345678;
                const checksum = std.hash.Crc32.hash(zon_name_value);
                const fingerprint = (@as(u64, checksum) << 32) | id;
                try out.print(alloc2, "0x{x:0>16}", .{fingerprint});
            } else {
                try out.appendSlice(alloc2, data[i .. end + 2]); // 未知占位符原样保留
            }
            i = end + 2;
        } else {
            try out.append(alloc2, data[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc2);
}

// 由 main 解析后填充（模块级可变状态；工具进程生命周期内有效）
var app_name_value: []const u8 = "My Zilt App";
var app_id_value: []const u8 = "app.myziltapp";
var version_value: []const u8 = "0.1.0";
var zon_name_value: []const u8 = "my_zilt_app";

// ---------------------------------------------------------------------------
// 测试（zig build test-tools）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "validName" {
    try testing.expect(validName("my-app"));
    try testing.expect(validName("App_1"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("a b"));
    try testing.expect(!validName("中文"));
}

test "zonName: 清洗 + 数字开头补前缀" {
    const a = zonName("my-app");
    try testing.expect(std.mem.startsWith(u8, &a, "my_app"));
    const b = zonName("1abc");
    try testing.expect(std.mem.startsWith(u8, &b, "app1abc"));
    const c = zonName("Vue TS!"); // 空格/! → _
    try testing.expect(std.mem.startsWith(u8, &c, "vue_ts_"));
}

test "replacePlaceholders" {
    const out = try replacePlaceholders(testing.allocator, "name={{APP_NAME}} id={{APP_ID}} v={{VERSION}} keep={{X}}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "name=My Zilt App") != null);
    try testing.expect(std.mem.indexOf(u8, out, "id=app.myziltapp") != null);
    try testing.expect(std.mem.indexOf(u8, out, "v=0.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "keep={{X}}") != null);
}

// ---- 文件助手 ----

fn join2(base: []const u8, a: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}" ++ BS ++ "{s}", .{ base, a });
}

fn join3(base: []const u8, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}" ++ BS ++ "{s}" ++ BS ++ "{s}", .{ base, a, b });
}

/// 递归创建目录（逐段创建，CreateDirectoryW 不建父目录）。
fn mkDir(path: []const u8) void {
    var i: usize = 0;
    while (i < path.len) {
        // 跳过盘符段（如 "D:"）
        if (i + 1 < path.len and path[i + 1] == ':') {
            i += 3; // "X:" + 分隔符
            continue;
        }
        if (path[i] == 92 or path[i] == 47) { // backslash or slash
            i += 1;
            continue;
        }
        const end = std.mem.indexOfAnyPos(u8, path, i, "\x5c/") orelse path.len;
        const seg_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path[0..end]) catch return;
        defer alloc.free(seg_w);
        _ = CreateDirectoryW(seg_w.ptr, null); // 已存在则失败，忽略
        i = end;
    }
}

fn readFile(path: []const u8) ![]u8 {
    const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(w);
    const f = CreateFileW(w.ptr, GENERIC_READ, 1, null, OPEN_EXISTING, 0x80, null);
    if (f == INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer _ = CloseHandle(f);
    var size: i64 = 0;
    if (GetFileSizeEx(f, &size) != 0 and size > 0) {
        const buf = try alloc.alloc(u8, @intCast(size));
        var total: DWORD = 0;
        while (total < buf.len) {
            var got: DWORD = 0;
            if (ReadFile(f, buf.ptr + total, @intCast(buf.len - total), &got, null) == 0 or got == 0) {
                alloc.free(buf);
                return error.ReadFailed;
            }
            total += got;
        }
        return buf;
    }
    return alloc.alloc(u8, 0);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(w);
    const f = CreateFileW(w.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0x80, null);
    if (f == INVALID_HANDLE_VALUE) {
        std.debug.print("[init] writeFile OpenFailed: {s}\n", .{path});
        return error.OpenFailed;
    }
    defer _ = CloseHandle(f);
    var written: DWORD = 0;
    if (WriteFile(f, data.ptr, @intCast(data.len), &written, null) == 0) return error.WriteFailed;
}
