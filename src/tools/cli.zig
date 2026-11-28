//! Zilt CLI（v0.1.17）：`zilt doctor` / `zilt info` / `zilt version`。
//!
//! 定位是「包装现有 zig build step 的薄壳 + 环境自检」：
//!  - `doctor` 检查构建链（Zig / WebView2 运行时 / makensis / 前端 dist / 图标）
//!  - `info`   打印 project.zig 的配置摘要（版本、app_id、前端工程、图标、安装器范围）
//!
//! 输出走 stderr（与 zig build 日志一致，便于 CI 收集）；退出码非 0 表示有检查失败。
//!
//! v0.2.8：跨平台——argv 走 Args.Iterator、文件检查走 std.Io（Windows/Linux 同一
//! 份实现）；doctor 平台分派：Windows 查 WebView2/makensis/signtool/WiX，
//! Linux 查 pkg-config（gtk+-3.0 / webkit2gtk-4.1）+ xvfb-run/xdg-open/mksquashfs。
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zilt = @import("zilt");
const meta = @import("app_meta");
const signtool_locator = @import("signtool_locate.zig");
const wix_tool = @import("wix_tool.zig");

const win32 = if (builtin.os.tag == .windows) zilt.platform_windows.win32 else {};
const print = std.debug.print;

/// 工具进程的 Io（Threaded 惰性创建；doctor 的文件存在性检查用）。
var g_threaded: Io.Threaded = undefined;
var g_threaded_ready = false;
fn toolIo() Io {
    if (!g_threaded_ready) {
        g_threaded = .init(std.heap.page_allocator, .{});
        g_threaded_ready = true;
    }
    return g_threaded.io();
}

const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;

pub fn main(init: std.process.Init) !u8 {
    const alloc = std.heap.page_allocator;

    // v0.2.8：argv 读取跨平台化（Args.Iterator 两平台同用；替代 CommandLineToArgvW）
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer it.deinit();
    _ = it.skip(); // argv[0]

    var args: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }
    while (it.next()) |raw| {
        try args.append(alloc, try alloc.dupe(u8, raw));
    }

    const cmd = if (args.items.len > 0) args.items[0] else "help";
    const eql = std.mem.eql;

    if (eql(u8, cmd, "version") or eql(u8, cmd, "--version") or eql(u8, cmd, "-v")) {
        printVersion();
        return 0;
    }
    if (eql(u8, cmd, "doctor")) return runDoctor(alloc);
    if (eql(u8, cmd, "info")) return runInfo();
    // v0.6.0a：flavor 语法糖——翻译成 zig build -Dflavor/-Dconfig
    if (eql(u8, cmd, "build")) return runBuild(init, alloc, args.items[1..]);
    if (eql(u8, cmd, "mcp")) return runMcp(init, alloc, args.items[1..]);
    if (eql(u8, cmd, "icon")) return runIcon(alloc, args.items[1..]);
    if (eql(u8, cmd, "npm-pack")) return runNpmPack(alloc, args.items[1..]);
    if (eql(u8, cmd, "new")) return runNew(alloc, args.items[1..]);
    // v0.4.1 H12：CLI 自更新（ed25519 清单 + sha256 + staging 原子替换）
    if (eql(u8, cmd, "self-update")) return runSelfUpdate(alloc, args.items[1..]);
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
        \\  zilt mcp [app] 以 MCP stdio 直连应用（默认取同目录 zilt-app / ZILT_MCP_APP）
        \\  zilt version   打印版本
        \\  zilt icon <in.png> [-o out.ico] [--sizes 16,32,48,256]
        \\                 PNG → 多尺寸 .ico（Windows 发布图标）
        \\  zilt npm-pack [-o npm] [--name @zilt/runtime] [--version <x.y.z>]
        \\                 生成 @zilt/runtime npm 包（package.json/index.js/index.d.ts）
        \\  zilt self-update --manifest <url> --pubkey <64hex> [--github owner/repo]
        \\                 [--channel stable|beta] [--exe-name <name>]
        \\                 CLI 自身经更新器基建更新（ed25519 验签 + 原子替换 + .zilt-old 备份）
        \\  zilt build [--flavor dev|beta|prod] [--config extra.json] [zig build 参数...]
        \\                 转译成 zig build -Dflavor=... -Dconfig=...（flavor 文件：zilt.<name>.json）
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

