//! v0.1.17：SQL（SQLite）纯逻辑层。
//!
//! 实际的 sqlite3.dll 动态加载与 FFI 调用在平台层（Windows:
//! platform/windows/sqlite.zig，对齐 WebView2 loader 模式 —— 运行时发现、
//! 不静态链接）。本模块只包含跨平台的数据结构与行序列化，保证可单测。

const std = @import("std");

/// 绑定参数 / 结果值。用 kind + 可选字段的普通结构（而非 tagged union）——
/// std.json 对 void 载荷的 union 无法从 JSON 还原（"nul" / {"nul":null} 都失败，
/// 实测确认），结构形态对前端最友好：{kind:'text',text:'a'} / {kind:'int',int:1}
/// / {kind:'nul'}。
pub const SqlValue = struct {
    kind: Kind = .text,
    text: ?[]const u8 = null,
    int: i64 = 0,
    real: f64 = 0,

    pub const Kind = enum { text, int, real, nul };

    pub fn textOf(s: []const u8) SqlValue {
        return .{ .kind = .text, .text = s };
    }
    pub fn intOf(v: i64) SqlValue {
        return .{ .kind = .int, .int = v };
    }
    pub fn realOf(v: f64) SqlValue {
        return .{ .kind = .real, .real = v };
    }
    pub fn nul() SqlValue {
        return .{ .kind = .nul };
    }
};

/// 一次 query 的结果（全部内存归调用方 allocator）。
pub const QueryOutput = struct {
    columns: []const []const u8 = &.{},
    rows: []const []const SqlValue = &.{},
};

pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;
pub const SQLITE_OK: c_int = 0;
/// sqlite3_open_v2 flags：READWRITE | CREATE
pub const OPEN_FLAGS: c_int = 0x2 | 0x4;

/// 列值 → JSON 标量（不带列名）。
pub fn appendValueJson(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: SqlValue) !void {
    switch (v.kind) {
        .nul => try out.appendSlice(alloc, "null"),
        .int => try out.print(alloc, "{d}", .{v.int}),
        .real => try out.print(alloc, "{d}", .{v.real}),
        .text => {
            try out.append(alloc, '"');
            try appendJsonEscaped(out, alloc, v.text orelse "");
            try out.append(alloc, '"');
        },
    }
}

/// 行集 → JSON 数组（[{"col":v,...},...]）。
pub fn serializeRows(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), q: QueryOutput) !void {
    try out.append(alloc, '[');
    for (q.rows, 0..) |row, ri| {
        if (ri != 0) try out.append(alloc, ',');
        try out.append(alloc, '{');
        for (row, 0..) |v, ci| {
            if (ci != 0) try out.append(alloc, ',');
            try out.append(alloc, '"');
            const name = if (ci < q.columns.len) q.columns[ci] else "";
            try appendJsonEscaped(out, alloc, name);
            try out.appendSlice(alloc, "\":");
            try appendValueJson(out, alloc, v);
        }
        try out.append(alloc, '}');
    }
    try out.append(alloc, ']');
}

/// 最小 JSON 字符串转义（对齐 std.json：控制字符 \\u00XX）。
pub fn appendJsonEscaped(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.print(alloc, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
}

test "serializeRows builds named JSON array" {
    const a = std.testing.allocator;
    const columns = [_][]const u8{ "id", "name", "score" };
    const r0 = [_]SqlValue{ SqlValue.intOf(1), SqlValue.textOf("Alice"), SqlValue.realOf(9.5) };
    const r1 = [_]SqlValue{ SqlValue.intOf(2), SqlValue.textOf("Bo\"b"), SqlValue.nul() };
    const rows = [_][]const SqlValue{ &r0, &r1 };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try serializeRows(a, &out, .{ .columns = &columns, .rows = &rows });
    try std.testing.expectEqualStrings(
        \\[{"id":1,"name":"Alice","score":9.5},{"id":2,"name":"Bo\"b","score":null}]
    , out.items);
    // 产出必须是合法 JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}

test "appendJsonEscaped handles control chars" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendJsonEscaped(&out, a, "a\x01\n\\\"");
    try std.testing.expectEqualStrings("a\\u0001\\n\\\\\\\"", out.items);
}
