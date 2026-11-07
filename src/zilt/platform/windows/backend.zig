//! Windows 平台后端：配置驱动的应用生命周期。
//!
//! Backend 按 Config 编译期实例化（Config.commands 等为 comptime type 字段）；
//! 运行时可变状态（dev 覆盖、退出码）为普通字段。
//!
//! 职责：多窗口 + 消息循环、WebView2 生命周期、custom scheme 资产服务
//! （embedded 表 / dev 目录 / dev url 三种模式，含 Range/206）、IPC 分发
//! （含 origin 校验）、线程安全的 emit 编排（WM_APP marshal 到 UI 线程）、
//! 运行时 JS 注入、拖放/深链接/剪贴板/托盘右键菜单、dev 目录热重载 watcher。

const std = @import("std");
const log = @import("../../log.zig");
const ipc = @import("../../ipc.zig");
const updater = @import("../../updater.zig");
const Config = @import("../../config.zig").Config;
const com = @import("com.zig");
const win32 = @import("win32.zig");
const wv2 = @import("webview2.zig");
const loader = @import("loader.zig");
const tray_mod = @import("tray.zig");
const toast_mod = @import("toast.zig");
const patch = @import("../../patch.zig");
const single_instance = @import("single_instance.zig");
const menu_mod = @import("menu.zig");
const hotkey_mod = @import("hotkey.zig");
const dialog_mod = @import("dialog.zig");
const dlgx = @import("dialog_ext.zig");
const range_mod = @import("range.zig");
const icon_mod = @import("icon.zig");
const deep_link = @import("deep_link.zig");
const security = @import("../../security.zig");
const asset_routes = @import("../../asset_routes.zig");
const app_data = @import("app_data.zig");
const builtin = @import("../../builtin.zig");
const shared_webview = @import("../../webview.zig");
const shared_clipboard = @import("../../clipboard.zig");
const shared_drag = @import("../../drag_drop.zig");
const shared_notification = @import("../../notification.zig");
const environment = @import("../../environment.zig");
const webview_driver = @import("webview_driver.zig");
const env_options = @import("environment_options.zig");
const win_clipboard = @import("clipboard.zig");
const win_drag = @import("drag_drop.zig");

extern "user32" fn EnableWindow(win32.HWND, win32.BOOL) callconv(.c) win32.BOOL;
extern "user32" fn IsWindowEnabled(win32.HWND) callconv(.c) win32.BOOL;
extern "user32" fn IsZoomed(win32.HWND) callconv(.c) win32.BOOL;

const HRESULT = com.HRESULT;
const WM_ZILT_EMIT: win32.UINT = win32.WM_APP + 1;
const WM_ZILT_NOTIFY: win32.UINT = win32.WM_APP + 2;
const WM_ZILT_TRAY: win32.UINT = win32.WM_APP + 3;
const WM_ZILT_WINCTL: win32.UINT = win32.WM_APP + 4;
const WM_ZILT_NEWWIN: win32.UINT = win32.WM_APP + 5;
const WM_ZILT_CLIP: win32.UINT = win32.WM_APP + 6;
const WM_ZILT_ACTION: win32.UINT = win32.WM_APP + 7; // 统一能力动作 marshal（UI 线程）
const WM_ZILT_WAKE: win32.UINT = win32.WM_APP + 8; // WebView driver 延迟派发
const WM_ZILT_TOAST_EVENT: win32.UINT = win32.WM_APP + 9; // WinRT 线程 → UI 线程
const WM_CLIPBOARDUPDATE: win32.UINT = 0x031D;
const TRAY_MENU_BASE: u16 = 100;

extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    operation: ?[*:0]const u16,
    file: [*:0]const u16,
    parameters: ?[*:0]const u16,
    directory: ?[*:0]const u16,
    show_cmd: i32,
) callconv(.c) usize;
extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.c) com.HRESULT;
extern "ole32" fn OleUninitialize() callconv(.c) void;
const SMOKE_ENV = "ZILT_SMOKE_TEST_MS";
/// 内置默认图标（Zig 官方 logo，多尺寸 ICO）。config.icon 为 null 时使用。
const default_icon_bytes = @embedFile("../../assets/zilt.ico");

pub fn run(comptime config: Config) !void {
    try security.validateHeaders(config.security);
    const B = Backend(config);
    log.initFileLog("zilt.log");
    const alloc = std.heap.page_allocator;

    const argv: []const []const u8 = collectArgs(alloc) catch &.{};
    defer freeArgv(alloc, argv);
    const args = if (argv.len > 1) argv[1..] else &[_][]const u8{};

    // 重启接力拦截（v0.1.5）：`<exe> --zilt-restart <target>` 不进主流程，
    // 等旧实例退出（互斥体释放）后拉起 target 即退出。
    if (updater.isRestartHelperCall(argv)) |target| {
        updater.runRestartHelper(alloc, target);
        return; // helper 不进主流程
    }

    // 单实例保护：第二实例把启动参数转发给首个实例（WM_COPYDATA）后退出码 5。
    const class_u8 = try std.fmt.allocPrint(alloc, "ZiltWindow.{s}", .{config.app_id});
    defer alloc.free(class_u8);
    var guard: ?single_instance.Guard = null;
    if (config.single_instance) {
        guard = single_instance.Guard.acquire(alloc, config.app_id);
        if (guard == null) {
            const payload = deep_link.payloadOfArgs(alloc, args) catch "";
            defer if (payload.len > 0) alloc.free(payload);
            const forwarded = forwardToRunning(alloc, class_u8, payload);
            log.print("[single-instance] another instance is running (args forwarded={}) -> exit({d})", .{ forwarded, single_instance.SECOND_INSTANCE_EXIT_CODE });
            std.process.exit(single_instance.SECOND_INSTANCE_EXIT_CODE);
        }
    }
    defer if (guard) |*g| g.release();

    // 清理上次更新留下的备份
    if (config.update != null) {
        const exe_path = currentExePath(alloc) catch null;
        if (exe_path) |p| {
            defer alloc.free(p);
            updater.cleanupOld(alloc, p);
        }
    }

    _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    const hr_init = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
    if (com.failed(hr_init)) {
        log.print("[fatal] CoInitializeEx failed hr=0x{x}", .{@as(u32, @bitCast(hr_init))});
        return error.CoInitializeFailed;
    }
    defer _ = win32.CoUninitialize();
    // OLE 拖放（v0.1.12）要求 OleInitialize 而不仅是 CoInitializeEx。
    const ole_ok = com.succeeded(OleInitialize(null));
    defer if (ole_ok) OleUninitialize();
    if (!ole_ok) log.print("[ole] OleInitialize failed -> OLE drag/drop disabled", .{});

    var backend = try alloc.create(B);
    backend.* = .{ .allocator = alloc };
    B.setInstance(backend);
    defer {
        alloc.destroy(backend);
        B.setInstance(null);
    }

    try backend.init(class_u8);

    // 更新器环境（公钥解析/URL env 覆盖），命令与自动流共用
    if (config.update) |uc| {
        backend.updater_env = try buildUpdaterEnv(backend, uc);
        log.print("[updater] configured (manifest={s}, current={s})", .{ backend.updater_env.?.manifest_url, uc.current_version });
    }

    // dev 模式环境变量覆盖（无需重新编译）
    if (win32.getEnvUtf8(alloc, "ZILT_DEV_DIR")) |d| {
        backend.dev_dir = d;
        log.print("[dev] ZILT_DEV_DIR={s}", .{d});
    }
    if (win32.getEnvUtf8(alloc, "ZILT_DEV_URL")) |u| {
        backend.dev_url = u;
        log.print("[dev] ZILT_DEV_URL={s}", .{u});
    }
    // WinRT Toast 通知主通道（v0.1.5：气球降级；不要求 tray 启用）
    blk: {
        const exe = currentExePath(alloc) catch break :blk;
        defer alloc.free(exe);
        backend.toast = toast_mod.Toast.init(alloc, config.app_id, config.title, exe) catch |err| {
            log.print("[toast] init failed: {s}（通知降级托盘气球）", .{@errorName(err)});
            break :blk;
        };
        // v0.1.12：Toast 按钮/输入/点击/关闭回调（WinRT 线程 → UI 线程 marshal）。
        backend.toast.?.callback = .{ .context = backend, .function = B.onToastEvent };
        log.print("[toast] winrt ready (aumid={s})", .{config.app_id});
    }

    if (win32.getEnvUtf8(alloc, "ZILT_DEV_PROXY")) |u| {
        backend.dev_proxy = u;
        // 反代模式优先生效（应用保持自身 origin；dev_url 仅作为 origin 白名单兜底无意义，忽略）
        if (backend.dev_url != null) log.print("[dev] ZILT_DEV_PROXY 与 ZILT_DEV_URL 同时设置：反代优先", .{});
        log.print("[dev] ZILT_DEV_PROXY={s}", .{u});
    }

    // 深链接：启动参数分类 + 可选 HKCU 注册
    const scheme = if (config.deep_link) |dl| dl.scheme else "zilt";
    backend.pending_launch = deep_link.parseArgs(alloc, args, scheme) catch null;
    if (config.deep_link) |dl| {
        if (currentExePath(alloc)) |exe| {
            defer alloc.free(exe);
            if (dl.register) {
                const ok = deep_link.registerProtocol(alloc, dl.scheme, config.title, exe);
                log.print("[deep-link] protocol \"{s}\" registered (ok={})", .{ dl.scheme, ok });
            }
            if (dl.file_ext) |ext| {
                const ok = deep_link.registerFileExt(alloc, ext, config.app_id, config.title, exe);
                log.print("[deep-link] file assoc \"{s}\" registered (ok={})", .{ ext, ok });
            }
        } else |_| {}
    }

    const main = try backend.createWindow(.{
        .title = config.title,
        .width = config.width,
        .height = config.height,
        .url = config.url,
        .x = config.x,
        .y = config.y,
        .visible = config.visible,
        .resizable = config.resizable,
        .decorations = config.decorations,
        .transparent = config.transparent,
        .always_on_top = config.always_on_top,
        .skip_taskbar = config.skip_taskbar,
        .min_width = config.min_width,
        .min_height = config.min_height,
        .max_width = config.max_width,
        .max_height = config.max_height,
        .background_color = config.background_color,
        .close_requested_event = config.close_requested_event,
        .icon = config.icon,
        .label = "main",
        .state_key = config.state_key,
    });
    if (config.visible) {
        _ = win32.ShowWindow(main.hwnd, win32.SW_SHOW);
        _ = win32.UpdateWindow(main.hwnd);
    }
    log.print("[win32] window created: \"{s}\" {d}x{d}", .{ config.title, config.width, config.height });

    // 全局快捷键（编译期校验 key 合法性）
    if (B.hotkey_cfg) |hks| {
        if (hotkey_mod.registerAll(main.hwnd, hks)) |failed_id| {
            log.print("[hotkey] register failed: {s}（可能被其他程序占用）", .{failed_id});
        } else {
            log.print("[hotkey] registered {} hotkeys", .{B.hotkey_count});
        }
    }

    // v0.1.10：运行时通道 / 固定版本目录 / UA / 语言 / 代理 / 浏览器参数。
    var runtime = try loader.findRuntimeWithOptions(alloc, config.environment);
    log.print("[loader] runtime version: {s} (channel={s})", .{ runtime.version, @tagName(config.environment.channel) });
    if (std.unicode.utf16LeToUtf8Alloc(alloc, runtime.dll_path)) |dll_u8| {
        defer alloc.free(dll_u8);
        log.print("[loader] dll: {s}", .{dll_u8});
    } else |_| {}

    const udf = try buildUserDataFolder(alloc, config.app_id, config.migrate_legacy_profile);
    log.print("[profile] {s}", .{udf.utf8});
    defer alloc.free(udf.utf8);
    defer alloc.free(udf.utf16);

    var env_opts: ?*env_options.EnvironmentOptions = null;
    const eo = config.environment;
    if (eo.language != null or eo.proxy_server != null or eo.additional_browser_arguments != null or eo.channel != .evergreen or eo.browser_directory != null) {
        env_opts = env_options.EnvironmentOptions.create(alloc, eo) catch |err| blk: {
            log.print("[env] environment options unavailable: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (env_opts != null) log.print("[env] options applied (lang={s}, proxy={s}, args={s})", .{
            if (eo.language) |v| v else "-",
            if (eo.proxy_server) |v| v else "-",
            if (eo.additional_browser_arguments) |v| v else "-",
        });
    }
    defer if (env_opts) |o| o.dropRef();

    const env_handler = try B.EnvCompletedHandler.create(backend, main);
    const env_opt_ptr: ?*anyopaque = if (env_opts) |o| @ptrCast(o) else null;
    const hr_env = loader.createEnvironment(&runtime, udf.utf16.ptr, env_opt_ptr, env_handler);
    env_handler.dropRef();
    if (com.failed(hr_env)) {
        log.print("[fatal] createEnvironment failed hr=0x{x}", .{@as(u32, @bitCast(hr_env))});
        return error.EnvironmentCreateFailed;
    }

    // 冒烟测试安全网（ZILT_SMOKE_TEST_MS 毫秒后强制退出）
    if (win32.getEnvUtf8(alloc, SMOKE_ENV)) |ms_str| {
        defer alloc.free(ms_str);
        const ms = std.fmt.parseInt(u32, ms_str, 10) catch 20000;
        _ = win32.SetTimer(main.hwnd, 1, ms, null);
        log.print("[test] smoke timer set: {d} ms", .{ms});
    }

    // 消息泵
    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
    log.print("[win32] message loop exited (code {d})", .{backend.quit_code.load(.monotonic)});

    if (backend.watcher) |w| w.stopJoin();
    backend.watcher = null;

    backend.saveAllStates();
    backend.cleanup();
    if (backend.quit_code.load(.monotonic) != 0) return error.AppFailed;
}

// ---------------------------------------------------------------------------
// 启动参数 / 第二实例转发
// ---------------------------------------------------------------------------

fn collectArgs(alloc: std.mem.Allocator) ![]const []const u8 {
    var argc: i32 = 0;
    const raw = win32.CommandLineToArgvW(win32.GetCommandLineW(), &argc);
    if (raw == null or argc <= 0) return alloc.alloc([]const u8, 0);
    defer _ = win32.LocalFree(@ptrCast(raw));

    const out = try alloc.alloc([]const u8, @intCast(argc));
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        out[i] = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(raw.?[i])) catch try alloc.dupe(u8, "");
    }
    return out;
}

fn freeArgv(alloc: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| alloc.free(a);
    if (argv.len > 0) alloc.free(argv);
}

/// 第二实例：把启动参数发给首个实例（找主窗口类名，最多等 2s）。
fn forwardToRunning(alloc: std.mem.Allocator, class_name: []const u8, payload: []const u8) bool {
    const class_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, class_name) catch return false;
    defer alloc.free(class_w);

    var hwnd: win32.HWND = null;
    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        hwnd = win32.FindWindowW(class_w.ptr, null);
        if (hwnd != null) break;
        win32.Sleep(50);
    }
    if (hwnd == null) return false;

    var cds = win32.COPYDATASTRUCT{
        .dwData = 0,
        .cbData = @intCast(payload.len),
        .lpData = if (payload.len > 0) @ptrCast(@constCast(payload.ptr)) else null,
    };
    const r = win32.SendMessageW(hwnd, win32.WM_COPYDATA, 0, @bitCast(@intFromPtr(&cds)));
    return r != 0;
}

const UserDataFolder = struct { utf8: []u8, utf16: [:0]u16 };

fn buildUserDataFolder(alloc: std.mem.Allocator, app_id: []const u8, migrate: bool) !UserDataFolder {
    const dir = try app_data.profileDirectory(alloc, app_id, migrate);
    errdefer alloc.free(dir);
    return .{ .utf8 = dir, .utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, dir) };
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

pub fn originOf(uri: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, uri, "://") orelse return uri;
    const rest = uri[sep + 3 ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return uri[0 .. sep + 3 + end];
}

pub fn contentTypeOf(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const ext = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[i + 1 ..] else "";
    const map = [_]struct { ext: []const u8, ct: []const u8 }{
        .{ .ext = "html", .ct = "text/html; charset=utf-8" },
        .{ .ext = "js", .ct = "text/javascript; charset=utf-8" },
        .{ .ext = "mjs", .ct = "text/javascript; charset=utf-8" },
        .{ .ext = "css", .ct = "text/css; charset=utf-8" },
        .{ .ext = "json", .ct = "application/json" },
        .{ .ext = "svg", .ct = "image/svg+xml" },
        .{ .ext = "png", .ct = "image/png" },
        .{ .ext = "jpg", .ct = "image/jpeg" },
        .{ .ext = "ico", .ct = "image/x-icon" },
        .{ .ext = "woff2", .ct = "font/woff2" },
        .{ .ext = "ts", .ct = "text/plain; charset=utf-8" },
    };
    for (map) |m| {
        if (std.ascii.eqlIgnoreCase(ext, m.ext)) return m.ct;
    }
    return "application/octet-stream";
}

fn clampIconPx(metric: i32, fallback: u32) u32 {
    if (metric <= 0 or metric > 256) return fallback;
    return @intCast(metric);
}

/// 窗口样式（纯函数，单测覆盖）。
fn windowStyleFor(opts: ipc.WindowOptions) win32.DWORD {
    var style: win32.DWORD = if (opts.decorations)
        win32.WS_OVERLAPPEDWINDOW
    else
        win32.WS_POPUP | win32.WS_SYSMENU | win32.WS_MINIMIZEBOX | win32.WS_MAXIMIZEBOX;

    if (!opts.resizable) {
        style &= ~(win32.WS_THICKFRAME | win32.WS_MAXIMIZEBOX);
    } else if (!opts.decorations) {
        style |= win32.WS_THICKFRAME;
    }
    if (opts.child) style = (style & ~(win32.WS_POPUP | win32.WS_CAPTION | win32.WS_SYSMENU | win32.WS_MINIMIZEBOX | win32.WS_MAXIMIZEBOX)) | 0x40000000;
    if (opts.visible) style |= win32.WS_VISIBLE;
    return style;
}

/// 扩展样式：任务栏隐藏 / 透明合成。
fn windowExStyleFor(opts: ipc.WindowOptions) win32.DWORD {
    var ex: win32.DWORD = 0;
    if (opts.skip_taskbar) ex |= win32.WS_EX_TOOLWINDOW;
    if (opts.transparent) ex |= win32.WS_EX_NOREDIRECTIONBITMAP;
    return ex;
}

/// 0xRRGGBB → COLORREF（0x00BBGGRR）。
fn colorRefOf(rgb: u32) win32.DWORD {
    const r = (rgb >> 16) & 0xff;
    const g = (rgb >> 8) & 0xff;
    const b = rgb & 0xff;
    return @intCast((b << 16) | (g << 8) | r);
}

