//! 示例应用配置（命令 + 事件 + 内嵌资产）。主程序与 gen 工具共用。
//! 资产表由 build.zig 资产 codegen 从 frontend dist 自动生成（zilt_assets 模块）。

const zilt = @import("zilt");

pub const commands = @import("commands.zig");
pub const events = @import("events.zig");

pub const assets = @import("zilt_assets").assets;
