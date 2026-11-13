//! Linux 平台后端（v0.2.0 骨架）：GTK3 + WebKit2GTK 4.1。
//!
//! 本版目标是把 Windows 那套「资产 + IPC」模型在 Linux 上立起来，且**可验证**：
//!   - 窗口：`gtk_window_new` + `webkit_web_view_new_with_user_content_manager`
//!   - 资产：注册自有 scheme `zilt://app/...`，由 `config.assets` 提供（含 gzip 解压）
//!   - IPC：JS → Zig 走 `window.webkit.messageHandlers.zilt`；Zig → JS 走
//!          `webkit_web_view_evaluate_javascript("window.__ziltDeliver(...)")`
//!   - 线程：worker → UI 用 `g_idle_add` 封送（对应 Windows 的 `PostMessageW`）
//!
//! 与 Windows 的差异（有意为之，不是遗漏）：
//!   - **URL 形态**：WebKitGTK 只能注册自有 scheme，不能接管 `https`。因此
//!     `config.url = https://zilt.app/index.html` 在 Linux 上映射为
//!     `zilt://app/index.html`；ACL 判定用的 app_url 也换成 `zilt://app/...`。
//!   - 尚未实现（钩子留 null → 前端拿到与 Windows 相同的固定降级错误名）：
//!     剪贴板 / 通知 / 对话框 / 系统集成 / 多窗口 / 下载 / 托盘 / 菜单 / 快捷键。
//!     这些属于 v0.2.1–v0.2.3，`platform/interface.zig` 的能力矩阵逐项打勾。
//!
//! 依赖（构建期）：pkg-config + libgtk-3-dev + libwebkit2gtk-4.1-dev。
//! Zig 0.17 移除了 `@cImport`，C 绑定由 `build.zig` 的 `addTranslateC` 从 `capi.h` 生成。
const std = @import("std");

const c = @import("gtk");

const ipc = @import("../../ipc.zig");
const asset_routes = @import("../../asset_routes.zig");
const inflate = @import("../../inflate.zig");
const security = @import("../../security.zig");
const builtin_cmds = @import("../../builtin.zig");
const log = @import("../../log.zig");
const Config = @import("../../config.zig").Config;

pub const platform_name = "linux";

/// 自有 scheme（WebKitGTK 要求不是 http/https/file）。
const scheme = "zilt";
const scheme_host = "app";

/// v0.2.0 Linux 冒烟脚本（只测已实现能力；见 smoke.js 顶部说明）。
const smoke_script = @embedFile("smoke.js");

/// G_SOURCE_REMOVE：idle 回调返回它表示「执行一次后移除」。
const G_SOURCE_REMOVE: c.gboolean = 0;

/// `config.url` → 自定义 scheme 下的入口路径（如 `/index.html`）。
///
/// `https://zilt.app/index.html` → `/index.html`
/// `https://zilt.app`             → `/index.html`
/// `https://zilt.app/sub/`        → `/sub/`（尾斜杠交给 SPA 候选补 index.html）
pub fn entryPath(url: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return "/index.html";
    const rest = url[sep + 3 ..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const path = std.mem.sliceTo(rest[host_end..], '?');
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return "/index.html";
    return path;
}

/// ZILT_LINUX_SMOKE=1 开启 Linux 冒烟（与 Windows 的 ZILT_SMOKE_EXIT 同一套约定）。
///
/// 0.17 的 `main() !void` 拿不到环境表（env 在 `std.process.Init` 里），
/// 这里直接用 libc 的 getenv——后端本来就链接 libc。
fn smokeEnabled() bool {
    const raw = std.c.getenv("ZILT_LINUX_SMOKE") orelse return false;
    return std.mem.eql(u8, std.mem.span(raw), "1");
}

/// 状态码 → reason phrase（scheme 响应需要显式给）。
/// NUL 结尾副本（0.17 的 Allocator 已移除 dupeZ；C API 传参需要 sentinel）。
fn dupeZ(alloc: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const buf = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(buf, s);
    return buf;
}

fn reasonFor(status: u16) [:0]const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "OK",
    };
}