/// Windows 应用主题：true = 浅色（AppsUseLightTheme）。
fn appsUseLightTheme() bool {
    var value: u32 = 1;
    var size: win32.DWORD = 4;
    // 直接 RegGetValueW 需要完整子键；用 page allocator 构造宽字符。
    const alloc = std.heap.page_allocator;
    const sub_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize") catch return true;
    defer alloc.free(sub_w);
    const val_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, "AppsUseLightTheme") catch return true;
    defer alloc.free(val_w);
    const hr = win32.RegGetValueW(win32.HKEY_CURRENT_USER, sub_w.ptr, val_w.ptr, win32.RRF_RT_REG_DWORD, null, &value, &size);
    if (com.failed(hr)) return true;
    return value != 0;
}

fn themeName() []const u8 {
    return if (appsUseLightTheme()) "light" else "dark";
}

/// WM_SETTINGCHANGE 的 lParam 是否为主题变更（UTF-16 "ImmersiveColorSet"）。
fn isImmersiveColorSet(lparam: win32.LPARAM) bool {
    if (lparam == 0) return false;
    const addr: usize = @bitCast(lparam);
    const ptr: [*:0]const u16 = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(addr))));
    const s = std.mem.span(ptr);
    return std.mem.eql(u16, s, &[_]u16{ 'I', 'm', 'm', 'e', 'r', 's', 'i', 'v', 'e', 'C', 'o', 'l', 'o', 'r', 'S', 'e', 't' });
}

fn streamFromBytes(bytes: []const u8) ?*wv2.IStream {
    const hg = win32.GlobalAlloc(win32.GMEM_MOVEABLE, @max(bytes.len, 1)) orelse return null;
    const locked = win32.GlobalLock(hg) orelse {
        _ = win32.GlobalFree(hg);
        return null;
    };
    const dst: [*]u8 = @ptrCast(locked);
    if (bytes.len > 0) @memcpy(dst[0..bytes.len], bytes);
    _ = win32.GlobalUnlock(hg);

    var stream: ?*anyopaque = null;
    if (com.failed(win32.CreateStreamOnHGlobal(hg, 1, &stream))) {
        _ = win32.GlobalFree(hg);
        return null;
    }
    return @ptrCast(stream);
}

// ---------------------------------------------------------------------------
// 资产服务纯函数（Phase C；单测覆盖）
// ---------------------------------------------------------------------------

fn flateDecompress(alloc: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const n = try dec.reader.streamRemaining(&aw.writer);
    const out = try alloc.dupe(u8, aw.written());
    std.debug.assert(n == out.len);
    return out;
}

/// 实体标记字节缓冲：`"` + 16 hex + `"` = 18 字节。
pub const EtagBytes = [18]u8;

/// 内容强 ETag：wyhash(u64) hex（同内容必同值，跨构建稳定）。
pub fn etagOf(content: []const u8) EtagBytes {
    const digest = std.hash.Wyhash.hash(0, content);
    const hexd = "0123456789abcdef";
    var out: EtagBytes = undefined;
    out[0] = '"';
    out[17] = '"';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        out[1 + i] = hexd[(digest >> shift) & 0xf];
    }
    return out;
}

/// Accept-Encoding 是否接受 gzip（RFC 9110：大小写不敏感；q=0 视为拒绝）。
pub fn acceptsGzip(header: ?[]const u8) bool {
    const h = header orelse return false;
    var it = std.mem.splitScalar(u8, h, ',');
    while (it.next()) |tok_raw| {
        var tok = std.mem.trim(u8, tok_raw, " \t");
        if (tok.len == 0) continue;
        var q: f32 = 1.0;
        if (std.mem.indexOfScalar(u8, tok, ';')) |semi| {
            const params = tok[semi + 1 ..];
            tok = std.mem.trim(u8, tok[0..semi], " \t");
            var pit = std.mem.splitScalar(u8, params, ';');
            while (pit.next()) |p_raw| {
                const p = std.mem.trim(u8, p_raw, " \t");
                if (p.len >= 2 and (p[0] == 'q' or p[0] == 'Q') and p[1] == '=') {
                    q = std.fmt.parseFloat(f32, p[2..]) catch 1.0;
                }
            }
        }
        if (q > 0 and std.ascii.eqlIgnoreCase(tok, "gzip")) return true;
    }
    return false;
}

/// If-None-Match 匹配（RFC 9110：逗号列表 / `*` / W/ 弱前缀均可参与比较）。
pub fn ifNoneMatchMatches(header: ?[]const u8, etag: []const u8) bool {
    const h = header orelse return false;
    var it = std.mem.splitScalar(u8, h, ',');
    while (it.next()) |tok_raw| {
        var tok = std.mem.trim(u8, tok_raw, " \t");
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "*")) return true;
        if (tok.len > 2 and tok[0] == 'W' and tok[1] == '/') tok = tok[2..];
        if (std.mem.eql(u8, tok, etag)) return true;
    }
    return false;
}

/// 反代上游 URL：base 去尾 '/' + path（含 query，须以 '/' 开头）。
pub fn joinProxyUrl(alloc: std.mem.Allocator, base: []const u8, path_with_query: []const u8) ![]u8 {
    var b = base;
    while (b.len > 0 and b[b.len - 1] == '/') b = b[0 .. b.len - 1];
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ b, path_with_query });
}

/// 读请求头（UTF-8，调用方释放）；头不存在返回 null。
fn requestHeaderUtf8(args: *wv2.ICoreWebView2WebResourceRequestedEventArgs, alloc: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
    const rr = args.getRequest();
    if (com.failed(rr.hr) or rr.request == null) return null;
    const hh = rr.request.?.getHeaders();
    if (com.failed(hh.hr) or hh.headers == null) return null;
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
    defer alloc.free(name_w);
    const r = hh.headers.?.getHeader(name_w.ptr);
    if (com.failed(r.hr) or r.value == null) return null;
    defer wv2.freeCoString(r.value.?);
    return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(r.value.?)) catch null;
}

// ---------------------------------------------------------------------------
// Backend（按 Config 编译期实例化）
// ---------------------------------------------------------------------------

/// 同步等待 WebView 异步 action 的 completion（局部消息泵，避免 STA 死锁）。
const SyncWait = struct {
    alloc: std.mem.Allocator,
    done: bool = false,
    json: ?[]u8 = null,
    err: ?anyerror = null,

    fn callback(context: *anyopaque, result: anyerror![]const u8) void {
        const self: *SyncWait = @ptrCast(@alignCast(context));
        if (result) |json| {
            self.json = self.alloc.dupe(u8, json) catch {
                self.err = error.OutOfMemory;
                self.done = true;
                return;
            };
        } else |e| self.err = e;
        self.done = true;
    }
};

fn jsonString(alloc: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    return if (value) |v| std.json.Stringify.valueAlloc(alloc, v, .{}) else alloc.dupe(u8, "null");
}

fn appendFmt(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(text);
    try buf.appendSlice(alloc, text);
}

/// Toast 交互事件（WinRT 线程）→ UI 线程事件 JSON。纯函数，便于单测。
fn toastEventJson(alloc: std.mem.Allocator, ev: shared_notification.Event) ![]u8 {
    const tag = try jsonString(alloc, ev.tag);
    defer alloc.free(tag);
    const group = try jsonString(alloc, ev.group);
    defer alloc.free(group);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    switch (ev.kind) {
        .activated => |a| {
            const args = try std.json.Stringify.valueAlloc(alloc, a.arguments, .{});
            defer alloc.free(args);
            try appendFmt(alloc, &body, "{{\"kind\":\"activated\",\"arguments\":{s},\"data_error\":{},\"user_input\":[", .{ args, a.data_error });
            for (a.user_input, 0..) |ui, i| {
                if (i != 0) try body.append(alloc, ',');
                const id = try std.json.Stringify.valueAlloc(alloc, ui.id, .{});
                defer alloc.free(id);
                const value = try std.json.Stringify.valueAlloc(alloc, ui.value, .{});
                defer alloc.free(value);
                try appendFmt(alloc, &body, "{{\"id\":{s},\"value\":{s}}}", .{ id, value });
            }
            try body.appendSlice(alloc, "]}");
        },
        .dismissed => |reason| try appendFmt(alloc, &body, "{{\"kind\":\"dismissed\",\"reason\":\"{s}\"}}", .{@tagName(reason)}),
        .failed => |code| try appendFmt(alloc, &body, "{{\"kind\":\"failed\",\"code\":{d}}}", .{code}),
    }
    return std.fmt.allocPrint(alloc, "{{\"tag\":{s},\"group\":{s},\"event\":{s}}}", .{ tag, group, body.items });
}

/// OLE 拖放的自定义格式名 + 载荷长度（不回传原始字节）。
fn customFormatsJson(alloc: std.mem.Allocator, custom: []const shared_drag.CustomFormat) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (custom, 0..) |c, i| {
        if (i != 0) try buf.append(alloc, ',');
        const name = try std.json.Stringify.valueAlloc(alloc, c.name, .{});
        defer alloc.free(name);
        try appendFmt(alloc, &buf, "{{\"name\":{s},\"bytes\":{d}}}", .{ name, c.data.len });
    }
    try buf.append(alloc, ']');
    return buf.toOwnedSlice(alloc);
}

fn openExternal(alloc: std.mem.Allocator, url: []const u8) void {
    if (!security.isWebUrl(url)) return;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, url) catch return;
    defer alloc.free(wide);
    // operation=null → 系统默认（浏览器打开 https/http URL）
    const rc = ShellExecuteW(null, null, wide.ptr, null, null, win32.SW_SHOW);
    if (rc <= 32) log.print("[webview] ShellExecuteW failed ({d}) for {s}", .{ rc, url });
}

