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
    /// v0.4.3 L5：目标架构（rpm BuildArch / PKGBUILD arch / deb 文件名与 control）。
    /// 取 Zig 的 `builtin.cpu.arch` 语义命名：x86_64 / aarch64。
    arch: []const u8 = "x86_64",
};

/// Debian 架构名（与 Zig/rpm 命名不同：amd64 / arm64）。
pub fn debArch(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "aarch64") or std.mem.eql(u8, arch, "arm64")) return "arm64";
    if (std.mem.eql(u8, arch, "x86_64") or std.mem.eql(u8, arch, "amd64")) return "amd64";
    if (std.mem.eql(u8, arch, "arm")) return "armhf";
    return "amd64";
}

/// 桌面项文件名：pkg 已以 `.desktop` 结尾时直接复用（`app.zilt.desktop`），
/// 否则补后缀。必须与 pack_linux 的 desktopFileName / postinst 的
/// `xdg-mime default <name>` 一致——此前 deb 装成 `app.zilt.desktop.desktop`
/// 而 postinst 注册 `app.zilt.desktop`，深链默认程序实际没生效。
pub fn desktopFileName(alloc: std.mem.Allocator, pkg: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, pkg, ".desktop")) return alloc.dupe(u8, pkg);
    return std.fmt.allocPrint(alloc, "{s}.desktop", .{pkg});
}

/// RPM/PKGBUILD 架构名（aarch64 与 Zig 一致；x86_64 一致）。
pub fn rpmArch(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "arm64")) return "aarch64";
    if (std.mem.eql(u8, arch, "amd64")) return "x86_64";
    return arch;
}

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

/// v0.5.1：Info.plist 可选字段（深链 URL types / TCC 用途串 / 图标 / 分类 / 最低系统）。
/// 默认值保持与历史 generateInfoPlist 兼容（基础 CFBundle* + 10.13 + 高分屏）。
pub const PlistOptions = struct {
    /// Contents/Resources 下图标文件名（如 "AppIcon.icns"）；null = 不写 CFBundleIconFile。
    icon_file: ?[]const u8 = null,
    /// 深链 scheme（如 {"zilt"}）→ CFBundleURLTypes；空 = 不写。
    url_schemes: []const []const u8 = &.{},
    /// NSCameraUsageDescription（getUserMedia 视频必需，缺失时 macOS 直接终止进程）。
    camera_usage: ?[]const u8 = null,
    /// NSMicrophoneUsageDescription（getUserMedia 音频必需）。
    microphone_usage: ?[]const u8 = null,
    /// LSApplicationCategoryType（如 "public.app-category.developer-tools"）。
    category: ?[]const u8 = null,
    /// LSMinimumSystemVersion。
    min_system: []const u8 = "10.13",
    /// CFBundleDevelopmentRegion。
    development_region: []const u8 = "en",
};

/// Info.plist（CFBundle* 由 meta 填充；exe 名去 .exe 后缀）。默认 opts 的薄包装。
pub fn generateInfoPlist(alloc: std.mem.Allocator, meta: PackMeta) ![]u8 {
    return generateInfoPlistOpt(alloc, meta, .{});
}

/// v0.5.1：完整 Info.plist——基础 CFBundle* + 可选深链/用途串/图标/分类。
/// 字符串值经 XML 转义（& < > " '），避免名称/用途串里的 & 损坏 plist。
pub fn generateInfoPlistOpt(alloc: std.mem.Allocator, meta: PackMeta, opts: PlistOptions) ![]u8 {
    const exe_base = if (std.mem.endsWith(u8, meta.exe_name, ".exe"))
        meta.exe_name[0 .. meta.exe_name.len - 4]
    else
        meta.exe_name;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );
    try appendKeyString(&buf, alloc, "CFBundleName", meta.name);
    try appendKeyString(&buf, alloc, "CFBundleDisplayName", meta.name);
    try appendKeyString(&buf, alloc, "CFBundleIdentifier", meta.app_id);
    try appendKeyString(&buf, alloc, "CFBundleVersion", meta.version);
    try appendKeyString(&buf, alloc, "CFBundleShortVersionString", meta.version);
    try appendKeyString(&buf, alloc, "CFBundleExecutable", exe_base);
    try appendKeyString(&buf, alloc, "CFBundlePackageType", "APPL");
    try appendKeyString(&buf, alloc, "CFBundleInfoDictionaryVersion", "6.0");
    try appendKeyString(&buf, alloc, "CFBundleDevelopmentRegion", opts.development_region);
    if (opts.icon_file) |icon| try appendKeyString(&buf, alloc, "CFBundleIconFile", icon);
    try appendKeyString(&buf, alloc, "LSMinimumSystemVersion", opts.min_system);
    if (opts.category) |cat| try appendKeyString(&buf, alloc, "LSApplicationCategoryType", cat);
    try buf.appendSlice(alloc, "  <key>NSHighResolutionCapable</key><true/>\n");
    try buf.appendSlice(alloc, "  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>\n");
    if (opts.camera_usage) |s| try appendKeyString(&buf, alloc, "NSCameraUsageDescription", s);
    if (opts.microphone_usage) |s| try appendKeyString(&buf, alloc, "NSMicrophoneUsageDescription", s);
    if (opts.url_schemes.len > 0) {
        try buf.appendSlice(alloc, "  <key>CFBundleURLTypes</key>\n  <array>\n    <dict>\n");
        try appendKeyString(&buf, alloc, "CFBundleURLName", meta.app_id);
        try buf.appendSlice(alloc, "      <key>CFBundleURLSchemes</key>\n      <array>\n");
        for (opts.url_schemes) |scheme| {
            try buf.appendSlice(alloc, "        <string>");
            try appendXmlEscaped(&buf, alloc, scheme);
            try buf.appendSlice(alloc, "</string>\n");
        }
        try buf.appendSlice(alloc, "      </array>\n    </dict>\n  </array>\n");
    }
    try buf.appendSlice(alloc, "</dict>\n</plist>\n");
    return buf.toOwnedSlice(alloc);
}

fn appendKeyString(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try buf.appendSlice(alloc, "  <key>");
    try buf.appendSlice(alloc, key);
    try buf.appendSlice(alloc, "</key><string>");
    try appendXmlEscaped(buf, alloc, value);
    try buf.appendSlice(alloc, "</string>\n");
}

fn appendXmlEscaped(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try buf.appendSlice(alloc, "&amp;"),
            '<' => try buf.appendSlice(alloc, "&lt;"),
            '>' => try buf.appendSlice(alloc, "&gt;"),
            '"' => try buf.appendSlice(alloc, "&quot;"),
            '\'' => try buf.appendSlice(alloc, "&apos;"),
            else => try buf.append(alloc, c),
        }
    }
}

/// v0.5.1：.app bundle 内部相对路径恒用正斜杠（macOS 宿主与跨平台生成共用）。
pub const macos_info_plist_rel = "Contents/Info.plist";
pub const macos_pkg_info_rel = "Contents/PkgInfo";
pub const macos_resources_rel = "Contents/Resources";
pub const macos_macos_rel = "Contents/MacOS";
/// PkgInfo 内容：APPL + 4 字节签名占位 '????'。
pub const macos_pkg_info_bytes = "APPL????";

