//! v0.5.8：macOS 系统信息 / Shell 的纯函数部分（无 ObjC，宿主可单测）。
//! ObjC/IOKit 采集见 `backend.zig`；这里只做「原始值 → 共享模型」的换算与兜底。
const std = @import("std");

const Allocator = std.mem.Allocator;
const shared = @import("../../sysinfo.zig");

const testing = std.testing;

pub const Version = struct { major: u32, minor: u32, patch: u32 = 0 };

/// macOS 11 起 NSProcessInfo 报真实产品版本；10.16 兼容层兜底：没有 SDK 版本标记的
/// 裸二进制在 macOS 11+ 上仍报 10.16，只能从 Darwin 内核主版本反推。
/// 已知内核版本之外返回 null（调用方保留 NSProcessInfo 的值，不猜）。
pub fn darwinToMacos(darwin_major: u32) ?Version {
    return switch (darwin_major) {
        15...19 => .{ .major = 10, .minor = darwin_major - 4 },
        20...24 => .{ .major = darwin_major - 9, .minor = 0 },
        25 => .{ .major = 26, .minor = 0 },
        else => null,
    };
}

pub fn kernelMajor(release: []const u8) ?u32 {
    const dot = std.mem.indexOfScalar(u8, release, '.') orelse release.len;
    return std.fmt.parseInt(u32, release[0..dot], 10) catch null;
}

/// "26.1" / "15.5.1" / "15"（kern.osproductversion）；缺位补 0，任一段非数字即拒绝。
pub fn parseDotted(text: []const u8) ?Version {
    var v = Version{ .major = 0, .minor = 0 };
    var it = std.mem.splitScalar(u8, text, '.');
    var parts: usize = 0;
    while (it.next()) |part| : (parts += 1) {
        const n = std.fmt.parseInt(u32, part, 10) catch return null;
        switch (parts) {
            0 => v.major = n,
            1 => v.minor = n,
            2 => v.patch = n,
            else => return null,
        }
    }
    return if (parts == 0) null else v;
}

/// OsInfo 里堆上只有 version / locale（name / arch 是静态串）。
pub fn freeOsInfo(alloc: Allocator, info: *const shared.OsInfo) void {
    alloc.free(info.version);
    alloc.free(info.locale);
}

pub fn freeGpu(alloc: Allocator, g: shared.GpuInfo) void {
    alloc.free(g.name);
    alloc.free(g.vendor);
}

pub fn resolveOsVersion(pi_major: u32, pi_minor: u32, pi_patch: u32, kernel_release: ?[]const u8) Version {
    if (pi_major == 10 and pi_minor == 16) {
        if (kernel_release) |rel| {
            if (kernelMajor(rel)) |k| {
                if (darwinToMacos(k)) |v| return v;
            }
        }
    }
    return .{ .major = pi_major, .minor = pi_minor, .patch = pi_patch };
}

pub fn formatVersion(buf: []u8, v: Version) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
}

pub const Locale = struct { language: []const u8, region: ?[]const u8 = null };

/// NSLocale preferredLanguages 首项切分：中间 4 字母的书面语子标签（"zh-Hans-CN"）去掉，
/// 只有书面语没有地区的（"zh-Hant"）原样保留在 language 里。
pub fn parseLocale(raw: []const u8) Locale {
    const first = std.mem.indexOfScalar(u8, raw, '-') orelse return .{ .language = raw };
    const second = std.mem.indexOfScalarPos(u8, raw, first + 1, '-') orelse {
        if (first + 5 == raw.len) return .{ .language = raw };
        return .{ .language = raw[0..first], .region = raw[first + 1 ..] };
    };
    if (second - first - 1 != 4) return .{ .language = raw[0..first], .region = raw[first + 1 ..] };
    return .{ .language = raw[0..first], .region = raw[second + 1 ..] };
}

pub fn formatLocale(alloc: Allocator, loc: Locale) ![]u8 {
    const region = loc.region orelse return alloc.dupe(u8, loc.language);
    return std.fmt.allocPrint(alloc, "{s}-{s}", .{ loc.language, region });
}