fn Backend(comptime config: Config) type {
    return struct {
        const Self = @This();

        /// comptime 固化的配置切片（供 comptime 参数的反射函数使用）
        const menu_cfg: ?[]const Config.MenuItem = config.menu;
        const hotkey_cfg: ?[]const Config.Hotkey = config.hotkeys;
        const update_cfg: ?Config.Update = config.update;
        const tray_menu_cfg: ?[]const Config.MenuItem = if (config.tray) |t| t.menu else null;
        const menu_leaf_count: usize = if (config.menu) |items| menu_mod.collectIds(items).len else 0;
        const hotkey_count: usize = if (config.hotkeys) |h| h.len else 0;

        var instance: ?*Self = null;

        fn setInstance(p: ?*Self) void {
            instance = p;
        }

        /// 单窗口状态（多窗口 v0.1.6）。窗口对象在应用生命周期内存活，
        /// 关闭只标记 alive=false（COM/句柄在 cleanup 统一释放）。
        const Window = struct {
            backend: *Self,
            id: u32,
            hwnd: win32.HWND = null,
            title: []u8,
            url: []u8,
            label: []u8,
            parent_id: ?u32 = null,
            modal: bool = false,
            child: bool = false,
            modal_children: u32 = 0,
            parent_was_enabled: bool = true,
            menu: win32.HMENU = null,
            menu_items: []const Config.MenuItem = &.{},
            menu_arena: std.heap.ArenaAllocator,
            state_key: ?[]const u8 = null,
            normal_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 900, .bottom = 640 },
            controller: ?*wv2.ICoreWebView2Controller = null,
            webview: ?*wv2.ICoreWebView2 = null,
            msg_handler: ?*MessageHandler = null,
            res_handler: ?*WebResourceHandler = null,
            nav_handler: ?*NavCompletedHandler = null,
            alive: bool = true,
            fullscreen: bool = false,
            saved_style: i32 = 0,
            saved_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            // ---- v0.1.7 窗口模型 ----
            min_width: ?u32 = null,
            min_height: ?u32 = null,
            max_width: ?u32 = null,
            max_height: ?u32 = null,
            background_color: ?u32 = null,
            transparent: bool = false,
            close_requested_events: bool = false,
            icon_big: win32.HICON = null,
            icon_small: win32.HICON = null,
            owns_icons: bool = false,
            bg_brush: win32.HBRUSH = null,
            dpi: u32 = 96,
            // ---- v0.1.9–v0.1.12 ----
            driver: ?*webview_driver.Driver = null,
            drop_target: ?*win_drag.DropTarget = null,
            clipboard_listening: bool = false,

            fn updateBounds(self: *Window) void {
                const controller = self.controller orelse return;
                var rc: win32.RECT = undefined;
                if (win32.GetClientRect(self.hwnd, &rc) == 0) return;
                _ = controller.putBounds(.{ .left = 0, .top = 0, .right = rc.right, .bottom = rc.bottom });
            }

            /// UI 线程便捷事件：序列化 payload 并直接投递（菜单/快捷键/更新流程用）。
            fn emitEventPayload(self: *Window, name: []const u8, payload: anytype) void {
                if (!self.alive) return;
                const b = self.backend;
                // v0.1.11：声明了 capability 清单时，Zig→JS 事件同样受
                // receive_events 约束（框架内部 "__" 事件不受限）。
                if (config.security.capabilities.len != 0 and !std.mem.startsWith(u8, name, "__") and
                    !security.allowed(config.security, config.url, b.dev_url, config.url, self.label, .receive_event, name)) return;
                const payload_json = std.json.Stringify.valueAlloc(b.allocator, payload, .{}) catch return;
                defer b.allocator.free(payload_json);
                const msg = ipc.encodeEvent(b.allocator, name, payload_json) catch return;
                self.emitJsonUi(msg); // 所有权转移
            }

            fn emitJsonUi(self: *Window, msg: []u8) void {
                const b = self.backend;
                defer b.allocator.free(msg);
                if (!self.alive) return;
                const webview = self.webview orelse return;
                const wide = std.unicode.utf8ToUtf16LeAllocZ(b.allocator, msg) catch return;
                defer b.allocator.free(wide);
                _ = webview.postWebMessageAsJson(wide.ptr);
            }

            fn sendJson(self: *Window, msg: []u8) void {
                const b = self.backend;
                defer b.allocator.free(msg);
                const webview = self.webview orelse return;
                const wide = std.unicode.utf8ToUtf16LeAllocZ(b.allocator, msg) catch return;
                defer b.allocator.free(wide);
                _ = webview.postWebMessageAsJson(wide.ptr);
            }

            /// 渲染进程/浏览器进程崩溃后重建 WebView 前，释放旧 COM 引用。
            fn releaseWebViewCom(self: *Window) void {
                if (self.msg_handler) |h| h.dropRef();
                if (self.res_handler) |h| h.dropRef();
                if (self.nav_handler) |h| h.dropRef();
                if (self.webview) |wv| _ = wv.lpVtbl.Release(wv);
                if (self.controller) |c| {
                    _ = c.lpVtbl.Close(c);
                    _ = c.lpVtbl.Release(c);
                }
                self.webview = null;
                self.msg_handler = null;
                self.res_handler = null;
                self.nav_handler = null;
                self.controller = null;
            }
        };

        allocator: std.mem.Allocator,
        class_u8: []u8 = &.{},
        class_w: [:0]u16 = undefined,
        windows: std.ArrayListUnmanaged(*Window) = .empty,
        next_id: u32 = 1,
        env: ?*wv2.ICoreWebView2Environment = null,
        tray_menu: ?win32.HMENU = null,
        icon_big: win32.HICON = null,
        icon_small: win32.HICON = null,
        tray_icon: win32.HICON = null,
        tray: ?tray_mod.Tray = null,
        watcher: ?*Watcher = null,
        updater_env: ?updater.Env = null,
        updater_url_override: ?[]u8 = null,
        dev_dir: ?[]const u8 = null,
        dev_url: ?[]const u8 = null,
        /// dev 反代模式（Phase C）：应用保持自身 origin，资产请求转发到该上游（如 vite）
        dev_proxy: ?[]const u8 = null,
        proxy_threaded: ?*std.Io.Threaded = null, // 懒建，连接池复用
        proxy_client: ?*std.http.Client = null,
        /// 压缩资产惰性解压缓存（key = asset path；UI 线程独占访问，无需锁）
        asset_cache: std.StringHashMapUnmanaged([]u8) = .empty,
        /// WinRT Toast 通知主通道（气球为降级；不要求 tray 启用）
        toast: ?toast_mod.Toast = null,
        quit_code: std.atomic.Value(u8) = .init(0),
        /// 启动/第二实例转发的深链接载荷（导航完成后发 deepLink 事件）
        pending_launch: ?deep_link.Launch = null,
        launch_emitted: bool = false,

        // ---- 初始化 ----

        fn init(self: *Self, class_u8: []const u8) !void {
            self.class_u8 = try self.allocator.dupe(u8, class_u8);
            self.class_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, class_u8);

            // 图标按目标尺寸创建：托盘/标题栏用小图标，Alt-Tab/任务栏用大图标。
            // 直接用 256px HICON 会被托盘按 1:1 绘制成"左上角一块"（实测）。
            const big_px = clampIconPx(win32.GetSystemMetrics(win32.SM_CXICON), 32);
            const small_px = clampIconPx(win32.GetSystemMetrics(win32.SM_CXSMICON), 16);
            self.icon_big = self.makeIcon(config.icon, big_px, big_px);
            self.icon_small = self.makeIcon(config.icon, small_px, small_px);
            if (config.tray) |t| {
                self.tray_icon = self.makeIcon(t.icon, small_px, small_px);
            }
            if (self.icon_small != null) {
                log.print("[icon] ready (custom={s}; small={d}px big={d}px)", .{
                    if (config.icon) |p| p else "builtin Zig logo",
                    small_px,
                    big_px,
                });
            }

            const hinstance = win32.GetModuleHandleW(null);
            const wc = win32.WNDCLASSEXW{
                .cbSize = @sizeOf(win32.WNDCLASSEXW),
                .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
                .lpfnWndProc = wndProc,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = hinstance,
                .hIcon = self.icon_big,
                .hCursor = win32.LoadCursorW(null, @ptrFromInt(win32.IDC_ARROW)),
                .hbrBackground = @ptrFromInt(win32.COLOR_WINDOW + 1),
                .lpszMenuName = null,
                .lpszClassName = self.class_w.ptr,
                .hIconSm = self.icon_small,
            };
            if (win32.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

            if (Self.tray_menu_cfg) |items| {
                if (menu_mod.buildPopup(self.allocator, items, TRAY_MENU_BASE)) |m| {
                    self.tray_menu = m;
                    log.print("[tray] popup menu built", .{});
                } else |err| {
                    log.print("[tray] popup menu build failed: {s}", .{@errorName(err)});
                }
            }
        }

        const IconBytes = struct {
            data: []const u8,
            owned: ?[]u8 = null,
        };

        /// 图标来源：资产路径（config.icon / Tray.icon）或内置 Zig logo 兜底。
        fn iconBytes(self: *Self, path_opt: ?[]const u8) IconBytes {
            if (path_opt) |path| {
                for (config.assets) |asset| {
                    if (!std.mem.eql(u8, asset.path, path)) continue;
                    switch (asset.encoding) {
                        .identity => return .{ .data = asset.content },
                        .gzip => {
                            const raw = flateDecompress(self.allocator, asset.content) catch break;
                            return .{ .data = raw, .owned = raw };
                        },
                    }
                }
                log.print("[icon] custom asset not usable: {s} -> builtin Zig logo", .{path});
            }
            return .{ .data = default_icon_bytes };
        }

        /// 按目标像素尺寸创建 HICON（源图像由 iconBytes 解析，临时解压随用随释放）。
        fn makeIcon(self: *Self, path_opt: ?[]const u8, cx: u32, cy: u32) win32.HICON {
            const src = self.iconBytes(path_opt);
            defer if (src.owned) |o| self.allocator.free(o);
            return icon_mod.createHiconAt(src.data, cx, cy);
        }

        // ---- 窗口表 ----

        fn windowById(self: *Self, id: u32) ?*Window {
            for (self.windows.items) |w| {
                if (w.id == id) return w;
            }
            return null;
        }

        fn mainWindow(self: *Self) ?*Window {
            if (self.windowById(1)) |w| {
                if (w.alive) return w;
            }
            for (self.windows.items) |w| {
                if (w.alive) return w;
            }
            return null;
        }

        fn windowOfHwnd(self: *Self, hwnd: win32.HWND) ?*Window {
            for (self.windows.items) |w| {
                if (w.hwnd == hwnd) return w;
            }
            return null;
        }

        fn focusedWindow(self: *Self) ?*Window {
            const fg = win32.GetForegroundWindow();
            if (fg != null) {
                if (self.windowOfHwnd(fg)) |w| return w;
            }
            return self.mainWindow();
        }

        fn aliveCount(self: *Self) usize {
            var n: usize = 0;
            for (self.windows.items) |w| {
                if (w.alive) n += 1;
            }
            return n;
        }

        // ---- 窗口创建 / WebView 附加 ----

        fn cloneMenu(alloc: std.mem.Allocator, items: []const Config.MenuItem) anyerror![]const Config.MenuItem {
            if (items.len > 4096) return error.TooManyMenuItems;
            const copy = try alloc.alloc(Config.MenuItem, items.len);
            for (items, copy) |item, *dest| {
                dest.* = .{
                    .label = try alloc.dupe(u8, item.label),
                    .id = if (item.id) |id| try alloc.dupe(u8, id) else null,
                    .items = if (item.items) |children| try cloneMenu(alloc, children) else null,
                };
            }
            return copy;
        }

        fn createWindow(self: *Self, opts: ipc.WindowOptions) !*Window {
            if (opts.width == 0 or opts.height == 0 or opts.width > 32767 or opts.height > 32767) return error.InvalidWindowSize;
            if (opts.child and opts.modal) return error.InvalidWindowRelationship;
            const parent = if (opts.parent) |id| self.windowById(if (id == 0) 1 else id) orelse return error.ParentNotFound else null;
            if (parent) |p| { if (!p.alive) return error.ParentNotFound; }
            if ((opts.child or opts.modal) and parent == null) return error.ParentRequired;
            const label = if (opts.label) |name| try self.allocator.dupe(u8, name) else try std.fmt.allocPrint(self.allocator, "window-{d}", .{self.next_id});
            errdefer self.allocator.free(label);
            for (self.windows.items) |other| if (other.alive and std.mem.eql(u8, other.label, label)) return error.DuplicateWindowLabel;
            var menu_arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer menu_arena.deinit();
            // v0.1.8：显式 state_key 优先；开启全局持久化时按窗口 label（≈ 窗口 id）保存。
            const state_key = if (opts.state_key) |key|
                try menu_arena.allocator().dupe(u8, key)
            else if (config.persist_window_state)
                try menu_arena.allocator().dupe(u8, label)
            else
                null;
            const menu_items = try cloneMenu(menu_arena.allocator(), opts.menu orelse config.menu orelse &.{});
            const title = try self.allocator.dupe(u8, opts.title);
            errdefer self.allocator.free(title);
            const url = try self.allocator.dupe(u8, opts.url orelse config.url);
            errdefer self.allocator.free(url);

            const w = try self.allocator.create(Window);
            errdefer self.allocator.destroy(w);
            w.* = .{
                .backend = self,
                .id = self.next_id,
                .title = title,
                .url = url,
                .label = label,
                .parent_id = if (parent) |p| p.id else null,
                .modal = opts.modal,
                .child = opts.child,
                .menu_arena = menu_arena,
                .menu_items = menu_items,
                .state_key = state_key,
                .min_width = opts.min_width,
                .min_height = opts.min_height,
                .max_width = opts.max_width,
                .max_height = opts.max_height,
                .background_color = opts.background_color,
                .transparent = opts.transparent,
                .close_requested_events = opts.close_requested_event,
            };

            const hinstance = win32.GetModuleHandleW(null);
            const title_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, title);
            defer self.allocator.free(title_w);

            const style = windowStyleFor(opts);
            const ex_style = windowExStyleFor(opts);
            const has_menu = opts.decorations and !opts.child and menu_items.len != 0;
            if (has_menu) w.menu = try menu_mod.buildWin32(self.allocator, menu_items);
            errdefer { if (w.menu) |menu| _ = win32.DestroyMenu(menu); }
            try self.windows.ensureUnusedCapacity(self.allocator, 1);

            var rect = win32.RECT{
                .left = 0,
                .top = 0,
                .right = @intCast(opts.width),
                .bottom = @intCast(opts.height),
            };
            _ = win32.AdjustWindowRect(&rect, style, if (has_menu) 1 else 0);

            w.hwnd = win32.CreateWindowExW(
                ex_style,
                self.class_w.ptr,
                title_w.ptr,
                style,
                opts.x orelse win32.CW_USEDEFAULT,
                opts.y orelse win32.CW_USEDEFAULT,
                rect.right - rect.left,
                rect.bottom - rect.top,
                if (parent) |p| p.hwnd else null,
                null,
                hinstance,
                null,
            ) orelse return error.CreateWindowFailed;

            w.dpi = win32.GetDpiForWindow(w.hwnd);

            if (has_menu) {
                if (win32.SetMenu(w.hwnd, w.menu) == 0) {
                    _ = win32.DestroyWindow(w.hwnd);
                    return error.AttachMenuFailed;
                }
            }

            // 每窗口图标（opts.icon）或应用默认图标
            w.icon_big = self.icon_big;
            w.icon_small = self.icon_small;
            if (opts.icon) |path| {
                const cx_big = clampIconPx(win32.GetSystemMetrics(win32.SM_CXICON), 32);
                const cx_small = clampIconPx(win32.GetSystemMetrics(win32.SM_CXSMICON), 16);
                const ib = self.makeIcon(path, cx_big, cx_big);
                const is = self.makeIcon(path, cx_small, cx_small);
                if (ib != null and is != null) {
                    w.icon_big = ib;
                    w.icon_small = is;
                    w.owns_icons = true;
                } else {
                    if (ib) |h| _ = win32.DestroyIcon(h);
                    if (is) |h| _ = win32.DestroyIcon(h);
                }
            }
            if (w.icon_big) |ic| {
                _ = win32.SendMessageW(w.hwnd, win32.WM_SETICON, win32.ICON_BIG, @bitCast(@intFromPtr(ic)));
            }
            if (w.icon_small) |ic| {
                _ = win32.SendMessageW(w.hwnd, win32.WM_SETICON, win32.ICON_SMALL, @bitCast(@intFromPtr(ic)));
            }

            if (opts.always_on_top) {
                _ = win32.SetWindowPos(w.hwnd, win32.HWND_TOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
            }
            // v0.1.12：OLE IDropTarget（含坐标/自定义格式）优先，失败回退 WM_DROPFILES。
            if (win_drag.DropTarget.create(self.allocator, w.hwnd, w, Self.onDragEvent, config.drag_formats)) |target| {
                w.drop_target = target;
            } else |err| {
                log.print("[drag] OLE drop target unavailable: {s} (fallback WM_DROPFILES)", .{@errorName(err)});
            }
            win32.DragAcceptFiles(w.hwnd, if (w.drop_target == null) 1 else 0);
            if (config.clipboard_change_event) {
                if (win_clipboard.startListening(w.hwnd)) |_| {
                    w.clipboard_listening = true;
                } else |err| {
                    log.print("[clip] change listener unavailable: {s}", .{@errorName(err)});
                }
            }

            self.windows.appendAssumeCapacity(w);
            self.next_id += 1;
            _ = win32.GetWindowRect(w.hwnd, &w.normal_rect);
            if (opts.modal) {
                const p = parent.?;
                if (p.modal_children == 0) {
                    p.parent_was_enabled = IsWindowEnabled(p.hwnd) != 0;
                    _ = EnableWindow(p.hwnd, 0);
                }
                p.modal_children += 1;
            }
            log.print("[win32] window #{d} created: \"{s}\" ({s}) decorations={} transparent={} topmost={} taskbar={} visible={}", .{
                w.id, title, url, opts.decorations, opts.transparent, opts.always_on_top, !opts.skip_taskbar, opts.visible,
            });
            self.restoreWindowState(w);
            return w;
        }

        fn beginController(self: *Self, w: *Window) void {
            const env = self.env orelse return;
            const handler = ControllerCompletedHandler.create(self, w) catch {
                log.print("[fatal] controller handler alloc failed", .{});
                return;
            };
            const hr = env.createController(w.hwnd, handler);
            handler.dropRef();
            if (com.failed(hr)) {
                log.print("[fatal] CreateCoreWebView2Controller failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
                win32.PostQuitMessage(3);
            }
        }

        fn onControllerReady(self: *Self, w: *Window, controller: *wv2.ICoreWebView2Controller) void {
            w.controller = controller;
            _ = controller.lpVtbl.AddRef(controller);
            log.print("[webview] controller created (window #{d})", .{w.id});

            _ = controller.putIsVisible(1);
            w.updateBounds();

            const wv_result = controller.getCoreWebView2();
            if (com.failed(wv_result.hr) or wv_result.webview == null) {
                log.print("[fatal] get_CoreWebView2 failed hr=0x{x}", .{@as(u32, @bitCast(wv_result.hr))});
                win32.PostQuitMessage(5);
                return;
            }
            const webview = wv_result.webview.?;
            w.webview = webview;
            log.print("[webview] core webview attached (window #{d})", .{w.id});

            // v0.1.7：透明/自定义背景（ICoreWebView2Controller2）
            if (w.transparent or w.background_color != null) {
                if (controller.getController2()) |c2| {
                    const col: wv2.Color = if (w.transparent)
                        .{ .a = 0, .r = 0, .g = 0, .b = 0 }
                    else blk: {
                        const rgb = w.background_color.?;
                        break :blk .{
                            .a = 255,
                            .r = @intCast((rgb >> 16) & 0xff),
                            .g = @intCast((rgb >> 8) & 0xff),
                            .b = @intCast(rgb & 0xff),
                        };
                    };
                    const hr_bg = c2.putDefaultBackgroundColor(col);
                    c2.release();
                    log.print("[webview] default background set (a={d}, hr=0x{x})", .{ col.a, @as(u32, @bitCast(hr_bg)) });
                } else {
                    log.print("[webview] Controller2 unavailable -> transparent/background ignored", .{});
                    if (w.transparent) {
                        // 降级：移除无重定向位图，恢复窗口底色（避免整窗不可见）
                        w.transparent = false;
                        const cur: win32.DWORD = @bitCast(win32.GetWindowLongW(w.hwnd, win32.GWL_EXSTYLE));
                        _ = win32.SetWindowLongW(w.hwnd, win32.GWL_EXSTYLE, @bitCast(cur & ~win32.WS_EX_NOREDIRECTIONBITMAP));
                        _ = win32.SetWindowPos(w.hwnd, null, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED);
                        _ = win32.InvalidateRect(w.hwnd, null, 1);
                    }
                }
            }

            // IPC sink
            w.msg_handler = MessageHandler.create(w) catch null;
            if (w.msg_handler) |mh| {
                var token: com.EventRegistrationToken = .{ .value = 0 };
                const hr1 = webview.addWebMessageReceived(mh, &token);
                log.print("[webview] add_WebMessageReceived hr=0x{x}", .{@as(u32, @bitCast(hr1))});
            }

            // 资产服务（dev-url 模式无需 custom scheme 拦截）
            if (self.dev_url == null) {
                w.res_handler = WebResourceHandler.create(w) catch null;
                if (w.res_handler) |rh| {
                    var token2: com.EventRegistrationToken = .{ .value = 0 };
                    const hr2 = webview.addWebResourceRequested(rh, &token2);
                    log.print("[webview] add_WebResourceRequested hr=0x{x}", .{@as(u32, @bitCast(hr2))});

                    const filter = std.fmt.allocPrint(self.allocator, "{s}/*", .{originOf(config.url)}) catch return;
                    defer self.allocator.free(filter);
                    const filter_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, filter) catch return;
                    defer self.allocator.free(filter_w);
                    const hr3 = webview.addWebResourceRequestedFilter(filter_w.ptr, wv2.WEB_RESOURCE_CONTEXT_ALL);
                    log.print("[webview] AddWebResourceRequestedFilter({s}) hr=0x{x}", .{ filter, @as(u32, @bitCast(hr3)) });
                }
            }

            // 导航完成诊断
            w.nav_handler = NavCompletedHandler.create(w) catch null;
            if (w.nav_handler) |nh| {
                var token3: com.EventRegistrationToken = .{ .value = 0 };
                const hr3c = webview.addNavigationCompleted(nh, &token3);
                log.print("[webview] add_NavigationCompleted hr=0x{x}", .{@as(u32, @bitCast(hr3c))});
            }

            // v0.1.9/v0.1.10：WebView2 事件面 / Settings / 运行时 API / 下载 / 权限 / 崩溃恢复。
            var wv_opts = config.webview;
            wv_opts.origin = originOf(config.url);
            if (webview_driver.attach(self.allocator, webview, controller, wv_opts, w, .{
                .emit = driverEmit,
                .navigation = driverNavigation,
                .new_window = driverNewWindow,
                .external = driverExternal,
                .schedule = driverSchedule,
                .recover = driverRecover,
            })) |driver| {
                w.driver = driver;
                log.print("[webview] driver attached (devtools={}, downloads={}, new_window={s}, recover={})", .{
                    wv_opts.settings.devtools, wv_opts.downloads.enabled, @tagName(wv_opts.new_window), wv_opts.recover_renderer,
                });
            } else |err| {
                log.print("[webview] driver unavailable: {s} (legacy handlers remain)", .{@errorName(err)});
            }

            // 注入 zilt 运行时（window.zilt：invoke/emit/on + __reload）
            const script_handler = IgnoreCompletedHandler(wv2.IID_AddScriptToExecuteOnDocumentCreatedCompletedHandler).create(w) catch null;
            if (script_handler) |sh| {
                const js_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, ipc.runtime_js) catch return;
                defer self.allocator.free(js_w);
                const hr_js = webview.addScriptToExecuteOnDocumentCreated(js_w.ptr, sh);
                sh.dropRef();
                log.print("[webview] inject runtime js hr=0x{x}", .{@as(u32, @bitCast(hr_js))});
            }

            // 导航
            const nav_url = if (w.id == 1) (self.dev_url orelse w.url) else w.url;
            const url_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, nav_url) catch return;
            defer self.allocator.free(url_w);
            const hr4 = webview.navigate(url_w.ptr);
            log.print("[webview] navigate {s} hr=0x{x}", .{ nav_url, @as(u32, @bitCast(hr4)) });

            if (w.id == 1) self.onMainReady(w);
        }

        /// 主窗口 WebView 就绪后的应用级挂载（托盘 / watcher / 更新器自动流）。
        fn onMainReady(self: *Self, w: *Window) void {
            if (config.tray) |tc| {
                self.tray = tray_mod.Tray.init(self.allocator, w.hwnd, WM_ZILT_TRAY, tc.tooltip, self.tray_icon) catch null;
                if (self.tray) |*t| {
                    const ok = t.add();
                    log.print("[tray] added (ok={})", .{ok});
                }
            }

            if (self.dev_dir) |dir| {
                self.watcher = Watcher.start(self.allocator, self.makeContextWith(w, self.allocator), dir);
            }

            // 窗口模型 E2E（ZILT_SMOKE_FRAME=1 无边框 / 2 透明 / 3 置顶 / 4 隐藏任务栏）
            if (win32.getEnvUtf8(self.allocator, "ZILT_SMOKE_FRAME")) |v| {
                defer self.allocator.free(v);
                if (v.len > 0) {
                    const base = originOf(config.url);
                    const path = if (v[0] == '2') "/transparent.html" else "/second.html";
                    const url = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, path }) catch return;
                    defer self.allocator.free(url);
                    var opts = ipc.WindowOptions{
                        .title = "Zilt 窗口模型 E2E",
                        .width = 560,
                        .height = 400,
                        .url = url,
                    };
                    switch (v[0]) {
                        '1' => opts.decorations = false,
                        '2' => {
                            opts.decorations = false;
                            opts.transparent = true;
                            opts.close_requested_event = true;
                        },
                        '3' => opts.always_on_top = true,
                        '4' => opts.skip_taskbar = true,
                        else => {},
                    }
                    if (self.createWindow(opts)) |nw| {
                        _ = win32.ShowWindow(nw.hwnd, win32.SW_SHOW);
                        self.beginController(nw);
                        log.print("[frame] window #{d} created (mode={c})", .{ nw.id, v[0] });
                    } else |_| {}
                }
            }
            if (win32.getEnvUtf8(self.allocator, "ZILT_SMOKE_MULTI")) |v| {
                defer self.allocator.free(v);
                if (v.len > 0 and v[0] == '1') {
                    const url = std.fmt.allocPrint(self.allocator, "{s}/second.html", .{originOf(config.url)}) catch return;
                    defer self.allocator.free(url);
                    const nw = self.createWindow(.{ .title = "Zilt 多窗口 E2E", .width = 640, .height = 460, .url = url }) catch null;
                    if (nw) |x| {
                        _ = win32.ShowWindow(x.hwnd, win32.SW_SHOW);
                        self.beginController(x);
                        log.print("[multi] second window created (#{d})", .{x.id});
                        // '2' = 3s 后自动关闭第二个窗口（验证关闭/事件/资源释放路径）
                        if (v.len > 1 and v[1] == '2') _ = win32.SetTimer(x.hwnd, 2, 3000, null);
                    }
                }
            }

            if (self.updater_env != null) {
                if (win32.getEnvUtf8(self.allocator, "ZILT_UPDATE_URL")) |u| {
                    defer self.allocator.free(u);
                    if (self.allocator.dupe(u8, u)) |dup| {
                        self.updater_env.?.manifest_url = dup;
                    } else |_| {}
                }
                if (win32.getEnvUtf8(self.allocator, "ZILT_UPDATE_AUTO")) |a| {
                    defer self.allocator.free(a);
                    if (a.len > 0 and a[0] == '1') {
                        if (std.Thread.spawn(.{ .stack_size = 512 * 1024 }, updaterFlow, .{self})) |t| {
                            t.detach();
                            log.print("[updater] auto check started", .{});
                        } else |_| {}
                    }
                }
            }
        }

        // ---- IPC ----

        fn makeContext(self: *Self) ipc.Context {
            const w = self.mainWindow() orelse return .{
                .allocator = self.allocator,
                .msg_allocator = self.allocator,
                .backend = self,
                .emit_fn = emitFromThread,
                .quit_fn = quitFromBackend,
            };
            return self.makeContextWith(w, self.allocator);
        }

        fn makeContextWith(self: *Self, w: *Window, allocator: std.mem.Allocator) ipc.Context {
            return .{
                .allocator = allocator,
                .msg_allocator = self.allocator,
                .backend = self,
                .window_id = w.id,
                .emit_fn = emitFromThread,
                .quit_fn = quitFromBackend,
                .notify_fn = notifyFromThread,
                .dialog_fn = runDialog,
                .updater_env = self.updater_env,
                .restart_fn = restartToApplyDispatch,
                .window_fn = runWindowCmd,
                .spawn_window_fn = spawnWindowFromBackend,
                .clipboard_write_fn = clipboardWriteFromBackend,
                .clipboard_read_fn = clipboardReadFromBackend,
                // ---- v0.1.9–v0.1.12 ----
                .clipboard_read_data_fn = clipboardReadData,
                .clipboard_write_data_fn = clipboardWriteData,
                .start_drag_fn = startDragFiles,
                .notification_show_fn = notificationShow,
                .notification_update_fn = notificationUpdate,
                .notification_status_fn = notificationStatus,
                .webview_request_fn = webviewRequestAction,
                .eval_async_fn = evalAsyncAction,
            };
        }

        /// 任意线程 emit 的 marshal 入口（ipc.Context.emit_fn）。
        fn emitFromThread(backend_ptr: *anyopaque, window_id: u32, message_json: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            var target = self.windowById(if (window_id == 0) 1 else window_id) orelse self.mainWindow() orelse {
                self.allocator.free(message_json);
                return;
            };
            if (!target.alive) target = self.mainWindow() orelse {
                self.allocator.free(message_json);
                return;
            };
            const ok = win32.PostMessageW(target.hwnd, WM_ZILT_EMIT, @intCast(message_json.len), @bitCast(@intFromPtr(message_json.ptr)));
            if (ok == 0) self.allocator.free(message_json);
        }

        /// quit（UI 线程的命令/事件回调内调用）。
        fn quitFromBackend(backend_ptr: *anyopaque, code: u8) void {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            self.quit_code.store(code, .monotonic);
            win32.PostQuitMessage(@intCast(code));
        }

        /// Context.restart_fn 入口（*anyopaque → 实例）。
        fn restartToApplyDispatch(backend_ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            restartToApplyImpl(self);
        }

        /// 原生对话框实现（Context.dialog_fn）。仅在 UI 线程调用（模态阻塞）。
        fn runDialog(backend_ptr: *anyopaque, alloc: std.mem.Allocator, req: ipc.DialogRequest) anyerror!ipc.DialogResponse {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const hwnd = (self.focusedWindow() orelse return error.DialogNotAvailable).hwnd;
            switch (req) {
                .message_box => |o| return .{ .button = try dialog_mod.runMessageBox(alloc, hwnd, o) },
                .open_file => |o| return .{ .path = try dialog_mod.runOpenFile(alloc, hwnd, o) },
                .save_file => |o| return .{ .path = try dialog_mod.runSaveFile(alloc, hwnd, o) },
                .pick_folder => |o| return .{ .path = try dlgx.runPickFolder(alloc, hwnd, o) },
                .pick_files => |o| return .{ .paths = try dlgx.runPickFiles(alloc, hwnd, o) },
                .pick_color => |o| return .{ .color = dlgx.runPickColor(o) },
                .pick_font => |o| return .{ .font = try dlgx.runPickFont(alloc, hwnd, o) },
            }
        }

        /// 任意线程 notify 的 marshal 入口（经主窗口消息泵）。
        fn notifyFromThread(backend_ptr: *anyopaque, title: []const u8, body: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const w = self.mainWindow() orelse return;
            const packed_msg = packNotify(self.allocator, title, body) orelse return;
            const ok = win32.PostMessageW(w.hwnd, WM_ZILT_NOTIFY, 0, @bitCast(@intFromPtr(packed_msg.ptr)));
            if (ok == 0) self.allocator.free(packed_msg);
        }

        fn originAllowed(self: *Self, origin: []const u8) bool {
            _ = self;
            if (std.mem.eql(u8, origin, originOf(config.url))) return true;
            if (config.origin) |o| if (std.mem.eql(u8, origin, o)) return true;
            if (instance) |b| {
                if (b.dev_url) |u| if (std.mem.eql(u8, origin, originOf(u))) return true;
            }
            return false;
        }

        /// UI 线程：WebMessageReceived 分发。
        fn onWebMessage(w: *Window, args: *wv2.ICoreWebView2WebMessageReceivedEventArgs) void {
            const self = w.backend;
            // origin 校验：非允许来源的消息一律丢弃
            var src_u8_owned: ?[]u8 = null;
            defer if (src_u8_owned) |s| self.allocator.free(s);
            var source_url: []const u8 = config.url;
            const src = args.getSource();
            defer if (src.value) |p| wv2.freeCoString(p);
            if (src.value) |p| {
                src_u8_owned = std.unicode.utf16LeToUtf8Alloc(self.allocator, std.mem.span(p)) catch null;
                if (src_u8_owned) |s| {
                    source_url = s;
                    const origin = originOf(s);
                    if (!originAllowed(self, origin)) {
                        log.print("[ipc] dropped message from disallowed origin: {s}", .{origin});
                        return;
                    }
                    // v0.1.11 远程内容边界：isolation 下远程页面不得访问 IPC。
                    const local = security.sameOrigin(origin, originOf(config.url)) or
                        (if (self.dev_url) |u| security.sameOrigin(origin, originOf(u)) else false);
                    if (config.security.isolation and !local) {
                        log.print("[ipc] dropped isolated remote message: {s}", .{origin});
                        return;
                    }
                }
            }

            const result = args.getWebMessageAsJson();
            defer if (result.value) |p| wv2.freeCoString(p);
            const raw = result.value orelse return;
            const raw_u8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, std.mem.span(raw)) catch return;
            defer self.allocator.free(raw_u8);

            // per-message arena：命令处理期间的分配随响应发出后统一释放
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const ctx = self.makeContextWith(w, arena.allocator());
            // v0.1.11：只有声明了 capability 清单才强制（未声明保持 v0.1.7 兼容）。
            const enforce_acl = config.security.capabilities.len != 0;

            var decoded = ipc.decode(self.allocator, raw_u8) catch return;
            defer decoded.deinit();
            switch (decoded.msg) {
                .invoke => |inv| {
                    log.print("[ipc] invoke {s} (id={d}, window={d})", .{ inv.method, inv.id, w.id });

                    // 框架内置：自定义标题栏拖动（runtime_js 的 data-zilt-drag-region）
                    if (std.mem.eql(u8, inv.method, "__zilt.startDragging")) {
                        const ok = runWindowCmd(w.backend, w.id, .start_dragging);
                        const result_json = if (ok) "true" else "false";
                        const resp = ipc.encodeResolve(self.allocator, inv.id, result_json) catch return;
                        w.sendJson(resp);
                        return;
                    }

                    if (enforce_acl and !security.allowed(config.security, config.url, self.dev_url, source_url, w.label, .command, inv.method)) {
                        log.print("[acl] command '{s}' denied (window={s}, source={s})", .{ inv.method, w.label, source_url });
                        const rej = ipc.encodeReject(self.allocator, inv.id, "PermissionDenied") catch return;
                        w.sendJson(rej);
                        return;
                    }

                    const result_json: []u8 = blk: {
                        // v0.1.9–v0.1.12 框架内置命令（window.zilt.*）
                        if (builtin.dispatch(ctx, inv.method, inv.args_json)) |builtin_result| {
                            if (builtin_result) |json| break :blk json;
                        } else |err| {
                            log.print("[ipc] builtin {s} failed: {s}", .{ inv.method, @errorName(err) });
                            const rej = ipc.encodeReject(self.allocator, inv.id, @errorName(err)) catch return;
                            w.sendJson(rej);
                            return;
                        }
                        break :blk ipc.dispatch(config.commands, ctx, inv.method, inv.args_json) catch |err| {
                            log.print("[ipc] invoke {s} failed: {s}", .{ inv.method, @errorName(err) });
                            const rej = ipc.encodeReject(self.allocator, inv.id, @errorName(err)) catch return;
                            w.sendJson(rej);
                            return;
                        };
                    };
                    const resp = ipc.encodeResolve(self.allocator, inv.id, result_json) catch return;
                    w.sendJson(resp);
                },
                .event => |ev| {
                    if (enforce_acl and !security.allowed(config.security, config.url, self.dev_url, source_url, w.label, .event, ev.name)) {
                        log.print("[acl] event '{s}' denied (window={s})", .{ ev.name, w.label });
                        return;
                    }
                    const handled = ipc.dispatchEvent(config.events, ctx, ev.name, ev.payload_json);
                    if (!handled) log.print("[ipc] event '{s}' (no handler)", .{ev.name});
                },
                .ignore => {},
            }
        }

        // ---- 窗口控制 / 新窗口 / 剪贴板（v0.1.6）----

        const WindowCmdReq = struct {
            cmd: ipc.WindowCmd,
            ok: bool = false,
        };

        const SpawnReq = struct {
            opts: ipc.WindowOptions,
            id: ?u32 = null,
        };

        const ClipReq = struct {
            write: ?[]const u8 = null,
            read: bool = false,
            alloc: std.mem.Allocator = std.heap.page_allocator,
            out: ?[]u8 = null,
            ok: bool = false,
        };

        // ---- v0.1.8–v0.1.12：统一能力动作（任意线程 → UI 线程同步 marshal） ----

        const Action = union(enum) {
            clipboard_read: struct { alloc: std.mem.Allocator, format: shared_clipboard.Format, out: ?shared_clipboard.Data = null },
            clipboard_write: shared_clipboard.Data,
            start_drag: []const []const u8,
            notification_show: shared_notification.Options,
            notification_update: struct { tag: []const u8, group: ?[]const u8, progress: shared_notification.Progress },
            notification_status: struct { status: shared_notification.Status = .enabled },
            webview_request: struct { alloc: std.mem.Allocator, request: shared_webview.Request, out: ?[]u8 = null },
            eval_async: struct { script: []const u8, completion: shared_webview.Completion },
        };
        const ActionReq = struct {
            action: Action,
            err: ?anyerror = null,
        };

        fn marshalAction(backend_ptr: *anyopaque, window_id: u32, req: *ActionReq) void {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const w = self.windowById(if (window_id == 0) 1 else window_id) orelse {
                req.err = error.WindowNotFound;
                return;
            };
            if (!w.alive) {
                req.err = error.WindowClosed;
                return;
            }
            _ = win32.SendMessageW(w.hwnd, WM_ZILT_ACTION, 0, @bitCast(@intFromPtr(req)));
        }

        fn clipboardReadData(backend_ptr: *anyopaque, window_id: u32, alloc: std.mem.Allocator, format: shared_clipboard.Format) anyerror!?shared_clipboard.Data {
            var req = ActionReq{ .action = .{ .clipboard_read = .{ .alloc = alloc, .format = format } } };
            marshalAction(backend_ptr, window_id, &req);
            if (req.err) |e| return e;
            return switch (req.action) {
                .clipboard_read => |a| a.out,
                else => unreachable,
            };
        }

        fn clipboardWriteData(backend_ptr: *anyopaque, window_id: u32, data: shared_clipboard.Data) anyerror!void {
            var req = ActionReq{ .action = .{ .clipboard_write = data } };
            marshalAction(backend_ptr, window_id, &req);
            if (req.err) |e| return e;
        }

        fn startDragFiles(backend_ptr: *anyopaque, window_id: u32, files: []const []const u8) anyerror!void {
            var req = ActionReq{ .action = .{ .start_drag = files } };
            marshalAction(backend_ptr, window_id, &req);
            if (req.err) |e| return e;
        }

        fn notificationShow(backend_ptr: *anyopaque, window_id: u32, options: shared_notification.Options) anyerror!void {
            var req = ActionReq{ .action = .{ .notification_show = options } };
            marshalAction(backend_ptr, window_id, &req);
            if (req.err) |e| return e;
        }

        fn notificationUpdate(backend_ptr: *anyopaque, window_id: u32, tag: []const u8, group: ?[]const u8, progress: shared_notification.Progress) anyerror!void {
            var req = ActionReq{ .action = .{ .notification_update = .{ .tag = tag, .group = group, .progress = progress } } };
            marshalAction(backend_ptr, window_id, &req);
            if (req.err) |e| return e;
        }

        fn notificationStatus(backend_ptr: *anyopaque, window_id: u32) anyerror!shared_notification.Status {
            var req = ActionReq{ .action = .{ .notification_status = .{} } };
            marshalAction(backend_ptr, window_id, &req);
            if (req.err) |e| return e;
            return switch (req.action) {
                .notification_status => |a| a.status,
                else => unreachable,
            };
        }

        fn webviewRequestAction(backend_ptr: *anyopaque, window_id: u32, alloc: std.mem.Allocator, request: shared_webview.Request) anyerror![]u8 {
            var req = ActionReq{ .action = .{ .webview_request = .{ .alloc = alloc, .request = request } } };
            marshalAction(backend_ptr, window_id, &req);
            if (req.err) |e| return e;
            return switch (req.action) {
                .webview_request => |a| a.out orelse return error.WebViewNoResult,
                else => unreachable,
            };
        }

        fn evalAsyncAction(backend_ptr: *anyopaque, window_id: u32, script: []const u8, completion: shared_webview.Completion) anyerror!void {
            var req = ActionReq{ .action = .{ .eval_async = .{ .script = script, .completion = completion } } };
            marshalAction(backend_ptr, window_id, &req);
            if (req.err) |e| return e;
        }

        fn runAction(self: *Self, w: *Window, req: *ActionReq) void {
            switch (req.action) {
                .clipboard_read => |*a| {
                    a.out = win_clipboard.read(a.alloc, w.hwnd, a.format) catch |e| {
                        req.err = e;
                        return;
                    };
                },
                .clipboard_write => |a| {
                    win_clipboard.write(self.allocator, w.hwnd, a) catch |e| {
                        req.err = e;
                        return;
                    };
                },
                .start_drag => |a| {
                    win_drag.startDrag(self.allocator, w.hwnd, a) catch |e| {
                        req.err = e;
                        return;
                    };
                },
                .notification_show => |a| {
                    if (self.toast) |*t| {
                        t.showOptions(a) catch |e| {
                            req.err = e;
                            return;
                        };
                    } else req.err = error.NotificationNotAvailable;
                },
                .notification_update => |a| {
                    if (self.toast) |*t| {
                        const options = shared_notification.Options{
                            .title = "",
                            .body = "",
                            .tag = a.tag,
                            .group = a.group,
                            .progress = a.progress,
                        };
                        t.updateProgress(options) catch |e| {
                            req.err = e;
                            return;
                        };
                    } else req.err = error.NotificationNotAvailable;
                },
                .notification_status => |*a| {
                    if (self.toast) |*t| {
                        a.status = t.status() catch |e| {
                            req.err = e;
                            return;
                        };
                    } else req.err = error.NotificationNotAvailable;
                },
                .webview_request => |*a| {
                    const d = w.driver orelse {
                        req.err = error.WebViewNotAvailable;
                        return;
                    };
                    a.out = runWebviewAction(d, a.alloc, a.request) catch |e| {
                        req.err = e;
                        return;
                    };
                },
                .eval_async => |a| {
                    const d = w.driver orelse {
                        req.err = error.WebViewNotAvailable;
                        return;
                    };
                    d.action(.{ .eval = .{ .script = a.script } }, a.completion) catch |e| {
                        req.err = e;
                        return;
                    };
                },
            }
        }

        /// 同步返回 JSON：同步 action 的 completion 立即触发；异步 action 用
        /// 局部消息泵驱动 STA 回调（不阻塞 UI 线程，也不会死锁 COM）。
        fn runWebviewAction(d: *webview_driver.Driver, alloc: std.mem.Allocator, request: shared_webview.Request) ![]u8 {
            var wait = SyncWait{ .alloc = alloc };
            try d.action(request, .{ .context = &wait, .callback = SyncWait.callback });
            while (!wait.done) {
                var msg: win32.MSG = undefined;
                if (win32.GetMessageW(&msg, null, 0, 0) <= 0) break;
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
            if (wait.err) |e| return e;
            return wait.json orelse try alloc.dupe(u8, "null");
        }

        // ---- WebView2 driver 回调（v0.1.9/v0.1.10） ----

        fn driverEmit(context: *anyopaque, name: []const u8, payload_json: []const u8) void {
            const w: *Window = @ptrCast(@alignCast(context));
            const msg = ipc.encodeEvent(w.backend.allocator, name, payload_json) catch return;
            w.emitJsonUi(msg);
        }

        fn driverNavigation(context: *anyopaque, url: []const u8) shared_webview.NavigationPolicy {
            const w: *Window = @ptrCast(@alignCast(context));
            return switch (security.navigation(config.security, config.url, w.backend.dev_url, url)) {
                .allow => .allow,
                .system_browser => .external,
                .deny => .deny,
            };
        }

        fn driverExternal(context: *anyopaque, url: []const u8) void {
            const w: *Window = @ptrCast(@alignCast(context));
            openExternal(w.backend.allocator, url);
        }

        fn driverNewWindow(context: *anyopaque, url: []const u8) void {
            const w: *Window = @ptrCast(@alignCast(context));
            const self = w.backend;
            const label = std.fmt.allocPrint(self.allocator, "webview-{d}", .{self.next_id}) catch return;
            defer self.allocator.free(label);
            const nw = self.createWindow(.{ .title = "Zilt Window", .url = url, .label = label }) catch |err| {
                log.print("[webview] new window failed: {s}", .{@errorName(err)});
                return;
            };
            _ = win32.ShowWindow(nw.hwnd, win32.SW_SHOW);
            if (self.env != null) self.beginController(nw);
            log.print("[webview] new window #{d} -> {s}", .{ nw.id, url });
        }

        fn driverSchedule(context: *anyopaque) void {
            const w: *Window = @ptrCast(@alignCast(context));
            _ = win32.PostMessageW(w.hwnd, WM_ZILT_WAKE, 0, 0);
        }

        fn driverRecover(context: *anyopaque) void {
            const w: *Window = @ptrCast(@alignCast(context));
            const self = w.backend;
            log.print("[webview] browser process failed -> rebuild controller (window #{d})", .{w.id});
            if (w.driver) |d| d.destroy();
            w.driver = null;
            w.releaseWebViewCom();
            self.beginController(w);
        }

        // ---- 窗口状态持久化（v0.1.8） ----

        fn saveWindowState(self: *Self, w: *Window) void {
            const key = w.state_key orelse return;
            var rc: win32.RECT = undefined;
            if (win32.GetWindowRect(w.hwnd, &rc) == 0) return;
            const width = rc.right - rc.left;
            const height = rc.bottom - rc.top;
            if (width <= 0 or height <= 0) return;
            const state = app_data.State{
                .x = rc.left,
                .y = rc.top,
                .width = @intCast(width),
                .height = @intCast(height),
                .maximized = win32.IsZoomed(w.hwnd) != 0,
                .fullscreen = w.fullscreen,
            };
            app_data.save(self.allocator, config.app_id, key, state) catch |err| {
                log.print("[state] save failed: {s}", .{@errorName(err)});
                return;
            };
            log.print("[state] saved window #{d} ({s}) {d},{d} {d}x{d} max={} full={}", .{ w.id, key, state.x, state.y, state.width, state.height, state.maximized, state.fullscreen });
        }

        fn restoreWindowState(self: *Self, w: *Window) void {
            const key = w.state_key orelse return;
            const state = (app_data.load(self.allocator, config.app_id, key) catch |err| {
                log.print("[state] load failed: {s}", .{@errorName(err)});
                return;
            }) orelse return;
            if (state.width == 0 or state.height == 0) return;
            _ = win32.SetWindowPos(w.hwnd, null, state.x, state.y, @intCast(state.width), @intCast(state.height), win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
            if (state.maximized) _ = win32.ShowWindow(w.hwnd, win32.SW_MAXIMIZE);
            if (state.fullscreen) _ = self.applyWindowCmd(w, .{ .fullscreen = true });
            log.print("[state] restored window #{d} ({s}) {d},{d} {d}x{d} max={} full={}", .{ w.id, key, state.x, state.y, state.width, state.height, state.maximized, state.fullscreen });
        }

        fn saveAllStates(self: *Self) void {
            for (self.windows.items) |w| if (w.alive) self.saveWindowState(w);
        }

        // ---- WinRT Toast / OLE 拖放事件（v0.1.12） ----

        fn onToastEvent(context: ?*anyopaque, event: shared_notification.Event) void {
            const p = context orelse return;
            const self: *Self = @ptrCast(@alignCast(p));
            const payload = toastEventJson(self.allocator, event) catch return;
            defer self.allocator.free(payload);
            const msg = ipc.encodeEvent(self.allocator, "notification", payload) catch return;
            const w = self.mainWindow() orelse {
                self.allocator.free(msg);
                return;
            };
            if (win32.PostMessageW(w.hwnd, WM_ZILT_TOAST_EVENT, @intCast(msg.len), @bitCast(@intFromPtr(msg.ptr))) == 0) self.allocator.free(msg);
        }

        fn onDragEvent(context: ?*anyopaque, event: shared_drag.Event) void {
            const p = context orelse return;
            const w: *Window = @ptrCast(@alignCast(p));
            const b = w.backend;
            const files_json = std.json.Stringify.valueAlloc(b.allocator, event.files, .{}) catch return;
            defer b.allocator.free(files_json);
            const custom_json = customFormatsJson(b.allocator, event.custom) catch return;
            defer b.allocator.free(custom_json);
            const payload = std.fmt.allocPrint(b.allocator, "{{\"x\":{d},\"y\":{d},\"files\":{s},\"custom\":{s}}}", .{ event.x, event.y, files_json, custom_json }) catch return;
            defer b.allocator.free(payload);
            const name: []const u8 = switch (event.kind) {
                .enter => "dragEnter",
                .over => "dragOver",
                .leave => "dragLeave",
                .drop => "drop",
            };
            const msg = ipc.encodeEvent(b.allocator, name, payload) catch return;
            w.emitJsonUi(msg);
        }

        fn runWindowCmd(backend_ptr: *anyopaque, window_id: u32, cmd: ipc.WindowCmd) bool {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const w = self.windowById(if (window_id == 0) 1 else window_id) orelse return false;
            if (!w.alive) return false;
            var req = WindowCmdReq{ .cmd = cmd };
            _ = win32.SendMessageW(w.hwnd, WM_ZILT_WINCTL, 0, @bitCast(@intFromPtr(&req)));
            return req.ok;
        }

        fn spawnWindowFromBackend(backend_ptr: *anyopaque, opts: ipc.WindowOptions) ?u32 {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const main = self.mainWindow() orelse return null;
            var req = SpawnReq{ .opts = opts };
            _ = win32.SendMessageW(main.hwnd, WM_ZILT_NEWWIN, 0, @bitCast(@intFromPtr(&req)));
            return req.id;
        }

        fn clipboardWriteFromBackend(backend_ptr: *anyopaque, text: []const u8) bool {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const main = self.mainWindow() orelse return false;
            var req = ClipReq{ .write = text };
            _ = win32.SendMessageW(main.hwnd, WM_ZILT_CLIP, 0, @bitCast(@intFromPtr(&req)));
            return req.ok;
        }

        fn clipboardReadFromBackend(backend_ptr: *anyopaque, alloc: std.mem.Allocator) ?[]u8 {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const main = self.mainWindow() orelse return null;
            var req = ClipReq{ .read = true, .alloc = alloc };
            _ = win32.SendMessageW(main.hwnd, WM_ZILT_CLIP, 0, @bitCast(@intFromPtr(&req)));
            return req.out;
        }

        fn applyWindowCmd(self: *Self, w: *Window, cmd: ipc.WindowCmd) bool {
            switch (cmd) {
                .set_title => |t| {
                    const tw = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, t) catch return false;
                    defer self.allocator.free(tw);
                    _ = win32.SetWindowTextW(w.hwnd, tw.ptr);
                    return true;
                },
                .minimize => {
                    _ = win32.ShowWindow(w.hwnd, win32.SW_MINIMIZE);
                    return true;
                },
                .maximize => {
                    _ = win32.ShowWindow(w.hwnd, win32.SW_MAXIMIZE);
                    return true;
                },
                .restore => {
                    _ = win32.ShowWindow(w.hwnd, win32.SW_RESTORE);
                    return true;
                },
                .fullscreen => |on| {
                    self.setFullscreen(w, on);
                    return true;
                },
                .size => |sz| {
                    if (sz.width == 0 or sz.height == 0 or sz.width > 32767 or sz.height > 32767) return false;
                    var rect = win32.RECT{ .left = 0, .top = 0, .right = @intCast(sz.width), .bottom = @intCast(sz.height) };
                    _ = win32.AdjustWindowRect(&rect, @bitCast(win32.GetWindowLongW(w.hwnd, win32.GWL_STYLE)), if (w.menu != null) 1 else 0);
                    _ = win32.SetWindowPos(w.hwnd, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, win32.SWP_NOMOVE | win32.SWP_NOZORDER);
                    return true;
                },
                .position => |p| {
                    _ = win32.SetWindowPos(w.hwnd, null, p.x, p.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER);
                    return true;
                },
                .show => {
                    _ = win32.ShowWindow(w.hwnd, win32.SW_SHOW);
                    _ = win32.SetForegroundWindow(w.hwnd);
                    return true;
                },
                .hide => {
                    _ = win32.ShowWindow(w.hwnd, win32.SW_HIDE);
                    return true;
                },
                .focus => {
                    _ = win32.SetForegroundWindow(w.hwnd);
                    return true;
                },
                .close => {
                    _ = win32.DestroyWindow(w.hwnd);
                    return true;
                },
                .start_dragging => {
                    _ = win32.ReleaseCapture();
                    _ = win32.SendMessageW(w.hwnd, win32.WM_NCLBUTTONDOWN, win32.HTCAPTION, 0);
                    return true;
                },
                .always_on_top => |on| {
                    _ = win32.SetWindowPos(w.hwnd, if (on) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
                    return true;
                },
                .skip_taskbar => |skip| {
                    var ex: win32.DWORD = @bitCast(win32.GetWindowLongW(w.hwnd, win32.GWL_EXSTYLE));
                    if (skip) {
                        ex |= win32.WS_EX_TOOLWINDOW;
                    } else {
                        ex &= ~win32.WS_EX_TOOLWINDOW;
                    }
                    _ = win32.SetWindowLongW(w.hwnd, win32.GWL_EXSTYLE, @bitCast(ex));
                    _ = win32.SetWindowPos(w.hwnd, null, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED);
                    return true;
                },
            }
        }

        fn setFullscreen(self: *Self, w: *Window, on: bool) void {
            _ = self;
            if (on and !w.fullscreen) {
                w.saved_style = win32.GetWindowLongW(w.hwnd, win32.GWL_STYLE);
                _ = win32.GetWindowRect(w.hwnd, &w.saved_rect);
                _ = win32.SetWindowLongW(w.hwnd, win32.GWL_STYLE, @bitCast(win32.WS_POPUP | win32.WS_VISIBLE));
                const cx = win32.GetSystemMetrics(win32.SM_CXSCREEN);
                const cy = win32.GetSystemMetrics(win32.SM_CYSCREEN);
                _ = win32.SetWindowPos(w.hwnd, null, 0, 0, cx, cy, win32.SWP_FRAMECHANGED | win32.SWP_SHOWWINDOW);
                w.fullscreen = true;
            } else if (!on and w.fullscreen) {
                _ = win32.SetWindowLongW(w.hwnd, win32.GWL_STYLE, w.saved_style);
                _ = win32.SetWindowPos(w.hwnd, null, w.saved_rect.left, w.saved_rect.top, w.saved_rect.right - w.saved_rect.left, w.saved_rect.bottom - w.saved_rect.top, win32.SWP_FRAMECHANGED | win32.SWP_SHOWWINDOW);
                w.fullscreen = false;
            }
        }

        fn setClipboardText(self: *Self, w: *Window, text: []const u8) bool {
            const tw = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, text) catch return false;
            defer self.allocator.free(tw);
            const bytes_len: usize = (tw.len + 1) * 2; // 含 NUL 终止
            const hg = win32.GlobalAlloc(win32.GMEM_MOVEABLE, bytes_len) orelse return false;
            var owned = true;
            defer {
                if (owned) _ = win32.GlobalFree(hg);
            }

            const locked = win32.GlobalLock(hg) orelse return false;
            const dst: [*]u8 = @ptrCast(locked);
            @memcpy(dst[0..bytes_len], @as([*]const u8, @ptrCast(tw.ptr))[0..bytes_len]);
            _ = win32.GlobalUnlock(hg);

            if (win32.OpenClipboard(w.hwnd) == 0) {
                log.print("[clip] OpenClipboard failed", .{});
                return false;
            }
            defer _ = win32.CloseClipboard();
            _ = win32.EmptyClipboard();
            if (win32.SetClipboardData(win32.CF_UNICODETEXT, hg) == null) {
                log.print("[clip] SetClipboardData failed", .{});
                return false;
            }
            owned = false; // 所有权转移给系统
            log.print("[clip] wrote {d} chars", .{tw.len});
            return true;
        }

        fn getClipboardText(self: *Self, w: *Window, alloc: std.mem.Allocator) ?[]u8 {
            _ = self;
            if (win32.OpenClipboard(w.hwnd) == 0) {
                log.print("[clip] OpenClipboard(read) failed", .{});
                return null;
            }
            defer _ = win32.CloseClipboard();
            const h = win32.GetClipboardData(win32.CF_UNICODETEXT) orelse {
                log.print("[clip] no CF_UNICODETEXT", .{});
                return null;
            };
            const locked = win32.GlobalLock(h) orelse {
                log.print("[clip] GlobalLock(read) failed", .{});
                return null;
            };
            defer _ = win32.GlobalUnlock(h);
            const ptr: [*:0]const u16 = @ptrCast(@alignCast(locked));
            const span = std.mem.span(ptr);
            const out = std.unicode.utf16LeToUtf8Alloc(alloc, span) catch null;
            if (out) |o| log.print("[clip] read {d} chars", .{o.len});
            return out;
        }

        // ---- 拖放 / 深链接 / 托盘菜单 ----

        fn onDropFiles(self: *Self, w: *Window, hdrop: win32.HANDLE) void {
            const count = win32.DragQueryFileW(hdrop, 0xFFFF_FFFF, null, 0);
            var paths = self.allocator.alloc([]u8, count) catch {
                win32.DragFinish(hdrop);
                return;
            };
            var i: usize = 0;
            var built: usize = 0;
            while (i < count) : (i += 1) {
                const len = win32.DragQueryFileW(hdrop, @intCast(i), null, 0);
                const buf = self.allocator.alloc(u16, len + 1) catch continue;
                defer self.allocator.free(buf);
                const got = win32.DragQueryFileW(hdrop, @intCast(i), buf.ptr, @intCast(buf.len));
                if (got == 0) continue;
                const u8path = std.unicode.utf16LeToUtf8Alloc(self.allocator, buf[0..got]) catch continue;
                paths[built] = u8path;
                built += 1;
            }
            win32.DragFinish(hdrop);
            defer {
                for (paths[0..built]) |p| self.allocator.free(p);
                self.allocator.free(paths);
            }
            if (built == 0) return;
            log.print("[drop] {d} file(s) -> window #{d}", .{ built, w.id });
            w.emitEventPayload("dropFiles", .{ .files = paths[0..built] });
        }

        fn emitLaunch(self: *Self, launch: *deep_link.Launch) void {
            const w = self.mainWindow() orelse return;
            w.emitEventPayload("deepLink", .{ .url = launch.url, .files = launch.files });
        }

        /// 应用主题变化广播（每个窗口一条事件）。
        fn emitThemeAll(self: *Self) void {
            const theme = themeName();
            log.print("[theme] changed -> {s}", .{theme});
            for (self.windows.items) |w| {
                if (w.alive) w.emitEventPayload("windowThemeChanged", .{ .id = w.id, .theme = theme });
            }
        }

        fn emitPendingLaunch(self: *Self) void {
            if (self.launch_emitted) return;
            if (self.pending_launch) |*l| {
                if (l.isEmpty()) return;
                log.print("[deep-link] startup payload (url={}, {d} files)", .{ l.url != null, l.files.len });
                self.emitLaunch(l);
                l.deinit(self.allocator);
                self.pending_launch = null;
                self.launch_emitted = true;
            }
        }

        fn onCopyData(self: *Self, payload: []const u8) void {
            const scheme = if (config.deep_link) |dl| dl.scheme else "zilt";
            var launch = deep_link.parsePayload(self.allocator, payload, scheme) catch return;
            defer launch.deinit(self.allocator);
            if (launch.isEmpty()) {
                if (self.focusedWindow()) |w| {
                    _ = win32.ShowWindow(w.hwnd, win32.SW_RESTORE);
                    _ = win32.SetForegroundWindow(w.hwnd);
                }
                return;
            }
            log.print("[deep-link] received second-instance payload ({d} files)", .{launch.files.len});
            self.emitLaunch(&launch);
            if (self.focusedWindow()) |w| _ = win32.SetForegroundWindow(w.hwnd);
        }

        fn showTrayMenu(self: *Self, hwnd: win32.HWND) void {
            const hm = self.tray_menu orelse return;
            const items = Self.tray_menu_cfg orelse return;
            var pt: win32.POINT = undefined;
            if (win32.GetCursorPos(&pt) == 0) return;
            _ = win32.SetForegroundWindow(hwnd);
            const cmd = win32.TrackPopupMenu(hm, win32.TPM_RIGHTBUTTON | win32.TPM_RETURNCMD, pt.x, pt.y, 0, hwnd, null);
            _ = win32.PostMessageW(hwnd, win32.WM_NULL, 0, 0);
            if (cmd == 0) return;
            const menu_id: u16 = @intCast(cmd & 0xffff);
            if (menu_mod.idFromPopup(items, TRAY_MENU_BASE, menu_id)) |id| {
                log.print("[tray] menu {s}", .{id});
                if (self.mainWindow()) |w| w.emitEventPayload("trayMenu", .{ .id = id });
            }
        }

        // ---- 资产服务 ----

        fn onWebResource(self: *Self, uri_u8: []const u8, args: *wv2.ICoreWebView2WebResourceRequestedEventArgs) void {
            const env = self.env orelse return;

            const if_none_match = requestHeaderUtf8(args, self.allocator, "If-None-Match");
            defer if (if_none_match) |v| self.allocator.free(v);
            const range_header = requestHeaderUtf8(args, self.allocator, "Range");
            defer if (range_header) |v| self.allocator.free(v);

            var body: ?[]const u8 = null;
            var content_type: []const u8 = "application/octet-stream";
            var status: c_int = 404;
            var from_gz_store = false;
            var etag: ?EtagBytes = null;
            var owned: ?[]u8 = null;
            var owned_ct: ?[]u8 = null;
            defer if (owned) |o| self.allocator.free(o);
            defer if (owned_ct) |c| self.allocator.free(c);
            var range_start: u64 = 0;
            var range_end: u64 = 0;
            var range_total: u64 = 0;

            if (security.sameOrigin(uri_u8, config.url)) {
                const authority_start = (std.mem.indexOf(u8, uri_u8, "://") orelse return) + 3;
                const path_start = if (std.mem.indexOfAny(u8, uri_u8[authority_start..], "/?#")) |i| authority_start + i else uri_u8.len;
                const raw_path = uri_u8[path_start..];
                const path = asset_routes.decodePath(self.allocator, if (raw_path.len == 0 or raw_path[0] != '/') "/" else raw_path) catch return;
                defer self.allocator.free(path);
                var resource_context: u32 = 0;
                _ = args.lpVtbl.get_ResourceContext(args, &resource_context);
                var candidates = asset_routes.Candidates.init(self.allocator, path, resource_context == 1) catch return;
                defer candidates.deinit();

                if (self.dev_proxy) |base| {
                    self.serveFromProxy(base, raw_path, path, &body, &content_type, &status, &owned, &owned_ct, &etag);
                } else {
                    routes: for (candidates.paths) |candidate| {
                        const route = candidate orelse continue;
                        if (self.dev_dir) |dir| {
                            var ct: []const u8 = undefined;
                            if (self.serveFromDir(dir, route, &owned, &ct)) {
                                body = owned.?;
                                content_type = ct;
                                status = 200;
                                etag = etagOf(body.?);
                                break;
                            }
                        } else {
                            for (config.assets) |asset| {
                                if (!std.mem.eql(u8, asset.path, route)) continue;
                                switch (asset.encoding) {
                                    .identity => body = asset.content,
                                    .gzip => {
                                        body = self.assetDecompress(route, asset.content) orelse continue;
                                        from_gz_store = true;
                                    },
                                }
                                etag = etagOf(body.?);
                                content_type = contentTypeOf(route);
                                status = 200;
                                break :routes;
                            }
                        }
                    }
                }

                // ETag / 304（三种模式统一）
                if (status == 200) {
                    if (etag) |e| {
                        if (ifNoneMatchMatches(if_none_match, &e)) {
                            status = 304;
                            from_gz_store = false;
                            body = "";
                            log.print("[assets] 304 {s} (etag match)", .{path});
                        }
                    }
                }

                // Range / 206（大载荷通道；单区间）
                if (status == 200 and body != null) {
                    const total: u64 = @intCast(body.?.len);
                    switch (range_mod.parse(range_header, total)) {
                        .none => {},
                        .invalid => {
                            status = 416;
                            range_total = total;
                            body = "";
                            content_type = "text/plain; charset=utf-8";
                        },
                        .ok => |r| {
                            status = 206;
                            range_start = r.start;
                            range_end = r.end;
                            range_total = total;
                            body = body.?[@intCast(r.start)..@intCast(r.end + 1)];
                        },
                    }
                }
            }

            if (status == 200) {
                log.print("[assets] 200 {s} {d} bytes{s} <- {s}", .{ content_type, body.?.len, if (from_gz_store) " (gz-store)" else "", uri_u8 });
            } else if (status == 206) {
                log.print("[assets] 206 {s} bytes={d}-{d}/{d} <- {s}", .{ content_type, range_start, range_end, range_total, uri_u8 });
            } else if (status != 304) {
                log.print("[assets] {d} <- {s}", .{ status, uri_u8 });
                if (status != 502) content_type = "text/plain";
                body = if (status == 502) "zilt dev proxy: upstream unreachable (dev only)" else "";
            }

            const reason: []const u8 = switch (status) {
                200 => "OK",
                206 => "Partial Content",
                304 => "Not Modified",
                416 => "Range Not Satisfiable",
                502 => "Bad Gateway",
                else => "Not Found",
            };
            const reason_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, reason) catch return;
            defer self.allocator.free(reason_w);

            const headers = std.fmt.allocPrint(self.allocator, "Content-Type: {s}", .{content_type}) catch return;
            defer self.allocator.free(headers);
            const headers_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, headers) catch return;
            defer self.allocator.free(headers_w);

            const stream = streamFromBytes(body.?) orelse return;
            const stream_unknown: *com.IUnknown = @ptrCast(@alignCast(stream));
            defer _ = stream_unknown.lpVtbl.Release(stream_unknown);
            const r = env.createWebResourceResponse(stream, status, reason_w.ptr, headers_w.ptr);
            if (com.succeeded(r.hr) and r.response != null) {
                const response = r.response.?;
                defer _ = response.lpVtbl.Release(response);
                var response_headers: ?*wv2.ICoreWebView2HttpResponseHeaders = null;
                if (com.failed(response.lpVtbl.get_Headers(response, &response_headers))) return;
                const h = response_headers orelse return;
                defer _ = h.lpVtbl.Release(h);
                self.appendHeader(h, "Accept-Ranges", "bytes") catch return;
                if (etag) |e| self.appendHeader(h, "ETag", &e) catch return;
                if (status == 206 or status == 416) {
                    const value = if (status == 206)
                        std.fmt.allocPrint(self.allocator, "bytes {d}-{d}/{d}", .{range_start, range_end, range_total}) catch return
                    else
                        std.fmt.allocPrint(self.allocator, "bytes */{d}", .{range_total}) catch return;
                    defer self.allocator.free(value);
                    self.appendHeader(h, "Content-Range", value) catch return;
                }
                if (config.security.csp) |csp| self.appendHeader(h, "Content-Security-Policy", csp) catch return;
                for (config.security.headers) |header| self.appendHeader(h, header.name, header.value) catch return;
                _ = args.putResponse(response);
            } else {
                log.print("[assets] createWebResourceResponse failed hr=0x{x}", .{@as(u32, @bitCast(r.hr))});
            }
        }

        fn appendHeader(self: *Self, headers: *wv2.ICoreWebView2HttpResponseHeaders, name: []const u8, value: []const u8) !void {
            const name_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, name);
            defer self.allocator.free(name_w);
            const value_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, value);
            defer self.allocator.free(value_w);
            if (com.failed(headers.lpVtbl.AppendHeader(headers, name_w.ptr, value_w.ptr))) return error.ResponseHeaderFailed;
        }

        /// 压缩资产解压（惰性 + 进程内缓存；UI 线程独占，无锁）。
        fn assetDecompress(self: *Self, path: []const u8, gz: []const u8) ?[]const u8 {
            if (self.asset_cache.get(path)) |raw| return raw;
            const raw = flateDecompress(self.allocator, gz) catch return null;
            const key = self.allocator.dupe(u8, path) catch {
                self.allocator.free(raw);
                return null;
            };
            self.asset_cache.put(self.allocator, key, raw) catch {
                self.allocator.free(key);
                self.allocator.free(raw);
                return null;
            };
            return raw;
        }

        fn serveFromProxy(
            self: *Self,
            base: []const u8,
            path_full: []const u8,
            path: []const u8,
            body: *?[]const u8,
            content_type: *[]const u8,
            status: *c_int,
            owned: *?[]u8,
            owned_ct: *?[]u8,
            etag: *?EtagBytes,
        ) void {
            const url = joinProxyUrl(self.allocator, base, path_full) catch return;
            defer self.allocator.free(url);
            const result = self.proxyFetch(self.allocator, url, owned_ct) catch |err| {
                log.print("[proxy] GET {s} failed: {s}", .{ path_full, @errorName(err) });
                status.* = 502;
                content_type.* = "text/plain";
                body.* = "zilt dev proxy: upstream unreachable (dev only)";
                return;
            };
            owned.* = result;
            body.* = result;
            status.* = 200;
            content_type.* = if (owned_ct.*) |ct|
                (if (ct.len > 0) ct else contentTypeOf(path))
            else
                contentTypeOf(path);
            etag.* = etagOf(result);
            log.print("[proxy] GET {s} -> 200 ({s}) {d} bytes", .{ path_full, content_type.*, result.len });
        }

        fn proxyFetch(self: *Self, alloc: std.mem.Allocator, url: []const u8, out_ct: *?[]u8) ![]u8 {
            return self.proxyFetchInner(alloc, url, out_ct) catch |err| {
                log.print("[proxy] retry once after {s}", .{@errorName(err)});
                if (out_ct.*) |c| self.allocator.free(c);
                out_ct.* = null;
                self.proxyClientReset();
                return self.proxyFetchInner(alloc, url, out_ct);
            };
        }

        fn proxyClientReset(self: *Self) void {
            if (self.proxy_client) |c| {
                c.deinit();
                self.allocator.destroy(c);
                self.proxy_client = null;
            }
        }

        fn proxyFetchInner(self: *Self, alloc: std.mem.Allocator, url: []const u8, out_ct: *?[]u8) ![]u8 {
            const client = blk: {
                if (self.proxy_client) |c| break :blk c;
                const threaded = try self.allocator.create(std.Io.Threaded);
                threaded.* = .init(self.allocator, .{});
                self.proxy_threaded = threaded;
                const c = try self.allocator.create(std.http.Client);
                c.* = .{ .allocator = self.allocator, .io = threaded.io() };
                self.proxy_client = c;
                break :blk c;
            };

            const uri = try std.Uri.parse(url);
            var req = try client.request(.GET, uri, .{ .redirect_behavior = @enumFromInt(3) });
            defer req.deinit();
            try req.sendBodiless();
            var redirect_buffer: [8192]u8 = undefined;
            var response = try req.receiveHead(&redirect_buffer);

            out_ct.* = if (response.head.content_type) |ct|
                (self.allocator.dupe(u8, ct) catch null)
            else
                null;

            const decompress_buf: []u8 = switch (response.head.content_encoding) {
                .identity => &.{},
                else => self.allocator.alloc(u8, std.compress.flate.max_window_len) catch &.{},
            };
            defer if (decompress_buf.len > 0) self.allocator.free(decompress_buf);

            var transfer_buffer: [64]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buf);
            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            _ = try reader.streamRemaining(&aw.writer);
            return aw.toOwnedSlice();
        }

        fn serveFromDir(self: *Self, dir: []const u8, path: []const u8, out: *?[]u8, content_type: *[]const u8) bool {
            var rel = path;
            if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
            if (rel.len == 0) rel = "index.html";
            if (std.mem.indexOf(u8, rel, "..") != null) return false;

            const normalized = self.allocator.dupe(u8, rel) catch return false;
            for (normalized) |*c| {
                if (c.* == '/') c.* = '\\';
            }

            const full = std.fmt.allocPrint(self.allocator, "{s}\\{s}", .{ dir, normalized }) catch {
                self.allocator.free(normalized);
                return false;
            };
            defer self.allocator.free(full);
            const content = win32.readFileAlloc(self.allocator, full) orelse {
                self.allocator.free(normalized);
                return false;
            };
            self.allocator.free(normalized);
            out.* = content;
            content_type.* = contentTypeOf(rel);
            return true;
        }

        /// 释放窗口的 COM/GDI 资源（窗口关闭 / 应用退出共用；幂等）。
        fn releaseWindowCom(w: *Window) void {
            // driver.destroy 必须早于 controller.Close / 上下文释放。
            if (w.driver) |d| d.destroy();
            w.driver = null;
            if (w.drop_target) |t| t.destroy();
            w.drop_target = null;
            if (w.clipboard_listening) win_clipboard.stopListening(w.hwnd);
            w.clipboard_listening = false;
            if (w.webview) |wv| _ = wv.lpVtbl.Release(wv);
            if (w.msg_handler) |h| h.dropRef();
            if (w.res_handler) |h| h.dropRef();
            if (w.nav_handler) |h| h.dropRef();
            if (w.controller) |c| {
                _ = c.lpVtbl.Close(c);
                _ = c.lpVtbl.Release(c);
            }
            if (w.owns_icons) {
                if (w.icon_big) |ic| _ = win32.DestroyIcon(ic);
                if (w.icon_small) |ic| _ = win32.DestroyIcon(ic);
            }
            if (w.bg_brush) |br| _ = win32.DeleteObject(br);
            w.webview = null;
            w.msg_handler = null;
            w.res_handler = null;
            w.nav_handler = null;
            w.controller = null;
            w.icon_big = null;
            w.icon_small = null;
            w.owns_icons = false;
            w.bg_brush = null;
        }

        fn cleanup(self: *Self) void {
            if (self.mainWindow()) |w| _ = win32.KillTimer(w.hwnd, 1);
            if (Self.hotkey_cfg) |hks| {
                if (self.mainWindow()) |w| hotkey_mod.unregisterAll(w.hwnd, hks);
            }
            if (self.tray) |*t| _ = t.remove();
            if (self.toast) |*t| t.deinit();
            self.proxyClientReset();
            if (self.proxy_threaded) |t| {
                t.deinit();
                self.allocator.destroy(t);
                self.proxy_threaded = null;
            }
            {
                var it = self.asset_cache.iterator();
                while (it.next()) |e| {
                    self.allocator.free(e.key_ptr.*);
                    self.allocator.free(e.value_ptr.*);
                }
                self.asset_cache.deinit(self.allocator);
            }
            for (self.windows.items) |w| if (w.alive) { _ = win32.DestroyWindow(w.hwnd); };
            for (self.windows.items) |w| {
                releaseWindowCom(w);
                self.allocator.free(w.title);
                self.allocator.free(w.url);
                self.allocator.free(w.label);
                w.menu_arena.deinit();
                self.allocator.destroy(w);
            }
            self.windows.deinit(self.allocator);
            if (self.env) |e| _ = e.lpVtbl.Release(e);
            if (self.tray_menu) |hm| _ = win32.DestroyMenu(hm);
            if (self.tray_icon) |ic| _ = win32.DestroyIcon(ic);
            if (self.icon_small) |ic| _ = win32.DestroyIcon(ic);
            if (self.icon_big) |ic| _ = win32.DestroyIcon(ic);
            if (self.pending_launch) |*l| l.deinit(self.allocator);
            if (self.class_u8.len > 0) self.allocator.free(self.class_u8);
            self.allocator.free(self.class_w);
        }

        // ---- 消息循环 ----

        fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.c) win32.LRESULT {
            switch (msg) {
                win32.WM_MOVE => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            var rc: win32.RECT = undefined;
                            if (win32.GetWindowRect(hwnd, &rc) != 0) {
                                w.emitEventPayload("windowMoved", .{ .id = w.id, .x = rc.left, .y = rc.top });
                            }
                        }
                    }
                    return 0;
                },
                win32.WM_SIZE => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            w.updateBounds();
                            var rc: win32.RECT = undefined;
                            if (win32.GetClientRect(hwnd, &rc) != 0) {
                                w.emitEventPayload("windowResized", .{ .id = w.id, .width = rc.right, .height = rc.bottom });
                            }
                        }
                    }
                    return 0;
                },
                win32.WM_SETFOCUS => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| w.emitEventPayload("windowFocus", .{ .id = w.id });
                    }
                    return 0;
                },
                win32.WM_KILLFOCUS => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| w.emitEventPayload("windowBlur", .{ .id = w.id });
                    }
                    return 0;
                },
                win32.WM_GETMINMAXINFO => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (lparam != 0) {
                                const mmi: *win32.MINMAXINFO = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(@as(usize, @bitCast(lparam))))));
                                if (w.min_width) |mw| mmi.ptMinTrackSize.x = @intCast(mw);
                                if (w.min_height) |mh| mmi.ptMinTrackSize.y = @intCast(mh);
                                if (w.max_width) |mw| mmi.ptMaxTrackSize.x = @intCast(mw);
                                if (w.max_height) |mh| mmi.ptMaxTrackSize.y = @intCast(mh);
                            }
                        }
                    }
                    return 0;
                },
                win32.WM_ERASEBKGND => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (w.transparent) return 1;
                            if (w.background_color) |rgb| {
                                if (w.bg_brush == null) w.bg_brush = win32.CreateSolidBrush(colorRefOf(rgb));
                                if (w.bg_brush) |br| {
                                    var rc: win32.RECT = undefined;
                                    if (win32.GetClientRect(hwnd, &rc) != 0) {
                                        const hdc: win32.HDC = @ptrFromInt(wparam);
                                        _ = win32.FillRect(hdc, &rc, br);
                                    }
                                    return 1;
                                }
                            }
                        }
                    }
                },
                win32.WM_DPICHANGED => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            const new_dpi: u32 = @intCast(wparam & 0xffff);
                            if (lparam != 0) {
                                const rc: *const win32.RECT = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(@as(usize, @bitCast(lparam))))));
                                _ = win32.SetWindowPos(hwnd, null, rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
                            }
                            w.dpi = new_dpi;
                            w.updateBounds();
                            log.print("[window] #{d} dpi -> {d} (scale {d:.2})", .{ w.id, new_dpi, @as(f64, @floatFromInt(new_dpi)) / 96.0 });
                            w.emitEventPayload("windowScaleFactorChanged", .{
                                .id = w.id,
                                .scale_factor = @as(f64, @floatFromInt(new_dpi)) / 96.0,
                                .dpi = new_dpi,
                            });
                        }
                    }
                    return 0;
                },
                win32.WM_THEMECHANGED => {
                    if (instance) |b| b.emitThemeAll();
                    return 0;
                },
                win32.WM_SETTINGCHANGE => {
                    if (isImmersiveColorSet(lparam)) {
                        if (instance) |b| b.emitThemeAll();
                        return 0;
                    }
                },
                win32.WM_CLOSE => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (w.id == 1 and config.close_to_tray and b.tray != null and b.tray.?.active) {
                                _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
                                log.print("[tray] window hidden to tray", .{});
                                return 0;
                            }
                            if (w.close_requested_events) {
                                log.print("[window] close requested (window #{d})", .{w.id});
                                w.emitEventPayload("windowCloseRequested", .{ .id = w.id });
                                return 0; // 前端调用 windowClose 才真正销毁
                            }
                        }
                    }
                },
                win32.WM_DESTROY => {
                    log.print("[win32] WM_DESTROY (window)", .{});
                    if (instance) |b| {
                        var closed_id: u32 = 0;
                        if (b.windowOfHwnd(hwnd)) |w| {
                            // v0.1.8 状态持久化 + v0.1.9–v0.1.12 资源清理
                            b.saveWindowState(w);
                            if (w.driver) |d| d.destroy();
                            w.driver = null;
                            if (w.drop_target) |t| t.destroy();
                            w.drop_target = null;
                            if (w.clipboard_listening) win_clipboard.stopListening(w.hwnd);
                            w.clipboard_listening = false;
                            w.alive = false;
                            closed_id = w.id;
                            for (b.windows.items) |dependent| {
                                if (dependent.alive and dependent.parent_id == w.id) _ = win32.DestroyWindow(dependent.hwnd);
                            }
                            if (w.modal) {
                                if (w.parent_id) |parent_id| {
                                    if (b.windowById(parent_id)) |parent| {
                                        parent.modal_children -= 1;
                                        if (parent.alive and parent.modal_children == 0 and parent.parent_was_enabled) {
                                            _ = EnableWindow(parent.hwnd, 1);
                                            _ = win32.SetForegroundWindow(parent.hwnd);
                                        }
                                    }
                                }
                            }
                            // Attached menus are destroyed by DestroyWindow, not by COM teardown.
                            w.menu = null;
                            releaseWindowCom(w);
                        }
                        // 通知其余窗口
                        for (b.windows.items) |other| {
                            if (other.alive and other.id != closed_id) {
                                other.emitEventPayload("windowDestroyed", .{ .id = closed_id });
                            }
                        }
                        if (b.aliveCount() == 0) win32.PostQuitMessage(0);
                    }
                    return 0;
                },
                win32.WM_TIMER => {
                    if (wparam == 2) {
                        log.print("[multi] timer -> close secondary window", .{});
                        _ = win32.DestroyWindow(hwnd);
                        return 0;
                    }
                    log.print("[test] smoke timer fired (no quit) -> exit(124)", .{});
                    if (instance) |b| b.quit_code.store(124, .monotonic);
                    win32.PostQuitMessage(124);
                    return 0;
                },
                win32.WM_COMMAND => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            const mid: u16 = @intCast(wparam & 0xffff);
                            if (menu_mod.idFromPopup(w.menu_items, 0, mid)) |id| {
                                log.print("[menu] {s}", .{id});
                                w.emitEventPayload("menu", .{ .id = id });
                            }
                        }
                    }
                    return 0;
                },
                win32.WM_HOTKEY => {
                    if (instance) |b| {
                        if (Self.hotkey_cfg) |hks| {
                            if (hotkey_mod.idFromIndex(hks, @intCast(wparam))) |id| {
                                log.print("[hotkey] {s}", .{id});
                                const target = b.focusedWindow() orelse b.mainWindow();
                                if (target) |w| w.emitEventPayload("hotkey", .{ .id = id });
                            }
                        }
                    }
                    return 0;
                },
                WM_ZILT_EMIT => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            const len: usize = @intCast(wparam);
                            const ptr: [*]u8 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                            w.emitJsonUi(ptr[0..len]);
                        }
                    }
                    return 0;
                },
                WM_ZILT_NOTIFY => {
                    if (instance) |b| {
                        const ptr: [*]u8 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                        const nb = unpackNotify(ptr);
                        defer b.allocator.free(ptr[0 .. 8 + nb.title.len + nb.body.len]);
                        var sent = false;
                        if (b.toast) |*t| {
                            sent = t.send(nb.title, nb.body);
                            if (sent) log.print("[notify] sent (winrt toast)", .{});
                        }
                        if (!sent) {
                            if (b.tray) |*t| {
                                const ok = t.notify(nb.title, nb.body);
                                log.print("[notify] sent (balloon fallback, ok={})", .{ok});
                            } else {
                                log.print("[notify] dropped (no toast, no tray)", .{});
                            }
                        }
                    }
                    return 0;
                },
                WM_ZILT_TRAY => {
                    if (instance) |b| {
                        if (lparam == win32.WM_LBUTTONUP) {
                            const w = b.mainWindow() orelse return 0;
                            const visible = win32.IsWindowVisible(w.hwnd) != 0;
                            _ = win32.ShowWindow(w.hwnd, if (visible) win32.SW_HIDE else win32.SW_SHOW);
                            if (!visible) _ = win32.SetForegroundWindow(w.hwnd);
                            log.print("[tray] click -> {s}", .{if (visible) "hidden" else "shown"});
                        } else if (lparam == win32.WM_RBUTTONUP) {
                            b.showTrayMenu(hwnd);
                        }
                    }
                    return 0;
                },
                WM_ZILT_WINCTL => {
                    if (instance) |b| {
                        const raw: usize = @bitCast(lparam);
                        const req: *WindowCmdReq = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(raw))));
                        const w = b.windowOfHwnd(hwnd) orelse return 0;
                        if (w.alive) req.ok = b.applyWindowCmd(w, req.cmd);
                    }
                    return 0;
                },
                WM_ZILT_NEWWIN => {
                    if (instance) |b| {
                        const raw: usize = @bitCast(lparam);
                        const req: *SpawnReq = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(raw))));
                        const w = b.createWindow(req.opts) catch null;
                        if (w) |nw| {
                            req.id = nw.id;
                            if (req.opts.visible) _ = win32.ShowWindow(nw.hwnd, win32.SW_SHOW);
                            if (b.env != null) b.beginController(nw);
                        }
                    }
                    return 0;
                },
                WM_ZILT_CLIP => {
                    if (instance) |b| {
                        const raw: usize = @bitCast(lparam);
                        const req: *ClipReq = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(raw))));
                        const w = b.focusedWindow() orelse b.mainWindow() orelse return 0;
                        if (req.write) |text| {
                            req.ok = b.setClipboardText(w, text);
                        } else if (req.read) {
                            req.out = b.getClipboardText(w, req.alloc);
                        }
                    }
                    return 0;
                },
                WM_CLIPBOARDUPDATE => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| w.emitEventPayload("clipboardChanged", .{});
                    }
                    return 0;
                },
                WM_ZILT_WAKE => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (w.driver) |d| d.dispatchDeferred() catch |err| {
                                log.print("[webview] deferred dispatch failed: {s}", .{@errorName(err)});
                            };
                        }
                    }
                    return 0;
                },
                WM_ZILT_ACTION => {
                    if (instance) |b| {
                        const raw: usize = @bitCast(lparam);
                        const req: *ActionReq = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(raw))));
                        const w = b.windowOfHwnd(hwnd) orelse {
                            req.err = error.WindowNotFound;
                            return 0;
                        };
                        b.runAction(w, req);
                    }
                    return 0;
                },
                WM_ZILT_TOAST_EVENT => {
                    if (instance) |b| {
                        const len: usize = @intCast(wparam);
                        const ptr: [*]u8 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                        if (b.windowOfHwnd(hwnd)) |w| {
                            w.emitJsonUi(ptr[0..len]);
                        } else {
                            b.allocator.free(ptr[0..len]);
                        }
                    }
                    return 0;
                },
                win32.WM_DROPFILES => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            const hdrop: win32.HANDLE = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(wparam))));
                            b.onDropFiles(w, hdrop);
                        }
                    }
                    return 0;
                },
                win32.WM_COPYDATA => {
                    if (instance) |b| {
                        const raw: usize = @bitCast(lparam);
                        const cds: *const win32.COPYDATASTRUCT = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(raw))));
                        if (cds.lpData) |p| {
                            const bytes: [*]const u8 = @ptrCast(p);
                            b.onCopyData(bytes[0..cds.cbData]);
                        } else {
                            b.onCopyData("");
                        }
                    }
                    return 1; // WM_COPYDATA 必须返回 TRUE
                },
                else => {},
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        }

        // ---- dev 目录热重载 watcher ----

        const Watcher = struct {
            ctx: ipc.Context,
            dir: []u8,
            stop_flag: std.atomic.Value(bool) = .init(false),
            thread: ?std.Thread = null,

            fn start(allocator: std.mem.Allocator, ctx: ipc.Context, dir: []const u8) ?*Watcher {
                const w = allocator.create(Watcher) catch return null;
                w.* = .{
                    .ctx = ctx,
                    .dir = allocator.dupe(u8, dir) catch {
                        allocator.destroy(w);
                        return null;
                    },
                };
                w.thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, loop, .{w}) catch {
                    allocator.free(w.dir);
                    allocator.destroy(w);
                    return null;
                };
                return w;
            }

            fn stopJoin(self: *Watcher) void {
                self.stop_flag.store(true, .release);
                if (self.thread) |t| {
                    t.join();
                    self.thread = null;
                }
                const alloc = self.ctx.allocator;
                alloc.free(self.dir);
                alloc.destroy(self);
            }

            fn loop(self: *Watcher) void {
                var last_sig: u64 = self.signature();
                log.print("[dev] watching directory for changes", .{});
                while (!self.stop_flag.load(.acquire)) {
                    win32.Sleep(400);
                    const sig = self.signature();
                    if (sig != last_sig) {
                        last_sig = sig;
                        log.print("[dev] change detected -> emit __reload", .{});
                        self.ctx.emitNull("__reload");
                    }
                }
            }

            fn signature(self: *Watcher) u64 {
                var h = std.hash.Wyhash.init(0);
                hashDir(&h, self.dir, 0);
                return h.final();
            }

            fn hashDir(h: *std.hash.Wyhash, abs_dir: []const u8, depth: u8) void {
                if (depth > 4) return;
                const alloc = std.heap.page_allocator;
                const pattern = std.fmt.allocPrint(alloc, "{s}\\*", .{abs_dir}) catch return;
                defer alloc.free(pattern);
                const pattern_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, pattern) catch return;
                defer alloc.free(pattern_w);

                var wfd: win32.WIN32_FIND_DATAW = undefined;
                const handle = win32.FindFirstFileW(pattern_w.ptr, &wfd);
                if (handle == win32.INVALID_HANDLE_VALUE) return;
                defer _ = win32.FindClose(handle);

                while (true) {
                    const name_len = std.mem.indexOfScalar(u16, &wfd.cFileName, 0) orelse wfd.cFileName.len;
                    if (name_len > 0 and wfd.cFileName[0] != '.') {
                        if (std.unicode.utf16LeToUtf8Alloc(alloc, wfd.cFileName[0..name_len])) |name_u8| {
                            defer alloc.free(name_u8);
                            h.update(name_u8);
                            h.update(std.mem.asBytes(&wfd.ftLastWriteTime.dwLowDateTime));
                            h.update(std.mem.asBytes(&wfd.ftLastWriteTime.dwHighDateTime));
                            h.update(std.mem.asBytes(&wfd.nFileSizeLow));
                            if ((wfd.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY) != 0) {
                                const sub = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ abs_dir, name_u8 }) catch "";
                                if (sub.len > 0) {
                                    defer alloc.free(sub);
                                    hashDir(h, sub, depth + 1);
                                }
                            }
                        } else |_| {}
                    }
                    if (win32.FindNextFileW(handle, &wfd) == 0) break;
                }
            }
        };

        // ---- COM 事件处理器 ----

        /// 通用「忽略 LPCWSTR 结果」的 CompletedHandler（ExecuteScript / AddScript 共用）。
        fn IgnoreCompletedHandler(comptime iid: com.GUID) type {
            return extern struct {
                const H = @This();
                lpVtbl: *const VTable,
                refs: u32,
                window: *Window,

                pub const COM_IIDS = [_]com.GUID{iid};

                pub const VTable = extern struct {
                    QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
                    AddRef: *const fn (*anyopaque) callconv(.c) u32,
                    Release: *const fn (*anyopaque) callconv(.c) u32,
                    Invoke: *const fn (*anyopaque, HRESULT, ?[*:0]const u16) callconv(.c) HRESULT,
                };
                pub const vtable = VTable{
                    .QueryInterface = com.ComVTableMixin(H).queryInterface,
                    .AddRef = com.ComVTableMixin(H).addRef,
                    .Release = com.ComVTableMixin(H).release,
                    .Invoke = invoke,
                };

                fn create(w: *Window) !*H {
                    const h = try w.backend.allocator.create(H);
                    h.* = .{ .lpVtbl = &vtable, .refs = 1, .window = w };
                    return h;
                }
                pub fn comDestroy(self: *H) void {
                    self.window.backend.allocator.destroy(self);
                }
                pub fn dropRef(self: *H) void {
                    _ = com.ComVTableMixin(H).release(@ptrCast(self));
                }

                fn invoke(self_: *anyopaque, error_code: HRESULT, result_w: ?[*:0]const u16) callconv(.c) HRESULT {
                    _ = self_;
                    _ = result_w;
                    if (com.failed(error_code)) {
                        log.print("[zilt] completed handler failed hr=0x{x}", .{@as(u32, @bitCast(error_code))});
                    }
                    return com.S_OK;
                }
            };
        }

        /// ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler（主窗口）
        const EnvCompletedHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            backend: *Self,
            main_window: *Window,

            pub const COM_IIDS = [_]com.GUID{wv2.IID_EnvironmentCompletedHandler};

            pub const VTable = extern struct {
                QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
                AddRef: *const fn (*anyopaque) callconv(.c) u32,
                Release: *const fn (*anyopaque) callconv(.c) u32,
                Invoke: *const fn (*anyopaque, HRESULT, ?*wv2.ICoreWebView2Environment) callconv(.c) HRESULT,
            };
            pub const vtable = VTable{
                .QueryInterface = com.ComVTableMixin(EnvCompletedHandler).queryInterface,
                .AddRef = com.ComVTableMixin(EnvCompletedHandler).addRef,
                .Release = com.ComVTableMixin(EnvCompletedHandler).release,
                .Invoke = invoke,
            };

            fn create(backend: *Self, main_window: *Window) !*EnvCompletedHandler {
                const h = try backend.allocator.create(EnvCompletedHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend, .main_window = main_window };
                return h;
            }
            pub fn comDestroy(self: *EnvCompletedHandler) void {
                self.backend.allocator.destroy(self);
            }
            pub fn dropRef(self: *EnvCompletedHandler) void {
                _ = com.ComVTableMixin(EnvCompletedHandler).release(@ptrCast(self));
            }

            fn invoke(self_: *anyopaque, error_code: HRESULT, env: ?*wv2.ICoreWebView2Environment) callconv(.c) HRESULT {
                const self: *EnvCompletedHandler = @ptrCast(@alignCast(self_));
                const backend = self.backend;
                if (com.failed(error_code) or env == null) {
                    log.print("[fatal] Environment create failed hr=0x{x}", .{@as(u32, @bitCast(error_code))});
                    win32.PostQuitMessage(2);
                    return com.S_OK;
                }
                backend.env = env;
                _ = env.?.lpVtbl.AddRef(env.?);
                log.print("[webview] environment created", .{});
                backend.beginController(self.main_window);
                return com.S_OK;
            }
        };

        /// ICoreWebView2CreateCoreWebView2ControllerCompletedHandler
        const ControllerCompletedHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            backend: *Self,
            window: *Window,

            pub const COM_IIDS = [_]com.GUID{wv2.IID_ControllerCompletedHandler};

            pub const VTable = extern struct {
                QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
                AddRef: *const fn (*anyopaque) callconv(.c) u32,
                Release: *const fn (*anyopaque) callconv(.c) u32,
                Invoke: *const fn (*anyopaque, HRESULT, ?*wv2.ICoreWebView2Controller) callconv(.c) HRESULT,
            };
            pub const vtable = VTable{
                .QueryInterface = com.ComVTableMixin(ControllerCompletedHandler).queryInterface,
                .AddRef = com.ComVTableMixin(ControllerCompletedHandler).addRef,
                .Release = com.ComVTableMixin(ControllerCompletedHandler).release,
                .Invoke = invoke,
            };

            fn create(backend: *Self, window: *Window) !*ControllerCompletedHandler {
                const h = try backend.allocator.create(ControllerCompletedHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend, .window = window };
                return h;
            }
            pub fn comDestroy(self: *ControllerCompletedHandler) void {
                self.backend.allocator.destroy(self);
            }
            pub fn dropRef(self: *ControllerCompletedHandler) void {
                _ = com.ComVTableMixin(ControllerCompletedHandler).release(@ptrCast(self));
            }

            fn invoke(self_: *anyopaque, error_code: HRESULT, controller: ?*wv2.ICoreWebView2Controller) callconv(.c) HRESULT {
                const self: *ControllerCompletedHandler = @ptrCast(@alignCast(self_));
                if (com.failed(error_code) or controller == null) {
                    // 窗口在异步 controller 创建期间被关闭属于正常生命周期
                    // （如前端 create→close 的冒烟），不得终止整个应用。
                    if (!self.window.alive or self.window.hwnd == null) {
                        log.print("[webview] controller callback for closed window ignored hr=0x{x}", .{@as(u32, @bitCast(error_code))});
                        return com.S_OK;
                    }
                    log.print("[fatal] Controller create failed hr=0x{x}", .{@as(u32, @bitCast(error_code))});
                    self.backend.quit_code.store(4, .monotonic);
                    win32.PostQuitMessage(4);
                    return com.S_OK;
                }
                if (!self.window.alive or self.window.hwnd == null) {
                    _ = controller.?.lpVtbl.Release(controller.?);
                    log.print("[webview] controller ready for closed window -> released", .{});
                    return com.S_OK;
                }
                self.backend.onControllerReady(self.window, controller.?);
                return com.S_OK;
            }
        };

        /// ICoreWebView2WebMessageReceivedEventHandler
        const MessageHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            window: *Window,

            pub const COM_IIDS = [_]com.GUID{wv2.IID_WebMessageReceivedEventHandler};

            pub const VTable = extern struct {
                QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
                AddRef: *const fn (*anyopaque) callconv(.c) u32,
                Release: *const fn (*anyopaque) callconv(.c) u32,
                Invoke: *const fn (*anyopaque, ?*wv2.ICoreWebView2, ?*wv2.ICoreWebView2WebMessageReceivedEventArgs) callconv(.c) HRESULT,
            };
            pub const vtable = VTable{
                .QueryInterface = com.ComVTableMixin(MessageHandler).queryInterface,
                .AddRef = com.ComVTableMixin(MessageHandler).addRef,
                .Release = com.ComVTableMixin(MessageHandler).release,
                .Invoke = invoke,
            };

            fn create(w: *Window) !*MessageHandler {
                const h = try w.backend.allocator.create(MessageHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .window = w };
                return h;
            }
            pub fn comDestroy(self: *MessageHandler) void {
                self.window.backend.allocator.destroy(self);
            }
            pub fn dropRef(self: *MessageHandler) void {
                _ = com.ComVTableMixin(MessageHandler).release(@ptrCast(self));
            }

            fn invoke(self_: *anyopaque, sender: ?*wv2.ICoreWebView2, args: ?*wv2.ICoreWebView2WebMessageReceivedEventArgs) callconv(.c) HRESULT {
                _ = sender;
                const self: *MessageHandler = @ptrCast(@alignCast(self_));
                const a = args orelse return com.E_POINTER;
                onWebMessage(self.window, a);
                return com.S_OK;
            }
        };

        /// ICoreWebView2WebResourceRequestedEventHandler
        const WebResourceHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            window: *Window,

            pub const COM_IIDS = [_]com.GUID{wv2.IID_WebResourceRequestedEventHandler};

            pub const VTable = extern struct {
                QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
                AddRef: *const fn (*anyopaque) callconv(.c) u32,
                Release: *const fn (*anyopaque) callconv(.c) u32,
                Invoke: *const fn (*anyopaque, ?*wv2.ICoreWebView2, ?*wv2.ICoreWebView2WebResourceRequestedEventArgs) callconv(.c) HRESULT,
            };
            pub const vtable = VTable{
                .QueryInterface = com.ComVTableMixin(WebResourceHandler).queryInterface,
                .AddRef = com.ComVTableMixin(WebResourceHandler).addRef,
                .Release = com.ComVTableMixin(WebResourceHandler).release,
                .Invoke = invoke,
            };

            fn create(w: *Window) !*WebResourceHandler {
                const h = try w.backend.allocator.create(WebResourceHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .window = w };
                return h;
            }
            pub fn comDestroy(self: *WebResourceHandler) void {
                self.window.backend.allocator.destroy(self);
            }
            pub fn dropRef(self: *WebResourceHandler) void {
                _ = com.ComVTableMixin(WebResourceHandler).release(@ptrCast(self));
            }

            fn invoke(self_: *anyopaque, sender: ?*wv2.ICoreWebView2, args: ?*wv2.ICoreWebView2WebResourceRequestedEventArgs) callconv(.c) HRESULT {
                _ = sender;
                const self: *WebResourceHandler = @ptrCast(@alignCast(self_));
                const a = args orelse return com.E_POINTER;

                const req_result = a.getRequest();
                if (com.failed(req_result.hr) or req_result.request == null) return com.E_FAIL;
                const request = req_result.request.?;

                const uri_result = request.getUri();
                if (com.failed(uri_result.hr) or uri_result.value == null) return com.E_FAIL;
                defer wv2.freeCoString(uri_result.value);

                const uri_u8 = std.unicode.utf16LeToUtf8Alloc(self.window.backend.allocator, std.mem.span(uri_result.value.?)) catch return com.E_FAIL;
                defer self.window.backend.allocator.free(uri_u8);

                self.window.backend.onWebResource(uri_u8, a);
                return com.S_OK;
            }
        };

        /// ICoreWebView2NavigationCompletedEventHandler
        const NavCompletedHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            window: *Window,

            pub const COM_IIDS = [_]com.GUID{wv2.IID_NavigationCompletedEventHandler};

            pub const VTable = extern struct {
                QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
                AddRef: *const fn (*anyopaque) callconv(.c) u32,
                Release: *const fn (*anyopaque) callconv(.c) u32,
                Invoke: *const fn (*anyopaque, ?*wv2.ICoreWebView2, ?*wv2.ICoreWebView2NavigationCompletedEventArgs) callconv(.c) HRESULT,
            };
            pub const vtable = VTable{
                .QueryInterface = com.ComVTableMixin(NavCompletedHandler).queryInterface,
                .AddRef = com.ComVTableMixin(NavCompletedHandler).addRef,
                .Release = com.ComVTableMixin(NavCompletedHandler).release,
                .Invoke = invoke,
            };

            fn create(w: *Window) !*NavCompletedHandler {
                const h = try w.backend.allocator.create(NavCompletedHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .window = w };
                return h;
            }
            pub fn comDestroy(self: *NavCompletedHandler) void {
                self.window.backend.allocator.destroy(self);
            }
            pub fn dropRef(self: *NavCompletedHandler) void {
                _ = com.ComVTableMixin(NavCompletedHandler).release(@ptrCast(self));
            }

            fn invoke(self_: *anyopaque, sender: ?*wv2.ICoreWebView2, args: ?*wv2.ICoreWebView2NavigationCompletedEventArgs) callconv(.c) HRESULT {
                _ = sender;
                const self: *NavCompletedHandler = @ptrCast(@alignCast(self_));
                const a = args orelse return com.E_POINTER;
                const success = a.getIsSuccess();
                if (com.failed(success.hr)) return com.E_FAIL;
                if (success.value != 0) {
                    log.print("[webview] navigation completed: SUCCESS (window #{d})", .{self.window.id});
                    if (self.window.id == 1) self.window.backend.emitPendingLaunch();
                } else {
                    const err = a.getWebErrorStatus();
                    log.print("[webview] navigation completed: FAILED (web_error_status={d})", .{err.value});
                }
                return com.S_OK;
            }
        };
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "originOf: 提取 scheme://host[:port]" {
    try testing.expectEqualStrings("https://zilt.app", originOf("https://zilt.app/index.html"));
    try testing.expectEqualStrings("https://zilt.app", originOf("https://zilt.app"));
    try testing.expectEqualStrings("https://zilt.app", originOf("https://zilt.app/"));
    try testing.expectEqualStrings("http://localhost:5173", originOf("http://localhost:5173/@vite/client"));
    try testing.expectEqualStrings("weird", originOf("weird")); // 无 :// → 原样
}

