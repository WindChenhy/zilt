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
//!   - v0.2.1 切片 4：WebView 数据面补齐——
//!     * **下载**：WebKitWebContext::download-started → 目标路径（save_directory >
//!       show_dialog 原生保存框 > $HOME/Downloads；重名追加 " (n)"，不静默覆盖）
//!       → received-data（32KB 节流）/finished/failed → `webview.download_*` 事件
//!       （payload 对齐 Windows：started {id,url,path}；其余 {id,received,total,
//!       interrupt_reason}）；`cancel_download` 未知 id 返回 UnknownDownload。
//!     * **cookies**：WebKitCookieManager 的 get/set/delete/按域名清理
//!       （异步 API 用嵌套 GMainLoop 同步化；返回 {"cookies":[…]} 与 Windows 同形）。
//!     * **clear_storage**：WebKitWebsiteDataManager::clear（本版为全来源清理，
//!       origin 参数不参与过滤——超集语义，已在 docs/v0.2-LINUX.md 标注）。
//!     * **截图**：WebKit 无 CDP，仅支持 `Page.captureScreenshot`（PNG）——
//!       webkit_web_view_get_snapshot + cairo PNG + base64 → `webviewCdp` 事件，
//!       runtime 的 captureScreenshot 无需改动；其余 CDP 方法 NotSupported。
//!     * **窗口状态持久化**：`window_state.zig`（与 Windows app_data 同格式/同
//!       哈希文件名）→ state_key / persist_window_state 在创建时恢复、销毁时保存；
//!       `window.zilt.windowState.get/save` 走 system_fn 的 `.window_state` op。
//!     print 仍返回 NotSupported（P2，见能力清单）。
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
//!     剪贴板 / 通知 / 对话框 / 托盘 / 菜单 / 快捷键 / http/ws/fs/SQL。
//!     这些属于 v0.2.2–v0.2.3，`platform/interface.zig` 的能力矩阵逐项打勾。
//!   - 冒烟（ZILT_LINUX_SMOKE=1）：40 项检查。WSLg 环境必须 `GDK_BACKEND=x11`
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
const window_state = @import("window_state.zig");
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

/// JSON 字符串字面量（含引号）；调用方 free。
fn jsonStr(alloc: std.mem.Allocator, s: []const u8) ?[]u8 {
    return std.json.Stringify.valueAlloc(alloc, s, .{}) catch null;
}

