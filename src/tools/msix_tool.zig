//! MSIX 打包（IO 层）：组织 staging 目录 → 调 makeappx pack → 可选签名。
//!
//! makeappx 随 Windows SDK 的「App Certification Kit」提供（本机在
//! `E:\Windows Kits\10\App Certification Kit\`），不需要额外安装。
//!
//! 关于签名：MSIX 未签名无法安装，且签名证书的 Subject 必须与 manifest 的
//! `Publisher` 逐字一致。自签名证书做本地 sideload 时，还需要把证书导入
//! `LocalMachine\Root`（AppX 部署服务以 SYSTEM 身份校验，CurrentUser 下的根
//! 证书它看不到），这一步需要管理员权限。

const std = @import("std");
const zilt = @import("zilt");
const msix = zilt.msix;
const win32 = zilt.platform_windows.win32;
const log = zilt.log;
const wix_tool = @import("wix_tool.zig");
const signtool_locate = @import("signtool_locate.zig");

pub const PackError = error{
    MakeappxMissing,
    ManifestWriteFailed,
    ExeCopyFailed,
    AssetWriteFailed,
    PackFailed,
};

/// 在 SDK 里定位 makeappx.exe（App Certification Kit 优先，其次 bin\<ver>\x64）。
pub fn findMakeappx(alloc: std.mem.Allocator) ?[]u8 {
    if (signtool_locate.kitsRoot(alloc)) |root| {
        defer alloc.free(root);
        if (searchUnder(alloc, root)) |p| return p;
    }
    if (win32.getEnvUtf8(alloc, "ProgramFiles(x86)")) |pf86| {
        defer alloc.free(pf86);
        const root = std.fmt.allocPrint(alloc, "{s}\\Windows Kits\\10", .{pf86}) catch return null;
        defer alloc.free(root);
        if (searchUnder(alloc, root)) |p| return p;
    }
    return null;
}

fn searchUnder(alloc: std.mem.Allocator, root: []const u8) ?[]u8 {
    const base = std.mem.trimEnd(u8, root, "\\/");

    const appkit = std.fmt.allocPrint(alloc, "{s}\\App Certification Kit\\makeappx.exe", .{base}) catch return null;
    if (wix_tool.fileExists(alloc, appkit)) return appkit;
    alloc.free(appkit);

    // bin\<highest>\x64\makeappx.exe —— 只认数字开头的版本目录
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
            if (raw.len > 0 and std.ascii.isDigit(@intCast(raw[0]))) {
                if (std.unicode.utf16LeToUtf8Alloc(alloc, raw)) |name| {
                    if (best) |b| {
                        if (std.mem.order(u8, name, b) == .gt) {
                            alloc.free(b);
                            best = name;
                        } else alloc.free(name);
                    } else best = name;
                } else |_| {}
            }
        }
        if (win32.FindNextFileW(h, &fd) == 0) break;
    }

    const ver = best orelse return null;
    defer alloc.free(ver);
    const cand = std.fmt.allocPrint(alloc, "{s}\\bin\\{s}\\x64\\makeappx.exe", .{ base, ver }) catch return null;
    if (wix_tool.fileExists(alloc, cand)) return cand;
    alloc.free(cand);
    return null;
}

pub const StagingOptions = struct {
    /// staging 根目录（会被创建）
    dir: []const u8,
    /// 原始 exe 绝对路径
    exe_path: []const u8,
    /// 包内 exe 文件名（需与 manifest 的 Executable 一致）
    exe_name: []const u8,
    /// 生成好的 AppxManifest.xml 内容
    manifest: []const u8,
    /// 用作所有 Logo 的 PNG（一般取 ico 最大帧）
    logo_png: []const u8,
};

/// 组织 staging 目录：AppxManifest.xml + exe + Assets\*.png
pub fn stage(alloc: std.mem.Allocator, opts: StagingOptions) PackError!void {
    wix_tool.mkdirAll(alloc, opts.dir);

    const manifest_path = std.fmt.allocPrint(alloc, "{s}\\AppxManifest.xml", .{opts.dir}) catch return PackError.ManifestWriteFailed;
    defer alloc.free(manifest_path);
    if (!win32.writeFileAlloc(alloc, manifest_path, opts.manifest)) return PackError.ManifestWriteFailed;

    const exe_dst = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ opts.dir, opts.exe_name }) catch return PackError.ExeCopyFailed;
    defer alloc.free(exe_dst);
    const exe_bytes = win32.readFileAlloc(alloc, opts.exe_path) orelse return PackError.ExeCopyFailed;
    defer alloc.free(exe_bytes);
    if (!win32.writeFileAlloc(alloc, exe_dst, exe_bytes)) return PackError.ExeCopyFailed;

    const assets_dir = std.fmt.allocPrint(alloc, "{s}\\Assets", .{opts.dir}) catch return PackError.AssetWriteFailed;
    defer alloc.free(assets_dir);
    wix_tool.mkdirAll(alloc, assets_dir);

    for (msix.assets) |rel| {
        // rel 形如 "Assets\\StoreLogo.png"，staging 根下直接落盘
        const p = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ opts.dir, rel }) catch return PackError.AssetWriteFailed;
        defer alloc.free(p);
        if (!win32.writeFileAlloc(alloc, p, opts.logo_png)) return PackError.AssetWriteFailed;
    }
}

/// `makeappx pack /d <dir> /p <out> /o`
pub fn pack(alloc: std.mem.Allocator, staging_dir: []const u8, out_msix: []const u8) PackError!void {
    const tool = findMakeappx(alloc) orelse {
        log.print("[msix] makeappx.exe 未找到（需要 Windows SDK 的 App Certification Kit）", .{});
        return PackError.MakeappxMissing;
    };
    defer alloc.free(tool);

    const args = std.fmt.allocPrint(alloc, "pack /d \"{s}\" /p \"{s}\" /o", .{ staging_dir, out_msix }) catch return PackError.PackFailed;
    defer alloc.free(args);

    log.print("[msix] makeappx pack -> {s}", .{out_msix});
    const code = wix_tool.runAndWait(alloc, tool, args, 180_000) catch return PackError.PackFailed;
    if (code != 0) {
        log.print("[msix] makeappx 退出码 {d}", .{code});
        return PackError.PackFailed;
    }
}
