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
const signtool_locator = @import("signtool_locate.zig");
const wix_tool = @import("wix_tool.zig");

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
    if (eql(u8, cmd, "icon")) return runIcon(alloc, args.items[1..]);
    if (eql(u8, cmd, "npm-pack")) return runNpmPack(alloc, args.items[1..]);
    if (eql(u8, cmd, "new")) return runNew(alloc, args.items[1..]);
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
        \\  zilt icon <in.png> [-o out.ico] [--sizes 16,32,48,256]
        \\                 PNG → 多尺寸 .ico（Windows 发布图标）
        \\  zilt npm-pack [-o npm] [--name @zilt/runtime] [--version 0.1.21]
        \\                 生成 @zilt/runtime npm 包（package.json/index.js/index.d.ts）
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

    // 可选工具链：代码签名 / MSI
    if (signtool_locator.locate(alloc)) |p| {
        defer alloc.free(p);
        print("[ok]   signtool: {s}\n", .{p});
    } else {
        print("[warn] signtool not found — code signing needs Windows SDK (bundle prints the command)\n", .{});
    }
    if (wix_tool.detect(alloc)) |p| {
        defer alloc.free(p);
        print("[ok]   WiX 3.14: {s}\n", .{p});
    } else {
        print("[info] WiX 3 not cached — fetched automatically on first `zig build pack` (MSI)\n", .{});
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

// ---------------------------------------------------------------------------
// v0.1.16：icon 子命令 —— PNG → 多尺寸 .ico（对齐 tauri icon 的 Windows 面）
// ---------------------------------------------------------------------------

fn runIcon(alloc: std.mem.Allocator, args: []const []u8) !u8 {
    var input: ?[]const u8 = null;
    var output: []const u8 = "icon.ico";
    var sizes: std.ArrayListUnmanaged(u32) = .empty;
    defer sizes.deinit(alloc);
    // 默认尺寸：Windows 桌面/任务栏/Alt-Tab 全覆盖
    try sizes.appendSlice(alloc, &.{ 16, 24, 32, 48, 64, 128, 256 });

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) {
                print("zilt icon: -o needs a path\n", .{});
                return 2;
            }
            output = args[i];
        } else if (std.mem.eql(u8, a, "--sizes")) {
            i += 1;
            if (i >= args.len) {
                print("zilt icon: --sizes needs a list (e.g. 16,32,48,256)\n", .{});
                return 2;
            }
            sizes.clearRetainingCapacity();
            var it = std.mem.splitScalar(u8, args[i], ',');
            while (it.next()) |s| {
                const t = std.mem.trim(u8, s, " \t");
                const v = std.fmt.parseInt(u32, t, 10) catch {
                    print("zilt icon: bad size '{s}'\n", .{t});
                    return 2;
                };
                if (v == 0 or v > 256) {
                    print("zilt icon: size {d} out of range (1..256)\n", .{v});
                    return 2;
                }
                try sizes.append(alloc, v);
            }
        } else if (std.mem.startsWith(u8, a, "-")) {
            print("zilt icon: unknown option '{s}'\n", .{a});
            return 2;
        } else {
            input = a;
        }
    }
    const in_path = input orelse {
        print("usage: zilt icon <input.png> [-o out.ico] [--sizes 16,32,48,256]\n", .{});
        return 2;
    };

    const png_bytes = win32.readFileAlloc(alloc, in_path) orelse {
        print("zilt icon: cannot read '{s}'\n", .{in_path});
        return 1;
    };
    defer alloc.free(png_bytes);

    const img = zilt.png.decode(alloc, png_bytes) catch |e| {
        print("zilt icon: decode failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer alloc.free(img.pixels);
    print("zilt icon: {s} → {d}x{d} RGBA\n", .{ in_path, img.width, img.height });

    const ico_bytes = zilt.ico.encodeIco(alloc, img, sizes.items) catch |e| {
        print("zilt icon: encode failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer alloc.free(ico_bytes);

    if (!win32.writeFileAlloc(alloc, output, ico_bytes)) {
        print("zilt icon: cannot write '{s}'\n", .{output});
        return 1;
    }
    print("zilt icon: wrote {s} ({d} bytes, sizes ", .{ output, ico_bytes.len });
    for (sizes.items, 0..) |s, k| print("{s}{d}", .{ if (k == 0) "" else ",", s });
    print(")\n", .{});
    return 0;
}

// ---------------------------------------------------------------------------
// v0.1.17：npm-pack 子命令 —— 生成 @zilt/runtime npm 包（package.json /
// index.js / index.d.ts / README.md），可直接 npm pack / publish。
// ---------------------------------------------------------------------------

fn runNpmPack(alloc: std.mem.Allocator, args: []const []u8) !u8 {
    var out_dir: []const u8 = "npm";
    var version: []const u8 = "0.1.21";
    var name: []const u8 = "@zilt/runtime";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) {
                print("zilt npm-pack: -o needs a directory\n", .{});
                return 2;
            }
            out_dir = args[i];
        } else if (std.mem.eql(u8, a, "--version")) {
            i += 1;
            if (i >= args.len) {
                print("zilt npm-pack: --version needs a value\n", .{});
                return 2;
            }
            version = args[i];
        } else if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= args.len) {
                print("zilt npm-pack: --name needs a value\n", .{});
                return 2;
            }
            name = args[i];
        } else {
            print("zilt npm-pack: unknown argument '{s}'\n", .{a});
            return 2;
        }
    }

    var files = zilt.npm_pack.generate(alloc, .{
        .name = name,
        .version = version,
        .runtime_js = zilt.ipc.runtime_js,
    }) catch |e| {
        print("zilt npm-pack: generate failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer files.deinit(alloc);

    const targets = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "package.json", .data = files.package_json },
        .{ .name = "index.js", .data = files.index_js },
        .{ .name = "index.d.ts", .data = files.index_d_ts },
        .{ .name = "README.md", .data = files.readme_md },
    };

    // 目录不存在则创建（CreateDirectoryW，已存在视为成功）
    {
        const dir_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, out_dir) catch return 1;
        defer alloc.free(dir_w);
        _ = win32.CreateDirectoryW(dir_w.ptr, null);
    }
    for (targets) |t| {
        const path = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ out_dir, t.name }) catch return 1;
        defer alloc.free(path);
        if (!win32.writeFileAlloc(alloc, path, t.data)) {
            print("zilt npm-pack: cannot write '{s}'\n", .{path});
            return 1;
        }
        print("zilt npm-pack: wrote {s} ({d} bytes)\n", .{ path, t.data.len });
    }
    print("zilt npm-pack: package ready -> cd {s} && npm pack\n", .{out_dir});
    return 0;
}

