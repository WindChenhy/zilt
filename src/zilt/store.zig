//! 键值存储（v0.1.16 官方周边 API：store）。
//!
//! 单文件 JSON 对象持久化（`{ "key": "value" }`），值统一为字符串——
//! 与 Wails/Tauri 的 `store` 一致：复杂结构由前端 JSON.stringify 后存入。
//! 写入采用「临时文件 + 原子替换」，避免进程中断留下半截文件。
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Store = struct {
    alloc: Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .empty,
    path: ?[]u8 = null,
    dirty: bool = false,

    pub fn init(alloc: Allocator) Store {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.map.deinit(self.alloc);
        if (self.path) |p| self.alloc.free(p);
        self.* = undefined;
    }

    pub fn get(self: *Store, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn set(self: *Store, key: []const u8, value: []const u8) !void {
        if (self.map.getEntry(key)) |entry| {
            self.alloc.free(entry.value_ptr.*);
            entry.value_ptr.* = try self.alloc.dupe(u8, value);
            self.dirty = true;
            return;
        }
        const key_copy = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(key_copy);
        const value_copy = try self.alloc.dupe(u8, value);
        errdefer self.alloc.free(value_copy);
        try self.map.put(self.alloc, key_copy, value_copy);
        self.dirty = true;
    }

    pub fn remove(self: *Store, key: []const u8) bool {
        if (self.map.fetchRemove(key)) |kv| {
            self.alloc.free(kv.key);
            self.alloc.free(kv.value);
            self.dirty = true;
            return true;
        }
        return false;
    }

    pub fn count(self: *const Store) usize {
        return self.map.count();
    }

    /// 键列表（按字典序）。调用方负责 `alloc.free(list)`，元素指向内部存储。
    pub fn keys(self: *Store, alloc: Allocator) ![][]const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer list.deinit(alloc);
        var it = self.map.keyIterator();
        while (it.next()) |k| try list.append(alloc, k.*);
        std.mem.sort([]const u8, list.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return list.toOwnedSlice(alloc);
    }

    pub fn toJson(self: *Store, alloc: Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "{");
        var it = self.map.iterator();
        var first = true;
        while (it.next()) |e| {
            if (!first) try out.appendSlice(alloc, ",");
            first = false;
            const k = try std.json.Stringify.valueAlloc(alloc, e.key_ptr.*, .{});
            defer alloc.free(k);
            const v = try std.json.Stringify.valueAlloc(alloc, e.value_ptr.*, .{});
            defer alloc.free(v);
            const chunk = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ k, v });
            defer alloc.free(chunk);
            try out.appendSlice(alloc, chunk);
        }
        try out.appendSlice(alloc, "}");
        return out.toOwnedSlice(alloc);
    }

    pub fn fromJson(self: *Store, json: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{}) catch return error.InvalidStoreJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidStoreJson;
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            const value = switch (e.value_ptr.*) {
                .string => |s| s,
                else => return error.InvalidStoreJson,
            };
            try self.set(e.key_ptr.*, value);
        }
        self.dirty = false;
    }

};

// 落盘由平台层完成（Windows: Win32 CreateFileW + WriteFile 原子替换），
// 本模块只负责内容与 JSON 形态，便于跨平台复用与离线单测。

const testing = std.testing;

test "set get remove and overwrite" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(store.get("theme") == null);
    try store.set("theme", "dark");
    try testing.expectEqualStrings("dark", store.get("theme").?);
    try store.set("theme", "light");
    try testing.expectEqualStrings("light", store.get("theme").?);
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(store.remove("theme"));
    try testing.expect(!store.remove("theme"));
    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expect(store.dirty);
}

test "json roundtrip preserves keys and order-independent equality" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.set("a", "1");
    try store.set("b", "two");
    try store.set("c", "三点");

    const json = try store.toJson(testing.allocator);
    defer testing.allocator.free(json);

    var restored = Store.init(testing.allocator);
    defer restored.deinit();
    try restored.fromJson(json);
    try testing.expectEqualStrings("1", restored.get("a").?);
    try testing.expectEqualStrings("two", restored.get("b").?);
    try testing.expectEqualStrings("三点", restored.get("c").?);

    const keys = try restored.keys(testing.allocator);
    defer testing.allocator.free(keys);
    try testing.expectEqual(@as(usize, 3), keys.len);
    try testing.expectEqualStrings("a", keys[0]);
    try testing.expectEqualStrings("c", keys[2]);
}

test "invalid json is rejected" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try testing.expectError(error.InvalidStoreJson, store.fromJson("[1,2,3]"));
    try testing.expectError(error.InvalidStoreJson, store.fromJson("{"));
    try testing.expectError(error.InvalidStoreJson, store.fromJson("{\"a\":1}"));
}
