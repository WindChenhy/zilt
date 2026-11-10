//! 原生菜单栏：comptime id 表 + Win32 菜单构建。
//!
//! 配置（Config.menu）里的叶子项按深度优先顺序获得 win32 菜单 id（从 1 起）；
//! WM_COMMAND 到达时用同一 comptime 表把数字 id 反查为字符串 id（emit "menu" 事件）。

const std = @import("std");
const win32 = @import("win32.zig");
const Config = @import("../../config.zig").Config;
const accel_mod = @import("../../accel.zig");

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
    return buildWin32WithIcons(allocator, items, null);
}

/// v0.1.18：带图标的菜单栏构建（bitmaps 收集 HBITMAP，由调用方在窗口销毁时释放）。
pub fn buildWin32WithIcons(allocator: std.mem.Allocator, items: []const Config.MenuItem, bitmaps: ?*std.ArrayListUnmanaged(win32.HBITMAP)) !win32.HMENU {
    var counter: u16 = 0;
    const hmenu = win32.CreateMenu() orelse return error.CreateMenuFailed;
    errdefer _ = win32.DestroyMenu(hmenu);
    try fill(allocator, hmenu, items, &counter, bitmaps);
    return hmenu;
}

/// 构建弹出菜单（托盘右键）。菜单 id 从 base 起（避免与菜单栏 id 空间冲突）。
pub fn buildPopup(allocator: std.mem.Allocator, items: []const Config.MenuItem, base: u16) !win32.HMENU {
    var counter: u16 = base;
    const hmenu = win32.CreatePopupMenu() orelse return error.CreateMenuFailed;
    errdefer _ = win32.DestroyMenu(hmenu);
    try fill(allocator, hmenu, items, &counter, null);
    return hmenu;
}

/// 弹出菜单 id → 字符串 id（base 为 buildPopup 起始值；运行时查找，
/// 兼容 config 中托盘菜单为 null 的编译期场景）。
pub fn idFromPopup(items: []const Config.MenuItem, base: u16, menu_id: u16) ?[]const u8 {
    if (menu_id <= base) return null;
    var counter: u16 = 0;
    return findNth(items, menu_id - base, &counter);
}

fn findNth(items: []const Config.MenuItem, target: u16, counter: *u16) ?[]const u8 {
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "-")) continue;
        if (it.items) |children| {
            if (findNth(children, target, counter)) |id| return id;
        } else if (it.id) |id| {
            counter.* += 1;
            if (counter.* == target) return id;
        }
    }
    return null;
}

fn fill(allocator: std.mem.Allocator, hmenu: win32.HMENU, items: []const Config.MenuItem, counter: *u16, bitmaps: ?*std.ArrayListUnmanaged(win32.HBITMAP)) !void {
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "-")) {
            if (win32.AppendMenuW(hmenu, win32.MF_SEPARATOR, 0, null) == 0) return error.AppendMenuFailed;
            continue;
        }
        // v0.1.13：加速键用制表符右对齐显示（Windows 菜单惯例）
        const label_text = if (it.accel) |a|
            try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ it.label, a })
        else
            try allocator.dupe(u8, it.label);
        defer allocator.free(label_text);
        const label_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, label_text);
        defer allocator.free(label_w);

        if (it.items) |children| {
            const sub = win32.CreatePopupMenu() orelse return error.CreateMenuFailed;
            errdefer _ = win32.DestroyMenu(sub);
            try fill(allocator, sub, children, counter, bitmaps);
            if (win32.AppendMenuW(hmenu, win32.MF_POPUP, @intFromPtr(sub), label_w.ptr) == 0) return error.AppendMenuFailed;
        } else {
            if (it.id == null) continue; // 无 id 的叶子不响应
            counter.* += 1;
            if (win32.AppendMenuW(hmenu, win32.MF_STRING, counter.*, label_w.ptr) == 0) return error.AppendMenuFailed;
            if (it.icon) |icon_path| {
                if (bitmaps) |list| {
                    if (loadMenuBitmap(allocator, icon_path)) |bmp| {
                        _ = win32.SetMenuItemBitmaps(hmenu, counter.*, win32.MF_BYCOMMAND, bmp, bmp);
                        list.append(allocator, bmp) catch {
                            _ = win32.DeleteObject(@ptrCast(bmp));
                        };
                    }
                }
            }
        }
    }
}

/// v0.1.18：`.ico`/`.bmp` → HBITMAP（16×16）。GetIconInfo 生成的位图归菜单持有，
/// 调用方在菜单销毁时 DeleteObject；HICON 本身立即销毁（位图是副本）。
pub fn loadMenuBitmap(allocator: std.mem.Allocator, path: []const u8) ?win32.HBITMAP {
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return null;
    defer allocator.free(path_w);
    const is_bmp = std.mem.endsWith(u8, path, ".bmp") or std.mem.endsWith(u8, path, ".BMP");
    if (is_bmp) {
        const hb = win32.LoadImageW(null, path_w.ptr, win32.IMAGE_BITMAP, 16, 16, win32.LR_LOADFROMFILE);
        return hb;
    }
    const hicon = win32.LoadImageW(null, path_w.ptr, win32.IMAGE_ICON, 16, 16, win32.LR_LOADFROMFILE) orelse return null;
    defer _ = win32.DestroyIcon(hicon);
    var info: win32.ICONINFO = undefined;
    if (win32.GetIconInfo(hicon, &info) == 0) return null;
    if (info.hbmMask) |m| _ = win32.DeleteObject(@ptrCast(m));
    return info.hbmColor;
}

