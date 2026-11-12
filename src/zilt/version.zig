//! 框架版本号的**唯一来源**。
//!
//! 之前 5 处各写一遍（project.zig / ipc.zig 运行时 / mcp.zig / cli.zig / main.zig 标题），
//! 升版本时容易漏改一处。现在全部从这里派生：
//!   - `src/project.zig` 直接 re-export（build.zig / 打包 / 签名都用它）
//!   - 运行时 `window.zilt.version`（ipc.zig 拼接）
//!   - MCP `serverInfo.version`
//!   - `zilt --version` 默认值
pub const version = "0.1.23";

test "version 是 semver 形态（x.y.z）" {
    const std = @import("std");
    var it = std.mem.splitScalar(u8, version, '.');
    var parts: usize = 0;
    while (it.next()) |p| {
        try std.testing.expect(p.len > 0);
        _ = try std.fmt.parseInt(u32, p, 10);
        parts += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), parts);
}
