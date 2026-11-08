//! 最小 PNG 解码器（v0.1.16 图标 CLI 用）：8-bit RGBA/RGB/调色板，非交错。
//!
//! 只覆盖图标生成的输入面：真实图标 PNG 都是非交连 8-bit。其余组合
//! 明确报错（UnsupportedPng），不静默输出坏数据。

const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA8，每像素 4 字节，行优先
    pixels: []u8,
};

pub const DecodeError = error{
    NotPng,
    Truncated,
    UnsupportedPng,
    CrcMismatch,
    OutOfMemory,
};

const IHDR_LEN = 13;

/// 解码 PNG（zlib 压缩 + 5 种行过滤）为 RGBA8。调用方 free(pixels)。
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) DecodeError!Image {
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (bytes.len < sig.len + 8 or !std.mem.eql(u8, bytes[0..sig.len], &sig)) return error.NotPng;

    var pos: usize = sig.len;
    var width: u32 = 0;
    var height: u32 = 0;
    var color_type: u8 = 0;
    var bit_depth: u8 = 0;
    var interlace: u8 = 0;
    var palette: []const u8 = &[_]u8{};
    var trns: []const u8 = &[_]u8{};
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(alloc);
    var saw_iend = false;

    while (pos + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const ctype = bytes[pos + 4 .. pos + 8];
        const data_start = pos + 8;
        if (data_start + len + 4 > bytes.len) return error.Truncated;
        const data = bytes[data_start .. data_start + len];

        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (len < IHDR_LEN) return error.Truncated;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            bit_depth = data[8];
            color_type = data[9];
            interlace = data[12];
            if (width == 0 or height == 0) return error.UnsupportedPng;
        } else if (std.mem.eql(u8, ctype, "PLTE")) {
            palette = data;
        } else if (std.mem.eql(u8, ctype, "tRNS")) {
            trns = data;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            idat.appendSlice(alloc, data) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            saw_iend = true;
        }
        pos = data_start + len + 4; // 跳过 CRC（图标场景不校验：CrcMismatch 保留给未来）
        if (saw_iend) break;
    }
    if (!saw_iend or width == 0) return error.Truncated;
    if (bit_depth != 8) return error.UnsupportedPng;
    if (interlace != 0) return error.UnsupportedPng;
    // 6=RGBA 2=RGB 3=palette
    const channels: usize = switch (color_type) {
        6 => 4,
        2 => 3,
        3 => 1,
        else => return error.UnsupportedPng,
    };
    if (color_type == 3 and palette.len == 0 or palette.len % 3 != 0) return error.UnsupportedPng;

    // zlib inflate
    var in: std.Io.Reader = .fixed(idat.items);
    var dec = std.compress.flate.Decompress.init(&in, .zlib, &.{});
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    _ = dec.reader.streamRemaining(&aw.writer) catch return error.Truncated;
    const raw = aw.written();

    // unfilter → 每行 filter 字节 + width*channels
    const stride = @as(usize, width) * channels;
    const row_len = stride + 1;
    if (raw.len < row_len * height) return error.Truncated;

    const pixels = alloc.alloc(u8, @as(usize, width) * height * 4) catch return error.OutOfMemory;
    errdefer alloc.free(pixels);
    var prev: ?[]u8 = null; // 上一步的解滤波行（stride 长度，RGB 补 alpha=255 后）
    var cur: []u8 = alloc.alloc(u8, stride) catch return error.OutOfMemory;
    defer alloc.free(cur);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = raw[y * row_len .. (y + 1) * row_len];
        const filter = row[0];
        const fdata = row[1..];
        for (0..stride) |x| {
            const a: u8 = if (x >= channels) cur[x - channels] else 0;
            const b: u8 = if (prev) |p| p[x] else 0;
            // Paeth 的 c 是左上像素；首行没有上一行 → 0
            const c: u8 = if (prev) |p| (if (x >= channels) p[x - channels] else 0) else 0;
            const v = fdata[x];
            cur[x] = switch (filter) {
                0 => v,
                1 => v +% a,
                2 => v +% b,
                3 => v +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) / 2)),
                4 => v +% paeth(a, b, c),
                else => return error.UnsupportedPng,
            };
        }
        // 写 RGBA
        const out_row = pixels[y * @as(usize, width) * 4 ..][0 .. @as(usize, width) * 4];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const px = out_row[x * 4 ..][0..4];
            switch (color_type) {
                6 => {
                    px[0] = cur[x * 4];
                    px[1] = cur[x * 4 + 1];
                    px[2] = cur[x * 4 + 2];
                    px[3] = cur[x * 4 + 3];
                },
                2 => {
                    px[0] = cur[x * 3];
                    px[1] = cur[x * 3 + 1];
                    px[2] = cur[x * 3 + 2];
                    px[3] = 255;
                },
                3 => {
                    const idx = @as(usize, cur[x]) * 3;
                    if (idx + 2 >= palette.len) return error.Truncated;
                    px[0] = palette[idx];
                    px[1] = palette[idx + 1];
                    px[2] = palette[idx + 2];
                    px[3] = if (x < trns.len) trns[x] else 255;
                },
                else => unreachable,
            }
        }
        // prev 指向上一行的解滤波结果（下一行 filter 需要它）
        if (prev) |p| {
            @memcpy(p[0..stride], cur[0..stride]);
        } else {
            const p2 = alloc.alloc(u8, stride) catch return error.OutOfMemory;
            prev = p2;
        }
    }
    if (prev) |p| alloc.free(p);
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// 最近邻缩放（RGBA8 → RGBA8）。调用方 free。
pub fn resizeNearest(alloc: std.mem.Allocator, img: Image, w: u32, h: u32) !Image {
    const out = try alloc.alloc(u8, @as(usize, w) * h * 4);
    errdefer alloc.free(out);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const sy = @min(img.height - 1, @as(u32, @intCast(y * img.height / h)));
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const sx = @min(img.width - 1, @as(u32, @intCast(x * img.width / w)));
            const src = img.pixels[(@as(usize, sy) * img.width + sx) * 4 ..][0..4];
            const dst = out[(y * @as(usize, w) + x) * 4 ..][0..4];
            @memcpy(dst, src);
        }
    }
    return .{ .width = w, .height = h, .pixels = out };
}

