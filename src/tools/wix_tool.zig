//! WiX Toolset 自动供应（Tauri 式 vendor）：首次构建 MSI 时下载并缓存，
//! 不让用户手动装 WiX。
//!
//! 目录解析优先级（见 `wix_vendor.candidates`）：
//!   1. `ZILT_WIX_TOOLPATH`（显式；无效即报错，不静默回退）
//!   2. `WixToolPath` 环境变量（Scoop 安装 wixtoolset3 会写）
//!   3. `%LOCALAPPDATA%\zilt\WixTools`（本模块管理的缓存）
//!
//! 缓存命中判定只看 `candle.exe` + `light.exe` 是否存在 —— 不做 40 MB 的
//! 重复校验；校验发生在下载后一次。
//!
//! 离线/受控环境可设 `ZILT_WIX_NO_DOWNLOAD=1` 禁止自动下载，此时只报告
//! 缺失并提示手工放置路径。

const std = @import("std");
const zilt = @import("zilt");
const vendor = zilt.wix_vendor;
const log = zilt.log;

const win32 = zilt.platform_windows.win32;

pub const Prepared = struct {
    /// WiX 可执行文件所在目录（调用方负责 free）
    dir: []u8,
    source: vendor.Source,
    /// 本次是否触发了下载
    downloaded: bool,
};

pub const ProvisionError = error{
    OutOfMemory,
    ExplicitWixInvalid,
    NoLocalAppData,
    DownloadDisabled,
    HttpStatus,
    SizeUnexpected,
    ChecksumMismatch,
    WriteFailed,
    ExtractFailed,
    SpawnFailed,
    MissingBins,
};

/// 确保 WiX 可用。返回 null 表示"本机没有且不允许下载"，调用方应给出指引。
pub fn ensure(alloc: std.mem.Allocator) ProvisionError!?Prepared {
    const local_app_data = win32.getEnvUtf8(alloc, "LOCALAPPDATA");
    defer if (local_app_data) |v| alloc.free(v);

    const explicit = win32.getEnvUtf8(alloc, "ZILT_WIX_TOOLPATH");
    defer if (explicit) |v| alloc.free(v);
    const env_wix = win32.getEnvUtf8(alloc, "WixToolPath");
    defer if (env_wix) |v| alloc.free(v);

    const lad = local_app_data orelse return ProvisionError.NoLocalAppData;

    const list = try vendor.candidates(alloc, explicit, env_wix, lad);
    defer vendor.freeCandidates(alloc, list);

    // 显式指定时严格：无效即失败，避免构建结果随机器环境漂移
    if (list.len > 0 and list[0].source == .explicit) {
        if (isUsable(alloc, list[0].dir)) {
            return Prepared{ .dir = try alloc.dupe(u8, list[0].dir), .source = .explicit, .downloaded = false };
        }
        log.print("[wix] ZILT_WIX_TOOLPATH={s} 缺少 candle.exe/light.exe，拒绝回退到其他 WiX", .{list[0].dir});
        return ProvisionError.ExplicitWixInvalid;
    }

    // 环境变量 / 缓存逐级尝试
    for (list) |c| {
        if (isUsable(alloc, c.dir)) {
            log.print("[wix] found usable toolset ({s}) at {s}", .{ @tagName(c.source), c.dir });
            return Prepared{ .dir = try alloc.dupe(u8, c.dir), .source = c.source, .downloaded = false };
        }
    }

    // 缓存缺失 → 下载到缓存
    const cache = try vendor.cacheDir(alloc, lad);
    errdefer alloc.free(cache);

    const no_dl = win32.getEnvUtf8(alloc, "ZILT_WIX_NO_DOWNLOAD");
    defer if (no_dl) |v| alloc.free(v);
    if (no_dl) |v| {
        if (v.len > 0 and v[0] == '1') {
            log.print("[wix] 未找到 WiX 且已禁用自动下载（ZILT_WIX_NO_DOWNLOAD=1）", .{});
            alloc.free(cache);
            return ProvisionError.DownloadDisabled;
        }
    }

    try provision(alloc, lad, cache);
    if (!isUsable(alloc, cache)) {
        alloc.free(cache);
        return ProvisionError.MissingBins;
    }
    return Prepared{ .dir = cache, .source = .cache, .downloaded = true };
}

pub fn freePrepared(alloc: std.mem.Allocator, p: ?Prepared) void {
    if (p) |v| alloc.free(v.dir);
}

