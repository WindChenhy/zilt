//! 工具层单测聚合（zig build test 一并运行）。
//!
//! v0.2.0：按目标平台裁剪——`win_env` / `win_res` / `init`（脚手架目前仍走 Win32
//! 文件 API）只在 Windows 上编译；跨平台部分（资产 codegen / capability DSL）两平台都跑。
//! 待 `init.zig` 移植到 std.Io 后，Linux 分支同步放开。

const builtin = @import("builtin");

test {
    _ = @import("frontend_codegen.zig");
    _ = @import("capability_codegen.zig");
    _ = @import("gen_capabilities.zig");

    if (builtin.os.tag == .windows) {
        _ = @import("init.zig");
        _ = @import("win_env.zig");
        _ = @import("win_res.zig");
    }
}
