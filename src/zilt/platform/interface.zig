//! 平台后端契约（v0.2.0）。
//!
//! 一个平台后端（`platform/<os>/backend.zig`）必须提供：
//!
//! ```zig
//! pub const platform_name: []const u8;        // 诊断/日志用，如 "windows"
//! pub fn run(comptime config: Config) !void;   // 应用入口（阻塞至退出）
//! ```
//!
//! 并通过 `ipc.Context`（各后端自行构造，Windows 见 `backend.zig::makeContextWith`）
//! 把能力钩子交给平台无关层。**未实现的钩子必须留 null**，调用方依赖固定的降级错误名
//! （见下方 `test "最小 Context 的降级语义稳定"`）——Linux 后端照此实现即可保证
//! 前端拿到的错误与 Windows 一致。
//!
//! 能力矩阵（`windows_capabilities` / `linux_target_capabilities`）是文档的代码化版本：
//! Linux 侧按 `linux_target_capabilities` 逐项打勾，测试保证两项列表自身合法。
const std = @import("std");
const builtin = @import("builtin");

const Config = @import("../config.zig").Config;
const ipc = @import("../ipc.zig");

/// 平台能力标签（用于文档矩阵与可读性；不参与运行时分支）。
pub const Capability = enum {
    // 窗口
    window,
    multi_window,
    window_state,
    window_transparency,
    titlebar_overlay,
    per_window_proxy,
    per_window_user_agent,
    // WebView
    webview_eval,
    devtools,
    downloads,
    data_partition,
    child_webview,
    screenshot,
    cdp,
    find_in_page,
    // 内容与协议
    asset_server,
    custom_protocol,
    csp,
    // IPC
    ipc_events,
    ipc_stream,
    // 安全与数据
    capability_acl,
    fs_scopes,
    fs_watch,
    sql,
    store,
    http,
    websocket,
    // 系统集成
    tray,
    menu,
    notification,
    clipboard,
    drag_drop,
    dialog,
    autostart,
    deep_link,
    single_instance,
    global_hotkey,
    shell,
    sysinfo,
    theme,
    // 分发与工具链
    updater,
    headless,
    mcp,
    webdriver,
    packaging,
    // 平台独占（Linux 不适用）
    taskbar,
    window_material,
    pe_resources,
    authenticode,
    msix,
};

/// Windows 后端当前实现的能力（v0.1.24 实测面）。
pub const windows_capabilities = [_]Capability{
    .window,                .multi_window,   .window_state,      .window_transparency,
    .titlebar_overlay,      .per_window_proxy, .per_window_user_agent,
    .webview_eval,          .devtools,       .downloads,         .data_partition,
    .child_webview,         .screenshot,     .cdp,               .find_in_page,
    .asset_server,          .custom_protocol, .csp,
    .ipc_events,            .ipc_stream,
    .capability_acl,        .fs_scopes,      .fs_watch,          .sql,
    .store,                 .http,           .websocket,
    .tray,                  .menu,           .notification,      .clipboard,
    .drag_drop,             .dialog,         .autostart,         .deep_link,
    .single_instance,       .global_hotkey,  .shell,             .sysinfo,
    .theme,
    .updater,               .headless,       .mcp,               .webdriver,
    .packaging,
    .taskbar,               .window_material, .pe_resources,     .authenticode,
    .msix,
};

/// Linux 目标能力（v0.2.0–v0.2.5 的验收清单；见 docs/v0.2-LINUX.md §5）。
/// 平台独占项（taskbar / mica / PE 资源 / Authenticode / MSIX）刻意不在列表内。
pub const linux_target_capabilities = [_]Capability{
    .window,                .multi_window,   .window_state,      .window_transparency,
    .titlebar_overlay,      .per_window_user_agent,
    .webview_eval,          .devtools,       .downloads,         .data_partition,
    .child_webview,         .screenshot,
    .asset_server,          .custom_protocol, .csp,
    .ipc_events,            .ipc_stream,
    .capability_acl,        .fs_scopes,      .fs_watch,          .sql,
    .store,                 .http,           .websocket,
    .tray,                  .menu,           .notification,      .clipboard,
    .drag_drop,             .dialog,         .autostart,         .deep_link,
    .single_instance,       .global_hotkey,  .shell,             .sysinfo,
    .theme,
    .updater,               .headless,       .mcp,
    .packaging,
};