/// v0.3.1：`zilt mcp [app]` —— 用 MCP stdio 直连应用。
/// 实现方式：把 `ZILT_HEADLESS=1 ZILT_MCP_STDIO=1` 注入环境后原地 spawn 应用，
/// stdin/stdout/stderr 全部继承——不额外占端口、不需要桥接进程。
fn runMcp(init: std.process.Init, alloc: std.mem.Allocator, rest: []const []const u8) !u8 {
    var explicit: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eqlStr(a, "--help") or eqlStr(a, "-h")) {
            print(
                \\用法: zilt mcp [app-path]
                \\  默认取同目录 zilt-app（Windows: zilt-app.exe），可用 ZILT_MCP_APP 覆盖。
                \\  走的传输是 MCP stdio（一行一条 JSON-RPC），stdout 只输出响应。
                \\
            , .{});
            return 0;
        }
        if (eqlStr(a, "--app")) {
            if (i + 1 >= rest.len) {
                print("zilt mcp: --app 缺少路径\n", .{});
                return 2;
            }
            explicit = rest[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-")) {
            print("zilt mcp: 未知选项 '{s}'\n", .{a});
            return 2;
        }
        explicit = a;
    }

    var owned: ?[]u8 = null;
    defer if (owned) |p| alloc.free(p);

    const app_path: []const u8 = explicit orelse blk: {
        if (init.environ_map.get("ZILT_MCP_APP")) |p| break :blk p;
        const exe = std.process.executablePathAlloc(init.io, alloc) catch {
            print("zilt mcp: 无法定位 zilt 可执行文件\n", .{});
            return 1;
        };
        defer alloc.free(exe);
        const dir = std.fs.path.dirname(exe) orelse ".";
        const name = if (builtin.os.tag == .windows) "zilt-app.exe" else "zilt-app";
        owned = std.fs.path.join(alloc, &.{ dir, name }) catch {
            print("zilt mcp: 路径分配失败\n", .{});
            return 1;
        };
        break :blk owned.?;
    };

    _ = std.Io.Dir.cwd().statFile(init.io, app_path, .{}) catch {
        print(
            "zilt mcp: 找不到应用 '{s}'\n  用法: zilt mcp <path/to/zilt-app>（或设置 ZILT_MCP_APP）\n",
            .{app_path},
        );
        return 2;
    };

    var env = init.environ_map.clone(alloc) catch {
        print("zilt mcp: 环境变量克隆失败\n", .{});
        return 1;
    };
    defer env.deinit();
    env.put("ZILT_HEADLESS", "1") catch return 1;
    env.put("ZILT_MCP_STDIO", "1") catch return 1;

    var child = std.process.spawn(init.io, .{
        .argv = &.{app_path},
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env,
    }) catch |e| {
        print("zilt mcp: 启动失败: {s}\n", .{@errorName(e)});
        return 1;
    };
    const term = child.wait(init.io) catch return 1;
    return switch (term) {
        .exited => |code| @intCast(code),
        else => 1,
    };
}

