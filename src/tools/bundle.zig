//! 打包工具：`zig build bundle` → dist/ 下产出
//!   1) <name>-<ver>-x64.zip          便携版（exe + README）
//!   2) <name>-<ver>-x64-setup.nsi    NSIS 安装脚本
//!   3) <name>-<ver>-x64-setup.exe    安装器（本机有 makensis 时；含 WebView2 引导）
//!
//! argv[1] = 待打包 exe 路径（build 系统经 addArtifactArg 注入 Release 构建）。

const std = @import("std");
const zilt = @import("zilt");
const bundler = zilt.bundler;
const meta = @import("app_meta");

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const win32 = zilt.platform_windows.win32;
    const log = zilt.log;

    // argv[1] = exe 路径（build 系统注入）。0.17 无 std.process.args 全局 → 直接解析命令行。
    var argc: i32 = 0;
    const argv_w = win32.CommandLineToArgvW(win32.GetCommandLineW(), &argc) orelse return error.ArgsFailed;
    defer _ = win32.LocalFree(@ptrCast(argv_w));
    if (argc < 2) {
        log.print("[bundle] usage: zilt-bundle <exe-path>", .{});
        return error.MissingExeArg;
    }
    const exe_path = try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(argv_w[1]));
    defer alloc.free(exe_path);

    // dist/ 输出目录
    mkdirW(alloc, "dist");

    const dir_name = try std.fmt.allocPrint(alloc, "{s}-{s}-x64", .{ meta.app_name, meta.version });
    defer alloc.free(dir_name);

    // ---- 1) 便携 zip ----
    const exe_bytes = win32.readFileAlloc(alloc, exe_path) orelse {
        log.print("[bundle] cannot read exe: {s}", .{exe_path});
        return error.ReadExeFailed;
    };
    defer alloc.free(exe_bytes);

    const inner_exe = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_name, meta.exe_name });
    defer alloc.free(inner_exe);
    const readme = try std.fmt.allocPrint(alloc,
        \\{s} {s} (portable)
        \\
        \\运行: {s}
        \\数据目录: %TEMP%\zilt-app-webview2
        \\卸载: 直接删除本目录。
        \\
    , .{ meta.app_name, meta.version, meta.exe_name });
    defer alloc.free(readme);

    const readme_inner = try std.fmt.allocPrint(alloc, "{s}/README.txt", .{dir_name});
    defer alloc.free(readme_inner);

    const entries = [_]bundler.ZipEntry{
        .{ .name = inner_exe, .content = exe_bytes },
        .{ .name = readme_inner, .content = readme },
    };

    var zip_bytes: std.ArrayList(u8) = .empty;
    defer zip_bytes.deinit(alloc);
    try bundler.writeZip(alloc, &entries, &zip_bytes);

    const zip_path = try std.fmt.allocPrint(alloc, "dist/{s}.zip", .{dir_name});
    defer alloc.free(zip_path);
    try writeFileW(alloc, zip_path, zip_bytes.items);
    log.print("[bundle] portable zip: {s} ({d} bytes)", .{ zip_path, zip_bytes.items.len });

    // ---- 2) NSIS 安装器 ----
    const exe_abs = try getFullPathW(alloc, exe_path);
    defer alloc.free(exe_abs);

    const nsi_path = try std.fmt.allocPrint(alloc, "dist/{s}-setup.nsi", .{dir_name});
    defer alloc.free(nsi_path);
    const setup_path = try std.fmt.allocPrint(alloc, "dist/{s}-setup.exe", .{dir_name});
    defer alloc.free(setup_path);

    // v0.1.15：安装器范围与附加项可由环境变量覆盖（CI / 发布流水线用）
    const env_pm = win32.getEnvUtf8(alloc, "ZILT_INSTALLER_PER_MACHINE");
    defer if (env_pm) |v| alloc.free(v);
    const per_machine = if (env_pm) |v| v.len > 0 and v[0] == '1' else false;

    const env_license = win32.getEnvUtf8(alloc, "ZILT_INSTALLER_LICENSE");
    defer if (env_license) |v| alloc.free(v);
    const license_path: ?[]const u8 = if (env_license) |v| (if (v.len > 0) v else null) else null;

    const env_icon = win32.getEnvUtf8(alloc, "ZILT_INSTALLER_ICON");
    defer if (env_icon) |v| alloc.free(v);
    const setup_icon: ?[]const u8 = if (env_icon) |v| (if (v.len > 0) v else null) else null;

    const env_scheme = win32.getEnvUtf8(alloc, "ZILT_INSTALLER_SCHEME");
    defer if (env_scheme) |v| alloc.free(v);
    const env_ext = win32.getEnvUtf8(alloc, "ZILT_INSTALLER_EXT");
    defer if (env_ext) |v| alloc.free(v);

    var scheme_buf: [1][]const u8 = undefined;
    const schemes: []const []const u8 = if (env_scheme) |v| blk: {
        if (v.len == 0) break :blk &.{};
        scheme_buf[0] = v;
        break :blk scheme_buf[0..1];
    } else &.{};

    var ext_buf: [1][]const u8 = undefined;
    const file_exts: []const []const u8 = if (env_ext) |v| blk: {
        if (v.len == 0) break :blk &.{};
        ext_buf[0] = v;
        break :blk ext_buf[0..1];
    } else &.{};

    const script = try bundler.generateNsis(alloc, .{
        .app_name = meta.app_name,
        .version = meta.version,
        .publisher = meta.publisher,
        .exe_name = meta.exe_name,
        .app_id = meta.app_id,
        .out_path = setup_path,
        .exe_path = exe_abs,
        .per_machine = per_machine,
        .license_path = license_path,
        .setup_icon = setup_icon,
        .schemes = schemes,
        .file_exts = file_exts,
    });
    // makensis 以 UTF-8 BOM 识别编码（脚本含非 ASCII 注释）
    const bom = "\xEF\xBB\xBF";
    const script_bom = try std.fmt.allocPrint(alloc, "{s}{s}", .{ bom, script });
    defer alloc.free(script_bom);
    try writeFileW(alloc, nsi_path, script_bom);
    log.print("[bundle] nsis script: {s}", .{nsi_path});

    // makensis（有则产出 setup.exe，无则提示）
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const run = std.process.run(alloc, io, .{
        .argv = &.{ "makensis", "-NOCD", "-V2", nsi_path },
    }) catch |err| {
        log.print("[bundle] makensis 不可用（{s}）——已生成 .nsi，安装 NSIS 后重跑 `zig build bundle` 可得安装器", .{@errorName(err)});
        return;
    };
    defer alloc.free(run.stdout);
    defer alloc.free(run.stderr);
    if (run.stderr.len > 0) log.print("[bundle] makensis: {s}", .{run.stderr});

    switch (run.term) {
        .exited => |code| if (code == 0) {
            const setup_size = fileSizeW(alloc, setup_path);
            log.print("[bundle] installer ready: {s} ({d} bytes) — 含 WebView2 运行时检测与静默引导", .{ setup_path, setup_size });
        } else {
            log.print("[bundle] makensis exited with code {d}", .{code});
            return error.MakensisFailed;
        },
        else => {
            log.print("[bundle] makensis terminated abnormally", .{});
            return error.MakensisFailed;
        },
    }
}

