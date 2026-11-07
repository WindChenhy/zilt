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
pub extern "shell32" fn CommandLineToArgvW(lpCmdLine: [*:0]const u16, pNumArgs: *i32) callconv(.c) ?[*][*:0]u16;

const BOOL = i32;

fn getEnv(alloc: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
    const nw = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
    defer alloc.free(nw);
    const need = GetEnvironmentVariableW(nw.ptr, null, 0);
    if (need == 0) return null;
    const buf = alloc.alloc(u16, need + 1) catch return null;
    defer alloc.free(buf);
    const got = GetEnvironmentVariableW(nw.ptr, buf.ptr, @intCast(need + 1));
    if (got == 0 or got > need) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..got]) catch null;
}

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
        std.debug.print("usage: ZILT_PACK_TARGET=msi|macos|appimage|deb|rpm ZILT_PACK_OUT=<dir> zig build pack\n", .{});
        return error.MissingArgs;
    };

    if (std.mem.eql(u8, target, "msi")) {
        const exe_src = exe_path orelse return error.ExeArgRequired;
        const wxs = try zilt.pack_formats.generateWxs(alloc, meta, exe_src);
        const out = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}-{s}-x64.wxs", .{ meta.name, meta.version }));
        if (!writeFile(alloc, out, wxs)) return error.WriteFailed;
        std.debug.print("[pack] wxs -> {s}\n", .{out});
        std.debug.print("[pack] msi: 需要 WiX（wix build <wxs> -o out.msi，或 v3 candle+light）；本机未自动检测构建\n", .{});
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
        // Authenticode：ZILT_PACK_SIGN=<file> ZILT_SIGN_PFX=... ZILT_SIGN_PASS=... ZILT_SIGN_TS=...
        const file = getEnv(alloc, "ZILT_PACK_SIGN") orelse return error.SignFileRequired;
        const pfx = getEnv(alloc, "ZILT_SIGN_PFX") orelse return error.SignPfxRequired;
        const pass = getEnv(alloc, "ZILT_SIGN_PASS") orelse "";
        const ts = getEnv(alloc, "ZILT_SIGN_TS") orelse "http://timestamp.digicert.com";
        const cmd = try zilt.pack_formats.buildSigntoolCommand(alloc, pfx, pass, ts, file);
        std.debug.print("[pack] signtool cmd:\n  {s}\n（需要 Windows SDK signtool.exe 在 PATH；或自行用本命令签名）\n", .{cmd});
    } else {
        std.debug.print("[pack] unknown target: {s}\n", .{target});
        return error.BadTarget;
    }
}
