//! 全局快捷键：VK 码映射 / 修饰符 / id 表（comptime）+ 注册辅助。
//! WM_HOTKEY 的 wparam = 配置顺序（从 1 起），反查同一 comptime 表。

const std = @import("std");
const win32 = @import("win32.zig");
const Config = @import("../../config.zig").Config;

/// "A".."Z" / "0".."9" / "F1".."F12" → VK 码。
pub fn vkFromString(s: []const u8) ?u8 {
    if (s.len == 1) {
        const c = std.ascii.toUpper(s[0]);
        if ((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) return c;
        return null;
    }
    if (s.len >= 2 and (s[0] == 'F' or s[0] == 'f')) {
        const n = std.fmt.parseInt(u8, s[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return 0x70 + n - 1; // VK_F1=0x70
    }
    return null;
}

/// 修饰符 → MOD_* 位标志。
pub fn modFlags(hk: Config.Hotkey) win32.UINT {
    var f: win32.UINT = 0;
    if (hk.ctrl) f |= win32.MOD_CONTROL;
    if (hk.alt) f |= win32.MOD_ALT;
    if (hk.shift) f |= win32.MOD_SHIFT;
    if (hk.win) f |= win32.MOD_WIN;
    return f;
}

/// comptime 收集快捷键 id（顺序 = 注册顺序 = WM_HOTKEY wparam）。
pub fn collectIds(comptime hotkeys: []const Config.Hotkey) []const []const u8 {
    comptime {
        var ids: [hotkeys.len][]const u8 = undefined;
        for (hotkeys, 0..) |hk, i| ids[i] = hk.id;
        const frozen = ids;
        return &frozen;
    }
}

/// wparam 反查 id。
pub fn idFromIndex(comptime hotkeys: []const Config.Hotkey, idx: u32) ?[]const u8 {
    const table = comptime collectIds(hotkeys);
    inline for (table, 0..) |id, i| {
        if (i + 1 == idx) return id;
    }
    return null;
}

/// 编译期 VK 解析（非法 key 直接编译失败）。
pub fn vkComptime(comptime s: []const u8) u8 {
    if (comptime vkFromString(s)) |vk| return vk;
    @compileError("Zilt: 无效快捷键 key '" ++ s ++ "'（支持 A-Z/0-9/F1-F12）");
}

/// 编译期校验并注册全部快捷键（返回失败项名，全部成功返回 null）。
pub fn registerAll(hwnd: win32.HWND, comptime hotkeys: []const Config.Hotkey) ?[]const u8 {
    inline for (hotkeys, 0..) |hk, i| {
        const vk = comptime vkComptime(hk.key);
        if (win32.RegisterHotKey(hwnd, @intCast(i + 1), modFlags(hk), vk) == 0) {
            return hk.id;
        }
    }
    return null;
}

pub fn unregisterAll(hwnd: win32.HWND, comptime hotkeys: []const Config.Hotkey) void {
    inline for (hotkeys, 0..) |_, i| {
        _ = win32.UnregisterHotKey(hwnd, @intCast(i + 1));
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "vkFromString: 字母/数字/F 键/非法" {
    try testing.expectEqual(@as(?u8, 0x53), vkFromString("s")); // 小写归一
    try testing.expectEqual(@as(?u8, 0x5A), vkFromString("Z"));
    try testing.expectEqual(@as(?u8, 0x31), vkFromString("1"));
    try testing.expectEqual(@as(?u8, 0x70), vkFromString("F1"));
    try testing.expectEqual(@as(?u8, 0x7B), vkFromString("F12"));
    try testing.expectEqual(@as(?u8, null), vkFromString("F13"));
    try testing.expectEqual(@as(?u8, null), vkFromString("Space"));
    try testing.expectEqual(@as(?u8, null), vkFromString(""));
}

test "modFlags: 位组合" {
    try testing.expectEqual(@as(win32.UINT, win32.MOD_CONTROL | win32.MOD_ALT), modFlags(.{ .id = "x", .key = "N", .ctrl = true, .alt = true }));
    try testing.expectEqual(@as(win32.UINT, win32.MOD_WIN | win32.MOD_SHIFT), modFlags(.{ .id = "x", .key = "N", .win = true, .shift = true }));
    try testing.expectEqual(@as(win32.UINT, 0), modFlags(.{ .id = "x", .key = "N" }));
}

const TestHotkeys = [_]Config.Hotkey{
    .{ .id = "quick-note", .ctrl = true, .alt = true, .key = "N" },
    .{ .id = "refresh", .ctrl = true, .alt = true, .key = "R" },
    .{ .id = "help", .key = "F1" },
};

test "collectIds/idFromIndex: 顺序映射" {
    const ids = comptime collectIds(&TestHotkeys);
    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expectEqualStrings("quick-note", idFromIndex(&TestHotkeys, 1).?);
    try testing.expectEqualStrings("help", idFromIndex(&TestHotkeys, 3).?);
    try testing.expect(idFromIndex(&TestHotkeys, 4) == null);
}
