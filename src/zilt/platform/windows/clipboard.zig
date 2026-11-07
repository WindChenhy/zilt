//! Windows clipboard formats, independent of the backend/message dispatcher.
//! Link user32 and kernel32. Call with the window's HWND on its owning thread.
//! Listening posts WM_CLIPBOARDUPDATE (0x031D) to that window; stop before destroy.
//! Tests exercise only in-memory codecs and never access the live clipboard.

const std = @import("std");
const types = @import("../../clipboard.zig");
pub const Data = types.Data;
pub const Format = types.Format;
pub const Image = types.Image;
const Allocator = std.mem.Allocator;
const HWND = ?*anyopaque;
const HANDLE = *anyopaque;
const WINAPI: std.builtin.CallingConvention = if (@import("builtin").cpu.arch == .x86) .{ .x86_stdcall = .{} } else .c;

extern "user32" fn OpenClipboard(hwnd: HWND) callconv(WINAPI) i32;
extern "user32" fn CloseClipboard() callconv(WINAPI) i32;
extern "user32" fn EmptyClipboard() callconv(WINAPI) i32;
extern "user32" fn IsClipboardFormatAvailable(format: u32) callconv(WINAPI) i32;
extern "user32" fn GetClipboardData(format: u32) callconv(WINAPI) ?HANDLE;
extern "user32" fn SetClipboardData(format: u32, memory: HANDLE) callconv(WINAPI) ?HANDLE;
extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(WINAPI) u32;
extern "user32" fn AddClipboardFormatListener(hwnd: HWND) callconv(WINAPI) i32;
extern "user32" fn RemoveClipboardFormatListener(hwnd: HWND) callconv(WINAPI) i32;
extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn GlobalFree(memory: HANDLE) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn GlobalLock(memory: HANDLE) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(memory: HANDLE) callconv(WINAPI) i32;
extern "kernel32" fn GlobalSize(memory: HANDLE) callconv(WINAPI) usize;

const CF_DIB: u32 = 8;
const CF_UNICODETEXT: u32 = 13;
const CF_HDROP: u32 = 15;
const CF_DIBV5: u32 = 17;
const GMEM_MOVEABLE: u32 = 0x0002;

fn htmlFormat() !u32 {
    const id = RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("HTML Format"));
    if (id == 0) return error.RegisterFormatFailed;
    return id;
}

pub fn startListening(hwnd: HWND) !void {
    if (hwnd == null) return error.InvalidWindow;
    if (AddClipboardFormatListener(hwnd) == 0) return error.ClipboardListenerFailed;
}

pub fn stopListening(hwnd: HWND) void {
    if (hwnd != null) _ = RemoveClipboardFormatListener(hwnd);
}

const Transfer = struct {
    format: u32,
    handle: ?HANDLE,

    fn init(format: u32, bytes: []const u8) !Transfer {
        const h = GlobalAlloc(GMEM_MOVEABLE, bytes.len) orelse return error.OutOfMemory;
        errdefer _ = GlobalFree(h);
        const locked = GlobalLock(h) orelse return error.GlobalLockFailed;
        @memcpy(@as([*]u8, @ptrCast(locked))[0..bytes.len], bytes);
        _ = GlobalUnlock(h);
        return .{ .format = format, .handle = h };
    }

    fn deinit(self: *Transfer) void {
        if (self.handle) |h| _ = GlobalFree(h);
    }

    fn publish(self: *Transfer) !void {
        if (SetClipboardData(self.format, self.handle.?) == null) return error.SetClipboardDataFailed;
        self.handle = null; // Windows now owns the movable allocation.
    }
};

/// Replaces the clipboard with one value. Images publish alpha-preserving
/// CF_DIBV5 plus an opaque CF_DIB fallback for legacy consumers. Input is borrowed.
/// All encoding/allocation precedes EmptyClipboard; a later OS publication error
/// can still leave the clipboard empty or partially published (Win32 is not atomic).
pub fn write(alloc: Allocator, hwnd: HWND, data: Data) !void {
    // OpenClipboard(NULL) followed by EmptyClipboard cannot establish an owner.
    if (hwnd == null) return error.InvalidWindow;
    const format = switch (data) {
        .text => CF_UNICODETEXT,
        .html => try htmlFormat(),
        .image => CF_DIBV5,
        .files => CF_HDROP,
    };
    const bytes = switch (data) {
        .text => |text| try encodeText(alloc, text),
        .html => |html| try encodeHtml(alloc, html),
        .image => |image| try encodeDib(alloc, image, true),
        .files => |files| try encodeFiles(alloc, files),
    };
    defer alloc.free(bytes);
    var primary = try Transfer.init(format, bytes);
    defer primary.deinit();
    var fallback: ?Transfer = null;
    defer if (fallback) |*transfer| transfer.deinit();
    if (data == .image) {
        const dib = try encodeDib(alloc, data.image, false);
        defer alloc.free(dib);
        fallback = try Transfer.init(CF_DIB, dib);
    }
    if (OpenClipboard(hwnd) == 0) return error.ClipboardBusy;
    defer _ = CloseClipboard();
    if (EmptyClipboard() == 0) return error.EmptyClipboardFailed;
    try primary.publish();
    if (fallback) |*transfer| try transfer.publish();
}