pub fn run(comptime config: Config) !void {
    // 进程级长生命周期分配器：emit 可能来自任意 worker 线程，必须线程安全；
    // 后端已链接 libc，c_allocator 是最稳的选择（无泄漏检测开销，也不需要 deinit）。
    const alloc = std.heap.c_allocator;
    log.initFileLog("zilt.log");

    const Self = Backend(config);
    const self = try alloc.create(Self);
    self.* = .{
        .allocator = alloc,
        .smoke = smokeEnabled(),
    };
    defer {
        self.deinit();
        alloc.destroy(self);
    }

    // 无 DISPLAY 时 gtk_init 会直接 abort —— CI 必须用 xvfb-run（见 docs/v0.2-LINUX.md §7）
    c.gtk_init(null, null);

    // scheme 必须在创建 WebView 之前注册（web process 首次启动后不再接受）
    const wc = c.webkit_web_context_get_default();
    if (wc == null) return error.WebKitContextUnavailable;
    c.webkit_web_context_register_uri_scheme(wc, scheme, Self.onSchemeRequest, self, null);

    const win = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    if (win == null) return error.WindowCreateFailed;
    const win_typed: [*c]c.GtkWindow = @ptrCast(win);
    self.window = win_typed;

    c.gtk_window_set_title(win_typed, config.title.ptr);
    c.gtk_window_set_default_size(win_typed, @intCast(config.width), @intCast(config.height));
    c.gtk_window_set_resizable(win_typed, if (config.resizable) 1 else 0);
    c.gtk_window_set_decorated(win_typed, if (config.decorations) 1 else 0);
    if (config.always_on_top) c.gtk_window_set_keep_above(win_typed, 1);
    if (config.x != null and config.y != null) c.gtk_window_move(win_typed, config.x.?, config.y.?);

    const ucm = c.webkit_user_content_manager_new();
    if (ucm == null) return error.UserContentManagerFailed;
    self.ucm = ucm;

    if (c.webkit_user_content_manager_register_script_message_handler(ucm, "zilt") == 0) {
        return error.ScriptMessageHandlerFailed;
    }
    const handler_id = c.g_signal_connect_data(
        @ptrCast(ucm),
        "script-message-received::zilt",
        @ptrCast(&Self.onScriptMessage),
        self,
        null,
        0,
    );
    log.print("[linux] script message handler connected (id={d})", .{handler_id});

    // 框架 runtime：document-start 注入，早于页面脚本
    self.addUserScript(ipc.runtime_js);
    for (config.init_scripts) |script| self.addUserScript(script);
    if (self.smoke) self.addUserScript(smoke_script);

    const view_widget = c.webkit_web_view_new_with_user_content_manager(ucm);
    if (view_widget == null) return error.WebViewCreateFailed;
    self.view = @ptrCast(view_widget);
    c.gtk_container_add(@ptrCast(win), view_widget);

    _ = c.g_signal_connect_data(@ptrCast(win), "destroy", @ptrCast(&Self.onDestroy), self, null, 0);
    _ = c.g_signal_connect_data(@ptrCast(self.view), "load-changed", @ptrCast(&Self.onLoadChanged), self, null, 0);

    const url_text = try std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ scheme, scheme_host, entryPath(config.url) });
    defer alloc.free(url_text);
    const url = try dupeZ(alloc, url_text);
    defer alloc.free(url);
    self.app_url = try alloc.dupe(u8, url);
    c.webkit_web_view_load_uri(self.view, url.ptr);

    c.gtk_widget_show_all(win);
    if (config.visible) c.gtk_window_present(win_typed);

    log.print("[linux] window ready ({s}, {d}x{d}, gtk={d}.{d}.{d})", .{
        url,
        config.width,
        config.height,
        c.gtk_get_major_version(),
        c.gtk_get_minor_version(),
        c.gtk_get_micro_version(),
    });

    c.gtk_main();
    log.print("[linux] main loop exited", .{});
    // 冒烟模式：把结果变成进程退出码，便于 CI / 脚本判定
    if (self.smoke) std.process.exit(self.smoke_code);
}

