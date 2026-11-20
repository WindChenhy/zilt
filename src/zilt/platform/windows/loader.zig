//! WebView2 运行时发现与加载（纯 Zig，替代官方 WebView2Loader.dll，0 胶水）。
//!
//! 协议依据（已本机实证）：
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
const environment = @import("../../environment.zig");

pub const RuntimeType = enum(u32) { installed = 0, embedded = 1 };

pub const ChannelInfo = struct {
    update_guid: []const u8,
    application_subdirectory: []const u8,
};

/// Edge Update application IDs (not COM IIDs), verified against Microsoft's
/// https://learn.microsoft.com/en-us/deployedge/microsoft-edge-update-policies
pub fn channelInfo(channel: environment.Channel) ChannelInfo {
    return switch (channel) {
        .evergreen => .{ .update_guid = UPDATE_GUID, .application_subdirectory = "Microsoft\\EdgeWebView\\Application" },
        .beta => .{ .update_guid = "{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}", .application_subdirectory = "Microsoft\\Edge Beta\\Application" },
        .dev => .{ .update_guid = "{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}", .application_subdirectory = "Microsoft\\Edge Dev\\Application" },
        .canary => .{ .update_guid = "{65C35B14-6C1D-4122-AC46-7148CC9D6497}", .application_subdirectory = "Microsoft\\Edge SxS\\Application" },
    };
}

/// 最低 API 版本门槛（版本号第 3 段），与 webview 0.12.0 一致。
const MIN_API_VERSION: u32 = 1150;

const UPDATE_GUID = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";

pub const Runtime = struct {
    /// Owned UTF-8 version (e.g. "156.0.4314.58"), or "fixed" for an
    /// explicitly supplied directory whose version is checked during creation.
    version: []u8,
    /// EmbeddedBrowserWebView.dll 完整路径（UTF-16, NUL 结尾）。
    dll_path: [:0]u16,
    module: win32.HMODULE = null,
    runtime_type: RuntimeType = .installed,

    /// Frees discovery strings with the allocator supplied to findRuntime.
    /// A successfully loaded module stays pinned for process lifetime: releasing
    /// it here could invalidate asynchronous callbacks or live WebView COM objects.
    pub fn deinit(self: *Runtime, alloc: std.mem.Allocator) void {
        alloc.free(self.version);
        alloc.free(self.dll_path);
        self.* = undefined;
    }
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
    // RegGetValueW returns LSTATUS, not HRESULT: positive errors also fail.
    if (hr != 0 or size < 2 or size % 2 != 0) return null;

    const buf = alloc.alloc(u16, size / 2) catch return null;
    defer alloc.free(buf);
    hr = win32.RegGetValueW(root, subkey_w.ptr, value_w.ptr, win32.RRF_RT_REG_SZ, null, @ptrCast(buf.ptr), &size);
    if (hr != 0 or size % 2 != 0) return null;
    const n = size / 2;
    if (n == 0 or n > buf.len or buf[n - 1] != 0) return null;
    // The registry value may shrink between reads. Return a precisely sized
    // allocation so the caller can free it using the returned sentinel slice.
    return alloc.dupeSentinel(u16, buf[0 .. n - 1], 0) catch null;
}

fn parseVersion(s: []const u8) [4]u32 {
    var out = [4]u32{ 0, 0, 0, 0 };
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4 or part.len == 0) return .{ 0, 0, 0, 0 };
        for (part) |c| {
            if (!std.ascii.isDigit(c)) return .{ 0, 0, 0, 0 };
        }
        out[i] = std.fmt.parseInt(u32, part, 10) catch return .{ 0, 0, 0, 0 };
        i += 1;
    }
    return if (i == 4) out else .{ 0, 0, 0, 0 };
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
    const attributes = win32.GetFileAttributesW(path_w.ptr);
    return attributes != win32.INVALID_FILE_ATTRIBUTES and (attributes & win32.FILE_ATTRIBUTE_DIRECTORY) == 0;
}

fn makeDllPath(alloc: std.mem.Allocator, directory: []const u8) ![:0]u16 {
    const arch = switch (@import("builtin").cpu.arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        else => return error.UnsupportedArchitecture,
    };
    const dll_u8 = try std.fmt.allocPrint(alloc, "{s}\\EBWebView\\{s}\\EmbeddedBrowserWebView.dll", .{ std.mem.trimEnd(u8, directory, "\\/"), arch });
    defer alloc.free(dll_u8);
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, dll_u8);
}

