//! Zilt CLI（v0.1.17）：`zilt doctor` / `zilt info` / `zilt version`。
//!
//! 定位是「包装现有 zig build step 的薄壳 + 环境自检」：
//!  - `doctor` 检查构建链（Zig / WebView2 运行时 / makensis / 前端 dist / 图标）
//!  - `info`   打印 project.zig 的配置摘要（版本、app_id、前端工程、图标、安装器范围）
//!
//! 输出走 stderr（与 zig build 日志一致，便于 CI 收集）；退出码非 0 表示有检查失败。
const std = @import("std");
const builtin = @import("builtin");
const zilt = @import("zilt");
const meta = @import("app_meta");

const win32 = zilt.platform_windows.win32;
const print = std.debug.print;

extern "kernel32" fn SearchPathW(
    lpPath: ?win32.LPCWSTR,
    lpFileName: win32.LPCWSTR,
    lpExtension: ?win32.LPCWSTR,
    nBufferLength: u32,
    lpBuffer: [*]u16,
    lpFilePart: ?*?[*:0]u16,
) callconv(.c) u32;

const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;

pub fn main() !u8 {
    const alloc = std.heap.page_allocator;
    var argc: i32 = 0;
    const argv_w = win32.CommandLineToArgvW(win32.GetCommandLineW(), &argc) orelse return error.ArgsFailed;
    defer _ = win32.LocalFree(@ptrCast(argv_w));

    var args: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }
    var i: usize = 1;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        try args.append(alloc, try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(argv_w[i])));
    }

    const cmd = if (args.items.len > 0) args.items[0] else "help";
    const eql = std.mem.eql;

    if (eql(u8, cmd, "version") or eql(u8, cmd, "--version") or eql(u8, cmd, "-v")) {
        printVersion();
        return 0;
    }
    if (eql(u8, cmd, "doctor")) return runDoctor(alloc);
    if (eql(u8, cmd, "info")) return runInfo();
    if (eql(u8, cmd, "help") or eql(u8, cmd, "--help") or eql(u8, cmd, "-h")) {
        printHelp();
        return 0;
    }

    print("zilt: unknown command '{s}'\n\n", .{cmd});
    printHelp();
    return 2;
}

fn printVersion() void {
    const v = builtin.zig_version;
    print("zilt {s} (zig {d}.{d}.{d})\n", .{ meta.version, v.major, v.minor, v.patch });
}

fn printHelp() void {
    print(
        \\Zilt CLI
        \\
        \\用法:
        \\  zilt doctor    检查构建环境（Zig / WebView2 / makensis / frontend dist / 图标）
        \\  zilt info      打印当前项目配置摘要
        \\  zilt version   打印版本
        \\
        \\构建/运行仍走 zig build:
        \\  zig build           编译应用
        \\  zig build test      单元测试
        \\  zig build frontend  构建前端并嵌入
        \\  zig build bundle    产出 zip + setup.exe
        \\  zig build pack      多平台包（deb/rpm/wxs/appimage）
        \\
    , .{});
}

fn runDoctor(alloc: std.mem.Allocator) !u8 {
    var issues: usize = 0;

    const v = builtin.zig_version;
    print("[ok]   Zig {d}.{d}.{d}\n", .{ v.major, v.minor, v.patch });

    // WebView2 运行时（Evergreen）
    if (webviewVersion(alloc)) |wv| {
        defer alloc.free(wv);
        print("[ok]   WebView2 runtime {s}\n", .{wv});
    } else {
        print("[warn] WebView2 runtime not found (Evergreen) — 应用启动会失败\n", .{});
        issues += 1;
    }

    // makensis（安装器）
    if (findInPath(alloc, "makensis.exe")) |p| {
        defer alloc.free(p);
        print("[ok]   makensis: {s}\n", .{p});
    } else {
        print("[warn] makensis not in PATH — `zig build bundle` 只能生成 .nsi\n", .{});
    }

    // 前端 dist
    const dist = meta.frontend.dist;
    if (dirExists(alloc, dist)) {
        print("[ok]   frontend dist: {s}\n", .{dist});
    } else {
        print("[warn] frontend dist missing: {s}\n", .{dist});
        issues += 1;
    }

    // 图标
    if (meta.icon) |icon| {
        if (fileExists(alloc, icon)) {
            print("[ok]   app icon: {s}\n", .{icon});
        } else {
            print("[warn] app icon missing: {s}\n", .{icon});
            issues += 1;
        }
    } else {
        print("[ok]   app icon: builtin Zig logo\n", .{});
    }

    if (issues == 0) {
        print("\nAll checks passed.\n", .{});
        return 0;
    }
    print("\n{d} issue(s) found.\n", .{issues});
    return 1;
}

