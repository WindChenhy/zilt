//! MSIX 包定义（纯逻辑，可离线单测）：AppxManifest.xml 生成、ICO → PNG 帧提取、
//! 版本号规范化。
//!
//! 实测确认的两条硬约束：
//!   1. `Identity/@Publisher` 必须与签名证书的 Subject **逐字一致**，否则部署失败；
//!   2. `Identity/@Version` 必须是四段式（0.1.16 → 0.1.16.0），每段 0..65535。
//!
//! 图标：现有 `zilt.ico` 的四个帧都是 PNG 编码，直接取最大帧复用为 MSIX 资产。
//! 尺寸不是 MSIX 要求的精确值（150/44/50），本地松散注册与 sideload 均通过；
//! 若要提交 Microsoft Store，需换成精确尺寸，届时再补 PNG 缩放。

const std = @import("std");

pub const Frame = struct {
    /// ICO 目录里 0 表示 256（历史遗留：单字节字段放不下 256）
    width: u32,
    height: u32,
    png: []const u8,
};

const ico_png_sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

/// 从 .ico 里提取所有 PNG 编码的帧（BMP 帧跳过 —— 本项目的 ico 全是 PNG）。
pub fn extractPngFrames(alloc: std.mem.Allocator, ico: []const u8) ![]Frame {
    if (ico.len < 6) return error.TruncatedIcon;
    const count = readU16(ico, 4);
    if (count == 0) return error.EmptyIcon;

    var out: std.ArrayListUnmanaged(Frame) = .empty;
    errdefer out.deinit(alloc);

    var off: usize = 6;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (off + 16 > ico.len) return error.TruncatedIcon;
        const w_raw = ico[off];
        const h_raw = ico[off + 1];
        const bytes = readU32(ico, off + 8);
        const img_off = readU32(ico, off + 12);
        off += 16;

        if (img_off + bytes > ico.len) continue;
        const data = ico[img_off .. img_off + bytes];
        if (data.len < 8 or !std.mem.eql(u8, data[0..8], &ico_png_sig)) continue;

        // 以 PNG 的 IHDR 为准，ICO 目录字段只作参考（256 会被记成 0）
        const pw = readBE32(data, 16);
        const ph = readBE32(data, 20);
        try out.append(alloc, .{
            .width = if (pw != 0) pw else (if (w_raw == 0) 256 else w_raw),
            .height = if (ph != 0) ph else (if (h_raw == 0) 256 else h_raw),
            .png = data,
        });
    }
    if (out.items.len == 0) return error.NoPngFrame;
    return out.toOwnedSlice(alloc);
}

/// 取面积最大的帧（通常就是 256x256），用作 MSIX 的 Logo 源。
pub fn largestPngFrame(frames: []const Frame) ?Frame {
    var best: ?Frame = null;
    for (frames) |f| {
        if (best == null or f.width * f.height > best.?.width * best.?.height) best = f;
    }
    return best;
}

/// 把 semver 规范成 MSIX 要求的四段版本（每段 0..65535）。
/// "0.1.16" → "0.1.16.0"；"1.2.3-beta.4" → "1.2.3.0"（预发布标签整段丢弃）。
pub fn normalizeVersion(alloc: std.mem.Allocator, semver: []const u8) ![]u8 {
    var parts: [4]u32 = .{ 0, 0, 0, 0 };
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, semver, '.');
    while (it.next()) |raw| {
        if (idx >= 4) break;
        // 只取前导数字："3-beta" → 3
        var n: u32 = 0;
        var hit_non_digit = false;
        for (raw) |c| {
            if (c < '0' or c > '9') {
                hit_non_digit = true;
                break;
            }
            n = n * 10 + (c - '0');
            if (n > 65535) {
                n = 65535;
                break;
            }
        }
        parts[idx] = n;
        idx += 1;
        // 一旦出现非数字段，后面都属于预发布标签（1.2.3-beta.4 的 "4" 不是第四段），
        // 整个丢掉 —— 否则 1.2.3-beta.4 会变成 1.2.3.4。
        if (hit_non_digit) break;
    }
    return std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}", .{ parts[0], parts[1], parts[2], parts[3] });
}

pub const ManifestOptions = struct {
    /// 包标识，如 `app.zilt.desktop`（与 AUMID / 数据目录保持一致）
    identity_name: []const u8,
    /// **必须与签名证书 Subject 逐字一致**（如 `CN=Zilt`），否则部署报 0x800B0109
    publisher: []const u8,
    /// 已规范化的四段版本（用 normalizeVersion）
    version: []const u8,
    /// x64 / x86 / arm64
    arch: []const u8,
    display_name: []const u8,
    publisher_display_name: []const u8,
    description: []const u8,
    exe_name: []const u8,
};