/// 从 UTF-8 版本目录构造 Runtime（校验 DLL 存在）。
fn makeRuntime(alloc: std.mem.Allocator, dir_u8: []const u8) ?Runtime {
    const trimmed = std.mem.trim(u8, dir_u8, " \t\r\n");
    if (trimmed.len == 0) return null;
    const name = std.fs.path.basenameWindows(trimmed);
    if (!versionOk(parseVersion(name))) return null;

    const dll_w = makeDllPath(alloc, trimmed) catch return null;
    if (!fileExistsWide(dll_w)) {
        alloc.free(dll_w);
        return null;
    }
    const version = alloc.dupe(u8, name) catch {
        alloc.free(dll_w);
        return null;
    };
    return .{ .version = version, .dll_path = dll_w };
}

/// A fixed distribution may be renamed, so do not treat its directory name as
/// a version number. The actual version/compatibility is supplied by WebView2
/// during creation; "fixed" is only the discovery log label.
fn findFixedRuntime(alloc: std.mem.Allocator, directory: []const u8) !Runtime {
    if (directory.len == 0) return error.InvalidBrowserDirectory;
    for (directory) |c| {
        if (c < 0x20 or c == 0x7f) return error.InvalidBrowserDirectory;
    }
    const dll_w = try makeDllPath(alloc, directory);
    errdefer alloc.free(dll_w);
    if (!fileExistsWide(dll_w)) return error.WebView2RuntimeNotFound;
    const version = try alloc.dupe(u8, "fixed");
    return .{ .version = version, .dll_path = dll_w, .runtime_type = .embedded };
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

/// Existing API: discover Evergreen only, retaining the original search order.
pub fn findRuntime(alloc: std.mem.Allocator) !Runtime {
    return findInstalledRuntime(alloc, .evergreen);
}

/// Fixed directory takes precedence. Otherwise search only the requested channel.
/// Neither an unavailable channel nor a missing fixed runtime falls back to
/// Evergreen or any other channel. The caller owns both returned strings.
pub fn findRuntimeWithOptions(alloc: std.mem.Allocator, options: environment.Options) !Runtime {
    if (options.browser_directory) |directory| return findFixedRuntime(alloc, directory);
    return switch (options.channel) {
        inline else => |channel| findInstalledRuntime(alloc, channel),
    };
}

fn findInstalledRuntime(alloc: std.mem.Allocator, comptime channel: environment.Channel) !Runtime {
    const info = comptime channelInfo(channel);
    const client_state = "SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\" ++ info.update_guid;
    const client_state_wow = "SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\ClientState\\" ++ info.update_guid;
    const clients = "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\" ++ info.update_guid;
    const clients_wow = "SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\" ++ info.update_guid;
    const default_location = "C:\\Program Files (x86)\\" ++ info.application_subdirectory;

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
    if (tryScanDir(alloc, "C:\\Program Files\\" ++ info.application_subdirectory)) |rt| return rt;
    if (win32.getEnvUtf8(alloc, "LOCALAPPDATA")) |lad| {
        defer alloc.free(lad);
        // Per-user Clients.location can differ from the default install path.
        const path = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ lad, info.application_subdirectory }) catch return error.WebView2RuntimeNotFound;
        defer alloc.free(path);
        if (tryClients(alloc, win32.HKEY_CURRENT_USER, clients_wow, path)) |rt| return rt;
        if (tryClients(alloc, win32.HKEY_CURRENT_USER, clients, path)) |rt| return rt;
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
    if (runtime.module == null) {
        runtime.module = win32.LoadLibraryExW(runtime.dll_path.ptr, null, win32.LOAD_WITH_ALTERED_SEARCH_PATH) orelse {
            log.print("[loader] LoadLibraryExW failed", .{});
            return com.E_FAIL;
        };
    }

    const sym = win32.GetProcAddress(runtime.module, "CreateWebViewEnvironmentWithOptionsInternal") orelse {
        log.print("[loader] export CreateWebViewEnvironmentWithOptionsInternal missing", .{});
        _ = win32.FreeLibrary(runtime.module);
        runtime.module = null;
        return com.E_FAIL;
    };

    const f: CreateWebViewEnvironmentWithOptionsInternalFn = @ptrCast(@alignCast(sym));
    // arg0 stays true; arg1: 0 = installed channel, 1 = fixed/embedded.
    return f(true, @backingInt(runtime.runtime_type), user_data_folder, environment_options, handler);
}

