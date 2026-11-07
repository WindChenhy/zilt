//! .ico 解析 + HICON 创建（纯 Zig，无资源编译器）。
//!
//! 资产表里放一个 .ico（随 dist 嵌入），运行时按目录项挑最大图像，
//! CreateIconFromResourceEx 直接从字节建立 HICON——窗口/托盘图标共用。
//! 支持 BMP 与 PNG 压缩条目（Vista+ 的 CreateIconFromResourceEx 原生支持 PNG）。

const std = @import("std");
const win32 = @import("win32.zig");

pub const Image = struct {
    /// 图像数据切片（指向 .ico 源字节，无需释放）
    data: []const u8,
    width: u32,
    height: u32,
    bit_count: u16,
};

const DIR_SIZE = 6;
const ENTRY_SIZE = 16;

/// 从 .ico 字节中挑选面积最大（同面积取位深更高）的图像。
/// 非法/截断/空返回 null；纯函数，便于单测。
pub fn pickBest(bytes: []const u8) ?Image {
    if (bytes.len < DIR_SIZE) return null;
    if (readU16(bytes, 0) != 0) return null; // reserved
    if (readU16(bytes, 2) != 1) return null; // type = icon
    const count = readU16(bytes, 4);
    if (count == 0) return null;
    if (bytes.len < DIR_SIZE + @as(usize, count) * ENTRY_SIZE) return null;

    var best: ?Image = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = DIR_SIZE + i * ENTRY_SIZE;
        const w_raw = bytes[e];
        const h_raw = bytes[e + 1];
        const w: u32 = if (w_raw == 0) 256 else w_raw;
        const h: u32 = if (h_raw == 0) 256 else h_raw;
        const bpp = readU16(bytes, e + 6);
        const size: usize = readU32(bytes, e + 8);
        const off: usize = readU32(bytes, e + 12);
        if (size == 0) continue;
        if (off > bytes.len or size > bytes.len - off) continue;
        const candidate: Image = .{
            .data = bytes[off .. off + size],
            .width = w,
            .height = h,
            .bit_count = bpp,
        };
        if (best) |b| {
            const area = w * h;
            const best_area = b.width * b.height;
            if (area > best_area or (area == best_area and bpp > b.bit_count)) best = candidate;
        } else {
            best = candidate;
        }
    }
    return best;
}

/// .ico 字节 → HICON（失败 null，调用方回退默认图标）。
pub fn createHicon(bytes: []const u8) win32.HICON {
    const img = pickBest(bytes) orelse return null;
    const mutable: [*]u8 = @constCast(img.data.ptr);
    return win32.CreateIconFromResourceEx(
        mutable,
        @intCast(img.data.len),
        1, // fIcon
        0x0003_0000,
        0,
        0,
        win32.LR_DEFAULTCOLOR,
    );
}

fn readU16(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}
fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeIco(comptime entries: []const struct { w: u8, h: u8, bpp: u16, payload: []const u8 }) [22 + 16 * entries.len + totalPayload(entries)]u8 {
    var out: [22 + 16 * entries.len + totalPayload(entries)]u8 = @splat(0);
    std.mem.writeInt(u16, out[0..2], 0, .little);
    std.mem.writeInt(u16, out[2..4], 1, .little);
    std.mem.writeInt(u16, out[4..6], @intCast(entries.len), .little);
    var off: usize = 6 + 16 * entries.len;
    for (entries, 0..) |e, i| {
        const base = 6 + i * 16;
        out[base] = e.w;
        out[base + 1] = e.h;
        out[base + 2] = 0;
        out[base + 3] = 0;
        std.mem.writeInt(u16, out[base + 4 ..][0..2], 1, .little); // planes
        std.mem.writeInt(u16, out[base + 6 ..][0..2], e.bpp, .little);
        std.mem.writeInt(u32, out[base + 8 ..][0..4], @intCast(e.payload.len), .little);
        std.mem.writeInt(u32, out[base + 12 ..][0..4], @intCast(off), .little);
        @memcpy(out[off .. off + e.payload.len], e.payload);
        off += e.payload.len;
    }
    return out;
}

fn totalPayload(comptime entries: anytype) usize {
    comptime var n: usize = 0;
    for (entries) |e| n += e.payload.len;
    return n;
}

test "pickBest: 选最大图像 + 同面积取高位深" {
    const ico = comptime makeIco(&.{
        .{ .w = 16, .h = 16, .bpp = 32, .payload = &.{ 1, 2, 3 } },
        .{ .w = 32, .h = 32, .bpp = 8, .payload = &.{ 4, 5, 6, 7 } },
        .{ .w = 32, .h = 32, .bpp = 32, .payload = &.{ 8, 9 } },
    });
    const best = pickBest(&ico).?;
    try testing.expectEqual(@as(u32, 32), best.width);
    try testing.expectEqual(@as(u16, 32), best.bit_count);
    try testing.expectEqual(@as(usize, 2), best.data.len);

    // 0 宽高 = 256
    const ico256 = comptime makeIco(&.{
        .{ .w = 0, .h = 0, .bpp = 32, .payload = &.{ 7, 8, 9 } },
    });
    try testing.expectEqual(@as(u32, 256), pickBest(&ico256).?.width);
}

test "pickBest: 非法输入返回 null" {
    try testing.expect(pickBest(&.{}) == null);
    try testing.expect(pickBest(&.{ 1, 0, 1, 0, 1, 0 }) == null); // reserved != 0
    try testing.expect(pickBest(&.{ 0, 0, 2, 0, 1, 0 }) == null); // type != 1
    // 声明 1 个条目但缺数据
    try testing.expect(pickBest(&.{ 0, 0, 1, 0, 1, 0 }) == null);
    // 偏移越界
    var bad: [22]u8 = @splat(0);
    std.mem.writeInt(u16, bad[2..4], 1, .little);
    std.mem.writeInt(u16, bad[4..6], 1, .little);
    bad[6] = 16;
    bad[7] = 16;
    std.mem.writeInt(u16, bad[12..14], 1, .little);
    std.mem.writeInt(u32, bad[14..18], 8, .little);
    std.mem.writeInt(u32, bad[18..22], 100, .little); // offset 越界
    try testing.expect(pickBest(&bad) == null);
}
