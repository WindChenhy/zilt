//! v0.1.5 跨平台打包格式生成器（纯函数，全部可离线单测）：
//!   - WiX .wxs（MSI；candle/light 在本机可用时由工具驱动构建）
//!   - Authenticode 签名命令（signtool 包装）
//!   - macOS .app：Info.plist + bundle 结构约定（DMG 需 hdiutil，仅生成脚本）
//!   - Linux：.desktop（AppImage AppDir）、rpm .spec、**真实 .deb**（ar + ustar tar + gzip 纯 Zig）
//!
//! 元数据统一走 PackMeta；平台产物命名约定见各生成器文档。

const std = @import("std");

const testing = std.testing;

pub const PackMeta = struct {
    /// 显示名（窗口标题级）
    name: []const u8,
    version: []const u8,
    /// 应用 ID（如 app.zilt.desktop；macOS bundle id / AUMID 复用）
    app_id: []const u8,
    /// 可执行文件名（Windows 含 .exe；macOS/Linux 无后缀）
    exe_name: []const u8,
    maintainer: []const u8 = "Zilt App",
    description: []const u8 = "Zilt application",
};

// ---------------------------------------------------------------------------
// 纯函数：命名约定
// ---------------------------------------------------------------------------

/// Debian 包名规范化：小写、仅 [a-z0-9+-.]、下划线转连字符、长度 ≥2。
pub fn debianName(alloc: std.mem.Allocator, app_id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (app_id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.') {
            try out.append(alloc, std.ascii.toLower(c));
        } else {
            try out.append(alloc, '-');
        }
    }
    if (out.items.len < 2) try out.appendSlice(alloc, "app");
    return out.toOwnedSlice(alloc);
}

/// 从 app_id 派生确定性 GUID（v4 形态；同 app_id 恒同值——UpgradeCode 稳定性要求）。
pub fn derivedGuid(alloc: std.mem.Allocator, seed: []const u8) ![]u8 {
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(seed, &sha, .{});
    var g: [16]u8 = sha[0..16].*;
    g[6] = (g[6] & 0x0f) | 0x40; // version 4
    g[8] = (g[8] & 0x3f) | 0x80; // variant 10
    return std.fmt.allocPrint(alloc, "{X:0>2}{X:0>2}{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{
        g[0], g[1], g[2],  g[3],  g[4],  g[5],  g[6],  g[7],
        g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15],
    });
}

// ---------------------------------------------------------------------------
// WiX .wxs（MSI；per-user + 开始菜单快捷方式 + MajorUpgrade）
// ---------------------------------------------------------------------------

pub fn generateWxs(alloc: std.mem.Allocator, meta: PackMeta, exe_source_path: []const u8) ![]u8 {
    const upgrade_code = try derivedGuid(alloc, meta.app_id);
    defer alloc.free(upgrade_code);
    return std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
        \\  <Product Id="*" Name="{s}" Language="1033" Version="{s}" Manufacturer="{s}" UpgradeCode="{s}">
        \\    <Package InstallerVersion="200" Compressed="yes" InstallScope="perUser" Description="{s}"/>
        \\    <MajorUpgrade DowngradeErrorMessage="A newer version of [ProductName] is already installed."/>
        \\    <MediaTemplate EmbedCab="yes"/>
        \\    <Feature Id="Main" Level="1">
        \\      <ComponentRef Id="AppExe"/>
        \\      <ComponentRef Id="StartMenuShortcut"/>
        \\    </Feature>
        \\    <Directory Id="TARGETDIR" Name="SourceDir">
        \\      <Directory Id="LocalAppDataFolder">
        \\        <Directory Id="ZiltPrograms" Name="Programs">
        \\          <Directory Id="INSTALLDIR" Name="{s}">
        \\            <Component Id="AppExe" Guid="*">
        \\              <File Id="ExeFile" Source="{s}" KeyPath="yes"/>
        \\            </Component>
        \\          </Directory>
        \\        </Directory>
        \\      </Directory>
        \\      <Directory Id="ProgramMenuFolder">
        \\        <Directory Id="AppMenuDir" Name="{s}">
        \\          <Component Id="StartMenuShortcut" Guid="*">
        \\            <Shortcut Id="AppShortcut" Name="{s}" Description="{s}" Target="[ZiltPrograms]/{s}/{s}" WorkingDirectory="INSTALLDIR"/>
        \\            <RemoveFolder Id="RemoveMenuDir" On="uninstall"/>
        \\            <RegistryValue Root="HKCU" Key="Software\{s}" Name="installed" Type="integer" Value="1" KeyPath="yes"/>
        \\          </Component>
        \\        </Directory>
        \\      </Directory>
        \\    </Directory>
        \\  </Product>
        \\</Wix>
    , .{
        meta.name,          meta.version,                       meta.maintainer,
        upgrade_code,       meta.description,                   meta.name,
        exe_source_path,    meta.name,                          meta.name,
        meta.description,   "ZiltPrograms",                     meta.name,
        meta.app_id,
    });
}