test "channel mappings and internal runtime types" {
    const channels = [_]environment.Channel{ .evergreen, .beta, .dev, .canary };
    const guids = [_][]const u8{
        "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        "{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}",
        "{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}",
        "{65C35B14-6C1D-4122-AC46-7148CC9D6497}",
    };
    const paths = [_][]const u8{
        "Microsoft\\EdgeWebView\\Application",
        "Microsoft\\Edge Beta\\Application",
        "Microsoft\\Edge Dev\\Application",
        "Microsoft\\Edge SxS\\Application",
    };
    for (channels, guids, paths) |channel, guid, path| {
        const info = channelInfo(channel);
        try std.testing.expectEqualStrings(guid, info.update_guid);
        try std.testing.expectEqualStrings(path, info.application_subdirectory);
    }
    try std.testing.expectEqual(@as(u32, 0), @backingInt(RuntimeType.installed));
    try std.testing.expectEqual(@as(u32, 1), @backingInt(RuntimeType.embedded));
    // Force compilation of the loader entry point without launching a browser.
    _ = &createEnvironment;
}

test "version parsing and version-directory extraction" {
    try std.testing.expectEqual([4]u32{ 156, 0, 4314, 58 }, parseVersion("156.0.4314.58"));
    try std.testing.expect(versionOk(parseVersion(std.fs.path.basenameWindows("C:\\Edge\\156.0.4314.58\\"))));
    try std.testing.expect(versionOk(parseVersion(std.fs.path.basenameWindows("C:/Edge/156.0.4314.58"))));
    try std.testing.expect(!versionOk(parseVersion("100.0.1149.0")));
    for ([_][]const u8{ "\\156.0.4314.58", "invalid.0.4314.58", "156.0.4314", "156.0.4314.58.1" }) |bad| {
        try std.testing.expect(!versionOk(parseVersion(bad)));
    }
}

fn fixedWithAllocationFailures(alloc: std.mem.Allocator, path: []const u8) !void {
    var runtime = try findFixedRuntime(alloc, path);
    defer runtime.deinit(alloc);
}

test "fixed runtime uses embedded mode, owns strings, and never falls back" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A discovery-only fixture, never loaded or executed as a DLL.
    const arch = switch (@import("builtin").cpu.arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        else => return error.SkipZigTest,
    };
    try tmp.dir.createDirPath(io, "renamed-runtime/EBWebView/" ++ arch);
    try tmp.dir.writeFile(io, .{ .sub_path = "renamed-runtime/EBWebView/" ++ arch ++ "/EmbeddedBrowserWebView.dll", .data = "discovery fixture" });
    const path = try tmp.dir.realPathFileAlloc(io, "renamed-runtime", alloc);
    defer alloc.free(path);
    var runtime = try findRuntimeWithOptions(alloc, .{ .channel = .canary, .browser_directory = path });
    defer runtime.deinit(alloc);
    try std.testing.expectEqual(RuntimeType.embedded, runtime.runtime_type);
    try std.testing.expectEqualStrings("fixed", runtime.version);
    try std.testing.expect(runtime.module == null);
    const expected = try makeDllPath(alloc, path);
    defer alloc.free(expected);
    try std.testing.expectEqualSlices(u16, expected, runtime.dll_path);
    try std.testing.checkAllAllocationFailures(alloc, fixedWithAllocationFailures, .{path});

    const missing = try std.fmt.allocPrint(alloc, "{s}\\missing", .{path});
    defer alloc.free(missing);
    for ([_]environment.Channel{ .evergreen, .beta, .dev, .canary }) |channel| {
        try std.testing.expectError(error.WebView2RuntimeNotFound, findRuntimeWithOptions(alloc, .{ .channel = channel, .browser_directory = missing }));
    }
    for ([_][]const u8{ "", "C:\\runtime\x00suffix", "C:\\runtime\r", "C:\\runtime\t" }) |bad| {
        try std.testing.expectError(error.InvalidBrowserDirectory, findRuntimeWithOptions(alloc, .{ .browser_directory = bad }));
    }
}

test "installed runtime discovery owns version and DLL path" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const arch = switch (@import("builtin").cpu.arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        else => return error.SkipZigTest,
    };
    try tmp.dir.createDirPath(io, "156.0.4314.58/EBWebView/" ++ arch);
    try tmp.dir.writeFile(io, .{ .sub_path = "156.0.4314.58/EBWebView/" ++ arch ++ "/EmbeddedBrowserWebView.dll", .data = "discovery fixture" });
    const path = try tmp.dir.realPathFileAlloc(io, "156.0.4314.58", alloc);
    defer alloc.free(path);
    var runtime = makeRuntime(alloc, path) orelse return error.TestUnexpectedResult;
    defer runtime.deinit(alloc);
    try std.testing.expectEqualStrings("156.0.4314.58", runtime.version);
    try std.testing.expectEqual(RuntimeType.installed, runtime.runtime_type);
    var scanned = tryScanDir(alloc, std.fs.path.dirnameWindows(path).?) orelse return error.TestUnexpectedResult;
    defer scanned.deinit(alloc);
    try std.testing.expectEqualStrings(runtime.version, scanned.version);
}
