//! macOS 后端（v0.4.4）：NSApplication + NSWindow + WKWebView + 资产 scheme + IPC。
//!
//! 传输约定与 Linux 一致：页面侧 `window.webkit.messageHandlers.zilt.postMessage`
//! 上来，Zig 侧用 `window.__ziltDeliver({...})` 下发（`ipc.runtime_js` 原样注入）。
//!
//! 无 Mac 硬件的开发闭环：`zig build -Dtarget=aarch64-macos` 用 `stubs/*.tbd`
//! 完成编译+链接；运行/截图由 CI `macos-15` 承担（见 `.github/workflows/macos.yml`）。
//!
//! 阶段限制（v0.4.4）：单窗口；菜单/托盘/通知/多窗口按 v0.4.5+ 推进。命令与事件
//! 直接走 `ipc.dispatch`（暂无 isolation/ACL——macOS 的安全面随 v0.4.6 补）。
const std = @import("std");
const log = @import("../../log.zig");
const ipc = @import("../../ipc.zig");
const asset_routes = @import("../../asset_routes.zig");
const inflate = @import("../../inflate.zig");
const builtin_cmds = @import("../../builtin.zig");
const Config = @import("../../config.zig").Config;
const objc = @import("objc.zig");

const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;

pub const platform_name = "macos";

/// 自有 scheme（与 Linux 同名同 host，前端资产 URL 跨平台一致）。
const scheme = "zilt";
const scheme_host = "app";

/// 冒烟探针：页面加载完成后注入，验证 runtime 注入 + JS→Zig 传输。
const probe_js =
    \\(async () => {
    \\  let greet = null, err = null;
    \\  try { greet = await window.zilt.invoke("greet", { name: "macos" }); }
    \\  catch (e) { err = String(e); }
    \\  window.webkit.messageHandlers.zilt.postMessage({zilt:1,kind:"event",
    \\    name:"__zilt.macosProbe",
    \\    payload:{hasZilt: typeof window.zilt !== "undefined", greet: greet && greet.message || null,
    \\             err: err, title: document.title, href: location.href}});
    \\})();
;

pub fn run(comptime config: Config) !void {
    const App = Backend(config);
    return App.main();
}