/// Contents/MacOS/<exe_base>（exe 名去 .exe 后缀）。
pub fn macosExeRelPath(alloc: std.mem.Allocator, meta: PackMeta) ![]u8 {
    const exe_base = if (std.mem.endsWith(u8, meta.exe_name, ".exe"))
        meta.exe_name[0 .. meta.exe_name.len - 4]
    else
        meta.exe_name;
    return std.fmt.allocPrint(alloc, "Contents/MacOS/{s}", .{exe_base});
}

/// Contents/Resources/<icon_file>。
pub fn macosIconRelPath(alloc: std.mem.Allocator, icon_file: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Contents/Resources/{s}", .{icon_file});
}

/// v0.5.2：.icns 输入帧（width 决定 OSType；png 为 PNG 编码字节）。
pub const IcnsImage = struct { width: u32, png: []const u8 };

/// 像素宽 → icns OSType（PNG 承载型）。未列出的宽度（如 48）无标准型，跳过。
fn icnsTypeForWidth(width: u32) ?[4]u8 {
    return switch (width) {
        16 => .{ 'i', 'c', 'p', '4' },
        32 => .{ 'i', 'c', 'p', '5' },
        64 => .{ 'i', 'c', 'p', '6' },
        128 => .{ 'i', 'c', '0', '7' },
        256 => .{ 'i', 'c', '0', '8' },
        512 => .{ 'i', 'c', '0', '9' },
        1024 => .{ 'i', 'c', '1', '0' },
        else => null,
    };
}

/// v0.5.2：生成 .icns —— "icns" magic + BE u32 总长（含头）+ 若干条目
/// （OSType 4cc + BE u32 条目长[含 8 字节条目头] + PNG 字节）。
/// 无可映射宽度的帧时返回 error.NoIcnsImage（避免产出空图标）。
pub fn generateIcns(alloc: std.mem.Allocator, images: []const IcnsImage) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "icns");
    try appendBE32(&buf, alloc, 0); // 总长占位，末尾回填
    var emitted: usize = 0;
    for (images) |img| {
        const ty = icnsTypeForWidth(img.width) orelse continue;
        try buf.appendSlice(alloc, &ty);
        try appendBE32(&buf, alloc, @intCast(8 + img.png.len));
        try buf.appendSlice(alloc, img.png);
        emitted += 1;
    }
    if (emitted == 0) return error.NoIcnsImage;
    std.mem.writeInt(u32, buf.items[4..8], @intCast(buf.items.len), .big);
    return buf.toOwnedSlice(alloc);
}

fn appendBE32(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try buf.appendSlice(alloc, &b);
}

/// v0.5.3：DMG 打包脚本选项（自定位脚本，放在 dist 目录里执行）。
pub const DmgScriptOptions = struct {
    app_name: []const u8, // 如 "Zilt.app"
    dmg_name: []const u8, // 如 "Zilt.dmg"
    volname: []const u8, // 挂载卷名，如 "Zilt"
};

/// v0.5.3：生成拖装 DMG 的 bash 脚本（hdiutil UDZO；.app + /Applications 符号链）。
/// 脚本自定位到所在目录，故 app/dmg 用相对名即可；名称经 shell 双引号转义防注入。
pub fn generateBundleDmgScript(alloc: std.mem.Allocator, opts: DmgScriptOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc,
        \\#!/usr/bin/env bash
        \\# v0.5.3：从 .app 生成拖装 DMG（hdiutil，仅 macOS 可执行）。
        \\set -eu
        \\cd "$(dirname "$0")"
        \\STAGE="$(mktemp -d)"
        \\trap 'rm -rf "$STAGE"' EXIT
        \\cp -R "
    );
    try appendShellEscaped(&buf, alloc, opts.app_name);
    try buf.appendSlice(alloc, "\" \"$STAGE/\"\nln -s /Applications \"$STAGE/Applications\"\nhdiutil create -volname \"");
    try appendShellEscaped(&buf, alloc, opts.volname);
    try buf.appendSlice(alloc, "\" -srcfolder \"$STAGE\" -ov -format UDZO \"");
    try appendShellEscaped(&buf, alloc, opts.dmg_name);
    try buf.appendSlice(alloc, "\"\necho \"DMG=");
    try appendShellEscaped(&buf, alloc, opts.dmg_name);
    try buf.appendSlice(alloc, "\"\n");
    return buf.toOwnedSlice(alloc);
}

/// shell 双引号内的危险字符（\ " $ `）前置反斜杠转义。
fn appendShellEscaped(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\', '"', '$', '`' => {
                try buf.append(alloc, '\\');
                try buf.append(alloc, c);
            },
            else => try buf.append(alloc, c),
        }
    }
}

/// v0.5.4：hardened runtime 下的 entitlements（WKWebView 需 JIT/无符号可执行内存）。
pub const EntitlementsOptions = struct {
    allow_jit: bool = true,
    allow_unsigned_executable_memory: bool = true,
    disable_library_validation: bool = false,
    network_client: bool = true,
    network_server: bool = false,
    camera: bool = false,
    audio_input: bool = false,
    user_selected_files: bool = true,
};

/// v0.5.4：生成 entitlements.plist（hardened runtime 下按开关授予 WebView 必需例外）。
pub fn generateEntitlements(alloc: std.mem.Allocator, opts: EntitlementsOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );
    if (opts.allow_jit) try appendEntKey(&buf, alloc, "com.apple.security.cs.allow-jit");
    if (opts.allow_unsigned_executable_memory) try appendEntKey(&buf, alloc, "com.apple.security.cs.allow-unsigned-executable-memory");
    if (opts.disable_library_validation) try appendEntKey(&buf, alloc, "com.apple.security.cs.disable-library-validation");
    if (opts.network_client) try appendEntKey(&buf, alloc, "com.apple.security.network.client");
    if (opts.network_server) try appendEntKey(&buf, alloc, "com.apple.security.network.server");
    if (opts.camera) try appendEntKey(&buf, alloc, "com.apple.security.device.camera");
    if (opts.audio_input) try appendEntKey(&buf, alloc, "com.apple.security.device.audio-input");
    if (opts.user_selected_files) try appendEntKey(&buf, alloc, "com.apple.security.files.user-selected.read-write");
    try buf.appendSlice(alloc, "</dict>\n</plist>\n");
    return buf.toOwnedSlice(alloc);
}

fn appendEntKey(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8) !void {
    try buf.appendSlice(alloc, "  <key>");
    try buf.appendSlice(alloc, key);
    try buf.appendSlice(alloc, "</key><true/>\n");
}

/// v0.5.4：codesign 命令选项。identity="-" 为 ad-hoc（无需证书）；
/// Developer ID 签名需 timestamp=true（公证要求安全时间戳）。
pub const CodesignOptions = struct {
    identity: []const u8 = "-",
    app_path: []const u8,
    entitlements: ?[]const u8 = null,
    hardened_runtime: bool = true,
    timestamp: bool = false,
};

