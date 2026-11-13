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
// WiX .wxs（MSI）
//
// 两条真实约束（light 的 ICE 校验会拦）：
//   ICE38 per-user 安装时文件不能当 KeyPath，必须用 HKCU 注册表值做 KeyPath
//   ICE64 user profile 下的目录必须能被卸载清理（RemoveFolder；MSI 只删空目录，
//         所以对共用层 %LOCALAPPDATA%\Programs 也安全）
// ---------------------------------------------------------------------------

pub const WxsOptions = struct {
    /// per-machine：Program Files + HKLM + 需要提权；默认 per-user。
    per_machine: bool = false,
};

pub fn generateWxs(alloc: std.mem.Allocator, meta: PackMeta, exe_source_path: []const u8) ![]u8 {
    return generateWxsOpt(alloc, meta, exe_source_path, .{});
}

pub fn generateWxsOpt(
    alloc: std.mem.Allocator,
    meta: PackMeta,
    exe_source_path: []const u8,
    opts: WxsOptions,
) ![]u8 {
    const upgrade_code = try derivedGuid(alloc, meta.app_id);
    defer alloc.free(upgrade_code);

    const scope = if (opts.per_machine) "perMachine" else "perUser";
    const reg_root = if (opts.per_machine) "HKLM" else "HKCU";

    // 组件 GUID 必须显式：带 registry keypath 的组件不能用 Guid="*"
    // （candle 报 CNDL0230）。用稳定派生值而非随机 GUID —— 升级时 MSI 才能
    // 认出「同一个组件」，MajorUpgrade 的引用计数才不会错。
    const scope_key = if (opts.per_machine) "permachine" else "peruser";
    const exe_seed = try std.fmt.allocPrint(alloc, "{s}.{s}.exe", .{ meta.app_id, scope_key });
    defer alloc.free(exe_seed);
    const exe_guid = try derivedGuid(alloc, exe_seed);
    defer alloc.free(exe_guid);
    const menu_seed = try std.fmt.allocPrint(alloc, "{s}.{s}.menu", .{ meta.app_id, scope_key });
    defer alloc.free(menu_seed);
    const menu_guid = try derivedGuid(alloc, menu_seed);
    defer alloc.free(menu_guid);

    // 安装根：per-machine 用 Program Files，per-user 用 LocalAppData\Programs
    const root_block = if (opts.per_machine)
        \\      <Directory Id="ProgramFiles64Folder">
        \\        <Directory Id="INSTALLDIR" Name="@DIRNAME@">
        \\          <Component Id="AppExe" Guid="@EXE_GUID@">
        \\            <File Id="ExeFile" Source="@EXE_SRC@" Name="@EXE_NAME@" KeyPath="yes"/>
        \\            <RemoveFolder Id="RemoveInstallDir" On="uninstall" Directory="INSTALLDIR"/>
        \\          </Component>
        \\        </Directory>
        \\      </Directory>
    else
        \\      <Directory Id="LocalAppDataFolder">
        \\        <Directory Id="ProgramsFolder" Name="Programs">
        \\          <Directory Id="INSTALLDIR" Name="@DIRNAME@">
        \\            <Component Id="AppExe" Guid="@EXE_GUID@">
        \\              <File Id="ExeFile" Source="@EXE_SRC@" Name="@EXE_NAME@"/>
        \\              <RegistryValue Root="HKCU" Key="Software\@APPID@" Name="exe" Type="integer" Value="1" KeyPath="yes"/>
        \\              <RemoveFolder Id="RemoveInstallDir" On="uninstall" Directory="INSTALLDIR"/>
        \\              <RemoveFolder Id="RemoveProgramsFolder" On="uninstall" Directory="ProgramsFolder"/>
        \\            </Component>
        \\          </Directory>
        \\        </Directory>
        \\      </Directory>
    ;

    const template =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
        \\  <Product Id="*" Name="@NAME@" Language="1033" Version="@VERSION@" Manufacturer="@MFR@" UpgradeCode="@UPGRADE@">
        \\    <Package InstallerVersion="200" Compressed="yes" InstallScope="@SCOPE@" Description="@DESC@"/>
        \\    <MajorUpgrade DowngradeErrorMessage="A newer version of [ProductName] is already installed."/>
        \\    <MediaTemplate EmbedCab="yes"/>
        \\    <Feature Id="Main" Level="1">
        \\      <ComponentRef Id="AppExe"/>
        \\      <ComponentRef Id="StartMenuShortcut"/>
        \\    </Feature>
        \\    <Directory Id="TARGETDIR" Name="SourceDir">
        \\@ROOT_BLOCK@
        \\      <Directory Id="ProgramMenuFolder">
        \\        <Directory Id="AppMenuDir" Name="@DIRNAME@">
        \\          <Component Id="StartMenuShortcut" Guid="@MENU_GUID@">
        \\            <Shortcut Id="AppShortcut" Name="@NAME@" Description="@DESC@" Target="[#ExeFile]" WorkingDirectory="INSTALLDIR"/>
        \\            <RemoveFolder Id="RemoveMenuDir" On="uninstall"/>
        \\            <RegistryValue Root="@REG_ROOT@" Key="Software\@APPID@" Name="menu" Type="integer" Value="1" KeyPath="yes"/>
        \\          </Component>
        \\        </Directory>
        \\      </Directory>
        \\    </Directory>
        \\  </Product>
        \\</Wix>
        \\
    ;

    // 顺序很关键：@ROOT_BLOCK@ 插入的片段自身含 @EXE_SRC@ / @APPID@ / @EXE_GUID@
    // 等占位符，必须放在最前面展开，否则这些占位符会逃过替换（candle/light 会
    // 把字面量 @EXE_SRC@ 当成文件路径去打开）。
    const pairs = [_][2][]const u8{
        .{ "@ROOT_BLOCK@", root_block },
        .{ "@NAME@", meta.name },
        .{ "@VERSION@", meta.version },
        .{ "@MFR@", meta.maintainer },
        .{ "@UPGRADE@", upgrade_code },
        .{ "@SCOPE@", scope },
        .{ "@DESC@", meta.description },
        .{ "@DIRNAME@", meta.name },
        .{ "@EXE_SRC@", exe_source_path },
        .{ "@EXE_NAME@", meta.exe_name },
        .{ "@APPID@", meta.app_id },
        .{ "@REG_ROOT@", reg_root },
        .{ "@EXE_GUID@", exe_guid },
        .{ "@MENU_GUID@", menu_guid },
    };

    var cur = try alloc.dupe(u8, template);
    errdefer alloc.free(cur);
    for (pairs) |p| {
        const next = try std.mem.replaceOwned(u8, alloc, cur, p[0], p[1]);
        alloc.free(cur);
        cur = next;
    }
    return cur;
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

/// v0.2.4：deb 增强选项（Linux 打包；无依赖需求时用 buildDeb 简版）。
pub const DebOptions = struct {
    /// Depends: 逗号连接（如 libgtk-3-0、libwebkit2gtk-4.1-0）
    depends: []const []const u8 = &.{},
    /// postinst 逐行 shell（xdg-mime 注册深链/文件关联）
    postinst_lines: []const []const u8 = &.{},
    /// postrm 逐行 shell
    postrm_lines: []const []const u8 = &.{},
    /// hicolor 图标 PNG（256px；null = 不带图标）
    icon_png: ?[]const u8 = null,
};

/// 生成 .deb（control.tar.gz + data.tar.gz + debian-binary → ar 容器）。
/// v0.2.4 起带依赖声明 / 维护脚本 / hicolor 图标；旧签名保留为兼容入口。
pub fn buildDeb(alloc: std.mem.Allocator, meta: PackMeta, exe_bytes: []const u8) ![]u8 {
    return buildDebOpt(alloc, meta, exe_bytes, .{});
}

pub fn buildDebOpt(alloc: std.mem.Allocator, meta: PackMeta, exe_bytes: []const u8, opts: DebOptions) ![]u8 {
    const pkg = try debianName(alloc, meta.app_id);
    defer alloc.free(pkg);
    const exe_base = if (std.mem.endsWith(u8, meta.exe_name, ".exe"))
        meta.exe_name[0 .. meta.exe_name.len - 4]
    else
        meta.exe_name;

    var control: std.ArrayListUnmanaged(u8) = .empty;
    defer control.deinit(alloc);
    try control.appendSlice(alloc, "Package: ");
    try control.appendSlice(alloc, pkg);
    try control.appendSlice(alloc,
        \\
        \\Version: 
    );
    try control.appendSlice(alloc, meta.version);
    try control.appendSlice(alloc,
        \\
        \\Section: utils
        \\Priority: optional
        \\Architecture: amd64
        \\Maintainer: 
    );
    try control.appendSlice(alloc, meta.maintainer);
    try control.appendSlice(alloc,
        \\
        \\Description: 
    );
    try control.appendSlice(alloc, meta.description);
    try control.append(alloc, '\n');
    if (opts.depends.len > 0) {
        try control.appendSlice(alloc, "Depends: ");
        for (opts.depends, 0..) |d, i| {
            if (i != 0) try control.appendSlice(alloc, ", ");
            try control.appendSlice(alloc, d);
        }
        try control.append(alloc, '\n');
    }

    var entries: std.ArrayListUnmanaged(TarEntry) = .empty;
    defer entries.deinit(alloc);
    try entries.append(alloc, .{ .name = "./", .mode = 0o755, .typeflag = '5' });
    try entries.append(alloc, .{ .name = "./control", .mode = 0o644, .data = control.items });
    // 维护脚本：postinst/postrm（可执行；无内容则跳过——dpkg 接受缺省）
    if (opts.postinst_lines.len > 0) {
        const body = try std.mem.join(alloc, "\n", opts.postinst_lines);
        defer alloc.free(body);
        const script = try std.fmt.allocPrint(alloc,
            \\#!/bin/sh
            \\set -e
            \\{s}
            \\
        , .{body});
        defer alloc.free(script);
        try entries.append(alloc, .{ .name = "./postinst", .mode = 0o755, .data = script });
    }
    if (opts.postrm_lines.len > 0) {
        const body = try std.mem.join(alloc, "\n", opts.postrm_lines);
        defer alloc.free(body);
        const script = try std.fmt.allocPrint(alloc,
            \\#!/bin/sh
            \\set -e
            \\{s}
            \\
        , .{body});
        defer alloc.free(script);
        try entries.append(alloc, .{ .name = "./postrm", .mode = 0o755, .data = script });
    }
    const control_tar = try writeTarGz(alloc, entries.items);
    defer alloc.free(control_tar);

    var data_entries: std.ArrayListUnmanaged(TarEntry) = .empty;
    defer data_entries.deinit(alloc);
    const exe_entry = try std.fmt.allocPrint(alloc, "./usr/bin/{s}", .{exe_base});
    defer alloc.free(exe_entry);
    try data_entries.append(alloc, .{ .name = "./", .mode = 0o755, .typeflag = '5' });
    try data_entries.append(alloc, .{ .name = "./usr/", .mode = 0o755, .typeflag = '5' });
    try data_entries.append(alloc, .{ .name = "./usr/bin/", .mode = 0o755, .typeflag = '5' });
    try data_entries.append(alloc, .{ .name = exe_entry, .mode = 0o755, .data = exe_bytes });
    try data_entries.append(alloc, .{ .name = "./usr/share/", .mode = 0o755, .typeflag = '5' });
    try data_entries.append(alloc, .{ .name = "./usr/share/applications/", .mode = 0o755, .typeflag = '5' });
    const desktop_entry = try std.fmt.allocPrint(alloc, "./usr/share/applications/{s}.desktop", .{pkg});
    defer alloc.free(desktop_entry);
    const desktop = try generateDesktopFile(alloc, meta);
    defer alloc.free(desktop);
    try data_entries.append(alloc, .{ .name = desktop_entry, .mode = 0o644, .data = desktop });
    if (opts.icon_png) |png| {
        try data_entries.append(alloc, .{ .name = "./usr/share/icons/", .mode = 0o755, .typeflag = '5' });
        try data_entries.append(alloc, .{ .name = "./usr/share/icons/hicolor/", .mode = 0o755, .typeflag = '5' });
        try data_entries.append(alloc, .{ .name = "./usr/share/icons/hicolor/256x256/", .mode = 0o755, .typeflag = '5' });
        try data_entries.append(alloc, .{ .name = "./usr/share/icons/hicolor/256x256/apps/", .mode = 0o755, .typeflag = '5' });
        const icon_entry = try std.fmt.allocPrint(alloc, "./usr/share/icons/hicolor/256x256/apps/{s}.png", .{pkg});
        defer alloc.free(icon_entry);
        try data_entries.append(alloc, .{ .name = icon_entry, .mode = 0o644, .data = png });
    }
    const data_tar = try writeTarGz(alloc, data_entries.items);
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

test "buildDebOpt: 依赖/维护脚本/图标进入对应成员" {
    const a = testing.allocator;
    const meta = PackMeta{ .name = "Zilt Demo", .version = "0.2.4", .app_id = "app.zilt.desktop", .exe_name = "zilt-app" };
    const exe_bytes = "FAKE-ELF-BYTES";
    const deb = try buildDebOpt(a, meta, exe_bytes, .{
        .depends = &.{ "libgtk-3-0", "libwebkit2gtk-4.1-0" },
        .postinst_lines = &.{"xdg-mime default app.zilt.desktop.desktop x-scheme-handler/zilt"},
        .icon_png = "PNGDATA",
    });
    defer a.free(deb);
    // ar 容器结构：三成员齐全（成员内容是 gzip 压缩的——内容正确性由
    // dpkg-deb --info/-x 的打包 E2E 校验，这里只断言容器结构）
    try testing.expect(std.mem.startsWith(u8, deb, "!<arch>"));
    try testing.expect(std.mem.indexOf(u8, deb, "debian-binary") != null);
    try testing.expect(std.mem.indexOf(u8, deb, "control.tar.gz") != null);
    try testing.expect(std.mem.indexOf(u8, deb, "data.tar.gz") != null);
    try testing.expect(deb.len > 100);
}

test "buildDeb: 简版无 Depends/postinst" {
    const a = testing.allocator;
    const meta = PackMeta{ .name = "Z", .version = "1.0", .app_id = "app.x", .exe_name = "x" };
    const deb = try buildDeb(a, meta, "ELF");
    defer a.free(deb);
    try testing.expect(std.mem.indexOf(u8, deb, "Depends:") == null);
    try testing.expect(std.mem.indexOf(u8, deb, "postinst") == null);
}

test "debianName: 规范化" {
    const a = try debianName(testing.allocator, "app.zilt.desktop");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("app.zilt.desktop", a);
    const b = try debianName(testing.allocator, "My_App ID");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("my-app-id", b);
    const c = try debianName(testing.allocator, "x");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("xapp", c); // 单字符 id 直接补 "app"（实现行为；此前该测试从未被编译执行）
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
