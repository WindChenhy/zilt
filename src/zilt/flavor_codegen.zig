//! v0.6.0b：把 flavor overlay 的 `window` / `security` 对象生成 Zig patch 模块。
//!
//! 为什么生成源码而不是 build options：这两个对象是嵌套结构（capabilities /
//! headers 数组），build options 只能表达标量；生成模块让 `app_config` /
//! `main.zig` 在编译期把 overlay 应用到各自的基础声明上（RFC 7396 语义：
//! 数组整体替换、缺省键不覆盖）。
//!
//! 生成物固定在 `.zilt-cache-flavor/<hash>/flavor.zig`（内容寻址），由 build.zig
//! 写成真实文件后作为模块根；本模块只做纯字符串生成，便于单测。

const std = @import("std");

pub const Error = error{
    InvalidWindowOverlay,
    InvalidSecurityOverlay,
};

const AllocatorError = std.mem.Allocator.Error;

const header =
    \\//! 自动生成（v0.6.0b flavor overlay）——不要编辑。
    \\//! 由 build.zig 的 flavor 解析结果生成；源文件见 src/zilt/flavor_codegen.zig。
    \\const zilt = @import("zilt");
    \\
    \\
;

pub fn generate(alloc: std.mem.Allocator, merged: std.json.Value) (AllocatorError || Error)![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, header);

    const window_value = objectField(merged, "window") orelse null;
    const security_value = objectField(merged, "security") orelse null;

    try emitWindow(&out, alloc, window_value);
    try out.append(alloc, '\n');
    try emitSecurity(&out, alloc, security_value);

    return out.toOwnedSlice(alloc);
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

// ---------------------------------------------------------------------------
// window
// ---------------------------------------------------------------------------

const Kind = enum { string, sentinel_string, u32, i32, bool };

const Field = struct {
    name: []const u8,
    kind: Kind,
};

const window_fields = [_]Field{
    .{ .name = "title", .kind = .sentinel_string },
    .{ .name = "width", .kind = .u32 },
    .{ .name = "height", .kind = .u32 },
    .{ .name = "x", .kind = .i32 },
    .{ .name = "y", .kind = .i32 },
    .{ .name = "visible", .kind = .bool },
    .{ .name = "resizable", .kind = .bool },
    .{ .name = "decorations", .kind = .bool },
    .{ .name = "titlebar_overlay", .kind = .bool },
    .{ .name = "transparent", .kind = .bool },
    .{ .name = "always_on_top", .kind = .bool },
    .{ .name = "skip_taskbar", .kind = .bool },
    .{ .name = "close_requested_event", .kind = .bool },
    .{ .name = "url", .kind = .string },
    .{ .name = "min_width", .kind = .u32 },
    .{ .name = "min_height", .kind = .u32 },
    .{ .name = "max_width", .kind = .u32 },
    .{ .name = "max_height", .kind = .u32 },
    .{ .name = "background_color", .kind = .u32 },
};

