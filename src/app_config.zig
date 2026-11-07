//! 示例应用配置（命令 + 事件 + 内嵌资产）。主程序与 gen 工具共用。

const zilt = @import("zilt");

pub const commands = @import("commands.zig");
pub const events = @import("events.zig");

const index_html = @embedFile("frontend/index.html");
const app_js = @embedFile("frontend/app.js");
const styles_css = @embedFile("frontend/styles.css");

pub const assets = [_]zilt.Asset{
    .{ .path = "/", .content = index_html },
    .{ .path = "/index.html", .content = index_html },
    .{ .path = "/app.js", .content = app_js },
    .{ .path = "/styles.css", .content = styles_css },
};
