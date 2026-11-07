//! Zilt Phase 2 示例应用：配置驱动的窗口 + IPC + comptime 绑定 + dev 模式。

const std = @import("std");
const zilt = @import("zilt");
const app = @import("app_config");

pub fn main() !void {
    try zilt.run(.{
        .commands = app.commands,
        .events = app.events,
        .assets = &app.assets,
        .title = "Zilt — Phase 2 示例",
        .width = 900,
        .height = 680,
        .url = "https://zilt.app/index.html",
    });
}
