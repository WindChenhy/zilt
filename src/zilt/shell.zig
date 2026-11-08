//! Shell 集成（v0.1.14）的平台无关部分：目标类型与命令行构造。
//! Windows 调用见 `platform/windows/shell.zig`（ShellExecuteW / explorer.exe）。
const std = @import("std");

/// ShellExecute 的动词（Windows）；其他平台后端可映射到 xdg-open/open。
pub const Verb = enum { open, @"runas", @"print", edit };

pub const Target = union(enum) {
    /// 用默认浏览器/处理程序打开 URL
    url: []const u8,
    /// 用默认程序打开文件
    path: []const u8,
    /// 在资源管理器中定位并选中文件
    reveal: []const u8,
};

/// explorer.exe 的参数需要 `/select,"<path>"`：路径含空格/逗号时必须加引号，
/// 否则 explorer 会把路径拆成多个参数（Windows 已知行为）。
pub fn needsQuotes(path: []const u8) bool {
    if (path.len == 0) return true;
    for (path) |c| {
        if (c == ' ' or c == '\t' or c == ',') return true;
    }
    return false;
}

pub fn explorerSelectArgs(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "/select,\"{s}\"", .{path});
}

/// "C:\Program Files\App\app.exe" --flag
/// 含空格的 exe 路径必须整体加引号；无空格时保持原样（与注册表 Run 值的惯例一致）。
pub fn runCommand(alloc: std.mem.Allocator, exe_path: []const u8, args: ?[]const u8) ![]u8 {
    const quoted = needsQuotes(exe_path);
    if (args) |a| {
        return if (quoted)
            std.fmt.allocPrint(alloc, "\"{s}\" {s}", .{ exe_path, a })
        else
            std.fmt.allocPrint(alloc, "{s} {s}", .{ exe_path, a });
    }
    return if (quoted)
        std.fmt.allocPrint(alloc, "\"{s}\"", .{exe_path})
    else
        alloc.dupe(u8, exe_path);
}

const testing = std.testing;

test "quote decision" {
    try testing.expect(needsQuotes("C:\\Program Files\\App\\a.exe"));
    try testing.expect(needsQuotes("C:\\a b\\x.exe"));
    try testing.expect(needsQuotes(""));
    try testing.expect(needsQuotes("C:\\a,b\\x.exe"));
    try testing.expect(!needsQuotes("C:\\App\\a.exe"));
}

test "explorer select args always quote" {
    const args = try explorerSelectArgs(testing.allocator, "C:\\Users\\me\\a b.txt");
    defer testing.allocator.free(args);
    try testing.expectEqualStrings("/select,\"C:\\Users\\me\\a b.txt\"", args);
}

test "run command quoting" {
    const with_space = try runCommand(testing.allocator, "C:\\Program Files\\Zilt\\zilt-app.exe", "--autostart");
    defer testing.allocator.free(with_space);
    try testing.expectEqualStrings("\"C:\\Program Files\\Zilt\\zilt-app.exe\" --autostart", with_space);

    const plain = try runCommand(testing.allocator, "C:\\Zilt\\zilt-app.exe", null);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("C:\\Zilt\\zilt-app.exe", plain);

    const plain_args = try runCommand(testing.allocator, "C:\\Zilt\\zilt-app.exe", "--hidden");
    defer testing.allocator.free(plain_args);
    try testing.expectEqualStrings("C:\\Zilt\\zilt-app.exe --hidden", plain_args);
}
