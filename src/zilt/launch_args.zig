//! v0.4.0 H20：深链/第二实例参数的统一解析面（Tauri cli 插件语义对齐）。
//!
//! 首启与第二实例转发的 argv 在既有 `deepLink {url,files}` 分类（deep_link.zig）
//! 之外，额外给出结构化解析结果：位置参数 / `--key` 与 `--key=value` 旗标 /
//! 子命令（第一个位置参数）。纯函数 + 单测，两平台 deep_link 共用；
//! 事件 payload 以 `parsed` 字段随 `deepLink` 事件下发。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Flag = struct {
    /// 旗标名（不含 `--` 前缀）
    key: []const u8,
    /// `--key=value` 的 value；裸 `--key` 为 null
    value: ?[]const u8 = null,
};

pub const Parsed = struct {
    /// 非 `--` 开头的原始参数（保持原序；scheme URL 与文件路径的分类仍归 deep_link）
    positional: [][]u8 = &.{},
    flags: []Flag = &.{},
    /// 第一个位置参数（null = 无）
    subcommand: ?[]const u8 = null,

    pub fn deinit(self: *Parsed, alloc: Allocator) void {
        for (self.positional) |p| alloc.free(p);
        if (self.positional.len > 0) alloc.free(self.positional);
        for (self.flags) |f| {
            alloc.free(f.key);
            if (f.value) |v| alloc.free(v);
        }
        if (self.flags.len > 0) alloc.free(self.flags);
        self.* = .{};
    }
};

/// argv → 结构化解析。空参数 / 裸 `--` 分隔符跳过；`--` 后的所有参数视为位置参数
/// （POSIX 惯例，逃逸旗标歧义）。
pub fn parse(alloc: Allocator, args: []const []const u8) !Parsed {
    var pos: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (pos.items) |p| alloc.free(p);
        pos.deinit(alloc);
    }
    var flags: std.ArrayListUnmanaged(Flag) = .empty;
    errdefer {
        for (flags.items) |f| {
            alloc.free(f.key);
            if (f.value) |v| alloc.free(v);
        }
        flags.deinit(alloc);
    }

    var escaped = false;
    for (args) |arg| {
        if (arg.len == 0) continue;
        if (!escaped and std.mem.eql(u8, arg, "--")) {
            escaped = true;
            continue;
        }
        if (!escaped and std.mem.startsWith(u8, arg, "--") and arg.len > 2) {
            const body = arg[2..];
            if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
                const key = body[0..eq];
                if (key.len > 0) {
                    try flags.append(alloc, .{
                        .key = try alloc.dupe(u8, key),
                        .value = try alloc.dupe(u8, body[eq + 1 ..]),
                    });
                }
                continue;
            }
            try flags.append(alloc, .{ .key = try alloc.dupe(u8, body) });
            continue;
        }
        try pos.append(alloc, try alloc.dupe(u8, arg));
    }

    // 先捕获子命令——toOwnedSlice 会清空 pos.items（实测踩坑）
    const subcommand: ?[]u8 = if (pos.items.len > 0) pos.items[0] else null;
    return .{
        .positional = try pos.toOwnedSlice(alloc),
        .flags = try flags.toOwnedSlice(alloc),
        .subcommand = subcommand,
    };
}

/// deepLink 事件 payload 的 `parsed` 字段：
/// `{"positional":[…],"flags":[{"key":…,"value":…|null}],"subcommand":…|null}`
pub fn toJson(alloc: Allocator, parsed: *const Parsed) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"positional\":[");
    for (parsed.positional, 0..) |p, i| {
        if (i != 0) try out.append(alloc, ',');
        const s = try std.json.Stringify.valueAlloc(alloc, p, .{});
        defer alloc.free(s);
        try out.appendSlice(alloc, s);
    }
    try out.appendSlice(alloc, "],\"flags\":[");
    for (parsed.flags, 0..) |f, i| {
        if (i != 0) try out.append(alloc, ',');
        const key = try std.json.Stringify.valueAlloc(alloc, f.key, .{});
        defer alloc.free(key);
        if (f.value) |v| {
            const vs = try std.json.Stringify.valueAlloc(alloc, v, .{});
            defer alloc.free(vs);
            const chunk = try std.fmt.allocPrint(alloc, "{{\"key\":{s},\"value\":{s}}}", .{ key, vs });
            defer alloc.free(chunk);
            try out.appendSlice(alloc, chunk);
        } else {
            const chunk = try std.fmt.allocPrint(alloc, "{{\"key\":{s},\"value\":null}}", .{key});
            defer alloc.free(chunk);
            try out.appendSlice(alloc, chunk);
        }
    }
    try out.appendSlice(alloc, "],\"subcommand\":");
    if (parsed.subcommand) |sc| {
        const s = try std.json.Stringify.valueAlloc(alloc, sc, .{});
        defer alloc.free(s);
        try out.appendSlice(alloc, s);
    } else {
        try out.appendSlice(alloc, "null");
    }
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse: 位置参数 / 旗标 / 子命令" {
    const args = [_][]const u8{ "--zilt-x", "open", "--id=7", "--verbose", "zilt://x", "file.txt" };
    var p = try parse(testing.allocator, &args);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), p.positional.len);
    try testing.expectEqualStrings("open", p.subcommand.?);
    // 全部 `--` 参数进 flags（含框架旗标 --zilt-x——deep_link 的 url/files 分类
    // 自行跳过它们，parsed 面保留完整结构供应用消费）
    try testing.expectEqual(@as(usize, 3), p.flags.len);
    try testing.expectEqualStrings("zilt-x", p.flags[0].key);
    try testing.expect(p.flags[0].value == null);
    try testing.expectEqualStrings("id", p.flags[1].key);
    try testing.expectEqualStrings("7", p.flags[1].value.?);
    try testing.expectEqualStrings("verbose", p.flags[2].key);
}

test "parse: -- 逃逸与空参数" {
    const args = [_][]const u8{ "--real", "--", "--not-a-flag", "" };
    var p = try parse(testing.allocator, &args);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), p.flags.len);
    try testing.expectEqual(@as(usize, 1), p.positional.len);
    try testing.expectEqualStrings("--not-a-flag", p.positional[0]);
}

test "parse: --key= 带空值与空 key 忽略" {
    const args = [_][]const u8{ "--a=", "--=x" };
    var p = try parse(testing.allocator, &args);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), p.flags.len);
    try testing.expectEqualStrings("a", p.flags[0].key);
    try testing.expectEqualStrings("", p.flags[0].value.?);
}

test "parse: 无参数" {
    var p = try parse(testing.allocator, &.{});
    defer p.deinit(testing.allocator);
    try testing.expect(p.subcommand == null);
    const json = try toJson(testing.allocator, &p);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"positional\":[],\"flags\":[],\"subcommand\":null}", json);
}

test "toJson: 完整形状（含 JSON 串转义）" {
    const args = [_][]const u8{ "run", "--path=C:\\a\"b" };
    var p = try parse(testing.allocator, &args);
    defer p.deinit(testing.allocator);
    const json = try toJson(testing.allocator, &p);
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("run", obj.get("subcommand").?.string);
    try testing.expectEqual(@as(usize, 1), obj.get("flags").?.array.items.len);
    const flag = obj.get("flags").?.array.items[0].object;
    try testing.expectEqualStrings("path", flag.get("key").?.string);
    try testing.expectEqualStrings("C:\\a\"b", flag.get("value").?.string);
}
