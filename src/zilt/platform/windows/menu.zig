//! 原生菜单栏：comptime id 表 + Win32 菜单构建。
//!
//! 配置（Config.menu）里的叶子项按深度优先顺序获得 win32 菜单 id（从 1 起）；
//! WM_COMMAND 到达时用同一 comptime 表把数字 id 反查为字符串 id（emit "menu" 事件）。

const std = @import("std");
const win32 = @import("win32.zig");
const Config = @import("../../config.zig").Config;

/// 深度优先收集全部叶子项的字符串 id（comptime）。
pub fn collectIds(comptime items: []const Config.MenuItem) []const []const u8 {
    comptime {
        var count: usize = 0;
        for (items) |it| {
            if (it.items) |children| {
                count += collectIds(children).len;
            } else if (it.id != null) {
                count += 1;
            }
        }
        var ids: [count][]const u8 = undefined;
        var i: usize = 0;
        for (items) |it| {
            if (it.items) |children| {
                for (collectIds(children)) |cid| {
                    ids[i] = cid;
                    i += 1;
                }
            } else if (it.id) |id| {
                ids[i] = id;
                i += 1;
            }
        }
        const frozen = ids;
        return &frozen;
    }
}

/// 运行时反查：win32 菜单 id → 字符串 id。
pub fn idFromIndex(comptime items: []const Config.MenuItem, idx: u16) ?[]const u8 {
    const table = comptime collectIds(items);
    inline for (table, 0..) |id, i| {
        if (i + 1 == idx) return id;
    }
    return null;
}

/// 构建 Win32 菜单栏（运行时）。叶子项 win id 与 collectIds 顺序一致。
pub fn buildWin32(allocator: std.mem.Allocator, items: []const Config.MenuItem) !win32.HMENU {
    var counter: u16 = 0;
    return buildSub(allocator, items, &counter);
}

fn buildSub(allocator: std.mem.Allocator, items: []const Config.MenuItem, counter: *u16) !win32.HMENU {
    const hmenu = win32.CreateMenu() orelse return error.CreateMenuFailed;
    errdefer _ = win32.DestroyMenu(hmenu);

    for (items) |it| {
        if (std.mem.eql(u8, it.label, "-")) {
            if (win32.AppendMenuW(hmenu, win32.MF_SEPARATOR, 0, null) == 0) return error.AppendMenuFailed;
            continue;
        }
        const label_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, it.label);
        defer allocator.free(label_w);

        if (it.items) |children| {
            const sub = try buildSub(allocator, children, counter);
            if (win32.AppendMenuW(hmenu, win32.MF_POPUP, @intFromPtr(sub), label_w.ptr) == 0) return error.AppendMenuFailed;
        } else {
            if (it.id == null) continue; // 无 id 的叶子不响应
            counter.* += 1;
            if (win32.AppendMenuW(hmenu, win32.MF_STRING, counter.*, label_w.ptr) == 0) return error.AppendMenuFailed;
        }
    }
    return hmenu;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestMenu = [_]Config.MenuItem{
    .{ .label = "文件", .items = &.{
        .{ .label = "打开", .id = "open" },
        .{ .label = "-" },
        .{ .label = "退出", .id = "exit" },
    } },
    .{ .label = "帮助", .items = &.{
        .{ .label = "关于", .id = "about" },
    } },
};

const cfg = @import("../../config.zig");

test "collectIds: 深度优先叶子 id" {
    const ids = comptime collectIds(&TestMenu);
    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expectEqualStrings("open", ids[0]);
    try testing.expectEqualStrings("exit", ids[1]);
    try testing.expectEqualStrings("about", ids[2]);
}

test "idFromIndex: 双向映射" {
    try testing.expectEqualStrings("open", idFromIndex(&TestMenu, 1).?);
    try testing.expectEqualStrings("exit", idFromIndex(&TestMenu, 2).?);
    try testing.expectEqualStrings("about", idFromIndex(&TestMenu, 3).?);
    try testing.expect(idFromIndex(&TestMenu, 4) == null);
    try testing.expect(idFromIndex(&TestMenu, 0) == null);
}

test "collectIds: 空菜单与无 id 叶子" {
    const empty = comptime collectIds(&[_]Config.MenuItem{});
    try testing.expectEqual(@as(usize, 0), empty.len);

    const no_id = comptime collectIds(&[_]Config.MenuItem{.{ .label = "仅展示", .items = &.{
        .{ .label = "灰的" },
    } }});
    try testing.expectEqual(@as(usize, 0), no_id.len);
}
