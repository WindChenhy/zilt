//! 极简日志：stderr + 文件双写（v0.2.0 起跨平台）。
//!
//! Linux 侧冒烟靠 `zilt.log` 断言，因此文件日志必须真的落盘。
//! 写入用 `std.Io.File.Writer`（positional 模式，位置显式设为文件末尾）+ 互斥锁，
//! 因为后台线程（http/ws/fs watch）也会打日志。轮转按大小：4MB → .1 → .2 → .3。

const std = @import("std");
const Io = std.Io;

/// 惰性创建一次（Threaded 只在需要 async/concurrent 时才分配）。
var g_threaded: std.Io.Threaded = undefined;
var g_threaded_ready = false;
fn io() Io {
    if (!g_threaded_ready) {
        g_threaded = .init(std.heap.page_allocator, .{});
        g_threaded_ready = true;
    }
    return g_threaded.io();
}

var log_file: ?Io.File = null;
var log_mutex: Io.Mutex = .init;

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
    const i = io();
    const st = Io.Dir.cwd().statFile(i, path, .{}) catch return; // 不存在
    if (st.size < max_bytes) return;

    const alloc = std.heap.page_allocator;
    const cwd = Io.Dir.cwd();

    // 老的先让位：.2→.3, .1→.2（最老一份被覆盖）
    var idx: u32 = ROTATE_KEEP - 1;
    while (idx >= 1) : (idx -= 1) {
        const from = rotatedName(alloc, path, idx) catch return;
        defer alloc.free(from);
        const to = rotatedName(alloc, path, idx + 1) catch return;
        defer alloc.free(to);
        cwd.rename(from, cwd, to, i) catch {};
        if (idx == 1) break;
    }
    const first = rotatedName(alloc, path, 1) catch return;
    defer alloc.free(first);
    cwd.rename(path, cwd, first, i) catch {};
}

pub fn initFileLog(path: []const u8) void {
    rotateIfNeeded(path, ROTATE_BYTES);
    const f = Io.Dir.cwd().createFile(io(), path, .{ .truncate = false, .read = true }) catch return;
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
    const f = log_file orelse return;

    const i = io();
    log_mutex.lockUncancelable(i);
    defer log_mutex.unlock(i);
    var wbuf: [4096]u8 = undefined;
    var w = Io.File.Writer.init(f, i, &wbuf);
    // positional 模式：显式定位到末尾 → 语义等同 O_APPEND
    w.pos = f.length(i) catch return;
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}