fn channel(v: f64) u32 {
    return @intFromFloat(@round(@min(@max(v, 0.0), 1.0) * 255.0));
}

pub fn packArgb(a: f64, r: f64, g: f64, b: f64) u32 {
    return (channel(a) << 24) | (channel(r) << 16) | (channel(g) << 8) | channel(b);
}

/// AppKit 屏幕坐标左下原点 (y, height) → 左上原点的 top。
pub fn flipY(screen_height: f64, y: f64, height: f64) i32 {
    return @intFromFloat(@round(screen_height - (y + height)));
}

pub fn dpiFromScale(scale: f64) u32 {
    return @intFromFloat(@round(@max(1.0, scale) * 96.0));
}

/// CFData 内容按 C 字符串读：去尾 NUL，非空且全为可打印 ASCII 才算字符串。
pub fn cfDataToString(bytes: []const u8) ?[]const u8 {
    var s = bytes;
    while (s.len > 0 and s[s.len - 1] == 0) s = s[0 .. s.len - 1];
    if (s.len == 0) return null;
    for (s) |ch| {
        if (ch < 0x20 or ch > 0x7E) return null;
    }
    return s;
}

pub fn cfDataToU16Le(bytes: []const u8) ?u16 {
    if (bytes.len < 2) return null;
    return std.mem.readInt(u16, bytes[0..2], .little);
}

/// 0x106b = Apple（不在共享 PCI 表里）；其余走共享表，未知回退十六进制。
pub fn vendorName(alloc: Allocator, vendor_id: u32) ![]u8 {
    if (vendor_id == 0x106b) return alloc.dupe(u8, "Apple");
    const known = shared.vendorFromPciId(vendor_id);
    if (std.mem.eql(u8, known, "unknown")) return std.fmt.allocPrint(alloc, "0x{x:0>4}", .{vendor_id});
    return alloc.dupe(u8, known);
}

pub const GpuProps = struct {
    model: ?[]const u8 = null,
    vendor_id: ?u16 = null,
    vram_mb: u64 = 0,
};

pub fn gpuInfo(alloc: Allocator, p: GpuProps) !shared.GpuInfo {
    const vendor = try vendorName(alloc, p.vendor_id orelse 0);
    errdefer alloc.free(vendor);
    return .{
        .name = if (p.model) |m| try alloc.dupe(u8, m) else try alloc.dupe(u8, "unknown"),
        .vendor = vendor,
        .vram_mb = p.vram_mb,
        .driver = "",
    };
}

/// RFC 3986 scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"。
/// 单字母不算（Windows 盘符 "C:" 一类）；冒号后全是数字按 host:port 处理（"localhost:8080"），
/// 两者都交给 normalizeUrlTarget 补 https://。
pub fn hasUrlScheme(raw: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return false;
    if (colon < 2 or colon + 1 >= raw.len) return false;
    if (!std.ascii.isAlphabetic(raw[0])) return false;
    for (raw[0..colon]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }
    for (raw[colon + 1 ..]) |ch| {
        if (!std.ascii.isDigit(ch)) return true;
    }
    return false;
}

pub fn normalizeUrlTarget(alloc: Allocator, raw: []const u8) ![]u8 {
    if (hasUrlScheme(raw)) return alloc.dupe(u8, raw);
    return std.fmt.allocPrint(alloc, "https://{s}", .{raw});
}

test "v0.5.8: Darwin 主版本 → macOS 产品版本" {
    try testing.expectEqual(Version{ .major = 10, .minor = 15 }, darwinToMacos(19));
    try testing.expectEqual(Version{ .major = 11, .minor = 0 }, darwinToMacos(20));
    try testing.expectEqual(Version{ .major = 14, .minor = 0 }, darwinToMacos(23));
    try testing.expectEqual(Version{ .major = 15, .minor = 0 }, darwinToMacos(24));
    try testing.expectEqual(Version{ .major = 26, .minor = 0 }, darwinToMacos(25));
    try testing.expect(darwinToMacos(26) == null);
    try testing.expect(darwinToMacos(14) == null);
}

