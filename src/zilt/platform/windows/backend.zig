//! Windows 平台后端：配置驱动的应用生命周期。
//!
//! Backend 按 Config 编译期实例化（Config.commands 等为 comptime type 字段）；
//! 运行时可变状态（dev 覆盖、退出码）为普通字段。
//!
//! 职责：窗口/消息循环、WebView2 生命周期、custom scheme 资产服务
//! （embedded 表 / dev 目录 / dev url 三种模式）、IPC 分发（含 origin 校验）、
//! 线程安全的 emit 编排（WM_APP marshal 到 UI 线程）、运行时 JS 注入、
//! dev 目录热重载 watcher。

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
const single_instance = @import("single_instance.zig");
const menu_mod = @import("menu.zig");
const hotkey_mod = @import("hotkey.zig");
const dialog_mod = @import("dialog.zig");

const HRESULT = com.HRESULT;
const WM_ZILT_EMIT: win32.UINT = win32.WM_APP + 1;
const WM_ZILT_NOTIFY: win32.UINT = win32.WM_APP + 2;
const WM_ZILT_TRAY: win32.UINT = win32.WM_APP + 3;
const SMOKE_ENV = "ZILT_SMOKE_TEST_MS";

pub fn run(comptime config: Config) !void {
    const B = Backend(config);
    log.initFileLog("zilt.log");
    const alloc = std.heap.page_allocator;

    // 单实例保护（第二实例立即以退出码 5 结束）
    if (config.single_instance) {
        if (single_instance.Guard.acquire(alloc, config.app_id) == null) {
            log.print("[single-instance] another instance is running -> exit({d})", .{single_instance.SECOND_INSTANCE_EXIT_CODE});
            std.process.exit(single_instance.SECOND_INSTANCE_EXIT_CODE);
        }
    }

    // 清理上次更新留下的备份
    if (config.update != null) {
        const exe_path = try currentExePath(alloc);
        updater.cleanupOld(alloc, exe_path);
    }

    _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    const hr_init = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
    if (com.failed(hr_init)) {
        log.print("[fatal] CoInitializeEx failed hr=0x{x}", .{@as(u32, @bitCast(hr_init))});
        return error.CoInitializeFailed;
    }
    defer _ = win32.CoUninitialize();

    var backend = try alloc.create(B);
    backend.* = .{ .allocator = alloc };
    B.setInstance(backend);
    defer {
        alloc.destroy(backend);
        B.setInstance(null);
    }

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
    if (win32.getEnvUtf8(alloc, "ZILT_DEV_PROXY")) |u| {
        backend.dev_proxy = u;
        // 反代模式优先生效（应用保持自身 origin；dev_url 仅作为 origin 白名单兜底无意义，忽略）
        if (backend.dev_url != null) log.print("[dev] ZILT_DEV_PROXY 与 ZILT_DEV_URL 同时设置：反代优先", .{});
        log.print("[dev] ZILT_DEV_PROXY={s}", .{u});
    }

    try backend.createWindow();
    _ = win32.ShowWindow(backend.hwnd.?, win32.SW_SHOW);
    _ = win32.UpdateWindow(backend.hwnd.?);
    log.print("[win32] window created: \"{s}\" {d}x{d}", .{ config.title, config.width, config.height });

    // 全局快捷键（编译期校验 key 合法性）
    if (B.hotkey_cfg) |hks| {
        if (hotkey_mod.registerAll(backend.hwnd.?, hks)) |failed_id| {
            log.print("[hotkey] register failed: {s}（可能被其他程序占用）", .{failed_id});
        } else {
            log.print("[hotkey] registered {} hotkeys", .{B.hotkey_count});
        }
    }

    var runtime = try loader.findRuntime(alloc);
    log.print("[loader] runtime version: {s}", .{runtime.version});
    if (std.unicode.utf16LeToUtf8Alloc(alloc, runtime.dll_path)) |dll_u8| {
        defer alloc.free(dll_u8);
        log.print("[loader] dll: {s}", .{dll_u8});
    } else |_| {}

    const udf = try buildUserDataFolder(alloc);
    defer alloc.free(udf.utf8);
    defer alloc.free(udf.utf16);

    const env_handler = try B.EnvCompletedHandler.create(backend);
    const hr_env = loader.createEnvironment(&runtime, udf.utf16.ptr, null, env_handler);
    env_handler.dropRef();
    if (com.failed(hr_env)) {
        log.print("[fatal] createEnvironment failed hr=0x{x}", .{@as(u32, @bitCast(hr_env))});
        return error.EnvironmentCreateFailed;
    }

    // 冒烟测试安全网（ZILT_SMOKE_TEST_MS 毫秒后强制退出）
    if (win32.getEnvUtf8(alloc, SMOKE_ENV)) |ms_str| {
        defer alloc.free(ms_str);
        const ms = std.fmt.parseInt(u32, ms_str, 10) catch 20000;
        _ = win32.SetTimer(backend.hwnd.?, 1, ms, null);
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

    backend.cleanup();
    if (backend.quit_code.load(.monotonic) != 0) return error.AppFailed;
}

const UserDataFolder = struct { utf8: []u8, utf16: [:0]u16 };

fn buildUserDataFolder(alloc: std.mem.Allocator) !UserDataFolder {
    const temp = win32.getEnvUtf8(alloc, "TEMP") orelse try alloc.dupe(u8, "C:\\Windows\\Temp");
    defer alloc.free(temp);
    const dir = try std.fmt.allocPrint(alloc, "{s}\\zilt-app-webview2", .{temp});
    const dir_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, dir);
    defer alloc.free(dir_w);
    _ = win32.CreateDirectoryW(dir_w.ptr, null);
    const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, dir);
    return .{ .utf8 = dir, .utf16 = utf16 };
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