/// URL 的 host 部分（"https://user@example.com:8443/x" → "example.com"）；
/// 无 scheme/host 返回 null。cookie domain 推导用。
fn hostOf(url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    var rest = url[sep + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..end];
    if (std.mem.startsWith(u8, host, "[")) {
        // IPv6 字面量：保留方括号（去掉 ":port"）
        if (std.mem.indexOfScalar(u8, host, ']')) |close| host = host[0 .. close + 1];
    } else if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        host = host[0..colon];
    }
    if (host.len == 0) return null;
    return host;
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
    // v0.2.1：下载事件（分区 context 在 createPartitionContext 里同样注册）
    _ = c.g_signal_connect_data(wc, "download-started", @ptrCast(&Self.onDownloadStarted), self, null, 0);

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
    // 主循环退出时窗口通常还没 destroy（ctx.quit 路径）→ 逐窗口落盘状态
    for (self.windows.items) |st| self.saveWindowState(st);
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
            /// 窗口状态持久化键（null = 不持久化；配置 persist_window_state 时 = label）
            state_key: ?[]u8 = null,
            /// 最近一次 configure 的几何（destroy 时 gtk_window_get_size 可能已失效，
            /// 保存状态读这里；主循环退出前也用它）
            geom_x: i32 = 0,
            geom_y: i32 = 0,
            geom_width: u32 = 0,
            geom_height: u32 = 0,
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

        /// 进行中的下载（v0.2.1）。WebKit 持有 WebKitDownload 的所有权，
        /// 我们只记 id + 上次上报的进度（节流）。
        const Download = struct {
            backend: *Self,
            id: u64,
            dl: [*c]c.WebKitDownload,
            total: i64 = -1,
            last_progress: u64 = 0,
            /// 三个信号的处理 id：终止事件到达后先断开再释放记录。
            /// 实测 WebKit 失败时还会补一个 finished，不断开会二次进回调 → UAF。
            received_handler: c.gulong = 0,
            finished_handler: c.gulong = 0,
            failed_handler: c.gulong = 0,
        };

        /// 异步等待任务（cookies / clear_storage 需要嵌套主循环同步取结果）。
        const WaitTask = struct {
            backend: *Self,
            loop: ?*c.GMainLoop = null,
            json: ?[]u8 = null,
            failed: bool = false,
        };

        /// 截图任务：webkit_web_view_get_snapshot → PNG → base64 → webviewCdp 事件。
        const SnapshotTask = struct {
            backend: *Self,
            win_id: u32,
            rid: i64,
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
        /// 进行中的下载（v0.2.1）
        downloads: std.ArrayListUnmanaged(*Download) = .empty,
        next_download_id: u64 = 1,

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
            for (self.downloads.items) |d| self.allocator.destroy(d);
            self.downloads.deinit(self.allocator);
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
            if (st.state_key) |key| self.allocator.free(key);
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
            _ = c.g_signal_connect_data(ctx, "download-started", @ptrCast(&Self.onDownloadStarted), self, null, 0);
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

            // 窗口状态键：显式 state_key 优先；persist_window_state 时按 label
            //（与 Windows 的 createWindow 一致）
            const state_key: ?[]u8 = if (opts.state_key) |key|
                try self.allocator.dupe(u8, key)
            else if (config.persist_window_state)
                try self.allocator.dupe(u8, label)
            else
                null;
            errdefer if (state_key) |key| self.allocator.free(key);

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
                .state_key = state_key,
                .geom_x = opts.x orelse 0,
                .geom_y = opts.y orelse 0,
                .geom_width = opts.width,
                .geom_height = opts.height,
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

            // 窗口状态恢复（v0.2.1）：位置/尺寸/最大化/全屏覆盖 opts 默认值
            self.restoreWindowState(st);

            const url_z = try dupeZ(self.allocator, app_url);
            defer self.allocator.free(url_z);
            c.webkit_web_view_load_uri(view, url_z.ptr);

            try self.windows.append(self.allocator, st);
            self.next_window_id = id + 1;

            // 注册成功后才接窗口级信号：destroy 处理器会解引用 st，
            // 之前的错误路径（errdefer destroy(st)）绝不能有 destroy 处理器存活。
            _ = c.g_signal_connect_data(win, "destroy", @ptrCast(&Self.onDestroy), st, null, 0);
            _ = c.g_signal_connect_data(win, "configure-event", @ptrCast(&Self.onConfigureEvent), st, null, 0);
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
                .size => |s| {
                    c.gtk_window_resize(win, @intCast(s.width), @intCast(s.height));
                    // 跟踪值同步：窗口状态持久化在 destroy 期间查不到真实几何
                    st.geom_width = s.width;
                    st.geom_height = s.height;
                },
                .position => |p| {
                    c.gtk_window_move(win, p.x, p.y);
                    st.geom_x = p.x;
                    st.geom_y = p.y;
                },
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
        // 窗口状态持久化（v0.2.1；对齐 Windows 的 app_data 语义）
        // ------------------------------------------------------------------

        /// 当前窗口几何：**configure 跟踪值优先**。
        /// 实测：destroy 信号里 gtk_window_get_size/get_position 会退化到创建时的
        /// 默认值（0,0 / 初始 width×height），拿它保存会把用户调整后的几何丢掉；
        /// 跟踪值由 configure-event + 程序化 resize/move 命令共同维护。
        fn currentGeometry(self: *Self, st: *WinState) window_state.State {
            _ = self;
            var query_w: c.gint = 0;
            var query_h: c.gint = 0;
            c.gtk_window_get_size(st.win, &query_w, &query_h);
            const width: u32 = if (st.geom_width > 0)
                st.geom_width
            else if (query_w > 0)
                @intCast(query_w)
            else
                0;
            const height: u32 = if (st.geom_height > 0)
                st.geom_height
            else if (query_h > 0)
                @intCast(query_h)
            else
                0;
            return .{
                .x = st.geom_x,
                .y = st.geom_y,
                .width = width,
                .height = height,
                .maximized = c.gtk_window_is_maximized(st.win) != 0,
                .fullscreen = st.fullscreen,
            };
        }

        fn saveWindowState(self: *Self, st: *WinState) void {
            const key = st.state_key orelse return;
            const root = self.appDataRoot() orelse return;
            defer self.allocator.free(root);
            const state = self.currentGeometry(st);
            if (state.width == 0 or state.height == 0) return;
            window_state.save(self.allocator, root, key, state) catch |err| {
                log.print("[state] save failed: {s}", .{@errorName(err)});
                return;
            };
            log.print("[state] saved window #{d} ({s}) {d},{d} {d}x{d} max={} full={}", .{
                st.id, key, state.x, state.y, state.width, state.height, state.maximized, state.fullscreen,
            });
        }

        fn restoreWindowState(self: *Self, st: *WinState) void {
            const key = st.state_key orelse return;
            const root = self.appDataRoot() orelse return;
            defer self.allocator.free(root);
            const state = (window_state.load(self.allocator, root, key) catch |err| {
                log.print("[state] load failed: {s}", .{@errorName(err)});
                return;
            }) orelse return;
            if (state.width == 0 or state.height == 0) return;
            c.gtk_window_resize(st.win, @intCast(state.width), @intCast(state.height));
            c.gtk_window_move(st.win, state.x, state.y);
            st.geom_x = state.x;
            st.geom_y = state.y;
            st.geom_width = state.width;
            st.geom_height = state.height;
            if (state.maximized) c.gtk_window_maximize(st.win);
            if (state.fullscreen) {
                c.gtk_window_fullscreen(st.win);
                st.fullscreen = true;
            }
            log.print("[state] restored window #{d} ({s}) {d},{d} {d}x{d} max={} full={}", .{
                st.id, key, state.x, state.y, state.width, state.height, state.maximized, state.fullscreen,
            });
        }

        fn runWindowStateOp(self: *Self, w: *WinState, op: system_api.WindowStateOp, alloc: std.mem.Allocator) !system_api.Result {
            switch (op) {
                .save => {
                    self.saveWindowState(w);
                    log.print("[window-state] saved on demand", .{});
                    return .{ .ok = true };
                },
                .get => {
                    const s = self.currentGeometry(w);
                    return .{ .json = try std.fmt.allocPrint(
                        alloc,
                        "{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"maximized\":{}}}",
                        .{ s.x, s.y, s.width, s.height, s.maximized },
                    ) };
                },
            }
        }

        // ------------------------------------------------------------------
        // 下载（v0.2.1）：WebKitWebContext::download-started → 目标路径 →
        // received-data / finished / failed → webview.download_* 事件
        // ------------------------------------------------------------------

        /// 下载目标目录：显式 save_directory > $HOME/Downloads。
        fn defaultDownloadDir(self: *Self) ![]u8 {
            if (config.webview.downloads.save_directory) |dir| return self.allocator.dupe(u8, dir);
            const home = std.c.getenv("HOME") orelse return error.DownloadDirUnavailable;
            const safe = std.mem.span(home);
            if (safe.len == 0) return error.DownloadDirUnavailable;
            return std.fmt.allocPrint(self.allocator, "{s}/Downloads", .{safe});
        }

        /// 取 suggested filename 的最后一段（防目录穿越；空 → download-<id>）。
        fn downloadFilename(self: *Self, suggested: []const u8, id: u64) ![]u8 {
            const trimmed = std.mem.trim(u8, suggested, " \t\r\n");
            const base = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| trimmed[i + 1 ..] else trimmed;
            if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
                return std.fmt.allocPrint(self.allocator, "download-{d}", .{id});
            }
            return self.allocator.dupe(u8, base);
        }

        /// 目标文件已存在时追加 " (n)"（不静默覆盖；对齐 Windows 的显式目标语义）。
        fn uniqueDownloadPath(self: *Self, dir: []const u8, name: []const u8) ![]u8 {
            const first = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, name });
            if (!window_state.fileExists(first)) return first;
            defer self.allocator.free(first);
            const dot = std.mem.lastIndexOfScalar(u8, name, '.');
            var n: u32 = 1;
            while (n < 1000) : (n += 1) {
                const candidate = if (dot) |i|
                    try std.fmt.allocPrint(self.allocator, "{s}/{s} ({d}){s}", .{ dir, name[0..i], n, name[i..] })
                else
                    try std.fmt.allocPrint(self.allocator, "{s}/{s} ({d})", .{ dir, name, n });
                if (!window_state.fileExists(candidate)) return candidate;
                self.allocator.free(candidate);
            }
            return error.DownloadDestinationExists;
        }

        /// show_dialog=true 时的原生保存对话框；取消返回 null。
        fn chooseSavePath(self: *Self, suggested: []const u8) !?[]u8 {
            const title_z = try dupeZ(self.allocator, "Save File");
            defer self.allocator.free(title_z);
            const dlg = c.gtk_file_chooser_dialog_new(
                title_z.ptr,
                null,
                c.GTK_FILE_CHOOSER_ACTION_SAVE,
                "_Cancel",
                c.GTK_RESPONSE_CANCEL,
                "_Save",
                c.GTK_RESPONSE_ACCEPT,
                @as(?*anyopaque, null),
            );
            if (dlg == null) return error.DialogFailed;
            defer c.gtk_widget_destroy(dlg);
            const chooser: [*c]c.GtkFileChooser = @ptrCast(dlg);
            const name_z = try dupeZ(self.allocator, suggested);
            defer self.allocator.free(name_z);
            c.gtk_file_chooser_set_current_name(chooser, name_z.ptr);
            c.gtk_file_chooser_set_do_overwrite_confirmation(chooser, 1);
            if (c.gtk_dialog_run(@ptrCast(dlg)) != c.GTK_RESPONSE_ACCEPT) return null;
            const chosen = c.gtk_file_chooser_get_filename(chooser);
            if (chosen == null) return null;
            defer c.g_free(@ptrCast(chosen));
            return try self.allocator.dupe(u8, std.mem.span(chosen));
        }

        fn onDownloadStarted(_: [*c]c.WebKitWebContext, download: [*c]c.WebKitDownload, user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            if (!config.webview.downloads.enabled or download == null) return;

            const id = self.next_download_id;
            self.next_download_id += 1;

            const req = c.webkit_download_get_request(download);
            const uri_ptr = if (req != null) c.webkit_uri_request_get_uri(req) else null;
            const url = if (uri_ptr != null) std.mem.span(uri_ptr) else "";

            const resp = c.webkit_download_get_response(download);
            const suggested_ptr = if (resp != null) c.webkit_uri_response_get_suggested_filename(resp) else null;
            const suggested = if (suggested_ptr != null) std.mem.span(suggested_ptr) else "";
            const content_length: u64 = if (resp != null) c.webkit_uri_response_get_content_length(resp) else 0;
            const total: i64 = if (content_length > 0 and content_length <= std.math.maxInt(i64)) @intCast(content_length) else -1;

            const name = self.downloadFilename(suggested, id) catch return;
            defer self.allocator.free(name);

            var path: ?[]u8 = null;
            if (config.webview.downloads.show_dialog and config.webview.downloads.save_directory == null) {
                path = self.chooseSavePath(name) catch null;
                if (path == null) {
                    // 用户取消保存对话框：取消下载且不发事件（等价于没开始过）
                    c.webkit_download_cancel(download);
                    log.print("[download] cancelled by save dialog", .{});
                    return;
                }
            } else {
                const dir = self.defaultDownloadDir() catch |err| {
                    log.print("[download] no destination dir: {s}", .{@errorName(err)});
                    c.webkit_download_cancel(download);
                    return;
                };
                defer self.allocator.free(dir);
                makeDirPath(self.allocator, dir);
                path = self.uniqueDownloadPath(dir, name) catch |err| {
                    log.print("[download] destination failed: {s}", .{@errorName(err)});
                    c.webkit_download_cancel(download);
                    return;
                };
            }
            defer if (path) |p| self.allocator.free(p);
            const dest = path orelse return;

            const dest_z = dupeZ(self.allocator, dest) catch return;
            defer self.allocator.free(dest_z);
            c.webkit_download_set_destination(download, dest_z.ptr);

            const d = self.allocator.create(Download) catch return;
            d.* = .{ .backend = self, .id = id, .dl = download, .total = total };
            self.downloads.append(self.allocator, d) catch {
                self.allocator.destroy(d);
                c.webkit_download_cancel(download);
                return;
            };
            d.received_handler = c.g_signal_connect_data(@ptrCast(download), "received-data", @ptrCast(&Self.onDownloadReceived), d, null, 0);
            d.finished_handler = c.g_signal_connect_data(@ptrCast(download), "finished", @ptrCast(&Self.onDownloadFinished), d, null, 0);
            d.failed_handler = c.g_signal_connect_data(@ptrCast(download), "failed", @ptrCast(&Self.onDownloadFailed), d, null, 0);

            log.print("[download] #{d} started: {s} -> {s} (total={d})", .{ id, url, dest, total });
            self.emitDownloadStarted(d, url, dest);
        }

        fn onDownloadReceived(_: [*c]c.WebKitDownload, _: c.guint64, user_data: c.gpointer) callconv(.c) void {
            const d: *Download = @ptrCast(@alignCast(user_data orelse return));
            const received = c.webkit_download_get_received_data_length(d.dl);
            // 节流：WebKit 每个数据块都发信号，只按 32KB 步进上报
            if (received < d.last_progress + 32 * 1024) return;
            d.last_progress = received;
            d.backend.emitDownloadProgress(d, "webview.download_progress", 0);
        }

        fn onDownloadFinished(_: [*c]c.WebKitDownload, user_data: c.gpointer) callconv(.c) void {
            const d: *Download = @ptrCast(@alignCast(user_data orelse return));
            const received = c.webkit_download_get_received_data_length(d.dl);
            d.backend.disconnectDownloadSignals(d);
            log.print("[download] #{d} completed ({d}/{d} bytes)", .{ d.id, received, d.total });
            d.backend.emitDownloadProgress(d, "webview.download_completed", received);
            d.backend.removeDownload(d);
        }

        fn onDownloadFailed(_: [*c]c.WebKitDownload, err: [*c]c.GError, user_data: c.gpointer) callconv(.c) void {
            const d: *Download = @ptrCast(@alignCast(user_data orelse return));
            const received = c.webkit_download_get_received_data_length(d.dl);
            d.backend.disconnectDownloadSignals(d);
            const reason = if (err != null) std.mem.span(err.*.message) else "unknown";
            log.print("[download] #{d} failed: {s}", .{ d.id, reason });
            d.backend.emitDownloadProgress(d, "webview.download_failed", received);
            d.backend.removeDownload(d);
        }

        /// 终止事件后立刻断开三个信号（重复调用安全）。
        fn disconnectDownloadSignals(self: *Self, d: *Download) void {
            _ = self;
            if (d.received_handler != 0) {
                c.g_signal_handler_disconnect(@ptrCast(d.dl), d.received_handler);
                d.received_handler = 0;
            }
            if (d.finished_handler != 0) {
                c.g_signal_handler_disconnect(@ptrCast(d.dl), d.finished_handler);
                d.finished_handler = 0;
            }
            if (d.failed_handler != 0) {
                c.g_signal_handler_disconnect(@ptrCast(d.dl), d.failed_handler);
                d.failed_handler = 0;
            }
        }

        fn emitDownloadStarted(self: *Self, d: *Download, url: []const u8, path: []const u8) void {
            const w = self.windowForView(c.webkit_download_get_web_view(d.dl)) orelse return;
            const url_json = std.json.Stringify.valueAlloc(self.allocator, url, .{}) catch return;
            defer self.allocator.free(url_json);
            const path_json = std.json.Stringify.valueAlloc(self.allocator, path, .{}) catch return;
            defer self.allocator.free(path_json);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"url\":{s},\"path\":{s}}}", .{ d.id, url_json, path_json }) catch return;
            defer self.allocator.free(payload);
            const msg = ipc.encodeEvent(self.allocator, "webview.download_started", payload) catch return;
            defer self.allocator.free(msg);
            self.deliverAlloc(w.view, msg);
        }

        /// 进度/完成/失败三类事件（payload 与 Windows 对齐：
        /// {id, received, total, interrupt_reason}；失败时 interrupt_reason=1）。
        fn emitDownloadProgress(self: *Self, d: *Download, name: []const u8, received_override: u64) void {
            const w = self.windowForView(c.webkit_download_get_web_view(d.dl)) orelse return;
            const received = if (received_override != 0) received_override else c.webkit_download_get_received_data_length(d.dl);
            const interrupt: u8 = if (std.mem.endsWith(u8, name, "failed")) 1 else 0;
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"received\":{d},\"total\":{d},\"interrupt_reason\":{d}}}", .{ d.id, received, d.total, interrupt }) catch return;
            defer self.allocator.free(payload);
            const msg = ipc.encodeEvent(self.allocator, name, payload) catch return;
            defer self.allocator.free(msg);
            self.deliverAlloc(w.view, msg);
        }

        fn removeDownload(self: *Self, d: *Download) void {
            for (self.downloads.items, 0..) |item, i| {
                if (item == d) {
                    _ = self.downloads.swapRemove(i);
                    break;
                }
            }
            self.allocator.destroy(d);
        }

        fn cancelDownload(self: *Self, id: u64) !void {
            for (self.downloads.items) |d| {
                if (d.id != id) continue;
                c.webkit_download_cancel(d.dl);
                log.print("[download] #{d} cancel requested", .{id});
                return;
            }
            return error.UnknownDownload;
        }

        /// 下载/子 WebView 事件的目标窗口：按发起下载的 WebView 反查注册表，
        /// 找不到时退回主窗口（对齐 Windows 的「事件回发起窗口」语义）。
        fn windowForView(self: *Self, view: [*c]c.WebKitWebView) ?*WinState {
            if (view != null) {
                for (self.windows.items) |st| {
                    if (st.view == view) return st;
                    for (st.child_webviews.items) |cv| {
                        if (cv.view == view) return st;
                    }
                }
            }
            if (self.windows.items.len == 0) return null;
            return self.windowById(0);
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
                // v0.2.1：cookies / clear_storage / 截图 / 取消下载
                .cookies => |op| return self.cookiesOp(w, op, alloc),
                .clear_storage => |clear| return self.clearStorageOp(w, clear, alloc),
                .cancel_download => |id| {
                    try self.cancelDownload(id);
                    return try alloc.dupe(u8, "null");
                },
                // CDP 逃生口：Linux 只支持截图（WebKit 无 CDP 通道）。
                // 其余方法明确 NotSupported（能力矩阵里 Linux 也不含 cdp）。
                .cdp => |cdp| {
                    if (!std.mem.eql(u8, cdp.method, "Page.captureScreenshot")) return error.NotSupported;
                    try self.startSnapshot(w, cdp.rid);
                    return try alloc.dupe(u8, "{}");
                },
                .print => return error.NotSupported,
            }
            return try alloc.dupe(u8, "null");
        }

        // ------------------------------------------------------------------
        // cookies / clear_storage（v0.2.1）
        // ------------------------------------------------------------------

        fn cookieManagerFor(w: *WinState) [*c]c.WebKitCookieManager {
            const ctx = c.webkit_web_view_get_context(w.view);
            if (ctx == null) return null;
            return c.webkit_web_context_get_cookie_manager(ctx);
        }

        /// 请求未带 URL 时用窗口入口 URL；host 用于 domain 推导。
        fn cookieUrl(self: *Self, w: *WinState, url: ?[]const u8, buf: *std.ArrayListUnmanaged(u8)) ![]const u8 {
            const raw = url orelse w.app_url;
            try buf.appendSlice(self.allocator, raw);
            return buf.items;
        }

        fn cookiesOp(self: *Self, w: *WinState, op: webview.Cookies, alloc: std.mem.Allocator) ![]u8 {
            const mgr = cookieManagerFor(w) orelse return error.WebViewCallFailed;
            switch (op) {
                .get => |g| {
                    var url_buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer url_buf.deinit(self.allocator);
                    const url = try self.cookieUrl(w, g.url, &url_buf);
                    const url_z = try dupeZ(self.allocator, url);
                    defer self.allocator.free(url_z);

                    var task = WaitTask{ .backend = self };
                    task.loop = c.g_main_loop_new(null, 0) orelse return error.WebViewCallFailed;
                    defer c.g_main_loop_unref(task.loop);
                    c.webkit_cookie_manager_get_cookies(mgr, url_z.ptr, null, cookiesGetDone, &task);
                    c.g_main_loop_run(task.loop.?);

                    const json = task.json orelse return error.WebViewCallFailed;
                    defer self.allocator.free(json);
                    return try alloc.dupe(u8, json);
                },
                .set => |cookie| {
                    const built = try self.buildSoupCookie(w, cookie);
                    defer c.soup_cookie_free(built);
                    return self.runCookieWrite(mgr, built, alloc);
                },
                .delete => |del| {
                    const built = try self.buildSoupCookie(w, .{
                        .name = del.name,
                        .value = "",
                        .url = del.url,
                        .domain = del.domain,
                        .path = del.path orelse "/",
                    });
                    defer c.soup_cookie_free(built);
                    // 删除走同一 add/delete 二选一完成回调
                    return self.runCookieDelete(mgr, built, alloc);
                },
                .clear => |clear| {
                    var url_buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer url_buf.deinit(self.allocator);
                    const url = try self.cookieUrl(w, clear.origin, &url_buf);
                    const host = hostOf(url) orelse return error.InvalidCookie;
                    const host_z = try dupeZ(self.allocator, host);
                    defer self.allocator.free(host_z);
                    c.webkit_cookie_manager_delete_cookies_for_domain(mgr, host_z.ptr);
                    log.print("[cookies] cleared domain '{s}'", .{host});
                    return try alloc.dupe(u8, "null");
                },
            }
        }

        /// 构造 SoupCookie：domain/path 从 URL 与参数补齐（libsoup 要求 domain 非空）。
        fn buildSoupCookie(self: *Self, w: *WinState, cookie: webview.Cookie) !*c.SoupCookie {
            var url_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer url_buf.deinit(self.allocator);
            const url = try self.cookieUrl(w, cookie.url, &url_buf);
            const host = cookie.domain orelse hostOf(url) orelse return error.InvalidCookie;
            const path = if (cookie.path.len > 0) cookie.path else "/";
            const max_age: c_int = if (cookie.expires) |expires| blk: {
                if (!std.math.isFinite(expires)) return error.InvalidCookie;
                const now: f64 = @as(f64, @floatFromInt(c.g_get_real_time())) / 1_000_000.0;
                const delta = @max(0, expires - now);
                break :blk @intFromFloat(@min(delta, 2147483647.0));
            } else -1;

            const name_z = try dupeZ(self.allocator, cookie.name);
            defer self.allocator.free(name_z);
            const value_z = try dupeZ(self.allocator, cookie.value);
            defer self.allocator.free(value_z);
            const domain_z = try dupeZ(self.allocator, host);
            defer self.allocator.free(domain_z);
            const path_z = try dupeZ(self.allocator, path);
            defer self.allocator.free(path_z);

            const built = c.soup_cookie_new(name_z.ptr, value_z.ptr, domain_z.ptr, path_z.ptr, max_age) orelse
                return error.InvalidCookie;
            if (cookie.secure) c.soup_cookie_set_secure(built, 1);
            if (cookie.http_only) c.soup_cookie_set_http_only(built, 1);
            if (cookie.same_site) |same_site| {
                c.soup_cookie_set_same_site_policy(built, switch (same_site) {
                    .Strict => c.SOUP_SAME_SITE_POLICY_STRICT,
                    .Lax => c.SOUP_SAME_SITE_POLICY_LAX,
                    .None => c.SOUP_SAME_SITE_POLICY_NONE,
                });
            }
            return built;
        }

        fn runCookieWrite(self: *Self, mgr: [*c]c.WebKitCookieManager, cookie: *c.SoupCookie, alloc: std.mem.Allocator) ![]u8 {
            var task = WaitTask{ .backend = self };
            task.loop = c.g_main_loop_new(null, 0) orelse return error.WebViewCallFailed;
            defer c.g_main_loop_unref(task.loop);
            c.webkit_cookie_manager_add_cookie(mgr, cookie, null, cookieWriteDone, &task);
            c.g_main_loop_run(task.loop.?);
            if (task.failed) return error.WebViewCallFailed;
            return try alloc.dupe(u8, "null");
        }

        fn runCookieDelete(self: *Self, mgr: [*c]c.WebKitCookieManager, cookie: *c.SoupCookie, alloc: std.mem.Allocator) ![]u8 {
            var task = WaitTask{ .backend = self };
            task.loop = c.g_main_loop_new(null, 0) orelse return error.WebViewCallFailed;
            defer c.g_main_loop_unref(task.loop);
            c.webkit_cookie_manager_delete_cookie(mgr, cookie, null, cookieDeleteDone, &task);
            c.g_main_loop_run(task.loop.?);
            if (task.failed) return error.WebViewCallFailed;
            return try alloc.dupe(u8, "null");
        }

        fn cookiesGetDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            const task: *WaitTask = @ptrCast(@alignCast(user_data orelse return));
            const mgr: [*c]c.WebKitCookieManager = @ptrCast(source);
            var err: [*c]c.GError = null;
            const list = c.webkit_cookie_manager_get_cookies_finish(mgr, res, &err);
            if (err != null) {
                c.g_error_free(err);
                task.failed = true;
            } else {
                task.json = cookiesJson(task.backend.allocator, list);
                if (task.json == null) task.failed = true;
            }
            if (list != null) {
                var it: ?*c.GList = list;
                while (it) |node| : (it = node.*.next) {
                    if (node.*.data) |data| c.soup_cookie_free(@ptrCast(data));
                }
                c.g_list_free(list);
            }
            if (task.loop) |loop| c.g_main_loop_quit(loop);
        }

        fn cookieWriteDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            const task: *WaitTask = @ptrCast(@alignCast(user_data orelse return));
            const mgr: [*c]c.WebKitCookieManager = @ptrCast(source);
            var err: [*c]c.GError = null;
            if (c.webkit_cookie_manager_add_cookie_finish(mgr, res, &err) == 0) task.failed = true;
            if (err != null) c.g_error_free(err);
            if (task.loop) |loop| c.g_main_loop_quit(loop);
        }

        fn cookieDeleteDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            const task: *WaitTask = @ptrCast(@alignCast(user_data orelse return));
            const mgr: [*c]c.WebKitCookieManager = @ptrCast(source);
            var err: [*c]c.GError = null;
            if (c.webkit_cookie_manager_delete_cookie_finish(mgr, res, &err) == 0) task.failed = true;
            if (err != null) c.g_error_free(err);
            if (task.loop) |loop| c.g_main_loop_quit(loop);
        }

        fn cookiesJson(alloc: std.mem.Allocator, list: ?*c.GList) ?[]u8 {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(alloc);
            out.appendSlice(alloc, "{\"cookies\":[") catch return null;
            var it: ?*c.GList = list;
            var first = true;
            while (it) |node| : (it = node.*.next) {
                const ck: *c.SoupCookie = @ptrCast(node.*.data orelse continue);
                if (!first) out.append(alloc, ',') catch return null;
                first = false;

                const name = c.soup_cookie_get_name(ck);
                const value = c.soup_cookie_get_value(ck);
                const domain = c.soup_cookie_get_domain(ck);
                const path = c.soup_cookie_get_path(ck);
                const name_json = jsonStr(alloc, if (name != null) std.mem.span(name) else "") orelse return null;
                defer alloc.free(name_json);
                const value_json = jsonStr(alloc, if (value != null) std.mem.span(value) else "") orelse return null;
                defer alloc.free(value_json);
                const domain_json = jsonStr(alloc, if (domain != null) std.mem.span(domain) else "") orelse return null;
                defer alloc.free(domain_json);
                const path_json = jsonStr(alloc, if (path != null) std.mem.span(path) else "/") orelse return null;
                defer alloc.free(path_json);

                const same_site: []const u8 = switch (c.soup_cookie_get_same_site_policy(ck)) {
                    c.SOUP_SAME_SITE_POLICY_STRICT => "Strict",
                    c.SOUP_SAME_SITE_POLICY_LAX => "Lax",
                    else => "None",
                };
                var expires_buf: [32]u8 = undefined;
                var expires_json: []const u8 = "";
                if (c.soup_cookie_get_expires(ck)) |dt| {
                    defer c.g_date_time_unref(dt);
                    expires_json = std.fmt.bufPrint(&expires_buf, ",\"expires\":{d}", .{c.g_date_time_to_unix(dt)}) catch "";
                }

                const item = std.fmt.allocPrint(
                    alloc,
                    "{{\"name\":{s},\"value\":{s},\"domain\":{s},\"path\":{s},\"secure\":{s},\"httpOnly\":{s},\"sameSite\":\"{s}\"{s}}}",
                    .{
                        name_json,
                        value_json,
                        domain_json,
                        path_json,
                        boolStr(c.soup_cookie_get_secure(ck) != 0),
                        boolStr(c.soup_cookie_get_http_only(ck) != 0),
                        same_site,
                        expires_json,
                    },
                ) catch return null;
                defer alloc.free(item);
                out.appendSlice(alloc, item) catch return null;
            }
            out.appendSlice(alloc, "]}") catch return null;
            return out.toOwnedSlice(alloc) catch null;
        }

        /// clear_storage：WebKit 的 clear 是「全部来源」，origin 参数仅作记录
        ///（Windows 侧可按 origin 精确清理，Linux 为超集语义，已在文档标注）。
        fn clearStorageOp(self: *Self, w: *WinState, clear: webview.ClearStorage, alloc: std.mem.Allocator) ![]u8 {
            const ctx = c.webkit_web_view_get_context(w.view);
            if (ctx == null) return error.WebViewCallFailed;
            const mgr = c.webkit_web_context_get_website_data_manager(ctx);
            if (mgr == null) return error.WebViewCallFailed;

            var types: c.WebKitWebsiteDataTypes = 0;
            if (clear.local_storage) types |= c.WEBKIT_WEBSITE_DATA_LOCAL_STORAGE | c.WEBKIT_WEBSITE_DATA_SESSION_STORAGE;
            if (clear.indexed_db) types |= c.WEBKIT_WEBSITE_DATA_INDEXEDDB_DATABASES;
            if (clear.cache) {
                types |= c.WEBKIT_WEBSITE_DATA_MEMORY_CACHE |
                    c.WEBKIT_WEBSITE_DATA_DISK_CACHE |
                    c.WEBKIT_WEBSITE_DATA_SERVICE_WORKER_REGISTRATIONS |
                    c.WEBKIT_WEBSITE_DATA_DOM_CACHE;
            }
            if (clear.cookies) types |= c.WEBKIT_WEBSITE_DATA_COOKIES;
            if (types == 0) return try alloc.dupe(u8, "null");

            var task = WaitTask{ .backend = self };
            task.loop = c.g_main_loop_new(null, 0) orelse return error.WebViewCallFailed;
            defer c.g_main_loop_unref(task.loop);
            c.webkit_website_data_manager_clear(mgr, types, 0, null, clearStorageDone, &task);
            c.g_main_loop_run(task.loop.?);
            if (task.failed) return error.WebViewCallFailed;

            const origin: []const u8 = clear.origin orelse "(all)";
            log.print("[storage] cleared types=0x{x} origin={s}", .{ types, origin });
            return try alloc.dupe(u8, "null");
        }

        fn clearStorageDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            const task: *WaitTask = @ptrCast(@alignCast(user_data orelse return));
            const mgr: [*c]c.WebKitWebsiteDataManager = @ptrCast(source);
            var err: [*c]c.GError = null;
            if (c.webkit_website_data_manager_clear_finish(mgr, res, &err) == 0) task.failed = true;
            if (err != null) c.g_error_free(err);
            if (task.loop) |loop| c.g_main_loop_quit(loop);
        }

        // ------------------------------------------------------------------
        // 截图（v0.2.1）：WebKit 无 CDP → 用 cairo 快照实现 Page.captureScreenshot
        // ------------------------------------------------------------------

        fn startSnapshot(self: *Self, w: *WinState, rid: i64) !void {
            const task = try self.allocator.create(SnapshotTask);
            errdefer self.allocator.destroy(task);
            task.* = .{ .backend = self, .win_id = w.id, .rid = rid };
            c.webkit_web_view_get_snapshot(
                w.view,
                c.WEBKIT_SNAPSHOT_REGION_VISIBLE,
                c.WEBKIT_SNAPSHOT_OPTIONS_NONE,
                null,
                snapshotDone,
                task,
            );
        }

        fn snapshotDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            const task: *SnapshotTask = @ptrCast(@alignCast(user_data orelse return));
            const self = task.backend;
            defer self.allocator.destroy(task);
            const view: [*c]c.WebKitWebView = @ptrCast(source);

            var err: [*c]c.GError = null;
            const surface = c.webkit_web_view_get_snapshot_finish(view, res, &err);
            if (err != null or surface == null) {
                const message = if (err != null) std.mem.span(err.*.message) else "snapshot failed";
                if (err != null) c.g_error_free(err);
                log.print("[snapshot] failed: {s}", .{message});
                return self.emitCdpError(task.win_id, task.rid, message);
            }
            defer c.cairo_surface_destroy(surface);

            const stream = c.g_memory_output_stream_new_resizable();
            if (stream == null) return self.emitCdpError(task.win_id, task.rid, "snapshot stream failed");
            defer c.g_object_unref(@ptrCast(stream));
            const status = c.cairo_surface_write_to_png_stream(surface, pngWrite, stream);
            if (status != c.CAIRO_STATUS_SUCCESS) return self.emitCdpError(task.win_id, task.rid, "png encode failed");

            const raw: [*c]u8 = @ptrCast(c.g_memory_output_stream_get_data(@ptrCast(stream)));
            const size: usize = @intCast(c.g_memory_output_stream_get_size(@ptrCast(stream)));
            if (raw == null or size == 0) return self.emitCdpError(task.win_id, task.rid, "empty snapshot");

            const encoder = std.base64.standard.Encoder;
            const encoded = self.allocator.alloc(u8, encoder.calcSize(size)) catch return;
            defer self.allocator.free(encoded);
            _ = encoder.encode(encoded, raw[0..size]);
            log.print("[snapshot] {d} bytes -> base64 {d} chars", .{ size, encoded.len });
            self.emitCdpOk(task.win_id, task.rid, encoded);
        }

        /// cairo 的 PNG 写出回调（closure = GMemoryOutputStream）。
        fn pngWrite(closure: ?*anyopaque, data: [*c]const u8, length: c_uint) callconv(.c) c.cairo_status_t {
            const stream: [*c]c.GOutputStream = @ptrCast(@alignCast(closure orelse return c.CAIRO_STATUS_WRITE_ERROR));
            var written: c.gsize = 0;
            if (c.g_output_stream_write_all(stream, data, length, &written, null, null) == 0) return c.CAIRO_STATUS_WRITE_ERROR;
            if (written != length) return c.CAIRO_STATUS_WRITE_ERROR;
            return c.CAIRO_STATUS_SUCCESS;
        }

        fn emitCdpOk(self: *Self, win_id: u32, rid: i64, base64_data: []const u8) void {
            const payload = std.fmt.allocPrint(
                self.allocator,
                "{{\"rid\":{d},\"ok\":true,\"result\":{{\"data\":\"{s}\"}}}}",
                .{ rid, base64_data },
            ) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(win_id, "webviewCdp", payload);
        }

        fn emitCdpError(self: *Self, win_id: u32, rid: i64, message: []const u8) void {
            const msg_json = jsonStr(self.allocator, message) orelse return;
            defer self.allocator.free(msg_json);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"rid\":{d},\"ok\":false,\"error\":{s}}}", .{ rid, msg_json }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(win_id, "webviewCdp", payload);
        }

        fn emitRawToWindow(self: *Self, win_id: u32, name: []const u8, payload: []const u8) void {
            const w = self.windowById(win_id) orelse return;
            const msg = ipc.encodeEvent(self.allocator, name, payload) catch return;
            defer self.allocator.free(msg);
            self.deliverAlloc(w.view, msg);
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
                .window_state => |op| return self.runWindowStateOp(w, op, alloc),
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
            // 先落盘窗口状态（destroy 期间控件仍在，几何可查）
            self.saveWindowState(st);
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

        /// configure-event：跟踪窗口几何（destroy 时保存窗口状态用）。
        /// 返回 FALSE 表示继续传播给 GTK 默认处理。
        /// 注意：translate-c 里 `GdkEvent` 是不透明 union，信号参数只能按
        /// `?*anyopaque` 接、再转成具体的 GdkEventConfigure。
        fn onConfigureEvent(_: [*c]c.GtkWidget, event: ?*anyopaque, user_data: c.gpointer) callconv(.c) c.gboolean {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return 0));
            const cfg: [*c]c.GdkEventConfigure = @ptrCast(@alignCast(event orelse return 0));
            if (cfg.*.width > 0 and cfg.*.height > 0) {
                st.geom_x = cfg.*.x;
                st.geom_y = cfg.*.y;
                st.geom_width = @intCast(cfg.*.width);
                st.geom_height = @intCast(cfg.*.height);
            }
            return 0;
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

test "hostOf: URL host、端口与 IPv6 字面量" {
    try testing.expectEqualStrings("example.com", hostOf("https://example.com/a?b=1").?);
    try testing.expectEqualStrings("example.com", hostOf("https://user:pw@example.com:8443/x").?);
    try testing.expectEqualStrings("[::1]", hostOf("http://[::1]:8080/x").?);
    try testing.expectEqualStrings("app", hostOf("zilt://app/index.html").?);
    try testing.expect(hostOf("about:blank") == null);
    try testing.expect(hostOf("https:///x") == null);
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
