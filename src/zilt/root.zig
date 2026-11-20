// v0.1.16: http（后台线程 + PostMessage + httpResponse 事件）
// v0.1.15: msix（AppxManifest / ICO 帧 / 版本规范化）
// v0.1.15: wix_vendor（MSI 工具链 vendor）
//! Zilt —— 基于系统 WebView 的跨平台 GUI 框架（框架本体 Zig）。
//!
//! Phase 0–2：Windows 平台（纯 Zig 手写 WebView2 COM 绑定）。
//! Linux（zig-gobject/WebKitGTK）与 macOS（zig-objc/WKWebView）为 Phase 1 后置项。

const builtin = @import("builtin");

pub const version = @import("version.zig").version;
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
pub const power = @import("power.zig");
pub const server_session = @import("server_session.zig");
pub const shell = @import("shell.zig");
pub const autostart = @import("autostart.zig");
pub const theme = @import("theme.zig");
pub const system_api = @import("system_api.zig");
pub const codesign = @import("codesign.zig");
pub const wix_vendor = @import("wix_vendor.zig");
pub const msix = @import("msix.zig");
pub const ws = @import("ws.zig");
pub const store = @import("store.zig");
pub const fs_api = @import("fs_api.zig");
pub const services = @import("services.zig");
pub const png = @import("png.zig");
pub const ico = @import("ico.zig");
pub const sql = @import("sql.zig");
pub const npm_pack = @import("npm_pack.zig");
pub const mcp = @import("mcp.zig");
pub const net = @import("net.zig");
pub const protocol = @import("protocol.zig");
pub const sys = @import("sys.zig");

/// 平台模块（Windows 后端内部使用；用户一般无需直接接触）
pub const platform_windows = @import("platform/windows/mod.zig");
/// v0.2.0：平台后端选择层（platform/<os>/backend.zig）+ 契约校验
pub const platform = @import("platform/mod.zig");

/// 运行应用（入口）。config 为编译期值（commands 等类型字段要求）。
/// 平台选择与契约校验在 `platform/mod.zig`，本函数只做转发。
pub fn run(comptime config: Config) !void {
    return platform.run(config);
}

test {
    _ = @import("version.zig");
    _ = @import("protocol.zig");
    _ = @import("inflate.zig");
    _ = @import("sys.zig");
    _ = @import("platform/interface.zig");
    _ = @import("platform/mod.zig");
    // Linux 后端的纯逻辑单测只在 linux 目标上编译：它们 @import("gtk")，该模块由
    // build.zig 的 translate-c 在 linux 上生成。
    // 测试补齐（v0.3.19 审计）：此前只有 backend.zig 入图，其余 9 个模块的 33 个用例
    // 与 Windows 侧同病——`pub const` 惰性声明不会触发测试收集。
    if (builtin.os.tag == .linux) {
        _ = @import("platform/linux/backend.zig");
        _ = @import("platform/linux/deep_link.zig");
        _ = @import("platform/linux/desktop_entry.zig");
        _ = @import("platform/linux/fs_watch.zig");
        _ = @import("platform/linux/gtk_compat.zig");
        _ = @import("platform/linux/hotkey.zig");
        _ = @import("platform/linux/portal_hotkey.zig");
        _ = @import("platform/linux/sqlite.zig");
        _ = @import("platform/linux/sysinfo_linux.zig");
        _ = @import("platform/linux/window_state.zig");
    }
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
    _ = @import("power.zig");
    _ = @import("server_session.zig");
    _ = @import("shell.zig");
    _ = @import("autostart.zig");
    _ = @import("theme.zig");
    _ = @import("system_api.zig");
    _ = @import("codesign.zig");
    _ = @import("wix_vendor.zig");
    _ = @import("msix.zig");
    _ = @import("pack_formats.zig"); // v0.2.4：其单测此前从未被编译执行（断言与实现脱节）
    _ = @import("ws.zig");
    _ = @import("store.zig");
    _ = @import("fs_api.zig");
    _ = @import("services.zig");
    _ = @import("sql.zig");
    _ = @import("npm_pack.zig");
    _ = @import("mcp.zig");
    _ = @import("net.zig");
    _ = @import("log.zig");
    _ = @import("ipc.zig");
    _ = @import("bindings.zig");
    _ = @import("bundler.zig");
    _ = @import("updater.zig");
    // 测试补齐（v0.3.18 审计）：以下三模块此前只有 `pub const` 惰性声明，测试从未进入编译图
    // （41 个用例长期未执行，其中 patch/png 已随 Zig 0.17 失效而无法编译）。
    _ = @import("patch.zig");
    _ = @import("png.zig");
    _ = @import("ico.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("platform/windows/backend.zig");
        _ = @import("platform/windows/sqlite.zig");
        _ = @import("platform/windows/headless.zig");
        _ = @import("platform/windows/menu.zig");
        _ = @import("platform/windows/hotkey.zig");
        _ = @import("platform/windows/dialog.zig");
        _ = @import("platform/windows/taskbar.zig");
        _ = @import("platform/windows/sysinfo.zig");
        _ = @import("platform/windows/system_integration.zig");
        _ = @import("platform/windows/custom_scheme.zig");
        _ = @import("platform/windows/dpapi.zig");
        _ = @import("platform/windows/dcomp.zig"); // v0.3.19：vtable 槽位回归（v0.3.18 根因）
        // 测试补齐（v0.3.18 审计）：此前未纳入测试图的平台模块
        _ = @import("platform/windows/app_data.zig");
        _ = @import("platform/windows/deep_link.zig");
        _ = @import("platform/windows/dialog_ext.zig");
        _ = @import("platform/windows/icon.zig");
        _ = @import("platform/windows/menu_runtime.zig");
        _ = @import("platform/windows/range.zig");
        _ = @import("platform/windows/single_instance.zig");
        _ = @import("platform/windows/tray.zig");
        _ = @import("platform/windows/winhttp.zig");
    }
}