/// gzip 解压（运行时：压缩资产的 serve 期还原；std.compress.flate）。
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
/// 注意：实测 WebView2 custom scheme 请求不携带 Accept-Encoding（§G.5）——
/// 此解析当前用于语义完备与未来 HTTP 通道（反代/本地 server）。
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

fn Backend(comptime config: Config) type {
    return struct {
        const Self = @This();

        /// comptime 固化的配置切片（供 comptime 参数的反射函数使用）
        const menu_cfg: ?[]const Config.MenuItem = config.menu;
        const hotkey_cfg: ?[]const Config.Hotkey = config.hotkeys;
        const menu_leaf_count: usize = if (config.menu) |items| menu_mod.collectIds(items).len else 0;
        const hotkey_count: usize = if (config.hotkeys) |h| h.len else 0;

        var instance: ?*Self = null;

        fn setInstance(p: ?*Self) void {
            instance = p;
        }

        const window_class = "ZiltWindow";

        allocator: std.mem.Allocator,
        hwnd: win32.HWND = null,
        env: ?*wv2.ICoreWebView2Environment = null,
        controller: ?*wv2.ICoreWebView2Controller = null,
        webview: ?*wv2.ICoreWebView2 = null,
        msg_handler: ?*MessageHandler = null,
        res_handler: ?*WebResourceHandler = null,
        nav_handler: ?*NavCompletedHandler = null,
        watcher: ?*Watcher = null,
        tray: ?tray_mod.Tray = null,
        updater_env: ?updater.Env = null,
        updater_url_override: ?[]u8 = null,
        dev_dir: ?[]const u8 = null, // 环境变量覆盖（运行时）
        dev_url: ?[]const u8 = null,
        /// dev 反代模式（Phase C）：应用保持自身 origin，资产请求转发到该上游（如 vite）
        dev_proxy: ?[]const u8 = null,
        proxy_threaded: ?*std.Io.Threaded = null, // 懒建，连接池复用
        proxy_client: ?*std.http.Client = null,
        /// 压缩资产惰性解压缓存（key = asset path；UI 线程独占访问，无需锁）
        asset_cache: std.StringHashMapUnmanaged([]u8) = .empty,
        quit_code: std.atomic.Value(u8) = .init(0),

        fn createWindow(self: *Self) !void {
            const hinstance = win32.GetModuleHandleW(null);

            const class_name_w = try self.allocator.alloc(u16, window_class.len + 1);
            defer self.allocator.free(class_name_w);
            for (window_class, 0..) |c, i| class_name_w[i] = c;
            class_name_w[window_class.len] = 0;

            const title_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, config.title);
            defer self.allocator.free(title_w);

            const wc = win32.WNDCLASSEXW{
                .cbSize = @sizeOf(win32.WNDCLASSEXW),
                .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
                .lpfnWndProc = wndProc,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = hinstance,
                .hIcon = null,
                .hCursor = win32.LoadCursorW(null, @ptrFromInt(win32.IDC_ARROW)),
                .hbrBackground = @ptrFromInt(win32.COLOR_WINDOW + 1),
                .lpszMenuName = null,
                .lpszClassName = @ptrCast(class_name_w.ptr),
                .hIconSm = null,
            };
            if (win32.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

            var rect = win32.RECT{ .left = 0, .top = 0, .right = @intCast(config.width), .bottom = @intCast(config.height) };
            _ = win32.AdjustWindowRect(&rect, win32.WS_OVERLAPPEDWINDOW, 0);

            self.hwnd = win32.CreateWindowExW(
                0,
                @ptrCast(class_name_w.ptr),
                title_w.ptr,
                win32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,
                win32.CW_USEDEFAULT,
                win32.CW_USEDEFAULT,
                rect.right - rect.left,
                rect.bottom - rect.top,
                null,
                null,
                hinstance,
                null,
            ) orelse return error.CreateWindowFailed;

            // 原生菜单栏（comptime 叶子计数供日志）
            if (Self.menu_cfg) |items| {
                const hmenu = menu_mod.buildWin32(self.allocator, items) catch |err| {
                    log.print("[menu] build failed: {s}", .{@errorName(err)});
                    return err;
                };
                if (win32.SetMenu(self.hwnd.?, hmenu) == 0) return error.SetMenuFailed;
                log.print("[menu] built ({} leaf items)", .{Self.menu_leaf_count});
            }
        }

        fn updateBounds(self: *Self) void {
            const controller = self.controller orelse return;
            const hwnd = self.hwnd orelse return;
            var rc: win32.RECT = undefined;
            if (win32.GetClientRect(hwnd, &rc) == 0) return;
            _ = controller.putBounds(.{ .left = 0, .top = 0, .right = rc.right, .bottom = rc.bottom });
        }

        // ---- IPC ----

        /// UI 线程：把事件 JSON 投递给页面，然后释放（所有权在 emit 契约中转移）。
    /// UI 线程便捷事件：序列化 payload 并直接投递（菜单/快捷键/更新流程用）。
        fn emitEventPayload(self: *Self, name: []const u8, payload: anytype) void {
            const payload_json = std.json.Stringify.valueAlloc(self.allocator, payload, .{}) catch return;
            defer self.allocator.free(payload_json);
            const msg = ipc.encodeEvent(self.allocator, name, payload_json) catch return;
            self.emitJsonUi(msg); // 所有权转移
        }

        /// 原生对话框实现（Context.dialog_fn）。仅在 UI 线程调用（模态阻塞）。
        fn runDialog(backend_ptr: *anyopaque, alloc: std.mem.Allocator, req: ipc.DialogRequest) anyerror!ipc.DialogResponse {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const hwnd = self.hwnd orelse return error.DialogNotAvailable;
            switch (req) {
                .message_box => |o| return .{ .button = try dialog_mod.runMessageBox(alloc, hwnd, o) },
                .open_file => |o| return .{ .path = try dialog_mod.runOpenFile(alloc, hwnd, o) },
                .save_file => |o| return .{ .path = try dialog_mod.runSaveFile(alloc, hwnd, o) },
            }
        }

        fn emitJsonUi(self: *Self, msg: []u8) void {
            defer self.allocator.free(msg);
            const webview = self.webview orelse return;
            const wide = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, msg) catch return;
            defer self.allocator.free(wide);
            _ = webview.postWebMessageAsJson(wide.ptr);
        }

        /// 任意线程：emit 的 marshal 入口（ipc.Context.emit_fn）。
        fn emitFromThread(backend_ptr: *anyopaque, message_json: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const hwnd = self.hwnd orelse {
                self.allocator.free(message_json);
                return;
            };
            const ok = win32.PostMessageW(hwnd, WM_ZILT_EMIT, @intCast(message_json.len), @bitCast(@intFromPtr(message_json.ptr)));
            if (ok == 0) self.allocator.free(message_json);
        }

        /// quit（UI 线程的命令/事件回调内调用）。
        fn quitFromBackend(backend_ptr: *anyopaque, code: u8) void {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            self.quit_code.store(code, .monotonic);
            win32.PostQuitMessage(@intCast(code));
        }

        fn makeContext(self: *Self) ipc.Context {
            return .{
                .allocator = self.allocator,
                .msg_allocator = self.allocator,
                .backend = self,
                .emit_fn = emitFromThread,
                .quit_fn = quitFromBackend,
                .notify_fn = notifyFromThread,
                .updater_env = self.updater_env,
            };
        }

        /// UI 线程：WebMessageReceived 分发。
        fn onWebMessage(self: *Self, args: *wv2.ICoreWebView2WebMessageReceivedEventArgs) void {
            // origin 校验：非允许来源的消息一律丢弃
            const src = args.getSource();
            defer if (src.value) |p| wv2.freeCoString(p);
            if (src.value) |p| {
                const src_u8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, std.mem.span(p)) catch return;
                defer self.allocator.free(src_u8);
                const origin = originOf(src_u8);
                if (!self.originAllowed(origin)) {
                    log.print("[ipc] dropped message from disallowed origin: {s}", .{origin});
                    return;
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
            const ctx = self.makeContextWith(arena.allocator());

            var decoded = ipc.decode(self.allocator, raw_u8) catch return;
            defer decoded.deinit();
            switch (decoded.msg) {
                .invoke => |inv| {
                    log.print("[ipc] invoke {s} (id={d})", .{ inv.method, inv.id });
                    const result_json = ipc.dispatch(config.commands, ctx, inv.method, inv.args_json) catch |err| {
                        log.print("[ipc] invoke {s} failed: {s}", .{ inv.method, @errorName(err) });
                        const rej = ipc.encodeReject(self.allocator, inv.id, @errorName(err)) catch return;
                        self.sendJson(rej);
                        return;
                    };
                    // result_json 属于 per-message arena，响应发出后随 arena 释放
                    const resp = ipc.encodeResolve(self.allocator, inv.id, result_json) catch return;
                    self.sendJson(resp);
                },
                .event => |ev| {
                    const handled = ipc.dispatchEvent(config.events, ctx, ev.name, ev.payload_json);
                    if (!handled) log.print("[ipc] event '{s}' (no handler)", .{ev.name});
                },
                .ignore => {},
            }
        }

        fn makeContextWith(self: *Self, allocator: std.mem.Allocator) ipc.Context {
            return .{
                .allocator = allocator,
                .msg_allocator = self.allocator, // 消息可能比 per-message arena 活得久
                .backend = self,
                .emit_fn = emitFromThread,
                .quit_fn = quitFromBackend,
                .notify_fn = notifyFromThread,
                .dialog_fn = runDialog,
                .updater_env = self.updater_env,
            };
        }

        /// 任意线程：系统通知 marshal 入口（Context.notify_fn）。
        fn notifyFromThread(backend_ptr: *anyopaque, title: []const u8, body: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const hwnd = self.hwnd orelse return;
            const packed_msg = packNotify(self.allocator, title, body) orelse return;
            const ok = win32.PostMessageW(hwnd, WM_ZILT_NOTIFY, 0, @bitCast(@intFromPtr(packed_msg.ptr)));
            if (ok == 0) self.allocator.free(packed_msg);
        }

        /// UI 线程：发送 Zig→JS 消息并释放（所有权转移）。
        fn sendJson(self: *Self, msg: []u8) void {
            defer self.allocator.free(msg);
            const webview = self.webview orelse return;
            const wide = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, msg) catch return;
            defer self.allocator.free(wide);
            _ = webview.postWebMessageAsJson(wide.ptr);
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

        // ---- 资产服务 ----

        /// WebResourceRequested：按 dev 模式（反代/磁盘）或 embedded 表服务；
        /// 统一附 ETag（If-None-Match 命中 → 304）；embedded 支持 gzip 预压缩变体。
        fn onWebResource(self: *Self, uri_u8: []const u8, args: *wv2.ICoreWebView2WebResourceRequestedEventArgs) void {
            const env = self.env orelse return;

            // 实测（§G.6）：custom scheme 请求不带 Accept-Encoding（协商无从谈起）；
            // If-None-Match 读取保留（304 通道待用，若未来 WebView2 回传验证器即生效）。
            const if_none_match = requestHeaderUtf8(args, self.allocator, "If-None-Match");
            defer if (if_none_match) |v| self.allocator.free(v);

            var body: ?[]const u8 = null;
            var content_type: []const u8 = "application/octet-stream";
            var status: c_int = 404;
            var from_gz_store = false; // 服务字节来自压缩存储（解压后 identity 下发）
            var etag: ?EtagBytes = null; // 实际下发表示的实体标记
            var owned: ?[]u8 = null; // dev-dir/proxy 内容（需要释放）
            var owned_ct: ?[]u8 = null; // proxy 上游 content-type
            defer if (owned) |o| self.allocator.free(o);
            defer if (owned_ct) |c| self.allocator.free(c);

            const app_origin = originOf(config.url);
            if (std.mem.startsWith(u8, uri_u8, app_origin)) {
                var path = uri_u8[app_origin.len..];
                if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
                if (path.len == 0 or std.mem.eql(u8, path, "/")) path = "/index.html";

                if (self.dev_proxy) |base| {
                    // 反代：保留完整 path（含 query——vite 模块时间戳 HMR 需要）
                    self.serveFromProxy(base, uri_u8[app_origin.len..], path, &body, &content_type, &status, &owned, &owned_ct, &etag);
                } else if (self.dev_dir) |dir| {
                    var ct: []const u8 = undefined;
                    if (self.serveFromDir(dir, path, &owned, &ct)) {
                        body = owned.?;
                        content_type = ct;
                        status = 200;
                        etag = etagOf(body.?);
                    }
                } else {
                    for (config.assets) |asset| {
                        if (std.mem.eql(u8, asset.path, path)) {
                            switch (asset.encoding) {
                                .identity => body = asset.content,
                                .gzip => {
                                    // Tauri brotli 同款：存储压缩、服务 identity（惰性解压 + 进程内缓存）。
                                    // 实测（§G.6/G.7）：custom scheme 响应不走网络栈内容解码，
                                    // 压缩字节不能直接下发（模块 MIME 校验必炸）。
                                    if (self.assetDecompress(path, asset.content)) |raw| {
                                        body = raw;
                                        from_gz_store = true;
                                    } else {
                                        log.print("[assets] gzip decompress failed: {s}", .{path});
                                        continue;
                                    }
                                },
                            }
                            etag = etagOf(body.?);
                            content_type = contentTypeOf(path);
                            status = 200;
                            break;
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
            }

            if (status == 200) {
                log.print("[assets] 200 {s} {d} bytes{s} <- {s}", .{ content_type, body.?.len, if (from_gz_store) " (gz-store)" else "", uri_u8 });
            } else if (status != 304) {
                log.print("[assets] {d} <- {s}", .{ status, uri_u8 });
                if (status != 502) content_type = "text/plain";
                body = if (status == 502) "zilt dev proxy: upstream unreachable (dev only)" else "";
            }

            const reason: []const u8 = switch (status) {
                200 => "OK",
                304 => "Not Modified",
                502 => "Bad Gateway",
                else => "Not Found",
            };
            const reason_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, reason) catch return;
            defer self.allocator.free(reason_w);

            // 实测（docs/reference §G.7）：custom scheme 响应头对模块脚本走严格 MIME
            // 校验——服务字节恒为 identity（压缩存储在解压缓存层消化），
            // 200 只发 Content-Type；ETag 仅出现在 304（规格必带；当前通道
            // 不回传 If-None-Match，304 逻辑保留待用）。
            const headers = blk: {
                if (status == 304) {
                    break :blk std.fmt.allocPrint(self.allocator, "Content-Type: {s}\r\nETag: {s}", .{ content_type, etag.? }) catch return;
                }
                break :blk std.fmt.allocPrint(self.allocator, "Content-Type: {s}", .{content_type}) catch return;
            };
            defer self.allocator.free(headers);
            const headers_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, headers) catch return;
            defer self.allocator.free(headers_w);

            const stream = streamFromBytes(body.?) orelse return;
            const r = env.createWebResourceResponse(stream, status, reason_w.ptr, headers_w.ptr);
            if (com.succeeded(r.hr) and r.response != null) {
                _ = args.putResponse(r.response.?);
            } else {
                log.print("[assets] createWebResourceResponse failed hr=0x{x}", .{@as(u32, @bitCast(r.hr))});
            }
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

        /// dev 反代（Phase C，Wails build_dev.go 对应物）：应用 origin 的请求转发上游。
        /// UI 线程同步拉取——仅 dev 模式（vite 本地响应快）；生产路径不走此处。
        fn serveFromProxy(
            self: *Self,
            base: []const u8,
            path_full: []const u8, // 含 query（vite HMR 时间戳）
            path: []const u8, // 仅路径（ct 猜测/日志）
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

        /// 上游 HTTP GET（带一次重试：vite 等 dev server 会关闭空闲 keep-alive
        /// 连接——复用死连接表现为 ReadFailed，此时重建连接池再试）。
        fn proxyFetch(self: *Self, alloc: std.mem.Allocator, url: []const u8, out_ct: *?[]u8) ![]u8 {
            return self.proxyFetchInner(alloc, url, out_ct) catch |err| {
                log.print("[proxy] retry once after {s}", .{@errorName(err)});
                if (out_ct.*) |c| self.allocator.free(c);
                out_ct.* = null;
                self.proxyClientReset();
                return self.proxyFetchInner(alloc, url, out_ct);
            };
        }

        /// 丢弃并释放反代 client（连接池随之关闭，下次请求懒建重建）。
        fn proxyClientReset(self: *Self) void {
            if (self.proxy_client) |c| {
                c.deinit();
                self.allocator.destroy(c);
                self.proxy_client = null;
            }
        }

        /// 上游 HTTP GET（std.http.Client，镜像 fetch() 的读取模式以获取 Content-Type）。
        /// 返回 body（调用方释放）；ct 拷贝写入 out_ct（调用方释放，可能为 null）。
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

            // head.content_type 指向 redirect_buffer —— 立即拷贝
            out_ct.* = if (response.head.content_type) |ct|
                (self.allocator.dupe(u8, ct) catch null)
            else
                null;

            // 上游若已压缩则解压（下游按 identity 下发，不透传 Content-Encoding）
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
            // 路径安全：拒绝目录穿越
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

        fn cleanup(self: *Self) void {
            _ = win32.KillTimer(self.hwnd orelse return, 1);
            if (Self.hotkey_cfg) |hks| {
                if (self.hwnd) |h| hotkey_mod.unregisterAll(h, hks);
            }
            if (self.tray) |*t| _ = t.remove();
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
            if (self.webview) |wv| _ = wv.lpVtbl.Release(wv);
            if (self.msg_handler) |h| h.dropRef();
            if (self.res_handler) |h| h.dropRef();
            if (self.nav_handler) |h| h.dropRef();
            if (self.controller) |c| {
                _ = c.lpVtbl.Close(c);
                _ = c.lpVtbl.Release(c);
            }
            if (self.env) |e| _ = e.lpVtbl.Release(e);
            self.webview = null;
            self.msg_handler = null;
            self.res_handler = null;
            self.nav_handler = null;
            self.controller = null;
            self.env = null;
        }

        // ---- 消息循环 ----

        fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.c) win32.LRESULT {
            switch (msg) {
                win32.WM_SIZE => {
                    if (instance) |b| b.updateBounds();
                    return 0;
                },
                win32.WM_CLOSE => {
                    // close_to_tray：点关闭 = 隐藏到托盘
                    if (instance) |b| {
                        if (config.close_to_tray and b.tray != null and b.tray.?.active) {
                            _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
                            log.print("[tray] window hidden to tray", .{});
                            return 0;
                        }
                    }
                },
                win32.WM_DESTROY => {
                    log.print("[win32] WM_DESTROY", .{});
                    win32.PostQuitMessage(0);
                    return 0;
                },
                win32.WM_TIMER => {
                    log.print("[test] smoke timer fired (no quit) -> exit(124)", .{});
                    if (instance) |b| b.quit_code.store(124, .monotonic);
                    win32.PostQuitMessage(124);
                    return 0;
                },
                win32.WM_COMMAND => {
                    // 菜单点击：LOWORD(wparam) = win 菜单 id → 字符串 id 事件
                    if (instance) |b| {
                        const mid: u16 = @intCast(wparam & 0xffff);
                        if (Self.menu_cfg != null) {
                            const items = Self.menu_cfg.?;
                            if (menu_mod.idFromIndex(items, mid)) |id| {
                                log.print("[menu] {s}", .{id});
                                b.emitEventPayload("menu", .{ .id = id });
                            }
                        }
                    }
                    return 0;
                },
                win32.WM_HOTKEY => {
                    // 全局快捷键触发：wparam = 配置顺序
                    if (instance) |b| {
                        if (Self.hotkey_cfg != null) {
                            const hks = Self.hotkey_cfg.?;
                            if (hotkey_mod.idFromIndex(hks, @intCast(wparam))) |id| {
                                log.print("[hotkey] {s}", .{id});
                                b.emitEventPayload("hotkey", .{ .id = id });
                            }
                        }
                    }
                    return 0;
                },
                WM_ZILT_EMIT => {
                    // 任意线程 emit → UI 线程投递（所有权随消息转移）
                    if (instance) |b| {
                        const len: usize = @intCast(wparam);
                        const ptr: [*]u8 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                        b.emitJsonUi(ptr[0..len]);
                    }
                    return 0;
                },
                WM_ZILT_NOTIFY => {
                    // 任意线程 notify → UI 线程投递托盘通知（所有权随消息转移）
                    if (instance) |b| {
                        const ptr: [*]u8 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                        const nb = unpackNotify(ptr);
                        defer b.allocator.free(ptr[0 .. 8 + nb.title.len + nb.body.len]);
                        if (b.tray) |*t| {
                            const ok = t.notify(nb.title, nb.body);
                            log.print("[notify] sent (ok={})", .{ok});
                        } else {
                            log.print("[notify] dropped (tray not enabled)", .{});
                        }
                    }
                    return 0;
                },
                WM_ZILT_TRAY => {
                    // 托盘图标鼠标事件：左键点击 = 显示/隐藏窗口
                    if (instance != null) {
                        if (lparam == win32.WM_LBUTTONUP) {
                            const visible = win32.IsWindowVisible(hwnd) != 0;
                            _ = win32.ShowWindow(hwnd, if (visible) win32.SW_HIDE else win32.SW_SHOW);
                            if (!visible) _ = win32.SetForegroundWindow(hwnd);
                            log.print("[tray] click -> {s}", .{if (visible) "hidden" else "shown"});
                        }
                    }
                    return 0;
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
        /// 注意：result 不可 CoTaskMemFree（见 docs/reference §G.2）。
        fn IgnoreCompletedHandler(comptime iid: com.GUID) type {
            return extern struct {
                const H = @This();
                lpVtbl: *const VTable,
                refs: u32,
                backend: *Self,

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

                fn create(backend: *Self) !*H {
                    const h = try backend.allocator.create(H);
                    h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend };
                    return h;
                }
                pub fn comDestroy(self: *H) void {
                    self.backend.allocator.destroy(self);
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

        /// ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
        const EnvCompletedHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            backend: *Self,

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

            fn create(backend: *Self) !*EnvCompletedHandler {
                const h = try backend.allocator.create(EnvCompletedHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend };
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

                const ctrl_handler = ControllerCompletedHandler.create(backend) catch {
                    win32.PostQuitMessage(3);
                    return com.E_FAIL;
                };
                const hr = env.?.createController(backend.hwnd.?, ctrl_handler);
                ctrl_handler.dropRef();
                if (com.failed(hr)) {
                    log.print("[fatal] CreateCoreWebView2Controller failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
                    win32.PostQuitMessage(3);
                }
                return com.S_OK;
            }
        };

        /// ICoreWebView2CreateCoreWebView2ControllerCompletedHandler
        const ControllerCompletedHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            backend: *Self,

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

            fn create(backend: *Self) !*ControllerCompletedHandler {
                const h = try backend.allocator.create(ControllerCompletedHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend };
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
                const backend = self.backend;
                if (com.failed(error_code) or controller == null) {
                    log.print("[fatal] Controller create failed hr=0x{x}", .{@as(u32, @bitCast(error_code))});
                    win32.PostQuitMessage(4);
                    return com.S_OK;
                }
                backend.controller = controller;
                _ = controller.?.lpVtbl.AddRef(controller.?);
                log.print("[webview] controller created", .{});

                _ = controller.?.putIsVisible(1);
                backend.updateBounds();

                const wv_result = controller.?.getCoreWebView2();
                if (com.failed(wv_result.hr) or wv_result.webview == null) {
                    log.print("[fatal] get_CoreWebView2 failed hr=0x{x}", .{@as(u32, @bitCast(wv_result.hr))});
                    win32.PostQuitMessage(5);
                    return com.S_OK;
                }
                const webview = wv_result.webview.?;
                backend.webview = webview;
                log.print("[webview] core webview attached", .{});

                // IPC sink
                backend.msg_handler = MessageHandler.create(backend) catch null;
                if (backend.msg_handler) |mh| {
                    var token: com.EventRegistrationToken = .{ .value = 0 };
                    const hr1 = webview.addWebMessageReceived(mh, &token);
                    log.print("[webview] add_WebMessageReceived hr=0x{x}", .{@as(u32, @bitCast(hr1))});
                }

                // 资产服务（dev-url 模式无需 custom scheme 拦截）
                if (backend.dev_url == null) {
                    backend.res_handler = WebResourceHandler.create(backend) catch null;
                    if (backend.res_handler) |rh| {
                        var token2: com.EventRegistrationToken = .{ .value = 0 };
                        const hr2 = webview.addWebResourceRequested(rh, &token2);
                        log.print("[webview] add_WebResourceRequested hr=0x{x}", .{@as(u32, @bitCast(hr2))});

                        const filter = std.fmt.allocPrint(backend.allocator, "{s}/*", .{originOf(config.url)}) catch return com.E_FAIL;
                        defer backend.allocator.free(filter);
                        const filter_w = std.unicode.utf8ToUtf16LeAllocZ(backend.allocator, filter) catch return com.E_FAIL;
                        defer backend.allocator.free(filter_w);
                        const hr3 = webview.addWebResourceRequestedFilter(filter_w.ptr, wv2.WEB_RESOURCE_CONTEXT_ALL);
                        log.print("[webview] AddWebResourceRequestedFilter({s}) hr=0x{x}", .{ filter, @as(u32, @bitCast(hr3)) });
                    }
                }

                // 导航完成诊断
                backend.nav_handler = NavCompletedHandler.create(backend) catch null;
                if (backend.nav_handler) |nh| {
                    var token3: com.EventRegistrationToken = .{ .value = 0 };
                    const hr3c = webview.addNavigationCompleted(nh, &token3);
                    log.print("[webview] add_NavigationCompleted hr=0x{x}", .{@as(u32, @bitCast(hr3c))});
                }

                // 注入 zilt 运行时（window.zilt：invoke/emit/on + __reload）
                const script_handler = IgnoreCompletedHandler(wv2.IID_AddScriptToExecuteOnDocumentCreatedCompletedHandler).create(backend) catch null;
                if (script_handler) |sh| {
                    const js_w = std.unicode.utf8ToUtf16LeAllocZ(backend.allocator, ipc.runtime_js) catch return com.E_FAIL;
                    defer backend.allocator.free(js_w);
                    const hr_js = webview.addScriptToExecuteOnDocumentCreated(js_w.ptr, sh);
                    sh.dropRef();
                    log.print("[webview] inject runtime js hr=0x{x}", .{@as(u32, @bitCast(hr_js))});
                }

                // 导航
                const nav_url = backend.dev_url orelse config.url;
                const url_w = std.unicode.utf8ToUtf16LeAllocZ(backend.allocator, nav_url) catch return com.E_FAIL;
                defer backend.allocator.free(url_w);
                const hr4 = webview.navigate(url_w.ptr);
                log.print("[webview] navigate {s} hr=0x{x}", .{ nav_url, @as(u32, @bitCast(hr4)) });

                // 系统托盘
                if (config.tray) |tc| {
                    backend.tray = tray_mod.Tray.init(backend.allocator, backend.hwnd, WM_ZILT_TRAY, tc.tooltip) catch null;
                    if (backend.tray) |*t| {
                        const ok = t.add();
                        log.print("[tray] added (ok={})", .{ok});
                    }
                }

                // dev-dir 热重载 watcher
                if (backend.dev_dir) |dir| {
                    backend.watcher = Watcher.start(backend.allocator, backend.makeContext(), dir);
                }

                // 自动更新检查（后台线程；ZILT_UPDATE_AUTO=1 触发，供 E2E）
                if (backend.updater_env != null) {
                    if (win32.getEnvUtf8(backend.allocator, "ZILT_UPDATE_URL")) |u| {
                        defer backend.allocator.free(u);
                        if (backend.allocator.dupe(u8, u)) |dup| {
                            backend.updater_env.?.manifest_url = dup;
                        } else |_| {}
                    }
                    if (win32.getEnvUtf8(backend.allocator, "ZILT_UPDATE_AUTO")) |a| {
                        defer backend.allocator.free(a);
                        if (a.len > 0 and a[0] == '1') {
                            if (std.Thread.spawn(.{ .stack_size = 512 * 1024 }, updaterFlow, .{backend})) |t| {
                                t.detach();
                                log.print("[updater] auto check started", .{});
                            } else |_| {}
                        }
                    }
                }

                return com.S_OK;
            }
        };

        /// ICoreWebView2WebMessageReceivedEventHandler
        const MessageHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            backend: *Self,

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

            fn create(backend: *Self) !*MessageHandler {
                const h = try backend.allocator.create(MessageHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend };
                return h;
            }
            pub fn comDestroy(self: *MessageHandler) void {
                self.backend.allocator.destroy(self);
            }
            pub fn dropRef(self: *MessageHandler) void {
                _ = com.ComVTableMixin(MessageHandler).release(@ptrCast(self));
            }

            fn invoke(self_: *anyopaque, sender: ?*wv2.ICoreWebView2, args: ?*wv2.ICoreWebView2WebMessageReceivedEventArgs) callconv(.c) HRESULT {
                _ = sender;
                const self: *MessageHandler = @ptrCast(@alignCast(self_));
                const a = args orelse return com.E_POINTER;
                self.backend.onWebMessage(a);
                return com.S_OK;
            }
        };

        /// ICoreWebView2WebResourceRequestedEventHandler
        const WebResourceHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            backend: *Self,

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

            fn create(backend: *Self) !*WebResourceHandler {
                const h = try backend.allocator.create(WebResourceHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend };
                return h;
            }
            pub fn comDestroy(self: *WebResourceHandler) void {
                self.backend.allocator.destroy(self);
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

                const uri_u8 = std.unicode.utf16LeToUtf8Alloc(self.backend.allocator, std.mem.span(uri_result.value.?)) catch return com.E_FAIL;
                defer self.backend.allocator.free(uri_u8);

                self.backend.onWebResource(uri_u8, a);
                return com.S_OK;
            }
        };

        /// ICoreWebView2NavigationCompletedEventHandler
        const NavCompletedHandler = extern struct {
            lpVtbl: *const VTable,
            refs: u32,
            backend: *Self,

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

            fn create(backend: *Self) !*NavCompletedHandler {
                const h = try backend.allocator.create(NavCompletedHandler);
                h.* = .{ .lpVtbl = &vtable, .refs = 1, .backend = backend };
                return h;
            }
            pub fn comDestroy(self: *NavCompletedHandler) void {
                self.backend.allocator.destroy(self);
            }
            pub fn dropRef(self: *NavCompletedHandler) void {
                _ = com.ComVTableMixin(NavCompletedHandler).release(@ptrCast(self));
            }

            fn invoke(self_: *anyopaque, sender: ?*wv2.ICoreWebView2, args: ?*wv2.ICoreWebView2NavigationCompletedEventArgs) callconv(.c) HRESULT {
                _ = self_;
                _ = sender;
                const a = args orelse return com.E_POINTER;
                const success = a.getIsSuccess();
                if (com.failed(success.hr)) return com.E_FAIL;
                if (success.value != 0) {
                    log.print("[webview] navigation completed: SUCCESS", .{});
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

    const artifact = updater.downloadAndVerify(self.allocator, env.fetcher, m, env.public_key) catch |err| {
        log.print("[updater] download/verify failed: {s}", .{@errorName(err)});
        ctx.emit("updaterFailed", .{ .stage = "download", .err = @errorName(err) });
        return;
    };
    defer self.allocator.free(artifact);
    log.print("[updater] artifact verified ({d} bytes, sha256+ed25519)", .{artifact.len});

    updater.stageUpdate(self.allocator, env.exe_path, env.exe_name, artifact) catch |err| {
        log.print("[updater] stage failed: {s}", .{@errorName(err)});
        ctx.emit("updaterFailed", .{ .stage = "stage", .err = @errorName(err) });
        return;
    };
    log.print("[updater] staged ✓ {s} — restart to apply", .{m.version});
    ctx.emit("updateStaged", .{ .version = m.version });
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
    try testing.expect(acceptsGzip("gzip, deflate, br, zstd")); // WebView2/Chromium 默认
    try testing.expect(acceptsGzip("deflate, gzip"));
    try testing.expect(acceptsGzip("GZIP")); // 大小写不敏感
    try testing.expect(acceptsGzip("gzip;q=0.5, br"));
    try testing.expect(acceptsGzip("br;q=1.0, gzip"));
    try testing.expect(!acceptsGzip("deflate")); // 不含 gzip
    try testing.expect(!acceptsGzip("br, zstd"));
    try testing.expect(!acceptsGzip("gzip;q=0")); // 显式拒绝
    try testing.expect(!acceptsGzip("gzip;q=0.000, br;q=1.0"));
    try testing.expect(!acceptsGzip("GZIP ; Q=0")); // 大小写 + 空格
}

test "etagOf: 强 ETag（定长/引号/确定性/区分度）" {
    const e1 = etagOf("hello");
    const e2 = etagOf("hello");
    const e3 = etagOf("hello!");
    try testing.expectEqual(@as(usize, 18), e1.len);
    try testing.expectEqual(@as(u8, '"'), e1[0]);
    try testing.expectEqual(@as(u8, '"'), e1[17]);
    try testing.expectEqualSlices(u8, &e1, &e2); // 同内容同值
    try testing.expect(!std.mem.eql(u8, &e1, &e3)); // 异内容异值
    for (e1[1..17]) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "ifNoneMatchMatches: 列表 / * / W/ 前缀 / 非匹配" {
    const e = etagOf("hello"); // "xxxxxxxxxxxxxxxx"
    try testing.expect(!ifNoneMatchMatches(null, &e));
    try testing.expect(!ifNoneMatchMatches("", &e));
    try testing.expect(ifNoneMatchMatches(&e, &e)); // 精确
    try testing.expect(ifNoneMatchMatches(" \"zzzz\",  W/\"aaaa\" , W/", &e) == false); // 半个 token 不误判
    try testing.expect(ifNoneMatchMatches("*", &e)); // 星号
    try testing.expect(ifNoneMatchMatches("\"aaaa\", \"bbbb\", ", &e) == false);
    const list = try std.fmt.allocPrint(testing.allocator, "\"aaaa\", {s}, \"cccc\"", .{&e});
    defer testing.allocator.free(list);
    try testing.expect(ifNoneMatchMatches(list, &e)); // 列表内命中
    const weak = try std.fmt.allocPrint(testing.allocator, "W/{s}", .{&e});
    defer testing.allocator.free(weak);
    try testing.expect(ifNoneMatchMatches(weak, &e)); // W/ 弱前缀剥离后可比
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
