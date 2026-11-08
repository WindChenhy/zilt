//! 开机自启（v0.1.14）的平台无关部分。
//!
//! Windows 实现写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`（per-user，
//! 无需管理员；卸载/关闭时删除同名值）。Linux/macOS 后端可映射到 autostart .desktop
//! 与 LaunchAgents。
const std = @import("std");

pub const registry_path = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";

pub const State = struct {
    enabled: bool = false,
    /// 已注册的命令行（enabled = false 时为 null）
    command: ?[]const u8 = null,
};

/// 值名：用 app_id（`app.zilt`）保证多应用互不覆盖。
pub fn valueName(app_id: []const u8) []const u8 {
    return app_id;
}

/// 判断注册表里的命令是否指向当前 exe（忽略引号与参数差异）。
/// Windows 的 Run 值可能由旧版本写入（无引号 / 带参数），因此按“包含 exe 路径”比较。
pub fn matchesExe(registered: []const u8, exe_path: []const u8) bool {
    if (exe_path.len == 0) return false;
    if (std.mem.indexOf(u8, registered, exe_path) != null) return true;
    // 注册表可能存了 8.3 短路径或大小写差异：退化为文件名比较
    const reg_name = baseName(registered);
    const exe_name = baseName(exe_path);
    return std.ascii.eqlIgnoreCase(reg_name, exe_name);
}

fn baseName(cmd: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] == '\\' or cmd[i] == '/') {
            start = i + 1;
        } else if (cmd[i] == '"') {
            // 跳过引号：`"C:\a\b.exe" --x`
            start = if (start == 0 and i == 0) 1 else start;
        } else if (cmd[i] == ' ' and start < i) {
            return cmd[start..i];
        }
    }
    return cmd[start..];
}

const testing = std.testing;

test "matches exe with quotes and arguments" {
    try testing.expect(matchesExe("\"C:\\App\\zilt-app.exe\" --autostart", "C:\\App\\zilt-app.exe"));
    try testing.expect(matchesExe("C:\\App\\zilt-app.exe", "C:\\App\\zilt-app.exe"));
    try testing.expect(matchesExe("C:\\App\\ZILT-APP.EXE", "C:\\Other\\zilt-app.exe"));
    try testing.expect(!matchesExe("C:\\App\\other.exe", "C:\\App\\zilt-app.exe"));
    try testing.expect(!matchesExe("", "C:\\App\\zilt-app.exe"));
}

test "value name follows app id" {
    try testing.expectEqualStrings("app.zilt", valueName("app.zilt"));
}