/// Returns null only when the requested format is absent. Malformed/unsupported
/// payloads and OS failures are errors. Returned slices all belong to alloc.
/// Image reads prefer CF_DIBV5, falling back to CF_DIB when V5 is unavailable.
pub fn read(alloc: Allocator, hwnd: HWND, format: Format) !?Data {
    var id: u32 = switch (format) {
        .text => CF_UNICODETEXT,
        .html => try htmlFormat(),
        .image => CF_DIBV5,
        .files => CF_HDROP,
    };
    if (OpenClipboard(hwnd) == 0) return error.ClipboardBusy;
    defer _ = CloseClipboard();
    if (format == .image and IsClipboardFormatAvailable(id) == 0) id = CF_DIB;
    if (IsClipboardFormatAvailable(id) == 0) return null;
    const h = GetClipboardData(id) orelse return error.GetClipboardDataFailed;
    const size = GlobalSize(h);
    if (size == 0) return error.InvalidData;
    const locked = GlobalLock(h) orelse return error.GlobalLockFailed;
    defer _ = GlobalUnlock(h);
    const bytes = @as([*]const u8, @ptrCast(locked))[0..size];
    return switch (format) {
        .text => .{ .text = try decodeText(alloc, bytes) },
        .html => .{ .html = try decodeHtml(alloc, bytes) },
        .image => .{ .image = try decodeDib(alloc, bytes) },
        .files => .{ .files = try decodeFiles(alloc, bytes) },
    };
}

/// Only pass values returned by read, once, with the same allocator.
pub fn free(alloc: Allocator, data: Data) void {
    switch (data) {
        .text, .html => |bytes| alloc.free(bytes),
        .image => |image| alloc.free(image.rgba),
        .files => |files| {
            for (files) |path| alloc.free(path);
            alloc.free(files);
        },
    }
}

// Untrusted data is read bytewise: no alignment assumptions or sentinel scans.
fn add(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.InvalidData;
}

fn mul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch error.InvalidData;
}

fn get(comptime T: type, bytes: []const u8, offset: usize) !T {
    const n = @sizeOf(T);
    if (offset > bytes.len or n > bytes.len - offset) return error.InvalidData;
    return std.mem.readInt(T, bytes[offset..][0..n], .little);
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn validateUtf8(text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
}

fn encodeText(alloc: Allocator, text: []const u8) ![]u8 {
    try validateUtf8(text);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
    defer alloc.free(wide);
    const bytes = try alloc.alloc(u8, try mul(try add(wide.len, 1), 2));
    for (wide, 0..) |unit, i| put(u16, bytes, i * 2, unit);
    put(u16, bytes, wide.len * 2, 0);
    return bytes;
}

fn wideEnd(bytes: []const u8, start: usize) !usize {
    var end = start;
    while (end <= bytes.len and bytes.len - end >= 2) : (end += 2) {
        if (try get(u16, bytes, end) == 0) return end;
    }
    return error.InvalidData;
}

fn decodeWide(alloc: Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len % 2 != 0) return error.InvalidData;
    const wide = try alloc.alloc(u16, bytes.len / 2);
    defer alloc.free(wide);
    for (wide, 0..) |*unit, i| unit.* = try get(u16, bytes, i * 2);
    return std.unicode.utf16LeToUtf8Alloc(alloc, wide) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf16,
    };
}

fn decodeText(alloc: Allocator, bytes: []const u8) ![]u8 {
    return decodeWide(alloc, bytes[0..try wideEnd(bytes, 0)]);
}

const html_header = "Version:1.0\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n";
const html_prefix = "<html><body><!--StartFragment-->";
const html_suffix = "<!--EndFragment--></body></html>";

fn encodeHtml(alloc: Allocator, fragment: []const u8) ![]u8 {
    try validateUtf8(fragment);
    const start_fragment = html_header.len + html_prefix.len;
    const end_fragment = try add(start_fragment, fragment.len);
    const end_html = try add(end_fragment, html_suffix.len);
    if (@as(u64, end_html) > 9_999_999_999) return error.InvalidData;
    const out = try alloc.alloc(u8, try add(end_html, 1));
    errdefer alloc.free(out);
    _ = try std.fmt.bufPrint(out[0..html_header.len], "Version:1.0\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\nStartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n", .{ html_header.len, end_html, start_fragment, end_fragment });
    @memcpy(out[html_header.len..start_fragment], html_prefix);
    @memcpy(out[start_fragment..end_fragment], fragment);
    @memcpy(out[end_fragment..end_html], html_suffix);
    out[end_html] = 0;
    return out;
}

