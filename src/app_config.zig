//! 示例应用配置（命令 + 事件 + 内嵌资产）。主程序与 gen 工具共用。
//! 资产表由 build.zig 资产 codegen 从 frontend dist 自动生成（zilt_assets 模块）。

const zilt = @import("zilt");

pub const commands = @import("commands.zig");
pub const events = @import("events.zig");

pub const assets = @import("zilt_assets").assets;

/// v0.1.8/v0.1.11：CSP/导航白名单/capability ACL。构建时生成
/// frontend/bindings/capabilities.json，运行时按同一份声明强制。
pub const security: zilt.security.Options = .{
    .capabilities = &.{.{
        .name = "demo-local",
        .windows = &.{"*"},
        .commands = &.{"*"},
        .events = &.{"*"},
        .receive_events = &.{"*"},
    }},
    .deny_commands = &.{"blockedDemo"}, // 冒烟用：未授权命令须返回 PermissionDenied
    .navigation_origins = &.{"https://zilt.app"},
    .external_links = .system_browser,
};
