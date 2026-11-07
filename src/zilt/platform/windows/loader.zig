//! WebView2 运行时发现与加载（纯 Zig，替代官方 WebView2Loader.dll，0 胶水）。
//!
//! 协议依据（docs/reference/webview2-binding-notes.md §D，已本机实证）：
//!  1. 注册表 `HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\{F3017226-…}` 的
//!     `EBWebView` 值（REG_SZ）指向当前版本目录；备选 `Clients\{…}` 的 `pv`+`location`；
//!     再备选默认安装目录扫描。版本第 3 段须 ≥ 1150（API 版本门槛，同 webview 0.12.0）。
//!  2. 加载 `<目录>\EBWebView\x64\EmbeddedBrowserWebView.dll`。
//!  3. GetProcAddress("CreateWebViewEnvironmentWithOptionsInternal")：
//!     `HRESULT fn(bool, u32 runtime_type, PCWSTR userDataFolder, IUnknown* options, Handler*)`
//!     —— 调用 `fn(true, 0 /*installed*/, …)` 即得标准 ICoreWebView2Environment（经回调交付）。

const std = @import("std");
const log = @import("../../log.zig");
const com = @import("com.zig");
const win32 = @import("win32.zig");

/// 最低 API 版本门槛（版本号第 3 段），与 webview 0.12.0 一致。
const MIN_API_VERSION: u32 = 1150;

const UPDATE_GUID = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";

pub const Runtime = struct {
    /// 版本串（UTF-8），如 "156.0.4314.58"。
    version: []u8,
    /// EmbeddedBrowserWebView.dll 完整路径（UTF-16, NUL 结尾）。
    dll_path: [:0]u16,
    module: win32.HMODULE = null,
};

// ---------------------------------------------------------------------------
// 注册表 / 文件系统辅助
// ---------------------------------------------------------------------------

fn regGetString(alloc: std.mem.Allocator, root: win32.HKEY, subkey_u8: []const u8, value_u8: []const u8) ?[:0]u16 {
    const subkey_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, subkey_u8) catch return null;
    defer alloc.free(subkey_w);
    const value_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, value_u8) catch return null;
    defer alloc.free(value_w);

    var size: win32.DWORD = 0;
    var hr = win32.RegGetValueW(root, subkey_w.ptr, value_w.ptr, win32.RRF_RT_REG_SZ, null, null, &size);
    if (com.failed(hr) or size < 2) return null;

    const buf = alloc.alloc(u16, size / 2) catch return null;
    hr = win32.RegGetValueW(root, subkey_w.ptr, value_w.ptr, win32.RRF_RT_REG_SZ, null, @ptrCast(buf.ptr), &size);
    if (com.failed(hr)) {
        alloc.free(buf);
        return null;
    }
    // RegGetValueW 保证写入 NUL 结尾（size 含结尾 NUL 字节数）
    const n = size / 2;
    if (n == 0 or buf[n - 1] != 0) {
        alloc.free(buf);
        return null;
    }
    return buf[0 .. n - 1 :0];
}

fn parseVersion(s: []const u8) [4]u32 {
    var out = [4]u32{ 0, 0, 0, 0 };
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) break;
        out[i] = std.fmt.parseInt(u32, part, 10) catch 0;
        i += 1;
    }
    return out;
}

fn versionCmp(a: [4]u32, b: [4]u32) i32 {
    for (0..4) |i| {
        if (a[i] != b[i]) return if (a[i] < b[i]) -1 else 1;
    }
    return 0;
}

fn versionOk(v: [4]u32) bool {
    return v[2] >= MIN_API_VERSION;
}

fn fileExistsWide(path_w: [:0]u16) bool {
    return win32.GetFileAttributesW(path_w.ptr) != win32.INVALID_FILE_ATTRIBUTES;
}