fn Backend(comptime config: Config) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        window: [*c]c.GtkWindow = null,
        view: [*c]c.WebKitWebView = null,
        ucm: [*c]c.WebKitUserContentManager = null,
        app_url: []u8 = &.{},
        /// 冒烟模式（ZILT_LINUX_SMOKE=1）：注入 smoke.js，收到结果后按退出码结束
        smoke: bool = false,
        /// 冒烟退出码（0 通过 / 1 失败），主循环结束后生效
        smoke_code: u8 = 1,
        /// gzip 资产的解压缓存（UI 线程独占，无锁）
        asset_cache: std.StringHashMapUnmanaged([]u8) = .empty,
        /// 已登记的用户脚本（WebKit 侧持 ref，进程结束时统一释放）
        scripts: std.ArrayListUnmanaged(?*c.WebKitUserScript) = .empty,

        fn deinit(self: *Self) void {
            var it = self.asset_cache.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.asset_cache.deinit(self.allocator);
            for (self.scripts.items) |maybe| {
                if (maybe) |script| c.g_object_unref(@ptrCast(script));
            }
            self.scripts.deinit(self.allocator);
            if (self.app_url.len != 0) self.allocator.free(self.app_url);
        }

        // ---- WebView 脚本 ----

        fn addUserScript(self: *Self, source: []const u8) void {
            const src = dupeZ(self.allocator, source) catch return;
            defer self.allocator.free(src);
            const script = c.webkit_user_script_new(
                src.ptr,
                c.WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
                c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
                null,
                null,
            );
            if (script == null) return;
            c.webkit_user_content_manager_add_script(self.ucm, script);
            self.scripts.append(self.allocator, script) catch c.g_object_unref(@ptrCast(script));
        }

        /// 执行一段 JS（UI 线程）。WebKit 会把脚本复制进异步任务，返回后即可释放入参。
        fn evalScript(self: *Self, script: []const u8) void {
            if (self.view == null or script.len == 0) return;
            c.webkit_web_view_evaluate_javascript(
                self.view,
                script.ptr,
                @intCast(script.len),
                null,
                null,
                null,
                null,
                null,
            );
        }

        /// 把一条 IPC 消息推给前端（runtime_js 暴露的 `window.__ziltDeliver`）。
        fn deliverJson(self: *Self, json: []const u8) void {
            const script = std.fmt.allocPrint(self.allocator, "window.__ziltDeliver({s})", .{json}) catch return;
            defer self.allocator.free(script);
            self.evalScript(script);
        }

        // ---- Context 钩子 ----

        fn context(self: *Self, alloc: std.mem.Allocator) ipc.Context {
            return .{
                .allocator = alloc,
                .msg_allocator = self.allocator,
                .backend = @ptrCast(self),
                .window_id = 0,
                .emit_fn = emitEntry,
                .quit_fn = quitEntry,
                // 其余钩子留 null：调用方按 platform/interface.zig 的固定错误名降级
            };
        }

        fn emitEntry(backend: *anyopaque, window_id: u32, message_json: []const u8) void {
            _ = window_id; // 骨架只有主窗口
            const self: *Self = @ptrCast(@alignCast(backend));
            const task = self.allocator.create(EmitTask) catch return;
            const copy = self.allocator.dupe(u8, message_json) catch {
                self.allocator.destroy(task);
                return;
            };
            task.* = .{ .target = self, .json = copy };
            if (c.g_idle_add(emitIdle, task) == 0) {
                self.allocator.free(copy);
                self.allocator.destroy(task);
            }
        }

        fn quitEntry(_: *anyopaque, code: u8) void {
            _ = code;
            _ = c.g_idle_add(quitIdle, null);
        }

        // ---- 消息处理 ----

        fn handleMessage(self: *Self, raw: []const u8) !void {
            // per-message arena：命令期间的分配随响应发出后统一释放
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const ctx = self.context(arena.allocator());

            var decoded = try ipc.decode(self.allocator, raw);
            defer decoded.deinit();

            const enforce_acl = config.security.capabilities.len != 0;
            const source = self.currentUri();

            switch (decoded.msg) {
                .invoke => |inv| {
                    log.print("[ipc] invoke {s} (id={d})", .{ inv.method, inv.id });

                    // 框架内部：冒烟结果回传（不经过应用命令表，也不受 ACL 约束）
                    if (std.mem.eql(u8, inv.method, "__zilt.linuxSmoke")) {
                        self.finishSmoke(inv.args_json);
                        return;
                    }

                    if (enforce_acl and !security.allowed(
                        aclOptions(),
                        self.app_url,
                        null,
                        source,
                        "main",
                        .command,
                        inv.method,
                    )) {
                        log.print("[acl] command '{s}' denied (source={s})", .{ inv.method, source });
                        return self.reject(inv.id, "PermissionDenied");
                    }

                    const result_json: []u8 = blk: {
                        if (builtin_cmds.dispatch(ctx, inv.method, inv.args_json)) |maybe| {
                            if (maybe) |json| break :blk json;
                        } else |err| {
                            log.print("[ipc] builtin {s} failed: {s}", .{ inv.method, @errorName(err) });
                            return self.reject(inv.id, @errorName(err));
                        }
                        break :blk ipc.dispatch(config.commands, ctx, inv.method, inv.args_json) catch |err| {
                            log.print("[ipc] invoke {s} failed: {s}", .{ inv.method, @errorName(err) });
                            return self.reject(inv.id, @errorName(err));
                        };
                    };

                    const resp = try ipc.encodeResolve(self.allocator, inv.id, result_json);
                    defer self.allocator.free(resp);
                    self.deliverJson(resp);
                },
                .event => |ev| {
                    if (enforce_acl and !security.allowed(
                        aclOptions(),
                        self.app_url,
                        null,
                        source,
                        "main",
                        .event,
                        ev.name,
                    )) {
                        log.print("[acl] event '{s}' denied (source={s})", .{ ev.name, source });
                        return;
                    }
                    if (!ipc.dispatchEvent(config.events, ctx, ev.name, ev.payload_json)) {
                        log.print("[ipc] event '{s}' (no handler)", .{ev.name});
                    }
                },
                .ignore => {},
            }
        }

        fn reject(self: *Self, id: u64, err_name: []const u8) void {
            const resp = ipc.encodeReject(self.allocator, id, err_name) catch return;
            defer self.allocator.free(resp);
            self.deliverJson(resp);
        }

        /// 页面加载完成后自检：runtime_js 是否注入、messageHandlers 是否注册。
        /// 这两项任一为 false，前端所有 invoke 都会静默失败——所以显式记一行日志。
        fn diagnoseRuntime(self: *Self) void {
            // 诊断三元组：runtime 是否可用 / 首屏检查结果 / 页面是否已跑过 runChecks
            const script =
                "(() => {" ++
                "  const el = (id) => { const n = document.getElementById(id); return n ? (n.className + ':' + n.textContent) : 'missing'; };" ++
                "  return ['ready=' + document.readyState, 'greet=' + el('c-greet'), 'add=' + el('c-add')].join(' ');" ++
                "})()";
            c.webkit_web_view_evaluate_javascript(
                self.view,
                script.ptr,
                @intCast(script.len),
                null,
                null,
                null,
                diagDone,
                self,
            );
        }

        fn diagDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            _ = user_data;
            const view: [*c]c.WebKitWebView = @ptrCast(source);
            var err: [*c]c.GError = null;
            const value = c.webkit_web_view_evaluate_javascript_finish(view, res, &err);
            if (err != null) {
                c.g_error_free(err);
                log.print("[linux] runtime self-check failed (js error)", .{});
                return;
            }
            if (value == null) return;
            const text = c.jsc_value_to_string(value);
            if (text == null) return;
            defer c.g_free(@ptrCast(text));
            log.print("[linux] runtime self-check: zilt={s}", .{std.mem.span(text)});
        }

        fn onLoadChanged(_: [*c]c.WebKitWebView, event: c.WebKitLoadEvent, user_data: c.gpointer) callconv(.c) void {
            if (event != c.WEBKIT_LOAD_FINISHED) return;
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            self.diagnoseRuntime();
        }

        /// ACL 用的 Options：把 `zilt` 登记为应用自有 scheme。
        /// （WebKitGTK 只能注册自有 scheme，应用因此跑在 zilt://app 上。）
        fn aclOptions() security.Options {
            var opts = config.security;
            opts.app_schemes = &.{scheme};
            return opts;
        }

        /// 冒烟结果：`{passed,total,failed:[...]}` → 日志 + 退出码。
        fn finishSmoke(self: *Self, args_json: []const u8) void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), args_json, .{}) catch {
                log.print("[linux-smoke] FAILED to parse result: {s}", .{args_json});
                self.smoke_code = 1;
                return c.gtk_main_quit();
            };
            if (parsed != .object) {
                self.smoke_code = 1;
                return c.gtk_main_quit();
            }
            const obj = parsed.object;

            var passed: i64 = 0;
            var total: i64 = 0;
            if (obj.get("passed")) |v| {
                if (v == .integer) passed = v.integer;
            }
            if (obj.get("total")) |v| {
                if (v == .integer) total = v.integer;
            }
            var failed_buf: [512]u8 = undefined;
            var failed: []const u8 = "";
            if (obj.get("failed")) |v| {
                if (v == .array) {
                    var w: std.Io.Writer = .fixed(&failed_buf);
                    for (v.array.items, 0..) |item, i| {
                        if (item != .string) continue;
                        if (i != 0) w.writeAll(",") catch {};
                        w.writeAll(item.string) catch {};
                    }
                    failed = failed_buf[0..w.end];
                }
            }

            const ok = total > 0 and passed == total;
            self.smoke_code = if (ok) 0 else 1;
            if (ok) {
                log.print("[linux-smoke] ALL {d} CHECKS PASSED", .{total});
            } else {
                log.print("[linux-smoke] FAILED {d}/{d} (failed: {s})", .{ total - passed, total, failed });
            }
            c.gtk_main_quit();
        }

        fn currentUri(self: *Self) []const u8 {
            if (self.view == null) return self.app_url;
            const uri = c.webkit_web_view_get_uri(self.view);
            if (uri == null) return self.app_url;
            return std.mem.span(uri);
        }

        // ---- scheme 资产服务 ----

        fn serveScheme(self: *Self, request: [*c]c.WebKitURISchemeRequest) void {
            const raw_ptr = c.webkit_uri_scheme_request_get_path(request);
            const raw = if (raw_ptr != null) std.mem.span(raw_ptr) else "/index.html";
            const path = asset_routes.decodePath(self.allocator, if (raw.len == 0) "/index.html" else raw) catch {
                return self.finishPlain(request, 400, "bad request path");
            };
            defer self.allocator.free(path);

            var candidates = asset_routes.Candidates.init(self.allocator, path, true) catch {
                return self.finishPlain(request, 500, "out of memory");
            };
            defer candidates.deinit();

            for (candidates.paths) |maybe| {
                const route = maybe orelse continue;
                for (config.assets) |asset| {
                    if (!std.mem.eql(u8, asset.path, route)) continue;
                    const body = switch (asset.encoding) {
                        .identity => asset.content,
                        .gzip => self.assetDecompress(route, asset.content) orelse continue,
                    };
                    log.print("[assets] {s} -> 200 ({s}) {d} bytes", .{
                        route,
                        asset_routes.contentTypeOf(route),
                        body.len,
                    });
                    return self.finishBytes(request, 200, asset_routes.contentTypeOf(route), body);
                }
            }

            log.print("[assets] {s} -> 404", .{path});
            self.finishPlain(request, 404, "not found");
        }

        /// 压缩资产解压（惰性 + 进程内缓存）。
        fn assetDecompress(self: *Self, path: []const u8, gz: []const u8) ?[]const u8 {
            if (self.asset_cache.get(path)) |raw| return raw;
            const raw = inflate.gunzip(self.allocator, gz) catch return null;
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

        fn finishPlain(self: *Self, request: [*c]c.WebKitURISchemeRequest, status: u16, body: []const u8) void {
            self.finishBytes(request, status, "text/plain; charset=utf-8", body);
        }

        fn finishBytes(
            self: *Self,
            request: [*c]c.WebKitURISchemeRequest,
            status: u16,
            content_type: []const u8,
            body: []const u8,
        ) void {
            // g_bytes_new 会复制一份，之后即可释放临时解压结果
            const bytes = c.g_bytes_new(body.ptr, body.len);
            if (bytes == null) return;
            defer c.g_bytes_unref(bytes);
            const stream = c.g_memory_input_stream_new_from_bytes(bytes);
            if (stream == null) return;
            defer c.g_object_unref(@ptrCast(stream)); // response 自己会再 ref 一次

            const response = c.webkit_uri_scheme_response_new(stream, @intCast(body.len));
            if (response == null) return;
            defer c.g_object_unref(@ptrCast(response));

            const ct_z = dupeZ(self.allocator, content_type) catch return;
            defer self.allocator.free(ct_z);
            c.webkit_uri_scheme_response_set_content_type(response, ct_z.ptr);
            if (status != 200) {
                c.webkit_uri_scheme_response_set_status(response, status, reasonFor(status).ptr);
            }
            self.applySecurityHeaders(response);
            c.webkit_uri_scheme_request_finish_with_response(request, response);
        }

        /// 全局 CSP 与 security.headers：scheme 响应也要带上，否则 Linux 侧等于没配。
        fn applySecurityHeaders(self: *Self, response: [*c]c.WebKitURISchemeResponse) void {
            if (config.security.csp == null and config.security.headers.len == 0) return;
            const headers = c.soup_message_headers_new(c.SOUP_MESSAGE_HEADERS_RESPONSE);
            if (headers == null) return;
            defer c.soup_message_headers_unref(headers);

            if (config.security.csp) |csp| {
                const value = dupeZ(self.allocator, csp) catch return;
                defer self.allocator.free(value);
                c.soup_message_headers_append(headers, "Content-Security-Policy", value.ptr);
            }
            for (config.security.headers) |header| {
                const name = dupeZ(self.allocator, header.name) catch continue;
                defer self.allocator.free(name);
                const value = dupeZ(self.allocator, header.value) catch continue;
                defer self.allocator.free(value);
                c.soup_message_headers_append(headers, name.ptr, value.ptr);
            }
            c.webkit_uri_scheme_response_set_http_headers(response, headers);
        }

        // ---- GLib 回调（必须 callconv(.c)；放在泛型作用域内才能看到 config/Self） ----

        const EmitTask = struct { target: *Self, json: []u8 };

        fn emitIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const task: *EmitTask = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            defer {
                task.target.allocator.free(task.json);
                task.target.allocator.destroy(task);
            }
            task.target.deliverJson(task.json);
            return G_SOURCE_REMOVE;
        }

        fn quitIdle(_: c.gpointer) callconv(.c) c.gboolean {
            c.gtk_main_quit();
            return G_SOURCE_REMOVE;
        }

        fn onDestroy(_: [*c]c.GtkWidget, _: c.gpointer) callconv(.c) void {
            c.gtk_main_quit();
        }

        fn onSchemeRequest(request: [*c]c.WebKitURISchemeRequest, user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            self.serveScheme(request);
        }

        fn onScriptMessage(
            _: [*c]c.WebKitUserContentManager,
            result: ?*c.WebKitJavascriptResult,
            user_data: c.gpointer,
        ) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            if (result == null) return;

            // WebKitGTK 2.22+ 的信号载荷是 JSCValue：对象要用 jsc_value_to_json
            // 才能拿到 JSON 文本（jsc_value_to_string 只会给 "[object Object]"）。
            const value = c.webkit_javascript_result_get_js_value(result);
            if (value == null) return;
            const json_ptr = c.jsc_value_to_json(value, 0);
            if (json_ptr == null) return;
            defer c.g_free(@ptrCast(json_ptr));
            const raw = std.mem.span(json_ptr);
            if (raw.len == 0) return;

            self.handleMessage(raw) catch |err| {
                log.print("[linux] ipc failed: {s} (payload={s})", .{ @errorName(err), raw[0..@min(raw.len, 120)] });
            };
        }
    };
}

const testing = std.testing;

test "entryPath: 常见 config.url 形态" {
    try testing.expectEqualStrings("/index.html", entryPath("https://zilt.app/index.html"));
    try testing.expectEqualStrings("/index.html", entryPath("https://zilt.app"));
    try testing.expectEqualStrings("/index.html", entryPath("https://zilt.app/"));
    try testing.expectEqualStrings("/app.html", entryPath("https://zilt.app/app.html"));
    try testing.expectEqualStrings("/sub/", entryPath("https://zilt.app/sub/"));
    try testing.expectEqualStrings("/index.html", entryPath("http://localhost:5173/?debug=1"));
    // 没有 scheme 的畸形输入不应 panic：退回默认入口
    try testing.expectEqualStrings("/index.html", entryPath(""));
    try testing.expectEqualStrings("/index.html", entryPath("a.html"));
}

test "reasonFor: 状态码有可读短语" {
    try testing.expectEqualStrings("Not Found", reasonFor(404));
    try testing.expectEqualStrings("OK", reasonFor(200));
    try testing.expectEqualStrings("OK", reasonFor(599)); // 未知码不崩
}
