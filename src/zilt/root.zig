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
    _ = @import("ipc.zig");
    _ = @import("bindings.zig");
    _ = @import("bundler.zig");
    _ = @import("updater.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("platform/windows/backend.zig");
        _ = @import("platform/windows/menu.zig");
        _ = @import("platform/windows/hotkey.zig");
        _ = @import("platform/windows/dialog.zig");
    }
}