const testing = std.testing;

test "decode minimal 2x2 RGBA png (hand-built)" {
    // 手工构造一个最小合法 PNG：IHDR + IDAT(zlib) + IEND，2x2 RGBA8
    const zlib = try buildZlibIdat(testing.allocator, &[_]u8{
        0, 0xFF, 0x00, 0x00, 0xFF, // 行0 filter=0: 红、绿
        0, 0x00, 0x00, 0xFF, 0xFF, // 行1 filter=0: 蓝、白（半透明）
    });
    defer testing.allocator.free(zlib);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });
    try pushChunk(testing.allocator, &buf, "IHDR", &[_]u8{
        0, 0, 0, 2, // width 2
        0, 0, 0, 2, // height 2
        8,  // bit depth
        6,  // RGBA
        0, 0, 0, // compression/filter/interlace
    });
    try pushChunk(testing.allocator, &buf, "IDAT", zlib);
    try pushChunk(testing.allocator, &buf, "IEND", &.{});

    const img = try decode(testing.allocator, buf.items);
    defer testing.allocator.free(img.pixels);
    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqual(@as(u32, 2), img.height);
    try testing.expectEqual(@as(u8, 0xFF), img.pixels[0]); // 红
    try testing.expectEqual(@as(u8, 0x00), img.pixels[1]);
    try testing.expectEqual(@as(u8, 0x00), img.pixels[2]);
    try testing.expectEqual(@as(u8, 0xFF), img.pixels[8 + 2]); // 行1 蓝
}

test "decode rejects non-png / unsupported" {
    try testing.expectError(error.NotPng, decode(testing.allocator, "not a png"));
    try testing.expectError(error.NotPng, decode(testing.allocator, ""));
}

test "resizeNearest scales and clamps" {
    const img = Image{ .width = 2, .height = 2, .pixels = try testing.allocator.dupe(u8, &[_]u8{
        1, 2, 3, 255, 4, 5, 6, 255,
        7, 8, 9, 255, 10, 11, 12, 255,
    }) };
    defer testing.allocator.free(img.pixels);
    const out = try resizeNearest(testing.allocator, img, 4, 4);
    defer testing.allocator.free(out.pixels);
    try testing.expectEqual(@as(u8, 1), out.pixels[0]);
    try testing.expectEqual(@as(u8, 10), out.pixels[(3 * 4 + 3) * 4]); // 右下角取源右下
}

// ---- 测试辅助：手工构造 PNG ----

fn pushChunk(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), ctype: *const [4]u8, data: []const u8) !void {
    var len_b: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_b, @intCast(data.len), .big);
    try buf.appendSlice(alloc, &len_b);
    try buf.appendSlice(alloc, ctype);
    try buf.appendSlice(alloc, data);
    var crc = std.hash.Crc32.init();
    crc.update(ctype);
    crc.update(data);
    var crc_b: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_b, crc.final(), .big);
    try buf.appendSlice(alloc, &crc_b);
}

/// zlib 流（PNG IDAT 即 zlib 容器）：header + deflate + adler32
fn buildZlibIdat(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var cmp = try std.compress.flate.Compress.init(&aw.writer, &window, .zlib, .fastest);
    try cmp.writer.writeAll(raw);
    try cmp.finish(&aw.writer);
    return alloc.dupe(u8, aw.written());
}