fn emitWindow(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    value: ?std.json.Value,
) (AllocatorError || Error)!void {
    var allowed: [window_fields.len][]const u8 = undefined;
    for (window_fields, 0..) |f, i| allowed[i] = f.name;
    try validateObject(value, &allowed, error.InvalidWindowOverlay);

    try out.appendSlice(alloc,
        \\pub const window = struct {
        \\
    );

    inline for (window_fields) |f| {
        try out.appendSlice(alloc, "    pub const ");
        try out.appendSlice(alloc, f.name);
        try out.appendSlice(alloc, ": ?");
        try out.appendSlice(alloc, switch (f.kind) {
            .string => "[]const u8",
            .sentinel_string => "[:0]const u8",
            .u32 => "u32",
            .i32 => "i32",
            .bool => "bool",
        });
        try out.appendSlice(alloc, " = ");
        try emitOptionalScalar(out, alloc, value, f);
        try out.appendSlice(alloc, ";\n");
    }

    try out.appendSlice(alloc, "\n    pub fn apply(base: zilt.Config) zilt.Config {\n        var out = base;\n");
    inline for (window_fields) |f| {
        try out.appendSlice(alloc, "        if (");
        try out.appendSlice(alloc, f.name);
        try out.appendSlice(alloc, ") |v| out.");
        try out.appendSlice(alloc, f.name);
        try out.appendSlice(alloc, " = v;\n");
    }
    try out.appendSlice(alloc, "        return out;\n    }\n};\n");
}

// ---------------------------------------------------------------------------
// security
// ---------------------------------------------------------------------------

const SecurityKind = enum {
    string,
    strings,
    headers,
    external_links,
    capabilities,
    bool,
};

const SecurityField = struct {
    name: []const u8,
    kind: SecurityKind,
};

const security_fields = [_]SecurityField{
    .{ .name = "csp", .kind = .string },
    .{ .name = "headers", .kind = .headers },
    .{ .name = "navigation_origins", .kind = .strings },
    .{ .name = "external_links", .kind = .external_links },
    .{ .name = "capabilities", .kind = .capabilities },
    .{ .name = "deny_commands", .kind = .strings },
    .{ .name = "deny_events", .kind = .strings },
    .{ .name = "dev_relaxed", .kind = .bool },
    .{ .name = "isolation", .kind = .bool },
    .{ .name = "freeze_prototype", .kind = .bool },
    .{ .name = "app_schemes", .kind = .strings },
};

fn emitSecurity(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    value: ?std.json.Value,
) (AllocatorError || Error)!void {
    var allowed: [security_fields.len][]const u8 = undefined;
    for (security_fields, 0..) |f, i| allowed[i] = f.name;
    try validateObject(value, &allowed, error.InvalidSecurityOverlay);

    try out.appendSlice(alloc,
        \\pub const security = struct {
        \\
    );

    inline for (security_fields) |f| {
        try out.appendSlice(alloc, "    pub const ");
        try out.appendSlice(alloc, f.name);
        try out.appendSlice(alloc, ": ?");
        try out.appendSlice(alloc, switch (f.kind) {
            .string => "[]const u8",
            .strings => "[]const []const u8",
            .headers => "[]const zilt.security.Header",
            .external_links => "zilt.security.ExternalLinks",
            .capabilities => "[]const zilt.security.Capability",
            .bool => "bool",
        });
        try out.appendSlice(alloc, " = ");
        try emitSecurityValue(out, alloc, value, f);
        try out.appendSlice(alloc, ";\n");
    }

    try out.appendSlice(alloc, "\n    pub fn apply(base: zilt.security.Options) zilt.security.Options {\n        var out = base;\n");
    inline for (security_fields) |f| {
        try out.appendSlice(alloc, "        if (");
        try out.appendSlice(alloc, f.name);
        try out.appendSlice(alloc, ") |v| out.");
        try out.appendSlice(alloc, f.name);
        try out.appendSlice(alloc, " = v;\n");
    }
    try out.appendSlice(alloc, "        return out;\n    }\n};\n");
}

fn emitSecurityValue(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    value: ?std.json.Value,
    f: SecurityField,
) (AllocatorError || Error)!void {
    const v = fieldValue(value, f.name) orelse {
        try out.appendSlice(alloc, "null");
        return;
    };
    if (v == .null) {
        try out.appendSlice(alloc, "null");
        return;
    }
    switch (f.kind) {
        .string => {
            if (v != .string) return error.InvalidSecurityOverlay;
            try appendQuoted(out, alloc, v.string);
        },
        .strings => try emitStringArray(out, alloc, v),
        .headers => try emitHeaders(out, alloc, v),
        .external_links => try emitExternalLinks(out, alloc, v),
        .capabilities => try emitCapabilities(out, alloc, v),
        .bool => {
            if (v != .bool) return error.InvalidSecurityOverlay;
            try out.appendSlice(alloc, if (v.bool) "true" else "false");
        },
    }
}

fn emitExternalLinks(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    v: std.json.Value,
) (AllocatorError || Error)!void {
    if (v != .string) return error.InvalidSecurityOverlay;
    if (std.mem.eql(u8, v.string, "allow")) {
        try out.appendSlice(alloc, ".allow");
    } else if (std.mem.eql(u8, v.string, "system_browser")) {
        try out.appendSlice(alloc, ".system_browser");
    } else if (std.mem.eql(u8, v.string, "deny")) {
        try out.appendSlice(alloc, ".deny");
    } else {
        return error.InvalidSecurityOverlay;
    }
}

fn emitHeaders(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    v: std.json.Value,
) (AllocatorError || Error)!void {
    if (v != .array) return error.InvalidSecurityOverlay;
    try out.appendSlice(alloc, "&.{");
    for (v.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidSecurityOverlay;
        const name = item.object.get("name") orelse return error.InvalidSecurityOverlay;
        const value = item.object.get("value") orelse return error.InvalidSecurityOverlay;
        if (name != .string or value != .string) return error.InvalidSecurityOverlay;
        if (i != 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, ".{ .name = ");
        try appendQuoted(out, alloc, name.string);
        try out.appendSlice(alloc, ", .value = ");
        try appendQuoted(out, alloc, value.string);
        try out.appendSlice(alloc, " }");
    }
    try out.appendSlice(alloc, "}");
}

fn emitCapabilities(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    v: std.json.Value,
) (AllocatorError || Error)!void {
    if (v != .array) return error.InvalidSecurityOverlay;
    try out.appendSlice(alloc, "&.{");
    for (v.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidSecurityOverlay;
        if (i != 0) try out.appendSlice(alloc, ", ");
        try emitCapability(out, alloc, item.object);
    }
    try out.appendSlice(alloc, "}");
}

fn emitCapability(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    obj: std.json.ObjectMap,
) (AllocatorError || Error)!void {
    const allowed = [_][]const u8{
        "name",      "windows", "local", "remote_origins", "commands",
        "events",    "receive_events", "scopes",
    };
    try validateKeys(obj, &allowed, error.InvalidSecurityOverlay);

    const name = obj.get("name") orelse return error.InvalidSecurityOverlay;
    if (name != .string or name.string.len == 0) return error.InvalidSecurityOverlay;

    try out.appendSlice(alloc, ".{ .name = ");
    try appendQuoted(out, alloc, name.string);
    inline for ([_][]const u8{ "windows", "remote_origins", "commands", "events", "receive_events", "scopes" }) |key| {
        if (obj.get(key)) |arr| {
            try out.appendSlice(alloc, ", .");
            try out.appendSlice(alloc, key);
            try out.appendSlice(alloc, " = ");
            try emitStringArray(out, alloc, arr);
        }
    }
    if (obj.get("local")) |local| {
        if (local != .bool) return error.InvalidSecurityOverlay;
        try out.appendSlice(alloc, ", .local = ");
        try out.appendSlice(alloc, if (local.bool) "true" else "false");
    }
    try out.appendSlice(alloc, " }");
}

// ---------------------------------------------------------------------------
// 通用
// ---------------------------------------------------------------------------

fn validateObject(value: ?std.json.Value, allowed: []const []const u8, comptime err: Error) (AllocatorError || Error)!void {
    const v = value orelse return;
    if (v != .object) return err;
    try validateKeys(v.object, allowed, err);
}

fn validateKeys(obj: std.json.ObjectMap, allowed: []const []const u8, comptime err: Error) (AllocatorError || Error)!void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        var ok = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, name, key)) {
                ok = true;
                break;
            }
        }
        if (!ok) return err;
    }
}

