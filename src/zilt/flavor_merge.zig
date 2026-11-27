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

// ---------------------------------------------------------------------------
// 身份投影（v0.6.0a）
// ---------------------------------------------------------------------------

/// 构建期最终身份。字段均为 alloc 拥有的字符串（调用方 arena 统一释放）。
pub const Identity = struct {
    app_name: []const u8,
    app_id: []const u8,
    version: []const u8,
    publisher: []const u8,
    channel: []const u8 = "stable",
};

pub const IdentityError = error{
    MissingField,
    InvalidAppId,
    InvalidVersion,
    InvalidChannel,
};

/// 反向 DNS 风格：小写字母/数字/`-`，至少一个点，无空段、无首尾点。
pub fn validateAppId(id: []const u8) bool {
    if (id.len < 3 or id.len > 255) return false;
    if (!std.ascii.isLower(id[0]) and !std.ascii.isDigit(id[0])) return false;
    var dots: usize = 0;
    var prev_dot = false;
    for (id) |ch| {
        if (ch == '.') {
            if (prev_dot) return false;
            dots += 1;
            prev_dot = true;
        } else if (ch == '-') {
            if (prev_dot and dots == 0) return false;
            prev_dot = false;
        } else if (std.ascii.isLower(ch) or std.ascii.isDigit(ch)) {
            prev_dot = false;
        } else {
            return false;
        }
    }
    return dots >= 1 and !prev_dot;
}

fn validIdentifiers(s: []const u8, numeric_no_leading_zero: bool) bool {
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |id| {
        if (id.len == 0) return false;
        var numeric = true;
        for (id) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '-')) return false;
            if (!std.ascii.isDigit(ch)) numeric = false;
        }
        if (numeric_no_leading_zero and numeric and id.len > 1 and id[0] == '0') return false;
    }
    return true;
}

/// semver `x.y.z[-prerelease][+build]`；允许预发布后缀（v0.6.0a 决策）。
pub fn validateSemver(v: []const u8) bool {
    const plus = std.mem.indexOfScalar(u8, v, '+');
    const core_pre = if (plus) |i| v[0..i] else v;
    if (plus) |i| {
        if (!validIdentifiers(v[i + 1 ..], false)) return false;
    }
    const dash = std.mem.indexOfScalar(u8, core_pre, '-');
    const core = if (dash) |i| core_pre[0..i] else core_pre;
    if (dash) |i| {
        if (!validIdentifiers(core_pre[i + 1 ..], true)) return false;
    }
    var it = std.mem.splitScalar(u8, core, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n >= 3 or part.len == 0 or part.len > 10) return false;
        for (part) |ch| if (!std.ascii.isDigit(ch)) return false;
        if (part.len > 1 and part[0] == '0') return false;
    }
    return n == 3;
}

pub fn validateChannel(ch: []const u8) bool {
    if (ch.len == 0 or ch.len > 32) return false;
    for (ch) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

pub const FlavorTableError = error{
    InvalidFlavorTable,
    DuplicateAppId,
    UnknownFlavor,
    InvalidAppId,
};

/// `zilt.config.json` 可选的 `flavors` 表：
/// `{"flavors":{"dev":{"app_id":"app.zilt.dev"},"beta":{"app_id":"app.zilt.beta"}}}`
/// 有表时：每个 flavor 必须声明唯一 app_id；-Dflavor 必须命中表项（防止拼错名字
/// 静默产出 base 身份）。无表时走文件模式（zilt.<name>.json），不校验枚举。
pub fn validateFlavorTable(
    alloc: std.mem.Allocator,
    config: Value,
    selected: ?[]const u8,
) (AllocatorError || FlavorTableError)!void {
    if (config != .object) return;
    const flavors = config.object.get("flavors") orelse return;
    if (flavors != .object) return error.InvalidFlavorTable;

    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(alloc);

    var it = flavors.object.iterator();
    while (it.next()) |entry| {
        const item = entry.value_ptr.*;
        if (item != .object) return error.InvalidFlavorTable;
        const id_val = item.object.get("app_id") orelse return error.InvalidFlavorTable;
        if (id_val != .string or !validateAppId(id_val.string)) return error.InvalidAppId;
        for (seen.items) |prev| {
            if (std.mem.eql(u8, prev, id_val.string)) return error.DuplicateAppId;
        }
        try seen.append(alloc, id_val.string);
    }

    if (selected) |name| {
        if (!flavors.object.contains(name)) return error.UnknownFlavor;
    }
}

test "v0.6.0a flavor table: app_id 唯一 + 选中项必须存在" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try parse(a, "{\"flavors\":{\"dev\":{\"app_id\":\"app.zilt.dev\"},\"beta\":{\"app_id\":\"app.zilt.beta\"}}}");
    try validateFlavorTable(a, ok, "beta");
    try std.testing.expectError(error.UnknownFlavor, validateFlavorTable(a, ok, "prod"));

    const dup = try parse(a, "{\"flavors\":{\"dev\":{\"app_id\":\"app.zilt.dev\"},\"beta\":{\"app_id\":\"app.zilt.dev\"}}}");
    try std.testing.expectError(error.DuplicateAppId, validateFlavorTable(a, dup, null));

    const bad = try parse(a, "{\"flavors\":{\"dev\":{\"app_id\":\"App.Zilt\"}}}");
    try std.testing.expectError(error.InvalidAppId, validateFlavorTable(a, bad, null));

    const not_table = try parse(a, "{\"flavors\":[]}");
    try std.testing.expectError(error.InvalidFlavorTable, validateFlavorTable(a, not_table, null));

    const none = try parse(a, "{\"app_name\":\"Zilt\"}");
    try validateFlavorTable(a, none, "whatever");
}