test "contentTypeOf: 扩展名映射" {
    try testing.expectEqualStrings("text/html; charset=utf-8", contentTypeOf("/index.html"));
    try testing.expectEqualStrings("text/javascript; charset=utf-8", contentTypeOf("/app.js"));
    try testing.expectEqualStrings("text/css; charset=utf-8", contentTypeOf("styles.CSS"));
    try testing.expectEqualStrings("application/json", contentTypeOf("a/b/data.json"));
    try testing.expectEqualStrings("application/octet-stream", contentTypeOf("/x.bin"));
    try testing.expectEqualStrings("application/octet-stream", contentTypeOf("/noext"));
}

test "windowStyleFor: 装饰/可缩放/可见组合" {
    const def = windowStyleFor(.{});
    try testing.expect((def & win32.WS_OVERLAPPEDWINDOW) != 0);
    try testing.expect((def & win32.WS_VISIBLE) != 0);
    try testing.expect((def & win32.WS_THICKFRAME) != 0);

    const hidden = windowStyleFor(.{ .visible = false });
    try testing.expect((hidden & win32.WS_VISIBLE) == 0);

    const fixed = windowStyleFor(.{ .resizable = false });
    try testing.expect((fixed & win32.WS_THICKFRAME) == 0);
    try testing.expect((fixed & win32.WS_MAXIMIZEBOX) == 0);

    const frameless = windowStyleFor(.{ .decorations = false });
    try testing.expect((frameless & win32.WS_CAPTION) == 0);
    try testing.expect((frameless & win32.WS_POPUP) != 0);
    try testing.expect((frameless & win32.WS_THICKFRAME) != 0); // 无边框仍可缩放
}