/// 只检测不下载（doctor / 状态报告用）：返回已就绪的 WiX 目录，否则 null。
/// 绝不能在这里触发 40 MB 下载 —— 那属于构建时的 `ensure`。
pub fn detect(alloc: std.mem.Allocator) ?[]u8 {
    const lad = win32.getEnvUtf8(alloc, "LOCALAPPDATA") orelse return null;
    defer alloc.free(lad);
    const explicit = win32.getEnvUtf8(alloc, "ZILT_WIX_TOOLPATH");
    defer if (explicit) |v| alloc.free(v);
    const env_wix = win32.getEnvUtf8(alloc, "WixToolPath");
    defer if (env_wix) |v| alloc.free(v);

    const list = vendor.candidates(alloc, explicit, env_wix, lad) catch return null;
    defer vendor.freeCandidates(alloc, list);
    for (list) |c| {
        if (isUsable(alloc, c.dir)) return alloc.dupe(u8, c.dir) catch null;
    }
    return null;
}

/// 目录是否含 candle.exe 与 light.exe。
pub fn isUsable(alloc: std.mem.Allocator, dir: []const u8) bool {
    for (vendor.required_bins) |bin| {
        const p = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ std.mem.trimEnd(u8, dir, "\\/"), bin }) catch return false;
        defer alloc.free(p);
        if (!fileExists(alloc, p)) return false;
    }
    return true;
}

/// 下载 + 校验 + 解压 + 打标记。失败时抛出具体错误，不静默。
fn provision(alloc: std.mem.Allocator, local_app_data: []const u8, cache: []const u8) ProvisionError!void {
    _ = local_app_data;
    log.print("[wix] cache empty, fetching WiX {s} (~{d} MB) …", .{ vendor.version, vendor.download_size / (1024 * 1024) });

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = alloc, .io = threaded.io() };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = vendor.download_url },
        .response_writer = &aw.writer,
    }) catch |err| {
        log.print("[wix] download failed: {s}", .{@errorName(err)});
        return ProvisionError.HttpStatus;
    };
    if (result.status != .ok) {
        log.print("[wix] download HTTP status {d}", .{@intFromEnum(result.status)});
        return ProvisionError.HttpStatus;
    }

    const bytes = aw.toOwnedSlice() catch return ProvisionError.WriteFailed;
    defer alloc.free(bytes);

    if (!vendor.sizeSane(bytes.len)) {
        log.print("[wix] unexpected size {d} (want ~{d})", .{ bytes.len, vendor.download_size });
        return ProvisionError.SizeUnexpected;
    }

    const hex = vendor.sha256Hex(bytes);
    if (!vendor.sha256Matches(&hex, vendor.download_sha256)) {
        log.print("[wix] sha256 mismatch: got {s} want {s}", .{ hex, vendor.download_sha256 });
        return ProvisionError.ChecksumMismatch;
    }
    log.print("[wix] sha256 ok ({s})", .{vendor.download_sha256[0..16]});

    const tmp_zip = std.fmt.allocPrint(alloc, "{s}\\zilt-wix314.zip", .{trimEnd(win32.getEnvUtf8(alloc, "TEMP") orelse ".", "\\/")}) catch return ProvisionError.WriteFailed;
    defer alloc.free(tmp_zip);
    if (!win32.writeFileAlloc(alloc, tmp_zip, bytes)) return ProvisionError.WriteFailed;
    defer _ = deleteFile(alloc, tmp_zip);

    mkdirAll(alloc, cache);
    try extractZip(alloc, tmp_zip, cache);

    const stamp = vendor.stampContent(alloc) catch return ProvisionError.WriteFailed;
    defer alloc.free(stamp);
    const stamp_path = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ cache, vendor.stamp_file }) catch return ProvisionError.WriteFailed;
    defer alloc.free(stamp_path);
    _ = win32.writeFileAlloc(alloc, stamp_path, stamp);

    log.print("[wix] provisioned to {s}", .{cache});
}

/// 解压 zip：交给系统 `tar.exe`（Windows 10 1803+ 自带 libarchive，支持 zip）。
/// 不在 Zig 里自研 unzip 是为了少一处易错的二进制解析；解压失败时错误信息
/// 会带上 tar 的退出码，便于定位。
fn extractZip(alloc: std.mem.Allocator, zip_path: []const u8, dest: []const u8) ProvisionError!void {
    const tar = tarPath(alloc) orelse {
        log.print("[wix] 找不到 tar.exe（需要 Windows 10 1803+）；可手动解压 {s} 到 {s}", .{ zip_path, dest });
        return ProvisionError.ExtractFailed;
    };
    defer alloc.free(tar);

    const args = std.fmt.allocPrint(alloc, "-xf \"{s}\" -C \"{s}\"", .{ zip_path, dest }) catch return ProvisionError.ExtractFailed;
    defer alloc.free(args);

    const code = runAndWait(alloc, tar, args, 180_000) catch return ProvisionError.SpawnFailed;
    if (code != 0) {
        log.print("[wix] tar.exe exit {d}", .{code});
        return ProvisionError.ExtractFailed;
    }
}

