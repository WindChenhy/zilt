//! Linux 打包编排（v0.2.4）：`ZILT_PACK_OUT=<dir> zig build pack`（Linux 目标）。
//!
//! 产物（dist/）：
//!   - `<pkg>_<ver>_amd64.deb` —— 真实 ar 包（pack_formats.buildDebOpt：Depends
//!     libgtk-3-0/libwebkit2gtk-4.1-0/libsqlite3-0、postinst 用 xdg-mime 注册深链、
//!     hicolor 256 PNG 图标、/usr/share/applications 桌面项）
//!   - `<pkg>/` AppDir —— AppRun + usr/bin + 桌面项 + hicolor 多尺寸图标
//!     （AppRun 可直接执行；`mksquashfs` 存在时产出 `<pkg>.squashfs` 真实镜像 +
//!     `build-appimage.sh`（下载官方 runtime 拼单文件 AppImage，离线环境跳过）
//!   - `flatpak/<pkg>.json` —— Flatpak manifest（org.gnome.Platform runtime）
//!   - `<pkg>.spec` —— rpm spec（rpmbuild -bb 可构建）
//!
//! argv[1] = 应用 exe（build.zig 注入）；图标取 `project.icon` 或内置 zilt.ico
//!（ico 帧即 PNG，msix.extractPngFrames 提取）。
const std = @import("std");
// 直接按路径引用纯模块（避免把 zilt 根模块——含 GTK 绑定——拖进打包工具）
const pack_formats = @import("zilt/pack_formats.zig");
const msix = @import("zilt/msix.zig");
const app_meta = @import("app_meta.zig");

const PackMeta = pack_formats.PackMeta;
// v0.2.2 的 .desktop 生成器（单一来源；pack 是 Linux 专属工具）
const desktop_entry = @import("zilt/platform/linux/desktop_entry.zig");

const Allocator = std.mem.Allocator;

/// 惰性线程同步 Io（读 exe/ico；同后端模式）。
var g_io: std.Io.Threaded = undefined;
var g_io_ready = false;
fn sharedIo() std.Io {
    if (!g_io_ready) {
        g_io = .init(std.heap.page_allocator, .{});
        g_io_ready = true;
    }
    return g_io.io();
}

fn readFileAlloc(alloc: Allocator, path: []const u8, max: usize) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(sharedIo(), path, alloc, .limited(max)) catch null;
}

/// /proc/self/cmdline 全量读取（libc stdio；0.17 的 readFileAlloc 依赖 stat size，
/// procfs 恒报 0——同 backend 的 collectArgv 坑）。
fn readCmdlineAlloc(alloc: Allocator) ![]u8 {
    const f = std.c.fopen("/proc/self/cmdline", "rb") orelse return error.CmdlineUnavailable;
    defer _ = std.c.fclose(f);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&tmp, 1, tmp.len, f);
        if (n == 0) break;
        try buf.appendSlice(alloc, tmp[0..n]);
        if (buf.items.len > 64 * 1024) return error.CmdlineTooLong;
    }
    return buf.items;
}

fn getEnv(alloc: Allocator, key: [:0]const u8) ?[]u8 {
    const v = std.c.getenv(key.ptr) orelse return null;
    return alloc.dupe(u8, std.mem.span(v)) catch null;
}

fn pathJoin(alloc: Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ a, b });
}

fn mkDirs(alloc: Allocator, dir: []const u8) void {
    const z = alloc.allocSentinel(u8, dir.len, 0) catch return;
    defer alloc.free(z);
    @memcpy(z, dir);
    var idx: usize = 1;
    while (idx <= dir.len) : (idx += 1) {
        if (idx == dir.len or z[idx] == '/') {
            const saved = z[idx];
            z[idx] = 0;
            _ = std.c.mkdir(z.ptr, 0o755);
            z[idx] = saved;
        }
    }
}

fn writeFile(alloc: Allocator, path: []const u8, data: []const u8, mode: u32) bool {
    const z = alloc.allocSentinel(u8, path.len, 0) catch return false;
    defer alloc.free(z);
    @memcpy(z, path);
    // libc stdio + chmod（Io.Dir.writeFile 无 mode 参数；AppRun 需要 755）
    const f = std.c.fopen(z.ptr, "wb") orelse {
        std.debug.print("[pack] write failed {s}\n", .{path});
        return false;
    };
    _ = std.c.fwrite(data.ptr, 1, data.len, f);
    _ = std.c.fclose(f);
    return std.c.chmod(z.ptr, @intCast(mode)) == 0;
}

