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
const config_mod = @import("../../config.zig");
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
        wins: std.ArrayListUnmanaged(WinState) = .empty,
        next_win_id: u32 = 1,
        ev_moved: u32 = 0,
        ev_resized: u32 = 0,
        ev_focus: u32 = 0,
        ev_blur: u32 = 0,
        last_dark: ?bool = null,
        vibrancy_view: ?Id = null,
        smoke_ms: u32 = 0,
        /// v0.4.5：窗口控制探针结果（CI 硬断言）
        win_ops_ok: bool = false,
        assets: std.StringHashMapUnmanaged([]u8) = .empty,
        /// 跨线程 emit 队列（worker → 主线程 drain；WebKit 只允许主线程 eval）
        out_mutex: std.atomic.Mutex = .unlocked,
        out_queue: std.ArrayListUnmanaged(OutItem) = .empty,

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
            inst.buildMenu();
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

        /// v0.4.5 多窗口：主窗口沿用 window/webview 字段，附加窗口进 wins（id 从 1 起）
        const WinState = struct {
            id: u32,
            win: Id,
            webview: Id,
        };

        /// 跨线程投递项（带目标窗口，drain 时按窗 eval）
        const OutItem = struct {
            window_id: u32,
            json: []u8,
        };

        /// v0.4.5 外观：标题栏三态 + 透明（config 驱动）
        ///   standard：系统默认；overlay：摘 titled + FullSizeContentView（内容顶到红绿灯）；
        ///   transparent：标题栏透明；config.transparent 额外关 opaque 并设透明背景。
        fn boundsOf(view: Id) NSRect {
            return objc.msgSend(*const fn (Id, Sel) callconv(.c) NSRect)(view, objc.sel("bounds"));
        }

        /// 窗口材质：NSVisualEffectView 垫在 webview 下面（config.vibrancy；冒烟强制 sidebar）
        fn applyVibrancy(self: *Self) void {
            const v: config_mod.Vibrancy = config.vibrancy orelse blk: {
                if (self.smoke_ms != 0) break :blk config_mod.Vibrancy.sidebar;
                return;
            };
            const material: c_long = switch (v) {
                .sidebar => 7,
                .hud => 13,
                .window => 12,
            };
            const content = msg0(Id, self.window, "contentView");
            const ev = objc.allocInit(objc.cls("NSVisualEffectView"));
            _ = msg1(void, ev, "setMaterial:", material);
            _ = msg1(void, ev, "setBlendingMode:", @as(c_long, 0));
            _ = msg1(void, ev, "setState:", @as(c_long, 1));
            const b = boundsOf(content);
            _ = objc.msgSend(*const fn (Id, Sel, NSRect) callconv(.c) void)(ev, objc.sel("setFrame:"), b);
            _ = objc.msgSend(*const fn (Id, Sel, Id, c_long, ?Id) callconv(.c) void)(
                content,
                objc.sel("addSubview:positioned:relativeTo:"),
                ev,
                -1, // NSWindowBelow
                self.webview,
            );
            _ = msg1(void, self.window, "setOpaque:", false);
            self.vibrancy_view = ev;
            log.print("[macos] vibrancy applied material={d}", .{material});
        }

        fn statePath(_: *Self, buf: []u8) ?[]const u8 {
            const home_z = std.c.getenv("HOME") orelse return null;
            return std.fmt.bufPrint(buf, "{s}/.zilt-window-{s}.json", .{ std.mem.span(home_z), config.app_id }) catch null;
        }

        /// 关窗/退出时写当前 frame（走 Foundation，避开 std.Io 差异）
        fn saveWindowState(self: *Self) bool {
            var buf: [512]u8 = undefined;
            const path = self.statePath(&buf) orelse return false;
            const f = frameOf(self.window);
            var out: [128]u8 = undefined;
            const body = std.fmt.bufPrint(&out, "{d} {d} {d} {d}\n", .{
                toI32(f.origin.x), toI32(f.origin.y), dimToU32(f.size.w), dimToU32(f.size.h),
            }) catch return false;
            return objc.msgSend(*const fn (Id, Sel, Id, bool, c_ulong, ?Id) callconv(.c) bool)(
                objc.nsString(body.ptr, body.len),
                objc.sel("writeToFile:atomically:encoding:error:"),
                objc.nsString(path.ptr, path.len),
                true,
                4, // NSUTF8StringEncoding
                null,
            );
        }

        fn loadWindowState(self: *Self) ?[4]i32 {
            var buf: [512]u8 = undefined;
            const path = self.statePath(&buf) orelse return null;
            const ns = objc.msgSend(*const fn (Id, Sel, Id, c_ulong, ?Id) callconv(.c) ?Id)(
                objc.cls("NSString"),
                objc.sel("stringWithContentsOfFile:encoding:error:"),
                objc.nsString(path.ptr, path.len),
                4,
                null,
            ) orelse return null;
            const cs = msg0(?[*:0]const u8, ns, "UTF8String") orelse return null;
            const text = std.mem.span(cs);
            var it = std.mem.tokenizeAny(u8, text, " \n\r");
            var vals: [4]i32 = .{ 0, 0, 0, 0 };
            var i: usize = 0;
            while (it.next()) |tok| : (i += 1) {
                if (i >= 4) break;
                vals[i] = std.fmt.parseInt(i32, tok, 10) catch 0;
            }
            if (i < 4) return null;
            return vals;
        }


        fn applyAppearance(_: *Self, win: Id) void {
            if (config.titlebar_overlay) {
                var mask = styleMaskOf(win);
                mask &= ~@as(c_ulong, 1);
                mask |= 1 << 15; // NSWindowStyleMaskFullSizeContentView
                _ = objc.msgSend(*const fn (Id, Sel, c_ulong) callconv(.c) void)(win, objc.sel("setStyleMask:"), mask);
                _ = msg1(void, win, "setTitlebarAppearsTransparent:", true);
                _ = msg1(void, win, "setTitleVisibility:", @as(c_long, 1));
                _ = msg1(void, win, "setMovableByWindowBackground:", true);
            } else if (config.transparent) {
                _ = msg1(void, win, "setTitlebarAppearsTransparent:", true);
            }
            if (config.transparent) {
                _ = msg1(void, win, "setOpaque:", false);
                _ = msg1(void, win, "setBackgroundColor:", msg0(Id, objc.cls("NSColor"), "clearColor"));
            }
            log.print("[macos] appearance overlay={} transparent={}", .{ config.titlebar_overlay, config.transparent });
        }

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
            self.applyAppearance(win);
            if (self.loadWindowState()) |v| {
                _ = objc.msgSend(*const fn (Id, Sel, NSRect, bool) callconv(.c) void)(
                    win,
                    objc.sel("setFrame:display:"),
                    .{
                        .origin = .{ .x = @floatFromInt(v[0]), .y = @floatFromInt(v[1]) },
                        .size = .{ .w = @floatFromInt(v[2]), .h = @floatFromInt(v[3]) },
                    },
                    true,
                );
                log.print("[macos] window state restored x={d} y={d} w={d} h={d}", .{ v[0], v[1], v[2], v[3] });
            } else {
                log.print("[macos] window state none", .{});
            }
            _ = msg1(void, win, "makeKeyAndOrderFront:", @as(?Id, null));
            _ = msg1(void, self.app, "activateIgnoringOtherApps:", true);
            log.print("[macos] window created {d}x{d}", .{ config.width, config.height });
        }

        fn createWebView(self: *Self) !void {
            self.webview = try self.makeWebView(config.width, config.height);
            _ = msg1(void, self.window, "setContentView:", self.webview);
            log.print("[macos] webview created", .{});
            try self.loadUrlIn(self.webview, null);
            self.applyVibrancy();
        }

        /// 为一个 NSWindow 建 WKWebView：配置 + runtime 注入 + 消息/导航 delegate + scheme handler
        fn makeWebView(_: *Self, width: u32, height: u32) !Id {
            const cfg = objc.allocInit(objc.cls("WKWebViewConfiguration"));
            const ucc = objc.allocInit(objc.cls("WKUserContentController"));
            _ = objc.msgSend(*const fn (Id, Sel, Id, Id) callconv(.c) void)(
                ucc,
                objc.sel("addScriptMessageHandler:name:"),
                msg0(Id, objc.cls("ZiltMessageHandler"), "new"),
                objc.nsStringZ("zilt"),
            );
            const us_raw = msg0(Id, objc.cls("WKUserScript"), "alloc");
            const us = objc.msgSend(*const fn (Id, Sel, Id, c_ulong, bool) callconv(.c) Id)(
                us_raw,
                objc.sel("initWithSource:injectionTime:forMainFrameOnly:"),
                objc.nsString(ipc.runtime_js.ptr, ipc.runtime_js.len),
                0,
                false,
            );
            _ = msg1(void, ucc, "addUserScript:", us);
            _ = msg1(void, cfg, "setUserContentController:", ucc);
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
                    .w = @floatFromInt(width),
                    .h = @floatFromInt(height),
                },
                cfg,
            );
            if (@intFromPtr(wv) == 0) return error.WebViewCreationFailed;
            _ = msg1(void, wv, "setNavigationDelegate:", msg0(Id, objc.cls("ZiltNavigationDelegate"), "new"));
            return wv;
        }

        fn loadUrlIn(self: *Self, wv: Id, override: ?[]const u8) !void {
            const entry = if (override) |u| try self.alloc.dupe(u8, u) else try self.entryUrl();
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
        fn handleRaw(self: *Self, window_id: u32, raw: []const u8) void {
            var decoded = ipc.decode(self.alloc, raw) catch return;
            defer decoded.deinit();
            switch (decoded.msg) {
                .invoke => |inv| {
                    log.print("[macos] ipc invoke {s} id={d}", .{ inv.method, inv.id });
                    var arena = std.heap.ArenaAllocator.init(self.alloc);
                    defer arena.deinit();
                    const ctx = self.context(arena.allocator(), window_id);

                    const result: []const u8 = blk: {
                        if (builtin_cmds.dispatch(ctx, inv.method, inv.args_json)) |maybe| {
                            if (maybe) |json| break :blk json;
                        } else |err| {
                            log.print("[macos] builtin {s} failed: {s}", .{ inv.method, @errorName(err) });
                            self.reject(window_id, inv.id, @errorName(err));
                            return;
                        }
                        break :blk ipc.dispatch(config.commands, ctx, inv.method, inv.args_json) catch |err| {
                            log.print("[macos] invoke {s} failed: {s}", .{ inv.method, @errorName(err) });
                            self.reject(window_id, inv.id, @errorName(err));
                            return;
                        };
                    };
                    const resp = ipc.encodeResolve(self.alloc, inv.id, result) catch return;
                    defer self.alloc.free(resp);
                    self.deliver(window_id, resp);
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
                    const ctx = self.context(arena.allocator(), window_id);
                    _ = ipc.dispatchEvent(config.events, ctx, ev.name, ev.payload_json);
                },
                else => {},
            }
        }

        fn context(self: *Self, alloc: std.mem.Allocator, window_id: u32) ipc.Context {
            return .{
                .allocator = alloc,
                .msg_allocator = self.alloc,
                .backend = @ptrCast(self),
                .window_id = window_id,
                .emit_fn = emitEntry,
                .quit_fn = quitEntry,
                .window_fn = windowEntry,
                .window_query_fn = windowQueryEntry,
                .spawn_window_fn = spawnWindowEntry,
                .clipboard_write_fn = clipWriteEntry,
                .clipboard_read_fn = clipReadEntry,
                .dialog_fn = dialogEntry,
            };
        }

        fn deliver(self: *Self, window_id: u32, json: []const u8) void {
            lockSpin(&self.out_mutex);
            const copy = self.alloc.dupe(u8, json) catch {
                self.out_mutex.unlock();
                return;
            };
            self.out_queue.append(self.alloc, .{ .window_id = window_id, .json = copy }) catch {
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
                const it = item orelse break;
                defer self.alloc.free(it.json);
                const script = std.fmt.allocPrint(self.alloc, "window.__ziltDeliver({s})", .{it.json}) catch continue;
                defer self.alloc.free(script);
                self.evalScript(self.webviewFor(it.window_id), script);
            }
        }

        fn evalScript(_: *Self, wv: Id, script: []const u8) void {
            _ = objc.msgSend(*const fn (Id, Sel, Id, ?*const anyopaque) callconv(.c) void)(
                wv,
                objc.sel("evaluateJavaScript:completionHandler:"),
                objc.nsString(script.ptr, script.len),
                null,
            );
        }

        fn reject(self: *Self, window_id: u32, id: u64, err_name: []const u8) void {
            const resp = ipc.encodeReject(self.alloc, id, err_name) catch return;
            defer self.alloc.free(resp);
            self.deliver(window_id, resp);
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
            return self.applyWindowCmd(window_id, cmd);
        }

        fn applyWindowCmd(self: *Self, window_id: u32, cmd: ipc.WindowCmd) bool {
            const win = self.targetWindow(window_id) orelse return false;
            switch (cmd) {
                .start_dragging => {
                    // 自定义标题栏：runtime_js 命中 data-zilt-drag-region 后调 startDragging
                    const ev = msg0(?Id, objc.cls("NSApplication"), "currentEvent") orelse return false;
                    if (msg0(c_ulong, ev, "type") != 1) return false; // 1 = leftMouseDown
                    _ = msg1(void, win, "performWindowDragWithEvent:", ev);
                    return true;
                },
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

        /// NSWindow 的 contentMaxSize 默认是极大的值（近乎 FLT_MAX）——直接
        /// @intFromFloat 会触发 “integer part of floating point value out of bounds”
        /// （CI 45029055532 实测）。统一做有限性 + 边界钳制。
        fn dimToU32(v: f64) u32 {
            if (!std.math.isFinite(v) or v <= 0) return 0;
            const r = @round(v);
            if (r >= 4_000_000_000.0) return 4_000_000_000;
            return @intFromFloat(r);
        }

        fn toI32(v: f64) i32 {
            if (!std.math.isFinite(v)) return 0;
            const r = @round(v);
            if (r >= 2_000_000_000.0) return 2_000_000_000;
            if (r <= -2_000_000_000.0) return -2_000_000_000;
            return @intFromFloat(r);
        }

        /// 窗口状态 JSON：字段名与 Windows/Linux 对齐；macOS 无对等项的显式标记
        fn windowQueryEntry(backend: *anyopaque, window_id: u32, alloc: std.mem.Allocator) ?[]u8 {
            const self: *Self = @ptrCast(@alignCast(backend));
            const win = self.targetWindow(window_id) orelse return null;
            const f = frameOf(win);
            const cs = contentSize(win);
            const mn = objc.msgSend(*const fn (Id, Sel) callconv(.c) Size)(win, objc.sel("contentMinSize"));
            const mx = objc.msgSend(*const fn (Id, Sel) callconv(.c) Size)(win, objc.sel("contentMaxSize"));
            const x: i32 = toI32(f.origin.x);
            const y: i32 = toI32(screenHeight() - (f.origin.y + f.size.h));
            return std.fmt.allocPrint(alloc,
                \\{{"id":0,"x":{d},"y":{d},"width":{d},"height":{d},"visible":{s},"focused":{s},"zoomed":{s},"iconic":{s},"fullscreen":{s},"always_on_top":{s},"resizable":{s},"decorated":true,"min_width":{d},"min_height":{d},"max_width":{d},"max_height":{d}}}
            , .{
                x,
                y,
                dimToU32(cs.w),
                dimToU32(cs.h),
                boolStr(msg0(bool, win, "isVisible")),
                boolStr(msg0(bool, win, "isKeyWindow")),
                boolStr(msg0(bool, win, "isZoomed")),
                boolStr(msg0(bool, win, "isMiniaturized")),
                boolStr((styleMaskOf(win) & mask_fullscreen) != 0),
                boolStr(msg0(c_long, win, "level") > 0),
                boolStr((styleMaskOf(win) & mask_resizable) != 0),
                dimToU32(mn.w),
                dimToU32(mn.h),
                dimToU32(mx.w),
                dimToU32(mx.h),
            }) catch null;
        }

        /// 冒烟探针：真开一个副窗口，验证 wins 表 / spawn_window_fn 链路
        fn runSpawnProbe(self: *Self) bool {
            const before = self.wins.items.len;
            const id = spawnWindowEntry(@ptrCast(self), .{
                .title = "Zilt Secondary",
                .width = 480,
                .height = 360,
            });
            const ok = id != null and self.wins.items.len == before + 1;
            log.print("[macos] window spawn ok={s} id={d} count={d}", .{
                boolStr(ok),
                id orelse 0,
                self.wins.items.len,
            });
            return ok;
        }

        /// 冒烟探针：窗口控制往返（尺寸 / 标题 / 置顶 / 状态查询）→ CI 硬断言
        fn runWindowOpsProbe(self: *Self) bool {
            var ok = self.applyWindowCmd(0, .{ .size = .{ .width = 640, .height = 480 } });
            ok = self.applyWindowCmd(0, .{ .set_title = "Zilt Smoke (v0.4.5)" }) and ok;
            ok = self.applyWindowCmd(0, .{ .always_on_top = true }) and ok;
            ok = self.applyWindowCmd(0, .{ .always_on_top = false }) and ok;
            const cs = contentSize(self.window);
            const size_ok = @abs(cs.w - 640.0) < 1.0 and @abs(cs.h - 480.0) < 1.0;
            var json_ok = false;
            if (windowQueryEntry(@ptrCast(self), 0, self.alloc)) |json| {
                json_ok = std.mem.indexOf(u8, json, "width") != null;
                self.alloc.free(json);
            }
            // 外观：styleMask 切 FullSizeContentView 再还原，断言位确实能读写
            const mask0 = styleMaskOf(self.window);
            _ = objc.msgSend(*const fn (Id, Sel, c_ulong) callconv(.c) void)(self.window, objc.sel("setStyleMask:"), mask0 | (1 << 15));
            const mask1 = styleMaskOf(self.window);
            _ = objc.msgSend(*const fn (Id, Sel, c_ulong) callconv(.c) void)(self.window, objc.sel("setStyleMask:"), mask0);
            const appearance_ok = (mask1 & (1 << 15)) != 0;
            log.print("[macos] appearance ok={s} mask={d}", .{ boolStr(appearance_ok), mask1 });

            _ = self.applyWindowCmd(0, .{ .position = .{ .x = 300, .y = 320 } });
            _ = self.applyWindowCmd(0, .{ .size = .{ .width = 620, .height = 460 } });
            self.pumpFor(0.2);
            const orig_dark = self.isDarkAppearance();
            self.setDarkAppearance(true);
            const dark_ok = self.isDarkAppearance();
            self.setDarkAppearance(false);
            const light_ok = !self.isDarkAppearance();
            self.setDarkAppearance(orig_dark);
            const theme_ok = dark_ok and light_ok;
            log.print("[macos] theme ok={s} dark={s} light={s}", .{
                boolStr(theme_ok), boolStr(dark_ok), boolStr(light_ok),
            });

            const app = msg0(Id, objc.cls("NSApplication"), "sharedApplication");
            const tile = msg0(Id, app, "dockTile");
            _ = msg1(void, tile, "setBadgeLabel:", objc.nsStringZ("3"));
            var dock_ok = false;
            if (msg0(?Id, tile, "badgeLabel")) |b| {
                if (msg0(?[*:0]const u8, b, "UTF8String")) |cstr| {
                    dock_ok = std.mem.eql(u8, std.mem.span(cstr), "3");
                }
            }
            _ = msg1(void, tile, "setBadgeLabel:", @as(?Id, null));
            log.print("[macos] dock ok={s}", .{boolStr(dock_ok)});

            const vib_mat: c_long = if (self.vibrancy_view) |vv| msg0(c_long, vv, "material") else -1;
            const vibrancy_ok = self.vibrancy_view != null and vib_mat == 7;
            log.print("[macos] vibrancy ok={s} material={d}", .{ boolStr(vibrancy_ok), vib_mat });

            const saved_ok = self.saveWindowState();
            var state_ok = false;
            if (self.loadWindowState()) |v| {
                const f = frameOf(self.window);
                state_ok = saved_ok and v[2] == toI32(f.size.w) and v[3] == toI32(f.size.h);
            }
            log.print("[macos] state ok={s} saved={s}", .{ boolStr(state_ok), boolStr(saved_ok) });

            const drag_ok = std.mem.indexOf(u8, ipc.runtime_js, "startDragging") != null;
            log.print("[macos] drag ok={s} wiring-only", .{boolStr(drag_ok)});

            // 剪贴板：写→读→比对（事后还原）
            const prev = self.clipboardRead(self.alloc);
            const wrote = self.clipboardWrite("zilt-clip-probe");
            var clip_ok = wrote;
            if (self.clipboardRead(self.alloc)) |b| {
                clip_ok = clip_ok and std.mem.eql(u8, b, "zilt-clip-probe");
                self.alloc.free(b);
            } else clip_ok = false;
            if (prev) |pv| {
                _ = self.clipboardWrite(pv);
                self.alloc.free(pv);
            } else _ = self.clipboardWrite("");
            log.print("[macos] clipboard ok={s}", .{boolStr(clip_ok)});

            // 对话框：只验接线（runModal 会阻塞，CI 不调）
            const ctx0 = self.context(self.alloc, 0);
            const dialog_ok = ctx0.dialog_fn != null;
            log.print("[macos] dialog ok={s} wiring-only", .{boolStr(dialog_ok)});

            // 主菜单：条数 + 首项子菜单里是否有 Quit
            const app0 = msg0(Id, objc.cls("NSApplication"), "sharedApplication");
            var menu_ok = false;
            var menu_items: c_ulong = 0;
            if (msg0(?Id, app0, "mainMenu")) |mm| {
                menu_items = msg0(c_ulong, mm, "numberOfItems");
                if (menu_items >= 1) {
                    const item0 = msg1(Id, mm, "itemAtIndex:", @as(c_ulong, 0));
                    if (msg0(?Id, item0, "submenu")) |sm| {
                        const n = msg0(c_ulong, sm, "numberOfItems");
                        if (n >= 1) {
                            const qi = msg1(Id, sm, "itemAtIndex:", n - 1);
                            if (msg0(?Id, qi, "title")) |tz| {
                                if (msg0(?[*:0]const u8, tz, "UTF8String")) |csz| {
                                    menu_ok = std.mem.eql(u8, std.mem.span(csz), "Quit");
                                }
                            }
                        }
                    }
                }
            }
            log.print("[macos] menu ok={s} items={d}", .{ boolStr(menu_ok), menu_items });

            const events_ok = self.ev_moved > 0 and self.ev_resized > 0;
            log.print("[macos] window events ok={s} moved={d} resized={d} focus={d} blur={d}", .{
                boolStr(events_ok), self.ev_moved, self.ev_resized, self.ev_focus, self.ev_blur,
            });

            const good = ok and size_ok and json_ok and appearance_ok and events_ok and theme_ok and dock_ok and vibrancy_ok and state_ok and drag_ok and clip_ok and dialog_ok and menu_ok and self.runSpawnProbe();
            log.print("[macos] window ops ok={s} content={d}x{d} json={s}", .{
                boolStr(good),
                dimToU32(cs.w),
                dimToU32(cs.h),
                boolStr(json_ok),
            });
            return good;
        }

        // ------------------------------------------------------------------
        // v0.4.5 多窗口：id 0 = 主窗口；id 1.. = wins 里的附加窗口
        // ------------------------------------------------------------------
        fn targetWindow(self: *Self, window_id: u32) ?Id {
            if (window_id == 0) return self.window;
            for (self.wins.items) |it| {
                if (it.id == window_id) return it.win;
            }
            return null;
        }

        fn webviewFor(self: *Self, window_id: u32) Id {
            if (window_id == 0) return self.webview;
            for (self.wins.items) |it| {
                if (it.id == window_id) return it.webview;
            }
            return self.webview;
        }

        fn windowIdOf(self: *Self, wv: ?Id) u32 {
            const w = wv orelse return 0;
            if (w == self.webview) return 0;
            for (self.wins.items) |it| {
                if (it.webview == w) return it.id;
            }
            return 0;
        }

        fn windowIdOfWindow(self: *Self, win: Id) u32 {
            if (win == self.window) return 0;
            for (self.wins.items) |it| {
                if (it.win == win) return it.id;
            }
            return 0;
        }

        fn emitWindowEvent(self: *Self, window_id: u32, name: []const u8, payload: []const u8) void {
            const msg = ipc.encodeEvent(self.alloc, name, payload) catch return;
            defer self.alloc.free(msg);
            self.deliverAsync(window_id, msg);
        }

        /// 同 deliver，但一律异步转主线程：delegate 回调内直接 evaluate 会被丢弃
        fn deliverAsync(self: *Self, window_id: u32, json: []const u8) void {
            lockSpin(&self.out_mutex);
            const copy = self.alloc.dupe(u8, json) catch {
                self.out_mutex.unlock();
                return;
            };
            self.out_queue.append(self.alloc, .{ .window_id = window_id, .json = copy }) catch {
                self.out_mutex.unlock();
                self.alloc.free(copy);
                return;
            };
            self.out_mutex.unlock();
            _ = objc.msgSend(*const fn (Id, Sel, Sel, ?Id, bool) callconv(.c) void)(
                mainQueueObject(),
                objc.sel("performSelectorOnMainThread:withObject:waitUntilDone:"),
                objc.sel("drain:"),
                @as(?Id, null),
                false,
            );
        }

        fn isDarkAppearance(self: *Self) bool {
            _ = self;
            const app = msg0(Id, objc.cls("NSApplication"), "sharedApplication");
            const eff = msg0(?Id, app, "effectiveAppearance") orelse return false;
            const nm = msg0(?Id, eff, "name") orelse return false;
            const c = msg0(?[*:0]const u8, nm, "UTF8String") orelse return false;
            return std.mem.indexOf(u8, std.mem.span(c), "Dark") != null;
        }

        fn setDarkAppearance(self: *Self, dark: bool) void {
            _ = self;
            const app = msg0(Id, objc.cls("NSApplication"), "sharedApplication");
            const nm: [:0]const u8 = if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua";
            const ap = msg1(Id, objc.cls("NSAppearance"), "appearanceNamed:", objc.nsStringZ(nm));
            _ = msg1(void, app, "setAppearance:", ap);
        }

        fn pumpFor(self: *Self, seconds: f64) void {
            _ = self;
            const rl = msg0(Id, objc.cls("NSRunLoop"), "currentRunLoop");
            const d = objc.msgSend(*const fn (Id, Sel, f64) callconv(.c) Id)(
                objc.cls("NSDate"),
                objc.sel("dateWithTimeIntervalSinceNow:"),
                seconds,
            );
            _ = msg1(void, rl, "runUntilDate:", d);
        }

        fn newNSWindow(_: *Self, title: []const u8, w: u32, h: u32, resizable: bool) !Id {
            const raw = msg0(Id, objc.cls("NSWindow"), "alloc");
            var mask: c_ulong = 1 | 2 | 4;
            if (resizable) mask |= 8;
            const win = objc.msgSend(*const fn (Id, Sel, Rect, c_ulong, c_ulong, bool) callconv(.c) Id)(
                raw,
                objc.sel("initWithContentRect:styleMask:backing:defer:"),
                .{
                    .x = 240,
                    .y = 240,
                    .w = @floatFromInt(w),
                    .h = @floatFromInt(h),
                },
                mask,
                2,
                false,
            );
            if (@intFromPtr(win) == 0) return error.WindowCreationFailed;
            _ = msg1(void, win, "setTitle:", objc.nsString(title.ptr, title.len));
            _ = msg1(void, win, "setReleasedWhenClosed:", false);
            _ = msg1(void, win, "setDelegate:", msg0(Id, objc.cls("ZiltWindowDelegate"), "new"));
            _ = msg1(void, win, "makeKeyAndOrderFront:", @as(?Id, null));
            return win;
        }

        fn spawnWindowEntry(backend: *anyopaque, opts: ipc.WindowOptions) ?u32 {
            const self: *Self = @ptrCast(@alignCast(backend));
            if (!isMainThread()) {
                log.print("[macos] spawn_window off-main-thread → refused", .{});
                return null;
            }
            const win = self.newNSWindow(opts.title, opts.width, opts.height, opts.resizable) catch return null;
            const wv = self.makeWebView(opts.width, opts.height) catch return null;
            _ = msg1(void, win, "setContentView:", wv);
            self.loadUrlIn(wv, opts.url) catch {};
            const id = self.next_win_id;
            self.next_win_id += 1;
            self.wins.append(self.alloc, .{ .id = id, .win = win, .webview = wv }) catch return null;
            if (!opts.visible) _ = msg1(void, win, "orderOut:", @as(?Id, null));
            log.print("[macos] window created id={d} {d}x{d}", .{ id, opts.width, opts.height });
            return id;
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
                const cur_dark = self.isDarkAppearance();
                if (self.last_dark) |prev| {
                    if (prev != cur_dark) {
                        self.emitWindowEvent(0, "themeChanged", if (cur_dark)
                            "{\"appearance\":\"dark\"}"
                        else
                            "{\"appearance\":\"light\"}");
                    }
                }
                self.last_dark = cur_dark;
                if (self.page_loaded and !self.probe_sent) {
                    self.probe_sent = true;
                    self.evalScript(self.webview, probe_js);
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
                .{ .name = "windowDidMove:", .imp = imp(&onWindowDidMove), .types = "v@:@" },
                .{ .name = "windowDidResize:", .imp = imp(&onWindowDidResize), .types = "v@:@" },
                .{ .name = "windowDidBecomeKey:", .imp = imp(&onWindowDidBecomeKey), .types = "v@:@" },
                .{ .name = "windowDidResignKey:", .imp = imp(&onWindowDidResignKey), .types = "v@:@" },
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

        fn onWindowDidMove(_: Id, _: Sel, note: Id) callconv(.c) void {
            // 窗口 delegate 的 did*: 传的是 NSNotification，不是 NSWindow
            const window = msg0(?Id, note, "object") orelse return;
            inst.ev_moved += 1;
            const f = frameOf(window);
            const id = inst.windowIdOfWindow(window);
            const payload = std.fmt.allocPrint(inst.alloc, "{{\"id\":{d},\"x\":{d},\"y\":{d}}}", .{
                id,
                toI32(f.origin.x),
                toI32(screenHeight() - (f.origin.y + f.size.h)),
            }) catch return;
            defer inst.alloc.free(payload);
            inst.emitWindowEvent(id, "windowMoved", payload);
        }

        fn onWindowDidResize(_: Id, _: Sel, note: Id) callconv(.c) void {
            // 窗口 delegate 的 did*: 传的是 NSNotification，不是 NSWindow
            const window = msg0(?Id, note, "object") orelse return;
            inst.ev_resized += 1;
            const f = frameOf(window);
            const id = inst.windowIdOfWindow(window);
            const payload = std.fmt.allocPrint(inst.alloc, "{{\"id\":{d},\"width\":{d},\"height\":{d}}}", .{
                id,
                toI32(f.size.w),
                toI32(f.size.h),
            }) catch return;
            defer inst.alloc.free(payload);
            inst.emitWindowEvent(id, "windowResized", payload);
        }

        fn onWindowDidBecomeKey(_: Id, _: Sel, note: Id) callconv(.c) void {
            // 窗口 delegate 的 did*: 传的是 NSNotification，不是 NSWindow
            const window = msg0(?Id, note, "object") orelse return;
            inst.ev_focus += 1;
            const id = inst.windowIdOfWindow(window);
            const payload = std.fmt.allocPrint(inst.alloc, "{{\"id\":{d}}}", .{id}) catch return;
            defer inst.alloc.free(payload);
            inst.emitWindowEvent(id, "windowFocus", payload);
        }

        fn onWindowDidResignKey(_: Id, _: Sel, note: Id) callconv(.c) void {
            // 窗口 delegate 的 did*: 传的是 NSNotification，不是 NSWindow
            const window = msg0(?Id, note, "object") orelse return;
            inst.ev_blur += 1;
            const id = inst.windowIdOfWindow(window);
            const payload = std.fmt.allocPrint(inst.alloc, "{{\"id\":{d}}}", .{id}) catch return;
            defer inst.alloc.free(payload);
            inst.emitWindowEvent(id, "windowBlur", payload);
        }

        fn onWindowClose(_: Id, _: Sel, window: Id) callconv(.c) void {
            _ = inst.saveWindowState();
            const is_primary = window == inst.window;
            var idx: ?usize = null;
            for (inst.wins.items, 0..) |it, i| {
                if (it.win == window) idx = i;
            }
            if (idx) |i| _ = inst.wins.orderedRemove(i);
            const left = inst.wins.items.len + @as(usize, if (is_primary) 0 else 1);
            if (left == 0) {
                log.print("[macos] last window closing → terminate", .{});
                msg1(void, inst.app, "terminate:", @as(?Id, null));
            } else {
                log.print("[macos] window closed, {d} left", .{left});
            }
        }

        fn onNavigateFinish(_: Id, _: Sel, view: Id, _: Id) callconv(.c) void {
            if (view == inst.webview) {
                inst.page_loaded = true;
            } else {
                log.print("[macos] secondary window loaded id={d}", .{inst.windowIdOf(view)});
            }
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
            inst.handleRaw(inst.windowIdOf(msg0(?Id, message, "webView")), json);
        }

        // ------------------------------------------------------------------
        // 小工具
        // ------------------------------------------------------------------
        /// 主菜单：应用菜单 + Quit（NSMenuItem action terminate:）
        fn buildMenu(self: *Self) void {
            const app = msg0(Id, objc.cls("NSApplication"), "sharedApplication");
            const main_menu = objc.allocInit(objc.cls("NSMenu"));
            _ = msg1(void, main_menu, "setTitle:", objc.nsStringZ("MainMenu"));

            const app_item = objc.allocInit(objc.cls("NSMenuItem"));
            _ = msg1(void, main_menu, "addItem:", app_item);

            const sub = objc.allocInit(objc.cls("NSMenu"));
            _ = msg1(void, sub, "setTitle:", objc.nsString(config.title.ptr, config.title.len));

            const quit_item = objc.allocInit(objc.cls("NSMenuItem"));
            _ = msg1(void, quit_item, "setTitle:", objc.nsStringZ("Quit"));
            _ = objc.msgSend(*const fn (Id, Sel, ?Id) callconv(.c) void)(quit_item, objc.sel("setTarget:"), app);
            _ = objc.msgSend(*const fn (Id, Sel, Sel) callconv(.c) void)(quit_item, objc.sel("setAction:"), objc.sel("terminate:"));
            _ = msg1(void, sub, "addItem:", quit_item);

            _ = msg1(void, app_item, "setSubmenu:", sub);
            _ = msg1(void, app, "setMainMenu:", main_menu);
            _ = self;
            log.print("[macos] menu built", .{});
        }

        // ---- v0.4.7 桌面集成：剪贴板 / 原生对话框 ----

        fn clipboardWrite(self: *Self, text: []const u8) bool {
            _ = self;
            const pb = msg0(Id, objc.cls("NSPasteboard"), "generalPasteboard");
            _ = msg0(c_long, pb, "clearContents");
            return objc.msgSend(*const fn (Id, Sel, Id, Id) callconv(.c) bool)(
                pb,
                objc.sel("setString:forType:"),
                objc.nsString(text.ptr, text.len),
                objc.nsStringZ("public.utf8-plain-text"),
            );
        }

        fn clipboardRead(self: *Self, alloc: std.mem.Allocator) ?[]u8 {
            _ = self;
            const pb = msg0(Id, objc.cls("NSPasteboard"), "generalPasteboard");
            const str = objc.msgSend(*const fn (Id, Sel, Id) callconv(.c) ?Id)(
                pb, objc.sel("stringForType:"), objc.nsStringZ("public.utf8-plain-text"),
            ) orelse return null;
            const cs = msg0(?[*:0]const u8, str, "UTF8String") orelse return null;
            return alloc.dupe(u8, std.mem.span(cs)) catch null;
        }

        fn panelPath(alloc: std.mem.Allocator, panel: Id) !?[]u8 {
            const url = msg0(?Id, panel, "URL") orelse return null;
            const pz = msg0(?Id, url, "path") orelse return null;
            const cs = msg0(?[*:0]const u8, pz, "UTF8String") orelse return null;
            return try alloc.dupe(u8, std.mem.span(cs));
        }

        /// 原生对话框（NSAlert / NSOpenPanel / NSSavePanel）。会阻塞，冒烟不调用。
        fn runDialog(self: *Self, alloc: std.mem.Allocator, req: ipc.DialogRequest) anyerror!ipc.DialogResponse {
            _ = self;
            switch (req) {
                .message_box => |o| {
                    const alert = objc.allocInit(objc.cls("NSAlert"));
                    _ = msg1(void, alert, "setMessageText:", objc.nsString(o.text.ptr, o.text.len));
                    if (o.caption.len != 0) {
                        _ = msg1(void, alert, "setInformativeText:", objc.nsString(o.caption.ptr, o.caption.len));
                    }
                    const r: c_long = msg0(c_long, alert, "runModal");
                    const idx = r - 1000; // NSAlertFirstButtonReturn
                    return .{ .button = switch (idx) {
                        0 => .ok,
                        1 => .cancel,
                        2 => .yes,
                        else => .no,
                    } };
                },
                .save_file => |o| {
                    const panel = msg0(Id, objc.cls("NSSavePanel"), "savePanel");
                    if (o.title.len != 0) _ = msg1(void, panel, "setTitle:", objc.nsString(o.title.ptr, o.title.len));
                    if (o.default_name.len != 0) {
                        _ = msg1(void, panel, "setNameFieldStringValue:", objc.nsString(o.default_name.ptr, o.default_name.len));
                    }
                    if (msg0(c_long, panel, "runModal") != 1) return .{ .path = null };
                    return .{ .path = try panelPath(alloc, panel) };
                },
                .open_file => |o| {
                    const panel = msg0(Id, objc.cls("NSOpenPanel"), "openPanel");
                    _ = msg1(void, panel, "setCanChooseFiles:", true);
                    _ = msg1(void, panel, "setCanChooseDirectories:", false);
                    _ = msg1(void, panel, "setAllowsMultipleSelection:", false);
                    if (o.title.len != 0) _ = msg1(void, panel, "setTitle:", objc.nsString(o.title.ptr, o.title.len));
                    if (msg0(c_long, panel, "runModal") != 1) return .{ .path = null };
                    return .{ .path = try panelPath(alloc, panel) };
                },
                .pick_folder => |o| {
                    const panel = msg0(Id, objc.cls("NSOpenPanel"), "openPanel");
                    _ = msg1(void, panel, "setCanChooseFiles:", false);
                    _ = msg1(void, panel, "setCanChooseDirectories:", true);
                    if (o.title.len != 0) _ = msg1(void, panel, "setTitle:", objc.nsString(o.title.ptr, o.title.len));
                    if (msg0(c_long, panel, "runModal") != 1) return .{ .path = null };
                    return .{ .path = try panelPath(alloc, panel) };
                },
                .pick_files => |o| {
                    const panel = msg0(Id, objc.cls("NSOpenPanel"), "openPanel");
                    _ = msg1(void, panel, "setCanChooseFiles:", true);
                    _ = msg1(void, panel, "setAllowsMultipleSelection:", true);
                    if (o.title.len != 0) _ = msg1(void, panel, "setTitle:", objc.nsString(o.title.ptr, o.title.len));
                    if (msg0(c_long, panel, "runModal") != 1) return .{ .paths = null };
                    const urls = msg0(?Id, panel, "URLs") orelse return .{ .paths = null };
                    const n: c_ulong = msg0(c_ulong, urls, "count");
                    var list = try alloc.alloc([]u8, n);
                    var filled: usize = 0;
                    var i: c_ulong = 0;
                    while (i < n) : (i += 1) {
                        const u = msg1(Id, urls, "objectAtIndex:", i);
                        const pz = msg0(?Id, u, "path") orelse continue;
                        const cs = msg0(?[*:0]const u8, pz, "UTF8String") orelse continue;
                        list[filled] = try alloc.dupe(u8, std.mem.span(cs));
                        filled += 1;
                    }
                    if (filled == 0) return .{ .paths = null };
                    return .{ .paths = try alloc.realloc(list, filled) };
                },
                .pick_color, .pick_font => return error.DialogNotAvailable,
            }
        }

        fn clipWriteEntry(backend: *anyopaque, text: []const u8) bool {
            const self: *Self = @ptrCast(@alignCast(backend));
            return self.clipboardWrite(text);
        }

        fn clipReadEntry(backend: *anyopaque, alloc: std.mem.Allocator) ?[]u8 {
            const self: *Self = @ptrCast(@alignCast(backend));
            return self.clipboardRead(alloc);
        }

        fn dialogEntry(backend: *anyopaque, alloc: std.mem.Allocator, req: ipc.DialogRequest) anyerror!ipc.DialogResponse {
            const self: *Self = @ptrCast(@alignCast(backend));
            return self.runDialog(alloc, req);
        }

        fn emitEntry(backend: *anyopaque, window_id: u32, message_json: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(backend));
            self.deliver(window_id, message_json);
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