fn decodeHtml(alloc: Allocator, bytes: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, bytes, "Version:")) return error.InvalidData;
    const names = [_][]const u8{ "StartHTML:", "EndHTML:", "StartFragment:", "EndFragment:", "StartSelection:", "EndSelection:" };
    var offsets: [6]?i64 = @splat(null);
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        if (offsets[0]) |start| {
            if (start >= 0 and cursor >= @as(u64, @intCast(start))) break;
        }
        const end = cursor + (std.mem.indexOfAny(u8, bytes[cursor..], "\r\n") orelse break);
        const line = bytes[cursor..end];
        var recognized = false;
        for (names, 0..) |name, i| {
            if (std.mem.startsWith(u8, line, name)) {
                if (offsets[i] != null) return error.InvalidData;
                offsets[i] = std.fmt.parseInt(i64, std.mem.trim(u8, line[name.len..], " \t"), 10) catch return error.InvalidData;
                recognized = true;
                break;
            }
        }
        if (!recognized and !std.mem.startsWith(u8, line, "Version:") and
            !std.mem.startsWith(u8, line, "SourceURL:")) break;
        cursor = end + 1;
        if (bytes[end] == '\r' and cursor < bytes.len and bytes[cursor] == '\n') cursor += 1;
    }
    for (offsets[0..4]) |value| if (value == null) return error.InvalidData;
    const sh = offsets[0].?;
    const eh = offsets[1].?;
    const sf = std.math.cast(usize, offsets[2].?) orelse return error.InvalidData;
    const ef = std.math.cast(usize, offsets[3].?) orelse return error.InvalidData;
    if (sf < cursor or sf > ef or ef > bytes.len) return error.InvalidData;
    // -1/-1 is the CF_HTML representation of an omitted surrounding context.
    if (sh == -1 and eh == -1) {
        // Fragment bounds remain mandatory even without a context.
    } else {
        const start = std.math.cast(usize, sh) orelse return error.InvalidData;
        const end = std.math.cast(usize, eh) orelse return error.InvalidData;
        if (start < cursor or start > sf or ef > end or end > bytes.len) return error.InvalidData;
        try validateUtf8(bytes[start..end]);
    }
    if (offsets[4] != null or offsets[5] != null) {
        const start = std.math.cast(usize, offsets[4] orelse return error.InvalidData) orelse return error.InvalidData;
        const end = std.math.cast(usize, offsets[5] orelse return error.InvalidData) orelse return error.InvalidData;
        if (start < sf or start > end or end > ef) return error.InvalidData;
        try validateUtf8(bytes[start..end]);
    }
    try validateUtf8(bytes[sf..ef]);
    return alloc.dupe(u8, bytes[sf..ef]);
}

fn encodeFiles(alloc: Allocator, files: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendNTimes(alloc, 0, 20); // DROPFILES: pFiles, POINT, fNC, fWide.
    put(u32, out.items, 0, 20);
    put(u32, out.items, 16, 1);
    for (files) |path| {
        if (path.len == 0) return error.InvalidData;
        const encoded = try encodeText(alloc, path);
        defer alloc.free(encoded);
        try out.appendSlice(alloc, encoded);
    }
    try out.appendNTimes(alloc, 0, if (files.len == 0) 4 else 2);
    return out.toOwnedSlice(alloc);
}

fn decodeFiles(alloc: Allocator, bytes: []const u8) ![]const []const u8 {
    if (bytes.len < 20) return error.InvalidData;
    const start: usize = try get(u32, bytes, 0);
    if (start < 20 or start > bytes.len or start % 2 != 0) return error.InvalidData;
    if (try get(u32, bytes, 16) == 0) return error.UnsupportedFormat; // ANSI DROPFILES.
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |path| alloc.free(path);
        out.deinit(alloc);
    }
    var cursor = start;
    while (true) {
        const end = try wideEnd(bytes, cursor);
        if (end == cursor) {
            if (out.items.len == 0 and try get(u16, bytes, try add(cursor, 2)) != 0) return error.InvalidData;
            return out.toOwnedSlice(alloc);
        }
        const path = try decodeWide(alloc, bytes[cursor..end]);
        errdefer alloc.free(path);
        try out.append(alloc, path);
        cursor = end + 2;
    }
}

