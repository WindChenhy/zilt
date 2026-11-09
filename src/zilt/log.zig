//! 极简日志：stderr + 文件双写。
//! PoC 阶段假定单 UI 线程调用（WebView2 回调全部落在 UI 线程），故不加锁。

const std = @import("std");
const win32 = @import("platform/windows/win32.zig");

var log_file: ?win32.HANDLE = null;

/// 轮转阈值与保留份数（v0.1.17）。超过 4MB → zilt.log.1，最多保留 3 份。
pub const ROTATE_BYTES: u64 = 4 * 1024 * 1024;
pub const ROTATE_KEEP: u32 = 3;

/// 轮转后的文件名：<path>.<idx>
pub fn rotatedName(alloc: std.mem.Allocator, path: []const u8, idx: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}.{d}", .{ path, idx });
}

/// 按大小轮转：超阈值时把 .1→.2→.3 依次后移，当前文件 → .1。
/// 任何一步失败都静默（日志不可用不应影响应用启动）。
pub fn rotateIfNeeded(path: []const u8, max_bytes: u64) void {
    const alloc = std.heap.page_allocator;
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return;
    defer alloc.free(path_w);

    var data: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win32.GetFileAttributesExW(path_w.ptr, 0, &data) == 0) return; // 不存在
    const size = (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow;
    if (size < max_bytes) return;

    // 老的先让位：.2→.3, .1→.2（最老一份被覆盖）
    var idx: u32 = ROTATE_KEEP - 1;
    while (idx >= 1) : (idx -= 1) {
        const from = rotatedName(alloc, path, idx) catch return;
        defer alloc.free(from);
        const to = rotatedName(alloc, path, idx + 1) catch return;
        defer alloc.free(to);
        const from_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, from) catch return;
        defer alloc.free(from_w);
        const to_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, to) catch return;
        defer alloc.free(to_w);
        _ = win32.MoveFileExW(from_w.ptr, to_w.ptr, win32.MOVEFILE_REPLACE_EXISTING);
        if (idx == 1) break;
    }
    const first = rotatedName(alloc, path, 1) catch return;
    defer alloc.free(first);
    const first_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, first) catch return;
    defer alloc.free(first_w);
    _ = win32.MoveFileExW(path_w.ptr, first_w.ptr, win32.MOVEFILE_REPLACE_EXISTING);
}

pub fn initFileLog(path: []const u8) void {
    const alloc = std.heap.page_allocator;
    rotateIfNeeded(path, ROTATE_BYTES);
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

test "rotatedName appends numeric suffix" {
    const a = std.testing.allocator;
    const n1 = try rotatedName(a, "zilt.log", 1);
    defer a.free(n1);
    try std.testing.expectEqualStrings("zilt.log.1", n1);
    const n3 = try rotatedName(a, "logs/app.log", 3);
    defer a.free(n3);
    try std.testing.expectEqualStrings("logs/app.log.3", n3);
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
