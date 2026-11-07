//! 差分包生成工具：`ZILT_DIFF_OLD=<旧exe> ZILT_DIFF_NEW=<新exe> ZILT_DIFF_OUT=<补丁输出> zig build diff`
//! 生成 zilt-patch v1 补丁（见 src/zilt/patch.zig），随后用 zilt-sign 对补丁文件签名
//! （manifest.patch.{url,sha256,signature,from,from_sha256}）。

const std = @import("std");
const zilt = @import("zilt");

const DWORD = u32;
const BOOL = i32;
const HANDLE = *anyopaque;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.c) DWORD;
pub extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?*anyopaque) callconv(.c) HANDLE;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.c) BOOL;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;

fn getEnv(alloc: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
    const nw = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
    defer alloc.free(nw);
    const need = GetEnvironmentVariableW(nw.ptr, null, 0);
    if (need == 0) return null;
    const buf = alloc.alloc(u16, need + 1) catch return null;
    defer alloc.free(buf);
    const got = GetEnvironmentVariableW(nw.ptr, buf.ptr, @intCast(need + 1));
    if (got == 0 or got > need) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..got]) catch null;
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return null;
    defer alloc.free(pw);
    const GENERIC_READ: DWORD = 0x80000000;
    const OPEN_EXISTING: DWORD = 3;
    const f = CreateFileW(pw.ptr, GENERIC_READ, 1, null, OPEN_EXISTING, 0x80, null);
    if (f == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(f);
    var size: i64 = 0;
    if (GetFileSizeEx(f, &size) == 0 or size < 0 or size > 512 * 1024 * 1024) return null;
    const buf = alloc.alloc(u8, @intCast(size)) catch return null;
    var total: DWORD = 0;
    while (total < buf.len) {
        var got: DWORD = 0;
        if (ReadFile(f, buf.ptr + total, @intCast(buf.len - total), &got, null) == 0 or got == 0) {
            alloc.free(buf);
            return null;
        }
        total += got;
    }
    return buf;
}

fn writeFile(alloc: std.mem.Allocator, path: []const u8, data: []const u8) bool {
    const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(pw);
    const GENERIC_WRITE: DWORD = 0x40000000;
    const CREATE_ALWAYS: DWORD = 2;
    const f = CreateFileW(pw.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0x80, null);
    if (f == INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(f);
    var total: DWORD = 0;
    while (total < data.len) {
        var got: DWORD = 0;
        if (WriteFile(f, data.ptr + total, @intCast(data.len - total), &got, null) == 0 or got == 0) return false;
        total += got;
    }
    return true;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const old_path = getEnv(alloc, "ZILT_DIFF_OLD") orelse {
        std.debug.print("usage: ZILT_DIFF_OLD=<old> ZILT_DIFF_NEW=<new> ZILT_DIFF_OUT=<patch> zig build diff\n", .{});
        return error.MissingArgs;
    };
    const new_path = getEnv(alloc, "ZILT_DIFF_NEW") orelse return error.MissingArgs;
    const out_path = getEnv(alloc, "ZILT_DIFF_OUT") orelse return error.MissingArgs;

    const old = readFileAlloc(alloc, old_path) orelse return error.OldReadFailed;
    const new = readFileAlloc(alloc, new_path) orelse return error.NewReadFailed;

    const patch = try zilt.patch.buildPatch(alloc, old, new);
    if (!writeFile(alloc, out_path, patch)) return error.OutWriteFailed;

    const new_sha = try zilt.updater.sha256Hex(alloc, new);
    const old_sha = try zilt.updater.sha256Hex(alloc, old);
    std.debug.print(
        "[zilt-diff] old={d} new={d} patch={d} bytes ({d:.1}% of full)\n" ++
            "[zilt-diff] from_sha256={s}\n[zilt-diff] new_sha256={s}\n" ++
            "[zilt-diff] manifest.patch = {{ \"from\": <当前版本>, \"from_sha256\": \"{s}\", \"url\": <补丁URL>, \"sha256\": \"{s}\", \"signature\": <zilt-sign 输出> }}\n",
        .{ old.len, new.len, patch.len, @as(f64, @floatFromInt(patch.len)) / @as(f64, @floatFromInt(@max(new.len, 1))) * 100.0, old_sha, new_sha, old_sha, new_sha },
    );
}