fn eqlStr(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn runDoctor(alloc: std.mem.Allocator) !u8 {
    var issues: usize = 0;

    const v = builtin.zig_version;
    print("[ok]   Zig {d}.{d}.{d}\n", .{ v.major, v.minor, v.patch });

    if (builtin.os.tag == .windows) {
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
    } else {
        // v0.2.8：Linux 构建链检查（pkg-config 包 + 运行时工具）
        for ([_][]const u8{ "gtk+-3.0", "webkit2gtk-4.1" }) |pkg| {
            if (pkgConfigExists(alloc, pkg)) {
                print("[ok]   pkg-config: {s}\n", .{pkg});
            } else {
                print("[fail] pkg-config: {s} 缺失 — Ubuntu/Debian: sudo apt install {s}\n", .{
                    pkg, if (std.mem.eql(u8, pkg, "gtk+-3.0")) "libgtk-3-dev" else "libwebkit2gtk-4.1-dev",
                });
                issues += 1;
            }
        }
        if (findInPath(alloc, "xvfb-run")) |p| {
            defer alloc.free(p);
            print("[ok]   xvfb-run: {s}\n", .{p});
        } else {
            print("[info] xvfb-run not in PATH — 冒烟/E2E 需要（sudo apt install xvfb）\n", .{});
        }
        if (findInPath(alloc, "xdg-open")) |p| {
            defer alloc.free(p);
            print("[ok]   xdg-open: {s}\n", .{p});
        } else {
            print("[info] xdg-open not in PATH — shell/openUrl 与深链注册需要（sudo apt install xdg-utils）\n", .{});
        }
        if (findInPath(alloc, "mksquashfs")) |p| {
            defer alloc.free(p);
            print("[ok]   mksquashfs: {s}\n", .{p});
        } else {
            print("[info] mksquashfs not in PATH — `zig build pack` 跳过 squashfs（sudo apt install squashfs-tools）\n", .{});
        }
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

/// v0.6.0a：`zilt build [--flavor NAME] [--config FILE] [zig build args...]`
/// 只做参数转译（JSON 解析在 build.zig 配置期），其余原样转发。
fn runBuild(init: std.process.Init, alloc: std.mem.Allocator, args: []const []u8) u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.append(a, "zig") catch return 1;
    argv.append(a, "build") catch return 1;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        var opt: ?[]const u8 = null;
        var val: ?[]const u8 = null;

        if (eqlStr(arg, "--flavor") or eqlStr(arg, "-F")) {
            opt = "-Dflavor=";
            if (i + 1 >= args.len) {
                print("zilt build: --flavor 缺少值\n", .{});
                return 2;
            }
            i += 1;
            val = args[i];
        } else if (eqlStr(arg, "--config") or eqlStr(arg, "-C")) {
            opt = "-Dconfig=";
            if (i + 1 >= args.len) {
                print("zilt build: --config 缺少值\n", .{});
                return 2;
            }
            i += 1;
            val = args[i];
        } else if (std.mem.startsWith(u8, arg, "--flavor=")) {
            opt = "-Dflavor=";
            val = arg["--flavor=".len..];
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            opt = "-Dconfig=";
            val = arg["--config=".len..];
        }

        if (opt) |prefix| {
            argv.append(a, std.fmt.allocPrint(a, "{s}{s}", .{ prefix, val.? }) catch return 1) catch return 1;
        } else {
            argv.append(a, arg) catch return 1;
        }
    }

    var child = std.process.spawn(init.io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = init.environ_map,
    }) catch |e| {
        print("zilt build: 启动 zig 失败: {s}\n", .{@errorName(e)});
        return 1;
    };
    const term = child.wait(init.io) catch return 1;
    return switch (term) {
        .exited => |code| @intCast(code),
        else => 1,
    };
}