test "v0.5.8: 内核版本串主版本解析" {
    try testing.expectEqual(24, kernelMajor("24.6.0").?);
    try testing.expectEqual(19, kernelMajor("19.6.0").?);
    try testing.expect(kernelMajor("garbage") == null);
    try testing.expect(kernelMajor("") == null);
}

test "v0.5.8: OS 版本裁决（10.16 兼容层从内核反推，否则信任 NSProcessInfo）" {
    try testing.expectEqual(Version{ .major = 15, .minor = 0 }, resolveOsVersion(10, 16, 0, "24.6.0"));
    try testing.expectEqual(Version{ .major = 14, .minor = 0 }, resolveOsVersion(10, 16, 0, "23.6.0"));
    try testing.expectEqual(Version{ .major = 10, .minor = 15, .patch = 7 }, resolveOsVersion(10, 15, 7, "19.6.0"));
    try testing.expectEqual(Version{ .major = 26, .minor = 1 }, resolveOsVersion(26, 1, 0, "25.1.0"));
    try testing.expectEqual(Version{ .major = 10, .minor = 16 }, resolveOsVersion(10, 16, 0, null));
    try testing.expectEqual(Version{ .major = 10, .minor = 16 }, resolveOsVersion(10, 16, 0, "garbage"));
}

test "v0.5.8: 版本格式化" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("15.0.0", try formatVersion(&buf, .{ .major = 15, .minor = 0 }));
    try testing.expectEqualStrings("10.15.7", try formatVersion(&buf, .{ .major = 10, .minor = 15, .patch = 7 }));
}

test "v0.5.8: 语言标签归一（去书面语子标签）" {
    const a = testing.allocator;
    const norm = struct {
        fn f(alloc: Allocator, raw: []const u8) ![]u8 {
            return formatLocale(alloc, parseLocale(raw));
        }
    }.f;
    const zh = try norm(a, "zh-Hans-CN");
    defer a.free(zh);
    try testing.expectEqualStrings("zh-CN", zh);
    const sr = try norm(a, "sr-Latn-RS");
    defer a.free(sr);
    try testing.expectEqualStrings("sr-RS", sr);
    const en = try norm(a, "en-US");
    defer a.free(en);
    try testing.expectEqualStrings("en-US", en);
    const de = try norm(a, "de");
    defer a.free(de);
    try testing.expectEqualStrings("de", de);
    const es = try norm(a, "es-419");
    defer a.free(es);
    try testing.expectEqualStrings("es-419", es);
    const hant = try norm(a, "zh-Hant");
    defer a.free(hant);
    try testing.expectEqualStrings("zh-Hant", hant);
}

test "v0.5.8: 强调色打包为 0xAARRGGBB（越界钳制）" {
    try testing.expectEqual(@as(u32, 0xFFFF0000), packArgb(1, 1, 0, 0));
    try testing.expectEqual(@as(u32, 0xFF0000FF), packArgb(1, 0, 0, 1));
    try testing.expectEqual(@as(u32, 0xFF800000), packArgb(2, 0.5, 0, 0));
    try testing.expectEqual(@as(u32, 0xFF000000), packArgb(1, -1, 0, 0));
}

test "v0.5.8: AppKit 左下原点 → 左上原点" {
    try testing.expectEqual(@as(i32, 780), flipY(1080, 0, 300));
    try testing.expectEqual(@as(i32, 0), flipY(1080, 780, 300));
    try testing.expectEqual(@as(i32, 0), flipY(1080, 1050, 30));
}

test "v0.5.8: 缩放比 → DPI" {
    try testing.expectEqual(@as(u32, 96), dpiFromScale(1.0));
    try testing.expectEqual(@as(u32, 144), dpiFromScale(1.5));
    try testing.expectEqual(@as(u32, 192), dpiFromScale(2.0));
    try testing.expectEqual(@as(u32, 96), dpiFromScale(0));
}