fn fieldValue(value: ?std.json.Value, key: []const u8) ?std.json.Value {
    const v = value orelse return null;
    if (v != .object) return null;
    return v.object.get(key);
}

fn emitOptionalScalar(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    value: ?std.json.Value,
    f: Field,
) (AllocatorError || Error)!void {
    const v = fieldValue(value, f.name) orelse {
        try out.appendSlice(alloc, "null");
        return;
    };
    if (v == .null) {
        try out.appendSlice(alloc, "null");
        return;
    }
    switch (f.kind) {
        .string, .sentinel_string => {
            if (v != .string) return error.InvalidWindowOverlay;
            try appendQuoted(out, alloc, v.string);
        },
        .u32 => {
            if (v != .integer or v.integer < 0 or v.integer > std.math.maxInt(u32)) return error.InvalidWindowOverlay;
            try out.print(alloc, "{d}", .{v.integer});
        },
        .i32 => {
            if (v != .integer or v.integer < std.math.minInt(i32) or v.integer > std.math.maxInt(i32)) return error.InvalidWindowOverlay;
            try out.print(alloc, "{d}", .{v.integer});
        },
        .bool => {
            if (v != .bool) return error.InvalidWindowOverlay;
            try out.appendSlice(alloc, if (v.bool) "true" else "false");
        },
    }
}