/// Authenticode 签名命令（signtool；证书/时间戳经环境传入，工具侧执行）。
pub fn buildSigntoolCommand(alloc: std.mem.Allocator, pfx: []const u8, pass: []const u8, ts_url: []const u8, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "signtool sign /fd SHA256 /td SHA256 /tr {s} /f \"{s}\" /p {s} \"{s}\"", .{ ts_url, pfx, pass, file });
}

// ---------------------------------------------------------------------------
// macOS .app
// ---------------------------------------------------------------------------

/// Info.plist（CFBundle* 由 meta 填充；exe 名去 .exe 后缀）。
pub fn generateInfoPlist(alloc: std.mem.Allocator, meta: PackMeta) ![]u8 {
    const exe_base = if (std.mem.endsWith(u8, meta.exe_name, ".exe"))
        meta.exe_name[0 .. meta.exe_name.len - 4]
    else
        meta.exe_name;
    return std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleName</key><string>{s}</string>
        \\  <key>CFBundleDisplayName</key><string>{s}</string>
        \\  <key>CFBundleIdentifier</key><string>{s}</string>
        \\  <key>CFBundleVersion</key><string>{s}</string>
        \\  <key>CFBundleShortVersionString</key><string>{s}</string>
        \\  <key>CFBundleExecutable</key><string>{s}</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        \\  <key>LSMinimumSystemVersion</key><string>10.13</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\</dict>
        \\</plist>
    , .{ meta.name, meta.name, meta.app_id, meta.version, meta.version, exe_base });
}

/// AppRun（AppImage；Linux）。
pub const apprun_script =
    \\#!/bin/sh
    \\HERE=$(dirname "$(readlink -f "$0")")
    \\exec "$HERE/usr/bin/APP_EXE_NAME" "$@"
    \\
;

/// .desktop（AppImage AppDir / deb 共用）。
pub fn generateDesktopFile(alloc: std.mem.Allocator, meta: PackMeta) ![]u8 {
    const exe_base = if (std.mem.endsWith(u8, meta.exe_name, ".exe"))
        meta.exe_name[0 .. meta.exe_name.len - 4]
    else
        meta.exe_name;
    return std.fmt.allocPrint(alloc,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Comment={s}
        \\Exec={s}
        \\Icon={s}
        \\Terminal=false
        \\Categories=Utility;
        \\
    , .{ meta.name, meta.description, exe_base, meta.app_id });
}

/// rpm .spec（rpmbuild 可直接构建）。
pub fn generateRpmSpec(alloc: std.mem.Allocator, meta: PackMeta) ![]u8 {
    const name = try debianName(alloc, meta.app_id);
    defer alloc.free(name);
    const exe_base = if (std.mem.endsWith(u8, meta.exe_name, ".exe"))
        meta.exe_name[0 .. meta.exe_name.len - 4]
    else
        meta.exe_name;
    return std.fmt.allocPrint(alloc,
        \\Name:           {s}
        \\Version:        {s}
        \\Release:        1%{{?dist}}
        \\Summary:        {s}
        \\License:        Proprietary
        \\BuildArch:      x86_64
        \\
        \\%description
        \\{s}
        \\
        \\%install
        \\mkdir -p %{{buildroot}}/usr/bin
        \\install -m 755 %{{SOURCE0}} %{{buildroot}}/usr/bin/{s}
        \\
        \\%files
        \\/usr/bin/{s}
        \\
    , .{ name, meta.version, meta.description, meta.description, exe_base, exe_base });
}