test "windowExStyleFor: 任务栏隐藏 / 透明" {
    try testing.expectEqual(@as(win32.DWORD, 0), windowExStyleFor(.{}));
    try testing.expect((windowExStyleFor(.{ .skip_taskbar = true }) & win32.WS_EX_TOOLWINDOW) != 0);
    try testing.expect((windowExStyleFor(.{ .transparent = true }) & win32.WS_EX_NOREDIRECTIONBITMAP) != 0);
}

test "colorRefOf: 0xRRGGBB -> 0x00BBGGRR" {
    try testing.expectEqual(@as(win32.DWORD, 0x00332211), colorRefOf(0x112233));
    try testing.expectEqual(@as(win32.DWORD, 0x00000000), colorRefOf(0x000000));
    try testing.expectEqual(@as(win32.DWORD, 0x00ffffff), colorRefOf(0xffffff));
}

// ---------------------------------------------------------------------------
// 系统能力：通知打包 / 当前 exe 路径 / 更新器编排
// ---------------------------------------------------------------------------

/// 通知 marshal 载荷：[u32 tlen][u32 blen][title][body]（UTF-8）。
pub fn packNotify(alloc: std.mem.Allocator, title: []const u8, body: []const u8) ?[]u8 {
    const buf = alloc.alloc(u8, 8 + title.len + body.len) catch return null;
    std.mem.writeInt(u32, buf[0..4], @intCast(title.len), .little);
    std.mem.writeInt(u32, buf[4..8], @intCast(body.len), .little);
    @memcpy(buf[8 .. 8 + title.len], title);
    @memcpy(buf[8 + title.len ..], body);
    return buf;
}

