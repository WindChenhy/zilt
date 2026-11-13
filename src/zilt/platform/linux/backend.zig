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
const webview = @import("../../webview.zig");
const asset_routes = @import("../../asset_routes.zig");
const inflate = @import("../../inflate.zig");
const security = @import("../../security.zig");
const builtin_cmds = @import("../../builtin.zig");
const log = @import("../../log.zig");
const system_api = @import("../../system_api.zig");
const clipboard = @import("../../clipboard.zig");
const notification = @import("../../notification.zig");
const window_state = @import("window_state.zig");
const sys = @import("../../sys.zig");
const deep_link = @import("deep_link.zig");
const desktop_entry = @import("desktop_entry.zig");
const sysinfo_linux = @import("sysinfo_linux.zig");
const menu_model = @import("../../menu_model.zig");
const shared_sysinfo = @import("../../sysinfo.zig");
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
            mods |= c.GDK_MOD1_MASK;
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
        .smoke_stay = smokeStaySeconds(),
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

    // v0.2.2：GApplication 宿主 = 通知 + 单实例 + 深链转交三合一。
    // **先注册再建窗口**：第二实例在远端检测命中后立即转交退出（不建窗口、
    // 不注入脚本）。命令行参数（char**）进程生命周期内持有；冒烟模式会把
    // ZILT_LINUX_SMOKE_DEEPLINK 追加为伪参数，覆盖「启动深链」链路。
    const argv = try collectArgv(alloc);
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

    // v0.2.2：运行时菜单模型（托盘菜单驱动）+ 托盘（libayatana 可选，缺失仅日志）
    self.initMenuModel();
    self.initTray();

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

    // 深链 / 文件关联注册（.desktop + xdg-mime；config.deep_link.register）
    self.registerDeepLink();

    // v0.2.3：本地存储（store.json / acl.json，与 windowState 同根）
    self.initStorage();

    // v0.2.3：应用自定义协议 → 真 scheme（Config.protocols；每协议一个 scheme）
    self.registerProtocolSchemes(wc);

    // v0.2.2：剪贴板变化监听（owner-change → clipboardChanged 事件）
    if (config.clipboard_change_event) {
        const cb = c.gtk_clipboard_get(c.GDK_SELECTION_CLIPBOARD);
        if (cb != null) {
            _ = c.g_signal_connect_data(cb, "owner-change", @ptrCast(&Self.onClipboardOwnerChange), self, null, 0);
            log.print("[clip] change listener attached", .{});
        }
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
        c.gtk_main();
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
            /// 内容根（GtkBox 纵向：可选菜单栏 + overlay）；窗口销毁时随控件树释放
            box: [*c]c.GtkWidget = null,
            /// 每窗口菜单栏（config.menu；null = 无菜单）
            menubar: [*c]c.GtkWidget = null,
            /// 菜单项激活时的 user_data（窗口销毁时统一释放）
            menu_actions: std.ArrayListUnmanaged(*MenuAction) = .empty,
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
            /// v0.2.2：菜单加速键的 GtkAccelGroup（惰性创建；窗口销毁时随 GTK 释放）
            accel_group: ?*c.GtkAccelGroup = null,
            /// 页面是否已完成首次加载（runtime 注入就绪）——深链事件投递的前置条件
            loaded: bool = false,
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

        /// 剪贴板 HTML/文件列表的异步载荷（GTK 在目标程序粘贴时才调用 get 回调，
        /// 生命周期跟着剪贴板 owner 走，由 clear 回调释放）。
        const ClipPayload = struct {
            backend: *Self,
            data: []u8,
            targets: []c.GtkTargetEntry,
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
        /// 缺失时只记日志不阻断启动（对齐 docs/v0.2-LINUX.md §2.3 的决定）。
        const Tray = struct {
            lib: std.DynLib,
            indicator: ?*anyopaque,
            set_status: *const fn (?*anyopaque, c_int) callconv(.c) void,
            set_menu: *const fn (?*anyopaque, ?*c.GtkMenu) callconv(.c) void,
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
        /// ---- v0.2.2：运行时菜单模型 / 深链 / 拖放 ----
        /// 菜单模型（与 Windows 对齐：config.tray.menu 初始化；menu.* op 可变，
        /// 变更后重建托盘菜单；每窗口菜单栏仍是 config.menu 静态树）
        menu_state: ?menu_model.Model = null,
        /// 模型驱动的托盘 GtkMenu。有 indicator 时所有权归 indicator（替换后旧菜单
        /// 由 indicator 析构，绝不能再 destroy）；无 indicator 时归我们
        ///（tray_menu_owned = true，替换/退出时 destroy）。
        tray_menu_widget: ?*c.GtkMenu = null,
        tray_menu_owned: bool = false,
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
        /// HTTP（libsoup3；事件 httpResponse / httpChunk）
        next_http_id_seq: i64 = 1,
        /// WebSocket 连接表（SoupWebsocketConnection 所有权在此）
        ws_conns: std.AutoHashMapUnmanaged(i64, *WsConn) = .empty,
        next_ws_id_seq: i64 = 1,

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
                if (self.tray_menu_owned) c.gtk_widget_destroy(@ptrCast(menu));
                self.tray_menu_widget = null;
            }
            if (self.tray) |*t| t.lib.close();
            if (self.gapp) |app| c.g_object_unref(@ptrCast(app));
            if (self.pending_launch) |*launch| launch.deinit(self.allocator);
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
            if (self.smoke) {
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
                // v0.2.2：剪贴板 + 原生对话框
                .clipboard_write_fn = clipboardWriteTextEntry,
                .clipboard_read_fn = clipboardReadTextEntry,
                .clipboard_read_data_fn = clipboardReadDataEntry,
                .clipboard_write_data_fn = clipboardWriteDataEntry,
                .dialog_fn = dialogEntry,
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
                c.gtk_main_quit();
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
                c.gtk_main_quit();
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

            // 内容根：GtkBox（纵向）＝ 可选菜单栏 + GtkOverlay
            const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
            if (box == null) return error.WindowCreateFailed;
            st.box = @ptrCast(box);
            if (config.menu) |items| {
                const menubar = self.buildMenuBar(items, st);
                if (menubar != null) {
                    st.menubar = menubar;
                    c.gtk_box_pack_start(@ptrCast(box), menubar, 0, 0, 0);
                }
            }

            // GtkOverlay 布局容器（见 WinState.overlay 注释）
            const overlay = c.gtk_overlay_new();
            if (overlay == null) return error.WebViewCreateFailed;
            st.overlay = @ptrCast(overlay);
            c.gtk_box_pack_start(@ptrCast(box), overlay, 1, 1, 0);
            c.gtk_container_add(@ptrCast(win), box);

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

            // v0.2.2：拖放（文件拖入）。dest 与信号挂主 WebView：drag-drop 里
            // gtk_drag_get_data 后返回 TRUE（user handler 先于 WebKit 的 class
            // handler 运行，拦截「拖入文件即导航」的默认行为）；drag-data-received
            // 解析 text/uri-list → dropFiles 事件（对齐 Windows WM_DROPFILES）。
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
        // 剪贴板（v0.2.2）：文本 / HTML / 文件列表 / 图片
        // ------------------------------------------------------------------

        /// GtkClipboard 在 translate-c 里是不透明类型 → 用单指针（C 指针不可索引）。
        fn gtkClipboard() ?*c.GtkClipboard {
            return c.gtk_clipboard_get(c.GDK_SELECTION_CLIPBOARD);
        }

        fn clipboardWriteTextEntry(_: *anyopaque, text: []const u8) bool {
            const cb = gtkClipboard() orelse return false;
            const z = std.heap.c_allocator.allocSentinel(u8, text.len, 0) catch return false;
            defer std.heap.c_allocator.free(z);
            @memcpy(z, text);
            c.gtk_clipboard_set_text(cb, z.ptr, @intCast(text.len));
            c.gtk_clipboard_store(cb);
            return true;
        }

        fn readClipboardText(alloc: std.mem.Allocator) ?[]u8 {
            const cb = gtkClipboard() orelse return null;
            const text = c.gtk_clipboard_wait_for_text(cb);
            if (text == null) return null;
            defer c.g_free(@ptrCast(text));
            return alloc.dupe(u8, std.mem.span(text)) catch null;
        }

        fn clipboardReadTextEntry(_: *anyopaque, alloc: std.mem.Allocator) ?[]u8 {
            return readClipboardText(alloc);
        }

        fn clipboardReadDataEntry(_: *anyopaque, _: u32, alloc: std.mem.Allocator, format: clipboard.Format) anyerror!?clipboard.Data {
            const cb = gtkClipboard() orelse return error.ClipboardNotAvailable;
            switch (format) {
                .text => {
                    const text = readClipboardText(alloc) orelse return null;
                    return clipboard.Data{ .text = text };
                },
                .html => {
                    const atom = c.gdk_atom_intern("text/html", 0);
                    const sel = c.gtk_clipboard_wait_for_contents(cb, atom) orelse return null;
                    defer c.gtk_selection_data_free(sel);
                    const len = c.gtk_selection_data_get_length(sel);
                    const raw = c.gtk_selection_data_get_data(sel);
                    if (len <= 0 or raw == null) return null;
                    return clipboard.Data{ .html = try alloc.dupe(u8, raw[0..@intCast(len)]) };
                },
                .image => {
                    const pixbuf = c.gtk_clipboard_wait_for_image(cb) orelse return null;
                    defer c.g_object_unref(@ptrCast(pixbuf));
                    const width: u32 = @intCast(c.gdk_pixbuf_get_width(pixbuf));
                    const height: u32 = @intCast(c.gdk_pixbuf_get_height(pixbuf));
                    if (width == 0 or height == 0) return null;
                    const channels = c.gdk_pixbuf_get_n_channels(pixbuf);
                    const rowstride: usize = @intCast(c.gdk_pixbuf_get_rowstride(pixbuf));
                    const pixels = c.gdk_pixbuf_get_pixels(pixbuf);
                    if (pixels == null) return null;
                    const rgba = try alloc.alloc(u8, @as(usize, width) * height * 4);
                    errdefer alloc.free(rgba);
                    for (0..height) |row| {
                        const src = pixels + row * rowstride;
                        for (0..width) |col| {
                            const s = src + col * @as(usize, @intCast(channels));
                            const d = rgba[(row * width + col) * 4 ..][0..4];
                            d[0] = s[0];
                            d[1] = s[1];
                            d[2] = s[2];
                            d[3] = if (channels >= 4) s[3] else 255;
                        }
                    }
                    return clipboard.Data{ .image = .{ .width = width, .height = height, .rgba = rgba } };
                },
                .files => {
                    const uris = c.gtk_clipboard_wait_for_uris(cb) orelse return null;
                    defer c.g_strfreev(uris);
                    var count: usize = 0;
                    while (uris[count] != null) : (count += 1) {}
                    if (count == 0) return null;
                    const paths = try alloc.alloc([]const u8, count);
                    errdefer alloc.free(paths);
                    var filled: usize = 0;
                    errdefer for (paths[0..filled]) |p| alloc.free(p);
                    for (0..count) |i| {
                        paths[i] = try fileUriToPath(alloc, std.mem.span(uris[i]));
                        filled += 1;
                    }
                    return clipboard.Data{ .files = paths };
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
                    const pixbuf = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, @intCast(image.width), @intCast(image.height));
                    if (pixbuf == null) return error.ClipboardWriteFailed;
                    defer c.g_object_unref(@ptrCast(pixbuf));
                    const rowstride: usize = @intCast(c.gdk_pixbuf_get_rowstride(pixbuf));
                    const pixels = c.gdk_pixbuf_get_pixels(pixbuf);
                    if (pixels == null) return error.ClipboardWriteFailed;
                    for (0..image.height) |row| {
                        const src = image.rgba[row * image.width * 4 ..];
                        const dst = pixels + row * rowstride;
                        @memcpy(dst[0 .. image.width * 4], src[0 .. image.width * 4]);
                    }
                    c.gtk_clipboard_set_image(cb, pixbuf);
                    c.gtk_clipboard_store(cb);
                },
            }
        }

        /// HTML / 文件列表走“延迟提供”：GTK 在目标粘贴时才回调 clipGet。
        fn writeClipboardPayload(self: *Self, mime: [:0]const u8, bytes: []const u8) !void {
            const cb = gtkClipboard() orelse return error.ClipboardNotAvailable;
            c.gtk_clipboard_clear(cb); // 释放旧 payload（clipClear）
            const targets = try self.allocator.alloc(c.GtkTargetEntry, 2);
            errdefer self.allocator.free(targets);
            targets[0] = .{ .target = @ptrCast(@constCast(mime.ptr)), .flags = 0, .info = 0 };
            targets[1] = .{ .target = @ptrCast(@constCast("UTF8_STRING")), .flags = 0, .info = 1 };

            const data = try self.allocator.dupe(u8, bytes);
            errdefer self.allocator.free(data);
            const p = try self.allocator.create(ClipPayload);
            errdefer self.allocator.destroy(p);
            p.* = .{ .backend = self, .data = data, .targets = targets };
            if (c.gtk_clipboard_set_with_data(cb, targets.ptr, @intCast(targets.len), clipGet, clipClear, p) == 0) {
                return error.ClipboardWriteFailed;
            }
            self.clip_payload = p;
            c.gtk_clipboard_store(cb);
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

        fn onClipboardOwnerChange(_: ?*c.GtkClipboard, _: ?*anyopaque, user_data: c.gpointer) callconv(.c) void {
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
        fn buildMenuBar(self: *Self, items: []const Config.MenuItem, st: *WinState) [*c]c.GtkWidget {
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
            const self = action.backend;
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

        /// 程序化弹出（右键上下文菜单）：模型 → 临时 GtkMenu → gtk_menu_popup_at_rect。
        /// deactivate 即销毁（MenuAction 挂在窗口注册表，随窗口释放——与 Windows
        /// 的 TrackPopupMenu 每次全量构建同构）。
        fn popupMenu(self: *Self, x: i32, y: i32) !system_api.Result {
            const model = if (self.menu_state) |*m| m else return error.MenuNotConfigured;
            const w = self.windowById(0) orelse return error.WindowNotFound;
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
            const tray_cfg = config.tray orelse return;
            // 1) 菜单：模型优先（menu.* 可变）；模型缺失回退静态树
            if (self.menu_state) |*model| {
                if (self.buildTrayMenuFromModel(model)) |menu| self.setTrayMenu(menu);
            } else if (tray_cfg.menu) |items| {
                if (self.buildTrayMenu(items, if (self.windowById(0)) |w| w.id else 1)) |menu| {
                    self.setTrayMenu(@ptrCast(menu));
                }
            }

            // 2) indicator：dlopen（缺失 → 无托盘图标，但菜单/模型仍然可用）
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
                *const fn (?*anyopaque, ?*c.GtkMenu) callconv(.c) void,
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
            const model = if (self.menu_state) |*m| m else return;
            if (self.buildTrayMenuFromModel(model)) |menu| self.setTrayMenu(menu);
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
            payload.appendSlice(self.allocator, "]}") catch return false;
            self.emitRawToWindow(w.id, "deepLink", payload.items);
            return true;
        }

        /// 页面加载完成 → 补发挂起的启动深链（一次性）。
        fn flushPendingLaunch(self: *Self) void {
            const launch = self.pending_launch orelse return;
            if (self.emitLaunch(launch)) self.pending_launch = null;
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

        fn notificationShowEntry(backend: *anyopaque, _: u32, options: notification.Options) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(backend));
            try self.sendNotification(options.tag, options.title, options.body);
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
        fn notifyEntry(backend: *anyopaque, title: []const u8, body: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(backend));
            self.sendNotification(null, title, body) catch |err| {
                log.print("[notify] legacy notify failed: {s}", .{@errorName(err)});
            };
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
            defer c.gtk_widget_destroy(dlg);
            c.gtk_window_set_title(@ptrCast(dlg), caption_z.ptr);
            return switch (c.gtk_dialog_run(@ptrCast(dlg))) {
                c.GTK_RESPONSE_OK => .ok,
                c.GTK_RESPONSE_YES => .yes,
                c.GTK_RESPONSE_NO => .no,
                else => .cancel,
            };
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
            const native = (try nativeChooser(alloc, parent, opts, if (mode == .save) .save else .open)) orelse
                return error.DialogNotAvailable;
            defer c.g_object_unref(@ptrCast(native));
            const chooser: *c.GtkFileChooser = @ptrCast(native);
            if (mode == .save) c.gtk_file_chooser_set_do_overwrite_confirmation(chooser, 1);
            if (c.gtk_native_dialog_run(@alignCast(@ptrCast(native))) != c.GTK_RESPONSE_ACCEPT) return null;
            const chosen = c.gtk_file_chooser_get_filename(chooser);
            if (chosen == null) return null;
            defer c.g_free(@ptrCast(chosen));
            return try alloc.dupe(u8, std.mem.span(chosen));
        }

        fn folderDialog(self: *Self, alloc: std.mem.Allocator, parent: [*c]c.GtkWindow, title: []const u8) !?[]u8 {
            _ = self;
            const title_z = try dupeZ(alloc, if (title.len > 0) title else "选择文件夹");
            defer alloc.free(title_z);
            const native = c.gtk_file_chooser_native_new(title_z.ptr, parent, c.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER, "选择", "取消") orelse
                return error.DialogNotAvailable;
            defer c.g_object_unref(@ptrCast(native));
            const chooser: *c.GtkFileChooser = @ptrCast(native);
            if (c.gtk_native_dialog_run(@alignCast(@ptrCast(native))) != c.GTK_RESPONSE_ACCEPT) return null;
            const chosen = c.gtk_file_chooser_get_filename(chooser);
            if (chosen == null) return null;
            defer c.g_free(@ptrCast(chosen));
            return try alloc.dupe(u8, std.mem.span(chosen));
        }

        fn filesDialog(self: *Self, alloc: std.mem.Allocator, parent: [*c]c.GtkWindow, opts: ipc.FileDialogOptions) !?[][]u8 {
            _ = self;
            const native = (try nativeChooser(alloc, parent, opts, .open)) orelse return error.DialogNotAvailable;
            defer c.g_object_unref(@ptrCast(native));
            const chooser: *c.GtkFileChooser = @ptrCast(native);
            c.gtk_file_chooser_set_select_multiple(chooser, 1);
            if (c.gtk_native_dialog_run(@alignCast(@ptrCast(native))) != c.GTK_RESPONSE_ACCEPT) return null;

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
            defer c.gtk_widget_destroy(dlg);
            c.gtk_color_chooser_set_use_alpha(@ptrCast(dlg), 0);
            var rgba = c.GdkRGBA{
                .red = @as(f32, @floatFromInt(opts.default_rgb >> 16 & 0xFF)) / 255.0,
                .green = @as(f32, @floatFromInt(opts.default_rgb >> 8 & 0xFF)) / 255.0,
                .blue = @as(f32, @floatFromInt(opts.default_rgb & 0xFF)) / 255.0,
                .alpha = 1.0,
            };
            c.gtk_color_chooser_set_rgba(@ptrCast(dlg), &rgba);
            if (c.gtk_dialog_run(@ptrCast(dlg)) != c.GTK_RESPONSE_OK) return null;
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
            if (dlg == null) return error.DialogNotAvailable;
            defer c.gtk_widget_destroy(dlg);
            if (c.gtk_dialog_run(@ptrCast(dlg)) != c.GTK_RESPONSE_OK) return null;

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
            defer c.gtk_widget_destroy(dlg);
            const chooser: *c.GtkFileChooser = @ptrCast(dlg);
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
                // v0.2.2：运行时菜单模型 / 系统信息 / 自启动
                .menu => |op| return self.runMenuOp(op, alloc),
                .info => |kind| return .{ .json = try self.collectSystemInfo(kind, alloc) },
                .autostart => |op| return .{ .state = try self.runAutostartOp(op, alloc) },
                // v0.2.3：存储 / fs / ACL / SQL / http / ws
                .store => |op| return self.runStoreOp(op, alloc),
                .fs => |op| return self.runFsOp(op, alloc),
                .acl => |op| return self.runAclOp(op, alloc),
                .sql => |op| return self.runSqlOp(op, alloc),
                .http => |op| return self.runHttpOp(op, alloc),
                .ws => |op| return self.runWsOp(op, alloc),
                // 托盘运行时 op/快捷键/process/... 属后续版本；NotSupported
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
        // 系统信息（v0.2.2）：/etc/os-release + locale/theme 推导 + GDK 显示器
        // JSON 形状与 Windows 同构（shared sysinfo.osToJson / monitorsToJson）
        // ------------------------------------------------------------------

        fn collectSystemInfo(self: *Self, kind: system_api.InfoKind, alloc: std.mem.Allocator) ![]u8 {
            switch (kind) {
                .os => {
                    var info = try self.collectOsInfo(alloc);
                    defer sysinfo_linux.freeOsInfo(alloc, &info);
                    return shared_sysinfo.osToJson(alloc, info);
                },
                .monitors => {
                    const monitors = try self.collectMonitors(alloc);
                    defer alloc.free(monitors);
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
            }
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
            const n: usize = @intCast(c.gdk_display_get_n_monitors(display));
            const out = try alloc.alloc(shared_sysinfo.Monitor, n);
            errdefer alloc.free(out);
            const primary = c.gdk_display_get_primary_monitor(display);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const mon = c.gdk_display_get_monitor(display, @intCast(i));
                var geom: c.GdkRectangle = std.mem.zeroes(c.GdkRectangle);
                var work: c.GdkRectangle = std.mem.zeroes(c.GdkRectangle);
                var scale: c_int = 1;
                if (mon != null) {
                    c.gdk_monitor_get_geometry(mon, &geom);
                    c.gdk_monitor_get_workarea(mon, &work);
                    scale = c.gdk_monitor_get_scale_factor(mon);
                }
                const scale_abs: u32 = @intCast(@max(1, scale));
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
                    .dpi = scale_abs * 96,
                    .scale = @floatFromInt(scale_abs),
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
                    return .{ .json = try std.json.Stringify.valueAlloc(alloc, v, .{}) };
                },
                .set => |kv| {
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
                    job.* = .{
                        .backend = self,
                        .id = id,
                        .path = a2.dupe(u8, path) catch {
                            a2.destroy(job);
                            return error.OutOfMemory;
                        },
                        .chunk_size = @min(@max(req.chunk_size, 4096), 1024 * 1024),
                    };
                    const t = std.Thread.spawn(.{ .stack_size = sys.threadStackSize(256 * 1024) }, fsStreamMain, .{job}) catch {
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
            defer {
                a2.free(job.path);
                a2.destroy(job);
            }
            // 一次读入（上限沿用 fs 读限制），再按 chunk 切片发事件——
            // 0.17 的 Io.File 流式读 API 面向 reader 接口，这里内存版足够
            //（fs.read 本身也是 32MB 上限）。
            const data = std.Io.Dir.cwd().readFileAlloc(sharedIo(), job.path, a2, .limited((fs_api_mod.Limits{}).max_read)) catch {
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
            const req = op.request;
            // v0.1.21 对齐：http scope 走 ACL（含 URL 形式资源）
            if (!self.aclAllowed("http", req.url)) {
                log.print("[http] denied: {s}", .{req.url});
                return error.PermissionDenied;
            }
            return self.httpRequestStart(req, alloc);
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
            if (req.multipart) |parts| {
                const conv = try self.allocator.alloc(shared_net.Part, parts.len);
                defer self.allocator.free(conv);
                for (parts, 0..) |mp, i| {
                    conv[i] = .{ .name = mp.name, .data = mp.data, .filename = mp.filename, .content_type = mp.content_type };
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
                // libsoup3 的 SoupMessage:follow-redirects 属性（缺失时 GLib 记警告但不崩）
                c.g_object_set(@ptrCast(msg), "follow-redirects", @as(c.gboolean, 0), @as(?*anyopaque, null));
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
            };
            if (job.session == null) return error.SoupUnavailable;

            log.print("[http] {s} {s} (id={d}, stream={s}, proxy={s})", .{
                req.method, req.url, id, boolStr(req.stream), req.proxy orelse "-",
            });
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
        // 应用自定义协议 → 真 scheme（v0.2.3；每协议一个 scheme，URI 形态
        // <name>://<rest>?<query>，对应 Windows 的 /__proto/<name>/<rest>）
        // ------------------------------------------------------------------

        fn registerProtocolSchemes(self: *Self, wc: [*c]c.WebKitWebContext) void {
            for (config.protocols) |p| {
                const name_z = dupeZ(self.allocator, p.name) catch continue;
                defer self.allocator.free(name_z);
                c.webkit_web_context_register_uri_scheme(wc, name_z.ptr, Self.onProtocolRequest, self, null);
                log.print("[proto] scheme '{s}' registered", .{p.name});
            }
        }

        fn onProtocolRequest(request: [*c]c.WebKitURISchemeRequest, user_data: c.gpointer) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            self.serveProtocol(request);
        }

        fn serveProtocol(self: *Self, request: [*c]c.WebKitURISchemeRequest) void {
            const uri_ptr = c.webkit_uri_scheme_request_get_uri(request);
            const uri = if (uri_ptr != null) std.mem.span(uri_ptr) else "";
            const sep = std.mem.indexOf(u8, uri, "://") orelse return self.finishProtocolError(request, 400, "bad uri");
            const name = uri[0..sep];
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

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const resp = p.handle(.{
                .name = name,
                .path = path,
                .query = query,
                .method = method,
                .user_agent = user_agent,
                .url = uri,
            }, arena.allocator()) catch |err| {
                log.print("[proto] {s} handler failed: {s}", .{ name, @errorName(err) });
                return self.finishProtocolError(request, 500, "handler failed");
            };
            log.print("[proto] {s} {s}/{s} {d} bytes", .{ name, method, path, resp.body.len });
            self.finishProtocol(request, resp);
        }

        fn finishProtocol(self: *Self, request: [*c]c.WebKitURISchemeRequest, resp: protocol.Response) void {
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

        fn finishProtocolError(self: *Self, request: [*c]c.WebKitURISchemeRequest, status: u16, body: []const u8) void {
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
            const self = sink.backend;
            if (self.windowById(sink.win_id)) |w| w.loaded = true;
            self.diagnoseRuntime(sink.view);
            // 启动深链兜底：页面就绪后补发（窗口未就绪时 handleLaunchArgs 挂起的载荷）
            self.flushPendingLaunch();
        }

        // ------------------------------------------------------------------
        // 拖放（v0.2.2）：文件拖入 → dropFiles {files}
        // ------------------------------------------------------------------

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
            self.requestQuit();
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
            // 全部窗口都销毁才退出主循环（primary / 降级两种主循环形态统一走这里）
            if (self.windows.items.len == 0) {
                log.print("[linux] all windows destroyed -> quit main loop", .{});
                self.requestQuit();
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

test "parseAccelGtk: 修饰符组合 / 键位 / 非法输入" {
    const cases = [_]struct { accel: []const u8, mods: c.GdkModifierType, keyval: c.guint }{
        .{ .accel = "Ctrl+S", .mods = c.GDK_CONTROL_MASK, .keyval = 'S' },
        .{ .accel = "Ctrl+N", .mods = c.GDK_CONTROL_MASK, .keyval = 'N' },
        .{ .accel = "Ctrl+Alt+N", .mods = c.GDK_CONTROL_MASK | c.GDK_MOD1_MASK, .keyval = 'N' },
        .{ .accel = "Ctrl+Shift+P", .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .keyval = 'P' },
        .{ .accel = "Alt+F4", .mods = c.GDK_MOD1_MASK, .keyval = 0xffbe + 3 },
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