fn exeBaseName(alloc: Allocator, meta: PackMeta) ![]const u8 {
    if (std.mem.endsWith(u8, meta.exe_name, ".exe")) return meta.exe_name[0 .. meta.exe_name.len - 4];
    _ = alloc;
    return meta.exe_name;
}

/// 桌面项文件名：`<pkg>.desktop`；pkg 已以 .desktop 结尾时不重复拼接
/// （v0.2.7 修正：app_id `app.zilt.desktop` 此前会生成
/// `app.zilt.desktop.desktop`——与运行时 desktop_entry.entryFileName 同规则）。
fn desktopFileName(alloc: Allocator, pkg: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, pkg, ".desktop")) return alloc.dupe(u8, pkg);
    return std.fmt.allocPrint(alloc, "{s}.desktop", .{pkg});
}

/// Flatpak manifest（app id 反转为反域名；runtime 用 GNOME 45 平台）。
fn generateFlatpakManifest(alloc: Allocator, meta: PackMeta) ![]u8 {
    const pkg = try pack_formats.debianName(alloc, meta.app_id);
    defer alloc.free(pkg);
    const desktop_name = try desktopFileName(alloc, pkg);
    defer alloc.free(desktop_name);
    const exe_base = try exeBaseName(alloc, meta);
    // app.zilt.desktop → desktop.zilt.app（反域名）
    var app_id: std.ArrayListUnmanaged(u8) = .empty;
    defer app_id.deinit(alloc);
    var segs = std.mem.splitScalar(u8, meta.app_id, '.');
    var seg_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seg_list.deinit(alloc);
    while (segs.next()) |seg| seg_list.append(alloc, seg) catch break;
    var i: usize = seg_list.items.len;
    while (i > 0) {
        i -= 1;
        try app_id.appendSlice(alloc, seg_list.items[i]);
        if (i != 0) try app_id.append(alloc, '.');
    }
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "app-id": "{s}",
        \\  "runtime": "org.gnome.Platform",
        \\  "runtime-version": "45",
        \\  "sdk": "org.gnome.Sdk",
        \\  "command": "{s}",
        \\  "finish-args": [
        \\    "--share=ipc",
        \\    "--socket=x11",
        \\    "--socket=wayland",
        \\    "--device=dri",
        \\    "--share=network",
        \\    "--filesystem=home"
        \\  ],
        \\  "modules": [
        \\    {{
        \\      "name": "{s}",
        \\      "buildsystem": "simple",
        \\      "build-commands": [
        \\        "install -Dm755 {s} /app/bin/{s}",
        \\        "install -Dm644 {s} /app/share/applications/{s}"
        \\      ],
        \\      "sources": [ {{ "type": "dir", "path": "." }} ]
        \\    }}
        \\  ]
        \\}}
    , .{ app_id.items, exe_base, pkg, exe_base, exe_base, desktop_name, desktop_name });
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // argv[1] = exe 输入（build.zig addArtifactArg 注入）。0.17 的 argv 走
    // std.process.Init（main 入口）——工具直接读 /proc/self/cmdline（libc stdio）。
    const exe_path: ?[]const u8 = blk: {
        const cmdline = readCmdlineAlloc(alloc) catch break :blk null;
        // 第一段是程序自身；第二段即 argv[1]
        var it = std.mem.splitScalar(u8, cmdline, 0);
        _ = it.next() orelse break :blk null;
        const second = it.next() orelse break :blk null;
        if (second.len == 0) break :blk null;
        break :blk second;
    };

    const out_dir = getEnv(alloc, "ZILT_PACK_OUT") orelse "dist";
    mkDirs(alloc, out_dir);

    const meta = PackMeta{
        .name = app_meta.app_name,
        .version = app_meta.version,
        .app_id = app_meta.app_id,
        .exe_name = app_meta.exe_name,
        .maintainer = "Zilt App",
        .description = app_meta.app_name,
    };
    const pkg = try pack_formats.debianName(alloc, meta.app_id);
    const desktop_name = try desktopFileName(alloc, pkg);
    const exe_base = try exeBaseName(alloc, meta);

    // 图标：project.icon 或内置 zilt.ico（帧即 PNG）
    const icon_path = getEnv(alloc, "ZILT_ICON") orelse "src/zilt/assets/zilt.ico";
    var icon_png: ?[]const u8 = null;
    if (readFileAlloc(alloc, icon_path, 4 * 1024 * 1024)) |ico_bytes| {
        const frames = msix.extractPngFrames(alloc, ico_bytes) catch null;
        if (frames) |fs| {
            if (msix.largestPngFrame(fs)) |f| icon_png = f.png;
        }
    } else {
        std.debug.print("[pack] 图标 {s} 缺失（deb/AppDir 不带 PNG）\n", .{icon_path});
    }

    // ---- 1) .deb ----
    const exe_bytes = if (exe_path) |p|
        readFileAlloc(alloc, p, 256 * 1024 * 1024)
    else
        null;
    if (exe_bytes == null) {
        std.debug.print("[pack] 缺少 exe 参数（zig build pack 会注入 argv[1]）\n", .{});
        return error.ExeArgRequired;
    }
    const scheme = blk: {
        const v = getEnv(alloc, "ZILT_DEB_SCHEME") orelse break :blk "zilt";
        break :blk v;
    };
    const mime_line = try std.fmt.allocPrint(alloc, "xdg-mime default {s} x-scheme-handler/{s} || true", .{ desktop_name, scheme });
    // v0.3.11 E1b：external_bin sidecar 收集（源 exe 旁 <name>[.exe]；deb/AppDir 共用）
    const src_dir = std.fs.path.dirname(exe_path orelse "") orelse "";
    var sidecar_bytes: std.ArrayListUnmanaged(pack_formats.ExtraFile) = .empty;
    inline for (app_meta.external_bin) |sc_name| {
        const ext: []const u8 = if (@import("builtin").os.tag == .windows) ".exe" else "";
        const src_sc = try pathJoin(alloc, src_dir, try std.fmt.allocPrint(alloc, "{s}{s}", .{ sc_name, ext }));
        const sc_b = readFileAlloc(alloc, src_sc, 512 * 1024 * 1024) catch continue; // 缺失跳过
        try sidecar_bytes.append(alloc, .{ .name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ sc_name, ext }), .bytes = sc_b });
    }
    const deb = try pack_formats.buildDebOpt(alloc, meta, exe_bytes.?, .{
        .depends = &.{ "libgtk-3-0", "libwebkit2gtk-4.1-0", "libsqlite3-0" },
        .postinst_lines = &.{mime_line},
        .icon_png = icon_png,
        .extra_files = sidecar_bytes.items,
    });
    const deb_out = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}_{s}_amd64.deb", .{ pkg, meta.version }));
    if (!writeFile(alloc, deb_out, deb, 0o644)) return error.WriteFailed;
    std.debug.print("[pack] deb -> {s}（{d} bytes）\n", .{ deb_out, deb.len });

    // ---- 2) AppDir（AppRun 可直接执行）+ squashfs ----
    const app_dir = try pathJoin(alloc, out_dir, pkg);
    mkDirs(alloc, app_dir);
    inline for (.{ "usr/bin", "usr/share/applications", "usr/share/icons/hicolor/256x256/apps" }) |sub| {
        mkDirs(alloc, try pathJoin(alloc, app_dir, sub));
    }
    const apprun = pack_formats.apprun_script;
    const apprun_filled = try std.mem.replaceOwned(u8, alloc, apprun, "APP_EXE_NAME", exe_base);
    if (!writeFile(alloc, try pathJoin(alloc, app_dir, "AppRun"), apprun_filled, 0o755)) return error.WriteFailed;
    const app_bin = try pathJoin(alloc, app_dir, try std.fmt.allocPrint(alloc, "usr/bin/{s}", .{exe_base}));
    if (!writeFile(alloc, app_bin, exe_bytes.?, 0o755)) return error.WriteFailed;

    // v0.3.11 E1b：sidecar → AppDir usr/bin 同名（与 deb 的 extra_files 同源）
    for (sidecar_bytes.items) |sc| {
        const dst_sc = try pathJoin(alloc, app_dir, try std.fmt.allocPrint(alloc, "usr/bin/{s}", .{sc.name}));
        if (!writeFile(alloc, dst_sc, sc.bytes, 0o755)) return error.WriteFailed;
    }

    // 桌面项：与 deb 同一生成器（v0.2.2 的 desktop_entry）
    const desktop_text = try desktop_entry.content(alloc, .{
        .name = meta.name,
        .exec = exe_base,
        .icon = pkg,
        .comment = meta.description,
        .mime_types = &.{try std.fmt.allocPrint(alloc, "x-scheme-handler/{s}", .{scheme})},
        .wmclass = meta.app_id,
    });
    const desktop_out = try pathJoin(alloc, app_dir, try std.fmt.allocPrint(alloc, "usr/share/applications/{s}", .{desktop_name}));
    if (!writeFile(alloc, desktop_out, desktop_text, 0o644)) return error.WriteFailed;

    // AppDir 元数据（AppStream 可选文件）
    const appdata_dir = try pathJoin(alloc, app_dir, "usr/share/metainfo");
    mkDirs(alloc, appdata_dir);
    const appstream = try std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<component type="desktop-application">
        \\  <id>{s}</id>
        \\  <name>{s}</name>
        \\  <summary>{s}</summary>
        \\  <metadata_license>FSFAP</metadata_license>
        \\  <project_license>Proprietary</project_license>
        \\  <releases><release version="{s}" date="2026-11-14"/></releases>
        \\</component>
        \\
    , .{ meta.app_id, meta.name, meta.description, meta.version });
    if (!writeFile(alloc, try pathJoin(alloc, appdata_dir, try std.fmt.allocPrint(alloc, "{s}.metainfo.xml", .{meta.app_id})), appstream, 0o644)) return error.WriteFailed;

    if (icon_png) |png| {
        if (!writeFile(alloc, try pathJoin(alloc, app_dir, try std.fmt.allocPrint(alloc, "usr/share/icons/hicolor/256x256/apps/{s}.png", .{pkg})), png, 0o644)) return error.WriteFailed;
    }
    std.debug.print("[pack] AppDir -> {s}/（AppRun 可直接执行）\n", .{app_dir});

    // mksquashfs：真实 squashfs 镜像 + 拼 AppImage 的脚本（runtime 需下载；
    // 无 mksquashfs 时跳过，AppDir/AppRun 始终可用）
    const sq_out = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}.squashfs", .{pkg}));
    const res = std.process.run(alloc, sharedIo(), .{
        .argv = &.{ "mksquashfs", app_dir, sq_out, "-noappend", "-quiet", "-no-progress" },
        .stdout_limit = .limited(2048),
        .stderr_limit = .limited(2048),
    }) catch null;
    if (res) |r| {
        defer {
            if (r.stdout.len > 0) alloc.free(r.stdout);
            if (r.stderr.len > 0) alloc.free(r.stderr);
        }
        if (r.term.success()) {
            std.debug.print("[pack] squashfs -> {s}\n", .{sq_out});
            // 静态模板 + 占位替换（避免 fmt 占位符计数出错）
            const script_tpl =
                \\#!/bin/sh
                \\# 单文件 AppImage = 官方 runtime（AppImageKit）+ 本 squashfs 追加。
                \\# runtime 下载后： sh build-appimage.sh <runtime 文件>
                \\set -e
                \\runtime="${1:-appimage-runtime-x86_64}"
                \\cat "$runtime" "@SQUASHFS@" > "@NAME@-@VERSION@-@ARCH@.AppImage"
                \\chmod +x "@NAME@-@VERSION@-@ARCH@.AppImage"
                \\echo "AppImage built: @NAME@-@VERSION@-@ARCH@.AppImage"
                \\
            ;
            const sq_base = std.fs.path.basename(sq_out);
            var script = try std.mem.replaceOwned(u8, alloc, script_tpl, "@SQUASHFS@", sq_base);
            script = try std.mem.replaceOwned(u8, alloc, script, "@NAME@", meta.name);
            script = try std.mem.replaceOwned(u8, alloc, script, "@VERSION@", meta.version);
            script = try std.mem.replaceOwned(u8, alloc, script, "@ARCH@", "x86_64");
            const script_out = try pathJoin(alloc, out_dir, "build-appimage.sh");
            if (!writeFile(alloc, script_out, script, 0o755)) return error.WriteFailed;
            std.debug.print("[pack] build-appimage.sh -> {s}（需官方 runtime，离线环境跳过）\n", .{script_out});
        } else {
            std.debug.print("[pack] mksquashfs 失败（AppDir 仍可用）\n", .{});
        }
    } else {
        std.debug.print("[pack] mksquashfs 不可用（AppDir 仍可用）\n", .{});
    }

    // ---- 3) Flatpak manifest ----
    const fp_dir = try pathJoin(alloc, out_dir, "flatpak");
    mkDirs(alloc, fp_dir);
    const fp = try generateFlatpakManifest(alloc, meta);
    const fp_out = try pathJoin(alloc, fp_dir, try std.fmt.allocPrint(alloc, "{s}.json", .{pkg}));
    if (!writeFile(alloc, fp_out, fp, 0o644)) return error.WriteFailed;
    std.debug.print("[pack] flatpak manifest -> {s}\n", .{fp_out});

    // ---- 4) rpm spec ----
    const spec = try pack_formats.generateRpmSpec(alloc, meta);
    const spec_out = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}.spec", .{pkg}));
    if (!writeFile(alloc, spec_out, spec, 0o644)) return error.WriteFailed;
    std.debug.print("[pack] spec -> {s}（rpmbuild -bb 可构建）\n", .{spec_out});
}
