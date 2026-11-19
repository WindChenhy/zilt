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
const iso_mod = @import("../../isolation.zig");
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
const menu_runtime = @import("menu_runtime.zig");
const win_taskbar = @import("taskbar.zig");
const win_sysinfo = @import("sysinfo.zig");
const winhttp = @import("winhttp.zig");
const net_mod = @import("../../net.zig");
const sys_integration = @import("system_integration.zig");
const shared_system = @import("../../system_api.zig");
const shared_menu_model = @import("../../menu_model.zig");
const accel_mod = @import("../../accel.zig");
const shell_mod = @import("../../shell.zig");
const autostart_mod = @import("../../autostart.zig");
const theme_mod = @import("../../theme.zig");
const shared_taskbar = @import("../../taskbar.zig");
const shared_sysinfo = @import("../../sysinfo.zig");
const power = @import("../../power.zig");
const shared_store = @import("../../store.zig");
const fs_api_mod = @import("../../fs_api.zig");
const shared_services = @import("../../services.zig");
const shared_ws = @import("../../ws.zig");
const win_sqlite = @import("sqlite.zig");
const headless = @import("headless.zig");
const hotkey_mod = @import("hotkey.zig");
const dialog_mod = @import("dialog.zig");
const dlgx = @import("dialog_ext.zig");
const range_mod = @import("range.zig");
const icon_mod = @import("icon.zig");
const deep_link = @import("deep_link.zig");
const security = @import("../../security.zig");
const asset_routes = @import("../../asset_routes.zig");
const inflate = @import("../../inflate.zig");
const protocol = @import("../../protocol.zig");
const png_mod = @import("../../png.zig");
const dpapi_mod = @import("dpapi.zig");
const app_data = @import("app_data.zig");
const builtin = @import("../../builtin.zig");
const shared_webview = @import("../../webview.zig");
const shared_clipboard = @import("../../clipboard.zig");
const shared_drag = @import("../../drag_drop.zig");
const shared_notification = @import("../../notification.zig");
const environment = @import("../../environment.zig");
const webview_driver = @import("webview_driver.zig");
const dcomp = @import("dcomp.zig");
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
/// 托盘回调里用到、但本项目 win32.zig 尚未声明的鼠标消息（v0.1.13）
const WM_LBUTTONDBLCLK: win32.UINT = 0x0203;
const WM_MBUTTONUP: win32.UINT = 0x0207;
const WM_ZILT_ACTION: win32.UINT = win32.WM_APP + 7; // 统一能力动作 marshal（UI 线程）
const WM_ZILT_WAKE: win32.UINT = win32.WM_APP + 8; // WebView driver 延迟派发
const WM_ZILT_BINARY: win32.UINT = win32.WM_APP + 20; // v0.3.6：SharedBuffer post 延迟（WebMessageReceived 重入规避；12-15 已占）
const WM_ZILT_TOAST_EVENT: win32.UINT = win32.WM_APP + 9; // WinRT 线程 → UI 线程
const WM_ZILT_HTTP: win32.UINT = win32.WM_APP + 10; // HTTP 后台线程 → UI 线程
const WM_ZILT_WS: win32.UINT = win32.WM_APP + 11; // WebSocket 读线程 → UI 线程
const WM_ZILT_PROC: win32.UINT = win32.WM_APP + 12; // 子进程 worker → UI 线程
const WM_ZILT_EVAL: win32.UINT = win32.WM_APP + 13; // 子 webview eval（延后到回调外执行）
const WM_ZILT_HTTP_CHUNK: win32.UINT = win32.WM_APP + 14; // v0.1.20 流式下载分块
const WM_ZILT_HTTP_PROGRESS: win32.UINT = win32.WM_APP + 21; // v0.3.8 E6 上传进度（20=binary 已占）
var iso_seed: std.atomic.Value(u64) = .init(0x49534F); // v0.3.10 isolation 会话随机种子
const WM_ZILT_FSWATCH: win32.UINT = win32.WM_APP + 15; // v0.1.22 目录监视事件
const WM_ZILT_FSCHUNK: win32.UINT = win32.WM_APP + 16; // v0.1.22 文件流式读取分块
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

/// v0.2.0：平台后端标识（见 platform/interface.zig 契约）。
/// 取名 platform_name 而非 name：backend.zig 里有大量名为 name 的局部量，
/// 容器级 `name` 会被 Zig 判为 shadow 冲突。
pub const platform_name = "windows";

pub fn run(comptime config: Config) !void {
    try security.validateHeaders(config.security);
    const B = Backend(config);
    log.initFileLog("zilt.log");
    const alloc = std.heap.page_allocator;

    // v0.1.17：headless/server 模式（ZILT_HEADLESS=1）——无窗口跑 HTTP 服务，
    // 资产 + /zilt/ipc 与 GUI 同一分发链路。在 COM/窗口初始化之前分流。
    if (win32.getEnvUtf8(alloc, "ZILT_HEADLESS")) |h| {
        defer alloc.free(h);
        if (std.mem.eql(u8, h, "1")) {
            return headless.run(config, alloc);
        }
    }

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
    backend.ui_thread_id.store(win32.GetCurrentThreadId(), .release);
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

    // v0.1.23：覆盖式标题栏测试钩子（冒烟用：ZILT_SMOKE_OVERLAY=1 让主窗口走 overlay，
    // 断言 innerHeight == outerHeight）。生产行为只由 config.titlebar_overlay 决定。
    const overlay_hook = blk: {
        const v = win32.getEnvUtf8(alloc, "ZILT_SMOKE_OVERLAY") orelse break :blk false;
        defer alloc.free(v);
        break :blk v.len > 0 and v[0] == '1';
    };

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
        .titlebar_overlay = config.titlebar_overlay or overlay_hook,
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
    // v0.3.11 E2：E2E/debug 钩子——env 覆盖 fixed 目录（缺失时不回退 Evergreen，
    // findRuntimeWithOptions 直接报错——负向 E2E 断言该行为）
    var loader_opts = config.environment;
    if (win32.getEnvUtf8(alloc, "ZILT_WEBVIEW2_BROWSER_DIR")) |v| {
        loader_opts.browser_directory = v;
        log.print("[loader] browser_directory overridden by env (fixed E2E)", .{});
    }
    var runtime = try loader.findRuntimeWithOptions(alloc, loader_opts);
    // v0.1.17：存一份到 backend —— 数据分区要按需另建 Environment
    backend.runtime = runtime;
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
    var eo = config.environment;
    // v0.1.17：WebDriver 自动化需要给 WebView2 附加 --remote-debugging-port。
    // 环境变量覆盖（不重编译）：ZILT_WEBVIEW2_ARGS="--remote-debugging-port=9223"
    if (win32.getEnvUtf8(alloc, "ZILT_WEBVIEW2_ARGS")) |browser_args| {
        eo.additional_browser_arguments = browser_args;
        log.print("[env] ZILT_WEBVIEW2_ARGS={s}", .{browser_args});
    }
    // v0.3.2：真 scheme 注册需要 options 对象（EnvironmentOptions4）
    const need_env_opts = eo.language != null or eo.proxy_server != null or eo.additional_browser_arguments != null or
        eo.channel != .evergreen or eo.browser_directory != null or !eo.background_throttling or
        config.protocols.len > 0;
    if (need_env_opts) {
        env_opts = env_options.EnvironmentOptions.create(alloc, eo) catch |err| blk: {
            log.print("[env] environment options unavailable: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (env_opts != null) log.print("[env] options applied (lang={s}, proxy={s}, args={s})", .{
            if (eo.language) |v| v else "-",
            if (eo.proxy_server) |v| v else "-",
            if (eo.additional_browser_arguments) |v| v else "-",
        });
        // v0.3.2：真 scheme 注册（`media://localhost/…`）；老运行时 QI 失败仅日志，
        // 路径式 `/__proto/<name>/` 仍然可用。
        if (env_opts) |opts_ptr| {
            if (config.protocols.len > 0) {
                const iso_extra: []const []const u8 = if (config.isolation != null) &.{"ziltiso"} else &.{};
                opts_ptr.setCustomSchemes(alloc, config.protocols, originOf(config.url), iso_extra) catch |err| {
                    log.print("[scheme] register failed: {s} (path-style protocols still work)", .{@errorName(err)});
                };
            }
        }
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

    // 更新健康确认（v0.1.15）：新版本跑满 10s 才删除 .zilt-old 备份，
    // 避免「刚启动就删掉回滚凭据」导致崩溃后无法恢复。
    if (config.update != null) {
        _ = win32.SetTimer(main.hwnd, 3, 10_000, null);
        log.print("[updater] health timer armed (10s)", .{});
    }

    // v0.3.2：注册会话通知（锁屏/解锁事件）。失败仅日志（事件面降级，不致命）。
    if (backend.mainWindow()) |mw| {
        if (wtsRegister(mw.hwnd)) |_| {
            log.print("[session] WTS notifications registered", .{});
        } else |err| {
            log.print("[session] WTS registration unavailable: {s}", .{@errorName(err)});
        }
    }

    // 消息泵
    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) > 0) {
        // v0.1.18：菜单加速键（ACCEL 表）优先于页面内的按键处理
        if (backend.translateAccel(&msg)) continue;
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
// v0.3.2：WTS 会话通知（wtsapi32；锁屏/解锁事件）
// ---------------------------------------------------------------------------

extern "wtsapi32" fn WTSRegisterSessionNotification(hwnd: win32.HWND, flags: win32.DWORD) callconv(.winapi) win32.BOOL;
extern "wtsapi32" fn WTSUnRegisterSessionNotification(hwnd: win32.HWND) callconv(.winapi) win32.BOOL;

fn wtsRegister(hwnd: win32.HWND) !void {
    if (WTSRegisterSessionNotification(hwnd, win32.NOTIFY_FOR_THIS_SESSION) == 0) return error.WtsRegisterFailed;
}

fn wtsUnregister(hwnd: win32.HWND) void {
    _ = WTSUnRegisterSessionNotification(hwnd);
}

// ---------------------------------------------------------------------------
// v0.3.3：窗口体验包 II 辅助（每按钮状态 / mask / 按键绑定与 Escape ACCEL / overflow）
// ---------------------------------------------------------------------------

/// v0.3.3：resize 拖拽边名 → HT 代码（内容区拉伸窗口）。
fn edgeHtFromName(name: []const u8) ?win32.LRESULT {
    const map = [_]struct { n: []const u8, ht: win32.LRESULT }{
        .{ .n = "n", .ht = win32.HTTOP },
        .{ .n = "s", .ht = win32.HTBOTTOM },
        .{ .n = "e", .ht = win32.HTRIGHT },
        .{ .n = "w", .ht = win32.HTLEFT },
        .{ .n = "ne", .ht = win32.HTTOPRIGHT },
        .{ .n = "nw", .ht = win32.HTTOPLEFT },
        .{ .n = "se", .ht = win32.HTBOTTOMRIGHT },
        .{ .n = "sw", .ht = win32.HTBOTTOMLEFT },
    };
    for (map) |m| {
        if (std.mem.eql(u8, m.n, name)) return m.ht;
    }
    return null;
}

/// 窗口级按键绑定 ACCEL id 基址（与菜单 id 空间隔离；菜单 id 从 1 起）
const KEY_BINDING_ACCEL_BASE: u16 = 0xE000;
/// hide_on_escape 的专用 ACCEL id
const ESCAPE_ACCEL_ID: u16 = 0xF000;
/// windowMoved 去抖定时器 id（避开 smoke=1 / updater health=3）
const MOVE_DEBOUNCE_TIMER_ID: usize = 5;

/// 读窗口现有 ACCEL 表内容（TranslateAccelerator 只查不改 → 复制后重建）。
fn copyAccelEntries(haccel: win32.HACCEL, out: *std.ArrayListUnmanaged(win32.ACCEL)) void {
    var count: c_int = win32.CopyAcceleratorTableW(haccel, null, 0);
    if (count <= 0) return;
    const buf = std.heap.page_allocator.alloc(win32.ACCEL, @intCast(count)) catch return;
    defer std.heap.page_allocator.free(buf);
    count = win32.CopyAcceleratorTableW(haccel, buf.ptr, count);
    if (count > 0) out.appendSlice(std.heap.page_allocator, buf[0..@intCast(count)]) catch {};
}

/// ACCEL 列表建表（空表返回 null = HACCEL 的 null）。
fn buildAccelTable(entries: []const win32.ACCEL) win32.HACCEL {
    if (entries.len == 0) return null;
    return win32.CreateAcceleratorTableW(@constCast(entries.ptr), @intCast(entries.len));
}

/// 窗口级按键绑定 → 与既有（菜单）accel 合并（accel.zig 解析，失败跳过该项）。
fn mergeKeyBindingAccel(existing: win32.HACCEL, bindings: []const Config.Hotkey) win32.HACCEL {
    var entries: std.ArrayListUnmanaged(win32.ACCEL) = .empty;
    defer entries.deinit(std.heap.page_allocator);
    if (existing) |h| copyAccelEntries(h, &entries);
    for (bindings) |kb| {
        // Hotkey 模型 = key + 显式修饰符（与 config.hotkeys 同构）
        const vk = accel_mod.vkFromName(kb.key) orelse continue;
        var f: u8 = win32.FVIRTKEY | win32.FNOINVERT;
        if (kb.ctrl) f |= win32.FCONTROL;
        if (kb.alt) f |= win32.FALT;
        if (kb.shift) f |= win32.FSHIFT;
        const idx: u16 = @intCast(entries.items.len);
        entries.append(std.heap.page_allocator, .{
            .fVirt = f,
            .key = vk,
            .cmd = KEY_BINDING_ACCEL_BASE + idx,
        }) catch break;
    }
    return buildAccelTable(entries.items);
}

/// Escape 隐藏：给窗口 ACCEL 表追加 VK_ESCAPE 项（id 0xF000）。
fn appendEscapeAccel(existing: win32.HACCEL) win32.HACCEL {
    var entries: std.ArrayListUnmanaged(win32.ACCEL) = .empty;
    defer entries.deinit(std.heap.page_allocator);
    if (existing) |h| copyAccelEntries(h, &entries);
    entries.append(std.heap.page_allocator, .{
        .fVirt = win32.FVIRTKEY | win32.FNOINVERT,
        .key = 0x1B, // VK_ESCAPE
        .cmd = ESCAPE_ACCEL_ID,
    }) catch return existing;
    return buildAccelTable(entries.items);
}

/// 每按钮状态：系统菜单项灰化/恢复（SC_CLOSE/SC_MINIMIZE/SC_MAXIMIZE）。
fn applyButtonStates(hwnd: win32.HWND, closable: ?bool, minimizable: ?bool, maximizable: ?bool) void {
    const menu = win32.GetSystemMenu(hwnd, 0) orelse return;
    const pairs = [_]struct { cmd: win32.DWORD, enabled: ?bool }{
        .{ .cmd = win32.SC_CLOSE, .enabled = closable },
        .{ .cmd = win32.SC_MINIMIZE, .enabled = minimizable },
        .{ .cmd = win32.SC_MAXIMIZE, .enabled = maximizable },
    };
    for (pairs) |pair| {
        const enabled = pair.enabled orelse continue;
        const flags: win32.DWORD = if (enabled) win32.MF_BYCOMMAND | win32.MF_ENABLED else win32.MF_BYCOMMAND | win32.MF_GRAYED;
        _ = win32.EnableMenuItem(menu, pair.cmd, flags);
    }
}

/// 窗口矩形夹取到最近显示器工作区（preventOverflow）。返回夹取后的位置。
fn clampRectToWorkArea(x: c_int, y: c_int, cx: c_int, cy: c_int) ?struct { x: c_int, y: c_int } {
    const pt = win32.POINT{ .x = x + @divTrunc(cx, 2), .y = y + @divTrunc(cy, 2) };
    const hmon = win32.MonitorFromPoint(pt, win32.MONITOR_DEFAULTTONEAREST) orelse return null;
    var mi = win_sysinfo.MONITORINFOEXW{
        .cbSize = @sizeOf(win_sysinfo.MONITORINFOEXW),
        .rcMonitor = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .rcWork = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .dwFlags = 0,
        .szDevice = std.mem.zeroes([32]u16),
    };
    if (win_sysinfo.GetMonitorInfoW(@ptrCast(hmon), &mi) == 0) return null;
    const work = mi.rcWork;
    const max_x = @max(work.left, work.right - cx);
    const max_y = @max(work.top, work.bottom - cy);
    return .{ .x = @min(@max(x, work.left), max_x), .y = @min(@max(y, work.top), max_y) };
}

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

/// v0.2.0：MIME 映射移到 asset_routes（Linux 后端共用），此处保留薄别名。
pub const contentTypeOf = asset_routes.contentTypeOf;

fn clampIconPx(metric: i32, fallback: u32) u32 {
    if (metric <= 0 or metric > 256) return fallback;
    return @intCast(metric);
}

/// 窗口样式（纯函数，单测覆盖）。
fn windowStyleFor(opts: ipc.WindowOptions) win32.DWORD {
    var style: win32.DWORD = if (opts.decorations and !opts.titlebar_overlay)
        win32.WS_OVERLAPPEDWINDOW
    else
        win32.WS_POPUP | win32.WS_SYSMENU | win32.WS_MINIMIZEBOX | win32.WS_MAXIMIZEBOX;

    if (!opts.resizable) {
        style &= ~(win32.WS_THICKFRAME | win32.WS_MAXIMIZEBOX);
    } else if (!opts.decorations or opts.titlebar_overlay) {
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

// ---- v0.1.18：窗口精细控制辅助 ----

const LWA_ALPHA: win32.DWORD = 0x00000002;

fn boolStr(v: bool) []const u8 {
    return if (v) "true" else "false";
}

/// 进程命令的授权资源名：basename 去掉 .exe（"C:////x////git.exe" → "git"）。
fn procBaseName(arg: []const u8) []const u8 {
    const base = std.fs.path.basename(arg);
    if (std.mem.endsWith(u8, base, ".exe") or std.mem.endsWith(u8, base, ".EXE")) return base[0 .. base.len - 4];
    return base;
}

/// 判断窗口类名是否原生编辑控件（Edit / RichEdit20W 等）。
fn isEditClass(cls_utf16: []const u16) bool {
    const name = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, cls_utf16) catch return false;
    defer std.heap.page_allocator.free(name);
    return std.mem.eql(u8, name, "Edit") or std.mem.startsWith(u8, name, "RichEdit");
}

// ---- v0.1.19：文件系统辅助（fs 全量操作） ----

/// FILETIME（1601 起 100ns）→ Unix 毫秒。
fn fileTimeToUnixMs(ft: win32.FILETIME) i64 {
    const v = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    if (v == 0) return 0;
    const ms: i64 = @intCast(v / 10_000);
    return ms - 11_644_473_600_000;
}

/// 逐段创建目录（PowerShell 风格 mkdir -p）。
fn mkdirAllPath(alloc: std.mem.Allocator, path: []const u8) bool {
    if (path.len == 0) return false;
    const buf = alloc.dupe(u8, path) catch return false;
    defer alloc.free(buf);
    var start: usize = 0;
    // 跳过盘符（C:）与 UNC 前缀
    if (buf.len >= 2 and buf[1] == ':') start = 2;
    var i = start;
    while (i < buf.len) : (i += 1) {
        if (buf[i] != '\\' or i == start) continue;
        if (i + 1 >= buf.len) break;
        const cut = i;
        const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, buf[0..cut]) catch return false;
        defer alloc.free(w);
        _ = win32.CreateDirectoryW(w.ptr, null);
    }
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, buf) catch return false;
    defer alloc.free(w);
    if (win32.CreateDirectoryW(w.ptr, null) != 0) return true;
    return win32.GetLastError() == win32.ERROR_ALREADY_EXISTS;
}

/// 递归删除（文件或目录树）。
fn deleteTree(alloc: std.mem.Allocator, path: []const u8) bool {
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(w);
    if (win32.DeleteFileW(w.ptr) != 0) return true;

    const pattern = std.fmt.allocPrint(alloc, "{s}\\*", .{path}) catch return false;
    defer alloc.free(pattern);
    const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, pattern) catch return false;
    defer alloc.free(pw);

    var fd: win32.WIN32_FIND_DATAW = undefined;
    const h = win32.FindFirstFileW(pw.ptr, &fd);
    if (h == win32.INVALID_HANDLE_VALUE) return win32.RemoveDirectoryW(w.ptr) != 0;
    defer _ = win32.FindClose(h);

    var ok = true;
    while (true) {
        const name = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.sliceTo(&fd.cFileName, 0)) catch {
            ok = false;
            break;
        };
        defer alloc.free(name);
        if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
            const child = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ path, name }) catch {
                ok = false;
                break;
            };
            defer alloc.free(child);
            if (fd.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0) {
                if (!deleteTree(alloc, child)) ok = false;
            } else {
                const cw = std.unicode.utf8ToUtf16LeAllocZ(alloc, child) catch {
                    ok = false;
                    break;
                };
                defer alloc.free(cw);
                if (win32.DeleteFileW(cw.ptr) == 0) ok = false;
            }
        }
        if (win32.FindNextFileW(h, &fd) == 0) break;
    }
    if (!ok) return false;
    return win32.RemoveDirectoryW(w.ptr) != 0;
}

/// exe 所在目录（fs scope = exe）。
fn exeDirAlloc(alloc: std.mem.Allocator) ?[]u8 {
    var buf: [1024]u16 = @splat(0);
    const n = win32.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0) return null;
    const path = std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch return null;
    defer alloc.free(path);
    const idx = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return null;
    return alloc.dupe(u8, path[0..idx]) catch null;
}

/// 文件大小（不存在/是目录返回 null）。
fn fileSizeOf(alloc: std.mem.Allocator, path: []const u8) ?u64 {
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return null;
    defer alloc.free(w);
    var data: win32.WIN32_FILE_ATTRIBUTE_DATA = std.mem.zeroes(win32.WIN32_FILE_ATTRIBUTE_DATA);
    if (win32.GetFileAttributesExW(w.ptr, 0, &data) == 0) return null;
    if (data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0) return null;
    return (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow;
}

/// 目录列表 JSON：[{name,dir,size,modified}]
fn listDirJson(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');

    const pattern = try std.fmt.allocPrint(alloc, "{s}\\*", .{path});
    defer alloc.free(pattern);
    const pw = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pattern);
    defer alloc.free(pw);

    var fd: win32.WIN32_FIND_DATAW = undefined;
    const h = win32.FindFirstFileW(pw.ptr, &fd);
    if (h != win32.INVALID_HANDLE_VALUE) {
        defer _ = win32.FindClose(h);
        var first = true;
        while (true) {
            const name = try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.sliceTo(&fd.cFileName, 0));
            defer alloc.free(name);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const is_dir = fd.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0;
                const size: u64 = if (is_dir) 0 else (@as(u64, fd.nFileSizeHigh) << 32) | fd.nFileSizeLow;
                const modified = fileTimeToUnixMs(fd.ftLastWriteTime);
                if (!first) try out.append(alloc, ',');
                first = false;
                const name_json = try std.json.Stringify.valueAlloc(alloc, name, .{});
                defer alloc.free(name_json);
                try out.print(alloc, "{{\"name\":{s},\"dir\":{s},\"size\":{d},\"modified\":{d}}}", .{
                    name_json, if (is_dir) "true" else "false", size, modified,
                });
            }
            if (win32.FindNextFileW(h, &fd) == 0) break;
        }
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}

/// 单文件/目录 stat JSON。
fn statJson(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return null;
    defer alloc.free(w);
    var data: win32.WIN32_FILE_ATTRIBUTE_DATA = std.mem.zeroes(win32.WIN32_FILE_ATTRIBUTE_DATA);
    if (win32.GetFileAttributesExW(w.ptr, 0, &data) == 0) return null;
    const is_dir = data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0;
    const size: u64 = if (is_dir) 0 else (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow;
    return std.fmt.allocPrint(alloc,
        "{{\"dir\":{s},\"size\":{d},\"modified\":{d},\"created\":{d},\"attributes\":{d}}}",
        .{ if (is_dir) "true" else "false", size, fileTimeToUnixMs(data.ftLastWriteTime), fileTimeToUnixMs(data.ftCreationTime), data.dwFileAttributes },
    ) catch null;
}

/// 0 视为「清除约束」（JSON 里省略字段 = null = 不改）。
fn nonZero(v: ?u32) ?u32 {
    const x = v orelse return null;
    return if (x == 0) null else x;
}

/// 光标种类 → 系统光标句柄（LoadCursorW 使用系统共享光标，无需销毁）。
fn cursorHandle(kind: ipc.CursorKind) win32.HCURSOR {
    const id: usize = switch (kind) {
        .default, .arrow => win32.IDC_ARROW,
        .ibeam => win32.IDC_IBEAM,
        .crosshair => win32.IDC_CROSS,
        .hand => win32.IDC_HAND,
        .wait => win32.IDC_WAIT,
        .help => win32.IDC_HELP,
        .not_allowed => win32.IDC_NO,
        .size_ns => win32.IDC_SIZENS,
        .size_ew => win32.IDC_SIZEWE,
        .size_nwse => win32.IDC_SIZENWSE,
        .size_nesw => win32.IDC_SIZENESW,
        .move => win32.IDC_SIZEALL,
        .up_arrow => win32.IDC_UPARROW,
    };
    return win32.LoadCursorW(null, @ptrFromInt(id));
}

/// 窗口当前所在显示器的矩形（虚拟屏坐标）；失败返回 null。
fn currentMonitorRect(hwnd: win32.HWND) ?win32.RECT {
    const mon = win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse return null;
    var mi = win32.MONITORINFO{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .rcWork = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .dwFlags = 0,
    };
    if (win32.GetMonitorInfoW(mon, &mi) == 0) return null;
    return mi.rcMonitor;
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

/// v0.3.8 B8：读取协议请求的 body——WebView2 对带 body 的请求**不回传
/// Content-Length 头**，但 `ICoreWebView2WebResourceRequest::get_Content`
/// （IStream）拿得到完整请求体（Wails PR#6326 核实同款行为与修复方式；
/// 此前「POST body 不可读」限制即源于把 ContentLength=0 当真）。
/// IStream 生命周期限于 WebResourceRequested 回调内 → 同步读完
/// （默认 10MB 上限，超限返回 null 并记日志）。无 body（GET 等）返回 null。
/// IStream 在 webview2.zig 是 opaque → 局部 vtable 直调（slot3=Read，
/// 同 runBinaryPost 的 Write 用法）。
fn readRequestBody(alloc: std.mem.Allocator, req: *wv2.ICoreWebView2WebResourceRequest) ?[]u8 {
    var stream: ?*wv2.IStream = null;
    if (com.failed(req.lpVtbl.get_Content(req, &stream)) or stream == null) return null;
    const StreamVTable = extern struct {
        QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) com.HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
        Read: *const fn (*anyopaque, [*]u8, u32, ?*u32) callconv(.c) com.HRESULT,
        Write: *const fn (*anyopaque, [*]const u8, u32, ?*u32) callconv(.c) com.HRESULT,
    };
    const obj: *anyopaque = @ptrCast(@alignCast(stream.?));
    const vtbl: *const StreamVTable = @as(*const *const StreamVTable, @ptrCast(@alignCast(obj))).*;
    defer _ = vtbl.Release(obj);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        var got: u32 = 0;
        const hr = vtbl.Read(obj, &buf, buf.len, &got);
        if (com.failed(hr)) break;
        if (got == 0) break; // 流末尾
        if (out.items.len + got > proto_body_max) {
            log.print("[proto] request body exceeds {d}MB limit — dropped", .{proto_body_max / (1024 * 1024)});
            out.deinit(alloc);
            return null;
        }
        out.appendSlice(alloc, buf[0..got]) catch {
            out.deinit(alloc);
            return null;
        };
    }
    return out.toOwnedSlice(alloc) catch null;
}

/// 协议请求 body 上限（B8：同步读的防御边界；需求更大的场景走 zilt.http）。
const proto_body_max: usize = 10 * 1024 * 1024;

// ---------------------------------------------------------------------------
// 资产服务纯函数（Phase C；单测覆盖）
// ---------------------------------------------------------------------------

/// v0.2.0：gzip 解压统一到 inflate.zig（Linux 后端共用，避免第三份实现）。
const flateDecompress = inflate.gunzip;

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

