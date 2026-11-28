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
//! argv[1] = 应用 exe（build.zig 注入）；图标取 `app_meta.icon` 或内置 zilt.ico
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

// ---------------------------------------------------------------------------
// v0.4.3 L3：WebKit 随包（AppImage 自包含）
//
// 目标：宿主没有 libwebkit2gtk-4.1 也能跑。做法：
//   1. `ldd` 收集 exe + WebKit helper 的**全部**共享库（剔除 glibc/驱动栈），
//      按 soname 摊平到 `usr/lib/`（loader 按 soname 查找，无需符号链）；
//   2. helper 进程目录（WebKitWebProcess/NetworkProcess/GPUProcess +
//      injected-bundle）复制到 `usr/lib/<triplet>/webkit2gtk-4.1/`；
//   3. **改写 libwebkit 里的编译期路径**：2.52 无 WEBKIT_EXEC_PATH（strace
//      实测设置无效），helper 路径是常量 `/usr/lib/<triplet>/webkit2gtk-4.1`。
//      等长改写为 `/tmp/.zk-<hash>`（AppImage 挂载点长度可变，不能写死），
//      并把 `/injected-bundle/` 后缀一并改写（双保险，AppRun 亦设
//      WEBKIT_INJECTED_BUNDLE_PATH）；
//   4. AppRun 换成 bundled 版（LD_LIBRARY_PATH / GIO 模块 / pixbuf loaders /
//      GSettings schema / helper 符号链）。
// ---------------------------------------------------------------------------

