//! 由运行时菜单模型构建 Win32 HMENU（v0.1.13）。
//!
//! 与 `menu.zig` 的区别：那边直接吃编译期 `Config.MenuItem` 切片，只能建一次；
//! 这里吃 `menu_model.Model`，支持运行时增删/勾选/禁用后整树重建。
const std = @import("std");
const win32 = @import("win32.zig");
const menu_model = @import("../../menu_model.zig");

pub const MF_CHECKED: win32.UINT = 0x00000008;
pub const MF_GRAYED: win32.UINT = 0x00000001;
pub const MF_DEFAULT: win32.UINT = 0x00001000;
pub const MF_BYCOMMAND: win32.UINT = 0x00000000;

extern "user32" fn SetMenuDefaultItem(hMenu: win32.HMENU, uItem: win32.UINT, fByPos: win32.UINT) callconv(.c) win32.BOOL;
extern "user32" fn DrawMenuBar(hWnd: win32.HWND) callconv(.c) win32.BOOL;

pub const Built = struct {
    hmenu: win32.HMENU,
    /// 叶子命令 id，索引 = win_id - base - 1
    ids: std.ArrayListUnmanaged([]const u8) = .empty,
    base: u16 = 0,
    default_id: ?u16 = null,

    pub fn deinit(self: *Built, alloc: std.mem.Allocator) void {
        // ids 里的字符串归 model 的 arena，这里只释放数组本身
        self.ids.deinit(alloc);
        if (self.hmenu) |h| _ = win32.DestroyMenu(h);
    }

    pub fn idFor(self: *const Built, win_id: u16) ?[]const u8 {
        if (win_id <= self.base) return null;
        const idx = win_id - self.base - 1;
        if (idx >= self.ids.items.len) return null;
        const id = self.ids.items[idx];
        return if (id.len == 0) null else id;
    }

    pub fn labelFor(self: *const Built, win_id: u16) ?[]const u8 {
        if (win_id <= self.base) return null;
        const idx = win_id - self.base - 1;
        if (idx >= self.ids.items.len) return null;
        return self.ids.items[idx];
    }
};

const Ctx = struct {
    alloc: std.mem.Allocator,
    built: *Built,
    next: *u16,
    root: bool,
};

/// 构建菜单栏（CreateMenu）。`base` 为叶子 win id 起始值（菜单栏用 0）。
pub fn buildMenuBar(alloc: std.mem.Allocator, model: *menu_model.Model, base: u16) !Built {
    var built = Built{ .hmenu = win32.CreateMenu() orelse return error.CreateMenuFailed, .base = base };
    errdefer built.deinit(alloc);
    var next: u16 = base;
    var ctx = Ctx{ .alloc = alloc, .built = &built, .next = &next, .root = true };
    try fill(&ctx, built.hmenu, model.roots.items);
    return built;
}

/// 构建弹出菜单（托盘右键 / WebView 上下文菜单）。
pub fn buildPopup(alloc: std.mem.Allocator, model: *menu_model.Model, base: u16) !Built {
    var built = Built{ .hmenu = win32.CreatePopupMenu() orelse return error.CreateMenuFailed, .base = base };
    errdefer built.deinit(alloc);
    var next: u16 = base;
    var ctx = Ctx{ .alloc = alloc, .built = &built, .next = &next, .root = false };
    try fill(&ctx, built.hmenu, model.roots.items);
    return built;
}

fn fill(ctx: *Ctx, hmenu: win32.HMENU, list: []*menu_model.Node) !void {
    for (list) |node| {
        if (node.isSeparator()) {
            if (win32.AppendMenuW(hmenu, win32.MF_SEPARATOR, 0, null) == 0) return error.AppendMenuFailed;
            continue;
        }

        if (node.children.items.len != 0) {
            const sub = win32.CreatePopupMenu() orelse return error.CreateMenuFailed;
            errdefer _ = win32.DestroyMenu(sub);
            try fill(ctx, sub, node.children.items);
            const text = try menuText(ctx.alloc, node, false);
            defer ctx.alloc.free(text);
            const flags: win32.UINT = win32.MF_POPUP | (if (node.enabled) @as(win32.UINT, 0) else MF_GRAYED);
            if (win32.AppendMenuW(hmenu, flags, @intFromPtr(sub), text.ptr) == 0) return error.AppendMenuFailed;
            continue;
        }

        // 叶子：分配 win id（从 base+1 起）并记录命令 id
        ctx.next.* += 1;
        const win_id = ctx.next.*;
        try ctx.built.ids.append(ctx.alloc, node.id);

        var flags: win32.UINT = win32.MF_STRING;
        if (node.checked) flags |= MF_CHECKED;
        if (!node.enabled) flags |= MF_GRAYED;
        if (node.default_item) flags |= MF_DEFAULT;

        const text = try menuText(ctx.alloc, node, true);
        defer ctx.alloc.free(text);
        if (win32.AppendMenuW(hmenu, flags, win_id, text.ptr) == 0) return error.AppendMenuFailed;
        if (node.default_item) ctx.built.default_id = win_id;
    }
}

/// 菜单项文本：`label` + 可选 `\t<accel>`（Windows 用制表符右对齐加速键）。
fn menuText(alloc: std.mem.Allocator, node: *menu_model.Node, with_accel: bool) ![:0]u16 {
    const text = if (with_accel and node.accel != null)
        try std.fmt.allocPrint(alloc, "{s}\t{s}", .{ node.label, node.accel.? })
    else
        try alloc.dupe(u8, node.label);
    defer alloc.free(text);
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
}

/// 应用默认项（SetMenuDefaultItem 需要菜单句柄，AppendMenuW 的 MF_DEFAULT 在
/// 部分 Windows 版本上不生效，双保险）。
pub fn applyDefault(built: Built) void {
    if (built.default_id) |id| _ = SetMenuDefaultItem(built.hmenu, id, 0);
}

pub fn refreshMenuBar(hwnd: win32.HWND) void {
    _ = DrawMenuBar(hwnd);
}

const testing = std.testing;

const sample = [_]@import("../../config.zig").Config.MenuItem{
    .{ .label = "File", .items = &.{
        .{ .label = "New", .id = "new" },
        .{ .label = "-" },
        .{ .label = "Quit", .id = "quit" },
    } },
};

test "built id mapping skips separators" {
    var model = try menu_model.Model.fromConfig(testing.allocator, &sample);
    defer model.deinit();
    // 纯逻辑快速校验：model 的叶子顺序与 idFor 约定一致
    const leaves = try model.collectLeaves(testing.allocator);
    defer testing.allocator.free(leaves);
    try testing.expectEqual(@as(usize, 2), leaves.len);
    try testing.expectEqualStrings("new", leaves[0].id);
    try testing.expectEqualStrings("quit", leaves[1].id);

    var fake = Built{ .hmenu = null, .base = 0 };
    defer fake.ids.deinit(testing.allocator);
    try fake.ids.append(testing.allocator, "new");
    try fake.ids.append(testing.allocator, "quit");
    try testing.expectEqualStrings("new", fake.idFor(1).?);
    try testing.expectEqualStrings("quit", fake.idFor(2).?);
    try testing.expectEqual(@as(?[]const u8, null), fake.idFor(3));
    try testing.expectEqual(@as(?[]const u8, null), fake.idFor(0));
}