fn encodeDib(alloc: Allocator, image: Image, v5: bool) ![]u8 {
    if (image.width == 0 or image.height == 0 or image.width > std.math.maxInt(i32) or image.height > std.math.maxInt(i32)) return error.InvalidData;
    const stride = try mul(image.width, 4);
    const size = try mul(stride, image.height);
    if (size != image.rgba.len or size > std.math.maxInt(u32)) return error.InvalidData;
    const header: usize = if (v5) 124 else 40;
    const out = try alloc.alloc(u8, try add(header, size));
    @memset(out, 0);
    put(u32, out, 0, @intCast(header));
    put(u32, out, 4, image.width);
    const height: i32 = @intCast(image.height);
    put(i32, out, 8, if (v5) -height else height);
    put(u16, out, 12, 1);
    put(u16, out, 14, 32);
    put(u32, out, 16, if (v5) 3 else 0); // BI_BITFIELDS / BI_RGB.
    put(u32, out, 20, @intCast(size));
    if (v5) {
        put(u32, out, 40, 0x00ff0000);
        put(u32, out, 44, 0x0000ff00);
        put(u32, out, 48, 0x000000ff);
        put(u32, out, 52, 0xff000000);
        put(u32, out, 56, 0x73524742); // LCS_sRGB.
        put(u32, out, 108, 4); // LCS_GM_IMAGES.
    }
    for (0..image.height) |y| {
        const dst_y = if (v5) y else image.height - 1 - y;
        for (0..image.width) |x| {
            const src = y * stride + x * 4;
            const dst = header + dst_y * stride + x * 4;
            out[dst..][0..4].* = .{ image.rgba[src + 2], image.rgba[src + 1], image.rgba[src], if (v5) image.rgba[src + 3] else 0 };
        }
    }
    return out;
}

fn validateMasks(masks: [4]u32) !void {
    var used: u32 = 0;
    for (masks, 0..) |mask, i| {
        if (mask == 0) {
            if (i < 3) return error.InvalidData;
            continue;
        }
        if (used & mask != 0) return error.InvalidData;
        used |= mask;
        const shifted = mask >> @as(u5, @intCast(@ctz(mask)));
        if (shifted & (shifted +% 1) != 0) return error.InvalidData;
    }
}

fn channel(pixel: u32, mask: u32) u8 {
    if (mask == 0) return 255; // BGRX/BI_RGB has no defined alpha channel.
    const shift: u5 = @intCast(@ctz(mask));
    const maximum = mask >> shift;
    const value: u64 = (pixel & mask) >> shift;
    return @intCast((value * 255 + maximum / 2) / maximum);
}

/// Supports 24/32-bit BI_RGB and 32-bit BI_BITFIELDS/BI_ALPHABITFIELDS.
/// BI_RGB's reserved high byte is ignored; only an explicit alpha mask supplies
/// alpha. V4/V5 color profiles are bounded but not color-managed or dereferenced.
fn decodeDib(alloc: Allocator, bytes: []const u8) !Image {
    const header: usize = try get(u32, bytes, 0);
    switch (header) {
        40, 52, 56, 108, 124 => {},
        else => return error.UnsupportedFormat,
    }
    if (header > bytes.len) return error.InvalidData;
    const width = try get(i32, bytes, 4);
    const signed_height = try get(i32, bytes, 8);
    if (width <= 0 or signed_height == 0 or signed_height == std.math.minInt(i32)) return error.InvalidData;
    const height: usize = @intCast(if (signed_height < 0) -signed_height else signed_height);
    if (try get(u16, bytes, 12) != 1) return error.InvalidData;
    const bpp = try get(u16, bytes, 14);
    const compression = try get(u32, bytes, 16);
    if ((bpp != 24 and bpp != 32) or (compression != 0 and compression != 3 and compression != 6) or (bpp == 24 and compression != 0)) return error.UnsupportedFormat;
    var masks: [4]u32 = .{ 0x00ff0000, 0x0000ff00, 0x000000ff, 0 };
    var pixel_offset = header;
    if (compression != 0) {
        if (header == 40) pixel_offset = try add(header, if (compression == 6) 16 else 12);
        if (pixel_offset > bytes.len) return error.InvalidData;
        for (0..3) |i| masks[i] = try get(u32, bytes, 40 + i * 4);
        if (header >= 56 or compression == 6) {
            if (header == 52) return error.InvalidData;
            masks[3] = try get(u32, bytes, 52);
        }
        if (compression == 6 and masks[3] == 0) return error.InvalidData;
        try validateMasks(masks);
    }
    // High-bpp DIBs may still contain a color table (biClrUsed entries).
    pixel_offset = try add(pixel_offset, try mul(try get(u32, bytes, 32), 4));
    const row_bytes = try mul(@intCast(width), bpp / 8);
    const stride = (try add(row_bytes, 3)) & ~@as(usize, 3);
    const size = try mul(stride, height);
    if (pixel_offset > bytes.len or size > bytes.len - pixel_offset) return error.InvalidData;
    const declared_size = try get(u32, bytes, 20);
    if (declared_size != 0 and (declared_size < size or declared_size > bytes.len - pixel_offset)) return error.InvalidData;
    if (header == 124) {
        const profile: usize = try get(u32, bytes, 112);
        const profile_size: usize = try get(u32, bytes, 116);
        if (profile == 0 or profile_size == 0) {
            if (profile != 0 or profile_size != 0) return error.InvalidData;
        } else {
            // In a packed clipboard DIB the profile follows the bitmap bits.
            if (profile < try add(pixel_offset, @max(size, declared_size)) or profile > bytes.len or profile_size > bytes.len - profile) return error.InvalidData;
        }
    }
    const rgba_stride = try mul(@intCast(width), 4);
    const rgba = try alloc.alloc(u8, try mul(rgba_stride, height));
    errdefer alloc.free(rgba);
    for (0..height) |y| {
        const src_y = if (signed_height < 0) y else height - 1 - y;
        for (0..@as(usize, @intCast(width))) |x| {
            const src = pixel_offset + src_y * stride + x * (bpp / 8);
            const dst = y * rgba_stride + x * 4;
            if (bpp == 24) {
                rgba[dst..][0..4].* = .{ bytes[src + 2], bytes[src + 1], bytes[src], 255 };
            } else {
                const pixel = try get(u32, bytes, src);
                for (masks, 0..) |mask, i| rgba[dst + i] = channel(pixel, mask);
            }
        }
    }
    return .{ .width = @intCast(width), .height = @intCast(height), .rgba = rgba };
}

