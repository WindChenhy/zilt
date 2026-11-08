// v0.1.16: http（后台线程 + PostMessage + httpResponse 事件）
// v0.1.15: msix（AppxManifest / ICO 帧 / 版本规范化）
// v0.1.15: wix_vendor（MSI 工具链 vendor）
//! Zilt —— 基于系统 WebView 的跨平台 GUI 框架（框架本体 Zig）。
//!
//! Phase 0–2：Windows 平台（纯 Zig 手写 WebView2 COM 绑定）。
//! Linux（zig-gobject/WebKitGTK）与 macOS（zig-objc/WKWebView）为 Phase 1 后置项。

const builtin = @import("builtin");

pub const log = @import("log.zig");
pub const ipc = @import("ipc.zig");
pub const bindings = @import("bindings.zig");
pub const bundler = @import("bundler.zig");
pub const updater = @import("updater.zig");
pub const patch = @import("patch.zig");
pub const pack_formats = @import("pack_formats.zig");
pub const Config = @import("config.zig").Config;
pub const Asset = @import("config.zig").Asset;
pub const Context = ipc.Context;
pub const security = @import("security.zig");
pub const builtin_commands = @import("builtin.zig");
pub const webview = @import("webview.zig");
pub const environment = @import("environment.zig");
pub const clipboard = @import("clipboard.zig");
pub const drag_drop = @import("drag_drop.zig");
pub const notification = @import("notification.zig");
pub const accel = @import("accel.zig");
pub const menu_model = @import("menu_model.zig");
pub const taskbar = @import("taskbar.zig");
pub const sysinfo = @import("sysinfo.zig");
pub const shell = @import("shell.zig");
pub const autostart = @import("autostart.zig");
pub const theme = @import("theme.zig");
pub const system_api = @import("system_api.zig");
pub const codesign = @import("codesign.zig");
pub const wix_vendor = @import("wix_vendor.zig");
pub const msix = @import("msix.zig");
pub const store = @import("store.zig");
pub const fs_api = @import("fs_api.zig");
pub const services = @import("services.zig");

/// 平台模块（Windows 后端内部使用；用户一般无需直接接触）
pub const platform_windows = @import("platform/windows/mod.zig");

/// 运行应用（入口）。config 为编译期值（commands 等类型字段要求）。
pub fn run(comptime config: Config) !void {
    switch (builtin.os.tag) {
        .windows => return platform_windows.backend.run(config),
        else => @compileError("Zilt: 该平台后端尚未实现（Phase 1 计划：Linux/macOS）"),
    }
}

test {
    _ = @import("security.zig");
    _ = @import("asset_routes.zig");
    _ = @import("builtin.zig");
    _ = @import("webview.zig");
    _ = @import("environment.zig");
    _ = @import("clipboard.zig");
    _ = @import("drag_drop.zig");
    _ = @import("notification.zig");
    _ = @import("accel.zig");
    _ = @import("menu_model.zig");
    _ = @import("taskbar.zig");
    _ = @import("sysinfo.zig");
    _ = @import("shell.zig");
    _ = @import("autostart.zig");
    _ = @import("theme.zig");
    _ = @import("system_api.zig");
    _ = @import("codesign.zig");
    _ = @import("wix_vendor.zig");
    _ = @import("msix.zig");
    _ = @import("store.zig");
    _ = @import("fs_api.zig");
    _ = @import("services.zig");
    _ = @import("ipc.zig");
    _ = @import("bindings.zig");
    _ = @import("bundler.zig");
    _ = @import("updater.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("platform/windows/backend.zig");
        _ = @import("platform/windows/menu.zig");
        _ = @import("platform/windows/hotkey.zig");
        _ = @import("platform/windows/dialog.zig");
        _ = @import("platform/windows/taskbar.zig");
        _ = @import("platform/windows/sysinfo.zig");
        _ = @import("platform/windows/system_integration.zig");
    }
}
