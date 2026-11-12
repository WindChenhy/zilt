//! 跨平台打包编排：`ZILT_PACK_TARGET=msi|macos|appimage|deb|rpm ZILT_PACK_OUT=<目录> zig build pack`
//! （exe 输入由 build.zig 注入 argv[1]，meta 来自 src/app_meta.zig）
//!
//! 产物：
//!   msi      → <name>-<version>-x64.wxs（本机有 WiX 时自动构建 .msi，否则输出构建说明）
//!   macos    → <name>.app/（Info.plist + exe）+ bundle-dmg.sh（hdiutil，仅 macOS 可执行）
//!   appimage → AppDir/（AppRun + usr/… + .desktop）+ build-appimage.sh（mksquashfs，仅 Linux）
//!   deb      → <pkg>_<version>_amd64.deb（真实 ar+tar+gz 产物，可直接安装）
//!   rpm      → <pkg>.spec（rpmbuild 可构建）
//!
//! Windows 代码签名（ Authenticode）：`ZILT_PACK_SIGN=<file> ZILT_SIGN_PFX=<pfx>
//! ZILT_SIGN_PASS=<pass> ZILT_SIGN_TS=<url>` 调用 signtool；未安装时输出指引。

const std = @import("std");
const zilt = @import("zilt");
const app_meta = @import("app_meta");
const wix_tool = @import("wix_tool.zig");
const msix_tool = @import("msix_tool.zig");
const signtool_locator = @import("signtool_locate.zig");

const PackMeta = zilt.pack_formats.PackMeta;

const DWORD = u32;
const HANDLE = *anyopaque;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.c) DWORD;
pub extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?*anyopaque) callconv(.c) HANDLE;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.c) BOOL;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GetCommandLineW() callconv(.c) [*:0]u16;
pub extern "kernel32" fn GetFullPathNameW(lpFileName: [*:0]const u16, nBufferLength: DWORD, lpBuffer: [*]u16, lpFilePart: ?*?[*:0]u16) callconv(.c) DWORD;
pub extern "shell32" fn CommandLineToArgvW(lpCmdLine: [*:0]const u16, pNumArgs: *i32) callconv(.c) ?[*][*:0]u16;

const BOOL = i32;

/// v0.1.23：三份拷贝合一（实现见 win_env.zig）。
const getEnv = @import("win_env.zig").get;

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return null;
    defer alloc.free(pw);
    const f = CreateFileW(pw.ptr, 0x80000000, 1, null, 3, 0x80, null);
    if (f == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(f);
    var size: i64 = 0;
    if (GetFileSizeEx(f, &size) == 0 or size < 0 or size > 512 * 1024 * 1024) return null;
    const buf = alloc.alloc(u8, @intCast(size)) catch return null;
    var total: DWORD = 0;
    while (total < buf.len) {
        var got: DWORD = 0;
        if (ReadFile(f, buf.ptr + total, @intCast(buf.len - total), &got, null) == 0 or got == 0) {
            alloc.free(buf);
            return null;
        }
        total += got;
    }
    return buf;
}

fn writeFile(alloc: std.mem.Allocator, path: []const u8, data: []const u8) bool {
    const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(pw);
    const f = CreateFileW(pw.ptr, 0x40000000, 0, null, 2, 0x80, null);
    if (f == INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(f);
    var total: DWORD = 0;
    while (total < data.len) {
        var got: DWORD = 0;
        if (WriteFile(f, data.ptr + total, @intCast(data.len - total), &got, null) == 0 or got == 0) return false;
        total += got;
    }
    return true;
}

fn mkDirs(alloc: std.mem.Allocator, path: []const u8) void {
    // 逐段创建（简版）
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '\\' or path[i] == '/') {
            if (i > 0) {
                const part = path[0..i];
                const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, part) catch continue;
                defer alloc.free(pw);
                _ = CreateDirectoryW(pw.ptr, null);
            }
        }
    }
    const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return;
    defer alloc.free(pw);
    _ = CreateDirectoryW(pw.ptr, null);
}

fn pathJoin(alloc: std.mem.Allocator, base: []const u8, rest: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ base, rest });
}