const testing = std.testing;

test "text: UTF-16LE roundtrips, bounded terminators and invalid Unicode" {
    for ([_][]const u8{ "", "plain\r\ntext", "中文 \u{1f98e} café" }) |text| {
        const bytes = try encodeText(testing.allocator, text);
        defer testing.allocator.free(bytes);
        try testing.expectEqual(@as(u16, 0), try get(u16, bytes, bytes.len - 2));
        const decoded = try decodeText(testing.allocator, bytes);
        defer free(testing.allocator, .{ .text = decoded });
        try testing.expectEqualStrings(text, decoded);
        try testing.expectError(error.InvalidData, decodeText(testing.allocator, bytes[0 .. bytes.len - 1]));
    }
    try testing.expectError(error.EmbeddedNul, encodeText(testing.allocator, "a\x00b"));
    try testing.expectError(error.InvalidUtf8, encodeText(testing.allocator, "\xff"));
    try testing.expectError(error.InvalidData, decodeText(testing.allocator, &.{}));
    try testing.expectError(error.InvalidUtf16, decodeText(testing.allocator, &.{ 0, 0xd8, 0, 0 }));
    const padded = try decodeText(testing.allocator, &.{ 65, 0, 0, 0, 0xff });
    defer testing.allocator.free(padded);
    try testing.expectEqualStrings("A", padded);
}

test "HTML: UTF-8 byte offsets, fragments and hostile bounds" {
    for ([_][]const u8{ "", "<b>中文 \u{1f98e}</b>", "<!--StartFragment-->literal" }) |fragment| {
        const bytes = try encodeHtml(testing.allocator, fragment);
        defer testing.allocator.free(bytes);
        const decoded = try decodeHtml(testing.allocator, bytes);
        defer free(testing.allocator, .{ .html = decoded });
        try testing.expectEqualStrings(fragment, decoded);
        const expected = try std.fmt.allocPrint(testing.allocator, "EndFragment:{d:0>10}", .{html_header.len + html_prefix.len + fragment.len});
        defer testing.allocator.free(expected);
        try testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
        for (0..bytes.len - 1) |n| try testing.expectError(error.InvalidData, decodeHtml(testing.allocator, bytes[0..n]));
    }
    const bad = try encodeHtml(testing.allocator, "x");
    defer testing.allocator.free(bad);
    const sf = std.mem.indexOf(u8, bad, "StartFragment:").? + "StartFragment:".len;
    @memcpy(bad[sf..][0..10], "9999999999");
    try testing.expectError(error.InvalidData, decodeHtml(testing.allocator, bad));
    @memcpy(bad[sf..][0..10], "0000000001");
    try testing.expectError(error.InvalidData, decodeHtml(testing.allocator, bad));
}

