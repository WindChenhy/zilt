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
        \\Source0:        {s}
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
    , .{ name, meta.version, meta.description, meta.description, exe_base, exe_base, exe_base });
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
        \\arch=('x86_64')
        \\url="https://example.invalid/{s}"
        \\license=('Proprietary')
        \\depends=('gtk3' 'webkit2gtk-4.1' 'libsoup3')
        \\optdepends=('libayatana-appindicator3: 托盘图标支持')
        \\source=("$pkgname-$pkgver.tar.gz")
        \\sha256sums=('SKIP')
        \\noextract=()
        \\
        \\package() {{
        \\    install -Dm755 "$srcdir/{s}" "$pkgdir/usr/bin/{s}"
        \\    for d in "$srcdir"/*.desktop; do
        \\        [ -e "$d" ] && install -Dm644 "$d" "$pkgdir/usr/share/applications/$(basename "$d")"
        \\    done
        \\}}
        \\
    , .{ meta.maintainer, meta.maintainer, name, meta.version, meta.description, name, exe_base, exe_base });
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
        \\arch = x86_64
        \\license = Proprietary
        \\depends = gtk3
        \\depends = webkit2gtk-4.1
        \\depends = libsoup3
        \\optdepends = libayatana-appindicator3: 托盘图标支持
        \\noextract = 
        \\
        \\source = {s}-bin-{s}.tar.gz
        \\sha256sums = SKIP
        \\
    , .{ name, name, meta.version, meta.description, name, name, meta.version });
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
    // v0.3.11 E1b：external_bin sidecar（usr/bin 同目录分发）
    for (opts.extra_files) |ef| {
        const ef_entry = try std.fmt.allocPrint(alloc, "./usr/bin/{s}", .{ef.name});
        defer alloc.free(ef_entry);
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
            const dir_entry = try std.fmt.allocPrint(alloc, "./usr/bin/resources/{s}/", .{d});
            try data_entries.append(alloc, .{ .name = dir_entry, .mode = 0o755, .typeflag = '5' });
        }
        for (opts.resources) |rf| {
            const rf_entry = try std.fmt.allocPrint(alloc, "./usr/bin/resources/{s}", .{rf.rel});
            try data_entries.append(alloc, .{ .name = rf_entry, .mode = 0o644, .data = rf.bytes });
        }
    }
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