/// 编译期校验后端契约（`platform/mod.zig` 在本平台后端上调用一次）。
pub fn assertBackend(comptime B: type) void {
    if (!@hasDecl(B, "platform_name")) @compileError("平台后端缺少 `pub const platform_name: []const u8`");
    if (!@hasDecl(B, "run")) @compileError("平台后端缺少 `pub fn run(comptime config: Config) !void`");

    const Run = @TypeOf(B.run);
    switch (@typeInfo(Run)) {
        .@"fn" => |f| {
            // Zig 0.17：函数类型信息用 param_types（0.13 的 params 已移除）
            if (f.param_types.len != 1) @compileError("平台后端 run 必须只接受一个参数（comptime Config）");
            const ret = f.return_type orelse @compileError("平台后端 run 返回类型必须是 !void");
            switch (@typeInfo(ret)) {
                .error_union => |eu| if (eu.payload != void) @compileError("平台后端 run 必须返回 !void"),
                else => @compileError("平台后端 run 必须返回 !void"),
            }
        },
        else => @compileError("平台后端的 run 必须是函数"),
    }
}

const testing = std.testing;

fn noEmit(_: *anyopaque, _: u32, _: []const u8) void {}
fn noQuit(_: *anyopaque, _: u8) void {}

// 用「只有必需字段」的 Context 验证降级语义：Linux 后端未实现的钩子留 null 时，
// 前端必须拿到与 Windows 相同的错误名。
test "v0.2.0: 最小 Context 的降级语义稳定" {
    var dummy: u8 = 0;
    const ctx = ipc.Context{
        .allocator = testing.allocator,
        .msg_allocator = testing.allocator,
        .backend = @ptrCast(&dummy),
        .emit_fn = noEmit,
        .quit_fn = noQuit,
    };

    try testing.expectError(error.WebViewNotAvailable, ctx.webviewRequest(.reload));
    try testing.expectError(error.ClipboardNotAvailable, ctx.clipboardRead(.text));
    try testing.expectError(error.NotificationNotAvailable, ctx.notificationShow(.{ .title = "t", .body = "b" }));
    try testing.expectError(error.DialogNotAvailable, ctx.messageBox(.{ .text = "x" }));
    try testing.expectError(error.SystemNotAvailable, ctx.systemRequest(.{ .info = .os }));
    try testing.expectError(error.DragNotAvailable, ctx.startDrag(&.{}));
}

test "v0.2.0: 能力矩阵自身合法（无重复、覆盖核心项）" {
    const check = struct {
        fn unique(list: []const Capability) !void {
            for (list, 0..) |item, i| {
                for (list[i + 1 ..]) |other| {
                    if (item == other) return error.DuplicateCapability;
                }
            }
        }
        fn contains(list: []const Capability, cap: Capability) bool {
            for (list) |item| if (item == cap) return true;
            return false;
        }
    };

    try check.unique(&windows_capabilities);
    try check.unique(&linux_target_capabilities);

    // 核心项：两平台都必须有（Linux 目标集缺任一即说明规划漏项）
    const core = [_]Capability{ .window, .ipc_events, .asset_server, .capability_acl, .sql, .http, .single_instance };
    for (core) |cap| {
        try testing.expect(check.contains(&windows_capabilities, cap));
        try testing.expect(check.contains(&linux_target_capabilities, cap));
    }

    // 平台独占项不得出现在 Linux 目标里
    const windows_only = [_]Capability{ .taskbar, .window_material, .pe_resources, .authenticode, .msix };
    for (windows_only) |cap| {
        try testing.expect(!check.contains(&linux_target_capabilities, cap));
    }
}