// ---------------------------------------------------------------------------
// v0.1.17：new 子命令 —— 独立脚手架（create-zilt-app 的 Zig 侧实现）。
// 与 `zig build init` 共用 init.zig 的 scaffold；必须在框架仓库根执行。
// ---------------------------------------------------------------------------

fn runNew(alloc: std.mem.Allocator, args: []const []u8) !u8 {
    const init_mod = @import("init.zig");
    var template: []const u8 = "vanilla";
    var name: []const u8 = "my-zilt-app";
    var dest: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--template")) {
            i += 1;
            if (i >= args.len) {
                print("zilt new: -t needs a template name\n", .{});
                return 2;
            }
            template = args[i];
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= args.len) {
                print("zilt new: -n needs a name\n", .{});
                return 2;
            }
            name = args[i];
        } else if (std.mem.eql(u8, a, "--list")) {
            print("templates:", .{});
            for (init_mod.templates_available, 0..) |t, j| {
                print("{s}{s}", .{ if (j == 0) " " else "/", t });
            }
            print("\n", .{});
            return 0;
        } else if (std.mem.startsWith(u8, a, "-")) {
            print("zilt new: unknown option '{s}'\n", .{a});
            return 2;
        } else {
            dest = a;
        }
    }
    if (dest) |d| {
        // 目录名即默认项目名（未显式 -n 时）
        if (std.mem.eql(u8, name, "my-zilt-app")) name = std.fs.path.basename(d);
    }
    // 脚手架源是「框架仓库根」下的 src/zilt、src/tools、templates/：
    // 若当前目录不在根上，尝试从 exe 位置推导（<root>/zig-out/bin/zilt.exe）。
    chdirToFrameworkRoot(alloc);
    init_mod.scaffold(template, name, dest) catch |e| {
        print("zilt new: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

/// 把 cwd 切到框架仓库根。优先 ZILT_ROOT，其次 exe 的 ../../（zig-out/bin 布局）。
/// 找不到时保持原 cwd（scaffold 会以 SourceMissing 报错）。
fn chdirToFrameworkRoot(alloc: std.mem.Allocator) void {
    if (win32.getEnvUtf8(alloc, "ZILT_ROOT")) |root| {
        defer alloc.free(root);
        const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, root) catch return;
        defer alloc.free(w);
        _ = win32.SetCurrentDirectoryW(w.ptr);
        return;
    }
    var buf: [win32.MAX_PATH_W]u16 = undefined;
    const n = win32.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return;
    const exe = std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch return;
    defer alloc.free(exe);
    // <root>\zig-out\bin\zilt.exe → <root>
    var dir = std.fs.path.dirname(exe) orelse return; // ...\zig-out\bin
    dir = std.fs.path.dirname(dir) orelse return; // ...\zig-out
    const root = std.fs.path.dirname(dir) orelse return; // <root>
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, root) catch return;
    defer alloc.free(w);
    _ = win32.SetCurrentDirectoryW(w.ptr);
}