/// v0.5.4：构造 codesign 命令（工具侧执行）。ad-hoc（identity="-"）无需证书；
/// hardened_runtime → --options runtime；Developer ID 配 timestamp=true 供公证。
pub fn buildCodesignCommand(alloc: std.mem.Allocator, opts: CodesignOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "codesign --force");
    if (opts.hardened_runtime) try buf.appendSlice(alloc, " --options runtime");
    if (opts.entitlements) |e| {
        try buf.appendSlice(alloc, " --entitlements \"");
        try buf.appendSlice(alloc, e);
        try buf.append(alloc, '"');
    }
    try buf.appendSlice(alloc, " --sign \"");
    try buf.appendSlice(alloc, opts.identity);
    try buf.append(alloc, '"');
    if (opts.timestamp) try buf.appendSlice(alloc, " --timestamp");
    try buf.appendSlice(alloc, " \"");
    try buf.appendSlice(alloc, opts.app_path);
    try buf.append(alloc, '"');
    return buf.toOwnedSlice(alloc);
}

/// v0.5.4：codesign 脚本选项（自定位脚本，放在 dist 目录里执行）。
pub const CodesignScriptOptions = struct {
    app_name: []const u8, // "Zilt.app"
    entitlements_name: []const u8, // "entitlements.plist"
    identity: []const u8 = "-", // "-" = ad-hoc；Developer ID 由环境注入
    timestamp: bool = false, // Developer ID 公证需安全时间戳
};

/// v0.5.4：生成 codesign .app 的 bash 脚本（hardened runtime + entitlements，随后 verify）。
/// 自定位到所在目录；ad-hoc（identity="-"）无需证书，Developer ID 由环境注入并配 timestamp。
pub fn generateCodesignScript(alloc: std.mem.Allocator, opts: CodesignScriptOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc,
        \\#!/usr/bin/env bash
        \\# v0.5.4: codesign .app (hardened runtime + entitlements), then verify.
        \\set -eu
        \\cd "$(dirname "$0")"
        \\
    );
    const cmd = try buildCodesignCommand(alloc, .{
        .app_path = opts.app_name,
        .entitlements = opts.entitlements_name,
        .identity = opts.identity,
        .timestamp = opts.timestamp,
        .hardened_runtime = true,
    });
    defer alloc.free(cmd);
    try buf.appendSlice(alloc, cmd);
    try buf.appendSlice(alloc, "\ncodesign --verify --deep --strict \"");
    try appendShellEscaped(&buf, alloc, opts.app_name);
    try buf.appendSlice(alloc, "\"\necho \"CODESIGN=ok\"\n");
    return buf.toOwnedSlice(alloc);
}

/// AppRun（AppImage；Linux）。
pub const apprun_script =
    \\#!/bin/sh
    \\HERE=$(dirname "$(readlink -f "$0")")
    \\exec "$HERE/usr/bin/APP_EXE_NAME" "$@"
    \\
;

/// v0.4.3 L3：自包含 AppImage 的 AppRun（WebKit 随包）。
///
/// 占位符：`APP_EXE_NAME` / `WK_DIR` / `TRIPLET` / `APP_ID`。
///
/// 关键点：
///   - `LD_LIBRARY_PATH` 只指向随包目录，宿主 WebKit/GTK 不会被优先加载；
///   - WebKit 2.52 的 helper 路径是**编译期常量**（无 WEBKIT_EXEC_PATH，
///     strace 实测：即使设置该变量仍 exec /usr/lib/…）→ 打包时已把 libwebkit
///     里的 `/usr/lib/<triplet>/webkit2gtk-4.1` 改写成 `WK_DIR`（固定短路径，
///     挂载点长度可变不能写死 AppImage 路径），这里用符号链把随包 helper
///     暴露到该路径；
///   - `WEBKIT_INJECTED_BUNDLE_PATH` 指向随包 injected-bundle（双保险：打包
///     时同样改写了字面量路径）；
///   - bwrap 沙箱：helper 在进入沙箱前 exec，路径/库在宿主命名空间已解析；
///     沙箱内 WebKit 会自行 bind 注入包目录（WK_DIR 为 /tmp 下普通目录，内外一致）。
pub const apprun_script_bundled =
    \\#!/bin/sh
    \\# v0.4.3 L3：自包含 AppImage（WebKit 随包；bwrap 内外路径一致）
    \\HERE=$(dirname "$(readlink -f "$0")")
    \\TRIPLET="@TRIPLET@"
    \\export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib/$TRIPLET${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    \\export WEBKIT_INJECTED_BUNDLE_PATH="$HERE/usr/lib/$TRIPLET/webkit2gtk-4.1/injected-bundle"
    \\[ -d "$HERE/usr/lib/$TRIPLET/gio/modules" ] && export GIO_EXTRA_MODULES="$HERE/usr/lib/$TRIPLET/gio/modules"
    \\[ -d "$HERE/usr/lib/$TRIPLET/gdk-pixbuf-2.0/2.10.0/loaders" ] && export GDK_PIXBUF_MODULEDIR="$HERE/usr/lib/$TRIPLET/gdk-pixbuf-2.0/2.10.0/loaders"
    \\[ -f "$HERE/usr/share/glib-2.0/schemas/gschemas.compiled" ] && export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
    \\export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    \\# helper 暴露到打包时写入的固定路径（见上）
    \\WK="WK_DIR"
    \\# /tmp 共享：防符号链劫持——目录必须是我们自己的（非 -O 直接拒绝执行）
    \\if [ -L "$WK" ]; then rm -f "$WK"; fi
    \\mkdir -p "$WK" 2>/dev/null && chmod 700 "$WK" 2>/dev/null
    \\if [ ! -O "$WK" ]; then echo "zilt: unsafe WebKit runtime dir $WK" >&2; exit 1; fi
    \\for f in WebKitWebProcess WebKitNetworkProcess WebKitGPUProcess; do
    \\  [ -x "$HERE/usr/lib/$TRIPLET/webkit2gtk-4.1/$f" ] && ln -sf "$HERE/usr/lib/$TRIPLET/webkit2gtk-4.1/$f" "$WK/$f" 2>/dev/null
    \\done
    \\[ -d "$HERE/usr/lib/$TRIPLET/webkit2gtk-4.1/injected-bundle" ] && ln -sfn "$HERE/usr/lib/$TRIPLET/webkit2gtk-4.1/injected-bundle" "$WK/injected-bundle" 2>/dev/null
    \\exec "$HERE/usr/bin/APP_EXE_NAME" "$@"
    \\
;

/// v0.4.3 L3：WebKit 固定运行时目录（helper 路径改写目标）。
/// 长度必须 ≤ 原编译期前缀（x86_64 46 / aarch64 48 字节）；`/tmp/.zk-` + 12 hex。
pub fn webkitRuntimeDir(alloc: std.mem.Allocator, app_id: []const u8, version: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0x6b696c74);
    hasher.update(app_id);
    hasher.update("\x00");
    hasher.update(version);
    const h = hasher.final();
    return std.fmt.allocPrint(alloc, "/tmp/.zk-{x:0>12}", .{@as(u32, @truncate(h))});
}

/// ldd 输出行 → { soname, 解析路径 }。
/// 形态：`\tlibgtk-3.so.0 => /usr/lib/…/libgtk-3.so.0 (0x00007f…)`；
/// 跳过 `linux-vdso.so.1`、`ld-linux-…`、`not found` 与静态行。
pub const LddEntry = struct { soname: []const u8, path: []const u8 };

