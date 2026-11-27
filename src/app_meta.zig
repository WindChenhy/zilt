//! 打包器元数据（从 project.zig 派生——单一配置源）。
//! v0.6.0a：身份字段由 build graph 的 flavor 解析结果经 options 注入
//! （app_name / app_id / publisher / channel）；version 暂与运行时
//! `src/zilt/version.zig` 单源（flavor 覆盖排 0.6.0b）。
const opts = @import("app_meta_opts");

pub const app_name = opts.app_name;
pub const app_id = opts.app_id;
pub const publisher = opts.publisher;
pub const channel = opts.channel;
pub const version = @import("project.zig").version;
pub const exe_name = @import("project.zig").exe_name;
pub const external_bin = @import("project.zig").external_bin;
pub const resources = @import("project.zig").resources;

pub const icon = @import("project.zig").icon;
pub const frontend = @import("project.zig").frontend;