fn runTool(alloc: Allocator, argv: []const []const u8) ?[]u8 {
    const r = std.process.run(alloc, sharedIo(), .{
        .argv = argv,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch return null;
    alloc.free(r.stderr);
    if (!r.term.success()) {
        alloc.free(r.stdout);
        return null;
    }
    return r.stdout;
}

fn fileSize(path: []const u8) u64 {
    // 0.17：std.fs.cwd 已移除，走 Io.Dir（绝对/相对均可）
    const st = std.Io.Dir.cwd().statFile(sharedIo(), path, .{}) catch return 0;
    return st.size;
}

/// `cp -aL src dst`（跟随符号链：ldd 目录里的 soname 常是链，链目标不随包会悬空）。
fn copyFile(alloc: Allocator, src: []const u8, dst: []const u8) bool {
    if (runTool(alloc, &.{ "cp", "-aL", src, dst })) |out| {
        alloc.free(out);
        return true;
    }
    return false;
}

/// `cp -aL src/. dst/`（目录内容合并；dst 必须是已存在的目录）。
fn copyDirInto(alloc: Allocator, src: []const u8, dst: []const u8) bool {
    const src_dot = std.fmt.allocPrint(alloc, "{s}/.", .{src}) catch return false;
    defer alloc.free(src_dot);
    if (runTool(alloc, &.{ "cp", "-aL", src_dot, dst })) |out| {
        alloc.free(out);
        return true;
    }
    return false;
}

/// 把 `binary` 的 ldd 依赖按 soname 摊平复制到 `lib_dir`（去重、剔除系统库）。
fn collectLibs(alloc: Allocator, binary: []const u8, lib_dir: []const u8, seen: *std.StringHashMapUnmanaged(void)) usize {
    const out = runTool(alloc, &.{ "ldd", binary }) orelse return 0;
    defer alloc.free(out);
    var copied: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const e = pack_formats.parseLddLine(line) orelse continue;
        if (pack_formats.lddExcluded(e.soname)) continue;
        const gop = seen.getOrPut(alloc, e.soname) catch continue;
        if (gop.found_existing) continue;
        const dst = std.fmt.allocPrint(alloc, "{s}/{s}", .{ lib_dir, e.soname }) catch continue;
        defer alloc.free(dst);
        if (!copyFile(alloc, e.path, dst)) {
            _ = seen.remove(e.soname);
            continue;
        }
        copied += 1;
    }
    return copied;
}

/// WebKit 随包主流程。成功返回 true（AppRun 已换 bundled 版）。
fn bundleWebkit(alloc: Allocator, app_dir: []const u8, app_bin: []const u8, meta: PackMeta, wk_dir: []const u8) bool {
    const lib_dir = pathJoin(alloc, app_dir, "usr/lib") catch return false;
    mkDirs(alloc, lib_dir);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);

    // 1) exe 依赖闭包（同时留一份 ldd 文本用于定位 libwebkit）
    const exe_out = runTool(alloc, &.{ "ldd", app_bin }) orelse {
        std.debug.print("[pack:webkit] ldd 不可用——跳过 WebKit 随包（宿主依赖模式）\n", .{});
        return false;
    };
    defer alloc.free(exe_out);
    var lib_count: usize = 0;
    var webkit_host: ?[]const u8 = null;
    var webkit_soname: ?[]const u8 = null;
    {
        var it = std.mem.splitScalar(u8, exe_out, '\n');
        while (it.next()) |line| {
            const e = pack_formats.parseLddLine(line) orelse continue;
            if (std.mem.startsWith(u8, e.soname, "libwebkit2gtk-")) {
                webkit_host = e.path;
                webkit_soname = e.soname;
            }
            if (pack_formats.lddExcluded(e.soname)) continue;
            const gop = seen.getOrPut(alloc, e.soname) catch continue;
            if (gop.found_existing) continue;
            const dst = std.fmt.allocPrint(alloc, "{s}/{s}", .{ lib_dir, e.soname }) catch continue;
            defer alloc.free(dst);
            if (!copyFile(alloc, e.path, dst)) {
                _ = seen.remove(e.soname);
                continue;
            }
            lib_count += 1;
        }
    }

    // 2) 定位 WebKit：triplet + helper 目录
    const wk_lib_host = webkit_host orelse {
        std.debug.print("[pack:webkit] 未在 ldd 中找到 libwebkit2gtk——跳过随包\n", .{});
        return false;
    };
    const wk_soname = webkit_soname orelse return false;
    const host_libdir = std.fs.path.dirname(wk_lib_host) orelse return false;
    const triplet = std.fs.path.basename(host_libdir);
    const helpers_host = std.fmt.allocPrint(alloc, "{s}/webkit2gtk-4.1", .{host_libdir}) catch return false;
    defer alloc.free(helpers_host);

    // 3) helper 依赖闭包（helper 是独立可执行文件，不在 libwebkit 的 ldd 里）
    for ([_][]const u8{ "WebKitWebProcess", "WebKitNetworkProcess", "WebKitGPUProcess" }) |name| {
        const hp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ helpers_host, name }) catch continue;
        defer alloc.free(hp);
        if (fileSize(hp) == 0) continue;
        lib_count += collectLibs(alloc, hp, lib_dir, &seen);
    }

    // 4) helper 目录 → AppDir（helper + injected-bundle + 探测文件）
    const helpers_dst = std.fmt.allocPrint(alloc, "{s}/usr/lib/{s}/webkit2gtk-4.1", .{ app_dir, triplet }) catch return false;
    defer alloc.free(helpers_dst);
    mkDirs(alloc, helpers_dst);
    if (!copyDirInto(alloc, helpers_host, helpers_dst)) {
        std.debug.print("[pack:webkit] helper 目录复制失败\n", .{});
        return false;
    }

    // 5) 改写 libwebkit 字面量路径（先改带 /injected-bundle/ 的长串，再改前缀）
    const wk_lib_dst = std.fmt.allocPrint(alloc, "{s}/{s}", .{ lib_dir, wk_soname }) catch return false;
    defer alloc.free(wk_lib_dst);
    const bytes = readFileAlloc(alloc, wk_lib_dst, 512 * 1024 * 1024) orelse {
        std.debug.print("[pack:webkit] libwebkit 读取失败（{s}，{d} bytes）\n", .{ wk_lib_dst, fileSize(wk_lib_dst) });
        return false;
    };
    defer alloc.free(bytes);
    const prefix = std.fmt.allocPrint(alloc, "{s}/webkit2gtk-4.1", .{host_libdir}) catch return false;
    defer alloc.free(prefix);
    const long_needle = std.fmt.allocPrint(alloc, "{s}/injected-bundle/", .{prefix}) catch return false;
    defer alloc.free(long_needle);
    const long_repl = std.fmt.allocPrint(alloc, "{s}/injected-bundle/", .{wk_dir}) catch return false;
    defer alloc.free(long_repl);
    const n_bundle = pack_formats.patchCStringInPlace(bytes, long_needle, long_repl);
    const n_helper = pack_formats.patchCStringInPlace(bytes, prefix, wk_dir);
    if (!writeFile(alloc, wk_lib_dst, bytes, 0o644)) {
        std.debug.print("[pack:webkit] libwebkit 回写失败\n", .{});
        return false;
    }
    std.debug.print("[pack:webkit] libwebkit 路径改写: helper×{d} / injected-bundle×{d} -> {s}\n", .{ n_helper, n_bundle, wk_dir });

    // 6) 可选运行时面：GIO 模块（TLS）、gdk-pixbuf loaders、GLib schemas
    const extras = [_][]const u8{ "gio/modules", "gdk-pixbuf-2.0/2.10.0/loaders" };
    for (extras) |rel| {
        const src = std.fmt.allocPrint(alloc, "{s}/{s}", .{ host_libdir, rel }) catch continue;
        defer alloc.free(src);
        var dir_ok = true;
        if (std.Io.Dir.cwd().openDir(sharedIo(), src, .{})) |d| {
            var dd = d;
            dd.close(sharedIo());
        } else |_| dir_ok = false;
        if (!dir_ok) continue;
        const dst = std.fmt.allocPrint(alloc, "{s}/usr/lib/{s}/{s}", .{ app_dir, triplet, rel }) catch continue;
        defer alloc.free(dst);
        mkDirs(alloc, dst);
        _ = copyDirInto(alloc, src, dst);
    }
    if (fileSize("/usr/share/glib-2.0/schemas/gschemas.compiled") > 0) {
        const schema_dst = std.fmt.allocPrint(alloc, "{s}/usr/share/glib-2.0/schemas", .{app_dir}) catch return false;
        defer alloc.free(schema_dst);
        mkDirs(alloc, schema_dst);
        const dst_file = std.fmt.allocPrint(alloc, "{s}/gschemas.compiled", .{schema_dst}) catch return false;
        defer alloc.free(dst_file);
        _ = copyFile(alloc, "/usr/share/glib-2.0/schemas/gschemas.compiled", dst_file);
    }

    // 7) AppRun → bundled 版
    const apprun_filled = fillBundledAppRun(alloc, meta, triplet, wk_dir) orelse return false;
    defer alloc.free(apprun_filled);
    const apprun_path = pathJoin(alloc, app_dir, "AppRun") catch return false;
    defer alloc.free(apprun_path);
    if (!writeFile(alloc, apprun_path, apprun_filled, 0o755)) return false;
    std.debug.print("[pack:webkit] 随包完成: libs={d} triplet={s} wk={s}\n", .{ lib_count, triplet, wk_dir });
    return true;
}

