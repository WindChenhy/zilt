//! Linux 平台后端（v0.2.1）：GTK3 + WebKit2GTK 4.1。
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
//!     映射规则见 `mapAppUrl`（zilt.app origin → zilt://app；about: / zilt:// /
//!     其他 origin 原样；相对路径 = 入口同源路径）。
//!   - v0.2.1 切片 1：窗口 API（`window_fn` / `window_query_fn`）已接通——
//!     set_title / minimize / maximize / restore / fullscreen / size / position /
//!     show / hide / focus / close / start_dragging / always_on_top(_bottom) /
//!     skip_taskbar / focusable / enabled / theme(dark) / limits / fullscreen_monitor。
//!     光标系列、ignore_cursor、content_protected、shadow、icon 留 false（后续切片）。
//!   - v0.2.1 切片 2：WebView 面（`webview_request_fn` / `eval_async_fn`）已接通——
//!     reload / stop / zoom / get_zoom / history / back / forward / devtools /
//!     set_user_agent / eval（同步走嵌套 GMainLoop，对应 Windows 的 SyncWait 泵）。
//!     print / cdp / cancel_download / cookies / clear_storage 返回 NotSupported。
//!   - v0.2.1 切片 3：**多窗口 + 子 WebView + 数据分区**已接通——
//!     * 窗口注册表：每窗口独立 GtkWindow/WebView/UCM/脚本/状态跟踪，id 从 1 起
//!       （主窗口固定 1）；`window_fn` / `window_query_fn` / `webview_request_fn` /
//!       `eval_async_fn` / `emitEntry` / ACL 的 source 与 label 全部按 window_id
//!       路由（0 → 主窗口，对齐 Windows 的 `windowById(if (id == 0) 1 else id)`）。
//!     * `spawn_window_fn`：按 WindowOptions 创建新窗口 + 独立 UCM + WebView，
//!       注入 runtime/init/冒烟脚本；title/size/position/visible/resizable/
//!       decorations/always_on_top/skip_taskbar/limits 映射 GTK 属性；
//!       parent/modal → `gtk_window_set_transient_for` + `gtk_window_set_modal`
//!       （父销毁级联关子窗口，注册表维护父子关系）。child（Win32 WS_CHILD 概念）、
//!       per-window proxy/icon/background_color/user_agent/titlebar_overlay 等
//!       无 GTK 直接对应物的选项显式忽略。Linux 的 dispatch（script-message 信号）
//!       本身就在 UI 线程，无需像 Windows 那样 WM_ZILT_NEWWIN 封送。
//!     * 退出语义：**所有窗口都销毁才 gtk_main_quit**（对齐 Windows「全部关闭才
//!       退出消息泵」），主窗口销毁不再直接退出。
//!     * `system_fn`：接通 `.webviews` op（create/remove/navigate/setBounds/
//!       focus/list/eval）；其余 op 返回 NotSupported（降级语义与 Windows 同构，
//!       `platform/interface.zig` 的契约测试不受影响）。
//!     * 子 WebView：GtkOverlay 布局（主 WebView 是 main child 自动铺满；
//!       子 WebView 是 overlay child，经 get-child-position 信号定位——GtkFixed
//!       的子控件 size_request 会成为窗口最小尺寸，阻塞 gtk_window_resize）；无
//!       partition 共享默认 WebContext（scheme 处理器已注册 → 资产可用）；带
//!       partition 用独立 `webkit_website_data_manager_new(base-data-directory =
//!       <应用数据目录>/partitions/<name>)` + `webkit_web_context_new_with_
//!       website_data_manager`，**同名分区复用同一 context**（注册表持有，进程
//!       退出释放）；每个子 WebView 独立 UCM + runtime 注入 + script-message-
//!       received，**IPC 回复按 sender 路由**（子 webview 的 invoke 回到子页面，
//!       对齐 Windows 的 sendJsonTo(sender)）；`webviews.eval` 立即返回 pending、
//!       结果经 `webviewEval` 事件回传（对齐 Windows 的异步事件回传）；窗口销毁
//!       时子 WebView 随控件树一并释放。
//!   - 尚未实现（钩子留 null → 前端拿到与 Windows 相同的固定降级错误名）：
//!     剪贴板 / 通知 / 对话框 / 下载 / 托盘 / 菜单 / 快捷键 / http/ws/fs/SQL。
//!     这些属于 v0.2.2–v0.2.3，`platform/interface.zig` 的能力矩阵逐项打勾。
//!   - 冒烟（ZILT_LINUX_SMOKE=1）：33 项检查。WSLg 环境必须 `GDK_BACKEND=x11`
//!     跑 xvfb-run——Wayland 路径实测在多窗口场景触发协议错误（Error 71）断连。
//!
//! 依赖（构建期）：pkg-config + libgtk-3-dev + libwebkit2gtk-4.1-dev。
//! Zig 0.17 移除了 `@cImport`，C 绑定由 `build.zig` 的 `addTranslateC` 从 `capi.h` 生成。
const std = @import("std");

const c = @import("gtk");

const ipc = @import("../../ipc.zig");
const webview = @import("../../webview.zig");
const asset_routes = @import("../../asset_routes.zig");
const inflate = @import("../../inflate.zig");
const security = @import("../../security.zig");
const builtin_cmds = @import("../../builtin.zig");
const log = @import("../../log.zig");
const system_api = @import("../../system_api.zig");
const Config = @import("../../config.zig").Config;

pub const platform_name = "linux";

/// 自有 scheme（WebKitGTK 要求不是 http/https/file）。
const scheme = "zilt";
const scheme_host = "app";

/// v0.2.1 Linux 冒烟脚本（只测已实现能力；见 smoke.js 顶部说明）。
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

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// 分区名规范化为可安全做目录名：保留字母/数字/-/_，其余转 '_'，最长 64；
/// 全空 → "default"。与 Windows 后端同一份规则（对齐 `platform/windows/backend.zig`）。
pub fn sanitizePartition(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (raw) |ch| {
        if (out.items.len >= 64) break;
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_';
        try out.append(alloc, if (ok) ch else '_');
    }
    if (out.items.len == 0) try out.appendSlice(alloc, "default");
    return out.toOwnedSlice(alloc);
}

/// mkdir -p 等价物（后端链接 libc，直接走 mkdir 逐段建目录；已存在的段忽略）。
fn makeDirPath(alloc: std.mem.Allocator, path: []const u8) void {
    const z = alloc.allocSentinel(u8, path.len, 0) catch return;
    defer alloc.free(z);
    @memcpy(z, path);
    var idx: usize = 1;
    while (idx <= path.len) : (idx += 1) {
        if (idx == path.len or z[idx] == '/') {
            const saved = z[idx];
            z[idx] = 0;
            _ = std.c.mkdir(z.ptr, 0o755);
            z[idx] = saved;
        }
    }
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

    // 主窗口（id 固定 1）；spawn 的窗口走同一个创建函数（createWindowInternal）
    const main_opts = ipc.WindowOptions{
        .label = "main",
        .title = config.title,
        .width = config.width,
        .height = config.height,
        .url = config.url,
        .x = config.x,
        .y = config.y,
        .visible = config.visible,
        .resizable = config.resizable,
        .decorations = config.decorations,
        .always_on_top = config.always_on_top,
        .skip_taskbar = config.skip_taskbar,
        .min_width = config.min_width,
        .min_height = config.min_height,
        .max_width = config.max_width,
        .max_height = config.max_height,
        // background_color / icon / proxy / user_agent / titlebar_overlay / transparent：
        // Linux 侧暂无对应实现，主窗口与 spawn 窗口一致地忽略。
    };
    _ = try self.createWindowInternal(main_opts);

    log.print("[linux] main window ready (gtk={d}.{d}.{d}, smoke={s})", .{
        c.gtk_get_major_version(),
        c.gtk_get_minor_version(),
        c.gtk_get_micro_version(),
        boolStr(self.smoke),
    });

    c.gtk_main();
    log.print("[linux] main loop exited", .{});
    // 冒烟模式：把结果变成进程退出码，便于 CI / 脚本判定
    if (self.smoke) std.process.exit(self.smoke_code);
}

