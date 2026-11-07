//! 示例事件处理器（JS→Zig 事件）：每个 pub fn 对应一个事件名。
//! 函数签名约定：fn(ctx: zilt.Context, payload: struct{...}) void（或 !void）。

const std = @import("std");
const zilt = @import("zilt");
const Context = zilt.Context;

/// 前端日志
pub fn frontendLog(_: Context, payload: struct { msg: []const u8 }) void {
    zilt.log.print("[frontend] {s}", .{payload.msg});
}

/// 冒烟测试结果回传：默认仅记录；设置 ZILT_SMOKE_EXIT=1 时按结果退出
///（热重载验证需要应用存活，故退出行为由环境变量控制）。
pub fn smokeResult(ctx: Context, payload: struct {
    greet: bool = false,
    add: bool = false,
    fail: bool = false,
    user: bool = false,
    event: bool = false,
    mode: bool = false,
    fatal: ?[]const u8 = null,
}) void {
    var ok = false;
    if (payload.fatal) |f| {
        zilt.log.print("[smoke] FATAL(frontend): {s}", .{f});
    } else {
        ok = payload.greet and payload.add and payload.fail and payload.user and payload.event and payload.mode;
        if (ok) {
            zilt.log.print("[smoke] ALL CHECKS PASSED (greet/add/fail-reject/user-optional/event-tick/mode-enum)", .{});
        } else {
            zilt.log.print("[smoke] FAILED greet={} add={} fail={} user={} event={} mode={}", .{
                payload.greet, payload.add, payload.fail, payload.user, payload.event, payload.mode,
            });
        }
    }

    const alloc = std.heap.page_allocator;
    if (zilt.platform_windows.win32.getEnvUtf8(alloc, "ZILT_SMOKE_EXIT")) |v| {
        defer alloc.free(v);
        if (v.len > 0 and v[0] == '1') ctx.quit(if (ok) 0 else 1);
    }
}