fn stringField(
    alloc: std.mem.Allocator,
    obj: ObjectMap,
    key: []const u8,
    fallback: []const u8,
) (AllocatorError || IdentityError)![]const u8 {
    const v = obj.get(key) orelse return alloc.dupe(u8, fallback);
    if (v != .string or v.string.len == 0) return error.MissingField;
    return alloc.dupe(u8, v.string);
}

const AllocatorError = std.mem.Allocator.Error;

/// 从合并结果取身份；缺失字段用 fallback，非法值返回明确错误（不静默回落）。
pub fn identityFrom(
    alloc: std.mem.Allocator,
    value: Value,
    fallback: Identity,
) (AllocatorError || IdentityError)!Identity {
    if (value != .object) return error.MissingField;
    const obj = value.object;
    const id = Identity{
        .app_name = try stringField(alloc, obj, "app_name", fallback.app_name),
        .app_id = try stringField(alloc, obj, "app_id", fallback.app_id),
        .version = try stringField(alloc, obj, "version", fallback.version),
        .publisher = try stringField(alloc, obj, "publisher", fallback.publisher),
        .channel = try stringField(alloc, obj, "channel", fallback.channel),
    };
    if (!validateAppId(id.app_id)) return error.InvalidAppId;
    if (!validateSemver(id.version)) return error.InvalidVersion;
    if (!validateChannel(id.channel)) return error.InvalidChannel;
    return id;
}

test "v0.6.0a identity: 覆盖字段与默认回落" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try parse(a, "{\"app_name\":\"Zilt\",\"app_id\":\"app.zilt.desktop\",\"version\":\"0.5.11\",\"publisher\":\"Zilt\",\"channel\":\"stable\"}");
    const patch = try parse(a, "{\"app_name\":\"Zilt Beta\",\"app_id\":\"app.zilt.beta\",\"version\":\"0.6.0-beta.1\"}");
    const merged = try merge(a, base, patch);
    const id = try identityFrom(a, merged, .{
        .app_name = "Zilt",
        .app_id = "app.zilt.desktop",
        .version = "0.5.11",
        .publisher = "Zilt",
        .channel = "stable",
    });

    try std.testing.expectEqualStrings("Zilt Beta", id.app_name);
    try std.testing.expectEqualStrings("app.zilt.beta", id.app_id);
    try std.testing.expectEqualStrings("0.6.0-beta.1", id.version);
    try std.testing.expectEqualStrings("Zilt", id.publisher);
    try std.testing.expectEqualStrings("stable", id.channel);
}

test "v0.6.0a identity: 非法 app_id / version / channel 明确报错" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fallback = Identity{
        .app_name = "Zilt",
        .app_id = "app.zilt.desktop",
        .version = "0.5.11",
        .publisher = "Zilt",
        .channel = "stable",
    };

    const bad_id = try parse(a, "{\"app_id\":\"App.Zilt\"}");
    try std.testing.expectError(error.InvalidAppId, identityFrom(a, bad_id, fallback));

    const bad_ver = try parse(a, "{\"version\":\"1.2\"}");
    try std.testing.expectError(error.InvalidVersion, identityFrom(a, bad_ver, fallback));

    const bad_ch = try parse(a, "{\"channel\":\"Beta_1\"}");
    try std.testing.expectError(error.InvalidChannel, identityFrom(a, bad_ch, fallback));

    const bad_type = try parse(a, "{\"app_name\":5}");
    try std.testing.expectError(error.MissingField, identityFrom(a, bad_type, fallback));
}

test "v0.6.0a semver: 校验核心/预发布/构建元数据" {
    const valid = [_][]const u8{
        "0.5.11",
        "1.0.0",
        "0.6.0-beta.1",
        "1.2.3-rc.1+build.5",
        "1.2.3+20261128",
        "10.20.30-alpha-2",
    };
    for (valid) |v| try std.testing.expect(validateSemver(v));

    const invalid = [_][]const u8{
        "1.2",
        "v1.2.3",
        "1.2.3-",
        "1.2.3-01",
        "1.2.3+",
        "01.2.3",
        "1.2.3.4",
        "1.2.x",
        " 1.2.3",
    };
    for (invalid) |v| try std.testing.expect(!validateSemver(v));
}

test "v0.6.0a app_id: 反向 DNS 形态" {
    try std.testing.expect(validateAppId("app.zilt.desktop"));
    try std.testing.expect(validateAppId("com.example.my-app"));
    try std.testing.expect(!validateAppId("zilt"));
    try std.testing.expect(!validateAppId(".app.zilt"));
    try std.testing.expect(!validateAppId("app..zilt"));
    try std.testing.expect(!validateAppId("App.Zilt"));
    try std.testing.expect(!validateAppId("app.zilt."));
}