// ---------------------------------------------------------------------------
// .deb（真实产物：ar 容器 + ustar tar + gzip，全部纯 Zig）
// ---------------------------------------------------------------------------

pub const TarEntry = struct {
    name: []const u8,
    mode: u32, // 如 0o644 / 0o755
    typeflag: u8 = '0', // '0' 文件 / '5' 目录
    data: []const u8 = "",
};

fn writeOctal(field: []u8, value: u64) void {
    // "%0*o\0"：前导 0 填充 + NUL 结尾（size 字段为 11 位 + NUL）
    const digits = field.len - 1;
    var v = value;
    var i = digits;
    while (i > 0) {
        i -= 1;
        field[i] = @intCast('0' + @as(u8, @intCast(v & 7)));
        v >>= 3;
    }
    field[digits] = 0;
}

fn ustarHeader(alloc: std.mem.Allocator, e: TarEntry) ![]u8 {
    var h = try alloc.alloc(u8, 512);
    @memset(h, 0);
    @memcpy(h[0..e.name.len], e.name);
    writeOctal(h[100..108], e.mode);
    writeOctal(h[108..116], 0); // uid
    writeOctal(h[116..124], 0); // gid
    writeOctal(h[124..136], e.data.len); // size
    writeOctal(h[136..148], 0); // mtime
    @memset(h[148..156], ' '); // checksum 占位（空格参与计算）
    h[156] = e.typeflag;
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    // checksum
    var sum: u64 = 0;
    for (h) |c| sum += c;
    writeOctal(h[148..155], sum); // 6 位 + NUL
    h[155] = ' ';
    return h;
}

fn gzipCompress(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try aw.ensureTotalCapacity(256);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&aw.writer, &window, .gzip, .default);
    _ = try comp.writer.writeAll(raw);
    try comp.finish();
    return alloc.dupe(u8, aw.written());
}

fn writeTarGz(alloc: std.mem.Allocator, entries: []const TarEntry) ![]u8 {
    var tar: std.ArrayList(u8) = .empty;
    defer tar.deinit(alloc);
    for (entries) |e| {
        const hdr = try ustarHeader(alloc, e);
        defer alloc.free(hdr);
        try tar.appendSlice(alloc, hdr);
        try tar.appendSlice(alloc, e.data);
        const pad = (512 - (e.data.len % 512)) % 512;
        try tar.appendNTimes(alloc, 0, pad);
    }
    try tar.appendNTimes(alloc, 0, 1024); // 结束双零块
    return gzipCompress(alloc, tar.items);
}

fn appendArMember(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, data: []const u8) !void {
    var hdr: [60]u8 = undefined;
    @memset(&hdr, ' ');
    @memcpy(hdr[0..name.len], name);
    hdr[16] = '0'; // mtime（其余空格）
    @memcpy(hdr[28..34], "0     "); // uid
    @memcpy(hdr[34..40], "0     "); // gid
    @memcpy(hdr[40..48], "100644  "); // mode
    // size：右对齐 10 位十进制（空格填充）
    var size_buf: [16]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{data.len}) catch unreachable;
    @memcpy(hdr[48 + (10 - size_str.len) .. 58], size_str);
    hdr[58] = '`';
    hdr[59] = '\n';
    try out.appendSlice(alloc, &hdr);
    try out.appendSlice(alloc, data);
    if (data.len % 2 == 1) try out.append(alloc, '\n');
}