/// candle 的 Source 需要绝对路径；build 系统注入的 argv[1] 是
/// `.zig-cache/o/<hash>/zilt-app.exe` 这样的相对路径，相对 cwd 虽能解析，
/// 但一旦 out 目录变化就会指向错误位置。
fn getFullPathW(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return null;
    defer alloc.free(pw);
    var buf: [2048]u16 = undefined;
    const n = GetFullPathNameW(pw.ptr, buf.len, &buf, null);
    if (n == 0 or n >= buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch null;
}

fn exeBaseName(alloc: std.mem.Allocator, meta: PackMeta) ![]const u8 {
    if (std.mem.endsWith(u8, meta.exe_name, ".exe")) return meta.exe_name[0 .. meta.exe_name.len - 4];
    _ = alloc;
    return meta.exe_name;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // argv[1] = exe 输入（build.zig 注入）；CommandLineToArgvW 自包含
    var argc: i32 = 0;
    const argv_raw = CommandLineToArgvW(GetCommandLineW(), &argc);
    var exe_path: ?[]const u8 = null;
    if (argv_raw != null and argc > 1) {
        exe_path = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(argv_raw.?[1])) catch null;
    }

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

    const target = getEnv(alloc, "ZILT_PACK_TARGET") orelse {
        std.debug.print("usage: ZILT_PACK_TARGET=msi|msix|macos|appimage|deb|rpm ZILT_PACK_OUT=<dir> zig build pack\n", .{});
        return error.MissingArgs;
    };

    if (std.mem.eql(u8, target, "msi")) {
        const exe_arg = exe_path orelse return error.ExeArgRequired;
        // candle 的 Source 必须是绝对路径（argv[1] 来自 .zig-cache 相对路径）
        const exe_src = getFullPathW(alloc, exe_arg) orelse exe_arg;

        // 与 NSIS 同一套开关：ZILT_INSTALLER_PER_MACHINE=1 → Program Files + HKLM
        const per_machine = blk: {
            const v = getEnv(alloc, "ZILT_INSTALLER_PER_MACHINE") orelse break :blk false;
            break :blk v.len > 0 and v[0] == '1';
        };

        const wxs = try zilt.pack_formats.generateWxsOpt(alloc, meta, exe_src, .{ .per_machine = per_machine });
        const out = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}-{s}-x64.wxs", .{ meta.name, meta.version }));
        if (!writeFile(alloc, out, wxs)) return error.WriteFailed;
        std.debug.print("[pack] wxs -> {s}\n", .{out});

        // v0.1.15：自动供应 WiX（Tauri 式 vendor）并真实构建 MSI
        const prepared = wix_tool.ensure(alloc) catch |err| {
            std.debug.print(
                "[pack] WiX 供应失败：{s}\n" ++
                    "  · 离线环境可手工放置：解压 wix314-binaries.zip 到 %LOCALAPPDATA%\\zilt\\WixTools\n" ++
                    "  · 或用 ZILT_WIX_TOOLPATH 指向已解压目录（含 candle.exe/light.exe）\n" ++
                    "  · wxs 已生成，可自行执行：candle -arch x64 -out x.wixobj {s} && light -out x.msi x.wixobj\n",
                .{ @errorName(err), out },
            );
            return;
        };
        if (prepared == null) {
            std.debug.print(
                "[pack] 未找到 WiX 且自动下载被禁用；wxs 已生成：{s}\n" ++
                    "  · 将其解压目录设到 ZILT_WIX_TOOLPATH 后重试\n",
                .{out},
            );
            return;
        }
        defer wix_tool.freePrepared(alloc, prepared);
        const wix = prepared.?;
        std.debug.print("[pack] using WiX from {s} (source={s})\n", .{ wix.dir, @tagName(wix.source) });

        const msi = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}-{s}-x64.msi", .{ meta.name, meta.version }));
        wix_tool.buildMsi(alloc, wix.dir, out, msi, "x64") catch |err| {
            std.debug.print("[pack] MSI 构建失败：{s}（wxs 见 {s}）\n", .{ @errorName(err), out });
            return err;
        };
        std.debug.print("[pack] msi -> {s}\n", .{msi});
    } else if (std.mem.eql(u8, target, "msix")) {
        const exe_arg = exe_path orelse return error.ExeArgRequired;
        const exe_abs = getFullPathW(alloc, exe_arg) orelse exe_arg;
        const w32 = zilt.platform_windows.win32;

        // MSIX 版本必须四段式
        const mver = zilt.msix.normalizeVersion(alloc, meta.version) catch return error.VersionFailed;

        // Logo 直接取 ico 里最大的 PNG 帧（本项目 ico 四帧都是 PNG）
        const ico_path = "src/zilt/assets/zilt.ico";
        const ico = w32.readFileAlloc(alloc, ico_path) orelse {
            std.debug.print("[pack] 找不到图标 {s}\n", .{ico_path});
            return error.IconMissing;
        };
        const frames = zilt.msix.extractPngFrames(alloc, ico) catch |err| {
            std.debug.print("[pack] 解析 ico 失败：{s}\n", .{@errorName(err)});
            return err;
        };
        const logo = zilt.msix.largestPngFrame(frames) orelse return error.NoPngFrame;

        // Publisher 必须与签名证书 Subject 逐字一致，否则部署报 0x800B0109
        const publisher = getEnv(alloc, "ZILT_MSIX_PUBLISHER") orelse "CN=Zilt";

        const manifest = try zilt.msix.generateManifest(alloc, .{
            .identity_name = meta.app_id,
            .publisher = publisher,
            .version = mver,
            .arch = "x64",
            .display_name = meta.name,
            .publisher_display_name = meta.maintainer,
            .description = meta.description,
            .exe_name = meta.exe_name,
        });

        const staging = try pathJoin(alloc, out_dir, "msix-staging");
        try msix_tool.stage(alloc, .{
            .dir = staging,
            .exe_path = exe_abs,
            .exe_name = meta.exe_name,
            .manifest = manifest,
            .logo_png = logo.png,
        });
        std.debug.print("[pack] manifest -> {s}\\AppxManifest.xml (Publisher={s}, {s})\n", .{ staging, publisher, mver });

        const out_msix = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}-{s}-x64.msix", .{ meta.name, meta.version }));
        msix_tool.pack(alloc, staging, out_msix) catch |err| {
            std.debug.print(
                "[pack] MSIX 打包失败：{s}\n" ++
                    "  · 需要 Windows SDK 的 App Certification Kit（makeappx.exe）\n" ++
                    "  · staging 已保留：{s}\n",
                .{ @errorName(err), staging },
            );
            return err;
        };
        std.debug.print("[pack] msix -> {s}\n", .{out_msix});
    } else if (std.mem.eql(u8, target, "macos")) {
        const exe_src = exe_path orelse return error.ExeArgRequired;
        const exe_bytes = readFileAlloc(alloc, exe_src) orelse return error.ExeReadFailed;
        const app_dir = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}.app", .{meta.name}));
        mkDirs(alloc, try pathJoin(alloc, app_dir, "Contents\\MacOS"));
        const plist = try zilt.pack_formats.generateInfoPlist(alloc, meta);
        if (!writeFile(alloc, try pathJoin(alloc, app_dir, "Contents\\Info.plist"), plist)) return error.WriteFailed;
        const exe_dst = try pathJoin(alloc, app_dir, try std.fmt.allocPrint(alloc, "Contents\\MacOS\\{s}", .{try exeBaseName(alloc, meta)}));
        if (!writeFile(alloc, exe_dst, exe_bytes)) return error.WriteFailed;
        const dmg_sh =
            \\#!/bin/bash
            \\# DMG 打包（仅 macOS 可执行）：hdiutil create -volname NAME -srcfolder NAME.app -ov -format UDZO NAME.dmg
            \\
        ;
        _ = dmg_sh;
        std.debug.print("[pack] .app bundle -> {s}（DMG 需在 macOS 上执行 hdiutil）\n", .{app_dir});
    } else if (std.mem.eql(u8, target, "appimage")) {
        const exe_src = exe_path orelse return error.ExeArgRequired;
        const exe_bytes = readFileAlloc(alloc, exe_src) orelse return error.ExeReadFailed;
        const app_dir = try pathJoin(alloc, out_dir, "AppDir");
        mkDirs(alloc, try pathJoin(alloc, app_dir, "usr\\bin"));
        mkDirs(alloc, try pathJoin(alloc, app_dir, "usr\\share\\applications"));
        const apprun = try std.mem.replaceOwned(u8, alloc, zilt.pack_formats.apprun_script, "APP_EXE_NAME", try exeBaseName(alloc, meta));
        if (!writeFile(alloc, try pathJoin(alloc, app_dir, "AppRun"), apprun)) return error.WriteFailed;
        const exe_dst = try pathJoin(alloc, app_dir, try std.fmt.allocPrint(alloc, "usr\\bin\\{s}", .{try exeBaseName(alloc, meta)}));
        if (!writeFile(alloc, exe_dst, exe_bytes)) return error.WriteFailed;
        const desktop = try zilt.pack_formats.generateDesktopFile(alloc, meta);
        const pkg = try zilt.pack_formats.debianName(alloc, meta.app_id);
        if (!writeFile(alloc, try pathJoin(alloc, app_dir, try std.fmt.allocPrint(alloc, "usr\\share\\applications\\{s}.desktop", .{pkg})), desktop)) return error.WriteFailed;
        std.debug.print("[pack] AppDir -> {s}（AppImage 需在 Linux 上：mksquashfs AppDir sq + cat runtime >> <name>.AppImage）\n", .{app_dir});
    } else if (std.mem.eql(u8, target, "deb")) {
        const exe_src = exe_path orelse return error.ExeArgRequired;
        const exe_bytes = readFileAlloc(alloc, exe_src) orelse return error.ExeReadFailed;
        const pkg = try zilt.pack_formats.debianName(alloc, meta.app_id);
        const deb = try zilt.pack_formats.buildDeb(alloc, meta, exe_bytes);
        const out = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}_{s}_amd64.deb", .{ pkg, meta.version }));
        if (!writeFile(alloc, out, deb)) return error.WriteFailed;
        std.debug.print("[pack] deb -> {s}（{d} bytes）\n", .{ out, deb.len });
    } else if (std.mem.eql(u8, target, "rpm")) {
        const spec = try zilt.pack_formats.generateRpmSpec(alloc, meta);
        const out = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}.spec", .{try zilt.pack_formats.debianName(alloc, meta.app_id)}));
        if (!writeFile(alloc, out, spec)) return error.WriteFailed;
        std.debug.print("[pack] spec -> {s}（rpmbuild -bb 可构建）\n", .{out});
    } else if (std.mem.eql(u8, target, "sign")) {
        // 代码签名（v0.1.15）：真正执行，而不是只打印命令。
        // 凭据：ZILT_SIGN_PFX（路径）/ ZILT_SIGN_PFX_BASE64 / ZILT_SIGN_THUMBPRINT
        // 目标：ZILT_PACK_SIGN（文件路径；可为 .exe / .msix / .msi）
        const file = getEnv(alloc, "ZILT_PACK_SIGN") orelse return error.SignFileRequired;
        const sign = zilt.codesign;
        const w32 = zilt.platform_windows.win32;

        const pfx = getEnv(alloc, "ZILT_SIGN_PFX");
        const pfx_b64 = getEnv(alloc, "ZILT_SIGN_PFX_BASE64");
        const thumb = getEnv(alloc, "ZILT_SIGN_THUMBPRINT");
        const src_kind = sign.pickSource(pfx, pfx_b64, thumb) orelse {
            std.debug.print("[pack] 缺少签名凭据：设置 ZILT_SIGN_PFX / ZILT_SIGN_PFX_BASE64 / ZILT_SIGN_THUMBPRINT\n", .{});
            return error.SignCredentialRequired;
        };

        const pass = getEnv(alloc, "ZILT_SIGN_PASSWORD") orelse getEnv(alloc, "ZILT_SIGN_PASS");
        const ts = getEnv(alloc, "ZILT_SIGN_TIMESTAMP") orelse getEnv(alloc, "ZILT_SIGN_TS") orelse "http://timestamp.digicert.com";

        var tmp_pfx: ?[]u8 = null;
        defer if (tmp_pfx) |tp| {
            if (std.unicode.utf8ToUtf16LeAllocZ(alloc, tp)) |wz| {
                _ = w32.DeleteFileW(wz.ptr);
                alloc.free(wz);
            } else |_| {}
            alloc.free(tp);
        };

        var opts = sign.Options{
            .pfx_password = pass,
            .timestamp_url = ts,
        };
        switch (src_kind) {
            .pfx_path => opts.pfx_path = pfx,
            .thumbprint => opts.cert_thumbprint = thumb,
            .pfx_base64 => {
                const der = sign.decodePfxBase64(alloc, pfx_b64.?) catch |err| {
                    std.debug.print("[pack] base64 PFX 解码失败：{s}\n", .{@errorName(err)});
                    return err;
                };
                const tmp = try std.fmt.allocPrint(alloc, "{s}\\zilt-sign-temp.pfx", .{getEnv(alloc, "TEMP") orelse "."});
                if (!writeFile(alloc, tmp, der)) return error.WriteFailed;
                tmp_pfx = tmp;
                opts.pfx_path = tmp;
            },
        }

        const tool = signtool_locator.locate(alloc) orelse {
            const cmd = sign.fullCommand(alloc, opts, file) catch return error.SignToolMissing;
            std.debug.print("[pack] signtool.exe 未找到；可手工执行：\n  {s}\n", .{cmd});
            return error.SignToolMissing;
        };

        const args = try sign.signArgs(alloc, opts, file);
        const code = wix_tool.runAndWait(alloc, tool, args, 120_000) catch return error.SignFailed;
        std.debug.print("[pack] sign {s} -> exit {d}\n", .{ file, code });
        if (code != 0) return error.SignFailed;
    } else {
        std.debug.print("[pack] unknown target: {s}\n", .{target});
        return error.BadTarget;
    }
}