fn runInfo() u8 {
    const project = meta;
    print("app_name   {s}\n", .{project.app_name});
    print("flavor     {s}\n", .{if (project.flavor.len > 0) project.flavor else "(none)"});
    print("publisher  {s}\n", .{project.publisher});
    print("version    {s}\n", .{project.version});
    print("app_id     {s}\n", .{project.app_id});
    print("channel    {s}\n", .{project.channel});
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

/// Windows 的 PATH 查找（SearchPathW 自带 .exe 补全）。extern 声明惰性分析：
/// Linux 构建不引用即不参与编译。
extern "kernel32" fn SearchPathW(
    lpPath: ?[*:0]const u16,
    lpFileName: [*:0]const u16,
    lpExtension: ?[*:0]const u16,
    nBufferLength: u32,
    lpBuffer: [*]u16,
    lpFilePart: ?*?[*:0]u16,
) u32;

/// pkg-config --exists（Linux 构建链检查）。子进程退出码 0 = 存在。
fn pkgConfigExists(alloc: std.mem.Allocator, pkg: []const u8) bool {
    if (findInPath(alloc, "pkg-config") == null) return false;
    var child = std.process.spawn(toolIo(), .{
        .argv = &.{ "pkg-config", "--exists", pkg },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(toolIo()) catch return false;
    return term.success();
}

/// PATH 中查找可执行文件（Windows 走 SearchPathW；其他平台扫 PATH）。
fn findInPath(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (builtin.os.tag == .windows) {
        const name_z = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
        defer alloc.free(name_z);
        var buf: [1024]u16 = undefined;
        const n = SearchPathW(null, name_z.ptr, null, buf.len, &buf, null);
        if (n == 0 or n >= buf.len) return null;
        return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch null;
    }
    // Linux：扫 PATH（zilt doctor 检查 xdg-open / xvfb-run / pkg-config 用）
    const path_env = std.c.getenv("PATH") orelse return null;
    var dirs = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const cand = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch return null;
        defer alloc.free(cand);
        if (fileExists(alloc, cand)) return alloc.dupe(u8, cand) catch null;
    }
    return null;
}

/// v0.2.8：文件存在性检查走 std.Io（两平台同用；statFile 对目录/文件均返回）。
fn statExists(path: []const u8) ?bool {
    const st = Io.Dir.cwd().statFile(toolIo(), path, .{}) catch return null;
    return st.kind == .directory;
}

fn dirExists(alloc: std.mem.Allocator, path: []const u8) bool {
    _ = alloc;
    return (statExists(path) orelse false);
}

fn fileExists(alloc: std.mem.Allocator, path: []const u8) bool {
    _ = alloc;
    const st = Io.Dir.cwd().statFile(toolIo(), path, .{}) catch return false;
    return st.kind != .directory;
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

    const png_bytes = Io.Dir.cwd().readFileAlloc(toolIo(), in_path, alloc, .limited(64 * 1024 * 1024)) catch {
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

    Io.Dir.cwd().writeFile(toolIo(), .{ .sub_path = output, .data = ico_bytes }) catch {
        print("zilt icon: cannot write '{s}'\n", .{output});
        return 1;
    };
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
    var version: []const u8 = zilt.version;
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

    // 目录不存在则创建（std.Io，已存在视为成功）
    _ = Io.Dir.cwd().createDirPathStatus(toolIo(), out_dir, .default_dir) catch return 1;
    for (targets) |t| {
        const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ out_dir, t.name }) catch return 1;
        defer alloc.free(path);
        Io.Dir.cwd().writeFile(toolIo(), .{ .sub_path = path, .data = t.data }) catch {
            print("zilt npm-pack: cannot write '{s}'\n", .{path});
            return 1;
        };
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
/// v0.2.8：跨平台——env 走 std.c.getenv/Win32 分派，exe 路径走 executablePathAlloc，
/// chdir 走 Win32/libc（0.17 的 std 无 chdir）。
fn chdirToFrameworkRoot(alloc: std.mem.Allocator) void {
    var root: ?[]u8 = null;
    defer if (root) |r| alloc.free(r);
    if (builtin.os.tag == .windows) {
        root = win32.getEnvUtf8(alloc, "ZILT_ROOT");
    } else if (std.c.getenv("ZILT_ROOT")) |v| {
        root = alloc.dupe(u8, std.mem.span(v)) catch null;
    }
    if (root == null) {
        const exe = std.process.executablePathAlloc(toolIo(), alloc) catch return;
        defer alloc.free(exe);
        // <root>/zig-out/bin/zilt(.exe) → <root>（三层 dirname）
        var dir = std.fs.path.dirname(exe) orelse return; // <root>/zig-out/bin
        dir = std.fs.path.dirname(dir) orelse return; // <root>/zig-out
        const parent = std.fs.path.dirname(dir) orelse return; // <root>
        root = alloc.dupe(u8, parent) catch return;
    }
    const r = root.?;
    if (builtin.os.tag == .windows) {
        const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, r) catch return;
        defer alloc.free(w);
        _ = win32.SetCurrentDirectoryW(w.ptr);
    } else {
        const rz = alloc.allocSentinel(u8, r.len, 0) catch return;
        defer alloc.free(rz);
        @memcpy(rz, r);
        _ = std.c.chdir(rz.ptr); // 失败保持原 cwd（scaffold 报 SourceMissing）
    }
}

// ---------------------------------------------------------------------------
// v0.4.1 H12：`zilt self-update` —— CLI 自身经 updater 基建更新。
// ed25519 清单验签 + sha256 + staging 原子替换 + .zilt-old 备份（与应用侧同一套
// updater.zig 流程；目标 = zilt.exe 自身，重启由用户执行新 exe 完成）。
// 凭据：--manifest/--pubkey/--github/--channel/--exe-name 参数，或
// ZILT_UPDATE_URL / ZILT_UPDATE_PK 环境变量（与应用侧 env 覆盖同名呼应）。
// ---------------------------------------------------------------------------

fn cliFetchFn(ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8) anyerror![]u8 {
    _ = ctx;
    var threaded: Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = alloc, .io = threaded.io() };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });
    if (result.status != .ok) return error.HttpRequestFailed;
    return aw.toOwnedSlice();
}

