//! 平台后端选择（v0.2.0）。
//!
//! 唯一入口：`root.run` 委托到这里，按目标 OS 选择 `platform/<os>/backend.zig`。
//! 新增平台只需：
//!   1. 实现 `platform/<os>/backend.zig`（`pub const platform_name` + `pub fn run(comptime Config) !void`）
//!   2. 在本文件的 switch 里加一行
//!   3. 在 `interface.zig` 的 `linux_target_capabilities` 一类清单里维护能力矩阵
//!
//! 契约由 `interface.assertBackend` 在编译期强制（缺失 decl / 签名不符直接编译失败）。
const builtin = @import("builtin");

const Config = @import("../config.zig").Config;
const interface = @import("interface.zig");

pub const Backend = switch (builtin.os.tag) {
    .windows => @import("windows/backend.zig"),
    .linux => @import("linux/backend.zig"),
    else => @import("unsupported.zig"),
};

/// 当前目标平台的后端名（诊断/日志；不触发后端实例化）。
pub const name = Backend.platform_name;

pub fn run(comptime config: Config) !void {
    assertBackend(Backend);
    return Backend.run(config);
}

const assertBackend = interface.assertBackend;

test "v0.2.0: 当前平台后端满足契约" {
    assertBackend(Backend);
    try @import("std").testing.expect(name.len > 0);
}

