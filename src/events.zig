//! 示例事件处理器（JS→Zig 事件）：每个 pub fn 对应一个事件名。
//! 函数签名约定：fn(ctx: zilt.Context, payload: struct{...}) void（或 !void）。

const std = @import("std");
const zilt = @import("zilt");
const Context = zilt.Context;

/// v0.1.20：Zig 侧订阅内置窗口事件的计数（冒烟断言用）。
/// 说明：内置事件（windowMoved/windowResized/...）现在同时分发到 events 命名空间，
/// 因此这里可以像前端 `window.zilt.on` 一样在 Zig 里收到。
pub var builtin_hits = std.atomic.Value(u32).init(0);

pub fn windowMoved(_: Context, payload: struct { id: u32, x: i32, y: i32 }) void {
    _ = payload;
    _ = builtin_hits.fetchAdd(1, .monotonic);
}

/// 前端日志
pub fn frontendLog(_: Context, payload: struct { msg: []const u8 }) void {
    zilt.log.print("[frontend] {s}", .{payload.msg});
}

// ---- 菜单 / 全局快捷键（v0.1.2）----

pub fn menu(_: Context, payload: struct { id: []const u8 }) void {
    zilt.log.print("[frontend] menu clicked: {s}", .{payload.id});
}

pub fn hotkey(_: Context, payload: struct { id: []const u8 }) void {
    zilt.log.print("[frontend] hotkey fired: {s}", .{payload.id});
}

// ---- 更新器事件（命令/自动流回传） ----

pub fn updateInfo(_: Context, payload: struct { version: []const u8, notes: []const u8 = "" }) void {
    if (payload.version.len == 0) {
        zilt.log.print("[updater] up to date (frontend notice: {s})", .{payload.notes});
    } else {
        zilt.log.print("[updater] frontend notice: update {s} — {s}", .{ payload.version, payload.notes });
    }
}

pub fn updateStaged(_: Context, payload: struct { version: []const u8 }) void {
    zilt.log.print("[updater] staged event: {s} (restart to apply)", .{payload.version});
}

pub fn updaterFailed(_: Context, payload: struct { stage: []const u8, err: []const u8 }) void {
    zilt.log.print("[updater] failed at '{s}': {s}", .{ payload.stage, payload.err });
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
    clip: bool = false,
    win: bool = false,
    range: bool = false,
    winevent: bool = false,
    // v0.1.8–v0.1.12 新增检查
    windowapi: bool = false,
    eval: bool = false,
    webview: bool = false,
    capability: bool = false,
    clipmulti: bool = false,
    notification: bool = false,
    acl: bool = false,
    spa: bool = false,
    // v0.1.13–v0.1.14 新增检查
    traycheck: bool = false,
    taskbar: bool = false,
    hotkey: bool = false,
    sysinfo: bool = false,
    appearance: bool = false,
    autostart: bool = false,
    storage: bool = false,
    peripheral: bool = false,
    services: bool = false,
    http: bool = false,
    ws: bool = false,
    webviews: bool = false,
    proc: bool = false,
    partition: bool = false,
    wincontrol: bool = false,
    fsops: bool = false,
    channel: bool = false,
    initupd: bool = false,
    http2: bool = false,
    wss: bool = false,
    zigev: bool = false,
    acl2: bool = false,
    fs2: bool = false,
    // v0.1.23
    cdp: bool = false,
    shot: bool = false,
    hdrs: bool = false,
    find: bool = false,
    proxy: bool = false,
    overlay: bool = false,
    // v0.1.24
    proto: bool = false,
    ua: bool = false,
    fatal: ?[]const u8 = null,
}) void {
    var ok = false;
    if (payload.fatal) |f| {
        zilt.log.print("[smoke] FATAL(frontend): {s}", .{f});
    } else {
        ok = payload.greet and payload.add and payload.fail and payload.user and payload.event and payload.mode and payload.clip and payload.win and payload.range and payload.winevent and
            payload.windowapi and payload.eval and payload.webview and payload.capability and payload.clipmulti and payload.notification and payload.acl and payload.spa and
            payload.traycheck and payload.taskbar and payload.hotkey and payload.sysinfo and payload.appearance and payload.autostart and payload.storage and payload.peripheral and payload.services and payload.http and payload.ws and payload.webviews and payload.proc and payload.partition and payload.wincontrol and payload.fsops and payload.channel and payload.initupd and payload.http2 and payload.wss and payload.zigev and payload.acl2 and payload.fs2 and
            payload.cdp and payload.shot and payload.hdrs and payload.find and payload.proxy and payload.overlay and payload.proto and payload.ua;
        if (ok) {
            zilt.log.print("[smoke] ALL CHECKS PASSED (49 checks: core-10 + window-api/eval/webview-api/capability/clipboard-multi/notification/acl/spa + tray-check/taskbar/hotkey/sysinfo/appearance/autostart + store/fs + path/log/state + services + http + ws + webviews + proc + partition + wincontrol + fsops + channel + initupd + http2 + wss + zigev + acl2 + fs2 + cdp + shot + hdrs + find + proxy + overlay + proto + ua)", .{});
        } else {
            zilt.log.print("[smoke] FAILED greet={} add={} fail={} user={} event={} mode={} clip={} win={} range={} winevent={} windowapi={} eval={} webview={} capability={} clipmulti={} notification={}", .{
                payload.greet, payload.add, payload.fail, payload.user, payload.event, payload.mode, payload.clip,
                payload.win, payload.range, payload.winevent, payload.windowapi, payload.eval, payload.webview,
                payload.capability, payload.clipmulti, payload.notification,
            });
            zilt.log.print("[smoke] FAILED(2) acl={} spa={} traycheck={} taskbar={} hotkey={} sysinfo={} appearance={} autostart={} storage={} peripheral={} services={} http={} ws={} webviews={} proc={} partition={} wincontrol={} fsops={} channel={} initupd={} http2={} wss={} zigev={} acl2={} fs2={}", .{
                payload.acl, payload.spa, payload.traycheck, payload.taskbar, payload.hotkey, payload.sysinfo,
                payload.appearance, payload.autostart, payload.storage, payload.peripheral, payload.services,
                payload.http, payload.ws, payload.webviews, payload.proc, payload.partition, payload.wincontrol, payload.fsops, payload.channel, payload.initupd, payload.http2, payload.wss, payload.zigev, payload.acl2, payload.fs2,
            });
            zilt.log.print("[smoke] FAILED(3) cdp={} shot={} hdrs={} find={} proxy={} overlay={} proto={} ua={}", .{
                payload.cdp, payload.shot, payload.hdrs, payload.find, payload.proxy, payload.overlay, payload.proto, payload.ua,
            });
        }
    }

    const alloc = std.heap.page_allocator;
    if (zilt.platform_windows.win32.getEnvUtf8(alloc, "ZILT_SMOKE_EXIT")) |v| {
        defer alloc.free(v);
        if (v.len > 0 and v[0] == '1') ctx.quit(if (ok) 0 else 1);
    }
}