/// 跨平台 env 读取（Windows win32 / Linux std.c——cli 的 Windows 构建不链
/// libc，std.c.getenv 会触发链接要求）。返回值泄漏到进程退出（短生命周期）。
fn cliGetEnv(alloc: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        const w = zilt.platform_windows.win32;
        const v = w.getEnvUtf8(alloc, name) orelse return null;
        if (v.len == 0) {
            alloc.free(v);
            return null;
        }
        return v;
    }
    const name_z = alloc.allocSentinel(u8, name.len, 0) catch return null;
    defer alloc.free(name_z);
    @memcpy(name_z[0..name.len], name);
    const v = std.c.getenv(name_z.ptr) orelse return null;
    return alloc.dupe(u8, std.mem.span(v)) catch null;
}

fn runSelfUpdate(alloc: std.mem.Allocator, rest: []const []const u8) !u8 {
    const eql = std.mem.eql;
    var manifest_url: ?[]const u8 = null;
    var pubkey_hex: ?[]const u8 = null;
    var github: ?[]const u8 = null;
    var channel: []const u8 = "stable";
    var exe_name: []const u8 = "zilt.exe";
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        const val = if (i + 1 < rest.len) rest[i + 1] else null;
        if (eql(u8, a, "--manifest") and val != null) { manifest_url = val; i += 1; } else if (eql(u8, a, "--pubkey") and val != null) {
            pubkey_hex = val;
            i += 1;
        } else if (eql(u8, a, "--github") and val != null) {
            github = val;
            i += 1;
        } else if (eql(u8, a, "--channel") and val != null) {
            channel = val.?;
            i += 1;
        } else if (eql(u8, a, "--exe-name") and val != null) {
            exe_name = val.?;
            i += 1;
        } else {
            print("self-update: unknown arg '{s}'\n", .{a});
            return 2;
        }
    }
    if (manifest_url == null) manifest_url = cliGetEnv(alloc, "ZILT_UPDATE_URL");
    if (pubkey_hex == null) pubkey_hex = cliGetEnv(alloc, "ZILT_UPDATE_PK");
    if (manifest_url == null or pubkey_hex == null) {
        print("self-update 需要 --manifest <url> --pubkey <64hex>（或 ZILT_UPDATE_URL / ZILT_UPDATE_PK 环境变量）\n", .{});
        return 2;
    }
    var pk: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk, pubkey_hex.?) catch {
        print("公钥格式非法（需要 64 个 hex 字符）\n", .{});
        return 2;
    };
    const exe_path = std.process.executablePathAlloc(toolIo(), alloc) catch {
        print("无法定位自身 exe\n", .{});
        return 1;
    };

    const fetcher = zilt.updater.Fetcher{ .ctx = @ptrFromInt(1), .fetchFn = cliFetchFn };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const env = zilt.updater.Env{
        .manifest_url = manifest_url.?,
        .public_key = pk,
        .current_version = zilt.version,
        .exe_path = @constCast(exe_path),
        .exe_name = exe_name,
        .fetcher = fetcher,
        .channel = if (eql(u8, channel, "beta")) .beta else .stable,
        .github_repo = github,
    };

    print("self-update: 当前 {s}（{s}）\n  manifest={s}\n", .{ zilt.version, exe_path, manifest_url.? });
    const m = zilt.updater.checkForUpdateEnv(arena.allocator(), env) catch |e| {
        print("检查失败: {s}\n", .{@errorName(e)});
        return 1;
    };
    if (m == null) {
        print("已是最新版本\n", .{});
        return 0;
    }
    print("发现新版本 {s}：{s}\n下载中...\n", .{ m.?.version, m.?.notes });
    const artifact = zilt.updater.downloadAndVerify(alloc, env.fetcher, m.?, pk) catch |e| {
        print("下载/验签失败: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer alloc.free(artifact);
    // zip（PK 魔数）→ stageUpdate 解出 exe_name；裸 exe → stageBytes 直替
    if (artifact.len > 4 and artifact[0] == 'P' and artifact[1] == 'K') {
        _ = zilt.updater.stageUpdate(alloc, exe_path, exe_name, artifact) catch |e| {
            print("暂存失败: {s}\n", .{@errorName(e)});
            return 1;
        };
    } else {
        zilt.updater.stageBytes(alloc, exe_path, artifact) catch |e| {
            print("暂存失败: {s}\n", .{@errorName(e)});
            return 1;
        };
    }
    print("已暂存 {s} → 重启 zilt 生效（旧版备份 .zilt-old，10s 健康后清理）\n", .{exe_path});
    return 0;
}