fn Backend(comptime config: Config) type {
    return struct {
        const Self = @This();

        /// 进程内单实例（v0.4.4 单窗口；多窗口改为 map<window_id, 窗口对象>）。
        var inst: Self = .{};

        alloc: std.mem.Allocator = std.heap.c_allocator,
        app: Id = undefined,
        window: Id = undefined,
        webview: Id = undefined,
        page_loaded: bool = false,
        probe_sent: bool = false,
        ipc_seen: bool = false,
        ipc_ok: bool = false,
        smoke_ms: u32 = 0,
        /// v0.4.5：窗口控制探针结果（CI 硬断言）
        win_ops_ok: bool = false,
        assets: std.StringHashMapUnmanaged([]u8) = .empty,
        /// 跨线程 emit 队列（worker → 主线程 drain；WebKit 只允许主线程 eval）
        out_mutex: std.atomic.Mutex = .unlocked,
        out_queue: std.ArrayListUnmanaged([]u8) = .empty,

        fn main() !void {
            inst.smoke_ms = parseSmokeMs(env("ZILT_SMOKE_TEST_MS"));
            log.initFileLog("zilt.log");
            log.print("[macos] platform=macos smoke_ms={d}", .{inst.smoke_ms});

            inst.app = msg0(Id, objc.cls("NSApplication"), "sharedApplication");
            // NSApplicationActivationPolicyRegular = 0：无 .app bundle 也能进 Dock/前台
            _ = msg1(bool, inst.app, "setActivationPolicy:", @as(c_long, 0));
            // 冒烟模式手动泵事件、不走 [NSApp run]，必须显式 finishLaunching
            //（否则窗口不参与显示、截图空白）；正常模式交给 run 自己完成。
            if (inst.smoke_ms != 0) msg0(void, inst.app, "finishLaunching");
            log.print("[macos] NSApplication ready (policy=regular)", .{});

            registerClasses();
            try inst.createWindow();
            try inst.createWebView();

            if (inst.smoke_ms == 0) {
                // 正常应用：交给 NSApp runloop（阻塞至退出）
                msg0(void, inst.app, "run");
                return;
            }
            try inst.smokeLoop();
        }

        // ------------------------------------------------------------------
        // 窗口 / WebView
        // ------------------------------------------------------------------
        const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };

        fn createWindow(self: *Self) !void {
            const raw = msg0(Id, objc.cls("NSWindow"), "alloc");
            // styleMask: titled(1)|closable(2)|miniaturizable(4)|resizable(8)
            var mask: c_ulong = 1 | 2 | 4;
            if (config.resizable) mask |= 8;
            const win = objc.msgSend(*const fn (Id, Sel, Rect, c_ulong, c_ulong, bool) callconv(.c) Id)(
                raw,
                objc.sel("initWithContentRect:styleMask:backing:defer:"),
                .{
                    .x = 240,
                    .y = 240,
                    .w = @floatFromInt(config.width),
                    .h = @floatFromInt(config.height),
                },
                mask,
                2, // NSBackingStoreBuffered
                false,
            );
            if (@intFromPtr(win) == 0) return error.WindowCreationFailed;
            self.window = win;

            _ = msg1(void, win, "setTitle:", objc.nsStringZ(config.title.ptr));
            _ = msg1(void, win, "setReleasedWhenClosed:", false);
            _ = msg1(void, win, "setDelegate:", msg0(Id, objc.cls("ZiltWindowDelegate"), "new"));
            _ = msg1(void, win, "makeKeyAndOrderFront:", @as(?Id, null));
            _ = msg1(void, self.app, "activateIgnoringOtherApps:", true);
            log.print("[macos] window created {d}x{d}", .{ config.width, config.height });
        }

        fn createWebView(self: *Self) !void {
            const cfg = objc.allocInit(objc.cls("WKWebViewConfiguration"));
            const ucc = objc.allocInit(objc.cls("WKUserContentController"));

            // JS→Zig：window.webkit.messageHandlers.zilt
            _ = objc.msgSend(*const fn (Id, Sel, Id, Id) callconv(.c) void)(
                ucc,
                objc.sel("addScriptMessageHandler:name:"),
                msg0(Id, objc.cls("ZiltMessageHandler"), "new"),
                objc.nsStringZ("zilt"),
            );
            // 注入 window.zilt 运行时（document start）
            const us_raw = msg0(Id, objc.cls("WKUserScript"), "alloc");
            const us = objc.msgSend(*const fn (Id, Sel, Id, c_ulong, bool) callconv(.c) Id)(
                us_raw,
                objc.sel("initWithSource:injectionTime:forMainFrameOnly:"),
                objc.nsString(ipc.runtime_js.ptr, ipc.runtime_js.len),
                0, // WKUserScriptInjectionTimeAtDocumentStart
                false,
            );
            _ = msg1(void, ucc, "addUserScript:", us);
            _ = msg1(void, cfg, "setUserContentController:", ucc);

            // 资产：zilt://app/...
            _ = objc.msgSend(*const fn (Id, Sel, Id, Id) callconv(.c) void)(
                cfg,
                objc.sel("setURLSchemeHandler:forURLScheme:"),
                msg0(Id, objc.cls("ZiltSchemeHandler"), "new"),
                objc.nsStringZ(scheme),
            );

            const wv_raw = msg0(Id, objc.cls("WKWebView"), "alloc");
            const wv = objc.msgSend(*const fn (Id, Sel, Rect, Id) callconv(.c) Id)(
                wv_raw,
                objc.sel("initWithFrame:configuration:"),
                .{
                    .x = 0,
                    .y = 0,
                    .w = @floatFromInt(config.width),
                    .h = @floatFromInt(config.height),
                },
                cfg,
            );
            if (@intFromPtr(wv) == 0) return error.WebViewCreationFailed;
            self.webview = wv;
            _ = msg1(void, wv, "setNavigationDelegate:", msg0(Id, objc.cls("ZiltNavigationDelegate"), "new"));
            _ = msg1(void, self.window, "setContentView:", wv);
            log.print("[macos] webview created", .{});

            const entry = try self.entryUrl();
            defer self.alloc.free(entry);
            const nsurl = msg1(Id, objc.cls("NSURL"), "URLWithString:", objc.nsString(entry.ptr, entry.len));
            const req = msg1(Id, objc.cls("NSURLRequest"), "requestWithURL:", nsurl);
            _ = msg1(void, wv, "loadRequest:", req);
            log.print("[macos] loading {s}", .{entry});
        }

        /// 入口 URL：默认 `https://zilt.app/...` 映射到自有 scheme；其它 http(s)
        /// （开发服务器）原样加载。
        fn entryUrl(self: *Self) ![]u8 {
            return asset_routes.resolveEntryUrl(self.alloc, config.url, scheme, scheme_host, "zilt.app");
        }

        // ------------------------------------------------------------------
        // 资产服务（WKURLSchemeHandler）
        // ------------------------------------------------------------------
        fn serveTask(self: *Self, task: Id) void {
            const req = msg0(Id, task, "request");
            const url = msg0(Id, req, "URL");
            const abs = msg0(Id, url, "absoluteString");
            const cstr = objc.msgSend(*const fn (Id, Sel) callconv(.c) [*:0]const u8)(abs, objc.sel("UTF8String"));
            const raw_url = std.mem.span(cstr);
            const raw_path = asset_routes.pathFromCustomScheme(raw_url, scheme) orelse "/index.html";
            const path = asset_routes.decodePath(self.alloc, raw_path) catch {
                self.respond(task, url, "text/plain; charset=utf-8", "bad request path");
                return;
            };
            defer self.alloc.free(path);

            if (self.findAsset(path)) |body| {
                log.print("[assets] {s} -> 200 ({s}) {d} bytes", .{
                    path, asset_routes.contentTypeOf(path), body.len,
                });
                self.respond(task, url, asset_routes.contentTypeOf(path), body);
            } else {
                log.print("[assets] {s} -> 404", .{path});
                self.respond(task, url, "text/plain; charset=utf-8", "not found");
            }
        }

        fn findAsset(self: *Self, path: []const u8) ?[]const u8 {
            var cands = asset_routes.Candidates.init(self.alloc, path, true) catch return null;
            defer cands.deinit();
            for (cands.paths) |maybe| {
                const route = maybe orelse continue;
                for (config.assets) |asset| {
                    if (!std.mem.eql(u8, asset.path, route)) continue;
                    return switch (asset.encoding) {
                        .identity => asset.content,
                        .gzip => self.decompress(route, asset.content) orelse continue,
                    };
                }
            }
            return null;
        }

        fn decompress(self: *Self, path: []const u8, gz: []const u8) ?[]const u8 {
            if (self.assets.get(path)) |raw| return raw;
            const raw = inflate.gunzip(self.alloc, gz) catch return null;
            const key = self.alloc.dupe(u8, path) catch {
                self.alloc.free(raw);
                return null;
            };
            self.assets.put(self.alloc, key, raw) catch {
                self.alloc.free(key);
                self.alloc.free(raw);
                return null;
            };
            return raw;
        }

        fn respond(self: *Self, task: Id, url: Id, content_type: []const u8, body: []const u8) void {
            _ = self;
            const resp_raw = msg0(Id, objc.cls("NSURLResponse"), "alloc");
            const resp = objc.msgSend(*const fn (Id, Sel, Id, Id, c_long, ?Id) callconv(.c) Id)(
                resp_raw,
                objc.sel("initWithURL:MIMEType:expectedContentLength:textEncodingName:"),
                url,
                objc.nsString(content_type.ptr, content_type.len),
                @as(c_long, @intCast(body.len)),
                @as(?Id, null),
            );
            _ = msg1(void, task, "didReceiveResponse:", resp);
            _ = msg1(void, task, "didReceiveData:", objc.nsData(body.ptr, body.len));
            msg0(void, task, "didFinish");
        }

        // ------------------------------------------------------------------
        // IPC
        // ------------------------------------------------------------------
        fn handleRaw(self: *Self, raw: []const u8) void {
            var decoded = ipc.decode(self.alloc, raw) catch return;
            defer decoded.deinit();
            switch (decoded.msg) {
                .invoke => |inv| {
                    log.print("[macos] ipc invoke {s} id={d}", .{ inv.method, inv.id });
                    var arena = std.heap.ArenaAllocator.init(self.alloc);
                    defer arena.deinit();
                    const ctx = self.context(arena.allocator());

                    const result: []const u8 = blk: {
                        if (builtin_cmds.dispatch(ctx, inv.method, inv.args_json)) |maybe| {
                            if (maybe) |json| break :blk json;
                        } else |err| {
                            log.print("[macos] builtin {s} failed: {s}", .{ inv.method, @errorName(err) });
                            self.reject(inv.id, @errorName(err));
                            return;
                        }
                        break :blk ipc.dispatch(config.commands, ctx, inv.method, inv.args_json) catch |err| {
                            log.print("[macos] invoke {s} failed: {s}", .{ inv.method, @errorName(err) });
                            self.reject(inv.id, @errorName(err));
                            return;
                        };
                    };
                    const resp = ipc.encodeResolve(self.alloc, inv.id, result) catch return;
                    defer self.alloc.free(resp);
                    self.deliver(resp);
                },
                .event => |ev| {
                    if (std.mem.eql(u8, ev.name, "__zilt.macosProbe")) {
                        self.ipc_seen = true;
                        // 真实往返断言：greet 的返回必须回到页面（Zig→JS deliver → Promise）
                        self.ipc_ok = std.mem.indexOf(u8, ev.payload_json, "Hello, macos!") != null;
                        log.print("[macos] ipc roundtrip greet={s} {s}", .{
                            boolStr(self.ipc_ok), ev.payload_json,
                        });
                        return;
                    }
                    var arena = std.heap.ArenaAllocator.init(self.alloc);
                    defer arena.deinit();
                    const ctx = self.context(arena.allocator());
                    _ = ipc.dispatchEvent(config.events, ctx, ev.name, ev.payload_json);
                },
                else => {},
            }
        }

        fn context(self: *Self, alloc: std.mem.Allocator) ipc.Context {
            return .{
                .allocator = alloc,
                .msg_allocator = self.alloc,
                .backend = @ptrCast(self),
                .window_id = 0,
                .emit_fn = emitEntry,
                .quit_fn = quitEntry,
                .window_fn = windowEntry,
                .window_query_fn = windowQueryEntry,
            };
        }

        fn deliver(self: *Self, json: []const u8) void {
            lockSpin(&self.out_mutex);
            const copy = self.alloc.dupe(u8, json) catch {
                self.out_mutex.unlock();
                return;
            };
            self.out_queue.append(self.alloc, copy) catch {
                self.out_mutex.unlock();
                self.alloc.free(copy);
                return;
            };
            self.out_mutex.unlock();

            if (isMainThread()) {
                self.drain();
            } else {
                // 无 block 依赖的 marshal：performSelectorOnMainThread
                _ = objc.msgSend(*const fn (Id, Sel, Sel, ?Id, bool) callconv(.c) void)(
                    mainQueueObject(),
                    objc.sel("performSelectorOnMainThread:withObject:waitUntilDone:"),
                    objc.sel("drain:"),
                    @as(?Id, null),
                    false,
                );
            }
        }

        /// 主线程：把队列里的消息逐条投给页面。
        fn drain(self: *Self) void {
            while (true) {
                lockSpin(&self.out_mutex);
                const item = if (self.out_queue.items.len > 0)
                    self.out_queue.orderedRemove(0)
                else
                    null;
                self.out_mutex.unlock();
                const json = item orelse break;
                defer self.alloc.free(json);
                const script = std.fmt.allocPrint(self.alloc, "window.__ziltDeliver({s})", .{json}) catch continue;
                defer self.alloc.free(script);
                self.evalScript(script);
            }
        }

        fn evalScript(self: *Self, script: []const u8) void {
            _ = objc.msgSend(*const fn (Id, Sel, Id, ?*const anyopaque) callconv(.c) void)(
                self.webview,
                objc.sel("evaluateJavaScript:completionHandler:"),
                objc.nsString(script.ptr, script.len),
                null,
            );
        }

        fn reject(self: *Self, id: u64, err_name: []const u8) void {
            const resp = ipc.encodeReject(self.alloc, id, err_name) catch return;
            defer self.alloc.free(resp);
            self.deliver(resp);
        }

        // ------------------------------------------------------------------
        // ------------------------------------------------------------------
        // v0.4.5 窗口控制：window_fn / window_query_fn（本期单窗口 id 0）
        //   坐标语义对齐 Windows/Linux：对外 x/y 用左上原点，内部换算 Cocoa 左下原点；
        //   非主屏坐标按主屏高度换算（多屏精确换算随 v0.4.6）。
        // ------------------------------------------------------------------
        const Size = extern struct { w: f64, h: f64 };
        const Pt = extern struct { x: f64, y: f64 };
        const NSRect = extern struct { origin: Pt, size: Size };

        /// NSWindowStyleMaskFullScreen / NSWindowStyleMaskResizable
        const mask_fullscreen: c_ulong = 1 << 14;
        const mask_resizable: c_ulong = 1 << 3;

        fn frameOf(win: Id) NSRect {
            return objc.msgSend(*const fn (Id, Sel) callconv(.c) NSRect)(win, objc.sel("frame"));
        }

        fn styleMaskOf(win: Id) c_ulong {
            return objc.msgSend(*const fn (Id, Sel) callconv(.c) c_ulong)(win, objc.sel("styleMask"));
        }

        fn contentSize(win: Id) Size {
            const cv = msg0(?Id, win, "contentView") orelse return .{ .w = 0, .h = 0 };
            return objc.msgSend(*const fn (Id, Sel) callconv(.c) NSRect)(cv, objc.sel("bounds")).size;
        }

        /// 主屏高度（Cocoa 原点在左下）——把对外「左上原点」语义换算过去
        fn screenHeight() f64 {
            const scr = msg0(?Id, objc.cls("NSScreen"), "mainScreen") orelse return 0;
            return objc.msgSend(*const fn (Id, Sel) callconv(.c) NSRect)(scr, objc.sel("frame")).size.h;
        }

        fn windowEntry(backend: *anyopaque, window_id: u32, cmd: ipc.WindowCmd) bool {
            const self: *Self = @ptrCast(@alignCast(backend));
            if (window_id != 0) return false; // 多窗口随 spawn_window_fn 落地
            return self.applyWindowCmd(cmd);
        }

        fn applyWindowCmd(self: *Self, cmd: ipc.WindowCmd) bool {
            const win = self.window;
            switch (cmd) {
                .set_title => |t| {
                    _ = msg1(void, win, "setTitle:", objc.nsString(t.ptr, t.len));
                    return true;
                },
                .minimize => {
                    _ = msg1(void, win, "miniaturize:", @as(?Id, null));
                    return true;
                },
                .maximize => {
                    if (!msg0(bool, win, "isZoomed")) _ = msg1(void, win, "zoom:", @as(?Id, null));
                    return true;
                },
                .restore => {
                    if (msg0(bool, win, "isMiniaturized")) _ = msg1(void, win, "deminiaturize:", @as(?Id, null));
                    if (msg0(bool, win, "isZoomed")) _ = msg1(void, win, "zoom:", @as(?Id, null));
                    return true;
                },
                .fullscreen => |want| {
                    const cur = (styleMaskOf(win) & mask_fullscreen) != 0;
                    if (cur != want) _ = msg1(void, win, "toggleFullScreen:", @as(?Id, null));
                    return true;
                },
                .size => |sz| {
                    _ = objc.msgSend(*const fn (Id, Sel, Size) callconv(.c) void)(win, objc.sel("setContentSize:"), .{
                        .w = @floatFromInt(sz.width),
                        .h = @floatFromInt(sz.height),
                    });
                    return true;
                },
                .position => |p| {
                    const f = frameOf(win);
                    // 左上原点 y → Cocoa 左下原点
                    const y = screenHeight() - @as(f64, @floatFromInt(p.y)) - f.size.h;
                    _ = objc.msgSend(*const fn (Id, Sel, Pt) callconv(.c) void)(win, objc.sel("setFrameTopLeftPoint:"), .{
                        .x = @floatFromInt(p.x),
                        .y = y,
                    });
                    return true;
                },
                .show, .focus => {
                    _ = msg1(void, win, "makeKeyAndOrderFront:", @as(?Id, null));
                    _ = msg1(void, self.app, "activateIgnoringOtherApps:", true);
                    return true;
                },
                .hide => {
                    _ = msg1(void, win, "orderOut:", @as(?Id, null));
                    return true;
                },
                .close => {
                    _ = msg0(void, win, "close");
                    return true;
                },
                .always_on_top => |on| {
                    // NSFloatingWindowLevel=3 / NSNormalWindowLevel=0
                    _ = msg1(void, win, "setLevel:", @as(c_long, if (on) 3 else 0));
                    return true;
                },
                .limits => |lim| {
                    const mn = objc.msgSend(*const fn (Id, Sel) callconv(.c) Size)(win, objc.sel("contentMinSize"));
                    const mx = objc.msgSend(*const fn (Id, Sel) callconv(.c) Size)(win, objc.sel("contentMaxSize"));
                    _ = objc.msgSend(*const fn (Id, Sel, Size) callconv(.c) void)(win, objc.sel("setContentMinSize:"), .{
                        .w = if (lim.min_width) |v| @floatFromInt(v) else mn.w,
                        .h = if (lim.min_height) |v| @floatFromInt(v) else mn.h,
                    });
                    _ = objc.msgSend(*const fn (Id, Sel, Size) callconv(.c) void)(win, objc.sel("setContentMaxSize:"), .{
                        .w = if (lim.max_width) |v| @floatFromInt(v) else mx.w,
                        .h = if (lim.max_height) |v| @floatFromInt(v) else mx.h,
                    });
                    return true;
                },
                .state => return true, // 查询走 window_query_fn
                else => {
                    log.print("[macos] window cmd not mapped (v0.4.5 首批)", .{});
                    return false;
                },
            }
        }

        /// 窗口状态 JSON：字段名与 Windows/Linux 对齐；macOS 无对等项的显式标记
        fn windowQueryEntry(backend: *anyopaque, window_id: u32, alloc: std.mem.Allocator) ?[]u8 {
            const self: *Self = @ptrCast(@alignCast(backend));
            if (window_id != 0) return null;
            const f = frameOf(self.window);
            const cs = contentSize(self.window);
            const mn = objc.msgSend(*const fn (Id, Sel) callconv(.c) Size)(self.window, objc.sel("contentMinSize"));
            const mx = objc.msgSend(*const fn (Id, Sel) callconv(.c) Size)(self.window, objc.sel("contentMaxSize"));
            const x: i32 = @intFromFloat(@round(f.origin.x));
            const y: i32 = @intFromFloat(@round(screenHeight() - (f.origin.y + f.size.h)));
            return std.fmt.allocPrint(alloc,
                \\{"id":0,"x":{d},"y":{d},"width":{d},"height":{d},"visible":{s},"focused":{s},"zoomed":{s},"iconic":{s},"fullscreen":{s},"always_on_top":{s},"resizable":{s},"decorated":true,"min_width":{d},"min_height":{d},"max_width":{d},"max_height":{d}}
            , .{
                x,
                y,
                @as(u32, @intFromFloat(@round(cs.w))),
                @as(u32, @intFromFloat(@round(cs.h))),
                boolStr(msg0(bool, self.window, "isVisible")),
                boolStr(msg0(bool, self.window, "isKeyWindow")),
                boolStr(msg0(bool, self.window, "isZoomed")),
                boolStr(msg0(bool, self.window, "isMiniaturized")),
                boolStr((styleMaskOf(self.window) & mask_fullscreen) != 0),
                boolStr(msg0(c_long, self.window, "level") > 0),
                boolStr((styleMaskOf(self.window) & mask_resizable) != 0),
                @as(u32, @intFromFloat(@round(mn.w))),
                @as(u32, @intFromFloat(@round(mn.h))),
                @as(u32, @intFromFloat(@round(mx.w))),
                @as(u32, @intFromFloat(@round(mx.h))),
            }) catch null;
        }

        /// 冒烟探针：窗口控制往返（尺寸 / 标题 / 置顶 / 状态查询）→ CI 硬断言
        fn runWindowOpsProbe(self: *Self) bool {
            var ok = self.applyWindowCmd(.{ .size = .{ .width = 640, .height = 480 } });
            ok = self.applyWindowCmd(.{ .set_title = "Zilt Smoke (v0.4.5)" }) and ok;
            ok = self.applyWindowCmd(.{ .always_on_top = true }) and ok;
            ok = self.applyWindowCmd(.{ .always_on_top = false }) and ok;
            const cs = contentSize(self.window);
            const size_ok = @abs(cs.w - 640.0) < 1.0 and @abs(cs.h - 480.0) < 1.0;
            var json_ok = false;
            if (self.windowQueryEntry(@ptrCast(self), 0, self.alloc)) |json| {
                json_ok = std.mem.indexOf(u8, json, "width") != null;
                self.alloc.free(json);
            }
            const good = ok and size_ok and json_ok;
            log.print("[macos] window ops ok={s} content={d}x{d} json={s}", .{
                boolStr(good),
                @as(u32, @intFromFloat(@round(cs.w))),
                @as(u32, @intFromFloat(@round(cs.h))),
                boolStr(json_ok),
            });
            return good;
        }

        // 冒烟：有界 runloop + 页面/IPC 探针
        // ------------------------------------------------------------------
        fn smokeLoop(self: *Self) !void {
            const NSDate = objc.cls("NSDate");
            const mode = objc.nsStringZ("kCFRunLoopDefaultMode");
            const deadline = objc.msgSend(*const fn (Class, Sel, f64) callconv(.c) Id)(
                NSDate,
                objc.sel("dateWithTimeIntervalSinceNow:"),
                @as(f64, @floatFromInt(self.smoke_ms)) / 1000.0,
            );
            log.print("[macos] event loop start", .{});
            while (true) {
                // v0.4.5 基建：每轮泵手动 autorelease pool——dateWithTimeIntervalSinceNow:
                // 等返回 autoreleased 对象，不回收就是每 50ms 泄一个（长跑必泄）
                const pool = objc.objc_autoreleasePoolPush();
                defer objc.objc_autoreleasePoolPop(pool);
                const until = objc.msgSend(*const fn (Class, Sel, f64) callconv(.c) Id)(
                    NSDate,
                    objc.sel("dateWithTimeIntervalSinceNow:"),
                    0.05,
                );
                if (objc.msgSend(*const fn (Id, Sel, c_ulong, Id, Id, bool) callconv(.c) ?Id)(
                    self.app,
                    objc.sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
                    ~@as(c_ulong, 0),
                    until,
                    mode,
                    true,
                )) |ev| {
                    _ = msg1(void, self.app, "sendEvent:", ev);
                }
                if (self.page_loaded and !self.probe_sent) {
                    self.probe_sent = true;
                    self.evalScript(probe_js);
                    self.win_ops_ok = self.runWindowOpsProbe();
                    log.print("[macos] probe sent", .{});
                }
                const left = msg0(f64, deadline, "timeIntervalSinceNow");
                if (left <= 0) break;
            }
            log.print("[macos] smoke done, exiting (loaded={s} ipc={s} greet={s})", .{
                boolStr(self.page_loaded), boolStr(self.ipc_seen), boolStr(self.ipc_ok),
            });
            if (!self.page_loaded) return error.PageNotLoaded;
            if (!self.ipc_seen) return error.IpcProbeMissing;
            if (!self.ipc_ok) return error.IpcRoundtripFailed;
            if (!self.win_ops_ok) return error.WindowOpsFailed;
        }

        // ------------------------------------------------------------------
        // 运行时类 + 回调
        // ------------------------------------------------------------------
        fn registerClasses() void {
            _ = objc.defineClass("ZiltWindowDelegate", null, &.{
                .{ .name = "windowWillClose:", .imp = imp(&onWindowClose), .types = "v@:@" },
            });
            _ = objc.defineClass("ZiltNavigationDelegate", "WKNavigationDelegate", &.{
                .{ .name = "webView:didFinishNavigation:", .imp = imp(&onNavigateFinish), .types = "v@:@@" },
            });
            _ = objc.defineClass("ZiltSchemeHandler", "WKURLSchemeHandler", &.{
                .{ .name = "webView:startURLSchemeTask:", .imp = imp(&onStartTask), .types = "v@:@@" },
                .{ .name = "webView:stopURLSchemeTask:", .imp = imp(&onStopTask), .types = "v@:@@" },
            });
            _ = objc.defineClass("ZiltMessageHandler", "WKScriptMessageHandler", &.{
                .{ .name = "userContentController:didReceiveScriptMessage:", .imp = imp(&onScriptMessage), .types = "v@:@@" },
            });
            _ = objc.defineClass("ZiltMainQueue", null, &.{
                .{ .name = "drain:", .imp = imp(&onDrain), .types = "v@:@" },
            });
        }

        fn onWindowClose(_: Id, _: Sel, _: Id) callconv(.c) void {
            log.print("[macos] window closing → terminate", .{});
            msg1(void, inst.app, "terminate:", @as(?Id, null));
        }

        fn onNavigateFinish(_: Id, _: Sel, _: Id, _: Id) callconv(.c) void {
            inst.page_loaded = true;
            log.print("[macos] page loaded", .{});
        }

        fn onStartTask(_: Id, _: Sel, _: Id, task: Id) callconv(.c) void {
            inst.serveTask(task);
        }

        fn onStopTask(_: Id, _: Sel, _: Id, _: Id) callconv(.c) void {}

        fn onDrain(_: Id, _: Sel, _: Id) callconv(.c) void {
            inst.drain();
        }

        fn onScriptMessage(_: Id, _: Sel, _: Id, message: Id) callconv(.c) void {
            const body = msg0(Id, message, "body");
            const json = objc.jsonFromId(inst.alloc, body) orelse return;
            defer inst.alloc.free(json);
            inst.handleRaw(json);
        }

        // ------------------------------------------------------------------
        // 小工具
        // ------------------------------------------------------------------
        fn emitEntry(backend: *anyopaque, window_id: u32, message_json: []const u8) void {
            _ = window_id;
            const self: *Self = @ptrCast(@alignCast(backend));
            self.deliver(message_json);
        }

        fn quitEntry(backend: *anyopaque, code: u8) void {
            _ = code;
            const self: *Self = @ptrCast(@alignCast(backend));
            log.print("[macos] quit requested", .{});
            msg1(void, self.app, "terminate:", @as(?Id, null));
        }
    };
}

