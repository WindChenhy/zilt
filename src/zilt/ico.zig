//! ICO 编码器（v0.1.16 图标 CLI 用）：RGBA8 → 多尺寸 .ico。
//!
//! 全部条目用 BMP（BITMAPINFOHEADER 双高度 + BGRA + AND mask）——PNG 条目
//! 需要压缩编码器，体积差在图标场景可忽略；BMP 条目兼容性最好。

const std = @import("std");
const png = @import("png.zig");

/// 多尺寸 ICO。sizes 任意（常用 16/24/32/48/64/128/256）。
/// 全程最近邻缩放；输出调用方 free。
pub fn encodeIco(alloc: std.mem.Allocator, img: png.Image, sizes: []const u32) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    // ICONDIR
    try out.appendSlice(alloc, &[_]u8{ 0, 0 }); // reserved
    try out.appendSlice(alloc, &[_]u8{ 1, 0 }); // type = icon
    const count_b: [2]u8 = .{ @intCast(sizes.len & 0xFF), 0 };
    try out.appendSlice(alloc, &count_b);

    // 目录区（先算每条目的 BMP 大小）
    const Header = struct { size: u32, w: u8 };
    var headers: std.ArrayListUnmanaged(Header) = .empty;
    defer headers.deinit(alloc);
    for (sizes) |s| {
        const dim = dimOf(img, s);
        const bmp_len: u32 = bmpEntryLen(dim, dim);
        try headers.append(alloc, .{ .size = bmp_len, .w = @intCast(dim & 0xFF) });
    }

    var offset: u32 = 6 + @as(u32, @intCast(16 * sizes.len));
    for (sizes, headers.items) |s, hdr| {
        _ = s;
        try out.appendSlice(alloc, &[_]u8{hdr.w}); // width（256 记 0）
        try out.appendSlice(alloc, &[_]u8{hdr.w}); // height
        try out.appendSlice(alloc, &[_]u8{ 0, 0 }); // palette / reserved
        try out.appendSlice(alloc, &[_]u8{ 1, 0 }); // planes
        try out.appendSlice(alloc, &[_]u8{ 32, 0 }); // bpp
        var size_b: [4]u8 = undefined;
        std.mem.writeInt(u32, &size_b, hdr.size, .little);
        try out.appendSlice(alloc, &size_b);
        var off_b: [4]u8 = undefined;
        std.mem.writeInt(u32, &off_b, offset, .little);
        try out.appendSlice(alloc, &off_b);
        offset += hdr.size;
    }

    // 条目数据
    for (sizes) |s| {
        const dim = dimOf(img, s);
        const scaled = try png.resizeNearest(alloc, img, dim, dim);
        defer alloc.free(scaled.pixels);
        try appendBmpEntry(alloc, &out, scaled);
    }
    return out.toOwnedSlice(alloc);
}

fn dimOf(img: png.Image, s: u32) u32 {
    return if (s == 0) @max(img.width, img.height) else s;
}

fn bmpEntryLen(w: u32, h: u32) u32 {
    const px_len: u32 = @intCast(w * h * 4);
    // AND mask：每行按 4 字节对齐，全 0（不透明由 alpha 承担）
    const mask_row = (w + 31) / 32 * 4;
    return 40 + px_len + @as(u32, @intCast(mask_row * h));
}

fn appendBmpEntry(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), img: png.Image) !void {
    // BITMAPINFOHEADER（height = 图高 ×2，ICON 惯例：XOR + AND 两块）
    var bi: [40]u8 = @splat(0);
    std.mem.writeInt(u32, bi[0..4], 40, .little);
    std.mem.writeInt(i32, bi[4..8], @intCast(img.width), .little);
    std.mem.writeInt(i32, bi[8..12], @intCast(@as(i32, @intCast(img.height)) * 2), .little);
    std.mem.writeInt(u16, bi[12..14], 1, .little); // planes
    std.mem.writeInt(u16, bi[14..16], 32, .little); // bpp
    try out.appendSlice(alloc, &bi);

    // XOR：BGRA 自底向上
    var y: usize = img.height;
    while (y > 0) {
        y -= 1;
        var x: usize = 0;
        while (x < img.width) : (x += 1) {
            const px = img.pixels[(y * @as(usize, img.width) + x) * 4 ..][0..4];
            try out.appendSlice(alloc, &[_]u8{ px[2], px[1], px[0], px[3] });
        }
    }

    // AND mask：全 0（行按 4 字节对齐）
    const mask_row: usize = (img.width + 31) / 32 * 4;
    const zeros = try alloc.alloc(u8, mask_row);
    defer alloc.free(zeros);
    @memset(zeros, 0);
    var rows: usize = 0;
    while (rows < img.height) : (rows += 1) {
        try out.appendSlice(alloc, zeros);
    }
}

const testing = std.testing;

test "encodeIco produces valid icondir and entry sizes" {
    const img = png.Image{ .width = 4, .height = 4, .pixels = try testing.allocator.alloc(u8, 4 * 4 * 4) };
    defer testing.allocator.free(img.pixels);
    @memset(img.pixels, 0xAA);

    const ico = try encodeIco(testing.allocator, img, &.{ 16, 32 });
    defer testing.allocator.free(ico);

    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, ico[0..2], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ico[2..4], .little));
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, ico[4..6], .little));
    // 第一个条目：16x16 32bpp
    try testing.expectEqual(@as(u8, 16), ico[6]);
    try testing.expectEqual(@as(u8, 16), ico[7]);
    try testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, ico[12..14], .little));
    // 条目数据偏移 = 6 + 16*2
    const off1 = std.mem.readInt(u32, ico[18..22], .little);
    try testing.expectEqual(@as(u32, 6 + 32), off1);
    // BITMAPINFOHEADER 高度 = 16*2
    const bi_h = std.mem.readInt(i32, ico[off1 + 8 ..][0..4], .little);
    try testing.expectEqual(@as(i32, 32), bi_h);
}