// ---- 小工具 ----

fn mkdirW(alloc: std.mem.Allocator, path_u8: []const u8) void {
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path_u8) catch return;
    defer alloc.free(w);
    _ = zilt.platform_windows.win32.CreateDirectoryW(w.ptr, null);
}

fn writeFileW(alloc: std.mem.Allocator, path_u8: []const u8, data: []const u8) !void {
    const win32 = zilt.platform_windows.win32;
    const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path_u8);
    defer alloc.free(w);
    const f = win32.CreateFileW(w.ptr, win32.GENERIC_WRITE, 0, null, win32.CREATE_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (f == win32.INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer _ = win32.CloseHandle(f);
    var written: win32.DWORD = 0;
    if (win32.WriteFile(f, data.ptr, @intCast(data.len), &written, null) == 0) return error.WriteFailed;
}

fn getFullPathW(alloc: std.mem.Allocator, path_u8: []const u8) ![]u8 {
    const win32 = zilt.platform_windows.win32;
    const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path_u8);
    defer alloc.free(w);
    var len = win32.GetFullPathNameW(w.ptr, 0, null, null); // 0 返回所需字符数（含 NUL）
    if (len == 0) return error.FullPathFailed;
    var buf = try alloc.alloc(u16, len);
    errdefer alloc.free(buf);
    len = win32.GetFullPathNameW(w.ptr, len, buf.ptr, null);
    if (len == 0 or len >= buf.len) return error.FullPathFailed;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..len]);
}

fn fileSizeW(alloc: std.mem.Allocator, path_u8: []const u8) u64 {
    const win32 = zilt.platform_windows.win32;
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path_u8) catch return 0;
    defer alloc.free(w);
    var data: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win32.GetFileAttributesExW(w.ptr, 0, &data) == 0) return 0;
    return (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow;
}