test "files: Unicode DROPFILES, double NUL and invalid lists" {
    const paths = [_][]const u8{ "C:\\中文\\a.txt", "D:\\space dir\\\u{1f98e}.png" };
    const bytes = try encodeFiles(testing.allocator, &paths);
    defer testing.allocator.free(bytes);
    const decoded = try decodeFiles(testing.allocator, bytes);
    defer free(testing.allocator, .{ .files = decoded });
    try testing.expectEqual(paths.len, decoded.len);
    for (paths, decoded) |expected, actual| try testing.expectEqualStrings(expected, actual);
    try testing.expectEqual(@as(u32, 0), try get(u32, bytes, bytes.len - 4));
    for (0..bytes.len) |n| try testing.expectError(error.InvalidData, decodeFiles(testing.allocator, bytes[0..n]));
    const empty = try encodeFiles(testing.allocator, &.{});
    defer testing.allocator.free(empty);
    const no_paths = try decodeFiles(testing.allocator, empty);
    defer free(testing.allocator, .{ .files = no_paths });
    try testing.expectEqual(@as(usize, 0), no_paths.len);
    put(u32, bytes, 0, 19);
    try testing.expectError(error.InvalidData, decodeFiles(testing.allocator, bytes));
    put(u32, bytes, 0, 0xffffffff);
    try testing.expectError(error.InvalidData, decodeFiles(testing.allocator, bytes));
    put(u32, bytes, 0, 20);
    put(u32, bytes, 16, 0);
    try testing.expectError(error.UnsupportedFormat, decodeFiles(testing.allocator, bytes));
    try testing.expectError(error.InvalidData, encodeFiles(testing.allocator, &.{""}));
    try testing.expectError(error.EmbeddedNul, encodeFiles(testing.allocator, &.{"a\x00b"}));
}

const sample_image: Image = .{ .width = 2, .height = 2, .rgba = &.{
    255, 0, 0,   128, 0,  255, 0,  0,
    0,   0, 255, 255, 21, 42,  63, 64,
} };

test "DIBV5 and DIB: channel order, alpha and row orientation" {
    for ([_]bool{ true, false }) |v5| {
        const bytes = try encodeDib(testing.allocator, sample_image, v5);
        defer testing.allocator.free(bytes);
        const image = try decodeDib(testing.allocator, bytes);
        defer free(testing.allocator, .{ .image = image });
        try testing.expectEqual(sample_image.width, image.width);
        try testing.expectEqual(sample_image.height, image.height);
        for (sample_image.rgba, image.rgba, 0..) |expected, actual, i| {
            try testing.expectEqual(if (!v5 and i % 4 == 3) @as(u8, 255) else expected, actual);
        }
        const header: usize = if (v5) 124 else 40;
        try testing.expectEqualSlices(u8, if (v5) &.{ 0, 0, 255, 128 } else &.{ 255, 0, 0, 0 }, bytes[header..][0..4]);
        for (4..bytes.len) |n| try testing.expectError(error.InvalidData, decodeDib(testing.allocator, bytes[0..n]));
    }
}

test "DIB: padded 24-bit rows and external 32-bit masks" {
    var rgb: [48]u8 = @splat(0);
    put(u32, &rgb, 0, 40);
    put(i32, &rgb, 4, 1);
    put(i32, &rgb, 8, 2);
    put(u16, &rgb, 12, 1);
    put(u16, &rgb, 14, 24);
    rgb[40..].* = .{ 3, 2, 1, 99, 6, 5, 4, 99 };
    const image = try decodeDib(testing.allocator, &rgb);
    defer free(testing.allocator, .{ .image = image });
    try testing.expectEqualSlices(u8, &.{ 4, 5, 6, 255, 1, 2, 3, 255 }, image.rgba);
    var bitfields: [60]u8 = @splat(0);
    @memcpy(bitfields[0..40], rgb[0..40]);
    put(i32, &bitfields, 8, -1);
    put(u16, &bitfields, 14, 32);
    put(u32, &bitfields, 16, 6);
    // Non-BGRA masks: exercise mask extraction rather than a hardcoded swap.
    put(u32, &bitfields, 40, 0x000000ff);
    put(u32, &bitfields, 44, 0x0000ff00);
    put(u32, &bitfields, 48, 0x00ff0000);
    put(u32, &bitfields, 52, 0xff000000);
    bitfields[56..].* = .{ 10, 20, 30, 40 };
    const masked = try decodeDib(testing.allocator, &bitfields);
    defer free(testing.allocator, .{ .image = masked });
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, masked.rgba);
    put(u32, &bitfields, 44, 0xff);
    try testing.expectError(error.InvalidData, decodeDib(testing.allocator, &bitfields));
    put(u32, &bitfields, 44, 0x0000ff00);
    put(u32, &bitfields, 16, 3);
    @memcpy(bitfields[52..56], bitfields[56..60]);
    const rgb_masks = try decodeDib(testing.allocator, bitfields[0..56]);
    defer free(testing.allocator, .{ .image = rgb_masks });
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, rgb_masks.rgba);
}

