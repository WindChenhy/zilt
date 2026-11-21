//! macOS 后端（v0.4.4 骨架）：NSApplication + NSWindow，最小可启动闭环。
//!
//! 为什么手写 ObjC 而不是 `@cImport`：Zig 不带 ObjC 头文件，且 Zilt 的平台层
//! 一直走「extern + 动态消息」路线（Windows COM / Linux GTK 同构）。类名与
//! selector 都是运行时字符串，**不是链接符号**——所以非 macOS 宿主交叉编译时
//! 只需要极小的 tbd 桩（见 `stubs/`），CI 上换真 SDK 即可。
//!
//! 线程约束：NSApplication / NSWindow 全部主线程；`nextEventMatchingMask:` 手动
//! 泵事件（不用 `[NSApp run]`，否则冒烟模式无法定时退出）。
const std = @import("std");
const log = @import("../../log.zig");
const Config = @import("../../config.zig").Config;

pub const platform_name = "macos";

// ---------------------------------------------------------------------------
// ObjC 运行时（无头文件；objc_msgSend 按签名转型后调用）
// ---------------------------------------------------------------------------
const Id = *anyopaque;
const Sel = *anyopaque;
const Class = *anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "c" fn sel_registerName(name: [*:0]const u8) ?Sel;
extern "c" fn objc_msgSend() void;

inline fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name) orelse @panic("sel_registerName returned null");
}

/// 取 objc_msgSend 并按调用签名转型。签名必须与 `objc_msgSend` 的 ABI 一致
/// （arm64 上结构体返回走 x0/x1，暂未用到）。
inline fn msgSend(comptime Sig: type) Sig {
    return @ptrCast(&objc_msgSend);
}

fn classNamed(name: [*:0]const u8) Class {
    return objc_getClass(name) orelse {
        log.print("[macos] ObjC class missing: {s}", .{name});
        @panic("ObjC class missing");
    };
}

fn nsString(utf8: [*:0]const u8) Id {
    return msgSend(*const fn (Class, Sel, [*:0]const u8) callconv(.c) Id)(
        classNamed("NSString"),
        sel("stringWithUTF8String:"),
        utf8,
    );
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/// 冒烟时长（毫秒）：`ZILT_SMOKE_TEST_MS` > 0 时跑有限事件循环后退出；
/// 未设置/0 时进入 `[NSApp run]`（正常应用）。
pub fn run(comptime config: Config) !void {
    _ = config;
    const smoke_ms = parseSmokeMs(env("ZILT_SMOKE_TEST_MS"));
    log.print("[macos] platform=macos smoke_ms={d}", .{smoke_ms});

    const NSApp = classNamed("NSApplication");
    const app = msgSend(*const fn (Class, Sel) callconv(.c) Id)(NSApp, sel("sharedApplication"));

    // NSApplicationActivationPolicyRegular = 0（无 .app bundle 时也能进 Dock/前台）
    _ = msgSend(*const fn (Id, Sel, c_long) callconv(.c) bool)(app, sel("setActivationPolicy:"), 0);
    log.print("[macos] NSApplication ready (policy=regular)", .{});

    // NSRect{x,y,w,h}：4 个 double，arm64 按 HFA 传 v0-v3，与 CGRect 同 ABI
    const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };
    const NSWindow = classNamed("NSWindow");
    const alloc_obj = msgSend(*const fn (Class, Sel) callconv(.c) Id)(NSWindow, sel("alloc"));
    // styleMask: titled(1)|closable(2)|miniaturizable(4)|resizable(8) = 15
    // backing: NSBackingStoreBuffered = 2
    const win = msgSend(*const fn (Id, Sel, Rect, c_ulong, c_ulong, bool) callconv(.c) Id)(
        alloc_obj,
        sel("initWithContentRect:styleMask:backing:defer:"),
        .{ .x = 240, .y = 240, .w = 900, .h = 640 },
        15,
        2,
        false,
    );
    if (@intFromPtr(win) == 0) {
        log.print("[macos] NSWindow init failed", .{});
        return error.WindowCreationFailed;
    }
    _ = msgSend(*const fn (Id, Sel, Id) callconv(.c) void)(win, sel("setTitle:"), nsString("Zilt"));
    _ = msgSend(*const fn (Id, Sel) callconv(.c) void)(win, sel("makeKeyAndOrderFront:"));
    _ = msgSend(*const fn (Id, Sel, bool) callconv(.c) void)(app, sel("activateIgnoringOtherApps:"), true);
    log.print("[macos] window created 900x640", .{});

    if (smoke_ms == 0) {
        // 正常应用：阻塞到退出（NSApp run 内部就是主 runloop）
        msgSend(*const fn (Id, Sel) callconv(.c) void)(app, sel("run"));
        return;
    }

    // 冒烟：有限事件泵，deadline 用 NSDate 自身（避免依赖 std 时间 API）
    const NSDate = classNamed("NSDate");
    const mode = nsString("kCFRunLoopDefaultMode");
    const deadline = msgSend(*const fn (Class, Sel, f64) callconv(.c) Id)(
        NSDate,
        sel("dateWithTimeIntervalSinceNow:"),
        @as(f64, @floatFromInt(smoke_ms)) / 1000.0,
    );
    log.print("[macos] event loop start", .{});
    while (true) {
        const until = msgSend(*const fn (Class, Sel, f64) callconv(.c) Id)(
            NSDate,
            sel("dateWithTimeIntervalSinceNow:"),
            0.05,
        );
        // nextEventMatchingMask:untilDate:inMode:dequeue:
        if (msgSend(*const fn (Id, Sel, c_ulong, Id, Id, bool) callconv(.c) ?Id)(
            app,
            sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
            ~@as(c_ulong, 0),
            until,
            mode,
            true,
        )) |ev| {
            msgSend(*const fn (Id, Sel, Id) callconv(.c) void)(app, sel("sendEvent:"), ev);
        }
        // [deadline timeIntervalSinceNow] <= 0 → 到时
        const left = msgSend(*const fn (Id, Sel) callconv(.c) f64)(deadline, sel("timeIntervalSinceNow"));
        if (left <= 0) break;
    }
    log.print("[macos] smoke done, exiting", .{});
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// 解析冒烟时长（非数字/负数 → 0；上限 10 分钟防 CI 挂死）。
fn parseSmokeMs(raw: ?[]const u8) u32 {
    const s = raw orelse return 0;
    const v = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t\r\n"), 10) catch return 0;
    return @min(v, 600_000);
}

test "macos: parseSmokeMs 边界" {
    try std.testing.expectEqual(@as(u32, 0), parseSmokeMs(null));
    try std.testing.expectEqual(@as(u32, 0), parseSmokeMs("abc"));
    try std.testing.expectEqual(@as(u32, 5000), parseSmokeMs("5000"));
    try std.testing.expectEqual(@as(u32, 5000), parseSmokeMs(" 5000\n"));
    try std.testing.expectEqual(@as(u32, 600_000), parseSmokeMs("999999999"));
}