pub const NotifyPair = struct { title: []const u8, body: []const u8 };

/// 解包通知载荷（返回的切片指向 buf）。
pub fn unpackNotify(buf: [*]u8) NotifyPair {
    const tlen: usize = std.mem.readInt(u32, buf[0..4], .little);
    const blen: usize = std.mem.readInt(u32, buf[4..8], .little);
    return .{ .title = buf[8 .. 8 + tlen], .body = buf[8 + tlen .. 8 + tlen + blen] };
}

/// 当前运行 exe 的完整路径（UTF-8）。
pub fn currentExePath(alloc: std.mem.Allocator) ![]u8 {
    var buf: [1024]u16 = undefined;
    const n = win32.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.ModuleFileNameFailed;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]);
}

/// 组装更新器环境（公钥/URL 均可 env 覆盖 + HTTP fetcher）。file 级：泛型于 Backend 实例。
fn buildUpdaterEnv(self: anytype, uc: anytype) !updater.Env {
    var pk: [32]u8 = undefined;
    var pk_from_env = false;
    if (win32.getEnvUtf8(self.allocator, "ZILT_UPDATE_PK")) |hex| {
        defer self.allocator.free(hex);
        if (hex.len == 64) {
            _ = std.fmt.hexToBytes(&pk, hex) catch return error.InvalidPublicKey;
            pk_from_env = true;
        }
    }
    if (!pk_from_env) {
        if (uc.public_key_hex.len != 64) return error.InvalidPublicKey;
        _ = std.fmt.hexToBytes(&pk, uc.public_key_hex) catch return error.InvalidPublicKey;
    }

    var manifest_url: []const u8 = uc.manifest_url;
    if (win32.getEnvUtf8(self.allocator, "ZILT_UPDATE_URL")) |u| {
        self.updater_url_override = u;
        manifest_url = u;
    }

    return .{
        .manifest_url = manifest_url,
        .public_key = pk,
        .current_version = uc.current_version,
        .exe_path = try currentExePath(self.allocator),
        .exe_name = uc.exe_name,
        .fetcher = .{ .ctx = self, .fetchFn = httpFetch },
    };
}

