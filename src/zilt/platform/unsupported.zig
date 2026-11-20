//! 未支持平台的后端（占位）：给出明确编译错误，而不是晦涩的缺符号信息。
const Config = @import("../config.zig").Config;

pub const platform_name = "unsupported";

pub fn run(comptime config: Config) !void {
    _ = config;
    @compileError(
        \\Zilt: 当前平台尚无后端。
        \\  已支持：Windows（v0.1.x）；Linux 在 v0.2 落地；macOS 计划 v0.3+。
    );
}
