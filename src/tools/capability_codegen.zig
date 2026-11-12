//! capabilities.json → Zig 源码（v0.1.23）。
//!
//! 反向链路：运行时/前端已经有 `capabilities.json` 这份「编译期声明的导出视图」，
//! 这里把它变回可编译的 `security.Options` 字面量，用来：
//!   - 把安全策略从 Zig 源码搬到 JSON（改策略不必改类型）
//!   - 与已有 Zig 声明做 diff（生成后 `zig build` 直接类型检查）
//!
//! 只依赖 zilt 模块（不依赖 app_config），因此可被 build step 与 CLI 复用。
const std = @import("std");
const zilt = @import("zilt");

pub const Options = zilt.security.Options;

/// JSON 输入：所有字段可选（缺省沿用 Zig 侧默认值），未知字段忽略。
pub const RawHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const RawCapability = struct {
    name: []const u8,
    windows: ?[]const []const u8 = null,
    local: ?bool = null,
    remote_origins: ?[]const []const u8 = null,
    commands: ?[]const []const u8 = null,
    events: ?[]const []const u8 = null,
    receive_events: ?[]const []const u8 = null,
    scopes: ?[]const []const u8 = null,
};

pub const Raw = struct {
    csp: ?[]const u8 = null,
    headers: ?[]const RawHeader = null,
    navigation_origins: ?[]const []const u8 = null,
    external_links: ?[]const u8 = null,
    capabilities: ?[]const RawCapability = null,
    deny_commands: ?[]const []const u8 = null,
    deny_events: ?[]const []const u8 = null,
    dev_relaxed: ?bool = null,
    isolation: ?bool = null,
    freeze_prototype: ?bool = null,
};

pub fn parse(alloc: std.mem.Allocator, json: []const u8) !std.json.Parsed(Raw) {
    return std.json.parseFromSlice(Raw, alloc, json, .{ .ignore_unknown_fields = true });
}

/// 生成 `<out>` 的完整源码（不含文件头以外的元信息）。
pub fn renderZig(alloc: std.mem.Allocator, json: []const u8) ![]u8 {
    var parsed = try parse(alloc, json);
    defer parsed.deinit();
    return renderZigValue(alloc, parsed.value);
}

pub fn renderZigValue(alloc: std.mem.Allocator, raw: Raw) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\//! 由 capabilities.json 生成（v0.1.23，`zig build capabilities` 的 `ZILT_CAP_FROM`）。
        \\//! 不要手工编辑——改 JSON 后重新生成。
        \\pub const options: @import("zilt").security.Options = .{
        \\
    );

    if (raw.csp) |csp| {
        try w.writeAll("    .csp = ");
        try writeString(w, csp);
        try w.writeAll(",\n");
    }
    if (raw.headers) |headers| {
        if (headers.len > 0) {
            try w.writeAll("    .headers = &.{\n");
            for (headers) |h| {
                try w.writeAll("        .{ .name = ");
                try writeString(w, h.name);
                try w.writeAll(", .value = ");
                try writeString(w, h.value);
                try w.writeAll(" },\n");
            }
            try w.writeAll("    },\n");
        }
    }
    if (raw.navigation_origins) |origins| try writeStrList(w, "navigation_origins", origins);
    if (raw.external_links) |link| {
        const tag = switch (std.mem.eql(u8, link, "system_browser") or std.mem.eql(u8, link, "systemBrowser")) {
            true => "system_browser",
            false => if (std.mem.eql(u8, link, "allow")) "allow" else if (std.mem.eql(u8, link, "deny")) "deny" else return error.InvalidExternalLinks,
        };
        try w.print("    .external_links = .{s},\n", .{tag});
    }
    if (raw.capabilities) |caps| {
        if (caps.len > 0) {
            try w.writeAll("    .capabilities = &.{\n");
            for (caps) |c| {
                try w.writeAll("        .{ .name = ");
                try writeString(w, c.name);
                try w.writeAll(",\n");
                if (c.windows) |v| try writeStrListIndent(w, 12, "windows", v);
                if (c.local) |v| try w.print("            .local = {},\n", .{v});
                if (c.remote_origins) |v| try writeStrListIndent(w, 12, "remote_origins", v);
                if (c.commands) |v| try writeStrListIndent(w, 12, "commands", v);
                if (c.events) |v| try writeStrListIndent(w, 12, "events", v);
                if (c.receive_events) |v| try writeStrListIndent(w, 12, "receive_events", v);
                if (c.scopes) |v| try writeStrListIndent(w, 12, "scopes", v);
                try w.writeAll("        },\n");
            }
            try w.writeAll("    },\n");
        }
    }
    if (raw.deny_commands) |v| try writeStrList(w, "deny_commands", v);
    if (raw.deny_events) |v| try writeStrList(w, "deny_events", v);
    if (raw.dev_relaxed) |v| try w.print("    .dev_relaxed = {},\n", .{v});
    if (raw.isolation) |v| try w.print("    .isolation = {},\n", .{v});
    if (raw.freeze_prototype) |v| try w.print("    .freeze_prototype = {},\n", .{v});

    try w.writeAll("};\n");
    return alloc.dupe(u8, aw.written());
}