fn fillBundledAppRun(alloc: Allocator, meta: PackMeta, triplet: []const u8, wk_dir: []const u8) ?[]u8 {
    const exe_base = exeBaseName(alloc, meta) catch return null;
    var s = std.mem.replaceOwned(u8, alloc, pack_formats.apprun_script_bundled, "APP_EXE_NAME", exe_base) catch return null;
    s = std.mem.replaceOwned(u8, alloc, s, "@TRIPLET@", triplet) catch return null;
    s = std.mem.replaceOwned(u8, alloc, s, "WK_DIR", wk_dir) catch return null;
    return s;
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
        // v0.4.3 L5：包架构跟随构建目标（ARM64 容器内原生构建 → aarch64）
        .arch = @tagName(@import("builtin").cpu.arch),
    };
    const pkg = try pack_formats.debianName(alloc, meta.app_id);
    const desktop_name = try desktopFileName(alloc, pkg);
    const exe_base = try exeBaseName(alloc, meta);

    // 图标：flavor 覆盖的 app_meta.icon，否则内置 zilt.ico（帧即 PNG）
    const icon_path = getEnv(alloc, "ZILT_ICON") orelse (app_meta.icon orelse "src/zilt/assets/zilt.ico");
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
    // v0.3.16 G24：resources 收集（exe 旁 resources/** 递归；deb/AppDir 同布局
    // —— exe 相对路径解析，`path.resource` 在两种安装形态下语义一致）
    var resource_files: std.ArrayListUnmanaged(pack_formats.ResFile) = .empty;
    const resources_root = try pathJoin(alloc, src_dir, "resources");
    collectResources(alloc, resources_root, "", &resource_files);
    if (resource_files.items.len > 0) {
        std.debug.print("[pack] resources: {d} file(s)\n", .{resource_files.items.len});
    }

    const deb = try pack_formats.buildDebOpt(alloc, meta, exe_bytes.?, .{
        .depends = &.{ "libgtk-3-0", "libwebkit2gtk-4.1-0", "libsqlite3-0" },
        .postinst_lines = &.{mime_line},
        .icon_png = icon_png,
        .extra_files = sidecar_bytes.items,
        .resources = resource_files.items,
    });
    const deb_out = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}_{s}_{s}.deb", .{ pkg, meta.version, pack_formats.debArch(meta.arch) }));
    if (!writeFile(alloc, deb_out, deb, 0o644)) return error.WriteFailed;
    std.debug.print("[pack] deb -> {s}（{d} bytes）\n", .{ deb_out, deb.len });

    // ---- 2) AppDir（AppRun 可直接执行）+ squashfs ----
    const app_dir = try pathJoin(alloc, out_dir, pkg);
    // 先清上一轮 AppDir：历史残留（旧版本桌面项/图标/旧 WebKit 库）会被
    // squashfs 一起打进 AppImage——v0.4.3 实测发现 11-15 的
    // `app.zilt.desktop.desktop` 还在（发布物污染）
    std.Io.Dir.cwd().deleteTree(sharedIo(), app_dir) catch {};
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

    // v0.3.16 G24：resources → AppDir usr/bin/resources/**（与 deb 同布局）
    for (resource_files.items) |rf| {
        const dst_full = try pathJoin(alloc, app_dir, try std.fmt.allocPrint(alloc, "usr/bin/resources/{s}", .{rf.rel}));
        const dst_parent = std.fs.path.dirname(dst_full) orelse continue;
        mkDirs(alloc, dst_parent);
        if (!writeFile(alloc, dst_full, rf.bytes, 0o644)) return error.WriteFailed;
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

    // v0.4.3 L3：WebKit 随包（ZILT_BUNDLE_WEBKIT=1）。ldd/cp 缺失时保持宿主依赖，
    // 并在日志里明确原因——默认关闭，发布 AppImage 时才需要自包含。
    {
        const flag = getEnv(alloc, "ZILT_BUNDLE_WEBKIT");
        const enabled = if (flag) |v| !std.mem.eql(u8, v, "0") else false;
        if (enabled) {
            const wk_dir = pack_formats.webkitRuntimeDir(alloc, meta.app_id, meta.version) catch return error.OutOfMemory;
            defer alloc.free(wk_dir);
            if (!bundleWebkit(alloc, app_dir, app_bin, meta, wk_dir)) {
                std.debug.print("[pack:webkit] 随包失败——AppRun 保持宿主依赖模式\n", .{});
            }
        }
    }

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
    const spec = try pack_formats.generateRpmSpecOpt(alloc, meta, icon_png != null);
    const spec_out = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}.spec", .{pkg}));
    if (!writeFile(alloc, spec_out, spec, 0o644)) return error.WriteFailed;
    std.debug.print("[pack] spec -> {s}（rpmbuild -bb 可构建）\n", .{spec_out});

    // ---- 5) AUR（v0.4.3 L5）：dist/aur/PKGBUILD + .SRCINFO（-bin 形态）----
    const aur_dir = try pathJoin(alloc, out_dir, "aur");
    mkDirs(alloc, aur_dir);
    const pkgbuild = try pack_formats.generatePkgbuild(alloc, meta);
    const pkb_out = try pathJoin(alloc, aur_dir, "PKGBUILD");
    if (!writeFile(alloc, pkb_out, pkgbuild, 0o644)) return error.WriteFailed;
    const srcinfo = try pack_formats.generateSrcinfo(alloc, meta);
    const src_out = try pathJoin(alloc, aur_dir, ".SRCINFO");
    if (!writeFile(alloc, src_out, srcinfo, 0o644)) return error.WriteFailed;
    std.debug.print("[pack] aur -> {s}（PKGBUILD + .SRCINFO；makepkg -sf 走通为验收项）\n", .{aur_dir});
}