/// 从 UTF-8 版本目录构造 Runtime（校验 DLL 存在）。
fn makeRuntime(alloc: std.mem.Allocator, dir_u8: []const u8) ?Runtime {
    const trimmed = std.mem.trim(u8, dir_u8, " \t\r\n");
    if (trimmed.len == 0) return null;

    const v = parseVersion(trimmed[std.mem.lastIndexOfScalar(u8, trimmed, '\\') orelse 0 ..]);
    if (!versionOk(v)) return null;

    const dll_u8 = std.fmt.allocPrint(alloc, "{s}\\EBWebView\\x64\\EmbeddedBrowserWebView.dll", .{trimmed}) catch return null;
    defer alloc.free(dll_u8);

    const dll_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, dll_u8) catch return null;
    if (!fileExistsWide(dll_w)) {
        alloc.free(dll_w);
        return null;
    }

    // 版本串 = 目录最后一段
    const start = std.mem.lastIndexOfScalar(u8, trimmed, '\\');
    const version = if (start) |s| alloc.dupe(u8, trimmed[s + 1 ..]) catch return null else alloc.dupe(u8, trimmed) catch return null;

    return .{ .version = version, .dll_path = dll_w };
}

/// ClientState 键的 EBWebView 值 → 版本目录。
fn tryClientState(alloc: std.mem.Allocator, root: win32.HKEY, subkey_u8: []const u8) ?Runtime {
    const dir_w = regGetString(alloc, root, subkey_u8, "EBWebView") orelse return null;
    defer alloc.free(dir_w);
    const dir_u8 = std.unicode.utf16LeToUtf8Alloc(alloc, dir_w) catch return null;
    defer alloc.free(dir_u8);
    return makeRuntime(alloc, dir_u8);
}

/// Clients 键的 location + pv → 版本目录。
fn tryClients(alloc: std.mem.Allocator, root: win32.HKEY, subkey_u8: []const u8, default_location: []const u8) ?Runtime {
    const location_w = regGetString(alloc, root, subkey_u8, "location");
    defer if (location_w) |w| alloc.free(w);

    var location_u8: []u8 = undefined;
    var owned: ?[]u8 = null;
    if (location_w) |w| {
        location_u8 = std.unicode.utf16LeToUtf8Alloc(alloc, w) catch return null;
        owned = location_u8;
    } else {
        location_u8 = @constCast(default_location);
    }
    defer if (owned) |o| alloc.free(o);

    const pv_w = regGetString(alloc, root, subkey_u8, "pv") orelse return null;
    defer alloc.free(pv_w);
    const pv_u8 = std.unicode.utf16LeToUtf8Alloc(alloc, pv_w) catch return null;
    defer alloc.free(pv_u8);

    if (std.mem.eql(u8, pv_u8, "0.0.0.0")) return null;

    const dir = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ location_u8, pv_u8 }) catch return null;
    defer alloc.free(dir);
    return makeRuntime(alloc, dir);
}

/// 扫描默认安装目录，取满足版本门槛的最高版本（Win32 FindFirstFile，0.17 无 std.fs）。
fn tryScanDir(alloc: std.mem.Allocator, base_u8: []const u8) ?Runtime {
    const pattern_u8 = std.fmt.allocPrint(alloc, "{s}\\*", .{base_u8}) catch return null;
    defer alloc.free(pattern_u8);
    const pattern_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, pattern_u8) catch return null;
    defer alloc.free(pattern_w);

    var wfd: win32.WIN32_FIND_DATAW = undefined;
    const h = win32.FindFirstFileW(pattern_w.ptr, &wfd);
    if (h == win32.INVALID_HANDLE_VALUE) return null;
    defer _ = win32.FindClose(h);

    var best_name: ?[]u8 = null;
    var best_ver = [4]u32{ 0, 0, 0, 0 };
    while (true) {
        const name_len = std.mem.indexOfScalar(u16, &wfd.cFileName, 0) orelse wfd.cFileName.len;
        if ((wfd.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY) != 0 and name_len > 0 and wfd.cFileName[0] != '.') {
            if (std.unicode.utf16LeToUtf8Alloc(alloc, wfd.cFileName[0..name_len])) |nm| {
                const v = parseVersion(nm);
                if (versionOk(v) and (best_name == null or versionCmp(v, best_ver) > 0)) {
                    if (best_name) |old| alloc.free(old);
                    best_name = nm;
                    best_ver = v;
                } else {
                    alloc.free(nm);
                }
            } else |_| {}
        }
        if (win32.FindNextFileW(h, &wfd) == 0) break;
    }

    const name = best_name orelse return null;
    defer alloc.free(name);

    const dir_path = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ base_u8, name }) catch return null;
    defer alloc.free(dir_path);
    return makeRuntime(alloc, dir_path);
}