fn tarPath(alloc: std.mem.Allocator) ?[]u8 {
    const root = win32.getEnvUtf8(alloc, "SystemRoot") orelse "C:\\Windows";
    defer alloc.free(root);
    const p = std.fmt.allocPrint(alloc, "{s}\\System32\\tar.exe", .{root}) catch return null;
    if (fileExists(alloc, p)) return p;
    alloc.free(p);
    return null;
}

/// 运行外部程序并等退出码。bInheritHandles=1、flags=0 → 子进程继承父控制台，
/// 构建日志能直接被用户看到（不吞输出）。
pub fn runAndWait(alloc: std.mem.Allocator, exe: []const u8, args: []const u8, timeout_ms: u32) !u32 {
    const cl = try std.fmt.allocPrintSentinel(alloc, "\"{s}\" {s}", .{ exe, args }, 0);
    defer alloc.free(cl);
    const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, exe);
    defer alloc.free(exe_w);
    const cl_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, cl);
    defer alloc.free(cl_w);

    var si = std.mem.zeroes(win32.STARTUPINFOW);
    si.cb = @sizeOf(win32.STARTUPINFOW);
    var pi = std.mem.zeroes(win32.PROCESS_INFORMATION);
    if (win32.CreateProcessW(exe_w.ptr, cl_w.ptr, null, null, 1, 0, null, null, &si, &pi) == 0) {
        return error.SpawnFailed;
    }
    defer {
        _ = win32.CloseHandle(pi.hProcess);
        _ = win32.CloseHandle(pi.hThread);
    }

    _ = win32.WaitForSingleObject(pi.hProcess, timeout_ms);
    var code: u32 = 0;
    _ = win32.GetExitCodeProcess(pi.hProcess, &code);
    return code;
}

pub fn fileExists(alloc: std.mem.Allocator, path: []const u8) bool {
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(w);
    return win32.GetFileAttributesW(w.ptr) != 0xFFFFFFFF;
}

pub fn deleteFile(alloc: std.mem.Allocator, path: []const u8) bool {
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(w);
    return win32.DeleteFileW(w.ptr) != 0;
}

/// 逐段创建目录（CreateDirectoryW 不建中间层）。
pub fn mkdirAll(alloc: std.mem.Allocator, path: []const u8) void {
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '\\' or path[i] == '/') {
            if (i == 0) continue;
            const part = path[0..i];
            const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, part) catch continue;
            defer alloc.free(w);
            _ = win32.CreateDirectoryW(w.ptr, null);
        }
    }
}

fn trimEnd(s: []const u8, set: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, set);
}

/// 用 candle + light 把 .wxs 编成 .msi。返回产物路径，失败返回具体阶段。
pub const BuildError = error{
    CandleFailed,
    LightFailed,
    WixMissing,
};

pub fn buildMsi(
    alloc: std.mem.Allocator,
    wix_dir: []const u8,
    wxs_path: []const u8,
    out_msi: []const u8,
    arch: []const u8,
) BuildError!void {
    const candle = std.fmt.allocPrint(alloc, "{s}\\candle.exe", .{trimEnd(wix_dir, "\\/")}) catch return BuildError.WixMissing;
    defer alloc.free(candle);
    const light = std.fmt.allocPrint(alloc, "{s}\\light.exe", .{trimEnd(wix_dir, "\\/")}) catch return BuildError.WixMissing;
    defer alloc.free(light);
    if (!fileExists(alloc, candle) or !fileExists(alloc, light)) return BuildError.WixMissing;

    // .wixobj 放在 msi 同目录，避免污染 dist/ 之外
    const wixobj = std.fmt.allocPrint(alloc, "{s}.wixobj", .{wxs_path}) catch return BuildError.CandleFailed;
    defer alloc.free(wixobj);

    const candle_args = std.fmt.allocPrint(alloc, "-nologo -arch {s} -out \"{s}\" \"{s}\"", .{ arch, wixobj, wxs_path }) catch return BuildError.CandleFailed;
    defer alloc.free(candle_args);

    log.print("[wix] candle {s}", .{wxs_path});
    const c1 = runAndWait(alloc, candle, candle_args, 120_000) catch return BuildError.CandleFailed;
    if (c1 != 0) {
        log.print("[wix] candle failed (exit {d})", .{c1});
        return BuildError.CandleFailed;
    }

    const light_args = std.fmt.allocPrint(alloc, "-nologo -out \"{s}\" \"{s}\"", .{ out_msi, wixobj }) catch return BuildError.LightFailed;
    defer alloc.free(light_args);

    log.print("[wix] light -> {s}", .{out_msi});
    const c2 = runAndWait(alloc, light, light_args, 120_000) catch return BuildError.LightFailed;
    if (c2 != 0) {
        log.print("[wix] light failed (exit {d})", .{c2});
        return BuildError.LightFailed;
    }
}