pub fn generateManifest(alloc: std.mem.Allocator, opts: ManifestOptions) ![]u8 {
    const name = try escapeXml(alloc, opts.display_name);
    defer alloc.free(name);
    const desc = try escapeXml(alloc, opts.description);
    defer alloc.free(desc);
    const pub_disp = try escapeXml(alloc, opts.publisher_display_name);
    defer alloc.free(pub_disp);
    const publisher = try escapeXml(alloc, opts.publisher);
    defer alloc.free(publisher);

    return std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
        \\         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
        \\         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">
        \\  <Identity Name="{s}" Publisher="{s}" Version="{s}" ProcessorArchitecture="{s}"/>
        \\  <Properties>
        \\    <DisplayName>{s}</DisplayName>
        \\    <PublisherDisplayName>{s}</PublisherDisplayName>
        \\    <Logo>Assets\StoreLogo.png</Logo>
        \\  </Properties>
        \\  <Dependencies>
        \\    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0"/>
        \\  </Dependencies>
        \\  <Resources>
        \\    <Resource Language="zh-cn"/>
        \\    <Resource Language="en-us"/>
        \\  </Resources>
        \\  <Applications>
        \\    <Application Id="App" Executable="{s}" EntryPoint="Windows.FullTrustApplication">
        \\      <uap:VisualElements DisplayName="{s}" Description="{s}" BackgroundColor="transparent"
        \\        Square150x150Logo="Assets\Square150x150Logo.png"
        \\        Square44x44Logo="Assets\Square44x44Logo.png"/>
        \\    </Application>
        \\  </Applications>
        \\  <Capabilities>
        \\    <rescap:Capability Name="runFullTrust"/>
        \\  </Capabilities>
        \\</Package>
        \\
    , .{
        opts.identity_name, publisher, opts.version, opts.arch,
        name,               pub_disp,  opts.exe_name, name,
        desc,
    });
}

/// MSIX 资产文件名（相对于包根）。
pub const assets = [_][]const u8{
    "Assets\\StoreLogo.png",
    "Assets\\Square150x150Logo.png",
    "Assets\\Square44x44Logo.png",
};

fn escapeXml(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '"' => try out.appendSlice(alloc, "&quot;"),
            '\'' => try out.appendSlice(alloc, "&apos;"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

fn readU16(buf: []const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

fn readU32(buf: []const u8, off: usize) u32 {
    return @as(u32, buf[off]) | (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) | (@as(u32, buf[off + 3]) << 24);
}

fn readBE32(buf: []const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) | (@as(u32, buf[off + 1]) << 16) |
        (@as(u32, buf[off + 2]) << 8) | @as(u32, buf[off + 3]);
}

const testing = std.testing;

test "normalizeVersion pads to four segments" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "0.1.16", "0.1.16.0" },
        .{ "1.2", "1.2.0.0" },
        .{ "1", "1.0.0.0" },
        .{ "1.2.3.4", "1.2.3.4" },
        .{ "1.2.3.4.5", "1.2.3.4" },
        .{ "1.2.3-beta.4", "1.2.3.0" },
        .{ "", "0.0.0.0" },
        .{ "0.0.0", "0.0.0.0" },
    };
    for (cases) |c| {
        const got = try normalizeVersion(a, c[0]);
        defer a.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "normalizeVersion clamps segments above 65535" {
    const a = testing.allocator;
    const got = try normalizeVersion(a, "70000.1.2");
    defer a.free(got);
    try testing.expectEqualStrings("65535.1.2.0", got);
}

test "extractPngFrames parses the project icon" {
    const a = testing.allocator;
    const ico = @embedFile("assets/zilt.ico");
    const frames = try extractPngFrames(a, ico);
    defer a.free(frames);

    try testing.expectEqual(@as(usize, 4), frames.len);
    const big = largestPngFrame(frames).?;
    try testing.expectEqual(@as(u32, 256), big.width);
    try testing.expectEqual(@as(u32, 256), big.height);
    // 每一帧都应是有效 PNG（以签名开头）
    for (frames) |f| {
        try testing.expect(f.png.len > 8);
        try testing.expectEqualSlices(u8, &ico_png_sig, f.png[0..8]);
    }
    // 明显大于小帧
    try testing.expect(big.png.len > frames[0].png.len);
}

test "extractPngFrames rejects junk input" {
    const a = testing.allocator;
    try testing.expectError(error.TruncatedIcon, extractPngFrames(a, &.{0}));
    try testing.expectError(error.EmptyIcon, extractPngFrames(a, &.{ 0, 0, 1, 0, 0, 0 }));
}

test "manifest carries publisher verbatim and four-part version" {
    const a = testing.allocator;
    const v = try normalizeVersion(a, "0.1.16");
    defer a.free(v);
    const xml = try generateManifest(a, .{
        .identity_name = "app.zilt.desktop",
        .publisher = "CN=Zilt",
        .version = v,
        .arch = "x64",
        .display_name = "Zilt",
        .publisher_display_name = "Zilt",
        .description = "Zilt application",
        .exe_name = "zilt-app.exe",
    });
    defer a.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "Name=\"app.zilt.desktop\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Publisher=\"CN=Zilt\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Version=\"0.1.16.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "ProcessorArchitecture=\"x64\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Executable=\"zilt-app.exe\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "runFullTrust") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "EntryPoint=\"Windows.FullTrustApplication\"") != null);
}

test "manifest escapes XML special characters" {
    const a = testing.allocator;
    const xml = try generateManifest(a, .{
        .identity_name = "app.demo",
        .publisher = "CN=A & B",
        .version = "1.0.0.0",
        .arch = "x64",
        .display_name = "Tom & Jerry <Demo>",
        .publisher_display_name = "A \"B\"",
        .description = "it's <ok>",
        .exe_name = "demo.exe",
    });
    defer a.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "Publisher=\"CN=A &amp; B\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Tom &amp; Jerry &lt;Demo&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "&quot;B&quot;") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "it&apos;s") != null);
    // 绝不能留下裸 & / <
    try testing.expect(std.mem.indexOf(u8, xml, "A & B") == null);
}

test "asset list covers the three manifest-referenced logos" {
    try testing.expectEqual(@as(usize, 3), assets.len);
    try testing.expect(std.mem.endsWith(u8, assets[0], "StoreLogo.png"));
    try testing.expect(std.mem.endsWith(u8, assets[1], "Square150x150Logo.png"));
    try testing.expect(std.mem.endsWith(u8, assets[2], "Square44x44Logo.png"));
}