// ---------------------------------------------------------------------------
// 公共 API
// ---------------------------------------------------------------------------

/// 定位本机 WebView2 运行时。失败返回 error.WebView2RuntimeNotFound。
pub fn findRuntime(alloc: std.mem.Allocator) !Runtime {
    const client_state = "SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\" ++ UPDATE_GUID;
    const client_state_wow = "SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\ClientState\\" ++ UPDATE_GUID;
    const clients = "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\" ++ UPDATE_GUID;
    const clients_wow = "SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\" ++ UPDATE_GUID;
    const default_location = "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application";

    // 1) ClientState.EBWebView（webview 0.12.0 路线；64 位进程需 WOW6432Node 视图）
    if (tryClientState(alloc, win32.HKEY_LOCAL_MACHINE, client_state_wow)) |rt| return rt;
    if (tryClientState(alloc, win32.HKEY_LOCAL_MACHINE, client_state)) |rt| return rt;
    if (tryClientState(alloc, win32.HKEY_CURRENT_USER, client_state_wow)) |rt| return rt;
    if (tryClientState(alloc, win32.HKEY_CURRENT_USER, client_state)) |rt| return rt;

    // 2) Clients.location + pv（官方 loader 文档路线）
    if (tryClients(alloc, win32.HKEY_LOCAL_MACHINE, clients_wow, default_location)) |rt| return rt;
    if (tryClients(alloc, win32.HKEY_LOCAL_MACHINE, clients, default_location)) |rt| return rt;

    // 3) 默认安装目录扫描
    if (tryScanDir(alloc, default_location)) |rt| return rt;
    if (tryScanDir(alloc, "C:\\Program Files\\Microsoft\\EdgeWebView\\Application")) |rt| return rt;
    if (win32.getEnvUtf8(alloc, "LOCALAPPDATA")) |lad| {
        defer alloc.free(lad);
        const path = std.fmt.allocPrint(alloc, "{s}\\Microsoft\\EdgeWebView\\Application", .{lad}) catch return error.WebView2RuntimeNotFound;
        defer alloc.free(path);
        if (tryScanDir(alloc, path)) |rt| return rt;
    }

    return error.WebView2RuntimeNotFound;
}

const CreateWebViewEnvironmentWithOptionsInternalFn =
    *const fn (bool, u32, ?[*:0]const u16, ?*anyopaque, ?*anyopaque) callconv(.c) com.HRESULT;

/// 加载运行时 DLL 并异步创建 ICoreWebView2Environment。
/// 完成时通过 handler（ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler）交付。
pub fn createEnvironment(
    runtime: *Runtime,
    user_data_folder: ?[*:0]const u16,
    environment_options: ?*anyopaque,
    handler: *anyopaque,
) com.HRESULT {
    runtime.module = win32.LoadLibraryExW(runtime.dll_path.ptr, null, win32.LOAD_WITH_ALTERED_SEARCH_PATH) orelse {
        log.print("[loader] LoadLibraryExW failed", .{});
        return com.E_FAIL;
    };

    const sym = win32.GetProcAddress(runtime.module, "CreateWebViewEnvironmentWithOptionsInternal") orelse {
        log.print("[loader] export CreateWebViewEnvironmentWithOptionsInternal missing", .{});
        return com.E_FAIL;
    };

    const f: CreateWebViewEnvironmentWithOptionsInternalFn = @ptrCast(@alignCast(sym));
    // arg0 恒 true（webview 0.12.0 同款调用）；arg1: 0 = installed（Evergreen）
    return f(true, 0, user_data_folder, environment_options, handler);
}