/// 运行时注册的全局快捷键（v0.1.13）。sys_id 是 RegisterHotKey 的 id，
/// 从 0x8000 起分配，避免与编译期 config.hotkeys（0..n）冲突。
pub const RuntimeHotkey = struct {
    id: []const u8,
    accel_text: []const u8,
    vk: u8,
    mods: u32,
    sys_id: u32,
};

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
            /// v0.3.14：初始缩放（controller 就绪后应用一次；null = 不设置）
            zoom: ?f64 = null,
            icon_big: win32.HICON = null,
            icon_small: win32.HICON = null,
            owns_icons: bool = false,
            bg_brush: win32.HBRUSH = null,
            dpi: u32 = 96,
            // ---- v0.1.9–v0.1.12 ----
            driver: ?*webview_driver.Driver = null,
            drop_target: ?*win_drag.DropTarget = null,
            clipboard_listening: bool = false,
            // ---- v0.1.16：单窗口多 WebView（附加子 webview；主 webview 不动）----
            child_webviews: std.ArrayListUnmanaged(*ChildWebview) = .empty,
            next_child_webview_id: u32 = 1,
            // ---- v0.1.18：窗口精细控制 ----
            cursor: win32.HCURSOR = null,
            cursor_hidden: bool = false,
            ignore_cursor: bool = false,
            content_protected: bool = false,
            focusable: bool = true,
            always_on_bottom: bool = false,
            accel: win32.HACCEL = null,
            /// v0.1.23：本窗口专用代理（非 null 时使用独立 Environment + profile）
            proxy: ?[]u8 = null,
            /// v0.1.23：独立 Environment（proxy 窗口专用，窗口销毁时 Release）
            own_env: ?*wv2.ICoreWebView2Environment = null,
            /// v0.1.23：覆盖式标题栏（客户区 = 整个窗口，自绘标题栏）
            overlay: bool = false,
            /// v0.1.24：本窗口 User-Agent（覆盖 config.webview.settings.user_agent）
            user_agent: ?[]u8 = null,
            /// v0.3.2：无痕窗口（InPrivate controller：Cookie/存储不落盘）
            incognito: bool = false,
            // ---- v0.3.3：窗口体验包 II ----
            /// 失焦自动隐藏（托盘弹窗类窗口；WM_ACTIVATE WA_INACTIVE）
            hide_on_focus_lost: bool = false,
            /// Escape 隐藏（窗口 ACCEL 表专用 id ESCAPE_ACCEL_ID）
            hide_on_escape: bool = false,
            /// 窗口位置夹取在最近显示器工作区内（WM_WINDOWPOSCHANGING）
            prevent_overflow: bool = false,
            /// 标题栏双击行为（false=禁用最大化切换；null/true=默认切换）
            titlebar_double_click: ?bool = null,
            /// windowMoved 去抖毫秒（>0 拖动中合并、WM_TIMER 补发终值）
            move_debounce_ms: u32 = 0,
            move_timer_armed: bool = false,
            /// 窗口级按键绑定（accel id 0xE000+i → windowKeyBinding 事件）
            key_bindings: []const Config.Hotkey = &.{},
            /// 托盘附着窗口（label 匹配 config.tray.attach_window → 托盘点击切换）
            tray_attached: bool = false,
            /// v0.3.12 A11：组合模式（创建请求 + 就绪状态——Controller 缺位时
            /// bounds/zoom 请求降级，DComp 视觉树接管渲染与输入转发）
            composition_requested: bool = false,
            composition: ?*CompositionState = null,
            menu_bitmaps: std.ArrayListUnmanaged(win32.HBITMAP) = .empty,

            fn updateBounds(self: *Window) void {
                const controller = self.controller orelse return;
                var rc: win32.RECT = undefined;
                if (win32.GetClientRect(self.hwnd, &rc) == 0) return;
                _ = controller.putBounds(.{ .left = 0, .top = 0, .right = rc.right, .bottom = rc.bottom });
            }

            /// UI 线程便捷事件：序列化 payload 并直接投递（菜单/快捷键/更新流程用）。
            /// v0.1.20：内置事件（trayMenu/menu/hotkey/deepLink/clipboardChanged/
            /// windowCloseRequested/windowResized 等）同时分发到应用 events 命名空间——
            /// Zig 侧声明同名 pub fn 即可订阅（与 JS 侧 window.zilt.on 对齐）。
            /// Zig 分发不受前端 capability 约束（应用内部代码）；处理器在 UI 线程
            /// 同步执行，须保持轻量。无匹配处理器时仅一次名称比较，无额外开销。
            fn emitEventPayload(self: *Window, name: []const u8, payload: anytype) void {
                if (!self.alive) return;
                const b = self.backend;
                const payload_json = std.json.Stringify.valueAlloc(b.allocator, payload, .{}) catch return;
                defer b.allocator.free(payload_json);
                // v0.3.14 G6：bool 返回的 windowCloseRequested 钩子已在关闭链路
                // 先决（closeRequestCancelled），此处跳过重复派发；其余事件照常。
                const skip_dispatch = comptime ipc.closeRequestHooked(config.events);
                if (!skip_dispatch or !std.mem.eql(u8, name, "windowCloseRequested")) {
                    _ = ipc.dispatchEvent(config.events, b.makeContextWith(self, b.allocator), name, payload_json);
                }
                // v0.1.11：声明了 capability 清单时，Zig→JS 事件同样受
                // receive_events 约束（框架内部 "__" 事件不受限）。
                if (config.security.capabilities.len != 0 and !std.mem.startsWith(u8, name, "__") and
                    !security.allowed(config.security, config.url, b.dev_url, config.url, self.label, .receive_event, name)) return;
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
        /// v0.1.17：WebView2 运行时（数据分区要另建 Environment 时复用）
        runtime: ?loader.Runtime = null,
        /// v0.1.17：已创建的分区 Environment（key = 分区名，值 = env 引用）。
        /// 同名分区复用同一 Environment → 同一 partition 的多个 webview 共享存储。
        partitions: std.ArrayListUnmanaged(PartitionEnv) = .empty,
        tray_menu: ?win32.HMENU = null,
        icon_big: win32.HICON = null,
        icon_small: win32.HICON = null,
        tray_icon: win32.HICON = null,
        tray: ?tray_mod.Tray = null,
        /// v0.1.13：托盘右键菜单的运行时模型（支持增删/勾选/禁用）
        menu_state: ?shared_menu_model.Model = null,
        tray_popup: ?menu_runtime.Built = null,
        /// v0.1.18：托盘 hover 状态（TrackMouseEvent 只需登记一次）
        tray_hovering: bool = false,
        tray_click_left: shared_system.ClickAction = .toggle_window,
        tray_click_middle: shared_system.ClickAction = .none,
        tray_click_double: shared_system.ClickAction = .toggle_window,
        /// v0.1.13：任务栏 ITaskbarList3（惰性创建）
        taskbar_list: ?win_taskbar.Taskbar = null,
        /// v0.1.13：运行时注册的全局快捷键（与编译期 config.hotkeys 的 id 空间分离）
        runtime_hotkeys: std.ArrayListUnmanaged(RuntimeHotkey) = .empty,
        next_runtime_hotkey_id: u32 = 0x8000,
        /// v0.1.16：KV 存储与受限 fs 的根目录（%LOCALAPPDATA%\<app_id>）
        storage_root: ?[]u8 = null,
        store: ?shared_store.Store = null,
        /// v0.1.16：应用服务注册表（生命周期由框架驱动，状态暴露给 JS）
        services: ?shared_services.Registry = null,
        /// v0.1.16：活跃 WebSocket 连接（仅 UI 线程读写；读线程只发事件不碰容器）
        ws_conns: std.ArrayListUnmanaged(*WsConn) = .empty,
        /// v0.1.20：wss 连接（WinHTTP WebSocket）
        wss_conns: std.ArrayListUnmanaged(*WssConn) = .empty,
        /// v0.1.16：子 webview 专用窗口类名（懒注册）
        child_class_w: ?[:0]u16 = null,
        /// v0.1.21：运行时持久化授权（形如 "fs:documents/**"）
        acl_grants: std.ArrayListUnmanaged([]const u8) = .empty,
        acl_loaded: bool = false,
        /// v0.1.22：目录监视槽与 id 分配
        fs_watches: std.ArrayListUnmanaged(*FsWatch) = .empty,
        next_fs_watch_id: i64 = 1,
        next_fs_stream_id: i64 = 1,
        /// v0.1.16：子进程槽（仅 UI 线程读写；worker 只发事件）
        procs: std.ArrayListUnmanaged(*ProcSlot) = .empty,
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
        /// UI 线程 id（run() 创建后记录）：quitFromBackend 可能被任意线程调用
        ///（应用后台收尾线程等）——PostQuitMessage 只投递到调用线程的队列，
        /// 跨线程必须用 PostThreadMessageW(WM_QUIT) 才能送达 UI 消息循环。
        ui_thread_id: std.atomic.Value(u32) = .init(0),
        /// 启动/第二实例转发的深链接载荷（导航完成后发 deepLink 事件）
        pending_launch: ?deep_link.Launch = null,
        launch_emitted: bool = false,
        /// v0.3.10 C2：isolation（随机 origin 的隔离 iframe URL + 解封密钥）
        iso_url: ?[]u8 = null,
        iso_key: ?iso_mod.Key = null,
        iso_cache: iso_mod.ReplayCache = .{},

        // ---- 初始化 ----

        fn init(self: *Self, class_u8: []const u8) !void {
            self.class_u8 = try self.allocator.dupe(u8, class_u8);
            // v0.3.10 C2：isolation 会话随机段（ziltiso://<random>/ —— iframe origin 每进程不同）
            if (config.isolation) |iso| {
                self.iso_key = iso_mod.keyFromHex(iso.key_hex) catch |err| blk: {
                    log.print("[iso] key parse failed: {s} — isolation disabled", .{@errorName(err)});
                    break :blk null;
                };
                if (self.iso_key != null) {
                    var hex: [16]u8 = undefined;
                    // 会话随机段：时间 ^ 栈地址 ^ 进程内计数（origin 区分用途，非密钥）
                    const rnd: u64 = win32.GetTickCount64() ^ (@as(u64, @intFromPtr(&hex)) +% 0x9E3779B97F4A7C15) ^ iso_seed.fetchAdd(1, .monotonic);
                    _ = iso_mod.sessionRandom(&hex, rnd);
                    self.iso_url = std.fmt.allocPrint(self.allocator, "ziltiso://{s}/", .{hex}) catch null;
                    if (self.iso_url) |u| log.print("[iso] enabled (isolation origin {s})", .{u});
                }
            }
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
                // v0.1.13：托盘菜单改由运行时模型驱动，支持勾选/禁用/增删后重建
                self.menu_state = shared_menu_model.Model.fromConfig(self.allocator, items) catch |err| blk: {
                    log.print("[tray] menu model init failed: {s}（回退静态菜单）", .{@errorName(err)});
                    break :blk null;
                };
                if (self.menu_state) |*model| {
                    if (menu_runtime.buildPopup(self.allocator, model, TRAY_MENU_BASE)) |built| {
                        self.tray_popup = built;
                        log.print("[tray] popup menu built (runtime model, {d} leaves)", .{built.ids.items.len});
                    } else |err| {
                        log.print("[tray] popup menu build failed: {s}", .{@errorName(err)});
                    }
                } else if (menu_mod.buildPopup(self.allocator, items, TRAY_MENU_BASE) catch null) |m| {
                    self.tray_menu = m;
                    log.print("[tray] popup menu built (static fallback)", .{});
                }
            }

            // v0.1.16：本地存储（与 WebView2 profile 同级目录）
            self.initStorage();
            self.initServices();
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
            // v0.1.23：每窗口代理（独立 Environment 时使用）
            const proxy = if (opts.proxy) |p| try self.allocator.dupe(u8, p) else null;
            errdefer if (proxy) |p| self.allocator.free(p);
            const user_agent = if (opts.user_agent) |ua| try self.allocator.dupe(u8, ua) else null;
            errdefer if (user_agent) |ua| self.allocator.free(ua);
            // v0.3.3：窗口级按键绑定（克隆到窗口生命周期）
            const key_bindings = try self.allocator.dupe(Config.Hotkey, opts.key_bindings orelse &.{});
            errdefer self.allocator.free(key_bindings);

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
                .close_requested_events = ipc.resolveCloseRequested(opts.close_requested_event, config.close_requested_event),
                .zoom = opts.zoom,
                .proxy = proxy,
                .overlay = opts.titlebar_overlay,
                .user_agent = user_agent,
                .incognito = opts.incognito,
                .composition_requested = opts.composition,
                .hide_on_focus_lost = opts.hide_on_focus_lost,
                .hide_on_escape = opts.hide_on_escape,
                .prevent_overflow = opts.prevent_overflow,
                .titlebar_double_click = opts.titlebar_double_click,
                .move_debounce_ms = opts.move_debounce_ms,
                .key_bindings = key_bindings,
                .tray_attached = if (opts.label) |lbl|
                    (if (config.tray) |tray| (tray.attach_window != null and std.mem.eql(u8, lbl, tray.attach_window.?)) else false)
                else
                    false,
            };

            const hinstance = win32.GetModuleHandleW(null);
            const title_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, title);
            defer self.allocator.free(title_w);

            const style = windowStyleFor(opts);
            const ex_style = windowExStyleFor(opts);
            const has_menu = opts.decorations and !opts.titlebar_overlay and !opts.child and menu_items.len != 0;
            if (has_menu) {
                w.menu = try menu_mod.buildWin32WithIcons(self.allocator, menu_items, &w.menu_bitmaps);
            }
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
            // v0.1.18：菜单加速键表（TranslateAccelerator 在消息循环里生效）
            if (has_menu) w.accel = menu_mod.buildAccel(self.allocator, menu_items);
            // v0.3.3：窗口级按键绑定（id 0xE000+i）与 Escape（0xF000）追加进 ACCEL 表
            if (w.key_bindings.len > 0) {
                w.accel = mergeKeyBindingAccel(w.accel, w.key_bindings);
            }
            if (w.hide_on_escape) {
                w.accel = appendEscapeAccel(w.accel);
            }
            // v0.3.3：每按钮状态（系统菜单项灰化）
            applyButtonStates(w.hwnd, opts.closable, opts.minimizable, opts.maximizable);
            // v0.3.3：窗口形状 mask（PNG alpha → SetWindowRgn）
            if (opts.mask) |mask_path| {
                applyWindowMask(self.allocator, w, mask_path);
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
            // v0.3.14：创建即最大化（Wails StartState.Maximised / Tauri maximized）。
            // 在状态恢复之后应用——显式选项优先于持久化布局。
            if (opts.maximized) {
                _ = win32.ShowWindow(w.hwnd, win32.SW_MAXIMIZE);
            }
            return w;
        }

        fn beginController(self: *Self, w: *Window) void {
            // v0.1.23：代理窗口有自己的 Environment（首次创建，崩溃恢复时复用）
            if (w.own_env) |env| return self.beginControllerWithEnv(w, env);
            if (w.proxy) |proxy| return self.beginProxyEnv(w, proxy);
            const env = self.env orelse return;
            // v0.3.2：无痕窗口 → ControllerWithOptions（InPrivate；老运行时回退普通 controller）
            if (w.incognito) return self.beginIncognitoController(w, env);
            // v0.3.12 A11：组合模式（CompositionController + DComp 视觉树）
            if (w.composition_requested) return self.beginCompositionController(w, env);
            self.beginControllerWithEnv(w, env);
        }

        /// v0.3.12 A11：组合模式（CompositionController + DirectComposition 视觉树）。
        /// Environment10::CreateCoreWebView2CompositionControllerWithOptions（老运行时
        /// QI 失败 → 回退 HWND 模式——项目降级文化）。DComp 设备/目标/视觉在
        /// CompositionControllerCompletedHandler 里装配（put_RootVisualTarget +
        /// SetRoot + Commit）。
        fn beginCompositionController(self: *Self, w: *Window, env: *wv2.ICoreWebView2Environment) void {
            // **已知问题（本版文档化）**：CC 创建/DComp 装配（put_RootVisualTarget +
            // SetRoot + Commit + Settings9）在实测中全部成功，但页面导航阶段
            // WebView2 渲染管线段错误（EmbeddedBrowserWebView.dll 内部，about:blank
            // 亦复现；putIsVisible 前置/有序拆除 SetRoot(null)+Close 均不缓解——
            // 诊断笔记见 ROADMAP v0.3.12）。本版组合选项按降级文化直接走 HWND
            // 渲染（窗口存活/IPC 全正常），渲染管线修复列为后续专项。
            log.print("[comp] window #{d}: composition requested — render pipeline known issue, HWND fallback", .{w.id});
            return self.beginControllerWithEnv(w, env);
        }

        fn beginCompositionControllerProbe(self: *Self, w: *Window, env: *wv2.ICoreWebView2Environment) void {
            const env10 = wv2.ICoreWebView2Environment10.fromEnvironment(env) orelse {
                log.print("[comp] window #{d}: runtime lacks Environment10 — fallback to HWND mode", .{w.id});
                return self.beginControllerWithEnv(w, env);
            };
            const handler = CompositionControllerCompletedHandler.create(self, w) catch {
                log.print("[fatal] composition handler alloc failed", .{});
                return;
            };
            const hr = env10.createCompositionControllerWithOptions(w.hwnd, null, handler);
            handler.dropRef();
            if (com.failed(hr)) {
                log.print("[fatal] CreateCoreWebView2CompositionControllerWithOptions failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
                win32.PostQuitMessage(3);
            }
        }

        /// v0.3.2：无痕窗口（InPrivate）。Environment10 的 ControllerOptions +
        /// ControllerWithOptions；QI 失败（WebView2 运行时 < 1.0.1722）时记日志并
        /// 回退普通 controller（行为差异 = 数据落盘，与 InPrivate 的差异已在文档注明）。
        fn beginIncognitoController(self: *Self, w: *Window, env: *wv2.ICoreWebView2Environment) void {
            const env10 = wv2.ICoreWebView2Environment10.fromEnvironment(env) orelse {
                log.print("[incognito] window #{d}: runtime lacks Environment10, falling back to normal controller", .{w.id});
                return self.beginControllerWithEnv(w, env);
            };
            defer env10.release();
            const created = env10.createControllerOptions();
            if (com.failed(created.hr) or created.options == null) {
                log.print("[incognito] window #{d}: CreateCoreWebView2ControllerOptions failed hr=0x{x}", .{ w.id, @as(u32, @bitCast(created.hr)) });
                return self.beginControllerWithEnv(w, env);
            }
            const copts = created.options.?;
            defer copts.release();
            _ = copts.putInPrivateMode(true);
            const handler = ControllerCompletedHandler.create(self, w) catch {
                log.print("[fatal] controller handler alloc failed", .{});
                return;
            };
            const hr = env10.createControllerWithOptions(w.hwnd, copts, handler);
            handler.dropRef();
            if (com.failed(hr)) {
                log.print("[fatal] CreateCoreWebView2ControllerWithOptions failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
                win32.PostQuitMessage(3);
            }
        }

        fn beginControllerWithEnv(self: *Self, w: *Window, env: *wv2.ICoreWebView2Environment) void {
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

        /// v0.1.23：为指定窗口建独立 Environment（WebView2 的代理是环境级选项）。
        /// profile 目录：`<profile>\WebView2-windows\<窗口 id>`——该窗口与主窗口
        /// 不共享 cookie/缓存（代理隔离的必然代价，已在文档注明）。
        fn beginProxyEnv(self: *Self, w: *Window, proxy: []const u8) void {
            const rt = if (self.runtime) |*r| r else {
                log.print("[proxy] window #{d} failed: runtime missing", .{w.id});
                return;
            };
            const profile = app_data.profileDirectory(self.allocator, config.app_id, config.migrate_legacy_profile) catch {
                log.print("[proxy] window #{d} failed: profile dir", .{w.id});
                return;
            };
            defer self.allocator.free(profile);
            const root = std.fmt.allocPrint(self.allocator, "{s}\\WebView2-windows", .{profile}) catch return;
            defer self.allocator.free(root);
            const dir = std.fmt.allocPrint(self.allocator, "{s}\\{d}", .{ root, w.id }) catch return;
            defer self.allocator.free(dir);
            {
                const root_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, root) catch return;
                defer self.allocator.free(root_w);
                _ = win32.CreateDirectoryW(root_w.ptr, null);
                const dir_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, dir) catch return;
                defer self.allocator.free(dir_w);
                _ = win32.CreateDirectoryW(dir_w.ptr, null);
            }
            const dir_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, dir) catch return;
            defer self.allocator.free(dir_w);

            const eo = environment.Options{ .proxy_server = proxy };
            const env_opts = env_options.EnvironmentOptions.create(self.allocator, eo) catch null;
            defer if (env_opts) |o| o.dropRef();
            const handler = WindowEnvCompletedHandler.create(self, w) catch return;
            const hr = loader.createEnvironment(rt, dir_w.ptr, if (env_opts) |o| @ptrCast(o) else null, handler);
            handler.dropRef();
            if (com.failed(hr)) {
                log.print("[proxy] window #{d} createEnvironment hr=0x{x}", .{ w.id, @as(u32, @bitCast(hr)) });
            } else {
                log.print("[proxy] window #{d} env requested (proxy={s})", .{ w.id, proxy });
            }
        }

        fn onControllerReady(self: *Self, w: *Window, controller: *wv2.ICoreWebView2Controller) void {
            w.controller = controller;
            _ = controller.lpVtbl.AddRef(controller);
            log.print("[webview] controller created (window #{d})", .{w.id});

            _ = controller.putIsVisible(1);
            w.updateBounds();
            // v0.3.14 G11：初始缩放（Wails Zoom 选项；controller 级 put_ZoomFactor）
            if (w.zoom) |z| {
                if (z > 0.25 and z < 4.0) {
                    _ = controller.lpVtbl.put_ZoomFactor(controller, z);
                    log.print("[webview] initial zoom {d:.2} (window #{d})", .{ z, w.id });
                }
            }

            const wv_result = controller.getCoreWebView2();
            if (com.failed(wv_result.hr) or wv_result.webview == null) {
                log.print("[fatal] get_CoreWebView2 failed hr=0x{x}", .{@as(u32, @bitCast(wv_result.hr))});
                win32.PostQuitMessage(5);
                return;
            }
            const webview = wv_result.webview.?;
            w.webview = webview;
            log.print("[webview] core webview attached (window #{d})", .{w.id});

            // v0.1.7：透明/自定义背景（ICoreWebView2Controller2——HWND 模式专属）
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

            self.finishWebViewSetup(w, webview, controller);
        }

        /// v0.3.12 A11：组合状态（CC + CC4 探测 + DComp 视觉树句柄）。
        const CompositionState = struct {
            controller: *wv2.ICoreWebView2CompositionController,
            cc4: ?*wv2.ICoreWebView2CompositionController4,
            device: *dcomp.Device,
            target: *dcomp.Target,
            visual: *dcomp.Visual,
        };

        /// v0.3.12 A11：组合 controller 就绪——DComp 视觉树装配 + Settings9
        /// 非客户区支持 + driver attach（controller=null）。DComp 失败 → 回退
        /// HWND 模式（销毁 CC + 重新走普通 controller——项目降级文化）。
        fn onCompositionControllerReady(self: *Self, w: *Window, cc: *wv2.ICoreWebView2CompositionController) void {
            const device = dcomp.createDevice(null) orelse {
                log.print("[comp] window #{d}: DComp device failed — fallback to HWND mode", .{w.id});
                cc.release();
                return self.beginControllerWithEnv(w, self.env orelse return);
            };
            var target: ?*dcomp.Target = null;
            var visual: ?*dcomp.Visual = null;
            if (com.failed(device.lpVtbl.CreateTargetForHwnd(device, w.hwnd, 1, &target)) or target == null) {
                log.print("[comp] window #{d}: CreateTargetForHwnd failed — fallback", .{w.id});
                device.release();
                cc.release();
                return self.beginControllerWithEnv(w, self.env orelse return);
            }
            if (com.failed(device.lpVtbl.CreateVisual(device, &visual)) or visual == null) {
                log.print("[comp] window #{d}: CreateVisual failed — fallback", .{w.id});
                device.release();
                cc.release();
                return self.beginControllerWithEnv(w, self.env orelse return);
            }
            // webview → 视觉内容 → RootVisualTarget → SetRoot → Commit
            {
                // QI 探测诊断（组合对象实际实现的接口面）
                const probe = struct {
                    fn qi(obj: *wv2.ICoreWebView2CompositionController, iid: com.GUID) u32 {
                        var out: ?*anyopaque = null;
                        const hr2 = obj.lpVtbl.QueryInterface(obj, &iid, &out);
                        return @as(u32, @bitCast(hr2));
                    }
                };
                log.print("[comp] QI probe: webview=0x{x} controller=0x{x} cc4=0x{x}", .{
                    probe.qi(cc, wv2.IID_ICoreWebView2),
                    probe.qi(cc, wv2.IID_ICoreWebView2Controller),
                    probe.qi(cc, wv2.IID_ICoreWebView2CompositionController4),
                });
            }
            // QI 实测：组合对象实现 ICoreWebView2Controller（非 ICoreWebView2 直取）
            // → webview 经 controller.getCoreWebView2() 取；Controller 传给 driver
            //（zoom 等窗口面可用），但 **不进 w.controller**——bounds 请求由
            // updateBounds 的 null 守卫跳过（组合模式尺寸归 DComp 视觉树）
            const controller_probe = cc.getController() orelse {
                log.print("[comp] window #{d}: QI ICoreWebView2Controller failed — fallback", .{w.id});
                visual.?.release();
                device.release();
                cc.release();
                return self.beginControllerWithEnv(w, self.env orelse return);
            };
            const wv_result = controller_probe.getCoreWebView2();
            if (com.failed(wv_result.hr) or wv_result.webview == null) {
                log.print("[comp] window #{d}: get_CoreWebView2 failed — fallback", .{w.id});
                visual.?.release();
                device.release();
                cc.release();
                return self.beginControllerWithEnv(w, self.env orelse return);
            }
            const webview = wv_result.webview.?;
            // 可见性：组合模式下经 QI'd controller 置 IsVisible（渲染管线启动前提）
            _ = controller_probe.putIsVisible(1);
_ = cc.putRootVisualTarget(@ptrCast(visual.?));
            _ = target.?.setRoot(visual.?);
            _ = device.commit();
            const cc4 = cc.getCC4();
            const state = self.allocator.create(CompositionState) catch {
                log.print("[comp] state alloc failed", .{});
                return;
            };
            state.* = .{ .controller = cc, .cc4 = cc4, .device = device, .target = target.?, .visual = visual.? };
            w.composition = state;
            log.print("[comp] window #{d}: composition ready (cc4={s}, dcomp visual tree committed)", .{ w.id, if (cc4 != null) "yes" else "no" });

            // Settings9：非客户区支持（app-region: drag CSS → 原生 hit-test）
            var settings: ?*wv2.ICoreWebView2Settings = null;
            if (com.succeeded(webview.lpVtbl.get_Settings(webview, &settings)) and settings != null) {
                if (wv2.ICoreWebView2Settings9.fromSettings(settings.?)) |s9| {
                    const hr9 = s9.putIsNonClientRegionSupportEnabled(true);
                    log.print("[comp] IsNonClientRegionSupportEnabled hr=0x{x}", .{@as(u32, @bitCast(hr9))});
                } else {
                    log.print("[comp] Settings9 unavailable — app-region hit-test degraded", .{});
                }
            }

            // **已知问题（本版文档化）**：CC 创建/DComp 装配/Settings9 全部成功后，
            // 页面导航阶段 WebView2 渲染管线段错误（EmbeddedBrowserWebView.dll 内部，
            // about:blank 亦复现；putIsVisible 前置亦不缓解）。本版按降级文化回退
            // HWND 模式：组合管线（probe/装配/输入转发面/清理）全部落地并验证，
            // 渲染修复列为后续专项（诊断笔记见 ROADMAP v0.3.12）。
            log.print("[comp] render pipeline unstable (known issue) — fallback to HWND mode", .{});
            // 有序拆除：SetRoot(null) → Commit → Close(controller) → 释放引用。
            // 直接 cc.release() 会在运行时仍有挂起渲染时段错误（实测）。
            _ = target.?.setRoot(null);
            _ = device.commit();
            _ = controller_probe.lpVtbl.Close(controller_probe);
            _ = controller_probe.lpVtbl.Release(controller_probe);
            _ = webview.lpVtbl.Release(webview);
            visual.?.release();
            target.?.release();
            device.release();
            cc.release();
            return self.beginControllerWithEnv(w, self.env orelse return);
        }

        /// v0.3.12 A11：webview 后段装配（IPC sink / filters / driver / 脚本 / 导航）。
        /// controller 可为 null（组合模式——CC 不实现 Controller；bounds/zoom 降级）。
        fn finishWebViewSetup(self: *Self, w: *Window, webview: *wv2.ICoreWebView2, controller: ?*wv2.ICoreWebView2Controller) void {
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

                    // v0.3.2：真 scheme filter（每个注册的协议一条 `<scheme>://*`）
                    for (config.protocols) |p| {
                        const scheme_filter = std.fmt.allocPrint(self.allocator, "{s}://*", .{p.name}) catch continue;
                        defer self.allocator.free(scheme_filter);
                        const scheme_filter_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, scheme_filter) catch continue;
                        defer self.allocator.free(scheme_filter_w);
                        const hr4 = webview.addWebResourceRequestedFilter(scheme_filter_w.ptr, wv2.WEB_RESOURCE_CONTEXT_ALL);
                        log.print("[webview] AddWebResourceRequestedFilter({s}) hr=0x{x}", .{ scheme_filter, @as(u32, @bitCast(hr4)) });
                    }
                    // v0.3.10 C2：isolation 隔离 iframe 的独立 scheme filter
                    if (self.iso_url != null) {
                        const iso_filter_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, "ziltiso://*") catch return;
                        defer self.allocator.free(iso_filter_w);
                        const hr5 = webview.addWebResourceRequestedFilter(iso_filter_w.ptr, wv2.WEB_RESOURCE_CONTEXT_ALL);
                        log.print("[webview] AddWebResourceRequestedFilter(ziltiso://*) hr=0x{x}", .{@as(u32, @bitCast(hr5))});
                    }
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
            // v0.1.24：每窗口 UA 覆盖（config 里的是应用级默认值）
            if (w.user_agent) |ua| wv_opts.settings.user_agent = ua;
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

            // v0.1.21：原型冻结标记（runtime 末尾据此冻结 window.zilt 与内建原型）
            if (config.security.freeze_prototype) {
                self.injectScript(w, webview, "window.__ZILT_FREEZE__ = true;");
            }

            // v0.3.10 C2：isolation 标记（先于 runtime——invoke 双形态读它）
            if (self.iso_url) |u| {
                const iso_js = std.fmt.allocPrint(self.allocator, "window.__ZILT_ISO__='{s}';", .{u}) catch null;
                if (iso_js) |sc| {
                    self.injectScript(w, webview, sc);
                    self.allocator.free(sc);
                }
                log.print("[iso] __ZILT_ISO__ injected", .{});
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

            // v0.1.19：用户初始化脚本（document-start，runtime 之后）
            for (config.init_scripts) |script| {
                self.injectScript(w, webview, script);
            }

            // 导航
            const nav_url = if (w.id == 1) (self.dev_url orelse w.url) else w.url;
            const url_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, nav_url) catch return;
            defer self.allocator.free(url_w);
            const hr4 = webview.navigate(url_w.ptr);
            log.print("[webview] navigate {s} hr=0x{x}", .{ nav_url, @as(u32, @bitCast(hr4)) });

            if (w.id == 1) self.onMainReady(w);
        }

        /// v0.1.16：附加子 webview 的 controller 就绪。与主 webview 相同的
        /// IPC sink / 资产拦截 / 运行时注入，但不挂 driver（devtools/下载等
        /// 事件面属于主内容区，子 webview 保持最小面）。
        fn onChildControllerReady(self: *Self, w: *Window, c: *ChildWebview, controller: *wv2.ICoreWebView2Controller) void {
            c.controller = controller;
            _ = controller.lpVtbl.AddRef(controller);
            _ = controller.putIsVisible(1);

            var rc: win32.RECT = undefined;
            if (win32.GetClientRect(c.hwnd, &rc) != 0) {
                _ = controller.putBounds(.{ .left = 0, .top = 0, .right = rc.right, .bottom = rc.bottom });
            }

            const wv_result = controller.getCoreWebView2();
            if (com.failed(wv_result.hr) or wv_result.webview == null) {
                log.print("[webviews] child get_CoreWebView2 failed hr=0x{x}", .{@as(u32, @bitCast(wv_result.hr))});
                return;
            }
            const webview = wv_result.webview.?;
            c.webview = webview;

            // IPC sink（回复按 sender 路由：见 onWebMessage 的 sendJsonTo）
            if (MessageHandler.create(w)) |mh| {
                var token: com.EventRegistrationToken = .{ .value = 0 };
                _ = webview.addWebMessageReceived(mh, &token);
            } else |_| {}

            // 资产服务（与主 webview 同一 origin 拦截）
            if (self.dev_url == null) {
                if (WebResourceHandler.create(w)) |rh| {
                    var token2: com.EventRegistrationToken = .{ .value = 0 };
                    _ = webview.addWebResourceRequested(rh, &token2);
                    if (std.fmt.allocPrint(self.allocator, "{s}/*", .{originOf(config.url)})) |filter| {
                        defer self.allocator.free(filter);
                        if (std.unicode.utf8ToUtf16LeAllocZ(self.allocator, filter)) |filter_w| {
                            defer self.allocator.free(filter_w);
                            _ = webview.addWebResourceRequestedFilter(filter_w.ptr, wv2.WEB_RESOURCE_CONTEXT_ALL);
                        } else |_| {}
                    } else |_| {}
                } else |_| {}
            }

            // 注入 zilt 运行时（invoke 可用；Zig→JS 事件只广播主 webview）
            if (IgnoreCompletedHandler(wv2.IID_AddScriptToExecuteOnDocumentCreatedCompletedHandler).create(w)) |sh| {
                defer sh.dropRef();
                if (std.unicode.utf8ToUtf16LeAllocZ(self.allocator, ipc.runtime_js)) |js_w| {
                    defer self.allocator.free(js_w);
                    _ = webview.addScriptToExecuteOnDocumentCreated(js_w.ptr, sh);
                } else |_| {}
            } else |_| {}

            // 排队的目标 URL（create 时给的就绪后导航；pending_url 归 page_allocator）
            if (c.pending_url) |pending| {
                if (std.unicode.utf8ToUtf16LeAllocZ(self.allocator, pending)) |url_w| {
                    defer self.allocator.free(url_w);
                    _ = webview.navigate(url_w.ptr);
                } else |_| {}
                std.heap.page_allocator.free(pending);
                c.pending_url = null;
            }
            log.print("[webviews] child #{d} ready (window #{d}, partition={s})", .{ c.id, w.id, c.partition orelse "-" });
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
                .window_query_fn = runWindowQuery,
                .spawn_window_fn = spawnWindowFromBackend,
                // v0.3.6：SharedBuffer 二进制通道（Zig→JS）
                .post_binary_fn = postBinaryFromBackend,
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
                // ---- v0.1.13 / v0.1.14 ----
                .system_fn = systemAction,
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
            if (win32.GetCurrentThreadId() == self.ui_thread_id.load(.acquire)) {
                win32.PostQuitMessage(@intCast(code));
            } else {
                // 跨线程：WM_QUIT 定向投递到 UI 消息循环（PostQuitMessage 只投
                // 调用线程自身的队列——应用后台收尾线程调 quit 时会静默丢失）
                _ = win32.PostThreadMessageW(self.ui_thread_id.load(.acquire), win32.WM_QUIT, @intCast(code), 0);
            }
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

        /// v0.1.16：回复落点路由。sender 是消息来源 webview（主/子通用）；
        /// null 或等于主 webview 时走原路径（行为不变），否则 postWebMessageAsJson
        /// 直达来源 webview。msg 所有权转移。
        fn sendJsonTo(w: *Window, msg: []u8, sender: ?*wv2.ICoreWebView2) void {
            const b = w.backend;
            if (sender == null or w.webview == sender) {
                w.sendJson(msg); // 所有权转移
                return;
            }
            defer b.allocator.free(msg);
            if (!w.alive) return;
            const wide = std.unicode.utf8ToUtf16LeAllocZ(b.allocator, msg) catch return;
            defer b.allocator.free(wide);
            _ = sender.?.postWebMessageAsJson(wide.ptr);
        }

        /// UI 线程：WebMessageReceived 分发（sender = 消息来源 webview）。
        fn onWebMessage(w: *Window, args: *wv2.ICoreWebView2WebMessageReceivedEventArgs, sender: ?*wv2.ICoreWebView2) void {
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

            // v0.3.10 C2：isolation 启用时解封 sealed invoke
            var decoded = (if (self.iso_key) |k| ipc.decodeIsolated(self.allocator, raw_u8, k) else ipc.decode(self.allocator, raw_u8)) catch return;
            defer decoded.deinit();
            switch (decoded.msg) {
                .invoke => |inv| {
                    log.print("[ipc] invoke {s} (id={d}, window={d}, sealed={s})", .{ inv.method, inv.id, w.id, if (inv.seal != null) "true" else "false" });

                    // v0.3.10 C2：isolation 启用时——明文 invoke 拒绝（伪造防护），
                    // 签名不符/重放拒绝（IsoTampered）
                    if (self.iso_key != null) {
                        const ok_seal = blk2: {
                            const seal = inv.seal orelse break :blk2 false;
                            break :blk2 iso_mod.verifyJson(&self.iso_cache, self.iso_key.?, seal.nonce_hex, inv.method, inv.args_json, seal.sig_hex);
                        };
                        if (!ok_seal) {
                            const err_name: []const u8 = if (inv.seal == null) "IsolationRequired" else "IsoTampered";
                            log.print("[iso] invoke rejected ({s}) id={d} method={s}", .{ err_name, inv.id, inv.method });
                            const rej = ipc.encodeReject(self.allocator, inv.id, err_name) catch return;
                            sendJsonTo(w, rej, sender);
                            w.emitEventPayload("__zilt.isoRejected", .{ .id = inv.id });
                            return;
                        }
                    }

                    // 框架内置：自定义标题栏拖动（runtime_js 的 data-zilt-drag-region）
                    if (std.mem.eql(u8, inv.method, "__zilt.startDragging")) {
                        const ok = runWindowCmd(w.backend, w.id, .start_dragging);
                        const result_json = if (ok) "true" else "false";
                        const resp = ipc.encodeResolve(self.allocator, inv.id, result_json) catch return;
                        sendJsonTo(w, resp, sender);
                        return;
                    }

                    if (enforce_acl and !security.allowed(config.security, config.url, self.dev_url, source_url, w.label, .command, inv.method)) {
                        log.print("[acl] command '{s}' denied (window={s}, source={s})", .{ inv.method, w.label, source_url });
                        const rej = ipc.encodeReject(self.allocator, inv.id, "PermissionDenied") catch return;
                        sendJsonTo(w, rej, sender);
                        return;
                    }

                    const result_json: []u8 = blk: {
                        // v0.1.9–v0.1.12 框架内置命令（window.zilt.*）
                        if (builtin.dispatch(ctx, inv.method, inv.args_json)) |builtin_result| {
                            if (builtin_result) |json| break :blk json;
                        } else |err| {
                            log.print("[ipc] builtin {s} failed: {s}", .{ inv.method, @errorName(err) });
                            const rej = ipc.encodeReject(self.allocator, inv.id, @errorName(err)) catch return;
                            sendJsonTo(w, rej, sender);
                            return;
                        }
                        break :blk ipc.dispatch(config.commands, ctx, inv.method, inv.args_json) catch |err| {
                            log.print("[ipc] invoke {s} failed: {s}", .{ inv.method, @errorName(err) });
                            const rej = ipc.encodeReject(self.allocator, inv.id, @errorName(err)) catch return;
                            sendJsonTo(w, rej, sender);
                            return;
                        };
                    };
                    const resp = ipc.encodeResolve(self.allocator, inv.id, result_json) catch return;
                    sendJsonTo(w, resp, sender);
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
            /// v0.1.13 / v0.1.14：系统能力统一通道
            system: struct { alloc: std.mem.Allocator, req: shared_system.Request, out: ?shared_system.Result = null },
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

        fn systemAction(backend_ptr: *anyopaque, window_id: u32, alloc: std.mem.Allocator, request: shared_system.Request) anyerror!shared_system.Result {
            var req = ActionReq{ .action = .{ .system = .{ .alloc = alloc, .req = request } } };
            marshalAction(backend_ptr, window_id, &req);
            if (req.err) |e| return e;
            return switch (req.action) {
                .system => |a| a.out orelse .none,
                else => unreachable,
            };
        }

        // ------------------------------------------------------------------
        // v0.1.13 / v0.1.14：系统能力执行（UI 线程）
        // ------------------------------------------------------------------

        fn runSystem(self: *Self, w: *Window, request: shared_system.Request, alloc: std.mem.Allocator) !shared_system.Result {
            switch (request) {
                .menu => |op| return self.runMenuOp(w, op, alloc),
                .tray => |op| {
                    self.runTrayOp(op);
                    return .{ .ok = true };
                },
                .hotkey => |op| return self.runHotkeyOp(w, op, alloc),
                .taskbar => |op| {
                    const supported = try self.runTaskbarOp(w, op, alloc);
                    return .{ .ok = supported };
                },
                .info => |kind| return .{ .json = try self.collectSystemInfo(kind, alloc, w) },
                .shell => |target| {
                    try sys_integration.open(alloc, target);
                    return .{ .ok = true };
                },
                .admin_restart => |args| {
                    const exe = try currentExePath(alloc);
                    defer alloc.free(exe);
                    try sys_integration.restartAsAdmin(alloc, exe, args);
                    log.print("[shell] admin restart requested: {s}", .{exe});
                    return .{ .ok = true };
                },
                .autostart => |op| return .{ .state = try self.runAutostartOp(op, alloc) },
                .appearance => |ap| {
                    const r = sys_integration.applyAppearance(w.hwnd, ap);
                    log.print("[appearance] dark_titlebar={} backdrop={} tint={} corner={}", .{ r.dark, r.backdrop, r.tint, r.corner });
                    return .{ .ok = r.dark or r.backdrop or r.tint or r.corner };
                },
                .store => |op| return self.runStoreOp(op, alloc),
                .fs => |op| return self.runFsOp(op, alloc),
                .window_state => |op| return self.runWindowStateOp(w, op, alloc),
                .services => |op| return self.runServicesOp(op, alloc),
                .http => |op| return self.runHttpOp(op, alloc),
                .ws => |op| return self.runWsOp(op, alloc),
                .webviews => |op| return self.runWebviewsOp(w, op, alloc),
                .process => |op| return self.runProcOp(op, alloc),
                .sql => |op| return self.runSqlOp(op, alloc),
                .updater => |op| return self.runUpdaterOp(op, alloc),
                .acl => |op| return self.runAclOp(op, alloc),
            }
        }

        // ---- v0.1.16：KV 存储 / 受限 fs ----

        fn initStorage(self: *Self) void {
            const local = win32.getEnvUtf8(self.allocator, "LOCALAPPDATA") orelse return;
            defer self.allocator.free(local);
            const root = std.fmt.allocPrint(self.allocator, "{s}\\{s}", .{ local, config.app_id }) catch return;
            self.storage_root = root;

            self.loadAclGrants();

            const path = std.fmt.allocPrint(self.allocator, "{s}\\store.json", .{root}) catch return;
            defer self.allocator.free(path);

            var store = shared_store.Store.init(self.allocator);
            if (win32.readFileAlloc(self.allocator, path)) |bytes| {
                defer self.allocator.free(bytes);
                store.fromJson(bytes) catch |err| {
                    log.print("[store] invalid store.json: {s}", .{@errorName(err)});
                };
            }
            self.store = store;
            log.print("[store] ready ({d} keys) {s}", .{ store.count(), path });
        }

        fn persistStore(self: *Self) void {
            const st = if (self.store) |*v| v else return;
            const root = self.storage_root orelse return;
            const json = st.toJson(self.allocator) catch return;
            defer self.allocator.free(json);
            self.loadAclGrants();

            const path = std.fmt.allocPrint(self.allocator, "{s}\\store.json", .{root}) catch return;
            defer self.allocator.free(path);
            if (!win32.writeFileAlloc(self.allocator, path, json)) {
                log.print("[store] persist failed: {s}", .{path});
            }
        }

        // ---- v0.1.16：HTTP（异步） ----

        /// 发起请求后立刻返回；结果由后台线程 PostMessage 回 UI 线程，
        /// 再以 `httpResponse` 事件推给前端。**不阻塞 UI 线程**是这里的核心约束
        /// —— 同步实现会让窗口在慢请求下冻结数秒，体验上等同于卡死。
        fn runHttpOp(self: *Self, op: shared_system.HttpOp, alloc: std.mem.Allocator) !shared_system.Result {
            _ = alloc;
            switch (op) {
                .request => |req| {
                    const w = self.mainWindow() orelse return error.NoMainWindow;
                    if (!self.aclAllowed("http", req.url)) {
                        log.print("[acl] http denied: {s}", .{req.url});
                        return error.PermissionDenied;
                    }
                    const job = makeHttpJob(w.hwnd, req) orelse return error.OutOfMemory;
                    const t = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, httpWorker, .{job}) catch {
                        freeHttpJob(job);
                        log.print("[http] spawn failed", .{});
                        return error.HttpSpawnFailed;
                    };
                    t.detach();
                    log.print("[http] {s} {s} (id={d}, stream={}) dispatched", .{ job.method, job.url, job.id, job.stream });
                    return .{ .ok = true };
                },
            }
        }

        // ---- v0.1.16：WebSocket ----

        fn wsConnById(self: *Self, id: i64) ?*WsConn {
            for (self.ws_conns.items) |c| {
                if (c.id == id) return c;
            }
            return null;
        }

        /// UI 线程：移除连接槽并等读线程退出、释放全部资源。
        /// 只能在 UI 线程调用；幂等 —— conn 不在槽里则什么都不做
        ///（防两个 close/error 事件重复销毁同一连接）。
        fn wsRemoveConn(self: *Self, conn: *WsConn) void {
            var found = false;
            for (self.ws_conns.items, 0..) |c, i| {
                if (c == conn) {
                    _ = self.ws_conns.swapRemove(i);
                    found = true;
                    break;
                }
            }
            if (!found) return;
            const id = conn.id;
            conn.read_thread.join();
            conn.stream.close(conn.io);
            conn.threaded.deinit();
            const a = std.heap.page_allocator;
            a.destroy(conn.threaded);
            a.destroy(conn);
            log.print("[ws] conn id={d} released", .{id});
        }

        fn wssConnById(self: *Self, id: i64) ?*WssConn {
            for (self.wss_conns.items) |c| {
                if (c.id == id) return c;
            }
            return null;
        }

        /// UI 线程：移除 wss 槽 + 等读线程退出 + 释放 WinHTTP 句柄。
        fn wssRemoveConn(self: *Self, conn: *WssConn) void {
            var found = false;
            for (self.wss_conns.items, 0..) |c, i| {
                if (c == conn) {
                    _ = self.wss_conns.swapRemove(i);
                    found = true;
                    break;
                }
            }
            if (!found) return;
            conn.read_thread.join();
            conn.ws.deinit();
            std.heap.page_allocator.destroy(conn);
            log.print("[ws] wss conn id={d} released", .{conn.id});
        }

        /// connect/send/close。connect 异步（握手秒级，不能冻结 UI）；
        /// send/close 同步执行 —— 帧写是小缓冲阻塞写，通常亚毫秒。
        fn runWsOp(self: *Self, op: shared_system.WsOp, alloc: std.mem.Allocator) !shared_system.Result {
            _ = alloc;
            const a = std.heap.page_allocator;
            switch (op) {
                .connect => |req| {
                    const w = self.mainWindow() orelse return error.NoMainWindow;
                    if (!self.aclAllowed("http", req.url)) {
                        log.print("[acl] ws denied: {s}", .{req.url});
                        return error.PermissionDenied;
                    }
                    // v0.1.20：wss 走 WinHTTP（TLS/代理/证书策略），ws 仍走自研帧层
                    if (req.url.len >= 4 and std.ascii.eqlIgnoreCase(req.url[0..4], "wss:")) {
                        const job = a.create(WssJob) catch return error.OutOfMemory;
                        job.* = .{
                            .id = req.id,
                            .hwnd = w.hwnd,
                            .url = a.dupe(u8, req.url) catch {
                                a.destroy(job);
                                return error.OutOfMemory;
                            },
                        };
                        if (req.proxy) |pr| job.proxy = a.dupe(u8, pr) catch null;
                        job.insecure_tls = req.insecure_tls;
                        if (req.headers.len > 0) job.headers = a.dupe(u8, req.headers) catch &.{};
                        const t = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, wssWorker, .{job}) catch {
                            freeWssJob(job);
                            log.print("[ws] wss spawn failed", .{});
                            return error.WsSpawnFailed;
                        };
                        t.detach();
                        log.print("[ws] wss connect id={d} {s} dispatched", .{ req.id, req.url });
                        return .{ .ok = true };
                    }
                    const job = a.create(WsJob) catch return error.OutOfMemory;
                    job.* = .{
                        .id = req.id,
                        .hwnd = w.hwnd,
                        .url = a.dupe(u8, req.url) catch {
                            a.destroy(job);
                            return error.OutOfMemory;
                        },
                    };
                    const t = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, wsWorker, .{job}) catch {
                        a.free(job.url);
                        a.destroy(job);
                        log.print("[ws] spawn failed", .{});
                        return error.WsSpawnFailed;
                    };
                    t.detach();
                    log.print("[ws] connect id={d} {s} dispatched", .{ req.id, req.url });
                    return .{ .ok = true };
                },
                .send => |req| {
                    if (self.wsConnById(req.id)) |conn| {
                        wsWriteFrame(conn, .text, req.data) catch |err| {
                            log.print("[ws] send id={d} failed: {s}", .{ req.id, @errorName(err) });
                            return error.WsWriteFailed;
                        };
                        return .{ .ok = true };
                    }
                    if (self.wssConnById(req.id)) |conn| {
                        conn.ws.sendText(req.data) catch |err| {
                            log.print("[ws] wss send id={d} failed: {s}", .{ req.id, @errorName(err) });
                            return error.WsWriteFailed;
                        };
                        return .{ .ok = true };
                    }
                    return error.WsNotConnected;
                },
                .close => |req| {
                    if (self.wssConnById(req.id)) |tls_conn| {
                        tls_conn.closing = true;
                        tls_conn.ws.close(req.code, req.reason);
                        return .{ .ok = true };
                    }
                    const conn = self.wsConnById(req.id) orelse return error.WsNotConnected;
                    conn.closing = true;
                    const cp = shared_ws.closePayload(a, req.code, req.reason) catch return error.OutOfMemory;
                    defer a.free(cp);
                    wsWriteFrame(conn, .close, cp) catch |err| {
                        log.print("[ws] close id={d} write failed: {s}", .{ req.id, @errorName(err) });
                    };
                    // 半关写端：读线程会收到对端的 close echo 或 EOF，
                    // 然后发 close 事件 → UI 线程统一清理（wsRemoveConn）。
                    conn.stream.shutdown(conn.io, .send) catch {};
                    return .{ .ok = true };
                },
            }
        }

        // ---- v0.1.16：单窗口多 WebView ----

        /// 子 webview 专用窗口类（DefWindowProc）。不用系统 STATIC 类：
        /// STATIC 对 WM_PAINT/WM_ERASEBKGND 的特殊处理会干扰 Chromium
        /// 合成器挂钩（实测 controller 异步完成回调报 E_ABORT）。
        fn registerChildWebviewClass(self: *Self) bool {
            const name_z = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, "ZiltChildWebView") catch return false;
            var wc: win32.WNDCLASSEXW = .{
                .cbSize = @sizeOf(win32.WNDCLASSEXW),
                .style = 0,
                .lpfnWndProc = win32.DefWindowProcW,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = win32.GetModuleHandleW(null),
                .hIcon = null,
                .hCursor = win32.LoadCursorW(null, @ptrFromInt(win32.IDC_ARROW)),
                .hbrBackground = @ptrFromInt(win32.COLOR_WINDOW + 1),
                .lpszMenuName = null,
                .lpszClassName = name_z.ptr,
                .hIconSm = null,
            };
            const atom = win32.RegisterClassExW(&wc);
            if (atom == 0) {
                // 类名全局：已注册视为成功（ERROR_CLASS_ALREADY_EXISTS = 1410）
                const err = win32.GetLastError();
                if (err != 1410) {
                    log.print("[webviews] register child class failed err={d}", .{err});
                    self.allocator.free(name_z);
                    return false;
                }
            }
            self.child_class_w = name_z;
            return true;
        }

        fn createChildHwnd(self: *Self, parent: win32.HWND, x: i32, y: i32, width: i32, height: i32) ?win32.HWND {
            const class_w = self.child_class_w orelse return null;
            const empty_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, "") catch return null;
            defer self.allocator.free(empty_w);
            return win32.CreateWindowExW(
                0,
                class_w.ptr,
                empty_w.ptr,
                win32.WS_CHILD | win32.WS_VISIBLE | win32.WS_CLIPSIBLINGS,
                x,
                y,
                width,
                height,
                parent,
                null,
                win32.GetModuleHandleW(null),
                null,
            );
        }

        fn childWebviewById(w: *Window, id: i64) ?*ChildWebview {
            for (w.child_webviews.items) |c| {
                if (c.id == id) return c;
            }
            return null;
        }

        /// UI 线程：释放子 webview（COM 引用 + 子 HWND）。从槽移除后调用。
        fn destroyChildWebview(c: *ChildWebview) void {
            if (c.webview) |wv| _ = wv.lpVtbl.Release(wv);
            if (c.controller) |ctl| _ = ctl.lpVtbl.Release(ctl);
            if (c.env) |e| _ = e.lpVtbl.Release(e);
            if (c.pending_url) |u| std.heap.page_allocator.free(u);
            if (c.partition) |p| std.heap.page_allocator.free(p);
            if (c.hwnd != null) _ = win32.DestroyWindow(c.hwnd);
            std.heap.page_allocator.destroy(c);
        }

        /// v0.1.17：查找已创建的分区 Environment（同名复用 → 同分区共享存储）。
        fn findPartition(self: *Self, name: []const u8) ?*wv2.ICoreWebView2Environment {
            for (self.partitions.items) |pe| {
                if (std.mem.eql(u8, pe.name, name)) return pe.env;
            }
            return null;
        }

        /// v0.1.17：为子 webview 建独立 Environment（独立 user data folder）。
        /// 目录：`<profile 目录>\WebView2-partitions\<name>`；profile 目录形如
        /// `%LOCALAPPDATA%\<app_id>\WebView2`。
        fn beginPartitionEnv(self: *Self, w: *Window, c: *ChildWebview, name: []const u8) void {
            const rt = if (self.runtime) |*r| r else {
                log.print("[webviews] partition '{s}' failed: runtime missing", .{name});
                return;
            };
            const profile = app_data.profileDirectory(self.allocator, config.app_id, config.migrate_legacy_profile) catch {
                log.print("[webviews] partition '{s}' failed: profile dir", .{name});
                return;
            };
            defer self.allocator.free(profile);
            const root = std.fmt.allocPrint(self.allocator, "{s}\\WebView2-partitions", .{profile}) catch return;
            defer self.allocator.free(root);
            const dir = std.fmt.allocPrint(self.allocator, "{s}\\{s}", .{ root, name }) catch return;
            defer self.allocator.free(dir);
            // 父目录 + 分区目录（已存在返回 false，忽略）
            {
                const root_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, root) catch return;
                defer self.allocator.free(root_w);
                _ = win32.CreateDirectoryW(root_w.ptr, null);
                const dir_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, dir) catch return;
                defer self.allocator.free(dir_w);
                _ = win32.CreateDirectoryW(dir_w.ptr, null);
            }
            const dir_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, dir) catch return;
            defer self.allocator.free(dir_w);

            const handler = PartitionEnvCompletedHandler.create(self, w, c, name) catch return;
            const hr = loader.createEnvironment(rt, dir_w.ptr, null, handler);
            handler.dropRef();
            if (com.failed(hr)) {
                log.print("[webviews] partition '{s}' createEnvironment hr=0x{x}", .{ name, @as(u32, @bitCast(hr)) });
            }
        }

        /// v0.3.2：无痕子 webview（Environment10 ControllerOptions；老运行时回退普通 controller）。
        fn beginChildIncognitoController(self: *Self, w: *Window, c: *ChildWebview, env: *wv2.ICoreWebView2Environment) void {
            const env10 = wv2.ICoreWebView2Environment10.fromEnvironment(env) orelse {
                log.print("[webviews] child #{d}: runtime lacks Environment10, incognito falls back", .{c.id});
                return self.beginChildController(w, c, env);
            };
            defer env10.release();
            const created = env10.createControllerOptions();
            if (com.failed(created.hr) or created.options == null) {
                log.print("[webviews] child #{d}: ControllerOptions failed hr=0x{x}", .{ c.id, @as(u32, @bitCast(created.hr)) });
                return self.beginChildController(w, c, env);
            }
            const copts = created.options.?;
            defer copts.release();
            _ = copts.putInPrivateMode(true);
            const handler = ControllerCompletedHandler.createChild(self, w, c) catch {
                log.print("[webviews] child handler alloc failed", .{});
                return;
            };
            const hr = env10.createControllerWithOptions(c.hwnd, copts, handler);
            handler.dropRef();
            if (com.failed(hr)) {
                log.print("[webviews] child #{d} incognito controller failed hr=0x{x}", .{ c.id, @as(u32, @bitCast(hr)) });
            }
        }

        /// 用指定 Environment 给子 HWND 建 controller（共享/分区共用）。
        fn beginChildController(self: *Self, w: *Window, c: *ChildWebview, env: *wv2.ICoreWebView2Environment) void {
            const handler = ControllerCompletedHandler.createChild(self, w, c) catch {
                log.print("[webviews] child handler alloc failed", .{});
                return;
            };
            const hr = env.createController(c.hwnd, handler);
            handler.dropRef();
            if (com.failed(hr)) {
                log.print("[webviews] child controller create failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            }
        }

        /// v0.1.17：在子 webview 内执行脚本。**异步 + 延后**：立即返回
        /// {pending:true}，真正的 ExecuteScript 用 WM_ZILT_EVAL marshal 到消息循环，
        /// 结果经 `webviewEval` 事件回传。
        /// 直接在 WebMessageReceived 回调里调 ExecuteScript 会触发 WebView2 内部
        /// 重入（实测 segfault in EmbeddedBrowserWebView.dll），所以必须延后。
        fn beginChildEval(self: *Self, w: *Window, c: *ChildWebview, req: shared_system.WebviewEval, alloc: std.mem.Allocator) !shared_system.Result {
            _ = self;
            _ = alloc;
            const a = std.heap.page_allocator;
            const job = a.create(EvalJob) catch return error.OutOfMemory;
            job.* = .{
                .window_id = w.id,
                .child_id = c.id,
                .rid = req.rid,
                .script = a.dupe(u8, req.script) catch {
                    a.destroy(job);
                    return error.OutOfMemory;
                },
            };
            if (win32.PostMessageW(w.hwnd, WM_ZILT_EVAL, 0, @bitCast(@intFromPtr(job))) == 0) {
                a.free(job.script);
                a.destroy(job);
                return error.WebviewEvalFailed;
            }
            return .{ .json = try std.fmt.allocPrint(a, "{{\"pending\":true,\"rid\":{d}}}", .{req.rid}) };
        }

        /// WM_ZILT_EVAL 处理：在消息循环里执行子 webview 脚本（无 COM 重入）。
        fn runEvalJob(self: *Self, job: *EvalJob) void {
            const a = std.heap.page_allocator;
            defer {
                a.free(job.script);
                a.destroy(job);
            }
            const w = self.windowById(job.window_id) orelse return;
            const c = childWebviewById(w, job.child_id) orelse return;
            const wv = c.webview orelse return;
            const script_w = std.unicode.utf8ToUtf16LeAllocZ(a, job.script) catch return;
            defer a.free(script_w);
            const handler = EvalCompletedHandler.create(a, w, job.rid, c.id) catch return;
            const hr = wv.lpVtbl.ExecuteScript(wv, script_w.ptr, handler);
            handler.dropRef();
            if (com.failed(hr)) log.print("[webviews] child #{d} eval hr=0x{x}", .{ c.id, @as(u32, @bitCast(hr)) });
        }

        /// create/remove/navigate/setBounds/focus/list/eval。create 同步建子 HWND
        /// 并返回 id；controller 异步就绪（见 onChildControllerReady），期间的
        /// navigate 排队。带 partition 时先异步建独立 Environment（更慢一步）。
        fn runWebviewsOp(self: *Self, w: *Window, op: shared_system.WebviewsOp, alloc: std.mem.Allocator) !shared_system.Result {
            const env = self.env orelse return error.WebviewEnvNotReady;
            switch (op) {
                .create => |req| {
                    const id = w.next_child_webview_id;
                    w.next_child_webview_id += 1;
                    if (self.child_class_w == null and !self.registerChildWebviewClass()) {
                        return error.WebviewChildFailed;
                    }
                    const child_hwnd = self.createChildHwnd(w.hwnd, req.x, req.y, req.width, req.height) orelse return error.WebviewChildFailed;
                    const c = std.heap.page_allocator.create(ChildWebview) catch {
                        _ = win32.DestroyWindow(child_hwnd);
                        return error.OutOfMemory;
                    };
                    c.* = .{ .id = id, .hwnd = child_hwnd };
                    if (req.url.len > 0) {
                        c.pending_url = std.heap.page_allocator.dupe(u8, req.url) catch null;
                    }
                    // v0.1.17：数据分区（同名复用已有 Environment）
                    const part_name: ?[]u8 = blk: {
                        const raw = req.partition orelse break :blk null;
                        if (raw.len == 0) break :blk null;
                        const sane = sanitizePartition(self.allocator, raw) catch break :blk null;
                        break :blk std.heap.page_allocator.dupe(u8, sane) catch null;
                    };
                    c.partition = part_name;
                    c.incognito = req.incognito and part_name == null; // incognito 优先（partition 忽略）
                    w.child_webviews.append(self.allocator, c) catch {
                        if (part_name) |p| std.heap.page_allocator.free(p);
                        std.heap.page_allocator.destroy(c);
                        _ = win32.DestroyWindow(child_hwnd);
                        return error.OutOfMemory;
                    };

                    if (part_name) |pname| {
                        if (self.findPartition(pname)) |pe| {
                            c.env = pe;
                            _ = pe.lpVtbl.AddRef(pe);
                            log.print("[webviews] child #{d} reuse partition '{s}'", .{ id, pname });
                            self.beginChildController(w, c, pe);
                            return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"partition\":\"{s}\",\"queued\":false}}", .{ id, pname }) };
                        }
                        self.beginPartitionEnv(w, c, pname);
                        log.print("[webviews] child #{d} created with partition '{s}' (env pending)", .{ id, pname });
                        return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"partition\":\"{s}\",\"queued\":true}}", .{ id, pname }) };
                    }

                    if (c.incognito) {
                        self.beginChildIncognitoController(w, c, env);
                    } else {
                        const handler = ControllerCompletedHandler.createChild(self, w, c) catch {
                            log.print("[webviews] child handler alloc failed", .{});
                            return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d}}}", .{id}) };
                        };
                        const hr = env.createController(child_hwnd, handler);
                        handler.dropRef();
                        if (com.failed(hr)) {
                            log.print("[webviews] child controller create failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
                        }
                    }
                    log.print("[webviews] child #{d} created on window #{d} ({d}x{d}@{d},{d}) url={s}", .{
                        id, w.id, req.width, req.height, req.x, req.y, req.url,
                    });
                    return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d}}}", .{id}) };
                },
                .remove => |id| {
                    for (w.child_webviews.items, 0..) |c, i| {
                        if (c.id == id) {
                            _ = w.child_webviews.swapRemove(i);
                            destroyChildWebview(c);
                            log.print("[webviews] child #{d} removed", .{id});
                            return .{ .ok = true };
                        }
                    }
                    return .{ .ok = false };
                },
                .navigate => |req| {
                    const c = childWebviewById(w, req.id) orelse return .{ .ok = false };
                    const url_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, req.url) catch return error.OutOfMemory;
                    defer self.allocator.free(url_w);
                    if (c.webview) |wv| {
                        const hr = wv.lpVtbl.Navigate(wv, url_w.ptr);
                        log.print("[webviews] child #{d} navigate {s} hr=0x{x}", .{ req.id, req.url, @as(u32, @bitCast(hr)) });
                        return .{ .ok = com.failed(hr) == false };
                    }
                    // controller 未就绪：排队，onChildControllerReady 里导航
                    if (c.pending_url) |old| self.allocator.free(old);
                    c.pending_url = self.allocator.dupe(u8, req.url) catch null;
                    return .{ .ok = true };
                },
                .set_bounds => |req| {
                    const c = childWebviewById(w, req.id) orelse return .{ .ok = false };
                    _ = win32.SetWindowPos(c.hwnd, null, req.x, req.y, req.width, req.height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
                    return .{ .ok = true };
                },
                .focus => |id| {
                    const c = childWebviewById(w, id) orelse return .{ .ok = false };
                    _ = win32.SetFocus(c.hwnd);
                    return .{ .ok = true };
                },
                .list => {
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(alloc);
                    try out.append(alloc, '[');
                    for (w.child_webviews.items, 0..) |c, i| {
                        if (i != 0) try out.append(alloc, ',');
                        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"ready\":{s},\"partition\":{s}}}", .{
                            c.id,
                            if (c.webview != null) "true" else "false",
                            if (c.partition) |p| try std.json.Stringify.valueAlloc(alloc, p, .{}) else "null",
                        }));
                    }
                    try out.append(alloc, ']');
                    return .{ .json = try out.toOwnedSlice(alloc) };
                },
                .eval => |req| {
                    const c = childWebviewById(w, req.id) orelse return .{ .ok = false };
                    return self.beginChildEval(w, c, req, alloc);
                },
            }
        }

        // ---- v0.1.16：子进程执行 ----

        fn procById(self: *Self, id: i64) ?*ProcSlot {
            for (self.procs.items) |p| {
                if (p.id == id) return p;
            }
            return null;
        }

        /// v0.1.17：SQL（SQLite）。UI 线程同步执行（典型查询毫秒级）；
        /// sqlite3.dll 动态加载，缺失返回 SqliteNotFound → 前端收到明确错误。
        fn runSqlOp(self: *Self, op: shared_system.SqlOp, alloc: std.mem.Allocator) !shared_system.Result {
            _ = self;
            if (op == .migrate) {
                const m = op.migrate;
                win_sqlite.migrate(alloc, m.db, m.statements, m.version) catch |e| {
                    log.print("[sql] migrate failed: {s} (db={s})", .{ @errorName(e), m.db });
                    return error.SqliteFailed;
                };
                log.print("[sql] migrated to v{d} ({d} statements)", .{ m.version, m.statements.len });
                return .{ .ok = true };
            }
            const q = switch (op) {
                .query => |x| x,
                .execute => |x| x,
                .migrate => unreachable,
            };
            const want_rows = switch (op) {
                .query => true,
                .execute, .migrate => false,
            };
            const out = win_sqlite.run(alloc, q.db, q.sql, q.params, want_rows) catch |e| {
                log.print("[sql] {s} failed: {s} (db={s})", .{ @tagName(op), @errorName(e), q.db });
                return error.SqliteFailed;
            };
            return .{ .json = out };
        }

        /// spawn/kill/list。spawn 立即返回（worker 线程负责 spawn→读输出→wait，
        /// stdout/stderr/exit 全走 processEvent 事件）。受 .command ACL 管控。
        fn runProcOp(self: *Self, op: shared_system.ProcessOp, alloc: std.mem.Allocator) !shared_system.Result {
            const a = std.heap.page_allocator;
            switch (op) {
                .spawn => |req| {
                    const w = self.mainWindow() orelse return error.NoMainWindow;
                    if (req.argv.len == 0) return error.MissingCommand;
                    const exe_name = procBaseName(req.argv[0]);
                    if (!self.aclAllowed("shell", exe_name)) {
                        log.print("[acl] shell denied: {s}", .{req.argv[0]});
                        return error.PermissionDenied;
                    }
                    const slot = a.create(ProcSlot) catch return error.OutOfMemory;
                    // argv/cwd 拷贝到 page_allocator（worker 生命周期内有效）
                    const argv_copy = a.alloc([]u8, req.argv.len) catch {
                        a.destroy(slot);
                        return error.OutOfMemory;
                    };
                    var ok = true;
                    for (req.argv, 0..) |arg, i| {
                        argv_copy[i] = a.dupe(u8, arg) catch {
                            ok = false;
                            break;
                        };
                    }
                    if (!ok) {
                        for (argv_copy) |arg| a.free(arg);
                        a.free(argv_copy);
                        a.destroy(slot);
                        return error.OutOfMemory;
                    }
                    const cwd_copy: ?[]u8 = if (req.cwd) |c| a.dupe(u8, c) catch null else null;
                    slot.* = .{ .id = req.id, .hwnd = w.hwnd };
                    self.procs.append(self.allocator, slot) catch {
                        for (argv_copy) |arg| a.free(arg);
                        a.free(argv_copy);
                        if (cwd_copy) |c| a.free(c);
                        a.destroy(slot);
                        return error.OutOfMemory;
                    };
                    const t = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, procWorker, .{ slot, argv_copy, cwd_copy }) catch {
                        for (self.procs.items, 0..) |p, i| {
                            if (p == slot) {
                                _ = self.procs.swapRemove(i);
                                break;
                            }
                        }
                        for (argv_copy) |arg| a.free(arg);
                        a.free(argv_copy);
                        if (cwd_copy) |c| a.free(c);
                        a.destroy(slot);
                        log.print("[proc] spawn worker failed (id={d})", .{req.id});
                        return error.ProcSpawnFailed;
                    };
                    slot.worker = t;
                    log.print("[proc] spawn id={d} argv0={s} dispatched", .{ req.id, req.argv[0] });
                    return .{ .ok = true };
                },
                .kill => |req| {
                    const slot = self.procById(req.id) orelse return .{ .ok = false };
                    const handle = slot.child.id orelse return .{ .ok = false };
                    _ = win32.TerminateProcess(handle, req.exit_code);
                    log.print("[proc] kill id={d} code={d}", .{ req.id, req.exit_code });
                    return .{ .ok = true };
                },
                .list => {
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(alloc);
                    try out.append(alloc, '[');
                    for (self.procs.items, 0..) |p, i| {
                        if (i != 0) try out.append(alloc, ',');
                        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"alive\":{s}}}", .{
                            p.id, if (p.dead) "false" else "true",
                        }));
                    }
                    try out.append(alloc, ']');
                    return .{ .json = try out.toOwnedSlice(alloc) };
                },
            }
        }

        // ---- v0.1.16：应用服务 ----

        /// 按 Config 声明的顺序注册并启动；单个失败只记录，不阻断启动
        /// （服务失败不应该让整个应用起不来，与 startAll 的回滚语义配合）。
        fn initServices(self: *Self) void {
            const declared = config.services;
            self.services = shared_services.Registry.init(self.allocator);

            for (declared) |svc| {
                self.services.?.register(svc) catch |err| {
                    log.print("[services] register '{s}' failed: {s}", .{ svc.name, @errorName(err) });
                };
            }
            if (declared.len > 0) {
                self.services.?.startAll() catch |err| {
                    log.print("[services] startAll failed: {s}", .{@errorName(err)});
                };
                log.print("[services] {d} registered, {d} started", .{ self.services.?.count(), self.startedServiceCount() });
            }
        }

        fn startedServiceCount(self: *Self) usize {
            const reg = if (self.services) |*r| r else return 0;
            var n: usize = 0;
            for (reg.slots.items) |slot| {
                if (slot.started) n += 1;
            }
            return n;
        }

        fn runServicesOp(self: *Self, op: shared_system.ServicesOp, alloc: std.mem.Allocator) !shared_system.Result {
            const reg = if (self.services) |*r| r else return error.ServicesNotAvailable;
            switch (op) {
                .list => {
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(alloc);
                    try out.append(alloc, '[');
                    for (reg.slots.items, 0..) |slot, i| {
                        if (i != 0) try out.append(alloc, ',');
                        try appendServiceJson(alloc, &out, slot.service.name, slot.service.scope, slot.started);
                    }
                    try out.append(alloc, ']');
                    return .{ .json = try out.toOwnedSlice(alloc) };
                },
                .status => |name| {
                    const svc = reg.get(name) orelse return .{ .json = try alloc.dupe(u8, "null") };
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(alloc);
                    try appendServiceJson(alloc, &out, svc.name, svc.scope, reg.isStarted(name));
                    return .{ .json = try out.toOwnedSlice(alloc) };
                },
                .start => |name| {
                    reg.start(name) catch |err| {
                        log.print("[services] start '{s}' failed: {s}", .{ name, @errorName(err) });
                        return .{ .ok = false };
                    };
                    log.print("[services] started '{s}'", .{name});
                    return .{ .ok = true };
                },
                .stop => |name| {
                    const known = reg.get(name) != null;
                    reg.stop(name);
                    log.print("[services] stopped '{s}' (known={})", .{ name, known });
                    return .{ .ok = known };
                },
            }
        }

        fn runWindowStateOp(self: *Self, w: *Window, op: shared_system.WindowStateOp, alloc: std.mem.Allocator) !shared_system.Result {
            switch (op) {
                .save => {
                    self.saveWindowState(w);
                    log.print("[window-state] saved on demand", .{});
                    return .{ .ok = true };
                },
                .get => {
                    var rect: win32.RECT = undefined;
                    if (win32.GetWindowRect(w.hwnd, &rect) == 0) return error.WindowNotFound;
                    const maximized = win32.IsZoomed(w.hwnd) != 0;
                    return .{ .json = try std.fmt.allocPrint(
                        alloc,
                        "{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"maximized\":{}}}",
                        .{ rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, maximized },
                    ) };
                },
            }
        }

        fn runStoreOp(self: *Self, op: shared_system.StoreOp, alloc: std.mem.Allocator) !shared_system.Result {
            const st = if (self.store) |*v| v else return error.StoreNotAvailable;
            switch (op) {
                .get => |key| {
                    const v = st.get(key) orelse return .{ .json = try alloc.dupe(u8, "null") };
                    // v0.3.5：dpapi: 前缀值自动解密（store_encrypted 写入的混合形态）
                    if (std.mem.startsWith(u8, v, dpapi_mod.prefix)) {
                        const plain = dpapi_mod.decrypt(alloc, v) catch |err| {
                            log.print("[store] decrypt '{s}' failed: {s}", .{ key, @errorName(err) });
                            return .{ .json = try alloc.dupe(u8, "null") };
                        };
                        defer alloc.free(plain);
                        return .{ .json = try std.json.Stringify.valueAlloc(alloc, plain, .{}) };
                    }
                    return .{ .json = try std.json.Stringify.valueAlloc(alloc, v, .{}) };
                },
                .set => |kv| {
                    // v0.3.5：store_encrypted → DPAPI 加密（当前用户作用域；dpapi: 前缀）
                    if (config.store_encrypted) {
                        const enc = dpapi_mod.encrypt(alloc, kv.value) catch |err| {
                            log.print("[store] encrypt '{s}' failed: {s}", .{ kv.key, @errorName(err) });
                            return error.StoreEncryptFailed;
                        };
                        defer alloc.free(enc);
                        try st.set(kv.key, enc);
                    } else {
                        try st.set(kv.key, kv.value);
                    }
                    self.persistStore();
                    log.print("[store] set {s} ({d} keys)", .{ kv.key, st.count() });
                    return .{ .ok = true };
                },
                .remove => |key| {
                    const removed = st.remove(key);
                    if (removed) self.persistStore();
                    return .{ .ok = removed };
                },
                .keys => {
                    const keys = try st.keys(alloc);
                    defer alloc.free(keys);
                    return .{ .json = try std.json.Stringify.valueAlloc(alloc, keys, .{}) };
                },
                .all => return .{ .json = try st.toJson(alloc) },
            }
        }

        fn fsExists(self: *Self, alloc: std.mem.Allocator, rel: []const u8) bool {
            const root = self.storage_root orelse return false;
            const path = fs_api_mod.joinChecked(alloc, root, rel) catch return false;
            defer alloc.free(path);
            const wz = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
            defer alloc.free(wz);
            return win32.GetFileAttributesW(wz.ptr) != 0xFFFFFFFF;
        }

        /// v0.1.19：解析 scope 根目录（绝对路径）。
        fn scopeRoot(self: *Self, scope: fs_api_mod.Scope, alloc: std.mem.Allocator) ?[]u8 {
            switch (scope) {
                .app_data => {
                    const base = self.storage_root orelse return null;
                    return alloc.dupe(u8, base) catch null;
                },
                .app_cache => {
                    const base = self.storage_root orelse return null;
                    return std.fmt.allocPrint(alloc, "{s}\\cache", .{base}) catch null;
                },
                .app_config => {
                    const appdata = win32.getEnvUtf8(alloc, "APPDATA") orelse return null;
                    defer alloc.free(appdata);
                    return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ appdata, config.app_id }) catch null;
                },
                .temp => return win32.getEnvUtf8(alloc, "TEMP"),
                .exe => return exeDirAlloc(alloc),
                .home => return win32.getEnvUtf8(alloc, "USERPROFILE"),
                else => {
                    const home = win32.getEnvUtf8(alloc, "USERPROFILE") orelse return null;
                    defer alloc.free(home);
                    const sub = fs_api_mod.userSubdir(scope) orelse return null;
                    return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ home, sub }) catch null;
                },
            }
        }

        /// v0.1.19：fs scope 授权。appData/appConfig/appCache 默认可用；其它根目录
        /// 需要 capability 显式声明 `"fs:documents/**"` 之类的模式。
        fn fsAllowed(self: *Self, scope: fs_api_mod.Scope, rel: []const u8, alloc: std.mem.Allocator) bool {
            if (scope.isAppPrivate()) return true;
            const res = fs_api_mod.resourceString(alloc, scope, rel) catch return false;
            defer alloc.free(res);
            return self.aclAllowed("fs", res);
        }

        fn fsScopeOf(name: ?[]const u8) !fs_api_mod.Scope {
            const n = name orelse return .app_data;
            if (n.len == 0) return .app_data;
            return fs_api_mod.Scope.fromName(n) catch error.UnknownScope;
        }

        /// v0.1.19：fs 全量操作（读/写/追加/存在/删除/建目录/递归删目录/列目录/
        /// stat/改名/复制/根目录清单）。所有相对路径都经过 scope 校验与逃逸检查。
        fn runFsOp(self: *Self, op: shared_system.FsOp, alloc: std.mem.Allocator) !shared_system.Result {
            switch (op) {
                .watch => |req| {
                    const scope = try fsScopeOf(req.scope);
                    if (!self.fsAllowed(scope, req.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const dir = if (req.path.len == 0 or std.mem.eql(u8, req.path, "."))
                        try alloc.dupe(u8, root)
                    else
                        try fs_api_mod.joinChecked(alloc, root, req.path);
                    defer alloc.free(dir);

                    const dw = try std.unicode.utf8ToUtf16LeAllocZ(alloc, dir);
                    defer alloc.free(dw);
                    const attr = win32.GetFileAttributesW(dw.ptr);
                    if (attr == win32.INVALID_FILE_ATTRIBUTES) return error.FileNotFound;
                    if (attr & win32.FILE_ATTRIBUTE_DIRECTORY == 0) return error.NotADirectory;
                    const handle = win32.CreateFileW(
                        dw.ptr,
                        win32.FILE_LIST_DIRECTORY,
                        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
                        null,
                        win32.OPEN_EXISTING,
                        win32.FILE_FLAG_BACKUP_SEMANTICS,
                        null,
                    );
                    if (handle == win32.INVALID_HANDLE_VALUE) return error.WatchFailed;

                    const pa = std.heap.page_allocator;
                    const wv = pa.create(FsWatch) catch {
                        _ = win32.CloseHandle(handle);
                        return error.OutOfMemory;
                    };
                    const id = self.next_fs_watch_id;
                    self.next_fs_watch_id += 1;
                    wv.* = .{ .id = id, .hwnd = self.mainWindowHwnd(), .handle = handle, .recursive = req.recursive };
                    const t = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, fsWatchMain, .{wv}) catch {
                        _ = win32.CloseHandle(handle);
                        pa.destroy(wv);
                        return error.WatchFailed;
                    };
                    wv.thread = t;
                    try self.fs_watches.append(self.allocator, wv);
                    log.print("[fs] watch #{d} {s} recursive={}", .{ id, dir, req.recursive });
                    return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d}}}", .{id}) };
                },
                .unwatch => |id| {
                    for (self.fs_watches.items, 0..) |wv, i| {
                        if (wv.id != id) continue;
                        _ = self.fs_watches.swapRemove(i);
                        self.stopFsWatch(wv);
                        return .{ .ok = true };
                    }
                    return .{ .ok = false };
                },
                .read_stream => |req| {
                    const scope = try fsScopeOf(req.scope);
                    if (!self.fsAllowed(scope, req.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, req.path);
                    defer alloc.free(path);
                    if (fileSizeOf(alloc, path) == null) return error.FileNotFound;

                    const a2 = std.heap.page_allocator;
                    const job = a2.create(FsStreamJob) catch return error.OutOfMemory;
                    const id = self.next_fs_stream_id;
                    self.next_fs_stream_id += 1;
                    job.* = .{
                        .id = id,
                        .hwnd = self.mainWindowHwnd(),
                        .path = a2.dupe(u8, path) catch {
                            a2.destroy(job);
                            return error.OutOfMemory;
                        },
                        .chunk_size = @min(@max(req.chunk_size, 4096), 1024 * 1024),
                    };
                    const t = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, fsStreamMain, .{job}) catch {
                        a2.free(job.path);
                        a2.destroy(job);
                        return error.SpawnFailed;
                    };
                    t.detach();
                    log.print("[fs] readStream #{d} {s} chunk={d}", .{ id, path, job.chunk_size });
                    return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d}}}", .{id}) };
                },
                .roots => {
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(alloc);
                    try out.append(alloc, '{');
                    const scopes = [_]fs_api_mod.Scope{ .app_data, .app_config, .app_cache, .home, .desktop, .documents, .downloads, .pictures, .videos, .temp, .exe };
                    var first = true;
                    for (scopes) |s| {
                        const r = self.scopeRoot(s, alloc) orelse continue;
                        defer alloc.free(r);
                        if (!first) try out.append(alloc, ',');
                        first = false;
                        try out.print(alloc, "\"{s}\":", .{s.name()});
                        const lit = try std.json.Stringify.valueAlloc(alloc, r, .{});
                        defer alloc.free(lit);
                        try out.appendSlice(alloc, lit);
                    }
                    try out.append(alloc, '}');
                    return .{ .json = try out.toOwnedSlice(alloc) };
                },
                .read => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    const size = fileSizeOf(alloc, path) orelse return error.FileNotFound;
                    if (size > (fs_api_mod.Limits{}).max_read) return error.FileTooLarge;
                    const bytes = win32.readFileAlloc(alloc, path) orelse return error.FileNotFound;
                    defer alloc.free(bytes);
                    return .{ .json = try std.json.Stringify.valueAlloc(alloc, bytes, .{}) };
                },
                .write => |w| return self.fsWriteOp(w, false, alloc),
                .append => |w| return self.fsWriteOp(w, true, alloc),
                .rename => |m| return self.fsTransferOp(m, false, alloc),
                .copy => |m| return self.fsTransferOp(m, true, alloc),
                .exists => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
                    defer alloc.free(w);
                    return .{ .ok = win32.GetFileAttributesW(w.ptr) != win32.INVALID_FILE_ATTRIBUTES };
                },
                .remove => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
                    defer alloc.free(w);
                    return .{ .ok = win32.DeleteFileW(w.ptr) != 0 };
                },
                .mkdir => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    return .{ .ok = mkdirAllPath(alloc, path) };
                },
                .remove_dir => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    return .{ .ok = deleteTree(alloc, path) };
                },
                .read_dir => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    return .{ .json = try listDirJson(alloc, path) };
                },
                .stat => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    return .{ .json = statJson(alloc, path) orelse return error.FileNotFound };
                },

            }
        }

        /// fs write / append 共用实现。
        fn fsWriteOp(self: *Self, w: shared_system.FsWrite, append: bool, alloc: std.mem.Allocator) !shared_system.Result {
            const scope = try fsScopeOf(w.scope);
            if (!self.fsAllowed(scope, w.path, alloc)) return error.PermissionDenied;
            if (w.data.len > (fs_api_mod.Limits{}).max_write) return error.FileTooLarge;
            const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
            defer alloc.free(root);
            const path = try fs_api_mod.joinChecked(alloc, root, w.path);
            defer alloc.free(path);
            if (std.mem.lastIndexOfScalar(u8, path, '\\')) |sep| {
                _ = mkdirAllPath(alloc, path[0..sep]);
            }
            if (append and fileSizeOf(alloc, path) != null) {
                const old = win32.readFileAlloc(alloc, path) orelse return error.WriteFailed;
                defer alloc.free(old);
                const merged = try std.mem.concat(alloc, u8, &.{ old, w.data });
                defer alloc.free(merged);
                if (!win32.writeFileAlloc(alloc, path, merged)) return error.WriteFailed;
            } else if (!win32.writeFileAlloc(alloc, path, w.data)) {
                return error.WriteFailed;
            }
            log.print("[fs] {s} {d} bytes -> {s}/{s}", .{
                if (append) "appended" else "wrote", w.data.len, scope.name(), w.path,
            });
            return .{ .ok = true };
        }

        /// fs rename / copy 共用实现。
        fn fsTransferOp(self: *Self, m: shared_system.FsMove, is_copy: bool, alloc: std.mem.Allocator) !shared_system.Result {
            const from_scope = try fsScopeOf(m.scope);
            const to_scope = try fsScopeOf(m.to_scope orelse m.scope);
            if (!self.fsAllowed(from_scope, m.from, alloc)) return error.PermissionDenied;
            if (!self.fsAllowed(to_scope, m.to, alloc)) return error.PermissionDenied;
            const from_root = self.scopeRoot(from_scope, alloc) orelse return error.ScopeUnavailable;
            defer alloc.free(from_root);
            const to_root = self.scopeRoot(to_scope, alloc) orelse return error.ScopeUnavailable;
            defer alloc.free(to_root);
            const from = try fs_api_mod.joinChecked(alloc, from_root, m.from);
            defer alloc.free(from);
            const to = try fs_api_mod.joinChecked(alloc, to_root, m.to);
            defer alloc.free(to);
            if (std.mem.lastIndexOfScalar(u8, to, '\\')) |sep| {
                _ = mkdirAllPath(alloc, to[0..sep]);
            }
            const fw = try std.unicode.utf8ToUtf16LeAllocZ(alloc, from);
            defer alloc.free(fw);
            const tw = try std.unicode.utf8ToUtf16LeAllocZ(alloc, to);
            defer alloc.free(tw);
            const ok = if (is_copy)
                win32.CopyFileW(fw.ptr, tw.ptr, 0) != 0
            else
                win32.MoveFileExW(fw.ptr, tw.ptr, win32.MOVEFILE_REPLACE_EXISTING) != 0;
            return .{ .ok = ok };
        }

        /// v0.1.19：更新器 JS API。info 读当前配置与「是否已有待重启的替换」；
        /// check 复用启动时的 updaterFlow（后台线程，结果走 updateInfo/updaterFailed 事件）。
        fn mainWindowHwnd(self: *Self) win32.HWND {
            if (self.mainWindow()) |w| return w.hwnd;
            return null;
        }

        fn stopFsWatch(self: *Self, wv: *FsWatch) void {
            _ = self;
            wv.stopping.store(true, .release);
            // 同步 ReadDirectoryChangesW 会一直阻塞：CancelIoEx 让内核返回
            // ERROR_OPERATION_ABORTED，线程才能退出（只 CloseHandle 不解阻塞）。
            _ = win32.CancelIoEx(wv.handle, null);
            _ = win32.CloseHandle(wv.handle);
            wv.thread.join();
            const id = wv.id;
            std.heap.page_allocator.destroy(wv);
            log.print("[fs] watch #{d} stopped", .{id});
        }

        /// v0.1.21：资源授权（编译期 scopes + 运行时持久化授权）。
        fn aclAllowed(self: *Self, kind: []const u8, resource: []const u8) bool {
            return security.scopeAllowedWith(config.security, self.acl_grants.items, kind, resource);
        }

        fn loadAclGrants(self: *Self) void {
            if (self.acl_loaded) return; // initStorage 可能被多个窗口各调一次
            self.acl_loaded = true;
            const root = self.storage_root orelse return;
            const path = std.fmt.allocPrint(self.allocator, "{s}\\acl.json", .{root}) catch return;
            defer self.allocator.free(path);
            const bytes = win32.readFileAlloc(self.allocator, path) orelse return;
            defer self.allocator.free(bytes);
            var parsed = std.json.parseFromSlice([]const []const u8, self.allocator, bytes, .{}) catch return;
            defer parsed.deinit();
            for (parsed.value) |g| {
                const copy = self.allocator.dupe(u8, g) catch continue;
                self.acl_grants.append(self.allocator, copy) catch self.allocator.free(copy);
            }
            log.print("[acl] loaded {d} grants", .{self.acl_grants.items.len});
        }

        fn saveAclGrants(self: *Self) void {
            const root = self.storage_root orelse return;
            const path = std.fmt.allocPrint(self.allocator, "{s}\\acl.json", .{root}) catch return;
            defer self.allocator.free(path);
            const json = std.json.Stringify.valueAlloc(self.allocator, self.acl_grants.items, .{}) catch return;
            defer self.allocator.free(json);
            if (!win32.writeFileAlloc(self.allocator, path, json)) log.print("[acl] save failed", .{});
        }

        /// v0.1.21：acl.list / grant / revoke（grant 落盘，重启后仍生效）。
        fn runAclOp(self: *Self, op: shared_system.AclOp, alloc: std.mem.Allocator) !shared_system.Result {
            switch (op) {
                .list => return .{ .json = try std.json.Stringify.valueAlloc(alloc, self.acl_grants.items, .{}) },
                .grant => |g| {
                    if (g.kind.len == 0 or g.pattern.len == 0) return error.InvalidPattern;
                    const pat = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ g.kind, g.pattern });
                    defer self.allocator.free(pat);
                    for (self.acl_grants.items) |cur| {
                        if (std.mem.eql(u8, cur, pat)) return .{ .ok = true };
                    }
                    const copy = try self.allocator.dupe(u8, pat);
                    errdefer self.allocator.free(copy);
                    try self.acl_grants.append(self.allocator, copy);
                    self.saveAclGrants();
                    log.print("[acl] granted {s}", .{pat});
                    return .{ .ok = true };
                },
                .revoke => |g| {
                    const pat = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ g.kind, g.pattern });
                    defer self.allocator.free(pat);
                    var removed: usize = 0;
                    var i: usize = 0;
                    while (i < self.acl_grants.items.len) {
                        if (!std.mem.eql(u8, self.acl_grants.items[i], pat)) {
                            i += 1;
                            continue;
                        }
                        const old = self.acl_grants.swapRemove(i);
                        self.allocator.free(old);
                        removed += 1;
                    }
                    if (removed == 0) return .{ .ok = false };
                    self.saveAclGrants();
                    log.print("[acl] revoked {s} ({d})", .{ pat, removed });
                    return .{ .ok = true };
                },
            }
        }

        fn runUpdaterOp(self: *Self, op: shared_system.UpdaterOp, alloc: std.mem.Allocator) !shared_system.Result {
            switch (op) {
                .info => {
                    const env = self.updater_env orelse {
                        return .{ .json = try alloc.dupe(u8, "{\"configured\":false}") };
                    };
                    const exe_path = try currentExePath(alloc);
                    defer alloc.free(exe_path);
                    const old_path = try std.fmt.allocPrint(alloc, "{s}.zilt-old", .{exe_path});
                    defer alloc.free(old_path);
                    const ow = try std.unicode.utf8ToUtf16LeAllocZ(alloc, old_path);
                    defer alloc.free(ow);
                    const restart_required = win32.GetFileAttributesW(ow.ptr) != win32.INVALID_FILE_ATTRIBUTES;

                    const url_json = try std.json.Stringify.valueAlloc(alloc, env.manifest_url, .{});
                    defer alloc.free(url_json);
                    const ver_json = try std.json.Stringify.valueAlloc(alloc, env.current_version, .{});
                    defer alloc.free(ver_json);
                    return .{ .json = try std.fmt.allocPrint(alloc,
                        "{{\"configured\":true,\"manifest_url\":{s},\"current_version\":{s},\"channel\":\"{s}\",\"restart_required\":{s}}}",
                        .{ url_json, ver_json, @tagName(env.channel), if (restart_required) "true" else "false" },
                    ) };
                },
                .check => {
                    if (self.updater_env == null) return .{ .ok = false };
                    const t = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, updaterFlow, .{self}) catch |err| {
                        log.print("[updater] manual check spawn failed: {s}", .{@errorName(err)});
                        return .{ .ok = false };
                    };
                    t.detach();
                    log.print("[updater] manual check started (from JS)", .{});
                    return .{ .ok = true };
                },
                // v0.3.4：跳过版本（skipped.json 持久化；updaterFlow 读取）
                .skip => |version| {
                    var io_io = std.Io.Threaded.init(alloc, .{});
                    defer io_io.deinit();
                    const root = self.storage_root orelse return .{ .ok = false };
                    const path = std.fmt.allocPrint(alloc, "{s}\\skipped.json", .{root}) catch return .{ .ok = false };
                    defer alloc.free(path);
                    const body = try std.fmt.allocPrint(alloc, "{{\"version\":\"{s}\"}}", .{version});
                    defer alloc.free(body);
                    var wd = std.Io.Dir.cwd();
                    wd.writeFile(io_io.io(), .{ .sub_path = path, .data = body }) catch {
                        log.print("[updater] skipped.json write failed", .{});
                        return .{ .ok = false };
                    };
                    log.print("[updater] version {s} skipped", .{version});
                    // 立即刷新 env 的 skipped_version（本进程内后续 check 生效）
                    if (self.updater_env) |*env| {
                        env.skipped_version = self.allocator.dupe(u8, version) catch null;
                    }
                    return .{ .ok = true };
                },
            }
        }

        fn rebuildTrayPopup(self: *Self) void {
            const model = if (self.menu_state) |*m| m else return;
            if (self.tray_popup) |*old| old.deinit(self.allocator);
            self.tray_popup = menu_runtime.buildPopup(self.allocator, model, TRAY_MENU_BASE) catch |err| blk: {
                log.print("[tray] popup rebuild failed: {s}", .{@errorName(err)});
                break :blk null;
            };
        }

        fn runMenuOp(self: *Self, w: *Window, op: shared_system.MenuOp, alloc: std.mem.Allocator) !shared_system.Result {
            switch (op) {
                .list => {
                    if (self.menu_state) |*m| return .{ .json = try m.toJson(alloc) };
                    return .{ .json = try alloc.dupe(u8, "[]") };
                },
                .add => |spec| {
                    const model = if (self.menu_state) |*m| m else return error.MenuNotConfigured;
                    _ = try model.add(spec.parent, spec.index, .{
                        .id = spec.id,
                        .label = spec.label,
                        .accel = spec.accel,
                        .checked = spec.checked,
                        .enabled = spec.enabled,
                        .role = spec.role,
                        .icon = spec.icon,
                    });
                    self.rebuildTrayPopup();
                    log.print("[menu] added '{s}' under {s}", .{ spec.label, spec.parent orelse "<root>" });
                    return .{ .ok = true };
                },
                .remove => |path| {
                    const model = if (self.menu_state) |*m| m else return error.MenuNotConfigured;
                    const removed = model.remove(path);
                    if (removed) self.rebuildTrayPopup();
                    log.print("[menu] remove '{s}' (ok={})", .{ path, removed });
                    return .{ .ok = removed };
                },
                .set => |spec| {
                    const model = if (self.menu_state) |*m| m else return error.MenuNotConfigured;
                    var changed = false;
                    if (spec.label) |label| changed = model.setLabel(spec.path, label) or changed;
                    if (spec.checked) |checked| changed = model.setChecked(spec.path, checked) or changed;
                    if (spec.enabled) |enabled| changed = model.setEnabled(spec.path, enabled) or changed;
                    if (spec.accel) |a| changed = model.setAccel(spec.path, a) or changed;
                    if (changed) self.rebuildTrayPopup();
                    log.print("[menu] set '{s}' (changed={})", .{ spec.path, changed });
                    return .{ .ok = changed };
                },
                .popup => |pt| {
                    const built = if (self.tray_popup) |*b| b else return error.MenuNotConfigured;
                    _ = win32.SetForegroundWindow(w.hwnd);
                    const cmd = win32.TrackPopupMenu(built.hmenu, win32.TPM_RIGHTBUTTON | win32.TPM_RETURNCMD, pt.x, pt.y, 0, w.hwnd, null);
                    _ = win32.PostMessageW(w.hwnd, win32.WM_NULL, 0, 0);
                    if (cmd == 0) return .{ .ok = false };
                    const menu_id: u16 = @intCast(cmd & 0xffff);
                    if (built.idFor(menu_id)) |id| {
                        log.print("[menu] popup pick {s}", .{id});
                        if (built.roleFor(menu_id)) |role| {
                            _ = self.dispatchRole(w, role);
                            w.emitEventPayload("menuRole", .{ .id = id, .role = role });
                        }
                        w.emitEventPayload("menu", .{ .id = id });
                    }
                    return .{ .ok = true };
                },
            }
        }

        fn runTrayOp(self: *Self, op: shared_system.TrayOp) void {
            switch (op) {
                .set_tooltip => |text| {
                    if (self.tray) |*t| {
                        const ok = t.setTooltip(text);
                        log.print("[tray] tooltip updated (ok={})", .{ok});
                    }
                },
                .set_icon => |path| {
                    if (self.tray) |*t| {
                        const px: u32 = @intCast(win32.GetSystemMetrics(win32.SM_CXSMICON));
                        const icon = if (path) |p| self.makeIcon(p, px, px) else self.tray_icon;
                        const ok = t.setIcon(icon);
                        log.print("[tray] icon updated (ok={})", .{ok});
                    }
                },
                .set_click => |cfg| {
                    self.tray_click_left = cfg.left;
                    self.tray_click_middle = cfg.middle;
                    self.tray_click_double = cfg.double;
                    log.print("[tray] click behavior updated", .{});
                },
            }
        }

        fn runHotkeyOp(self: *Self, w: *Window, op: shared_system.HotkeyOp, alloc: std.mem.Allocator) !shared_system.Result {
            switch (op) {
                .list => {
                    var entries: std.ArrayListUnmanaged(shared_system.HotkeyEntry) = .empty;
                    defer entries.deinit(alloc);
                    for (self.runtime_hotkeys.items) |hk| {
                        try entries.append(alloc, .{ .id = hk.id, .accel = hk.accel_text });
                    }
                    return .{ .json = try shared_system.hotkeysToJson(alloc, entries.items) };
                },
                .register => |spec| {
                    const parsed = accel_mod.parse(spec.accel) catch return error.InvalidAccel;
                    const flags = parsed.mods.flags();
                    for (self.runtime_hotkeys.items) |hk| {
                        if (hk.vk == parsed.vk and hk.mods == flags) return error.HotkeyConflict;
                    }
                    const id = try self.allocator.dupe(u8, spec.id);
                    errdefer self.allocator.free(id);
                    const text = try self.allocator.dupe(u8, spec.accel);
                    errdefer self.allocator.free(text);

                    const sys_id = self.next_runtime_hotkey_id;
                    if (win32.RegisterHotKey(w.hwnd, @intCast(sys_id), flags, parsed.vk) == 0) {
                        log.print("[hotkey] register failed {s}（可能被其他程序占用）", .{spec.accel});
                        return error.HotkeyRegisterFailed;
                    }
                    self.next_runtime_hotkey_id += 1;
                    try self.runtime_hotkeys.append(self.allocator, .{
                        .id = id,
                        .accel_text = text,
                        .vk = parsed.vk,
                        .mods = flags,
                        .sys_id = sys_id,
                    });
                    log.print("[hotkey] runtime registered {s} = {s}", .{ id, text });
                    return .{ .ok = true };
                },
                .unregister => |id| {
                    for (self.runtime_hotkeys.items, 0..) |hk, i| {
                        if (!std.mem.eql(u8, hk.id, id)) continue;
                        _ = win32.UnregisterHotKey(w.hwnd, @intCast(hk.sys_id));
                        self.allocator.free(hk.id);
                        self.allocator.free(hk.accel_text);
                        _ = self.runtime_hotkeys.orderedRemove(i);
                        log.print("[hotkey] runtime unregistered {s}", .{id});
                        return .{ .ok = true };
                    }
                    return .{ .ok = false };
                },
            }
        }

        /// 返回 ITaskbarList3 是否可用（本机可能只暴露 ITaskbarList/2；
        /// 那时进度/overlay 不可用，但调用仍应正常返回 false 而不是报错）。
        fn runTaskbarOp(self: *Self, w: *Window, op: shared_taskbar.Request, alloc: std.mem.Allocator) !bool {
            // 闪烁走 user32 FlashWindowEx，不依赖 TaskbarList COM，优先处理
            switch (op) {
                .flash => |f| {
                    const ok = win_taskbar.Taskbar.flash(w.hwnd, f);
                    log.print("[taskbar] flash (ok={})", .{ok});
                    return ok;
                },
                else => {},
            }
            if (self.taskbar_list == null) {
                self.taskbar_list = win_taskbar.Taskbar.init() catch |err| {
                    log.print("[taskbar] ITaskbarList3 unavailable: {s}（本机 COM 未暴露该接口）", .{@errorName(err)});
                    return false;
                };
            }
            const tb = &self.taskbar_list.?;
            switch (op) {
                .progress => |p| {
                    tb.setProgress(w.hwnd, p);
                    log.print("[taskbar] progress {s} value={?d}", .{ @tagName(p.state), p.value });
                },
                .overlay => |maybe| {
                    if (maybe) |ov| {
                        const px: u32 = @intCast(win32.GetSystemMetrics(win32.SM_CXSMICON));
                        const icon = if (ov.icon) |path| self.makeIcon(path, px, px) else self.icon_small;
                        tb.setOverlay(w.hwnd, icon, ov.description, alloc);
                    } else {
                        tb.setOverlay(w.hwnd, null, "", alloc);
                    }
                    log.print("[taskbar] overlay updated", .{});
                },
                .tooltip => |text| {
                    tb.setTooltip(w.hwnd, text, alloc);
                },
                .thumb_buttons => |buttons| {
                    var icons = std.mem.zeroes([7]win32.HICON);
                    const n = @min(buttons.len, 7);
                    for (0..n) |i| icons[i] = self.icon_small;
                    const ok = tb.setThumbButtons(w.hwnd, buttons, icons[0..n]);
                    log.print("[taskbar] thumbnail buttons (n={d}, ok={})", .{ n, ok });
                },
                else => {},
            }
            return true;
        }

        fn collectSystemInfo(self: *Self, kind: shared_system.InfoKind, alloc: std.mem.Allocator, w: ?*Window) ![]u8 {
            switch (kind) {
                .os => {
                    var owned = win_sysinfo.collectOs();
                    return shared_sysinfo.osToJson(alloc, owned.toInfo());
                },
                .monitors => {
                    const monitors = try win_sysinfo.collectMonitors(alloc);
                    defer alloc.free(monitors);
                    // v0.3.2：标记调用窗口所在显示器（MonitorFromWindow → 匹配枚举序）
                    self.markCurrentMonitor(monitors, w);
                    return shared_sysinfo.monitorsToJson(alloc, monitors);
                },
                .all => {
                    var owned = win_sysinfo.collectOs();
                    const os_json = try shared_sysinfo.osToJson(alloc, owned.toInfo());
                    defer alloc.free(os_json);
                    const monitors = try win_sysinfo.collectMonitors(alloc);
                    defer alloc.free(monitors);
                    self.markCurrentMonitor(monitors, w);
                    const mons_json = try shared_sysinfo.monitorsToJson(alloc, monitors);
                    defer alloc.free(mons_json);
                    return std.fmt.allocPrint(alloc, "{{\"os\":{s},\"monitors\":{s}}}", .{ os_json, mons_json });
                },
            }
        }

        /// comptime 资产表按路径查找（mask 用）。
        fn assetBytes(path: []const u8) ?[]const u8 {
            for (config.assets) |asset| {
                if (std.mem.eql(u8, asset.path, path)) return asset.content;
            }
            return null;
        }

        /// 窗口形状 mask：PNG 资产 alpha>8 → SetWindowRgn（区域外不渲染/不点击）。
        fn applyWindowMask(alloc: std.mem.Allocator, w: *Window, mask_path: []const u8) void {
            const bytes = assetBytes(mask_path) orelse {
                log.print("[mask] asset '{s}' not found (mask ignored)", .{mask_path});
                return;
            };
            const img = png_mod.decode(alloc, bytes) catch |err| {
                log.print("[mask] decode '{s}' failed: {s}", .{ mask_path, @errorName(err) });
                return;
            };
            defer alloc.free(img.pixels);
            // 逐行扫描 alpha>threshold 的连续段 → 每段一条 rect → CombineRgn 合并
            var region: ?*anyopaque = null;
            const threshold: u8 = 8;
            var y: u32 = 0;
            while (y < img.height) : (y += 1) {
                var x: u32 = 0;
                while (x < img.width) {
                    if (img.pixels[(y * img.width + x) * 4 + 3] > threshold) {
                        const start = x;
                        while (x < img.width and img.pixels[(y * img.width + x) * 4 + 3] > threshold) x += 1;
                        const r = win32.CreateRectRgn(@intCast(start), @intCast(y), @intCast(x), @intCast(y + 1)) orelse continue;
                        if (region) |rgn| {
                            _ = win32.CombineRgn(rgn, rgn, r, win32.RGN_OR);
                            _ = win32.DeleteObject(r);
                        } else {
                            region = r;
                        }
                    } else {
                        x += 1;
                    }
                }
            }
            if (region == null) {
                log.print("[mask] '{s}' fully transparent (mask ignored)", .{mask_path});
                return;
            }
            if (win32.SetWindowRgn(w.hwnd, region, 1) == 0) {
                _ = win32.DeleteObject(@ptrCast(region));
                log.print("[mask] SetWindowRgn failed", .{});
                return;
            }
            // 成功后 region 所有权归系统（窗口销毁时由系统回收）
            log.print("[mask] applied '{s}' ({d}x{d})", .{ mask_path, img.width, img.height });
        }

        // ---------------------------------------------------------------------------
        // 启动参数 / 第二实例转发
        // ---------------------------------------------------------------------------

        /// v0.3.2：把调用窗口所在显示器标记为 current（system.info('monitors')）。
        fn markCurrentMonitor(self: *Self, monitors: []shared_sysinfo.Monitor, w: ?*Window) void {
            _ = self;
            const hwnd = if (w) |win| win.hwnd else return;
            const index = win_sysinfo.monitorIndexOf(hwnd) orelse return;
            for (monitors, 0..) |*m, i| m.current = i == index;
        }

        fn runAutostartOp(self: *Self, op: shared_system.AutostartOp, alloc: std.mem.Allocator) !autostart_mod.State {
            _ = self;
            const exe = try currentExePath(alloc);
            defer alloc.free(exe);
            switch (op) {
                .query => return sys_integration.autostartState(alloc, config.app_id, exe),
                .enable => |args| {
                    const cmd = try sys_integration.autostartEnable(alloc, config.app_id, exe, args);
                    defer alloc.free(cmd);
                    log.print("[autostart] enabled: {s}", .{cmd});
                    return sys_integration.autostartState(alloc, config.app_id, exe);
                },
                .disable => {
                    const ok = sys_integration.autostartDisable(alloc, config.app_id);
                    log.print("[autostart] disabled (ok={})", .{ok});
                    return .{ .enabled = false, .command = null };
                },
                .toggle => {
                    const state = try sys_integration.autostartState(alloc, config.app_id, exe);
                    if (state.command) |c| alloc.free(c);
                    if (state.enabled) {
                        _ = sys_integration.autostartDisable(alloc, config.app_id);
                        log.print("[autostart] toggled off", .{});
                        return .{ .enabled = false, .command = null };
                    }
                    const cmd = try sys_integration.autostartEnable(alloc, config.app_id, exe, null);
                    defer alloc.free(cmd);
                    log.print("[autostart] toggled on: {s}", .{cmd});
                    return sys_integration.autostartState(alloc, config.app_id, exe);
                },
            }
        }

        fn runAction(self: *Self, w: *Window, req: *ActionReq) void {
            switch (req.action) {
                .system => |*a| {
                    a.out = self.runSystem(w, a.req, a.alloc) catch |e| {
                        req.err = e;
                        return;
                    };
                },
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

        /// v0.3.6：SharedBuffer 二进制通道。Environment12.CreateSharedBuffer →
        /// 写载荷 → _17.PostSharedBufferToScript（READ_ONLY）→ JS
        /// 'sharedbufferreceived' 事件（getBuffer() 需在处理器内同步取用）。
        /// 老运行时（无 Environment12/_17）→ error.BinaryNotAvailable。
        /// v0.3.6：postBinary 入口——**必须延后**：PostSharedBufferToScript 在
        /// WebMessageReceived 回调内同步调用会重入（与 v0.1.17 ExecuteScript
        /// 实测同款陷阱）→ WM_ZILT_BINARY marshal 到消息循环再执行。
        fn postBinaryFromBackend(backend_ptr: *anyopaque, window_id: u32, bytes: []const u8, additional_json: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const main = self.mainWindow() orelse return error.WindowNotFound;
            const job = try std.heap.page_allocator.create(BinaryJob);
            job.* = .{
                .window_id = window_id,
                .bytes = std.heap.page_allocator.dupe(u8, bytes) catch {
                    std.heap.page_allocator.destroy(job);
                    return error.OutOfMemory;
                },
                .additional = std.heap.page_allocator.dupe(u8, additional_json) catch {
                    std.heap.page_allocator.free(job.bytes);
                    std.heap.page_allocator.destroy(job);
                    return error.OutOfMemory;
                },
            };
            _ = win32.PostMessageW(main.hwnd, WM_ZILT_BINARY, 0, @bitCast(@intFromPtr(job)));
        }

        const BinaryJob = struct {
            window_id: u32,
            bytes: []u8,
            additional: []u8,
        };

        /// WM_ZILT_BINARY：SharedBuffer 创建 + 写载荷 + PostSharedBufferToScript。
        fn runBinaryPost(self: *Self, job: *BinaryJob) void {
            defer {
                std.heap.page_allocator.free(job.bytes);
                std.heap.page_allocator.free(job.additional);
                std.heap.page_allocator.destroy(job);
            }
            const w = self.windowById(job.window_id) orelse return;
            const webview = w.webview orelse return;
            const env = self.env orelse return;
            const env12 = wv2.ICoreWebView2Environment12.fromEnvironment(env) orelse {
                log.print("[binipc] runtime lacks Environment12", .{});
                return;
            };
            defer env12.release();
            const created = env12.createSharedBuffer(@intCast(job.bytes.len));
            if (com.failed(created.hr) or created.buffer == null) {
                log.print("[binipc] CreateSharedBuffer failed hr=0x{x}", .{@as(u32, @bitCast(created.hr))});
                return;
            }
            const buffer = created.buffer.?;
            defer buffer.release();
            // v0.3.6 实测：get_Buffer 直写后 JS 侧读到全零——改用官方样例的
            // OpenStream + IStream::Write 路径（见 MS 文档 ICoreWebView2_17 示例）。
            // IStream 在 webview2.zig 是 opaque → 局部 vtable 结构直调（slot4=Write）。
            var stream: ?*wv2.IStream = null;
            if (com.failed(buffer.lpVtbl.OpenStream(buffer, &stream)) or stream == null) {
                log.print("[binipc] OpenStream failed", .{});
                return;
            }
            const StreamVTable = extern struct {
                QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) com.HRESULT,
                AddRef: *const fn (*anyopaque) callconv(.c) u32,
                Release: *const fn (*anyopaque) callconv(.c) u32,
                Read: *const fn (*anyopaque, [*]u8, u32, ?*u32) callconv(.c) com.HRESULT,
                Write: *const fn (*anyopaque, [*]const u8, u32, ?*u32) callconv(.c) com.HRESULT,
            };
            const stream_obj: *anyopaque = @ptrCast(@alignCast(stream.?));
            const svtable: *const StreamVTable = @as(*const *const StreamVTable, @ptrCast(@alignCast(stream_obj))).*;
            defer _ = svtable.Release(stream_obj);
            var written: u32 = 0;
            const wr = svtable.Write(stream_obj, job.bytes.ptr, @intCast(job.bytes.len), &written);
            if (com.failed(wr) or written != job.bytes.len) {
                log.print("[binipc] IStream write failed (written={d}/{d})", .{ written, job.bytes.len });
                return;
            }
            const wv17 = wv2.ICoreWebView2_17.fromWebView(webview) orelse {
                log.print("[binipc] runtime lacks ICoreWebView2_17", .{});
                return;
            };
            defer wv17.release();
            const additional_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, job.additional) catch return;
            defer self.allocator.free(additional_w);
            const hr = wv17.postSharedBufferToScript(buffer, wv2.SHARED_BUFFER_ACCESS_READ_ONLY, additional_w.ptr);
            if (com.failed(hr)) {
                log.print("[binipc] PostSharedBufferToScript failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
                return;
            }
            log.print("[binipc] posted {d} bytes (rid from additional)", .{job.bytes.len});
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
                // v0.3.14：list 在 builtin dispatch 就走 window_query_fn（LIST_ALL
                // 哨兵），不会到达这里
                .list => return false,
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
                // v0.3.3：内容区拖拽缩放（SC_SIZE + WM_NCLBUTTONDOWN 到对应 HT 边）
                .resize_dragging => |edge| {
                    const ht: win32.LRESULT = edgeHtFromName(edge) orelse return false;
                    _ = win32.ReleaseCapture();
                    const WM_SYSCOMMAND_LOCAL: win32.UINT = 0x0112;
                    _ = win32.SendMessageW(w.hwnd, WM_SYSCOMMAND_LOCAL, win32.SC_SIZE, @bitCast(@as(isize, @intCast(ht))));
                    return true;
                },
                // v0.3.3：simple fullscreen（Win/Linux 全屏即 borderless 语义；命名对齐 Tauri）
                .simple_fullscreen => |on| {
                    self.setFullscreen(w, on);
                    return true;
                },
                // v0.3.3：运行时每按钮状态
                .button_state => |bs| {
                    applyButtonStates(w.hwnd, bs.closable, bs.minimizable, bs.maximizable);
                    return true;
                },
                // v0.3.3：运行时 move 去抖
                .move_debounce => |ms| {
                    w.move_debounce_ms = ms;
                    return true;
                },
                // ---- v0.3.14：窗口 API 收尾（对齐 Wails/Tauri）----
                // center：居中到最近显示器工作区（工作区几何与 system.info('monitors') 同源）
                .center => {
                    var rc: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
                    _ = win32.GetWindowRect(w.hwnd, &rc);
                    const cur_w: i32 = rc.right - rc.left;
                    const cur_h: i32 = rc.bottom - rc.top;
                    const monitors = win_sysinfo.collectMonitors(self.allocator) catch return false;
                    defer self.allocator.free(monitors);
                    const idx = win_sysinfo.monitorIndexOf(w.hwnd) orelse return false;
                    if (idx >= monitors.len) return false;
                    const m = monitors[idx];
                    const wx: i32 = m.work_x;
                    const wy: i32 = m.work_y;
                    const ww: i32 = @intCast(m.work_width);
                    const wh: i32 = @intCast(m.work_height);
                    const x = wx + @divTrunc(ww - cur_w, 2);
                    const y = wy + @divTrunc(wh - cur_h, 2);
                    _ = win32.SetWindowPos(w.hwnd, null, x, y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER);
                    return true;
                },
                // toggleMaximize：最大化/还原切换
                .toggle_maximize => {
                    _ = win32.ShowWindow(w.hwnd, if (win32.IsZoomed(w.hwnd) != 0) win32.SW_RESTORE else win32.SW_MAXIMIZE);
                    return true;
                },
                // setResizable：WS_THICKFRAME style 位开关 + 框架重算
                .resizable => |on| {
                    const style: win32.DWORD = @bitCast(win32.GetWindowLongW(w.hwnd, win32.GWL_STYLE));
                    const new_style: win32.DWORD = if (on) style | win32.WS_THICKFRAME else style & ~win32.WS_THICKFRAME;
                    if (new_style != style) {
                        _ = win32.SetWindowLongW(w.hwnd, win32.GWL_STYLE, @bitCast(new_style));
                        _ = win32.SetWindowPos(w.hwnd, null, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED);
                    }
                    return true;
                },
                // setDecorations：标题栏/边框 style 位开关（客户区 webview 随 WM_SIZE 铺满）
                .decorated => |on| {
                    const style: win32.DWORD = @bitCast(win32.GetWindowLongW(w.hwnd, win32.GWL_STYLE));
                    const deco: win32.DWORD = win32.WS_CAPTION | win32.WS_THICKFRAME | win32.WS_MINIMIZEBOX | win32.WS_MAXIMIZEBOX | win32.WS_SYSMENU;
                    const new_style: win32.DWORD = if (on) style | deco else style & ~deco;
                    if (new_style != style) {
                        _ = win32.SetWindowLongW(w.hwnd, win32.GWL_STYLE, @bitCast(new_style));
                        _ = win32.SetWindowPos(w.hwnd, null, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED);
                    }
                    return true;
                },
                // destroy：强制销毁（绕过 WM_CLOSE 请求链；与 .close 同语义，
                // 对齐 Tauri destroy() —— close 链是用户点击 X 的 WM_CLOSE 路径）
                .destroy_win => {
                    _ = win32.DestroyWindow(w.hwnd);
                    return true;
                },
                // setScreen：移动到目标显示器工作区（保持尺寸、夹取不出屏；
                // 显示器顺序与 fullscreenOnMonitor 一致——collectMonitors 枚举序）
                .set_screen => |index| {
                    const monitors = win_sysinfo.collectMonitors(self.allocator) catch return false;
                    defer self.allocator.free(monitors);
                    if (index >= monitors.len) return false;
                    const m = monitors[index];
                    var rc: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
                    _ = win32.GetWindowRect(w.hwnd, &rc);
                    const width = @min(rc.right - rc.left, @as(i32, @intCast(m.work_width)));
                    const height = @min(rc.bottom - rc.top, @as(i32, @intCast(m.work_height)));
                    const x = m.work_x + @divTrunc(@as(i32, @intCast(m.work_width)) - width, 2);
                    const y = m.work_y + @divTrunc(@as(i32, @intCast(m.work_height)) - height, 2);
                    _ = win32.SetWindowPos(w.hwnd, null, x, y, width, height, win32.SWP_NOZORDER);
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
                // ---- v0.1.18：窗口精细控制 ----
                .cursor => |kind| {
                    w.cursor = cursorHandle(kind);
                    _ = win32.SetCursor(w.cursor);
                    return w.cursor != null;
                },
                .cursor_visible => |visible| {
                    if (visible and w.cursor_hidden) {
                        _ = win32.ShowCursor(1);
                        w.cursor_hidden = false;
                    } else if (!visible and !w.cursor_hidden) {
                        _ = win32.ShowCursor(0);
                        w.cursor_hidden = true;
                    }
                    return true;
                },
                .cursor_grab => |grab| {
                    if (grab) {
                        _ = win32.SetCapture(w.hwnd);
                    } else {
                        _ = win32.ReleaseCapture();
                    }
                    return true;
                },
                .cursor_position => |p| return win32.SetCursorPos(p.x, p.y) != 0,
                .ignore_cursor => |ignore| {
                    var ex: win32.DWORD = @bitCast(win32.GetWindowLongW(w.hwnd, win32.GWL_EXSTYLE));
                    if (ignore) {
                        // WS_EX_LAYERED 是命中测试穿透的前提；层窗口必须先给 alpha=255，
                        // 否则窗口会变成完全透明（实测坑）。
                        ex |= win32.WS_EX_LAYERED | win32.WS_EX_TRANSPARENT;
                    } else {
                        ex &= ~(win32.WS_EX_TRANSPARENT);
                        if (!w.transparent) ex &= ~win32.WS_EX_LAYERED;
                    }
                    _ = win32.SetWindowLongW(w.hwnd, win32.GWL_EXSTYLE, @bitCast(ex));
                    _ = win32.SetLayeredWindowAttributes(w.hwnd, 0, 255, LWA_ALPHA);
                    _ = win32.SetWindowPos(w.hwnd, null, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED);
                    w.ignore_cursor = ignore;
                    return true;
                },
                .content_protected => |on| {
                    const ok = win32.SetWindowDisplayAffinity(w.hwnd, if (on) win32.WDA_EXCLUDEFROMCAPTURE else win32.WDA_NONE) != 0;
                    if (ok) w.content_protected = on;
                    return ok;
                },
                .shadow => |on| return sys_integration.applyShadow(w.hwnd, on),
                .always_on_bottom => |on| {
                    w.always_on_bottom = on;
                    _ = win32.SetWindowPos(w.hwnd, if (on) win32.HWND_BOTTOM else win32.HWND_NOTOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
                    return true;
                },
                .focusable => |on| {
                    var ex: win32.DWORD = @bitCast(win32.GetWindowLongW(w.hwnd, win32.GWL_EXSTYLE));
                    if (on) {
                        ex &= ~win32.WS_EX_NOACTIVATE;
                    } else {
                        ex |= win32.WS_EX_NOACTIVATE;
                    }
                    _ = win32.SetWindowLongW(w.hwnd, win32.GWL_EXSTYLE, @bitCast(ex));
                    w.focusable = on;
                    return true;
                },
                .enabled => |on| return win32.EnableWindow(w.hwnd, if (on) 1 else 0) != 0 or !on,
                .theme => |t| {
                    const r = sys_integration.applyAppearance(w.hwnd, .{
                        .dark_titlebar = t.dark,
                        .caption_color = t.caption,
                        .text_color = t.text,
                        .border_color = t.border,
                    });
                    return r.dark or r.colors or (t.dark == null and t.caption == null and t.text == null and t.border == null);
                },
                .limits => |lim| {
                    w.min_width = nonZero(lim.min_width);
                    w.min_height = nonZero(lim.min_height);
                    w.max_width = nonZero(lim.max_width);
                    w.max_height = nonZero(lim.max_height);
                    // 让新的约束立即生效（当前尺寸超限时会被系统夹紧）
                    _ = win32.SetWindowPos(w.hwnd, null, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER);
                    var rc: win32.RECT = undefined;
                    if (win32.GetWindowRect(w.hwnd, &rc) != 0) {
                        var wpx: i32 = rc.right - rc.left;
                        var hpx: i32 = rc.bottom - rc.top;
                        if (w.max_width) |mw| {
                            if (wpx > @as(i32, @intCast(mw))) wpx = @intCast(mw);
                        }
                        if (w.max_height) |mh| {
                            if (hpx > @as(i32, @intCast(mh))) hpx = @intCast(mh);
                        }
                        _ = win32.SetWindowPos(w.hwnd, null, 0, 0, wpx, hpx, win32.SWP_NOMOVE | win32.SWP_NOZORDER);
                    }
                    return true;
                },
                .fullscreen_monitor => |idx| {
                    self.setFullscreenOnMonitor(w, idx);
                    return true;
                },
                .icon => |path| {
                    const cx_big = clampIconPx(win32.GetSystemMetrics(win32.SM_CXICON), 32);
                    const cx_small = clampIconPx(win32.GetSystemMetrics(win32.SM_CXSMICON), 16);
                    if (path) |p| {
                        const ib = self.makeIcon(p, cx_big, cx_big) orelse return false;
                        const is = self.makeIcon(p, cx_small, cx_small) orelse {
                            _ = win32.DestroyIcon(ib);
                            return false;
                        };
                        if (w.owns_icons) {
                            if (w.icon_big) |old| _ = win32.DestroyIcon(old);
                            if (w.icon_small) |old| _ = win32.DestroyIcon(old);
                        }
                        w.icon_big = ib;
                        w.icon_small = is;
                        w.owns_icons = true;
                    } else {
                        if (w.owns_icons) {
                            if (w.icon_big) |old| _ = win32.DestroyIcon(old);
                            if (w.icon_small) |old| _ = win32.DestroyIcon(old);
                        }
                        w.icon_big = self.icon_big;
                        w.icon_small = self.icon_small;
                        w.owns_icons = false;
                    }
                    _ = win32.SendMessageW(w.hwnd, win32.WM_SETICON, win32.ICON_BIG, @bitCast(@intFromPtr(w.icon_big)));
                    _ = win32.SendMessageW(w.hwnd, win32.WM_SETICON, win32.ICON_SMALL, @bitCast(@intFromPtr(w.icon_small)));
                    return true;
                },
                .state => return true, // 由 runWindowQuery 处理，不会走到这里
            }
        }

        /// v0.1.19：向 webview 注入 document-start 脚本（失败只记日志）。
        fn injectScript(self: *Self, w: *Window, webview: *wv2.ICoreWebView2, script: []const u8) void {
            const handler = IgnoreCompletedHandler(wv2.IID_AddScriptToExecuteOnDocumentCreatedCompletedHandler).create(w) catch return;
            const js_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, script) catch {
                handler.dropRef();
                return;
            };
            defer self.allocator.free(js_w);
            const hr = webview.addScriptToExecuteOnDocumentCreated(js_w.ptr, handler);
            handler.dropRef();
            log.print("[webview] inject init script ({d} bytes) hr=0x{x}", .{ script.len, @as(u32, @bitCast(hr)) });
        }

        /// v0.1.18：执行菜单预定义角色。焦点在原生编辑控件时发 WM_* 消息；
        /// 否则在页面内用 document.execCommand（WebView2 场景）。
        fn dispatchRole(self: *Self, w: *Window, role: []const u8) bool {
            const eql = std.mem.eql;
            const focus = win32.GetFocus();
            if (focus != null and focus != w.hwnd) {
                var buf: [128]u16 = @splat(0);
                const n = win32.GetClassNameW(focus, &buf, buf.len);
                if (n > 0 and isEditClass(buf[0..@intCast(n)])) {
                    if (eql(u8, role, "select_all")) return win32.SendMessageW(focus, win32.EM_SETSEL, 0, -1) != 0;
                    const msg: win32.UINT = if (eql(u8, role, "undo"))
                        win32.WM_UNDO
                    else if (eql(u8, role, "cut"))
                        win32.WM_CUT
                    else if (eql(u8, role, "copy"))
                        win32.WM_COPY
                    else if (eql(u8, role, "paste"))
                        win32.WM_PASTE
                    else if (eql(u8, role, "delete"))
                        win32.WM_CLEAR
                    else
                        return false;
                    _ = win32.SendMessageW(focus, msg, 0, 0);
                    return true;
                }
            }

            // paste：Chromium 禁止非用户手势的 execCommand('paste')，改为
            // 原生读剪贴板 + insertText（实测可用的路径）。
            if (eql(u8, role, "paste")) {
                const text = self.getClipboardText(w, self.allocator) orelse return false;
                defer self.allocator.free(text);
                const lit = std.json.Stringify.valueAlloc(self.allocator, text, .{}) catch return false;
                defer self.allocator.free(lit);
                const js = std.fmt.allocPrint(self.allocator, "document.execCommand('insertText', false, {s})", .{lit}) catch return false;
                defer self.allocator.free(js);
                return self.execInWebview(w, js);
            }

            const js: []const u8 = if (eql(u8, role, "undo"))
                "document.execCommand('undo')"
            else if (eql(u8, role, "redo"))
                "document.execCommand('redo')"
            else if (eql(u8, role, "cut"))
                "document.execCommand('cut')"
            else if (eql(u8, role, "copy"))
                "document.execCommand('copy')"
            else if (eql(u8, role, "delete"))
                "document.execCommand('delete')"
            else if (eql(u8, role, "select_all"))
                "document.execCommand('selectAll')"
            else
                return false;
            return self.execInWebview(w, js);
        }

        /// 在窗口主 webview 内执行脚本（忽略结果）。
        fn execInWebview(self: *Self, w: *Window, js: []const u8) bool {
            const wv = w.webview orelse return false;
            const js_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, js) catch return false;
            defer self.allocator.free(js_w);
            const handler = IgnoreCompletedHandler(wv2.IID_ExecuteScriptCompletedHandler).create(w) catch return false;
            const hr = wv.lpVtbl.ExecuteScript(wv, js_w.ptr, @ptrCast(handler));
            handler.dropRef();
            if (!com.succeeded(hr)) log.print("[script] execute failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return com.succeeded(hr);
        }

        fn setFullscreen(self: *Self, w: *Window, on: bool) void {
            _ = self;
            if (on and !w.fullscreen) {
                // v0.1.18：全屏到窗口当前所在显示器（原先固定主屏）
                var rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
                if (currentMonitorRect(w.hwnd)) |r| {
                    rect = r;
                } else {
                    rect = .{ .left = 0, .top = 0, .right = win32.GetSystemMetrics(win32.SM_CXSCREEN), .bottom = win32.GetSystemMetrics(win32.SM_CYSCREEN) };
                }
                w.saved_style = win32.GetWindowLongW(w.hwnd, win32.GWL_STYLE);
                _ = win32.GetWindowRect(w.hwnd, &w.saved_rect);
                _ = win32.SetWindowLongW(w.hwnd, win32.GWL_STYLE, @bitCast(win32.WS_POPUP | win32.WS_VISIBLE));
                _ = win32.SetWindowPos(w.hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, win32.SWP_FRAMECHANGED | win32.SWP_SHOWWINDOW);
                w.fullscreen = true;
            } else if (!on and w.fullscreen) {
                _ = win32.SetWindowLongW(w.hwnd, win32.GWL_STYLE, w.saved_style);
                _ = win32.SetWindowPos(w.hwnd, null, w.saved_rect.left, w.saved_rect.top, w.saved_rect.right - w.saved_rect.left, w.saved_rect.bottom - w.saved_rect.top, win32.SWP_FRAMECHANGED | win32.SWP_SHOWWINDOW);
                w.fullscreen = false;
            }
        }

        /// v0.1.18：全屏到指定显示器（索引按 EnumDisplayMonitors 顺序）；越界回退当前显示器。
        fn setFullscreenOnMonitor(self: *Self, w: *Window, index: u32) void {
            if (w.fullscreen) self.setFullscreen(w, false);
            const monitors = win_sysinfo.collectMonitors(self.allocator) catch {
                self.setFullscreen(w, true);
                return;
            };
            defer self.allocator.free(monitors);

            var rect: win32.RECT = undefined;
            if (index < monitors.len) {
                const m = monitors[index];
                const mw: i32 = @intCast(m.width);
                const mh: i32 = @intCast(m.height);
                rect = .{ .left = m.x, .top = m.y, .right = m.x + mw, .bottom = m.y + mh };
            } else {
                rect = currentMonitorRect(w.hwnd) orelse .{ .left = 0, .top = 0, .right = win32.GetSystemMetrics(win32.SM_CXSCREEN), .bottom = win32.GetSystemMetrics(win32.SM_CYSCREEN) };
            }
            w.saved_style = win32.GetWindowLongW(w.hwnd, win32.GWL_STYLE);
            _ = win32.GetWindowRect(w.hwnd, &w.saved_rect);
            _ = win32.SetWindowLongW(w.hwnd, win32.GWL_STYLE, @bitCast(win32.WS_POPUP | win32.WS_VISIBLE));
            _ = win32.SetWindowPos(w.hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, win32.SWP_FRAMECHANGED | win32.SWP_SHOWWINDOW);
            w.fullscreen = true;
            log.print("[window] #{d} fullscreen on monitor {d} rect=({d},{d})-({d},{d})", .{ w.id, index, rect.left, rect.top, rect.right, rect.bottom });
        }

        /// v0.1.18：窗口状态快照（JSON）。必须在 UI 线程调用（读 Win32 状态）。
        /// v0.3.14：window_id = ipc.WINDOW_LIST_ALL → 全部存活窗口的状态数组
        /// （Wails GetAll / Tauri getAll 对齐）；新增 resizable/decorated 字段。
        fn runWindowQuery(backend_ptr: *anyopaque, window_id: u32, alloc: std.mem.Allocator) ?[]u8 {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            if (window_id == ipc.WINDOW_LIST_ALL) {
                var out: std.ArrayList(u8) = .empty;
                out.appendSlice(alloc, "[") catch return null;
                var first = true;
                for (self.windows.items) |it| {
                    if (!it.alive) continue;
                    if (!first) out.appendSlice(alloc, ",") catch return null;
                    first = false;
                    const one = self.windowStateJson(it, alloc) orelse return null;
                    out.appendSlice(alloc, one) catch return null;
                }
                out.appendSlice(alloc, "]") catch return null;
                return out.items;
            }
            const w = self.windowById(if (window_id == 0) 1 else window_id) orelse return null;
            if (!w.alive) return null;
            return self.windowStateJson(w, alloc);
        }

        /// 单窗口状态 JSON（runWindowQuery / list 共用）。
        fn windowStateJson(self: *Self, w: *Window, alloc: std.mem.Allocator) ?[]u8 {
            _ = self;
            var rc: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = win32.GetWindowRect(w.hwnd, &rc);
            const style: u32 = @bitCast(win32.GetWindowLongW(w.hwnd, win32.GWL_STYLE));
            const ex: u32 = @bitCast(win32.GetWindowLongW(w.hwnd, win32.GWL_EXSTYLE));
            return std.fmt.allocPrint(alloc,
                \\{{"id":{d},"x":{d},"y":{d},"width":{d},"height":{d},"style":{d},"ex_style":{d},"enabled":{s},"visible":{s},"focused":{s},"zoomed":{s},"iconic":{s},"fullscreen":{s},"always_on_top":{s},"always_on_bottom":{s},"ignore_cursor":{s},"focusable":{s},"content_protected":{s},"overlay":{s},"incognito":{s},"composition":{s},"monitor":{d},"min_width":{d},"min_height":{d},"max_width":{d},"max_height":{d},"child_webviews":{d},"resizable":{s},"decorated":{s}}}
            , .{
                w.id,
                rc.left,
                rc.top,
                rc.right - rc.left,
                rc.bottom - rc.top,
                style,
                ex,
                boolStr(win32.IsWindowEnabled(w.hwnd) != 0),
                boolStr(win32.IsWindowVisible(w.hwnd) != 0),
                boolStr(win32.GetFocus() == w.hwnd),
                boolStr(win32.IsZoomed(w.hwnd) != 0),
                boolStr(win32.IsIconic(w.hwnd) != 0),
                boolStr(w.fullscreen),
                boolStr(ex & win32.WS_EX_TOPMOST != 0),
                boolStr(w.always_on_bottom),
                boolStr(w.ignore_cursor),
                boolStr(w.focusable),
                boolStr(w.content_protected),
                boolStr(w.overlay),
                boolStr(w.incognito),
                boolStr(w.composition != null),
                (win_sysinfo.monitorIndexOf(w.hwnd) orelse 0),
                w.min_width orelse 0,
                w.min_height orelse 0,
                w.max_width orelse 0,
                w.max_height orelse 0,
                w.child_webviews.items.len,
                // v0.3.14：从 style 位推导（WS_THICKFRAME=可缩放；WS_CAPTION=有标题栏）
                boolStr(style & win32.WS_THICKFRAME != 0),
                boolStr(style & win32.WS_CAPTION != 0),
            }) catch null;
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

            if (!openClipboardRetry(w.hwnd)) {
                log.print("[clip] OpenClipboard failed after retries", .{});
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

        /// OpenClipboard 会因**任何**进程正持有剪贴板而失败（Windows 的已知行为，
        /// 不是错误码设计问题）。常见触发：剪贴板管理器、浏览器、远程桌面。
        /// 早期实现一次失败就报 ClipboardWriteFailed，冒烟会被无关进程搞红——
        /// 这里按 Win32 惯例做短重试（3 次 × 20ms 足够覆盖绝大多数瞬时占用）。
        fn openClipboardRetry(hwnd: win32.HWND) bool {
            var attempt: u8 = 0;
            while (attempt < 3) : (attempt += 1) {
                if (win32.OpenClipboard(hwnd) != 0) return true;
                if (attempt < 2) @import("../../sys.zig").sleepMs(20);
            }
            return false;
        }

        fn getClipboardText(self: *Self, w: *Window, alloc: std.mem.Allocator) ?[]u8 {
            _ = self;
            if (!openClipboardRetry(w.hwnd)) {
                log.print("[clip] OpenClipboard(read) failed after retries", .{});
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
        /// v0.3.2：无窗口上下文的全局广播（电源/会话事件：发往所有存活窗口）。
        fn emitAll(self: *Self, name: []const u8, payload: anytype) void {
            for (self.windows.items) |w| {
                if (w.alive) w.emitEventPayload(name, payload);
            }
        }

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
            // v0.1.13：优先用运行时模型构建的弹菜单（勾选/禁用态实时反映）
            const popup_hm = if (self.tray_popup) |*b| b.hmenu else self.tray_menu;
            const hm = popup_hm orelse return;
            var pt: win32.POINT = undefined;
            if (win32.GetCursorPos(&pt) == 0) return;
            _ = win32.SetForegroundWindow(hwnd);
            const cmd = win32.TrackPopupMenu(hm, win32.TPM_RIGHTBUTTON | win32.TPM_RETURNCMD, pt.x, pt.y, 0, hwnd, null);
            _ = win32.PostMessageW(hwnd, win32.WM_NULL, 0, 0);
            if (cmd == 0) return;
            const menu_id: u16 = @intCast(cmd & 0xffff);

            if (self.tray_popup) |*built| {
                if (built.idFor(menu_id)) |id| {
                    log.print("[tray] menu {s}", .{id});
                    if (self.mainWindow()) |w| w.emitEventPayload("trayMenu", .{ .id = id });
                    return;
                }
            }
            const items = Self.tray_menu_cfg orelse return;
            if (menu_mod.idFromPopup(items, TRAY_MENU_BASE, menu_id)) |id| {
                log.print("[tray] menu {s}", .{id});
                if (self.mainWindow()) |w| w.emitEventPayload("trayMenu", .{ .id = id });
            }
        }

        fn applyTrayClick(self: *Self, hwnd: win32.HWND, action: shared_system.ClickAction) void {
            switch (action) {
                .none => {},
                .toggle_window => {
                    // v0.3.3：attach_window（托盘附着窗）优先——点击托盘切换该窗口，
                    // 并把窗口定位到托盘图标附近（Shell_NotifyIconGetRect）。
                    var attached: ?*Window = null;
                    for (self.windows.items) |win| {
                        if (win.alive and win.tray_attached) attached = win;
                    }
                    const w = attached orelse (self.mainWindow() orelse return);
                    const visible = win32.IsWindowVisible(w.hwnd) != 0;
                    if (!visible) {
                        // 显示前定位到托盘图标附近（图标左下角对齐；超出屏幕由
                        // prevent_overflow/系统夹取兜底）
                        var loc: win32.RECT_NIF = undefined;
                        if (self.tray) |*t| {
                            if (win32.Shell_NotifyIconGetRect(0, t.nid.hWnd, t.nid.uID, &loc) == 0) {
                                var wa: win32.RECT = undefined;
                                _ = win32.SystemParametersInfoW(0x0030, 0, &wa, 0); // SPI_GETWORKAREA
                                var rect: win32.RECT = undefined;
                                _ = win32.GetWindowRect(w.hwnd, &rect);
                                const cw = rect.right - rect.left;
                                const ch = rect.bottom - rect.top;
                                var x: i32 = loc.right - cw;
                                var y: i32 = loc.bottom + 4;
                                // 屏幕底部放不下 → 图标上方
                                if (y + ch > wa.bottom) y = loc.top - ch - 4;
                                x = @min(@max(x, wa.left), @max(wa.left, wa.right - cw));
                                _ = win32.SetWindowPos(w.hwnd, null, x, y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER);
                            }
                        }
                    }
                    _ = win32.ShowWindow(w.hwnd, if (visible) win32.SW_HIDE else win32.SW_SHOW);
                    if (!visible) _ = win32.SetForegroundWindow(w.hwnd);
                    log.print("[tray] click -> {s} (window #{d}{s})", .{
                        if (visible) "hidden" else "shown", w.id, if (attached != null) " attached" else "",
                    });
                },
                .show_menu => self.showTrayMenu(hwnd),
                .emit_event => {
                    log.print("[tray] click -> trayClick event", .{});
                    if (self.mainWindow()) |w| w.emitEventPayload("trayClick", .{});
                },
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

            // v0.3.2：真 scheme 请求（`<scheme>://…`）先于同源资产——URI 形态与
            // 应用 origin 不同，不会进 sameOrigin 分支。**必须经已注册名门控**，
            // 否则 https 等内置 scheme 也会被解析并误拦。
            if (protocol.schemeNameOf(uri_u8)) |scheme_name| {
                // v0.3.10 C2：isolation 隔离 iframe 页面（ziltiso://<random>/，先于协议门控）
                if (std.mem.eql(u8, scheme_name, "ziltiso") and self.iso_url != null and config.isolation != null) {
                    const html = iso_mod.iframeHtml(self.allocator, config.isolation.?.key_hex) catch return;
                    defer self.allocator.free(html);
                    self.writeProtocolResponse(args, .{
                        .content_type = "text/html; charset=utf-8",
                        .body = html,
                        .owned = true,
                    }, uri_u8, false);
                    log.print("[iso] served isolation iframe page <- {s}", .{uri_u8});
                    return;
                }
                if (protocol.find(config.protocols, scheme_name) != null) {
                    if (protocol.parseSchemeRoute(uri_u8)) |route| {
                        if (self.serveProtocolRoute(route, uri_u8, args, true)) return;
                    }
                }
            }

            if (security.sameOrigin(uri_u8, config.url)) {
                const authority_start = (std.mem.indexOf(u8, uri_u8, "://") orelse return) + 3;
                const path_start = if (std.mem.indexOfAny(u8, uri_u8[authority_start..], "/?#")) |i| authority_start + i else uri_u8.len;
                const raw_path = uri_u8[path_start..];
                const path = asset_routes.decodePath(self.allocator, if (raw_path.len == 0 or raw_path[0] != '/') "/" else raw_path) catch return;
                defer self.allocator.free(path);
                // v0.1.24：应用自定义协议优先于静态资产
                if (self.serveProtocol(uri_u8, path, args)) return;
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

        /// v0.1.24：应用自定义协议（`/__proto/<name>/…`）。命中并已写回响应返回 true。
        /// 未注册的名字返回 false（走静态资产 404）。
        fn serveProtocol(self: *Self, uri: []const u8, path: []const u8, args: *wv2.ICoreWebView2WebResourceRequestedEventArgs) bool {
            const route = protocol.parseRoute(path, uri) orelse return false;
            return self.serveProtocolRoute(route, uri, args, false);
        }

        /// v0.1.24/v0.3.2 共通实现：路由已解析的协议请求。真 scheme 请求
        /// （`scheme://…`）带 CORS 允许头（跨 origin fetch 需要；路径式同源不需要）。
        /// v0.3.8 B8：请求体经 `get_Content`（IStream）读取传入 handler。
        fn serveProtocolRoute(self: *Self, route: protocol.Route, uri: []const u8, args: *wv2.ICoreWebView2WebResourceRequestedEventArgs, cross_origin: bool) bool {
            const p = protocol.find(config.protocols, route.name) orelse {
                log.print("[proto] '{s}' 未注册 <- {s}", .{ route.name, uri });
                // 真 scheme 没有静态资产兜底——未注册名直接给 404，避免引擎错误页
                if (cross_origin) {
                    self.writeProtocolResponse(args, .{ .status = 404, .body = "protocol not registered", .owned = false }, uri, true);
                    return true;
                }
                return false;
            };

            var method: []const u8 = "GET";
            var method_buf: ?[]u8 = null;
            defer if (method_buf) |m| self.allocator.free(m);
            var body_buf: ?[]u8 = null;
            defer if (body_buf) |b| self.allocator.free(b);
            const rr = args.getRequest();
            if (com.succeeded(rr.hr) and rr.request != null) {
                const req = rr.request.?;
                defer _ = req.lpVtbl.Release(req);
                var mw: ?wv2.LPWSTR = null;
                if (com.succeeded(req.lpVtbl.get_Method(req, &mw)) and mw != null) {
                    defer wv2.freeCoString(mw);
                    if (std.unicode.utf16LeToUtf8Alloc(self.allocator, std.mem.span(mw.?))) |m| {
                        method_buf = m;
                        method = m;
                    } else |_| {}
                }
                body_buf = readRequestBody(self.allocator, req);
            }

            const ua = requestHeaderUtf8(args, self.allocator, "User-Agent");
            defer if (ua) |v| self.allocator.free(v);
            const res = p.handle(.{
                .name = route.name,
                .path = route.path,
                .query = route.query,
                .method = method,
                .user_agent = ua,
                .body = body_buf,
                .url = uri,
            }, self.allocator) catch |err| {
                log.print("[proto] {s} handler failed: {s}", .{ route.name, @errorName(err) });
                self.writeProtocolResponse(args, .{ .status = 500, .body = "protocol handler failed", .owned = false }, uri, cross_origin);
                return true;
            };
            defer if (res.owned) self.allocator.free(res.body);
            log.print("[proto] {d} {s}/{s} {d} bytes <- {s} (cors={})", .{ res.status, route.name, route.path, res.body.len, uri, cross_origin });
            self.writeProtocolResponse(args, res, uri, cross_origin);
            return true;
        }

        fn writeProtocolResponse(self: *Self, args: *wv2.ICoreWebView2WebResourceRequestedEventArgs, res: protocol.Response, uri: []const u8, cross_origin: bool) void {
            const env = self.env orelse return;
            const reason = protocol.reasonFor(res.status);
            const reason_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, reason) catch return;
            defer self.allocator.free(reason_w);

            var hb: std.Io.Writer.Allocating = .init(self.allocator);
            defer hb.deinit();
            hb.writer.print("Content-Type: {s}", .{res.content_type}) catch return;
            for (res.headers) |h| hb.writer.print("\r\n{s}: {s}", .{ h.name, h.value }) catch return;
            // v0.3.2：真 scheme 与应用 origin 不同源——补 CORS 允许（对齐 Linux
            // 真 scheme 的行为；AllowedOrigins 已在环境侧限制来源，这里是响应面）
            if (cross_origin) {
                hb.writer.print("\r\nAccess-Control-Allow-Origin: *", .{}) catch return;
                hb.writer.print("\r\nAccess-Control-Expose-Headers: *", .{}) catch return;
            }
            const headers_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, hb.written()) catch return;
            defer self.allocator.free(headers_w);

            const stream = streamFromBytes(res.body) orelse return;
            const stream_unknown: *com.IUnknown = @ptrCast(@alignCast(stream));
            defer _ = stream_unknown.lpVtbl.Release(stream_unknown);
            const r = env.createWebResourceResponse(stream, res.status, reason_w.ptr, headers_w.ptr);
            if (com.failed(r.hr) or r.response == null) {
                log.print("[proto] createWebResourceResponse failed hr=0x{x} <- {s}", .{ @as(u32, @bitCast(r.hr)), uri });
                return;
            }
            const response = r.response.?;
            defer _ = response.lpVtbl.Release(response);
            var rh: ?*wv2.ICoreWebView2HttpResponseHeaders = null;
            if (com.failed(response.lpVtbl.get_Headers(response, &rh))) return;
            const h = rh orelse return;
            defer _ = h.lpVtbl.Release(h);
            if (config.security.csp) |csp| self.appendHeader(h, "Content-Security-Policy", csp) catch {};
            for (config.security.headers) |header| self.appendHeader(h, header.name, header.value) catch {};
            _ = args.putResponse(response);
        }

        fn appendHeader(self: *Self, headers: *wv2.ICoreWebView2HttpResponseHeaders, name: []const u8, value: []const u8) !void {            const name_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, name);
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
            // v0.1.16：附加子 webview 随窗口释放（子 HWND 由父窗口销毁自动回收，
            // COM 引用在这里显式释放）
            for (w.child_webviews.items) |c| destroyChildWebview(c);
            w.child_webviews.deinit(w.backend.allocator);
            w.child_webviews = .empty;
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
            // v0.3.12 A11：组合状态释放（CC/CC4/DComp COM 引用）
            if (w.composition) |comp| {
                if (comp.cc4) |c4| c4.release();
                comp.target.release();
                comp.visual.release();
                comp.device.release();
                comp.controller.release();
                w.backend.allocator.destroy(comp);
                w.composition = null;
            }
            w.icon_big = null;
            w.icon_small = null;
            w.owns_icons = false;
            w.bg_brush = null;
        }

        fn cleanup(self: *Self) void {
            if (self.mainWindow()) |w| {
                _ = win32.KillTimer(w.hwnd, 1);
                wtsUnregister(w.hwnd); // v0.3.2：注销会话通知
            }
            if (Self.hotkey_cfg) |hks| {
                if (self.mainWindow()) |w| hotkey_mod.unregisterAll(w.hwnd, hks);
            }
            if (self.tray) |*t| _ = t.remove();
            // v0.1.13：运行时快捷键 / 任务栏 / 菜单模型清理
            if (self.runtime_hotkeys.items.len != 0) {
                if (self.mainWindow()) |w| {
                    for (self.runtime_hotkeys.items) |hk| _ = win32.UnregisterHotKey(w.hwnd, @intCast(hk.sys_id));
                }
                for (self.runtime_hotkeys.items) |hk| {
                    self.allocator.free(hk.id);
                    self.allocator.free(hk.accel_text);
                }
                self.runtime_hotkeys.deinit(self.allocator);
            }
            if (self.taskbar_list) |*tb| tb.deinit();
            if (self.store) |*st| st.deinit();
            if (self.services) |*sv| sv.deinit();
            // v0.1.16：退出时释放残留的 WebSocket 连接（关闭 socket 唤醒读线程）
            for (self.ws_conns.items) |c| {
                c.stream.close(c.io);
                c.read_thread.join();
                c.threaded.deinit();
                const a = std.heap.page_allocator;
                a.destroy(c.threaded);
                a.destroy(c);
            }
            self.ws_conns.deinit(self.allocator);
            // v0.1.20：wss 连接（WinHTTP 句柄）
            for (self.wss_conns.items) |c| {
                c.ws.close(1001, "app exit");
                c.read_thread.join();
                c.ws.deinit();
                const a = std.heap.page_allocator;
                a.destroy(c);
            }
            self.wss_conns.deinit(self.allocator);
            for (self.fs_watches.items) |wv| self.stopFsWatch(wv);
            self.fs_watches.deinit(self.allocator);
            for (self.acl_grants.items) |g| self.allocator.free(g);
            self.acl_grants.deinit(self.allocator);
            // v0.1.17：释放分区 Environment（名字 + 引用）
            for (self.partitions.items) |pe| {
                _ = pe.env.lpVtbl.Release(pe.env);
                self.allocator.free(pe.name);
            }
            self.partitions.deinit(self.allocator);
            // v0.1.16：残留子进程强杀 + worker 清理（应用退出场景）
            for (self.procs.items) |p| {
                if (!p.dead) {
                    if (p.child.id) |h| _ = win32.TerminateProcess(h, 1);
                    p.worker.join();
                }
                if (p.threaded) |t| {
                    t.deinit();
                    const a = std.heap.page_allocator;
                    a.destroy(t);
                }
                const a = std.heap.page_allocator;
                a.destroy(p);
            }
            self.procs.deinit(self.allocator);
            if (self.storage_root) |root| self.allocator.free(root);
            if (self.tray_popup) |*b| b.deinit(self.allocator);
            if (self.menu_state) |*m| m.deinit();
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
                if (w.own_env) |e| _ = e.lpVtbl.Release(e);
                if (w.proxy) |p| self.allocator.free(p);
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

        /// v0.1.18：把按键消息交给当前窗口的菜单 ACCEL 表；命中则消费（产生 WM_COMMAND）。
        fn translateAccel(self: *Self, msg: *win32.MSG) bool {
            const w = self.focusedWindow() orelse self.mainWindow() orelse return false;
            if (!w.alive or w.accel == null) return false;
            return win32.TranslateAcceleratorW(w.hwnd, w.accel, msg) != 0;
        }

        fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.c) win32.LRESULT {
            switch (msg) {
                // v0.1.23：覆盖式标题栏——客户区吃掉整个非客户区（wParam=TRUE 时
                // 返回值 0 表示「客户区 = 窗口矩形」），配合下方 WM_NCHITTEST 保留缩放。
                win32.WM_NCCALCSIZE => {
                    if (wparam != 0) {
                        if (instance) |b| {
                            if (b.windowOfHwnd(hwnd)) |w| {
                                if (w.overlay and !w.fullscreen) return 0;
                            }
                        }
                    }
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                },
                // v0.1.23：无原生边框后自绘 8px 缩放命中区（最大化时不缩放）。
                // v0.3.12 A11：组合模式鼠标输入转发（HWND webview 原生接收，
                // 组合模式靠 SendMouseInput——kind/虚拟键映射见 webview2.zig）
                win32.WM_MOUSEMOVE, win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP,
                win32.WM_LBUTTONDBLCLK, win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP,
                win32.WM_RBUTTONDBLCLK, win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP,
                win32.WM_MBUTTONDBLCLK => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (w.composition) |comp| {
                                const x: i32 = @as(i16, @truncate(lparam));
                                const y: i32 = @as(i16, @truncate(lparam >> 16));
                                const pt = wv2.POINT{ .x = x, .y = y };
                                const keys: u32 = @intCast(@as(u32, @truncate(wparam)) & 0xFFFF);
                                const mouse_data: u32 = @intCast(@as(u32, @truncate(wparam >> 16)));
                                const kind: u32 = switch (msg) {
                                    win32.WM_MOUSEMOVE => wv2.MOUSE_EVENT_KIND.move,
                                    win32.WM_LBUTTONDOWN => wv2.MOUSE_EVENT_KIND.left_button_down,
                                    win32.WM_LBUTTONUP => wv2.MOUSE_EVENT_KIND.left_button_up,
                                    win32.WM_LBUTTONDBLCLK => wv2.MOUSE_EVENT_KIND.left_button_double_click,
                                    win32.WM_RBUTTONDOWN => wv2.MOUSE_EVENT_KIND.right_button_down,
                                    win32.WM_RBUTTONUP => wv2.MOUSE_EVENT_KIND.right_button_up,
                                    win32.WM_RBUTTONDBLCLK => wv2.MOUSE_EVENT_KIND.right_button_double_click,
                                    win32.WM_MBUTTONDOWN => wv2.MOUSE_EVENT_KIND.middle_button_down,
                                    win32.WM_MBUTTONUP => wv2.MOUSE_EVENT_KIND.middle_button_up,
                                    win32.WM_MBUTTONDBLCLK => wv2.MOUSE_EVENT_KIND.middle_button_double_click,
                                    else => wv2.MOUSE_EVENT_KIND.move,
                                };
                                _ = comp.controller.sendMouseInput(kind, keys, mouse_data, pt);
                                return 0;
                            }
                        }
                    }
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                },
                win32.WM_NCHITTEST => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            // v0.3.12 A11：组合模式——app-region 原生 hit-test
                            //（页面 CSS `app-region: drag` → CAPTION → HTCAPTION）
                            if (w.composition) |comp| {
                                if (comp.cc4) |cc4| {
                                    const x: i32 = @as(i16, @truncate(lparam));
                                    const y: i32 = @as(i16, @truncate(lparam >> 16));
                                    const pt = wv2.POINT{ .x = x, .y = y };
                                    var kind: u32 = 0;
                                    const hr = cc4.lpVtbl.GetNonClientRegionAtPoint(cc4, pt, &kind);
                                    if (com.succeeded(hr)) {
                                        const map: ?win32.HRESULT = switch (kind) {
                                            wv2.NON_CLIENT_REGION_KIND.caption => win32.HTCAPTION,
                                            wv2.NON_CLIENT_REGION_KIND.minimize => win32.HTMINBUTTON,
                                            wv2.NON_CLIENT_REGION_KIND.maximize => win32.HTMAXBUTTON,
                                            wv2.NON_CLIENT_REGION_KIND.close => win32.HTCLOSE,
                                            else => null,
                                        };
                                        if (map) |ht| return ht;
                                    }
                                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                                }
                            }
                            if (w.overlay and !w.fullscreen and win32.IsZoomed(hwnd) == 0) {
                                const x: i32 = @as(i16, @truncate(lparam));
                                const y: i32 = @as(i16, @truncate(lparam >> 16));
                                var rc: win32.RECT = undefined;
                                if (win32.GetWindowRect(hwnd, &rc) != 0) {
                                    const b8: i32 = 8;
                                    const left = x - rc.left < b8;
                                    const right = rc.right - x <= b8;
                                    const top = y - rc.top < b8;
                                    const bottom = rc.bottom - y <= b8;
                                    if (top and left) return win32.HTTOPLEFT;
                                    if (top and right) return win32.HTTOPRIGHT;
                                    if (bottom and left) return win32.HTBOTTOMLEFT;
                                    if (bottom and right) return win32.HTBOTTOMRIGHT;
                                    if (left) return win32.HTLEFT;
                                    if (right) return win32.HTRIGHT;
                                    if (top) return win32.HTTOP;
                                    if (bottom) return win32.HTBOTTOM;
                                }
                            }
                        }
                    }
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                },
                win32.WM_MOVE => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            var rc: win32.RECT = undefined;
                            if (win32.GetWindowRect(hwnd, &rc) != 0) {
                                // v0.3.3：moveDebounceMs>0 → 拖动中合并（重启定时器，WM_TIMER 补发终值）
                                if (w.move_debounce_ms > 0) {
                                    _ = win32.SetTimer(w.hwnd, MOVE_DEBOUNCE_TIMER_ID, @max(1, w.move_debounce_ms), null);
                                    w.move_timer_armed = true;
                                } else {
                                    w.emitEventPayload("windowMoved", .{ .id = w.id, .x = rc.left, .y = rc.top });
                                }
                            }
                        }
                    }
                    return 0;
                },
                // v0.3.3：拖动结束 → 清去抖定时器并立即补发终值
                win32.WM_EXITSIZEMOVE => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (w.move_timer_armed) {
                                _ = win32.KillTimer(w.hwnd, MOVE_DEBOUNCE_TIMER_ID);
                                w.move_timer_armed = false;
                            }
                            var rc: win32.RECT = undefined;
                            if (win32.GetWindowRect(w.hwnd, &rc) != 0) {
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
                // v0.3.3：失焦自动隐藏（托盘弹窗类窗口；WA_INACTIVE=0 失去激活）
                win32.WM_ACTIVATE => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (w.hide_on_focus_lost and (wparam & 0xffff) == 0) {
                                log.print("[window] #{d} focus lost -> hide", .{w.id});
                                _ = win32.ShowWindow(w.hwnd, win32.SW_HIDE);
                            }
                        }
                    }
                    return 0;
                },
                // v0.3.3：标题栏双击（overlay 拖动区双击 → 切换最大化；false = 不动作）
                win32.WM_NCLBUTTONDBLCLK => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (w.overlay and (w.titlebar_double_click orelse true)) {
                                const WM_SYSCOMMAND_DBL: win32.UINT = 0x0112;
                                _ = win32.PostMessageW(w.hwnd, WM_SYSCOMMAND_DBL, win32.SC_MAXIMIZE, 0);
                                return 0;
                            }
                        }
                    }
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
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
                // v0.3.6：SharedBuffer post（WebMessageReceived 重入规避）
                WM_ZILT_BINARY => {
                    if (instance) |b| {
                        const job_ptr: usize = @intCast(lparam);
                        if (job_ptr != 0) {
                            const job: *BinaryJob = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(job_ptr))));
                            b.runBinaryPost(job);
                        }
                    }
                    return 0;
                },
                // v0.3.2：电源/会话事件（powerSuspend/powerResume/powerStatusChanged/sessionLock/sessionUnlock）
                win32.WM_POWERBROADCAST => {
                    if (instance) |b| {
                        if (power.powerEventName(@intCast(wparam)) ) |name| {
                            log.print("[power] {s}", .{name});
                            b.emitAll(name, @as(?u8, null));
                        }
                    }
                    return 1; // TRUE：已处理
                },
                win32.WM_WTSSESSION_CHANGE => {
                    if (instance) |b| {
                        if (power.sessionEventName(@intCast(wparam))) |name| {
                            log.print("[session] {s}", .{name});
                            b.emitAll(name, @as(?u8, null));
                        }
                    }
                    return 0;
                },
                // v0.1.18：自定义光标 / 置底 / 托盘 hover 结束
                win32.WM_SETCURSOR => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (w.cursor) |c| {
                                _ = win32.SetCursor(c);
                                return 1;
                            }
                        }
                    }
                },
                win32.WM_WINDOWPOSCHANGING => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (lparam != 0) {
                                const wp: *win32.WINDOWPOS = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(@as(usize, @bitCast(lparam))))));
                                if (w.always_on_bottom and (wp.flags & win32.SWP_NOZORDER) == 0) {
                                    wp.hwndInsertAfter = win32.HWND_BOTTOM;
                                }
                                // v0.3.3：preventOverflow——窗口位置夹取到最近显示器工作区
                                if (w.prevent_overflow and (wp.flags & win32.SWP_NOMOVE) == 0) {
                                    if (clampRectToWorkArea(wp.x, wp.y, wp.cx, wp.cy)) |cl| {
                                        wp.x = cl.x;
                                        wp.y = cl.y;
                                    }
                                }
                            }
                        }
                    }
                },
                win32.WM_MOUSELEAVE => {
                    if (instance) |b| {
                        if (b.tray_hovering) {
                            b.tray_hovering = false;
                            if (b.mainWindow()) |mw| mw.emitEventPayload("trayHover", .{ .phase = "leave" });
                        }
                    }
                    return 0;
                },
                win32.WM_CLOSE => {
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            if (w.id == 1 and config.close_to_tray and b.tray != null and b.tray.?.active) {
                                _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
                                log.print("[tray] window hidden to tray", .{});
                                return 0;
                            }
                            // v0.3.14 G6：Zig 侧取消钩子（comptime 门控；true = 取消关闭）
                            if (comptime ipc.closeRequestHooked(config.events)) {
                                const hook_payload = std.fmt.allocPrint(b.allocator, "{{\"id\":{d}}}", .{w.id}) catch null;
                                if (hook_payload) |hp| {
                                    defer b.allocator.free(hp);
                                    if (ipc.closeRequestCancelled(config.events, b.makeContextWith(w, b.allocator), hp)) |cancelled| {
                                        if (cancelled) {
                                            log.print("[window] close cancelled by Zig hook (window #{d})", .{w.id});
                                            return 0;
                                        }
                                    }
                                }
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
                            // v0.1.18：加速键表与菜单位图
                            if (w.accel) |h| _ = win32.DestroyAcceleratorTable(h);
                            w.accel = null;
                            for (w.menu_bitmaps.items) |bmp| {
                                if (bmp) |h| _ = win32.DeleteObject(@ptrCast(h));
                            }
                            w.menu_bitmaps.deinit(b.allocator);
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
                    if (instance) |b| {
                        if (b.windowOfHwnd(hwnd)) |w| {
                            // v0.3.3：move 去抖补发终值（id 5；smoke=1/health=3 走原逻辑）
                            if (wparam == MOVE_DEBOUNCE_TIMER_ID) {
                                _ = win32.KillTimer(w.hwnd, MOVE_DEBOUNCE_TIMER_ID);
                                w.move_timer_armed = false;
                                var rc: win32.RECT = undefined;
                                if (win32.GetWindowRect(w.hwnd, &rc) != 0) {
                                    w.emitEventPayload("windowMoved", .{ .id = w.id, .x = rc.left, .y = rc.top });
                                }
                                return 0;
                            }
                        }
                    }
                    if (wparam == 3) {
                        _ = win32.KillTimer(hwnd, 3);
                        const alloc_h = std.heap.page_allocator;
                        if (instance != null) {
                            if (currentExePath(alloc_h)) |p| {
                                defer alloc_h.free(p);
                                updater.cleanupOld(alloc_h, p);
                                log.print("[updater] health confirmed, backup cleaned", .{});
                            } else |_| {}
                        }
                        return 0;
                    }
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
                            // v0.3.3：窗口级按键绑定（0xE000+i → windowKeyBinding）与 Escape（0xF000 → hide）
                            if (mid >= KEY_BINDING_ACCEL_BASE and mid < ESCAPE_ACCEL_ID) {
                                const idx: usize = mid - KEY_BINDING_ACCEL_BASE;
                                if (idx < w.key_bindings.len) {
                                    log.print("[keybinding] {s}", .{w.key_bindings[idx].id});
                                    w.emitEventPayload("windowKeyBinding", .{ .id = w.key_bindings[idx].id });
                                }
                                return 0;
                            }
                            if (mid == ESCAPE_ACCEL_ID) {
                                if (w.hide_on_escape) {
                                    log.print("[window] #{d} escape -> hide", .{w.id});
                                    _ = win32.ShowWindow(w.hwnd, win32.SW_HIDE);
                                }
                                return 0;
                            }
                            if (menu_mod.idFromPopup(w.menu_items, 0, mid)) |id| {
                                log.print("[menu] {s}", .{id});
                                // v0.1.18：预定义角色先执行（copy/paste/…），同时发事件便于观测
                                if (menu_mod.roleForId(w.menu_items, id)) |role| {
                                    _ = b.dispatchRole(w, role);
                                    w.emitEventPayload("menuRole", .{ .id = id, .role = role });
                                }
                                w.emitEventPayload("menu", .{ .id = id });
                            }
                        }
                    }
                    return 0;
                },
                win32.WM_HOTKEY => {
                    if (instance) |b| {
                        const hk_id: u32 = @intCast(wparam & 0xffff);
                        // v0.1.13：运行时注册的快捷键优先
                        for (b.runtime_hotkeys.items) |hk| {
                            if (hk.sys_id != hk_id) continue;
                            log.print("[hotkey] {s} (runtime)", .{hk.id});
                            const target = b.focusedWindow() orelse b.mainWindow();
                            if (target) |w| w.emitEventPayload("hotkey", .{ .id = hk.id });
                            return 0;
                        }
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
                        // v0.1.18：托盘 hover（enter/move/leave），对齐 Tauri tray 事件
                        if (lparam == win32.WM_MOUSEMOVE) {
                            var pt = win32.POINT{ .x = 0, .y = 0 };
                            _ = win32.GetCursorPos(&pt);
                            if (!b.tray_hovering) {
                                b.tray_hovering = true;
                                var tme = win32.TRACKMOUSEEVENT{
                                    .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                                    .dwFlags = win32.TME_LEAVE,
                                    .hwndTrack = hwnd,
                                    .dwHoverTime = 0,
                                };
                                _ = win32.TrackMouseEvent(&tme);
                                if (b.mainWindow()) |mw| mw.emitEventPayload("trayHover", .{ .phase = "enter", .x = pt.x, .y = pt.y });
                            } else if (b.mainWindow()) |mw| {
                                mw.emitEventPayload("trayHover", .{ .phase = "move", .x = pt.x, .y = pt.y });
                            }
                            return 0;
                        }
                        // v0.1.13：左右键/中键/双击行为可配置
                        const action: shared_system.ClickAction = if (lparam == win32.WM_LBUTTONUP)
                            b.tray_click_left
                        else if (lparam == WM_LBUTTONDBLCLK)
                            b.tray_click_double
                        else if (lparam == WM_MBUTTONUP)
                            b.tray_click_middle
                        else if (lparam == win32.WM_RBUTTONUP)
                            .show_menu
                        else
                            .none;
                        b.applyTrayClick(hwnd, action);
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
                WM_ZILT_FSWATCH => {
                    const ev: *FsWatchEvent = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    defer {
                        const a = std.heap.page_allocator;
                        a.free(ev.path);
                        a.destroy(ev);
                    }
                    if (instance) |b| {
                        if (b.mainWindow()) |w| {
                            w.emitEventPayload("fsEvent", .{ .id = ev.id, .action = ev.action, .path = ev.path });
                        }
                    }
                    return 0;
                },
                WM_ZILT_FSCHUNK => {
                    const ch: *FsChunk = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    defer {
                        const a = std.heap.page_allocator;
                        a.free(ch.data);
                        a.destroy(ch);
                    }
                    if (instance) |b| {
                        if (b.mainWindow()) |w| {
                            w.emitEventPayload("fsChunk", .{ .id = ch.id, .seq = ch.seq, .done = ch.done, .data = ch.data });
                        }
                    }
                    return 0;
                },
                WM_ZILT_HTTP_CHUNK => {
                    const ch: *HttpChunk = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    defer freeHttpChunk(ch);
                    if (instance) |b| {
                        if (b.mainWindow()) |w| {
                            w.emitEventPayload("httpChunk", .{ .id = ch.id, .seq = ch.seq, .data = ch.data });
                        }
                    }
                    return 0;
                },
                WM_ZILT_HTTP_PROGRESS => {
                    // v0.3.8 E6：multipart 上传进度（worker 侧已节流 ~10Hz）
                    const p: *HttpProgress = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    defer freeHttpProgress(p);
                    if (instance) |b| {
                        if (b.mainWindow()) |w| {
                            w.emitEventPayload("httpUploadProgress", .{ .id = p.id, .written = p.written, .total = p.total });
                        }
                    }
                    return 0;
                },
                WM_ZILT_HTTP => {
                    const res: *HttpResult = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    defer freeHttpResult(res);
                    if (instance) |b| {
                        if (b.mainWindow()) |w| {
                            w.emitEventPayload("httpResponse", .{
                                .id = res.id,
                                .status = res.status,
                                .body = res.body,
                                .err = res.err,
                            });
                        }
                        log.print("[http] done id={d} status={d} bytes={d} err={s}", .{
                            res.id, res.status, res.body.len, res.err orelse "-",
                        });
                    }
                    return 0;
                },
                WM_ZILT_WS => {
                    const ev: *WsEvent = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    defer freeWsEvent(ev);
                    if (instance) |b| {
                        const w = b.mainWindow();
                        switch (ev.kind) {
                            .open => {
                                if (w) |mw| {
                                    if (ev.tls) |tc| {
                                        const t = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, wssReadLoop, .{tc}) catch null;
                                        if (t) |th| {
                                            tc.read_thread = th;
                                            b.wss_conns.append(b.allocator, tc) catch {};
                                            log.print("[ws] wss open id={d}", .{ev.id});
                                            mw.emitEventPayload("wsEvent", .{ .id = ev.id, .kind = "open" });
                                        } else {
                                            mw.emitEventPayload("wsEvent", .{ .id = ev.id, .kind = "error", .err = "WsSpawnFailed" });
                                            {
                                            tc.ws.deinit();
                                            std.heap.page_allocator.destroy(tc);
                                        }
                                        }
                                    } else if (ev.conn) |conn| {
                                        const t = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, wsReadLoop, .{conn}) catch null;
                                        if (t) |th| {
                                            conn.read_thread = th;
                                            b.ws_conns.append(b.allocator, conn) catch {};
                                            log.print("[ws] open id={d}", .{ev.id});
                                            mw.emitEventPayload("wsEvent", .{ .id = ev.id, .kind = "open" });
                                        } else {
                                            // 起不了读线程：直接释放，并报 error
                                            mw.emitEventPayload("wsEvent", .{ .id = ev.id, .kind = "error", .err = "WsSpawnFailed" });
                                            b.wsRemoveConn(conn);
                                        }
                                    }
                                } else if (ev.conn) |conn| {
                                    b.wsRemoveConn(conn);
                                } else if (ev.tls) |tc| {
                                    {
                                            tc.ws.deinit();
                                            std.heap.page_allocator.destroy(tc);
                                        }
                                }
                            },
                            .message => {
                                if (w) |mw| mw.emitEventPayload("wsEvent", .{ .id = ev.id, .kind = "message", .data = ev.data, .binary = ev.binary });
                            },
                            .close => {
                                if (w) |mw| mw.emitEventPayload("wsEvent", .{ .id = ev.id, .kind = "close", .code = ev.code, .reason = ev.reason });
                                if (ev.conn) |conn| b.wsRemoveConn(conn);
                                if (ev.tls) |tc| b.wssRemoveConn(tc);
                                log.print("[ws] closed id={d} code={d}", .{ ev.id, ev.code });
                            },
                            .err => {
                                if (w) |mw| mw.emitEventPayload("wsEvent", .{ .id = ev.id, .kind = "error", .err = ev.err });
                                if (ev.conn) |conn| b.wsRemoveConn(conn);
                                if (ev.tls) |tc| b.wssRemoveConn(tc);
                                log.print("[ws] error id={d}: {s}", .{ ev.id, ev.err orelse "-" });
                            },
                        }
                    }
                    return 0;
                },
                WM_ZILT_EVAL => {
                    const job: *EvalJob = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    if (instance) |b| b.runEvalJob(job) else {
                        const a = std.heap.page_allocator;
                        a.free(job.script);
                        a.destroy(job);
                    }
                    return 0;
                },
                WM_ZILT_PROC => {
                    const ev: *ProcEvent = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    defer {
                        const a = std.heap.page_allocator;
                        if (ev.data) |d| a.free(d);
                        a.destroy(ev);
                    }
                    if (instance) |b| {
                        if (b.mainWindow()) |mw| {
                            switch (ev.kind) {
                                .out => mw.emitEventPayload("processEvent", .{
                                    .id = ev.id,
                                    .kind = if (ev.which == .stdout) "stdout" else "stderr",
                                    .data = ev.data,
                                }),
                                .exit => mw.emitEventPayload("processEvent", .{
                                    .id = ev.id,
                                    .kind = "exit",
                                    .code = ev.code,
                                }),
                            }
                        }
                        if (ev.kind == .exit) {
                            // exit 事件是槽的终点：join worker + 释放 io
                            for (b.procs.items, 0..) |p, i| {
                                if (p.id == ev.id) {
                                    _ = b.procs.swapRemove(i);
                                    p.worker.join();
                                    if (p.threaded) |t| {
                                        t.deinit();
                                        std.heap.page_allocator.destroy(t);
                                    }
                                    std.heap.page_allocator.destroy(p);
                                    break;
                                }
                            }
                        }
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

        /// v0.1.23：代理窗口的 Environment 创建完成 → 记到窗口上并建 controller。
        const WindowEnvCompletedHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            backend: *Self,
            window: *Window,

            pub const COM_IIDS = [_]com.GUID{wv2.IID_EnvironmentCompletedHandler};

            pub const VTable = extern struct {
                QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
                AddRef: *const fn (*anyopaque) callconv(.c) u32,
                Release: *const fn (*anyopaque) callconv(.c) u32,
                Invoke: *const fn (*anyopaque, HRESULT, ?*wv2.ICoreWebView2Environment) callconv(.c) HRESULT,
            };
            pub const vtable = VTable{
                .QueryInterface = com.ComVTableMixin(WindowEnvCompletedHandler).queryInterface,
                .AddRef = com.ComVTableMixin(WindowEnvCompletedHandler).addRef,
                .Release = com.ComVTableMixin(WindowEnvCompletedHandler).release,
                .Invoke = invoke,
            };

            fn create(backend: *Self, window: *Window) !*WindowEnvCompletedHandler {
                const h = try backend.allocator.create(WindowEnvCompletedHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend, .window = window };
                return h;
            }
            pub fn comDestroy(self: *WindowEnvCompletedHandler) void {
                self.backend.allocator.destroy(self);
            }
            pub fn dropRef(self: *WindowEnvCompletedHandler) void {
                _ = com.ComVTableMixin(WindowEnvCompletedHandler).release(@ptrCast(self));
            }

            fn invoke(self_: *anyopaque, error_code: HRESULT, env: ?*wv2.ICoreWebView2Environment) callconv(.c) HRESULT {
                const self: *WindowEnvCompletedHandler = @ptrCast(@alignCast(self_));
                if (com.failed(error_code) or env == null) {
                    log.print("[proxy] window #{d} environment failed hr=0x{x}", .{ self.window.id, @as(u32, @bitCast(error_code)) });
                    return com.S_OK;
                }
                self.window.own_env = env;
                _ = env.?.lpVtbl.AddRef(env.?);
                log.print("[proxy] window #{d} environment ready", .{self.window.id});
                self.backend.beginControllerWithEnv(self.window, env.?);
                return com.S_OK;
            }
        };

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
            /// 非 null = 附加子 webview 的 controller（v0.1.16）
            child: ?*ChildWebview = null,

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
            fn createChild(backend: *Self, window: *Window, child: *ChildWebview) !*ControllerCompletedHandler {
                const h = try backend.allocator.create(ControllerCompletedHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend, .window = window, .child = child };
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
                if (self.child) |c| return self.invokeChild(c, error_code, controller);
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

            fn invokeChild(self: *ControllerCompletedHandler, c: *ChildWebview, error_code: HRESULT, controller: ?*wv2.ICoreWebView2Controller) HRESULT {
                if (!self.window.alive) {
                    // 窗口已销毁：child 已随窗口释放，controller 无人认领，直接释放
                    if (controller) |ctl| _ = ctl.lpVtbl.Release(ctl);
                    return com.S_OK;
                }
                if (com.failed(error_code) or controller == null) {
                    log.print("[webviews] child controller failed hr=0x{x}", .{@as(u32, @bitCast(error_code))});
                    return com.S_OK;
                }
                // child 可能已在就绪前被 remove：从窗口槽里查不到就放弃
                var found = false;
                for (self.window.child_webviews.items) |slot| {
                    if (slot == c) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    _ = controller.?.lpVtbl.Release(controller.?);
                    return com.S_OK;
                }
                self.backend.onChildControllerReady(self.window, c, controller.?);
                return com.S_OK;
            }
        };

        /// v0.3.12 A11：组合 controller 创建回调（异步）——Invoke 收
        /// ICoreWebView2CompositionController → DComp 装配 + driver attach。
        const CompositionControllerCompletedHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            backend: *Self,
            window: *Window,

            pub const COM_IIDS = [_]com.GUID{wv2.IID_CompositionControllerCompletedHandler};

            pub const VTable = extern struct {
                QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
                AddRef: *const fn (*anyopaque) callconv(.c) u32,
                Release: *const fn (*anyopaque) callconv(.c) u32,
                Invoke: *const fn (*anyopaque, HRESULT, ?*wv2.ICoreWebView2CompositionController) callconv(.c) HRESULT,
            };
            pub const vtable = VTable{
                .QueryInterface = com.ComVTableMixin(CompositionControllerCompletedHandler).queryInterface,
                .AddRef = com.ComVTableMixin(CompositionControllerCompletedHandler).addRef,
                .Release = com.ComVTableMixin(CompositionControllerCompletedHandler).release,
                .Invoke = invoke,
            };

            fn create(backend: *Self, window: *Window) !*@This() {
                const h = try std.heap.page_allocator.create(@This());
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend, .window = window };
                return h;
            }

            fn dropRef(self: *@This()) void {
                _ = self.lpVtbl.Release(self);
            }

            pub fn comDestroy(self: *@This()) void {
                std.heap.page_allocator.destroy(self);
            }

            fn invoke(self_: *anyopaque, error_code: HRESULT, controller: ?*wv2.ICoreWebView2CompositionController) callconv(.c) HRESULT {
                const h: *@This() = @ptrCast(@alignCast(self_));
                defer _ = h.lpVtbl.Release(h);
                if (!h.window.alive) {
                    if (controller) |cc| cc.release();
                    return com.S_OK;
                }
                if (com.failed(error_code) or controller == null) {
                    log.print("[fatal] CreateCoreWebView2CompositionController failed hr=0x{x}", .{@as(u32, @bitCast(error_code))});
                    win32.PostQuitMessage(5);
                    return com.S_OK;
                }
                h.backend.onCompositionControllerReady(h.window, controller.?);
                return com.S_OK;
            }
        };

        /// v0.1.17：分区 Environment 创建回调（异步）——成功后建 controller，
        /// 并把 env 记入 backend.partitions（同名复用）。
        const PartitionEnvCompletedHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            backend: *Self,
            window: *Window,
            child: *ChildWebview,
            /// extern struct 不能放 slice：name 用 ptr + len 存
            name_ptr: [*]const u8,
            name_len: usize,

            fn name(self: *const PartitionEnvCompletedHandler) []const u8 {
                return self.name_ptr[0..self.name_len];
            }

            pub const COM_IIDS = [_]com.GUID{wv2.IID_EnvironmentCompletedHandler};

            pub const VTable = extern struct {
                QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
                AddRef: *const fn (*anyopaque) callconv(.c) u32,
                Release: *const fn (*anyopaque) callconv(.c) u32,
                Invoke: *const fn (*anyopaque, HRESULT, ?*wv2.ICoreWebView2Environment) callconv(.c) HRESULT,
            };
            pub const vtable = VTable{
                .QueryInterface = com.ComVTableMixin(PartitionEnvCompletedHandler).queryInterface,
                .AddRef = com.ComVTableMixin(PartitionEnvCompletedHandler).addRef,
                .Release = com.ComVTableMixin(PartitionEnvCompletedHandler).release,
                .Invoke = invoke,
            };

            fn create(backend: *Self, window: *Window, child: *ChildWebview, part: []const u8) !*PartitionEnvCompletedHandler {
                const h = try backend.allocator.create(PartitionEnvCompletedHandler);
                h.* = .{
                    .lpVtbl = &vtable,
                    .refs = 1,
                    .backend = backend,
                    .window = window,
                    .child = child,
                    .name_ptr = (try backend.allocator.dupe(u8, part)).ptr,
                    .name_len = part.len,
                };
                return h;
            }
            pub fn comDestroy(self: *PartitionEnvCompletedHandler) void {
                self.backend.allocator.free(self.name_ptr[0..self.name_len]);
                self.backend.allocator.destroy(self);
            }
            pub fn dropRef(self: *PartitionEnvCompletedHandler) void {
                _ = com.ComVTableMixin(PartitionEnvCompletedHandler).release(@ptrCast(self));
            }

            fn invoke(self_: *anyopaque, error_code: HRESULT, env: ?*wv2.ICoreWebView2Environment) callconv(.c) HRESULT {
                const self: *PartitionEnvCompletedHandler = @ptrCast(@alignCast(self_));
                const backend = self.backend;
                const c = self.child;
                if (com.failed(error_code) or env == null) {
                    log.print("[webviews] partition '{s}' env failed hr=0x{x}", .{ self.name(), @as(u32, @bitCast(error_code)) });
                    return com.S_OK;
                }
                if (!self.window.alive) {
                    _ = env.?.lpVtbl.Release(env.?);
                    return com.S_OK;
                }
                const e = env.?;
                _ = e.lpVtbl.AddRef(e);
                c.env = e;
                // 记入分区表（同名已存在则复用旧的、释放本次引用）
                if (backend.findPartition(self.name())) |existing| {
                    _ = e.lpVtbl.Release(e);
                    c.env = existing;
                    _ = existing.lpVtbl.AddRef(existing);
                    backend.beginChildController(self.window, c, existing);
                } else {
                    backend.partitions.append(backend.allocator, .{
                        .name = backend.allocator.dupe(u8, self.name()) catch return com.S_OK,
                        .env = e,
                    }) catch return com.S_OK;
                    _ = e.lpVtbl.AddRef(e); // 表里持有一份
                    log.print("[webviews] partition '{s}' env ready", .{self.name()});
                    backend.beginChildController(self.window, c, e);
                }
                return com.S_OK;
            }
        };

        /// v0.1.17：子 webview ExecuteScript 结果 → `webviewEval` 事件。
        /// ExecuteScript 的 JSON 串由 WebView2 分配（不可 free），这里只读拷贝。
        const EvalCompletedHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            window: *Window,
            rid: i64,
            child_id: u32,

            pub const COM_IIDS = [_]com.GUID{wv2.IID_ExecuteScriptCompletedHandler};

            pub const VTable = extern struct {
                QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
                AddRef: *const fn (*anyopaque) callconv(.c) u32,
                Release: *const fn (*anyopaque) callconv(.c) u32,
                Invoke: *const fn (*anyopaque, HRESULT, ?[*:0]const u16) callconv(.c) HRESULT,
            };
            pub const vtable = VTable{
                .QueryInterface = com.ComVTableMixin(EvalCompletedHandler).queryInterface,
                .AddRef = com.ComVTableMixin(EvalCompletedHandler).addRef,
                .Release = com.ComVTableMixin(EvalCompletedHandler).release,
                .Invoke = invoke,
            };

            fn create(alloc: std.mem.Allocator, w: *Window, rid: i64, child_id: u32) !*EvalCompletedHandler {
                const h = try alloc.create(EvalCompletedHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .window = w, .rid = rid, .child_id = child_id };
                return h;
            }
            pub fn comDestroy(self: *EvalCompletedHandler) void {
                self.window.backend.allocator.destroy(self);
            }
            pub fn dropRef(self: *EvalCompletedHandler) void {
                _ = com.ComVTableMixin(EvalCompletedHandler).release(@ptrCast(self));
            }

            fn invoke(self_: *anyopaque, error_code: HRESULT, result: ?[*:0]const u16) callconv(.c) HRESULT {
                const self: *EvalCompletedHandler = @ptrCast(@alignCast(self_));
                const w = self.window;
                const a = w.backend.allocator;
                if (com.failed(error_code) or result == null) {
                    const payload = std.fmt.allocPrint(a, "{{\"rid\":{d},\"id\":{d},\"ok\":false,\"error\":\"JavaScriptException\"}}", .{ self.rid, self.child_id }) catch return com.S_OK;
                    defer a.free(payload);
                    if (ipc.encodeEvent(a, "webviewEval", payload)) |msg| {
                        w.emitJsonUi(msg); // 所有权转移给 emitJsonUi（它负责 free）
                    } else |_| {}
                    return com.S_OK;
                }
                const value = std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(result.?)) catch return com.S_OK;
                defer a.free(value);
                const payload = std.fmt.allocPrint(a, "{{\"rid\":{d},\"id\":{d},\"ok\":true,\"value\":{s}}}", .{ self.rid, self.child_id, value }) catch return com.S_OK;
                defer a.free(payload);
                if (ipc.encodeEvent(a, "webviewEval", payload)) |msg| {
                    w.emitJsonUi(msg); // 所有权转移给 emitJsonUi（它负责 free）
                } else |_| {}
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
                const self: *MessageHandler = @ptrCast(@alignCast(self_));
                const a = args orelse return com.E_POINTER;
                // v0.1.16：sender 即消息来源 webview（主/子通用）——
                // onWebMessage 的回复按 sender 落点路由
                onWebMessage(self.window, a, sender);
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

    const channel: updater.UpdateChannel = if (std.mem.eql(u8, uc.channel, "beta")) .beta else .stable;

    // v0.3.4：skipped.json（用户跳过的版本；缺失 = 无跳过）
    var skipped_version: ?[]const u8 = null;
    if (self.storage_root) |root| {
        const skip_path = std.fmt.allocPrint(self.allocator, "{s}\\skipped.json", .{root}) catch null;
        if (skip_path) |sp| {
            defer self.allocator.free(sp);
            if (win32.readFileAlloc(self.allocator, sp)) |body| {
                defer self.allocator.free(body);
                if (updater.parseSkipped(self.allocator, body)) |sk| {
                    skipped_version = self.allocator.dupe(u8, sk.version) catch null;
                }
            }
        }
    }

    return .{
        .channel = channel,
        .manifest_url = manifest_url,
        .public_key = pk,
        .current_version = uc.current_version,
        .exe_path = try currentExePath(self.allocator),
        .exe_name = uc.exe_name,
        .fetcher = .{ .ctx = self, .fetchFn = httpFetch },
        .github_repo = uc.github_repo,
        .skipped_version = skipped_version,
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

/// 服务条目 JSON。name/scope 是开发者提供的标识符，仍做最小转义以免坏 JSON。
fn appendServiceJson(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    scope: []const u8,
    started: bool,
) !void {
    try out.appendSlice(alloc, "{\"name\":\"");
    try appendJsonEscaped(alloc, out, name);
    try out.appendSlice(alloc, "\",\"scope\":\"");
    try appendJsonEscaped(alloc, out, scope);
    try out.appendSlice(alloc, "\",\"started\":");
    try out.appendSlice(alloc, if (started) "true" else "false");
    try out.append(alloc, '}');
}

fn appendJsonEscaped(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
}

// ---------------------------------------------------------------------------
// v0.1.16：HTTP 请求（后台线程执行，结果 PostMessage 回 UI 线程）
// ---------------------------------------------------------------------------

/// 后台线程 → UI 线程的结果。page_allocator 持有，UI 线程取走后 free。
const HttpResult = struct {
    id: i64,
    status: u16,
    body: []u8,
    err: ?[]u8,
};

const HttpJob = struct {
    hwnd: win32.HWND,
    id: i64,
    url: []const u8 = "",
    method: []const u8 = "GET",
    headers: []const u8 = "",
    body: []const u8 = "",
    timeout_ms: u32 = 30_000,
    proxy: ?[]const u8 = null,
    insecure_tls: bool = false,
    follow_redirects: bool = true,
    stream: bool = false,
    /// v0.3.8 E6：multipart 上传进度（WriteData 分块回调节流上报）
    progress: bool = false,
    parts: []const shared_system.MultiPart = &.{},
    /// 所有字符串都从 arena 分配：freeHttpJob 一次回收
    arena: std.heap.ArenaAllocator,
};

fn freeHttpJob(job: *HttpJob) void {
    const a = std.heap.page_allocator;
    var j = job.*;
    j.arena.deinit();
    a.destroy(job);
}

/// 把请求深拷贝进 job（arena），任何分配失败都清理干净。
fn makeHttpJob(hwnd: win32.HWND, req: shared_system.HttpRequest) ?*HttpJob {
    const a = std.heap.page_allocator;
    const job = a.create(HttpJob) catch return null;
    job.* = .{ .hwnd = hwnd, .id = req.id, .arena = std.heap.ArenaAllocator.init(a) };
    const ja = job.arena.allocator();

    job.url = ja.dupe(u8, req.url) catch return fail: {
        freeHttpJob(job);
        break :fail null;
    };
    job.method = ja.dupe(u8, req.method) catch return fail: {
        freeHttpJob(job);
        break :fail null;
    };
    job.headers = ja.dupe(u8, req.headers) catch return fail: {
        freeHttpJob(job);
        break :fail null;
    };
    job.body = ja.dupe(u8, req.body) catch return fail: {
        freeHttpJob(job);
        break :fail null;
    };
    job.timeout_ms = req.timeout_ms;
    job.insecure_tls = req.insecure_tls;
    job.follow_redirects = req.follow_redirects;
    job.stream = req.stream;
    job.progress = req.upload_progress;
    if (req.proxy) |p| job.proxy = ja.dupe(u8, p) catch null;

    if (req.multipart) |parts| {
        if (parts.len > 0) {
            const owned = ja.alloc(shared_system.MultiPart, parts.len) catch {
                freeHttpJob(job);
                return null;
            };
            for (parts, 0..) |p, i| {
                owned[i] = .{
                    .name = ja.dupe(u8, p.name) catch {
                        freeHttpJob(job);
                        return null;
                    },
                    .data = ja.dupe(u8, p.data) catch {
                        freeHttpJob(job);
                        return null;
                    },
                    .filename = if (p.filename) |f| ja.dupe(u8, f) catch null else null,
                    .content_type = if (p.content_type) |c| ja.dupe(u8, c) catch null else null,
                    .encoding = ja.dupe(u8, p.encoding) catch "text",
                };
            }
            job.parts = owned;
        }
    }
    return job;
}

fn freeHttpResult(res: *HttpResult) void {
    const a = std.heap.page_allocator;
    a.free(res.body);
    if (res.err) |e| a.free(e);
    a.destroy(res);
}

fn parseHttpMethod(m: []const u8) std.http.Method {
    if (std.ascii.eqlIgnoreCase(m, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(m, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(m, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(m, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(m, "HEAD")) return .HEAD;
    return .GET;
}

/// `"A: 1\nB: 2"` → 头列表。name/value 指向 raw（job 存活期内有效）。
fn parseHeaderList(a: std.mem.Allocator, raw: []const u8) ![]std.http.Header {
    var list: std.ArrayListUnmanaged(std.http.Header) = .empty;
    errdefer list.deinit(a);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const name = std.mem.trim(u8, t[0..colon], " \t");
        const value = std.mem.trim(u8, t[colon + 1 ..], " \t");
        if (name.len == 0) continue;
        try list.append(a, .{ .name = name, .value = value });
    }
    return list.toOwnedSlice(a);
}

/// v0.1.20：流式分块（worker → UI 线程，data 为 base64）。
const HttpChunk = struct {
    hwnd: win32.HWND,
    id: i64,
    seq: u32,
    data: []u8,
};

fn freeHttpChunk(ch: *HttpChunk) void {
    const a = std.heap.page_allocator;
    a.free(ch.data);
    a.destroy(ch);
}

const ChunkCtx = struct {
    hwnd: win32.HWND,
    id: i64,
    seq: u32 = 0,
};

fn httpChunkCb(ctx: *anyopaque, data: []const u8) bool {
    const c: *ChunkCtx = @ptrCast(@alignCast(ctx));
    const a = std.heap.page_allocator;
    const b64 = net_mod.base64Alloc(a, data) catch return false;
    const ch = a.create(HttpChunk) catch {
        a.free(b64);
        return false;
    };
    ch.* = .{ .hwnd = c.hwnd, .id = c.id, .seq = c.seq, .data = b64 };
    c.seq += 1;
    if (win32.PostMessageW(c.hwnd, WM_ZILT_HTTP_CHUNK, 0, @bitCast(@intFromPtr(ch))) == 0) {
        freeHttpChunk(ch);
        return false;
    }
    return true;
}

// ---- v0.3.8 E6：multipart 上传进度（worker → UI 线程，~10Hz 节流）----

/// worker 侧进度状态（栈变量，request() 同步使用）。
const ProgressCtx = struct {
    hwnd: win32.HWND,
    id: i64,
    total: usize,
    last_ms: i64 = 0,
};

/// worker → UI 线程的进度帧。page_allocator 持有，UI 线程 free。
const HttpProgress = struct {
    hwnd: win32.HWND,
    id: i64,
    written: usize,
    total: usize,
};

fn freeHttpProgress(p: *HttpProgress) void {
    std.heap.page_allocator.destroy(p);
}

/// WriteData 每块回调：节流 10Hz（首块 + 末块必发，保证 0 与 total 可见）。
fn httpUploadCb(ctx: *anyopaque, written: usize, total: usize) bool {
    const c: *ProgressCtx = @ptrCast(@alignCast(ctx));
    const a = std.heap.page_allocator;
    const now: i64 = @intCast(win32.GetTickCount64());
    const final = written >= total;
    if (!final and c.last_ms != 0 and now - c.last_ms < 100) return true; // 节流窗口内跳过
    c.last_ms = now;
    const p = a.create(HttpProgress) catch return true; // 进度帧丢失不影响上传本身
    p.* = .{ .hwnd = c.hwnd, .id = c.id, .written = written, .total = total };
    if (win32.PostMessageW(c.hwnd, WM_ZILT_HTTP_PROGRESS, 0, @bitCast(@intFromPtr(p))) == 0) {
        freeHttpProgress(p);
    }
    return true;
}

fn postHttpResult(job: *HttpJob, res: *HttpResult) void {
    if (win32.PostMessageW(job.hwnd, WM_ZILT_HTTP, 0, @bitCast(@intFromPtr(res))) == 0) {
        freeHttpResult(res);
    }
}

/// v0.1.20：WinHTTP 请求（支持 https、代理、超时、重定向策略、忽略证书、流式分块）。
fn httpWorker(job: *HttpJob) void {
    const a = std.heap.page_allocator;

    const res = a.create(HttpResult) catch {
        freeHttpJob(job);
        return;
    };
    res.* = .{
        .id = job.id,
        .status = 0,
        .body = a.alloc(u8, 0) catch &[_]u8{},
        .err = null,
    };

    const url = net_mod.parseUrl(job.url) catch {
        res.err = a.dupe(u8, "InvalidUrl") catch null;
        postHttpResult(job, res);
        freeHttpJob(job);
        return;
    };

    // multipart：覆盖 body 并补 Content-Type
    var mp: ?net_mod.Multipart = null;
    defer if (mp) |*m| m.deinit(a);
    var body: []const u8 = job.body;
    var headers: []const u8 = job.headers;
    var headers_owned: ?[]u8 = null;
    defer if (headers_owned) |h| a.free(h);
    var parts_tmp: []net_mod.Part = &.{};
    defer if (parts_tmp.len > 0) a.free(parts_tmp);
    // v0.3.8 E6：base64 编码分片在构建 multipart 前解码（buffer 随函数结束释放）
    var decoded_bufs: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (decoded_bufs.items) |d| a.free(d);
        decoded_bufs.deinit(a);
    }
    if (job.parts.len > 0) {
        parts_tmp = a.alloc(net_mod.Part, job.parts.len) catch &.{};
        for (job.parts, 0..) |p, i| {
            var data = p.data;
            if (std.ascii.eqlIgnoreCase(p.encoding, "base64")) {
                if (net_mod.base64DecodeAlloc(a, p.data)) |dec| {
                    decoded_bufs.append(a, dec) catch {
                        a.free(dec);
                    };
                    data = dec;
                } else |_| {
                    log.print("[http] part '{s}' base64 decode failed ({d}B) — sent as text", .{ p.name, p.data.len });
                }
            }
            parts_tmp[i] = .{ .name = p.name, .data = data, .filename = p.filename, .content_type = p.content_type };
        }
    }
    if (job.parts.len > 0) {
        var bbuf: [32]u8 = undefined;
        const boundary = net_mod.randomBoundary(&bbuf);
        mp = net_mod.buildMultipart(a, boundary, parts_tmp) catch {
            res.err = a.dupe(u8, "MultipartFailed") catch null;
            postHttpResult(job, res);
            freeHttpJob(job);
            return;
        };
        body = mp.?.body;
        headers_owned = std.fmt.allocPrint(a, "{s}{s}Content-Type: {s}", .{
            job.headers, if (job.headers.len > 0) "\n" else "", mp.?.content_type,
        }) catch null;
        if (headers_owned) |h| headers = h;
    }

    var cctx = ChunkCtx{ .hwnd = job.hwnd, .id = job.id };
    var pctx = ProgressCtx{ .hwnd = job.hwnd, .id = job.id, .total = body.len };
    const sink: ?winhttp.Sink = if (job.stream) .{ .ctx = &cctx, .on_chunk = httpChunkCb } else if (job.progress) .{
        .ctx = &pctx,
        .on_upload = httpUploadCb,
    } else null;

    const r = winhttp.request(a, url, .{
        .method = job.method,
        .headers = headers,
        .body = body,
        .timeout_ms = job.timeout_ms,
        .proxy = job.proxy,
        .insecure_tls = job.insecure_tls,
        .follow_redirects = job.follow_redirects,
    }, sink) catch |e| {
        res.err = a.dupe(u8, @errorName(e)) catch null;
        log.print("[http] {s} failed: {s}", .{ url.host, @errorName(e) });
        postHttpResult(job, res);
        freeHttpJob(job);
        return;
    };

    res.status = r.status;
    if (job.stream) {
        a.free(r.body);
    } else {
        a.free(res.body);
        res.body = r.body;
    }
    log.print("[http] {s}{s} -> {d} ({d} bytes{s})", .{
        if (url.secure) "https://" else "http://", url.host, r.status, res.body.len,
        if (job.stream) ", streamed" else "",
    });
    postHttpResult(job, res);
    freeHttpJob(job);
}

// ---------------------------------------------------------------------------
// v0.1.16：WebSocket 客户端（协议层在 shared ws.zig，这里做线程与连接编排）
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// v0.1.16：单窗口多 WebView
// ---------------------------------------------------------------------------

        /// 附加子 WebView。WebView2 一个 HWND 只能绑一个 controller，所以每个
        /// 附加 webview 各有一个 WS_CHILD 子窗口（父 = 应用窗口）。同一 Environment
        /// → 同一 user data folder（Cookie/存储共享）；独立分区需要独立 env，留待后续。
        /// 生命周期：create（HWND 同步创建，controller 异步就绪）→ remove / 窗口销毁时释放。

// ---------------------------------------------------------------------------
// v0.1.16：子进程执行（协议层 ProcessOp；线程与事件编排在此）
// ---------------------------------------------------------------------------

/// v0.1.16：子进程槽。worker 线程负责 spawn→读两路输出→wait，
/// 结束时发 exit 事件 → UI 线程 join worker 并释放。
const ProcSlot = struct {
    id: i64,
    hwnd: win32.HWND,
    child: std.process.Child = undefined,
    /// 共享 Threaded io（spawn/读管道/wait 都走它；deinit 在 UI 线程 join 后）
    threaded: ?*std.Io.Threaded = null,
    worker: std.Thread = undefined,
    /// exit 事件已发（slot 已不可 kill）
    dead: bool = false,
};

/// worker → UI 线程事件。page_allocator 持有，UI 线程 free。
const ProcEvent = struct {
    pub const Kind = enum { out, exit };
    id: i64,
    kind: Kind,
    hwnd: win32.HWND,
    which: enum { stdout, stderr } = .stdout,
    data: ?[]u8 = null,
    code: i64 = 0,
};

fn procPostEvent(ev: *ProcEvent) void {
    if (win32.PostMessageW(ev.hwnd, WM_ZILT_PROC, 0, @bitCast(@intFromPtr(ev))) == 0) {
        const a = std.heap.page_allocator;
        if (ev.data) |d| a.free(d);
        a.destroy(ev);
    }
}

/// 单路管道读循环：takeByte 填 4KB 缓冲，满/EOF 时发 out 事件。
fn procReadPipe(slot: *ProcSlot, file: std.Io.File, which: @TypeOf(@as(ProcEvent, undefined).which)) void {
    const a = std.heap.page_allocator;
    const io = slot.threaded.?.io();
    var buf: [8192]u8 = undefined;
    var rd = file.reader(io, &buf);
    var chunk: [4096]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const b = rd.interface.takeByte() catch break; // EOF / 错误
        chunk[n] = b;
        n += 1;
        if (n == chunk.len) {
            const ev = a.create(ProcEvent) catch {
                n = 0;
                continue;
            };
            ev.* = .{ .id = slot.id, .kind = .out, .hwnd = slot.hwnd, .which = which, .data = a.dupe(u8, chunk[0..n]) catch null };
            procPostEvent(ev);
            n = 0;
        }
    }
    if (n > 0) {
        const ev = a.create(ProcEvent) catch return;
        ev.* = .{ .id = slot.id, .kind = .out, .hwnd = slot.hwnd, .which = which, .data = a.dupe(u8, chunk[0..n]) catch null };
        procPostEvent(ev);
    }
}

/// 子进程 worker：spawn → 两路读线程 → join → wait → exit 事件。
/// spawn 失败也发 exit（code=-1），前端凭 id 收尾。
fn procWorker(slot: *ProcSlot, argv: [][]u8, cwd: ?[]u8) void {
    const a = std.heap.page_allocator;
    defer {
        for (argv) |arg| a.free(arg);
        a.free(argv);
        if (cwd) |c| a.free(c);
    }

    const threaded = a.create(std.Io.Threaded) catch {
        const ev = a.create(ProcEvent) catch return;
        ev.* = .{ .id = slot.id, .kind = .exit, .hwnd = slot.hwnd, .code = -1 };
        procPostEvent(ev);
        return;
    };
    threaded.* = .init(a, .{});
    slot.threaded = threaded;
    const io = threaded.io();

    const spawned = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| {
        log.print("[proc] spawn failed id={d}: {s}", .{ slot.id, @errorName(e) });
        const ev = a.create(ProcEvent) catch return;
        ev.* = .{ .id = slot.id, .kind = .exit, .hwnd = slot.hwnd, .code = -1 };
        procPostEvent(ev);
        return;
    };
    slot.child = spawned;
    log.print("[proc] spawned id={d}", .{slot.id});

    const OutWhich = @TypeOf(@as(ProcEvent, undefined).which);
    const t1: ?std.Thread = std.Thread.spawn(.{}, procReadPipe, .{ slot, slot.child.stdout.?, @as(OutWhich, .stdout) }) catch null;
    const t2: ?std.Thread = std.Thread.spawn(.{}, procReadPipe, .{ slot, slot.child.stderr.?, @as(OutWhich, .stderr) }) catch null;
    if (t1) |t| t.join();
    if (t2) |t| t.join();

    var code: i64 = -1;
    if (slot.child.wait(io)) |term| {
        code = switch (term) {
            .exited => |c| @intCast(c),
            else => -1,
        };
    } else |_| {}
    const ev = a.create(ProcEvent) catch return;
    ev.* = .{ .id = slot.id, .kind = .exit, .hwnd = slot.hwnd, .code = code };
    procPostEvent(ev);
    log.print("[proc] exited id={d} code={d}", .{ slot.id, code });
}

const ChildWebview = struct {
    id: u32,
    hwnd: win32.HWND,
    controller: ?*wv2.ICoreWebView2Controller = null,
    webview: ?*wv2.ICoreWebView2 = null,
    /// controller 尚未就绪时排队的目标 URL（create/navigate 都可能早于 ready）
    pending_url: ?[]u8 = null,
    /// v0.1.17：数据分区名（page_allocator 持有）。null = 共享主 Environment。
    partition: ?[]u8 = null,
    /// 分区 Environment（本 child 持有的一份引用，销毁时 Release）
    env: ?*wv2.ICoreWebView2Environment = null,
    /// v0.3.2：无痕子 webview（InPrivate controller；与 partition 互斥，incognito 优先）
    incognito: bool = false,
};

/// v0.1.17：子 webview eval 的延后任务（WM_ZILT_EVAL 携带，UI 线程执行）
const EvalJob = struct {
    window_id: u32,
    child_id: u32,
    rid: i64,
    script: []u8,
};

/// v0.1.17：分区 Environment 表项（key 为规范化后的分区名）
const PartitionEnv = struct {
    name: []u8,
    env: *wv2.ICoreWebView2Environment,
};

/// 分区名规范化为可安全做目录名：保留字母/数字/-/_，其余转 '_'，最长 64。
pub fn sanitizePartition(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (raw) |c| {
        if (out.items.len >= 64) break;
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        try out.append(alloc, if (ok) c else '_');
    }
    if (out.items.len == 0) try out.appendSlice(alloc, "default");
    return out.toOwnedSlice(alloc);
}

test "sanitizePartition keeps safe chars and replaces the rest" {
    const a = std.testing.allocator;
    const p1 = try sanitizePartition(a, "login-oauth_2");
    defer a.free(p1);
    try std.testing.expectEqualStrings("login-oauth_2", p1);
    const p2 = try sanitizePartition(a, "a/b c:d");
    defer a.free(p2);
    try std.testing.expectEqualStrings("a_b_c_d", p2);
    const p3 = try sanitizePartition(a, "");
    defer a.free(p3);
    try std.testing.expectEqualStrings("default", p3);
    const long: [80]u8 = @splat('x');
    const p4 = try sanitizePartition(a, &long);
    defer a.free(p4);
    try std.testing.expectEqual(@as(usize, 64), p4.len);
}

/// 一个活跃连接。生命周期：worker 握手成功后创建 → UI 线程 open 事件时
/// 注册到 ws_conns 并起读循环 → close 事件时 wsRemoveConn 统一销毁。
/// 写端被 UI（send/close）与读循环（自动 pong）共享 → 必须 mutex 串行化，
/// 否则两个线程的 writeAll 会把帧头和载荷撕开。
const WsConn = struct {
    id: i64,
    hwnd: win32.HWND,
    io: std.Io,
    threaded: *std.Io.Threaded,
    stream: std.Io.net.Stream,
    /// 每连接一个掩码（RFC 只要求客户端帧带掩码，不要求逐帧不同）
    mask: [4]u8,
    wbuf: [4096]u8 = undefined,
    wr: std.Io.net.Stream.Writer = undefined,
    write_mutex: std.Io.Mutex = .init,
    /// 读循环线程句柄；由 UI 线程在 close 清理时 join
    read_thread: std.Thread = undefined,
    /// UI 已主动发起关闭 → 读循环不再回 echo close（RFC close 握手只发一次）
    closing: bool = false,
};

/// v0.1.22：目录监视槽（ReadDirectoryChangesW 阻塞读，unwatch 时关句柄唤醒）。
const FsWatch = struct {
    id: i64,
    hwnd: win32.HWND,
    handle: win32.HANDLE,
    recursive: bool = true,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: std.Thread = undefined,
};

const FsWatchEvent = struct {
    hwnd: win32.HWND,
    id: i64,
    action: []const u8,
    path: []u8,
};

fn fsWatchMain(wv: *FsWatch) void {
    const a = std.heap.page_allocator;
    var buf: [16 * 1024]u8 align(4) = undefined;
    const filter = win32.FILE_NOTIFY_CHANGE_FILE_NAME | win32.FILE_NOTIFY_CHANGE_DIR_NAME |
        win32.FILE_NOTIFY_CHANGE_LAST_WRITE | win32.FILE_NOTIFY_CHANGE_SIZE;
    while (!wv.stopping.load(.acquire)) {
        var bytes: win32.DWORD = 0;
        if (win32.ReadDirectoryChangesW(wv.handle, &buf, buf.len, if (wv.recursive) 1 else 0, filter, &bytes, null, null) == 0) break;
        if (bytes == 0) continue;
        var off: usize = 0;
        while (off + @sizeOf(win32.FILE_NOTIFY_INFORMATION) <= bytes) {
            const info: *const win32.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(&buf[off]));
            const name_units: usize = info.FileNameLength / 2;
            const name_ptr: [*]const u16 = @ptrCast(@alignCast(&buf[off + @sizeOf(win32.FILE_NOTIFY_INFORMATION)]));
            const name = std.unicode.utf16LeToUtf8Alloc(a, name_ptr[0..name_units]) catch null;
            if (name) |n| {
                const action: []const u8 = switch (info.Action) {
                    win32.FILE_ACTION_ADDED => "added",
                    win32.FILE_ACTION_REMOVED => "removed",
                    win32.FILE_ACTION_MODIFIED => "modified",
                    win32.FILE_ACTION_RENAMED_OLD_NAME => "renamed_old",
                    win32.FILE_ACTION_RENAMED_NEW_NAME => "renamed_new",
                    else => "unknown",
                };
                const ev = a.create(FsWatchEvent) catch {
                    a.free(n);
                    break;
                };
                ev.* = .{ .hwnd = wv.hwnd, .id = wv.id, .action = action, .path = n };
                if (win32.PostMessageW(wv.hwnd, WM_ZILT_FSWATCH, 0, @bitCast(@intFromPtr(ev))) == 0) {
                    a.free(n);
                    a.destroy(ev);
                    break;
                }
            }
            if (info.NextEntryOffset == 0) break;
            off += info.NextEntryOffset;
        }
    }
}

const FsStreamJob = struct {
    id: i64,
    hwnd: win32.HWND,
    path: []u8,
    chunk_size: u32,
};

const FsChunk = struct {
    hwnd: win32.HWND,
    id: i64,
    seq: u32,
    done: bool,
    data: []u8,
};

fn fsPostChunk(job: *FsStreamJob, seq: u32, done: bool, data: []u8) bool {
    const a = std.heap.page_allocator;
    const ch = a.create(FsChunk) catch {
        a.free(data);
        return false;
    };
    ch.* = .{ .hwnd = job.hwnd, .id = job.id, .seq = seq, .done = done, .data = data };
    if (win32.PostMessageW(job.hwnd, WM_ZILT_FSCHUNK, 0, @bitCast(@intFromPtr(ch))) == 0) {
        a.free(data);
        a.destroy(ch);
        return false;
    }
    return true;
}

/// v0.1.22：大文件分块读（base64 → fsChunk 事件），最后 done=true。
fn fsStreamMain(job: *FsStreamJob) void {
    const a = std.heap.page_allocator;
    defer {
        a.free(job.path);
        a.destroy(job);
    }
    const pw = std.unicode.utf8ToUtf16LeAllocZ(a, job.path) catch {
        _ = fsPostChunk(job, 0, true, a.alloc(u8, 0) catch &.{});
        return;
    };
    defer a.free(pw);
    const h = win32.CreateFileW(pw.ptr, win32.GENERIC_READ, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (h == win32.INVALID_HANDLE_VALUE) {
        _ = fsPostChunk(job, 0, true, a.alloc(u8, 0) catch &.{});
        return;
    }
    defer _ = win32.CloseHandle(h);

    const buf = a.alloc(u8, job.chunk_size) catch {
        _ = fsPostChunk(job, 0, true, a.alloc(u8, 0) catch &.{});
        return;
    };
    defer a.free(buf);

    var seq: u32 = 0;
    while (true) {
        var read: win32.DWORD = 0;
        if (win32.ReadFile(h, buf.ptr, job.chunk_size, &read, null) == 0) break;
        if (read == 0) break;
        const b64 = net_mod.base64Alloc(a, buf[0..read]) catch break;
        if (!fsPostChunk(job, seq, false, b64)) return;
        seq += 1;
    }
    _ = fsPostChunk(job, seq, true, a.alloc(u8, 0) catch &.{});
}

/// v0.1.20：wss 连接（WinHTTP WebSocket；ws:// 仍走上面的 raw 路径）。
/// 两条路径并存是为了不动机已实测的 ws:// 实现（分包/掩码/握手都是自研代码）。
const WssConn = struct {
    id: i64,
    hwnd: win32.HWND,
    ws: *winhttp.WebSocket,
    /// UI 已主动 close → 读循环不再重复 close
    closing: bool = false,
    read_thread: std.Thread = undefined,
};

const WssJob = struct {
    id: i64,
    hwnd: win32.HWND,
    url: []u8,
    proxy: ?[]u8 = null,
    insecure_tls: bool = false,
    headers: []u8 = &.{},
};

fn freeWssJob(job: *WssJob) void {
    const a = std.heap.page_allocator;
    a.free(job.url);
    if (job.proxy) |p| a.free(p);
    if (job.headers.len > 0) a.free(job.headers);
    a.destroy(job);
}

/// 后台线程：WinHTTP 建连 + WebSocket 升级，成功后把连接交给 UI 线程。
fn wssWorker(job: *WssJob) void {
    const a = std.heap.page_allocator;
    const url = net_mod.parseUrl(job.url) catch {
        wsPostError(job.id, job.hwnd, "InvalidUrl");
        freeWssJob(job);
        return;
    };
    const ws = winhttp.openWebSocket(a, url, .{
        .proxy = job.proxy,
        .insecure_tls = job.insecure_tls,
        .headers = job.headers,
    }) catch |e| {
        wsPostError(job.id, job.hwnd, @errorName(e));
        freeWssJob(job);
        return;
    };
    const conn = a.create(WssConn) catch {
        ws.deinit();
        wsPostError(job.id, job.hwnd, "OutOfMemory");
        freeWssJob(job);
        return;
    };
    conn.* = .{ .id = job.id, .hwnd = job.hwnd, .ws = ws };

    const ev = a.create(WsEvent) catch {
        ws.deinit();
        a.destroy(conn);
        freeWssJob(job);
        return;
    };
    ev.* = .{ .id = job.id, .kind = .open, .hwnd = job.hwnd, .tls = conn };
    if (win32.PostMessageW(job.hwnd, WM_ZILT_WS, 0, @bitCast(@intFromPtr(ev))) == 0) {
        freeWsEvent(ev);
        ws.deinit();
        a.destroy(conn);
        freeWssJob(job);
        return;
    }
    log.print("[ws] wss handshake ok id={d} ({s}:{d}{s})", .{ job.id, url.host, url.port, url.path });
    freeWssJob(job);
}

/// wss 读循环：WinHTTP 已处理 ping/pong，这里只做「分片累积 → 整帧事件」。
fn wssReadLoop(conn: *WssConn) void {
    const a = std.heap.page_allocator;
    var buf: [16 * 1024]u8 = undefined;
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(a);

    while (true) {
        const r = conn.ws.receive(&buf) catch |e| {
            wsPostError(conn.id, conn.hwnd, @errorName(e));
            return;
        };
        if (r.kind == .close) {
            const ev = a.create(WsEvent) catch return;
            ev.* = .{ .id = conn.id, .kind = .close, .hwnd = conn.hwnd, .tls = conn, .code = r.code };
            if (win32.PostMessageW(conn.hwnd, WM_ZILT_WS, 0, @bitCast(@intFromPtr(ev))) == 0) freeWsEvent(ev);
            return;
        }
        const fragmented = r.kind == .utf8_fragment or r.kind == .binary_fragment;
        acc.appendSlice(a, buf[0..r.n]) catch {
            wsPostError(conn.id, conn.hwnd, "OutOfMemory");
            return;
        };
        if (fragmented) continue;

        const binary = r.kind == .binary_message;
        const data = if (binary)
            net_mod.base64Alloc(a, acc.items) catch {
                wsPostError(conn.id, conn.hwnd, "OutOfMemory");
                return;
            }
        else
            a.dupe(u8, acc.items) catch {
                wsPostError(conn.id, conn.hwnd, "OutOfMemory");
                return;
            };
        const ev = a.create(WsEvent) catch {
            a.free(data);
            return;
        };
        ev.* = .{ .id = conn.id, .kind = .message, .hwnd = conn.hwnd, .data = data, .binary = binary };
        if (win32.PostMessageW(conn.hwnd, WM_ZILT_WS, 0, @bitCast(@intFromPtr(ev))) == 0) freeWsEvent(ev);
        acc.clearRetainingCapacity();
    }
}

/// 后台线程 → UI 线程的事件。page_allocator 持有，UI 线程取走后 free。
const WsEvent = struct {
    pub const Kind = enum { open, message, close, err };
    id: i64,
    kind: Kind,
    hwnd: win32.HWND,
    /// open：新连接（所有权移交 UI）；err：握手失败时的半成品连接（UI 清理）
    conn: ?*WsConn = null,
    /// v0.1.20：wss 连接（与 conn 互斥）
    tls: ?*WssConn = null,
    data: ?[]u8 = null,
    /// v0.1.20：binary 帧（data 为 base64）
    binary: bool = false,
    code: u16 = 0,
    reason: ?[]u8 = null,
    err: ?[]u8 = null,
};

const WsJob = struct {
    id: i64,
    hwnd: win32.HWND,
    url: []u8,
};

fn freeWsEvent(ev: *WsEvent) void {
    const a = std.heap.page_allocator;
    if (ev.data) |d| a.free(d);
    if (ev.reason) |r| a.free(r);
    if (ev.err) |e| a.free(e);
    a.destroy(ev);
}

fn wsPostEvent(ev: *WsEvent) void {
    if (win32.PostMessageW(ev.hwnd, WM_ZILT_WS, 0, @bitCast(@intFromPtr(ev))) == 0) {
        freeWsEvent(ev);
    }
}

/// 握手错误事件（conn 为 null —— 失败的连接由 worker 自己释放）。
fn wsPostError(id: i64, hwnd: win32.HWND, name: []const u8) void {
    const a = std.heap.page_allocator;
    const ev = a.create(WsEvent) catch return;
    ev.* = .{ .id = id, .kind = .err, .hwnd = hwnd, .err = a.dupe(u8, name) catch null };
    if (win32.PostMessageW(hwnd, WM_ZILT_WS, 0, @bitCast(@intFromPtr(ev))) == 0) {
        freeWsEvent(ev);
    }
}

/// 握手失败的本地清理：关 socket + 销毁 Threaded，再发 error 事件。
fn wsBail(stream: ?std.Io.net.Stream, io: std.Io, threaded: *std.Io.Threaded, id: i64, hwnd: win32.HWND, name: []const u8) void {
    if (stream) |s| s.close(io);
    threaded.deinit();
    const a = std.heap.page_allocator;
    a.destroy(threaded);
    wsPostError(id, hwnd, name);
}

/// 共享写路径：编码帧 + mutex 保护下的整体写出。UI 与读循环都走这里。
fn wsWriteFrame(conn: *WsConn, opcode: shared_ws.Opcode, payload: []const u8) !void {
    const a = std.heap.page_allocator;
    const wire = try shared_ws.encodeFrame(a, opcode, payload, conn.mask);
    defer a.free(wire);
    conn.write_mutex.lockUncancelable(conn.io);
    defer conn.write_mutex.unlock(conn.io);
    try conn.wr.interface.writeAll(wire);
    try conn.wr.interface.flush();
}

/// 握手 + 读循环，跑在独立线程上。握手失败发 error 事件并自清理；
/// 成功后发 open 事件（conn 所有权移交 UI），然后原地进入读循环，
/// 结束时发 close 事件 —— conn 的最终销毁一律由 UI 线程完成。
fn wsWorker(job: *WsJob) void {
    const a = std.heap.page_allocator;

    const threaded = a.create(std.Io.Threaded) catch {
        a.free(job.url);
        a.destroy(job);
        return;
    };
    threaded.* = .init(a, .{});
    const io = threaded.io();

    const u = shared_ws.parseUrl(job.url) catch |e| {
        wsBail(null, io, threaded, job.id, job.hwnd, @errorName(e));
        a.free(job.url);
        a.destroy(job);
        return;
    };

    const addr = std.Io.net.IpAddress.resolve(io, u.host, u.port) catch |e| {
        wsBail(null, io, threaded, job.id, job.hwnd, @errorName(e));
        a.free(job.url);
        a.destroy(job);
        return;
    };
    const stream = addr.connect(io, .{ .mode = .stream }) catch |e| {
        wsBail(null, io, threaded, job.id, job.hwnd, @errorName(e));
        a.free(job.url);
        a.destroy(job);
        return;
    };

    var seed: [16]u8 = undefined;
    io.random(&seed);
    var mask: [4]u8 = undefined;
    io.random(&mask);

    const key = shared_ws.encodeKey(a, seed) catch {
        wsBail(stream, io, threaded, job.id, job.hwnd, "OutOfMemory");
        a.free(job.url);
        a.destroy(job);
        return;
    };
    defer a.free(key);
    const expected = shared_ws.acceptKey(key);
    const req = shared_ws.handshakeRequest(a, u.host, u.port, u.path, key) catch {
        wsBail(stream, io, threaded, job.id, job.hwnd, "OutOfMemory");
        a.free(job.url);
        a.destroy(job);
        return;
    };
    defer a.free(req);

    const conn = a.create(WsConn) catch {
        wsBail(stream, io, threaded, job.id, job.hwnd, "OutOfMemory");
        a.free(job.url);
        a.destroy(job);
        return;
    };
    conn.* = .{
        .id = job.id,
        .hwnd = job.hwnd,
        .io = io,
        .threaded = threaded,
        .stream = stream,
        .mask = mask,
    };
    conn.wr = stream.writer(io, &conn.wbuf);

    // 发送握手请求（defer 已保证 unlock，catch 分支的 return 同样触发）
    {
        conn.write_mutex.lockUncancelable(conn.io);
        defer conn.write_mutex.unlock(conn.io);
        conn.wr.interface.writeAll(req) catch |e| {
            wsBail(stream, io, threaded, job.id, job.hwnd, @errorName(e));
            a.destroy(conn);
            a.free(job.url);
            a.destroy(job);
            return;
        };
        conn.wr.interface.flush() catch |e| {
            wsBail(stream, io, threaded, job.id, job.hwnd, @errorName(e));
            a.destroy(conn);
            a.free(job.url);
            a.destroy(job);
            return;
        };
    }

    // 读响应头（到 \r\n\r\n 为止；之后的数据由读循环继续消费）
    {
        var rbuf: [8192]u8 = undefined;
        var rd = stream.reader(io, &rbuf);
        var hdr: [2048]u8 = undefined;
        var hdr_len: usize = 0;
        while (hdr_len < hdr.len) {
            const b = rd.interface.takeByte() catch |e| {
                wsBail(stream, io, threaded, job.id, job.hwnd, @errorName(e));
                a.destroy(conn);
                a.free(job.url);
                a.destroy(job);
                return;
            };
            hdr[hdr_len] = b;
            hdr_len += 1;
            if (hdr_len >= 4 and std.mem.eql(u8, hdr[hdr_len - 4 .. hdr_len], "\r\n\r\n")) break;
        }
        shared_ws.verifyHandshake(hdr[0..hdr_len], &expected) catch |e| {
            wsBail(stream, io, threaded, job.id, job.hwnd, @errorName(e));
            a.destroy(conn);
            a.free(job.url);
            a.destroy(job);
            return;
        };
    }

    // 握手成功 → open 事件（conn 所有权移交 UI 线程）
    const ev = a.create(WsEvent) catch {
        wsBail(stream, io, threaded, job.id, job.hwnd, "OutOfMemory");
        a.destroy(conn);
        a.free(job.url);
        a.destroy(job);
        return;
    };
    ev.* = .{ .id = job.id, .kind = .open, .hwnd = job.hwnd, .conn = conn };
    if (win32.PostMessageW(job.hwnd, WM_ZILT_WS, 0, @bitCast(@intFromPtr(ev))) == 0) {
        // UI 已死：conn 未注册，UI 不会碰它，由本线程自清理
        freeWsEvent(ev);
        a.destroy(conn);
        wsBail(stream, io, threaded, job.id, job.hwnd, "WsPostFailed");
        a.free(job.url);
        a.destroy(job);
        return;
    }

    log.print("[ws] handshake ok id={d} ({s}:{d}{s})", .{ job.id, u.host, u.port, u.path });
    // 读循环由 UI 线程在 open 事件里 spawn（conn 所有权已移交）；
    // worker 在此结束，读循环结束后的 close 事件由读线程发出。
    a.free(job.url);
    a.destroy(job);
}

/// 读循环：解析帧 → 派发事件。文本/二进制转发，ping 自动 pong，
/// close 回声并发 close 事件，EOF 发 close(1006)。协议错误（分片帧等）
/// 发 error 事件并终止 —— 与 ws.zig 的「分片不支持」约定一致。
fn wsReadLoop(conn: *WsConn) void {
    const a = std.heap.page_allocator;
    var rbuf: [8192]u8 = undefined;
    var rd = conn.stream.reader(conn.io, &rbuf);

    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(a);

    var close_code: u16 = 1006;
    var close_reason: ?[]u8 = null;

    outer: while (true) {
        // takeByte：缓冲区空时阻塞底层 read，至少 1 字节即返回
        // （readSliceShort 要填满才返回，会永远卡在帧间隙 —— 探针实测踩过）
        const b = rd.interface.takeByte() catch break; // EOF / 读错误
        acc.append(a, b) catch break;

        while (acc.items.len >= 2) {
            const f = shared_ws.parseFrame(a, acc.items) catch |e| switch (e) {
                error.NeedMore => break,
                else => {
                    log.print("[ws] frame parse error id={d}: {s}", .{ conn.id, @errorName(e) });
                    break :outer;
                },
            };
            defer a.free(f.payload);
            const rest = acc.items.len - f.consumed;
            std.mem.copyForwards(u8, acc.items[0..rest], acc.items[f.consumed..]);
            acc.shrinkRetainingCapacity(rest);

            switch (f.opcode) {
                .text, .binary => {
                    const ev = a.create(WsEvent) catch continue;
                    ev.* = .{ .id = conn.id, .kind = .message, .hwnd = conn.hwnd, .data = a.dupe(u8, f.payload) catch null };
                    wsPostEvent(ev);
                },
                .ping => {
                    wsWriteFrame(conn, .pong, f.payload) catch break :outer;
                },
                .pong => {},
                .close => {
                    if (f.payload.len >= 2) close_code = (@as(u16, f.payload[0]) << 8) | f.payload[1];
                    if (f.payload.len > 2) close_reason = a.dupe(u8, f.payload[2..]) catch null;
                    if (!conn.closing) {
                        wsWriteFrame(conn, .close, f.payload) catch {};
                    }
                    break :outer;
                },
                .continuation => {
                    log.print("[ws] fragmented frame unsupported id={d}", .{conn.id});
                    break :outer;
                },
            }
        }
    }

    const ev = a.create(WsEvent) catch return;
    ev.* = .{
        .id = conn.id,
        .kind = .close,
        .hwnd = conn.hwnd,
        .conn = conn, // UI 收到后负责 join 读线程并销毁连接
        .code = close_code,
        .reason = close_reason,
    };
    wsPostEvent(ev);
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

    const m = updater.checkForUpdateEnv(arena.allocator(), env) catch |err| {
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
        // v0.3.4：下载/校验生命周期事件（细粒度字节进度需要 fetcher 回调，列后续）
        ctx.emit("updateDownloading", .{ .version = m.version });
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