// ---------------------------------------------------------------------------
// ObjC 消息糖（按参数类型选签名，避免每处重复写 fn 指针类型）
// ---------------------------------------------------------------------------
fn msg0(comptime R: type, obj: Id, name: [*:0]const u8) R {
    return objc.msgSend(*const fn (Id, Sel) callconv(.c) R)(obj, objc.sel(name));
}

fn msg1(comptime R: type, obj: Id, name: [*:0]const u8, arg: anytype) R {
    return switch (@TypeOf(arg)) {
        Id, ?Id => objc.msgSend(*const fn (Id, Sel, @TypeOf(arg)) callconv(.c) R)(obj, objc.sel(name), arg),
        bool => objc.msgSend(*const fn (Id, Sel, bool) callconv(.c) R)(obj, objc.sel(name), arg),
        c_long => objc.msgSend(*const fn (Id, Sel, c_long) callconv(.c) R)(obj, objc.sel(name), arg),
        else => @compileError("msg1: unsupported arg type " ++ @typeName(@TypeOf(arg))),
    };
}

/// 取方法实现的裸指针（class_addMethod 需要）。入参必须是**函数指针**
/// （`&onXxx`），直接转型——此前 `@ptrCast(&f)` 取到的是「指针的指针」，
/// WebKit 一调用 IMP 就 Bus error（CI 45023844762 实测）。
fn imp(comptime f: anytype) *const anyopaque {
    return @ptrCast(f);
}

