//! Zilt Phase 2 示例应用：配置驱动的窗口 + IPC + comptime 绑定 + dev 模式。

const std = @import("std");
const zilt = @import("zilt");
const app = @import("app_config");

pub fn main() !void {
    try zilt.run(.{
        .commands = app.commands,
        .events = app.events,
        .assets = &app.assets,
        .title = "Zilt — v0.1.5 示例",
        .width = 960,
        .height = 700,
        .url = "https://zilt.app/index.html",
        // 系统能力（Windows）
        .tray = .{ .tooltip = "Zilt — 点击显示/隐藏窗口" },
        .close_to_tray = true,
        .single_instance = true,
        .menu = &.{
            .{ .label = "文件", .items = &.{
                .{ .label = "打开文件...", .id = "open" },
                .{ .label = "-" },
                .{ .label = "退出", .id = "exit" },
            } },
            .{ .label = "帮助", .items = &.{
                .{ .label = "关于 Zilt", .id = "about" },
            } },
        },
        .hotkeys = &.{
            .{ .id = "quick-note", .ctrl = true, .alt = true, .key = "N" },
            .{ .id = "reload-page", .ctrl = true, .alt = true, .key = "R" },
            .{ .id = "help", .key = "F7" },
        },
        // 自动更新器（E2E 用 ZILT_UPDATE_URL / ZILT_UPDATE_PK 环境变量覆盖）
        .update = .{
            .manifest_url = "https://updates.invalid/manifest.json",
            .public_key_hex = "0000000000000000000000000000000000000000000000000000000000000000",
            .current_version = "0.1.1",
        },
    });
}
