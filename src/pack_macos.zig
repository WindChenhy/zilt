//! macOS 打包编排（v0.5.3）：`ZILT_PACK_OUT=<dir> zig build pack`（macOS 目标）。
//!
//! 产物（dist/）：
//!   - `<name>.app/` —— Contents/MacOS/<exe> + Contents/Resources/AppIcon.icns
//!     + Info.plist（深链/TCC/分类，pack_formats.generateInfoPlistOpt）+ PkgInfo
//!   - `bundle-dmg.sh` —— hdiutil 拖装 DMG 脚本（pack_formats.generateBundleDmgScript，
//!     仅 macOS 可执行；CI 跑它产出 `<name>.dmg`）
//!
//! argv[1] = 应用 exe（build.zig 注入）；图标取内置 zilt.ico（PNG 帧 → generateIcns）。
//! 与 pack_linux.zig 同构：HOST 目标 + libc 文件操作；argv 走 Args.Iterator（macOS 无 /proc）。
const std = @import("std");
const pack_formats = @import("zilt/pack_formats.zig");
const msix = @import("zilt/msix.zig");
const app_meta = @import("app_meta.zig");

const PackMeta = pack_formats.PackMeta;
const Allocator = std.mem.Allocator;

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
    const f = std.c.fopen(z.ptr, "wb") orelse {
        std.debug.print("[pack] write failed {s}\n", .{path});
        return false;
    };
    _ = std.c.fwrite(data.ptr, 1, data.len, f);
    _ = std.c.fclose(f);
    return std.c.chmod(z.ptr, @intCast(mode)) == 0;
}

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer it.deinit();
    _ = it.skip(); // argv[0]
    const exe_path = it.next() orelse {
        std.debug.print("[pack] 缺少 exe 参数（build.zig 注入 argv[1]）\n", .{});
        return 1;
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
    const pf = pack_formats;

    const exe_bytes = readFileAlloc(alloc, exe_path, 512 * 1024 * 1024) orelse {
        std.debug.print("[pack] 读 exe 失败：{s}\n", .{exe_path});
        return 1;
    };
    const app_dir = try pathJoin(alloc, out_dir, try std.fmt.allocPrint(alloc, "{s}.app", .{meta.name}));
    mkDirs(alloc, try pathJoin(alloc, app_dir, pf.macos_macos_rel));
    mkDirs(alloc, try pathJoin(alloc, app_dir, pf.macos_resources_rel));

    // 图标 best-effort：zilt.ico 的 PNG 帧 → .icns（16/32/256 可映射，48 跳过）。
    var icon_file: ?[]const u8 = null;
    if (readFileAlloc(alloc, "src/zilt/assets/zilt.ico", 16 * 1024 * 1024)) |ico| {
        if (msix.extractPngFrames(alloc, ico)) |frames| {
            var imgs: std.ArrayList(pf.IcnsImage) = .empty;
            for (frames) |f| try imgs.append(alloc, .{ .width = f.width, .png = f.png });
            if (pf.generateIcns(alloc, imgs.items)) |icns| {
                const icon_dst = try pathJoin(alloc, app_dir, try pf.macosIconRelPath(alloc, "AppIcon.icns"));
                if (writeFile(alloc, icon_dst, icns, 0o644)) icon_file = "AppIcon.icns";
            } else |_| {}
        } else |_| {}
    }

    const plist = try pf.generateInfoPlistOpt(alloc, meta, .{
        .icon_file = icon_file,
        .url_schemes = &.{"zilt"},
        .camera_usage = "Zilt needs camera access for web video features.",
        .microphone_usage = "Zilt needs microphone access for web audio features.",
        .category = "public.app-category.developer-tools",
    });
    if (!writeFile(alloc, try pathJoin(alloc, app_dir, pf.macos_info_plist_rel), plist, 0o644)) return 1;
    if (!writeFile(alloc, try pathJoin(alloc, app_dir, pf.macos_pkg_info_rel), pf.macos_pkg_info_bytes, 0o644)) return 1;
    const exe_dst = try pathJoin(alloc, app_dir, try pf.macosExeRelPath(alloc, meta));
    if (!writeFile(alloc, exe_dst, exe_bytes, 0o755)) return 1;

    // DMG 脚本（hdiutil 仅 macOS 可执行；CI 跑它产出 .dmg）。
    const dmg_script = try pf.generateBundleDmgScript(alloc, .{
        .app_name = try std.fmt.allocPrint(alloc, "{s}.app", .{meta.name}),
        .dmg_name = try std.fmt.allocPrint(alloc, "{s}.dmg", .{meta.name}),
        .volname = meta.name,
    });
    const script_dst = try pathJoin(alloc, out_dir, "bundle-dmg.sh");
    if (!writeFile(alloc, script_dst, dmg_script, 0o755)) return 1;

    std.debug.print("[pack] .app bundle -> {s}\n", .{app_dir});
    std.debug.print("[pack] DMG 脚本 -> {s}（bash 它产出 {s}.dmg）\n", .{ script_dst, meta.name });
    return 0;
}