/// 0.17 的 std.atomic.Mutex 只有 tryLock（无阻塞 lock）——队列极短，自旋足够。
fn lockSpin(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

fn isMainThread() bool {
    return msg0(bool, objc.cls("NSThread"), "isMainThread");
}

/// 主线程 marshal 的接收者（懒创建，进程生命周期）。
fn mainQueueObject() Id {
    const S = struct {
        var obj: ?Id = null;
    };
    if (S.obj) |o| return o;
    const o = msg0(Id, objc.cls("ZiltMainQueue"), "new");
    S.obj = o;
    return o;
}

fn boolStr(v: bool) []const u8 {
    return if (v) "true" else "false";
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// 冒烟时长（毫秒）：非数字/0 → 0（正常运行）；上限 10 分钟防 CI 挂死。
fn parseSmokeMs(raw: ?[]const u8) u32 {
    const s = raw orelse return 0;
    const v = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t\r\n"), 10) catch return 0;
    return @min(v, 600_000);
}

const testing = std.testing;

test "macos: parseSmokeMs 边界" {
    try testing.expectEqual(@as(u32, 0), parseSmokeMs(null));
    try testing.expectEqual(@as(u32, 0), parseSmokeMs("abc"));
    try testing.expectEqual(@as(u32, 5000), parseSmokeMs("5000"));
    try testing.expectEqual(@as(u32, 5000), parseSmokeMs(" 5000\n"));
    try testing.expectEqual(@as(u32, 600_000), parseSmokeMs("999999999"));
}
