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
const webview = @import("../../webview.zig");
const asset_routes = @import("../../asset_routes.zig");
const inflate = @import("../../inflate.zig");
const builtin_cmds = @import("../../builtin.zig");
const Config = @import("../../config.zig").Config;
const config_mod = @import("../../config.zig");
const objc = @import("objc.zig");
const keychain = @import("keychain.zig");
const store_mod = @import("../../store.zig");
const system_api = @import("../../system_api.zig");
const updater = @import("../../updater.zig");
const power = @import("../../power.zig");
const shell_mod = @import("../../shell.zig");
const sysinfo_mod = @import("../../sysinfo.zig");
const macos_sysinfo = @import("sysinfo.zig");
const builtin = @import("builtin");

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
        status_item: ?Id = null,
        pending_url: ?[]u8 = null,
        hotkey_ok: usize = 0,
        lock_fd: c_int = -1,
        inspectable: bool = false,
        downloads: std.ArrayListUnmanaged(DownloadRec) = .empty,
        download_seq: u64 = 0,
        smoke_ms: u32 = 0,
        /// v0.4.5：窗口控制探针结果（CI 硬断言）
        win_ops_ok: bool = false,
        assets: std.StringHashMapUnmanaged([]u8) = .empty,
        /// 跨线程 emit 队列（worker → 主线程 drain；WebKit 只允许主线程 eval）
        out_mutex: std.atomic.Mutex = .unlocked,
        out_queue: std.ArrayListUnmanaged(OutItem) = .empty,
        /// v0.5.6：store 子系统（appData/store.json + Keychain 加密；对齐 Linux v0.2.3/H3）
        storage_root: ?[]u8 = null,
        store: ?store_mod.Store = null,
        secret: ?keychain.KeychainLib = null,
        store_ok: bool = false,
        /// v0.5.7：更新器（复用 ed25519 核心 + .app 束整树 staging；对齐 Linux v0.4.x）
        updater_env: ?updater.Env = null,
        updater_url_override: ?[]u8 = null,
        updater_ok: bool = false,
        /// v0.5.8：系统事件观察者（NSWorkspace 电源/会话 + 分布式主题通知）
        system_observer: ?Id = null,
        workspace_notes: u32 = 0,
        theme_notes: u32 = 0,
        sys_probe_posted: bool = false,
        theme_logged: bool = false,

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
            // v0.5.8：单实例锁先于菜单/托盘/热键——第二实例不该先建一遍托盘再退出
            if (config.single_instance and !inst.acquireSingleLock()) {
                log.print("[macos] single instance: lock held, exiting", .{});
                return;
            }
            inst.buildMenu();
            inst.setupTray(inst.smoke_ms != 0);
            inst.captureDeepLink();
            _ = inst.registerHotkeys();
            try inst.createWindow();
            try inst.createWebView();
            inst.initStorage();
            inst.initUpdater();
            inst.installSystemObservers();
            inst.last_dark = inst.isDarkAppearance();

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
            return structMsg(NSRect, view, "bounds");
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

        // ------------------------------------------------------------------
        // v0.5.6 存储子系统（appData/store.json + Keychain 加密；对齐 Linux）
        // ------------------------------------------------------------------

        /// 应用数据根：~/Library/Application Support/<app_id>
        fn appDataRoot(self: *Self) ?[]u8 {
            const home_z = std.c.getenv("HOME") orelse return null;
            return std.fmt.allocPrint(self.alloc, "{s}/Library/Application Support/{s}", .{ std.mem.span(home_z), config.app_id }) catch null;
        }

        /// 递归建目录（NSFileManager withIntermediateDirectories:YES）
        fn makeDirPath(_: *Self, path: []const u8) void {
            const fm = msg0(Id, objc.cls("NSFileManager"), "defaultManager");
            _ = objc.msgSend(*const fn (Id, Sel, Id, bool, ?Id, ?Id) callconv(.c) bool)(
                fm,
                objc.sel("createDirectoryAtPath:withIntermediateDirectories:attributes:error:"),
                objc.nsString(path.ptr, path.len),
                true,
                null,
                null,
            );
        }

        /// 读文本文件（Foundation stringWithContentsOfFile，同 loadWindowState）
        fn readTextFile(self: *Self, path: []const u8) ?[]u8 {
            const ns = objc.msgSend(*const fn (Id, Sel, Id, c_ulong, ?Id) callconv(.c) ?Id)(
                objc.cls("NSString"),
                objc.sel("stringWithContentsOfFile:encoding:error:"),
                objc.nsString(path.ptr, path.len),
                4,
                null,
            ) orelse return null;
            const cs = msg0(?[*:0]const u8, ns, "UTF8String") orelse return null;
            return self.alloc.dupe(u8, std.mem.span(cs)) catch null;
        }

        /// 写文本文件（Foundation writeToFile:atomically:，同 persistStore）。
        fn writeTextFile(_: *Self, path: []const u8, data: []const u8) bool {
            return objc.msgSend(*const fn (Id, Sel, Id, bool, c_ulong, ?Id) callconv(.c) bool)(
                objc.nsString(data.ptr, data.len),
                objc.sel("writeToFile:atomically:encoding:error:"),
                objc.nsString(path.ptr, path.len),
                true,
                4,
                null,
            );
        }

        /// run() 早期一次：钥匙串开关 + storage_root + store.json 载入。
        fn initStorage(self: *Self) void {
            if (config.store_encrypted) {
                if (keychain.open()) |lib| {
                    self.secret = lib;
                    log.print("[store] keychain enabled (encrypted store)", .{});
                } else {
                    log.print("[store] store_encrypted=true but keychain unavailable -> plaintext fallback", .{});
                }
            }
            if (self.storage_root != null) return;
            const root = self.appDataRoot() orelse {
                log.print("[store] app data root unavailable — store disabled", .{});
                return;
            };
            self.makeDirPath(root);
            self.storage_root = root;
            var st = store_mod.Store.init(self.alloc);
            const store_path = std.fmt.allocPrint(self.alloc, "{s}/store.json", .{root}) catch null;
            if (store_path) |sp| {
                defer self.alloc.free(sp);
                if (self.readTextFile(sp)) |bytes| {
                    defer self.alloc.free(bytes);
                    st.fromJson(bytes) catch |err| log.print("[store] parse failed: {s}（从空表开始）", .{@errorName(err)});
                }
            }
            self.store = st;
            log.print("[store] ready ({d} keys) {s}/store.json", .{ st.count(), root });
        }

        /// 原子落盘（Foundation writeToFile:atomically:，同 saveWindowState）。
        fn persistStore(self: *Self) void {
            const root = self.storage_root orelse return;
            const st = if (self.store) |*v| v else return;
            const json = st.toJson(self.alloc) catch return;
            defer self.alloc.free(json);
            const path = std.fmt.allocPrint(self.alloc, "{s}/store.json", .{root}) catch return;
            defer self.alloc.free(path);
            const ok = objc.msgSend(*const fn (Id, Sel, Id, bool, c_ulong, ?Id) callconv(.c) bool)(
                objc.nsString(json.ptr, json.len),
                objc.sel("writeToFile:atomically:encoding:error:"),
                objc.nsString(path.ptr, path.len),
                true,
                4,
                null,
            );
            if (!ok) log.print("[store] persist failed", .{});
        }

        fn runStoreOp(self: *Self, op: system_api.StoreOp, alloc: std.mem.Allocator) !system_api.Result {
            const st = if (self.store) |*v| v else return error.StoreNotAvailable;
            switch (op) {
                .get => |key| {
                    const v = st.get(key) orelse return .{ .json = try alloc.dupe(u8, "null") };
                    // `secret:` 标记 → 值在钥匙串（Keychain lookup）
                    if (std.mem.startsWith(u8, v, keychain.marker)) {
                        const lib = self.secret orelse return error.KeyringUnavailable;
                        const got = keychain.lookupValue(&lib, alloc, config.app_id, key) orelse return error.KeyringUnavailable;
                        defer alloc.free(got);
                        return .{ .json = try std.json.Stringify.valueAlloc(alloc, got, .{}) };
                    }
                    return .{ .json = try std.json.Stringify.valueAlloc(alloc, v, .{}) };
                },
                .set => |kv| {
                    // 加密模式 + 钥匙串 → 值进钥匙串，store.json 落标记
                    if (self.secret) |*lib| {
                        keychain.storeValue(lib, config.app_id, kv.key, kv.value) catch |err| {
                            log.print("[store] keychain store failed: {s} -> plaintext fallback", .{@errorName(err)});
                            try st.set(kv.key, kv.value);
                            self.persistStore();
                            return .{ .ok = true };
                        };
                        try st.set(kv.key, keychain.marker);
                        self.persistStore();
                        return .{ .ok = true };
                    }
                    try st.set(kv.key, kv.value);
                    self.persistStore();
                    return .{ .ok = true };
                },
                .remove => |key| {
                    const removed = st.remove(key);
                    if (removed) {
                        if (self.secret) |*lib| _ = keychain.deleteValue(lib, config.app_id, key);
                        self.persistStore();
                    }
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

        /// system_fn：.store / .updater / .info / .cursor_position / .shell
        /// （其余 system_api 面随 v0.5.9+ 对等补，降级为 SystemNotAvailable）。
        fn systemEntry(backend_ptr: *anyopaque, window_id: u32, alloc: std.mem.Allocator, req: system_api.Request) anyerror!system_api.Result {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            switch (req) {
                .store => |op| return self.runStoreOp(op, alloc),
                .updater => |op| return self.runUpdaterOp(op, alloc),
                .info => |kind| return .{ .json = try self.collectSystemInfo(kind, alloc, window_id) },
                // AppKit 光标原点在左下 → 对外语义（左上原点）
                .cursor_position => {
                    const p = structMsg(Pt, objc.cls("NSEvent"), "mouseLocation");
                    return .{ .json = try std.fmt.allocPrint(alloc, "{{\"x\":{d},\"y\":{d}}}", .{
                        toI32(p.x), macos_sysinfo.flipY(screenHeight(), p.y, 0),
                    }) };
                },
                .shell => |target| {
                    try self.openShellTarget(target);
                    return .{ .ok = true };
                },
                else => return error.SystemNotAvailable,
            }
        }

        /// 冒烟探针：store set/get/remove 往返（CI 硬断言 [macos] store ok=true）。
        fn runStoreProbe(self: *Self) bool {
            const alloc = self.alloc;
            _ = self.runStoreOp(.{ .set = .{ .key = "zilt-smoke", .value = "macos-store" } }, alloc) catch {
                log.print("[macos] store ok=false", .{});
                return false;
            };
            const get_res = self.runStoreOp(.{ .get = "zilt-smoke" }, alloc) catch {
                log.print("[macos] store ok=false", .{});
                return false;
            };
            var ok = false;
            if (get_res == .json) {
                ok = std.mem.eql(u8, get_res.json, "\"macos-store\"");
                alloc.free(get_res.json);
            }
            _ = self.runStoreOp(.{ .remove = "zilt-smoke" }, alloc) catch {};
            log.print("[macos] store ok={s}", .{boolStr(ok)});
            return ok;
        }

        // ------------------------------------------------------------------
        // v0.5.8：系统信息（sysctl + NSScreen + IOKit）/ Shell / 系统事件观察者
        // ------------------------------------------------------------------

        /// NSProcessInfo operatingSystemVersion（24 字节 struct → x86_64 走 stret）
        const OsVersionRaw = extern struct { major: c_long, minor: c_long, patch: c_long };

        fn collectSystemInfo(self: *Self, kind: system_api.InfoKind, alloc: std.mem.Allocator, window_id: u32) ![]u8 {
            switch (kind) {
                .os => {
                    const info = try self.collectOsInfo(alloc);
                    defer macos_sysinfo.freeOsInfo(alloc, &info);
                    return sysinfo_mod.osToJson(alloc, info);
                },
                .monitors => {
                    const monitors = try self.collectMonitors(alloc, window_id);
                    defer alloc.free(monitors);
                    return sysinfo_mod.monitorsToJson(alloc, monitors);
                },
                .all => {
                    const info = try self.collectOsInfo(alloc);
                    defer macos_sysinfo.freeOsInfo(alloc, &info);
                    const os_json = try sysinfo_mod.osToJson(alloc, info);
                    defer alloc.free(os_json);
                    const monitors = try self.collectMonitors(alloc, window_id);
                    defer alloc.free(monitors);
                    const mons_json = try sysinfo_mod.monitorsToJson(alloc, monitors);
                    defer alloc.free(mons_json);
                    return std.fmt.allocPrint(alloc, "{{\"os\":{s},\"monitors\":{s}}}", .{ os_json, mons_json });
                },
                .gpu => {
                    const gpus = try self.collectGpus(alloc);
                    defer {
                        for (gpus) |g| macos_sysinfo.freeGpu(alloc, g);
                        alloc.free(gpus);
                    }
                    return sysinfo_mod.gpuToJson(alloc, gpus);
                },
            }
        }

        /// 版本取 kern.osproductversion（不经 10.16 兼容层压平）；没有该 sysctl 的旧系统
        /// 退回 NSProcessInfo + 内核主版本反推。build 恒 0：macOS 构建号是字母数字串（25B2083）。
        fn collectOsInfo(self: *Self, alloc: std.mem.Allocator) !sysinfo_mod.OsInfo {
            var v: macos_sysinfo.Version = .{ .major = 10, .minor = 16 };
            var known = false;
            var buf: [64]u8 = undefined;
            if (sysctlString("kern.osproductversion", &buf)) |product| {
                if (macos_sysinfo.parseDotted(product)) |parsed| {
                    v = parsed;
                    known = true;
                }
            }
            if (!known) {
                const raw = structMsg(OsVersionRaw, msg0(Id, objc.cls("NSProcessInfo"), "processInfo"), "operatingSystemVersion");
                v = macos_sysinfo.resolveOsVersion(
                    @intCast(@max(raw.major, 0)),
                    @intCast(@max(raw.minor, 0)),
                    @intCast(@max(raw.patch, 0)),
                    sysctlString("kern.osrelease", &buf),
                );
            }
            var vbuf: [32]u8 = undefined;
            const version = try alloc.dupe(u8, try macos_sysinfo.formatVersion(&vbuf, v));
            errdefer alloc.free(version);
            return .{
                .name = "macOS",
                .version = version,
                .arch = @tagName(builtin.cpu.arch),
                .locale = try preferredLocale(alloc),
                .theme = if (self.isDarkAppearance()) .dark else .light,
                .accent_color = accentColorArgb(),
            };
        }

        fn preferredLocale(alloc: std.mem.Allocator) ![]u8 {
            const langs = msg0(?Id, objc.cls("NSLocale"), "preferredLanguages") orelse return alloc.dupe(u8, "en-US");
            const first = msg0(?Id, langs, "firstObject") orelse return alloc.dupe(u8, "en-US");
            const c = msg0(?[*:0]const u8, first, "UTF8String") orelse return alloc.dupe(u8, "en-US");
            return macos_sysinfo.formatLocale(alloc, macos_sysinfo.parseLocale(std.mem.span(c)));
        }

        fn accentColorArgb() u32 {
            const c = msg0(?Id, objc.cls("NSColor"), "controlAccentColor") orelse return 0;
            const space = msg0(?Id, objc.cls("NSColorSpace"), "sRGBColorSpace") orelse return 0;
            const srgb = objc.msgSend(*const fn (Id, Sel, Id) callconv(.c) ?Id)(c, objc.sel("colorUsingColorSpace:"), space) orelse return 0;
            return macos_sysinfo.packArgb(
                1,
                msg0(f64, srgb, "redComponent"),
                msg0(f64, srgb, "greenComponent"),
                msg0(f64, srgb, "blueComponent"),
            );
        }

        /// NSScreen（单位：点，与窗口坐标一致）。AppKit 全局坐标左下原点 → 左上原点，
        /// 以主屏高度换算；screens[0] 即主屏（菜单栏所在）。rotation 恒 0（未接 CGDisplayRotation）。
        fn collectMonitors(self: *Self, alloc: std.mem.Allocator, window_id: u32) ![]sysinfo_mod.Monitor {
            const screens = msg0(?Id, objc.cls("NSScreen"), "screens") orelse return alloc.alloc(sysinfo_mod.Monitor, 0);
            const n: usize = @intCast(msg0(c_ulong, screens, "count"));
            const out = try alloc.alloc(sysinfo_mod.Monitor, n);
            errdefer alloc.free(out);
            const primary_h = screenHeight();
            var current: ?usize = null;
            if (self.targetWindow(window_id)) |win| {
                if (msg0(?Id, win, "screen")) |scr| {
                    const idx = msg1(c_long, screens, "indexOfObject:", scr);
                    if (idx >= 0) current = @intCast(idx);
                }
            }
            for (0..n) |i| {
                const scr = msg1(Id, screens, "objectAtIndex:", @as(c_long, @intCast(i)));
                const f = structMsg(NSRect, scr, "frame");
                const vf = structMsg(NSRect, scr, "visibleFrame");
                const scale = msg0(f64, scr, "backingScaleFactor");
                out[i] = .{
                    .index = @intCast(i),
                    .primary = i == 0,
                    .x = toI32(f.origin.x),
                    .y = macos_sysinfo.flipY(primary_h, f.origin.y, f.size.h),
                    .width = dimToU32(f.size.w),
                    .height = dimToU32(f.size.h),
                    .work_x = toI32(vf.origin.x),
                    .work_y = macos_sysinfo.flipY(primary_h, vf.origin.y, vf.size.h),
                    .work_width = dimToU32(vf.size.w),
                    .work_height = dimToU32(vf.size.h),
                    .dpi = macos_sysinfo.dpiFromScale(scale),
                    .scale = scale,
                    .current = current == i,
                };
            }
            return out;
        }

        /// GPU：IOKit IOAccelerator 服务（Apple Silicon 的 AGX* / Intel 机上的独显核显加速器节点）。
        /// 名字取 model（CFString 或 CFData），缺则用 IOClass；vendor-id 缺失且类名 AGX* 即 Apple；
        /// VRAM,totals 只在独显上有 → 统一内存的 Apple Silicon 为 0。没有加速器节点 → 空数组。
        fn collectGpus(self: *Self, alloc: std.mem.Allocator) ![]sysinfo_mod.GpuInfo {
            _ = self;
            var list: std.ArrayListUnmanaged(sysinfo_mod.GpuInfo) = .empty;
            errdefer {
                for (list.items) |g| macos_sysinfo.freeGpu(alloc, g);
                list.deinit(alloc);
            }
            var it: c_uint = 0;
            const matching = IOServiceMatching("IOAccelerator") orelse return list.toOwnedSlice(alloc);
            if (IOServiceGetMatchingServices(0, matching, &it) != 0) return list.toOwnedSlice(alloc);
            defer _ = IOObjectRelease(it);
            while (true) {
                const entry = IOIteratorNext(it);
                if (entry == 0) break;
                defer _ = IOObjectRelease(entry);

                var cbuf: [256]u8 = undefined;
                var mbuf: [256]u8 = undefined;
                var class_name: []const u8 = "";
                var props = macos_sysinfo.GpuProps{};
                if (ioProperty(entry, "IOClass")) |cf| {
                    defer CFRelease(cf);
                    if (cfToBuf(cf, &cbuf)) |cn| class_name = cn;
                }
                if (ioProperty(entry, "model")) |cf| {
                    defer CFRelease(cf);
                    if (cfToBuf(cf, &mbuf)) |m| props.model = m;
                }
                if (ioProperty(entry, "vendor-id")) |cf| {
                    defer CFRelease(cf);
                    props.vendor_id = cfDataU16Le(cf);
                } else if (std.mem.startsWith(u8, class_name, "AGX")) {
                    props.vendor_id = 0x106b;
                }
                if (props.model == null and class_name.len > 0) props.model = class_name;
                if (ioProperty(entry, "VRAM,totals")) |cf| {
                    defer CFRelease(cf);
                    if (cfDataBytes(cf)) |bytes| {
                        if (bytes.len >= 4) props.vram_mb = std.mem.readInt(u32, bytes[0..4], .little) / 1024;
                    }
                }
                const g = try macos_sysinfo.gpuInfo(alloc, props);
                list.append(alloc, g) catch |e| {
                    macos_sysinfo.freeGpu(alloc, g);
                    return e;
                };
                log.print("[macos] gpu[{d}] class={s} vendor=0x{x:0>4} vram={d}MB name={s}", .{
                    list.items.len - 1, class_name, props.vendor_id orelse 0, g.vram_mb, g.name,
                });
            }
            return list.toOwnedSlice(alloc);
        }

        /// NSWorkspace：url（无 scheme 补 https://）/ path（file URL）/ reveal（Finder 选中）。
        fn openShellTarget(self: *Self, target: shell_mod.Target) !void {
            const ws = msg0(Id, objc.cls("NSWorkspace"), "sharedWorkspace");
            switch (target) {
                .url => |u| {
                    const norm = macos_sysinfo.normalizeUrlTarget(self.alloc, u) catch return error.ShellExecuteFailed;
                    defer self.alloc.free(norm);
                    const url = msg1(?Id, objc.cls("NSURL"), "URLWithString:", objc.nsString(norm.ptr, norm.len)) orelse
                        return error.ShellExecuteFailed;
                    if (!objc.msgSend(*const fn (Id, Sel, Id) callconv(.c) bool)(ws, objc.sel("openURL:"), url))
                        return error.ShellExecuteFailed;
                    log.print("[shell] openUrl -> NSWorkspace ({s})", .{norm});
                },
                .path => |p| {
                    const url = msg1(Id, objc.cls("NSURL"), "fileURLWithPath:", objc.nsString(p.ptr, p.len));
                    if (!objc.msgSend(*const fn (Id, Sel, Id) callconv(.c) bool)(ws, objc.sel("openURL:"), url))
                        return error.ShellExecuteFailed;
                    log.print("[shell] openPath -> NSWorkspace ({s})", .{p});
                },
                .reveal => |p| {
                    const url = msg1(Id, objc.cls("NSURL"), "fileURLWithPath:", objc.nsString(p.ptr, p.len));
                    const arr = objc.msgSend(*const fn (Class, Sel, Id) callconv(.c) Id)(objc.cls("NSArray"), objc.sel("arrayWithObject:"), url);
                    _ = objc.msgSend(*const fn (Id, Sel, Id) callconv(.c) void)(ws, objc.sel("activateFileViewerSelectingURLs:"), arr);
                    log.print("[shell] reveal -> Finder ({s})", .{p});
                },
            }
        }

        /// 订阅 NSWorkspace 通知中心（名称传 nil = 全收，映射不到统一事件的直接忽略）
        /// 与分布式主题通知。正常模式下系统明暗切换由此发 themeChanged。
        fn installSystemObservers(self: *Self) void {
            const obs = msg0(Id, objc.cls("ZiltSystemObserver"), "new");
            self.system_observer = obs;
            const ws = msg0(Id, objc.cls("NSWorkspace"), "sharedWorkspace");
            const nc = msg0(Id, ws, "notificationCenter");
            objc.msgSend(*const fn (Id, Sel, Id, Sel, ?Id, ?Id) callconv(.c) void)(
                nc,
                objc.sel("addObserver:selector:name:object:"),
                obs,
                objc.sel("onWorkspaceNote:"),
                @as(?Id, null),
                @as(?Id, null),
            );
            const dnc = msg0(Id, objc.cls("NSDistributedNotificationCenter"), "defaultCenter");
            objc.msgSend(*const fn (Id, Sel, Id, Sel, ?Id, ?Id) callconv(.c) void)(
                dnc,
                objc.sel("addObserver:selector:name:object:"),
                obs,
                objc.sel("onThemeNote:"),
                objc.nsStringZ("AppleInterfaceThemeChangedNotification"),
                @as(?Id, null),
            );
        }

        /// 冒烟探针：.info 四种 + .cursor_position + Shell 解析 + 系统事件观察者接线。
        /// CI 无法真的睡眠/切系统外观：power 只断言「NSWorkspace 通知到达观察者」，
        /// theme observer 断言分布式通知回路（smokeLoop 里落 [macos] theme observer ok=），
        /// Shell 只断言能解析出默认处理程序——不在 runner 上真的打开 URL。
        fn runSystemProbe(self: *Self) bool {
            const alloc = self.alloc;
            var ok = true;
            const needs = struct {
                fn has(j: []const u8, needle: []const u8) bool {
                    return std.mem.indexOf(u8, j, needle) != null;
                }
            };
            if (self.collectSystemInfo(.os, alloc, 0)) |j| {
                defer alloc.free(j);
                ok = ok and needs.has(j, "\"name\":\"macOS\"") and !needs.has(j, "\"version\":\"0.0.0\"") and !needs.has(j, "\"locale\":\"\"");
                log.print("[macos] sysinfo os={s}", .{j});
            } else |_| ok = false;
            if (self.collectSystemInfo(.monitors, alloc, 0)) |j| {
                defer alloc.free(j);
                ok = ok and needs.has(j, "\"primary\":true") and !needs.has(j, "\"width\":0,") and !needs.has(j, "\"workHeight\":0");
                log.print("[macos] sysinfo monitors={s}", .{j});
            } else |_| ok = false;
            if (self.collectSystemInfo(.gpu, alloc, 0)) |j| {
                defer alloc.free(j);
                ok = ok and std.mem.startsWith(u8, j, "[");
                log.print("[macos] sysinfo gpu={s}", .{j});
            } else |_| ok = false;
            if (self.collectSystemInfo(.all, alloc, 0)) |j| {
                defer alloc.free(j);
                ok = ok and needs.has(j, "\"os\":") and needs.has(j, "\"monitors\":");
            } else |_| ok = false;
            log.print("[macos] sysinfo ok={s}", .{boolStr(ok)});

            var cursor_ok = false;
            if (systemEntry(@ptrCast(self), 0, alloc, .{ .cursor_position = {} })) |res| {
                defer alloc.free(res.json);
                cursor_ok = needs.has(res.json, "\"x\":") and needs.has(res.json, "\"y\":");
                log.print("[macos] cursor {s}", .{res.json});
            } else |_| {}
            log.print("[macos] cursor ok={s}", .{boolStr(cursor_ok)});

            const ws = msg0(Id, objc.cls("NSWorkspace"), "sharedWorkspace");
            const probe_url = msg1(?Id, objc.cls("NSURL"), "URLWithString:", objc.nsStringZ("https://example.com"));
            const shell_ok = msg1(?Id, ws, "URLForApplicationToOpenURL:", probe_url) != null;
            log.print("[macos] shell ok={s} wiring-only", .{boolStr(shell_ok)});

            const nc = msg0(Id, ws, "notificationCenter");
            objc.msgSend(*const fn (Id, Sel, Id, ?Id) callconv(.c) void)(
                nc,
                objc.sel("postNotificationName:object:"),
                objc.nsStringZ("ZiltSmokeWorkspaceNote"),
                @as(?Id, null),
            );
            const dnc = msg0(Id, objc.cls("NSDistributedNotificationCenter"), "defaultCenter");
            objc.msgSend(*const fn (Id, Sel, Id, ?Id, ?Id, bool) callconv(.c) void)(
                dnc,
                objc.sel("postNotificationName:object:userInfo:deliverImmediately:"),
                objc.nsStringZ("AppleInterfaceThemeChangedNotification"),
                @as(?Id, null),
                @as(?Id, null),
                true,
            );
            self.sys_probe_posted = true;
            log.print("[macos] power ok={s} wiring-only", .{boolStr(self.workspace_notes >= 1)});

            const label = msg0(?Id, self.webview, "accessibilityLabel");
            var acc_ok = false;
            if (label) |l| {
                if (msg0(?[*:0]const u8, l, "UTF8String")) |c| acc_ok = std.mem.eql(u8, std.mem.span(c), config.title);
            }
            log.print("[macos] accessibility ok={s} label={s}", .{ boolStr(acc_ok), config.title });

            return ok and cursor_ok and shell_ok and self.workspace_notes >= 1 and acc_ok;
        }

        // ------------------------------------------------------------------
        // v0.5.7：更新器（复用 ed25519 核心；.app 束整树 staging + 裸二进制回退）
        // ------------------------------------------------------------------

        /// 当前 exe 路径（0.17 executablePathAlloc 走 Io；per-call Threaded）。
        fn currentExePath(_: *Self, alloc: std.mem.Allocator) ![]u8 {
            var threaded: std.Io.Threaded = .init(alloc, .{});
            defer threaded.deinit();
            return std.process.executablePathAlloc(threaded.io(), alloc);
        }

        /// 是否已有暂存备份（.zilt-old）：.app 束查束根备份，裸二进制查 exe 备份。
        fn hasStagedBackup(self: *Self, exe_path: []const u8) bool {
            var threaded: std.Io.Threaded = .init(self.alloc, .{});
            defer threaded.deinit();
            const target = updater.appBundleRoot(exe_path) orelse exe_path;
            const old = std.fmt.allocPrint(self.alloc, "{s}.zilt-old", .{target}) catch return false;
            defer self.alloc.free(old);
            std.Io.Dir.cwd().access(threaded.io(), old, .{}) catch return false;
            return true;
        }

        /// 组装 updater.Env（镜像 Linux buildUpdaterEnv；pk/url 支持 env 覆盖）。
        fn buildUpdaterEnv(self: *Self, uc: Config.Update) !updater.Env {
            var pk: [32]u8 = undefined;
            var pk_from_env = false;
            if (std.c.getenv("ZILT_UPDATE_PK")) |hex| {
                const h = std.mem.span(hex);
                if (h.len == 64) {
                    _ = std.fmt.hexToBytes(&pk, h) catch return error.InvalidPublicKey;
                    pk_from_env = true;
                }
            }
            if (!pk_from_env) {
                if (uc.public_key_hex.len != 64) return error.InvalidPublicKey;
                _ = std.fmt.hexToBytes(&pk, uc.public_key_hex) catch return error.InvalidPublicKey;
            }
            var manifest_url: []const u8 = uc.manifest_url;
            if (std.c.getenv("ZILT_UPDATE_URL")) |u| {
                if (self.alloc.dupe(u8, std.mem.span(u))) |owned| {
                    self.updater_url_override = owned;
                    manifest_url = owned;
                } else |_| {}
            }
            const channel: updater.UpdateChannel = if (std.mem.eql(u8, uc.channel, "beta")) .beta else .stable;
            var skipped_version: ?[]const u8 = null;
            if (self.storage_root) |root| {
                const skip_path = std.fmt.allocPrint(self.alloc, "{s}/skipped.json", .{root}) catch null;
                if (skip_path) |sp| {
                    defer self.alloc.free(sp);
                    if (self.readTextFile(sp)) |body| {
                        defer self.alloc.free(body);
                        if (updater.parseSkipped(self.alloc, body)) |sk| {
                            skipped_version = self.alloc.dupe(u8, sk.version) catch null;
                        }
                    }
                }
            }
            return .{
                .channel = channel,
                .manifest_url = manifest_url,
                .public_key = pk,
                .current_version = uc.current_version,
                .exe_path = try self.currentExePath(self.alloc),
                .github_repo = uc.github_repo,
                .skipped_version = skipped_version,
                .exe_name = uc.exe_name,
                .fetcher = .{ .ctx = @ptrCast(self), .fetchFn = updaterFetchMacos },
            };
        }

        /// run() 早期一次：config.update 存在则组装 env（缺失 = 更新器未配置）。
        fn initUpdater(self: *Self) void {
            const uc = config.update orelse {
                log.print("[updater] not configured", .{});
                return;
            };
            self.updater_env = self.buildUpdaterEnv(uc) catch |err| {
                log.print("[updater] env build failed: {s}", .{@errorName(err)});
                return;
            };
            log.print("[updater] ready (channel={s})", .{@tagName(self.updater_env.?.channel)});
        }

        fn runUpdaterOp(self: *Self, op: system_api.UpdaterOp, alloc: std.mem.Allocator) !system_api.Result {
            switch (op) {
                .info => {
                    const uenv = self.updater_env orelse return .{ .json = try alloc.dupe(u8, "{\"configured\":false}") };
                    const exe_path = try self.currentExePath(alloc);
                    defer alloc.free(exe_path);
                    const restart_required = self.hasStagedBackup(exe_path);
                    const url_json = try std.json.Stringify.valueAlloc(alloc, uenv.manifest_url, .{});
                    defer alloc.free(url_json);
                    const ver_json = try std.json.Stringify.valueAlloc(alloc, uenv.current_version, .{});
                    defer alloc.free(ver_json);
                    return .{ .json = try std.fmt.allocPrint(alloc,
                        "{{\"configured\":true,\"manifest_url\":{s},\"current_version\":{s},\"channel\":\"{s}\",\"restart_required\":{s}}}",
                        .{ url_json, ver_json, @tagName(uenv.channel), if (restart_required) "true" else "false" }) };
                },
                .check => {
                    if (self.updater_env == null) return .{ .ok = false };
                    const t = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, updaterFlow, .{self}) catch |err| {
                        log.print("[updater] manual check spawn failed: {s}", .{@errorName(err)});
                        return .{ .ok = false };
                    };
                    t.detach();
                    log.print("[updater] manual check started (from JS)", .{});
                    return .{ .ok = true };
                },
                .skip => |version| {
                    const root = self.storage_root orelse return .{ .ok = false };
                    const path = std.fmt.allocPrint(alloc, "{s}/skipped.json", .{root}) catch return .{ .ok = false };
                    defer alloc.free(path);
                    const body = try std.fmt.allocPrint(alloc, "{{\"version\":\"{s}\"}}", .{version});
                    defer alloc.free(body);
                    if (!self.writeTextFile(path, body)) {
                        log.print("[updater] skipped.json write failed", .{});
                        return .{ .ok = false };
                    }
                    log.print("[updater] version {s} skipped", .{version});
                    if (self.updater_env) |*uenv| uenv.skipped_version = self.alloc.dupe(u8, version) catch null;
                    return .{ .ok = true };
                },
            }
        }

        /// 后台更新流：检查 → 下载验签 → staging（.app 束整树替换 / 裸二进制单文件）。
        /// v0.5.7 仅全量下载（差分/补丁、auto_restart 见 ADR 诚实缺口）。
        fn updaterFlow(self: *Self) void {
            const uenv = self.updater_env orelse return;
            const ctx = self.context(self.alloc, 0);
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();

            const m = updater.checkForUpdateEnv(arena.allocator(), uenv) catch |err| {
                log.print("[updater] check failed: {s}", .{@errorName(err)});
                ctx.emit("updaterFailed", .{ .stage = "check", .err = @errorName(err) });
                return;
            } orelse {
                log.print("[updater] up to date ({s})", .{uenv.current_version});
                return;
            };
            log.print("[updater] update available: {s} (current {s})", .{ m.version, uenv.current_version });
            ctx.emit("updateInfo", .{ .version = m.version, .notes = m.notes });

            const artifact = updater.downloadAndVerify(self.alloc, uenv.fetcher, m, uenv.public_key) catch |err| {
                log.print("[updater] download/verify failed: {s}", .{@errorName(err)});
                ctx.emit("updaterFailed", .{ .stage = "download", .err = @errorName(err) });
                return;
            };
            defer self.alloc.free(artifact);
            log.print("[updater] artifact verified ({d} bytes, sha256+ed25519)", .{artifact.len});

            var threaded: std.Io.Threaded = .init(self.alloc, .{});
            defer threaded.deinit();
            const io = threaded.io();

            if (updater.appBundleRoot(uenv.exe_path)) |bundle| {
                // .app 束：解压新束到同级临时目录 → 整束原子替换（codesign 封整束）
                const tmp = std.fmt.allocPrint(self.alloc, "{s}.zilt-new", .{bundle}) catch {
                    ctx.emit("updaterFailed", .{ .stage = "stage", .err = "OutOfMemory" });
                    return;
                };
                defer self.alloc.free(tmp);
                const cwd = std.Io.Dir.cwd();
                cwd.deleteTree(io, tmp) catch {};
                defer cwd.deleteTree(io, tmp) catch {};
                updater.extractZipTree(io, self.alloc, artifact, tmp) catch |err| {
                    log.print("[updater] extract failed: {s}", .{@errorName(err)});
                    ctx.emit("updaterFailed", .{ .stage = "stage", .err = @errorName(err) });
                    return;
                };
                const new_app = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ tmp, std.fs.path.basename(bundle) }) catch {
                    ctx.emit("updaterFailed", .{ .stage = "stage", .err = "OutOfMemory" });
                    return;
                };
                defer self.alloc.free(new_app);
                updater.stageAppBundle(io, self.alloc, bundle, new_app) catch |err| {
                    log.print("[updater] bundle stage failed: {s}", .{@errorName(err)});
                    ctx.emit("updaterFailed", .{ .stage = "stage", .err = @errorName(err) });
                    return;
                };
            } else {
                updater.stageUpdate(self.alloc, uenv.exe_path, uenv.exe_name, artifact) catch |err| {
                    log.print("[updater] stage failed: {s}", .{@errorName(err)});
                    ctx.emit("updaterFailed", .{ .stage = "stage", .err = @errorName(err) });
                    return;
                };
            }
            log.print("[updater] staged ✓ {s} — restart to apply", .{m.version});
            ctx.emit("updateStaged", .{ .version = m.version });
        }

        /// 冒烟探针：.updater info 往返（CI 硬断言 [macos] updater ok=true）。
        /// 冒烟无 update 配置 → configured:false；验证 systemEntry→runUpdaterOp→JSON 通路。
        fn runUpdaterProbe(self: *Self) bool {
            const alloc = self.alloc;
            const res = self.runUpdaterOp(.info, alloc) catch {
                log.print("[macos] updater ok=false", .{});
                return false;
            };
            var ok = false;
            if (res == .json) {
                ok = std.mem.indexOf(u8, res.json, "\"configured\":") != null;
                alloc.free(res.json);
            }
            log.print("[macos] updater ok={s}", .{boolStr(ok)});
            return ok;
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
            const sub_cls = objc.cls("ZiltWebView");
            const wv_cls = if (@intFromPtr(sub_cls) != 0) sub_cls else objc.cls("WKWebView");
            const wv_raw = msg0(Id, wv_cls, "alloc");
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
            // Accessibility：VoiceOver 把 WebView 念作窗口标题而不是"web content"
            _ = msg1(void, wv, "setAccessibilityLabel:", objc.nsString(config.title.ptr, config.title.len));
            _ = msg1(void, wv, "setNavigationDelegate:", msg0(Id, objc.cls("ZiltNavigationDelegate"), "new"));
            _ = msg1(void, wv, "setUIDelegate:", msg0(Id, objc.cls("ZiltUIDelegate"), "new"));
            const drag_types = objc.msgSend(*const fn (Class, Sel, Id) callconv(.c) Id)(objc.cls("NSArray"), objc.sel("arrayWithObject:"), objc.nsStringZ("public.file-url"));
            _ = objc.msgSend(*const fn (Id, Sel, Id) callconv(.c) void)(wv, objc.sel("registerForDraggedTypes:"), drag_types);
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

        fn webviewRequestEntry(backend: *anyopaque, window_id: u32, alloc: std.mem.Allocator, req: webview.Request) anyerror![]u8 {
            const self: *Self = @ptrCast(@alignCast(backend));
            return self.webviewRequest(window_id, alloc, req);
        }

        /// v0.4.8：WKWebView 行为面。只实现真正落地的能力，其余返回明确的 NotAvailable，
        /// 不伪装成功（下载/媒体权限需 block 回调，随 v0.4.8 后续批次补）。
        fn webviewRequest(self: *Self, window_id: u32, alloc: std.mem.Allocator, req: webview.Request) anyerror![]u8 {
            const wv = self.webviewFor(window_id);
            if (@intFromPtr(wv) == 0) return error.WebViewNotAvailable;
            switch (req) {
                .reload => {
                    _ = objc.msgSend(*const fn (Id, Sel) callconv(.c) void)(wv, objc.sel("reload"));
                    return alloc.dupe(u8, "{}");
                },
                .stop => {
                    _ = objc.msgSend(*const fn (Id, Sel) callconv(.c) void)(wv, objc.sel("stopLoading"));
                    return alloc.dupe(u8, "{}");
                },
                .zoom => |z| {
                    if (!std.math.isFinite(z) or z <= 0.0) return error.InvalidZoomFactor;
                    _ = objc.msgSend(*const fn (Id, Sel, f64) callconv(.c) void)(wv, objc.sel("setPageZoom:"), z);
                    return alloc.dupe(u8, "{}");
                },
                .get_zoom => {
                    const z: f64 = objc.msgSend(*const fn (Id, Sel) callconv(.c) f64)(wv, objc.sel("pageZoom"));
                    return std.fmt.allocPrint(alloc, "{{\"zoom\":{d}}}", .{z});
                },
                .back => {
                    _ = objc.msgSend(*const fn (Id, Sel) callconv(.c) void)(wv, objc.sel("goBack"));
                    return alloc.dupe(u8, "{}");
                },
                .forward => {
                    _ = objc.msgSend(*const fn (Id, Sel) callconv(.c) void)(wv, objc.sel("goForward"));
                    return alloc.dupe(u8, "{}");
                },
                .load_html => |html| {
                    _ = objc.msgSend(*const fn (Id, Sel, Id, ?Id) callconv(.c) void)(wv, objc.sel("loadHTMLString:baseURL:"), objc.nsString(html.ptr, html.len), @as(?Id, null));
                    return alloc.dupe(u8, "{}");
                },
                .set_user_agent => |ua| {
                    const s_ua: ?Id = if (ua.len == 0) null else objc.nsString(ua.ptr, ua.len);
                    _ = objc.msgSend(*const fn (Id, Sel, ?Id) callconv(.c) void)(wv, objc.sel("setCustomUserAgent:"), s_ua);
                    return alloc.dupe(u8, "{}");
                },
                .devtools => |op| switch (op) {
                    .open => {
                        _ = objc.msgSend(*const fn (Id, Sel, bool) callconv(.c) void)(wv, objc.sel("setInspectable:"), true);
                        self.inspectable = true;
                        return alloc.dupe(u8, "{}");
                    },
                    .close => {
                        _ = objc.msgSend(*const fn (Id, Sel, bool) callconv(.c) void)(wv, objc.sel("setInspectable:"), false);
                        self.inspectable = false;
                        return alloc.dupe(u8, "{}");
                    },
                    .state => return std.fmt.allocPrint(alloc, "{{\"inspectable\":{s}}}", .{if (self.inspectable) "true" else "false"}),
                },
                .print => |kind| {
                    const info = msg0(Id, objc.cls("NSPrintInfo"), "sharedPrintInfo");
                    const op = objc.msgSend(*const fn (Id, Sel, Id) callconv(.c) ?Id)(wv, objc.sel("printOperationWithPrintInfo:"), info) orelse return error.PrintUnavailable;
                    if (kind == .system) {
                        _ = objc.msgSend(*const fn (Id, Sel) callconv(.c) bool)(op, objc.sel("runOperation"));
                    }
                    return alloc.dupe(u8, "{}");
                },
                .print_to_pdf => |p| {
                    // 不走 NSPrintOperation（保存任务在无交互 session 下会阻塞冒烟），
                    // 改用 dataWithPDFInsideRect: 同步导出当前视图矩形的 PDF。
                    const fr = frameOf(wv);
                    const rect = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = fr.size.w, .h = fr.size.h } };
                    const data = objc.msgSend(*const fn (Id, Sel, NSRect) callconv(.c) ?Id)(wv, objc.sel("dataWithPDFInsideRect:"), rect) orelse return error.PdfNotSupported;
                    const wrote = objc.msgSend(*const fn (Id, Sel, Id, bool) callconv(.c) bool)(data, objc.sel("writeToFile:atomically:"), objc.nsString(p.path.ptr, p.path.len), true);
                    var payload: [96]u8 = undefined;
                    if (std.fmt.bufPrint(&payload, "{{\"rid\":{d},\"ok\":{s}}}", .{ p.rid, boolStr(wrote) })) |js| {
                        self.emitWindowEvent(window_id, "webviewPdf", js);
                    } else |_| {}
                    return alloc.dupe(u8, "{}");
                },
                .cancel_download => |did| {
                    for (self.downloads.items) |rec| {
                        if (rec.id == did) {
                            _ = objc.msgSend(*const fn (Id, Sel, ?Id) callconv(.c) void)(rec.dl, objc.sel("cancel:"), @as(?Id, null));
                            return alloc.dupe(u8, "{}");
                        }
                    }
                    return error.DownloadNotFound;
                },
                else => return error.WebViewNotAvailable,
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
                .notify_fn = notifyEntry,
                .webview_request_fn = webviewRequestEntry,
                .system_fn = systemEntry,
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
            return structMsg(NSRect, win, "frame");
        }

        fn styleMaskOf(win: Id) c_ulong {
            return objc.msgSend(*const fn (Id, Sel) callconv(.c) c_ulong)(win, objc.sel("styleMask"));
        }

        fn contentSize(win: Id) Size {
            const cv = msg0(?Id, win, "contentView") orelse return .{ .w = 0, .h = 0 };
            return structMsg(NSRect, cv, "bounds").size;
        }

        /// 主屏高度（Cocoa 原点在左下）——把对外「左上原点」语义换算过去
        fn screenHeight() f64 {
            const scr = msg0(?Id, objc.cls("NSScreen"), "mainScreen") orelse return 0;
            return structMsg(NSRect, scr, "frame").size.h;
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
                    const item0 = objc.msgSend(*const fn (Id, Sel, c_ulong) callconv(.c) Id)(mm, objc.sel("itemAtIndex:"), 0);
                    if (msg0(?Id, item0, "submenu")) |sm| {
                        const n = msg0(c_ulong, sm, "numberOfItems");
                        if (n >= 1) {
                            const qi = objc.msgSend(*const fn (Id, Sel, c_ulong) callconv(.c) Id)(sm, objc.sel("itemAtIndex:"), n - 1);
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

            var tray_action_ok = false;
            if (self.status_item) |si| {
                if (msg0(?Id, si, "menu")) |tm| {
                    const cnt: c_ulong = msg0(c_ulong, tm, "numberOfItems");
                    if (cnt >= 1) {
                        const it0 = objc.msgSend(*const fn (Id, Sel, c_ulong) callconv(.c) Id)(tm, objc.sel("itemAtIndex:"), 0);
                        tray_action_ok = msg0(?*anyopaque, it0, "action") != null;
                    }
                }
            }
            log.print("[macos] tray action ok={s}", .{boolStr(tray_action_ok)});

            const tray_ok = self.status_item != null;
            log.print("[macos] tray ok={s}", .{boolStr(tray_ok)});

            const bundle0 = msg0(Id, objc.cls("NSBundle"), "mainBundle");
            const notify_ok = msg0(?Id, bundle0, "bundleIdentifier") == null;
            log.print("[macos] notify ok={s} guarded=no-bundle", .{boolStr(notify_ok)});

            var urlbuf: [96]u8 = undefined;
            const sch2 = if (config.deep_link) |d| d.scheme else "zilt";
            const sample = std.fmt.bufPrint(&urlbuf, "{s}://probe/x", .{sch2}) catch "";
            const deeplink_ok = self.matchUrl(sample) and !self.matchUrl("https://example.com");
            log.print("[macos] deeplink ok={s}", .{boolStr(deeplink_ok)});

            // BSD flock 是进程级锁，同进程再次 flock 会成功，故只断言“锁已拿住”
            const single_ok = !config.single_instance or self.lock_fd >= 0;
            log.print("[macos] single ok={s}", .{boolStr(single_ok)});

            var hk_out: ?*anyopaque = null;
            const hk_st = RegisterEventHotKey(122, 0x1000 | 0x0800, .{ .signature = 0x5a4c5448, .id = 99 }, GetApplicationEventTarget(), 0, &hk_out);
            const hotkey_ok = hk_st == 0;
            log.print("[macos] hotkey ok={s} status={d}", .{ boolStr(hotkey_ok), hk_st });

            if (self.pending_url) |u| {
                var dl: [512]u8 = undefined;
                if (std.fmt.bufPrint(&dl, "{{\"url\":\"{s}\"}}", .{u})) |j| {
                    self.emitWindowEvent(0, "deeplink", j);
                } else |_| {}
            }

            // ---- v0.4.8 WebView 深度 ----
            var wv_zoom_ok = false;
            if (self.webviewRequest(0, self.alloc, .{ .zoom = 1.25 })) |r| {
                self.alloc.free(r);
                if (self.webviewRequest(0, self.alloc, .{ .get_zoom = {} })) |js| {
                    wv_zoom_ok = std.mem.indexOf(u8, js, "1.25") != null;
                    self.alloc.free(js);
                } else |_| {}
            } else |_| {}
            if (self.webviewRequest(0, self.alloc, .{ .zoom = 1.0 })) |r| self.alloc.free(r) else |_| {}
            log.print("[macos] webview zoom ok={s}", .{boolStr(wv_zoom_ok)});

            var dv_ok = false;
            if (self.webviewRequest(0, self.alloc, .{ .devtools = .open })) |r| {
                self.alloc.free(r);
                dv_ok = self.inspectable;
                if (self.webviewRequest(0, self.alloc, .{ .devtools = .close })) |r2| self.alloc.free(r2) else |_| {}
            } else |_| {}
            log.print("[macos] webview devtools ok={s}", .{boolStr(dv_ok)});

            var print_ok = false;
            if (self.webviewRequest(0, self.alloc, .{ .print = .browser })) |r| {
                self.alloc.free(r);
                print_ok = true;
            } else |_| {}
            log.print("[macos] webview print ok={s} wiring-only", .{boolStr(print_ok)});

            var pdf_ok = false;
            var pbuf: [512]u8 = undefined;
            if (std.c.getenv("TMPDIR")) |tmp0| {
                if (std.fmt.bufPrint(&pbuf, "{s}zilt-probe.pdf", .{std.mem.span(tmp0)})) |pth| {
                    if (self.webviewRequest(0, self.alloc, .{ .print_to_pdf = .{ .path = pth, .rid = 7 } })) |r| {
                        self.alloc.free(r);
                        const fm = msg0(Id, objc.cls("NSFileManager"), "defaultManager");
                        const ns_p = objc.nsString(pth.ptr, pth.len);
                        const exists = objc.msgSend(*const fn (Id, Sel, Id) callconv(.c) bool)(fm, objc.sel("fileExistsAtPath:"), ns_p);
                        if (exists) {
                            if (objc.msgSend(*const fn (Id, Sel, Id) callconv(.c) ?Id)(objc.cls("NSData"), objc.sel("dataWithContentsOfFile:"), ns_p)) |data| {
                                const n: c_ulong = msg0(c_ulong, data, "length");
                                pdf_ok = n > 1000;
                            }
                        }
                    } else |_| {}
                } else |_| {}
            }
            log.print("[macos] webview pdf ok={s}", .{boolStr(pdf_ok)});

            const dl_dlg = msg0(Id, objc.cls("ZiltDownloadDelegate"), "new");
            const dl_sel = objc.sel("download:decideDestinationUsingResponse:suggestedFilename:completionHandler:");
            const dl_ok = objc.msgSend(*const fn (Id, Sel, Sel) callconv(.c) bool)(dl_dlg, objc.sel("respondsToSelector:"), dl_sel);
            log.print("[macos] webview download ok={s} wiring-only", .{boolStr(dl_ok)});

            const ui_dlg = msg0(Id, objc.cls("ZiltUIDelegate"), "new");
            const perm_sel = objc.sel("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:");
            const perm_ok = objc.msgSend(*const fn (Id, Sel, Sel) callconv(.c) bool)(ui_dlg, objc.sel("respondsToSelector:"), perm_sel);
            log.print("[macos] webview permission ok={s} wiring-only", .{boolStr(perm_ok)});

            var drop_ok = false;
            if (msg0(?Id, self.webview, "class")) |k| {
                if (msg0(?Id, k, "description")) |nmz| {
                    if (msg0(?[*:0]const u8, nmz, "UTF8String")) |csz| {
                        drop_ok = std.mem.eql(u8, std.mem.span(csz), "ZiltWebView");
                    }
                }
            }
            log.print("[macos] webview drop ok={s}", .{boolStr(drop_ok)});

            const events_ok = self.ev_moved > 0 and self.ev_resized > 0;
            log.print("[macos] window events ok={s} moved={d} resized={d} focus={d} blur={d}", .{
                boolStr(events_ok), self.ev_moved, self.ev_resized, self.ev_focus, self.ev_blur,
            });

            const good = ok and size_ok and json_ok and appearance_ok and events_ok and theme_ok and dock_ok and vibrancy_ok and state_ok and drag_ok and clip_ok and dialog_ok and menu_ok and tray_ok and tray_action_ok and notify_ok and deeplink_ok and single_ok and hotkey_ok and wv_zoom_ok and dv_ok and print_ok and pdf_ok and dl_ok and perm_ok and drop_ok and self.runSpawnProbe();
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

        /// 主题变化统一出口：冒烟轮询与分布式通知都走这里（首个基线不发光）。
        fn onThemeMaybeChanged(self: *Self) void {
            const cur = self.isDarkAppearance();
            if (self.last_dark) |prev| {
                if (prev != cur) self.emitAllEvent("themeChanged", if (cur)
                    "{\"appearance\":\"dark\"}"
                else
                    "{\"appearance\":\"light\"}");
            }
            self.last_dark = cur;
        }

        /// 系统级事件（电源/会话/主题）广播到所有窗口（对齐 Linux：载荷 null）
        fn emitAllEvent(self: *Self, name: []const u8, payload: []const u8) void {
            self.emitWindowEvent(0, name, payload);
            for (self.wins.items) |w| self.emitWindowEvent(w.id, name, payload);
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
            _ = msg1(void, wv, "setAccessibilityLabel:", objc.nsString(opts.title.ptr, opts.title.len));
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
                self.onThemeMaybeChanged();
                if (self.sys_probe_posted and !self.theme_logged and self.theme_notes > 0) {
                    self.theme_logged = true;
                    log.print("[macos] theme observer ok=true", .{});
                }
                if (self.page_loaded and !self.probe_sent) {
                    self.probe_sent = true;
                    self.evalScript(self.webview, probe_js);
                    self.win_ops_ok = self.runWindowOpsProbe();
                    self.store_ok = self.runStoreProbe();
                    self.updater_ok = self.runUpdaterProbe();
                    self.win_ops_ok = self.win_ops_ok and self.runSystemProbe();
                    log.print("[macos] probe sent", .{});
                }
                const left = msg0(f64, deadline, "timeIntervalSinceNow");
                if (left <= 0) break;
            }
            if (self.sys_probe_posted and !self.theme_logged) log.print("[macos] theme observer ok=false", .{});
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
                .{ .name = "trayMenuAction:", .imp = imp(&onTrayMenuAction), .types = "v@:@" },
            });
            _ = objc.defineClass("ZiltNavigationDelegate", "WKNavigationDelegate", &.{
                .{ .name = "webView:didFinishNavigation:", .imp = imp(&onNavigateFinish), .types = "v@:@@" },
                .{ .name = "webView:navigationResponse:didBecomeDownload:", .imp = imp(&onNavBecameDownload), .types = "v@:@@" },
            });
            _ = objc.defineClass("ZiltSchemeHandler", "WKURLSchemeHandler", &.{
                .{ .name = "webView:startURLSchemeTask:", .imp = imp(&onStartTask), .types = "v@:@@" },
                .{ .name = "webView:stopURLSchemeTask:", .imp = imp(&onStopTask), .types = "v@:@@" },
            });
            _ = objc.defineClass("ZiltMessageHandler", "WKScriptMessageHandler", &.{
                .{ .name = "userContentController:didReceiveScriptMessage:", .imp = imp(&onScriptMessage), .types = "v@:@@" },
            });
            _ = objc.defineClass("ZiltSystemObserver", null, &.{
                .{ .name = "onWorkspaceNote:", .imp = imp(&onWorkspaceNote), .types = "v@:@" },
                .{ .name = "onThemeNote:", .imp = imp(&onThemeNote), .types = "v@:@" },
            });
            _ = objc.defineClass("ZiltMainQueue", null, &.{
                .{ .name = "drain:", .imp = imp(&onDrain), .types = "v@:@" },
            });
            _ = objc.defineClass("ZiltDownloadDelegate", null, &.{
                .{ .name = "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:", .imp = imp(&onDecideDestination), .types = "v@:@@@@" },
                .{ .name = "downloadDidFinish:", .imp = imp(&onDownloadFinished), .types = "v@:@" },
                .{ .name = "download:didFailWithError:", .imp = imp(&onDownloadFailed), .types = "v@:@@" },
            });
            _ = objc.defineClass("ZiltUIDelegate", null, &.{
                .{ .name = "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:", .imp = imp(&onMediaCapturePermission), .types = "v@:@@@l@" },
            });
            _ = objc.defineSubclass("ZiltWebView", "WKWebView", &.{}, &.{
                .{ .name = "draggingEntered:", .imp = imp(&onDragEntered), .types = "Q@:@" },
                .{ .name = "performDragOperation:", .imp = imp(&onPerformDrag), .types = "c@:@" },
                .{ .name = "draggingExited:", .imp = imp(&onDragExited), .types = "v@:@" },
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

        fn onWorkspaceNote(_: Id, _: Sel, note: Id) callconv(.c) void {
            inst.workspace_notes += 1;
            const nm = msg0(?Id, note, "name") orelse return;
            const c = msg0(?[*:0]const u8, nm, "UTF8String") orelse return;
            const name = power.macWorkspaceEventName(std.mem.span(c)) orelse return;
            log.print("[macos] system event: {s}", .{name});
            inst.emitAllEvent(name, "null");
        }

        fn onThemeNote(_: Id, _: Sel, _: Id) callconv(.c) void {
            inst.theme_notes += 1;
            inst.onThemeMaybeChanged();
        }

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

        // ---- v0.4.7：托盘 / 通知 / 单实例 / 深链 / 热键 ----

        var g_inst: ?*Self = null;

        fn setupTray(self: *Self, force: bool) void {
            const probe_items = [_]Config.MenuItem{ .{ .label = "Probe", .id = "probe" }, .{ .label = "-" } };
            const t: Config.Tray = config.tray orelse blk: {
                if (!force) return;
                break :blk .{ .menu = &probe_items };
            };
            const bar = msg0(Id, objc.cls("NSStatusBar"), "systemStatusBar");
            const item = objc.msgSend(*const fn (Id, Sel, f64) callconv(.c) Id)(bar, objc.sel("statusItemWithLength:"), -1);
            if (msg0(?Id, item, "button")) |btn| {
                _ = msg1(void, btn, "setTitle:", objc.nsStringZ("\u{25cf}"));
                _ = msg1(void, btn, "setToolTip:", objc.nsString(t.tooltip.ptr, t.tooltip.len));
            }
            if (t.menu) |items| {
                const menu = objc.allocInit(objc.cls("NSMenu"));
                const dlg = objc.allocInit(objc.cls("ZiltWindowDelegate"));
                var leaf: c_long = 0;
                for (items) |it| {
                    if (std.mem.eql(u8, it.label, "-")) {
                        _ = msg1(void, menu, "addItem:", msg0(Id, objc.cls("NSMenuItem"), "separatorItem"));
                        continue;
                    }
                    const mi = objc.allocInit(objc.cls("NSMenuItem"));
                    _ = msg1(void, mi, "setTitle:", objc.nsString(it.label.ptr, it.label.len));
                    leaf += 1;
                    _ = objc.msgSend(*const fn (Id, Sel, c_long) callconv(.c) void)(mi, objc.sel("setTag:"), leaf);
                    _ = objc.msgSend(*const fn (Id, Sel, ?Id) callconv(.c) void)(mi, objc.sel("setTarget:"), dlg);
                    _ = objc.msgSend(*const fn (Id, Sel, Sel) callconv(.c) void)(mi, objc.sel("setAction:"), objc.sel("trayMenuAction:"));
                    _ = msg1(void, menu, "addItem:", mi);
                }
                _ = msg1(void, item, "setMenu:", menu);
            }
            self.status_item = item;
            log.print("[macos] tray created", .{});
        }

        fn notifyImpl(self: *Self, title: []const u8, body: []const u8) void {
            _ = self;
            const bundle = msg0(Id, objc.cls("NSBundle"), "mainBundle");
            if (msg0(?Id, bundle, "bundleIdentifier") == null) {
                log.print("[macos] notify skipped: no bundle identifier", .{});
                return;
            }
            const center = msg0(?Id, objc.cls("UNUserNotificationCenter"), "currentNotificationCenter") orelse return;
            const content = objc.allocInit(objc.cls("UNMutableNotificationContent"));
            _ = msg1(void, content, "setTitle:", objc.nsString(title.ptr, title.len));
            _ = msg1(void, content, "setBody:", objc.nsString(body.ptr, body.len));
            const req = objc.msgSend(*const fn (Id, Sel, Id, Id, ?Id) callconv(.c) ?Id)(
                objc.cls("UNNotificationRequest"),
                objc.sel("requestWithIdentifier:content:trigger:"),
                objc.nsStringZ("zilt"),
                content,
                @as(?Id, null),
            ) orelse return;
            _ = msg1(void, center, "addNotificationRequest:withCompletionHandler:", req);
        }

        /// 单实例锁：~/Library/Application Support/<app_id>/zilt.lock（flock，进程退出即释放）。
        /// v0.5.8 从 $TMPDIR 迁出——系统会清理临时目录里的旧文件，长跑应用的锁文件
        /// 被删后新实例重建一个再 flock 就会成功；应用数据目录按用户隔离且不清理。
        fn acquireSingleLock(self: *Self) bool {
            const root = self.appDataRoot() orelse return true;
            self.makeDirPath(root);
            defer self.alloc.free(root);
            const path = std.fmt.allocPrintSentinel(self.alloc, "{s}/zilt.lock", .{root}, 0) catch return true;
            defer self.alloc.free(path);
            const fd = open(path.ptr, 0x0202, 0o644); // O_RDWR|O_CREAT
            if (fd < 0) return true;
            if (flock(fd, 0x2 | 0x4) != 0) return false; // LOCK_EX|LOCK_NB
            self.lock_fd = fd;
            return true;
        }

        /// 深链：从 NSProcessInfo.arguments 里抓首个匹配 scheme 的 URL（open <url> 启动时传入）
        fn captureDeepLink(self: *Self) void {
            if (config.deep_link == null) return;
            const pi = msg0(Id, objc.cls("NSProcessInfo"), "processInfo");
            const args = msg0(?Id, pi, "arguments") orelse return;
            const n: c_ulong = msg0(c_ulong, args, "count");
            var i: c_ulong = 1;
            while (i < n) : (i += 1) {
                const a = objc.msgSend(*const fn (Id, Sel, c_ulong) callconv(.c) Id)(args, objc.sel("objectAtIndex:"), i);
                const cs = msg0(?[*:0]const u8, a, "UTF8String") orelse continue;
                const sp = std.mem.span(cs);
                if (self.matchUrl(sp)) {
                    self.pending_url = self.alloc.dupe(u8, sp) catch null;
                    log.print("[macos] deep link captured", .{});
                    return;
                }
            }
        }

        fn matchUrl(self: *Self, u: []const u8) bool {
            _ = self;
            const sch = if (config.deep_link) |d| d.scheme else return false;
            if (u.len < sch.len + 3) return false;
            if (!std.mem.startsWith(u8, u, sch)) return false;
            return std.mem.startsWith(u8, u[scheme.len..], "://");
        }

        fn registerHotkeys(self: *Self) bool {
            const hks = config.hotkeys orelse return true;
            const target = GetApplicationEventTarget();
            var spec = EventTypeSpec{ .eventClass = 0x6b657962, .eventKind = 5 };
            _ = InstallEventHandler(target, hotkeyHandler, 1, &spec, null, null);
            g_inst = self;
            var ok: usize = 0;
            for (hks, 0..) |hk, i| {
                const code = keyCode(hk.key) orelse continue;
                var mods: u32 = 0;
                if (hk.ctrl) mods |= 0x1000;
                if (hk.alt) mods |= 0x0800;
                if (hk.shift) mods |= 0x0200;
                if (hk.win) mods |= 0x0100;
                var out: ?*anyopaque = null;
                const st = RegisterEventHotKey(code, mods, .{ .signature = 0x5a4c5448, .id = @intCast(i + 1) }, target, 0, &out);
                if (st == 0) ok += 1;
            }
            self.hotkey_ok = ok;
            return ok == hks.len;
        }

        fn hotkeyHandler(_: ?*anyopaque, ev: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
            const self = g_inst orelse return 0;
            var hk = EventHotKeyID{ .signature = 0, .id = 0 };
            if (GetEventParameter(ev, 0x2d2d2d2d, 0x686b6964, null, @sizeOf(EventHotKeyID), null, &hk) != 0) return 0;
            var id_str: []const u8 = "probe";
            if (hk.id != 99) {
                id_str = "unknown";
                if (config.hotkeys) |hks| {
                    const idx: usize = @intCast(hk.id);
                    if (idx >= 1 and idx <= hks.len) id_str = hks[idx - 1].id;
                }
            }
            var payload: [192]u8 = undefined;
            const json = std.fmt.bufPrint(&payload, "{{\"id\":\"{s}\"}}", .{id_str}) catch return 0;
            self.emitWindowEvent(0, "hotkey", json);
            return 0;
        }

        /// 托盘菜单项点击：tag 是叶子序号（1 起），按顺序映射回 MenuItem.id
        fn onTrayMenuAction(_: Id, _: Sel, sender: Id) callconv(.c) void {
            const tag: c_long = msg0(c_long, sender, "tag");
            if (tag <= 0) return;
            const want: usize = @intCast(tag);
            const t = config.tray orelse return;
            const items = t.menu orelse return;
            var leaf: usize = 0;
            for (items) |it| {
                if (std.mem.eql(u8, it.label, "-")) continue;
                leaf += 1;
                if (leaf != want) continue;
                const id = it.id orelse it.label;
                const payload = std.fmt.allocPrint(inst.alloc, "{{\"id\":\"{s}\"}}", .{id}) catch return;
                defer inst.alloc.free(payload);
                inst.emitWindowEvent(0, "menu", payload);
                return;
            }
        }

        const DownloadRec = struct { id: u64, dl: Id };

        /// ObjC block 布局前四字段定长，invoke 在偏移 24；拿它当函数指针调。
        const BlockLayout = extern struct { isa: ?*anyopaque, flags: u32, reserved: u32, invoke: ?*const anyopaque, descriptor: ?*anyopaque };

        fn blockCallId(block: ?*anyopaque, arg: Id) void {
            const b = block orelse return;
            const blk: *BlockLayout = @ptrCast(@alignCast(b));
            const iv = blk.invoke orelse return;
            const f: *const fn (?*anyopaque, Id) callconv(.c) void = @ptrCast(@alignCast(iv));
            f(b, arg);
        }

        fn blockCallLong(block: ?*anyopaque, arg: c_long) void {
            const b = block orelse return;
            const blk: *BlockLayout = @ptrCast(@alignCast(b));
            const iv = blk.invoke orelse return;
            const f: *const fn (?*anyopaque, c_long) callconv(.c) void = @ptrCast(@alignCast(iv));
            f(b, arg);
        }

        fn findDownload(self: *Self, dl: Id) ?u64 {
            for (self.downloads.items) |rec| {
                if (@intFromPtr(rec.dl) == @intFromPtr(dl)) return rec.id;
            }
            return null;
        }

        fn onNavBecameDownload(_: Id, _: Sel, _: Id, dl: Id) callconv(.c) void {
            _ = msg1(void, dl, "setDelegate:", msg0(Id, objc.cls("ZiltDownloadDelegate"), "new"));
            inst.download_seq += 1;
            inst.downloads.append(inst.alloc, .{ .id = inst.download_seq, .dl = dl }) catch {};
            var payload: [64]u8 = undefined;
            if (std.fmt.bufPrint(&payload, "{{\"id\":{d}}}", .{inst.download_seq})) |js| {
                inst.emitWindowEvent(0, "downloadStarted", js);
            } else |_| {}
            log.print("[macos] download started id={d}", .{inst.download_seq});
        }

        fn onDecideDestination(_: Id, _: Sel, _: Id, _: Id, name: Id, handler: ?*anyopaque) callconv(.c) void {
            const tmp = std.c.getenv("TMPDIR") orelse "/tmp";
            var nm_buf: [256]u8 = undefined;
            var nm: []const u8 = "zilt-download.bin";
            if (msg0(?[*:0]const u8, name, "UTF8String")) |cs| nm = std.mem.span(cs);
            if (nm.len > 200) nm = nm[0..200];
            const raw = std.fmt.bufPrint(&nm_buf, "{s}zilt-dl-{s}", .{ std.mem.span(tmp), nm }) catch return blockCallId(handler, objc.nsStringZ("/tmp/zilt-download.bin"));
            nm_buf[raw.len] = 0;
            const path = nm_buf[0..raw.len :0];
            const url = objc.msgSend(*const fn (Class, Sel, Id) callconv(.c) Id)(objc.cls("NSURL"), objc.sel("fileURLWithPath:"), objc.nsString(path.ptr, raw.len));
            blockCallId(handler, url);
            log.print("[macos] download destination {s}", .{path});
        }

        fn onDownloadFinished(_: Id, _: Sel, dl: Id) callconv(.c) void {
            if (inst.findDownload(dl)) |id| {
                var payload: [64]u8 = undefined;
                if (std.fmt.bufPrint(&payload, "{{\"id\":{d}}}", .{id})) |js| {
                    inst.emitWindowEvent(0, "downloadFinished", js);
                } else |_| {}
            }
        }

        fn onDownloadFailed(_: Id, _: Sel, dl: Id, err: Id) callconv(.c) void {
            _ = err;
            if (inst.findDownload(dl)) |id| {
                var payload: [64]u8 = undefined;
                if (std.fmt.bufPrint(&payload, "{{\"id\":{d}}}", .{id})) |js| {
                    inst.emitWindowEvent(0, "downloadFailed", js);
                } else |_| {}
            }
        }

        /// WKPermissionDecision：0 prompt / 1 grant / 2 deny。本应用是本地壳，默认授予。
        fn onMediaCapturePermission(_: Id, _: Sel, _: Id, _: Id, _: Id, ty: c_long, handler: ?*anyopaque) callconv(.c) void {
            blockCallLong(handler, 1);
            var payload: [64]u8 = undefined;
            if (std.fmt.bufPrint(&payload, "{{\"type\":{d},\"granted\":true}}", .{ty})) |js| {
                inst.emitWindowEvent(0, "mediaPermission", js);
            } else |_| {}
        }

        fn onDragEntered(_: Id, _: Sel, _: Id) callconv(.c) c_ulong {
            return 1; // NSDragOperationCopy
        }

        fn onDragExited(_: Id, _: Sel, _: Id) callconv(.c) void {
            inst.emitWindowEvent(0, "dragOver", "{{\"kind\":\"leave\"}}");
        }

        fn onPerformDrag(_: Id, _: Sel, sender: Id) callconv(.c) bool {
            const pb: Id = msg0(Id, sender, "draggingPasteboard");
            const cls_arr = objc.msgSend(*const fn (Class, Sel, Id) callconv(.c) Id)(objc.cls("NSArray"), objc.sel("arrayWithObject:"), objc.cls("NSURL"));
            const urls = objc.msgSend(*const fn (Id, Sel, Id, ?Id) callconv(.c) ?Id)(pb, objc.sel("readObjectsForClasses:options:"), cls_arr, @as(?Id, null)) orelse return false;
            const n: c_ulong = msg0(c_ulong, urls, "count");
            if (n == 0) return false;
            var list: std.ArrayListUnmanaged(u8) = .empty;
            defer list.deinit(inst.alloc);
            list.append(inst.alloc, '{') catch return false;
            list.appendSlice(inst.alloc, "\"paths\":[") catch return false;
            var i: c_ulong = 0;
            while (i < n) : (i += 1) {
                const u = objc.msgSend(*const fn (Id, Sel, c_ulong) callconv(.c) Id)(urls, objc.sel("objectAtIndex:"), i);
                const cs = msg0(?[*:0]const u8, u, "path") orelse continue;
                const pth = std.mem.span(cs);
                if (i != 0) list.append(inst.alloc, ',') catch return false;
                list.append(inst.alloc, '"') catch return false;
                list.appendSlice(inst.alloc, pth) catch return false;
                list.append(inst.alloc, '"') catch return false;
            }
            list.appendSlice(inst.alloc, "]}") catch return false;
            inst.emitWindowEvent(0, "filesDropped", list.items);
            return true;
        }

        fn notifyEntry(backend: *anyopaque, title: []const u8, body: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(backend));
            self.notifyImpl(title, body);
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

        fn applyFilters(panel: Id, filters: []const ipc.Filter) void {
            if (filters.len == 0) return;
            const arr = objc.allocInit(objc.cls("NSMutableArray"));
            for (filters) |f| {
                var ext = f.pattern;
                if (std.mem.lastIndexOfScalar(u8, ext, '*')) |k| ext = ext[k + 1 ..];
                if (std.mem.startsWith(u8, ext, ".")) ext = ext[1..];
                if (ext.len == 0) continue;
                _ = msg1(void, arr, "addObject:", objc.nsString(ext.ptr, ext.len));
            }
            if (msg0(c_ulong, arr, "count") == 0) return;
            _ = msg1(void, panel, "setAllowedFileTypes:", arr);
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
                    applyFilters(panel, o.filters);
                    if (msg0(c_long, panel, "runModal") != 1) return .{ .path = null };
                    return .{ .path = try panelPath(alloc, panel) };
                },
                .open_file => |o| {
                    const panel = msg0(Id, objc.cls("NSOpenPanel"), "openPanel");
                    _ = msg1(void, panel, "setCanChooseFiles:", true);
                    _ = msg1(void, panel, "setCanChooseDirectories:", false);
                    _ = msg1(void, panel, "setAllowsMultipleSelection:", false);
                    if (o.title.len != 0) _ = msg1(void, panel, "setTitle:", objc.nsString(o.title.ptr, o.title.len));
                    applyFilters(panel, o.filters);
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
                    applyFilters(panel, o.filters);
                    if (msg0(c_long, panel, "runModal") != 1) return .{ .paths = null };
                    const urls = msg0(?Id, panel, "URLs") orelse return .{ .paths = null };
                    const n: c_ulong = msg0(c_ulong, urls, "count");
                    var list = try alloc.alloc([]u8, n);
                    var filled: usize = 0;
                    var i: c_ulong = 0;
                    while (i < n) : (i += 1) {
                        const u = objc.msgSend(*const fn (Id, Sel, c_ulong) callconv(.c) Id)(urls, objc.sel("objectAtIndex:"), i);
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

/// 返回 struct 的消息：Apple x86_64 ABI 对 >16 字节的 struct 走 stret
/// （objc_msgSend_stret，返回值经首参指针带回），arm64 走普通 objc_msgSend。
fn structMsg(comptime T: type, obj: Id, name: [*:0]const u8) T {
    if (builtin.cpu.arch == .x86_64) {
        var out: T = undefined;
        objc.msgSendStret(*const fn (*T, Id, Sel) callconv(.c) void)(&out, obj, objc.sel(name));
        return out;
    }
    return objc.msgSend(*const fn (Id, Sel) callconv(.c) T)(obj, objc.sel(name));
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

/// updater.Fetcher 取数实现（std.http.Client；与 Linux updaterFetchLinux 同构，
/// 两平台共享同一套 updater 决策/验签逻辑）。per-call Io.Threaded，线程安全。
fn updaterFetchMacos(backend_ptr: *anyopaque, alloc: std.mem.Allocator, url: []const u8) anyerror![]u8 {
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

// ---- v0.4.7 Carbon：全局热键 ----
const EventTypeSpec = extern struct { eventClass: c_uint, eventKind: c_uint };
const EventHotKeyID = extern struct { signature: u32, id: u32 };

// ---- v0.5.8：系统信息（sysctl / IOKit / CoreFoundation）----
extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
extern "c" fn IOServiceMatching(name: [*:0]const u8) ?Id;
extern "c" fn IOServiceGetMatchingServices(port: c_uint, matching: Id, existing: *c_uint) c_int;
extern "c" fn IOIteratorNext(iterator: c_uint) c_uint;
extern "c" fn IOObjectRelease(obj: c_uint) c_int;
extern "c" fn IORegistryEntryCreateCFProperty(entry: c_uint, key: Id, allocator: ?Id, options: c_uint) ?Id;
extern "c" fn CFRelease(cf: Id) void;
extern "c" fn CFStringCreateWithCString(allocator: ?Id, c_str: [*:0]const u8, encoding: c_uint) ?Id;
extern "c" fn CFStringGetCString(cf: Id, buf: [*]u8, buf_len: c_long, encoding: c_uint) bool;
extern "c" fn CFDataGetLength(cf: Id) c_long;
extern "c" fn CFDataGetBytePtr(cf: Id) ?[*]const u8;
extern "c" fn CFGetTypeID(cf: Id) c_ulong;
extern "c" fn CFStringGetTypeID() c_ulong;
extern "c" fn CFDataGetTypeID() c_ulong;

const kCFStringEncodingUTF8: c_uint = 0x08000100;

/// sysctl 字符串值 → 调用方缓冲（去掉结尾 NUL）；失败/空返回 null。
fn sysctlString(name: [*:0]const u8, buf: []u8) ?[]const u8 {
    var len = buf.len;
    if (sysctlbyname(name, buf.ptr, &len, null, 0) != 0 or len == 0) return null;
    return std.mem.sliceTo(buf[0..len], 0);
}

fn ioProperty(entry: c_uint, key: [*:0]const u8) ?Id {
    const k = CFStringCreateWithCString(null, key, kCFStringEncodingUTF8) orelse return null;
    defer CFRelease(k);
    return IORegistryEntryCreateCFProperty(entry, k, null, 0);
}

/// CFString / CFData 属性值拷进调用方缓冲（放不下或类型不符返回 null）。
fn cfToBuf(cf: Id, buf: []u8) ?[]const u8 {
    var tmp: [512]u8 = undefined;
    const value: []const u8 = if (CFGetTypeID(cf) == CFStringGetTypeID()) blk: {
        if (!CFStringGetCString(cf, &tmp, tmp.len, kCFStringEncodingUTF8)) return null;
        break :blk std.mem.sliceTo(&tmp, 0);
    } else if (CFGetTypeID(cf) == CFDataGetTypeID()) blk: {
        break :blk macos_sysinfo.cfDataToString(cfDataBytes(cf) orelse return null) orelse return null;
    } else return null;
    if (value.len > buf.len) return null;
    @memcpy(buf[0..value.len], value);
    return buf[0..value.len];
}

fn cfDataBytes(cf: Id) ?[]const u8 {
    if (CFGetTypeID(cf) != CFDataGetTypeID()) return null;
    const len = CFDataGetLength(cf);
    if (len <= 0) return null;
    const p = CFDataGetBytePtr(cf) orelse return null;
    return p[0..@intCast(len)];
}

fn cfDataU16Le(cf: Id) ?u16 {
    return macos_sysinfo.cfDataToU16Le(cfDataBytes(cf) orelse return null);
}

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn flock(fd: c_int, op: c_int) c_int;
extern "c" fn GetApplicationEventTarget() ?*anyopaque;
extern "c" fn InstallEventHandler(
    target: ?*anyopaque,
    handler: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) i32,
    num: c_ulong,
    list: *const EventTypeSpec,
    user: ?*anyopaque,
    out: ?*?*anyopaque,
) i32;
extern "c" fn RegisterEventHotKey(code: u32, mods: u32, hk: EventHotKeyID, target: ?*anyopaque, opts: u32, out: *?*anyopaque) i32;
extern "c" fn GetEventParameter(ev: ?*anyopaque, name: u32, desired: u32, actual: ?*u32, size: c_ulong, out_size: ?*c_ulong, data: ?*anyopaque) i32;

fn keyCode(k: []const u8) ?u32 {
    const letters = [_]u32{ 0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6 };
    const digits = [_]u32{ 29, 18, 19, 20, 21, 23, 22, 26, 28, 25 };
    const funcs = [_]u32{ 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111 };
    if (k.len == 1) {
        const ch = k[0];
        if (ch >= 'A' and ch <= 'Z') return letters[ch - 'A'];
        if (ch >= 'a' and ch <= 'z') return letters[ch - 'a'];
        if (ch >= '0' and ch <= '9') return digits[ch - '0'];
        return null;
    }
    if (k.len >= 2 and k[0] == 'F') {
        const n = std.fmt.parseInt(usize, k[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return funcs[n - 1];
    }
    return null;
}