/// 生成 .deb（control.tar.gz + data.tar.gz + debian-binary → ar 容器）。
pub fn buildDeb(alloc: std.mem.Allocator, meta: PackMeta, exe_bytes: []const u8) ![]u8 {
    const pkg = try debianName(alloc, meta.app_id);
    defer alloc.free(pkg);
    const exe_base = if (std.mem.endsWith(u8, meta.exe_name, ".exe"))
        meta.exe_name[0 .. meta.exe_name.len - 4]
    else
        meta.exe_name;

    const control = try std.fmt.allocPrint(alloc,
        \\Package: {s}
        \\Version: {s}
        \\Section: utils
        \\Priority: optional
        \\Architecture: amd64
        \\Maintainer: {s}
        \\Description: {s}
        \\
    , .{ pkg, meta.version, meta.maintainer, meta.description });

    const control_tar = try writeTarGz(alloc, &.{
        .{ .name = "./", .mode = 0o755, .typeflag = '5' },
        .{ .name = "./control", .mode = 0o644, .data = control },
    });
    defer alloc.free(control_tar);

    const desktop = try generateDesktopFile(alloc, meta);
    defer alloc.free(desktop);
    const exe_entry = try std.fmt.allocPrint(alloc, "./usr/bin/{s}", .{exe_base});
    defer alloc.free(exe_entry);
    const desktop_entry = try std.fmt.allocPrint(alloc, "./usr/share/applications/{s}.desktop", .{pkg});
    defer alloc.free(desktop_entry);
    const data_tar = try writeTarGz(alloc, &.{
        .{ .name = "./", .mode = 0o755, .typeflag = '5' },
        .{ .name = "./usr/", .mode = 0o755, .typeflag = '5' },
        .{ .name = "./usr/bin/", .mode = 0o755, .typeflag = '5' },
        .{ .name = exe_entry, .mode = 0o755, .data = exe_bytes },
        .{ .name = "./usr/share/", .mode = 0o755, .typeflag = '5' },
        .{ .name = "./usr/share/applications/", .mode = 0o755, .typeflag = '5' },
        .{ .name = desktop_entry, .mode = 0o644, .data = desktop },
    });
    defer alloc.free(data_tar);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "!<arch>\n");
    try appendArMember(alloc, &out, "debian-binary", "2.0\n");
    try appendArMember(alloc, &out, "control.tar.gz", control_tar);
    try appendArMember(alloc, &out, "data.tar.gz", data_tar);
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "debianName: 规范化" {
    const a = try debianName(testing.allocator, "app.zilt.desktop");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("app.zilt.desktop", a);
    const b = try debianName(testing.allocator, "My_App ID");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("my-app-id", b);
    const c = try debianName(testing.allocator, "x");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("x-app", c);
}

test "derivedGuid: 确定性 + 区分度 + v4 形态" {
    const a = try derivedGuid(testing.allocator, "app.zilt.desktop");
    defer testing.allocator.free(a);
    const b = try derivedGuid(testing.allocator, "app.zilt.desktop");
    defer testing.allocator.free(b);
    const c = try derivedGuid(testing.allocator, "other");
    defer testing.allocator.free(c);
    try testing.expectEqualSlices(u8, a, b);
    try testing.expect(!std.mem.eql(u8, a, c));
    try testing.expectEqual(@as(usize, 36), a.len);
    try testing.expect(a[14] == '4'); // version nibble
    try testing.expect(a[19] == '8' or a[19] == '9' or a[19] == 'a' or a[19] == 'b'); // variant
}

test "generateWxs: 关键字段齐全" {
    const meta = PackMeta{ .name = "Zilt Demo", .version = "0.1.5", .app_id = "app.zilt.desktop", .exe_name = "zilt-app.exe" };
    const wxs = try generateWxs(testing.allocator, meta, "D:\\out\\zilt-app.exe");
    defer testing.allocator.free(wxs);
    try testing.expect(std.mem.indexOf(u8, wxs, "Name=\"Zilt Demo\"") != null);
    try testing.expect(std.mem.indexOf(u8, wxs, "Version=\"0.1.5\"") != null);
    try testing.expect(std.mem.indexOf(u8, wxs, "Source=\"D:\\out\\zilt-app.exe\"") != null);
    try testing.expect(std.mem.indexOf(u8, wxs, "InstallScope=\"perUser\"") != null);
    try testing.expect(std.mem.indexOf(u8, wxs, "MajorUpgrade") != null);
    try testing.expect(std.mem.indexOf(u8, wxs, "UpgradeCode=\"") != null);
}

test "buildSigntoolCommand: 参数齐全" {
    const cmd = try buildSigntoolCommand(testing.allocator, "my.pfx", "pw123", "http://ts/x", "app.exe");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "/fd SHA256") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "/tr http://ts/x") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "/f \"my.pfx\"") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "/p pw123") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "\"app.exe\"") != null);
}