fn writeStrList(w: anytype, field: []const u8, list: []const []const u8) !void {
    if (list.len == 0) return;
    try w.print("    .{s} = ", .{field});
    try writeSlice(w, list);
    try w.writeAll(",\n");
}

fn writeStrListIndent(w: anytype, comptime indent: usize, field: []const u8, list: []const []const u8) !void {
    if (list.len == 0) return;
    var i: usize = 0;
    while (i < indent) : (i += 1) try w.writeByte(' ');
    try w.print(".{s} = ", .{field});
    try writeSlice(w, list);
    try w.writeAll(",\n");
}

fn writeSlice(w: anytype, list: []const []const u8) !void {
    try w.writeAll("&.{");
    for (list, 0..) |item, i| {
        if (i != 0) try w.writeAll(", ");
        try writeString(w, item);
    }
    try w.writeAll("}");
}

/// Zig 字符串字面量：转义 `"` `\` 与控制字符，其余原样（UTF-8 保留）。
pub fn writeString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31, 127 => try w.print("\\x{x:0>2}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

const testing = std.testing;

const sample =
    \\{
    \\  "csp": "default-src 'self'",
    \\  "headers": [{"name":"X-Test","value":"a\"b"}],
    \\  "external_links": "deny",
    \\  "capabilities": [
    \\    {"name":"fs","windows":["main"],"scopes":["fs:documents/**"]},
    \\    {"name":"net","local":false,"remote_origins":["https://api.example.com"],"scopes":["http:https://api.example.com/*"]}
    \\  ],
    \\  "deny_commands": ["blockedDemo"],
    \\  "isolation": true
    \\}
;

test "v0.1.23: json → zig 源码包含全部字段" {
    const zig = try renderZig(testing.allocator, sample);
    defer testing.allocator.free(zig);

    try testing.expect(std.mem.indexOf(u8, zig, "pub const options: @import(\"zilt\").security.Options = .{") != null);
    try testing.expect(std.mem.indexOf(u8, zig, ".csp = \"default-src 'self'\",") != null);
    try testing.expect(std.mem.indexOf(u8, zig, ".{ .name = \"X-Test\", .value = \"a\\\"b\" },") != null);
    try testing.expect(std.mem.indexOf(u8, zig, ".external_links = .deny,") != null);
    try testing.expect(std.mem.indexOf(u8, zig, ".scopes = &.{\"fs:documents/**\"},") != null);
    try testing.expect(std.mem.indexOf(u8, zig, ".local = false,") != null);
    try testing.expect(std.mem.indexOf(u8, zig, ".deny_commands = &.{\"blockedDemo\"},") != null);
    try testing.expect(std.mem.indexOf(u8, zig, ".isolation = true,") != null);
}

test "v0.1.23: 省略字段不生成（保持 Zig 默认）" {
    const zig = try renderZig(testing.allocator, "{\"capabilities\":[]}");
    defer testing.allocator.free(zig);
    try testing.expect(std.mem.indexOf(u8, zig, ".csp") == null);
    try testing.expect(std.mem.indexOf(u8, zig, ".capabilities") == null);
    try testing.expect(std.mem.indexOf(u8, zig, "freeze_prototype") == null);
}

test "v0.1.23: 非法 external_links 报错" {
    try testing.expectError(error.InvalidExternalLinks, renderZig(testing.allocator, "{\"external_links\":\"nope\"}"));
}