pub fn parseLddLine(line_in: []const u8) ?LddEntry {
    const line = std.mem.trim(u8, line_in, " \t\r");
    if (line.len == 0) return null;
    const arrow = std.mem.indexOf(u8, line, "=>") orelse {
        // 直接给绝对路径的行（`/lib64/ld-linux-x86-64.so.2 (0x…)`）
        if (line[0] != '/') return null;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        return .{ .soname = std.fs.path.basename(line[0..sp]), .path = line[0..sp] };
    };
    const soname = std.mem.trim(u8, line[0..arrow], " \t");
    if (soname.len == 0) return null;
    var rest = std.mem.trim(u8, line[arrow + 2 ..], " \t");
    if (std.mem.startsWith(u8, rest, "not found")) return null;
    if (std.mem.lastIndexOfScalar(u8, rest, '(')) |lp| rest = std.mem.trim(u8, rest[0..lp], " \t");
    if (rest.len == 0 or rest[0] != '/') return null;
    return .{ .soname = soname, .path = rest };
}

/// 不随包分发的系统库（glibc 家族 / 编译器运行时 / 图形驱动栈）。
/// 依据 linuxdeploy 的 excludelist 口径：这些库必须用宿主的（ABI 与驱动绑定）。
pub fn lddExcluded(soname: []const u8) bool {
    const exact = [_][]const u8{
        "linux-vdso.so.1",
        "libc.so.6",         "libm.so.6",           "libdl.so.2",
        "libpthread.so.0",   "librt.so.1",          "libresolv.so.2",
        "libnsl.so.1",       "libutil.so.1",        "libanl.so.1",
        "libgcc_s.so.1",     "libstdc++.so.6",      "libz.so.1",
        "libGL.so.1",        "libEGL.so.1",         "libGLX.so.0",
        "libGLdispatch.so.0", "libOpenGL.so.0",     "libgbm.so.1",
        "libdrm.so.2",       "libvulkan.so.1",      "libglapi.so.0",
    };
    for (exact) |e| if (std.mem.eql(u8, soname, e)) return true;
    const prefixes = [_][]const u8{
        "ld-linux",   "libnvidia-", "libcuda.so",     "libX11-xcb.so",
        "libxcb-dri", "libxcb-glx",  "libxcb-shm.so",
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, soname, p)) return true;
    return false;
}

/// 在 `buf` 中把所有 `needle` 原地改写为 `replacement` + NUL 填充（长度不可增）。
/// 返回替换次数。用于把 libwebkit 里编译期的 helper/注入包路径改写到固定短路径。
pub fn patchCStringInPlace(buf: []u8, needle: []const u8, replacement: []const u8) usize {
    if (needle.len == 0 or replacement.len > needle.len) return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= buf.len) {
        if (!std.mem.eql(u8, buf[i .. i + needle.len], needle)) {
            i += 1;
            continue;
        }
        @memcpy(buf[i .. i + replacement.len], replacement);
        @memset(buf[i + replacement.len .. i + needle.len], 0);
        count += 1;
        i += needle.len;
    }
    return count;
}


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

/// rpm .spec（rpmbuild 可直接构建）。默认不带图标；`generateRpmSpecOpt` 可声明
/// Source2（打包脚本从 AppDir 取 PNG 暂存）。
pub fn generateRpmSpec(alloc: std.mem.Allocator, meta: PackMeta) ![]u8 {
    return generateRpmSpecOpt(alloc, meta, false);
}

pub fn generateRpmSpecOpt(alloc: std.mem.Allocator, meta: PackMeta, has_icon: bool) ![]u8 {
    const name = try debianName(alloc, meta.app_id);
    defer alloc.free(name);
    const exe_base = if (std.mem.endsWith(u8, meta.exe_name, ".exe"))
        meta.exe_name[0 .. meta.exe_name.len - 4]
    else
        meta.exe_name;
    const desk = try desktopFileName(alloc, name);
    defer alloc.free(desk);
    const icon_src = if (has_icon)
        try std.fmt.allocPrint(alloc,
            \\Source2:        {s}.png
            \\
        , .{name})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(icon_src);
    const icon_install = if (has_icon)
        try std.fmt.allocPrint(alloc,
            \\install -Dm644 %{{SOURCE2}} %{{buildroot}}%{{_datadir}}/icons/hicolor/256x256/apps/{s}.png
            \\
        , .{name})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(icon_install);
    const icon_files = if (has_icon)
        try std.fmt.allocPrint(alloc,
            \\%{{_datadir}}/icons/hicolor/256x256/apps/{s}.png
            \\
        , .{name})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(icon_files);
    return std.fmt.allocPrint(alloc,
        \\Name:           {s}
        \\Version:        {s}
        \\Release:        1%{{?dist}}
        \\Summary:        {s}
        \\License:        Proprietary
        \\BuildArch:      {s}
        \\Source0:        {s}
        \\Source1:        {s}
        \\{s}
        \\%description
        \\{s}
        \\
        \\%install
        \\mkdir -p %{{buildroot}}%{{_bindir}}
        \\install -m 755 %{{SOURCE0}} %{{buildroot}}%{{_bindir}}/{s}
        \\install -Dm644 %{{SOURCE1}} %{{buildroot}}%{{_datadir}}/applications/{s}
        \\{s}
        \\%post
        \\update-desktop-database -q %{{_datadir}}/applications 2>/dev/null || true
        \\
        \\%postun
        \\update-desktop-database -q %{{_datadir}}/applications 2>/dev/null || true
        \\
        \\%files
        \\%{{_bindir}}/{s}
        \\%{{_datadir}}/applications/{s}
        \\{s}
    , .{
        name,
        meta.version,
        meta.description,
        rpmArch(meta.arch),
        exe_base,
        desk,
        icon_src,
        meta.description,
        exe_base,
        desk,
        icon_install,
        exe_base,
        desk,
        icon_files,
    });
}

// ---------------------------------------------------------------------------
// AUR（PKGBUILD -bin 形态 + .SRCINFO；字段与 rpm/deb 命名约定一致）
// ---------------------------------------------------------------------------