test "generateInfoPlist: 字段齐全 + exe 名去后缀" {
    const meta = PackMeta{ .name = "Zilt Demo", .version = "0.1.5", .app_id = "app.zilt.desktop", .exe_name = "zilt-app.exe" };
    const plist = try generateInfoPlist(testing.allocator, meta);
    defer testing.allocator.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>app.zilt.desktop</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>zilt-app</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>0.1.5</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "NSHighResolutionCapable") != null);
}

test "generateDesktopFile/generateRpmSpec: 内容断言" {
    const meta = PackMeta{ .name = "Zilt Demo", .version = "0.1.5", .app_id = "app.zilt.desktop", .exe_name = "zilt-app.exe", .description = "Demo app" };
    const desktop = try generateDesktopFile(testing.allocator, meta);
    defer testing.allocator.free(desktop);
    try testing.expect(std.mem.startsWith(u8, desktop, "[Desktop Entry]\n"));
    try testing.expect(std.mem.indexOf(u8, desktop, "Exec=zilt-app") != null);

    const spec = try generateRpmSpec(testing.allocator, meta);
    defer testing.allocator.free(spec);
    try testing.expect(std.mem.indexOf(u8, spec, "Name:           app.zilt.desktop") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "Version:        0.1.5") != null);
}

test "buildDeb: ar 结构 + control.tar.gz 内容回读" {
    const meta = PackMeta{ .name = "Zilt Demo", .version = "0.1.5", .app_id = "app.zilt.desktop", .exe_name = "zilt-app.exe", .maintainer = "Z <z@x.io>", .description = "Demo app" };
    const deb = try buildDeb(testing.allocator, meta, "MZBINARY");
    defer testing.allocator.free(deb);

    // ar 全局魔数
    try testing.expect(std.mem.startsWith(u8, deb, "!<arch>\n"));

    // 逐成员解析（60 字节头）
    var pos: usize = 8;
    var member_count: usize = 0;
    var control_gz: []const u8 = "";
    while (pos + 60 <= deb.len) : (member_count += 1) {
        const name = std.mem.trim(u8, deb[pos..][0..16], " ");
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, deb[pos + 48 ..][0..10], " "), 10) catch unreachable;
        pos += 60;
        const data = deb[pos..][0..size];
        pos += size + (size % 2);
        if (std.mem.eql(u8, name, "debian-binary")) {
            try testing.expectEqualStrings("2.0\n", data);
        } else if (std.mem.eql(u8, name, "control.tar.gz")) {
            control_gz = data;
        } else if (std.mem.eql(u8, name, "data.tar.gz")) {
            try testing.expect(size > 0);
        } else {
            try testing.expect(false); // 未知成员
        }
    }
    try testing.expectEqual(@as(usize, 3), member_count);
    try testing.expect(control_gz.len > 0);

    // gunzip control.tar.gz → ustar → control 内容
    var in: std.Io.Reader = .fixed(control_gz);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    _ = try dec.reader.streamRemaining(&aw.writer);
    const tar_bytes = aw.written();

    // 第一个 ustar 头（./ 目录）之后是 ./control 文件
    try testing.expect(std.mem.startsWith(u8, tar_bytes[257..263], "ustar"));
    const ctrl_name = tar_bytes[512..][0..9];
    try testing.expectEqualStrings("./control", ctrl_name);
    const ctrl_size = std.fmt.parseInt(usize, std.mem.trim(u8, tar_bytes[512 + 124 ..][0..12], " \x00"), 8) catch unreachable;
    const ctrl_data = tar_bytes[1024..][0..ctrl_size];
    try testing.expect(std.mem.indexOf(u8, ctrl_data, "Package: app.zilt.desktop") != null);
    try testing.expect(std.mem.indexOf(u8, ctrl_data, "Version: 0.1.5") != null);
    try testing.expect(std.mem.indexOf(u8, ctrl_data, "Maintainer: Z <z@x.io>") != null);
}

test "buildDeb: 确定性输出" {
    const meta = PackMeta{ .name = "Z", .version = "1.0", .app_id = "a.b", .exe_name = "a.exe" };
    const d1 = try buildDeb(testing.allocator, meta, "X");
    defer testing.allocator.free(d1);
    const d2 = try buildDeb(testing.allocator, meta, "X");
    defer testing.allocator.free(d2);
    try testing.expectEqualSlices(u8, d1, d2);
}
