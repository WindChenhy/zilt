//! v0.6.0a：配置 flavors 的 RFC 7396 JSON Merge Patch 纯函数实现。
//!
//! 语义（与 Tauri `--config` / RFC 7396 一致）：
//!   - patch 是对象 → 递归合并；base 不是对象时视为空对象
//!   - patch 的值是 null → 删除该键
//!   - 数组整体替换（不做元素级合并）
//!   - 其它标量 → 直接覆盖
//!
//! 只做数据层，不读文件、不认识平台；build.zig 负责按顺序喂 patch。

const std = @import("std");

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;
pub const Array = std.json.Array;

/// 深拷贝（结果全部落在 alloc 上；字符串/键都重新 dupe）。
pub fn clone(alloc: std.mem.Allocator, value: Value) std.mem.Allocator.Error!Value {
    return switch (value) {
        .null, .bool, .integer, .float => value,
        .number_string => |s| .{ .number_string = try alloc.dupe(u8, s) },
        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        .array => |arr| blk: {
            var out = Array.init(alloc);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try clone(alloc, item));
            break :blk .{ .array = out };
        },
        .object => |obj| .{ .object = try cloneObject(alloc, obj) },
    };
}

fn cloneObject(alloc: std.mem.Allocator, obj: ObjectMap) std.mem.Allocator.Error!ObjectMap {
    var out = ObjectMap.empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        try out.put(alloc, try alloc.dupe(u8, entry.key_ptr.*), try clone(alloc, entry.value_ptr.*));
    }
    return out;
}

/// RFC 7396：把 patch 合并到 base，返回新值（不改动入参）。
pub fn merge(alloc: std.mem.Allocator, base: Value, patch: Value) std.mem.Allocator.Error!Value {
    if (patch != .object) return clone(alloc, patch);

    var out = switch (base) {
        .object => |obj| try cloneObject(alloc, obj),
        else => ObjectMap.empty,
    };

    var it = patch.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const patch_value = entry.value_ptr.*;
        if (patch_value == .null) {
            _ = out.orderedRemove(key);
            continue;
        }
        if (out.getPtr(key)) |existing| {
            existing.* = try merge(alloc, existing.*, patch_value);
        } else {
            try out.put(alloc, try alloc.dupe(u8, key), try clone(alloc, patch_value));
        }
    }
    return .{ .object = out };
}

/// 顺序合并多个 patch（后者覆盖前者）。
pub fn mergeAll(alloc: std.mem.Allocator, base: Value, patches: []const Value) std.mem.Allocator.Error!Value {
    var out = try clone(alloc, base);
    for (patches) |patch| out = try merge(alloc, out, patch);
    return out;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

fn parse(alloc: std.mem.Allocator, text: []const u8) !Value {
    const parsed = try std.json.parseFromSlice(Value, alloc, text, .{});
    return parsed.value;
}

fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn intAt(v: Value, key: []const u8) ?i64 {
    const child = get(v, key) orelse return null;
    if (child != .integer) return null;
    return child.integer;
}

test "v0.6.0a merge: 对象递归合并，未提及的键保留" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try parse(a, "{\"a\":{\"b\":1,\"c\":2},\"d\":3}");
    const patch = try parse(a, "{\"a\":{\"b\":9},\"e\":4}");
    const m = try merge(a, base, patch);

    try std.testing.expectEqual(@as(?i64, 9), intAt(get(m, "a").?, "b"));
    try std.testing.expectEqual(@as(?i64, 2), intAt(get(m, "a").?, "c"));
    try std.testing.expectEqual(@as(?i64, 3), intAt(m, "d"));
    try std.testing.expectEqual(@as(?i64, 4), intAt(m, "e"));
}

test "v0.6.0a merge: 数组整体替换" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try parse(a, "{\"a\":[1,2,3]}");
    const patch = try parse(a, "{\"a\":[9]}");
    const m = try merge(a, base, patch);

    const arr = get(m, "a").?.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    try std.testing.expectEqual(@as(i64, 9), arr.items[0].integer);
}

test "v0.6.0a merge: null 删除键" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try parse(a, "{\"a\":1,\"b\":2}");
    const patch = try parse(a, "{\"a\":null}");
    const m = try merge(a, base, patch);

    try std.testing.expect(get(m, "a") == null);
    try std.testing.expectEqual(@as(?i64, 2), intAt(m, "b"));
}

test "v0.6.0a merge: 标量覆盖对象 / 对象覆盖标量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try parse(a, "{\"a\":{\"b\":1},\"c\":5}");
    const patch = try parse(a, "{\"a\":5,\"c\":{\"d\":7}}");
    const m = try merge(a, base, patch);

    try std.testing.expectEqual(@as(?i64, 5), intAt(m, "a"));
    try std.testing.expectEqual(@as(?i64, 7), intAt(get(m, "c").?, "d"));
}

test "v0.6.0a merge: 空 patch 保持 base，多 patch 顺序覆盖" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try parse(a, "{\"name\":\"zilt\",\"nested\":{\"x\":1}}");
    const empty = try parse(a, "{}");
    const keep = try merge(a, base, empty);
    try std.testing.expectEqualStrings("zilt", get(keep, "name").?.string);
    try std.testing.expectEqual(@as(?i64, 1), intAt(get(keep, "nested").?, "x"));

    const p1 = try parse(a, "{\"name\":\"beta\",\"nested\":{\"x\":2}}");
    const p2 = try parse(a, "{\"name\":\"prod\"}");
    const m = try mergeAll(a, base, &.{ p1, p2 });
    try std.testing.expectEqualStrings("prod", get(m, "name").?.string);
    try std.testing.expectEqual(@as(?i64, 2), intAt(get(m, "nested").?, "x"));
}

test "v0.6.0a merge: 不修改入参（base 仍可读）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try parse(a, "{\"a\":{\"b\":1}}");
    const patch = try parse(a, "{\"a\":{\"b\":2}}");
    _ = try merge(a, base, patch);
    try std.testing.expectEqual(@as(?i64, 1), intAt(get(base, "a").?, "b"));
}
