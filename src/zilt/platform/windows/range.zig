//! HTTP Range 解析（资产服务 206/416；单区间）。
//!
//! 支持 `bytes=a-b`、`bytes=a-`、`bytes=-n` 三种形式；多区间/越界/语法错误 →
//! `.invalid`（后端回 416），无 Range 头 → `.none`。

const std = @import("std");

pub const Spec = struct {
    /// 起始字节（含）
    start: u64,
    /// 结束字节（含）
    end: u64,

    pub fn len(self: Spec) u64 {
        return self.end - self.start + 1;
    }
};

pub const Result = union(enum) {
    none,
    invalid,
    ok: Spec,
};

pub fn parse(header: ?[]const u8, total: u64) Result {
    const raw = header orelse return .none;
    const h = std.mem.trim(u8, raw, " \t");
    if (h.len == 0) return .none;
    const eq = std.mem.indexOfScalar(u8, h, '=') orelse return .invalid;
    const unit = std.mem.trim(u8, h[0..eq], " \t");
    if (!std.ascii.eqlIgnoreCase(unit, "bytes")) return .invalid;
    if (std.mem.indexOfScalar(u8, h, ',') != null) return .invalid; // 多区间不支持
    if (total == 0) return .invalid;

    const spec = std.mem.trim(u8, h[eq + 1 ..], " \t");
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .invalid;
    const left = std.mem.trim(u8, spec[0..dash], " \t");
    const right = std.mem.trim(u8, spec[dash + 1 ..], " \t");

    if (left.len == 0) {
        // bytes=-n：最后 n 字节
        const n = std.fmt.parseInt(u64, right, 10) catch return .invalid;
        if (n == 0) return .invalid;
        const start = if (n >= total) 0 else total - n;
        return .{ .ok = .{ .start = start, .end = total - 1 } };
    }

    const start = std.fmt.parseInt(u64, left, 10) catch return .invalid;
    if (start >= total) return .invalid;
    var end: u64 = total - 1;
    if (right.len > 0) {
        end = std.fmt.parseInt(u64, right, 10) catch return .invalid;
        if (end < start) return .invalid;
        if (end >= total) end = total - 1;
    }
    return .{ .ok = .{ .start = start, .end = end } };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse: 常规区间" {
    const r1 = parse("bytes=0-99", 1000);
    try testing.expect(r1 == .ok);
    try testing.expectEqual(@as(u64, 0), r1.ok.start);
    try testing.expectEqual(@as(u64, 99), r1.ok.end);

    const r2 = parse("bytes=10-", 1000);
    try testing.expectEqual(@as(u64, 10), r2.ok.start);
    try testing.expectEqual(@as(u64, 999), r2.ok.end);

    const r3 = parse("BYTES = 1-2", 100); // 前缀大小写+空格
    try testing.expectEqual(@as(u64, 1), r3.ok.start);
    try testing.expectEqual(@as(u64, 2), r3.ok.end);
}

test "parse: 尾部 n 字节 / 越界截断" {
    const r1 = parse("bytes=-20", 100);
    try testing.expectEqual(@as(u64, 80), r1.ok.start);
    const r2 = parse("bytes=-200", 100);
    try testing.expectEqual(@as(u64, 0), r2.ok.start);
    const r3 = parse("bytes=90-500", 100);
    try testing.expectEqual(@as(u64, 99), r3.ok.end);
}

test "parse: none / invalid" {
    try testing.expect(parse(null, 100) == .none);
    try testing.expect(parse("   ", 100) == .none);
    try testing.expect(parse("items=0-1", 100) == .invalid);
    try testing.expect(parse("bytes=0-1,3-4", 100) == .invalid); // 多区间
    try testing.expect(parse("bytes=100-", 100) == .invalid); // start >= total
    try testing.expect(parse("bytes=5-3", 100) == .invalid); // end < start
    try testing.expect(parse("bytes=-0", 100) == .invalid);
    try testing.expect(parse("bytes=a-b", 100) == .invalid);
    try testing.expect(parse("bytes=0-1", 0) == .invalid); // 空实体
}