/// 重启以应用已暂存的更新：分离接力进程（同 exe --zilt-restart）等本进程退出后拉起新版。
fn restartToApplyImpl(self: anytype) void {
    const alloc = self.allocator;
    const exe = currentExePath(alloc) catch {
        log.print("[updater] restart: currentExePath failed", .{});
        return;
    };
    defer alloc.free(exe);
    const args = std.fmt.allocPrint(alloc, "--zilt-restart \"{s}\"", .{exe}) catch return;
    defer alloc.free(args);
    if (win32.spawnDetached(exe, args) == null) {
        log.print("[updater] restart: spawn helper failed", .{});
        return;
    }
    log.print("[updater] restart helper spawned -> quit(0)", .{});
    self.quit_code.store(0, .monotonic);
    win32.PostQuitMessage(0);
}

/// 差分更新路径（v0.1.5）：校验基线 → 下载/验签补丁 → 应用 → 复核全量 sha256+签名 → 暂存。
fn tryPatchUpdate(self: anytype, p: *const updater.PatchInfo, m: *const updater.Manifest, env: *const updater.Env) ?[]u8 {
    const alloc = self.allocator;
    log.print("[updater] patch path: {s} -> {s}", .{ p.from, m.version });

    const exe_path = currentExePath(alloc) catch return null;
    defer alloc.free(exe_path);
    const current = win32.readFileAlloc(alloc, exe_path) orelse return null;
    defer alloc.free(current);

    const cur_hex = updater.sha256Hex(alloc, current) catch return null;
    defer alloc.free(cur_hex);
    if (!std.ascii.eqlIgnoreCase(cur_hex, p.from_sha256)) {
        log.print("[updater] patch base mismatch -> full download", .{});
        return null;
    }

    const patch_bytes = env.fetcher.fetchFn(env.fetcher.ctx, alloc, p.url) catch return null;
    defer alloc.free(patch_bytes);
    const patch_hex = updater.sha256Hex(alloc, patch_bytes) catch return null;
    defer alloc.free(patch_hex);
    if (!std.ascii.eqlIgnoreCase(patch_hex, p.sha256)) {
        log.print("[updater] patch sha256 mismatch", .{});
        return null;
    }
    updater.verifyArtifact(patch_bytes, p.signature, env.public_key) catch return null;

    const new_bytes = patch.applyPatch(alloc, current, patch_bytes) catch |err| {
        log.print("[updater] patch apply failed: {s}", .{@errorName(err)});
        return null;
    };
    defer alloc.free(new_bytes);

    const new_hex = updater.sha256Hex(alloc, new_bytes) catch return null;
    defer alloc.free(new_hex);
    if (!std.ascii.eqlIgnoreCase(new_hex, m.sha256)) {
        log.print("[updater] patched result sha256 != manifest -> full download", .{});
        return null;
    }
    updater.verifyArtifact(new_bytes, m.signature, env.public_key) catch return null;

    const out = alloc.dupe(u8, new_bytes) catch return null;
    updater.stageBytes(alloc, exe_path, out) catch {
        alloc.free(out);
        return null;
    };
    log.print("[updater] patched & staged ok ({d} -> {d} bytes)", .{ current.len, new_bytes.len });
    return out;
}

