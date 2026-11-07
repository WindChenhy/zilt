//! 绑定生成工具：`zig build gen` → 写出 src/frontend/zilt-bindings.ts。
//! 从 app_config（命令 + 事件命名空间）经 comptime 反射生成强类型 TS 绑定。

const std = @import("std");
const zilt = @import("zilt");
const app = @import("app_config");

const OUTPUT_PATH = "src/frontend/zilt-bindings.ts";

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const ts = comptime zilt.bindings.generateTs(app.commands, app.events);

    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, OUTPUT_PATH);
    defer alloc.free(path_w);

    const win32 = zilt.platform_windows.win32;
    const f = win32.CreateFileW(path_w.ptr, win32.GENERIC_WRITE, 0, null, win32.CREATE_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (f == win32.INVALID_HANDLE_VALUE) {
        std.debug.print("error: cannot open {s}\n", .{OUTPUT_PATH});
        return error.WriteFailed;
    }
    defer _ = win32.CloseHandle(f);

    var written: win32.DWORD = 0;
    if (win32.WriteFile(f, ts.ptr, @intCast(ts.len), &written, null) == 0) {
        std.debug.print("error: write failed\n", .{});
        return error.WriteFailed;
    }
    std.debug.print("generated {s} ({d} bytes)\n", .{ OUTPUT_PATH, ts.len });
}