test "DIB: invalid sizes, masks, color tables and profile boundaries" {
    const valid = try encodeDib(testing.allocator, sample_image, true);
    defer testing.allocator.free(valid);
    const Case = struct { offset: usize, value: u32 };
    for ([_]Case{
        .{ .offset = 4, .value = 0 },
        .{ .offset = 4, .value = 0xffffffff },
        .{ .offset = 8, .value = 0 },
        .{ .offset = 8, .value = 0x80000000 },
        .{ .offset = 4, .value = 0x7fffffff },
        .{ .offset = 20, .value = 1 },
        .{ .offset = 20, .value = 0xffffffff },
        .{ .offset = 32, .value = 0xffffffff },
        .{ .offset = 40, .value = 0 },
        .{ .offset = 40, .value = 0x00ff00ff },
        .{ .offset = 44, .value = 0x00ff0000 },
        .{ .offset = 112, .value = 0xffffffff },
        .{ .offset = 116, .value = 4 },
    }) |case| {
        const bytes = try testing.allocator.dupe(u8, valid);
        defer testing.allocator.free(bytes);
        put(u32, bytes, case.offset, case.value);
        try testing.expectError(error.InvalidData, decodeDib(testing.allocator, bytes));
    }
    try testing.expectError(error.InvalidData, encodeDib(testing.allocator, .{ .width = 1, .height = 1, .rgba = &.{} }, true));
}

test "HTML: omitted context, alternate line endings and optional selection" {
    const template = "Version:0.9\rStartHTML:-1\rEndHTML:-1\rStartFragment:0000000000\rEndFragment:0000000000\r";
    const payload = try std.fmt.allocPrint(testing.allocator, "Version:0.9\rStartHTML:-1\rEndHTML:-1\rStartFragment:{d:0>10}\rEndFragment:{d:0>10}\r{s}", .{ template.len, template.len + "中文".len, "中文" });
    defer testing.allocator.free(payload);
    const fragment = try decodeHtml(testing.allocator, payload);
    defer testing.allocator.free(fragment);
    try testing.expectEqualStrings("中文", fragment);
    for (payload) |*byte| if (byte.* == '\r') {
        byte.* = '\n';
    };
    const lf_fragment = try decodeHtml(testing.allocator, payload);
    defer testing.allocator.free(lf_fragment);
    try testing.expectEqualStrings("中文", lf_fragment);

    const selection_header = html_header ++ "StartSelection:0000000000\r\nEndSelection:0000000000\r\nSourceURL:https://example.test/\r\n";
    const selected = try std.fmt.allocPrint(testing.allocator, "Version:1.0\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\nStartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\nStartSelection:{d:0>10}\r\nEndSelection:{d:0>10}\r\nSourceURL:https://example.test/\r\nabc", .{ selection_header.len, selection_header.len + 3, selection_header.len, selection_header.len + 3, selection_header.len + 1, selection_header.len + 2 });
    defer testing.allocator.free(selected);
    const decoded = try decodeHtml(testing.allocator, selected);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("abc", decoded);
    const selection = std.mem.indexOf(u8, selected, "StartSelection:").? + "StartSelection:".len;
    @memcpy(selected[selection..][0..10], "9999999999");
    try testing.expectError(error.InvalidData, decodeHtml(testing.allocator, selected));

    for ([_][]const u8{
        "Version:1.0\nStartHTML:-1\nEndHTML:-1\nStartFragment:0\nEndFragment:1\nx",
        "Version:1.0\nStartHTML:-1\nEndHTML:-1\nStartFragment:-2\nEndFragment:1\nx",
        "Version:1.0\nStartHTML:-1\nEndHTML:-1\nStartFragment:999999999999999999999999\nEndFragment:1\nx",
        "Version:1.0\nStartHTML:-1\nStartHTML:-1\nEndHTML:-1\nStartFragment:0\nEndFragment:1\nx",
        "Version:1.0\nStartHTML:-1\nEndHTML:-1\nEndFragment:1\nx",
    }) |bad| try testing.expectError(error.InvalidData, decodeHtml(testing.allocator, bad));
}