test "v0.5.8: CFData 解码（字符串去尾 NUL，小端 u16）" {
    try testing.expectEqualStrings("Apple M1", cfDataToString("Apple M1\x00").?);
    try testing.expect(cfDataToString("") == null);
    try testing.expect(cfDataToString("\x00") == null);
    try testing.expect(cfDataToString("ab\x01") == null);
    try testing.expectEqual(@as(u16, 0x106b), cfDataToU16Le("\x6b\x10").?);
    try testing.expect(cfDataToU16Le("\x01") == null);
}

test "v0.5.8: GPU 厂商名（Apple PCI id + 共享表 + 未知回退十六进制）" {
    const a = testing.allocator;
    const apple = try vendorName(a, 0x106b);
    defer a.free(apple);
    try testing.expectEqualStrings("Apple", apple);
    const intel = try vendorName(a, 0x8086);
    defer a.free(intel);
    try testing.expectEqualStrings("Intel", intel);
    const other = try vendorName(a, 0x1234);
    defer a.free(other);
    try testing.expectEqualStrings("0x1234", other);
}

test "v0.5.8: GPU 属性 → 共享模型（模型缺失回退 unknown）" {
    const a = testing.allocator;
    const g = try gpuInfo(a, .{ .model = "Apple M1", .vendor_id = 0x106b });
    defer a.free(g.name);
    defer a.free(g.vendor);
    try testing.expectEqualStrings("Apple M1", g.name);
    try testing.expectEqualStrings("Apple", g.vendor);
    try testing.expectEqualStrings("", g.driver);

    const anon = try gpuInfo(a, .{});
    defer a.free(anon.name);
    defer a.free(anon.vendor);
    try testing.expectEqualStrings("unknown", anon.name);
    try testing.expectEqualStrings("0x0000", anon.vendor);
}

test "v0.5.8: Shell 目标 URL scheme 判定与归一" {
    try testing.expect(hasUrlScheme("https://example.com"));
    try testing.expect(hasUrlScheme("mailto:a@b.c"));
    try testing.expect(hasUrlScheme("zilt+app://x"));
    try testing.expect(!hasUrlScheme("example.com/path"));
    try testing.expect(!hasUrlScheme("localhost:8080"));
    try testing.expect(!hasUrlScheme("C:\\foo"));
    try testing.expect(!hasUrlScheme(""));

    const a = testing.allocator;
    const bare = try normalizeUrlTarget(a, "example.com/x");
    defer a.free(bare);
    try testing.expectEqualStrings("https://example.com/x", bare);
    const full = try normalizeUrlTarget(a, "mailto:a@b.c");
    defer a.free(full);
    try testing.expectEqualStrings("mailto:a@b.c", full);
    const empty = try normalizeUrlTarget(a, "");
    defer a.free(empty);
    try testing.expectEqualStrings("https://", empty);
}

test "v0.5.8: 点分版本解析（缺位补 0，非数字拒绝）" {
    try testing.expectEqual(Version{ .major = 26, .minor = 1, .patch = 0 }, parseDotted("26.1").?);
    try testing.expectEqual(Version{ .major = 15, .minor = 5, .patch = 1 }, parseDotted("15.5.1").?);
    try testing.expectEqual(Version{ .major = 15, .minor = 0, .patch = 0 }, parseDotted("15").?);
    try testing.expect(parseDotted("garbage") == null);
    try testing.expect(parseDotted("") == null);
    try testing.expect(parseDotted("99999999999") == null);
}

test "v0.5.8: freeOsInfo / freeGpu 释放堆上字段（泄漏检查）" {
    const a = testing.allocator;
    const info = shared.OsInfo{
        .name = "macOS",
        .version = try a.dupe(u8, "26.1.0"),
        .arch = "aarch64",
        .locale = try a.dupe(u8, "zh-CN"),
    };
    freeOsInfo(a, &info);
    const g = try gpuInfo(a, .{ .model = "Apple M1", .vendor_id = 0x106b });
    freeGpu(a, g);
}
