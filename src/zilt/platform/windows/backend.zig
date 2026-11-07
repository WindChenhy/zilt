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
const Config = @import("../../config.zig").Config;
const com = @import("com.zig");
const win32 = @import("win32.zig");
const wv2 = @import("webview2.zig");
const loader = @import("loader.zig");

const HRESULT = com.HRESULT;
const WM_ZILT_EMIT: win32.UINT = win32.WM_APP + 1;
const SMOKE_ENV = "ZILT_SMOKE_TEST_MS";

pub fn run(comptime config: Config) !void {
    const B = Backend(config);
    log.initFileLog("zilt.log");
    const alloc = std.heap.page_allocator;

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

    // dev 模式环境变量覆盖（无需重新编译）
    if (win32.getEnvUtf8(alloc, "ZILT_DEV_DIR")) |d| {
        backend.dev_dir = d;
        log.print("[dev] ZILT_DEV_DIR={s}", .{d});
    }
    if (win32.getEnvUtf8(alloc, "ZILT_DEV_URL")) |u| {
        backend.dev_url = u;
        log.print("[dev] ZILT_DEV_URL={s}", .{u});
    }

    try backend.createWindow();
    _ = win32.ShowWindow(backend.hwnd.?, win32.SW_SHOW);
    _ = win32.UpdateWindow(backend.hwnd.?);
    log.print("[win32] window created: \"{s}\" {d}x{d}", .{ config.title, config.width, config.height });

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
// Backend（按 Config 编译期实例化）
// ---------------------------------------------------------------------------

fn Backend(comptime config: Config) type {
    return struct {
        const Self = @This();

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
        dev_dir: ?[]const u8 = null, // 环境变量覆盖（运行时）
        dev_url: ?[]const u8 = null,
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
            };
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

        /// WebResourceRequested：按 dev 模式（磁盘/devUrl）或 embedded 表服务。
        fn onWebResource(self: *Self, uri_u8: []const u8, args: *wv2.ICoreWebView2WebResourceRequestedEventArgs) void {
            const env = self.env orelse return;

            var body: ?[]const u8 = null;
            var content_type: []const u8 = "application/octet-stream";
            var status: c_int = 404;
            var owned: ?[]u8 = null; // dev 模式读盘内容（需要释放）
            defer if (owned) |o| self.allocator.free(o);

            const app_origin = originOf(config.url);
            if (std.mem.startsWith(u8, uri_u8, app_origin)) {
                var path = uri_u8[app_origin.len..];
                if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
                if (std.mem.eql(u8, path, "") or std.mem.eql(u8, path, "/")) path = "/index.html";

                if (self.dev_dir) |dir| {
                    var ct: []const u8 = undefined;
                    if (self.serveFromDir(dir, path, &owned, &ct)) {
                        body = owned.?;
                        content_type = ct;
                        status = 200;
                    }
                } else {
                    for (config.assets) |asset| {
                        if (std.mem.eql(u8, asset.path, path)) {
                            body = asset.content;
                            content_type = contentTypeOf(path);
                            status = 200;
                            break;
                        }
                    }
                }
            }

            if (status == 200) {
                log.print("[assets] 200 {s} {d} bytes <- {s}", .{ content_type, body.?.len, uri_u8 });
            } else {
                log.print("[assets] 404 <- {s}", .{uri_u8});
                content_type = "text/plain";
                body = "";
            }

            const reason_w: [:0]u16 = if (status == 200)
                std.unicode.utf8ToUtf16LeAllocZ(self.allocator, "OK") catch return
            else
                std.unicode.utf8ToUtf16LeAllocZ(self.allocator, "Not Found") catch return;
            defer self.allocator.free(reason_w);

            const headers = std.fmt.allocPrint(self.allocator, "Content-Type: {s}", .{content_type}) catch return;
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
                WM_ZILT_EMIT => {
                    // 任意线程 emit → UI 线程投递（所有权随消息转移）
                    if (instance) |b| {
                        const len: usize = @intCast(wparam);
                        const ptr: [*]u8 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                        b.emitJsonUi(ptr[0..len]);
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

                // dev-dir 热重载 watcher
                if (backend.dev_dir) |dir| {
                    backend.watcher = Watcher.start(backend.allocator, backend.makeContext(), dir);
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
