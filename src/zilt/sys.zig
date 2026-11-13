//! 跨平台系统小工具（v0.2.0）。
//!
//! 只放「两行代码但两套实现」的东西：Win32 与 POSIX 的差异不该泄漏到命令层/
//! 框架公共逻辑里。更大的能力（fs / 环境变量 / 进程）仍走各自的模块。
//!
//! 注意：这里对 `win32` 的 import 不会给非 Windows 目标引入符号——`switch`
//! 在 comptime 上定分支，另一支不参与语义分析，链接期自然没有 `Sleep` 引用。
const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("platform/windows/win32.zig");

/// 阻塞当前线程 `ms` 毫秒（0 直接返回）。
pub fn sleepMs(ms: u64) void {
    if (ms == 0) return;
    switch (builtin.os.tag) {
        .windows => win32.Sleep(@intCast(@min(ms, std.math.maxInt(u32)))),
        else => {
            const ts: std.c.timespec = .{
                .sec = @intCast(ms / 1000),
                .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
            };
            // 拿不到 io 的线程（示例命令的 worker）只能走 libc；
            // 被信号打断时按剩余时间继续睡，避免提前返回。
            var req = ts;
            while (std.c.nanosleep(&req, &req) != 0) {
                if (req.sec == 0 and req.nsec == 0) break;
            }
        },
    }
}

/// 启动线程用的栈大小（带平台下限）。
///
/// Linux/glibc 的 `pthread_create` 对过小的栈返回 `EINVAL`，而 Zig 0.17 的
/// `std.Thread.spawn` 把它映射成 `unreachable`——于是 `.stack_size = 256 * 1024`
/// 会**直接 panic**（不是返回错误，没法 catch）。
/// 实测（Zig 0.17.1 + glibc 2.35 / Ubuntu 22.04）：128K、256K 失败，384K 起成功；
/// 下限与二进制的静态 TLS 大小有关，所以这里统一抬到 1MB 留余量。
pub fn threadStackSize(requested: usize) usize {
    if (builtin.os.tag == .windows) return requested;
    return @max(requested, 1024 * 1024);
}

const testing = std.testing;

test "sleepMs: 0 立即返回且不 panic" {
    sleepMs(0);
    try testing.expect(true);
}

test "threadStackSize: 小栈被抬到平台下限" {
    if (builtin.os.tag == .windows) {
        try testing.expectEqual(@as(usize, 256 * 1024), threadStackSize(256 * 1024));
    } else {
        try testing.expectEqual(@as(usize, 1024 * 1024), threadStackSize(256 * 1024));
        // 已经够大的不缩小
        try testing.expectEqual(@as(usize, 4 * 1024 * 1024), threadStackSize(4 * 1024 * 1024));
    }
}
