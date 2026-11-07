//! 工具层单测聚合（zig build test 一并运行）。

test {
    _ = @import("frontend_codegen.zig");
    _ = @import("init.zig");
    _ = @import("gen_capabilities.zig");
}
