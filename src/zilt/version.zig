//! 框架版本号的**唯一来源**（v0.6.0b：build graph options）。
//!
//! 由 build.zig 的 flavor 解析结果注入（base = `src/project.zig` 的 version，
//! 可被 `zilt.<flavor>.json` / `-Dconfig` 覆盖）。全部消费点从 `zilt.version` 派生：
//!   - `src/project.zig` 是构建期 base（打包/PE 资源也用解析后的同一个值）
//!   - 运行时 `window.zilt.version`（ipc.zig 拼接）
//!   - MCP `serverInfo.version`
//!   - `zilt --version` 默认值
const opts = @import("app_meta_opts");

pub const version = opts.version;

test "version 是 semver 形态（允许 -prerelease / +build）" {
    const vm = @import("flavor_merge.zig");
    try @import("std").testing.expect(vm.validateSemver(version));
}
