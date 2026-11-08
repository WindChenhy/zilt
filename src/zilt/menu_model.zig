//! 运行时可变菜单模型（v0.1.13）。
//!
//! 编译期 `Config.MenuItem` 只能在启动时建一次菜单；本模块提供可变树，用于：
//!  - 运行时增删项 / 勾选 / 禁用 / 改标题 / 改加速键（菜单栏与托盘右键菜单共用）
//!  - 程序化 popup（右键上下文菜单）
//!  - 把当前状态序列化为 JSON 交给前端（勾选态同步）
//!
//! 设计取舍：节点与字符串全部由内部 arena 分配，`remove` 只摘链不释放（arena
//! 统一回收）。菜单规模在几十项量级，操作后由平台层整树重建 HMENU 更简单可靠，
//! 也避免 `ModifyMenu` 与 owner-draw 的状态错位。
const std = @import("std");
const Config = @import("config.zig").Config;

const Allocator = std.mem.Allocator;

pub const Node = struct {
    /// 叶子项的命令 id（唯一）；分组/子菜单可为空串
    id: []const u8 = "",
    label: []const u8 = "",
    /// 展示用加速键文本（如 "Ctrl+K"）；解析交给 accel 模块
    accel: ?[]const u8 = null,
    enabled: bool = true,
    checked: bool = false,
    /// 子菜单默认项（粗体）
    default_item: bool = false,
    children: std.ArrayListUnmanaged(*Node) = .empty,

    pub fn isSeparator(self: Node) bool {
        return self.id.len == 0 and std.mem.eql(u8, self.label, "-");
    }

    pub fn isSubmenu(self: Node) bool {
        return self.children.items.len != 0;
    }
};

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    roots: std.ArrayListUnmanaged(*Node) = .empty,

    pub fn init(backing: Allocator) Model {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn arenaAlloc(self: *Model) Allocator {
        return self.arena.allocator();
    }

    /// 从编译期菜单树建立初始模型（label "-" 为分隔符，items 非空为子菜单）。
    pub fn fromConfig(backing: Allocator, items: []const Config.MenuItem) !Model {
        var model = Model.init(backing);
        errdefer model.deinit();
        try model.appendConfigItems(&model.roots, items);
        return model;
    }

    fn appendConfigItems(self: *Model, out: *std.ArrayListUnmanaged(*Node), items: []const Config.MenuItem) !void {
        for (items) |item| {
            const node = try self.arenaAlloc().create(Node);
            node.* = .{
                .id = try self.arenaAlloc().dupe(u8, item.id orelse ""),
                .label = try self.arenaAlloc().dupe(u8, item.label),
                .accel = if (item.accel) |a| try self.arenaAlloc().dupe(u8, a) else null,
            };
            if (item.items) |children| {
                try self.appendConfigItems(&node.children, children);
            }
            try out.append(self.arenaAlloc(), node);
        }
    }

    fn matchSeg(node: *Node, seg: []const u8) bool {
        return std.mem.eql(u8, node.id, seg) or std.mem.eql(u8, node.label, seg);
    }

    fn findInList(list: []*Node, seg: []const u8) ?*Node {
        for (list) |node| {
            if (matchSeg(node, seg)) return node;
        }
        return null;
    }

    /// 逐段按根路径解析（"文件/open"）。
    fn findPath(self: *Model, path: []const u8) ?*Node {
        var list: []*Node = self.roots.items;
        var found: ?*Node = null;
        var it = std.mem.splitScalar(u8, path, '/');
        var any = false;
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            any = true;
            found = findInList(list, seg) orelse return null;
            list = found.?.children.items;
        }
        return if (any) found else null;
    }

    /// 深度优先：在子层里找（根层已单独查过）。
    fn findDeep(list: []*Node, seg: []const u8) ?*Node {
        for (list) |node| {
            if (node.children.items.len == 0) continue;
            if (findInList(node.children.items, seg)) |hit| return hit;
            if (findDeep(node.children.items, seg)) |hit| return hit;
        }
        return null;
    }

    /// 查找：含 "/" 按路径；否则先查根层再深度优先，因此 `"save"` 这类命令 id
    /// 即使嵌在子菜单里也能直接命中。
    pub fn find(self: *Model, path: []const u8) ?*Node {
        if (path.len == 0) return null;
        if (std.mem.indexOfScalar(u8, path, '/') != null) return self.findPath(path);
        return findInList(self.roots.items, path) orelse findDeep(self.roots.items, path);
    }

    /// 在 `path` 指定位置插入（path 为父路径；null/空 = 根）。index = -1 表示追加。
    pub fn add(self: *Model, parent_path: ?[]const u8, index: i32, spec: Spec) !*Node {
        const list = if (parent_path) |p| blk: {
            if (p.len == 0) break :blk &self.roots;
            const parent = self.find(p) orelse return error.ParentNotFound;
            break :blk &parent.children;
        } else &self.roots;

        const node = try self.arenaAlloc().create(Node);
        node.* = .{
            .id = try self.arenaAlloc().dupe(u8, spec.id orelse ""),
            .label = try self.arenaAlloc().dupe(u8, spec.label),
            .accel = if (spec.accel) |a| try self.arenaAlloc().dupe(u8, a) else null,
            .enabled = spec.enabled,
            .checked = spec.checked,
        };
        if (spec.children) |children| {
            try self.appendConfigItems(&node.children, children);
        }
        if (index < 0 or @as(usize, @intCast(index)) >= list.items.len) {
            try list.append(self.arenaAlloc(), node);
        } else {
            try list.insert(self.arenaAlloc(), @intCast(index), node);
        }
        return node;
    }

    fn removeFrom(list: *std.ArrayListUnmanaged(*Node), seg: []const u8) bool {
        for (list.items, 0..) |node, i| {
            if (matchSeg(node, seg)) {
                _ = list.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    fn removeDeep(list: []*Node, seg: []const u8) bool {
        for (list) |node| {
            if (node.children.items.len == 0) continue;
            if (removeFrom(&node.children, seg)) return true;
            if (removeDeep(node.children.items, seg)) return true;
        }
        return false;
    }

    /// 摘除节点（arena 不回收内存）。含 "/" 走父路径，否则先查根层再深度优先。
    pub fn remove(self: *Model, path: []const u8) bool {
        if (path.len == 0) return false;
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
            const parent_path = path[0..idx];
            const leaf = path[idx + 1 ..];
            if (leaf.len == 0) return false;
            const list = if (parent_path.len == 0)
                &self.roots
            else blk: {
                const parent = self.find(parent_path) orelse return false;
                break :blk &parent.children;
            };
            return removeFrom(list, leaf);
        }
        if (removeFrom(&self.roots, path)) return true;
        return removeDeep(self.roots.items, path);
    }

    pub fn setChecked(self: *Model, path: []const u8, checked: bool) bool {
        const node = self.find(path) orelse return false;
        node.checked = checked;
        return true;
    }

    pub fn setEnabled(self: *Model, path: []const u8, enabled: bool) bool {
        const node = self.find(path) orelse return false;
        node.enabled = enabled;
        return true;
    }

    pub fn setLabel(self: *Model, path: []const u8, label: []const u8) bool {
        const node = self.find(path) orelse return false;
        node.label = self.arenaAlloc().dupe(u8, label) catch return false;
        return true;
    }

    pub fn setAccel(self: *Model, path: []const u8, accel: ?[]const u8) bool {
        const node = self.find(path) orelse return false;
        node.accel = if (accel) |a| (self.arenaAlloc().dupe(u8, a) catch return false) else null;
        return true;
    }

    pub fn toggleChecked(self: *Model, path: []const u8) bool {
        const node = self.find(path) orelse return false;
        node.checked = !node.checked;
        return true;
    }

    /// 叶子项 id → 命令名（供 WM_COMMAND 查表；分隔符与分组不参与）。
    pub fn collectLeaves(self: *Model, alloc: Allocator) ![]const LeafRef {
        var out: std.ArrayListUnmanaged(LeafRef) = .empty;
        errdefer out.deinit(alloc);
        try collectInto(self, &self.roots, &out, alloc);
        return out.toOwnedSlice(alloc);
    }

    const LeafRef = struct { id: []const u8, label: []const u8, checked: bool, enabled: bool };

    fn collectInto(self: *Model, list: *std.ArrayListUnmanaged(*Node), out: *std.ArrayListUnmanaged(LeafRef), alloc: Allocator) !void {
        for (list.items) |node| {
            if (node.isSeparator()) continue;
            if (node.children.items.len != 0) {
                try collectInto(self, &node.children, out, alloc);
                continue;
            }
            try out.append(alloc, .{
                .id = node.id,
                .label = node.label,
                .checked = node.checked,
                .enabled = node.enabled,
            });
        }
    }

    /// 当前状态 JSON（前端可读的勾选/禁用态快照）。
    pub fn toJson(self: *Model, alloc: Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        try writeJson(self, &buf, &self.roots, alloc);
        return buf.toOwnedSlice(alloc);
    }

    fn writeJson(self: *Model, buf: *std.ArrayListUnmanaged(u8), list: *std.ArrayListUnmanaged(*Node), alloc: Allocator) !void {
        try buf.appendSlice(alloc, "[");
        for (list.items, 0..) |node, i| {
            if (i != 0) try buf.appendSlice(alloc, ",");
            const id = try std.json.Stringify.valueAlloc(alloc, node.id, .{});
            defer alloc.free(id);
            const label = try std.json.Stringify.valueAlloc(alloc, node.label, .{});
            defer alloc.free(label);
            const accel_json = if (node.accel) |a| try std.json.Stringify.valueAlloc(alloc, a, .{}) else try alloc.dupe(u8, "null");
            defer alloc.free(accel_json);
            const head = try std.fmt.allocPrint(alloc, "{{\"id\":{s},\"label\":{s},\"accel\":{s},\"enabled\":{},\"checked\":{},\"separator\":{},\"children\":", .{
                id, label, accel_json, node.enabled, node.checked, node.isSeparator(),
            });
            defer alloc.free(head);
            try buf.appendSlice(alloc, head);
            if (node.children.items.len == 0) {
                try buf.appendSlice(alloc, "[]");
            } else {
                try writeJson(self, buf, &node.children, alloc);
            }
            try buf.appendSlice(alloc, "}");
        }
        try buf.appendSlice(alloc, "]");
    }
};

pub const Spec = struct {
    id: ?[]const u8 = null,
    label: []const u8,
    accel: ?[]const u8 = null,
    enabled: bool = true,
    checked: bool = false,
    children: ?[]const Config.MenuItem = null,
};

const testing = std.testing;

const sample_menu = [_]Config.MenuItem{
    .{ .label = "文件", .items = &.{
        .{ .label = "新建", .id = "new" },
        .{ .label = "打开", .id = "open" },
        .{ .label = "-" },
        .{ .label = "退出", .id = "quit" },
    } },
    .{ .label = "视图", .items = &.{
        .{ .label = "侧栏", .id = "sidebar" },
        .{ .label = "状态栏", .id = "statusbar" },
    } },
};

test "build from config and find by id or label" {
    var model = try Model.fromConfig(testing.allocator, &sample_menu);
    defer model.deinit();

    try testing.expect(model.find("open") != null);
    try testing.expect(model.find("文件/open") != null);
    try testing.expect(model.find("视图/statusbar") != null);
    try testing.expect(model.find("missing") == null);

    const leaves = try model.collectLeaves(testing.allocator);
    defer testing.allocator.free(leaves);
    // 分隔符被跳过，只剩 5 个叶子
    try testing.expectEqual(@as(usize, 5), leaves.len);
    try testing.expectEqualStrings("new", leaves[0].id);
    try testing.expectEqualStrings("statusbar", leaves[4].id);
}

test "runtime add remove and state mutation" {
    var model = try Model.fromConfig(testing.allocator, &sample_menu);
    defer model.deinit();

    _ = try model.add("文件", -1, .{ .id = "save", .label = "保存", .accel = "Ctrl+S" });
    try testing.expectEqualStrings("保存", model.find("save").?.label);
    try testing.expectEqualStrings("Ctrl+S", model.find("save").?.accel.?);

    // 插入到首位
    _ = try model.add("视图", 0, .{ .id = "zoom", .label = "缩放" });
    const view = model.find("视图").?;
    try testing.expectEqualStrings("zoom", view.children.items[0].id);

    try testing.expect(model.setChecked("save", true));
    try testing.expect(model.find("save").?.checked);
    try testing.expect(model.toggleChecked("save"));
    try testing.expect(!model.find("save").?.checked);

    try testing.expect(model.setEnabled("quit", false));
    try testing.expect(!model.find("quit").?.enabled);

    try testing.expect(model.setLabel("open", "打开…"));
    try testing.expectEqualStrings("打开…", model.find("open").?.label);

    try testing.expect(model.remove("save"));
    try testing.expect(model.find("save") == null);
    try testing.expect(!model.remove("save"));

    // 根级增删
    _ = try model.add(null, -1, .{ .id = "help", .label = "帮助" });
    try testing.expect(model.find("help") != null);
    try testing.expect(model.remove("help"));
}

test "json snapshot carries checked and enabled state" {
    var model = try Model.fromConfig(testing.allocator, &sample_menu);
    defer model.deinit();
    _ = model.setChecked("sidebar", true);
    _ = model.setEnabled("statusbar", false);

    const json = try model.toJson(testing.allocator);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const roots = parsed.value.array;
    try testing.expectEqual(@as(usize, 2), roots.items.len);

    const view = roots.items[1].object.get("children").?.array;
    const sidebar = view.items[0].object;
    try testing.expectEqualStrings("sidebar", sidebar.get("id").?.string);
    try testing.expect(sidebar.get("checked").?.bool);
    const statusbar = view.items[1].object;
    try testing.expect(!statusbar.get("enabled").?.bool);
    try testing.expect(statusbar.get("accel").? == .null);
}

test "separator detection and duplicate insert order" {
    var model = Model.init(testing.allocator);
    defer model.deinit();
    _ = try model.add(null, -1, .{ .id = "a", .label = "A" });
    _ = try model.add(null, -1, .{ .label = "-" });
    _ = try model.add(null, -1, .{ .id = "b", .label = "B" });
    try testing.expect(model.roots.items[1].isSeparator());
    try testing.expect(!model.roots.items[0].isSeparator());
    // 指定越界索引等价追加
    _ = try model.add(null, 99, .{ .id = "c", .label = "C" });
    try testing.expectEqual(@as(usize, 4), model.roots.items.len);
    try testing.expectEqualStrings("c", model.roots.items[3].id);
}

test "unknown parent is reported" {
    var model = Model.init(testing.allocator);
    defer model.deinit();
    try testing.expectError(error.ParentNotFound, model.add("nope", -1, .{ .label = "x" }));
    try testing.expect(!model.setChecked("nope/child", true));
}