/// v0.1.18：菜单项角色反查（按 id 命中叶子项）。
pub fn roleForId(items: []const Config.MenuItem, id: []const u8) ?[]const u8 {
    for (items) |it| {
        if (it.items) |children| {
            if (roleForId(children, id)) |r| return r;
        } else if (it.id) |x| {
            if (std.mem.eql(u8, x, id)) return it.role;
        }
    }
    return null;
}

/// v0.1.18：由菜单加速键构建 ACCEL 表（叶子 id 与 collectIds 顺序一致）。
/// 解析失败的加速键静默跳过；无任何加速键时返回 null。
pub fn buildAccel(allocator: std.mem.Allocator, items: []const Config.MenuItem) win32.HACCEL {
    var accels: std.ArrayListUnmanaged(win32.ACCEL) = .empty;
    defer accels.deinit(allocator);
    var counter: u16 = 0;
    collectAccels(allocator, items, &counter, &accels);
    if (accels.items.len == 0) return null;
    return win32.CreateAcceleratorTableW(accels.items.ptr, @intCast(accels.items.len));
}

fn collectAccels(allocator: std.mem.Allocator, items: []const Config.MenuItem, counter: *u16, out: *std.ArrayListUnmanaged(win32.ACCEL)) void {
    for (items) |it| {
        if (it.items) |children| {
            collectAccels(allocator, children, counter, out);
            continue;
        }
        if (it.id == null) continue;
        counter.* += 1;
        const text = it.accel orelse continue;
        const parsed = accel_mod.parse(text) catch continue;
        var f: u8 = win32.FVIRTKEY | win32.FNOINVERT;
        if (parsed.mods.ctrl) f |= win32.FCONTROL;
        if (parsed.mods.alt) f |= win32.FALT;
        if (parsed.mods.shift) f |= win32.FSHIFT;
        if (parsed.mods.win) continue; // Win 键不能进菜单 ACCEL 表（系统保留）
        out.append(allocator, .{ .fVirt = f, .key = parsed.vk, .cmd = counter.* }) catch return;
    }
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

test "idFromPopup: base 偏移映射" {
    // 托盘菜单 id 从 100 起：101 → open，102 → exit，103 → about
    try testing.expectEqualStrings("open", idFromPopup(&TestMenu, 100, 101).?);
    try testing.expectEqualStrings("about", idFromPopup(&TestMenu, 100, 103).?);
    try testing.expect(idFromPopup(&TestMenu, 100, 100) == null);
    try testing.expect(idFromPopup(&TestMenu, 100, 104) == null);
}

test "collectIds: 空菜单与无 id 叶子" {
    const empty = comptime collectIds(&[_]Config.MenuItem{});
    try testing.expectEqual(@as(usize, 0), empty.len);

    const no_id = comptime collectIds(&[_]Config.MenuItem{.{ .label = "仅展示", .items = &.{
        .{ .label = "灰的" },
    } }});
    try testing.expectEqual(@as(usize, 0), no_id.len);
}

test "v0.1.18: role lookup by id" {
    const items = [_]Config.MenuItem{
        .{ .label = "编辑", .items = &.{
            .{ .label = "复制", .id = "edit.copy", .role = "copy", .accel = "Ctrl+C" },
            .{ .label = "粘贴", .id = "edit.paste", .role = "paste", .accel = "Ctrl+V" },
            .{ .label = "全选", .id = "edit.selectAll", .accel = "Ctrl+A" },
        } },
        .{ .label = "退出", .id = "quit" },
    };
    try testing.expectEqualStrings("copy", roleForId(&items, "edit.copy").?);
    try testing.expectEqualStrings("paste", roleForId(&items, "edit.paste").?);
    try testing.expect(roleForId(&items, "edit.selectAll") == null);
    try testing.expect(roleForId(&items, "quit") == null);
    try testing.expect(roleForId(&items, "missing") == null);
}

test "v0.1.18: accel table skips unparsable and Win-modifier entries" {
    const items = [_]Config.MenuItem{
        .{ .label = "A", .id = "a", .accel = "Ctrl+S" },
        .{ .label = "B", .id = "b", .accel = "not a key combo!!" },
        .{ .label = "C", .id = "c", .accel = "Win+X" },
        .{ .label = "D", .id = "d" },
    };
    // 计数逻辑与 collectIds 一致：4 个叶子 → id 1..4；只有 a 进入 ACCEL 表
    var accels: std.ArrayListUnmanaged(win32.ACCEL) = .empty;
    defer accels.deinit(testing.allocator);
    var counter: u16 = 0;
    collectAccels(testing.allocator, &items, &counter, &accels);
    try testing.expectEqual(@as(u16, 4), counter);
    try testing.expectEqual(@as(usize, 1), accels.items.len);
    try testing.expectEqual(@as(u16, 1), accels.items[0].cmd);
    try testing.expectEqual(@as(u8, 'S'), accels.items[0].key);
    try testing.expect(accels.items[0].fVirt & win32.FCONTROL != 0);
}
