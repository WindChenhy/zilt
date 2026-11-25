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
//!       origin 参数不参与过滤——超集语义）。
//!     * **截图**：WebKit 无 CDP，仅支持 `Page.captureScreenshot`（PNG）——
//!       webkit_web_view_get_snapshot + cairo PNG + base64 → `webviewCdp` 事件，
//!       runtime 的 captureScreenshot 无需改动；其余 CDP 方法 NotSupported。
//!     * **窗口状态持久化**：`window_state.zig`（与 Windows app_data 同格式/同
//!       哈希文件名）→ state_key / persist_window_state 在创建时恢复、销毁时保存；
//!       `window.zilt.windowState.get/save` 走 system_fn 的 `.window_state` op。
//!     print 仍返回 NotSupported（P2，见能力清单）。
//!   - v0.2.2（2026-11-13 完成）：系统集成——
//!     * **剪贴板**：文本 / HTML / 文件列表 / 图片读写（GTK 剪贴板；HTML 与
//!       URI 列表走延迟提供，owner-change 可选发 clipboardChanged 事件）。
//!     * **原生对话框**：消息框 / 打开 / 保存 / 选文件夹 / 多选 / 颜色 / 字体
//!       （GtkFileChooserNative 在有 portal 时走 portal；字体用 Pango 描述解析）。
//!     * **通知**：GApplication + GNotification（tag 替换语义）；无 D-Bus 会话总线时
//!       按设计降级为 status=disabled_for_application，不阻断启动。
//!     * **菜单栏**：config.menu → 每窗口 GtkMenuBar；叶子 activate 发 `menu`
//!       事件 {id}；无 id 叶子置灰；accel 解析挂 GtkAccelGroup（展示+真实触发），
//!       role（undo/redo/cut/copy/paste/select_all）→ WebKit 编辑命令 +
//!       menuRole 事件，delete → document.execCommand。
//!     * **托盘**：libayatana-appindicator3 **dlopen 可选依赖**（缺失只日志）；
//!       菜单构建与 indicator 解耦——**运行时菜单模型**（`menu_model`，由
//!       config.tray.menu 初始化，与 Windows 同构）驱动托盘菜单：
//!       `menu.*` op（list/add/remove/set → 重建 + popup）无 libayatana 也可用。
//!     * **单实例 + 深链**：GApplication 唯一 ID（HANDLES_COMMAND_LINE）——
//!       主实例走 g_application_run，第二实例 argv 经 command-line 转交后
//!       exit 5（对齐 Windows）；`deepLink` 事件 {url, files} 在页面加载后投递
//!       （pending_launch 兜底）；无参二次启动聚焦主窗口。深链/文件关联注册 =
//!       应用级 `.desktop`（MimeType=x-scheme-handler/<scheme>）+ `xdg-mime
//!       default`。**无 D-Bus 时降级**：本地解析启动参数 + gtk_main。
//!     * **拖放**：主 WebView 挂 drag dest（drag-drop 拦截 WebKit 默认导航 +
//!       drag-data-received 解析 text/uri-list）→ `dropFiles` {files} 事件。
//!     * **自启动**：`~/.config/autostart/<app_id>.desktop`（autostart.* op）。
//!     * **系统信息**：/etc/os-release + locale/theme 推导 + GDK 显示器枚举
//!       （`system.info('os'|'monitors'|'all')`，JSON 形状与 Windows 同构）。
//!     * print 仍为 NotSupported（P2，规划随 v0.2.5）。
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
//!     快捷键 / http/ws/fs/SQL（v0.2.3）。`platform/interface.zig` 的能力矩阵逐项打勾。
//!   - 冒烟（ZILT_LINUX_SMOKE=1）：48 项检查。WSLg 环境必须 `GDK_BACKEND=x11`
//!     跑 xvfb-run——Wayland 路径实测在多窗口场景触发协议错误（Error 71）断连。
//!     通知/托盘完整路径建议 `dbus-run-session -- xvfb-run …`（无总线时按设计降级）。
//!     单实例转交 E2E：主实例带 `ZILT_LINUX_SMOKE_STAY=<秒>` 存活，第二实例带
//!     `zilt://…` 参数启动 → exit 5 + 主实例日志 deepLink 事件。
//!
//! 依赖（构建期）：pkg-config + libgtk-3-dev + libwebkit2gtk-4.1-dev。
//! Zig 0.17 移除了 `@cImport`，C 绑定由 `build.zig` 的 `addTranslateC` 从 `capi.h` 生成。
const std = @import("std");

const c = @import("gtk");

const ipc = @import("../../ipc.zig");
const iso_mod = @import("../../isolation.zig");
const webview = @import("../../webview.zig");
const asset_routes = @import("../../asset_routes.zig");
const inflate = @import("../../inflate.zig");
const security = @import("../../security.zig");
const builtin_cmds = @import("../../builtin.zig");
const log = @import("../../log.zig");
const system_api = @import("../../system_api.zig");
const shared_taskbar = @import("../../taskbar.zig");
const shared_services = @import("../../services.zig");
const updater = @import("../../updater.zig");
const patch_mod = @import("../../patch.zig");
const shell_mod = @import("../../shell.zig");
const headless = @import("../windows/headless.zig");
const clipboard = @import("../../clipboard.zig");
const notification = @import("../../notification.zig");
const window_state = @import("window_state.zig");
const sys = @import("../../sys.zig");
const gtk_compat = @import("gtk_compat.zig");
const hotkey_mod = @import("hotkey.zig");
const portal_hotkey = @import("portal_hotkey.zig");
const deep_link = @import("deep_link.zig");
const unity_badge = @import("unity_badge.zig");
const launch_args = @import("../../launch_args.zig");
const upload_resume = @import("../../upload_resume.zig");
const libsecret = @import("libsecret.zig");
const desktop_entry = @import("desktop_entry.zig");
const sysinfo_linux = @import("sysinfo_linux.zig");
const menu_model = @import("../../menu_model.zig");
const shared_sysinfo = @import("../../sysinfo.zig");
const shared_power = @import("../../power.zig");
const shared_png = @import("../../png.zig");
const autostart_mod = @import("../../autostart.zig");
const fs_api_mod = @import("../../fs_api.zig");
const store_mod = @import("../../store.zig");
const protocol = @import("../../protocol.zig");
const shared_net = @import("../../net.zig");
const linux_sqlite = @import("sqlite.zig");
const fs_watch_mod = @import("fs_watch.zig");
const Config = @import("../../config.zig").Config;

pub const platform_name = "linux";

/// 自有 scheme（WebKitGTK 要求不是 http/https/file）。
const scheme = "zilt";
const scheme_host = "app";

/// v0.2.1 Linux 冒烟脚本（只测已实现能力；见 smoke.js 顶部说明）。
const smoke_script = @embedFile("smoke.js");

/// v0.3.14 G26：缩放快捷键 polyfill（runtime 之后、应用脚本之前注入）。
/// WebKitGTK 没有 WebView2 的 IsZoomControlEnabled 对等 API；对齐 Tauri
/// `zoomHotkeysEnabled` 的 Linux 手法——Ctrl/Cmd ±/0 → window.zilt.webview.zoom。
const zoom_hotkey_polyfill =
    \\(function(){
    \\  if (!window.zilt || !window.zilt.webview) return;
    \\  window.addEventListener('keydown', function(e){
    \\    if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
    \\    var k = e.key;
    \\    if (k !== '+' && k !== '=' && k !== '-' && k !== '0') return;
    \\    e.preventDefault();
    \\    window.zilt.webview.getZoom().then(function(z){
    \\      var t = (typeof z === 'number' && z > 0) ? z : 1;
    \\      if (k === '+' || k === '=') t = Math.min(t * 1.2, 10);
    \\      else if (k === '-') t = Math.max(t / 1.2, 0.2);
    \\      else t = 1;
    \\      return window.zilt.webview.zoom(t);
    \\    }).catch(function(){});
    \\  }, true);
    \\})();
;

test "zoom polyfill: 快捷键面覆盖 +/=/-/0 且走 runtime zoom 通道" {
    const t = std.testing;
    try t.expect(std.mem.indexOf(u8, zoom_hotkey_polyfill, "getZoom") != null);
    try t.expect(std.mem.indexOf(u8, zoom_hotkey_polyfill, "zilt.webview.zoom") != null);
    for ([_][]const u8{ "'+'", "'='", "'-'", "'0'" }) |key| {
        try t.expect(std.mem.indexOf(u8, zoom_hotkey_polyfill, key) != null);
    }
}

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

/// ZILT_LINUX_SMOKE_STAY=<秒>：冒烟检查完成后主实例保持存活（单实例转交
/// E2E 用；上限 120 秒，防止 CI 挂死）。
fn smokeStaySeconds() u32 {
    const raw = std.c.getenv("ZILT_LINUX_SMOKE_STAY") orelse return 0;
    const n = std.fmt.parseInt(u32, std.mem.span(raw), 10) catch return 0;
    return @min(n, 120);
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

/// 分离拉起子进程（v0.2.7）：spawn 后不等待（对齐 Windows ShellExecuteW 的
/// 立即返回语义——xdg-open 可能等浏览器退出，同步等待会冻结 UI）。
/// 僵尸回收：每个子进程挂一个收割线程（waitpid 该 pid 直到退出）——**不能**
/// 用 SIGCHLD=SIG_IGN（内核自动回收会让子进程 op 的 wait 拿到 ECHILD，
/// Threaded io 视为 errno bug 直接 panic，v0.3.0 实测踩到）。
/// 返回 spawn 是否成功（子进程自身的成败是异步的，调用方拿不到）。
fn spawnDetachedLinux(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const child = std.process.spawn(sharedIo(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        log.print("[spawn] {s} failed: {s}", .{ argv[0], @errorName(err) });
        return false;
    };
    if (child.id) |pid| {
        const t = std.Thread.spawn(.{ .stack_size = sys.threadStackSize(256 * 1024) }, reapDetached, .{pid}) catch return true;
        t.detach();
    }
    return true;
}

/// 收割线程：waitpid 指定子进程直到退出（阻塞；shell 打开器通常很快退出）。
fn reapDetached(pid: std.c.pid_t) void {
    _ = std.c.waitpid(pid, null, 0);
}

/// updater.Fetcher 的取数实现（std.http.Client；与 Windows httpFetch 同构，
/// 两平台共享同一套 updater 决策/验签逻辑）。
fn updaterFetchLinux(backend_ptr: *anyopaque, alloc: std.mem.Allocator, url: []const u8) anyerror![]u8 {
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

/// 重启 helper（Linux）：等旧实例（父进程）退出 → 拉起新版并观察 3 秒。
/// 3 秒内退出视为更新失败 → 用 `.zilt-old` 回滚并重拉旧版（对齐 Windows v0.1.15）；
/// 仍在运行视为健康，helper 退出（子进程被 init 收养）。
fn runRestartHelperLinux(target: []const u8) void {
    log.print("[updater] restart helper: waiting for old instance to exit", .{});
    var waited_ms: u32 = 0;
    while (waited_ms < 30_000) : (waited_ms += 200) {
        if (std.c.getppid() == 1) break; // 父进程已退出（被 init 收养）
        _ = c.g_usleep(200_000);
    }
    if (waited_ms >= 30_000) {
        log.print("[updater] restart helper: timeout waiting for old instance", .{});
        return;
    }

    const alloc = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // v0.4.0 L7：与 Windows runRestartHelper 同语义同日志——
    //   * 退出码 5（单实例转交，GApplication 名释放滞后）→ 稍候重试拉起（≤5 次）
    //   * 3s 内非 0 退出（或被信号杀死）→ rollbackToBackup + 重拉 + 观察
    //   * 3s 内 0 退出 → 视为正常（不回滚）；存活 ≥3s → healthy
    var attempt: u32 = 0;
    while (attempt < 5) : (attempt += 1) {
        log.print("[updater] restart helper: spawn {s} (attempt {d})", .{ target, attempt + 1 });
        const child = std.process.spawn(io, .{ .argv = &.{target} }) catch |e| {
            log.print("[updater] restart helper: spawn failed: {s}", .{@errorName(e)});
            return;
        };
        const id = child.id orelse return;
        const pid: std.c.pid_t = @intCast(id);

        var observe_ms: u32 = 0;
        var exited = false;
        var code: u32 = 0;
        while (observe_ms < 3000) : (observe_ms += 100) {
            var status: c_int = 0;
            const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
            if (r == pid) {
                exited = true;
                // waitpid 状态解码（手写位运算——std.c.W 各平台宏差异规避）：
                // 低 7 位 = 终止信号（0 = 正常退出）；高 8 位 = 退出码
                code = if ((status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else 1;
                break;
            }
            _ = c.g_usleep(100_000);
        }
        if (!exited) {
            log.print("[updater] target healthy after 3s", .{});
            return;
        }
        if (code == 5) {
            _ = c.g_usleep(400_000);
            continue;
        }
        if (code != 0) {
            if (updater.rollbackToBackup(alloc, target)) {
                log.print("[updater] target exited with {d}, rolled back to backup", .{code});
                const old_child = std.process.spawn(io, .{ .argv = &.{target} }) catch return;
                _ = old_child; // 健康观察由 init 接管（10s cleanupOld）；这里只负责拉起
            } else {
                log.print("[updater] target exited with {d}, no backup available", .{code});
            }
        }
        return;
    }
    log.print("[updater] restart helper: exit-5 retry attempts exhausted", .{});
}

/// 窗口事件的字段（v0.2.6：windowMoved/Resized/Focus/Blur/CloseRequested）。
/// 数值直出、无字符串转义——payload 都是小而固定的形状。
pub const WindowEventField = struct { name: []const u8, value: i64 };

/// 窗口事件 payload JSON 拼装（纯函数）。单测锁定「字段名必须带引号」——
/// v0.2.6 实测漏引号时 `{id":1}` 是非法 JSON，evaluate_javascript 静默丢弃。
fn windowEventPayloadJson(alloc: std.mem.Allocator, fields: []const WindowEventField) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer payload.deinit(alloc);
    try payload.append(alloc, '{');
    for (fields, 0..) |f, i| {
        if (i != 0) try payload.append(alloc, ',');
        try payload.append(alloc, '"');
        try payload.appendSlice(alloc, f.name);
        try payload.appendSlice(alloc, "\":");
        var buf: [24]u8 = undefined;
        const printed = std.fmt.bufPrint(&buf, "{d}", .{f.value}) catch continue;
        try payload.appendSlice(alloc, printed);
    }
    try payload.append(alloc, '}');
    // toOwnedSlice：free 必须拿整块分配（items 的 len < capacity 时 free(items)
    // 与分配元数据不符——0.17 SafeAllocator 实测直接 panic）
    return try payload.toOwnedSlice(alloc);
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

/// 托盘图标名：取资产路径的 basename 去扩展名。
/// AppIndicator 只接受**主题图标名**（不是文件路径），自定义图标需要随应用
/// 安装到 hicolor 主题目录（v0.2.4 打包阶段处理）；这里至少保证名字稳定。
fn trayIconName(path: ?[]const u8) []const u8 {
    const p = path orelse return "zilt-app";
    const base = if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot > 0) return base[0..dot];
    }
    return if (base.len > 0) base else "zilt-app";
}

fn hexVal(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

/// `file://` URI → 本地路径（百分号解码；只接受空 host / localhost）。
/// 调用方 free。非 file URI 返回 UnsupportedUri。
fn fileUriToPath(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return error.UnsupportedUri;
    var rest = uri["file://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.UnsupportedUri;
    const host = rest[0..slash];
    if (host.len != 0 and !std.mem.eql(u8, host, "localhost")) return error.UnsupportedUri;
    rest = rest[slash..];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < rest.len) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (hexVal(rest[i + 1])) |hi| {
                if (hexVal(rest[i + 2])) |lo| {
                    try out.append(alloc, (hi << 4) | lo);
                    i += 3;
                    continue;
                }
            }
        }
        try out.append(alloc, rest[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// 本地路径 → `file://` URI（保留 `/` 与 unreserved 字符，其余百分号编码）。
fn pathToFileUri(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (path) |ch| {
        const unreserved = std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or
            ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try out.append(alloc, ch);
        } else {
            var buf: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "%{X:0>2}", .{ch}) catch unreachable;
            try out.appendSlice(alloc, &buf);
        }
    }
    return out.toOwnedSlice(alloc);
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

/// 后端本地的线程同步 Io（文件写入/读取/删除；同 window_state.zig 的惰性模式）。
var g_backend_io: std.Io.Threaded = undefined;
var g_backend_io_ready = false;
fn sharedIo() std.Io {
    if (!g_backend_io_ready) {
        g_backend_io = .init(std.heap.page_allocator, .{});
        g_backend_io_ready = true;
    }
    return g_backend_io.io();
}

/// 命令行参数 → char**（g_application_run 的入参；缓冲与指针表进程生命周期内
/// 持有，不释放——c_allocator 且参数表在 main loop 退出前必须存活）。
/// 0.17 的 argv 走 `std.process.Init`（main 入口），后端拿不到 → 直接读
/// /proc/self/cmdline（Linux 专属，与后端限定一致）。
/// 冒烟模式把 ZILT_LINUX_SMOKE_DEEPLINK 追加为伪参数（模拟深链启动，与
/// Windows 的 `zilt-app zilt://startup?demo=1` E2E 同思路）。
fn collectArgv(alloc: std.mem.Allocator) ![][*c]u8 {
    var list: std.ArrayListUnmanaged([*c]u8) = .empty;
    if (readCmdlineAlloc(alloc)) |data| {
        // 格式：argv0<NUL>argv1<NUL>...（尾随 NUL；参数内不含 NUL）
        var i: usize = 0;
        while (i < data.len) {
            const end = std.mem.indexOfScalarPos(u8, data, i, 0) orelse data.len;
            if (end > i) try list.append(alloc, data[i..end].ptr);
            i = end + 1;
        }
    } else |_| {
        // 极端环境拿不到 cmdline → 空参数表（g_application_run 用 argc=0 也能跑）
    }
    if (smokeEnabled()) {
        if (std.c.getenv("ZILT_LINUX_SMOKE_DEEPLINK")) |u| {
            const s = std.mem.span(u);
            if (s.len > 0) try list.append(alloc, @constCast(s.ptr));
        }
    }
    return list.items;
}

/// /proc/self/cmdline 全量读取（libc stdio——0.17 的 readFileAlloc 依赖
/// stat size，procfs 恒报 0，实测读回空；本后端本就链接 libc）。
fn readCmdlineAlloc(alloc: std.mem.Allocator) ![]u8 {
    const f = std.c.fopen("/proc/self/cmdline", "rb") orelse return error.CmdlineUnavailable;
    defer _ = std.c.fclose(f);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&tmp, 1, tmp.len, f);
        if (n == 0) break;
        try buf.appendSlice(alloc, tmp[0..n]);
        if (buf.items.len > 64 * 1024) return error.CmdlineTooLong;
    }
    return buf.items;
}

/// text/uri-list 解析（拖放 / 深链文件列表共用）：\r\n 分隔、`#` 注释跳过、
/// `file://` → 本地路径；非 file URI（http:// 等）与远端 host 拒绝（跳过）。
pub fn parseDropUris(alloc: std.mem.Allocator, uri_list: []const u8) ![][]u8 {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p);
        out.deinit(alloc);
    }
    var it = std.mem.splitAny(u8, uri_list, "\r\n");
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        const path = fileUriToPath(alloc, line) catch continue;
        try out.append(alloc, path);
    }
    return out.toOwnedSlice(alloc);
}

/// 加速键解析结果（GDK 修饰符掩码 + keysym）。
pub const AccelGtk = struct { mods: c.GdkModifierType, keyval: c.guint };

/// v0.3.9 A4L：窗口级按键绑定条目（id 所有权归 WinState；窗口销毁释放）
pub const KeyBindEntry = struct {
    id: []u8,
    mods: c.GdkModifierType,
    keyval: c.guint,
};

/// 拉丁键位归一小写（GDK_KEY_A..Z = ASCII 0x41-0x5A / a..z = 0x61-0x7A——
/// keyvalForGtk 已依赖同一事实；测试构建不链 GTK，不调 gdk_keyval_to_lower）。
fn keyvalLower(k: c.guint) c.guint {
    if (k >= 'A' and k <= 'Z') return k + 32;
    return k;
}

/// v0.3.9 A4L：按键匹配（keyval 归一小写比较——keyvalForGtk 统一大写键位
/// 0x41-0x5A，而事件 keyval 是实际 level 的键值，'X' 绑定按 'x' 0x78 到达）。
/// mods 只比较四个语义修饰符位（忽略 MOD2 numlock 等 lock 位）。
pub fn matchKeyBinding(entries: []const KeyBindEntry, keyval: c.guint, mods: c.GdkModifierType) ?*const KeyBindEntry {
    const semantic: c.GdkModifierType = c.GDK_CONTROL_MASK | gtk_compat.MOD1_MASK | c.GDK_SHIFT_MASK | c.GDK_SUPER_MASK;
    const pressed = mods & semantic;
    const ev_key = keyvalLower(keyval);
    for (entries) |*kb| {
        if (keyvalLower(kb.keyval) == ev_key and kb.mods == pressed) return kb;
    }
    return null;
}

/// "Ctrl+Alt+N" → (GDK_CONTROL_MASK|GDK_MOD1_MASK, GDK_KEY_n)。
/// 修饰符：Ctrl/Control、Shift、Alt/Mod1、Super；键位：A-Z / 0-9 / F1-F12
///（与 Windows 侧 config.hotkeys 的合法键位集一致）。无法解析返回 null。
pub fn parseAccelGtk(accel: []const u8) ?AccelGtk {
    var mods: c.GdkModifierType = 0;
    var keyval: c.guint = 0;
    var it = std.mem.splitScalar(u8, accel, '+');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(part, "Ctrl") or std.ascii.eqlIgnoreCase(part, "Control")) {
            mods |= c.GDK_CONTROL_MASK;
        } else if (std.ascii.eqlIgnoreCase(part, "Shift")) {
            mods |= c.GDK_SHIFT_MASK;
        } else if (std.ascii.eqlIgnoreCase(part, "Alt") or std.ascii.eqlIgnoreCase(part, "Mod1")) {
            mods |= gtk_compat.MOD1_MASK;
        } else if (std.ascii.eqlIgnoreCase(part, "Super")) {
            mods |= c.GDK_SUPER_MASK;
        } else {
            if (keyval != 0) return null; // 两个键位
            keyval = keyvalForGtk(part) orelse return null;
        }
    }
    if (keyval == 0) return null;
    return .{ .mods = mods, .keyval = keyval };
}

/// v0.3.0：CursorKind → GDK 标准光标名（CSS cursor 名）。
/// `up-arrow` 在部分主题里缺失 → 调用方再回退 "default"。
pub fn gdkCursorName(kind: ipc.CursorKind) [:0]const u8 {
    return switch (kind) {
        .default, .arrow => "default",
        .ibeam => "text",
        .crosshair => "crosshair",
        .hand => "pointer",
        .wait => "wait",
        .help => "help",
        .not_allowed => "not-allowed",
        .size_ns => "ns-resize",
        .size_ew => "ew-resize",
        .size_nwse => "nwse-resize",
        .size_nesw => "nesw-resize",
        .move => "move",
        .up_arrow => "up-arrow",
    };
}

/// v0.3.0：拖出文件列表 → text/uri-list 内容（CRLF 分隔，空项跳过）。
pub fn buildUriList(alloc: std.mem.Allocator, files: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (files) |f| {
        if (f.len == 0) continue;
        const uri = try pathToFileUri(alloc, f);
        defer alloc.free(uri);
        try out.appendSlice(alloc, uri);
        try out.appendSlice(alloc, "\r\n");
    }
    return out.toOwnedSlice(alloc);
}

/// 键名 → GDK keysym：字母 GDK_KEY_A=0x41..，数字 GDK_KEY_0=0x30..，
/// 功能键 GDK_KEY_F1=0xffbe 起。
fn keyvalForGtk(part: []const u8) ?c.guint {
    if (part.len == 1) {
        const ch = part[0];
        if (ch >= 'A' and ch <= 'Z') return ch;
        if (ch >= 'a' and ch <= 'z') return ch - 32; // 统一大写键位
        if (ch >= '0' and ch <= '9') return ch;
        return null;
    }
    if (part.len >= 2 and (part[0] == 'F' or part[0] == 'f')) {
        const n = std.fmt.parseInt(u8, part[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return 0xffbe + @as(c.guint, n - 1);
    }
    return null;
}

/// v0.3.0：会话是否有窗口管理器（X11 `_NET_SUPPORTING_WM_CHECK`）。
/// Xvfb 裸跑无 WM → false（configure/focus 事件不会到达，冒烟按 skip 处理）；
/// CI 装 openbox 后为 true → windowMoved/Resized/Focus 真实断言。
fn detectWindowManager() bool {
    const display = c.XOpenDisplay(null) orelse return false;
    defer _ = c.XCloseDisplay(display);
    const root = c.XDefaultRootWindow(display);
    const atom = c.XInternAtom(display, "_NET_SUPPORTING_WM_CHECK", 0);
    if (atom == 0) return false;
    var actual_type: c.Atom = 0;
    var actual_format: c_int = 0;
    var nitems: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var prop: [*c]u8 = null;
    const status = c.XGetWindowProperty(
        display,
        root,
        atom,
        0,
        1,
        0,
        // XA_WINDOW = 33（X11 协议固定原子；translate-c 不导出该宏）
        @as(c.Atom, 33),
        &actual_type,
        &actual_format,
        &nitems,
        &bytes_after,
        &prop,
    );
    defer {
        if (prop != null) _ = c.XFree(@ptrCast(prop));
    }
    return status == 0 and nitems == 1 and prop != null;
}

// ---------------------------------------------------------------------------
// v0.4.3 L6：焦点跟随鼠标（focus-follows-mouse）桌面判定
//
// hideOnFocusLost 在点击聚焦的桌面上是托盘弹窗的标配；FFM 桌面下指针一离
// 开弹窗就失焦 → 窗口在用户点到之前消失。Wails 在 Hyprland/Sway/i3 一类
// 环境禁用该行为（HideOnEscape 保留），Zilt 同语义：挂窗 + FFM → 不自动隐藏。
// X11 没有「当前焦点策略」的查询面（EWMH 无此属性），判定按桌面/合成器标识。
// ---------------------------------------------------------------------------

/// 桌面标识是否属于 FFM 默认桌面。令牌匹配（大小写不敏感）：XDG 的值形如
/// "sway" / "Hyprland" / "ubuntu:GNOME" / "i3"，按 `:;,/ ` 切分后逐个比较，
/// 避免 "i386" 之类子串误命中。
pub fn impliesFocusFollowsMouse(desktop: []const u8) bool {
    const known = [_][]const u8{ "hyprland", "sway", "i3", "xmonad", "qtile", "wayfire" };
    var it = std.mem.tokenizeAny(u8, desktop, ":;,/ \t");
    while (it.next()) |token| {
        for (known) |name| {
            if (std.ascii.eqlIgnoreCase(token, name)) return true;
        }
    }
    return false;
}

/// 会话级 FFM 判定：
/// - `ZILT_FOCUS_FOLLOWS_MOUSE=1|0` 强制覆盖（其它 WM / 实测用）
/// - `HYPRLAND_INSTANCE_SIGNATURE` / `SWAYSOCK`（Wayland 合成器环境变量）
/// - XDG 桌面标识令牌（XDG_CURRENT_DESKTOP / XDG_SESSION_DESKTOP / DESKTOP_SESSION）
fn detectFocusFollowsMouse() bool {
    if (std.c.getenv("ZILT_FOCUS_FOLLOWS_MOUSE")) |v| {
        const s = std.mem.span(v);
        if (s.len != 0) return !(s[0] == '0' or s[0] == 'n' or s[0] == 'N' or s[0] == 'f' or s[0] == 'F');
    }
    if (std.c.getenv("HYPRLAND_INSTANCE_SIGNATURE") != null) return true;
    if (std.c.getenv("SWAYSOCK") != null) return true;
    inline for (.{ "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "DESKTOP_SESSION" }) |key| {
        if (std.c.getenv(key)) |v| {
            if (impliesFocusFollowsMouse(std.mem.span(v))) return true;
        }
    }
    return false;
}

pub fn run(comptime config: Config) !void {
    // 进程级长生命周期分配器：emit 可能来自任意 worker 线程，必须线程安全；
    // 后端已链接 libc，c_allocator 是最稳的选择（无泄漏检测开销，也不需要 deinit）。
    const alloc = std.heap.c_allocator;
    log.initFileLog("zilt.log");

    // v0.3.16 G20：GPU 策略（WebKit 初始化前设置环境变量；Wails WebviewGpuPolicy
    // 对齐）。never → 禁用加速合成（软件合成，NVIDIA/远程桌面空白窗对策）；
    // auto（null）+ NVIDIA 探测 → 自动禁 DMABUF 渲染器（Wails 同款修复）。
    applyGpuPolicy(config.environment.gpu_policy);

    // v0.2.8：headless/server 模式（对齐 Windows v0.1.17）——跳过窗口/GTK，
    // 应用作为 HTTP 服务运行（/zilt/health、/zilt/ipc、/mcp、资产）。
    // 与 Windows 同一份 headless 实现（std.Io；env/SQL 两处平台点 comptime 分派）。
    if (std.c.getenv("ZILT_HEADLESS")) |h| {
        if (std.mem.eql(u8, std.mem.span(h), "1")) {
            return headless.run(config, alloc);
        }
    }

    const Self = Backend(config);
    const self = try alloc.create(Self);
    self.* = .{
        .allocator = alloc,
        .smoke = smokeEnabled(),
        .smoke_stay = smokeStaySeconds(),
    };
    // v0.3.10 C2：isolation 会话随机段（ziltiso://<random>/ —— iframe origin 每进程不同）
    if (config.isolation) |iso| {
        self.iso_key = iso_mod.keyFromHex(iso.key_hex) catch |err| blk: {
            log.print("[iso] key parse failed: {s} — isolation disabled", .{@errorName(err)});
            break :blk null;
        };
        if (self.iso_key != null) {
            var hex: [16]u8 = undefined;
            // 会话随机段：时间 ^ 栈地址（origin 区分用途，非密钥）
            const rnd: u64 = @as(u64, @bitCast(c.g_get_real_time())) ^ (@as(u64, @intFromPtr(&hex)) +% 0x9E3779B97F4A7C15);
            _ = iso_mod.sessionRandom(&hex, rnd);
            self.iso_url = std.fmt.allocPrint(alloc, "ziltiso://{s}/", .{hex}) catch null;
            if (self.iso_url) |u| log.print("[iso] enabled (isolation origin {s})", .{u});
        }
    }
    defer {
        self.deinit();
        alloc.destroy(self);
    }

    // 无 DISPLAY 时 gtk_init 会直接 abort —— CI 必须用 xvfb-run
    gtk_compat.gtkInit();
    // v0.3.0：WM 探测（Xvfb 裸跑无 WM → windowMoved/Resized/Focus 不会触发；
    // CI 装 openbox 后这些事件真实生效，冒烟据此决定是否断言）
    self.wm_present = detectWindowManager();
    log.print("[linux] window manager: {s}", .{if (self.wm_present) "present" else "none (Xvfb)"});
    // v0.4.3 L6：FFM 桌面 → 挂窗的 hideOnFocusLost 禁用（Wails 对齐）
    self.ffm = detectFocusFollowsMouse();
    if (self.ffm) log.print("[tray] focus-follows-mouse desktop — attach window hideOnFocusLost disabled", .{});

    // scheme 必须在创建 WebView 之前注册（web process 首次启动后不再接受）
    const wc = c.webkit_web_context_get_default();
    if (wc == null) return error.WebKitContextUnavailable;
    c.webkit_web_context_register_uri_scheme(wc, scheme, Self.onSchemeRequest, self, null);
    // v0.2.9：WebDriver 自动化（zilt-driver 经 WebKitWebDriver 拉起时注入该 env）
    if (std.c.getenv("ZILT_AUTOMATION")) |a| {
        if (std.mem.eql(u8, std.mem.span(a), "1")) {
            c.webkit_web_context_set_automation_allowed(wc, 1);
            log.print("[linux] automation allowed (ZILT_AUTOMATION=1)", .{});
        }
    }
    // v0.2.1：下载事件（分区 context 在 createPartitionContext 里同样注册）
            if (comptime gtk_compat.isGtk4()) {
                const session = gtk_compat.networkSessionDefault();
                _ = c.g_signal_connect_data(session, "download-started", @ptrCast(&Self.onDownloadStarted), self, null, 0);
            } else {
                _ = c.g_signal_connect_data(wc, "download-started", @ptrCast(&Self.onDownloadStarted), self, null, 0);
            }

    // v0.2.2：GApplication 宿主 = 通知 + 单实例 + 深链转交三合一。
    // **先注册再建窗口**：第二实例在远端检测命中后立即转交退出（不建窗口、
    // 不注入脚本）。命令行参数（char**）进程生命周期内持有；冒烟模式会把
    // ZILT_LINUX_SMOKE_DEEPLINK 追加为伪参数，覆盖「启动深链」链路。
    const argv = try collectArgv(alloc);

    // v0.2.7：重启接力拦截（对齐 Windows v0.1.5）——`<exe> --zilt-restart <target>`
    // 等旧实例退出（父进程消失）后 replace 成新版，不进主流程。
    {
        var argv_strs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv_strs.deinit(alloc);
        for (argv) |a| {
            if (a != null) argv_strs.append(alloc, std.mem.span(a)) catch break;
        }
        if (updater.isRestartHelperCall(argv_strs.items)) |target| {
            runRestartHelperLinux(target);
            std.process.exit(0);
        }
    }

    const app_mode = self.initApplication();

    switch (app_mode) {
        .remote => {
            // 第二实例：g_application_run 把 argv 经 command-line 转交主实例后
            // 立即返回 → 退出码 5（对齐 Windows 单实例第二实例语义）
            _ = c.g_application_run(self.gapp.?, @intCast(argv.len), argv.ptr);
            log.print("[single-instance] args forwarded to primary -> exit 5", .{});
            std.process.exit(5);
        },
        else => {},
    }

    // v0.4.0 H10：Unity 会话总线一次性缓存（init 上下文安全；严禁在 script
    // 回调内 acquire——g_bus_get_sync 同步 I/O 重入主循环 abort，实测）
    self.unity_bus = unity_badge.acquireSessionBus();
    log.print("[taskbar] unity session bus: {s}", .{if (self.unity_bus != null) "available" else "unavailable"});

    // v0.4.2 H15：计划通知调度线程（init 启动——回调内 spawn 会 abort，实测）
    const notify_sched = @import("../../notify_sched.zig");
    notify_sched.startScheduler();

    // v0.2.2：运行时菜单模型（托盘菜单驱动）+ 托盘（libayatana 可选，缺失仅日志）
    self.initMenuModel();
    self.initTray();

    // 主窗口（id 固定 1）；spawn 的窗口走同一个创建函数（createWindowInternal）
    var main_opts = ipc.WindowOptions{
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
        // v0.3.0：桌面体验面（透明 / 背景色 / 覆盖式标题栏）
        .transparent = config.transparent,
        .background_color = config.background_color,
        .titlebar_overlay = config.titlebar_overlay,
        // icon / proxy / user_agent：主窗口仍使用平台默认（运行时 setIcon 可改）
    };
    // 冒烟：主窗口 opt-in 关闭请求事件（windowCloseRequested 发给本窗口——
    // 冒烟在主窗口自测「拦截 → 存活」闭环；桌面应用走 config.close_requested_event）
    if (self.smoke) main_opts.close_requested_event = true;
    _ = try self.createWindowInternal(main_opts);

    log.print("[linux] main window ready (gtk={d}.{d}.{d}, smoke={s})", .{
        c.gtk_get_major_version(),
        c.gtk_get_minor_version(),
        c.gtk_get_micro_version(),
        boolStr(self.smoke),
    });

    // 深链 / 文件关联注册（.desktop + xdg-mime；config.deep_link.register）
    self.registerDeepLink();

    // v0.2.3：本地存储（store.json / acl.json，与 windowState 同根）
    self.initStorage();

    // v0.2.7：服务注册表（Config.services → init/start，逆序 deinit）
    self.initServices();

    // v0.2.7：自动更新器（config.update + ZILT_UPDATE_URL/ZILT_UPDATE_PK 覆盖；
    // ZILT_UPDATE_AUTO=1 启动即检查——与 Windows 同语义）
    if (config.update) |uc| {
        if (self.buildUpdaterEnv(uc)) |env| {
            self.updater_env = env;
            log.print("[updater] configured (manifest={s}, current={s})", .{ env.manifest_url, uc.current_version });
            if (std.c.getenv("ZILT_UPDATE_AUTO")) |a| {
                if (std.mem.span(a).len > 0 and std.mem.span(a)[0] == '1') {
                    if (std.Thread.spawn(.{ .stack_size = sys.threadStackSize(512 * 1024) }, Self.updaterFlow, .{self})) |t| {
                        t.detach();
                        log.print("[updater] auto check started", .{});
                    } else |_| {}
                }
            }
        } else |err| {
            log.print("[updater] env build failed: {s} (updater disabled)", .{@errorName(err)});
        }
    }

    // v0.2.7：主题变化事件（GTK settings 全局 → 广播所有窗口）
    self.watchThemeChanges();

    // v0.2.6：X11 全局快捷键（config.hotkeys 声明式注册 + hotkey.* 运行时 op）
    self.initHotkeys();

    // v0.3.2：电源/会话事件（GDBus 订阅 org.freedesktop.login1；无系统总线仅日志）
    self.initLogindEvents();

    // v0.2.3：应用自定义协议 → 真 scheme（Config.protocols；每协议一个 scheme）
    self.registerProtocolSchemes(wc);

    // v0.2.2：剪贴板变化监听（owner-change → clipboardChanged 事件）
    if (config.clipboard_change_event) {
        const cb = gtk_compat.clipboardGet();
        if (cb != null) {
            gtk_compat.clipboardConnectChanged(cb, &Self.onClipboardChangedEvent, self);
            log.print("[clip] change listener attached", .{});
        }
    }

    // v0.3.1：更新健康确认（对齐 Windows v0.1.15）——新版本跑满 10s 才删除
    // .zilt-old 备份，避免「刚启动就删掉回滚凭据」。
    if (config.update != null) {
        _ = c.g_timeout_add_seconds(10, Self.healthConfirmIdle, self);
        log.print("[updater] health timer armed (10s)", .{});
    }

    if (app_mode == .primary) {
        // 主实例：g_application_run 兼任主循环（command-line 信号承载深链/聚焦）。
        // HANDLES_COMMAND_LINE 的应用在 command-line 处理完、use count 为 0 时
        // 会直接退出 → 先 hold，requestQuit 里再 release+quit。
        c.g_application_hold(self.gapp.?);
        self.app_held = true;
        _ = c.g_application_run(self.gapp.?, @intCast(argv.len), argv.ptr);
    } else {
        // 降级（无 D-Bus）：本地分类启动参数（深链启动载荷），gtk_main 承担主循环
        var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args_list.deinit(alloc);
        for (argv[1..]) |a| { // 跳过程序自身
            if (a == null) continue;
            args_list.append(alloc, std.mem.span(a)) catch break;
        }
        if (args_list.items.len > 0) self.handleLaunchArgs(args_list.items);
        gtk_compat.mainLoopRun();
    }

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
            view: ?*c.WebKitWebView,
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
            /// 内容根（GtkBox 纵向：可选菜单栏 + overlay）；窗口销毁时随控件树释放
            box: [*c]c.GtkWidget = null,
            /// 每窗口菜单栏（config.menu；null = 无菜单）
            menubar: [*c]c.GtkWidget = null,
            /// 菜单项激活时的 user_data（窗口销毁时统一释放）
            menu_actions: std.ArrayListUnmanaged(*MenuAction) = .empty,
            view: ?*c.WebKitWebView,
            ucm: ?*c.WebKitUserContentManager,
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
            /// v0.2.2：菜单加速键的 GtkAccelGroup（惰性创建；窗口销毁时随 GTK 释放）
            // GTK4 无 GtkAccelGroup（accel 面移除）→ 占位不透明类型
            accel_group: if (gtk_compat.isGtk4()) ?*anyopaque else ?*c.GtkAccelGroup = null,
            /// v0.3.9 A4L：窗口级 KeyBindings（创建时解析好的 keyval/mods；
            /// key-press-event 匹配——菜单 accel 由 GTK accel group 先行消费）
            key_bindings: []const KeyBindEntry = &.{},
            /// 页面是否已完成首次加载（runtime 注入就绪）——深链事件投递的前置条件
            loaded: bool = false,
            /// v0.2.6：窗口事件去重（configure/focus 抖动过滤 + 关闭请求 opt-in）
            reported_x: i32 = -2147483647,
            reported_y: i32 = -2147483647,
            reported_w: i64 = -1,
            reported_h: i64 = -1,
            reported_focus: bool = false,
            close_requested_event: bool = false,
            // ---- v0.3.0：桌面体验面（透明 / 覆盖式标题栏 / 精细控制 / 拖出）----
            /// 透明窗口（RGBA visual + 空白背景；desktop 透出）
            transparent: bool = false,
            /// WebView 背景色（0xRRGGBB；null = 引擎默认白底）
            background_color: ?u32 = null,
            /// 覆盖式标题栏（无原生边框；前端 data-zilt-drag-region 拖动）
            titlebar_overlay: bool = false,
            /// v0.3.2：无痕窗口（ephemeral data manager；Cookie/存储不落盘）
            incognito: bool = false,
            /// v0.4.0 H7：拖放开关（false = 不挂 drag-dest——页面原生 drag 可用）
            drag_drop: bool = true,
            /// v0.4.0 H8：JS 开关（false = WebKitSettings enable-javascript=false，
            /// 本窗口注入 runtime 不可用——kiosk 锁定用途）
            javascript: bool = true,
            // v0.4.3 L6：托盘挂窗（tray.attach_window label 匹配标记 + 失焦抑制窗）
            tray_attached: bool = false,
            /// 显示挂窗后短暂抑制失焦隐藏（focus-follows-mouse WM 下指针
            /// 掠过即失焦——Wails 对齐语义，600ms 窗口）
            hide_suppress_until_ms: i64 = 0,
            /// v0.4.2 H17：拖出 opt-in drag source（runtime dragstart 桥标记）
            drag_source: bool = false,
            // ---- v0.3.3：窗口体验包 II ----
            hide_on_focus_lost: bool = false,
            hide_on_escape: bool = false,
            prevent_overflow: bool = false,
            titlebar_double_click: ?bool = null,
            /// 鼠标穿透（GdkWindow input shape 置空）
            ignore_cursor: bool = false,
            /// 当前设置的光标（gdk_window_set_cursor 自己持有 ref；替换时 unref 旧值）
            cursor: ?*c.GdkCursor = null,
            /// 光标隐藏状态（1×1 透明 cursor 顶替）
            cursor_hidden: bool = false,
            /// 待拖出的文件（drag-data-get 时转 text/uri-list）
            drag_files: std.ArrayListUnmanaged([]u8) = .empty,
            /// v0.3.0：创建期已恢复的几何（WM 下 map 前的 move 会被忽略，
            /// map-event 时补一次；只补一次，避免盖掉用户后续拖动）
            restored_geometry: bool = false,
            restored_x: i32 = 0,
            restored_y: i32 = 0,
            /// v0.3.0：焦点轮询（X11 焦点直接落在 WebKit 子窗口时 GTK 不派发
            /// focus-in/out，也不更新 has-toplevel-focus → 200ms 轮询兜底）
            focus_timer: c.guint = 0,
        };

        /// 子 WebView（webviews.* op 管理的窗口内附加视图）。
        const ChildView = struct {
            id: u32,
            view: ?*c.WebKitWebView,
            ucm: ?*c.WebKitUserContentManager,
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
        /// 分区 WebContext 表项（key = 规范化后的分区名）。
        /// 同名分区复用同一 context → 同分区多个子 WebView 共享存储。
        /// 6.0：网络/存储面在 session（与 ctx 配对使用）。
        const PartitionCtx = struct {
            name: []u8,
            ctx: ?*c.WebKitWebContext,
            session: ?*anyopaque = null,
        };

        /// per-window WebView 代理（v0.2.7，对齐 Windows v0.1.23）：同 proxy 串
        /// 复用同一 WebContext（独立数据目录，cookie/缓存不与主窗口共享）。
        /// 6.0：网络面拆到 WebKitNetworkSession（与 ctx 同 manager 源）。
        const ProxyEntry = struct {
            proxy: []u8,
            ctx: ?*c.WebKitWebContext,
            session: ?*anyopaque = null,
        };

        /// 进行中的下载（v0.2.1）。WebKit 持有 WebKitDownload 的所有权，
        /// 我们只记 id + 上次上报的进度（节流）。
        const Download = struct {
            backend: *Self,
            id: u64,
            dl: ?*c.WebKitDownload,
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

        /// 剪贴板 HTML/文件列表的异步载荷（GTK 在目标程序粘贴时才调用 get 回调，
        /// 生命周期跟着剪贴板 owner 走，由 clear 回调释放）。
        const ClipPayload = struct {
            backend: *Self,
            data: []u8,
            // GTK4 走 eager content provider（无延迟提供回调）→ 占位类型
            targets: if (gtk_compat.isGtk4()) []u8 else []c.GtkTargetEntry,
        };

        /// 菜单项激活的 user_data（窗口注册表持有，窗口销毁时统一释放）。
        const MenuAction = struct {
            backend: *Self,
            win_id: u32,
            kind: MenuKind,
            id: []u8,
            /// v0.2.2：预定义角色（undo/redo/cut/copy/paste/delete/select_all）
            role: ?[]u8 = null,
        };
        const MenuKind = enum { menu, tray_menu };

        /// 托盘（v0.2.2）：libayatana-appindicator3 为**可选依赖**，用 dlopen 动态加载；
        /// 缺失时只记日志不阻断启动。
        const Tray = struct {
            lib: std.DynLib,
            indicator: ?*anyopaque,
            set_status: *const fn (?*anyopaque, c_int) callconv(.c) void,
            set_menu: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
        };

        /// v0.3.2：logind 订阅状态（signal id 供将来注销；connection 生命周期
        /// 与进程一致——GIO 全局默认主上下文持有，无需显式 unref）。
        const LogindState = struct {
            /// GDBusConnection 是 opaque 类型——以 anyopaque 句柄持有（调用点 @ptrCast）
            connection: ?*anyopaque = null,
            sleep_sub: c.guint = 0,
            lock_sub: c.guint = 0,
            unlock_sub: c.guint = 0,
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

        /// fs watch / 流式读的封送任务（v0.2.3）。
        const FsWatchEvent = struct {
            backend: *Self,
            id: i64,
            action: []const u8,
            path: []u8,
        };
        const FsChunkEvent = struct {
            backend: *Self,
            id: i64,
            seq: u64,
            done: bool,
            data: []u8,
        };
        const FsStreamJob = struct {
            backend: *Self,
            id: i64,
            path: []u8,
            chunk_size: usize,
        };

        /// HTTP 请求上下文（send_async 完成回调的 user_data；libsoup 全程主循环）。
        const HttpJob = struct {
            backend: *Self,
            id: i64,
            session: [*c]c.SoupSession,
            msg: ?*c.SoupMessage,
            stream: ?[*c]c.GInputStream = null,
            body: std.ArrayListUnmanaged(u8) = .empty,
            stream_mode: bool = false,
            seq: u64 = 0,
            /// v0.3.8 E6：multipart 上传（粗粒度进度：libsoup3 无字节级上传
            /// 进度 API → send 前 0/total、httpFinish 时 total/total 两帧，文档化差异）
            upload: bool = false,
            upload_total: usize = 0,
        };

        /// WebSocket 连接（soup_websocket_connect_async 的会话 + 连接 + 信号 id）。
        const WsConn = struct {
            backend: *Self,
            id: i64,
            session: [*c]c.SoupSession,
            /// SoupWebsocketConnection 是 opaque → 单指针
            conn: ?*c.SoupWebsocketConnection,
            msg: ?*c.SoupMessage = null,
            msg_handler: c.gulong = 0,
            closed_handler: c.gulong = 0,
            error_handler: c.gulong = 0,
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
        /// 当前剪贴板 HTML/文件列表载荷（v0.2.2；clear 回调里释放）
        clip_payload: ?*ClipPayload = null,
        /// GNotification 宿主（v0.2.2；注册失败时通知降级为日志）
        gapp: ?*c.GApplication = null,
        gapp_registered: bool = false,
        /// g_application_run 的 hold 标记（HANDLES_COMMAND_LINE 下 command-line
        /// 处理完若无 hold 会直接退出主循环——必须显式 hold 到 quit）
        app_held: bool = false,
        /// 托盘（libayatana 动态加载；null = 不可用/未配置）
        tray: ?Tray = null,
        /// v0.4.0 H10：Unity LauncherEntry 会话总线连接（init 一次性缓存——
        /// script 回调内 g_bus_get_sync 会重入主循环 abort，实测教训）
        unity_bus: ?*anyopaque = null,
        /// v0.4.2 H17：下一窗口的拖出 opt-in 标记（createWindowInternal → attachIpc
        /// 单跳传递；attachIpc 无 per-window opts 参数——经 Self 单字段传递）
        pending_drag_source: bool = false,
        /// v0.4.2 H3：libsecret 密钥环（config.store_encrypted 且 dlopen 成功；
        /// null = 明文降级——与 DPAPI 缺失语义同构）
        secret: ?libsecret.SecretLib = null,
        /// ---- v0.2.2：运行时菜单模型 / 深链 / 拖放 ----
        /// 菜单模型（与 Windows 对齐：config.tray.menu 初始化；menu.* op 可变，
        /// 变更后重建托盘菜单；每窗口菜单栏仍是 config.menu 静态树）
        menu_state: ?menu_model.Model = null,
        /// 模型驱动的托盘 GtkMenu。有 indicator 时所有权归 indicator（替换后旧菜单
        /// 由 indicator 析构，绝不能再 destroy）；无 indicator 时归我们
        ///（tray_menu_owned = true，替换/退出时 destroy）。
        // GTK4：libayatana-appindicator3 为 GTK3 链接库，进程内不可载 → 无托盘
        tray_menu_widget: if (gtk_compat.isGtk4()) ?*anyopaque else ?*c.GtkMenu = null,
        /// v0.4.3 L6：XEmbed 托盘自建 GtkStatusIcon（左键 activate → 挂窗 toggle；
        /// 几何经 gtk_status_icon_get_geometry）。与 SNI 的 libayatana 互斥。
        tray_status_icon: if (gtk_compat.isGtk4()) ?*anyopaque else ?*c.GtkStatusIcon = null,
        /// v0.4.3 L6：secondary activate 目标控件（挂窗点击面；托盘存续期持有）
        tray_sec_target: ?*anyopaque = null,
        /// v0.4.3 L6：挂窗 toggle 去抖（Wails WindowDebounce 语义——SNI 与
        /// GtkStatusIcon 回退路径可能对同一次点击各触发一遍，且双击不应抖动）
        tray_toggle_ms: i64 = 0,
        tray_menu_owned: bool = false,
        /// v0.4.3 L6：焦点跟随鼠标桌面（Hyprland/Sway/i3 等）——挂窗的
        /// hideOnFocusLost 在这些桌面下禁用（Wails 对齐；否则指针离开即消失）
        ffm: bool = false,
        /// 启动 / 第二实例转交的深链载荷（页面尚未就绪时挂起，load-finished 补发）
        pending_launch: ?deep_link.Launch = null,
        /// 冒烟：dropFiles 模拟投递只发一次
        smoke_drop_sent: bool = false,
        /// 冒烟：主实例保持存活的秒数（ZILT_LINUX_SMOKE_STAY，第二实例转交 E2E 用）
        smoke_stay: u32 = 0,
        /// 退出中（后台线程据此停止产出）
        quitting: bool = false,
        /// ---- v0.2.3：存储 / fs / SQL / 网络 ----
        /// 应用数据根（store.json / acl.json；与 windowState 同根）
        storage_root: ?[]u8 = null,
        store: ?store_mod.Store = null,
        /// 运行时授权（acl.json 持久化；对齐 Windows v0.1.21）
        acl_grants: std.ArrayListUnmanaged([]const u8) = .empty,
        acl_loaded: bool = false,
        /// inotify 监视表 / 流式读 job
        fs_watches: std.ArrayListUnmanaged(*fs_watch_mod.Watch) = .empty,
        next_fs_watch_id: i64 = 1,
        next_fs_stream_id: i64 = 1,
        /// SQL lib 缓存（进程内一次加载）
        sqlite_lib: ?*linux_sqlite.Lib = null,
        /// v0.3.10 C2：isolation（随机 origin 的隔离 iframe URL + 解封密钥）
        iso_url: ?[]u8 = null,
        iso_key: ?iso_mod.Key = null,
        iso_cache: iso_mod.ReplayCache = .{},
        /// X11 全局快捷键（v0.2.6；config.hotkeys 启动注册 + hotkey.* 运行时 op）
        hotkeys: ?*hotkey_mod.Manager = null,
        /// v0.3.10 D1：Wayland portal 快捷键（Wayland 会话取代 XGrabKey Manager）
        hotkeys_portal: ?*portal_hotkey.Portal = null,
        /// HTTP（libsoup3；事件 httpResponse / httpChunk）
        next_http_id_seq: i64 = 1,
        /// WebSocket 连接表（SoupWebsocketConnection 所有权在此）
        ws_conns: std.AutoHashMapUnmanaged(i64, *WsConn) = .empty,
        next_ws_id_seq: i64 = 1,
        /// ---- v0.2.7：services / updater / per-window 代理 ----
        /// 服务注册表（Config.services 声明 → init/start，对齐 Windows v0.1.16）
        services: ?shared_services.Registry = null,
        /// 自动更新器（共享 updater.zig；Linux 侧 stageBytes 走 POSIX 原子替换）
        updater_env: ?updater.Env = null,
        update_cfg: ?Config.Update = config.update,
        /// per-window WebView 代理（对齐 Windows v0.1.23）：同 proxy 串复用独立
        /// WebContext（独立数据目录 + scheme 处理器），cookie/缓存与主窗口隔离
        proxy_ctxs: std.ArrayListUnmanaged(ProxyEntry) = .empty,
        /// ZILT_UPDATE_URL 覆盖的清单 URL（进程生命周期持有）
        updater_url_override: ?[]u8 = null,
        /// 冒烟后置闭环（v0.2.7）：终止检查进行中 / 信号已见 / 首轮结果已定
        terminate_check: bool = false,
        terminate_seen: bool = false,
        smoke_finished: bool = false,
        /// ---- v0.3.0：桌面体验面 ----
        /// WebView 右键菜单 / 脚本对话框信号已接线（冒烟探针断言用）
        context_menu_wired: bool = false,
        script_dialog_wired: bool = false,
        /// 会话是否有窗口管理器（Xvfb 裸跑为 false；CI 装 openbox 后为 true）。
        /// windowMoved/Resized/Focus 需要 WM 才会触发（configure/focus 信号）。
        wm_present: bool = false,
        /// 子进程槽表（v0.3.0；exit 事件后由 UI 线程摘除并 join）
        procs: std.ArrayListUnmanaged(*ProcSlot) = .empty,
        /// 通知按钮载荷表 + GAction 注册标记（v0.3.0）
        notify_actions: std.ArrayListUnmanaged(NotifyActionEntry) = .empty,
        notify_action_added: bool = false,
        /// v0.3.2：logind 订阅状态（电源/会话事件）
        logind: LogindState = .{},

        fn deinit(self: *Self) void {
            // 主循环退出后可能仍有窗口未 destroy（ctx.quit 路径）→ 逐个释放记录
            while (self.windows.items.len != 0) self.freeWindowState(self.windows.items[0]);
            self.windows.deinit(self.allocator);
            for (self.partitions.items) |pe| {
                c.g_object_unref(@ptrCast(pe.ctx));
                if (pe.session) |s| c.g_object_unref(@ptrCast(s));
                self.allocator.free(pe.name);
            }
            self.partitions.deinit(self.allocator);
            // v0.2.7：per-window 代理 context（生命周期同 partitions）
            for (self.proxy_ctxs.items) |pe| {
                c.g_object_unref(@ptrCast(pe.ctx));
                if (pe.session) |s| c.g_object_unref(@ptrCast(s));
                self.allocator.free(pe.proxy);
            }
            self.proxy_ctxs.deinit(self.allocator);
            // v0.2.7：服务注册表（stopAll + 逆序 deinit）
            if (self.services) |*r| r.deinit();
            var it = self.asset_cache.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.asset_cache.deinit(self.allocator);
            for (self.downloads.items) |d| self.allocator.destroy(d);
            self.downloads.deinit(self.allocator);
            if (self.clip_payload) |p| {
                self.allocator.free(p.data);
                self.allocator.free(p.targets);
                self.allocator.destroy(p);
                self.clip_payload = null;
            }
            // v0.2.2：菜单模型（arena 统一回收节点与字符串）
            if (self.menu_state) |*m| m.deinit();
            // 托盘菜单：有 indicator 时归它（进程退出无需释放）；无 indicator 归我们
            if (self.tray_menu_widget) |menu| {
                if (comptime gtk_compat.isGtk3()) {
                    if (self.tray_menu_owned) c.gtk_widget_destroy(@ptrCast(menu));
                }
                self.tray_menu_widget = null;
            }
            if (self.tray_sec_target) |sec| {
                if (comptime gtk_compat.isGtk3()) c.g_object_unref(sec);
                self.tray_sec_target = null;
            }
            // v0.4.3 L6：XEmbed 自建托盘图标（GTK3 独占；先隐藏再 unref）
            if (self.tray_status_icon) |si| {
                if (comptime gtk_compat.isGtk3()) {
                    c.gtk_status_icon_set_visible(si, 0);
                    c.g_object_unref(@ptrCast(si));
                }
                self.tray_status_icon = null;
            }
            if (self.tray) |*t| t.lib.close();
            if (self.gapp) |app| c.g_object_unref(@ptrCast(app));
            if (self.pending_launch) |*launch| launch.deinit(self.allocator);
            if (self.hotkeys) |m| m.deinit();
            // v0.2.3：存储 / fs / SQL
            for (self.fs_watches.items) |w| fs_watch_mod.stop(w);
            self.fs_watches.deinit(self.allocator);
            for (self.acl_grants.items) |g| self.allocator.free(g);
            self.acl_grants.deinit(self.allocator);
            {
                var ws_it = self.ws_conns.iterator();
                while (ws_it.next()) |entry| self.freeWsConn(entry.value_ptr.*);
                self.ws_conns.deinit(self.allocator);
            }
            if (self.store) |*st| st.deinit();
            if (self.storage_root) |r| self.allocator.free(r);
            if (self.updater_url_override) |u| self.allocator.free(u);
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
            for (st.menu_actions.items) |action| {
                self.allocator.free(action.id);
                if (action.role) |r| self.allocator.free(r);
                self.allocator.destroy(action);
            }
            st.menu_actions.deinit(self.allocator);
            for (st.child_webviews.items) |cv| self.freeChildView(cv);
            st.child_webviews.deinit(self.allocator);
            if (st.focus_timer != 0) {
                _ = c.g_source_remove(st.focus_timer);
                st.focus_timer = 0;
            }
            // v0.3.0：光标引用 / 待拖文件
            if (st.cursor) |cursor| c.g_object_unref(@ptrCast(cursor));
            for (st.drag_files.items) |f| self.allocator.free(f);
            st.drag_files.deinit(self.allocator);
            // v0.3.9 A4L：窗口级 KeyBindings（id 所有权）
            for (st.key_bindings) |kb| self.allocator.free(kb.id);
            if (st.key_bindings.len > 0) self.allocator.free(st.key_bindings);
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
        /// v0.4.0 H6：config.data_dir 覆盖优先（Tauri appDirectoriesOverride 对齐）。
        fn appDataRoot(self: *Self) ?[]u8 {
            if (config.data_dir) |d| return self.allocator.dupe(u8, d) catch null;
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

        fn findPartition(self: *Self, name: []const u8) ?ProxyPieces {
            for (self.partitions.items) |pe| {
                if (std.mem.eql(u8, pe.name, name)) return .{ .ctx = pe.ctx, .session = pe.session };
            }
            return null;
        }

        /// 为分区建独立 WebContext：独立 `WebKitWebsiteDataManager`
        ///（base-data-directory = <应用数据目录>/partitions/<name>）→ 该分区的
        /// Cookie/localStorage/IndexedDB 与其他分区、默认 context 完全隔离。
        /// scheme 处理器同样注册（资产服务对分区子 WebView 可用）。
        /// 返回的 context 引用归注册表（deinit 时释放）。
        fn createPartitionContext(self: *Self, name: []const u8) !ProxyPieces {
            const dir = try self.partitionDirectory(name);
            defer self.allocator.free(dir);
            // 目录不存在则创建（WebKit 会往里写 localStorage/IndexedDB 等）
            makeDirPath(self.allocator, dir);
            const dir_z = try dupeZ(self.allocator, dir);
            defer self.allocator.free(dir_z);

            // 6.0：分区隔离由 session 目录承载；GTK3：manager + context
            const session = if (comptime gtk_compat.isGtk4())
                gtk_compat.networkSessionNew(dir_z.ptr, dir_z.ptr)
            else
                null;
            // 初始引用归分区表所有（create 的 rc=1 直接转交）。此前这里 defer
            // unref 再在调用方补 ref——函数返回时 session 已析构，调用方 ref 的是
            // 悬垂指针：GTK4 冒烟实测 g_object_ref 断言 + g_object_new 收到
            // invalid unclassed object（WebKitNetworkSession），随后 SIGABRT。
            errdefer if (session) |s| c.g_object_unref(@ptrCast(s));
            const mgr = if (comptime gtk_compat.isGtk3())
                gtk_compat.websiteDataManagerNew(dir_z.ptr)
            else
                null;
            defer if (mgr) |m| c.g_object_unref(@ptrCast(m));

            const ctx: ?*c.WebKitWebContext = @ptrCast(@alignCast(gtk_compat.webContextNewWithManager(mgr)));
            if (ctx == null) return error.WebKitContextUnavailable;
            c.webkit_web_context_register_uri_scheme(ctx, scheme, Self.onSchemeRequest, self, null);
            if (comptime gtk_compat.isGtk4()) {
                _ = c.g_signal_connect_data(session, "download-started", @ptrCast(&Self.onDownloadStarted), self, null, 0);
            } else {
                _ = c.g_signal_connect_data(ctx, "download-started", @ptrCast(&Self.onDownloadStarted), self, null, 0);
            }
            log.print("[webviews] partition '{s}' context created ({s})", .{ name, dir });
            // 注册表持引用（session 初始引用 + ctx 引用都归表）
            return .{ .ctx = ctx, .session = session };
        }

        // ------------------------------------------------------------------
        // WebView 脚本 / IPC 投递
        // ------------------------------------------------------------------

        /// 向指定 UCM 注册 document-start 用户脚本（runtime / init / 冒烟）。
        fn addUserScriptTo(
            self: *Self,
            scripts: *std.ArrayListUnmanaged(?*c.WebKitUserScript),
            ucm: ?*c.WebKitUserContentManager,
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
        fn attachIpc(self: *Self, sink: *IpcSink, ucm: ?*c.WebKitUserContentManager, scripts: *std.ArrayListUnmanaged(?*c.WebKitUserScript)) void {
            if (!gtk_compat.registerScriptMessageHandler(ucm, "zilt")) {
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
            if (self.iso_url) |u| {
                const iso_script = std.fmt.allocPrint(self.allocator, "window.__ZILT_ISO__='{s}';", .{u}) catch null;
                if (iso_script) |sc| {
                    self.addUserScriptTo(scripts, ucm, sc);
                    self.allocator.free(sc);
                }
            }
            // v0.4.2 H17：拖出 opt-in 标记（先于 runtime——桥按标记接线）
            if (self.pending_drag_source) {
                self.addUserScriptTo(scripts, ucm, "window.__ZILT_DRAG_SOURCE__=true;");
                self.pending_drag_source = false;
            }
            self.addUserScriptTo(scripts, ucm, ipc.runtime_js);
            // v0.3.14 G26：缩放控件 polyfill（WebKitGTK 无 IsZoomControlEnabled 对等；
            // 对齐 Tauri zoomHotkeysEnabled 的 Linux 手法——Ctrl/Cmd ±/0 → zoom 请求）
            self.addUserScriptTo(scripts, ucm, zoom_hotkey_polyfill);
            for (config.init_scripts) |script| self.addUserScriptTo(scripts, ucm, script);
            if (self.smoke) {
                // v0.5.9：变体能力表先于检查脚本注入——降级面据此显式 skip，
                // 而不是把「GTK4 没有这个面」记成失败。
                var caps_buf: [256]u8 = undefined;
                if (gtk_compat.capsJson(&caps_buf)) |cj| {
                    const marker = std.fmt.allocPrint(self.allocator, "window.__ziltSmokeCaps = {s};", .{cj}) catch null;
                    if (marker) |mk| {
                        defer self.allocator.free(mk);
                        self.addUserScriptTo(scripts, ucm, mk);
                    }
                }
                self.addUserScriptTo(scripts, ucm, smoke_script);
                // 冒烟：把注入的启动深链暴露给检查脚本（ZILT_LINUX_SMOKE_DEEPLINK）
                if (std.c.getenv("ZILT_LINUX_SMOKE_DEEPLINK")) |u| {
                    const s = std.mem.span(u);
                    if (s.len > 0) {
                        if (jsonStr(self.allocator, s)) |uj| {
                            defer self.allocator.free(uj);
                            const marker = std.fmt.allocPrint(self.allocator, "window.__ziltSmokeDeepLink = {s};", .{uj}) catch null;
                            if (marker) |mk| {
                                defer self.allocator.free(mk);
                                self.addUserScriptTo(scripts, ucm, mk);
                            }
                        }
                    }
                }
            }
        }

        /// 执行一段 JS（UI 线程）。WebKit 会把脚本复制进异步任务，返回后即可释放入参。
        fn evalScriptOn(view: ?*c.WebKitWebView, script: []const u8) void {
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
        fn deliverAlloc(self: *Self, view: ?*c.WebKitWebView, json: []const u8) void {
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
                // v0.3.8 C1L：二进制 IPC（evaluate base64 通道；Windows 为 SharedBuffer）
                .post_binary_fn = postBinaryEntry,
                // v0.2.2：剪贴板 + 原生对话框
                .clipboard_write_fn = clipboardWriteTextEntry,
                .clipboard_read_fn = clipboardReadTextEntry,
                .clipboard_read_data_fn = clipboardReadDataEntry,
                .clipboard_write_data_fn = clipboardWriteDataEntry,
                .dialog_fn = dialogEntry,
                .start_drag_fn = startDragEntry,
                .notify_fn = notifyEntry,
                .notification_show_fn = notificationShowEntry,
                .notification_update_fn = notificationUpdateEntry,
                .notification_status_fn = notificationStatusEntry,
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

        fn quitEntry(backend: *anyopaque, code: u8) void {
            _ = code;
            const self: *Self = @ptrCast(@alignCast(backend));
            _ = c.g_idle_add(quitIdle, self);
        }

        // ---- v0.3.8 C1L：二进制 IPC（evaluate base64 通道）----
        // WebKitGTK 无 SharedBuffer 对等 API（Windows 走 CreateSharedBuffer +
        // PostSharedBufferToScript）→ 载荷 base64 编码后 evaluateJavaScript 注入
        // `window.__ziltSharedBufferArrived(additional, b64)`（runtime tail 定义，
        // 与 Windows sharedbufferreceived 桥同一事件契约：解码 + checksum 比对）。
        // g_idle_add 封送——script-message-handler 回调内直接 evaluate 有重入
        // 风险，对齐 Windows 的 WM marshal 策略（v0.3.6 实测同款陷阱）。

        const BinaryJob = struct {
            backend: *Self,
            win_id: u32,
            bytes: []u8,
            additional: []u8,
        };

        fn postBinaryEntry(backend: *anyopaque, window_id: u32, bytes: []const u8, additional_json: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(backend));
            const job = try self.allocator.create(BinaryJob);
            errdefer self.allocator.destroy(job);
            job.* = .{
                .backend = self,
                .win_id = if (window_id == 0) 1 else window_id,
                .bytes = try self.allocator.dupe(u8, bytes),
                .additional = try self.allocator.dupe(u8, additional_json),
            };
            _ = c.g_idle_add(binaryPostIdle, job);
        }

        fn binaryPostIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const job: *BinaryJob = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            const self = job.backend;
            defer {
                self.allocator.free(job.bytes);
                self.allocator.free(job.additional);
                self.allocator.destroy(job);
            }
            if (self.windowById(job.win_id)) |w| {
                const encoder = std.base64.standard.Encoder;
                const b64 = self.allocator.alloc(u8, encoder.calcSize(job.bytes.len)) catch return G_SOURCE_REMOVE;
                defer self.allocator.free(b64);
                _ = encoder.encode(b64, job.bytes);
                const script = std.fmt.allocPrint(self.allocator, "window.__ziltSharedBufferArrived({s}, '{s}')", .{ job.additional, b64 }) catch return G_SOURCE_REMOVE;
                defer self.allocator.free(script);
                // evaluate 的 JS 错误必须显式回显（null 回调会静默吞掉
                // ReferenceError——smoke.js 超时的排查证据）
                c.webkit_web_view_evaluate_javascript(w.view, script.ptr, @intCast(script.len), null, null, null, onBinaryEvalDone, self);
                log.print("[binipc] posted {d} bytes via evaluate channel (additional={s})", .{ job.bytes.len, job.additional });
            } else {
                log.print("[binipc] dropped (window #{d} gone)", .{job.win_id});
            }
            return G_SOURCE_REMOVE;
        }

        fn onBinaryEvalDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            _ = user_data;
            var err: [*c]c.GError = null;
            _ = c.webkit_web_view_evaluate_javascript_finish(@ptrCast(source), res, &err);
            if (err != null) {
                log.print("[binipc] evaluate js error: {s}", .{std.mem.span(err.*.message)});
                c.g_error_free(err);
            }
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

        fn quitIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const self: *Self = @ptrCast(@alignCast(data orelse {
                gtk_compat.mainLoopQuit();
                return G_SOURCE_REMOVE;
            }));
            self.requestQuit();
            return G_SOURCE_REMOVE;
        }

        /// 退出主循环：primary 走 release + g_application_quit（g_application_run
        /// 的循环）；降级 / 未注册走 gtk_main_quit。
        fn requestQuit(self: *Self) void {
            if (self.gapp != null and self.gapp_registered) {
                if (self.app_held) {
                    c.g_application_release(self.gapp.?);
                    self.app_held = false;
                }
                c.g_application_quit(self.gapp.?);
            } else {
                gtk_compat.mainLoopQuit();
            }
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

            const win = gtk_compat.windowNew();
            if (win == null) return error.WindowCreateFailed;
            const win_typed: [*c]c.GtkWindow = @ptrCast(win);
            // 失败路径统一销毁窗口控件（此时 destroy 信号尚未连接，不会触碰 Zig 记录）
            errdefer gtk_compat.windowDestroy(win_typed);

            const title_z = try dupeZ(self.allocator, opts.title);
            defer self.allocator.free(title_z);
            c.gtk_window_set_title(win_typed, title_z.ptr);
            c.gtk_window_set_default_size(win_typed, @intCast(opts.width), @intCast(opts.height));
            c.gtk_window_set_resizable(win_typed, if (opts.resizable) 1 else 0);
            // v0.3.0：覆盖式标题栏 = 无原生边框（客户区覆盖整窗；前端自绘 +
            // data-zilt-drag-region 拖动，语义对齐 Windows v0.1.23）
            const overlay_title = opts.titlebar_overlay;
            c.gtk_window_set_decorated(win_typed, if (opts.decorations and !overlay_title) 1 else 0);
            if (opts.always_on_top) gtk_compat.setKeepAbove(win_typed, true);
            if (opts.skip_taskbar) gtk_compat.setSkipTaskbar(win_typed, true);
            if (opts.x != null and opts.y != null) gtk_compat.windowMove(win_typed, opts.x.?, opts.y.?);
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

            // v0.3.9 A4L：窗口级 KeyBindings——创建时解析 keyval/mods（解析失败的
            // 项跳过，对齐 Windows mergeKeyBindingAccel 的语义）；id 所有权随窗口释放
            const kb_entries: []KeyBindEntry = blk: {
                const kbs = opts.key_bindings orelse break :blk &.{};
                if (kbs.len == 0) break :blk &.{};
                const entries = try self.allocator.alloc(KeyBindEntry, kbs.len);
                var n: usize = 0;
                errdefer {
                    for (entries[0..n]) |e| self.allocator.free(e.id);
                    self.allocator.free(entries);
                }
                for (kbs) |hk| {
                    const parsed = parseAccelGtk(accelTextOf(hk)) orelse continue;
                    entries[n] = .{
                        .id = try self.allocator.dupe(u8, hk.id),
                        .mods = parsed.mods,
                        .keyval = parsed.keyval,
                    };
                    n += 1;
                }
                break :blk entries[0..n];
            };

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
                .close_requested_event = ipc.resolveCloseRequested(opts.close_requested_event, config.close_requested_event),
                .min_width = opts.min_width orelse 0,
                .min_height = opts.min_height orelse 0,
                .max_width = opts.max_width orelse 0,
                .max_height = opts.max_height orelse 0,
                .titlebar_overlay = overlay_title,
                .transparent = opts.transparent,
                .background_color = opts.background_color,
                .hide_on_focus_lost = opts.hide_on_focus_lost,
                .hide_on_escape = opts.hide_on_escape,
                .prevent_overflow = opts.prevent_overflow,
                .titlebar_double_click = opts.titlebar_double_click,
                // v0.4.0：H7 拖放开关 / H8 JS 开关
                .drag_drop = opts.drag_drop,
                .javascript = opts.javascript,
                .drag_source = opts.drag_source,
                // v0.4.3 L6：tray.attach_window label 匹配（与 Windows 的
                // tray_attached 同语义；toggle 兜底 mainWindow）
                .tray_attached = if (opts.label) |lbl|
                    (if (config.tray) |tray|
                        (tray.attach_window != null and std.mem.eql(u8, lbl, tray.attach_window.?))
                    else
                        false)
                else
                    false,
                .key_bindings = kb_entries,
            };

            // 内容根：GtkBox（纵向）＝ 可选菜单栏 + GtkOverlay
            const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
            if (box == null) return error.WindowCreateFailed;
            st.box = @ptrCast(box);
            if (config.menu) |items| {
                const menubar = self.buildMenuBar(items, st);
                if (menubar != null) {
                    st.menubar = menubar;
                    gtk_compat.boxPackStart(@ptrCast(@alignCast(box)), menubar);
                }
            }

            // GtkOverlay 布局容器（见 WinState.overlay 注释）
            const overlay = c.gtk_overlay_new();
            if (overlay == null) return error.WebViewCreateFailed;
            st.overlay = @ptrCast(overlay);
            gtk_compat.boxPackStartFill(@ptrCast(@alignCast(box)), overlay); // 主内容区必须 expand+fill
            if (comptime gtk_compat.isGtk4()) {
                c.gtk_window_set_child(win_typed, box);
            } else {
                c.gtk_container_add(@ptrCast(win), box);
            }

            const ucm = c.webkit_user_content_manager_new();
            if (ucm == null) return error.UserContentManagerFailed;
            st.ucm = ucm;

            const sink = try self.allocator.create(IpcSink);
            errdefer self.allocator.destroy(sink);
            sink.* = .{ .backend = self, .win_id = id, .view = null };
            st.sink = sink;

            // v0.2.7：per-window WebView 代理（opts.proxy）→ 独立 WebContext +
            // 独立数据目录（scheme 处理器齐全）；WebView 用 context 构造，UCM 取
            // view 自带的（同分区子 WebView 的既有手法）。失败降级共享 context。
            var view_widget: [*c]c.GtkWidget = null;
            if (opts.proxy) |proxy| {
                if (self.proxyContext(proxy)) |pieces| {
                    view_widget = @ptrCast(@alignCast(gtk_compat.webViewNew(null, pieces.ctx, pieces.session)));
                    if (view_widget != null) {
                        st.ucm = c.webkit_web_view_get_user_content_manager(@ptrCast(view_widget));
                    }
                } else {
                    log.print("[proxy] context unavailable for '{s}' -> shared context", .{proxy});
                }
            }
            // v0.3.2：无痕窗口（ephemeral data manager；与 proxy 独立 context 同手法）
            if (view_widget == null and opts.incognito) {
                if (self.incognitoContext()) |pieces| {
                    view_widget = @ptrCast(@alignCast(gtk_compat.webViewNew(null, pieces.ctx, pieces.session)));
                    // view 已各自 ref 一份；释放函数转交的初始引用
                    if (pieces.ctx) |cx| c.g_object_unref(@ptrCast(cx));
                    if (pieces.session) |s| c.g_object_unref(@ptrCast(s));
                    if (view_widget != null) {
                        st.ucm = c.webkit_web_view_get_user_content_manager(@ptrCast(view_widget));
                        st.incognito = true;
                    }
                } else {
                    log.print("[incognito] context unavailable -> shared context (data will persist)", .{});
                }
            }
            if (view_widget == null) {
                view_widget = @ptrCast(@alignCast(gtk_compat.webViewNew(ucm, null, null)));
            }
            if (view_widget == null) return error.WebViewCreateFailed;
            const view: ?*c.WebKitWebView = @ptrCast(view_widget);
            st.view = view;
            sink.view = view;
            // v0.4.0 H8：禁用 JS（kiosk/锁定；本窗口注入 runtime 随之不可用——
            // Tauri with_javascript_disabled 同语义。WebKitSettings enable-javascript）
            if (!opts.javascript) {
                const js_settings = c.webkit_web_view_get_settings(view);
                if (js_settings != null) {
                    c.webkit_settings_set_enable_javascript(js_settings, 0);
                    log.print("[settings] javascript disabled (kiosk)", .{});
                }
            }
            // v0.3.15 G14：前进/后退滑动手势（WebKitSettings 原生 API——
            // Windows 走 Settings6 IsSwipeNavigationEnabled，默认关对齐）
            if (config.webview.settings.swipe_gestures) {
                const wsettings = c.webkit_web_view_get_settings(view);
                if (wsettings != null) {
                    c.webkit_settings_set_enable_back_forward_navigation_gestures(wsettings, 1);
                    log.print("[settings] swipe_gestures=true (back-forward gestures)", .{});
                }
            }
            // v0.3.15 G13：browser_accelerators——WebKitGTK 无对应 API（加速键由
            // WM/GTK 消费），文档化 skip
            // 主 WebView 作为 main child：随窗口内容区自动伸缩
            if (comptime gtk_compat.isGtk4()) {
                c.gtk_overlay_set_child(@ptrCast(@alignCast(overlay)), view_widget);
            } else {
                c.gtk_container_add(@ptrCast(overlay), view_widget);
            }

            // v0.3.0：透明窗口 / WebView 背景色（RGBA visual + app_paintable +
            // webkit_web_view_set_background_color；必须在 realize 之前设置）
            Self.applyWindowBackground(st);

            // IPC sink + load-changed（必须在 gtk_main 之前接好；页面脚本要等主循环）
            _ = c.g_signal_connect_data(
                @ptrCast(view_widget),
                "load-changed",
                @ptrCast(&Self.onLoadChanged),
                sink,
                null,
                0,
            );
            self.pending_drag_source = opts.drag_source;
            self.attachIpc(sink, ucm, &st.scripts);

            // v0.2.7：导航策略 / 新窗口策略 / 权限请求 / 渲染进程终止——只挂主
            // WebView（与 Windows「child webview 不挂 driver」的边界一致）。
            _ = c.g_signal_connect_data(@ptrCast(view_widget), "decide-policy", @ptrCast(&Self.onDecidePolicy), sink, null, 0);
            _ = c.g_signal_connect_data(@ptrCast(view_widget), "permission-request", @ptrCast(&Self.onPermissionRequest), sink, null, 0);
            _ = c.g_signal_connect_data(@ptrCast(view_widget), "create", @ptrCast(&Self.onCreate), sink, null, 0);
            _ = c.g_signal_connect_data(@ptrCast(view_widget), "web-process-terminated", @ptrCast(&Self.onWebProcessTerminated), sink, null, 0);

            // v0.3.0：WebView 右键菜单 / 脚本对话框接管（WebKit 原生信号）。
            // 两者都按共享 `webview.Settings` 语义：context_menus=false → 阻止默认菜单
            //（应用可经既有 menu.popup 自绘）；script_dialogs=false → 阻止原生模态框。
            // 冒烟必须无交互：即使配置开启，脚本对话框也一律阻止（否则主循环被卡死）。
            _ = c.g_signal_connect_data(@ptrCast(view_widget), "context-menu", @ptrCast(&Self.onContextMenu), sink, null, 0);
            _ = c.g_signal_connect_data(@ptrCast(view_widget), "script-dialog", @ptrCast(&Self.onScriptDialog), sink, null, 0);
            self.context_menu_wired = true;
            self.script_dialog_wired = true;

            // v0.3.0：拖出（window.zilt.drag.start → text/uri-list 文件拖放）。
            // 只在 JS 主动请求时 begin（不做常驻 drag source——否则会抢走页面
            // 文本选择/图片拖拽的默认手势）。
            if (comptime gtk_compat.isGtk3()) {
                _ = c.g_signal_connect_data(@ptrCast(view_widget), "drag-data-get", @ptrCast(&Self.onDragDataGet), sink, null, 0);
            }

            // v0.2.2：拖放（文件拖入）。dest 与信号挂主 WebView：drag-drop 里
            // gtk_drag_get_data 后返回 TRUE（user handler 先于 WebKit 的 class
            // handler 运行，拦截「拖入文件即导航」的默认行为）；drag-data-received
            // 解析 text/uri-list → dropFiles 事件（对齐 Windows WM_DROPFILES）。
            // v0.4.0 H7：每窗口拖放开关（false = 不挂 drag-dest——页面原生
            // drag 事件可用，dropFiles 事件不再产生；冒烟模拟投递不走 dest）
            if (opts.drag_drop) {
                if (comptime gtk_compat.isGtk4()) {
                    // GTK4：GtkDropTarget 控制器（drop 信号内异步读 uri-list，
                    // 解析 → handleDropUris 与 GTK3 的 drag-data-received 同汇）
                    const mimes = [_][*:0]const u8{ "text/uri-list", "text/plain" };
                    _ = gtk_compat.dropTargetAttach(view_widget, &mimes, &Self.onGdkDrop, sink);
                } else {
                    const dnd_targets = [_]c.GtkTargetEntry{
                        .{ .target = @constCast("text/uri-list"), .flags = 0, .info = 0 },
                        .{ .target = @constCast("text/plain"), .flags = 0, .info = 1 },
                    };
                    c.gtk_drag_dest_set(
                        view_widget,
                        c.GTK_DEST_DEFAULT_ALL,
                        &dnd_targets,
                        dnd_targets.len,
                        c.GDK_ACTION_COPY,
                    );
                    _ = c.g_signal_connect_data(@ptrCast(view_widget), "drag-drop", @ptrCast(&Self.onDragDrop), sink, null, 0);
                    _ = c.g_signal_connect_data(@ptrCast(view_widget), "drag-data-received", @ptrCast(&Self.onDragDataReceived), sink, null, 0);
                }
            }

            // geometry hints（min/max；Xvfb 无 WM 不执行，真实桌面生效）
            gtk_compat.applyGeometryHints(
                win_typed,
                st.min_width,
                st.min_height,
                st.max_width,
                st.max_height,
            );

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
            if (comptime gtk_compat.isGtk3()) {
                _ = c.g_signal_connect_data(win, "configure-event", @ptrCast(&Self.onConfigureEvent), st, null, 0);
            } else {
                // GTK4：size-allocate 信号对 GtkWindow 不存在（实测 GLib CRITICAL）
                // → 尺寸/位置全部走 focusPollTick 的 X11 轮询面（Wayland 以
                // 跟踪值为准，文档化）
            }
            // v0.2.6：窗口事件面——焦点 + 关闭请求（close-request/delete-event 收敛
            // 进 compat；close_requested_event=true 时不销毁、发 windowCloseRequested
            // 由前端确认后调 windowClose——对齐 Windows 的 WM_CLOSE opt-in 语义）
            gtk_compat.connectFocusSignals(win, &Self.onFocusCompat, st);
            if (comptime gtk_compat.isGtk3()) {
                // v0.3.0：WebKit 的焦点落在子 GdkWindow 上，GtkWindow 的 focus-in/out
                // 事件与 is-active 在 openbox 下都拿不到——补 has-toplevel-focus 通知
                //（Wayland 等非 X11 后端的低延迟路径；X11 由 focusPollTick 兜底）。
                _ = c.g_signal_connect_data(win, "notify::has-toplevel-focus", @ptrCast(&Self.onActiveNotify), st, null, 0);
            }
            gtk_compat.connectCloseRequest(win, &Self.onDeleteEvent, st);
            // v0.3.3：Escape 隐藏（hideOnEscape opt-in）
            // v0.3.9 A4L：窗口级 KeyBindings 同一 handler 匹配（有绑定即接线）
            if (st.hide_on_escape or st.key_bindings.len > 0) {
                gtk_compat.connectKeyPress(@ptrCast(win), &Self.onKeyPressCompat, st);
            }
            // v0.3.0：恢复过几何的窗口在 map 后补一次 move（WM 会忽略 map 前的请求）
            if (st.restored_geometry) {
                gtk_compat.connectMap(win, &Self.onMapRestore, st);
            }
            // v0.3.3：窗口形状 mask（PNG alpha → cairo region → shape；realize 后有效）
            if (opts.mask) |mask_path| {
                Self.applyWindowMask(self.allocator, st, mask_path);
            }
            _ = c.g_signal_connect_data(
                overlay,
                "get-child-position",
                @ptrCast(&Self.onChildPosition),
                st,
                null,
                0,
            );

            gtk_compat.showAll(@ptrCast(win));
            if (opts.visible) c.gtk_window_present(win_typed);
            // v0.3.14：创建即最大化（Wails StartState.Maximised / Tauri maximized；
            // show 之后应用——GTK 的 maximize 在映射后生效）
            if (opts.maximized) c.gtk_window_maximize(win_typed);
            // v0.3.14 G11：初始缩放（Wails Zoom 选项；WebKit 级 zoom level）
            if (opts.zoom) |z| {
                if (z > 0.25 and z < 4.0 and st.view != null) {
                    c.webkit_web_view_set_zoom_level(@ptrCast(st.view), z);
                }
            }
            // v0.3.0：焦点轮询（见 WinState.focus_timer 注释）
            st.focus_timer = c.g_timeout_add(200, Self.focusPollTick, st);

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

        // ------------------------------------------------------------------
        // v0.3.0：透明窗口 / 背景色 / 光标 / 拖出
        // ------------------------------------------------------------------

        /// 透明窗口 + WebView 背景色。
        /// 透明需要 RGBA visual + app_paintable + draw 清屏（GTK3 没有「透明窗口」
        /// 开关，必须自己画 alpha=0）；WebView 侧用 set_background_color 让渲染
        /// 结果透出。**必须在 realize（show_all/present）之前调用**。
        fn applyWindowBackground(st: *WinState) void {
            const widget: [*c]c.GtkWidget = @ptrCast(st.win);
            if (st.transparent) {
                var rgba_visual = false;
                if (comptime gtk_compat.isGtk3()) {
                    gtk_compat.applyTransparentWindow(widget);
                    _ = c.g_signal_connect_data(widget, "draw", @ptrCast(&Self.onTransparentDraw), st, null, 0);
                    rgba_visual = true; // GTK3：visual+app_paintable 路径
                } else {
                    // GTK4：display 级 CSS（透明背景类）；visual 由 GDK 自动选择
                    gtk_compat.applyTransparentWindow(widget);
                    rgba_visual = true;
                }
                var clear = c.GdkRGBA{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };
                c.webkit_web_view_set_background_color(st.view, &clear);
                log.print("[window] #{d} transparent (rgba visual={s})", .{ st.id, boolStr(rgba_visual) });
                return;
            }
            if (st.background_color) |rgb| {
                // 0xRRGGBB → GdkRGBA（alpha=1）。字段宽度差异：GTK3 double / GTK4 float
                if (comptime gtk_compat.isGtk4()) {
                    const r: f32 = @floatFromInt((rgb >> 16) & 0xff);
                    const g: f32 = @floatFromInt((rgb >> 8) & 0xff);
                    const b: f32 = @floatFromInt(rgb & 0xff);
                    var color = c.GdkRGBA{ .red = r / 255.0, .green = g / 255.0, .blue = b / 255.0, .alpha = 1 };
                    c.webkit_web_view_set_background_color(st.view, &color);
                } else {
                    const r: f64 = @floatFromInt((rgb >> 16) & 0xff);
                    const g: f64 = @floatFromInt((rgb >> 8) & 0xff);
                    const b: f64 = @floatFromInt(rgb & 0xff);
                    var color = c.GdkRGBA{ .red = r / 255.0, .green = g / 255.0, .blue = b / 255.0, .alpha = 1 };
                    c.webkit_web_view_set_background_color(st.view, &color);
                }
                log.print("[window] #{d} background color #{x:0>6}", .{ st.id, rgb });
            }
        }

        /// 透明窗口清屏：cairo 用 SOURCE 算子把整块区域涂成全透明
        ///（app_paintable 下 GTK 不再画主题背景）。
        fn onTransparentDraw(_: [*c]c.GtkWidget, cr: ?*c.cairo_t, user_data: c.gpointer) callconv(.c) c.gboolean {
            _ = user_data;
            const ctx = cr orelse return 0;
            c.cairo_set_source_rgba(ctx, 0, 0, 0, 0);
            c.cairo_set_operator(ctx, c.CAIRO_OPERATOR_SOURCE);
            c.cairo_paint(ctx);
            return 1;
        }

        /// 1×1 全透明光标（compat 面收敛：GTK4 走 texture 构造）。
        fn blankCursorCompat(widget: [*c]c.GtkWidget) ?*anyopaque {
            return gtk_compat.blankCursorFor(widget);
        }

        /// 把 st.cursor / cursor_hidden 的当前状态落到 GdkWindow。
        fn applyWindowCursor(st: *WinState) bool {
            const widget: [*c]c.GtkWidget = @ptrCast(st.win);
            if (st.cursor_hidden) {
                const blank = blankCursorCompat(widget) orelse return false;
                defer c.g_object_unref(@ptrCast(blank));
                return gtk_compat.surfaceSetCursor(widget, blank);
            }
            return gtk_compat.surfaceSetCursor(widget, st.cursor);
        }

        /// 释放拖出文件列表（替换/窗口销毁时）。
        fn clearDragFiles(self: *Self, st: *WinState) void {
            for (st.drag_files.items) |f| self.allocator.free(f);
            st.drag_files.clearRetainingCapacity();
        }

        /// drag-data-get：把待拖文件列表写成 text/uri-list。
        fn onDragDataGet(
            _: [*c]c.GtkWidget,
            _: ?*c.GdkDragContext,
            data: ?*c.GtkSelectionData,
            _: c.guint,
            _: c.guint,
            user_data: c.gpointer,
        ) callconv(.c) void {
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return));
            const self = sink.backend;
            const st = self.windowById(sink.win_id) orelse return;
            const sel: *c.GtkSelectionData = @ptrCast(@alignCast(data orelse return));
            var views: std.ArrayListUnmanaged([]const u8) = .empty;
            defer views.deinit(self.allocator);
            for (st.drag_files.items) |f| views.append(self.allocator, f) catch return;
            const uri_list = buildUriList(self.allocator, views.items) catch return;
            defer self.allocator.free(uri_list);
            const atom = c.gdk_atom_intern("text/uri-list", 0);
            _ = c.gtk_selection_data_set(sel, atom, 8, uri_list.ptr, @intCast(uri_list.len));
            log.print("[dnd] drag-data-get served {d} file(s) ({d} bytes)", .{
                st.drag_files.items.len,
                uri_list.len,
            });
        }

        /// v0.3.0：`window.zilt.drag.start(files)` —— 记录待拖文件并立即开始
        /// GTK 拖放（text/uri-list，COPY）。目标程序读取时经 drag-data-get 提供。
        fn startDragEntry(backend: *anyopaque, window_id: u32, files: []const []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(backend));
            const st = self.windowById(window_id) orelse return error.DragNotAvailable;
            if (files.len == 0) return error.NoFiles;
            self.clearDragFiles(st);
            for (files) |f| {
                if (f.len == 0) continue;
                const copy = try self.allocator.dupe(u8, f);
                errdefer self.allocator.free(copy);
                try st.drag_files.append(self.allocator, copy);
            }
            if (st.drag_files.items.len == 0) return error.NoFiles;

            // GTK4：GDK 无公开的「脚本发起拖拽」入口（GtkDragSource 仅手势驱动；
            // 低层 gdk_drag_begin 的数据面不走 content provider）→ 文档化 NotAvailable。
            // 待拖文件列表仍记录（恢复 GTK3 或后续 GDK 级方案时语义不变）。
            if (comptime !gtk_compat.programmaticDragAvailable()) {
                log.print("[dnd] drag-out not available under GTK4 (window #{d})", .{st.id});
                return error.DragNotAvailable;
            }
            var x: c.gint = 0;
            var y: c.gint = 0;
            if (!gtk_compat.pointerRootPos(@ptrCast(st.view), &x, &y)) {
                log.print("[dnd] pointer position unavailable", .{});
                return error.DragNotAvailable;
            }
            const widget: [*c]c.GtkWidget = @ptrCast(st.view);

            const targets = [_]c.GtkTargetEntry{
                .{ .target = @constCast("text/uri-list"), .flags = 0, .info = 0 },
            };
            const list = c.gtk_target_list_new(&targets, targets.len);
            if (list == null) return error.DragNotAvailable;
            defer c.gtk_target_list_unref(list);
            _ = c.gtk_drag_begin_with_coordinates(widget, list, c.GDK_ACTION_COPY, 1, null, x, y);
            log.print("[dnd] drag-out started ({d} file(s), window #{d})", .{ st.drag_files.items.len, st.id });
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
                // v0.3.14：list 在 builtin dispatch 就走 window_query_fn（LIST_ALL
                // 哨兵），不会到达这里
                .list => return false,
                // v0.3.16 G21：全工作区可见（gtk_window_stick——所有工作区显示；
                // Tauri visibleOnAllWorkspaces 对齐）
                .visible_on_all_workspaces => |on| {
                    gtk_compat.setSticky(win, on);
                    return true;
                },
                .set_title => |t| {
                    const z = dupeZ(self.allocator, t) catch return false;
                    defer self.allocator.free(z);
                    c.gtk_window_set_title(win, z.ptr);
                },
                .minimize => gtk_compat.setIconic(win, true),
                .maximize => c.gtk_window_maximize(win),
                .restore => {
                    // 全屏 → 最大化 → 最小化，逐层退出（与 Windows restore 语义对齐）
                    if (st.fullscreen) {
                        c.gtk_window_unfullscreen(win);
                        st.fullscreen = false;
                    }
                    if (c.gtk_window_is_maximized(win) != 0) c.gtk_window_unmaximize(win);
                    gtk_compat.setIconic(win, false);
                },
                .fullscreen => |on| {
                    if (on) c.gtk_window_fullscreen(win) else c.gtk_window_unfullscreen(win);
                    st.fullscreen = on;
                },
                .size => |s| {
                    gtk_compat.windowResize(win, @intCast(s.width), @intCast(s.height));
                    // 跟踪值同步：窗口状态持久化在 destroy 期间查不到真实几何
                    st.geom_width = s.width;
                    st.geom_height = s.height;
                },
                .position => |p| {
                    gtk_compat.windowMove(win, p.x, p.y);
                    st.geom_x = p.x;
                    st.geom_y = p.y;
                },
                .show => gtk_compat.showAll(widget),
                .hide => c.gtk_widget_hide(widget),
                .focus => c.gtk_window_present(win),
                .close => {
                    // opt-in：直接发 close-request / delete-event（变体收敛于 compat；
                    // gtk_window_close 实测不派发关闭信号——真实 WM 的关闭请求自然到达）
                    if (st.close_requested_event) {
                        const handled = gtk_compat.emitCloseRequest(win);
                        if (!handled) c.gtk_window_close(win); // 未拦截（理论不达）兜底
                    } else {
                        c.gtk_window_close(win);
                    }
                },
                .resize_dragging => |edge| {
                    // v0.3.3：内容区拖拽缩放（gtk_window_begin_resize_drag）
                    const st2 = self.windowById(window_id) orelse return false;
                    const edge_int: c.gint = if (std.mem.eql(u8, edge, "n"))
                        gtk_compat.EDGE_NORTH
                    else if (std.mem.eql(u8, edge, "s"))
                        gtk_compat.EDGE_SOUTH
                    else if (std.mem.eql(u8, edge, "e"))
                        gtk_compat.EDGE_EAST
                    else if (std.mem.eql(u8, edge, "w"))
                        gtk_compat.EDGE_WEST
                    else if (std.mem.eql(u8, edge, "ne"))
                        gtk_compat.EDGE_NORTH_EAST
                    else if (std.mem.eql(u8, edge, "nw"))
                        gtk_compat.EDGE_NORTH_WEST
                    else if (std.mem.eql(u8, edge, "sw"))
                        gtk_compat.EDGE_SOUTH_WEST
                    else
                        gtk_compat.EDGE_SOUTH_EAST;
                    var px: c.gint = 0;
                    var py: c.gint = 0;
                    if (!gtk_compat.pointerRootPos(widget, &px, &py)) return false;
                    gtk_compat.beginResizeDrag(st2.win, edge_int, px, py);
                    return true;
                },
                // v0.3.3：体验包 II 的 Linux 范围——simple_fullscreen 语义同 fullscreen；
                // button_state（GTK3 无每按钮 API）与 move_debounce → NotSupported（文档化）
                .simple_fullscreen => |on| {
                    if (on) {
                        c.gtk_window_fullscreen(win);
                    } else {
                        c.gtk_window_unfullscreen(win);
                    }
                },
                .button_state => return false, // GTK3 无 per-button API（文档化）
                .move_debounce => return false, // Linux 未接线（文档化）
                // ---- v0.3.14：窗口 API 收尾（对齐 Wails/Tauri；GTK 等价实现）----
                // center：居中到最近显示器工作区（gdk_monitor_get_workarea）
                .center => {
                    const display = c.gdk_display_get_default() orelse return false;
                    const monitor = if (gtk_compat.surfaceOf(widget) != null)
                        gtk_compat.monitorAtSurface(widget)
                    else
                        gtk_compat.displayPrimaryMonitor(display);
                    if (monitor == null) return false;
                    var wa: c.GdkRectangle = undefined;
                    gtk_compat.monitorWorkarea(monitor, &wa);
                    var ww: c.gint = 0;
                    var wh: c.gint = 0;
                    gtk_compat.windowGetSize(win, &ww, &wh);
                    const x = wa.x + @divTrunc(wa.width - ww, 2);
                    const y = wa.y + @divTrunc(wa.height - wh, 2);
                    gtk_compat.windowMove(win, x, y);
                    st.geom_x = x;
                    st.geom_y = y;
                    return true;
                },
                // toggleMaximize：最大化/还原切换
                .toggle_maximize => {
                    if (c.gtk_window_is_maximized(win) != 0) c.gtk_window_unmaximize(win) else c.gtk_window_maximize(win);
                    return true;
                },
                // setResizable / setDecorations（GTK 原生 API）
                .resizable => |on| {
                    c.gtk_window_set_resizable(win, @intFromBool(on));
                    return true;
                },
                .decorated => |on| {
                    c.gtk_window_set_decorated(win, @intFromBool(on));
                    return true;
                },
                // destroy：强制销毁（绕过 delete-event 请求链；对齐 Tauri destroy()）
                // GTK3 无 gtk_window_destroy（GTK4 才有）——用 gtk_widget_destroy
                .destroy_win => {
                    gtk_compat.windowDestroy(win);
                    return true;
                },
                // setScreen：移动到目标显示器工作区（gdk_display 枚举序，与
                // system.info('monitors') 一致）
                .set_screen => |index| {
                    const display2 = c.gdk_display_get_default() orelse return false;
                    const n = gtk_compat.displayMonitorCount(display2);
                    if (index >= @as(u32, @intCast(n))) return false;
                    const monitor = gtk_compat.displayMonitorAtIdx(display2, @intCast(index)) orelse return false;
                    var wa: c.GdkRectangle = undefined;
                    gtk_compat.monitorWorkarea(monitor, &wa);
                    var ww: c.gint = 0;
                    var wh: c.gint = 0;
                    gtk_compat.windowGetSize(win, &ww, &wh);
                    const width = @min(ww, wa.width);
                    const height = @min(wh, wa.height);
                    const x = wa.x + @divTrunc(wa.width - width, 2);
                    const y = wa.y + @divTrunc(wa.height - height, 2);
                    gtk_compat.windowMove(win, x, y);
                    st.geom_x = x;
                    st.geom_y = y;
                    return true;
                },
                .start_dragging => {
                    // 无鼠标事件上下文也能拖：取指针根坐标（begin 细节收敛 compat）
                    var x: c.gint = 0;
                    var y: c.gint = 0;
                    if (!gtk_compat.pointerRootPos(widget, &x, &y)) return false;
                    gtk_compat.beginMoveDrag(win, x, y);
                },
                .always_on_top => |on| {
                    gtk_compat.setKeepAbove(win, on);
                    st.always_on_top = on;
                },
                .always_on_bottom => |on| {
                    gtk_compat.setKeepBelow(win, on);
                    st.always_on_bottom = on;
                },
                .skip_taskbar => |on| gtk_compat.setSkipTaskbar(win, on),
                .focusable => |on| gtk_compat.setAcceptFocus(win, on),
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
                    gtk_compat.applyGeometryHints(win, st.min_width, st.min_height, st.max_width, st.max_height);
                },
                .fullscreen_monitor => |idx| {
                    if (!gtk_compat.fullscreenOnMonitor(win, idx)) return false;
                    st.fullscreen = true;
                },
                // ---- v0.3.0：窗口精细控制 ----
                .cursor => |kind| {
                    const name = gdkCursorName(kind);
                    var cursor = if (comptime gtk_compat.isGtk4())
                        c.gdk_cursor_new_from_name(name.ptr, null)
                    else
                        c.gdk_cursor_new_from_name(c.gdk_display_get_default(), name.ptr);
                    if (cursor == null and !std.mem.eql(u8, name, "default")) {
                        cursor = if (comptime gtk_compat.isGtk4())
                            c.gdk_cursor_new_from_name("default", null)
                        else
                            c.gdk_cursor_new_from_name(c.gdk_display_get_default(), "default");
                    }
                    if (cursor == null) return false;
                    if (!gtk_compat.surfaceSetCursor(widget, cursor)) {
                        c.g_object_unref(@ptrCast(cursor));
                        return false;
                    }
                    if (st.cursor) |old| c.g_object_unref(@ptrCast(old));
                    st.cursor = cursor;
                    st.cursor_hidden = false;
                    return true;
                },
                .cursor_visible => |visible| {
                    st.cursor_hidden = !visible;
                    return applyWindowCursor(st);
                },
                .cursor_grab => |grab| {
                    if (comptime gtk_compat.isGtk4()) {
                        // 4.14 capi 无 gdk_seat_grab（指针抓取面移除）→ 文档化 skip
                        log.print("[window] cursor grab unsupported under GTK4 (seat grab removed)", .{});
                        return false;
                    }
                    const gdk_win = c.gtk_widget_get_window(widget) orelse return false;
                    const display = c.gdk_window_get_display(gdk_win) orelse return false;
                    const seat = c.gdk_display_get_default_seat(display) orelse return false;
                    if (grab) {
                        const status = c.gdk_seat_grab(
                            seat,
                            gdk_win,
                            c.GDK_SEAT_CAPABILITY_ALL,
                            0,
                            null,
                            null,
                            null,
                            null,
                        );
                        if (status != c.GDK_GRAB_SUCCESS) {
                            log.print("[window] cursor grab failed (status={d})", .{status});
                        }
                    } else {
                        c.gdk_seat_ungrab(seat);
                    }
                    return true;
                },
                .cursor_position => |p| {
                    const display = c.gdk_display_get_default() orelse return false;
                    const seat = c.gdk_display_get_default_seat(display) orelse return false;
                    const pointer = c.gdk_seat_get_pointer(seat) orelse return false;
                    return gtk_compat.deviceWarp(widget, pointer, p.x, p.y);
                },
                .ignore_cursor => |ignore| {
                    if (comptime gtk_compat.isGtk4()) {
                        // GDK4 无 input shape 面 → X11 XShape（Wayland skip 文档化）
                        if (!gtk_compat.inputShapeSetIgnore(widget, ignore)) return false;
                    } else {
                        const gdk_win = c.gtk_widget_get_window(widget) orelse return false;
                        if (ignore) {
                            // 空 input shape = 该窗口不接收指针事件（穿透到下层窗口）
                            const region = c.cairo_region_create() orelse return false;
                            defer c.cairo_region_destroy(region);
                            c.gdk_window_input_shape_combine_region(gdk_win, region, 0, 0);
                        } else {
                            c.gdk_window_input_shape_combine_region(gdk_win, null, 0, 0);
                        }
                    }
                    st.ignore_cursor = ignore;
                    return true;
                },
                .content_protected => {
                    // Linux 无标准「禁止截屏」API（X11 无、Wayland 由 compositor 决定）
                    log.print("[window] content protection not supported on Linux (window #{d})", .{st.id});
                    return false;
                },
                .shadow => |on| {
                    // GTK3 无窗口阴影 API：装饰窗口的阴影由 WM/compositor 提供；
                    // 无边框窗口需要 CSD（GTK4 一等支持）。接受请求但不改变状态。
                    log.print("[window] shadow={s} (WM/compositor-owned on Linux)", .{boolStr(on)});
                    return true;
                },
                .icon => |maybe_path| {
                    if (maybe_path) |path| {
                        const z = dupeZ(self.allocator, path) catch return false;
                        defer self.allocator.free(z);
                        const ok = gtk_compat.setIconFromPath(win, z.ptr);
                        if (!ok) log.print("[window] icon load failed ('{s}')", .{path});
                        return ok;
                    }
                    // null = 清空图标（GTK 回退到默认；GTK4 无属性面 → no-op）
                    gtk_compat.setIcon(win, null);
                    return true;
                },
                // builtin 的 state 动作在调用 window_fn 之前已走 window_query_fn
                // v0.4.2 H16：reparent——WebView 从本窗口容器移挂目标窗口容器
                //（Tauri unstable 语义：移动 webview 而非窗口本身）
                .reparent => |new_parent_id| {
                    const target = self.windowById(if (new_parent_id == 0) 1 else new_parent_id) orelse return false;
                    if (target.id == st.id) return false;
                    const old_box = st.box orelse return false;
                    const view_w: [*c]c.GtkWidget = @ptrCast(st.view orelse return false);
                    if (comptime gtk_compat.isGtk4()) {
                        // GTK4：GtkBox 无 container 面且 reparent 需先 unparent——
                        // view 主挂点在 GtkOverlay（set_child），子视图为 overlay child
                        if (st.overlay != null and old_box == st.box) {
                            // 主视图换窗：目标窗口的 overlay 接收
                            c.gtk_overlay_remove_overlay(@ptrCast(@alignCast(st.overlay)), view_w);
                            c.gtk_overlay_add_overlay(@ptrCast(@alignCast(target.overlay)), view_w);
                        } else {
                            c.gtk_box_remove(@ptrCast(@alignCast(old_box)), view_w);
                            c.gtk_box_append(@ptrCast(@alignCast(target.box)), view_w);
                        }
                    } else {
                        // 主视图在 overlay 的 main child 位（v0.3.11 布局），不是 box
                        // 的直接子控件——从 overlay 摘除后再按 expand+fill 装进目标窗口
                        _ = c.gtk_container_remove(@ptrCast(@alignCast(st.overlay)), view_w);
                        const tbox2 = target.box orelse return false;
                        gtk_compat.boxPackStartFill(@ptrCast(@alignCast(tbox2)), view_w);
                    }
                    st.parent_id = target.id;
                    return true;
                },
                .state => return true,
            }
            return true;
        }

        /// 窗口状态查询 → JSON（字段名与 Windows 的 runWindowQuery 对齐，
        /// style/ex_style 等 Win32 概念在 Linux 恒为 0/false）。
        fn windowQueryEntry(backend: *anyopaque, window_id: u32, alloc: std.mem.Allocator) ?[]u8 {
            const self: *Self = @ptrCast(@alignCast(backend));
            // v0.3.14 G7：LIST_ALL 哨兵 → 全部存活窗口状态数组（Wails GetAll 对齐；
            // 注册表在销毁时即摘除，条目均为存活窗口）
            if (window_id == ipc.WINDOW_LIST_ALL) {
                var out: std.ArrayList(u8) = .empty;
                out.appendSlice(alloc, "[") catch return null;
                var first = true;
                for (self.windows.items) |it| {
                    if (!first) out.appendSlice(alloc, ",") catch return null;
                    first = false;
                    const one = self.windowStateJson(it, alloc) orelse return null;
                    out.appendSlice(alloc, one) catch return null;
                }
                out.appendSlice(alloc, "]") catch return null;
                return out.items;
            }
            const st = self.windowById(window_id) orelse return null;
            return self.windowStateJson(st, alloc);
        }

        /// v0.3.14：单窗口状态 JSON（query / list 共用；新增 resizable/decorated）。
        fn windowStateJson(_: *Self, st: *WinState, alloc: std.mem.Allocator) ?[]u8 {
            const win = st.win;
            const widget: [*c]c.GtkWidget = @ptrCast(win);

            var x: c.gint = 0;
            var y: c.gint = 0;
            gtk_compat.windowGetPosition(win, &x, &y);
            var width: c.gint = 0;
            var height: c.gint = 0;
            gtk_compat.windowGetSize(win, &width, &height);

            const iconic = gtk_compat.surfaceIconified(widget);

            // v0.4.0 H9：物理像素面——frame extents（外框物理）+ 客户区原点；
            // Xvfb 无 WM 时 frame == 窗口 → 边框 0（合法值）；Wayland 无全局
            // 坐标/外框 → false 回退零值（文档化）
            var frame: c.GdkRectangle = std.mem.zeroes(c.GdkRectangle);
            var ox: c.gint = 0;
            var oy: c.gint = 0;
            var scale: c.gint = 1;
            if (gtk_compat.frameExtents(widget, &frame)) {
                _ = gtk_compat.surfaceOrigin(widget, &ox, &oy);
                scale = gtk_compat.surfaceScale(widget);
            }
            const phys_client_w = width * scale;
            const phys_client_h = height * scale;
            const border_left = ox - frame.x;
            const border_top = oy - frame.y;
            const border_right = (frame.x + frame.width) - (ox + phys_client_w);
            const border_bottom = (frame.y + frame.height) - (oy + phys_client_h);

            // v0.4.0：格式化参数超 32 上限 → 两段拼接（head 到 decorated；tail 为
            // v0.4.0 新增字段 drag_drop/javascript/border_sizes/physical_*）
            const head = std.fmt.allocPrint(alloc,
                \\{{"id":{d},"x":{d},"y":{d},"width":{d},"height":{d},"style":0,"ex_style":0,"enabled":{s},"visible":{s},"focused":{s},"zoomed":{s},"iconic":{s},"fullscreen":{s},"always_on_top":{s},"always_on_bottom":{s},"ignore_cursor":{s},"focusable":{s},"content_protected":false,"overlay":{s},"incognito":{s},"monitor":{d},"transparent":{s},"background_color":{d},"min_width":{d},"min_height":{d},"max_width":{d},"max_height":{d},"child_webviews":{d},"resizable":{s},"decorated":{s},
            , .{
                st.id,
                x,
                y,
                width,
                height,
                boolStr(c.gtk_widget_get_sensitive(widget) != 0),
                boolStr(c.gtk_widget_get_visible(widget) != 0),
                boolStr(windowFocused(st)),
                boolStr(c.gtk_window_is_maximized(win) != 0),
                boolStr(iconic),
                boolStr(st.fullscreen),
                boolStr(st.always_on_top),
                boolStr(st.always_on_bottom),
                boolStr(st.ignore_cursor),
                boolStr(gtk_compat.getAcceptFocus(win)),
                boolStr(st.titlebar_overlay),
                boolStr(st.incognito),
                @as(i64, blk: {
                    // v0.3.2：当前窗口所在显示器（枚举序；无 GDK surface 时 0）
                    const widget2: [*c]c.GtkWidget = @ptrCast(win);
                    const display = c.gdk_display_get_default() orelse break :blk 0;
                    const mon = gtk_compat.monitorAtSurface(widget2);
                    if (mon == null) break :blk 0;
                    const n = gtk_compat.displayMonitorCount(display);
                    var idx: c_int = 0;
                    while (idx < n) : (idx += 1) {
                        if (gtk_compat.displayMonitorAtIdx(display, idx) == mon) break;
                    }
                    break :blk @intCast(idx);
                }),
                boolStr(st.transparent),
                if (st.background_color) |bg| @as(i64, bg) else -1,
                st.min_width,
                st.min_height,
                st.max_width,
                st.max_height,
                st.child_webviews.items.len,
                // v0.3.14：GTK 属性直读
                boolStr(c.gtk_window_get_resizable(win) != 0),
                boolStr(c.gtk_window_get_decorated(win) != 0),
            }) catch return null;
            defer alloc.free(head);
            // v0.4.0：H7 拖放开关 / H8 JS 开关（创建期记录）+ H9 边框（非客户区）/
            // 物理位置与尺寸（frame extents 物理外框）
            const tail = std.fmt.allocPrint(alloc,
                \\"drag_drop":{s},"javascript":{s},"parent":{d},"border_sizes":{{"left":{d},"top":{d},"right":{d},"bottom":{d}}},"physical_position":{{"x":{d},"y":{d}}},"physical_size":{{"width":{d},"height":{d}}}}}
            , .{
                boolStr(st.drag_drop),
                boolStr(st.javascript),
                // v0.4.2 H16：父窗口 id（0 = 无父；reparent 后更新）
                @as(u32, if (st.parent_id) |p| p else 0),
                border_left,
                border_top,
                border_right,
                border_bottom,
                ox,
                oy,
                frame.width,
                frame.height,
            }) catch {
                alloc.free(head);
                return null;
            };
            defer alloc.free(tail);
            return std.fmt.allocPrint(alloc, "{s}{s}", .{ head, tail }) catch null;
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
            gtk_compat.windowGetSize(st.win, &query_w, &query_h);
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
            gtk_compat.windowResize(st.win, @intCast(state.width), @intCast(state.height));
            gtk_compat.windowMove(st.win, state.x, state.y);
            st.geom_x = state.x;
            st.geom_y = state.y;
            st.geom_width = state.width;
            st.geom_height = state.height;
            // v0.3.0：WM 下创建期（未 map）的 move 会被忽略 → map 后补一次
            st.restored_geometry = true;
            st.restored_x = state.x;
            st.restored_y = state.y;
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
        // 剪贴板（v0.2.2）：文本 / HTML / 文件列表 / 图片
        // ------------------------------------------------------------------

        /// 剪贴板句柄（GtkClipboard / GdkClipboard 收敛于 compat——不透明句柄）。
        fn gtkClipboard() ?*anyopaque {
            return gtk_compat.clipboardGet();
        }

        /// GTK3 延迟提供面的类型化句柄（set_with_data 需要 GtkClipboard 具体类型）。
        fn gtkClipboardTyped() ?*c.GtkClipboard {
            return @ptrCast(@alignCast(gtkClipboard()));
        }

        fn clipboardWriteTextEntry(_: *anyopaque, text: []const u8) bool {
            const cb = gtkClipboard() orelse return false;
            const z = std.heap.c_allocator.allocSentinel(u8, text.len, 0) catch return false;
            defer std.heap.c_allocator.free(z);
            // allocSentinel 不清零：必须显式拷贝（漏了这步会把未初始化内存写进
            // 剪贴板 → 读回乱码；v0.4.3 L3 冒烟实测的 clipboard 失败根因）
            @memcpy(z, text);
            gtk_compat.clipboardWriteText(cb, z.ptr, text.len);
            return true;
        }

        fn readClipboardText(alloc: std.mem.Allocator) ?[]u8 {
            const cb = gtkClipboard() orelse return null;
            return gtk_compat.clipboardReadText(cb, alloc);
        }

        fn clipboardReadTextEntry(_: *anyopaque, alloc: std.mem.Allocator) ?[]u8 {
            return readClipboardText(alloc);
        }

        fn clipboardReadDataEntry(_: *anyopaque, _: u32, alloc: std.mem.Allocator, format: clipboard.Format) anyerror!?clipboard.Data {
            const cb = gtkClipboard() orelse return error.ClipboardNotAvailable;
            switch (format) {
                .text => {
                    const text = gtk_compat.clipboardReadText(cb, alloc) orelse return null;
                    return clipboard.Data{ .text = text };
                },
                .html => {
                    const raw = gtk_compat.clipboardReadMime(cb, "text/html", alloc) orelse return null;
                    return clipboard.Data{ .html = raw };
                },
                .image => {
                    const img = gtk_compat.clipboardReadImage(cb, alloc) orelse return null;
                    return clipboard.Data{ .image = .{ .width = img.width, .height = img.height, .rgba = img.rgba } };
                },
                .files => {
                    const raw = gtk_compat.clipboardReadUriList(cb, alloc) orelse return null;
                    defer alloc.free(raw);
                    // uri-list（CRLF 分隔）→ 路径数组（两栈输入形状一致）
                    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
                    errdefer for (paths.items) |p| alloc.free(p);
                    errdefer paths.deinit(alloc);
                    var it = std.mem.splitAny(u8, raw, "\r\n");
                    while (it.next()) |uri| {
                        if (uri.len == 0) continue;
                        const path = try fileUriToPath(alloc, uri);
                        paths.append(alloc, path) catch {
                            alloc.free(path);
                            continue;
                        };
                    }
                    if (paths.items.len == 0) return null;
                    return clipboard.Data{ .files = try paths.toOwnedSlice(alloc) };
                },
            }
        }

        fn clipboardWriteDataEntry(backend: *anyopaque, _: u32, data: clipboard.Data) !void {
            const self: *Self = @ptrCast(@alignCast(backend));
            const cb = gtkClipboard() orelse return error.ClipboardNotAvailable;
            switch (data) {
                .text => |text| {
                    if (!clipboardWriteTextEntry(backend, text)) return error.ClipboardWriteFailed;
                },
                .html => |html| try self.writeClipboardPayload("text/html", html),
                .files => |files| {
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer buf.deinit(self.allocator);
                    for (files, 0..) |path, i| {
                        if (i != 0) try buf.append(self.allocator, '\r');
                        if (i != 0) try buf.append(self.allocator, '\n');
                        const uri = try pathToFileUri(self.allocator, path);
                        defer self.allocator.free(uri);
                        try buf.appendSlice(self.allocator, uri);
                    }
                    try buf.appendSlice(self.allocator, "\r\n");
                    try self.writeClipboardPayload("text/uri-list", buf.items);
                },
                .image => |image| {
                    if (image.width == 0 or image.height == 0) return error.ClipboardWriteFailed;
                    const expect = @as(usize, image.width) * image.height * 4;
                    if (image.rgba.len != expect) return error.ClipboardWriteFailed;
                    if (!gtk_compat.clipboardWriteImage(cb, image.rgba, image.width, image.height)) {
                        return error.ClipboardWriteFailed;
                    }
                },
            }
        }

        /// HTML / 文件列表写面。
        /// GTK3：走“延迟提供”（目标粘贴时才回调 clipGet，payload 随 owner-change 释放）。
        /// GTK4：GdkContentProvider 立即提供（GDK4 无 set_with_data 回调面；
        /// mime 内容 + UTF-8 纯文本回退双 provider 联合，语义对齐）。
        fn writeClipboardPayload(self: *Self, mime: [:0]const u8, bytes: []const u8) !void {
            const cb = gtkClipboard() orelse return error.ClipboardNotAvailable;
            if (comptime gtk_compat.isGtk4()) {
                const data_g = c.g_bytes_new(bytes.ptr, bytes.len) orelse return error.ClipboardWriteFailed;
                defer c.g_bytes_unref(data_g);
                const text_g = c.g_bytes_new(bytes.ptr, bytes.len) orelse return error.ClipboardWriteFailed;
                // GBytes 是 refcount 但不是 GObject——g_object_unref 会走
                // invalid unclassed object（GTK4 冒烟实测 GPF/SIGABRT）。
                defer c.g_bytes_unref(text_g);
                const p_mime = c.gdk_content_provider_new_for_bytes(mime.ptr, data_g) orelse return error.ClipboardWriteFailed;
                const p_text = c.gdk_content_provider_new_for_bytes("text/plain;charset=utf-8", text_g) orelse return error.ClipboardWriteFailed;
                var providers = [_][*c]c.GdkContentProvider{ @ptrCast(p_mime), @ptrCast(p_text) };
                const union_p = c.gdk_content_provider_new_union(@as([*c][*c]c.GdkContentProvider, @ptrCast(&providers)), @intCast(providers.len)) orelse return error.ClipboardWriteFailed;
                defer c.g_object_unref(@ptrCast(union_p));
                if (c.gdk_clipboard_set_content(@ptrCast(@alignCast(cb)), @ptrCast(@alignCast(union_p))) == 0) {
                    return error.ClipboardWriteFailed;
                }
                gtk_compat.clipboardStore(cb);
                return;
            }
            const cb3 = gtkClipboardTyped();
            c.gtk_clipboard_clear(cb3); // 释放旧 payload（clipClear）
            const targets = try self.allocator.alloc(c.GtkTargetEntry, 2);
            errdefer self.allocator.free(targets);
            targets[0] = .{ .target = @ptrCast(@constCast(mime.ptr)), .flags = 0, .info = 0 };
            targets[1] = .{ .target = @ptrCast(@constCast("UTF8_STRING")), .flags = 0, .info = 1 };

            const data = try self.allocator.dupe(u8, bytes);
            errdefer self.allocator.free(data);
            const p = try self.allocator.create(ClipPayload);
            errdefer self.allocator.destroy(p);
            p.* = .{ .backend = self, .data = data, .targets = targets };
            if (c.gtk_clipboard_set_with_data(cb3, targets.ptr, @intCast(targets.len), clipGet, clipClear, p) == 0) {
                return error.ClipboardWriteFailed;
            }
            self.clip_payload = p;
            gtk_compat.clipboardStore(cb);
        }

        fn clipGet(_: ?*c.GtkClipboard, selection: ?*c.GtkSelectionData, _: c.guint, user_data: c.gpointer) callconv(.c) void {
            const p: *ClipPayload = @ptrCast(@alignCast(user_data orelse return));
            const sel = selection orelse return;
            const target = c.gtk_selection_data_get_target(sel);
            c.gtk_selection_data_set(sel, target, 8, p.data.ptr, @intCast(p.data.len));
        }

        fn clipClear(_: ?*c.GtkClipboard, user_data: c.gpointer) callconv(.c) void {
            const p: *ClipPayload = @ptrCast(@alignCast(user_data orelse return));
            const backend = p.backend;
            if (backend.clip_payload == p) backend.clip_payload = null;
            backend.allocator.free(p.data);
            backend.allocator.free(p.targets);
            backend.allocator.destroy(p);
        }

        fn onClipboardChangedEvent(user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            const w = self.windowById(0) orelse return;
            const msg = ipc.encodeEvent(self.allocator, "clipboardChanged", "{}") catch return;
            defer self.allocator.free(msg);
            self.deliverAlloc(w.view, msg);
        }

        // ------------------------------------------------------------------
        // 菜单栏 / 托盘（v0.2.2）
        // ------------------------------------------------------------------

        /// 每窗口菜单栏：config.menu（静态树）→ GtkMenuBar。
        /// GTK4：GtkMenuBar 已移除 → 恒 null（menuBarAvailable 收敛点）。
        fn buildMenuBar(self: *Self, items: []const Config.MenuItem, st: *WinState) [*c]c.GtkWidget {
            if (comptime gtk_compat.isGtk4()) {
                log.print("[menu] menu bar unsupported under GTK4 (config.menu ignored)", .{});
                return null;
            }
            const bar = c.gtk_menu_bar_new();
            if (bar == null) return null;
            self.appendMenuItems(@ptrCast(bar), items, st.id, .menu);
            c.gtk_widget_show_all(bar);
            log.print("[menu] menu bar built ({d} top-level items)", .{items.len});
            return bar;
        }

        /// 托盘右键菜单（config.tray.menu）→ GtkMenu。
        fn buildTrayMenu(self: *Self, items: []const Config.MenuItem, win_id: u32) ?*c.GtkMenu {
            const menu_widget = c.gtk_menu_new() orelse return null;
            const menu: *c.GtkMenu = @ptrCast(menu_widget);
            self.appendMenuItems(@ptrCast(menu), items, win_id, .tray_menu);
            c.gtk_widget_show_all(@ptrCast(menu));
            log.print("[tray] menu built ({d} top-level items)", .{items.len});
            return menu;
        }

        /// 递归建菜单：分隔符 "-"；有 items → 子菜单；叶子按 id 绑定 activate。
        /// 无 id 的叶子置灰（与 Windows 的 id 表语义一致）。
        fn appendMenuItems(
            self: *Self,
            shell: [*c]c.GtkMenuShell,
            items: []const Config.MenuItem,
            win_id: u32,
            kind: MenuKind,
        ) void {
            for (items) |item| {
                if (std.mem.eql(u8, item.label, "-")) {
                    const sep = c.gtk_separator_menu_item_new();
                    if (sep != null) {
                        c.gtk_menu_shell_append(shell, sep);
                        c.gtk_widget_show(sep);
                    }
                    continue;
                }
                const label_z = dupeZ(self.allocator, item.label) catch continue;
                defer self.allocator.free(label_z);
                const menu_item = c.gtk_menu_item_new_with_label(label_z.ptr);
                if (menu_item == null) continue;

                if (item.items) |sub_items| {
                    const sub = c.gtk_menu_new();
                    if (sub != null) {
                        self.appendMenuItems(@ptrCast(sub), sub_items, win_id, kind);
                        c.gtk_menu_item_set_submenu(@ptrCast(menu_item), sub);
                    }
                } else if (item.id) |id| {
                    // 统一绑定：activate → menu/trayMenu 事件 + accel + role
                    self.bindMenuItem(menu_item, id, item.accel, item.role, win_id, kind);
                } else {
                    c.gtk_widget_set_sensitive(menu_item, 0);
                }
                c.gtk_menu_shell_append(shell, menu_item);
                c.gtk_widget_show(menu_item);
            }
        }

        fn onMenuActivate(_: [*c]c.GtkMenuItem, user_data: c.gpointer) callconv(.c) void {
            const action: *MenuAction = @ptrCast(@alignCast(user_data orelse return));
            dispatchMenuAction(action.backend, action);
        }

        /// GTK4：GSimpleAction activate/change-state → 同一激活分发面。
        fn onMenuActionGtk4(action_obj: ?*anyopaque, value: ?*anyopaque, user_data: c.gpointer) callconv(.c) void {
            _ = action_obj;
            _ = value;
            const action: *MenuAction = @ptrCast(@alignCast(user_data orelse return));
            dispatchMenuAction(action.backend, action);
        }

        /// 菜单激活统一分发（role → WebKit 编辑命令 + menu/menu/trayMenu 事件）。
        fn dispatchMenuAction(self: *Self, action: *MenuAction) void {
            const name: []const u8 = switch (action.kind) {
                .menu => "menu",
                .tray_menu => "trayMenu",
            };
            // role：编辑命令 + menuRole 事件（对齐 Windows 的 dispatchRole）
            if (action.role) |role| {
                if (self.windowById(action.win_id)) |w| self.dispatchMenuRole(w, action.id, role);
            }
            log.print("[menu] {s} -> {s}", .{ name, action.id });
            const id_json = jsonStr(self.allocator, action.id) orelse return;
            defer self.allocator.free(id_json);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{s}}}", .{id_json}) catch return;
            defer self.allocator.free(payload);
            const target = if (action.kind == .tray_menu) self.windowById(0) else self.windowById(action.win_id);
            const w = target orelse return;
            self.emitRawToWindow(w.id, name, payload);
        }

        /// 菜单角色 → WebKit 编辑命令（undo/redo/cut/copy/paste/select_all；
        /// delete 无专属命令 → document.execCommand）。同时发 menuRole {id, role}。
        fn dispatchMenuRole(self: *Self, w: *WinState, id: []const u8, role: []const u8) void {
            const command: ?[*:0]const u8 = if (std.mem.eql(u8, role, "undo"))
                "Undo"
            else if (std.mem.eql(u8, role, "redo"))
                "Redo"
            else if (std.mem.eql(u8, role, "cut"))
                "Cut"
            else if (std.mem.eql(u8, role, "copy"))
                "Copy"
            else if (std.mem.eql(u8, role, "paste"))
                "Paste"
            else if (std.mem.eql(u8, role, "select_all"))
                "SelectAll"
            else
                null;
            if (command) |cmd| {
                c.webkit_web_view_execute_editing_command(w.view, cmd);
            } else if (std.mem.eql(u8, role, "delete")) {
                evalScriptOn(w.view, "document.execCommand('delete', false, null)");
            } else return;
            const id_json = jsonStr(self.allocator, id) orelse return;
            defer self.allocator.free(id_json);
            const role_json = jsonStr(self.allocator, role) orelse return;
            defer self.allocator.free(role_json);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{s},\"role\":{s}}}", .{ id_json, role_json }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(w.id, "menuRole", payload);
        }

        /// 叶子项统一绑定：activate → menu/trayMenu 事件；accel → 窗口
        /// GtkAccelGroup（GTK_ACCEL_VISIBLE 同时给出右对齐展示）；role 随激活分发。
        fn bindMenuItem(self: *Self, menu_item: [*c]c.GtkWidget, id: []const u8, accel: ?[]const u8, role: ?[]const u8, win_id: u32, kind: MenuKind) void {
            const owner = self.windowById(win_id) orelse return;
            const action = self.allocator.create(MenuAction) catch return;
            const id_copy = self.allocator.dupe(u8, id) catch {
                self.allocator.destroy(action);
                return;
            };
            const role_copy: ?[]u8 = if (role) |r| (self.allocator.dupe(u8, r) catch null) else null;
            action.* = .{ .backend = self, .win_id = win_id, .kind = kind, .id = id_copy, .role = role_copy };
            w_menu_actions_append: {
                owner.menu_actions.append(self.allocator, action) catch break :w_menu_actions_append;
                _ = c.g_signal_connect_data(@ptrCast(menu_item), "activate", @ptrCast(&onMenuActivate), action, null, 0);
                if (accel) |a| self.attachAccel(owner, menu_item, a);
                return;
            }
            self.allocator.free(id_copy);
            if (role_copy) |r| self.allocator.free(r);
            self.allocator.destroy(action);
        }

        /// 加速键：解析 "Ctrl+S" → (mods, keyval)，挂进窗口的 GtkAccelGroup。
        /// 解析失败忽略（与 Windows 的「加速键展示失败不致命」一致）。
        fn attachAccel(self: *Self, w: *WinState, menu_item: [*c]c.GtkWidget, accel: []const u8) void {
            _ = self;
            const parsed = parseAccelGtk(accel) orelse return;
            if (w.accel_group == null) {
                const group = c.gtk_accel_group_new();
                if (group == null) return;
                c.gtk_window_add_accel_group(w.win, @ptrCast(group));
                c.g_object_unref(@ptrCast(group)); // add_accel_group 已持引用
                w.accel_group = group;
            }
            c.gtk_widget_add_accelerator(menu_item, "activate", w.accel_group, parsed.keyval, parsed.mods, c.GTK_ACCEL_VISIBLE);
        }

        /// 模型驱动的托盘菜单（menu.* 变更后整树重建）。
        fn buildTrayMenuFromModel(self: *Self, model: *menu_model.Model) ?*c.GtkMenu {
            const menu_widget = c.gtk_menu_new() orelse return null;
            const menu: *c.GtkMenu = @ptrCast(menu_widget);
            const win_id = if (self.windowById(0)) |w| w.id else 1;
            self.appendModelItems(@ptrCast(menu), model.roots.items, win_id, .tray_menu);
            c.gtk_widget_show_all(@ptrCast(menu));
            return menu;
        }

        /// 递归建菜单（模型节点）：分隔符/子菜单/勾选（GtkCheckMenuItem）/禁用/
        /// 加速键/角色。与 Windows 的 menu_runtime.buildPopup 同构。
        fn appendModelItems(self: *Self, shell: [*c]c.GtkMenuShell, nodes: []*menu_model.Node, win_id: u32, kind: MenuKind) void {
            for (nodes) |node| {
                if (node.isSeparator()) {
                    const sep = c.gtk_separator_menu_item_new();
                    if (sep != null) {
                        c.gtk_menu_shell_append(shell, sep);
                        c.gtk_widget_show(sep);
                    }
                    continue;
                }
                const label_z = dupeZ(self.allocator, node.label) catch continue;
                defer self.allocator.free(label_z);
                const menu_item: [*c]c.GtkWidget = if (node.checked)
                    @ptrCast(c.gtk_check_menu_item_new_with_label(label_z.ptr))
                else
                    @ptrCast(c.gtk_menu_item_new_with_label(label_z.ptr));
                if (menu_item == null) continue;
                if (node.checked) c.gtk_check_menu_item_set_active(@ptrCast(menu_item), 1);

                if (node.children.items.len != 0) {
                    const sub = c.gtk_menu_new();
                    if (sub != null) {
                        self.appendModelItems(@ptrCast(sub), node.children.items, win_id, kind);
                        c.gtk_menu_item_set_submenu(@ptrCast(menu_item), sub);
                    }
                } else if (!node.enabled or node.id.len == 0) {
                    // 无 id 的叶子置灰（与 Windows 的 id 表语义一致）
                    c.gtk_widget_set_sensitive(menu_item, 0);
                } else {
                    self.bindMenuItem(menu_item, node.id, node.accel, node.role, win_id, kind);
                }
                c.gtk_menu_shell_append(shell, @ptrCast(menu_item));
                c.gtk_widget_show(menu_item);
            }
        }

        /// 递归构建 GMenu 模型（GTK4 上下文菜单面）：分隔符/子菜单/勾选/
        /// 禁用。叶子经 GSimpleAction（activate/change-state → dispatchMenuAction）。
        /// action 名在组内全局序号化；动作激活后 popover 关闭（GTK 模型）。
        fn appendModelItemsGMenu(
            self: *Self,
            menu: ?*anyopaque,
            nodes: []*menu_model.Node,
            win_id: u32,
            kind: MenuKind,
            group: ?*anyopaque,
            counter: *u32,
        ) void {
            for (nodes) |node| {
                if (node.isSeparator()) {
                    gtk_compat.menuModelAppendSeparator(menu);
                    continue;
                }
                const label_z = dupeZ(self.allocator, node.label) catch continue;
                defer self.allocator.free(label_z);
                if (node.children.items.len != 0) {
                    const sub = gtk_compat.menuModelNew() orelse continue;
                    self.appendModelItemsGMenu(sub, node.children.items, win_id, kind, group, counter);
                    gtk_compat.menuModelAppendSubmenu(menu, label_z.ptr, sub);
                    continue;
                }
                counter.* += 1;
                const action_name = std.fmt.allocPrintSentinel(self.allocator, "m{d}", .{counter.*}, 0) catch continue;
                defer self.allocator.free(action_name);
                const detailed = std.fmt.allocPrintSentinel(self.allocator, "ziltmenu.{s}", .{action_name}, 0) catch continue;
                defer self.allocator.free(detailed);
                const stateful = node.checked;
                const action = gtk_compat.menuActionAdd(group, action_name.ptr, stateful, node.checked);
                if (action == null) continue;
                if (!node.enabled or node.id.len == 0) {
                    // 无 id 的叶子置灰（与 Windows 的 id 表语义一致）
                    gtk_compat.menuActionSetEnabled(action, false);
                } else if (self.mkMenuAction(win_id, kind, node.id, node.role)) |ma| {
                    gtk_compat.menuActionConnect(action, stateful, &Self.onMenuActionGtk4, ma);
                }
                gtk_compat.menuModelAppendItem(menu, label_z.ptr, detailed.ptr);
            }
        }

        /// MenuAction 构造（bindMenuItem 的无菜单项部分——GTK4 动作面共用）。
        fn mkMenuAction(self: *Self, win_id: u32, kind: MenuKind, id: []const u8, role: ?[]const u8) ?*MenuAction {
            const owner = self.windowById(win_id) orelse return null;
            const action = self.allocator.create(MenuAction) catch return null;
            const id_copy = self.allocator.dupe(u8, id) catch {
                self.allocator.destroy(action);
                return null;
            };
            const role_copy: ?[]u8 = if (role) |r| (self.allocator.dupe(u8, r) catch null) else null;
            action.* = .{ .backend = self, .win_id = win_id, .kind = kind, .id = id_copy, .role = role_copy };
            owner.menu_actions.append(self.allocator, action) catch {
                self.allocator.free(id_copy);
                if (role_copy) |r| self.allocator.free(r);
                self.allocator.destroy(action);
                return null;
            };
            return action;
        }

        /// 程序化弹出（右键上下文菜单）：模型 → 临时 GtkMenu → gtk_menu_popup_at_rect。
        /// deactivate 即销毁（MenuAction 挂在窗口注册表，随窗口释放——与 Windows
        /// 的 TrackPopupMenu 每次全量构建同构）。
        fn popupMenu(self: *Self, x: i32, y: i32) !system_api.Result {
            const model = if (self.menu_state) |*m| m else return error.MenuNotConfigured;
            const w = self.windowById(0) orelse return error.WindowNotFound;
            if (comptime gtk_compat.isGtk4()) {
                // GTK4：GMenu 模型 + GSimpleActionGroup + GtkPopoverMenu
                const gmenu = gtk_compat.menuModelNew() orelse return error.MenuNotConfigured;
                const group = gtk_compat.menuActionGroupNew() orelse return error.MenuNotConfigured;
                var counter: u32 = 0;
                self.appendModelItemsGMenu(@ptrCast(gmenu), model.roots.items, w.id, .menu, group, &counter);
                if (!gtk_compat.menuPopupAt(@ptrCast(@alignCast(w.win)), gmenu, group, x, y)) {
                    return error.MenuNotConfigured;
                }
                log.print("[menu] popup at {d},{d} ({d} roots, gtk4 popover)", .{ x, y, model.roots.items.len });
                return .{ .ok = true };
            }
            const menu_widget = c.gtk_menu_new() orelse return error.MenuNotConfigured;
            self.appendModelItems(@ptrCast(menu_widget), model.roots.items, w.id, .menu);
            c.gtk_widget_show_all(menu_widget);
            _ = c.g_signal_connect_data(@ptrCast(menu_widget), "deactivate", @ptrCast(&onPopupDeactivate), menu_widget, null, 0);
            var rect = c.GdkRectangle{ .x = x, .y = y, .width = 1, .height = 1 };
            const gdk_win = c.gtk_widget_get_window(@ptrCast(w.win));
            c.gtk_menu_popup_at_rect(
                @ptrCast(menu_widget),
                gdk_win,
                &rect,
                c.GDK_GRAVITY_SOUTH_WEST,
                c.GDK_GRAVITY_NORTH_WEST,
                null,
            );
            log.print("[menu] popup at {d},{d} ({d} roots)", .{ x, y, model.roots.items.len });
            return .{ .ok = true };
        }

        fn onPopupDeactivate(widget: [*c]c.GtkWidget, _: c.gpointer) callconv(.c) void {
            c.gtk_widget_destroy(widget);
        }

        /// 运行时菜单模型 op（v0.2.2）：list/add/remove/set/popup。
        /// 与 Windows 的 runMenuOp 同构——模型来自 config.tray.menu，
        /// 变更后重建托盘菜单；每窗口菜单栏保持静态（Windows 同此边界）。
        fn runMenuOp(self: *Self, op: system_api.MenuOp, alloc: std.mem.Allocator) !system_api.Result {
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
                    });
                    self.rebuildTrayMenu();
                    log.print("[menu] added '{s}' under {s}", .{ spec.label, spec.parent orelse "<root>" });
                    return .{ .ok = true };
                },
                .remove => |path| {
                    const model = if (self.menu_state) |*m| m else return error.MenuNotConfigured;
                    const removed = model.remove(path);
                    if (removed) self.rebuildTrayMenu();
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
                    if (changed) self.rebuildTrayMenu();
                    log.print("[menu] set '{s}' (changed={})", .{ spec.path, changed });
                    return .{ .ok = changed };
                },
                .popup => |pt| return self.popupMenu(pt.x, pt.y),
            }
        }

        /// 运行时菜单模型（v0.2.2，与 Windows 对齐）：config.tray.menu 初始化 ——
        /// menu.* op（list/add/remove/set）作用于它并重建托盘菜单；每窗口菜单栏
        /// 仍是 config.menu 的静态树（与 Windows 的 per-window HMENU 行为一致）。
        fn initMenuModel(self: *Self) void {
            const tray_cfg = config.tray orelse return;
            const items = tray_cfg.menu orelse return;
            self.menu_state = menu_model.Model.fromConfig(self.allocator, items) catch |err| {
                log.print("[menu] model init failed: {s}（回退静态菜单）", .{@errorName(err)});
                return;
            };
        }

        /// 托盘初始化：先建菜单（模型驱动，不依赖 libayatana —— menu.* op 与
        /// popup 无 indicator 也可用），再 dlopen libayatana-appindicator3.so.1
        ///（**可选依赖**：缺失/符号缺失只记日志）。
        fn initTray(self: *Self) void {
            if (comptime gtk_compat.isGtk4()) {
                // GTK4 限制：libayatana-appindicator3 链接 GTK3，混载会符号冲突。
                // 托盘面（含 SNI D-Bus 直连方案）记录于 ROADMAP L1b 已知限制。
                log.print("[tray] tray unavailable under GTK4 (ayatana is GTK3-linked)", .{});
                return;
            }
            const tray_cfg = config.tray orelse return;
            // 1) 菜单：模型优先（menu.* 可变）；模型缺失回退静态树
            if (self.menu_state) |*model| {
                if (self.buildTrayMenuFromModel(model)) |menu| self.setTrayMenu(menu);
            } else if (tray_cfg.menu) |items| {
                if (self.buildTrayMenu(items, if (self.windowById(0)) |w| w.id else 1)) |menu| {
                    self.setTrayMenu(@ptrCast(menu));
                }
            }

            // 2) XEmbed 宿主优先：自建 GtkStatusIcon——libayatana 的回退实现把
            // 左键绑成弹菜单（activate → menu），拿不到「左键 toggle」语义；
            // 自建图标还能用 gtk_status_icon_get_geometry 取真实图标矩形。
            if (gtk_compat.hasXembedTray()) {
                self.initTrayXembed(tray_cfg);
                return;
            }

            // 3) 无 XEmbed 宿主 → libayatana（SNI；GNOME/KDE 经 D-Bus 绘制）
            // dlopen（缺失 → 无托盘图标，但菜单/模型仍然可用）
            var lib = std.DynLib.open("libayatana-appindicator3.so.1") catch |err| {
                log.print("[tray] libayatana-appindicator3 unavailable ({s}) — running without tray icon", .{@errorName(err)});
                return;
            };
            const new_fn = lib.lookup(
                *const fn ([*c]const u8, [*c]const u8, c_int) callconv(.c) ?*anyopaque,
                "app_indicator_new",
            ) orelse {
                lib.close();
                log.print("[tray] app_indicator_new not found — tray disabled", .{});
                return;
            };
            const set_status_fn = lib.lookup(
                *const fn (?*anyopaque, c_int) callconv(.c) void,
                "app_indicator_set_status",
            ) orelse {
                lib.close();
                log.print("[tray] app_indicator_set_status not found — tray disabled", .{});
                return;
            };
            const set_menu_fn = lib.lookup(
                *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
                "app_indicator_set_menu",
            ) orelse {
                lib.close();
                log.print("[tray] app_indicator_set_menu not found — tray disabled", .{});
                return;
            };
            const set_icon_fn = lib.lookup(
                *const fn (?*anyopaque, [*c]const u8, [*c]const u8) callconv(.c) void,
                "app_indicator_set_icon_full",
            );
            const set_title_fn = lib.lookup(
                *const fn (?*anyopaque, [*c]const u8) callconv(.c) void,
                "app_indicator_set_title",
            );

            const icon_name = trayIconName(tray_cfg.icon orelse config.icon);
            const id_z = dupeZ(self.allocator, config.app_id) catch return;
            defer self.allocator.free(id_z);
            const icon_z = dupeZ(self.allocator, icon_name) catch return;
            defer self.allocator.free(icon_z);
            // APP_INDICATOR_CATEGORY_APPLICATION_STATUS = 0
            const indicator = new_fn(id_z.ptr, icon_z.ptr, 0) orelse {
                lib.close();
                log.print("[tray] app_indicator_new failed — tray disabled", .{});
                return;
            };
            if (set_icon_fn) |f| f(indicator, icon_z.ptr, icon_z.ptr);
            if (set_title_fn) |f| {
                const title_z = dupeZ(self.allocator, tray_cfg.tooltip) catch null;
                if (title_z) |tz| {
                    defer self.allocator.free(tz);
                    f(indicator, tz.ptr);
                }
            }
            // 菜单已在上面构建（setTrayMenu）；交给 indicator 后所有权归它
            if (self.tray_menu_widget) |menu| set_menu_fn(indicator, menu);

            // v0.4.3 L6：托盘挂窗点击面——secondary activate（SNI 次级激活）→
            // toggle 挂窗。隐藏 GtkMenuItem 作为目标控件（ayatana 内部代理激活）。
            if (lib.lookup(
                *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
                "app_indicator_set_secondary_activate_target",
            )) |sec_fn| {
                if (c.gtk_menu_item_new()) |sec_item| {
                    _ = c.g_object_ref_sink(@ptrCast(sec_item));
                    c.gtk_widget_hide(sec_item);
                    _ = c.g_signal_connect_data(@ptrCast(sec_item), "activate", @ptrCast(&Self.onTraySecondaryActivate), self, null, 0);
                    sec_fn(indicator, @ptrCast(sec_item));
                    self.tray_sec_target = @ptrCast(sec_item);
                    log.print("[tray] secondary activate wired (attach_window toggle)", .{});
                }
            }
            // 说明：libayatana 0.5/0.6 没有 `secondary-activate` GObject 信号
            //（字符串审计确认；D-Bus `SecondaryActivate`/`XAyatanaSecondaryActivate`
            // 由库内部转成「激活 target 菜单项」）→ 上面的隐藏菜单项就是 SNI 面
            // 的点击入口，无需再连信号。
            // APP_INDICATOR_STATUS_ACTIVE = 1
            set_status_fn(indicator, 1);
            self.tray = .{
                .lib = lib,
                .indicator = indicator,
                .set_status = set_status_fn,
                .set_menu = set_menu_fn,
            };
            self.tray_menu_owned = false;
            log.print("[tray] indicator created (icon={s}, menu={})", .{ icon_name, self.tray_menu_widget != null });
        }

        /// v0.4.3 L6：XEmbed 托盘（stalonetray/trayer/xfce4-panel…）自建图标。
        ///
        /// 为什么不复用 libayatana：它在无 SNI 宿主时的 GtkStatusIcon 回退把
        /// 左键绑成「弹菜单」（activate → gtk_menu_popup），拿不到左键 toggle；
        /// 自建图标既能接 activate，又能用 gtk_status_icon_get_geometry 取真实
        /// 图标矩形（挂窗定位锚点，与 Wails 的 gtk_status_icon_get_geometry 一致）。
        fn initTrayXembed(self: *Self, tray_cfg: Config.Tray) void {
            const icon_name = trayIconName(tray_cfg.icon orelse config.icon);
            const icon_z = dupeZ(self.allocator, icon_name) catch return;
            defer self.allocator.free(icon_z);
            const status_icon = c.gtk_status_icon_new_from_icon_name(icon_z.ptr);
            if (status_icon == null) {
                log.print("[tray] gtk_status_icon_new_from_icon_name failed — tray disabled", .{});
                return;
            }
            const title_z = dupeZ(self.allocator, tray_cfg.tooltip) catch null;
            if (title_z) |tz| {
                defer self.allocator.free(tz);
                c.gtk_status_icon_set_title(status_icon, tz.ptr);
                c.gtk_status_icon_set_tooltip_text(status_icon, tz.ptr);
            }
            _ = c.g_signal_connect_data(@ptrCast(status_icon), "activate", @ptrCast(&Self.onXembedTrayActivate), self, null, 0);
            _ = c.g_signal_connect_data(@ptrCast(status_icon), "popup-menu", @ptrCast(&Self.onXembedTrayPopupMenu), self, null, 0);
            c.gtk_status_icon_set_visible(status_icon, 1);
            self.tray_status_icon = status_icon;
            self.tray_menu_owned = true; // 菜单归我们（无 indicator 接管）
            log.print("[tray] xembed status icon created (icon={s}, menu={}, embedded={})", .{
                icon_name, self.tray_menu_widget != null, c.gtk_status_icon_is_embedded(status_icon) != 0,
            });
        }

        fn onXembedTrayActivate(_: ?*c.GtkStatusIcon, user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            self.toggleAttachedWindow();
        }

        /// 右键：图标旁弹菜单（gtk_status_icon_position_menu 负责边缘翻转）。
        fn onXembedTrayPopupMenu(status_icon: [*c]c.GtkStatusIcon, button: c.guint, activate_time: c.guint, user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            const menu = self.tray_menu_widget orelse return;
            c.gtk_menu_popup(menu, null, null, @ptrCast(&c.gtk_status_icon_position_menu), @ptrCast(status_icon), button, activate_time);
            log.print("[tray] xembed popup menu (button={d})", .{button});
        }

        /// 托盘菜单替换。有 indicator 时所有权归它（旧菜单由 indicator 在
        /// set_menu 替换时析构——悬浮引用已被 sink，**绝不能再 destroy**）；
        /// 无 indicator 时归我们（tray_menu_owned = true）。
        fn setTrayMenu(self: *Self, menu: ?*c.GtkMenu) void {
            if (self.tray_menu_widget) |old| {
                if (self.tray_menu_owned) c.gtk_widget_destroy(@ptrCast(old));
            }
            self.tray_menu_widget = menu;
            self.tray_menu_owned = self.tray == null;
            if (self.tray) |*t| {
                if (menu) |m| t.set_menu(t.indicator, m);
            }
        }

        fn rebuildTrayMenu(self: *Self) void {
            if (comptime gtk_compat.isGtk4()) return; // 托盘不可用（菜单模型仍可 list/set）
            const model = if (self.menu_state) |*m| m else return;
            if (self.buildTrayMenuFromModel(model)) |menu| self.setTrayMenu(menu);
        }

        // ------------------------------------------------------------------
        // v0.4.3 L6：托盘挂窗（tray.attach_window）
        // 点击面：libayatana 的 secondary activate（托盘图标中键/宿主次级激活，
        // SNI 协议 SecondaryActivate；左键按 SNI 惯例开菜单）→ toggle。
        // 定位：X11 以指针位置近似图标位（点击瞬时光标即在图标上）→ 窗口右下
        // 对齐 + 工作区夹取；Wayland 无全局坐标 → 保持原位（文档化）。
        // FFM：显示后 600ms 抑制失焦隐藏（notifyFocus 面）。
        // ------------------------------------------------------------------

        fn onTraySecondaryActivate(_: [*c]c.GtkMenuItem, user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            self.toggleAttachedWindow();
        }

        /// 点击入口：去抖（Wails WindowDebounce 语义）。目标菜单项与信号面可能
        /// 对同一次点击各触发一次；双击也不应把窗口瞬间藏了又显。
        fn toggleAttachedWindow(self: *Self) void {
            const now = gtk_compat.nowMs();
            const elapsed = now - self.tray_toggle_ms;
            if (self.tray_toggle_ms != 0 and elapsed < 200) {
                log.print("[tray] toggle debounced ({d}ms)", .{elapsed});
                return;
            }
            self.tray_toggle_ms = now;
            self.toggleAttachedWindowInner(true);
        }

        /// 挂窗定位的一次性校正上下文（延时回调 → 读客户区真实原点 → 补偿 WM
        /// 外框偏移；只校正一次，之后用户拖动/程序移动不再被覆盖）。
        const TrayPosCtx = struct {
            backend: *Self,
            win_id: u32,
            x: c_int,
            y: c_int,
        };

        fn onTrayPosCorrect(user_data: c.gpointer) callconv(.c) c.gboolean {
            const ctx: *TrayPosCtx = @ptrCast(@alignCast(user_data orelse return G_SOURCE_REMOVE));
            defer std.heap.c_allocator.destroy(ctx);
            const st = ctx.backend.windowById(ctx.win_id) orelse return G_SOURCE_REMOVE;
            const widget: [*c]c.GtkWidget = @ptrCast(st.win);
            var ox: c_int = 0;
            var oy: c_int = 0;
            if (!gtk_compat.surfaceOrigin(widget, &ox, &oy)) return G_SOURCE_REMOVE;
            const dx = ctx.x - ox;
            const dy = ctx.y - oy;
            if (dx != 0 or dy != 0) {
                gtk_compat.windowMove(st.win, ctx.x + dx, ctx.y + dy);
                log.print("[tray] attach window #{d} position corrected by {d},{d} (was {d},{d})", .{
                    st.id, dx, dy, ox, oy,
                });
            }
            return G_SOURCE_REMOVE;
        }

        fn toggleAttachedWindowInner(self: *Self, position: bool) void {
            var attached: ?*WinState = null;
            for (self.windows.items) |w| {
                if (w.tray_attached) attached = w;
            }
            const w = attached orelse (self.windowById(0) orelse return);
            const widget: [*c]c.GtkWidget = @ptrCast(w.win);
            const visible = c.gtk_widget_get_visible(widget) != 0;
            if (visible) {
                c.gtk_widget_hide(widget);
                log.print("[tray] attach window #{d} hidden", .{w.id});
                return;
            }
            // 定位锚点：优先图标窗口几何（XEmbed 托盘，stalonetray/trayer/面板），
            // 否则点击瞬时的指针位置（SNI 宿主无图标窗口；X11 下指针就在图标上），
            // Wayland 无全局坐标 → 保持原位（文档化）。
            var target: ?[2]c_int = null;
            var anchor_log: [2]c_int = .{ 0, 0 };
            if (position) {
                var right: c_int = 0;
                var bottom: c_int = 0;
                var top: c_int = 0;
                var anchored = false;
                // ① GtkStatusIcon 几何（XEmbed 自建图标——与 Wails 同源）
                if (self.tray_status_icon) |si| {
                    if (comptime gtk_compat.isGtk3()) {
                        var area: c.GdkRectangle = std.mem.zeroes(c.GdkRectangle);
                        if (c.gtk_status_icon_get_geometry(si, null, &area, null) != 0 and area.width > 0 and area.height > 0) {
                            right = area.x + area.width;
                            bottom = area.y + area.height;
                            top = area.y;
                            anchored = true;
                            log.print("[tray] icon geometry {d},{d} {d}x{d} (status icon)", .{ area.x, area.y, area.width, area.height });
                        }
                    }
                }
                // ② X 树扫描（图标由别的进程绘制、或 geometry 暂不可用）
                if (!anchored) {
                    if (gtk_compat.xembedTrayIconRect()) |r| {
                        right = r.x + r.width;
                        bottom = r.y + r.height;
                        top = r.y;
                        anchored = true;
                        log.print("[tray] icon rect {d},{d} {d}x{d} (xembed)", .{ r.x, r.y, r.width, r.height });
                    }
                }
                // ③ 指针位置（SNI 宿主无图标窗口；X11 下点击点即图标）
                if (!anchored) {
                    var px: c_int = 0;
                    var py: c_int = 0;
                    if (gtk_compat.pointerRootPos(widget, &px, &py)) {
                        right = px;
                        bottom = py;
                        top = py;
                        anchored = true;
                        log.print("[tray] icon geometry unavailable — pointer anchor {d},{d}", .{ px, py });
                    }
                }
                if (anchored) {
                    const display = c.gdk_display_get_default();
                    const prim = gtk_compat.displayPrimaryMonitor(display);
                    var wa: c.GdkRectangle = std.mem.zeroes(c.GdkRectangle);
                    gtk_compat.monitorWorkarea(prim, &wa);
                    var ww: c_int = 0;
                    var wh: c_int = 0;
                    gtk_compat.windowGetSize(w.win, &ww, &wh);
                    var x: c_int = right - ww; // 右缘贴图标右缘（Windows 同款对齐）
                    var y: c_int = bottom + 4;
                    // 底部放不下 → 图标上方
                    if (y + wh > wa.y + wa.height) y = top - wh - 4;
                    x = @min(@max(x, wa.x), @max(wa.x, wa.x + wa.width - ww));
                    y = @min(@max(y, wa.y), @max(wa.y, wa.y + wa.height - wh));
                    target = .{ x, y };
                    anchor_log = .{ right, bottom };
                }
            }
            // 失焦抑制窗：显示后 600ms 内不因失焦隐藏（FFM 桌面另有整段禁用）
            w.hide_suppress_until_ms = gtk_compat.nowMs() + 600;
            c.gtk_widget_show(widget);
            c.gtk_window_present(w.win);
            // **先 show/present 再 move**：openbox 等 reparent 型 WM 会忽略未映射
            // 窗口的 move 请求（退化成智能放置/居中；L6 实测 y=95）。
            if (target) |t| {
                gtk_compat.windowMove(w.win, t[0], t[1]);
                w.geom_x = t[0];
                w.geom_y = t[1];
                // map 后的「恢复启动几何」会盖掉托盘定位（v0.3.0 onMapRestore
                // 的补 move）——挂窗显示时以托盘锚点为准，撤销待补的恢复。
                w.restored_geometry = false;
                // reparent 型 WM（openbox 等）把 ConfigureRequest 当外框位置，
                // 客户区会偏移标题栏高度（L6 实测 +20px）。同步读几何拿到的是
                // 旧值（WM 尚未处理请求），因此延后 80ms 校正一次。
                if (std.heap.c_allocator.create(TrayPosCtx)) |ctx| {
                    ctx.* = .{ .backend = self, .win_id = w.id, .x = t[0], .y = t[1] };
                    _ = c.g_timeout_add(80, @ptrCast(&Self.onTrayPosCorrect), @ptrCast(ctx));
                } else |_| {}
                log.print("[tray] attach window #{d} positioned {d},{d} (anchor {d},{d})", .{ w.id, t[0], t[1], anchor_log[0], anchor_log[1] });
            }
            log.print("[tray] attach window #{d} shown", .{w.id});
        }

        // ------------------------------------------------------------------
        // 通知（v0.2.2）：GNotification（需要 D-Bus session bus；缺失时降级为日志）
        // ------------------------------------------------------------------

        // ------------------------------------------------------------------
        // GApplication 宿主（v0.2.2）：通知 + 单实例 + 深链转交三合一
        // ------------------------------------------------------------------
        //
        // - flags = HANDLES_COMMAND_LINE：主实例通过 command-line 信号收到
        //   第二实例转交的 argv（GApplication 内部经 D-Bus 完成，无需 WM_COPYDATA）。
        // - single_instance=false 时追加 NON_UNIQUE（各自注册，不转交）。
        // - 无 D-Bus 会话总线时 register 失败 → unavailable：通知降级、启动参数
        //   本地解析、主循环退回 gtk_main（对齐「无总线不阻断启动」的设计）。

        const AppMode = enum { primary, remote, unavailable };

        fn initApplication(self: *Self) AppMode {
            var flags: c.GApplicationFlags = c.G_APPLICATION_HANDLES_COMMAND_LINE;
            if (!config.single_instance) flags |= c.G_APPLICATION_NON_UNIQUE;
            const app_id_z = dupeZ(self.allocator, config.app_id) catch return .unavailable;
            defer self.allocator.free(app_id_z);
            const app = c.g_application_new(app_id_z.ptr, flags) orelse return .unavailable;
            _ = c.g_signal_connect_data(@ptrCast(app), "command-line", @ptrCast(&Self.onCommandLine), self, null, 0);
            var err: [*c]c.GError = null;
            const registered = c.g_application_register(app, null, &err) != 0;
            if (err != null) {
                log.print("[app] GApplication register failed: {s}", .{std.mem.span(err.*.message)});
                c.g_error_free(err);
            }
            if (!registered) {
                c.g_object_unref(@ptrCast(app));
                self.gapp = null;
                self.gapp_registered = false;
                log.print("[app] no session bus — single-instance/deep-link forwarding degraded (notifications unavailable)", .{});
                return .unavailable;
            }
            self.gapp = app;
            self.gapp_registered = true;
            if (config.single_instance and c.g_application_get_is_remote(app) != 0) return .remote;
            log.print("[app] GApplication primary (id={s}, single_instance={s})", .{ config.app_id, boolStr(config.single_instance) });
            return .primary;
        }

        /// 主实例收到命令行（自身启动 或 第二实例转交）→ 深链分类 → 事件 / 聚焦。
        /// argv[0] 是程序自身路径，跳过（第二实例转交的是完整 argv）。
        fn onCommandLine(_: *c.GApplication, cmdline: ?*c.GApplicationCommandLine, user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            var argc: c_int = 0;
            const argv = c.g_application_command_line_get_arguments(cmdline, &argc);
            if (argv == null) return;
            defer c.g_strfreev(argv);
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            defer list.deinit(self.allocator);
            var i: usize = 1; // 跳过程序自身
            while (i < @as(usize, @intCast(argc))) : (i += 1) {
                list.append(self.allocator, std.mem.span(argv[i])) catch break;
            }
            log.print("[command-line] {d} args (first={s})", .{ list.items.len, if (list.items.len > 0) list.items[0] else "-" });
            self.handleLaunchArgs(list.items);
        }

        /// 参数分类 → deepLink 事件 / 无参聚焦（与 Windows 的 deep_link 语义对齐）。
        fn handleLaunchArgs(self: *Self, args: []const []const u8) void {
            var launch = deep_link.parseArgs(self.allocator, args, scheme, null, deep_link.pathExists) catch return;
            if (launch.isEmpty()) {
                launch.deinit(self.allocator);
                // 无参二次启动 → 聚焦已有主窗口（对齐 Windows）
                if (self.windowById(0)) |w| c.gtk_window_present(w.win);
                return;
            }
            log.print("[deep-link] launch (url={s}, files={d})", .{ launch.url orelse "-", launch.files.len });
            if (self.emitLaunch(launch)) return;
            // 页面尚未就绪（启动深链）→ 挂起，主窗口 load-finished 时补发
            if (self.pending_launch) |*old| old.deinit(self.allocator);
            self.pending_launch = launch;
        }

        /// deepLink 事件 {url, files}：投递成功返回 true（launch 所有权随之消耗）。
        /// 页面未完成首次加载时返回 false（runtime 未就绪，事件会丢）→ 调用方挂起。
        fn emitLaunch(self: *Self, launch_in: deep_link.Launch) bool {
            var launch = launch_in;
            const w = self.windowById(0) orelse return false;
            if (!w.loaded) return false;
            defer launch.deinit(self.allocator);
            const url_json = if (launch.url) |u|
                (jsonStr(self.allocator, u) orelse return false)
            else
                self.allocator.dupe(u8, "null") catch return false;
            defer self.allocator.free(url_json);
            var payload: std.ArrayListUnmanaged(u8) = .empty;
            defer payload.deinit(self.allocator);
            payload.appendSlice(self.allocator, "{\"url\":") catch return false;
            payload.appendSlice(self.allocator, url_json) catch return false;
            payload.appendSlice(self.allocator, ",\"files\":[") catch return false;
            for (launch.files, 0..) |f, i| {
                if (i != 0) payload.append(self.allocator, ',') catch return false;
                const fj = jsonStr(self.allocator, f) orelse return false;
                defer self.allocator.free(fj);
                payload.appendSlice(self.allocator, fj) catch return false;
            }
            // v0.4.0 H20：结构化参数解析随事件下发（positional/flags/subcommand）
            if (launch.parsed) |*p| {
                const pjson = launch_args.toJson(self.allocator, p) catch return false;
                defer self.allocator.free(pjson);
                payload.appendSlice(self.allocator, ",\"parsed\":") catch return false;
                payload.appendSlice(self.allocator, pjson) catch return false;
            }
            payload.appendSlice(self.allocator, "]}") catch return false;
            self.emitRawToWindow(w.id, "deepLink", payload.items);
            return true;
        }

        /// 页面加载完成 → 补发挂起的启动深链（一次性）。
        fn flushPendingLaunch(self: *Self) void {
            const launch = self.pending_launch orelse return;
            log.print("[deep-link] pending flush attempt (url={s})", .{launch.url orelse "-"});
            if (self.emitLaunch(launch)) {
                self.pending_launch = null;
                log.print("[deep-link] pending flush delivered", .{});
            } else {
                log.print("[deep-link] pending flush deferred (page not ready)", .{});
            }
        }

        /// 深链 / 文件关联注册：应用级 .desktop（MimeType=x-scheme-handler/<scheme>
        /// [+ application/x-<ext>]）+ `xdg-mime default`。完整 MIME 包（glob 映射）
        /// 随 v0.2.4 打包补齐；xdg-mime 缺失/失败只记日志（best-effort）。
        fn registerDeepLink(self: *Self) void {
            const dl = config.deep_link orelse return;
            if (!dl.register) return;
            const exe = deep_link.exePath(self.allocator) catch return;
            defer self.allocator.free(exe);
            const dir = deep_link.applicationsDir(self.allocator) catch return;
            defer self.allocator.free(dir);
            makeDirPath(self.allocator, dir);

            const name = desktop_entry.entryFileName(self.allocator, config.app_id) catch return;
            defer self.allocator.free(name);

            var mimes: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (mimes.items) |m| self.allocator.free(m);
                mimes.deinit(self.allocator);
            }
            {
                const scheme_mime = std.fmt.allocPrint(self.allocator, "x-scheme-handler/{s}", .{dl.scheme}) catch return;
                mimes.append(self.allocator, scheme_mime) catch {
                    self.allocator.free(scheme_mime);
                    return;
                };
            }
            if (dl.file_ext) |ext| {
                const bare = if (ext.len > 0 and ext[0] == '.') ext[1..] else ext;
                if (bare.len > 0) {
                    if (std.fmt.allocPrint(self.allocator, "application/x-{s}", .{bare})) |m| {
                        mimes.append(self.allocator, m) catch self.allocator.free(m);
                    } else |_| {}
                }
            }

            const exec = desktop_entry.formatExec(self.allocator, exe, "%u") catch return;
            defer self.allocator.free(exec);
            const text = desktop_entry.content(self.allocator, .{
                .name = config.title,
                .exec = exec,
                .icon = trayIconName(config.icon),
                .comment = config.title,
                .mime_types = mimes.items,
                .wmclass = config.app_id,
            }) catch return;
            defer self.allocator.free(text);

            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, name }) catch return;
            defer self.allocator.free(path);
            self.writeFileAtomic(path, text) catch |err| {
                log.print("[deep-link] .desktop write failed ({s}): {s}", .{ @errorName(err), path });
                return;
            };
            self.runXdgMime(name, mimes.items);
            log.print("[deep-link] registered scheme '{s}' -> {s}", .{ dl.scheme, path });
        }

        fn runXdgMime(self: *Self, desktop_name: []const u8, mimes: []const []u8) void {
            for (mimes) |mime| {
                const argv = [_][]const u8{ "xdg-mime", "default", desktop_name, mime };
                const result = std.process.run(self.allocator, sharedIo(), .{
                    .argv = &argv,
                    .stdout_limit = .limited(4096),
                    .stderr_limit = .limited(4096),
                }) catch |err| {
                    log.print("[deep-link] xdg-mime spawn failed ({s}) for {s}", .{ @errorName(err), mime });
                    continue;
                };
                defer self.allocator.free(result.stdout);
                defer self.allocator.free(result.stderr);
                const ok = result.term.success();
                log.print("[deep-link] xdg-mime default {s} ({s}, ok={})", .{ mime, desktop_name, ok });
            }
        }

        /// 小文件写入（.desktop / 自启动条目；先建父目录，覆盖式）。
        fn writeFileAtomic(_: *Self, path: []const u8, data: []const u8) !void {
            const io = sharedIo();
            if (std.fs.path.dirname(path)) |dir| {
                _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
            }
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
        }

        fn readFileSmall(self: *Self, path: []const u8) ![]u8 {
            const io = sharedIo();
            return std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(256 * 1024));
        }

        fn sendNotification(self: *Self, tag: ?[]const u8, title: []const u8, body: []const u8) !void {
            const app = self.gapp orelse return error.NotificationNotAvailable;
            if (!self.gapp_registered) return error.NotificationNotAvailable;
            const title_z = try dupeZ(self.allocator, title);
            defer self.allocator.free(title_z);
            const body_z = try dupeZ(self.allocator, body);
            defer self.allocator.free(body_z);
            const n = c.g_notification_new(title_z.ptr) orelse return error.NotificationFailed;
            defer c.g_object_unref(@ptrCast(n));
            c.g_notification_set_body(n, body_z.ptr);
            var tag_z: ?[:0]u8 = null;
            if (tag) |t| tag_z = dupeZ(self.allocator, t) catch null;
            defer if (tag_z) |z| self.allocator.free(z);
            c.g_application_send_notification(app, if (tag_z) |z| z.ptr else null, n);
            log.print("[notify] sent title=\"{s}\" tag={s}", .{ title, tag orelse "-" });
        }

        /// v0.3.0：完整通知（按钮/正文点击 → GAction 索引机制，避免 GVariant
        /// 字符串转义）。input/progress 是 WinRT 独有 → 稳定 NotSupported。
        fn notificationShowEntry(backend: *anyopaque, _: u32, options: notification.Options) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(backend));
            if (options.input != null) return error.NotificationInputNotSupported;
            if (options.progress != null) return error.NotificationProgressNotSupported;
            const app = self.gapp orelse return error.NotificationNotAvailable;
            if (!self.gapp_registered) return error.NotificationNotAvailable;
            self.initNotifyAction();

            const title_z = try dupeZ(self.allocator, options.title);
            defer self.allocator.free(title_z);
            const body_z = try dupeZ(self.allocator, options.body);
            defer self.allocator.free(body_z);
            const n = c.g_notification_new(title_z.ptr) orelse return error.NotificationFailed;
            defer c.g_object_unref(@ptrCast(n));
            c.g_notification_set_body(n, body_z.ptr);

            for (options.actions) |act| {
                const idx = self.registerNotifyAction(if (act.arguments.len > 0) act.arguments else (act.launch orelse act.title), options.tag);
                const detail = std.fmt.allocPrint(self.allocator, "app.zilt-notify::{d}", .{idx}) catch continue;
                defer self.allocator.free(detail);
                const label_z = dupeZ(self.allocator, act.title) catch continue;
                defer self.allocator.free(label_z);
                c.g_notification_add_button(n, label_z.ptr, detail.ptr);
                log.print("[notify] button '{s}' -> action#{d}", .{ act.title, idx });
            }
            if (options.launch) |launch| {
                const idx = self.registerNotifyAction(launch, options.tag);
                const detail = std.fmt.allocPrint(self.allocator, "app.zilt-notify::{d}", .{idx}) catch return;
                defer self.allocator.free(detail);
                c.g_notification_set_default_action(n, detail.ptr);
                log.print("[notify] default action -> action#{d} ({s})", .{ idx, launch });
            }

            var tag_z: ?[:0]u8 = null;
            if (options.tag) |t| tag_z = dupeZ(self.allocator, t) catch null;
            defer if (tag_z) |z| self.allocator.free(z);
            c.g_application_send_notification(app, if (tag_z) |z| z.ptr else null, n);
            log.print("[notify] sent title=\"{s}\" tag={s} buttons={d}", .{ options.title, options.tag orelse "-", options.actions.len });
        }

        /// 注册一次 GAction（app.zilt-notify，参数 int32 索引）——activate 信号
        /// 挂在 SimpleAction 上（GApplication 无 per-action 信号）。
        fn initNotifyAction(self: *Self) void {
            if (self.notify_action_added) return;
            const app = self.gapp orelse return;
            // G_VARIANT_TYPE_INT32 宏 translate-c 失败——用 g_variant_type_new("i")
            const vt = c.g_variant_type_new("i");
            defer c.g_variant_type_free(vt);
            const action = c.g_simple_action_new("zilt-notify", vt);
            if (action == null) return;
            _ = c.g_signal_connect_data(@ptrCast(action), "activate", @ptrCast(&Self.onNotifyActionActivated), self, null, 0);
            c.g_action_map_add_action(@ptrCast(app), @ptrCast(action));
            c.g_object_unref(@ptrCast(action)); // map 持有自己的引用
            self.notify_action_added = true;
            log.print("[notify] GAction 'zilt-notify' registered", .{});
        }

        /// 通知按钮载荷表（索引即槽位；进程生命周期内持有）。
        const NotifyActionEntry = struct {
            arguments: []u8,
            tag: ?[]u8,
        };

        fn registerNotifyAction(self: *Self, arguments: []const u8, tag: ?[]const u8) u32 {
            const args_copy = self.allocator.dupe(u8, arguments) catch return 0;
            const tag_copy: ?[]u8 = if (tag) |t| (self.allocator.dupe(u8, t) catch null) else null;
            self.notify_actions.append(self.allocator, .{ .arguments = args_copy, .tag = tag_copy }) catch {
                self.allocator.free(args_copy);
                if (tag_copy) |t2| self.allocator.free(t2);
                return 0;
            };
            return @intCast(self.notify_actions.items.len - 1);
        }

        fn onNotifyActionActivated(
            action: ?*c.GSimpleAction,
            parameter: ?*c.GVariant,
            user_data: c.gpointer,
        ) callconv(.c) void {
            _ = action;
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            if (parameter == null) return;
            if (self.notify_actions.items.len == 0) return;
            const idx: u32 = @intCast(@as(i64, c.g_variant_get_int32(parameter)));
            if (idx >= self.notify_actions.items.len) return;
            const entry = self.notify_actions.items[idx];
            log.print("[notify] activated action#{d} args={s}", .{ idx, entry.arguments });
            // notification 事件（对齐 Windows toastEventJson 的 activated 形状）
            const args_json = jsonStr(self.allocator, entry.arguments) orelse return;
            defer self.allocator.free(args_json);
            const tag_json = if (entry.tag) |t| (jsonStr(self.allocator, t) orelse return) else self.allocator.dupe(u8, "null") catch return;
            defer self.allocator.free(tag_json);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"tag\":{s},\"kind\":\"activated\",\"arguments\":{s}}}", .{ tag_json, args_json }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(0, "notification", payload);
        }

        fn notificationUpdateEntry(
            backend: *anyopaque,
            _: u32,
            tag: []const u8,
            group: ?[]const u8,
            progress: notification.Progress,
        ) anyerror!void {
            _ = group;
            const self: *Self = @ptrCast(@alignCast(backend));
            const body = if (progress.value_string.len > 0) progress.value_string else progress.status;
            const title = if (progress.title.len > 0) progress.title else config.title;
            try self.sendNotification(tag, title, body);
        }

        fn notificationStatusEntry(backend: *anyopaque, _: u32) anyerror!notification.Status {
            const self: *Self = @ptrCast(@alignCast(backend));
            return if (self.gapp_registered) .enabled else .disabled_for_application;
        }

        /// v0.1.6 兼容入口（ctx.notify）：无 tag 的普通通知。
        const NotifyTask = struct { self: *Self, title: []u8, body: []u8 };

        fn notifyIdle(user_data: c.gpointer) callconv(.c) c.gboolean {
            const t: *NotifyTask = @ptrCast(@alignCast(user_data orelse return 0));
            t.self.sendNotification(null, t.title, t.body) catch |err| {
                log.print("[notify] legacy notify failed: {s}", .{@errorName(err)});
            };
            t.self.allocator.free(t.title);
            t.self.allocator.free(t.body);
            t.self.allocator.destroy(t);
            return 0;
        }

        fn notifyEntry(backend: *anyopaque, title: []const u8, body: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(backend));
            // v0.4.2 H15：调度线程可达——GNotification 调用封送到主循环
            //（g_idle_add；对齐 emit 封送模式，非主线程直呼会 abort）
            const task = self.allocator.create(NotifyTask) catch return;
            task.* = .{
                .self = self,
                .title = self.allocator.dupe(u8, title) catch {
                    self.allocator.destroy(task);
                    return;
                },
                .body = self.allocator.dupe(u8, body) catch {
                    self.allocator.free(task.title);
                    self.allocator.destroy(task);
                    return;
                },
            };
            if (c.g_idle_add(notifyIdle, task) == 0) {
                self.allocator.free(task.title);
                self.allocator.free(task.body);
                self.allocator.destroy(task);
            }
        }

        // ------------------------------------------------------------------
        // 原生对话框（v0.2.2）：消息框 / 文件 / 文件夹 / 多选 / 颜色 / 字体
        // ------------------------------------------------------------------

        fn dialogEntry(backend: *anyopaque, alloc: std.mem.Allocator, req: ipc.DialogRequest) anyerror!ipc.DialogResponse {
            const self: *Self = @ptrCast(@alignCast(backend));
            const parent: [*c]c.GtkWindow = if (self.windowById(0)) |w| w.win else null;
            switch (req) {
                .message_box => |opts| return .{ .button = self.messageBoxDialog(parent, opts) },
                .open_file => |opts| return .{ .path = try self.fileDialog(alloc, parent, opts, .open) },
                .save_file => |opts| return .{ .path = try self.fileDialog(alloc, parent, opts, .save) },
                .pick_folder => |opts| return .{ .path = try self.folderDialog(alloc, parent, opts.title) },
                .pick_files => |opts| return .{ .paths = try self.filesDialog(alloc, parent, opts) },
                .pick_color => |opts| return .{ .color = self.colorDialog(parent, opts) },
                .pick_font => |opts| return .{ .font = try self.fontDialog(alloc, parent, opts) },
            }
        }

        fn messageBoxDialog(self: *Self, parent: [*c]c.GtkWindow, opts: ipc.MessageBoxOptions) ipc.Button {
            _ = self;
            const kind: c.GtkMessageType = switch (opts.kind) {
                .info => c.GTK_MESSAGE_INFO,
                .warning => c.GTK_MESSAGE_WARNING,
                .err => c.GTK_MESSAGE_ERROR,
            };
            const buttons: c.GtkButtonsType = switch (opts.buttons) {
                .ok => c.GTK_BUTTONS_OK,
                .ok_cancel => c.GTK_BUTTONS_OK_CANCEL,
                .yes_no => c.GTK_BUTTONS_YES_NO,
            };
            const text_z = dupeZ(std.heap.c_allocator, opts.text) catch return .cancel;
            defer std.heap.c_allocator.free(text_z);
            const caption_z = dupeZ(std.heap.c_allocator, opts.caption) catch return .cancel;
            defer std.heap.c_allocator.free(caption_z);
            const dlg = c.gtk_message_dialog_new(
                parent,
                c.GTK_DIALOG_MODAL,
                kind,
                buttons,
                "%s",
                text_z.ptr,
            );
            if (dlg == null) return .cancel;
            defer gtk_compat.destroyDialog(@ptrCast(@alignCast(dlg)));
            c.gtk_window_set_title(@ptrCast(dlg), caption_z.ptr);
            return switch (gtk_compat.runDialog(@ptrCast(@alignCast(dlg)))) {
                c.GTK_RESPONSE_OK => .ok,
                c.GTK_RESPONSE_YES => .yes,
                c.GTK_RESPONSE_NO => .no,
                else => .cancel,
            };
        }

        /// ipc.Filter → compat FileFilterSpec（同形状零拷贝映射；null 终结由
        /// compat 内部 dupeZ 处理）。
        fn toFilterSpecs(alloc: std.mem.Allocator, filters: []const ipc.Filter) ![]gtk_compat.FileFilterSpec {
            const out = try alloc.alloc(gtk_compat.FileFilterSpec, filters.len);
            for (filters, 0..) |f, i| out[i] = .{ .name = f.name, .pattern = f.pattern };
            return out;
        }

        const FileMode = enum { open, save };

        /// GtkFileChooserNative：有桌面 portal 时走 portal，否则退化为普通 GtkFileChooserDialog。
        /// 返回路径由 `alloc` 分配；取消返回 null。
        fn fileDialog(
            self: *Self,
            alloc: std.mem.Allocator,
            parent: [*c]c.GtkWindow,
            opts: ipc.FileDialogOptions,
            mode: FileMode,
        ) !?[]u8 {
            _ = self;
            if (comptime gtk_compat.isGtk4()) {
                // GTK4：GtkFileDialog（async → SyncWait 桥保持同步接口）
                const title_z = try dupeZ(alloc, if (opts.title.len > 0) opts.title else (if (mode == .save) "保存文件" else "打开文件"));
                defer alloc.free(title_z);
                const default_z: ?[:0]u8 = if (opts.default_name.len > 0) try dupeZ(alloc, opts.default_name) else null;
                defer if (default_z) |dz| alloc.free(dz);
                const filters = try toFilterSpecs(alloc, opts.filters);
                defer alloc.free(filters);
                const chosen = if (mode == .save)
                    gtk_compat.fileDialogSaveSync(parent, title_z.ptr, if (default_z) |dz| dz.ptr else null, filters, alloc)
                else
                    gtk_compat.fileDialogOpenSync(parent, title_z.ptr, if (default_z) |dz| dz.ptr else null, filters, alloc);
                return chosen;
            }
            const native = (try nativeChooser(alloc, parent, opts, if (mode == .save) .save else .open)) orelse
                return error.DialogNotAvailable;
            defer c.g_object_unref(@ptrCast(native));
            const chooser: *c.GtkFileChooser = @ptrCast(native);
            if (mode == .save) c.gtk_file_chooser_set_do_overwrite_confirmation(chooser, 1);
            if (gtk_compat.nativeDialogRun(native) != c.GTK_RESPONSE_ACCEPT) return null;
            const chosen = c.gtk_file_chooser_get_filename(chooser);
            if (chosen == null) return null;
            defer c.g_free(@ptrCast(chosen));
            return try alloc.dupe(u8, std.mem.span(chosen));
        }

        fn folderDialog(self: *Self, alloc: std.mem.Allocator, parent: [*c]c.GtkWindow, title: []const u8) !?[]u8 {
            _ = self;
            const title_z = try dupeZ(alloc, if (title.len > 0) title else "选择文件夹");
            defer alloc.free(title_z);
            if (comptime gtk_compat.isGtk4()) {
                return gtk_compat.fileDialogSelectFolderSync(parent, title_z.ptr, alloc);
            }
            const native = c.gtk_file_chooser_native_new(title_z.ptr, parent, c.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER, "选择", "取消") orelse
                return error.DialogNotAvailable;
            defer c.g_object_unref(@ptrCast(native));
            const chooser: *c.GtkFileChooser = @ptrCast(native);
            if (gtk_compat.nativeDialogRun(native) != c.GTK_RESPONSE_ACCEPT) return null;
            const chosen = c.gtk_file_chooser_get_filename(chooser);
            if (chosen == null) return null;
            defer c.g_free(@ptrCast(chosen));
            return try alloc.dupe(u8, std.mem.span(chosen));
        }

        fn filesDialog(self: *Self, alloc: std.mem.Allocator, parent: [*c]c.GtkWindow, opts: ipc.FileDialogOptions) !?[][]u8 {
            _ = self;
            if (comptime gtk_compat.isGtk4()) {
                const title_z = try dupeZ(alloc, if (opts.title.len > 0) opts.title else "打开文件");
                defer alloc.free(title_z);
                const filters = try toFilterSpecs(alloc, opts.filters);
                defer alloc.free(filters);
                return gtk_compat.fileDialogOpenMultipleSync(parent, title_z.ptr, filters, alloc);
            }
            const native = (try nativeChooser(alloc, parent, opts, .open)) orelse return error.DialogNotAvailable;
            defer c.g_object_unref(@ptrCast(native));
            const chooser: *c.GtkFileChooser = @ptrCast(native);
            c.gtk_file_chooser_set_select_multiple(chooser, 1);
            if (gtk_compat.nativeDialogRun(native) != c.GTK_RESPONSE_ACCEPT) return null;

            const list = c.gtk_file_chooser_get_filenames(chooser);
            if (list == null) return null;
            defer {
                var node: ?*c.GSList = list;
                while (node) |n| : (node = n.*.next) {
                    if (n.*.data) |data| c.g_free(data);
                }
                c.g_slist_free(list);
            }
            var count: usize = 0;
            {
                var node: ?*c.GSList = list;
                while (node) |n| : (node = n.*.next) count += 1;
            }
            if (count == 0) return null;
            const paths = try alloc.alloc([]u8, count);
            errdefer alloc.free(paths);
            var i: usize = 0;
            var node: ?*c.GSList = list;
            errdefer for (paths[0..i]) |p| alloc.free(p);
            while (node) |n| : (node = n.*.next) {
                const raw: [*c]const u8 = @ptrCast(n.*.data orelse continue);
                paths[i] = try alloc.dupe(u8, std.mem.span(raw));
                i += 1;
            }
            return paths[0..i];
        }

        /// 共享的 native chooser 构造（含 filter / 默认文件名）。
        fn nativeChooser(
            alloc: std.mem.Allocator,
            parent: [*c]c.GtkWindow,
            opts: ipc.FileDialogOptions,
            mode: FileMode,
        ) !?*c.GtkFileChooserNative {
            const title_z = try dupeZ(alloc, if (opts.title.len > 0) opts.title else (if (mode == .save) "保存文件" else "打开文件"));
            defer alloc.free(title_z);
            const action: c.GtkFileChooserAction = if (mode == .save) c.GTK_FILE_CHOOSER_ACTION_SAVE else c.GTK_FILE_CHOOSER_ACTION_OPEN;
            const native = c.gtk_file_chooser_native_new(title_z.ptr, parent, action, if (mode == .save) "保存" else "打开", "取消");
            if (native == null) return error.DialogNotAvailable;
            const chooser: *c.GtkFileChooser = @ptrCast(native);

            if (opts.default_name.len > 0) {
                const name_z = try dupeZ(alloc, opts.default_name);
                defer alloc.free(name_z);
                c.gtk_file_chooser_set_current_name(chooser, name_z.ptr);
            }
            for (opts.filters) |f| {
                const filter = c.gtk_file_filter_new();
                if (filter == null) continue;
                defer c.g_object_unref(@ptrCast(filter));
                if (f.name.len > 0) {
                    const fname_z = try dupeZ(alloc, f.name);
                    defer alloc.free(fname_z);
                    c.gtk_file_filter_set_name(filter, fname_z.ptr);
                }
                var patterns = std.mem.splitScalar(u8, f.pattern, ';');
                while (patterns.next()) |pattern| {
                    const trimmed = std.mem.trim(u8, pattern, " \t");
                    if (trimmed.len == 0) continue;
                    const pat_z = try dupeZ(alloc, trimmed);
                    defer alloc.free(pat_z);
                    c.gtk_file_filter_add_pattern(filter, pat_z.ptr);
                }
                c.gtk_file_chooser_add_filter(chooser, filter);
            }
            return native;
        }

        fn colorDialog(self: *Self, parent: [*c]c.GtkWindow, opts: ipc.ColorDialogOptions) ?u32 {
            _ = self;
            const title_z = dupeZ(std.heap.c_allocator, opts.title) catch return null;
            defer std.heap.c_allocator.free(title_z);
            const dlg = c.gtk_color_chooser_dialog_new(title_z.ptr, parent);
            if (dlg == null) return null;
            defer gtk_compat.destroyDialog(@ptrCast(@alignCast(dlg)));
            c.gtk_color_chooser_set_use_alpha(@ptrCast(dlg), 0);
            var rgba = c.GdkRGBA{
                .red = @as(f32, @floatFromInt(opts.default_rgb >> 16 & 0xFF)) / 255.0,
                .green = @as(f32, @floatFromInt(opts.default_rgb >> 8 & 0xFF)) / 255.0,
                .blue = @as(f32, @floatFromInt(opts.default_rgb & 0xFF)) / 255.0,
                .alpha = 1.0,
            };
            c.gtk_color_chooser_set_rgba(@ptrCast(dlg), &rgba);
            if (gtk_compat.runDialog(@ptrCast(@alignCast(dlg))) != c.GTK_RESPONSE_OK) return null;
            c.gtk_color_chooser_get_rgba(@ptrCast(dlg), &rgba);
            const r: u32 = @intFromFloat(@round(std.math.clamp(rgba.red, 0, 1) * 255));
            const g: u32 = @intFromFloat(@round(std.math.clamp(rgba.green, 0, 1) * 255));
            const b: u32 = @intFromFloat(@round(std.math.clamp(rgba.blue, 0, 1) * 255));
            return (r << 16) | (g << 8) | b;
        }

        fn fontDialog(self: *Self, alloc: std.mem.Allocator, parent: [*c]c.GtkWindow, opts: ipc.FontDialogOptions) !?ipc.FontChoice {
            _ = self;
            const title_z = try dupeZ(alloc, opts.title);
            defer alloc.free(title_z);
            const dlg = c.gtk_font_chooser_dialog_new(title_z.ptr, parent);
            if (dlg == null) return null;
            defer gtk_compat.destroyDialog(@ptrCast(@alignCast(dlg)));
            if (gtk_compat.runDialog(@ptrCast(@alignCast(dlg))) != c.GTK_RESPONSE_OK) return null;

            const font = c.gtk_font_chooser_get_font(@ptrCast(dlg));
            if (font == null) return null;
            defer c.g_free(@ptrCast(font));
            const desc = c.pango_font_description_from_string(font);
            if (desc == null) return null;
            defer c.pango_font_description_free(desc);
            const family_ptr = c.pango_font_description_get_family(desc);
            const family: []const u8 = if (family_ptr != null) std.mem.span(family_ptr) else "";
            const size_pango = c.pango_font_description_get_size(desc);
            const points: i32 = @intCast(@divTrunc(size_pango, c.PANGO_SCALE));
            return ipc.FontChoice{
                .name = try alloc.dupe(u8, family),
                .size_points = points,
                .bold = c.pango_font_description_get_weight(desc) >= c.PANGO_WEIGHT_BOLD,
                .italic = c.pango_font_description_get_style(desc) != c.PANGO_STYLE_NORMAL,
                .underline = false,
                .strikeout = false,
                .color_rgb = opts.color_rgb,
            };
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
            defer gtk_compat.destroyDialog(@ptrCast(@alignCast(dlg)));
            const chooser: *c.GtkFileChooser = @ptrCast(dlg);
            const name_z = try dupeZ(self.allocator, suggested);
            defer self.allocator.free(name_z);
            c.gtk_file_chooser_set_current_name(chooser, name_z.ptr);
            c.gtk_file_chooser_set_do_overwrite_confirmation(chooser, 1);
            if (gtk_compat.runDialog(@ptrCast(@alignCast(dlg))) != c.GTK_RESPONSE_ACCEPT) return null;
            const chosen = c.gtk_file_chooser_get_filename(chooser);
            if (chosen == null) return null;
            defer c.g_free(@ptrCast(chosen));
            return try self.allocator.dupe(u8, std.mem.span(chosen));
        }

        fn onDownloadStarted(_: ?*c.WebKitWebContext, download: ?*c.WebKitDownload, user_data: c.gpointer) callconv(.c) void {
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

        fn onDownloadReceived(_: ?*c.WebKitDownload, _: c.guint64, user_data: c.gpointer) callconv(.c) void {
            const d: *Download = @ptrCast(@alignCast(user_data orelse return));
            const received = c.webkit_download_get_received_data_length(d.dl);
            // 节流：WebKit 每个数据块都发信号，只按 32KB 步进上报
            if (received < d.last_progress + 32 * 1024) return;
            d.last_progress = received;
            d.backend.emitDownloadProgress(d, "webview.download_progress", 0);
        }

        fn onDownloadFinished(_: ?*c.WebKitDownload, user_data: c.gpointer) callconv(.c) void {
            const d: *Download = @ptrCast(@alignCast(user_data orelse return));
            const received = c.webkit_download_get_received_data_length(d.dl);
            d.backend.disconnectDownloadSignals(d);
            log.print("[download] #{d} completed ({d}/{d} bytes)", .{ d.id, received, d.total });
            d.backend.emitDownloadProgress(d, "webview.download_completed", received);
            d.backend.removeDownload(d);
        }

        fn onDownloadFailed(_: ?*c.WebKitDownload, err: [*c]c.GError, user_data: c.gpointer) callconv(.c) void {
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
        fn windowForView(self: *Self, view: ?*c.WebKitWebView) ?*WinState {
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
        fn evalResultJson(self: *Self, value: ?*c.JSCValue) ?[]u8 {
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
            const view: ?*c.WebKitWebView = @ptrCast(source);
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
        fn syncEval(self: *Self, view: ?*c.WebKitWebView, alloc: std.mem.Allocator, script: []const u8) ![]u8 {
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
                .devtools => |op| {
                    if (!config.webview.settings.devtools) return error.DevToolsDisabled;
                    const settings = c.webkit_web_view_get_settings(view);
                    if (settings == null) return error.WebViewCallFailed;
                    c.webkit_settings_set_enable_developer_extras(settings, 1);
                    const inspector = c.webkit_web_view_get_inspector(view);
                    if (inspector == null) return error.WebViewCallFailed;
                    // v0.3.14 G10：open/close/state（WebKitGTK inspector 全支持）
                    switch (op) {
                        .open => {
                            c.webkit_web_inspector_show(inspector);
                            return try alloc.dupe(u8, "{}");
                        },
                        .close => {
                            c.webkit_web_inspector_close(inspector);
                            return try alloc.dupe(u8, "{}");
                        },
                        .state => {
                            const is_open = c.webkit_web_inspector_is_attached(inspector);
                            return try std.fmt.allocPrint(alloc, "{{\"open\":{s}}}", .{boolStr(is_open != 0)});
                        },
                    }
                },
                // v0.3.14 G9：加载 HTML 字符串（webkit_web_view_load_html；
                // base_uri 用应用 app_url——相对资源仍按应用 origin 解析）
                .load_html => |html| {
                    const z = try dupeZ(self.allocator, html);
                    defer self.allocator.free(z);
                    c.webkit_web_view_load_html(@ptrCast(view), z.ptr, w.app_url.ptr);
                    return try alloc.dupe(u8, "{}");
                },
                // v0.3.15 G12：printToPdf——WebKitGTK 无 PDF 导出 API（仅打印
                // 对话框；与上游 wry 同限制）→ 明确错误文档化
                .print_to_pdf => return error.PdfNotSupported,
                // v0.3.15：Settings3/6 探针——WebKitGTK 无 AreBrowserAcceleratorKeys
                // / IsSwipeNavigationEnabled 对等（手势经 WebKitSettings 创建期设置）
                // → null 文档化
                .settings_probe => return try alloc.dupe(u8, "{\"accelerators\":null,\"swipe\":null}"),
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
                // v0.2.5：print 实装——WebKitPrintOperation 原生打印对话框
                //（对齐 Windows 的原生打印 UI；模态，真实桌面交互，冒烟不覆盖）。
                // system（系统打印首选项）在 Linux 无标准 API → NotSupported。
                .print => |kind| {
                    if (kind == .system) return error.NotSupported;
                    const op = c.webkit_print_operation_new(view);
                    if (op == null) return error.NotSupported;
                    defer c.g_object_unref(@ptrCast(op));
                    _ = c.webkit_print_operation_run_dialog(op, null);
                },
            }
            return try alloc.dupe(u8, "null");
        }

        // ------------------------------------------------------------------
        // cookies / clear_storage（v0.2.1）
        // ------------------------------------------------------------------

        fn cookieManagerFor(w: *WinState) ?*c.WebKitCookieManager {
            if (comptime gtk_compat.isGtk4()) {
                const view: ?*c.WebKitWebView = @ptrCast(@alignCast(w.view));
                if (view == null) return null;
                const session = c.webkit_web_view_get_network_session(view);
                if (session == null) return null;
                return c.webkit_network_session_get_cookie_manager(session);
            }
            const ctx = c.webkit_web_view_get_context(w.view);
            if (ctx == null) return null;
            const session_any = gtk_compat.cookieManagerFromSessionOrContext(null, ctx);
            return @ptrCast(@alignCast(session_any));
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
                    if (comptime gtk_compat.isGtk4()) {
                        // 6.0 的 CookieManager 无 delete_cookies_for_domain →
                        // 文档化 NotAvailable（按域清理待 session 级 API 补齐）
                        alloc.free(host_z);
                        return error.WebViewCallFailed;
                    }
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

        fn runCookieWrite(self: *Self, mgr: ?*c.WebKitCookieManager, cookie: *c.SoupCookie, alloc: std.mem.Allocator) ![]u8 {
            var task = WaitTask{ .backend = self };
            task.loop = c.g_main_loop_new(null, 0) orelse return error.WebViewCallFailed;
            defer c.g_main_loop_unref(task.loop);
            c.webkit_cookie_manager_add_cookie(mgr, cookie, null, cookieWriteDone, &task);
            c.g_main_loop_run(task.loop.?);
            if (task.failed) return error.WebViewCallFailed;
            return try alloc.dupe(u8, "null");
        }

        fn runCookieDelete(self: *Self, mgr: ?*c.WebKitCookieManager, cookie: *c.SoupCookie, alloc: std.mem.Allocator) ![]u8 {
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
            const mgr: ?*c.WebKitCookieManager = @ptrCast(source);
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
            const mgr: ?*c.WebKitCookieManager = @ptrCast(source);
            var err: [*c]c.GError = null;
            if (c.webkit_cookie_manager_add_cookie_finish(mgr, res, &err) == 0) task.failed = true;
            if (err != null) c.g_error_free(err);
            if (task.loop) |loop| c.g_main_loop_quit(loop);
        }

        fn cookieDeleteDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            const task: *WaitTask = @ptrCast(@alignCast(user_data orelse return));
            const mgr: ?*c.WebKitCookieManager = @ptrCast(source);
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
            var mgr: ?*c.WebKitWebsiteDataManager = null;
            if (comptime gtk_compat.isGtk4()) {
                // 6.0：data manager 在 view 的网络会话上
                const view: ?*c.WebKitWebView = @ptrCast(@alignCast(w.view));
                const session = c.webkit_web_view_get_network_session(view);
                if (session == null) return error.WebViewCallFailed;
                mgr = c.webkit_network_session_get_website_data_manager(session);
            } else {
                const ctx = c.webkit_web_view_get_context(w.view);
                if (ctx == null) return error.WebViewCallFailed;
                mgr = c.webkit_web_context_get_website_data_manager(ctx);
            }
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
            const mgr: ?*c.WebKitWebsiteDataManager = @ptrCast(source);
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
            const view: ?*c.WebKitWebView = @ptrCast(source);

            var raw: [*c]u8 = null;
            var size: usize = 0;
            if (comptime gtk_compat.isGtk4()) {
                // 6.0：快照结果为 GdkTexture → 直接编码 PNG bytes（cairo 面不参与）
                var tex_err: [*c]c.GError = null;
                const texture = c.webkit_web_view_get_snapshot_finish(view, res, &tex_err);
                if (tex_err != null or texture == null) {
                    // GError 的 message 在 free 后失效——先打日志/回传，再释放
                    const message = if (tex_err != null) std.mem.span(tex_err.*.message) else "snapshot failed";
                    log.print("[snapshot] failed (gtk4): {s}", .{message});
                    self.emitCdpError(task.win_id, task.rid, message);
                    if (tex_err != null) c.g_error_free(tex_err);
                    return;
                }
                defer c.g_object_unref(@ptrCast(texture));
                const bytes = c.gdk_texture_save_to_png_bytes(texture) orelse {
                    return self.emitCdpError(task.win_id, task.rid, "png encode failed");
                };
                // GBytes 非 GObject
                defer c.g_bytes_unref(bytes);
                var bsize: c.gsize = 0;
                raw = @constCast(@ptrCast(c.g_bytes_get_data(bytes, &bsize)));
                size = @intCast(bsize);
            } else {
                var surf_err: [*c]c.GError = null;
                const surface = c.webkit_web_view_get_snapshot_finish(view, res, &surf_err);
                if (surf_err != null or surface == null) {
                    // 同上：先消费 message 再 free
                    const message = if (surf_err != null) std.mem.span(surf_err.*.message) else "snapshot failed";
                    log.print("[snapshot] failed (gtk3): {s}", .{message});
                    self.emitCdpError(task.win_id, task.rid, message);
                    if (surf_err != null) c.g_error_free(surf_err);
                    return;
                }
                defer c.cairo_surface_destroy(surface);
                const sw = c.cairo_image_surface_get_width(surface);
                const sh = c.cairo_image_surface_get_height(surface);
                log.print("[snapshot] surface {d}x{d}", .{ sw, sh });

                const stream = c.g_memory_output_stream_new_resizable();
                if (stream == null) return self.emitCdpError(task.win_id, task.rid, "snapshot stream failed");
                defer c.g_object_unref(@ptrCast(stream));
                const status = c.cairo_surface_write_to_png_stream(surface, pngWrite, stream);
                if (status != c.CAIRO_STATUS_SUCCESS) return self.emitCdpError(task.win_id, task.rid, "png encode failed");

                raw = @ptrCast(c.g_memory_output_stream_get_data(@ptrCast(stream)));
                size = @intCast(c.g_memory_output_stream_get_size(@ptrCast(stream)));
            }
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
                // v0.2.2：运行时菜单模型 / 系统信息 / 自启动
                .menu => |op| return self.runMenuOp(op, alloc),
                .info => |kind| return .{ .json = try self.collectSystemInfo(kind, alloc, w) },
                // v0.3.16 G19：全局光标位置（gdk_device_get_position 屏幕坐标）
                .cursor_position => {
                    var x: c.gint = 0;
                    var y: c.gint = 0;
                    if (!gtk_compat.pointerRootPos(@ptrCast(@alignCast(w.win)), &x, &y)) {
                        return error.CursorNotAvailable;
                    }
                    return .{ .json = try std.fmt.allocPrint(alloc, "{{\"x\":{d},\"y\":{d}}}", .{ x, y }) };
                },
                .autostart => |op| return .{ .state = try self.runAutostartOp(op, alloc) },
                // v0.2.3：存储 / fs / ACL / SQL / http / ws
                .store => |op| return self.runStoreOp(op, alloc),
                .fs => |op| return self.runFsOp(op, alloc),
                .acl => |op| return self.runAclOp(op, alloc),
                .sql => |op| return self.runSqlOp(op, alloc),
                .hotkey => |op| return self.runHotkeyOp(op, alloc),
                .http => |op| return self.runHttpOp(op, alloc),
                .ws => |op| return self.runWsOp(op, alloc),
                // v0.2.7：shell（opener）/ services / updater；v0.3.0：子进程
                .process => |op| return self.runProcOp(op, alloc),
                .shell => |target| {
                    try openShellTarget(target);
                    return .{ .ok = true };
                },
                .services => |op| return self.runServicesOp(op, alloc),
                .updater => |op| return self.runUpdaterOp(op, alloc),
                // v0.4.0 H10：Unity LauncherEntry 数值徽标（其余 taskbar op 仍 NotSupported）
                .taskbar => |op| return self.runTaskbarOpLinux(op, alloc),
                // 托盘运行时 op/process/appearance/... 属后续版本；NotSupported
                // 与 Windows 的降级语义同构（platform/interface.zig 契约不受影响）
                else => return error.NotSupported,
            }
        }

        /// v0.4.0 H10：badge_count → Unity LauncherEntry Update 信号。
        /// 连接来自 init 时的缓存（见 initApplication）；无会话总线（CI/Xvfb）→
        /// NotSupported（文档化降级，与剪贴板环境问题同文化）。
        fn runTaskbarOpLinux(self: *Self, op: shared_taskbar.Request, alloc: std.mem.Allocator) !system_api.Result {
            switch (op) {
                .badge_count => |n| {
                    const conn = self.unity_bus orelse {
                        log.print("[taskbar] unity badge_count({d}): no session bus (acquired at init) -> NotSupported", .{n});
                        return error.NotSupported;
                    };
                    const id = try unity_badge.desktopId(alloc, config.app_id);
                    defer alloc.free(id);
                    unity_badge.emitBadgeCount(conn, alloc, id, n) catch |err| {
                        log.print("[taskbar] unity badge_count({d}) emit failed: {s}", .{ n, @errorName(err) });
                        return error.NotSupported;
                    };
                    log.print("[taskbar] unity badge_count={d} (LauncherEntry signal, app={s})", .{ n, config.app_id });
                    return .{ .ok = true };
                },
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

                    var pieces: ?ProxyPieces = null;
                    if (part_name) |pname| {
                        if (self.findPartition(pname)) |existing| {
                            pieces = existing;
                            log.print("[webviews] child #{d} reuse partition '{s}'", .{ id, pname });
                        } else {
                            pieces = try self.createPartitionContext(pname);
                            // 注册失败要释放刚建的 context/session（OOM 路径不留悬挂引用）
                            const name_copy = self.allocator.dupe(u8, pname) catch |dup_err| {
                                c.g_object_unref(@ptrCast(pieces.?.ctx));
                                if (pieces.?.session) |s| c.g_object_unref(@ptrCast(s));
                                return dup_err;
                            };
                            self.partitions.append(self.allocator, .{
                                .name = name_copy,
                                .ctx = pieces.?.ctx,
                                .session = pieces.?.session,
                            }) catch |append_err| {
                                self.allocator.free(name_copy);
                                c.g_object_unref(@ptrCast(pieces.?.ctx));
                                if (pieces.?.session) |s| c.g_object_unref(@ptrCast(s));
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
                    const view_widget: [*c]c.GtkWidget = if (pieces) |pc|
                        @ptrCast(@alignCast(gtk_compat.webViewNew(null, pc.ctx, pc.session)))
                    else
                        @ptrCast(@alignCast(gtk_compat.webViewNew(ucm, null, null)));
                    if (view_widget == null) return error.WebViewCreateFailed;
                    const view: ?*c.WebKitWebView = @ptrCast(view_widget);
                    sink.view = view;
                    const view_ucm: ?*c.WebKitUserContentManager = if (pieces != null)
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
                    // GTK4：GtkWidget 初始是 floating，add_overlay 会 sink 掉；
                    // 若不自留一份引用，remove_overlay 时会直接 finalize，
                    // 随后的 g_object_unref 就是 UAF（实测 remove 时
                    // `g_object_unref: assertion G_IS_OBJECT` + 后续堆破坏）。
                    if (comptime gtk_compat.isGtk4()) {
                        _ = c.g_object_ref_sink(@ptrCast(view_widget));
                    }
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
                            // UCM/信号随 view 释放。GTK4：先摘除 overlay child 再 unref
                            if (comptime gtk_compat.isGtk4()) {
                                if (w.overlay) |ov| c.gtk_overlay_remove_overlay(@ptrCast(@alignCast(ov)), @ptrCast(cv.view));
                                c.g_object_unref(@ptrCast(cv.view));
                            } else {
                                c.gtk_widget_destroy(@ptrCast(cv.view));
                            }
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
                    if (comptime gtk_compat.isGtk4()) {
                        _ = c.gtk_widget_grab_focus(@ptrCast(cv.view)); // 4.x 返回 gboolean
                    } else {
                        c.gtk_widget_grab_focus(@ptrCast(cv.view));
                    }
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
        // 系统信息（v0.2.2）：/etc/os-release + locale/theme 推导 + GDK 显示器
        // JSON 形状与 Windows 同构（shared sysinfo.osToJson / monitorsToJson）
        // ------------------------------------------------------------------

        fn collectSystemInfo(self: *Self, kind: system_api.InfoKind, alloc: std.mem.Allocator, w: ?*WinState) ![]u8 {
            switch (kind) {
                .os => {
                    var info = try self.collectOsInfo(alloc);
                    defer sysinfo_linux.freeOsInfo(alloc, &info);
                    return shared_sysinfo.osToJson(alloc, info);
                },
                .monitors => {
                    const monitors = try self.collectMonitors(alloc);
                    defer alloc.free(monitors);
                    // v0.3.2：标记调用窗口所在显示器
                    if (w) |st| {
                        if (st.win != null) {
                            const display = c.gdk_display_get_default();
                            if (display != null) {
                                const widget: [*c]c.GtkWidget = @ptrCast(st.win);
                                if (gtk_compat.monitorAtSurface(widget)) |mon_any| {
                                    const mon: ?*c.GdkMonitor = @ptrCast(@alignCast(mon_any));
                                    const n = gtk_compat.displayMonitorCount(display);
                                    var idx: c_int = 0;
                                    while (idx < n) : (idx += 1) {
                                        if (idx < monitors.len) monitors[@intCast(idx)].current = (gtk_compat.displayMonitorAtIdx(display, idx) == @as(?*anyopaque, @ptrCast(mon)));
                                    }
                                }
                            }
                        }
                    }
                    return shared_sysinfo.monitorsToJson(alloc, monitors);
                },
                .all => {
                    var info = try self.collectOsInfo(alloc);
                    defer sysinfo_linux.freeOsInfo(alloc, &info);
                    const os_json = try shared_sysinfo.osToJson(alloc, info);
                    defer alloc.free(os_json);
                    const monitors = try self.collectMonitors(alloc);
                    defer alloc.free(monitors);
                    const mons_json = try shared_sysinfo.monitorsToJson(alloc, monitors);
                    defer alloc.free(mons_json);
                    return std.fmt.allocPrint(alloc, "{{\"os\":{s},\"monitors\":{s}}}", .{ os_json, mons_json });
                },
                // v0.4.0 H11：GPU 适配器（/sys/class/drm/card* 解析；无 DRM → 空数组）
                .gpu => {
                    const gpus = try self.collectGpus(alloc);
                    defer sysinfo_linux.freeGpus(alloc, gpus);
                    return shared_sysinfo.gpuToJson(alloc, gpus);
                },
            }
        }

        /// v0.4.0 H11：GPU 适配器采集——card 索引 0..15 逐一 stat
        /// /sys/class/drm/card<i>/device/{vendor,device,uevent}（不做目录枚举，
        /// 规避 Io walker 的 readdir 限制）。WSLg 无 drm 卡 → 空数组。
        fn collectGpus(self: *Self, alloc: std.mem.Allocator) ![]shared_sysinfo.GpuInfo {
            _ = self;
            var out: std.ArrayListUnmanaged(shared_sysinfo.GpuInfo) = .empty;
            errdefer sysinfo_linux.freeGpus(alloc, out.items);
            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                var vendor_buf: [96]u8 = undefined;
                const vendor_path = std.fmt.bufPrint(&vendor_buf, "/sys/class/drm/card{d}/device/vendor", .{i}) catch break;
                const vendor_text = std.Io.Dir.cwd().readFileAlloc(sharedIo(), vendor_path, alloc, .limited(64)) catch continue;
                defer alloc.free(vendor_text);
                const vendor_id = sysinfo_linux.parseHexId(vendor_text) orelse continue;
                var dev_buf: [96]u8 = undefined;
                const device_path = std.fmt.bufPrint(&dev_buf, "/sys/class/drm/card{d}/device/device", .{i}) catch break;
                var device_text: ?[]u8 = null;
                defer if (device_text) |t| alloc.free(t);
                device_text = std.Io.Dir.cwd().readFileAlloc(sharedIo(), device_path, alloc, .limited(64)) catch null;
                const device_id = if (device_text) |t| (sysinfo_linux.parseHexId(t) orelse 0) else 0;
                var ue_buf: [96]u8 = undefined;
                const uevent_path = std.fmt.bufPrint(&ue_buf, "/sys/class/drm/card{d}/device/uevent", .{i}) catch break;
                var uevent_text: ?[]u8 = null;
                defer if (uevent_text) |t| alloc.free(t);
                uevent_text = std.Io.Dir.cwd().readFileAlloc(sharedIo(), uevent_path, alloc, .limited(4096)) catch null;
                const driver = if (uevent_text) |t| sysinfo_linux.driverFromUevent(t) else null;
                const card_name = try std.fmt.allocPrint(alloc, "card{d}", .{i});
                const name = try sysinfo_linux.gpuName(alloc, card_name, vendor_id, device_id);
                errdefer alloc.free(name);
                const vendor_name = shared_sysinfo.vendorFromPciId(vendor_id);
                const vendor = if (std.mem.eql(u8, vendor_name, "unknown"))
                    try std.fmt.allocPrint(alloc, "0x{x:0>4}", .{vendor_id})
                else
                    try alloc.dupe(u8, vendor_name);
                errdefer alloc.free(vendor);
                const driver_str = if (driver) |d| (if (d.len > 0) try alloc.dupe(u8, d) else try alloc.dupe(u8, "")) else try alloc.dupe(u8, "");
                errdefer if (driver_str.len > 0) alloc.free(driver_str);
                try out.append(alloc, .{
                    .name = name,
                    .vendor = vendor,
                    .vram_mb = 0,
                    .driver = driver_str,
                });
            }
            return out.toOwnedSlice(alloc);
        }

        fn collectOsInfo(self: *Self, alloc: std.mem.Allocator) !shared_sysinfo.OsInfo {
            _ = self;
            const text = std.Io.Dir.cwd().readFileAlloc(sharedIo(), "/etc/os-release", alloc, .limited(64 * 1024)) catch null;
            defer if (text) |t| alloc.free(t);
            var release = try sysinfo_linux.parseOsRelease(alloc, text orelse "");
            defer sysinfo_linux.freeOsRelease(alloc, &release);
            const lc_all: ?[]const u8 = if (std.c.getenv("LC_ALL")) |v| std.mem.span(v) else null;
            const lang: ?[]const u8 = if (std.c.getenv("LANG")) |v| std.mem.span(v) else null;
            const locale = try sysinfo_linux.localeFromEnv(alloc, lc_all, lang);
            defer alloc.free(locale);
            const dark = blk: {
                const settings = c.gtk_settings_get_default() orelse break :blk false;
                var name_ptr: ?[*:0]const u8 = null;
                c.g_object_get(@ptrCast(settings), "gtk-theme-name", &name_ptr, @as(?*anyopaque, null));
                defer if (name_ptr) |p| c.g_free(@constCast(p));
                break :blk sysinfo_linux.isDarkThemeName(if (name_ptr) |p| std.mem.span(p) else null);
            };
            return sysinfo_linux.osInfo(alloc, release, locale, dark);
        }

        fn collectMonitors(self: *Self, alloc: std.mem.Allocator) ![]shared_sysinfo.Monitor {
            _ = self;
            const display = c.gdk_display_get_default() orelse return try alloc.alloc(shared_sysinfo.Monitor, 0);
            const n: usize = @intCast(gtk_compat.displayMonitorCount(display));
            const out = try alloc.alloc(shared_sysinfo.Monitor, n);
            errdefer alloc.free(out);
            const primary: ?*c.GdkMonitor = @ptrCast(@alignCast(gtk_compat.displayPrimaryMonitor(display)));
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const mon: ?*c.GdkMonitor = @ptrCast(@alignCast(gtk_compat.displayMonitorAtIdx(display, @intCast(i))));
                var geom: c.GdkRectangle = std.mem.zeroes(c.GdkRectangle);
                var work: c.GdkRectangle = std.mem.zeroes(c.GdkRectangle);
                // v0.4.0 L2：分数缩放——GTK4（4.14+）gdk_monitor_get_scale 返回小数；
                // GTK3 回退整数 scale_factor（无分数 API，文档化）。comptime 分支
                // 保证另一变体的符号不被分析（gtk3 构建无 get_scale，反之亦然）。
                var scale_f: f64 = 1.0;
                if (mon != null) {
                    c.gdk_monitor_get_geometry(mon, &geom);
                    gtk_compat.monitorWorkarea(mon, &work);
                    if (comptime gtk_compat.isGtk4()) {
                        scale_f = c.gdk_monitor_get_scale(mon);
                    } else {
                        scale_f = @floatFromInt(@max(1, c.gdk_monitor_get_scale_factor(mon)));
                    }
                }
                const dpi: u32 = @intFromFloat(@round(@max(1.0, scale_f) * 96.0));
                out[i] = .{
                    .index = @intCast(i),
                    .primary = mon != null and mon == primary,
                    .x = geom.x,
                    .y = geom.y,
                    .width = @intCast(@max(0, geom.width)),
                    .height = @intCast(@max(0, geom.height)),
                    .work_x = work.x,
                    .work_y = work.y,
                    .work_width = @intCast(@max(0, work.width)),
                    .work_height = @intCast(@max(0, work.height)),
                    .dpi = dpi,
                    .scale = scale_f,
                };
            }
            return out;
        }

        // ------------------------------------------------------------------
        // 自启动（v0.2.2）：~/.config/autostart/<app_id>.desktop
        // enable = 写条目（Exec=/proc/self/exe [+ args]）；disable = 删除文件
        // ------------------------------------------------------------------

        fn runAutostartOp(self: *Self, op: system_api.AutostartOp, alloc: std.mem.Allocator) !autostart_mod.State {
            const exe = deep_link.exePath(self.allocator) catch return error.AutostartNotAvailable;
            defer self.allocator.free(exe);
            const dir = deep_link.autostartDir(self.allocator) catch return error.AutostartNotAvailable;
            defer self.allocator.free(dir);
            const name = desktop_entry.entryFileName(self.allocator, config.app_id) catch return error.AutostartNotAvailable;
            defer self.allocator.free(name);
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, name }) catch return error.OutOfMemory;
            defer self.allocator.free(path);

            switch (op) {
                .query => {
                    const text = self.readFileSmall(path) catch null;
                    defer if (text) |t| self.allocator.free(t);
                    return self.autostartStateCopied(alloc, text, exe);
                },
                .enable => |args| {
                    try self.enableAutostart(dir, path, exe, args);
                    const text = self.readFileSmall(path) catch null;
                    defer if (text) |t| self.allocator.free(t);
                    return self.autostartStateCopied(alloc, text, exe);
                },
                .disable => {
                    std.Io.Dir.cwd().deleteFile(sharedIo(), path) catch {};
                    log.print("[autostart] disabled (removed {s})", .{path});
                    return .{ .enabled = false, .command = null };
                },
                .toggle => {
                    const text = self.readFileSmall(path) catch null;
                    defer if (text) |t| self.allocator.free(t);
                    const state = desktop_entry.autostartState(alloc, text, exe);
                    if (state.enabled) {
                        std.Io.Dir.cwd().deleteFile(sharedIo(), path) catch {};
                        log.print("[autostart] toggled off", .{});
                        return .{ .enabled = false, .command = null };
                    }
                    try self.enableAutostart(dir, path, exe, null);
                    const after = self.readFileSmall(path) catch null;
                    defer if (after) |t| self.allocator.free(t);
                    return self.autostartStateCopied(alloc, after, exe);
                },
            }
        }

        /// State.command 指向 text（self.allocator、本调用作用域内存），
        /// 结果要跨回 IPC 编码 → 拷到结果分配器（per-message arena）。
        fn autostartStateCopied(_: *Self, alloc: std.mem.Allocator, text: ?[]const u8, exe: []const u8) !autostart_mod.State {
            const state = desktop_entry.autostartState(alloc, text, exe);
            if (state.command) |cmd| {
                return .{ .enabled = state.enabled, .command = try alloc.dupe(u8, cmd) };
            }
            return .{ .enabled = false, .command = null };
        }

        fn enableAutostart(self: *Self, dir: []const u8, path: []const u8, exe: []const u8, args: ?[]const u8) !void {
            makeDirPath(self.allocator, dir);
            const exec = try desktop_entry.formatExec(self.allocator, exe, args);
            defer self.allocator.free(exec);
            const text = try desktop_entry.content(self.allocator, .{
                .name = config.title,
                .exec = exec,
                .icon = trayIconName(config.icon),
                .comment = config.title,
                .wmclass = config.app_id,
                .autostart = true,
            });
            defer self.allocator.free(text);
            try self.writeFileAtomic(path, text);
            log.print("[autostart] enabled: {s}", .{path});
        }


        // ------------------------------------------------------------------
        // 存储 / 受限 fs / 运行时授权（v0.2.3，对齐 Windows v0.1.16–v0.1.21）
        // ------------------------------------------------------------------

        /// 应用数据根（storage_root）：与 window_state 同根
        /// <XDG_DATA_HOME|~/.local/share>/<app_id>。run() 早期调用一次。
        fn initStorage(self: *Self) void {
            // v0.4.2 H3：store_encrypted → libsecret dlopen（缺失降级明文，日志）
            if (config.store_encrypted) {
                if (libsecret.open()) |lib| {
                    self.secret = lib;
                    log.print("[store] libsecret keyring enabled (encrypted store)", .{});
                } else {
                    log.print("[store] store_encrypted=true but libsecret unavailable -> plaintext fallback", .{});
                }
            }
            if (self.storage_root != null) return;
            const root = self.appDataRoot() orelse {
                log.print("[store] app data root unavailable — store/acl/fs(appData) disabled", .{});
                return;
            };
            makeDirPath(self.allocator, root);
            self.storage_root = root;

            var st = store_mod.Store.init(self.allocator);
            {
                const store_path = std.fmt.allocPrint(self.allocator, "{s}/store.json", .{root}) catch null;
                if (store_path) |sp| {
                    defer self.allocator.free(sp);
                    if (std.Io.Dir.cwd().readFileAlloc(sharedIo(), sp, self.allocator, .limited(1024 * 1024))) |bytes| {
                        defer self.allocator.free(bytes);
                        st.fromJson(bytes) catch |err| {
                            log.print("[store] parse failed: {s}（从空表开始）", .{@errorName(err)});
                        };
                    } else |_| {}
                }
            }
            self.store = st;
            log.print("[store] ready ({d} keys) {s}/store.json", .{ st.count(), root });

            self.loadAclGrants();
        }

        fn persistStore(self: *Self) void {
            const root = self.storage_root orelse return;
            const st = if (self.store) |*v| v else return;
            const json = st.toJson(self.allocator) catch return;
            defer self.allocator.free(json);
            const path = std.fmt.allocPrint(self.allocator, "{s}/store.json", .{root}) catch return;
            defer self.allocator.free(path);
            self.writeFileAtomic(path, json) catch |err| {
                log.print("[store] persist failed: {s}", .{@errorName(err)});
            };
        }

        fn runStoreOp(self: *Self, op: system_api.StoreOp, alloc: std.mem.Allocator) !system_api.Result {
            const st = if (self.store) |*v| v else return error.StoreNotAvailable;
            switch (op) {
                .get => |key| {
                    const v = st.get(key) orelse return .{ .json = try alloc.dupe(u8, "null") };
                    // v0.4.2 H3：`secret:` 标记 → 值在密钥环（libsecret lookup）
                    if (std.mem.startsWith(u8, v, "secret:")) {
                        const lib = self.secret orelse return error.KeyringUnavailable;
                        const got = libsecret.lookupValue(&lib, alloc, key) orelse return error.KeyringUnavailable;
                        defer alloc.free(got);
                        return .{ .json = try std.json.Stringify.valueAlloc(alloc, got, .{}) };
                    }
                    return .{ .json = try std.json.Stringify.valueAlloc(alloc, v, .{}) };
                },
                .set => |kv| {
                    // v0.4.2 H3：加密模式 + libsecret → 值进密钥环，store.json 落标记
                    if (self.secret) |*lib| {
                        libsecret.storeValue(lib, alloc, config.app_id, kv.key, kv.value) catch |err| {
                            log.print("[store] keyring store failed: {s} -> plaintext fallback", .{@errorName(err)});
                            try st.set(kv.key, kv.value);
                            self.persistStore();
                            return .{ .ok = true };
                        };
                        try st.set(kv.key, "secret:");
                        self.persistStore();
                        log.print("[store] set {s} (keyring, {d} keys)", .{ kv.key, st.count() });
                        return .{ .ok = true };
                    }
                    try st.set(kv.key, kv.value);
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

        /// v0.1.19 对齐：解析 scope 根目录（绝对路径）。
        fn scopeRoot(self: *Self, scope: fs_api_mod.Scope, alloc: std.mem.Allocator) ?[]u8 {
            switch (scope) {
                .app_data => {
                    const base = self.storage_root orelse return null;
                    return alloc.dupe(u8, base) catch null;
                },
                .app_cache => return self.cacheRoot(alloc),
                .app_config => return self.configRoot(alloc),
                .temp => return alloc.dupe(u8, "/tmp") catch null,
                .exe => {
                    const exe = deep_link.exePath(alloc) catch return null;
                    defer alloc.free(exe);
                    const dir = std.fs.path.dirname(exe) orelse return null;
                    return alloc.dupe(u8, dir) catch null;
                },
                else => {
                    const home_z = std.c.getenv("HOME") orelse return null;
                    const home = std.mem.span(home_z);
                    if (home.len == 0) return null;
                    const sub = fs_api_mod.userSubdir(scope) orelse return null;
                    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ home, sub }) catch null;
                },
            }
        }

        fn cacheRoot(self: *Self, alloc: std.mem.Allocator) ?[]u8 {
            _ = self;
            // v0.4.0 H6：cache_dir 覆盖
            if (config.cache_dir) |d| return alloc.dupe(u8, d) catch null;
            if (std.c.getenv("XDG_CACHE_HOME")) |x| {
                const sv = std.mem.span(x);
                if (sv.len > 0) return alloc.dupe(u8, sv) catch null;
            }
            const home_z = std.c.getenv("HOME") orelse return null;
            const home = std.mem.span(home_z);
            if (home.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}/.cache", .{home}) catch null;
        }

        fn configRoot(self: *Self, alloc: std.mem.Allocator) ?[]u8 {
            _ = self;
            // v0.4.0 H6：config_dir 覆盖
            if (config.config_dir) |d| return alloc.dupe(u8, d) catch null;
            if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
                const sv = std.mem.span(x);
                if (sv.len > 0) return std.fmt.allocPrint(alloc, "{s}/{s}", .{ sv, config.app_id }) catch null;
            }
            const home_z = std.c.getenv("HOME") orelse return null;
            const home = std.mem.span(home_z);
            if (home.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}/.config/{s}", .{ home, config.app_id }) catch null;
        }

        /// fs scope 授权：appData/appConfig/appCache 默认可用；其它根目录需要
        /// capability 声明 "fs:documents/**" 之类（或运行时 grant）。
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

        fn aclAllowed(self: *Self, kind: []const u8, resource: []const u8) bool {
            return security.scopeAllowedWith(config.security, self.acl_grants.items, kind, resource);
        }

        fn loadAclGrants(self: *Self) void {
            if (self.acl_loaded) return;
            self.acl_loaded = true;
            const root = self.storage_root orelse return;
            const path = std.fmt.allocPrint(self.allocator, "{s}/acl.json", .{root}) catch return;
            defer self.allocator.free(path);
            const bytes = std.Io.Dir.cwd().readFileAlloc(sharedIo(), path, self.allocator, .limited(256 * 1024)) catch return;
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
            const path = std.fmt.allocPrint(self.allocator, "{s}/acl.json", .{root}) catch return;
            defer self.allocator.free(path);
            const json = std.json.Stringify.valueAlloc(self.allocator, self.acl_grants.items, .{}) catch return;
            defer self.allocator.free(json);
            self.writeFileAtomic(path, json) catch {
                log.print("[acl] save failed", .{});
            };
        }

        /// acl.list / grant / revoke（grant 落盘，重启后仍生效）。
        fn runAclOp(self: *Self, op: system_api.AclOp, alloc: std.mem.Allocator) !system_api.Result {
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
                        self.allocator.free(self.acl_grants.orderedRemove(i));
                        removed += 1;
                    }
                    if (removed > 0) self.saveAclGrants();
                    log.print("[acl] revoked {s} ({d})", .{ pat, removed });
                    return .{ .ok = removed > 0 };
                },
            }
        }

        // ------------------------------------------------------------------
        // v0.2.7：shell（opener）/ services / updater（对齐 Windows v0.1.14/16/5）
        // ------------------------------------------------------------------

        /// shell op：url/path → xdg-open；reveal → 打开所在目录（Linux 无
        /// explorer「定位并选中」的通用等价物——xdg-open 目录是最大公约数，
        /// 文档化语义差异）。分离拉起，不等待 xdg-open 退出。
        fn openShellTarget(target: shell_mod.Target) !void {
            switch (target) {
                .url => |u| {
                    if (!spawnDetachedLinux(&.{ "xdg-open", u })) return error.ShellExecuteFailed;
                    log.print("[shell] openUrl -> xdg-open ({s})", .{u});
                },
                .path => |p| {
                    if (!spawnDetachedLinux(&.{ "xdg-open", p })) return error.ShellExecuteFailed;
                    log.print("[shell] openPath -> xdg-open ({s})", .{p});
                },
                .reveal => |p| {
                    const dir = std.fs.path.dirname(p) orelse "/";
                    if (!spawnDetachedLinux(&.{ "xdg-open", dir })) return error.ShellExecuteFailed;
                    log.print("[shell] reveal -> xdg-open {s} (dir of {s})", .{ dir, p });
                },
            }
        }

        fn appendServiceJson(
            alloc: std.mem.Allocator,
            out: *std.ArrayListUnmanaged(u8),
            name: []const u8,
            scope: []const u8,
            started: bool,
        ) !void {
            try shared_services.appendToJson(alloc, out, name, scope, started);
        }

        /// 按 Config 声明的顺序注册并启动（对齐 Windows initServices：单个失败
        /// 只记录，不阻断启动）。
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
                var started: usize = 0;
                for (self.services.?.slots.items) |slot| {
                    if (slot.started) started += 1;
                }
                log.print("[services] {d} registered, {d} started", .{ self.services.?.count(), started });
            }
        }

        /// 主题变化监听（v0.2.7）：GTK settings 是全局的 → 变化时广播所有窗口
        /// （Windows 是每窗口 WM_THEMECHANGED，payload 同形 {id, theme}）。
        // GDBus extern（translate-c 把 GDBusConnection 变成 opaque → [*c] 不可用；
        // 全部用 *anyopaque 句柄，libgio 已随 GTK 链接）
        extern fn g_bus_get_sync(bus_type: c_int, err_ptr: ?*anyopaque) ?*anyopaque;
        extern fn g_dbus_connection_signal_subscribe(
            connection: *anyopaque,
            sender: ?[*:0]const u8,
            interface_name: ?[*:0]const u8,
            member: ?[*:0]const u8,
            object_path: ?[*:0]const u8,
            arg0: ?*anyopaque,
            flags: c_uint,
            callback: *const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?*anyopaque, ?*anyopaque) callconv(.c) void,
            user_data: ?*anyopaque,
            user_data_free_func: ?*const fn (?*anyopaque) callconv(.c) void,
        ) c.guint;
        extern fn g_dbus_connection_call_sync(
            connection: *anyopaque,
            bus_name: ?[*:0]const u8,
            object_path: ?[*:0]const u8,
            interface_name: ?[*:0]const u8,
            method_name: ?[*:0]const u8,
            parameters: ?*anyopaque,
            reply_type: ?*anyopaque,
            flags: c_int,
            timeout_msec: c_int,
            cancellable: ?*anyopaque,
            err_ptr: ?*anyopaque,
        ) ?*anyopaque;
        extern fn g_variant_new(fmt: [*:0]const u8, ...) ?*anyopaque;
        extern fn g_variant_unref(v: *anyopaque) void;
        extern fn g_variant_get(v: *anyopaque, fmt: [*:0]const u8, ...) void;
        // GVariant 的可变参数回调签名（PrepareForSleep 参数解析用）
        const GDBusSignalCallback = *const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?*anyopaque, ?*anyopaque) callconv(.c) void;

        // ------------------------------------------------------------------
        // v0.3.2：电源/会话事件（GDBus → org.freedesktop.login1）
        //   PrepareForSleep(true/false) → powerSuspend / powerResume
        //   GetSessionByPID → 会话对象 Lock/Unlock → sessionLock / sessionUnlock
        // 无系统总线（CI/无 logind）→ 订阅失败仅日志，事件面降级不致命。
        // 信号回调在 GDBus worker 线程 → g_idle_add 封送到 UI 线程再投递。
        // ------------------------------------------------------------------

        fn initLogindEvents(self: *Self) void {
            const conn = g_bus_get_sync(2, null) orelse { // 2 = G_BUS_TYPE_SYSTEM
                log.print("[power] no system bus (logind events unavailable)", .{});
                return;
            };
            self.logind.connection = conn;
            // PrepareForSleep(b start)：true=进入睡眠，false=恢复
            self.logind.sleep_sub = g_dbus_connection_signal_subscribe(
                conn,
                "org.freedesktop.login1",
                "org.freedesktop.login1.Manager",
                "PrepareForSleep",
                "/org/freedesktop/login1",
                null,
                0, // G_DBUS_SIGNAL_FLAGS_NONE
                &Self.onPrepareForSleep,
                self,
                null,
            );
            // 会话对象 Lock/Unlock（GetSessionByPID 定位当前会话路径）
            const pid: u32 = @intCast(std.os.linux.getpid());
            if (Self.currentSessionPath(conn, pid)) |path| {
                defer self.allocator.free(path);
                const path_z = dupeZ(self.allocator, path) catch return;
                defer self.allocator.free(path_z);
                self.logind.lock_sub = g_dbus_connection_signal_subscribe(
                    conn,
                    "org.freedesktop.login1",
                    "org.freedesktop.login1.Session",
                    "Lock",
                    path_z.ptr,
                    null,
                    0,
                    &Self.onSessionLocked,
                    self,
                    null,
                );
                self.logind.unlock_sub = g_dbus_connection_signal_subscribe(
                    conn,
                    "org.freedesktop.login1",
                    "org.freedesktop.login1.Session",
                    "Unlock",
                    path_z.ptr,
                    null,
                    0,
                    &Self.onSessionUnlocked,
                    self,
                    null,
                );
                log.print("[power] logind subscribed (sleep + session {s})", .{path});
            } else {
                log.print("[power] logind sleep subscribed (session path unavailable)", .{});
            }
        }

        fn currentSessionPath(conn: *anyopaque, pid: u32) ?[]u8 {
            const params = g_variant_new("(u)", @as(c_uint, pid)) orelse return null;
            const reply = g_dbus_connection_call_sync(
                conn,
                "org.freedesktop.login1",
                "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager",
                "GetSessionByPID",
                params,
                null, // 回复类型按服务端给（"(so)"）
                0, // G_DBUS_CALL_FLAGS_NONE
                2000,
                null,
                null,
            ) orelse return null;
            defer g_variant_unref(@ptrCast(@alignCast(reply)));
            var object_path: ?[*:0]u8 = null;
            var session_id: ?[*:0]u8 = null;
            g_variant_get(@ptrCast(@alignCast(reply)), "(so)", &object_path, &session_id);
            if (session_id != null) c.g_free(@constCast(session_id.?));
            if (object_path == null) return null;
            defer c.g_free(@constCast(object_path.?));
            return self_alloc_dupe(std.mem.span(object_path.?)) catch null;
        }

        /// currentSessionPath 的分配辅助（无 self 上下文的 extern 路径用 c_allocator）
        fn self_alloc_dupe(src: []const u8) ![]u8 {
            return std.heap.c_allocator.dupe(u8, src);
        }

        const LogindTask = struct {
            backend: *Self,
            name: []u8,
        };

        fn marshalLogindName(self: *Self, name: []const u8) void {
            const t = self.allocator.create(LogindTask) catch return;
            const name_copy = self.allocator.dupe(u8, name) catch {
                self.allocator.destroy(t);
                return;
            };
            t.* = .{ .backend = self, .name = name_copy };
            if (c.g_idle_add(logindIdle, t) == 0) {
                self.allocator.free(name_copy);
                self.allocator.destroy(t);
            }
        }

        fn logindIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const task: *LogindTask = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            const self = task.backend;
            defer {
                self.allocator.free(task.name);
                self.allocator.destroy(task);
            }
            for (self.windows.items) |w| {
                self.emitRawToWindow(w.id, task.name, "null");
            }
            log.print("[power] {s}", .{task.name});
            return G_SOURCE_REMOVE;
        }

        fn onPrepareForSleep(_: ?*anyopaque, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, parameters: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            var start: c.gboolean = 0;
            if (parameters != null) {
                g_variant_get(@ptrCast(@alignCast(parameters.?)), "(b)", &start);
            }
            marshalLogindName(self, shared_power.sleepEventName(start != 0));
        }

        fn onSessionLocked(_: ?*anyopaque, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            marshalLogindName(self, "sessionLock");
        }

        fn onSessionUnlocked(_: ?*anyopaque, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            marshalLogindName(self, "sessionUnlock");
        }

        fn watchThemeChanges(self: *Self) void {
            const settings = c.gtk_settings_get_default() orelse return;
            _ = c.g_signal_connect_data(
                @ptrCast(settings),
                "notify::gtk-theme-name",
                @ptrCast(&Self.onThemeChanged),
                self,
                null,
                0,
            );
        }

        fn onThemeChanged(_: [*c]c.GObject, _: c.guint, user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            const dark = currentThemeIsDark();
            const theme: []const u8 = if (dark) "dark" else "light";
            for (self.windows.items) |w| {
                // theme 是字符串字段：payload 直接拼（emitWindowEvent 只支持数值字段）
                const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"theme\":\"{s}\"}}", .{ w.id, theme }) catch continue;
                defer self.allocator.free(payload);
                self.emitRawToWindow(w.id, "windowThemeChanged", payload);
            }
            log.print("[theme] changed -> {s}", .{theme});
        }

        fn currentThemeIsDark() bool {
            const settings = c.gtk_settings_get_default() orelse return false;
            var name_ptr: ?[*:0]const u8 = null;
            c.g_object_get(@ptrCast(settings), "gtk-theme-name", &name_ptr, @as(?*anyopaque, null));
            defer if (name_ptr) |p| c.g_free(@constCast(p));
            return sysinfo_linux.isDarkThemeName(if (name_ptr) |p| std.mem.span(p) else null);
        }

        /// per-window WebView 代理 context（对齐 Windows v0.1.23）：同 proxy 串
        /// 复用；独立数据目录（<应用数据>/webview-windows/<sanitized>）+ 全套
        /// scheme 处理器（资产/协议/下载）。失败返回 null（降级共享 context）。
        /// 代理 context + 网络会话（6.0 的 session 为 null = 无网络面拆分）。
        const ProxyPieces = struct {
            ctx: ?*c.WebKitWebContext,
            session: ?*anyopaque = null,
        };

        fn proxyContext(self: *Self, proxy: []const u8) ?ProxyPieces {
            for (self.proxy_ctxs.items) |pe| {
                if (std.mem.eql(u8, pe.proxy, proxy)) return .{ .ctx = pe.ctx, .session = pe.session };
            }
            const dir = self.proxyDirectory(proxy) catch return null;
            defer self.allocator.free(dir);
            makeDirPath(self.allocator, dir);
            const dir_z = dupeZ(self.allocator, dir) catch return null;
            defer self.allocator.free(dir_z);
            const proxy_z = dupeZ(self.allocator, proxy) catch return null;
            defer self.allocator.free(proxy_z);

            // 6.0：持久化由 session 目录承载（data+cache 同根，WebKit 内部再分目录）；
            // GTK3：manager + context 面
            const session = if (comptime gtk_compat.isGtk4())
                gtk_compat.networkSessionNew(dir_z.ptr, dir_z.ptr)
            else
                null;
            // 与分区表同规则：成功登记后初始引用转交 ProxyEntry；失败路径
            // （ctx 为空 / dupe / append）由 defer 释放，不留悬垂引用。
            var session_owned = true;
            defer if (session_owned) {
                if (session) |s| c.g_object_unref(@ptrCast(s));
            };
            const mgr = if (comptime gtk_compat.isGtk3())
                gtk_compat.websiteDataManagerNew(dir_z.ptr)
            else
                null;
            defer if (mgr) |m| c.g_object_unref(@ptrCast(m));
            const ctx: ?*c.WebKitWebContext = @ptrCast(@alignCast(gtk_compat.webContextNewWithManager(mgr)));
            if (ctx == null) return null;

            // 代理：custom 模式 + 单一代理 URI（等价 Windows per-window env 代理）
            // 6.0：设置面在 session；GTK3 在 context
            const settings = c.webkit_network_proxy_settings_new(proxy_z.ptr, null);
            if (settings != null) {
                defer c.webkit_network_proxy_settings_free(@ptrCast(settings));
                const proxy_target: ?*anyopaque = if (session) |s| s else @ptrCast(@alignCast(ctx));
                gtk_compat.setNetworkProxySettings(proxy_target, @intCast(c.WEBKIT_NETWORK_PROXY_MODE_CUSTOM), settings);
            }
            c.webkit_web_context_register_uri_scheme(ctx, scheme, Self.onSchemeRequest, self, null);
            if (comptime gtk_compat.isGtk4()) {
                _ = c.g_signal_connect_data(session, "download-started", @ptrCast(&Self.onDownloadStarted), self, null, 0);
            } else {
                _ = c.g_signal_connect_data(ctx, "download-started", @ptrCast(&Self.onDownloadStarted), self, null, 0);
            }
            self.registerProtocolSchemes(ctx);

            const copy = self.allocator.dupe(u8, proxy) catch {
                c.g_object_unref(@ptrCast(ctx));
                return null;
            };
            // session 由 ProxyEntry 持引用（view 另持自身 ref）
            self.proxy_ctxs.append(self.allocator, .{ .proxy = copy, .ctx = ctx, .session = session }) catch {
                self.allocator.free(copy);
                c.g_object_unref(@ptrCast(ctx));
                return null;
            };
            session_owned = false;
            log.print("[proxy] webview context ready ({s}, dir={s})", .{ proxy, dir });
            return .{ .ctx = ctx, .session = session };
        }

        /// v0.3.2：无痕窗口 context——`webkit_website_data_manager_new_ephemeral()`
        /// （内存态，Cookie/localStorage/缓存不落盘，context 销毁即消失）。
        /// 不缓存：每个无痕窗口独立 context（互不共享，也和主 context 隔离）。
        fn incognitoContext(self: *Self) ?ProxyPieces {
            const session = if (comptime gtk_compat.isGtk4())
                gtk_compat.networkSessionNewEphemeral()
            else
                null;
            const mgr = if (comptime gtk_compat.isGtk3())
                gtk_compat.websiteDataManagerNewEphemeral()
            else
                null;
            defer if (mgr) |m| c.g_object_unref(@ptrCast(m));
            const ctx: ?*c.WebKitWebContext = @ptrCast(@alignCast(gtk_compat.webContextNewWithManager(mgr)));
            if (ctx == null) {
                if (session) |s| c.g_object_unref(@ptrCast(s));
                return null;
            }
            c.webkit_web_context_register_uri_scheme(ctx, scheme, Self.onSchemeRequest, self, null);
            if (comptime gtk_compat.isGtk4()) {
                _ = c.g_signal_connect_data(session, "download-started", @ptrCast(&Self.onDownloadStarted), self, null, 0);
            } else {
                _ = c.g_signal_connect_data(ctx, "download-started", @ptrCast(&Self.onDownloadStarted), self, null, 0);
            }
            self.registerProtocolSchemes(ctx);
            log.print("[incognito] ephemeral web context ready", .{});
            // 无痕 context 不缓存——初始引用转交调用方，webViewNew 后由调用方
            // 释放（view 自己持一份）。此前在这里 defer unref，返回的 session
            // 已析构：g_object_new 收到 invalid unclassed object（GTK4 冒烟实证）。
            return .{ .ctx = ctx, .session = session };
        }

        /// 代理 → 数据目录名：非 [A-Za-z0-9._-] 全替换 '_'（防注入/超长）。
        fn proxyDirectory(self: *Self, proxy: []const u8) ![]u8 {
            var sanitized = try self.allocator.alloc(u8, proxy.len);
            defer self.allocator.free(sanitized);
            for (proxy, 0..) |ch, i| {
                sanitized[i] = switch (ch) {
                    'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => ch,
                    else => '_',
                };
            }
            const root = self.storage_root orelse return error.StorageNotReady;
            return std.fmt.allocPrint(self.allocator, "{s}/webview-windows/{s}", .{ root, sanitized });
        }

        fn runServicesOp(self: *Self, op: system_api.ServicesOp, alloc: std.mem.Allocator) !system_api.Result {
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

        /// updater.info：状态查询（不触发网络）。restart_required 看 .zilt-old
        /// 是否存在（stageBytes 的改名痕迹，与 Windows 同语义）。
        fn runUpdaterOp(self: *Self, op: system_api.UpdaterOp, alloc: std.mem.Allocator) !system_api.Result {
            switch (op) {
                .info => {
                    const env = self.updater_env orelse {
                        return .{ .json = try alloc.dupe(u8, "{\"configured\":false}") };
                    };
                    const exe_path = try currentExePathLinux(alloc);
                    defer alloc.free(exe_path);
                    const old_path = try std.fmt.allocPrint(alloc, "{s}.zilt-old", .{exe_path});
                    defer alloc.free(old_path);
                    const restart_required = blk: {
                        _ = std.Io.Dir.cwd().statFile(sharedIo(), old_path, .{}) catch break :blk false;
                        break :blk true;
                    };
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
                    const t = std.Thread.spawn(.{ .stack_size = sys.threadStackSize(512 * 1024) }, updaterFlow, .{self}) catch |err| {
                        log.print("[updater] manual check spawn failed: {s}", .{@errorName(err)});
                        return .{ .ok = false };
                    };
                    t.detach();
                    log.print("[updater] manual check started (from JS)", .{});
                    return .{ .ok = true };
                },
                // v0.3.4：跳过版本（skipped.json 持久化；updaterFlow 读取）
                .skip => |version| {
                    const root = self.storage_root orelse return .{ .ok = false };
                    const path = std.fmt.allocPrint(alloc, "{s}/skipped.json", .{root}) catch return .{ .ok = false };
                    defer alloc.free(path);
                    const body = try std.fmt.allocPrint(alloc, "{{\"version\":\"{s}\"}}", .{version});
                    defer alloc.free(body);
                    var wd = std.Io.Dir.cwd();
                    var io_t = std.Io.Threaded.init(alloc, .{});
                    defer io_t.deinit();
                    wd.writeFile(io_t.io(), .{ .sub_path = path, .data = body }) catch {
                        log.print("[updater] skipped.json write failed", .{});
                        return .{ .ok = false };
                    };
                    log.print("[updater] version {s} skipped", .{version});
                    if (self.updater_env) |*env| {
                        env.skipped_version = self.allocator.dupe(u8, version) catch null;
                    }
                    return .{ .ok = true };
                },
            }
        }

        /// 当前 exe 路径（updater 用；0.17 的 executablePathAlloc 走 Io）。
        fn currentExePathLinux(alloc: std.mem.Allocator) ![]u8 {
            return std.process.executablePathAlloc(sharedIo(), alloc);
        }

        /// 构建 updater.Env（config.update + 环境变量覆盖，与 Windows 同语义：
        /// ZILT_UPDATE_URL 覆盖清单 URL、ZILT_UPDATE_PK 覆盖公钥 hex）。
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
                if (self.allocator.dupe(u8, std.mem.span(u))) |owned| {
                    self.updater_url_override = owned;
                    manifest_url = owned;
                } else |_| {}
            }

            const channel: updater.UpdateChannel = if (std.mem.eql(u8, uc.channel, "beta")) .beta else .stable;

            // v0.3.4：skipped.json（用户跳过的版本；缺失 = 无跳过）
            var skipped_version: ?[]const u8 = null;
            if (self.storage_root) |root| {
                const skip_path = std.fmt.allocPrint(self.allocator, "{s}/skipped.json", .{root}) catch null;
                if (skip_path) |sp| {
                    defer self.allocator.free(sp);
                    if (std.Io.Dir.cwd().readFileAlloc(sharedIo(), sp, self.allocator, .limited(4096))) |body| {
                        defer self.allocator.free(body);
                        if (updater.parseSkipped(self.allocator, body)) |sk| {
                            skipped_version = self.allocator.dupe(u8, sk.version) catch null;
                        }
                    } else |_| {}
                }
            }

            return .{
                .channel = channel,
                .manifest_url = manifest_url,
                .public_key = pk,
                .current_version = uc.current_version,
                .exe_path = try currentExePathLinux(self.allocator),
                .github_repo = uc.github_repo,
                .skipped_version = skipped_version,
                .exe_name = uc.exe_name,
                .fetcher = .{ .ctx = @ptrCast(self), .fetchFn = updaterFetchLinux },
            };
        }

        /// 差分更新路径（v0.3.1，对齐 Windows v0.1.5）：校验基线 → 下载/验签补丁 →
        /// 应用 → 复核全量 sha256+签名 → 暂存。任一步失败返回 false（回退全量）。
        fn tryPatchUpdateLinux(self: *Self, p: *const updater.PatchInfo, m: *const updater.Manifest, env: *const updater.Env) bool {
            const alloc = self.allocator;
            log.print("[updater] patch path: {s} -> {s}", .{ p.from, m.version });

            const current = self.fsReadFile(env.exe_path, 512 * 1024 * 1024) catch |e| {
                log.print("[updater] patch: read current exe failed: {s}", .{@errorName(e)});
                return false;
            };
            defer alloc.free(current);
            log.print("[updater] patch: current exe {d} bytes", .{current.len});

            const cur_hex = updater.sha256Hex(alloc, current) catch return false;
            defer alloc.free(cur_hex);
            log.print("[updater] patch: current sha256={s}", .{cur_hex});
            if (!std.ascii.eqlIgnoreCase(cur_hex, p.from_sha256)) {
                log.print("[updater] patch base mismatch (current {s} != from {s}) -> full download", .{ cur_hex, p.from_sha256 });
                return false;
            }

            const patch_bytes = env.fetcher.fetchFn(env.fetcher.ctx, alloc, p.url) catch |e| {
                log.print("[updater] patch fetch failed ({s}): {s}", .{ p.url, @errorName(e) });
                return false;
            };
            defer alloc.free(patch_bytes);
            log.print("[updater] patch: downloaded {d} bytes", .{patch_bytes.len});
            const patch_hex = updater.sha256Hex(alloc, patch_bytes) catch return false;
            defer alloc.free(patch_hex);
            if (!std.ascii.eqlIgnoreCase(patch_hex, p.sha256)) {
                log.print("[updater] patch sha256 mismatch ({s} != {s})", .{ patch_hex, p.sha256 });
                return false;
            }
            updater.verifyArtifact(patch_bytes, p.signature, env.public_key) catch {
                log.print("[updater] patch signature invalid", .{});
                return false;
            };

            const new_bytes = patch_mod.applyPatch(alloc, current, patch_bytes) catch |e| {
                log.print("[updater] patch apply failed: {s}", .{@errorName(e)});
                return false;
            };
            defer alloc.free(new_bytes);

            const new_hex = updater.sha256Hex(alloc, new_bytes) catch return false;
            defer alloc.free(new_hex);
            if (!std.ascii.eqlIgnoreCase(new_hex, m.sha256)) {
                log.print("[updater] patched result sha256 != manifest -> full download", .{});
                return false;
            }
            updater.verifyArtifact(new_bytes, m.signature, env.public_key) catch {
                log.print("[updater] patched result signature invalid", .{});
                return false;
            };

            updater.stageBytes(alloc, env.exe_path, new_bytes) catch |e| {
                log.print("[updater] patch stage failed: {s}", .{@errorName(e)});
                return false;
            };
            log.print("[updater] patched & staged ok ({d} -> {d} bytes)", .{ current.len, new_bytes.len });
            return true;
        }

        /// 更新流程（后台线程）：检查 → 差分优先/全量回退 → 验签 → 替换 → 事件。
        fn updaterFlow(self: *Self) void {
            const env = self.updater_env orelse return;
            const ctx = self.context(self.allocator, 0); // emit 用 msg_allocator，线程安全

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

            var staged_by_patch = false;
            if (m.patch) |*p| {
                if (std.mem.eql(u8, p.from, env.current_version)) {
                    staged_by_patch = self.tryPatchUpdateLinux(p, &m, &env);
                    if (!staged_by_patch) {
                        log.print("[updater] patch path failed -> full download fallback", .{});
                    }
                } else {
                    log.print("[updater] patch base {s} != current {s} -> full download", .{ p.from, env.current_version });
                }
            }
            if (!staged_by_patch) {
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
            }
            log.print("[updater] staged ✓ {s} — restart to apply", .{m.version});
            ctx.emit("updateStaged", .{ .version = m.version });
            if (self.update_cfg != null and self.update_cfg.?.auto_restart) {
                self.restartToApply();
            }
        }

        /// 重启以应用已暂存的更新：分离拉起 `<exe> --zilt-restart <target>`，
        /// helper 进程在 run() 最早期拦截（等旧实例退出后 replace 成新版）。
        fn restartToApply(self: *Self) void {
            const exe = currentExePathLinux(self.allocator) catch {
                log.print("[updater] restart: exe path failed", .{});
                return;
            };
            defer self.allocator.free(exe);
            const ok = spawnDetachedLinux(&.{ exe, updater.restart_flag, exe });
            log.print("[updater] restart helper spawned ({})", .{ok});
        }

        // ------------------------------------------------------------------
        // fs 12 ops（v0.2.3；读写上限与路径校验复用共享 fs_api）
        // ------------------------------------------------------------------

        fn fileSizeOf(self: *Self, path: []const u8) ?u64 {
            _ = self;
            const st = std.Io.Dir.cwd().statFile(sharedIo(), path, .{}) catch return null;
            return st.size;
        }

        fn fsReadFile(self: *Self, path: []const u8, max: usize) ![]u8 {
            return std.Io.Dir.cwd().readFileAlloc(sharedIo(), path, self.allocator, .limited(max)) catch |err| switch (err) {
                error.FileNotFound => error.FileNotFound,
                else => error.ReadFailed,
            };
        }

        fn fsWriteFile(self: *Self, path: []const u8, data: []const u8) !void {
            if (std.fs.path.dirname(path)) |dir| {
                makeDirPath(self.allocator, dir);
            }
            try std.Io.Dir.cwd().writeFile(sharedIo(), .{ .sub_path = path, .data = data });
        }

        fn fsAppendFile(self: *Self, path: []const u8, data: []const u8) !void {
            const old = self.fsReadFile(path, (fs_api_mod.Limits{}).max_read) catch "";
            defer if (old.len > 0) self.allocator.free(old);
            const merged = try std.mem.concat(self.allocator, u8, &.{ old, data });
            defer self.allocator.free(merged);
            try self.fsWriteFile(path, merged);
        }

        fn fsDeleteTree(self: *Self, path: []const u8) bool {
            _ = self;
            std.Io.Dir.cwd().deleteTree(sharedIo(), path) catch return false;
            return true;
        }

        /// 复制文件（读旧 + 写新；大小上限沿用读限制）。
        fn fsCopyFile(self: *Self, from: []const u8, to: []const u8) !void {
            const data = try self.fsReadFile(from, (fs_api_mod.Limits{}).max_read);
            defer self.allocator.free(data);
            try self.fsWriteFile(to, data);
        }

        /// stat JSON（形状与 Windows 同构：dir/size/modified/created/attributes；
        /// modified/created Linux 侧无 mtime 暴露给该通道，恒 0）。
        fn fsStatJson(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
            const st = std.Io.Dir.cwd().statFile(sharedIo(), path, .{}) catch return null;
            return std.fmt.allocPrint(alloc,
                "{{\"dir\":{s},\"size\":{d},\"modified\":{d},\"created\":{d},\"attributes\":{d}}}",
                .{ boolStr(st.kind == .directory), st.size, 0, 0, @intFromEnum(st.kind) },
            ) catch null;
        }

        /// readDir JSON：[{name, dir, size}]（形状与 Windows 一致）。
        fn fsListDirJson(self: *Self, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
            var dir = std.Io.Dir.cwd().openDir(sharedIo(), path, .{ .iterate = true }) catch return error.FileNotFound;
            defer dir.close(sharedIo());
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.append(alloc, '[');
            var it = dir.iterate();
            var first = true;
            while (it.next(sharedIo()) catch null) |entry| {
                if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
                if (!first) try out.append(alloc, ',');
                first = false;
                const is_dir = entry.kind == .directory;
                var size: u64 = 0;
                if (!is_dir) {
                    const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name }) catch continue;
                    defer self.allocator.free(full);
                    size = self.fileSizeOf(full) orelse 0;
                }
                const name_json = try std.json.Stringify.valueAlloc(alloc, entry.name, .{});
                defer alloc.free(name_json);
                const chunk = try std.fmt.allocPrint(alloc, "{{\"name\":{s},\"dir\":{},\"size\":{d}}}", .{ name_json, is_dir, size });
                defer alloc.free(chunk);
                try out.appendSlice(alloc, chunk);
            }
            try out.append(alloc, ']');
            return out.toOwnedSlice(alloc);
        }

        /// fs write / append 共用实现。
        fn fsWriteOp(self: *Self, w: system_api.FsWrite, append: bool, alloc: std.mem.Allocator) !system_api.Result {
            const scope = try fsScopeOf(w.scope);
            if (!self.fsAllowed(scope, w.path, alloc)) return error.PermissionDenied;
            if (w.data.len > (fs_api_mod.Limits{}).max_write) return error.FileTooLarge;
            const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
            defer alloc.free(root);
            const path = try fs_api_mod.joinChecked(alloc, root, w.path);
            defer alloc.free(path);
            if (append) {
                self.fsAppendFile(path, w.data) catch return error.WriteFailed;
            } else {
                self.fsWriteFile(path, w.data) catch return error.WriteFailed;
            }
            log.print("[fs] {s} {d} bytes -> {s}/{s}", .{
                if (append) "appended" else "wrote", w.data.len, scope.name(), w.path,
            });
            return .{ .ok = true };
        }

        /// fs rename / copy 共用实现。
        fn fsTransferOp(self: *Self, m: system_api.FsMove, is_copy: bool, alloc: std.mem.Allocator) !system_api.Result {
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
            if (std.fs.path.dirname(to)) |dir| makeDirPath(self.allocator, dir);
            if (is_copy) {
                self.fsCopyFile(from, to) catch return error.CopyFailed;
            } else {
                std.Io.Dir.renameAbsolute(from, to, sharedIo()) catch return error.RenameFailed;
            }
            return .{ .ok = true };
        }

        /// fs 12 ops + watch/unwatch + readStream（v0.2.3）。
        fn runFsOp(self: *Self, op: system_api.FsOp, alloc: std.mem.Allocator) !system_api.Result {
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

                    const id = self.next_fs_watch_id;
                    const w = fs_watch_mod.start(
                        std.heap.page_allocator,
                        id,
                        dir,
                        req.recursive,
                        onFsWatchEvent,
                        self,
                    ) catch |err| {
                        log.print("[fs] watch failed: {s} ({s})", .{ @errorName(err), dir });
                        return switch (err) {
                            error.FileNotFound => error.FileNotFound,
                            else => error.WatchFailed,
                        };
                    };
                    self.next_fs_watch_id += 1;
                    try self.fs_watches.append(self.allocator, w);
                    log.print("[fs] watch #{d} {s} recursive={}", .{ id, dir, req.recursive });
                    return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d}}}", .{id}) };
                },
                .unwatch => |id| {
                    for (self.fs_watches.items, 0..) |w, i| {
                        if (w.id != id) continue;
                        _ = self.fs_watches.swapRemove(i);
                        fs_watch_mod.stop(w);
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
                    if (self.fileSizeOf(path) == null) return error.FileNotFound;

                    const a2 = std.heap.page_allocator;
                    const job = a2.create(FsStreamJob) catch return error.OutOfMemory;
                    const id = self.next_fs_stream_id;
                    self.next_fs_stream_id += 1;
                    // job 的所有权在 spawn 后归 worker（完成即 free）——日志与
                    // 响应必须用**局部副本**，否则小文件在日志前就 free 了
                    //（L3 实测 30KB 文件 segfault：job.chunk_size 读已释放内存）。
                    const chunk_size = @min(@max(req.chunk_size, 4096), 1024 * 1024);
                    job.* = .{
                        .backend = self,
                        .id = id,
                        .path = a2.dupe(u8, path) catch {
                            a2.destroy(job);
                            return error.OutOfMemory;
                        },
                        .chunk_size = chunk_size,
                    };
                    const t = std.Thread.spawn(.{ .stack_size = sys.threadStackSize(256 * 1024) }, fsStreamMain, .{job}) catch {
                        a2.free(job.path);
                        a2.destroy(job);
                        return error.SpawnFailed;
                    };
                    t.detach();
                    log.print("[fs] readStream #{d} {s} chunk={d}", .{ id, path, chunk_size });
                    return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d}}}", .{id}) };
                },
                .roots => {
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(alloc);
                    try out.append(alloc, '{');
                    const scopes = [_]fs_api_mod.Scope{ .app_data, .app_config, .app_cache, .home, .desktop, .documents, .downloads, .pictures, .videos, .temp, .exe };
                    var first = true;
                    for (scopes) |sc| {
                        const r = self.scopeRoot(sc, alloc) orelse continue;
                        defer alloc.free(r);
                        if (!first) try out.append(alloc, ',');
                        first = false;
                        try out.print(alloc, "\"{s}\":", .{sc.name()});
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
                    const bytes = self.fsReadFile(path, (fs_api_mod.Limits{}).max_read) catch return error.FileNotFound;
                    defer self.allocator.free(bytes);
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
                    return .{ .ok = self.fileSizeOf(path) != null };
                },
                .remove => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    std.Io.Dir.cwd().deleteFile(sharedIo(), path) catch return .{ .ok = false };
                    return .{ .ok = true };
                },
                .mkdir => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    makeDirPath(self.allocator, path);
                    return .{ .ok = true };
                },
                .remove_dir => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    return .{ .ok = self.fsDeleteTree(path) };
                },
                .read_dir => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    return .{ .json = try self.fsListDirJson(alloc, path) };
                },
                .stat => |t| {
                    const scope = try fsScopeOf(t.scope);
                    if (!self.fsAllowed(scope, t.path, alloc)) return error.PermissionDenied;
                    const root = self.scopeRoot(scope, alloc) orelse return error.ScopeUnavailable;
                    defer alloc.free(root);
                    const path = try fs_api_mod.joinChecked(alloc, root, t.path);
                    defer alloc.free(path);
                    return .{ .json = fsStatJson(alloc, path) orelse return error.FileNotFound };
                },
            }
        }

        // ------------------------------------------------------------------
        // fs 事件封送 / 流式读（v0.2.3）
        // ------------------------------------------------------------------

        /// fs watch 事件：监视线程 → g_idle_add → fsEvent {id, action, path}。
        fn onFsWatchEvent(ctx: ?*anyopaque, id: i64, action: []const u8, path: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            const task = self.allocator.create(FsWatchEvent) catch return;
            const path_copy = self.allocator.dupe(u8, path) catch {
                self.allocator.destroy(task);
                return;
            };
            task.* = .{ .backend = self, .id = id, .action = action, .path = path_copy };
            if (c.g_idle_add(fsWatchIdle, task) == 0) {
                self.allocator.free(task.path);
                self.allocator.destroy(task);
            }
        }

        fn fsWatchIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const task: *FsWatchEvent = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            const self = task.backend;
            defer {
                self.allocator.free(task.path);
                self.allocator.destroy(task);
            }
            const w = self.windowById(0) orelse return G_SOURCE_REMOVE;
            const action_json = jsonStr(self.allocator, task.action) orelse return G_SOURCE_REMOVE;
            defer self.allocator.free(action_json);
            const path_json = jsonStr(self.allocator, task.path) orelse return G_SOURCE_REMOVE;
            defer self.allocator.free(path_json);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"action\":{s},\"path\":{s}}}", .{ task.id, action_json, path_json }) catch return G_SOURCE_REMOVE;
            defer self.allocator.free(payload);
            self.emitRawToWindow(w.id, "fsEvent", payload);
            return G_SOURCE_REMOVE;
        }

        /// fsChunk 事件（流式读）：{id, seq, done, data(base64)}。
        fn emitFsChunk(self: *Self, id: i64, seq: u64, done: bool, data: []const u8) void {
            const w = self.windowById(0) orelse return;
            const encoder = std.base64.standard.Encoder;
            const encoded = self.allocator.alloc(u8, encoder.calcSize(data.len)) catch return;
            defer self.allocator.free(encoded);
            _ = encoder.encode(encoded, data);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"seq\":{d},\"done\":{},\"data\":\"{s}\"}}", .{ id, seq, done, encoded }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(w.id, "fsChunk", payload);
        }

        fn fsStreamMain(job: *FsStreamJob) void {
            const self = job.backend;
            const a2 = std.heap.page_allocator;
            // 正常结束由本线程释放；读失败时 job 交给 fsStreamErrIdle（否则
            // defer 先释放、idle 回调再访问 = use-after-free——L3 实测路径）
            var handed_off = false;
            defer {
                if (!handed_off) {
                    a2.free(job.path);
                    a2.destroy(job);
                }
            }
            // 一次读入（上限沿用 fs 读限制），再按 chunk 切片发事件——
            // 0.17 的 Io.File 流式读 API 面向 reader 接口，这里内存版足够
            //（fs.read 本身也是 32MB 上限）。
            const data = std.Io.Dir.cwd().readFileAlloc(sharedIo(), job.path, a2, .limited((fs_api_mod.Limits{}).max_read)) catch {
                handed_off = true;
                _ = c.g_idle_add(fsStreamErrIdle, job);
                return;
            };
            defer a2.free(data);
            var off: usize = 0;
            var seq: u64 = 0;
            while (off < data.len) {
                if (self.quitting) break;
                const end = @min(off + job.chunk_size, data.len);
                const chunk = a2.dupe(u8, data[off..end]) catch break;
                const ev = a2.create(FsChunkEvent) catch {
                    a2.free(chunk);
                    break;
                };
                ev.* = .{ .backend = self, .id = job.id, .seq = seq, .done = end == data.len, .data = chunk };
                _ = c.g_idle_add(fsChunkIdle, ev);
                seq += 1;
                off = end;
                if (end == data.len) break;
            }
        }

        fn fsChunkIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const ev: *FsChunkEvent = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            const a2 = std.heap.page_allocator;
            defer {
                a2.free(ev.data);
                a2.destroy(ev);
            }
            ev.backend.emitFsChunk(ev.id, ev.seq, ev.done, ev.data);
            return G_SOURCE_REMOVE;
        }

        fn fsStreamErrIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const job: *FsStreamJob = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            const a2 = std.heap.page_allocator;
            defer {
                a2.free(job.path);
                a2.destroy(job);
            }
            job.backend.emitFsChunk(job.id, 0, true, "");
            return G_SOURCE_REMOVE;
        }

        // ------------------------------------------------------------------
        // 全局快捷键（v0.2.6，X11 XGrabKey；绑定见 hotkey.zig）
        // ------------------------------------------------------------------

        fn onHotkeyPress(ctx: ?*anyopaque, id: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            const w = self.windowById(0) orelse return;
            const id_json = jsonStr(self.allocator, id) orelse return;
            defer self.allocator.free(id_json);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{s}}}", .{id_json}) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(w.id, "hotkey", payload);
        }

        /// v0.3.10 D1：环境变量读取（libc getenv；Wayland 判定用）
        fn getenvZ(name: [:0]const u8) ?[:0]const u8 {
            const v = std.c.getenv(name.ptr) orelse return null;
            return std.mem.span(v);
        }

        fn initHotkeys(self: *Self) void {
            // v0.3.10 D1：Wayland 会话 → portal GlobalShortcuts（XGrabKey 在 Wayland
            // 下无法全局捕获）；X11/CI（Xvfb）保持 XGrabKey 分支不变
            const wayland_env = getenvZ("WAYLAND_DISPLAY");
            const gdk_backend = getenvZ("GDK_BACKEND");
            if (portal_hotkey.isWaylandSession(wayland_env, gdk_backend)) {
                const p = portal_hotkey.Portal.init(self.allocator, wayland_env, gdk_backend, onHotkeyPress, self) catch |err| {
                    log.print("[hotkey] portal unavailable ({s}) — global hotkeys disabled (Wayland)", .{@errorName(err)});
                    return;
                };
                self.hotkeys_portal = p;
                log.print("[hotkey] Wayland session — portal GlobalShortcuts backend", .{});
                for (config.hotkeys orelse &.{}) |hk| {
                    const accel_text = accelTextOf(hk);
                    p.register(hk.id, accel_text) catch |err| {
                        log.print("[hotkey] config '{s}' portal register failed ({s})——不致命", .{ hk.id, @errorName(err) });
                        continue;
                    };
                    log.print("[hotkey] config '{s}' = {s} registered (portal)", .{ hk.id, accel_text });
                }
                return;
            }
            const m = hotkey_mod.Manager.init(self.allocator, onHotkeyPress, self) catch |err| {
                log.print("[hotkey] X11 unavailable ({s}) — global hotkeys disabled", .{@errorName(err)});
                return;
            };
            self.hotkeys = m;
            // config.hotkeys 声明式注册（对齐 Windows 启动注册；冲突/占用优雅降级）
            for (config.hotkeys orelse &.{}) |hk| {
                const keyval = keyvalForGtk(hk.key) orelse continue;
                const keysym_name = hotkey_mod.keysymNameFor(self.allocator, keyval) catch null;
                if (keysym_name) |kn| {
                    defer self.allocator.free(kn);
                    const mods: c_uint = (if (hk.shift) @as(c_uint, 1) else 0) |
                        (if (hk.ctrl) @as(c_uint, 4) else 0) |
                        (if (hk.alt) @as(c_uint, 8) else 0) |
                        (if (hk.win) @as(c_uint, 1 << 26) else 0);
                    const accel_text = accelTextOf(hk);
                    m.register(hk.id, accel_text, kn, mods) catch |err| {
                        log.print("[hotkey] config '{s}' register failed ({s})——占用/无效键位不致命", .{ hk.id, @errorName(err) });
                        continue;
                    };
                    log.print("[hotkey] config '{s}' = {s} registered", .{ hk.id, accel_text });
                }
            }
        }

        /// v0.3.10 D1：portal 版 hotkey op（list/register/unregister；事件面与 X11 一致）。
        fn runHotkeyOpPortal(p: *portal_hotkey.Portal, op: system_api.HotkeyOp, alloc: std.mem.Allocator) !system_api.Result {
            switch (op) {
                .list => {
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(alloc);
                    try out.append(alloc, '[');
                    const items = try p.list(alloc);
                    defer alloc.free(items);
                    for (items, 0..) |e, i| {
                        if (i != 0) try out.appendSlice(alloc, ",");
                        const id = try std.json.Stringify.valueAlloc(alloc, e.id, .{});
                        defer alloc.free(id);
                        const accel = try std.json.Stringify.valueAlloc(alloc, e.description, .{});
                        defer alloc.free(accel);
                        try out.appendSlice(alloc, "{\"id\":");
                        try out.appendSlice(alloc, id);
                        try out.appendSlice(alloc, ",\"accel\":");
                        try out.appendSlice(alloc, accel);
                        try out.appendSlice(alloc, "}");
                    }
                    try out.append(alloc, ']');
                    return .{ .json = try out.toOwnedSlice(alloc) };
                },
                .register => |spec| {
                    p.register(spec.id, spec.accel) catch |err| return switch (err) {
                        error.InvalidAccel, error.InvalidShortcutId => error.InvalidAccel,
                        error.BindFailed, error.CreateSessionFailed => error.HotkeyConflict,
                        else => err,
                    };
                    log.print("[hotkey] '{s}' = {s} registered (portal)", .{ spec.id, spec.accel });
                    return .{ .ok = true };
                },
                .unregister => |id| {
                    _ = p.unregister(id);
                    return .{ .ok = true };
                },
            }
        }

        /// config.hotkeys 的展示文本（"Ctrl+Alt+N"——与 Windows 的 accel 格式一致）。
        var accel_text_buf: [64]u8 = undefined;
        fn accelTextOf(hk: Config.Hotkey) []const u8 {
            var w: std.Io.Writer = .fixed(&accel_text_buf);
            if (hk.ctrl) w.writeAll("Ctrl+") catch {};
            if (hk.alt) w.writeAll("Alt+") catch {};
            if (hk.shift) w.writeAll("Shift+") catch {};
            if (hk.win) w.writeAll("Super+") catch {};
            w.writeAll(hk.key) catch {};
            return accel_text_buf[0..w.end];
        }

        fn runHotkeyOp(self: *Self, op: system_api.HotkeyOp, alloc: std.mem.Allocator) !system_api.Result {
            // v0.3.10 D1：Wayland 会话走 portal manager（同事件面，X11 语义逐字一致）
            if (self.hotkeys_portal) |p| return runHotkeyOpPortal(p, op, alloc);
            const m = self.hotkeys orelse return error.HotkeyNotAvailable;
            switch (op) {
                .list => {
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(alloc);
                    try out.append(alloc, '[');
                    const items = try m.list(alloc);
                    defer alloc.free(items);
                    for (items, 0..) |e, i| {
                        if (i != 0) try out.appendSlice(alloc, ",");
                        const id = try std.json.Stringify.valueAlloc(alloc, e.id, .{});
                        defer alloc.free(id);
                        const accel = try std.json.Stringify.valueAlloc(alloc, e.accel, .{});
                        defer alloc.free(accel);
                        try out.appendSlice(alloc, "{\"id\":");
                        try out.appendSlice(alloc, id);
                        try out.appendSlice(alloc, ",\"accel\":");
                        try out.appendSlice(alloc, accel);
                        try out.appendSlice(alloc, "}");
                    }
                    try out.append(alloc, ']');
                    return .{ .json = try out.toOwnedSlice(alloc) };
                },
                .register => |spec| {
                    const parsed = parseAccelGtk(spec.accel) orelse return error.InvalidAccel;
                    const keysym_name = (hotkey_mod.keysymNameFor(self.allocator, parsed.keyval) catch null) orelse return error.InvalidAccel;
                    defer self.allocator.free(keysym_name);
                    m.register(spec.id, spec.accel, keysym_name, @intCast(parsed.mods)) catch |err| return switch (err) {
                        error.XGrabFailed => error.HotkeyConflict,
                        else => err,
                    };
                    log.print("[hotkey] runtime registered {s} = {s}", .{ spec.id, spec.accel });
                    return .{ .ok = true };
                },
                .unregister => |id| {
                    const ok = m.unregister(id);
                    log.print("[hotkey] runtime unregistered {s} (ok={})", .{ id, ok });
                    return .{ .ok = ok };
                },
            }
        }

        // ------------------------------------------------------------------
        // SQL（v0.2.3）：libsqlite3 dlopen（绑定见 sqlite.zig）
        // ------------------------------------------------------------------

        fn runSqlOp(self: *Self, op: system_api.SqlOp, alloc: std.mem.Allocator) !system_api.Result {
            if (self.sqlite_lib == null) {
                const lib_ptr = self.allocator.create(linux_sqlite.Lib) catch return error.OutOfMemory;
                lib_ptr.* = linux_sqlite.load() catch {
                    self.allocator.destroy(lib_ptr);
                    log.print("[sql] libsqlite3 not found — SQL disabled（apt install libsqlite3-0）", .{});
                    return error.SqliteFailed;
                };
                self.sqlite_lib = lib_ptr;
                log.print("[sql] libsqlite3 loaded", .{});
            }

            if (op == .migrate) {
                const m = op.migrate;
                linux_sqlite.migrate(alloc, m.db, m.statements, m.version) catch |e| {
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
            const out = linux_sqlite.run(alloc, q.db, q.sql, q.params, want_rows) catch |e| {
                log.print("[sql] {s} failed: {s} (db={s})", .{ @tagName(op), @errorName(e), q.db });
                return error.SqliteFailed;
            };
            return .{ .json = out };
        }


        // ------------------------------------------------------------------
        // http / ws（v0.2.3，libsoup3；与 WebKit 共享 TLS 信任链/代理栈）
        // 事件与 Windows 对齐：httpResponse {id,status,body,err?} /
        // httpChunk {id,seq,data(base64)} / wsEvent {id,kind,data?,err?,binary?}
        // ------------------------------------------------------------------

        fn runHttpOp(self: *Self, op: system_api.HttpOp, alloc: std.mem.Allocator) !system_api.Result {
            const req = switch (op) {
                .request => |r| r,
                // v0.4.1 H14：断点续传分块上传（独立线程逐块 PATCH；状态落盘）
                .upload_resumable => |r| return self.uploadResumableStart(r, alloc),
            };
            // v0.1.21 对齐：http scope 走 ACL（含 URL 形式资源）
            if (!self.aclAllowed("http", req.url)) {
                log.print("[http] denied: {s}", .{req.url});
                return error.PermissionDenied;
            }
            return self.httpRequestStart(req, alloc);
        }

        const UploadJob = struct {
            backend: *Self,
            id: i64,
            url: []u8,
            path: []u8,
            state_dir: []u8,
            chunk_size: u32,
            fail_after: u32,
        };

        /// libsoup3 同步读取（libsoup 3.0 起soup_session_send_and_read 即同步变体；
        /// translate-c 的 capi 缺此声明——手动 extern，链接由 -lsoup-3.0 提供）。
        extern fn soup_session_send_and_read(
            session: *anyopaque,
            msg: *anyopaque,
            cancellable: ?*anyopaque,
            err_ptr: ?*?*anyopaque,
        ) ?*anyopaque;

        fn uploadResumableStart(self: *Self, req: system_api.UploadResumableReq, alloc: std.mem.Allocator) !system_api.Result {
            _ = alloc;
            // job 与字符串全部用 page_allocator（worker 线程释放所有权；
            // dispatch 的 per-message arena 会在消息处理结束时回收——实测
            // arena 分配 + worker free = free(): invalid pointer abort）
            const pa = std.heap.page_allocator;
            if (!self.aclAllowed("http", req.url)) {
                log.print("[http] denied: {s}", .{req.url});
                return error.PermissionDenied;
            }
            const root = self.appDataRoot() orelse return error.StorageUnavailable;
            defer self.allocator.free(root);
            const state_dir = std.fmt.allocPrint(pa, "{s}/upload-state", .{root}) catch return error.OutOfMemory;
            const job = pa.create(UploadJob) catch {
                pa.free(state_dir);
                return error.OutOfMemory;
            };
            job.* = .{
                .backend = self,
                .id = req.id,
                .url = pa.dupe(u8, req.url) catch {
                    pa.free(state_dir);
                    pa.destroy(job);
                    return error.OutOfMemory;
                },
                .path = pa.dupe(u8, req.path) catch {
                    pa.free(state_dir);
                    pa.free(job.url);
                    pa.destroy(job);
                    return error.OutOfMemory;
                },
                .state_dir = state_dir,
                .chunk_size = if (req.chunk_size == 0) 64 * 1024 else req.chunk_size,
                .fail_after = req.fail_after,
            };
            const t = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, resumableUploadWorker, .{job}) catch {
                pa.free(job.url);
                pa.free(job.path);
                pa.free(job.state_dir);
                pa.destroy(job);
                return error.HttpSpawnFailed;
            };
            t.detach();
            log.print("[upload] resumable dispatched (id={d}, path={s}, chunk={d}, fail_after={d})", .{ req.id, req.path, req.chunk_size, req.fail_after });
            return .{ .ok = true };
        }

        /// v0.4.1 H14：断点续传 worker（libsoup 同步逐块 PATCH；状态落盘可跨
        /// 重启续传；emitHttpResponse/emitHttpProgress 经 g_idle_add 封送线程安全）。
        fn resumableUploadWorker(job: *UploadJob) void {
            const self = job.backend;
            const a = std.heap.page_allocator;
            var threaded: std.Io.Threaded = .init(a, .{});
            defer threaded.deinit();
            const io = threaded.io();
            defer {
                a.free(job.url);
                a.free(job.path);
                a.free(job.state_dir);
                a.destroy(job);
            }

            const data = std.Io.Dir.cwd().readFileAlloc(io, job.path, a, .limited(512 * 1024 * 1024)) catch {
                self.emitHttpResponse(job.id, 0, "", "FileNotFound");
                return;
            };
            defer a.free(data);
            const total: u64 = data.len;
            const key = upload_resume.stateKeyHex(a, job.url, job.path) catch {
                self.emitHttpResponse(job.id, 0, "", "OutOfMemory");
                return;
            };
            defer a.free(key);
            const spath = upload_resume.statePath(a, job.state_dir, key) catch {
                self.emitHttpResponse(job.id, 0, "", "OutOfMemory");
                return;
            };
            defer a.free(spath);
            // 状态目录首次创建（writeFile 不建父目录）
            const dir_z = dupeZ(a, job.state_dir) catch return;
            defer a.free(dir_z);
            _ = std.c.mkdir(dir_z.ptr, 0o755); // 已存在 → EEXIST（忽略）
            var st = upload_resume.loadState(io, a, spath, key) orelse upload_resume.State{ .key = key, .offset = 0, .total = total };
            if (st.total != total) st.offset = 0; // 文件变了 → 从头上传
            if (st.offset > total) st.offset = 0;
            var offset = st.offset;
            log.print("[upload] resumable id={d}: total={d} resume-from={d} chunk={d}", .{ job.id, total, offset, job.chunk_size });

            // PUT 初始化（确定性 uploadId = sha256(key)[:16]；已有 uid 则跳过）
            var uid_buf: [64]u8 = undefined;
            var uid: []const u8 = st.upload_id;
            if (uid.len == 0) {
                const init_body = std.fmt.allocPrint(a, "{{\"size\":{d},\"key\":\"{s}\"}}", .{ total, key }) catch {
                    self.emitHttpResponse(job.id, 0, "", "OutOfMemory");
                    return;
                };
                defer a.free(init_body);
                const url_i = dupeZ(a, job.url) catch {
                    self.emitHttpResponse(job.id, 0, "", "OutOfMemory");
                    return;
                };
                defer a.free(url_i);
                const msg_i = c.soup_message_new("PUT", url_i.ptr) orelse {
                    self.emitHttpResponse(job.id, 0, "", "InvalidUrl");
                    return;
                };
                const bi = c.g_bytes_new(init_body.ptr, init_body.len);
                defer c.g_bytes_unref(bi);
                c.soup_message_set_request_body_from_bytes(msg_i, "application/json", bi);
                const sess_i = newSoupSession(60_000, null) orelse {
                    self.emitHttpResponse(job.id, 0, "", "SoupUnavailable");
                    return;
                };
                defer c.g_object_unref(@ptrCast(sess_i));
                var gierr: [*c]c.GError = null;
                const gbi_raw = soup_session_send_and_read(@ptrCast(sess_i), @ptrCast(msg_i), null, @ptrCast(&gierr));
                                if (gierr != null) {
                    c.g_error_free(gierr);
                    self.emitHttpResponse(job.id, 0, "", "CannotConnect");
                    return;
                }
                defer if (gbi_raw) |gp| c.g_bytes_unref(@ptrCast(gp));
                if (c.soup_message_get_status(msg_i) < 200 or c.soup_message_get_status(msg_i) >= 300) {
                    self.emitHttpResponse(job.id, @intCast(c.soup_message_get_status(msg_i)), "", "UploadRejected");
                    return;
                }
                var ilen: c.gsize = 0;
                const iptr = if (gbi_raw) |gp| c.g_bytes_get_data(@ptrCast(gp), &ilen) else null;
                var body_src: []const u8 = "";
                if (iptr != null and ilen > 0) body_src = @as([*]const u8, @ptrCast(iptr.?))[0..ilen];
                const p_init = std.json.parseFromSlice(std.json.Value, a, body_src, .{}) catch {
                    self.emitHttpResponse(job.id, 0, "", "ProtocolMismatch");
                    return;
                };
                defer p_init.deinit();
                const uid_opt = p_init.value.object.get("uploadId") orelse {
                    self.emitHttpResponse(job.id, 0, "", "ProtocolMismatch");
                    return;
                };
                if (uid_opt != .string or uid_opt.string.len >= uid_buf.len) {
                    self.emitHttpResponse(job.id, 0, "", "ProtocolMismatch");
                    return;
                }
                @memcpy(uid_buf[0..uid_opt.string.len], uid_opt.string);
                uid = uid_buf[0..uid_opt.string.len];
            }

            var sent_this_session: u32 = 0;
            var idx: u64 = 0;
            if (job.chunk_size > 0) idx = offset / job.chunk_size;
            const patch_url = std.fmt.allocPrint(a, "{s}/{s}", .{ job.url, uid }) catch {
                self.emitHttpResponse(job.id, 0, "", "OutOfMemory");
                return;
            };
            defer a.free(patch_url);
            while (offset < total) {
                const clen = upload_resume.chunkLen(total, job.chunk_size, idx);
                if (clen == 0) break;
                const slice = data[@intCast(offset)..@intCast(offset + clen)];
                const url_z = dupeZ(a, patch_url) catch break;
                defer a.free(url_z);
                const msg = c.soup_message_new("PATCH", url_z.ptr) orelse {
                    self.emitHttpResponse(job.id, 0, "", "InvalidUrl");
                    return;
                };
                var hdr_buf: [64]u8 = undefined;
                const off_str = std.fmt.bufPrint(&hdr_buf, "{d}", .{offset}) catch break;
                const off_z = dupeZ(a, off_str) catch break;
                defer a.free(off_z);
                c.soup_message_headers_append(c.soup_message_get_request_headers(msg), "Upload-Offset", off_z.ptr);
                var fail_buf: [32]u8 = undefined;
                const fail_str = std.fmt.bufPrint(&fail_buf, "{d}", .{job.fail_after}) catch break;
                const fail_z = dupeZ(a, fail_str) catch break;
                defer a.free(fail_z);
                c.soup_message_headers_append(c.soup_message_get_request_headers(msg), "X-Fail-After", fail_z.ptr);
                const bytes = c.g_bytes_new(slice.ptr, slice.len);
                defer c.g_bytes_unref(bytes);
                c.soup_message_set_request_body_from_bytes(msg, "application/octet-stream", bytes);
                const session = newSoupSession(60_000, null) orelse {
                    self.emitHttpResponse(job.id, 0, "", "SoupUnavailable");
                    return;
                };
                defer c.g_object_unref(@ptrCast(session));
                var gerr: [*c]c.GError = null;
                const gbytes_raw = soup_session_send_and_read(@ptrCast(session), @ptrCast(msg), null, @ptrCast(&gerr));
                                if (gerr != null) {
                    const reason = a.dupe(u8, std.mem.span(gerr.*.message)) catch "";
                    defer if (reason.len > 0) a.free(reason);
                    log.print("[upload] id={d} chunk {d} failed: {s} (state kept at {d})", .{ job.id, idx, reason, offset });
                    c.g_error_free(gerr);
                    var body_buf: [64]u8 = undefined;
                    const body = std.fmt.bufPrint(&body_buf, "{{\"offset\":{d},\"total\":{d}}}", .{ offset, total }) catch "{}";
                    self.emitHttpResponse(job.id, 0, body, "CannotConnect");
                    return;
                }
                defer if (gbytes_raw) |gp| c.g_bytes_unref(@ptrCast(gp));
                const status = c.soup_message_get_status(msg);
                if (status < 200 or status >= 300) {
                    self.emitHttpResponse(job.id, @intCast(status), "", "UploadRejected");
                    return;
                }
                var body_len: c.gsize = 0;
                const body_ptr = if (gbytes_raw) |gp| c.g_bytes_get_data(@ptrCast(gp), &body_len) else null;
                var chunk_src: []const u8 = "";
                if (body_ptr != null and body_len > 0) chunk_src = @as([*]const u8, @ptrCast(body_ptr.?))[0..body_len];
                const parsed = std.json.parseFromSlice(std.json.Value, a, chunk_src, .{}) catch {
                    self.emitHttpResponse(job.id, @intCast(status), "", "ProtocolMismatch");
                    return;
                };
                defer parsed.deinit();
                const new_off: i64 = blk: {
                    const o = parsed.value.object.get("offset") orelse break :blk -1;
                    if (o != .integer or o.integer < 0) break :blk -1;
                    break :blk o.integer;
                };
                if (new_off < 0 or @as(u64, @intCast(new_off)) != offset + clen) {
                    log.print("[upload] id={d} offset mismatch: got {d}, want {d}", .{ job.id, new_off, offset + clen });
                    self.emitHttpResponse(job.id, @intCast(status), "", "ProtocolMismatch");
                    return;
                }
                offset = @intCast(new_off);
                upload_resume.saveState(io, a, spath, .{ .key = key, .offset = offset, .total = total, .upload_id = uid }) catch |e| {
                    log.print("[upload] id={d} saveState failed: {s}", .{ job.id, @errorName(e) });
                };
                self.emitHttpProgress(job.id, offset, total);
                sent_this_session += 1;
                idx += 1;
                if (job.fail_after > 0 and sent_this_session >= job.fail_after and offset < total) {
                    log.print("[upload] id={d} simulated interrupt after {d} chunks (state at {d}/{d})", .{ job.id, sent_this_session, offset, total });
                    var body_buf: [64]u8 = undefined;
                    const body = std.fmt.bufPrint(&body_buf, "{{\"offset\":{d},\"total\":{d}}}", .{ offset, total }) catch "{}";
                    self.emitHttpResponse(job.id, 0, body, "InterruptedForResume");
                    return;
                }
            }
            upload_resume.clearState(io, spath);
            log.print("[upload] id={d} complete ({d} bytes, {d} chunks this session)", .{ job.id, offset, sent_this_session });
            var body_buf: [64]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"offset\":{d},\"total\":{d}}}", .{ offset, total }) catch "{}";
            self.emitHttpResponse(job.id, 200, body, "");
        }

        fn newSoupSession(timeout_ms: u32, proxy: ?[]const u8) [*c]c.SoupSession {
            const session = c.soup_session_new();
            if (session == null) return null;
            const secs: c_int = @intCast(@max(1, @min(@as(u32, 600), @max(timeout_ms, 1000) / 1000)));
            c.g_object_set(@ptrCast(session), "timeout", secs, "idle-timeout", secs, @as(?*anyopaque, null));
            if (proxy) |p| {
                if (p.len > 0) {
                    const pz = std.heap.c_allocator.allocSentinel(u8, p.len, 0) catch return session;
                    defer std.heap.c_allocator.free(pz);
                    @memcpy(pz[0..p.len], p);
                    const resolver = c.g_simple_proxy_resolver_new(pz.ptr, null);
                    if (resolver != null) {
                        c.soup_session_set_proxy_resolver(session, @ptrCast(resolver));
                        c.g_object_unref(@ptrCast(resolver));
                    }
                }
            }
            return session;
        }

        fn httpRequestStart(self: *Self, req: system_api.HttpRequest, alloc: std.mem.Allocator) !system_api.Result {
            const id = if (req.id != 0) req.id else blk: {
                const v = self.next_http_id_seq;
                self.next_http_id_seq += 1;
                break :blk v;
            };

            const url_z = try dupeZ(self.allocator, req.url);
            defer self.allocator.free(url_z);
            const method_z = try dupeZ(self.allocator, req.method);
            defer self.allocator.free(method_z);
            const msg = c.soup_message_new(method_z.ptr, url_z.ptr) orelse return error.InvalidUrl;

            // 头（"A: 1\r\nB: 2" 单串）
            var content_type: ?[]const u8 = null;
            var hit = std.mem.splitSequence(u8, req.headers, "\r\n");
            while (hit.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t");
                if (line.len == 0) continue;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const name = std.mem.trim(u8, line[0..colon], " \t");
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (name.len == 0) continue;
                if (std.ascii.eqlIgnoreCase(name, "content-type")) content_type = value;
                const name_z = try dupeZ(self.allocator, name);
                defer self.allocator.free(name_z);
                const value_z = try dupeZ(self.allocator, value);
                defer self.allocator.free(value_z);
                c.soup_message_headers_append(c.soup_message_get_request_headers(msg), name_z.ptr, value_z.ptr);
            }

            // body / multipart（multipart 覆盖 body 并自动 Content-Type）
            var body_owned: ?[]u8 = null;
            defer if (body_owned) |b| self.allocator.free(b);
            var ct_owned: ?[]u8 = null;
            defer if (ct_owned) |t| self.allocator.free(t);
            // v0.3.8 E6：base64 编码分片在构建 multipart 前解码
            var decoded_bufs: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (decoded_bufs.items) |d| self.allocator.free(d);
                decoded_bufs.deinit(self.allocator);
            }
            if (req.multipart) |parts| {
                const conv = try self.allocator.alloc(shared_net.Part, parts.len);
                defer self.allocator.free(conv);
                for (parts, 0..) |mp, i| {
                    var data = mp.data;
                    if (std.ascii.eqlIgnoreCase(mp.encoding, "base64")) {
                        if (shared_net.base64DecodeAlloc(self.allocator, mp.data)) |dec| {
                            decoded_bufs.append(self.allocator, dec) catch {};
                            data = dec;
                        } else |_| {}
                    }
                    conv[i] = .{ .name = mp.name, .data = data, .filename = mp.filename, .content_type = mp.content_type };
                }
                var boundary_buf: [32]u8 = undefined;
                const boundary = std.fmt.bufPrint(&boundary_buf, "zilt-{x}", .{@as(u64, @bitCast(c.g_get_real_time()))}) catch "zilt-boundary";
                var mp = try shared_net.buildMultipart(self.allocator, boundary, conv);
                defer mp.deinit(self.allocator);
                body_owned = try self.allocator.dupe(u8, mp.body);
                ct_owned = try self.allocator.dupe(u8, mp.content_type);
            } else if (req.body.len > 0) {
                body_owned = try self.allocator.dupe(u8, req.body);
            }
            if (body_owned) |b| {
                const ct = if (ct_owned) |t| t else (content_type orelse "application/octet-stream");
                const ct_z = try dupeZ(self.allocator, ct);
                defer self.allocator.free(ct_z);
                const bytes = c.g_bytes_new(b.ptr, b.len);
                defer c.g_bytes_unref(bytes);
                c.soup_message_set_request_body_from_bytes(msg, ct_z.ptr, bytes);
            }

            if (!req.follow_redirects) {
                // libsoup3 移除了 SoupMessage:follow-redirects 属性（3.6+ 会打
                // "has no property named 'follow-redirects'"）；禁用重定向走标志位。
                c.soup_message_set_flags(msg, c.SOUP_MESSAGE_NO_REDIRECT);
            }
            if (req.insecure_tls) {
                _ = c.g_signal_connect_data(@ptrCast(msg), "accept-certificate", @ptrCast(&onHttpAcceptCert), null, null, 0);
            }

            const job = try self.allocator.create(HttpJob);
            errdefer self.allocator.destroy(job);
            job.* = .{
                .backend = self,
                .id = id,
                .session = newSoupSession(req.timeout_ms, req.proxy),
                .msg = msg,
                .stream_mode = req.stream,
                .upload = req.upload_progress,
                .upload_total = if (body_owned) |b| b.len else 0,
            };
            if (job.session == null) return error.SoupUnavailable;

            log.print("[http] {s} {s} (id={d}, stream={s}, proxy={s}{s})", .{
                req.method, req.url, id, boolStr(req.stream), req.proxy orelse "-",
                if (req.upload_progress) ", upload" else "",
            });
            // v0.3.8 E6：粗粒度上传进度（0/total 起始帧；soup 无字节级上传进度）
            if (req.upload_progress) {
                self.emitHttpProgress(id, 0, job.upload_total);
            }
            c.soup_session_send_async(job.session, msg, 0, null, httpSendDone, job);
            // 立即返回；结果走 httpResponse / httpChunk 事件（对齐 Windows）
            return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"pending\":true}}", .{id}) };
        }

        fn onHttpAcceptCert(_: ?*c.SoupMessage, cert: ?*anyopaque, errors_flags: c_int, _: c.gpointer) callconv(.c) c.gboolean {
            _ = cert;
            _ = errors_flags;
            log.print("[http] insecure_tls: certificate accepted", .{});
            return 1;
        }

        fn httpSendDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            const job: *HttpJob = @ptrCast(@alignCast(user_data orelse return));
            const self = job.backend;
            var err: [*c]c.GError = null;
            const stream = c.soup_session_send_finish(@ptrCast(source), res, &err);
            if (err != null) {
                // GError 的 message 在 g_error_free 后失效 → 先拷贝再释放
                const reason = self.allocator.dupe(u8, std.mem.span(err.*.message)) catch "";
                defer if (reason.len > 0) self.allocator.free(reason);
                log.print("[http] id={d} failed: {s}", .{ job.id, reason });
                c.g_error_free(err);
                self.emitHttpResponse(job.id, 0, "", reason);
                self.freeHttpJob(job);
                return;
            }
            job.stream = stream;
            self.httpReadNext(job);
        }

        /// 继续读响应体（64KB 分块；stream 模式逐块发 httpChunk，普通模式累积）。
        fn httpReadNext(self: *Self, job: *HttpJob) void {
            _ = self;
            c.g_input_stream_read_bytes_async(job.stream.?, 64 * 1024, 0, null, httpReadDone, job);
        }

        fn httpReadDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            const job: *HttpJob = @ptrCast(@alignCast(user_data orelse return));
            const self = job.backend;
            var gerr: [*c]c.GError = null;
            const bytes = c.g_input_stream_read_bytes_finish(@ptrCast(source), res, &gerr);
            if (gerr != null) c.g_error_free(gerr);
            if (bytes == null) return self.httpFinish(job);
            var size: c.gsize = 0;
            const data_ptr = c.g_bytes_get_data(bytes, &size);
            if (size == 0) {
                c.g_bytes_unref(bytes);
                return self.httpFinish(job);
            }
            const data: [*]const u8 = @ptrCast(data_ptr);
            if (job.stream_mode) {
                c.g_bytes_unref(bytes);
                self.emitHttpChunk(job.id, job.seq, data[0..size]);
                job.seq += 1;
                return self.httpReadNext(job);
            }
            job.body.appendSlice(self.allocator, data[0..size]) catch {
                c.g_bytes_unref(bytes);
                return self.httpFinish(job);
            };
            c.g_bytes_unref(bytes);
            self.httpReadNext(job);
        }

        fn httpFinish(self: *Self, job: *HttpJob) void {
            const status: u16 = @intCast(c.soup_message_get_status(job.msg.?));
            const body: []const u8 = if (job.stream_mode) "" else job.body.items;
            log.print("[http] done id={d} status={d} bytes={d}", .{ job.id, status, body.len });
            // v0.3.8 E6：粗粒度上传进度收尾帧（total/total）
            if (job.upload) {
                self.emitHttpProgress(job.id, job.upload_total, job.upload_total);
            }
            self.emitHttpResponse(job.id, status, body, null);
            self.freeHttpJob(job);
        }

        fn freeHttpJob(self: *Self, job: *HttpJob) void {
            if (job.stream) |st| {
                _ = c.g_input_stream_close(st, null, null);
                c.g_object_unref(@ptrCast(st));
            }
            if (job.msg) |m| c.g_object_unref(@ptrCast(m));
            c.g_object_unref(@ptrCast(job.session));
            job.body.deinit(self.allocator);
            self.allocator.destroy(job);
        }

        fn emitHttpResponse(self: *Self, id: i64, status: u16, body: []const u8, err: ?[]const u8) void {
            const w = self.windowById(0) orelse return;
            const body_json = std.json.Stringify.valueAlloc(self.allocator, body, .{}) catch return;
            defer self.allocator.free(body_json);
            const err_json = if (err) |e| (jsonStr(self.allocator, e) orelse return) else self.allocator.dupe(u8, "null") catch return;
            defer self.allocator.free(err_json);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"status\":{d},\"body\":{s},\"err\":{s}}}", .{ id, status, body_json, err_json }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(w.id, "httpResponse", payload);
        }

        fn emitHttpChunk(self: *Self, id: i64, seq: u64, data: []const u8) void {
            const w = self.windowById(0) orelse return;
            const encoder = std.base64.standard.Encoder;
            const encoded = self.allocator.alloc(u8, encoder.calcSize(data.len)) catch return;
            defer self.allocator.free(encoded);
            _ = encoder.encode(encoded, data);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"seq\":{d},\"data\":\"{s}\"}}", .{ id, seq, encoded }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(w.id, "httpChunk", payload);
        }

        /// v0.3.8 E6：上传进度事件（Linux 粗粒度——send 前 0/total、完成时 total/total；
        /// libsoup3 无字节级上传进度信号，文档化平台差异）
        fn emitHttpProgress(self: *Self, id: i64, written: usize, total: usize) void {
            const w = self.windowById(0) orelse return;
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"written\":{d},\"total\":{d}}}", .{ id, written, total }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(w.id, "httpUploadProgress", payload);
        }

        // ---- WebSocket（SoupWebsocketConnection）----

        fn runWsOp(self: *Self, op: system_api.WsOp, alloc: std.mem.Allocator) !system_api.Result {
            switch (op) {
                .connect => |req| {
                    if (!self.aclAllowed("http", req.url)) {
                        log.print("[ws] denied: {s}", .{req.url});
                        return error.PermissionDenied;
                    }
                    const id = if (req.id != 0) req.id else blk: {
                        const v = self.next_ws_id_seq;
                        self.next_ws_id_seq += 1;
                        break :blk v;
                    };
                    const url_z = try dupeZ(self.allocator, req.url);
                    defer self.allocator.free(url_z);
                    const msg = c.soup_message_new("GET", url_z.ptr) orelse return error.InvalidUrl;
                    // 头（cookie/子协议等）
                    var hit = std.mem.splitSequence(u8, req.headers, "\r\n");
                    while (hit.next()) |line_raw| {
                        const line = std.mem.trim(u8, line_raw, " \t");
                        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                        const name = std.mem.trim(u8, line[0..colon], " \t");
                        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                        if (name.len == 0) continue;
                        const name_z = try dupeZ(self.allocator, name);
                        defer self.allocator.free(name_z);
                        const value_z = try dupeZ(self.allocator, value);
                        defer self.allocator.free(value_z);
                        c.soup_message_headers_append(c.soup_message_get_request_headers(msg), name_z.ptr, value_z.ptr);
                    }

                    const job = try self.allocator.create(WsConn);
                    errdefer self.allocator.destroy(job);
                    job.* = .{
                        .backend = self,
                        .id = id,
                        .session = newSoupSession(30_000, req.proxy),
                        .conn = null,
                    };
                    if (job.session == null) return error.SoupUnavailable;
                    if (req.insecure_tls) {
                        _ = c.g_signal_connect_data(@ptrCast(msg), "accept-certificate", @ptrCast(&onHttpAcceptCert), null, null, 0);
                    }
                    log.print("[ws] connect id={d} {s}", .{ id, req.url });
                    c.soup_session_websocket_connect_async(job.session, msg, null, null, 0, null, wsConnectDone, job);
                    return .{ .json = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"pending\":true}}", .{id}) };
                },
                .send => |req| {
                    const conn = (self.ws_conns.get(req.id) orelse return .{ .ok = false }).conn orelse return .{ .ok = false };
                    // 文本优先；非法 UTF-8 → 二进制
                    if (std.unicode.utf8ValidateSlice(req.data)) {
                        const z = try dupeZ(self.allocator, req.data);
                        defer self.allocator.free(z);
                        c.soup_websocket_connection_send_text(conn, z.ptr);
                    } else {
                        c.soup_websocket_connection_send_binary(conn, req.data.ptr, @intCast(req.data.len));
                    }
                    return .{ .ok = true };
                },
                .close => |req| {
                    const conn = (self.ws_conns.get(req.id) orelse return .{ .ok = false }).conn orelse return .{ .ok = false };
                    const reason_z: ?[:0]u8 = if (req.reason.len > 0) try dupeZ(self.allocator, req.reason) else null;
                    defer if (reason_z) |z| self.allocator.free(z);
                    c.soup_websocket_connection_close(conn, @intCast(req.code), if (reason_z) |z| @as([*c]const u8, @ptrCast(z.ptr)) else "");
                    return .{ .ok = true };
                },
            }
        }

        fn wsConnectDone(source: [*c]c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
            const job: *WsConn = @ptrCast(@alignCast(user_data orelse return));
            const self = job.backend;
            var err: [*c]c.GError = null;
            const conn = c.soup_session_websocket_connect_finish(@ptrCast(source), res, &err);
            if (err != null) {
                // GError 的 message 在 g_error_free 后失效 → 先拷贝再释放
                const reason = self.allocator.dupe(u8, std.mem.span(err.*.message)) catch "";
                defer if (reason.len > 0) self.allocator.free(reason);
                log.print("[ws] id={d} connect failed: {s}", .{ job.id, reason });
                c.g_error_free(err);
                self.emitWsEvent(job.id, "error", null, false, reason);
                c.g_object_unref(@ptrCast(job.session));
                self.allocator.destroy(job);
                return;
            }
            job.conn = conn;
            job.msg_handler = c.g_signal_connect_data(@ptrCast(conn), "message", @ptrCast(&wsOnMessage), job, null, 0);
            job.closed_handler = c.g_signal_connect_data(@ptrCast(conn), "closed", @ptrCast(&wsOnClosed), job, null, 0);
            job.error_handler = c.g_signal_connect_data(@ptrCast(conn), "error", @ptrCast(&wsOnError), job, null, 0);
            self.ws_conns.put(self.allocator, job.id, job) catch {};
            log.print("[ws] open id={d}", .{job.id});
            self.emitWsEvent(job.id, "open", null, false, null);
        }

        fn wsOnMessage(_: ?*c.SoupWebsocketConnection, data_type: c.SoupWebsocketDataType, bytes: ?*c.GBytes, user_data: c.gpointer) callconv(.c) void {
            const job: *WsConn = @ptrCast(@alignCast(user_data orelse return));
            const self = job.backend;
            if (bytes == null) return;
            var size: c.gsize = 0;
            const data_ptr = c.g_bytes_get_data(bytes, &size);
            if (data_ptr == null) return;
            const data: [*]const u8 = @ptrCast(data_ptr);
            const raw = data[0..size];
            const binary = data_type != c.SOUP_WEBSOCKET_DATA_TEXT;
            if (!binary and std.unicode.utf8ValidateSlice(raw)) {
                self.emitWsEvent(job.id, "message", raw, false, null);
            } else {
                // 二进制/非法 UTF-8 → base64 + binary 标记
                const encoder = std.base64.standard.Encoder;
                const encoded = self.allocator.alloc(u8, encoder.calcSize(raw.len)) catch return;
                defer self.allocator.free(encoded);
                _ = encoder.encode(encoded, raw);
                self.emitWsEvent(job.id, "message", encoded, true, null);
            }
        }

        fn wsOnClosed(_: ?*c.SoupWebsocketConnection, user_data: c.gpointer) callconv(.c) void {
            const job: *WsConn = @ptrCast(@alignCast(user_data orelse return));
            const self = job.backend;
            log.print("[ws] close id={d}", .{job.id});
            self.emitWsEvent(job.id, "close", null, false, null);
            _ = self.ws_conns.remove(job.id);
            self.freeWsConn(job);
        }

        fn wsOnError(_: ?*c.SoupWebsocketConnection, err: [*c]c.GError, user_data: c.gpointer) callconv(.c) void {
            const job: *WsConn = @ptrCast(@alignCast(user_data orelse return));
            const self = job.backend;
            const reason = if (err != null) std.mem.span(err.*.message) else "error";
            log.print("[ws] error id={d}: {s}", .{ job.id, reason });
            self.emitWsEvent(job.id, "error", null, false, reason);
        }

        fn freeWsConn(self: *Self, job: *WsConn) void {
            if (job.msg_handler != 0 and job.conn != null) c.g_signal_handler_disconnect(@ptrCast(job.conn), job.msg_handler);
            if (job.closed_handler != 0 and job.conn != null) c.g_signal_handler_disconnect(@ptrCast(job.conn), job.closed_handler);
            if (job.error_handler != 0 and job.conn != null) c.g_signal_handler_disconnect(@ptrCast(job.conn), job.error_handler);
            if (job.conn) |conn| c.g_object_unref(@ptrCast(conn));
            if (job.msg) |m| c.g_object_unref(@ptrCast(m)); // connect_async 引用期间由会话持有
            c.g_object_unref(@ptrCast(job.session));
            self.allocator.destroy(job);
        }

        fn emitWsEvent(self: *Self, id: i64, kind: []const u8, data: ?[]const u8, binary: bool, err: ?[]const u8) void {
            const w = self.windowById(0) orelse return;
            const kind_json = jsonStr(self.allocator, kind) orelse return;
            defer self.allocator.free(kind_json);
            const data_json = if (data) |d| (jsonStr(self.allocator, d) orelse return) else self.allocator.dupe(u8, "null") catch return;
            defer self.allocator.free(data_json);
            const err_json = if (err) |e| (jsonStr(self.allocator, e) orelse return) else self.allocator.dupe(u8, "null") catch return;
            defer self.allocator.free(err_json);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"kind\":{s},\"data\":{s},\"binary\":{},\"err\":{s}}}", .{ id, kind_json, data_json, binary, err_json }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(w.id, "wsEvent", payload);
        }

        // ------------------------------------------------------------------
        // 子进程执行（v0.3.0，对齐 Windows v0.1.16 的 runProcOp/procWorker 面）
        // ------------------------------------------------------------------

        /// 一个子进程槽：worker 线程拥有 child/管道读循环；exit 事件后由
        /// UI 线程 join 并释放（与 Windows 的 WM_ZILT_PROC 收尾同构）。
        const ProcSlot = struct {
            backend: *Self,
            id: i64,
            child: std.process.Child = undefined,
            /// 共享 Threaded io（spawn/读管道/wait 都走它）
            threaded: ?*std.Io.Threaded = null,
            worker: std.Thread = undefined,
        };

        /// worker → UI 线程事件（g_idle_add 封送；page_allocator 持有，UI 线程 free）。
        const ProcEventTask = struct {
            backend: *Self,
            ev: *ProcEvent,
        };

        const ProcWhich = enum { stdout, stderr };

        const ProcEvent = struct {
            const Kind = enum { out, exit };
            id: i64,
            kind: Kind,
            which: ProcWhich = .stdout,
            data: ?[]u8 = null,
            code: i64 = 0,
        };

        fn procPostEvent(self: *Self, ev: *ProcEvent) void {
            const task = self.allocator.create(ProcEventTask) catch {
                const a = std.heap.page_allocator;
                if (ev.data) |d| a.free(d);
                a.destroy(ev);
                return;
            };
            task.* = .{ .backend = self, .ev = ev };
            if (c.g_idle_add(procEventIdle, task) == 0) {
                const a = std.heap.page_allocator;
                if (ev.data) |d| a.free(d);
                a.destroy(ev);
                self.allocator.destroy(task);
            }
        }

        fn procEventIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const task: *ProcEventTask = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            const self = task.backend;
            const ev = task.ev;
            defer {
                const a = std.heap.page_allocator;
                if (ev.data) |d| a.free(d);
                a.destroy(ev);
                self.allocator.destroy(task);
            }
            switch (ev.kind) {
                .out => self.emitProcEvent(ev.id, if (ev.which == .stdout) "stdout" else "stderr", ev.data, 0),
                .exit => {
                    self.emitProcEvent(ev.id, "exit", null, ev.code);
                    // exit 事件是槽的终点：join worker + 释放 io（与 Windows 同构）
                    for (self.procs.items, 0..) |p, i| {
                        if (p.id == ev.id) {
                            _ = self.procs.swapRemove(i);
                            p.worker.join();
                            if (p.threaded) |t| {
                                t.deinit();
                                std.heap.page_allocator.destroy(t);
                            }
                            std.heap.page_allocator.destroy(p);
                            break;
                        }
                    }
                },
            }
            return G_SOURCE_REMOVE;
        }

        fn emitProcEvent(self: *Self, id: i64, kind: []const u8, data: ?[]const u8, code: i64) void {
            const w = self.windowById(0) orelse return;
            const kind_json = jsonStr(self.allocator, kind) orelse return;
            defer self.allocator.free(kind_json);
            const payload = if (data) |d| blk: {
                const dj = jsonStr(self.allocator, d) orelse return;
                defer self.allocator.free(dj);
                break :blk std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"kind\":{s},\"data\":{s}}}", .{ id, kind_json, dj }) catch return;
            } else std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"kind\":{s},\"code\":{d}}}", .{ id, kind_json, code }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(w.id, "processEvent", payload);
        }

        /// 单路管道读循环：takeByte 填 4KB 缓冲，满/EOF 时发 out 事件（与 Windows 同构）。
        fn procReadPipe(slot: *ProcSlot, file: std.Io.File, which: ProcWhich) void {
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
                    ev.* = .{ .id = slot.id, .kind = .out, .which = which, .data = a.dupe(u8, chunk[0..n]) catch null };
                    slot.backend.procPostEvent(ev);
                    n = 0;
                }
            }
            if (n > 0) {
                const ev = a.create(ProcEvent) catch return;
                ev.* = .{ .id = slot.id, .kind = .out, .which = which, .data = a.dupe(u8, chunk[0..n]) catch null };
                slot.backend.procPostEvent(ev);
            }
        }

        /// 子进程 worker：spawn → 两路读线程 → join → wait → exit 事件。
        /// spawn 失败也发 exit（code=-1），前端凭 id 收尾（与 Windows 同构）。
        fn procWorker(slot: *ProcSlot, argv: [][]u8, cwd: ?[]u8) void {
            const a = std.heap.page_allocator;
            defer {
                for (argv) |arg| a.free(arg);
                a.free(argv);
                if (cwd) |cw| a.free(cw);
            }

            const threaded = a.create(std.Io.Threaded) catch {
                const ev = a.create(ProcEvent) catch return;
                ev.* = .{ .id = slot.id, .kind = .exit, .code = -1 };
                slot.backend.procPostEvent(ev);
                return;
            };
            threaded.* = .init(a, .{});
            slot.threaded = threaded;
            const io = threaded.io();

            const spawned = std.process.spawn(io, .{
                .argv = argv,
                .cwd = if (cwd) |cw| .{ .path = cw } else .inherit,
                .stdout = .pipe,
                .stderr = .pipe,
            }) catch |e| {
                log.print("[proc] spawn failed id={d}: {s}", .{ slot.id, @errorName(e) });
                const ev = a.create(ProcEvent) catch return;
                ev.* = .{ .id = slot.id, .kind = .exit, .code = -1 };
                slot.backend.procPostEvent(ev);
                return;
            };
            slot.child = spawned;
            log.print("[proc] spawned id={d}", .{slot.id});

            const t1: ?std.Thread = std.Thread.spawn(.{}, procReadPipe, .{ slot, slot.child.stdout.?, @as(ProcWhich, .stdout) }) catch null;
            const t2: ?std.Thread = std.Thread.spawn(.{}, procReadPipe, .{ slot, slot.child.stderr.?, @as(ProcWhich, .stderr) }) catch null;
            if (t1) |t| t.join();
            if (t2) |t| t.join();

            var code: i64 = -1;
            if (slot.child.wait(io)) |term| {
                code = switch (term) {
                    .exited => |cc| @intCast(cc),
                    else => -1,
                };
            } else |_| {}
            const ev = a.create(ProcEvent) catch return;
            ev.* = .{ .id = slot.id, .kind = .exit, .code = code };
            slot.backend.procPostEvent(ev);
            log.print("[proc] exited id={d} code={d}", .{ slot.id, code });
        }

        fn procById(self: *Self, id: i64) ?*ProcSlot {
            for (self.procs.items) |p| {
                if (p.id == id) return p;
            }
            return null;
        }

        /// spawn 受 `shell:` scope 管控（argv[0] basename 去 .exe——与 Windows 同规则）。
        fn procBaseName(arg: []const u8) []const u8 {
            const base = std.fs.path.basename(arg);
            if (std.mem.endsWith(u8, base, ".exe") or std.mem.endsWith(u8, base, ".EXE")) return base[0 .. base.len - 4];
            return base;
        }

        fn runProcOp(self: *Self, op: system_api.ProcessOp, alloc: std.mem.Allocator) !system_api.Result {
            const a = std.heap.page_allocator;
            switch (op) {
                .spawn => |req| {
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
                    const cwd_copy: ?[]u8 = if (req.cwd) |cw| a.dupe(u8, cw) catch null else null;
                    slot.* = .{ .backend = self, .id = req.id };
                    self.procs.append(self.allocator, slot) catch {
                        for (argv_copy) |arg| a.free(arg);
                        a.free(argv_copy);
                        if (cwd_copy) |cw| a.free(cw);
                        a.destroy(slot);
                        return error.OutOfMemory;
                    };
                    const t = std.Thread.spawn(.{ .stack_size = sys.threadStackSize(512 * 1024) }, procWorker, .{ slot, argv_copy, cwd_copy }) catch {
                        for (self.procs.items, 0..) |p, i| {
                            if (p == slot) {
                                _ = self.procs.swapRemove(i);
                                break;
                            }
                        }
                        for (argv_copy) |arg| a.free(arg);
                        a.free(argv_copy);
                        if (cwd_copy) |cw| a.free(cw);
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
                    const pid = slot.child.id orelse return .{ .ok = false };
                    // Linux 无「以指定退出码终止」——SIGKILL 直达，exit 事件给实际码
                    _ = std.c.kill(pid, .KILL);
                    log.print("[proc] kill id={d} (SIGKILL; requested code={d} 不适用)", .{ req.id, req.exit_code });
                    return .{ .ok = true };
                },
                .list => {
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer out.deinit(alloc);
                    try out.append(alloc, '[');
                    for (self.procs.items, 0..) |p, i| {
                        if (i != 0) try out.append(alloc, ',');
                        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"alive\":true}}", .{p.id}));
                    }
                    try out.append(alloc, ']');
                    return .{ .json = try out.toOwnedSlice(alloc) };
                },
            }
        }

        // ------------------------------------------------------------------
        // 应用自定义协议 → 真 scheme（v0.2.3；每协议一个 scheme，URI 形态
        // <name>://<rest>?<query>，对应 Windows 的 /__proto/<name>/<rest>）
        // ------------------------------------------------------------------

        fn registerProtocolSchemes(self: *Self, wc: ?*c.WebKitWebContext) void {
            for (config.protocols) |p| {
                const name_z = dupeZ(self.allocator, p.name) catch continue;
                defer self.allocator.free(name_z);
                c.webkit_web_context_register_uri_scheme(wc, name_z.ptr, Self.onProtocolRequest, self, null);
                log.print("[proto] scheme '{s}' registered", .{p.name});
            }
            // v0.3.10 C2：isolation 隔离 iframe 的独立 scheme（随机 origin）
            if (self.iso_url != null) {
                c.webkit_web_context_register_uri_scheme(wc, "ziltiso", Self.onProtocolRequest, self, null);
                log.print("[iso] scheme 'ziltiso' registered", .{});
            }
        }

        fn onProtocolRequest(request: ?*c.WebKitURISchemeRequest, user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            self.serveProtocol(request);
        }

        fn serveProtocol(self: *Self, request: ?*c.WebKitURISchemeRequest) void {
            const uri_ptr = c.webkit_uri_scheme_request_get_uri(request);
            const uri = if (uri_ptr != null) std.mem.span(uri_ptr) else "";
            const sep = std.mem.indexOf(u8, uri, "://") orelse return self.finishProtocolError(request, 400, "bad uri");
            const name = uri[0..sep];
            // v0.3.10 C2：isolation 隔离 iframe 页面（内嵌 WebCrypto 封装器）
            if (std.mem.eql(u8, name, "ziltiso") and config.isolation != null and self.iso_url != null) {
                const html = iso_mod.iframeHtml(self.allocator, config.isolation.?.key_hex) catch return self.finishProtocolError(request, 500, "iso html");
                defer self.allocator.free(html);
                return self.finishProtocol(request, .{
                    .content_type = "text/html; charset=utf-8",
                    .body = html,
                    .owned = true,
                });
            }
            const p = protocol.find(config.protocols, name) orelse {
                log.print("[proto] '{s}' 未注册 <- {s}", .{ name, uri });
                return self.finishProtocolError(request, 404, "unknown protocol");
            };

            // rest：scheme:// 之后的部分，去掉前导 '/'；query = '?' 之后
            var rest: []const u8 = uri[sep + 3 ..];
            if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
            var path: []const u8 = rest;
            var query: []const u8 = "";
            if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
                path = rest[0..q];
                query = rest[q + 1 ..];
            }

            var method: []const u8 = "GET";
            var user_agent: ?[]const u8 = null;
            const method_ptr = c.webkit_uri_scheme_request_get_http_method(request);
            if (method_ptr != null) method = std.mem.span(method_ptr);
            const headers: ?*c.SoupMessageHeaders = c.webkit_uri_scheme_request_get_http_headers(request);
            if (headers != null) {
                const ua = c.soup_message_headers_get_one(headers, "User-Agent");
                if (ua != null) user_agent = std.mem.span(ua);
            }

            // v0.3.8 B8：请求体——SoupMessageBody 的 data/length 仅在回调内有效
            //（dupe 进 handler 的 arena）；无 body（GET 等）为 null
            var body_raw: ?[]const u8 = null;
            const soup_body = c.webkit_uri_scheme_request_get_http_body(request);
            if (soup_body != null) {
                const sb: *c.SoupMessageBody = @ptrCast(soup_body.?);
                if (sb.length > 0 and sb.data != null) {
                    body_raw = @as([*]const u8, @ptrCast(sb.data))[0..@intCast(sb.length)];
                }
            }
            if (body_raw) |b| log.print("[proto] body {d} bytes head={x}", .{ b.len, b[0..@min(b.len, 16)] });

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_body: ?[]const u8 = if (body_raw) |b| arena.allocator().dupe(u8, b) catch null else null;
            const resp = p.handle(.{
                .name = name,
                .path = path,
                .query = query,
                .method = method,
                .user_agent = user_agent,
                .body = arena_body,
                .url = uri,
            }, arena.allocator()) catch |err| {
                log.print("[proto] {s} handler failed: {s}", .{ name, @errorName(err) });
                return self.finishProtocolError(request, 500, "handler failed");
            };
            log.print("[proto] {s} {s}/{s} {d} bytes", .{ name, method, path, resp.body.len });
            self.finishProtocol(request, resp);
        }

        fn finishProtocol(self: *Self, request: ?*c.WebKitURISchemeRequest, resp: protocol.Response) void {
            const bytes = c.g_bytes_new(resp.body.ptr, resp.body.len);
            if (bytes == null) return;
            defer c.g_bytes_unref(bytes);
            const stream = c.g_memory_input_stream_new_from_bytes(bytes);
            if (stream == null) return;
            defer c.g_object_unref(@ptrCast(stream));

            const response = c.webkit_uri_scheme_response_new(stream, @intCast(resp.body.len));
            if (response == null) return;
            defer c.g_object_unref(@ptrCast(response));

            const ct_z = dupeZ(self.allocator, resp.content_type) catch return;
            defer self.allocator.free(ct_z);
            c.webkit_uri_scheme_response_set_content_type(response, ct_z.ptr);
            if (resp.status != 200) {
                c.webkit_uri_scheme_response_set_status(response, resp.status, protocol.reasonFor(resp.status).ptr);
            }
            // 应用头 + ACAO（自定义 scheme 的 fetch 需要 CORS 允许，Tauri 同款）。
            // set_http_headers 转移所有权（transfer full）——**不能**再 unref。
            const headers = c.soup_message_headers_new(c.SOUP_MESSAGE_HEADERS_RESPONSE);
            if (headers != null) {
                c.soup_message_headers_append(headers, "Access-Control-Allow-Origin", "*");
                c.soup_message_headers_append(headers, "Access-Control-Expose-Headers", "*");
                for (resp.headers) |h| {
                    const name_z = dupeZ(self.allocator, h.name) catch continue;
                    defer self.allocator.free(name_z);
                    const value_z = dupeZ(self.allocator, h.value) catch continue;
                    defer self.allocator.free(value_z);
                    c.soup_message_headers_append(headers, name_z.ptr, value_z.ptr);
                }
                self.applySecurityHeadersRaw(headers);
                c.webkit_uri_scheme_response_set_http_headers(response, headers);
            }
            c.webkit_uri_scheme_request_finish_with_response(request, response);
        }

        fn finishProtocolError(self: *Self, request: ?*c.WebKitURISchemeRequest, status: u16, body: []const u8) void {
            self.finishBytes(request, status, "text/plain; charset=utf-8", body);
        }

        /// applySecurityHeaders 的裸版（headers 已在调用方创建，协议响应复用）。
        fn applySecurityHeadersRaw(self: *Self, headers: ?*c.SoupMessageHeaders) void {
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

            // v0.3.10 C2：isolation 启用时解封 sealed invoke
            var decoded = if (self.iso_key) |k| try ipc.decodeIsolated(self.allocator, raw, k) else try ipc.decode(self.allocator, raw);
            defer decoded.deinit();

            const enforce_acl = config.security.capabilities.len != 0;
            const source = currentUri(sink.view, w.app_url);

            switch (decoded.msg) {
                .invoke => |inv| {
                    log.print("[ipc] invoke {s} (id={d}, window={d}, sealed={s})", .{ inv.method, inv.id, w.id, boolStr(inv.seal != null) });
                    // v0.3.10 C2：isolation 启用时——明文 invoke 拒绝（伪造防护），
                    // 签名不符/重放拒绝（IsoTampered）
                    if (self.iso_key != null) {
                        const ok_seal = blk2: {
                            const seal = inv.seal orelse break :blk2 false;
                            break :blk2 iso_mod.verifyJson(&self.iso_cache, self.iso_key.?, seal.nonce_hex, inv.method, inv.args_json, seal.sig_hex);
                        };
                        if (!ok_seal) {
                            const err_name: []const u8 = if (inv.seal == null) "IsolationRequired" else "IsoTampered";
                            log.print("[iso] invoke rejected ({s}) id={d} method={s} args={s} nonce={s} sig={s}", .{
                                err_name,                inv.id,
                                inv.method,              inv.args_json,
                                if (inv.seal) |sl| sl.nonce_hex else "",
                                if (inv.seal) |sl| sl.sig_hex else "",
                            });
                            const rej = try ipc.encodeReject(self.allocator, inv.id, err_name);
                            defer self.allocator.free(rej);
                            self.deliverAlloc(sink.view, rej);
                            const id_json = std.fmt.allocPrint(self.allocator, "{d}", .{inv.id}) catch return;
                            defer self.allocator.free(id_json);
                            const ev = std.fmt.allocPrint(self.allocator, "{{\"id\":{s}}}", .{id_json}) catch return;
                            defer self.allocator.free(ev);
                            self.emitRawToWindow(w.id, "__zilt.isoRejected", ev);
                            return;
                        }
                    }

                    // 框架内部：冒烟结果回传（不经过应用命令表，也不受 ACL 约束）
                    if (std.mem.eql(u8, inv.method, "__zilt.linuxSmoke")) {
                        self.finishSmoke(inv.args_json);
                        return;
                    }
                    // 框架内部：冒烟的拖放模拟——invoke 先 resolve，事件在下一拍
                    // 经 g_idle_add 投递（保证前端监听器已就位）
                    if (std.mem.eql(u8, inv.method, "__zilt.linuxSmokeDrop")) {
                        self.smoke_drop_sent = true;
                        log.print("[dnd] simulated drop (smoke, via invoke)", .{});
                        _ = c.g_idle_add(smokeDropIdle, self);
                        const resp = try ipc.encodeResolve(self.allocator, inv.id, "\"queued\"");
                        defer self.allocator.free(resp);
                        self.deliverAlloc(sink.view, resp);
                        return;
                    }
                    // 框架内部：v0.3.9 A4L 冒烟探针——XSendEvent 注入 KeyPress（真实
                    // GDK key-press 路径：注入 → handler 匹配 → windowKeyBinding 事件）
                    if (std.mem.eql(u8, inv.method, "__zilt.linuxSmokeKeyBind")) {
                        self.smokeKeyBindInject(inv.args_json);
                        const resp = try ipc.encodeResolve(self.allocator, inv.id, "\"sent\"");
                        defer self.allocator.free(resp);
                        self.deliverAlloc(sink.view, resp);
                        return;
                    }
                    // v0.4.3 L6：托盘挂窗冒烟探针（toggle → 可见性/位置回传）
                    if (std.mem.eql(u8, inv.method, "__zilt.linuxSmokeAttach")) {
                        self.smokeAttachInject();
                        const resp_at = try ipc.encodeResolve(self.allocator, inv.id, "\"sent\"");
                        defer self.allocator.free(resp_at);
                        self.deliverAlloc(sink.view, resp_at);
                        return;
                    }
                    // 框架内部：冒烟探针——v0.3.0 桌面体验面是否接线 + 会话有无 WM
                    //（windowMoved/Resized/Focus 需要 WM；Xvfb 裸跑跳过断言）
                    if (std.mem.eql(u8, inv.method, "__zilt.linuxSmokeWired")) {
                        const body = try std.fmt.allocPrint(self.allocator, "{{\"context_menu\":{s},\"script_dialog\":{s},\"wm\":{s}}}", .{
                            boolStr(self.context_menu_wired),
                            boolStr(self.script_dialog_wired),
                            boolStr(self.wm_present),
                        });
                        defer self.allocator.free(body);
                        const resp = try ipc.encodeResolve(self.allocator, inv.id, body);
                        defer self.allocator.free(resp);
                        self.deliverAlloc(sink.view, resp);
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
                            log.print("[ipc] builtin {s} failed: {s} (args={s})", .{ inv.method, @errorName(err), inv.args_json[0..@min(inv.args_json.len, 200)] });
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

        fn reject(self: *Self, view: ?*c.WebKitWebView, id: u64, err_name: []const u8) void {
            const resp = ipc.encodeReject(self.allocator, id, err_name) catch return;
            defer self.allocator.free(resp);
            self.deliverAlloc(view, resp);
        }

        /// 页面加载完成后自检：runtime_js 是否注入、messageHandlers 是否注册。
        /// 这两项任一为 false，前端所有 invoke 都会静默失败——所以显式记一行日志。
        fn diagnoseRuntime(self: *Self, view: ?*c.WebKitWebView) void {
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
            const view: ?*c.WebKitWebView = @ptrCast(source);
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

        fn onLoadChanged(_: ?*c.WebKitWebView, event: c.WebKitLoadEvent, user_data: c.gpointer) callconv(.c) void {
            if (event != c.WEBKIT_LOAD_FINISHED) return;
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return));
            const self = sink.backend;
            if (self.windowById(sink.win_id)) |w| w.loaded = true;
            self.diagnoseRuntime(sink.view);
            // 启动深链兜底：页面就绪后补发（窗口未就绪时 handleLaunchArgs 挂起的载荷）
            self.flushPendingLaunch();
        }

        // ------------------------------------------------------------------
        // v0.2.7：导航策略 / 新窗口策略 / 权限请求 / 渲染进程终止
        // （对齐 Windows v0.1.9 的 driver 面；只挂主 WebView——子 WebView 不挂
        // driver，与 Windows 的「child webview 不挂 driver」边界一致）
        // ------------------------------------------------------------------

        /// webview.* 事件的载荷拼装（url 等字符串经 jsonStr 转义）。
        fn emitWebViewJson(self: *Self, win_id: u32, name: []const u8, payload: []const u8) void {
            self.emitRawToWindow(win_id, name, payload);
        }

        /// 外部 URL（system_browser 策略）→ xdg-open（分离拉起）。
        fn openExternalUrl(url: []const u8) void {
            if (!security.isWebUrl(url)) return;
            const ok = spawnDetachedLinux(&.{ "xdg-open", url });
            log.print("[webview] external url -> xdg-open ({s})", .{boolStr(ok)});
        }

        /// 导航策略判定（v0.2.7）：应用自有 scheme（zilt://，mapAppUrl 后的加载
        /// 形态）与内联 scheme（data:/blob:/about:）一律放行——security.navigation
        /// 只认 http(s)，不判它们会把应用初始加载拦死、把 `<a download>` 的
        /// data: 下载拦掉（两者均实测）；其余走共享 security.navigation
        /// （config.url 为应用 origin，与 Windows driverNavigation 同参）。
        fn navigationPolicyFor(url: []const u8) security.ExternalLinks {
            if (std.mem.startsWith(u8, url, scheme ++ "://")) return .allow;
            inline for (.{ "data:", "blob:", "about:" }) |pfx| {
                if (std.mem.startsWith(u8, url, pfx)) return .allow;
            }
            return security.navigation(config.security, config.url, null, url);
        }

        /// decide-policy：导航动作走 navigationPolicyFor 三态；新窗口动作走
        /// config.webview.new_window 三态；响应放行（下载走 download-started）。
        /// translate-c 把 WebKitPolicyDecisionType 变成 c_uint → 用 if 链比较。
        fn onDecidePolicy(
            _: ?*c.WebKitWebView,
            decision: ?*c.WebKitPolicyDecision,
            dtype: c.WebKitPolicyDecisionType,
            user_data: c.gpointer,
        ) callconv(.c) c.gboolean {
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return 0));
            const self = sink.backend;
            const d = decision orelse return 0;
            if (dtype == c.WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
                const npd: *c.WebKitNavigationPolicyDecision = @ptrCast(@alignCast(d));
                const action = c.webkit_navigation_policy_decision_get_navigation_action(npd);
                const req = if (action != null) c.webkit_navigation_action_get_request(action) else null;
                const uri_raw = if (req != null) c.webkit_uri_request_get_uri(req) else null;
                if (uri_raw == null) return 0;
                const url = std.mem.span(uri_raw);
                // v0.3.10 C2：isolation 隔离 iframe 的导航（ziltiso://<random>/）放行
                if (self.iso_url != null and std.mem.startsWith(u8, url, "ziltiso://")) {
                    c.webkit_policy_decision_use(d);
                    return 1;
                }
                const policy = navigationPolicyFor(url);
                const redirected = c.webkit_navigation_action_is_redirect(action) != 0;
                if (jsonStr(self.allocator, url)) |uj| {
                    defer self.allocator.free(uj);
                    const payload = std.fmt.allocPrint(self.allocator,
                        "{{\"url\":{s},\"id\":0,\"redirected\":{},\"policy\":\"{s}\"}}",
                        .{ uj, redirected, @tagName(policy) },
                    ) catch null;
                    if (payload) |p| {
                        defer self.allocator.free(p);
                        self.emitWebViewJson(sink.win_id, webview.Event.navigation_starting, p);
                    }
                }
                log.print("[nav] {s} -> {s}", .{ url, @tagName(policy) });
                switch (policy) {
                    .allow => c.webkit_policy_decision_use(d),
                    // system_browser/deny 都拦截导航；前者另行交给系统处理程序
                    .system_browser => {
                        c.webkit_policy_decision_ignore(d);
                        openExternalUrl(url);
                    },
                    .deny => c.webkit_policy_decision_ignore(d),
                }
                return 1;
            }
            if (dtype == c.WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
                const npd: *c.WebKitNavigationPolicyDecision = @ptrCast(@alignCast(d));
                const action = c.webkit_navigation_policy_decision_get_navigation_action(npd);
                const req = if (action != null) c.webkit_navigation_action_get_request(action) else null;
                const uri_raw = if (req != null) c.webkit_uri_request_get_uri(req) else null;
                const url = if (uri_raw != null) std.mem.span(uri_raw) else "";
                const policy = config.webview.new_window;
                if (jsonStr(self.allocator, url)) |uj| {
                    defer self.allocator.free(uj);
                    const payload = std.fmt.allocPrint(self.allocator,
                        "{{\"url\":{s},\"policy\":\"{s}\"}}",
                        .{ uj, @tagName(policy) },
                    ) catch null;
                    if (payload) |p| {
                        defer self.allocator.free(p);
                        self.emitWebViewJson(sink.win_id, webview.Event.new_window, p);
                    }
                }
                log.print("[new-window] {s} -> {s}", .{ url, @tagName(policy) });
                switch (policy) {
                    .deny => c.webkit_policy_decision_ignore(d),
                    .external => {
                        c.webkit_policy_decision_ignore(d);
                        if (url.len != 0) openExternalUrl(url);
                    },
                    .new_window => {
                        c.webkit_policy_decision_ignore(d);
                        if (url.len != 0) self.spawnPolicyWindow(url);
                    },
                }
                return 1;
            }
            // RESPONSE：放行（下载走 download-started 通道，v0.2.1）
            c.webkit_policy_decision_use(d);
            return 0;
        }

        /// new_window 策略命中 → 建新 Zilt 窗口（对齐 Windows driverNewWindow：
        /// 独立 label，复用 createWindowInternal 的全部接线）。
        fn spawnPolicyWindow(self: *Self, url: []const u8) void {
            const label = std.fmt.allocPrint(self.allocator, "webview-{d}", .{self.next_window_id}) catch return;
            defer self.allocator.free(label);
            const id = self.createWindowInternal(.{
                .label = label,
                .title = "Zilt Window",
                .url = url,
                .width = config.width,
                .height = config.height,
            }) catch |err| {
                log.print("[new-window] spawn failed: {s}", .{@errorName(err)});
                return;
            };
            log.print("[new-window] window #{d} -> {s}", .{ id.id, url });
        }

        /// `create` 信号：默认弹窗一律不建（策略已在 decide-policy 处理——
        /// ignore 后不会走到这里；兜底返回 NULL 阻断 WebKit 自建窗口）。
        fn onCreate(
            _: ?*c.WebKitWebView,
            _: ?*c.WebKitNavigationAction,
            _: c.gpointer,
        ) callconv(.c) ?*c.WebKitWebView {
            return null;
        }

        /// permission-request：GType 反查 → 共享 PermissionKind → config 策略。
        /// ask 在冒烟模式直接拒绝（无交互；桌面弹原生询问框），事件 payload
        /// {url,kind,policy} 与 Windows 同形（WebKitGTK 拿不到发起 URL → 空串）。
        fn onPermissionRequest(
            _: ?*c.WebKitWebView,
            request: ?*c.WebKitPermissionRequest,
            user_data: c.gpointer,
        ) callconv(.c) c.gboolean {
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return 0));
            const self = sink.backend;
            const req = request orelse return 0;
            const kind = permissionKindOf(req);
            const policy = config.webview.permissions.policy(kind);
            var resolved = policy;
            if (policy == .ask) {
                resolved = if (self.smoke) .deny else permissionAskDialog(self, sink.win_id, kind);
            }
            switch (resolved) {
                .allow => c.webkit_permission_request_allow(req),
                else => c.webkit_permission_request_deny(req),
            }
            const payload = std.fmt.allocPrint(self.allocator,
                "{{\"url\":\"\",\"kind\":\"{s}\",\"policy\":\"{s}\"}}",
                .{ @tagName(kind), @tagName(policy) },
            ) catch return 1;
            defer self.allocator.free(payload);
            self.emitWebViewJson(sink.win_id, webview.Event.permission, payload);
            log.print("[permission] {s} -> {s}", .{ @tagName(kind), @tagName(policy) });
            return 1;
        }

        /// GType 反查 WebKitGTK 权限类型 → 共享 PermissionKind（未知 → .unknown，
        /// 共享默认策略是 deny）。
        fn permissionKindOf(req: *c.WebKitPermissionRequest) webview.PermissionKind {
            const obj: *c.GObject = @ptrCast(@alignCast(req));
            if (c.g_type_check_instance_is_a(@ptrCast(obj), c.webkit_user_media_permission_request_get_type()) != 0) {
                const um: *c.WebKitUserMediaPermissionRequest = @ptrCast(@alignCast(req));
                if (c.webkit_user_media_permission_is_for_video_device(um) != 0) return .camera;
                if (c.webkit_user_media_permission_is_for_audio_device(um) != 0) return .microphone;
                return .unknown;
            }
            if (c.g_type_check_instance_is_a(@ptrCast(obj), c.webkit_geolocation_permission_request_get_type()) != 0) return .location;
            if (c.g_type_check_instance_is_a(@ptrCast(obj), c.webkit_notification_permission_request_get_type()) != 0) return .notifications;
            if (c.g_type_check_instance_is_a(@ptrCast(obj), c.webkit_clipboard_permission_request_get_type()) != 0) return .clipboard;
            return .unknown;
        }

        /// ask 策略的原生询问框（模态；嵌套泵与 cookies/eval 同手法）。
        /// 返回 allow/deny；窗口缺失（子页面场景）直接 deny。
        fn permissionAskDialog(self: *Self, win_id: u32, kind: webview.PermissionKind) webview.PermissionPolicy {
            const w = self.windowById(win_id) orelse return .deny;
            const phrase: []const u8 = switch (kind) {
                .camera => "use the camera",
                .microphone => "use the microphone",
                .location => "access your location",
                .clipboard => "read the clipboard",
                .notifications => "show notifications",
                .other_sensors => "access device sensors",
                .unknown => "access a device capability",
            };
            const parent: [*c]c.GtkWindow = @ptrCast(w.win);
            const text = std.fmt.allocPrintSentinel(self.allocator, "Allow this page to {s}?", .{phrase}, 0) catch return .deny;
            defer self.allocator.free(text);
            const dialog = c.gtk_message_dialog_new(
                parent,
                c.GTK_DIALOG_MODAL,
                c.GTK_MESSAGE_QUESTION,
                c.GTK_BUTTONS_YES_NO,
                "%s",
                text.ptr,
            );
            if (dialog == null) return .deny;
            var st = PermissionDialogState{ .loop = c.g_main_loop_new(null, 0), .allowed = false };
            defer if (st.loop) |l| c.g_main_loop_unref(l);
            _ = c.g_signal_connect_data(
                dialog,
                "response",
                @ptrCast(&Self.permissionDialogResponse),
                @ptrCast(&st),
                null,
                0,
            );
            c.gtk_widget_show(dialog);
            c.g_main_loop_run(st.loop.?);
            gtk_compat.destroyDialog(@ptrCast(@alignCast(dialog)));
            return if (st.allowed) .allow else .deny;
        }

        /// 权限询问框的会话状态（对话框/嵌套泵/结果）；栈上分配——嵌套泵
        /// 运行期间本栈帧存活，信号回调直接借用。
        const PermissionDialogState = struct {
            loop: ?*c.GMainLoop,
            allowed: bool,
        };

        fn permissionDialogResponse(
            _: [*c]c.GtkDialog,
            response_id: c.gint,
            user_data: c.gpointer,
        ) callconv(.c) void {
            const st: *PermissionDialogState = @ptrCast(@alignCast(user_data orelse return));
            st.allowed = response_id == c.GTK_RESPONSE_YES;
            if (st.loop) |l| c.g_main_loop_quit(l);
        }

        /// web-process-terminated：发 process_failed（kind = WebKit reason 0/1/2）
        /// + 自动恢复（对齐 Windows recover_renderer：crashed/exceeded_memory →
        /// reload；terminated_by_api 是主动调用 → 不恢复）。
        fn onWebProcessTerminated(
            view: ?*c.WebKitWebView,
            reason: c.WebKitWebProcessTerminationReason,
            user_data: c.gpointer,
        ) callconv(.c) void {
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return));
            const self = sink.backend;
            // translate-c 把 WebKitWebProcessTerminationReason 变成 c_uint
            const kind: i64 = @intCast(reason);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"kind\":{d}}}", .{kind}) catch return;
            defer self.allocator.free(payload);
            self.emitWebViewJson(sink.win_id, webview.Event.process_failed, payload);
            log.print("[webview] web process terminated (reason={d})", .{kind});
            // 冒烟后置闭环：终止信号到达即 PASS → 退出（不 reload——重载页面会把
            // 整套冒烟再跑一遍，与 1.5s 退出窗口竞态，实测踩到）
            if (self.terminate_check and !self.terminate_seen) {
                self.terminate_seen = true;
                log.print("[linux-smoke] post terminate-check PASS (reason={d})", .{kind});
                self.requestQuit();
                return;
            }
            if (reason != c.WEBKIT_WEB_PROCESS_TERMINATED_BY_API and config.webview.recover_renderer) {
                // 进程刚终止：reload 放到 idle 下一拍（避免与终止处理竞态）
                const task = self.allocator.create(CrashReloadTask) catch return;
                task.* = .{ .backend = self, .view = view };
                if (c.g_idle_add(crashReloadIdle, task) == 0) self.allocator.destroy(task);
            }
        }

        const CrashReloadTask = struct {
            backend: *Self,
            view: ?*c.WebKitWebView,
        };

        fn crashReloadIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const task: *CrashReloadTask = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            defer task.backend.allocator.destroy(task);
            const w = task.backend.windowByView(task.view) orelse return G_SOURCE_REMOVE;
            log.print("[webview] auto reload after process termination (window #{d})", .{w.id});
            c.webkit_web_view_reload(w.view);
            return G_SOURCE_REMOVE;
        }

        /// 由 WebView 指针反查窗口状态（崩溃恢复 idle 回调用）。
        fn windowByView(self: *Self, view: ?*c.WebKitWebView) ?*WinState {
            for (self.windows.items) |w| {
                if (w.view == view) return w;
            }
            return null;
        }

        // ------------------------------------------------------------------
        // 拖放（v0.2.2）：文件拖入 → dropFiles {files}
        // ------------------------------------------------------------------

        /// v0.3.0：WebView 右键菜单接管。返回 TRUE 阻止 WebKit 默认菜单
        ///（context_menus=false；应用可经既有 menu.popup 自绘）。
        fn onContextMenu(
            _: ?*c.WebKitWebView,
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: ?*anyopaque,
            user_data: c.gpointer,
        ) callconv(.c) c.gboolean {
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return 0));
            _ = sink;
            return if (config.webview.settings.context_menus) 0 else 1;
        }

        /// v0.3.0：脚本对话框接管（alert/confirm/prompt/beforeunload）。
        /// - `settings.script_dialogs=false` → 阻止原生模态框；
        /// - 冒烟模式一律阻止（无交互环境，模态框会卡死主循环）→ 默认应答。
        fn onScriptDialog(
            _: ?*c.WebKitWebView,
            dialog: ?*anyopaque,
            user_data: c.gpointer,
        ) callconv(.c) c.gboolean {
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return 0));
            if (config.webview.settings.script_dialogs and !sink.backend.smoke) return 0;
            if (dialog) |d| {
                const sd: *c.WebKitScriptDialog = @ptrCast(@alignCast(d));
                const kind = c.webkit_script_dialog_get_dialog_type(sd);
                if (kind == c.WEBKIT_SCRIPT_DIALOG_CONFIRM or kind == c.WEBKIT_SCRIPT_DIALOG_BEFORE_UNLOAD_CONFIRM) {
                    c.webkit_script_dialog_confirm_set_confirmed(sd, 0);
                } else if (kind == c.WEBKIT_SCRIPT_DIALOG_PROMPT) {
                    c.webkit_script_dialog_prompt_set_text(sd, "");
                }
            }
            log.print("[webview] script dialog suppressed (window #{d})", .{sink.win_id});
            return 1;
        }

        /// drag-drop：取数据（uri-list 优先）后返回 TRUE，拦截 WebKit 默认导航。
        fn onDragDrop(
            _: [*c]c.GtkWidget,
            drag_ctx: ?*c.GdkDragContext,
            _: c.gint,
            _: c.gint,
            time: c.guint,
            user_data: c.gpointer,
        ) callconv(.c) c.gboolean {
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return 0));
            const widget: [*c]c.GtkWidget = @ptrCast(sink.view);
            const target = c.gtk_drag_dest_find_target(widget, drag_ctx, null);
            if (target == null) {
                c.gtk_drag_finish(drag_ctx, 0, 0, time);
                return 1;
            }
            c.gtk_drag_get_data(widget, drag_ctx, target, time);
            return 1;
        }

        /// drag-data-received：解析 selection 数据（text/uri-list）→ dropFiles。
        fn onDragDataReceived(
            _: [*c]c.GtkWidget,
            drag_ctx: ?*c.GdkDragContext,
            _: c.gint,
            _: c.gint,
            data: ?*c.GtkSelectionData,
            _: c.guint,
            time: c.guint,
            user_data: c.gpointer,
        ) callconv(.c) void {
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return));
            const self = sink.backend;
            defer c.gtk_drag_finish(drag_ctx, 1, 0, time);
            if (data == null) return;
            const len: usize = @intCast(c.gtk_selection_data_get_length(data));
            if (len == 0) return;
            const raw_ptr = c.gtk_selection_data_get_data(data);
            if (raw_ptr == null) return;
            self.handleDropUris(sink.win_id, raw_ptr[0..len]);
        }

        /// uri-list → dropFiles 事件（冒烟的模拟投递同走这里）。
        fn handleDropUris(self: *Self, win_id: u32, uri_list: []const u8) void {
            const paths = parseDropUris(self.allocator, uri_list) catch return;
            defer {
                for (paths) |p| self.allocator.free(p);
                self.allocator.free(paths);
            }
            if (paths.len == 0) return;
            log.print("[dnd] drop on window #{d} ({d} files)", .{ win_id, paths.len });
            var payload: std.ArrayListUnmanaged(u8) = .empty;
            defer payload.deinit(self.allocator);
            payload.appendSlice(self.allocator, "{\"files\":[") catch return;
            for (paths, 0..) |p, i| {
                if (i != 0) payload.append(self.allocator, ',') catch return;
                const pj = jsonStr(self.allocator, p) orelse return;
                defer self.allocator.free(pj);
                payload.appendSlice(self.allocator, pj) catch return;
            }
            payload.appendSlice(self.allocator, "]}") catch return;
            self.emitRawToWindow(win_id, "dropFiles", payload.items);
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
            // 终止后重载页面会把整套冒烟重跑一遍（实测）——只认首轮结果
            if (self.smoke_finished) return;
            self.smoke_finished = true;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), args_json, .{}) catch {
                log.print("[linux-smoke] FAILED to parse result: {s}", .{args_json});
                self.smoke_code = 1;
                return self.requestQuit();
            };
            if (parsed != .object) {
                self.smoke_code = 1;
                return self.requestQuit();
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
            // E2E 辅助：主实例保持存活若干秒，供第二实例转交深链
            //（ZILT_LINUX_SMOKE_STAY=<秒>，超时后自行退出，退出码仍按检查结果）
            if (self.smoke_stay > 0) {
                log.print("[linux-smoke] staying alive {d}s (second-instance window)", .{self.smoke_stay});
                _ = c.g_timeout_add_seconds(self.smoke_stay, stayQuit, self);
                return;
            }
            // v0.2.7 后置闭环：前端检查全过后，Zig 侧主动终止 web process →
            // 断言 web-process-terminated 信号 + process_failed 事件链路 → reload
            // 恢复 → 退出（渲染进程死亡无法被前端断言——JS 上下文随进程一起没了）
            if (ok) {
                log.print("[linux-smoke] post: web process terminate check", .{});
                self.terminate_check = true;
                _ = c.g_timeout_add_seconds(6, smokeTerminateTimeout, self);
                if (self.windowById(1)) |w| {
                    c.webkit_web_view_terminate_web_process(w.view);
                }
                return; // 退出由 onWebProcessTerminated / 超时承担
            }
            self.requestQuit();
        }

        /// 后置闭环的失败兜底：6 秒内未见终止信号 → FAIL + 退出。
        fn smokeTerminateTimeout(user_data: c.gpointer) callconv(.c) c.gboolean {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return G_SOURCE_REMOVE));
            if (self.terminate_seen) return G_SOURCE_REMOVE;
            log.print("[linux-smoke] post terminate-check FAIL (no web-process-terminated signal)", .{});
            self.smoke_code = 1;
            self.requestQuit();
            return G_SOURCE_REMOVE;
        }

        fn stayQuit(user_data: c.gpointer) callconv(.c) c.gboolean {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return G_SOURCE_REMOVE));
            log.print("[linux-smoke] stay window over -> quit", .{});
            self.requestQuit();
            return G_SOURCE_REMOVE;
        }

        /// 冒烟的拖放模拟投递（idle 下一拍；见 handleMessage 的 __zilt.linuxSmokeDrop）。
        fn smokeDropIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const self: *Self = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            self.handleDropUris(1, "file:///tmp/zilt-smoke-a.txt\r\nfile:///tmp/zilt-smoke-b.txt\r\n");
            return G_SOURCE_REMOVE;
        }

        fn currentUri(view: ?*c.WebKitWebView, fallback: []const u8) []const u8 {
            if (view == null) return fallback;
            const uri = c.webkit_web_view_get_uri(view);
            if (uri == null) return fallback;
            return std.mem.span(uri);
        }

        // ------------------------------------------------------------------
        // scheme 资产服务
        // ------------------------------------------------------------------

        fn serveScheme(self: *Self, request: ?*c.WebKitURISchemeRequest) void {
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

        fn finishPlain(self: *Self, request: ?*c.WebKitURISchemeRequest, status: u16, body: []const u8) void {
            self.finishBytes(request, status, "text/plain; charset=utf-8", body);
        }

        fn finishBytes(
            self: *Self,
            request: ?*c.WebKitURISchemeRequest,
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
        fn applySecurityHeaders(self: *Self, response: ?*c.WebKitURISchemeResponse) void {
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
            // v0.3.14：windowDestroyed 事件对齐 Windows 契约（发给其余存活窗口；
            // destroy 回调内直接 evaluate 会被丢弃——走 emitWindowEvent 的 idle 封送。
            // 级联子窗口由其自身 onDestroy 重入补发）
            for (self.windows.items) |other| {
                if (other.id == closed_id) continue;
                self.emitWindowEvent(other, "windowDestroyed", &.{.{ .name = "id", .value = closed_id }});
            }
            // 先落盘窗口状态（destroy 期间控件仍在，几何可查）
            self.saveWindowState(st);
            self.freeWindowState(st);
            // 父销毁级联关子窗口（子窗口的 destroy 会重入本回调并自行摘除）
            while (self.findWindowByParent(closed_id)) |child| {
                log.print("[linux] cascade close window #{d} (parent #{d} gone)", .{ child.id, closed_id });
                gtk_compat.windowDestroy(child.win);
            }
            // 全部窗口都销毁才退出主循环（primary / 降级两种主循环形态统一走这里）
            if (self.windows.items.len == 0) {
                log.print("[linux] all windows destroyed -> quit main loop", .{});
                self.requestQuit();
            }
        }

        /// v0.3.1：启动 10s 后清理 `.zilt-old`（健康确认；与 Windows WM_TIMER id=3 同语义）。
        fn healthConfirmIdle(user_data: c.gpointer) callconv(.c) c.gboolean {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return G_SOURCE_REMOVE));
            const exe = currentExePathLinux(self.allocator) catch return G_SOURCE_REMOVE;
            defer self.allocator.free(exe);
            updater.cleanupOld(self.allocator, exe);
            log.print("[updater] health confirmed, backup cleaned", .{});
            return G_SOURCE_REMOVE;
        }

        /// v0.3.0：map 后补一次恢复几何的 move（openbox 等 reparent 型 WM 实测
        /// 会忽略窗口 map 之前的 gtk_window_move，恢复位置退化成 0,0）。
        /// 只补一次：之后用户拖动/程序移动不再被覆盖。
        fn onMapRestore(user_data: c.gpointer) callconv(.c) c.gboolean {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return 0));
            if (!st.restored_geometry) return 0;
            st.restored_geometry = false;
            gtk_compat.windowMove(st.win, st.restored_x, st.restored_y);
            st.geom_x = st.restored_x;
            st.geom_y = st.restored_y;
            log.print("[state] re-applied restored position {d},{d} after map (window #{d})", .{
                st.restored_x, st.restored_y, st.id,
            });
            return 0;
        }

        /// configure-event：跟踪窗口几何（destroy 时保存窗口状态用）。
        /// 返回 FALSE 表示继续传播给 GTK 默认处理。
        /// 注意：translate-c 里 `GdkEvent` 是不透明 union，信号参数只能按
        /// `?*anyopaque` 接、再转成具体的 GdkEventConfigure。
        /// v0.3.3：窗口形状 mask（PNG 资产 alpha>8 → cairo region；input+visual shape）。
        fn applyWindowMask(alloc: std.mem.Allocator, st: *WinState, mask_path: []const u8) void {
            const bytes = assetBytesFor(mask_path) orelse {
                log.print("[mask] asset '{s}' not found (mask ignored)", .{mask_path});
                return;
            };
            const img = shared_png.decode(alloc, bytes) catch |err| {
                log.print("[mask] decode '{s}' failed: {s}", .{ mask_path, @errorName(err) });
                return;
            };
            defer alloc.free(img.pixels);
            const region = c.cairo_region_create() orelse return;
            defer c.cairo_region_destroy(@ptrCast(region));
            const threshold: u8 = 8;
            var y: u32 = 0;
            while (y < img.height) : (y += 1) {
                var x: u32 = 0;
                while (x < img.width) {
                    if (img.pixels[(y * img.width + x) * 4 + 3] > threshold) {
                        const start = x;
                        while (x < img.width and img.pixels[(y * img.width + x) * 4 + 3] > threshold) x += 1;
                        var rect = c.cairo_rectangle_int_t{
                            .x = @intCast(start),
                            .y = @intCast(y),
                            .width = @intCast(x - start),
                            .height = 1,
                        };
                        _ = c.cairo_region_union_rectangle(@ptrCast(region), &rect);
                    } else {
                        x += 1;
                    }
                }
            }
            const widget: [*c]c.GtkWidget = @ptrCast(st.win);
            if (comptime gtk_compat.isGtk4()) {
                // GDK4 无 shape API → X11 直连（XShape）；Wayland 无对等 → skip
                if (!gtk_compat.applySurfaceMask(widget, region)) {
                    log.print("[mask] shape unsupported on this display backend (mask skipped)", .{});
                    return;
                }
                log.print("[mask] applied '{s}' ({d}x{d})", .{ mask_path, img.width, img.height });
                return;
            }
            const gdk_win = c.gtk_widget_get_window(widget) orelse {
                log.print("[mask] window not realized yet (mask deferred unsupported)", .{});
                return;
            };
            c.gdk_window_shape_combine_region(gdk_win, @ptrCast(region), 0, 0);
            c.gdk_window_input_shape_combine_region(gdk_win, @ptrCast(region), 0, 0);
            log.print("[mask] applied '{s}' ({d}x{d})", .{ mask_path, img.width, img.height });
        }

        fn assetBytesFor(path: []const u8) ?[]const u8 {
            for (config.assets) |asset| {
                if (std.mem.eql(u8, asset.path, path)) return asset.content;
            }
            return null;
        }

        /// v0.3.3：窗口位置夹取工作区（preventOverflow；configure-event 时机）。
        fn clampToWorkArea(st: *WinState) void {
            if (!st.prevent_overflow or st.win == null) return;
            const widget: [*c]c.GtkWidget = @ptrCast(st.win);
            const mon_any = gtk_compat.monitorAtSurface(widget) orelse return;
            const mon: ?*c.GdkMonitor = @ptrCast(@alignCast(mon_any));
            var work: c.GdkRectangle = std.mem.zeroes(c.GdkRectangle);
            gtk_compat.monitorWorkarea(mon, &work);
            var x: c.gint = 0;
            var y: c.gint = 0;
            gtk_compat.windowGetPosition(st.win, &x, &y);
            var w: c.gint = 0;
            var h: c.gint = 0;
            gtk_compat.windowGetSize(st.win, &w, &h);
            const max_x = @max(work.x, work.x + work.width - w);
            const max_y = @max(work.y, work.y + work.height - h);
            const cx = @min(@max(x, work.x), max_x);
            const cy = @min(@max(y, work.y), max_y);
            if (cx != x or cy != y) gtk_compat.windowMove(st.win, cx, cy);
        }

        fn onConfigureEvent(_: [*c]c.GtkWidget, event: ?*anyopaque, user_data: c.gpointer) callconv(.c) c.gboolean {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return 0));
            const cfg: [*c]c.GdkEventConfigure = @ptrCast(@alignCast(event orelse return 0));
            if (cfg.*.width > 0 and cfg.*.height > 0) {
                Self.syncGeometry(st, cfg.*.x, cfg.*.y, @intCast(cfg.*.width), @intCast(cfg.*.height));
            }
            return 0;
        }

        /// 窗口事件的字段发射器（小而固定的 payload；数值直出、无字符串转义）。
        const WinEventField = WindowEventField;

        fn emitWindowEvent(self: *Self, st: *WinState, name: []const u8, fields: []const WinEventField) void {
            // 经 idle 封送：本函数在 script-message 回调（invoke 处理）内触发，
            // 回调里直接 evaluate_javascript 实测会被丢弃（与 emitEntry 同理）
            const task = self.allocator.create(WindowEventTask) catch return;
            const name_copy = self.allocator.dupe(u8, name) catch {
                self.allocator.destroy(task);
                return;
            };
            const payload = windowEventPayloadJson(self.allocator, fields) catch {
                self.allocator.free(name_copy);
                self.allocator.destroy(task);
                return;
            };
            task.* = .{
                .backend = self,
                .win_id = st.id,
                .name = name_copy,
                .payload = payload,
            };
            if (c.g_idle_add(windowEventIdle, task) == 0) {
                self.allocator.free(name_copy);
                self.allocator.free(payload);
                self.allocator.destroy(task);
            }
        }

        const WindowEventTask = struct {
            backend: *Self,
            win_id: u32,
            name: []u8,
            payload: []u8,
        };

        fn windowEventIdle(data: c.gpointer) callconv(.c) c.gboolean {
            const task: *WindowEventTask = @ptrCast(@alignCast(data orelse return G_SOURCE_REMOVE));
            const self = task.backend;
            defer {
                self.allocator.free(task.name);
                self.allocator.free(task.payload);
                self.allocator.destroy(task);
            }
            self.emitRawToWindow(task.win_id, task.name, task.payload);
            return G_SOURCE_REMOVE;
        }

        /// v0.3.0：X11 输入焦点是否落在本窗口（含 WebKit 子 GdkWindow）。
        /// GTK 的 has-toplevel-focus 在「焦点直接落在子 GdkWindow」时不更新
        ///（openbox + WebKit 实测：toplevel 从未收到 FocusIn，X 焦点是子窗口）；
        /// 这里沿 X 焦点窗口向父链走，命中 toplevel XID 即视为窗口持有焦点。
        /// 非 X11 后端（或 GTK4 变体）返回 null → 调用方回退 GTK 焦点属性。
        const FocusProbe = if (gtk_compat.isGtk3() and @hasDecl(c, "gdk_x11_window_get_xid")) struct {
            fn within(st: *WinState) ?bool {
                const widget: [*c]c.GtkWidget = @ptrCast(st.win);
                const gdk_win = c.gtk_widget_get_window(widget) orelse return null;
                const top_xid = c.gdk_x11_window_get_xid(gdk_win);
                if (top_xid == 0) return null;
                const display = c.gdk_window_get_display(gdk_win) orelse return null;
                const xdisplay = c.gdk_x11_display_get_xdisplay(display);
                if (xdisplay == null) return null;
                var focus: c.Window = 0;
                var revert: c_int = 0;
                _ = c.XGetInputFocus(xdisplay, &focus, &revert);
                // None / PointerRoot：焦点不在任何具体窗口
                if (focus == 0 or focus == 1) return false;
                var cur = focus;
                var depth: u32 = 0;
                while (cur != 0 and depth < 32) : (depth += 1) {
                    if (cur == top_xid) return true;
                    var root: c.Window = 0;
                    var parent: c.Window = 0;
                    var children: [*c]c.Window = null;
                    var nchildren: c_uint = 0;
                    if (c.XQueryTree(xdisplay, cur, &root, &parent, &children, &nchildren) == 0) return null;
                    if (children != null) _ = c.XFree(@ptrCast(children));
                    if (parent == 0 or parent == cur) return false;
                    cur = parent;
                }
                return false;
            }
        } else if (gtk_compat.isGtk4()) struct {
            // GTK4：gdk_x11_surface_get_xid + gtk_native_get_surface
            fn within(st: *WinState) ?bool {
                const widget: [*c]c.GtkWidget = @ptrCast(st.win);
                const surface = c.gtk_native_get_surface(@ptrCast(widget)) orelse return null;
                const top_xid = c.gdk_x11_surface_get_xid(surface);
                if (top_xid == 0) return null;
                const display = c.gtk_widget_get_display(widget) orelse return null;
                const xdisplay = c.gdk_x11_display_get_xdisplay(display);
                if (xdisplay == null) return null;
                var focus: c.Window = 0;
                var revert: c_int = 0;
                _ = c.XGetInputFocus(xdisplay, &focus, &revert);
                if (focus == 0 or focus == 1) return false;
                var cur = focus;
                var depth: u32 = 0;
                while (cur != 0 and depth < 32) : (depth += 1) {
                    if (cur == top_xid) return true;
                    var root: c.Window = 0;
                    var parent: c.Window = 0;
                    var children: [*c]c.Window = null;
                    var nchildren: c_uint = 0;
                    if (c.XQueryTree(xdisplay, cur, &root, &parent, &children, &nchildren) == 0) return null;
                    if (children != null) _ = c.XFree(@ptrCast(children));
                    if (parent == 0 or parent == cur) return false;
                    cur = parent;
                }
                return false;
            }
        } else struct {
            fn within(_: *WinState) ?bool {
                return null;
            }
        };

        /// 窗口当前是否持有焦点（X11 优先，回退 GTK 属性）。
        fn windowFocused(st: *WinState) bool {
            if (FocusProbe.within(st)) |focused| return focused;
            return gtk_compat.windowHasFocus(st.win);
        }

        /// 200ms 焦点轮询：X11 焦点直接落在 WebKit 子窗口时 GTK 不派发任何
        /// focus 信号，属性也不更新——只有轮询能可靠触发 windowFocus/Blur。
        fn focusPollTick(user_data: c.gpointer) callconv(.c) c.gboolean {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return G_SOURCE_REMOVE));
            notifyFocus(st, windowFocused(st));
            if (comptime gtk_compat.isGtk4()) {
                // GTK4：无 configure-event——位置由 200ms X11 轮询面跟踪
                //（Wayland 无全局坐标，跳过；尺寸经 size-allocate 已跟踪）
                if (st.win != null) {
                    const widget: [*c]c.GtkWidget = @ptrCast(st.win);
                    var px: c.gint = 0;
                    var py: c.gint = 0;
                    var gw: c.gint = 0;
                    var gh: c.gint = 0;
                    if (gtk_compat.surfaceOrigin(widget, &px, &py)) {
                        gtk_compat.windowGetSize(st.win, &gw, &gh);
                        if (st.geom_x != px or st.geom_y != py or
                            st.geom_width != @as(u32, @intCast(gw)) or st.geom_height != @as(u32, @intCast(gh)))
                        {
                            Self.syncGeometry(st, px, py, @intCast(gw), @intCast(gh));
                        }
                    }
                }
            }
            return 1; // G_SOURCE_CONTINUE
        }

        /// focus-in/out → windowFocus/windowBlur（去重）。
        /// v0.3.3：Escape 隐藏（hideOnEscape）。GdkEventKey 是 opaque →
        /// 经 gdk_event_get_keyval 取键值（translate-c 对 opaque 事件结构不可用）。
        /// v0.3.9 A4L：窗口级 KeyBindings 匹配——菜单 accel 由 GTK accel group
        /// 先行处理，被菜单消费的键不会到达本 handler（与 Windows 菜单优先一致）。
        /// compat 形状的按键处理器（key-press-event 与 GtkEventControllerKey 收敛点）。
        fn onKeyPressCompat(keyval: c.guint, mods: c.GdkModifierType, user_data: c.gpointer) callconv(.c) c.gboolean {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return 0));
            const is_escape: bool = keyval == 0xff1b;
            if (is_escape and st.win != null) { // GDK_KEY_Escape = 0xff1b
                c.gtk_widget_hide(@ptrCast(st.win));
                log.print("[window] #{d} escape -> hide", .{st.id});
                return 1;
            }
            if (st.key_bindings.len > 0) {
                if (matchKeyBinding(st.key_bindings, keyval, mods)) |kb| {
                    log.print("[keybinding] {s}", .{kb.id});
                    st.backend.emitKeyBinding(st, kb.id);
                    return 1;
                }
            }
            return 0;
        }

        /// v0.3.9 A4L：windowKeyBinding 事件（payload 与 Windows 逐字一致）。
        fn emitKeyBinding(self: *Self, st: *WinState, id: []const u8) void {
            const id_json = jsonStr(self.allocator, id) orelse return;
            defer self.allocator.free(id_json);
            const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{s},\"windowId\":{d}}}", .{ id_json, st.id }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(st.id, "windowKeyBinding", payload);
        }

        /// v0.3.9 A4L 冒烟：按键派发探针（{windowId, key, ctrl}）。
        /// 走与 key-press-event handler **同一条匹配→事件路径**（matchKeyBinding +
        /// emitKeyBinding），keyval/mods 由 key 名合成。X 层注入（XSendEvent/XTest）
        /// 实测在 Xvfb+WebKit 下段错（环境限制），真实按键路径由
        /// matchKeyBinding 单测 + GTK key-press 语义保证。
        /// v0.4.3 L6 冒烟：托盘挂窗探针（toggle → 隐藏/显示+定位回传）。
        fn smokeAttachInject(self: *Self) void {
            const w = self.windowById(0) orelse {
                self.emitRawToWindow(1, "linuxSmokeAttach", "{\"ok\":false}");
                return;
            };
            const widget: [*c]c.GtkWidget = @ptrCast(w.win);
            const before = c.gtk_widget_get_visible(widget) != 0;
            const x0 = w.geom_x;
            const y0 = w.geom_y;
            // 往返 toggle（隐藏→显示）：机制面证明（免定位——不扰动后续检查）
            self.toggleAttachedWindowInner(false);
            self.toggleAttachedWindowInner(false);
            if (w.geom_x != x0 or w.geom_y != y0) {
                gtk_compat.windowMove(w.win, x0, y0);
                w.geom_x = x0;
                w.geom_y = y0;
            }
            const after = c.gtk_widget_get_visible(widget) != 0;
            const payload = std.fmt.allocPrint(self.allocator, "{{\"before\":{},\"after\":{},\"x\":{d},\"y\":{d}}}", .{
                before, after, w.geom_x, w.geom_y,
            }) catch return;
            defer self.allocator.free(payload);
            self.emitRawToWindow(1, "linuxSmokeAttach", payload);
        }

        fn smokeKeyBindInject(self: *Self, args_json: []const u8) void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), args_json, .{}) catch return;
            if (parsed != .object) return;
            const obj = parsed.object;
            const win_id: u32 = if (obj.get("windowId")) |v|
                (if (v == .integer) @as(u32, @intCast(v.integer)) else 1)
            else
                1;
            const key_name: []const u8 = if (obj.get("key")) |v|
                (if (v == .string) v.string else "x")
            else
                "x";
            const with_ctrl = if (obj.get("ctrl")) |v| (v == .bool and v.bool) else true;

            const w = self.windowById(win_id) orelse return;
            const accel = std.fmt.allocPrint(arena.allocator(), "{s}{s}", .{
                if (with_ctrl) "Ctrl+" else "", key_name,
            }) catch return;
            const spec = parseAccelGtk(accel) orelse return;
            var mods: c.GdkModifierType = spec.mods;
            // 合成事件的 state 带 MOD2（numlock）等 lock 位——handler 同样先掩码
            mods |= gtk_compat.MOD2_MASK;
            const kb = matchKeyBinding(w.key_bindings, spec.keyval, mods) orelse {
                log.print("[keybinding] smoke probe: no match for '{s}' on window #{d} (bindings={d})", .{ key_name, win_id, w.key_bindings.len });
                // 不命中也要回传确认（冒烟断言区分「没注册」与「没收到」）
                self.emitRawToWindow(1, "linuxSmokeKeyBind", "{\"matched\":false}");
                return;
            };
            log.print("[keybinding] {s} (smoke probe)", .{kb.id});
            // 真实事件路径：windowKeyBinding 发给持有绑定的窗口
            self.emitKeyBinding(w, kb.id);
            // 冒烟确认通道：结果回传主页面（对齐 secondWindowProbe 的 emitTo(1) 先例）
            const id_json = jsonStr(self.allocator, kb.id) orelse return;
            defer self.allocator.free(id_json);
            const confirm = std.fmt.allocPrint(self.allocator, "{{\"matched\":true,\"id\":{s},\"windowId\":{d}}}", .{ id_json, w.id }) catch return;
            defer self.allocator.free(confirm);
            self.emitRawToWindow(1, "linuxSmokeKeyBind", confirm);
        }

        /// GTK4：size-allocate → 几何跟踪（宽度/高度；位置由 X11 轮询面补齐）。
        fn onSizeAllocated(width: c.gint, height: c.gint, user_data: c.gpointer) callconv(.c) void {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return));
            syncGeometry(st, null, null, @intCast(width), @intCast(height));
        }

        /// GTK4：GtkDropTarget drop → uri-list 字节（读面在 compat 内完成；
        /// 参数按 C ABI 面：指针 + 长度）。
        fn onGdkDrop(user_data: c.gpointer, data: ?*const anyopaque, len: usize) callconv(.c) void {
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return));
            const self = sink.backend;
            if (data == null or len == 0) return;
            const payload: []const u8 = @as([*]const u8, @ptrCast(data.?))[0..len];
            self.handleDropUris(sink.win_id, payload);
        }

        /// 几何跟踪去重（GTK3 configure-event / GTK4 size-allocate+X11 轮询共用）。
        fn syncGeometry(st: *WinState, x: ?i32, y: ?i32, width: u32, height: u32) void {
            Self.clampToWorkArea(st);
            var moved = false;
            var resized = false;
            if (x) |vx| {
                if (st.geom_x != vx) {
                    st.geom_x = vx;
                    moved = true;
                }
            }
            if (y) |vy| {
                if (st.geom_y != vy) {
                    st.geom_y = vy;
                    moved = true;
                }
            }
            if (st.geom_width != width) {
                st.geom_width = width;
                resized = true;
            }
            if (st.geom_height != height) {
                st.geom_height = height;
                resized = true;
            }
            moved = moved or st.geom_x != st.reported_x or st.geom_y != st.reported_y;
            if (moved) {
                st.reported_x = st.geom_x;
                st.reported_y = st.geom_y;
                st.backend.emitWindowEvent(st, "windowMoved", &.{
                    .{ .name = "id", .value = st.id },
                    .{ .name = "x", .value = st.geom_x },
                    .{ .name = "y", .value = st.geom_y },
                });
            }
            resized = resized or @as(i64, st.geom_width) != st.reported_w or @as(i64, st.geom_height) != st.reported_h;
            if (resized) {
                st.reported_w = @intCast(st.geom_width);
                st.reported_h = @intCast(st.geom_height);
                st.backend.emitWindowEvent(st, "windowResized", &.{
                    .{ .name = "id", .value = st.id },
                    .{ .name = "width", .value = @as(i64, st.geom_width) },
                    .{ .name = "height", .value = @as(i64, st.geom_height) },
                });
            }
        }

        /// compat 形状的焦点处理器（focus-in/out 与 notify::is-active 的收敛点）。
        fn onFocusCompat(focused: bool, user_data: c.gpointer) callconv(.c) void {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return));
            notifyFocus(st, focused);
        }

        /// v0.3.0：`notify::has-toplevel-focus` → windowFocus/windowBlur。
        /// GtkWindow 的 focus-in/out 事件依赖事件落在 toplevel GdkWindow 上；
        /// WebKit 子窗口持有焦点时（openbox 实测）收不到。属性通知作为非 X11
        /// 后端的低延迟路径；X11 由 focusPollTick 兜底。
        fn onActiveNotify(_: [*c]c.GtkWidget, _: ?*anyopaque, user_data: c.gpointer) callconv(.c) void {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return));
            notifyFocus(st, windowFocused(st));
        }

        /// 焦点状态去重 + 事件发射（focus-in/out、属性通知与轮询共用）。
        fn notifyFocus(st: *WinState, focused: bool) void {
            if (focused == st.reported_focus) return;
            // v0.3.3：失焦自动隐藏（hideOnFocusLost）
            if (!focused and st.hide_on_focus_lost and st.win != null) {
                if (st.tray_attached and st.backend.ffm) {
                    // v0.4.3 L6：FFM 桌面（Hyprland/Sway/i3…）下挂窗不随失焦隐藏
                    //（指针离开即失焦 → 弹窗在可用前消失；Wails 同语义）
                    log.print("[window] #{d} focus lost ignored (focus-follows-mouse)", .{st.id});
                } else if (gtk_compat.nowMs() < st.hide_suppress_until_ms) {
                    // v0.4.3 L6：挂窗显示后的抑制窗（FFM WM 下指针掠过即失焦）
                    log.print("[window] #{d} focus lost suppressed (attach window)", .{st.id});
                } else {
                    c.gtk_widget_hide(@ptrCast(st.win));
                    log.print("[window] #{d} focus lost -> hide", .{st.id});
                }
            }
            st.reported_focus = focused;
            log.print("[window] focus changed #{d} focused={}", .{ st.id, focused });
            st.backend.emitWindowEvent(st, if (focused) "windowFocus" else "windowBlur", &.{
                .{ .name = "id", .value = st.id },
            });
        }

        /// delete-event → close_requested_event=true 时拦截（发 windowCloseRequested
        /// 由前端确认；false = 走默认销毁）。
        fn onDeleteEvent(user_data: c.gpointer) callconv(.c) c.gboolean {
            const st: *WinState = @ptrCast(@alignCast(user_data orelse return 0));
            if (!st.close_requested_event) return 0; // 默认销毁
            // v0.3.14 G6：Zig 侧取消钩子（comptime 门控；true = 取消关闭）
            if (comptime ipc.closeRequestHooked(config.events)) {
                const hook_payload = std.fmt.allocPrint(st.backend.allocator, "{{\"id\":{d}}}", .{st.id}) catch null;
                if (hook_payload) |hp| {
                    defer st.backend.allocator.free(hp);
                    if (ipc.closeRequestCancelled(config.events, st.backend.context(st.backend.allocator, st.id), hp)) |cancelled| {
                        if (cancelled) {
                            log.print("[window] close cancelled by Zig hook (window #{d})", .{st.id});
                            return 1; // 拦截：不销毁
                        }
                    }
                }
            }
            log.print("[window] close requested (window #{d})", .{st.id});
            st.backend.emitWindowEvent(st, "windowCloseRequested", &.{
                .{ .name = "id", .value = st.id },
            });
            return 1; // 拦截：不销毁，等前端确认
        }

        /// GtkOverlay 的 get-child-position：子 WebView 按存储的布局矩形放置。
        /// 返回 TRUE 表示已处理（不用 GTK 默认的边缘对齐位置）。
        fn onChildPosition(
            _: ?*c.GtkOverlay,
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

        fn onSchemeRequest(request: ?*c.WebKitURISchemeRequest, user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            self.serveScheme(request);
        }

        fn onScriptMessage(
            _: ?*c.WebKitUserContentManager,
            result: ?*anyopaque,
            user_data: c.gpointer,
        ) callconv(.c) void {
            const sink: *IpcSink = @ptrCast(@alignCast(user_data orelse return));
            if (result == null) return;

            // 信号载荷收敛 JSCValue：GTK3 从 WebKitJavascriptResult 解包，
            // 6.0 直接携带 JSCValue。对象要用 jsc_value_to_json 才能拿到 JSON
            // 文本（jsc_value_to_string 只会给 "[object Object]"）。
            const value = gtk_compat.scriptMessageJscValue(result);
            if (value == null) return;
            const json_ptr = c.jsc_value_to_json(@ptrCast(@alignCast(value)), 0);
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

test "file URI 往返与百分号解码" {
    const a = testing.allocator;
    const p = try fileUriToPath(a, "file:///tmp/a%20b.txt");
    defer a.free(p);
    try testing.expectEqualStrings("/tmp/a b.txt", p);
    try testing.expectError(error.UnsupportedUri, fileUriToPath(a, "https://example.com/x"));
    try testing.expectError(error.UnsupportedUri, fileUriToPath(a, "file://host/x"));
    try testing.expectError(error.UnsupportedUri, fileUriToPath(a, "file://nope"));

    const uri = try pathToFileUri(a, "/tmp/a b.txt");
    defer a.free(uri);
    try testing.expectEqualStrings("file:///tmp/a%20b.txt", uri);
}

test "reasonFor: 状态码有可读短语" {
    try testing.expectEqualStrings("Not Found", reasonFor(404));
    try testing.expectEqualStrings("OK", reasonFor(200));
    try testing.expectEqualStrings("OK", reasonFor(599)); // 未知码不崩
}

test "v0.4.3 L6: FFM 桌面判定（令牌匹配，不做子串误命中）" {
    // 命中：FFM 默认桌面（Wails 文档点名的 Hyprland/Sway/i3 + 同类）
    try testing.expect(impliesFocusFollowsMouse("sway"));
    try testing.expect(impliesFocusFollowsMouse("Hyprland"));
    try testing.expect(impliesFocusFollowsMouse("i3"));
    try testing.expect(impliesFocusFollowsMouse("i3:WM"));
    try testing.expect(impliesFocusFollowsMouse("ubuntu:GNOME,sway"));
    try testing.expect(impliesFocusFollowsMouse("xmonad"));
    // 不命中：点击聚焦桌面（含易误命中的子串）
    try testing.expect(!impliesFocusFollowsMouse("ubuntu:GNOME"));
    try testing.expect(!impliesFocusFollowsMouse("KDE"));
    try testing.expect(!impliesFocusFollowsMouse("X-Cinnamon"));
    try testing.expect(!impliesFocusFollowsMouse("i386"));
    try testing.expect(!impliesFocusFollowsMouse(""));
    try testing.expect(!impliesFocusFollowsMouse("swayland")); // 前缀不匹配
}

test "gdkCursorName: 14 种 CursorKind 全部映射到 GDK 标准光标名" {
    const kinds = [_]ipc.CursorKind{
        .default, .arrow,     .ibeam,     .crosshair,
        .hand,    .wait,      .help,      .not_allowed,
        .size_ns, .size_ew,   .size_nwse, .size_nesw,
        .move,    .up_arrow,
    };
    for (kinds) |kind| {
        const name = gdkCursorName(kind);
        try testing.expect(name.len > 0);
    }
    try testing.expectEqualStrings("pointer", gdkCursorName(.hand));
    try testing.expectEqualStrings("text", gdkCursorName(.ibeam));
    try testing.expectEqualStrings("not-allowed", gdkCursorName(.not_allowed));
    try testing.expectEqualStrings("ns-resize", gdkCursorName(.size_ns));
    try testing.expectEqualStrings("default", gdkCursorName(.arrow));
}

test "buildUriList: file:// 编码、CRLF 分隔与空项跳过" {
    const alloc = testing.allocator;
    const list = try buildUriList(alloc, &.{ "/tmp/a b.txt", "", "/tmp/c.txt" });
    defer alloc.free(list);
    try testing.expectEqualStrings("file:///tmp/a%20b.txt\r\nfile:///tmp/c.txt\r\n", list);

    const empty = try buildUriList(alloc, &.{});
    defer alloc.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
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

test "parseDropUris: 注释/非 file URI/百分号解码" {
    const a = testing.allocator;
    const list = "# comment\r\nfile:///tmp/zilt-smoke-a.txt\r\n\r\nhttps://example.com/x\r\nfile:///tmp/a%20b.txt\r\n";
    const paths = try parseDropUris(a, list);
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("/tmp/zilt-smoke-a.txt", paths[0]);
    try testing.expectEqualStrings("/tmp/a b.txt", paths[1]);

    const empty = try parseDropUris(a, "https://only/remote");
    defer {
        for (empty) |p| a.free(p);
        a.free(empty);
    }
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "v0.3.9 A4L: matchKeyBinding 大小写归一 + 修饰符掩码" {
    var id_buf = [_]u8{ 'k', 'b', '-', 'p', 'r', 'o', 'b', 'e' };
    const entries = [_]KeyBindEntry{
        .{ .id = id_buf[0..], .mods = c.GDK_CONTROL_MASK, .keyval = 'X' }, // keyvalForGtk 大写键位
    };
    // 事件 'x'（0x78）+ ControlMask → 命中（归一小写比较）
    const hit = matchKeyBinding(&entries, 'x', c.GDK_CONTROL_MASK | gtk_compat.MOD2_MASK); // MOD2(numlock) 应被忽略
    try testing.expect(hit != null);
    try testing.expectEqualStrings("kb-probe", hit.?.id);
    // 修饰符不符（无 ctrl）→ 不命中
    try testing.expect(matchKeyBinding(&entries, 'x', 0) == null);
    // 修饰符不符（ctrl+shift）→ 不命中
    try testing.expect(matchKeyBinding(&entries, 'x', c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK) == null);
    // 键位不符 → 不命中
    try testing.expect(matchKeyBinding(&entries, 'y', c.GDK_CONTROL_MASK) == null);
    // 大写事件 keyval（0x58）同样命中
    try testing.expect(matchKeyBinding(&entries, 'X', c.GDK_CONTROL_MASK) != null);
    // 空表不命中
    try testing.expect(matchKeyBinding(&.{}, 'x', c.GDK_CONTROL_MASK) == null);
}

test "parseAccelGtk: 修饰符组合 / 键位 / 非法输入" {
    const cases = [_]struct { accel: []const u8, mods: c.GdkModifierType, keyval: c.guint }{
        .{ .accel = "Ctrl+S", .mods = c.GDK_CONTROL_MASK, .keyval = 'S' },
        .{ .accel = "Ctrl+N", .mods = c.GDK_CONTROL_MASK, .keyval = 'N' },
        .{ .accel = "Ctrl+Alt+N", .mods = c.GDK_CONTROL_MASK | gtk_compat.MOD1_MASK, .keyval = 'N' },
        .{ .accel = "Ctrl+Shift+P", .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .keyval = 'P' },
        .{ .accel = "Alt+F4", .mods = gtk_compat.MOD1_MASK, .keyval = 0xffbe + 3 },
        .{ .accel = "F7", .mods = 0, .keyval = 0xffbe + 6 },
        .{ .accel = "F12", .mods = 0, .keyval = 0xffbe + 11 },
        .{ .accel = "5", .mods = 0, .keyval = '5' },
    };
    for (cases) |tc| {
        const parsed = parseAccelGtk(tc.accel) orelse {
            std.debug.print("parseAccelGtk('{s}') unexpectedly null\n", .{tc.accel});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(tc.mods, parsed.mods);
        try testing.expectEqual(tc.keyval, parsed.keyval);
    }
    // 非法：空段 / 未知键名 / 两个键位 / 仅修饰符
    try testing.expect(parseAccelGtk("") == null);
    try testing.expect(parseAccelGtk("Ctrl+") == null);
    try testing.expect(parseAccelGtk("Ctrl+Space+X") == null);
    try testing.expect(parseAccelGtk("Ctrl+Foo") == null);
    try testing.expect(parseAccelGtk("Ctrl+Alt") == null);
    try testing.expect(parseAccelGtk("Ctrl+A+B") == null);
}

test "windowEventPayloadJson: 字段名带引号、多字段与空字段" {
    const alloc = testing.allocator;
    {
        const json = try windowEventPayloadJson(alloc, &.{
            .{ .name = "id", .value = 1 },
            .{ .name = "x", .value = -12 },
        });
        defer alloc.free(json);
        try testing.expectEqualStrings("{\"id\":1,\"x\":-12}", json);
    }
    {
        const json = try windowEventPayloadJson(alloc, &.{});
        defer alloc.free(json);
        try testing.expectEqualStrings("{}", json);
    }
    // 负数与 i64 大值直出
    {
        const json = try windowEventPayloadJson(alloc, &.{
            .{ .name = "width", .value = 9007199254740993 },
        });
        defer alloc.free(json);
        try testing.expectEqualStrings("{\"width\":9007199254740993}", json);
    }
}


/// v0.3.16 G20：GPU 策略环境变量（必须在 WebKit 首次实例化之前 setenv）。
/// 显式 never → WEBKIT_DISABLE_COMPOSITING_MODE=1；auto + NVIDIA（/proc/driver/
/// nvidia 存在）→ WEBKIT_DISABLE_DMABUF_RENDERER=1（上游 NVIDIA DMA-BUF 空白窗
/// 问题的对策，Wails 恒设；对非 NVIDIA 无害但保守起见仅在探测命中时设置）。
fn applyGpuPolicy(policy: ?@import("../../environment.zig").Options.GpuPolicy) void {
    switch (policy orelse .always) {
        .never => {
            _ = setEnvVar("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
            log.print("[gpu] compositing disabled (policy=never)", .{});
        },
        else => {
            if (policy == null and nvidiaDetected()) {
                _ = setEnvVar("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
                log.print("[gpu] NVIDIA detected -> DMABUF renderer disabled (auto workaround)", .{});
            }
        },
    }
}

/// 仅用于 WebKit 初始化前的环境对策（进程早期、无并发——setenv 直呼安全）。
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
fn setEnvVar(name: [*:0]const u8, value: [*:0]const u8) bool {
    return setenv(name, value, 1) == 0;
}

/// NVIDIA 独占驱动探测（/proc/driver/nvidia/version；nouveau 不在——DMABUF 问题
/// 是 nvidia 专有驱动的 WebKit 交互）。
fn nvidiaDetected() bool {
    var buf: [64]u8 = undefined;
    var io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer io.deinit();
    var dir = std.Io.Dir.cwd();
    var f = dir.openFile(io.io(), "/proc/driver/nvidia/version", .{}) catch return false;
    defer f.close(io.io());
    const n = std.Io.File.readPositionalAll(f, io.io(), &buf, 0) catch return false;
    return n > 0;
}

test "gpu policy: never 设置合成禁用变量；NVIDIA 探测函数可达" {
    // 环境变量写进进程环境后可读回
    try std.testing.expect(setEnvVar("ZILT_GPU_TEST", "1"));
    try std.testing.expectEqualStrings("1", std.mem.span(std.c.getenv("ZILT_GPU_TEST").?));
    try std.testing.expect(setEnvVar("ZILT_GPU_TEST", "0"));
    // NVIDIA 探测在无该驱动的 CI（Xvfb）上应安全返回 false，不崩溃
    _ = nvidiaDetected();
}
