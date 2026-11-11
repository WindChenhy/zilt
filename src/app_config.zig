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
        // v0.1.21：资源 scope（fs/http/shell）。声明后进入强制模式；
        // 应用私有目录（appData/appConfig/appCache）始终可用。
        .scopes = &.{
            "fs:appData/**",
            "fs:appCache/**",
            "fs:appConfig/**",
            "http:http://127.0.0.1:*",
            "http:ws://127.0.0.1:*",
            "http:wss://127.0.0.1:*",
            "shell:cmd",
        },
    }},
    // v0.1.21：冻结 window.zilt + 内建原型（防原型链篡改）
    .freeze_prototype = true,
    .deny_commands = &.{"blockedDemo"}, // 冒烟用：未授权命令须返回 PermissionDenied
    .navigation_origins = &.{"https://zilt.app"},
    .external_links = .system_browser,
};
