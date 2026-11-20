//! 工具层单测聚合（zig build test 一并运行）。
//!
//! v0.2.8：`init.zig` 已移植 std.Io（跨平台）→ 测试两平台同跑；
//! `win_env` / `win_res` 仍为 Windows 专用（Win32 API），仅 Windows 编译。

const builtin = @import("builtin");

test {
    _ = @import("frontend_codegen.zig");
    _ = @import("capability_codegen.zig");
    _ = @import("gen_capabilities.zig");
    _ = @import("init.zig");
    // 测试补齐（v0.3.18 审计）：driver.zig 跨平台化（v0.2.9）后其单测未进入任何测试根
    _ = @import("driver.zig");

    if (builtin.os.tag == .windows) {
        _ = @import("win_env.zig");
        _ = @import("win_res.zig");
    }
}