fn Backend(comptime config: Config) type {
    return struct {
        const Self = @This();

        // ------------------------------------------------------------------
        // 数据模型
        // ------------------------------------------------------------------

        /// IPC 回复路由的锚点：每个 WebView（窗口主页面 / 子 WebView）一个。
        /// script-message-received 的 user_data 指向它——WebKitGTK 的信号不携带
        /// sender，但信号是 per-UCM 注册的，UCM 又归属唯一 WebView，所以
        /// 「每个 WebView 一个 sink」等价于拿到 sender（对齐 Windows 的
        /// MessageHandler.create(w) + sendJsonTo(w, msg, sender) 语义）。
        const IpcSink = struct {
            backend: *Self,
            win_id: u32,
            view: [*c]c.WebKitWebView,
        };

        /// 单窗口状态（v0.2.1 切片 3 注册表化；WM 参与的状态以 GTK 查询为准，
        /// 这里只存客户端可查项）。
        const WinState = struct {
            backend: *Self,
            id: u32,
            label: []u8,
            win: [*c]c.GtkWindow,
            /// GtkOverlay 布局容器：主 WebView 是 main child（自动铺满内容区，
            /// 且不阻塞窗口缩小），子 WebView 是 overlay child、经
            /// get-child-position 信号按存储坐标放置。
            /// 不用 GtkFixed 的原因：fixed 子控件的 size_request 会成为窗口
            /// 的最小尺寸，gtk_window_resize 被钳制（实测 setSize(800,600)
            /// 被卡在 960x700），而主 WebView 作为 bin 类 child 无此问题。
            overlay: [*c]c.GtkWidget,
            view: [*c]c.WebKitWebView,
            ucm: [*c]c.WebKitUserContentManager,
            /// 入口 URL（ACL 判定用，形如 zilt://app/index.html）
            app_url: []u8,
            sink: *IpcSink,
            /// 已登记的用户脚本（WebKit 侧持 ref，窗口销毁时统一释放）
            scripts: std.ArrayListUnmanaged(?*c.WebKitUserScript) = .empty,
            /// 父窗口（parent/modal 映射 transient-for；父销毁级联关子窗口）
            parent_id: ?u32 = null,
            // ---- 窗口状态跟踪（v0.2.1 切片 1；Xvfb 无 WM，查询读跟踪值）----
            fullscreen: bool = false,
            always_on_top: bool = false,
            always_on_bottom: bool = false,
            /// 尺寸约束（0 = 无约束；对应 __zilt.window setMinMax）
            min_width: u32 = 0,
            min_height: u32 = 0,
            max_width: u32 = 0,
            max_height: u32 = 0,
            // ---- v0.2.1 切片 3：窗口内附加子 WebView ----
            child_webviews: std.ArrayListUnmanaged(*ChildView) = .empty,
            next_child_webview_id: u32 = 1,
        };

        /// 子 WebView（webviews.* op 管理的窗口内附加视图）。
        const ChildView = struct {
            id: u32,
            view: [*c]c.WebKitWebView,
            ucm: [*c]c.WebKitUserContentManager,
            sink: *IpcSink,
            /// 数据分区名（null = 共享默认 WebContext）。生命周期归 ChildView。
            partition: ?[]u8 = null,
            /// 布局（窗口内容区坐标，get-child-position 信号读取）
            x: i32 = 0,
            y: i32 = 0,
            width: i32 = 400,
            height: i32 = 300,
            /// 已登记的用户脚本（窗口销毁 / remove 时统一释放）
            scripts: std.ArrayListUnmanaged(?*c.WebKitUserScript) = .empty,
        };

        /// 分区 WebContext 表项（key = 规范化后的分区名）。
        /// 同名分区复用同一 context → 同分区多个子 WebView 共享存储。
        const PartitionCtx = struct {
            name: []u8,
            ctx: [*c]c.WebKitWebContext,
        };

        /// emit 的封送任务（worker 线程 → UI 线程，g_idle_add）。
        const EmitTask = struct {
            backend: *Self,
            win_id: u32,
            json: []u8,
        };

        /// 子 WebView eval（webviews.eval）的回传任务：
        /// 结果经 `webviewEval` 事件回传所属窗口（rid 匹配 Promise，对齐 Windows）。
        const ChildEvalJob = struct {
            win_id: u32,
            child_id: u32,
            rid: i64,
        };

        /// eval 任务（窗口主 WebView 与子 WebView 共用完成回调，见 evalFinished）。
        const EvalTask = struct {
            backend: *Self,
            /// null = 同步模式（嵌套泵等结果），非 null = 异步回调模式
            completion: ?webview.Completion = null,
            /// 同步模式专用：嵌套泵 + 结果落点（栈上，由调用方持有）
            loop: ?*c.GMainLoop = null,
            sync_err: ?anyerror = null,
            sync_json: ?[]u8 = null,
            /// 子 WebView eval：结果经 webviewEval 事件回传
            child_emit: ?ChildEvalJob = null,
        };

        allocator: std.mem.Allocator,
        /// 窗口注册表（id 从 1 起；主窗口固定 1）
        windows: std.ArrayListUnmanaged(*WinState) = .empty,
        next_window_id: u32 = 1,
        /// 已创建的分区 WebContext（同名复用）
        partitions: std.ArrayListUnmanaged(PartitionCtx) = .empty,
        /// 冒烟模式（ZILT_LINUX_SMOKE=1）：注入 smoke.js，收到结果后按退出码结束
        smoke: bool = false,
        /// 冒烟退出码（0 通过 / 1 失败），主循环结束后生效
        smoke_code: u8 = 1,
        /// gzip 资产的解压缓存（UI 线程独占，无锁）
        asset_cache: std.StringHashMapUnmanaged([]u8) = .empty,

        fn deinit(self: *Self) void {
            // 主循环退出后可能仍有窗口未 destroy（ctx.quit 路径）→ 逐个释放记录
            while (self.windows.items.len != 0) self.freeWindowState(self.windows.items[0]);
            self.windows.deinit(self.allocator);
            for (self.partitions.items) |pe| {
                c.g_object_unref(@ptrCast(pe.ctx));
                self.allocator.free(pe.name);
            }
            self.partitions.deinit(self.allocator);
            var it = self.asset_cache.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.asset_cache.deinit(self.allocator);
        }

        // ------------------------------------------------------------------
        // 窗口注册表
        // ------------------------------------------------------------------

        /// window_id 路由：0 → 主窗口（id 1），对齐 Windows 的 windowById。
        fn windowById(self: *Self, id: u32) ?*WinState {
            const target = if (id == 0) 1 else id;
            for (self.windows.items) |w| {
                if (w.id == target) return w;
            }
            return null;
        }

        fn findWindowByParent(self: *Self, parent_id: u32) ?*WinState {
            for (self.windows.items) |w| {
                if (w.parent_id == parent_id) return w;
            }
            return null;
        }

        /// 释放窗口记录（从注册表摘除 + 脚本/子 WebView/字符串）。
        /// **不销毁 GTK 控件**——调用方是窗口的 destroy 信号（GTK 自己销毁控件树）
        /// 或进程收尾（无需销毁）。
        fn freeWindowState(self: *Self, st: *WinState) void {
            for (self.windows.items, 0..) |item, i| {
                if (item == st) {
                    _ = self.windows.swapRemove(i);
                    break;
                }
            }
            for (st.scripts.items) |maybe| {
                // WebKitUserScript 不是 GObject（boxed/opaque），必须用专属 unref
                // （g_object_unref 会触发 GLib-CRITICAL，实测）
                if (maybe) |script| c.webkit_user_script_unref(script);
            }
            st.scripts.deinit(self.allocator);
            for (st.child_webviews.items) |cv| self.freeChildView(cv);
            st.child_webviews.deinit(self.allocator);
            self.allocator.destroy(st.sink);
            self.allocator.free(st.label);
            if (st.app_url.len != 0) self.allocator.free(st.app_url);
            self.allocator.destroy(st);
        }

        /// 释放子 WebView 记录。**不销毁 view 控件**：
        /// - remove op 先 gtk_widget_destroy(view) 再调这里；
        /// - 窗口 destroy 时控件树由 GTK 统一销毁，再 destroy 会双重释放。
        fn freeChildView(self: *Self, cv: *ChildView) void {
            for (cv.scripts.items) |maybe| {
                // WebKitUserScript 不是 GObject（boxed/opaque），必须用专属 unref
                // （g_object_unref 会触发 GLib-CRITICAL，实测）
                if (maybe) |script| c.webkit_user_script_unref(script);
            }
            cv.scripts.deinit(self.allocator);
            if (cv.partition) |p| self.allocator.free(p);
            self.allocator.destroy(cv.sink);
            self.allocator.destroy(cv);
        }

        fn childViewById(w: *WinState, id: i64) ?*ChildView {
            for (w.child_webviews.items) |cv| {
                if (cv.id == id) return cv;
            }
            return null;
        }

        // ------------------------------------------------------------------
        // URL / 数据目录 / 分区 context
        // ------------------------------------------------------------------

        /// URL 映射（窗口与子 WebView 共用）：
        ///   空                                → 主入口（zilt://app + entryPath(config.url)）
        ///   about:* / zilt://*                → 原样
        ///   https://zilt.app/x                → zilt://app/x（自有 scheme 映射）
        ///   其他 origin（远程内容/开发服务器） → 原样
        ///   相对路径（"second.html"）          → zilt://app/second.html
        fn mapAppUrl(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
            if (raw.len == 0) {
                return std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ scheme, scheme_host, entryPath(config.url) });
            }
            if (std.mem.startsWith(u8, raw, "about:")) return alloc.dupe(u8, raw);
            if (std.mem.startsWith(u8, raw, scheme ++ "://")) return alloc.dupe(u8, raw);
            if (std.mem.indexOf(u8, raw, "://")) |sep| {
                const rest = raw[sep + 3 ..];
                const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
                const host = rest[0..host_end];
                if (!std.mem.eql(u8, host, "zilt.app")) return alloc.dupe(u8, raw);
                var path = rest[host_end..];
                if (std.mem.indexOfAny(u8, path, "?#")) |q| path = path[0..q];
                if (path.len == 0 or std.mem.eql(u8, path, "/")) path = "/index.html";
                return std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ scheme, scheme_host, path });
            }
            // 相对路径 = 入口同源路径
            if (raw[0] == '/') {
                return std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ scheme, scheme_host, raw });
            }
            return std.fmt.allocPrint(alloc, "{s}://{s}/{s}", .{ scheme, scheme_host, raw });
        }

        /// 应用数据根目录（Linux 约定）：$XDG_DATA_HOME/<app_id> 或
        /// ~/.local/share/<app_id>。调用方 free。
        fn appDataRoot(self: *Self) ?[]u8 {
            if (std.c.getenv("XDG_DATA_HOME")) |xdg| {
                const s = std.mem.span(xdg);
                if (s.len > 0) {
                    return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ s, config.app_id }) catch null;
                }
            }
            const home = std.c.getenv("HOME") orelse return null;
            const hs = std.mem.span(home);
            if (hs.len == 0) return null;
            return std.fmt.allocPrint(self.allocator, "{s}/.local/share/{s}", .{ hs, config.app_id }) catch null;
        }

        /// 分区数据目录：<应用数据目录>/partitions/<name>。调用方 free。
        fn partitionDirectory(self: *Self, name: []const u8) ![]u8 {
            const root = self.appDataRoot() orelse return error.AppDataUnavailable;
            defer self.allocator.free(root);
            return std.fmt.allocPrint(self.allocator, "{s}/partitions/{s}", .{ root, name });
        }

        fn findPartition(self: *Self, name: []const u8) ?[*c]c.WebKitWebContext {
            for (self.partitions.items) |pe| {
                if (std.mem.eql(u8, pe.name, name)) return pe.ctx;
            }
            return null;
        }

        /// 为分区建独立 WebContext：独立 `WebKitWebsiteDataManager`
        ///（base-data-directory = <应用数据目录>/partitions/<name>）→ 该分区的
        /// Cookie/localStorage/IndexedDB 与其他分区、默认 context 完全隔离。
        /// scheme 处理器同样注册（资产服务对分区子 WebView 可用）。
        /// 返回的 context 引用归注册表（deinit 时释放）。
        fn createPartitionContext(self: *Self, name: []const u8) ![*c]c.WebKitWebContext {
            const dir = try self.partitionDirectory(name);
            defer self.allocator.free(dir);
            // 目录不存在则创建（WebKit 会往里写 localStorage/IndexedDB 等）
            makeDirPath(self.allocator, dir);
            const dir_z = try dupeZ(self.allocator, dir);
            defer self.allocator.free(dir_z);

            const mgr = c.webkit_website_data_manager_new(
                "base-data-directory",
                @as(?*const anyopaque, dir_z.ptr),
                @as(?*anyopaque, null), // 属性表哨兵
            );
            if (mgr == null) return error.WebKitContextUnavailable;
            defer c.g_object_unref(@ptrCast(mgr)); // context 会持有自己的引用

            const ctx = c.webkit_web_context_new_with_website_data_manager(mgr);
            if (ctx == null) return error.WebKitContextUnavailable;
            c.webkit_web_context_register_uri_scheme(ctx, scheme, Self.onSchemeRequest, self, null);
            log.print("[webviews] partition '{s}' context created ({s})", .{ name, dir });
            return ctx;
        }

        // ------------------------------------------------------------------
        // WebView 脚本 / IPC 投递
        // ------------------------------------------------------------------

        /// 向指定 UCM 注册 document-start 用户脚本（runtime / init / 冒烟）。
        fn addUserScriptTo(
            self: *Self,
            scripts: *std.ArrayListUnmanaged(?*c.WebKitUserScript),
            ucm: [*c]c.WebKitUserContentManager,
            source: []const u8,
        ) void {
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
            c.webkit_user_content_manager_add_script(ucm, script);
            scripts.append(self.allocator, script) catch c.webkit_user_script_unref(script);
        }

        /// 给一个（窗口主 / 子）WebView 接好 IPC 信号并注入全套脚本。
        fn attachIpc(self: *Self, sink: *IpcSink, ucm: [*c]c.WebKitUserContentManager, scripts: *std.ArrayListUnmanaged(?*c.WebKitUserScript)) void {
            if (c.webkit_user_content_manager_register_script_message_handler(ucm, "zilt") == 0) {
                log.print("[linux] script message handler register failed (win={d})", .{sink.win_id});
                return;
            }
            _ = c.g_signal_connect_data(
                @ptrCast(ucm),
                "script-message-received::zilt",
                @ptrCast(&Self.onScriptMessage),
                sink,
                null,
                0,
            );
            self.addUserScriptTo(scripts, ucm, ipc.runtime_js);
            for (config.init_scripts) |script| self.addUserScriptTo(scripts, ucm, script);
            if (self.smoke) self.addUserScriptTo(scripts, ucm, smoke_script);
        }

        /// 执行一段 JS（UI 线程）。WebKit 会把脚本复制进异步任务，返回后即可释放入参。
        fn evalScriptOn(view: [*c]c.WebKitWebView, script: []const u8) void {
            if (view == null or script.len == 0) return;
            c.webkit_web_view_evaluate_javascript(
                view,
                script.ptr,
                @intCast(script.len),
                null,
                null,
                null,
                null,
                null,
            );
        }

        /// 把一条 IPC 消息推给指定 WebView（runtime_js 暴露的 `window.__ziltDeliver`）。
        fn deliverAlloc(self: *Self, view: [*c]c.WebKitWebView, json: []const u8) void {
            const script = std.fmt.allocPrint(self.allocator, "window.__ziltDeliver({s})", .{json}) catch return;
            defer self.allocator.free(script);
            evalScriptOn(view, script);
        }

        // ------------------------------------------------------------------
        // Context 钩子
        // ------------------------------------------------------------------

        fn context(self: *Self, alloc: std.mem.Allocator, window_id: u32) ipc.Context {
            return .{
                .allocator = alloc,
                .msg_allocator = self.allocator,
                .backend = @ptrCast(self),
                .window_id = window_id,
                .emit_fn = emitEntry,
                .quit_fn = quitEntry,
                .window_fn = windowEntry,
                .window_query_fn = windowQueryEntry,
                .webview_request_fn = webviewRequestEntry,
                .eval_async_fn = evalAsyncEntry,
                .spawn_window_fn = spawnWindowEntry,
                .system_fn = systemEntry,
                // 其余钩子留 null：调用方按 platform/interface.zig 的固定错误名降级
            };
        }

        /// emit（Zig → JS 事件）：按 window_id 路由到目标窗口的主 WebView。
        /// message_json 的所有权转移给后端（emit_fn 契约：用 msg_allocator 分配、
        /// 后端用同一分配器释放——包括窗口已销毁的路径）。
        fn emitEntry(backend: *anyopaque, window_id: u32, message_json: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(backend));
            const task = self.allocator.create(EmitTask) catch {
                self.allocator.free(@constCast(message_json));
                return;
            };
            task.* = .{
                .backend = self,
                .win_id = if (window_id == 0) 1 else window_id,
                .json = @constCast(message_json),
            };
            if (c.g_idle_add(emitIdle, task) == 0) {
                self.allocator.free(task.json);
                self.allocator.destroy(task);
            }
        }

        fn quitEntry(_: *anyopaque, code: u8) void {
            _ = code;
            _ = c.g_idle_add(quitIdle, null);
        }

        /// UI 线程：把 emit 消息投递到目标窗口（窗口可能已销毁 → 只释放）。
        fn emitIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const task: *EmitTask = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            const self = task.backend;
            defer {
                self.allocator.free(task.json);
                self.allocator.destroy(task);
            }
            if (self.windowById(task.win_id)) |w| {
                self.deliverAlloc(w.view, task.json);
            } else {
                log.print("[linux] emit dropped (window #{d} gone)", .{task.win_id});
            }
            return G_SOURCE_REMOVE;
        }

        fn quitIdle(_: c.gpointer) callconv(.c) c.gboolean {
            c.gtk_main_quit();
            return G_SOURCE_REMOVE;
        }

        // ------------------------------------------------------------------
        // 窗口创建（主窗口 + spawn_window_fn 共用）
        // ------------------------------------------------------------------

        /// 按 WindowOptions 创建窗口。须在 UI（GTK 主循环）线程调用——Linux 的
        /// dispatch 全在 script-message 信号里，天然满足（对应 Windows 的
        /// WM_ZILT_NEWWIN SendMessageW 封送）。
        fn createWindowInternal(self: *Self, opts: ipc.WindowOptions) !*WinState {
            if (opts.width == 0 or opts.height == 0) return error.InvalidWindowSize;
            const id = self.next_window_id;
            const label = if (opts.label) |l|
                try self.allocator.dupe(u8, l)
            else
                try std.fmt.allocPrint(self.allocator, "window-{d}", .{id});
            errdefer self.allocator.free(label);
            for (self.windows.items) |other| {
                if (std.mem.eql(u8, other.label, label)) return error.DuplicateWindowLabel;
            }

            // parent / modal：GTK 无 WS_CHILD 子窗口 → child 选项显式忽略；
            // parent/modal → transient-for + set-modal。
            var parent_state: ?*WinState = null;
            if (opts.parent) |pid| {
                parent_state = self.windowById(if (pid == 0) 1 else pid) orelse return error.ParentNotFound;
            }
            if ((opts.child or opts.modal) and parent_state == null) return error.ParentRequired;

            const app_url = try mapAppUrl(self.allocator, opts.url orelse config.url);
            errdefer self.allocator.free(app_url);

            const win = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
            if (win == null) return error.WindowCreateFailed;
            const win_typed: [*c]c.GtkWindow = @ptrCast(win);
            // 失败路径统一销毁窗口控件（此时 destroy 信号尚未连接，不会触碰 Zig 记录）
            errdefer c.gtk_widget_destroy(win);

            const title_z = try dupeZ(self.allocator, opts.title);
            defer self.allocator.free(title_z);
            c.gtk_window_set_title(win_typed, title_z.ptr);
            c.gtk_window_set_default_size(win_typed, @intCast(opts.width), @intCast(opts.height));
            c.gtk_window_set_resizable(win_typed, if (opts.resizable) 1 else 0);
            c.gtk_window_set_decorated(win_typed, if (opts.decorations) 1 else 0);
            if (opts.always_on_top) c.gtk_window_set_keep_above(win_typed, 1);
            if (opts.skip_taskbar) c.gtk_window_set_skip_taskbar_hint(win_typed, 1);
            if (opts.x != null and opts.y != null) c.gtk_window_move(win_typed, opts.x.?, opts.y.?);
            if (parent_state) |p| {
                c.gtk_window_set_transient_for(win_typed, p.win);
                if (opts.modal) c.gtk_window_set_modal(win_typed, 1);
            }

            const st = try self.allocator.create(WinState);
            errdefer self.allocator.destroy(st);
            st.* = .{
                .backend = self,
                .id = id,
                .label = label,
                .win = win_typed,
                .overlay = null,
                .view = null,
                .ucm = null,
                .app_url = app_url,
                .sink = undefined,
                .parent_id = if (parent_state) |p| p.id else null,
                .always_on_top = opts.always_on_top,
                .min_width = opts.min_width orelse 0,
                .min_height = opts.min_height orelse 0,
                .max_width = opts.max_width orelse 0,
                .max_height = opts.max_height orelse 0,
            };

            // GtkOverlay 布局容器（见 WinState.overlay 注释）
            const overlay = c.gtk_overlay_new();
            if (overlay == null) return error.WebViewCreateFailed;
            st.overlay = @ptrCast(overlay);
            c.gtk_container_add(@ptrCast(win), overlay);

            const ucm = c.webkit_user_content_manager_new();
            if (ucm == null) return error.UserContentManagerFailed;
            st.ucm = ucm;

            const sink = try self.allocator.create(IpcSink);
            errdefer self.allocator.destroy(sink);
            sink.* = .{ .backend = self, .win_id = id, .view = null };
            st.sink = sink;

            const view_widget = c.webkit_web_view_new_with_user_content_manager(ucm);
            if (view_widget == null) return error.WebViewCreateFailed;
            const view: [*c]c.WebKitWebView = @ptrCast(view_widget);
            st.view = view;
            sink.view = view;
            // 主 WebView 作为 main child：随窗口内容区自动伸缩
            c.gtk_container_add(@ptrCast(overlay), view_widget);

            // IPC sink + load-changed（必须在 gtk_main 之前接好；页面脚本要等主循环）
            _ = c.g_signal_connect_data(
                @ptrCast(view_widget),
                "load-changed",
                @ptrCast(&Self.onLoadChanged),
                sink,
                null,
                0,
            );
            self.attachIpc(sink, ucm, &st.scripts);

            // geometry hints（min/max；Xvfb 无 WM 不执行，真实桌面生效）
            applyGeometryHints(st, win_typed);

            const url_z = try dupeZ(self.allocator, app_url);
            defer self.allocator.free(url_z);
            c.webkit_web_view_load_uri(view, url_z.ptr);

            try self.windows.append(self.allocator, st);
            self.next_window_id = id + 1;

            // 注册成功后才接窗口级信号：destroy 处理器会解引用 st，
            // 之前的错误路径（errdefer destroy(st)）绝不能有 destroy 处理器存活。
            _ = c.g_signal_connect_data(win, "destroy", @ptrCast(&Self.onDestroy), st, null, 0);
            _ = c.g_signal_connect_data(
                overlay,
                "get-child-position",
                @ptrCast(&Self.onChildPosition),
                st,
                null,
                0,
            );

            c.gtk_widget_show_all(win);
            if (opts.visible) c.gtk_window_present(win_typed);

            log.print("[linux] window #{d} created: \"{s}\" ({s}) label={s} parent={s} modal={} visible={}", .{
                id,
                opts.title,
                app_url,
                label,
                if (parent_state) |p| p.label else "-",
                opts.modal,
                opts.visible,
            });
            return st;
        }

        /// 尺寸约束 → gdk geometry hints（0 = 无约束；全空则不下发任何 hint 位）。
        /// 注意 WM 才会执行约束，Xvfb 下无 WM——所以 query 读跟踪值而非 hint。
        fn applyGeometryHints(st: *WinState, win: [*c]c.GtkWindow) void {
            var geom: c.GdkGeometry = std.mem.zeroes(c.GdkGeometry);
            var flags: c.GdkWindowHints = 0;
            if (st.min_width != 0 or st.min_height != 0) {
                geom.min_width = @intCast(st.min_width);
                geom.min_height = @intCast(st.min_height);
                flags |= c.GDK_HINT_MIN_SIZE;
            }
            if (st.max_width != 0 or st.max_height != 0) {
                geom.max_width = @intCast(st.max_width);
                geom.max_height = @intCast(st.max_height);
                flags |= c.GDK_HINT_MAX_SIZE;
            }
            // geometry_widget 传 null = 约束相对窗口自身
            c.gtk_window_set_geometry_hints(win, null, &geom, flags);
        }

        // ------------------------------------------------------------------
        // 窗口控制（v0.2.1 切片 1，切片 3 起按 window_id 路由）
        // ------------------------------------------------------------------

        fn windowEntry(backend: *anyopaque, window_id: u32, cmd: ipc.WindowCmd) bool {
            const self: *Self = @ptrCast(@alignCast(backend));
            const st = self.windowById(window_id) orelse return false;
            const win = st.win;
            const widget: [*c]c.GtkWidget = @ptrCast(win);

            switch (cmd) {
                .set_title => |t| {
                    const z = dupeZ(self.allocator, t) catch return false;
                    defer self.allocator.free(z);
                    c.gtk_window_set_title(win, z.ptr);
                },
                .minimize => c.gtk_window_iconify(win),
                .maximize => c.gtk_window_maximize(win),
                .restore => {
                    // 全屏 → 最大化 → 最小化，逐层退出（与 Windows restore 语义对齐）
                    if (st.fullscreen) {
                        c.gtk_window_unfullscreen(win);
                        st.fullscreen = false;
                    }
                    if (c.gtk_window_is_maximized(win) != 0) c.gtk_window_unmaximize(win);
                    _ = c.gtk_window_deiconify(win);
                },
                .fullscreen => |on| {
                    if (on) c.gtk_window_fullscreen(win) else c.gtk_window_unfullscreen(win);
                    st.fullscreen = on;
                },
                .size => |s| c.gtk_window_resize(win, @intCast(s.width), @intCast(s.height)),
                .position => |p| c.gtk_window_move(win, p.x, p.y),
                .show => c.gtk_widget_show_all(widget),
                .hide => c.gtk_widget_hide(widget),
                .focus => c.gtk_window_present(win),
                .close => c.gtk_window_close(win),
                .start_dragging => {
                    // 无鼠标事件上下文也能拖：取指针根坐标 + GLib 当前事件时间戳
                    const display = c.gdk_display_get_default() orelse return false;
                    const seat = c.gdk_display_get_default_seat(display) orelse return false;
                    var x: c.gint = 0;
                    var y: c.gint = 0;
                    c.gdk_device_get_position(c.gdk_seat_get_pointer(seat), null, &x, &y);
                    c.gtk_window_begin_move_drag(win, 1, x, y, c.gtk_get_current_event_time());
                },
                .always_on_top => |on| {
                    c.gtk_window_set_keep_above(win, @intFromBool(on));
                    st.always_on_top = on;
                },
                .always_on_bottom => |on| {
                    c.gtk_window_set_keep_below(win, @intFromBool(on));
                    st.always_on_bottom = on;
                },
                .skip_taskbar => |on| c.gtk_window_set_skip_taskbar_hint(win, @intFromBool(on)),
                .focusable => |on| c.gtk_window_set_accept_focus(win, @intFromBool(on)),
                .enabled => |on| c.gtk_widget_set_sensitive(widget, @intFromBool(on)),
                .theme => |t| {
                    // GTK3 只有暗色偏好这一项可映射；caption/border 等 DWM 配色是 Windows 独占
                    if (t.dark) |dark| {
                        const settings = c.gtk_settings_get_default() orelse return false;
                        c.g_object_set(
                            @ptrCast(settings),
                            "gtk-application-prefer-dark-theme",
                            @as(c.gboolean, @intFromBool(dark)),
                            @as(?*anyopaque, null),
                        );
                    }
                },
                .limits => |lim| {
                    // null = 不改，0 = 清除该约束（与 Windows 语义一致）
                    if (lim.min_width) |v| st.min_width = @intCast(v) else st.min_width = 0;
                    if (lim.min_height) |v| st.min_height = @intCast(v) else st.min_height = 0;
                    if (lim.max_width) |v| st.max_width = @intCast(v) else st.max_width = 0;
                    if (lim.max_height) |v| st.max_height = @intCast(v) else st.max_height = 0;
                    applyGeometryHints(st, win);
                },
                .fullscreen_monitor => |idx| {
                    // GTK3 的 API 走 GdkScreen（3.22 起才有 GdkMonitor 版本）
                    const screen = c.gdk_screen_get_default() orelse return false;
                    if (idx >= @as(u32, @intCast(c.gdk_screen_get_n_monitors(screen)))) return false;
                    c.gtk_window_fullscreen_on_monitor(win, screen, @intCast(idx));
                    st.fullscreen = true;
                },
                // 光标系列 / 穿透 / 截图保护 / 阴影 / 图标：后续切片（false = 前端拿到明确失败）
                .cursor, .cursor_visible, .cursor_grab, .cursor_position => return false,
                .ignore_cursor, .content_protected, .shadow, .icon => return false,
                // builtin 的 state 动作在调用 window_fn 之前已走 window_query_fn
                .state => return true,
            }
            return true;
        }

        /// 窗口状态查询 → JSON（字段名与 Windows 的 runWindowQuery 对齐，
        /// style/ex_style 等 Win32 概念在 Linux 恒为 0/false）。
        fn windowQueryEntry(backend: *anyopaque, window_id: u32, alloc: std.mem.Allocator) ?[]u8 {
            const self: *Self = @ptrCast(@alignCast(backend));
            const st = self.windowById(window_id) orelse return null;
            const win = st.win;
            const widget: [*c]c.GtkWidget = @ptrCast(win);

            var x: c.gint = 0;
            var y: c.gint = 0;
            c.gtk_window_get_position(win, &x, &y);
            var width: c.gint = 0;
            var height: c.gint = 0;
            c.gtk_window_get_size(win, &width, &height);

            var iconic = false;
            if (c.gtk_widget_get_window(widget)) |gdk_win| {
                iconic = (c.gdk_window_get_state(gdk_win) & c.GDK_WINDOW_STATE_ICONIFIED) != 0;
            }

            return std.fmt.allocPrint(alloc,
                \\{{"id":{d},"x":{d},"y":{d},"width":{d},"height":{d},"style":0,"ex_style":0,"enabled":{s},"visible":{s},"focused":{s},"zoomed":{s},"iconic":{s},"fullscreen":{s},"always_on_top":{s},"always_on_bottom":{s},"ignore_cursor":false,"focusable":{s},"content_protected":false,"overlay":false,"min_width":{d},"min_height":{d},"max_width":{d},"max_height":{d},"child_webviews":{d}}}
            , .{
                st.id,
                x,
                y,
                width,
                height,
                boolStr(c.gtk_widget_get_sensitive(widget) != 0),
                boolStr(c.gtk_widget_get_visible(widget) != 0),
                boolStr(c.gtk_window_is_active(win) != 0),
                boolStr(c.gtk_window_is_maximized(win) != 0),
                boolStr(iconic),
                boolStr(st.fullscreen),
                boolStr(st.always_on_top),
                boolStr(st.always_on_bottom),
                boolStr(c.gtk_window_get_accept_focus(win) != 0),
                st.min_width,
                st.min_height,
                st.max_width,
                st.max_height,
                st.child_webviews.items.len,
            }) catch null;
        }

        // ------------------------------------------------------------------
        // spawn_window_fn（v0.2.1 切片 3）
        // ------------------------------------------------------------------

        fn spawnWindowEntry(backend_ptr: *anyopaque, opts: ipc.WindowOptions) ?u32 {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const st = self.createWindowInternal(opts) catch |err| {
                log.print("[linux] spawn window failed: {s}", .{@errorName(err)});
                return null;
            };
            return st.id;
        }

        // ------------------------------------------------------------------
        // WebView 面（v0.2.1 切片 2，切片 3 起按 window_id 路由）
        // ------------------------------------------------------------------
        //
        // eval 双路径：
        //   - eval_async_fn（__zilt.eval，Promise 语义）：发起后立即返回，结果在
        //     后续主循环迭代经 completion 回调（builtin 的 EvalBox 负责转成事件）。
        //   - webview_request_fn 的 .eval：调用方要同步拿到结果——对应 Windows 的
        //     SyncWait + 局部消息泵，Linux 用嵌套 GMainLoop（WebKit 完成回调里
        //     quit；嵌套泵在 GTK 是合法的，模态对话框就是这么做的）。
        //   结果都是「值的 JSON 文本」（undefined → "null"），JS 异常 → JavaScriptException。

        /// JSCValue → 结果 JSON（undefined/不可序列化 → "null"）。self.allocator 分配。
        fn evalResultJson(self: *Self, value: [*c]c.JSCValue) ?[]u8 {
            if (value == null) return self.allocator.dupe(u8, "null") catch null;
            if (c.jsc_value_is_undefined(value) != 0) return self.allocator.dupe(u8, "null") catch null;
            const text = c.jsc_value_to_json(value, 0) orelse return self.allocator.dupe(u8, "null") catch null;
            defer c.g_free(@ptrCast(text));
            const span = std.mem.span(text);
            if (span.len == 0) return self.allocator.dupe(u8, "null") catch null;
            return self.allocator.dupe(u8, span) catch null;
        }

        /// WebKit eval 完成回调（窗口主 WebView 与子 WebView 共用）：
        /// completion（异步）/ 嵌套泵（同步）/ webviewEval 事件（子 WebView eval）三模式。
        fn evalFinished(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            const task: *EvalTask = @ptrCast(@alignCast(user_data orelse return));
            const self = task.backend;
            const view: [*c]c.WebKitWebView = @ptrCast(source);
            var err: [*c]c.GError = null;
            const value = c.webkit_web_view_evaluate_javascript_finish(view, res, &err);
            if (err != null) {
                const is_js = err.*.domain == c.webkit_javascript_error_quark();
                c.g_error_free(err);
                const failure: anyerror = if (is_js) error.JavaScriptException else error.WebViewCallFailed;
                if (task.child_emit) |job| return self.finishChildEval(task, job, failure, null);
                if (task.completion) |comp| {
                    comp.callback(comp.context, failure);
                    self.allocator.destroy(task);
                } else {
                    task.sync_err = failure;
                    c.g_main_loop_quit(task.loop.?);
                }
                return;
            }
            const json = self.evalResultJson(value) orelse {
                if (task.child_emit) |job| return self.finishChildEval(task, job, error.WebViewCallFailed, null);
                if (task.completion) |comp| {
                    comp.callback(comp.context, error.WebViewCallFailed);
                    self.allocator.destroy(task);
                } else {
                    task.sync_err = error.WebViewCallFailed;
                    c.g_main_loop_quit(task.loop.?);
                }
                return;
            };
            if (task.child_emit) |job| return self.finishChildEval(task, job, null, json);
            if (task.completion) |comp| {
                // JSON 只在回调期间借用：回调返回后立即释放
                comp.callback(comp.context, json);
                self.allocator.free(json);
                self.allocator.destroy(task);
            } else {
                task.sync_json = json;
                c.g_main_loop_quit(task.loop.?);
            }
        }

        /// 子 WebView eval 收尾：`webviewEval` 事件回传所属窗口（rid 匹配 Promise）。
        /// payload 形状与 Windows 对齐：{rid,id,ok,value|error}。
        fn finishChildEval(self: *Self, task: *EvalTask, job: ChildEvalJob, failure: ?anyerror, json: ?[]u8) void {
            defer self.allocator.destroy(task);
            defer if (json) |j| self.allocator.free(j);
            const w = self.windowById(job.win_id) orelse return; // 窗口已销毁
            const payload: []u8 = blk: {
                if (failure) |e| {
                    const name_json = std.json.Stringify.valueAlloc(self.allocator, @errorName(e), .{}) catch return;
                    defer self.allocator.free(name_json);
                    break :blk std.fmt.allocPrint(self.allocator, "{{\"rid\":{d},\"id\":{d},\"ok\":false,\"error\":{s}}}", .{ job.rid, job.child_id, name_json }) catch return;
                }
                break :blk std.fmt.allocPrint(self.allocator, "{{\"rid\":{d},\"id\":{d},\"ok\":true,\"value\":{s}}}", .{ job.rid, job.child_id, json.? }) catch return;
            };
            defer self.allocator.free(payload);
            const msg = ipc.encodeEvent(self.allocator, "webviewEval", payload) catch return;
            defer self.allocator.free(msg);
            // UI 线程（evalFinished 是 GTK 回调）→ 直接投递，无需 idle
            self.deliverAlloc(w.view, msg);
        }

        /// 发起异步 eval（__zilt.eval）。提交失败时不欠回调；提交成功回调恰一次。
        fn evalAsyncEntry(backend_ptr: *anyopaque, window_id: u32, script: []const u8, completion: webview.Completion) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const w = self.windowById(window_id) orelse return error.WebViewNotAvailable;
            const task = try self.allocator.create(EvalTask);
            errdefer self.allocator.destroy(task);
            task.* = .{ .backend = self, .completion = completion };
            const src = try dupeZ(self.allocator, script);
            defer self.allocator.free(src);
            // WebKit 内部会复制脚本与入参，返回后即可释放 src/task 之外的东西
            c.webkit_web_view_evaluate_javascript(w.view, src.ptr, @intCast(script.len), null, null, null, evalFinished, task);
        }

        /// 同步 eval：嵌套泵等待 WebKit 异步完成（对应 Windows 的 SyncWait）。
        fn syncEval(self: *Self, view: [*c]c.WebKitWebView, alloc: std.mem.Allocator, script: []const u8) ![]u8 {
            var task = EvalTask{ .backend = self };
            task.loop = c.g_main_loop_new(null, 0) orelse return error.WebViewCallFailed;
            defer c.g_main_loop_unref(task.loop);

            const src = try dupeZ(self.allocator, script);
            defer self.allocator.free(src);
            c.webkit_web_view_evaluate_javascript(view, src.ptr, @intCast(script.len), null, null, null, evalFinished, &task);
            c.g_main_loop_run(task.loop);

            if (task.sync_err) |e| return e;
            const json = task.sync_json orelse return try alloc.dupe(u8, "null");
            defer self.allocator.free(json);
            return try alloc.dupe(u8, json);
        }

        fn webviewRequestEntry(backend_ptr: *anyopaque, window_id: u32, alloc: std.mem.Allocator, request: webview.Request) anyerror![]u8 {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const w = self.windowById(window_id) orelse return error.WebViewNotAvailable;
            const view = w.view;

            switch (request) {
                .reload => c.webkit_web_view_reload(view),
                .stop => c.webkit_web_view_stop_loading(view),
                .back => c.webkit_web_view_go_back(view),
                .forward => c.webkit_web_view_go_forward(view),
                .zoom => |factor| {
                    if (!std.math.isFinite(factor) or factor <= 0) return error.InvalidZoom;
                    c.webkit_web_view_set_zoom_level(view, factor);
                },
                .get_zoom => {
                    return try std.fmt.allocPrint(alloc, "{{\"factor\":{d}}}", .{c.webkit_web_view_get_zoom_level(view)});
                },
                .history => {
                    // 与 Windows 对齐：{"can_go_back":b,"can_go_forward":b}
                    const bfl = c.webkit_web_view_get_back_forward_list(view);
                    const can_back = bfl != null and c.webkit_back_forward_list_get_back_item(bfl) != null;
                    const can_fwd = bfl != null and c.webkit_back_forward_list_get_forward_item(bfl) != null;
                    return try std.fmt.allocPrint(alloc, "{{\"can_go_back\":{s},\"can_go_forward\":{s}}}", .{
                        boolStr(can_back),
                        boolStr(can_fwd),
                    });
                },
                .devtools => {
                    if (!config.webview.settings.devtools) return error.DevToolsDisabled;
                    const settings = c.webkit_web_view_get_settings(view);
                    if (settings == null) return error.WebViewCallFailed;
                    c.webkit_settings_set_enable_developer_extras(settings, 1);
                    c.webkit_web_inspector_show(c.webkit_web_view_get_inspector(view));
                },
                .set_user_agent => |ua| {
                    const settings = c.webkit_web_view_get_settings(view);
                    if (settings == null) return error.WebViewCallFailed;
                    if (ua.len == 0) {
                        // 空串 = 恢复引擎默认（WebKit 文档：NULL/空 → 默认 UA）
                        c.webkit_settings_set_user_agent(settings, null);
                    } else {
                        const z = try dupeZ(self.allocator, ua);
                        defer self.allocator.free(z);
                        c.webkit_settings_set_user_agent(settings, z.ptr);
                    }
                },
                .eval => |e| return self.syncEval(view, alloc, e.script),
                // 后续切片：print/cdp/下载/cookies/clear_storage
                .print, .cdp, .cancel_download, .cookies, .clear_storage => return error.NotSupported,
            }
            return try alloc.dupe(u8, "null");
        }

        // ------------------------------------------------------------------
        // system_fn（v0.2.1 切片 3）：目前只接 .webviews
        // ------------------------------------------------------------------

        fn systemEntry(
            backend_ptr: *anyopaque,
            window_id: u32,
            alloc: std.mem.Allocator,
            req: system_api.Request,
        ) anyerror!system_api.Result {
            const self: *Self = @ptrCast(@alignCast(backend_ptr));
            const w = self.windowById(window_id) orelse return error.WindowNotFound;
            switch (req) {
                .webviews => |op| return self.runWebviewsOp(w, op, alloc),
                // 菜单/托盘/快捷键/http/ws/fs/... 属 v0.2.2–v0.2.3；NotSupported
                // 与 Windows 的降级语义同构（platform/interface.zig 契约不受影响）
                else => return error.NotSupported,
            }
        }

        /// 子 WebView 面：create/remove/navigate/setBounds/focus/list/eval。
        /// create 同步建 WebView（WebKitGTK 无 WebView2 的异步 controller 概念，
        /// ready 恒为 true）；eval 立即返回 pending，结果经 webviewEval 事件回传。
        fn runWebviewsOp(self: *Self, w: *WinState, op: system_api.WebviewsOp, alloc: std.mem.Allocator) !system_api.Result {
            switch (op) {
                .create => |req| {
                    if (req.width <= 0 or req.height <= 0) return error.InvalidWindowSize;
                    const id = w.next_child_webview_id;
                    w.next_child_webview_id += 1;

                    // 数据分区（同名复用已有 context）
                    var part_name: ?[]u8 = null;
                    defer if (part_name) |p| self.allocator.free(p);
                    if (req.partition) |raw| {
                        if (raw.len > 0) part_name = try sanitizePartition(self.allocator, raw);
                    }

                    var web_ctx: ?[*c]c.WebKitWebContext = null;
                    if (part_name) |pname| {
                        if (self.findPartition(pname)) |existing| {
                            web_ctx = existing;
                            log.print("[webviews] child #{d} reuse partition '{s}'", .{ id, pname });
                        } else {
                            web_ctx = try self.createPartitionContext(pname);
                            // 注册失败要释放刚建的 context（OOM 路径不留悬挂引用）
                            const name_copy = self.allocator.dupe(u8, pname) catch |dup_err| {
                                c.g_object_unref(@ptrCast(web_ctx.?));
                                return dup_err;
                            };
                            self.partitions.append(self.allocator, .{ .name = name_copy, .ctx = web_ctx.? }) catch |append_err| {
                                self.allocator.free(name_copy);
                                c.g_object_unref(@ptrCast(web_ctx.?));
                                return append_err;
                            };
                        }
                    }

                    const ucm = c.webkit_user_content_manager_new() orelse return error.UserContentManagerFailed;
                    const sink = try self.allocator.create(IpcSink);
                    errdefer self.allocator.destroy(sink);
                    sink.* = .{ .backend = self, .win_id = w.id, .view = null };

                    // 分区 → 独立 context；无分区 → 默认 context（scheme 处理器已注册）。
                    // 本 WebKit2GTK 头文件没有 new_with_user_content_manager_and_context，
                    // 分区路径用 view 自带的 UCM（register handler / add script 等效）。
                    const view_widget: [*c]c.GtkWidget = if (web_ctx) |wctx|
                        @ptrCast(c.webkit_web_view_new_with_context(wctx))
                    else
                        @ptrCast(c.webkit_web_view_new_with_user_content_manager(ucm));
                    if (view_widget == null) return error.WebViewCreateFailed;
                    const view: [*c]c.WebKitWebView = @ptrCast(view_widget);
                    sink.view = view;
                    const view_ucm: [*c]c.WebKitUserContentManager = if (web_ctx != null)
                        c.webkit_web_view_get_user_content_manager(view)
                    else
                        ucm;

                    const cv = try self.allocator.create(ChildView);
                    errdefer self.allocator.destroy(cv);
                    cv.* = .{
                        .id = id,
                        .view = view,
                        .ucm = view_ucm,
                        .sink = sink,
                        .partition = if (part_name) |p| try self.allocator.dupe(u8, p) else null,
                        .x = req.x,
                        .y = req.y,
                        .width = req.width,
                        .height = req.height,
                    };
                    self.attachIpc(sink, view_ucm, &cv.scripts);

                    try w.child_webviews.append(self.allocator, cv);

                    // 布局：作为 overlay child 挂进窗口内容区（位置由
                    // get-child-position 信号按 cv.x/y/width/height 提供）
                    c.gtk_overlay_add_overlay(@ptrCast(w.overlay), view_widget);
                    c.gtk_widget_show(view_widget);

                    // 目标 URL（空 = about:blank，对齐 Windows）
                    if (req.url.len > 0) {
                        const uri = try mapAppUrl(alloc, req.url);
                        defer alloc.free(uri);
                        const uri_z = try dupeZ(self.allocator, uri);
                        defer self.allocator.free(uri_z);
                        c.webkit_web_view_load_uri(view, uri_z.ptr);
                    }
                    log.print("[webviews] child #{d} created on window #{d} ({d}x{d}@{d},{d}) partition={s}", .{
                        id,
                        w.id,
                        req.width,
                        req.height,
                        req.x,
                        req.y,
                        cv.partition orelse "-",
                    });
                    if (cv.partition) |p| {
                        const pj = try std.json.Stringify.valueAlloc(alloc, p, .{});
                        return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"partition\":{s},\"queued\":false}}", .{ id, pj }) };
                    }
                    return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d}}}", .{id}) };
                },
                .remove => |id| {
                    for (w.child_webviews.items, 0..) |cv, i| {
                        if (cv.id == id) {
                            _ = w.child_webviews.swapRemove(i);
                            c.gtk_widget_destroy(@ptrCast(cv.view)); // UCM/信号随 view 释放
                            self.freeChildView(cv);
                            log.print("[webviews] child #{d} removed (window #{d})", .{ id, w.id });
                            return .{ .ok = true };
                        }
                    }
                    return .{ .ok = false };
                },
                .navigate => |req| {
                    if (req.url.len == 0) return .{ .ok = false };
                    const cv = childViewById(w, req.id) orelse return .{ .ok = false };
                    const uri = try mapAppUrl(alloc, req.url);
                    defer alloc.free(uri);
                    const uri_z = try dupeZ(self.allocator, uri);
                    defer self.allocator.free(uri_z);
                    c.webkit_web_view_load_uri(cv.view, uri_z.ptr);
                    log.print("[webviews] child #{d} navigate {s}", .{ req.id, uri });
                    return .{ .ok = true };
                },
                .set_bounds => |req| {
                    const cv = childViewById(w, req.id) orelse return .{ .ok = false };
                    cv.x = req.x;
                    cv.y = req.y;
                    cv.width = req.width;
                    cv.height = req.height;
                    // 重新触发 overlay 的 get-child-position
                    c.gtk_widget_queue_resize(@ptrCast(cv.view));
                    return .{ .ok = true };
                },
                .focus => |id| {
                    const cv = childViewById(w, id) orelse return .{ .ok = false };
                    c.gtk_widget_grab_focus(@ptrCast(cv.view));
                    return .{ .ok = true };
                },
                .list => {
                    // 与 Windows 对齐：[{id, ready, partition}]
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(alloc);
                    try out.append(alloc, '[');
                    for (w.child_webviews.items, 0..) |cv, i| {
                        if (i != 0) try out.append(alloc, ',');
                        const pj = if (cv.partition) |p|
                            try std.json.Stringify.valueAlloc(alloc, p, .{})
                        else
                            try alloc.dupe(u8, "null");
                        defer alloc.free(pj);
                        const chunk = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"ready\":true,\"partition\":{s}}}", .{ cv.id, pj });
                        defer alloc.free(chunk);
                        try out.appendSlice(alloc, chunk);
                    }
                    try out.append(alloc, ']');
                    return .{ .json = try out.toOwnedSlice(alloc) };
                },
                .eval => |req| {
                    const cv = childViewById(w, req.id) orelse return .{ .ok = false };
                    // 异步：立即返回 pending，结果经 webviewEval 事件回传（对齐 Windows）
                    const task = try self.allocator.create(EvalTask);
                    errdefer self.allocator.destroy(task);
                    task.* = .{ .backend = self, .child_emit = .{
                        .win_id = w.id,
                        .child_id = cv.id,
                        .rid = req.rid,
                    } };
                    const src = try dupeZ(self.allocator, req.script);
                    defer self.allocator.free(src);
                    // WebKit 内部复制脚本；完成回调里查注册表路由（窗口/子已销毁则丢弃）
                    c.webkit_web_view_evaluate_javascript(cv.view, src.ptr, @intCast(req.script.len), null, null, null, evalFinished, task);
                    return .{ .json = try std.fmt.allocPrint(alloc, "{{\"pending\":true,\"rid\":{d}}}", .{req.rid}) };
                },
            }
        }

        // ------------------------------------------------------------------
        // 消息处理
        // ------------------------------------------------------------------

        fn handleMessage(self: *Self, sink: *IpcSink, raw: []const u8) !void {
            const w = self.windowById(sink.win_id) orelse return;
            // per-message arena：命令期间的分配随响应发出后统一释放
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const ctx = self.context(arena.allocator(), w.id);

            var decoded = try ipc.decode(self.allocator, raw);
            defer decoded.deinit();

            const enforce_acl = config.security.capabilities.len != 0;
            const source = currentUri(sink.view, w.app_url);

            switch (decoded.msg) {
                .invoke => |inv| {
                    log.print("[ipc] invoke {s} (id={d}, window={d})", .{ inv.method, inv.id, w.id });

                    // 框架内部：冒烟结果回传（不经过应用命令表，也不受 ACL 约束）
                    if (std.mem.eql(u8, inv.method, "__zilt.linuxSmoke")) {
                        self.finishSmoke(inv.args_json);
                        return;
                    }

                    if (enforce_acl and !security.allowed(
                        aclOptions(),
                        w.app_url,
                        null,
                        source,
                        w.label,
                        .command,
                        inv.method,
                    )) {
                        log.print("[acl] command '{s}' denied (window={s}, source={s})", .{ inv.method, w.label, source });
                        return self.reject(sink.view, inv.id, "PermissionDenied");
                    }

                    const result_json: []u8 = blk: {
                        if (builtin_cmds.dispatch(ctx, inv.method, inv.args_json)) |maybe| {
                            if (maybe) |json| break :blk json;
                        } else |err| {
                            log.print("[ipc] builtin {s} failed: {s}", .{ inv.method, @errorName(err) });
                            return self.reject(sink.view, inv.id, @errorName(err));
                        }
                        break :blk ipc.dispatch(config.commands, ctx, inv.method, inv.args_json) catch |err| {
                            log.print("[ipc] invoke {s} failed: {s}", .{ inv.method, @errorName(err) });
                            return self.reject(sink.view, inv.id, @errorName(err));
                        };
                    };

                    const resp = try ipc.encodeResolve(self.allocator, inv.id, result_json);
                    defer self.allocator.free(resp);
                    self.deliverAlloc(sink.view, resp);
                },
                .event => |ev| {
                    if (enforce_acl and !security.allowed(
                        aclOptions(),
                        w.app_url,
                        null,
                        source,
                        w.label,
                        .event,
                        ev.name,
                    )) {
                        log.print("[acl] event '{s}' denied (window={s}, source={s})", .{ ev.name, w.label, source });
                        return;
                    }
                    if (!ipc.dispatchEvent(config.events, ctx, ev.name, ev.payload_json)) {
                        log.print("[ipc] event '{s}' (no handler)", .{ev.name});
                    }
                },
                .ignore => {},
            }
        }

        fn reject(self: *Self, view: [*c]c.WebKitWebView, id: u64, err_name: []const u8) void {
            const resp = ipc.encodeReject(self.allocator, id, err_name) catch return;
            defer self.allocator.free(resp);
            self.deliverAlloc(view, resp);
        }

        /// 页面加载完成后自检：runtime_js 是否注入、messageHandlers 是否注册。
        /// 这两项任一为 false，前端所有 invoke 都会静默失败——所以显式记一行日志。
        fn diagnoseRuntime(self: *Self, view: [*c]c.WebKitWebView) void {
            // 诊断三元组：runtime 是否可用 / 首屏检查结果 / 页面是否已跑过 runChecks
            const script =
                "(() => {" ++
                "  const el = (id) => { const n = document.getElementById(id); return n ? (n.className + ':' + n.textContent) : 'missing'; };" ++
                "  return ['ready=' + document.readyState, 'greet=' + el('c-greet'), 'add=' + el('c-add')].join(' ');" ++
                "})()";
            c.webkit_web_view_evaluate_javascript(
                view,
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
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return));
            sink.backend.diagnoseRuntime(sink.view);
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

        fn currentUri(view: [*c]c.WebKitWebView, fallback: []const u8) []const u8 {
            if (view == null) return fallback;
            const uri = c.webkit_web_view_get_uri(view);
            if (uri == null) return fallback;
            return std.mem.span(uri);
        }

        // ------------------------------------------------------------------
        // scheme 资产服务
        // ------------------------------------------------------------------

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

        // ------------------------------------------------------------------
        // GLib 回调（必须 callconv(.c)；放在泛型作用域内才能看到 config/Self）
        // ------------------------------------------------------------------

        /// 窗口销毁：从注册表摘除 → 级联关闭子窗口 → 全部关闭才退出主循环。
        /// （对齐 Windows「全部关闭才退出消息泵」；GTK 无 WS_CHILD 级联，父子
        /// 关系由注册表维护。控件树（fixed/主 WebView/子 WebView/UCM）由 GTK
        /// 随 destroy 一并释放，这里只释放 Zig 侧记录。）
        fn onDestroy(_: [*c]c.GtkWidget, user_data: c.gpointer) callconv(.c) void {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return));
            const self = st.backend;
            const closed_id = st.id;
            log.print("[linux] window #{d} destroyed (label={s}, children={d})", .{
                st.id,
                st.label,
                st.child_webviews.items.len,
            });
            self.freeWindowState(st);
            // 父销毁级联关子窗口（子窗口的 destroy 会重入本回调并自行摘除）
            while (self.findWindowByParent(closed_id)) |child| {
                log.print("[linux] cascade close window #{d} (parent #{d} gone)", .{ child.id, closed_id });
                c.gtk_widget_destroy(@ptrCast(child.win));
            }
            // 全部窗口都销毁才 gtk_main_quit
            if (self.windows.items.len == 0) {
                log.print("[linux] all windows destroyed -> quit main loop", .{});
                c.gtk_main_quit();
            }
        }

        /// GtkOverlay 的 get-child-position：子 WebView 按存储的布局矩形放置。
        /// 返回 TRUE 表示已处理（不用 GTK 默认的边缘对齐位置）。
        fn onChildPosition(
            _: [*c]c.GtkOverlay,
            widget: [*c]c.GtkWidget,
            allocation: [*c]c.GdkRectangle,
            user_data: c.gpointer,
        ) callconv(.c) c.gboolean {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return 0));
            for (st.child_webviews.items) |cv| {
                if (@as([*c]c.GtkWidget, @ptrCast(cv.view)) == widget) {
                    allocation.*.x = cv.x;
                    allocation.*.y = cv.y;
                    allocation.*.width = cv.width;
                    allocation.*.height = cv.height;
                    return 1;
                }
            }
            return 0;
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
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return));
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

            sink.backend.handleMessage(sink, raw) catch |err| {
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

test "sanitizePartition: 安全字符保留、其余替换、截断与空名兜底" {
    const a = try sanitizePartition(testing.allocator, "alpha-01");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("alpha-01", a);

    const b = try sanitizePartition(testing.allocator, "a b/c.d");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("a_b_c_d", b);

    // 超长截断到 64
    var long_buf: [100]u8 = undefined;
    @memset(&long_buf, 'x');
    const c1 = try sanitizePartition(testing.allocator, &long_buf);
    defer testing.allocator.free(c1);
    try testing.expectEqual(@as(usize, 64), c1.len);
    for (c1) |ch| try testing.expect(ch == 'x');

    // 全空 → "default"
    const d = try sanitizePartition(testing.allocator, "***");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("___", d);

    const e = try sanitizePartition(testing.allocator, "");
    defer testing.allocator.free(e);
    try testing.expectEqualStrings("default", e);
}