/// HTTP 下载（std.http.Client；每次调用独立 Threaded Io，更新流程低频可接受）。
fn httpFetch(backend_ptr: *anyopaque, alloc: std.mem.Allocator, url: []const u8) anyerror![]u8 {
    _ = backend_ptr;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = alloc, .io = threaded.io() };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });
    if (result.status != .ok) {
        log.print("[updater] http {s} -> status {d}", .{ url, @intFromEnum(result.status) });
        return error.HttpRequestFailed;
    }
    return aw.toOwnedSlice();
}

/// 更新流程（后台线程）：检查 → 下载 → 验签 → 提取替换 → 事件 + 日志。
fn updaterFlow(self: anytype) void {
    const env = self.updater_env orelse return;
    const ctx = self.makeContext(); // emit 用 msg_allocator，线程安全

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const m = updater.checkForUpdate(arena.allocator(), env.fetcher, env.manifest_url, env.current_version) catch |err| {
        log.print("[updater] check failed: {s}", .{@errorName(err)});
        ctx.emit("updaterFailed", .{ .stage = "check", .err = @errorName(err) });
        return;
    } orelse {
        log.print("[updater] up to date ({s})", .{env.current_version});
        return;
    };
    log.print("[updater] update available: {s} (current {s})", .{ m.version, env.current_version });
    ctx.emit("updateInfo", .{ .version = m.version, .notes = m.notes });

    var artifact: ?[]u8 = null;
    var staged_by_patch = false;
    if (m.patch) |*p| {
        if (std.mem.eql(u8, p.from, env.current_version)) {
            if (tryPatchUpdate(self, p, &m, &env)) |_| {
                artifact = self.allocator.alloc(u8, 0) catch null;
                staged_by_patch = true;
            } else {
                log.print("[updater] patch path failed -> full download fallback", .{});
            }
        } else {
            log.print("[updater] patch base {s} != current {s} -> full download", .{ p.from, env.current_version });
        }
    }
    if (artifact == null) {
        artifact = updater.downloadAndVerify(self.allocator, env.fetcher, m, env.public_key) catch |err| {
            log.print("[updater] download/verify failed: {s}", .{@errorName(err)});
            ctx.emit("updaterFailed", .{ .stage = "download", .err = @errorName(err) });
            return;
        };
        log.print("[updater] artifact verified ({d} bytes, sha256+ed25519)", .{artifact.?.len});
        updater.stageUpdate(self.allocator, env.exe_path, env.exe_name, artifact.?) catch |err| {
            log.print("[updater] stage failed: {s}", .{@errorName(err)});
            ctx.emit("updaterFailed", .{ .stage = "stage", .err = @errorName(err) });
            return;
        };
    }
    defer if (artifact) |a| self.allocator.free(a);
    log.print("[updater] staged ✓ {s} — restart to apply", .{m.version});
    ctx.emit("updateStaged", .{ .version = m.version });
    if (@TypeOf(self.*).update_cfg != null and @TypeOf(self.*).update_cfg.?.auto_restart) {
        restartToApplyImpl(self);
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "packNotify/unpackNotify: 往返 + 边界" {
    const alloc = testing.allocator;
    const packed_msg = packNotify(alloc, "标题", "body ✓") orelse return error.TestUnexpectedResult;
    defer alloc.free(packed_msg);

    const nb = unpackNotify(packed_msg.ptr);
    try testing.expectEqualStrings("标题", nb.title);
    try testing.expectEqualStrings("body ✓", nb.body);
    try testing.expectEqual(@as(usize, 8 + 6 + 8), packed_msg.len);
}

test "currentExePath: 返回非空且以 .exe 结尾" {
    const p = try currentExePath(testing.allocator);
    defer testing.allocator.free(p);
    try testing.expect(p.len > 4);
    try testing.expect(std.mem.endsWith(u8, p, ".exe") or std.mem.endsWith(u8, p, ".EXE"));
}

test "acceptsGzip: 常见头形态 + q=0 拒绝" {
    try testing.expect(!acceptsGzip(null));
    try testing.expect(!acceptsGzip(""));
    try testing.expect(acceptsGzip("gzip, deflate, br, zstd"));
    try testing.expect(acceptsGzip("deflate, gzip"));
    try testing.expect(acceptsGzip("GZIP"));
    try testing.expect(acceptsGzip("gzip;q=0.5, br"));
    try testing.expect(acceptsGzip("br;q=1.0, gzip"));
    try testing.expect(!acceptsGzip("deflate"));
    try testing.expect(!acceptsGzip("br, zstd"));
    try testing.expect(!acceptsGzip("gzip;q=0"));
    try testing.expect(!acceptsGzip("gzip;q=0.000, br;q=1.0"));
    try testing.expect(!acceptsGzip("GZIP ; Q=0"));
}

test "etagOf: 强 ETag（定长/引号/确定性/区分度）" {
    const e1 = etagOf("hello");
    const e2 = etagOf("hello");
    const e3 = etagOf("hello!");
    try testing.expectEqual(@as(usize, 18), e1.len);
    try testing.expectEqual(@as(u8, '"'), e1[0]);
    try testing.expectEqual(@as(u8, '"'), e1[17]);
    try testing.expectEqualSlices(u8, &e1, &e2);
    try testing.expect(!std.mem.eql(u8, &e1, &e3));
    for (e1[1..17]) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "ifNoneMatchMatches: 列表 / * / W/ 前缀 / 非匹配" {
    const e = etagOf("hello");
    try testing.expect(!ifNoneMatchMatches(null, &e));
    try testing.expect(!ifNoneMatchMatches("", &e));
    try testing.expect(ifNoneMatchMatches(&e, &e));
    try testing.expect(ifNoneMatchMatches(" \"zzzz\",  W/\"aaaa\" , W/", &e) == false);
    try testing.expect(ifNoneMatchMatches("*", &e));
    try testing.expect(ifNoneMatchMatches("\"aaaa\", \"bbbb\", ", &e) == false);
    const list = try std.fmt.allocPrint(testing.allocator, "\"aaaa\", {s}, \"cccc\"", .{&e});
    defer testing.allocator.free(list);
    try testing.expect(ifNoneMatchMatches(list, &e));
    const weak = try std.fmt.allocPrint(testing.allocator, "W/{s}", .{&e});
    defer testing.allocator.free(weak);
    try testing.expect(ifNoneMatchMatches(weak, &e));
}

test "joinProxyUrl: 去尾斜杠 + 保留 query" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const up1 = try joinProxyUrl(alloc, "http://localhost:5173", "/index.html?t=123");
    try testing.expectEqualStrings("http://localhost:5173/index.html?t=123", up1);
    const up2 = try joinProxyUrl(alloc, "http://localhost:5173/", "/");
    try testing.expectEqualStrings("http://localhost:5173/", up2);
    const up3 = try joinProxyUrl(alloc, "http://localhost:5173///", "/src/main.ts?import");
    try testing.expectEqualStrings("http://localhost:5173/src/main.ts?import", up3);
}

// ---- v0.1.9–v0.1.12 接线层测试 ----

test "toastEventJson: activation includes arguments and user input" {
    const inputs = [_]shared_notification.UserInput{.{ .id = "note", .value = "hello" }};
    const json = try toastEventJson(testing.allocator, .{
        .tag = "job-1",
        .group = "jobs",
        .kind = .{ .activated = .{ .arguments = "open", .user_input = &inputs } },
    });
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("job-1", obj.get("tag").?.string);
    try testing.expectEqualStrings("jobs", obj.get("group").?.string);
    const event = obj.get("event").?.object;
    try testing.expectEqualStrings("activated", event.get("kind").?.string);
    try testing.expectEqualStrings("open", event.get("arguments").?.string);
    try testing.expectEqual(@as(usize, 1), event.get("user_input").?.array.items.len);
    try testing.expectEqualStrings("hello", event.get("user_input").?.array.items[0].object.get("value").?.string);
}

test "toastEventJson: dismissal and failure keep their payloads" {
    const dismissed = try toastEventJson(testing.allocator, .{ .kind = .{ .dismissed = .user_canceled } });
    defer testing.allocator.free(dismissed);
    const d = try std.json.parseFromSlice(std.json.Value, testing.allocator, dismissed, .{});
    defer d.deinit();
    try testing.expectEqualStrings("null", @tagName(std.meta.activeTag(d.value.object.get("tag").?)));
    const event = d.value.object.get("event").?.object;
    try testing.expectEqualStrings("dismissed", event.get("kind").?.string);
    try testing.expectEqualStrings("user_canceled", event.get("reason").?.string);
    const failed = try toastEventJson(testing.allocator, .{ .kind = .{ .failed = -2147024809 } });
    defer testing.allocator.free(failed);
    const f = try std.json.parseFromSlice(std.json.Value, testing.allocator, failed, .{});
    defer f.deinit();
    try testing.expectEqualStrings("failed", f.value.object.get("event").?.object.get("kind").?.string);
}

test "customFormatsJson reports names and bounded lengths" {
    const formats = [_]shared_drag.CustomFormat{
        .{ .name = "ZiltDemoFormat", .data = "abc" },
        .{ .name = "Second", .data = "" },
    };
    const json = try customFormatsJson(testing.allocator, &formats);
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try testing.expectEqualStrings("ZiltDemoFormat", parsed.value.array.items[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 3), parsed.value.array.items[0].object.get("bytes").?.integer);
}

test "SyncWait completion copies JSON and propagates errors" {
    var wait = SyncWait{ .alloc = testing.allocator };
    SyncWait.callback(&wait, "{\"factor\":1}");
    try testing.expect(wait.done);
    try testing.expect(wait.err == null);
    try testing.expectEqualStrings("{\"factor\":1}", wait.json.?);
    testing.allocator.free(wait.json.?);
    var failed = SyncWait{ .alloc = testing.allocator };
    SyncWait.callback(&failed, error.JavaScriptException);
    try testing.expect(failed.done);
    try testing.expectEqual(error.JavaScriptException, failed.err.?);
    try testing.expect(failed.json == null);
}
