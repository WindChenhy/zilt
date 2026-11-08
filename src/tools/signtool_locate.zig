//! signtool.exe 定位（bundle 与 `zilt doctor` 共用）。
//!
//! 为什么要读注册表：Windows SDK 可以装在任意盘。本机就装在 `E:\Windows Kits\10\`，
//! 而直觉写法 `ProgramFiles(x86)\Windows Kits\10\bin\*\x64` 会直接返回 null，
//! 让人误以为「没装 SDK / 无法签名」。正确的锚点是
//! `HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots\KitsRoot10`。
//!
//! 查找顺序：
//!   1. PATH
//!   2. `<KitsRoot10>\bin\<最高版本>\x64\signtool.exe`
//!   3. `<KitsRoot10>\App Certification Kit\signtool.exe`（少数安装不含 bin）
//!   4. `ProgramFiles(x86)\Windows Kits\10\…` 同上两条（注册表读不到时兜底）

const std = @import("std");
const zilt = @import("zilt");
const win32 = zilt.platform_windows.win32;

extern "kernel32" fn SearchPathW(
    lpPath: ?win32.LPCWSTR,
    lpFileName: win32.LPCWSTR,
    lpExtension: ?win32.LPCWSTR,
    nBufferLength: u32,
    lpBuffer: [*]u16,
    lpFilePart: ?*?[*:0]u16,
) callconv(.c) u32;

pub fn locate(alloc: std.mem.Allocator) ?[]u8 {
    if (fromPath(alloc, "signtool.exe")) |p| return p;

    if (kitsRoot(alloc)) |root| {
        defer alloc.free(root);
        if (searchUnder(alloc, root)) |p| return p;
    }

    // 注册表缺失/异常时的默认盘兜底
    if (win32.getEnvUtf8(alloc, "ProgramFiles(x86)")) |pf86| {
        defer alloc.free(pf86);
        const root = std.fmt.allocPrint(alloc, "{s}\\Windows Kits\\10", .{pf86}) catch return null;
        defer alloc.free(root);
        if (searchUnder(alloc, root)) |p| return p;
    }
    return null;
}

/// 在某个 Kits 根目录下找 signtool。
fn searchUnder(alloc: std.mem.Allocator, root: []const u8) ?[]u8 {
    const base = std.mem.trimEnd(u8, root, "\\/");

    // 2) bin\<最高版本>\x64\signtool.exe
    if (highestVersionDir(alloc, base)) |ver| {
        defer alloc.free(ver);
        const cand = std.fmt.allocPrint(alloc, "{s}\\bin\\{s}\\x64\\signtool.exe", .{ base, ver }) catch null;
        if (cand) |c| {
            if (fileExists(alloc, c)) return c;
            alloc.free(c);
        }
        // 非 x64 发行（如 ARM64 主机）
        const arm = std.fmt.allocPrint(alloc, "{s}\\bin\\{s}\\arm64\\signtool.exe", .{ base, ver }) catch null;
        if (arm) |c| {
            if (fileExists(alloc, c)) return c;
            alloc.free(c);
        }
    }

    // 3) App Certification Kit 下的完整版（部分安装不含 bin\ 目录）
    const appkit = std.fmt.allocPrint(alloc, "{s}\\App Certification Kit\\signtool.exe", .{base}) catch return null;
    if (fileExists(alloc, appkit)) return appkit;
    alloc.free(appkit);
    return null;
}

/// 枚举 `<base>\bin\*` 取字典序最大的目录名（SDK 版本号如 10.0.26100.0）。
fn highestVersionDir(alloc: std.mem.Allocator, base: []const u8) ?[]u8 {
    const bin = std.fmt.allocPrint(alloc, "{s}\\bin", .{base}) catch return null;
    defer alloc.free(bin);

    const pattern = std.fmt.allocPrint(alloc, "{s}\\*", .{bin}) catch return null;
    defer alloc.free(pattern);

    const wz = std.unicode.utf8ToUtf16LeAllocZ(alloc, pattern) catch return null;
    defer alloc.free(wz);

    var fd: win32.WIN32_FIND_DATAW = undefined;
    const h = win32.FindFirstFileW(wz.ptr, &fd);
    if (h == win32.INVALID_HANDLE_VALUE) return null;
    defer _ = win32.FindClose(h);

    var best: ?[]u8 = null;
    while (true) {
        if ((fd.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY) != 0) {
            const raw = std.mem.sliceTo(&fd.cFileName, 0);
            // bin\ 下混着 x64 / x86 / arm64 之类目录，字典序最大的是 "x86"，
            // 会拼成 x86\x64\signtool.exe 而错过真正的最新版本。版本目录
            // 一律以数字开头（10.0.26100.0），据此过滤。
            const looks_like_version = raw.len > 0 and std.ascii.isDigit(@intCast(raw[0]));
            if (looks_like_version) {
                if (std.unicode.utf16LeToUtf8Alloc(alloc, raw)) |name| {
                    if (best) |b| {
                        if (std.mem.order(u8, name, b) == .gt) {
                            alloc.free(b);
                            best = name;
                        } else {
                            alloc.free(name);
                        }
                    } else {
                        best = name;
                    }
                } else |_| {}
            }
        }
        if (win32.FindNextFileW(h, &fd) == 0) break;
    }
    return best;
}

fn kitsRoot(alloc: std.mem.Allocator) ?[]u8 {
    const sub = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots");
    const val = std.unicode.utf8ToUtf16LeStringLiteral("KitsRoot10");
    var buf: [512]u16 = std.mem.zeroes([512]u16);
    var size: u32 = @intCast(@sizeOf(@TypeOf(buf)));
    const hr = win32.RegGetValueW(win32.HKEY_LOCAL_MACHINE, sub.ptr, val.ptr, win32.RRF_RT_REG_SZ, null, @ptrCast(&buf), &size);
    if (hr < 0) return null;
    const text = std.mem.sliceTo(buf[0..], 0);
    if (text.len == 0) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, text) catch null;
}

fn fromPath(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    const name_z = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
    defer alloc.free(name_z);
    var buf: [1024]u16 = undefined;
    const n = SearchPathW(null, name_z.ptr, null, buf.len, &buf, null);
    if (n == 0 or n >= buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch null;
}

pub fn fileExists(alloc: std.mem.Allocator, path: []const u8) bool {
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(w);
    return win32.GetFileAttributesW(w.ptr) != 0xFFFFFFFF;
}