/// v0.3.16 G24：递归收集 `<root>/**` → ResFile{rel, bytes}（'/' 分隔相对路径；
/// root 不存在 = 静默空集——模板项目未声明 resources 时零开销）。
fn collectResources(alloc: Allocator, root: []const u8, rel: []const u8, out: *std.ArrayListUnmanaged(pack_formats.ResFile)) void {
    const full = if (rel.len == 0) root else pathJoin(alloc, root, rel) catch return;
    // libc opendir/readdir（与工具其余 std.c 风格一致；Io walker 的句柄语义在
    // 递归场景实测 BADF——本工具不做 async，直呼 libc 最稳）
    const z = alloc.allocSentinel(u8, full.len, 0) catch return;
    defer alloc.free(z);
    @memcpy(z, full);
    const dir = std.c.opendir(z.ptr) orelse return;
    defer _ = std.c.closedir(dir);
    while (true) {
        const entry = std.c.readdir(dir) orelse break;
        const d: *posixDirent = @ptrCast(@alignCast(entry));
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&d.d_name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child_rel = if (rel.len == 0)
            (alloc.dupe(u8, name) catch continue)
        else
            (pathJoin(alloc, rel, name) catch continue);
        switch (d.d_type) {
            4 => collectResources(alloc, root, child_rel, out), // DT_DIR
            8, 10 => { // DT_REG / DT_LNK
                const child_full = pathJoin(alloc, root, child_rel) catch continue;
                const bytes = readFileAlloc(alloc, child_full, 64 * 1024 * 1024) orelse continue;
                out.append(alloc, .{ .rel = child_rel, .bytes = bytes }) catch return;
            },
            else => {},
        }
    }
}

/// glibc readdir 返回的 dirent 布局（x86_64 上即 dirent64；d_type 在
/// d_reclen 后，d_name 以 NUL 结尾）
const posixDirent = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};
