//! Win32 环境变量读取——pack / diff_patch / sign_update 三个工具原先各有一份
//! 完全相同的 12 行实现，现统一到这里（行为不变：返回 UTF-8 副本，调用方 free）。
const std = @import("std");

const DWORD = u32;

pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.c) DWORD;

pub fn get(alloc: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
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

test "missing variable returns null" {
    try std.testing.expect(get(std.testing.allocator, "ZILT_DEFINITELY_NOT_SET_12345") == null);
}