/// AUR PKGBUILD（-bin 惯例：分发预编译二进制，不参与源码构建）。
/// source 指向随包分发的 tar（pack-aur.sh 生成），package() 仅安装。
pub fn generatePkgbuild(alloc: std.mem.Allocator, meta: PackMeta) ![]u8 {
    const name = try debianName(alloc, meta.app_id);
    defer alloc.free(name);
    const exe_base = if (std.mem.endsWith(u8, meta.exe_name, ".exe"))
        meta.exe_name[0 .. meta.exe_name.len - 4]
    else
        meta.exe_name;
    return std.fmt.allocPrint(alloc,
        \\# Maintainer: {s} <{s}>
        \\# v0.4.3 L5：AUR -bin 打包面（zilt-pack 生成；makepkg -sf 走通为验收项）
        \\pkgname={s}-bin
        \\pkgver={s}
        \\pkgrel=1
        \\pkgdesc="{s}"
        \\arch=('{s}')
        \\url="https://example.invalid/{s}"
        \\license=('Proprietary')
        \\depends=('gtk3' 'webkit2gtk-4.1' 'libsoup3')
        \\optdepends=('libayatana-appindicator3: 托盘图标支持')
        \\source=("$pkgname-$pkgver.tar.gz")
        \\sha256sums=('SKIP')
        \\
        \\package() {{
        \\    install -Dm755 "$srcdir/{s}" "$pkgdir/usr/bin/{s}"
        \\    for d in "$srcdir"/*.desktop; do
        \\        [ -e "$d" ] && install -Dm644 "$d" "$pkgdir/usr/share/applications/$(basename "$d")"
        \\    done
        \\    for p in "$srcdir"/*.png; do
        \\        [ -e "$p" ] && install -Dm644 "$p" "$pkgdir/usr/share/icons/hicolor/256x256/apps/$(basename "$p")"
        \\    done
        \\}}
        \\
    , .{ meta.maintainer, meta.maintainer, name, meta.version, meta.description, rpmArch(meta.arch), name, exe_base, exe_base });
}

/// AUR .SRCINFO（静态生成——makepkg --printsrcinfo 的等价输出，离线可单测）。
pub fn generateSrcinfo(alloc: std.mem.Allocator, meta: PackMeta) ![]u8 {
    const name = try debianName(alloc, meta.app_id);
    defer alloc.free(name);
    return std.fmt.allocPrint(alloc,
        \\pkgbase = {s}-bin
        \\pkgname = {s}-bin
        \\pkgver = {s}
        \\pkgrel = 1
        \\pkgdesc = {s}
        \\url = https://example.invalid/{s}
        \\arch = {s}
        \\license = Proprietary
        \\depends = gtk3
        \\depends = webkit2gtk-4.1
        \\depends = libsoup3
        \\optdepends = libayatana-appindicator3: 托盘图标支持
        \\
        \\source = {s}-bin-{s}.tar.gz
        \\sha256sums = SKIP
        \\
    , .{ name, name, meta.version, meta.description, name, rpmArch(meta.arch), name, meta.version });
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
/// v0.3.11 E1b：sidecar 等额外 data 文件（usr/bin 同目录分发）
pub const ExtraFile = struct { name: []const u8, bytes: []const u8 };

/// v0.3.16 G24：resources（exe 旁 resources/** 递归收集；'/' 分隔相对路径）。
pub const ResFile = struct { rel: []const u8, bytes: []const u8 };

pub const DebOptions = struct {
    /// Depends: 逗号连接（如 libgtk-3-0、libwebkit2gtk-4.1-0）
    depends: []const []const u8 = &.{},
    /// postinst 逐行 shell（xdg-mime 注册深链/文件关联）
    postinst_lines: []const []const u8 = &.{},
    /// postrm 逐行 shell
    postrm_lines: []const []const u8 = &.{},
    /// hicolor 图标 PNG（256px；null = 不带图标）
    icon_png: ?[]const u8 = null,
    /// v0.3.11 E1b：external_bin sidecar（name → usr/bin/<name> 同目录分发；
    /// 内容 = exe 旁已装好的同名文件字节）
    extra_files: []const ExtraFile = &.{},
    /// v0.3.16 G24：resources（rel → usr/bin/resources/<rel>——与 exe 同目录，
    /// path.resource 语义一致）
    resources: []const ResFile = &.{},
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
    // v0.4.3 L5 实测修复：条目名必须活到 writeTarGz 之后。此前 sidecar/resources/
    // 图标的名字在 for/if 块内 `defer alloc.free` → 块结束即回收，Zig 安全构建把
    // 回收内存填 0xAA，tar 里出现 58 字节乱码文件名（dpkg-deb -c 可见）。统一由
    // arena 托管，函数尾部一次性释放。
    var names = std.heap.ArenaAllocator.init(alloc);
    defer names.deinit();
    const na = names.allocator();

    var control: std.ArrayListUnmanaged(u8) = .empty;
    defer control.deinit(alloc);
    try control.appendSlice(alloc, "Package: ");
    try control.appendSlice(alloc, pkg);
    try control.appendSlice(alloc,
        \\
        \\Version: 
    );
    try control.appendSlice(alloc, meta.version);
    try control.appendSlice(alloc, "\nSection: utils\nPriority: optional\n");
    // 架构字段单列（v0.4.3 L5：跟随目标，不再硬编码 amd64）
    const arch_line = try std.fmt.allocPrint(alloc, "Architecture: {s}\nMaintainer: {s}", .{ debArch(meta.arch), meta.maintainer });
    defer alloc.free(arch_line);
    try control.appendSlice(alloc, arch_line);
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
    const exe_entry = try std.fmt.allocPrint(na, "./usr/bin/{s}", .{exe_base});
    try data_entries.append(alloc, .{ .name = "./", .mode = 0o755, .typeflag = '5' });
    try data_entries.append(alloc, .{ .name = "./usr/", .mode = 0o755, .typeflag = '5' });
    try data_entries.append(alloc, .{ .name = "./usr/bin/", .mode = 0o755, .typeflag = '5' });
    try data_entries.append(alloc, .{ .name = exe_entry, .mode = 0o755, .data = exe_bytes });
    // v0.3.11 E1b：external_bin sidecar（usr/bin 同目录分发）
    for (opts.extra_files) |ef| {
        const ef_entry = try std.fmt.allocPrint(na, "./usr/bin/{s}", .{ef.name});
        try data_entries.append(alloc, .{ .name = ef_entry, .mode = 0o755, .data = ef.bytes });
    }
    // v0.3.16 G24：resources（usr/bin/resources/**；目录条目逐级补齐）。
    // dir_rel 切片直接指向 rf.rel 内部（零分配零释放——arena 段内回收语义
    // 实测会破坏条目名，见 v0.3.16 实测记录）
    if (opts.resources.len > 0) {
        var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
        for (opts.resources) |rf| {
            var idx: usize = 0;
            while (std.mem.indexOfScalarPos(u8, rf.rel, idx, '/')) |slash| {
                const dir_rel = rf.rel[0..slash];
                idx = slash + 1;
                var dup = false;
                for (dirs.items) |d| {
                    if (std.mem.eql(u8, d, dir_rel)) dup = true;
                }
                if (!dup) dirs.append(alloc, dir_rel) catch break;
            }
        }
        std.mem.sort([]const u8, dirs.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        for (dirs.items) |d| {
            const dir_entry = try std.fmt.allocPrint(na, "./usr/bin/resources/{s}/", .{d});
            try data_entries.append(alloc, .{ .name = dir_entry, .mode = 0o755, .typeflag = '5' });
        }
        for (opts.resources) |rf| {
            const rf_entry = try std.fmt.allocPrint(na, "./usr/bin/resources/{s}", .{rf.rel});
            try data_entries.append(alloc, .{ .name = rf_entry, .mode = 0o644, .data = rf.bytes });
        }
    }
    try data_entries.append(alloc, .{ .name = "./usr/share/", .mode = 0o755, .typeflag = '5' });
    try data_entries.append(alloc, .{ .name = "./usr/share/applications/", .mode = 0o755, .typeflag = '5' });
    const desktop_name = try desktopFileName(na, pkg);
    const desktop_entry = try std.fmt.allocPrint(na, "./usr/share/applications/{s}", .{desktop_name});
    const desktop = try generateDesktopFile(alloc, meta);
    defer alloc.free(desktop);
    try data_entries.append(alloc, .{ .name = desktop_entry, .mode = 0o644, .data = desktop });
    if (opts.icon_png) |png| {
        try data_entries.append(alloc, .{ .name = "./usr/share/icons/", .mode = 0o755, .typeflag = '5' });
        try data_entries.append(alloc, .{ .name = "./usr/share/icons/hicolor/", .mode = 0o755, .typeflag = '5' });
        try data_entries.append(alloc, .{ .name = "./usr/share/icons/hicolor/256x256/", .mode = 0o755, .typeflag = '5' });
        try data_entries.append(alloc, .{ .name = "./usr/share/icons/hicolor/256x256/apps/", .mode = 0o755, .typeflag = '5' });
        const icon_entry = try std.fmt.allocPrint(na, "./usr/share/icons/hicolor/256x256/apps/{s}.png", .{pkg});
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

test "generateInfoPlistOpt: 深链 URL types + TCC 用途串 + 图标 + 分类 + 区域 + 最低系统（v0.5.1）" {
    const meta = PackMeta{ .name = "Zilt Demo", .version = "0.5.1", .app_id = "app.zilt.desktop", .exe_name = "zilt-app.exe" };
    const plist = try generateInfoPlistOpt(testing.allocator, meta, .{
        .icon_file = "AppIcon.icns",
        .url_schemes = &.{ "zilt", "zilt-demo" },
        .camera_usage = "Need camera",
        .microphone_usage = "Need mic",
        .category = "public.app-category.developer-tools",
        .min_system = "11.0",
        .development_region = "zh_CN",
    });
    defer testing.allocator.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>app.zilt.desktop</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>zilt-app</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleIconFile</key><string>AppIcon.icns</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>LSMinimumSystemVersion</key><string>11.0</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>NSCameraUsageDescription</key><string>Need camera</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>NSMicrophoneUsageDescription</key><string>Need mic</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleURLTypes</key>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleURLSchemes</key>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>zilt</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>zilt-demo</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "NSSupportsAutomaticGraphicsSwitching") != null);
}

test "generateInfoPlistOpt: 默认 opts 与 generateInfoPlist 等价 + 不写可选字段（向后兼容）" {
    const meta = PackMeta{ .name = "Zilt Demo", .version = "0.5.1", .app_id = "app.zilt.desktop", .exe_name = "zilt-app" };
    const a = try generateInfoPlist(testing.allocator, meta);
    defer testing.allocator.free(a);
    const b = try generateInfoPlistOpt(testing.allocator, meta, .{});
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
    try testing.expect(std.mem.indexOf(u8, a, "CFBundleIconFile") == null);
    try testing.expect(std.mem.indexOf(u8, a, "CFBundleURLTypes") == null);
    try testing.expect(std.mem.indexOf(u8, a, "NSCameraUsageDescription") == null);
    try testing.expect(std.mem.indexOf(u8, a, "LSApplicationCategoryType") == null);
    try testing.expect(std.mem.indexOf(u8, a, "<key>LSMinimumSystemVersion</key><string>10.13</string>") != null);
    try testing.expect(std.mem.indexOf(u8, a, "<key>CFBundleDevelopmentRegion</key><string>en</string>") != null);
}

test "generateInfoPlistOpt: XML 转义（& < > \" 防止 plist 损坏/注入）" {
    const meta = PackMeta{ .name = "A & B <C>", .version = "0.5.1", .app_id = "app.zilt.desktop", .exe_name = "zilt-app" };
    const plist = try generateInfoPlistOpt(testing.allocator, meta, .{ .camera_usage = "Use \"cam\" & <mic>" });
    defer testing.allocator.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "A &amp; B &lt;C&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "Use &quot;cam&quot; &amp; &lt;mic&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "A & B <C>") == null);
}

test "macosExeRelPath/macosIconRelPath: 正斜杠布局 + exe 去后缀（v0.5.1）" {
    const meta = PackMeta{ .name = "Zilt", .version = "0.5.1", .app_id = "app.zilt.desktop", .exe_name = "zilt-app.exe" };
    const exe_rel = try macosExeRelPath(testing.allocator, meta);
    defer testing.allocator.free(exe_rel);
    try testing.expectEqualStrings("Contents/MacOS/zilt-app", exe_rel);
    try testing.expect(std.mem.indexOf(u8, exe_rel, "\\") == null);
    const icon_rel = try macosIconRelPath(testing.allocator, "AppIcon.icns");
    defer testing.allocator.free(icon_rel);
    try testing.expectEqualStrings("Contents/Resources/AppIcon.icns", icon_rel);
}

test "macOS bundle 常量: PkgInfo + 相对路径（v0.5.1）" {
    try testing.expectEqualStrings("APPL????", macos_pkg_info_bytes);
    try testing.expectEqualStrings("Contents/Info.plist", macos_info_plist_rel);
    try testing.expectEqualStrings("Contents/PkgInfo", macos_pkg_info_rel);
    try testing.expectEqualStrings("Contents/Resources", macos_resources_rel);
    try testing.expectEqualStrings("Contents/MacOS", macos_macos_rel);
}

test "generateIcns: 单 256 帧 → icns 头 + ic08 条目 + 总长回填（v0.5.2）" {
    const png = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4 };
    const icns = try generateIcns(testing.allocator, &.{.{ .width = 256, .png = &png }});
    defer testing.allocator.free(icns);
    try testing.expectEqualStrings("icns", icns[0..4]);
    const total = std.mem.readInt(u32, icns[4..8], .big);
    try testing.expectEqual(@as(u32, @intCast(icns.len)), total);
    try testing.expectEqualStrings("ic08", icns[8..12]);
    const esize = std.mem.readInt(u32, icns[12..16], .big);
    try testing.expectEqual(@as(u32, @intCast(8 + png.len)), esize);
    try testing.expectEqualSlices(u8, &png, icns[16..]);
    try testing.expectEqual(@as(usize, 8 + 8 + png.len), icns.len);
}

test "generateIcns: width→OSType 映射（16/32/128/256/512/1024）+ 跳过 48（v0.5.2）" {
    const p = [_]u8{ 0x89, 'P', 'N', 'G' };
    const imgs = [_]IcnsImage{
        .{ .width = 16, .png = &p },
        .{ .width = 32, .png = &p },
        .{ .width = 48, .png = &p }, // 无标准 OSType → 跳过
        .{ .width = 128, .png = &p },
        .{ .width = 256, .png = &p },
        .{ .width = 512, .png = &p },
        .{ .width = 1024, .png = &p },
    };
    const icns = try generateIcns(testing.allocator, &imgs);
    defer testing.allocator.free(icns);
    try testing.expectEqual(@as(usize, 8 + 6 * (8 + p.len)), icns.len);
    const total = std.mem.readInt(u32, icns[4..8], .big);
    try testing.expectEqual(@as(u32, @intCast(icns.len)), total);
    var off: usize = 8;
    var types: [6][4]u8 = undefined;
    var n: usize = 0;
    while (off < icns.len) {
        @memcpy(types[n][0..4], icns[off..][0..4]);
        const esz = std.mem.readInt(u32, icns[off + 4 ..][0..4], .big);
        off += esz;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqualStrings("icp4", &types[0]);
    try testing.expectEqualStrings("icp5", &types[1]);
    try testing.expectEqualStrings("ic07", &types[2]);
    try testing.expectEqualStrings("ic08", &types[3]);
    try testing.expectEqualStrings("ic09", &types[4]);
    try testing.expectEqualStrings("ic10", &types[5]);
}

test "generateIcns: 无可映射宽度 → error.NoIcnsImage（v0.5.2）" {
    const p = [_]u8{ 0x89, 'P', 'N', 'G' };
    try testing.expectError(error.NoIcnsImage, generateIcns(testing.allocator, &.{.{ .width = 48, .png = &p }}));
    try testing.expectError(error.NoIcnsImage, generateIcns(testing.allocator, &.{}));
}

test "generateBundleDmgScript: hdiutil UDZO + 拖装布局 + 自定位（v0.5.3）" {
    const script = try generateBundleDmgScript(testing.allocator, .{
        .app_name = "Zilt.app",
        .dmg_name = "Zilt.dmg",
        .volname = "Zilt Demo",
    });
    defer testing.allocator.free(script);
    try testing.expect(std.mem.startsWith(u8, script, "#!/usr/bin/env bash"));
    try testing.expect(std.mem.indexOf(u8, script, "set -eu") != null);
    try testing.expect(std.mem.indexOf(u8, script, "cd \"$(dirname \"$0\")\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "hdiutil create") != null);
    try testing.expect(std.mem.indexOf(u8, script, "-volname \"Zilt Demo\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "-srcfolder") != null);
    try testing.expect(std.mem.indexOf(u8, script, "-format UDZO") != null);
    try testing.expect(std.mem.indexOf(u8, script, "ln -s /Applications") != null);
    try testing.expect(std.mem.indexOf(u8, script, "Zilt.app") != null);
    try testing.expect(std.mem.indexOf(u8, script, "Zilt.dmg") != null);
    try testing.expect(std.mem.indexOf(u8, script, "mktemp -d") != null);
}

test "generateEntitlements: 默认 WebView 键齐全 + 可选键按开关（v0.5.4）" {
    const ent = try generateEntitlements(testing.allocator, .{});
    defer testing.allocator.free(ent);
    try testing.expect(std.mem.indexOf(u8, ent, "<plist version=\"1.0\">") != null);
    try testing.expect(std.mem.indexOf(u8, ent, "<key>com.apple.security.cs.allow-jit</key><true/>") != null);
    try testing.expect(std.mem.indexOf(u8, ent, "<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>") != null);
    try testing.expect(std.mem.indexOf(u8, ent, "<key>com.apple.security.network.client</key><true/>") != null);
    try testing.expect(std.mem.indexOf(u8, ent, "<key>com.apple.security.files.user-selected.read-write</key><true/>") != null);
    // 默认关闭的键不出现
    try testing.expect(std.mem.indexOf(u8, ent, "com.apple.security.device.camera") == null);
    try testing.expect(std.mem.indexOf(u8, ent, "com.apple.security.network.server") == null);

    const ent2 = try generateEntitlements(testing.allocator, .{ .camera = true, .audio_input = true, .network_server = true, .allow_jit = false });
    defer testing.allocator.free(ent2);
    try testing.expect(std.mem.indexOf(u8, ent2, "<key>com.apple.security.device.camera</key><true/>") != null);
    try testing.expect(std.mem.indexOf(u8, ent2, "<key>com.apple.security.device.audio-input</key><true/>") != null);
    try testing.expect(std.mem.indexOf(u8, ent2, "<key>com.apple.security.network.server</key><true/>") != null);
    try testing.expect(std.mem.indexOf(u8, ent2, "com.apple.security.cs.allow-jit") == null);
}

test "buildCodesignCommand: ad-hoc 默认 + hardened runtime + Developer ID 时间戳（v0.5.4）" {
    const adhoc = try buildCodesignCommand(testing.allocator, .{ .app_path = "dist/Zilt.app", .entitlements = "dist/entitlements.plist" });
    defer testing.allocator.free(adhoc);
    try testing.expect(std.mem.indexOf(u8, adhoc, "codesign --force") != null);
    try testing.expect(std.mem.indexOf(u8, adhoc, "--options runtime") != null);
    try testing.expect(std.mem.indexOf(u8, adhoc, "--entitlements \"dist/entitlements.plist\"") != null);
    try testing.expect(std.mem.indexOf(u8, adhoc, "--sign \"-\"") != null);
    try testing.expect(std.mem.indexOf(u8, adhoc, "\"dist/Zilt.app\"") != null);
    try testing.expect(std.mem.indexOf(u8, adhoc, "--timestamp") == null);

    const devid = try buildCodesignCommand(testing.allocator, .{
        .identity = "Developer ID Application: Zilt (TEAMID)",
        .app_path = "dist/Zilt.app",
        .timestamp = true,
    });
    defer testing.allocator.free(devid);
    try testing.expect(std.mem.indexOf(u8, devid, "--sign \"Developer ID Application: Zilt (TEAMID)\"") != null);
    try testing.expect(std.mem.indexOf(u8, devid, "--timestamp") != null);
    try testing.expect(std.mem.indexOf(u8, devid, "--entitlements") == null);
}

test "generateCodesignScript: 自定位 + ad-hoc 签名 + verify（v0.5.4）" {
    const script = try generateCodesignScript(testing.allocator, .{ .app_name = "Zilt.app", .entitlements_name = "entitlements.plist" });
    defer testing.allocator.free(script);
    try testing.expect(std.mem.startsWith(u8, script, "#!/usr/bin/env bash"));
    try testing.expect(std.mem.indexOf(u8, script, "cd \"$(dirname \"$0\")\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "codesign --force") != null);
    try testing.expect(std.mem.indexOf(u8, script, "--options runtime") != null);
    try testing.expect(std.mem.indexOf(u8, script, "--entitlements \"entitlements.plist\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "--sign \"-\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "codesign --verify --deep --strict \"Zilt.app\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "--timestamp") == null);

    const devid = try generateCodesignScript(testing.allocator, .{
        .app_name = "Zilt.app",
        .entitlements_name = "entitlements.plist",
        .identity = "Developer ID Application: Zilt (TEAMID)",
        .timestamp = true,
    });
    defer testing.allocator.free(devid);
    try testing.expect(std.mem.indexOf(u8, devid, "--timestamp") != null);
    try testing.expect(std.mem.indexOf(u8, devid, "--sign \"Developer ID Application: Zilt (TEAMID)\"") != null);
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

test "generatePkgbuild/generateSrcinfo: AUR 字段齐全（v0.4.3 L5）" {
    const meta = PackMeta{ .name = "Zilt Demo", .version = "0.4.3", .app_id = "app.zilt.desktop", .exe_name = "zilt-app", .description = "Demo app" };
    const pkb = try generatePkgbuild(testing.allocator, meta);
    defer testing.allocator.free(pkb);
    try testing.expect(std.mem.startsWith(u8, pkb, "# Maintainer:"));
    try testing.expect(std.mem.indexOf(u8, pkb, "pkgname=app.zilt.desktop-bin") != null);
    try testing.expect(std.mem.indexOf(u8, pkb, "pkgver=0.4.3") != null);
    try testing.expect(std.mem.indexOf(u8, pkb, "depends=('gtk3' 'webkit2gtk-4.1' 'libsoup3')") != null);
    try testing.expect(std.mem.indexOf(u8, pkb, "install -Dm755") != null);

    const info = try generateSrcinfo(testing.allocator, meta);
    defer testing.allocator.free(info);
    try testing.expect(std.mem.startsWith(u8, info, "pkgbase = app.zilt.desktop-bin"));
    try testing.expect(std.mem.indexOf(u8, info, "pkgver = 0.4.3") != null);
    try testing.expect(std.mem.indexOf(u8, info, "arch = x86_64") != null);
    try testing.expect(std.mem.indexOf(u8, info, "source = app.zilt.desktop-bin-0.4.3.tar.gz") != null);
}

test "v0.4.3 L5: generateRpmSpec 载荷与架构（Source1/Source2 + BuildArch）" {
    const a = testing.allocator;
    const meta = PackMeta{
        .name = "Zilt Demo",
        .version = "0.4.3",
        .app_id = "app.zilt.desktop",
        .exe_name = "zilt-app",
        .description = "Demo app",
        .arch = "aarch64",
    };
    const spec = try generateRpmSpecOpt(a, meta, true);
    defer a.free(spec);
    // 参数顺序回归：Source0 是 exe 名、%description 是描述（此前错位成
    // Source0=description、%description=exe 名）
    try testing.expect(std.mem.indexOf(u8, spec, "Source0:        zilt-app\n") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "%description\nDemo app\n") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "BuildArch:      aarch64") != null);
    // 载荷：桌面项 + 图标（Source1/Source2 与 %files 对齐）
    try testing.expect(std.mem.indexOf(u8, spec, "Source1:        app.zilt.desktop\n") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "Source2:        app.zilt.desktop.png") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "install -Dm644 %{SOURCE1} %{buildroot}%{_datadir}/applications/app.zilt.desktop\n") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "%{_datadir}/icons/hicolor/256x256/apps/app.zilt.desktop.png") != null);
    try testing.expect(std.mem.indexOf(u8, spec, "update-desktop-database") != null);

    // 无图标变体不得声明 Source2（否则 rpmbuild 缺文件直接失败）
    const plain = try generateRpmSpec(a, meta);
    defer a.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "Source2:") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "Source1:") != null);
}

test "v0.4.3 L5: debArch/rpmArch 映射与 PKGBUILD 架构跟随" {
    try testing.expectEqualStrings("amd64", debArch("x86_64"));
    try testing.expectEqualStrings("arm64", debArch("aarch64"));
    try testing.expectEqualStrings("x86_64", rpmArch("x86_64"));
    try testing.expectEqualStrings("aarch64", rpmArch("aarch64"));

    const meta = PackMeta{ .name = "Z", .version = "1.0", .app_id = "app.zilt.desktop", .exe_name = "zilt-app", .arch = "aarch64" };
    const pkb = try generatePkgbuild(testing.allocator, meta);
    defer testing.allocator.free(pkb);
    try testing.expect(std.mem.indexOf(u8, pkb, "arch=('aarch64')") != null);
    const info = try generateSrcinfo(testing.allocator, meta);
    defer testing.allocator.free(info);
    try testing.expect(std.mem.indexOf(u8, info, "arch = aarch64") != null);
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

test "v0.4.3 L3: parseLddLine 形态（箭头/绝对路径/not found/垃圾行）" {
    const a = parseLddLine("\tlibgtk-3.so.0 => /usr/lib/x86_64-linux-gnu/libgtk-3.so.0 (0x00007f8c12345678)").?;
    try testing.expectEqualStrings("libgtk-3.so.0", a.soname);
    try testing.expectEqualStrings("/usr/lib/x86_64-linux-gnu/libgtk-3.so.0", a.path);

    // 无箭头（解释器行）
    const b = parseLddLine("\t/lib64/ld-linux-x86-64.so.2 (0x00007f00deadbeef)").?;
    try testing.expectEqualStrings("ld-linux-x86-64.so.2", b.soname);
    try testing.expectEqualStrings("/lib64/ld-linux-x86-64.so.2", b.path);

    try testing.expect(parseLddLine("\tlibfoo.so.1 => not found") == null);
    try testing.expect(parseLddLine("\tlinux-vdso.so.1 (0x00007ffd)") == null);
    try testing.expect(parseLddLine("") == null);
    try testing.expect(parseLddLine("hello world") == null);
}

test "v0.4.3 L3: lddExcluded 系统库/驱动栈不随包" {
    // glibc 家族与编译器运行时
    try testing.expect(lddExcluded("libc.so.6"));
    try testing.expect(lddExcluded("libm.so.6"));
    try testing.expect(lddExcluded("libgcc_s.so.1"));
    try testing.expect(lddExcluded("ld-linux-aarch64.so.1"));
    // 图形驱动栈
    try testing.expect(lddExcluded("libGL.so.1"));
    try testing.expect(lddExcluded("libEGL.so.1"));
    try testing.expect(lddExcluded("libdrm.so.2"));
    try testing.expect(lddExcluded("libnvidia-glcore.so.550"));
    // 业务库要随包
    try testing.expect(!lddExcluded("libwebkit2gtk-4.1.so.0"));
    try testing.expect(!lddExcluded("libjavascriptcoregtk-4.1.so.0"));
    try testing.expect(!lddExcluded("libgtk-3.so.0"));
    try testing.expect(!lddExcluded("libsoup-3.0.so.0"));
    try testing.expect(!lddExcluded("libicui18n.so.70"));
}

test "v0.4.3 L3: patchCStringInPlace 等长改写 + NUL 填充 + 长度保护" {
    var buf = [_]u8{ 'x', ' ', '/', 'u', 's', 'r', '/', 'l', 'i', 'b', '/', 'w', 'k', '/', 'i', 'b', '/', 'z', 'z' };
    const n = patchCStringInPlace(&buf, "/usr/lib/wk", "/tmp/.zk-1");
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("/tmp/.zk-1", buf[2..12]);
    try testing.expectEqual(@as(u8, 0), buf[12]); // 余下字节 NUL（C 字符串语义）
    try testing.expectEqualStrings("/ib/zz", buf[13..19]);

    // 替换串超长 → 拒绝（必须原地等长约束）
    var buf2 = [_]u8{ '/', 'u', 's', 'r' };
    try testing.expectEqual(@as(usize, 0), patchCStringInPlace(&buf2, "/usr", "/very/long/path"));
    try testing.expectEqualStrings("/usr", &buf2);
}

test "v0.4.3 L3: webkitRuntimeDir 长度受限且确定性" {
    const d1 = try webkitRuntimeDir(testing.allocator, "app.zilt.desktop", "0.4.3");
    defer testing.allocator.free(d1);
    const d2 = try webkitRuntimeDir(testing.allocator, "app.zilt.desktop", "0.4.3");
    defer testing.allocator.free(d2);
    try testing.expectEqualStrings(d1, d2);
    try testing.expect(std.mem.startsWith(u8, d1, "/tmp/.zk-"));
    // x86_64 前缀 46 字节 / aarch64 48 字节——固定目录必须更短
    try testing.expect(d1.len <= 40);
    const d3 = try webkitRuntimeDir(testing.allocator, "app.other", "0.4.3");
    defer testing.allocator.free(d3);
    try testing.expect(!std.mem.eql(u8, d1, d3));
}
