//! 极简日志：stderr + 文件双写。
//! PoC 阶段假定单 UI 线程调用（WebView2 回调全部落在 UI 线程），故不加锁。

const std = @import("std");
const win32 = @import("platform/windows/win32.zig");

var log_file: ?win32.HANDLE = null;

pub fn initFileLog(path: []const u8) void {
    const alloc = std.heap.page_allocator;
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return;
    defer alloc.free(path_w);
    const f = win32.CreateFileW(
        path_w.ptr,
        win32.FILE_APPEND_DATA,
        win32.FILE_SHARE_READ,
        null,
        win32.OPEN_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (f == win32.INVALID_HANDLE_VALUE) return;
    log_file = f;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch "(log line truncated)\n";

    std.debug.print("{s}", .{msg});
    if (log_file) |f| {
        var written: win32.DWORD = 0;
        _ = win32.WriteFile(f, msg.ptr, @intCast(msg.len), &written, null);
    }
}