test "DIB: V2/V3/V4 headers, color table and bounded V5 profile" {
    const v5 = try encodeDib(testing.allocator, sample_image, true);
    defer testing.allocator.free(v5);
    // The same masked bitmap with each supported embedded-mask header size.
    for ([_]usize{ 52, 56, 108 }) |header| {
        const bytes = try testing.allocator.alloc(u8, header + sample_image.rgba.len);
        defer testing.allocator.free(bytes);
        @memcpy(bytes[0..header], v5[0..header]);
        put(u32, bytes, 0, @intCast(header));
        @memcpy(bytes[header..], v5[124..]);
        const image = try decodeDib(testing.allocator, bytes);
        defer free(testing.allocator, .{ .image = image });
        for (image.rgba, sample_image.rgba, 0..) |actual, expected, i| {
            try testing.expectEqual(if (header == 52 and i % 4 == 3) @as(u8, 255) else expected, actual);
        }
    }
    var with_profile: [148]u8 = @splat(0);
    @memcpy(with_profile[0..124], v5[0..124]);
    put(u32, &with_profile, 32, 1); // One RGBQUAD before pixels.
    @memcpy(with_profile[128..144], v5[124..]);
    put(u32, &with_profile, 112, 144);
    put(u32, &with_profile, 116, 4);
    const image = try decodeDib(testing.allocator, &with_profile);
    defer free(testing.allocator, .{ .image = image });
    try testing.expectEqualSlices(u8, sample_image.rgba, image.rgba);
    put(u32, &with_profile, 112, 128); // Must not overlap the pixel array.
    try testing.expectError(error.InvalidData, decodeDib(testing.allocator, &with_profile));
    put(u32, &with_profile, 112, 144);
    put(u32, &with_profile, 116, 5); // One byte beyond GlobalSize.
    try testing.expectError(error.InvalidData, decodeDib(testing.allocator, &with_profile));
}

test "files: padded offset and malformed UTF-16 after a valid path" {
    const bytes = try encodeFiles(testing.allocator, &.{ "C:\\one", "D:\\two" });
    defer testing.allocator.free(bytes);
    const padded = try testing.allocator.alloc(u8, bytes.len + 4);
    defer testing.allocator.free(padded);
    @memcpy(padded[0..20], bytes[0..20]);
    @memset(padded[20..24], 0xff);
    @memcpy(padded[24..], bytes[20..]);
    put(u32, padded, 0, 24);
    const paths = try decodeFiles(testing.allocator, padded);
    defer free(testing.allocator, .{ .files = paths });
    try testing.expectEqualStrings("D:\\two", paths[1]);
    const second = (try wideEnd(padded, 24)) + 2;
    put(u16, padded, second, 0xdc00); // Lone low surrogate; first path must be freed.
    try testing.expectError(error.InvalidUtf16, decodeFiles(testing.allocator, padded));
}

test "mutated payloads stay bounded and release any successful result" {
    const text = try encodeText(testing.allocator, "test");
    defer testing.allocator.free(text);
    const html = try encodeHtml(testing.allocator, "<b>test</b>");
    defer testing.allocator.free(html);
    const dib = try encodeDib(testing.allocator, sample_image, true);
    defer testing.allocator.free(dib);
    const files = try encodeFiles(testing.allocator, &.{ "C:\\one", "D:\\two" });
    defer testing.allocator.free(files);
    const formats = [_]Format{ .text, .html, .image, .files };
    for ([_][]u8{ text, html, dib, files }, formats) |bytes, format| {
        for (0..bytes.len) |i| {
            const original = bytes[i];
            defer bytes[i] = original;
            for ([_]u8{ 0, 0x80, 0xff }) |value| {
                bytes[i] = value;
                const result: Data = switch (format) {
                    .text => .{ .text = decodeText(testing.allocator, bytes) catch continue },
                    .html => .{ .html = decodeHtml(testing.allocator, bytes) catch continue },
                    .image => .{ .image = decodeDib(testing.allocator, bytes) catch continue },
                    .files => .{ .files = decodeFiles(testing.allocator, bytes) catch continue },
                };
                free(testing.allocator, result);
            }
        }
    }
}

fn allocationRoundtrips(alloc: Allocator) !void {
    const text = try encodeText(alloc, "Unicode 中文");
    defer alloc.free(text);
    const decoded_text = try decodeText(alloc, text);
    defer free(alloc, .{ .text = decoded_text });
    const html = try encodeHtml(alloc, "<b>中文</b>");
    defer alloc.free(html);
    const decoded_html = try decodeHtml(alloc, html);
    defer free(alloc, .{ .html = decoded_html });
    const files = try encodeFiles(alloc, &.{ "C:\\one", "D:\\two" });
    defer alloc.free(files);
    const decoded_files = try decodeFiles(alloc, files);
    defer free(alloc, .{ .files = decoded_files });
    const dib = try encodeDib(alloc, sample_image, true);
    defer alloc.free(dib);
    const image = try decodeDib(alloc, dib);
    defer free(alloc, .{ .image = image });
}

test "all codecs clean up on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationRoundtrips, .{});
}

test "public API compiles without touching the clipboard" {
    // refAllDecls forces semantic analysis/linking without calling Win32 APIs.
    testing.refAllDecls(@This());
}