fn emitStringArray(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    v: std.json.Value,
) (AllocatorError || Error)!void {
    if (v != .array) return error.InvalidSecurityOverlay;
    try out.appendSlice(alloc, "&.{");
    for (v.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidSecurityOverlay;
        if (i != 0) try out.appendSlice(alloc, ", ");
        try appendQuoted(out, alloc, item.string);
    }
    try out.appendSlice(alloc, "}");
}

fn appendQuoted(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    s: []const u8,
) AllocatorError!void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '"' => try out.appendSlice(alloc, "\\\""),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try out.print(alloc, "\\x{x:0>2}", .{c});
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    try out.append(alloc, '"');
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

fn parse(alloc: std.mem.Allocator, text: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    return parsed.value;
}

test "v0.6.0b codegen: window patch 生成 const + apply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const merged = try parse(a, "{\"window\":{\"title\":\"Beta \\\"App\\\"\",\"width\":1024,\"x\":-20,\"transparent\":true}}");
    const src = try generate(a, merged);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const window = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const width: ?u32 = 1024;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const x: ?i32 = -20;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const transparent: ?bool = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const title: ?[:0]const u8 = \"Beta \\\"App\\\"\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (width) |v| out.width = v;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const height: ?u32 = null;") != null);
}

test "v0.6.0b codegen: security patch（capabilities/headers/external_links）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const merged = try parse(a,
        \\{"security":{
        \\ "csp":"default-src 'self'","external_links":"system_browser",
        \\ "headers":[{"name":"X-Frame-Options","value":"DENY"}],
        \\ "capabilities":[{"name":"beta","windows":["main"],"local":false,
        \\   "commands":["greet"],"scopes":["fs:appData/**"]}],
        \\ "deny_commands":["blockedDemo"],"freeze_prototype":true}}
    );
    const src = try generate(a, merged);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const csp: ?[]const u8 = \"default-src 'self'\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const external_links: ?zilt.security.ExternalLinks = .system_browser;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const headers: ?[]const zilt.security.Header = &.{.{ .name = \"X-Frame-Options\", .value = \"DENY\" }};") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".{ .name = \"beta\", .windows = &.{\"main\"}, .commands = &.{\"greet\"}, .scopes = &.{\"fs:appData/**\"}, .local = false }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const deny_commands: ?[]const []const u8 = &.{\"blockedDemo\"};") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const freeze_prototype: ?bool = true;") != null);
}

test "v0.6.0b codegen: 未知键 / 类型错误明确报错" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad_window = try parse(a, "{\"window\":{\"widht\":1024}}");
    try std.testing.expectError(error.InvalidWindowOverlay, generate(a, bad_window));

    const bad_security = try parse(a, "{\"security\":{\"csp\":5}}");
    try std.testing.expectError(error.InvalidSecurityOverlay, generate(a, bad_security));

    const missing_name = try parse(a, "{\"security\":{\"capabilities\":[{\"commands\":[\"x\"]}]}}");
    try std.testing.expectError(error.InvalidSecurityOverlay, generate(a, missing_name));

    const empty = try parse(a, "{}");
    const src = try generate(a, empty);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const window = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const security = struct") != null);
}