fn runInfo() u8 {
    const project = meta;
    print("app_name   {s}\n", .{project.app_name});
    print("publisher  {s}\n", .{project.publisher});
    print("version    {s}\n", .{project.version});
    print("app_id     {s}\n", .{project.app_id});
    print("exe_name   {s}\n", .{project.exe_name});
    print("icon       {s}\n", .{project.icon orelse "(builtin)"});
    const fe = project.frontend;
    print("\nfrontend\n", .{});
    print("  dir            {s}\n", .{fe.dir});
    print("  dist           {s}\n", .{fe.dist});
    print("  build_command  {s}\n", .{fe.build_command orelse "(none)"});
    print("  dev_command    {s}\n", .{fe.dev_command orelse "(none)"});
    print("  dev_url        {s}\n", .{fe.dev_url orelse "(none)"});
    print("  dev_proxy      {}\n", .{fe.dev_proxy});
    return 0;
}

/// 读取 WebView2 Evergreen 版本。注意 32 位安装器写在 WOW6432Node 下，
/// 64 位进程读 HKLM\SOFTWARE 时不会自动重定向，因此两条路径都要试。
fn webviewVersion(alloc: std.mem.Allocator) ?[]u8 {
    const sub64 = std.unicode.utf8ToUtf16LeStringLiteral(
        "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
    );
    const sub32 = std.unicode.utf8ToUtf16LeStringLiteral(
        "SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
    );
    const pv = std.unicode.utf8ToUtf16LeStringLiteral("pv");

    const Candidate = struct { root: win32.HKEY, sub: [:0]const u16 };
    const candidates = [_]Candidate{
        .{ .root = win32.HKEY_LOCAL_MACHINE, .sub = sub64 },
        .{ .root = win32.HKEY_LOCAL_MACHINE, .sub = sub32 },
        .{ .root = win32.HKEY_CURRENT_USER, .sub = sub64 },
    };

    for (candidates) |c| {
        var buf: [128]u16 = std.mem.zeroes([128]u16);
        var size: u32 = @intCast(@sizeOf(@TypeOf(buf)));
        const hr = win32.RegGetValueW(c.root, c.sub.ptr, pv.ptr, win32.RRF_RT_REG_SZ, null, @ptrCast(&buf), &size);
        if (hr < 0) continue;
        const text = std.mem.sliceTo(buf[0..], 0);
        if (text.len == 0) continue;
        return std.unicode.utf16LeToUtf8Alloc(alloc, text) catch null;
    }
    return null;
}

/// PATH 中查找可执行文件（SearchPathW 自带 .exe 补全）。
fn findInPath(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    const name_z = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
    defer alloc.free(name_z);
    var buf: [1024]u16 = undefined;
    const n = SearchPathW(null, name_z.ptr, null, buf.len, &buf, null);
    if (n == 0 or n >= buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch null;
}

fn dirExists(alloc: std.mem.Allocator, path: []const u8) bool {
    const path_z = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(path_z);
    const attrs = win32.GetFileAttributesW(path_z.ptr);
    if (attrs == INVALID_FILE_ATTRIBUTES) return false;
    return attrs & FILE_ATTRIBUTE_DIRECTORY != 0;
}

fn fileExists(alloc: std.mem.Allocator, path: []const u8) bool {
    const path_z = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(path_z);
    const attrs = win32.GetFileAttributesW(path_z.ptr);
    if (attrs == INVALID_FILE_ATTRIBUTES) return false;
    return attrs & FILE_ATTRIBUTE_DIRECTORY == 0;
}
