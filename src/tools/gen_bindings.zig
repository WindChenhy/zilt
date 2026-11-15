//! 绑定生成工具：`zig build gen` → 写出 src/frontend/zilt-bindings.ts。
//! 从 app_config（命令 + 事件命名空间）经 comptime 反射生成强类型 TS 绑定。
//!
//! v0.2.8：文件 IO 从 Win32 换成 std.Io（跨平台；Linux 的 `zig build dev`/`gen`
//! 依赖本工具）。

const std = @import("std");
const Io = std.Io;
const zilt = @import("zilt");
const app = @import("app_config");

const OUTPUT_PATH = "frontend/bindings/zilt.ts";

var g_threaded: Io.Threaded = undefined;
var g_threaded_ready = false;
fn toolIo() Io {
    if (!g_threaded_ready) {
        g_threaded = .init(std.heap.page_allocator, .{});
        g_threaded_ready = true;
    }
    return g_threaded.io();
}

pub fn main() !void {
    const ts = comptime zilt.bindings.generateTs(app.commands, app.events);

    // 确保输出目录存在（frontend/bindings），再写文件
    if (std.mem.lastIndexOfScalar(u8, OUTPUT_PATH, '/')) |slash| {
        _ = try Io.Dir.cwd().createDirPathStatus(toolIo(), OUTPUT_PATH[0..slash], .default_dir);
    }
    try Io.Dir.cwd().writeFile(toolIo(), .{ .sub_path = OUTPUT_PATH, .data = ts });
    std.debug.print("generated {s} ({d} bytes)\n", .{ OUTPUT_PATH, ts.len });
}
