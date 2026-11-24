//! GTK 变体差异收敛点（v0.2.5 建立，v0.4.3 L1b 全面扩展）。
//!
//! 构建变体由 `zig build -Dgtk=gtk4` 选择（build.zig 切换 pkg-config 包名：
//! gtk3 → `gtk+-3.0` + `webkit2gtk-4.1`；gtk4 → `gtk4` + `webkitgtk-6.0`），
//! 本文件收敛**代码侧**的 API 差异。capi.h 按 `GTK_MAJOR_VERSION` 选择头
//!（pkg-config 只注入所选包的 -I，判据与链接库严格一致）。
//!
//! 实现模式：每个差异面提供**双栈签名同型**的 shim——
//!   * GTK3 分支 = 既有调用的逐字搬运（零回归基线）；
//!   * GTK4 分支 = GDK4 等价物（GdkClipboard / GtkDropTarget / GtkPopoverMenu /
//!     GtkFileDialog / GdkToplevelLayout / X11 EWMH 直连）。
//! 分支体经 comptime 消除：GTK3 构建不引用 4.x 符号，反之亦然——
//! 72 个 GTK4 移除符号（gtkaudit.sh 审计）全部收敛于此或调用点守卫。
//!
//! GTK4 已知限制（文档化，见 ROADMAP L1b；代码侧登记在 `caps()`）：
//!   * 托盘：libayatana-appindicator3 为 GTK3 链接库，4.x 进程不可载 → 无托盘；
//!   * drag.start（脚本发起拖拽）：GDK4 无公开 begin 入口 → DragNotAvailable；
//!   * 菜单栏（config.menu）：GtkMenuBar 已移除 → menuBarAvailable()=false；
//!   * 指针抓取 / 按域清 cookie：4.14 capi 无 gdk_seat_grab、6.0 无
//!     delete_cookies_for_domain → 调用点守卫；
//!   * Wayland 几何：position/move 无全局坐标概念 → X11 直连仅 X11 生效。

const std = @import("std");
const c = @import("gtk");

pub const Variant = enum { gtk3, gtk4 };

/// 当前变体：按 `gtk_init` 的参数个数在编译期判定
///（GTK3 = 2 参；GTK4 = 0 参）。
pub const variant: Variant = blk: {
    const F = @TypeOf(c.gtk_init);
    const n = @typeInfo(F).@"fn".param_types.len;
    break :blk if (n == 0) Variant.gtk4 else Variant.gtk3;
};

pub fn isGtk4() bool {
    return variant == .gtk4;
}

pub fn isGtk3() bool {
    return variant == .gtk3;
}

/// gtk_init：GTK3 带 (argc, argv)，GTK4 无参。
pub fn gtkInit() void {
    const F = @TypeOf(c.gtk_init);
    const n = @typeInfo(F).@"fn".param_types.len;
    if (n == 0) {
        c.gtk_init();
    } else {
        c.gtk_init(null, null);
    }
}

/// GDK 修饰符掩码（v0.4.3 L1b）：`GDK_MOD1_MASK` 在 GTK4 头中更名 `GDK_ALT_MASK`、
/// `GDK_MOD2_MASK` 整体移除。位序跨版本稳定（X11/XGrabKey 语义不变）：
/// MOD1 = 1<<3、MOD2 = 1<<4，故以数值回退收敛双栈。
/// MOD 掩码：无类型 comptime_int——GdkModifierType 在两栈 translate-c 里都是
/// 整数 typedef（c_int/c_uint），位运算按使用点类型收敛；数值双栈一致
///（X11 位序）：MOD1=1<<3、MOD2=1<<4。
pub const MOD1_MASK = 1 << 3;
pub const MOD2_MASK = 1 << 4;

/// 菜单栏构造在 GTK4 下不可用（GtkMenuBar 已移除）——
/// 调用方据此降级为「无菜单栏」。
pub fn menuBarAvailable() bool {
    return caps().menu_bar;
}

/// 变体能力表（v0.5.9）：降级面集中登记一处，冒烟脚本据此显式 skip，
/// 而不是把「GTK4 没有这个面」当成失败。
pub const Caps = struct {
    tray: bool,
    menu_bar: bool,
    programmatic_drag: bool,
    cursor_grab: bool,
    cookie_clear_by_domain: bool,
    clipboard_read: bool,
};

pub fn caps() Caps {
    return .{
        .tray = isGtk3(),
        .menu_bar = isGtk3(),
        .programmatic_drag = isGtk3(),
        .cursor_grab = isGtk3(),
        .cookie_clear_by_domain = isGtk3(),
        .clipboard_read = true,
    };
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// 冒烟注入载荷（`window.__ziltSmokeCaps`）。缓冲不足 → null。
pub fn capsJson(buf: []u8) ?[]const u8 {
    const cp = caps();
    return std.fmt.bufPrint(
        buf,
        "{{\"tray\":{s},\"menu_bar\":{s},\"programmatic_drag\":{s},\"cursor_grab\":{s}," ++
            "\"cookie_clear_by_domain\":{s},\"clipboard_read\":{s}}}",
        .{
            boolStr(cp.tray),
            boolStr(cp.menu_bar),
            boolStr(cp.programmatic_drag),
            boolStr(cp.cursor_grab),
            boolStr(cp.cookie_clear_by_domain),
            boolStr(cp.clipboard_read),
        },
    ) catch null;
}

// ---------------------------------------------------------------------------
// 主循环（gtk_main / gtk_main_quit 在 GTK4 移除）
// ---------------------------------------------------------------------------

var main_loop: ?*c.GMainLoop = null;

pub fn mainLoopRun() void {
    if (comptime isGtk4()) {
        main_loop = c.g_main_loop_new(null, 0);
        c.g_main_loop_run(main_loop);
        if (main_loop) |lp| c.g_main_loop_unref(lp);
        main_loop = null;
        return;
    }
    c.gtk_main();
}

pub fn mainLoopQuit() void {
    if (comptime isGtk4()) {
        if (main_loop) |lp| c.g_main_loop_quit(lp);
        return;
    }
    c.gtk_main_quit();
}

// ---------------------------------------------------------------------------
// 异步 → 同步桥（SyncWait）：GDK4 的剪贴板/对话框全异步，框架 IPC 面是同步的。
// 与 GTK3 的 gtk_dialog_run 语义同构——嵌套运行默认主上下文直至回调完成。
// 单主线程串行（嵌套循环一次只有一个）→ 结果槽为模块级静态是安全的。
// ---------------------------------------------------------------------------

pub const SyncWait = struct {
    loop: ?*c.GMainLoop = null,
    result: ?*c.GAsyncResult = null,
    source: ?*c.GObject = null,
    done: bool = false,

    pub fn begin() SyncWait {
        return .{ .loop = c.g_main_loop_new(null, 0) };
    }

    /// 在 GAsyncReadyCallback 里调用：记录结果并退出嵌套循环。
    pub fn finish(self: *SyncWait) void {
        self.done = true;
        if (self.loop) |lp| c.g_main_loop_quit(lp);
    }

    /// 阻塞等待完成（调用 finish 之后返回；随后释放循环）。
    pub fn wait(self: *SyncWait) void {
        if (self.loop) |lp| c.g_main_loop_run(lp);
        if (self.loop) |lp| c.g_main_loop_unref(lp);
        self.loop = null;
    }

    /// 交出结果引用（消费方在 xxx_finish 之后 defer 调用）。
    pub fn releaseResult(self: *SyncWait) void {
        if (self.result) |r| c.g_object_unref(@ptrCast(r));
        self.result = null;
    }
};

/// 通用 GAsyncReadyCallback：只存结果 + 退出嵌套循环。
/// 与 SyncWait 搭配：finish(read_xxx_finish(wait.result, &err))。
pub fn onAsyncReady(
    source: ?*c.GObject,
    result: ?*c.GAsyncResult,
    user_data: c.gpointer,
) callconv(.c) void {
    const w: *SyncWait = @ptrCast(@alignCast(user_data orelse return));
    w.source = source;
    // GAsyncResult 的存活期只到本回调返回为止，而消费方在 wait() 之后才
    // xxx_finish(result)——不自己持一份引用就是 use-after-free + 二次释放。
    w.result = null;
    if (result) |r| {
        const held: ?*anyopaque = c.g_object_ref(@ptrCast(r));
        w.result = @ptrCast(held);
    }
    w.finish();
}

// ---------------------------------------------------------------------------
// 窗口构造 / 销毁 / 显示
// ---------------------------------------------------------------------------

/// 窗口构造（GTK4 的 gtk_window_new 无参——类型参数随 4.x 窗口模型移除）。
pub fn windowNew() ?*c.GtkWindow {
    if (comptime isGtk4()) {
        return @ptrCast(c.gtk_window_new());
    }
    return @ptrCast(c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL));
}

/// toplevel 窗口销毁（GTK3 gtk_widget_destroy / GTK4 gtk_window_destroy——
/// 后者异步销毁且先断开信号，destroy 处理器语义不变）。
pub fn windowDestroy(win: [*c]c.GtkWindow) void {
    if (comptime isGtk4()) {
        c.gtk_window_destroy(@ptrCast(@alignCast(win)));
        return;
    }
    c.gtk_widget_destroy(@ptrCast(win));
}

/// show_all：GTK4 无递归 show——自上而下逐层置 visible（映射随父级传播）。
pub fn showAll(w: [*c]c.GtkWidget) void {
    if (comptime isGtk4()) {
        setVisibleRecursive(w);
        return;
    }
    c.gtk_widget_show_all(w);
}

fn setVisibleRecursive(w: [*c]c.GtkWidget) void {
    c.gtk_widget_set_visible(w, 1);
    var child = c.gtk_widget_get_first_child(w);
    while (child != null) : (child = c.gtk_widget_get_next_sibling(child)) {
        setVisibleRecursive(child);
    }
}

/// GtkBox pack_start（GTK4 → append；本框架使用 expand=FALSE 语义，
/// append 与之一致——expand 的调用点无）。
pub fn boxPackStart(box: [*c]c.GtkBox, child: [*c]c.GtkWidget) void {
    if (comptime isGtk4()) {
        c.gtk_box_append(box, child);
        return;
    }
    c.gtk_box_pack_start(box, child, 0, 0, 0);
}

/// 装箱（expand+fill）：主内容区（WebView/GtkOverlay）必须占满剩余空间。
/// v0.4.3 L3 实测：用上面的 boxPackStart（expand=0）装 overlay 会让 WebView
/// 只分到 1px 高——窗口其余区域空白，截图快照 800x1。
pub fn boxPackStartFill(box: [*c]c.GtkBox, child: [*c]c.GtkWidget) void {
    if (comptime isGtk4()) {
        c.gtk_box_append(box, child);
        return;
    }
    c.gtk_box_pack_start(box, child, 1, 1, 0);
}

// ---------------------------------------------------------------------------
// X11 直连底座（GTK4 的窗口几何/状态面：GDK4 刻意移除了 position API——
// X11 下经 Xlib/EWMH 直连保语义，Wayland 下按规范无全局坐标 → no-op）
// ---------------------------------------------------------------------------

const X11Ctx = struct {
    dpy: *c.Display,
    xwin: c.Window,
    surface: ?*c.GdkSurface,
};

/// 解析窗口的 X11 句柄。Wayland（或未 realize）→ null。
/// gdk_x11_display_get_xdisplay / gdk_x11_surface_get_xid 对非 X11 对象
/// 返回 NULL/0（g_return_val_if_fail 路径），不会中止进程。
fn x11Of(widget: [*c]c.GtkWidget) ?X11Ctx {
    const surface = c.gtk_native_get_surface(@ptrCast(widget)) orelse return null;
    const display = c.gtk_widget_get_display(widget) orelse return null;
    const dpy = c.gdk_x11_display_get_xdisplay(display) orelse return null;
    const xwin = c.gdk_x11_surface_get_xid(surface);
    if (xwin == 0) return null;
    return .{ .dpy = dpy, .xwin = xwin, .surface = surface };
}

fn rootWindowOf(dpy: *c.Display) c.Window {
    return c.XDefaultRootWindow(dpy);
}

fn internAtom(dpy: *c.Display, name: [*c]const u8) c.Atom {
    return c.XInternAtom(dpy, name, c.False);
}

/// EWMH _NET_WM_STATE ClientMessage（keep_above/below/sticky/skip_taskbar）。
fn ewmhSetState(dpy: *c.Display, xwin: c.Window, prop: [*c]const u8, add: bool) void {
    var ev: c.XEvent = std.mem.zeroes(c.XEvent);
    ev.xclient.type = c.ClientMessage;
    ev.xclient.window = xwin;
    ev.xclient.message_type = internAtom(dpy, "_NET_WM_STATE");
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = if (add) 1 else 0; // _NET_WM_STATE_ADD / REMOVE
    ev.xclient.data.l[1] = @intCast(internAtom(dpy, prop));
    ev.xclient.data.l[2] = 0;
    ev.xclient.data.l[3] = 1; // source indication: application
    ev.xclient.data.l[4] = 0;
    _ = c.XSendEvent(dpy, rootWindowOf(dpy), c.False, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &ev);
    _ = c.XFlush(dpy);
}

// ---------------------------------------------------------------------------
// 窗口几何 / 状态面（gtk_window_move/resize/get_size/get_position、
// keep_above/below、iconify/stick/skip_taskbar/accept_focus、
// geometry_hints、fullscreen_on_monitor、begin_move/resize_drag）
// ---------------------------------------------------------------------------

pub fn windowMove(win: [*c]c.GtkWindow, x: c_int, y: c_int) void {
    if (comptime isGtk4()) {
        if (x11Of(@ptrCast(win))) |x11| {
            _ = c.XMoveWindow(x11.dpy, x11.xwin, @intCast(x), @intCast(y));
            _ = c.XFlush(x11.dpy);
        } // Wayland：无全局坐标 → no-op（文档化）
        return;
    }
    c.gtk_window_move(win, x, y);
}

pub fn windowResize(win: [*c]c.GtkWindow, width: c_int, height: c_int) void {
    if (comptime isGtk4()) {
        if (x11Of(@ptrCast(win))) |x11| {
            _ = c.XResizeWindow(x11.dpy, x11.xwin, @intCast(width), @intCast(height));
            _ = c.XFlush(x11.dpy);
            return;
        }
        // Wayland：尺寸经 GTK 布局面（default-size 是唯一受支持的请求通道）
        c.gtk_window_set_default_size(win, width, height);
        return;
    }
    c.gtk_window_resize(win, width, height);
}

pub fn windowGetSize(win: [*c]c.GtkWindow, width: *c_int, height: *c_int) void {
    if (comptime isGtk4()) {
        if (c.gtk_native_get_surface(@ptrCast(win))) |surface| {
            const w: c_int = @intCast(c.gdk_surface_get_width(surface));
            const h: c_int = @intCast(c.gdk_surface_get_height(surface));
            if (w > 1 and h > 1) {
                width.* = w;
                height.* = h;
                return;
            }
        }
        // 未映射/占位 surface（≤1px）→ default size（与 GTK3 get_size 的
        // 未映射语义对齐：返回请求尺寸而非占位值）
        var dw: c.gint = 0;
        var dh: c.gint = 0;
        c.gtk_window_get_default_size(win, &dw, &dh);
        width.* = dw;
        height.* = dh;
        return;
    }
    c.gtk_window_get_size(win, width, height);
}

pub fn windowGetPosition(win: [*c]c.GtkWindow, x: *c_int, y: *c_int) void {
    if (comptime isGtk4()) {
        if (x11Of(@ptrCast(win))) |x11| {
            var child: c.Window = 0;
            var rx: c_int = 0;
            var ry: c_int = 0;
            // 对根窗口平移 (0,0) → 返回的即根坐标
            _ = c.XTranslateCoordinates(x11.dpy, x11.xwin, rootWindowOf(x11.dpy), 0, 0, &rx, &ry, &child);
            x.* = rx;
            y.* = ry;
            return;
        }
        x.* = 0;
        y.* = 0;
        return;
    }
    c.gtk_window_get_position(win, x, y);
}

pub fn setKeepAbove(win: [*c]c.GtkWindow, on: bool) void {
    if (comptime isGtk4()) {
        // GDK4 无 keep-above 布局位（toplevel layout 仅 maximized/fullscreen/
        // resizable）→ X11 EWMH；Wayland no-op（文档化）
        if (x11Of(@ptrCast(win))) |x11| {
            ewmhSetState(x11.dpy, x11.xwin, "_NET_WM_STATE_ABOVE", on);
        }
        return;
    }
    c.gtk_window_set_keep_above(win, @intFromBool(on));
}

pub fn setKeepBelow(win: [*c]c.GtkWindow, on: bool) void {
    if (comptime isGtk4()) {
        if (x11Of(@ptrCast(win))) |x11| {
            ewmhSetState(x11.dpy, x11.xwin, "_NET_WM_STATE_BELOW", on);
        }
        return;
    }
    c.gtk_window_set_keep_below(win, @intFromBool(on));
}

pub fn setIconic(win: [*c]c.GtkWindow, iconic: bool) void {
    if (comptime isGtk4()) {
        // GDK4 无 iconic 布局位（iconify API 整体移除）→ X11 XIconifyWindow；
        // Wayland 最小化由 compositor 决定 → no-op（文档化）
        if (iconic) {
            if (x11Of(@ptrCast(win))) |x11| {
                _ = c.XIconifyWindow(x11.dpy, x11.xwin, c.XDefaultScreen(x11.dpy));
                _ = c.XFlush(x11.dpy);
            }
            return;
        }
        c.gtk_window_present(win);
        return;
    }
    if (iconic) c.gtk_window_iconify(win) else _ = c.gtk_window_deiconify(win);
}

pub fn setSticky(win: [*c]c.GtkWindow, on: bool) void {
    if (comptime isGtk4()) {
        if (x11Of(@ptrCast(win))) |x11| {
            ewmhSetState(x11.dpy, x11.xwin, "_NET_WM_STATE_STICKY", on);
        } // Wayland：compositor 概念 → no-op（文档化）
        return;
    }
    if (on) c.gtk_window_stick(win) else c.gtk_window_unstick(win);
}

pub fn setSkipTaskbar(win: [*c]c.GtkWindow, on: bool) void {
    if (comptime isGtk4()) {
        if (x11Of(@ptrCast(win))) |x11| {
            ewmhSetState(x11.dpy, x11.xwin, "_NET_WM_STATE_SKIP_TASKBAR", on);
        } // Wayland：无对等（文档化）
        return;
    }
    c.gtk_window_set_skip_taskbar_hint(win, @intFromBool(on));
}

pub fn setAcceptFocus(win: [*c]c.GtkWindow, on: bool) void {
    if (comptime isGtk4()) {
        // GDK4 无 accept-focus 布局位 → X11 WM_HINTS.input；Wayland no-op
        if (x11Of(@ptrCast(win))) |x11| {
            var hints = c.XGetWMHints(x11.dpy, x11.xwin);
            if (hints == null) {
                hints = c.XAllocWMHints();
            }
            if (hints) |h| {
                h.*.input = if (on) 1 else 0;
                h.*.flags |= c.InputHint;
                _ = c.XSetWMHints(x11.dpy, x11.xwin, h);
                _ = c.XFree(@ptrCast(h));
                _ = c.XFlush(x11.dpy);
            }
        }
        return;
    }
    c.gtk_window_set_accept_focus(win, @intFromBool(on));
}

pub fn getAcceptFocus(win: [*c]c.GtkWindow) bool {
    if (comptime isGtk4()) {
        // 读取经 X11 WM_HINTS；Wayland 无 API → 恒 true（文档化）
        if (x11Of(@ptrCast(win))) |x11| {
            if (c.XGetWMHints(x11.dpy, x11.xwin)) |h| {
                const accept = (h.*.flags & c.InputHint) == 0 or h.*.input != 0;
                _ = c.XFree(@ptrCast(h));
                return accept;
            }
        }
        return true;
    }
    return c.gtk_window_get_accept_focus(win) != 0;
}

/// 尺寸约束（min/max；0 = 无约束）。
/// GTK3：gtk_window_set_geometry_hints（既有语义）。
/// GTK4：X11 → XSetWMNormalHints（PMinSize/PMaxSize）；Wayland → min 经
/// set_size_request（GTK 布局面），max 无对等 → skip（文档化）。
pub fn applyGeometryHints(win: [*c]c.GtkWindow, min_w: u32, min_h: u32, max_w: u32, max_h: u32) void {
    if (comptime isGtk4()) {
        if (x11Of(@ptrCast(win))) |x11| {
            var hints: c.XSizeHints = std.mem.zeroes(c.XSizeHints);
            hints.flags = 0;
            if (min_w != 0 or min_h != 0) {
                hints.flags |= c.PMinSize;
                hints.min_width = @intCast(min_w);
                hints.min_height = @intCast(min_h);
            }
            if (max_w != 0 or max_h != 0) {
                hints.flags |= c.PMaxSize;
                hints.max_width = @intCast(max_w);
                hints.max_height = @intCast(max_h);
            }
            if (hints.flags != 0) _ = c.XSetWMNormalHints(x11.dpy, x11.xwin, &hints);
            _ = c.XFlush(x11.dpy);
            return;
        }
        if (min_w != 0 or min_h != 0) {
            c.gtk_widget_set_size_request(@ptrCast(win), @intCast(min_w), @intCast(min_h));
        }
        return;
    }
    var geom: c.GdkGeometry = std.mem.zeroes(c.GdkGeometry);
    var flags: c.GdkWindowHints = 0;
    if (min_w != 0 or min_h != 0) {
        geom.min_width = @intCast(min_w);
        geom.min_height = @intCast(min_h);
        flags |= c.GDK_HINT_MIN_SIZE;
    }
    if (max_w != 0 or max_h != 0) {
        geom.max_width = @intCast(max_w);
        geom.max_height = @intCast(max_h);
        flags |= c.GDK_HINT_MAX_SIZE;
    }
    // geometry_widget 传 null = 约束相对窗口自身
    c.gtk_window_set_geometry_hints(win, null, &geom, flags);
}

/// 全屏到指定显示器（gdk_display 枚举序）。失败（无显示器）返回 false。
pub fn fullscreenOnMonitor(win: [*c]c.GtkWindow, monitor_index: u32) bool {
    if (comptime isGtk4()) {
        const display = c.gdk_display_get_default() orelse return false;
        if (monitor_index >= @as(u32, @intCast(displayMonitorCount(display)))) return false;
        const monitor = displayMonitorAtIdx(display, @intCast(monitor_index)) orelse return false;
        if (c.gtk_native_get_surface(@ptrCast(win))) |surface| {
            const layout = c.gdk_toplevel_layout_new();
            c.gdk_toplevel_layout_set_fullscreen(layout, 1, @ptrCast(@alignCast(monitor)));
            c.gdk_toplevel_present(@ptrCast(@alignCast(surface)), layout);
            c.g_object_unref(@ptrCast(layout));
        }
        return true;
    }
    const screen = c.gdk_screen_get_default() orelse return false;
    if (monitor_index >= @as(u32, @intCast(c.gdk_screen_get_n_monitors(screen)))) return false;
    c.gtk_window_fullscreen_on_monitor(win, screen, @intCast(monitor_index));
    return true;
}

/// 内容区拖拽移动（无鼠标事件上下文也能拖：取指针 + GLib 事件时间戳）。
/// GTK4：gdk_toplevel_begin_move（需要交互设备；Xvfb 无 WM 时与 GTK3 同为 no-op）。
pub fn beginMoveDrag(win: [*c]c.GtkWindow, x_root: c_int, y_root: c_int) void {
    // gtk_get_current_event_time 在 GTK4 移除 → GDK_CURRENT_TIME（0）
    const time: c.guint32 = 0;
    if (comptime isGtk4()) {
        if (c.gtk_native_get_surface(@ptrCast(win))) |surface| {
            const display = c.gdk_display_get_default() orelse return;
            const seat = c.gdk_display_get_default_seat(display) orelse return;
            const pointer = c.gdk_seat_get_pointer(seat) orelse return;
            c.gdk_toplevel_begin_move(@ptrCast(@alignCast(surface)), pointer, 1, @as(f64, @floatFromInt(x_root)), @as(f64, @floatFromInt(y_root)), time);
        }
        return;
    }
    c.gtk_window_begin_move_drag(win, 1, x_root, y_root, time);
}

/// 窗口边缘常量（GdkWindowEdge/GdkSurfaceEdge 数值一致：0..7）。
pub const EDGE_NORTH_WEST: c_int = 0;
pub const EDGE_NORTH: c_int = 1;
pub const EDGE_NORTH_EAST: c_int = 2;
pub const EDGE_WEST: c_int = 3;
pub const EDGE_EAST: c_int = 4;
pub const EDGE_SOUTH_WEST: c_int = 5;
pub const EDGE_SOUTH: c_int = 6;
pub const EDGE_SOUTH_EAST: c_int = 7;

pub fn beginResizeDrag(win: [*c]c.GtkWindow, edge_int: c_int, x_root: c_int, y_root: c_int) void {
    // 同 beginMoveDrag：GTK4 → GDK_CURRENT_TIME
    const time: c.guint32 = 0;
    if (comptime isGtk4()) {
        if (c.gtk_native_get_surface(@ptrCast(win))) |surface| {
            const display = c.gdk_display_get_default() orelse return;
            const seat = c.gdk_display_get_default_seat(display) orelse return;
            const pointer = c.gdk_seat_get_pointer(seat) orelse return;
            // capi 形状：(toplevel, edge, device, button, x, y, time)；edge 与
            // GTK3 的 GDK_WINDOW_EDGE 数值一致（0..7）
            c.gdk_toplevel_begin_resize(@ptrCast(@alignCast(surface)), @as(c_uint, @intCast(edge_int)), pointer, 1, @as(f64, @floatFromInt(x_root)), @as(f64, @floatFromInt(y_root)), time);
        }
        return;
    }
    c.gtk_window_begin_resize_drag(win, @as(c_uint, @intCast(edge_int)), 1, x_root, y_root, time);
}

// ---------------------------------------------------------------------------
// surface 读取面（H9 物理像素 / 状态查询）
// ---------------------------------------------------------------------------

/// 窗口 GdkSurface（GTK3 GdkWindow / GTK4 GdkSurface——只作不透明句柄传递）。
pub fn surfaceOf(widget: [*c]c.GtkWidget) ?*anyopaque {
    if (comptime isGtk4()) {
        return c.gtk_native_get_surface(@ptrCast(widget));
    }
    return c.gtk_widget_get_window(widget);
}

pub fn surfaceIconified(widget: [*c]c.GtkWidget) bool {
    if (comptime isGtk4()) {
        // GDK4 无 state 读取 API → X11 _NET_WM_STATE 含 HIDDEN；Wayland → false
        const x11 = x11Of(widget) orelse return false;
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        _ = c.XGetWindowProperty(x11.dpy, x11.xwin, internAtom(x11.dpy, "_NET_WM_STATE"), 0, 64, c.False, @as(c.Atom, 4), &actual_type, &actual_format, &nitems, &bytes_after, &prop); // XA_ATOM=4（宏未入 capi）
        var hidden = false;
        if (prop) |p| {
            const atoms: [*c]const c.Atom = @ptrCast(@alignCast(p));
            const hidden_atom = internAtom(x11.dpy, "_NET_WM_STATE_HIDDEN");
            var i: c_ulong = 0;
            while (i < nitems) : (i += 1) {
                if (atoms[i] == hidden_atom) {
                    hidden = true;
                    break;
                }
            }
            _ = c.XFree(@ptrCast(p));
        }
        return hidden;
    }
    const gdk_win = c.gtk_widget_get_window(widget) orelse return false;
    return (c.gdk_window_get_state(gdk_win) & c.GDK_WINDOW_STATE_ICONIFIED) != 0;
}

/// 缩放系数（整数化；GTK4 的 get_scale 为 double）。
pub fn surfaceScale(widget: [*c]c.GtkWidget) c_int {
    if (comptime isGtk4()) {
        const surface = c.gtk_native_get_surface(@ptrCast(widget)) orelse return 1;
        const s = c.gdk_surface_get_scale(surface);
        return @intFromFloat(@round(s));
    }
    const gdk_win = c.gtk_widget_get_window(widget) orelse return 1;
    return c.gdk_window_get_scale_factor(gdk_win);
}

/// 外框矩形（frame extents）。GTK4：X11 读 _NET_FRAME_EXTENTS；Wayland → false。
pub fn frameExtents(widget: [*c]c.GtkWidget, out: *c.GdkRectangle) bool {
    if (comptime isGtk4()) {
        const x11 = x11Of(widget) orelse return false;
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        const extents_atom = internAtom(x11.dpy, "_NET_FRAME_EXTENTS");
        if (c.XGetWindowProperty(x11.dpy, x11.xwin, extents_atom, 0, 4, c.False, @as(c.Atom, 6), &actual_type, &actual_format, &nitems, &bytes_after, &prop) == 0 and nitems == 4) { // XA_CARDINAL=6
            if (prop) |p| {
                const vals: [*c]const c_ulong = @ptrCast(@alignCast(p));
                // EWMH 顺序：left, right, top, bottom（CARDINAL 无符号 → 显式宽化）
                const left: i64 = @intCast(vals[0]);
                const right: i64 = @intCast(vals[1]);
                const top: i64 = @intCast(vals[2]);
                const bottom: i64 = @intCast(vals[3]);
                out.x = @intCast(-left);
                out.y = @intCast(-top);
                out.width = @intCast(right + left);
                out.height = @intCast(bottom + top);
                _ = c.XFree(@ptrCast(p));
                return true;
            }
        }
        if (prop != null) _ = c.XFree(@ptrCast(prop));
        return false;
    }
    const gdk_win = c.gtk_widget_get_window(widget) orelse return false;
    c.gdk_window_get_frame_extents(gdk_win, out);
    return true;
}

/// 窗口客户区原点（根坐标系）。GTK4：X11 XTranslateCoordinates；Wayland → false。
pub fn surfaceOrigin(widget: [*c]c.GtkWidget, x: *c_int, y: *c_int) bool {
    if (comptime isGtk4()) {
        const x11 = x11Of(widget) orelse return false;
        var child: c.Window = 0;
        var rx: c_int = 0;
        var ry: c_int = 0;
        if (c.XTranslateCoordinates(x11.dpy, x11.xwin, rootWindowOf(x11.dpy), 0, 0, &rx, &ry, &child) == 0) return false;
        x.* = rx;
        y.* = ry;
        return true;
    }
    const gdk_win = c.gtk_widget_get_window(widget) orelse return false;
    _ = c.gdk_window_get_origin(gdk_win, x, y);
    return true;
}

/// 窗口所在显示器。GTK4 的 monitor_at_surface 面向 GdkSurface。
pub fn monitorAtSurface(widget: [*c]c.GtkWidget) ?*anyopaque {
    if (comptime isGtk4()) {
        const display = c.gdk_display_get_default() orelse return null;
        const surface = c.gtk_native_get_surface(@ptrCast(widget)) orelse return null;
        return c.gdk_display_get_monitor_at_surface(display, surface);
    }
    const gdk_win = c.gtk_widget_get_window(widget) orelse return null;
    const display = c.gdk_display_get_default() orelse return null;
    return c.gdk_display_get_monitor_at_window(display, gdk_win);
}

/// 显示器枚举（GTK4：gdk_display_get_monitors GListModel；GTK3 原生面）。
pub fn displayMonitorCount(display: ?*anyopaque) c_int {
    if (comptime isGtk4()) {
        const list = c.gdk_display_get_monitors(@ptrCast(@alignCast(display))) orelse return 0;
        return @intCast(c.g_list_model_get_n_items(@ptrCast(@alignCast(list))));
    }
    return c.gdk_display_get_n_monitors(@ptrCast(@alignCast(display)));
}

/// 枚举序取显示器（调用方不释放——display 持有）。
pub fn displayMonitorAtIdx(display: ?*anyopaque, idx: c_int) ?*anyopaque {
    if (comptime isGtk4()) {
        const list = c.gdk_display_get_monitors(@ptrCast(@alignCast(display))) orelse return null;
        if (idx < 0 or idx >= @as(c_int, @intCast(c.g_list_model_get_n_items(@ptrCast(@alignCast(list)))))) return null;
        const item = c.g_list_model_get_item(@ptrCast(@alignCast(list)), @intCast(idx)) orelse return null;
        // GListModel 的 item 带 ref——转交调用方语义由 display 缓存吸收：
        // 这里立即 unref，返回借用指针（display 的 monitors 列表持有对象）
        const mon: ?*c.GdkMonitor = @ptrCast(@alignCast(item));
        c.g_object_unref(@ptrCast(item));
        return mon;
    }
    return c.gdk_display_get_monitor(@ptrCast(@alignCast(display)), idx);
}

/// 主显示器。GTK4：列表首项近似（无 primary 概念）→ 与 GTK3 枚举序一致。
pub fn displayPrimaryMonitor(display: ?*anyopaque) ?*anyopaque {
    if (comptime isGtk4()) {
        return displayMonitorAtIdx(display, 0);
    }
    return c.gdk_display_get_primary_monitor(@ptrCast(@alignCast(display)));
}

/// 单调毫秒时钟（FFM 抑制窗等时长判定；双栈 GLib 原生）。
pub fn nowMs() i64 {
    return @intCast(@divTrunc(c.g_get_monotonic_time(), 1000));
}

/// 显示器工作区（GTK4 无 workarea API → geometry 近似，面板区不剔除——文档化）。
pub fn monitorWorkarea(mon: ?*anyopaque, out: [*c]c.GdkRectangle) void {
    if (comptime isGtk4()) {
        c.gdk_monitor_get_geometry(@ptrCast(@alignCast(mon)), out);
        return;
    }
    c.gdk_monitor_get_workarea(@ptrCast(@alignCast(mon)), out);
}

/// 指针根坐标（GDK4 无全局指针位置 API → X11 XQueryPointer；Wayland → false）。
pub fn pointerRootPos(widget: [*c]c.GtkWidget, x: *c_int, y: *c_int) bool {
    if (comptime isGtk4()) {
        const x11 = x11Of(widget) orelse return false;
        var root_ret: c.Window = 0;
        var child_ret: c.Window = 0;
        var rx: c_int = 0;
        var ry: c_int = 0;
        var wx: c_int = 0;
        var wy: c_int = 0;
        var mask: c_uint = 0;
        if (c.XQueryPointer(x11.dpy, rootWindowOf(x11.dpy), &root_ret, &child_ret, &rx, &ry, &wx, &wy, &mask) == 0) return false;
        x.* = rx;
        y.* = ry;
        return true;
    }
    const display = c.gdk_display_get_default() orelse return false;
    const seat = c.gdk_display_get_default_seat(display) orelse return false;
    const pointer = c.gdk_seat_get_pointer(seat) orelse return false;
    c.gdk_device_get_position(pointer, null, x, y);
    return true;
}

// ---------------------------------------------------------------------------
// v0.4.3 L6：系统托盘图标几何（挂窗定位的锚点）
//
// XEmbed 宿主（stalonetray / trayer / xfce4-panel 等）把图标窗口 reparent 进
// `_NET_SYSTEM_TRAY_S<n>` 选择拥有者窗口，图标窗口带 `_XEMBED_INFO`；因此可
// 按 X 树扫描拿到真实矩形（Wails 用 gtk_status_icon_get_geometry 的等价物——
// libayatana 的内部 GtkStatusIcon 实例不对外暴露，只能从 X 侧取几何）。
//
// SNI 宿主（GNOME/KDE 面板经 D-Bus 绘制图标）没有图标窗口 → null，调用方
// 回退指针位置；Wayland 无全局坐标 → null（由调用方保持原位）。
// ---------------------------------------------------------------------------

pub const TrayIconRect = struct { x: c_int, y: c_int, width: c_int, height: c_int };

/// 会话是否有 XEmbed 系统托盘宿主（stalonetray/trayer/xfce4-panel…）。
/// 有 → 走自建 GtkStatusIcon（左键 activate 可控、几何可查）；
/// 无 → 由 libayatana 走 SNI（GNOME/KDE，D-Bus 绘制）。
pub fn hasXembedTray() bool {
    const gdk_display = c.gdk_display_get_default() orelse return false;
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(gdk_display)), c.gdk_x11_display_get_type()) == 0) return false;
    const dpy = c.gdk_x11_display_get_xdisplay(gdk_display) orelse return false;
    return xembedTrayOwner(dpy) != 0;
}

fn xembedTrayOwner(dpy: *c.Display) c.Window {
    const screen_num = c.XDefaultScreen(dpy);
    var atom_buf: [40]u8 = @splat(0);
    const atom_name = std.fmt.bufPrint(atom_buf[0..39], "_NET_SYSTEM_TRAY_S{d}", .{screen_num}) catch return 0;
    atom_buf[atom_name.len] = 0;
    return c.XGetSelectionOwner(dpy, c.XInternAtom(dpy, @ptrCast(&atom_buf), c.False));
}

/// 托盘图标矩形（根坐标）。找不到 XEmbed 图标窗口 → null。
pub fn xembedTrayIconRect() ?TrayIconRect {
    const gdk_display = c.gdk_display_get_default() orelse return null;
    // GDK_IS_X11_DISPLAY 宏在 translate-c 里引用了 comptime 不可调用的
    // gdk_x11_display_get_type()（GDK_TYPE_* 常量），故运行时按类型判定。
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(gdk_display)), c.gdk_x11_display_get_type()) == 0) return null;
    const dpy = c.gdk_x11_display_get_xdisplay(gdk_display) orelse return null;

    // _NET_SYSTEM_TRAY_S<n> 的拥有者 = 托盘宿主窗口
    const owner = xembedTrayOwner(dpy);
    if (owner == 0) return null;

    const icon = findXembedIcon(dpy, owner, 3) orelse return null;
    var rx: c_int = 0;
    var ry: c_int = 0;
    var child_ret: c.Window = 0;
    if (c.XTranslateCoordinates(dpy, icon, rootWindowOf(dpy), 0, 0, &rx, &ry, &child_ret) == 0) return null;
    var root_ret: c.Window = 0;
    var gx: c_int = 0;
    var gy: c_int = 0;
    var gw: c_uint = 0;
    var gh: c_uint = 0;
    var border: c_uint = 0;
    var depth: c_uint = 0;
    if (c.XGetGeometry(dpy, icon, &root_ret, &gx, &gy, &gw, &gh, &border, &depth) == 0) return null;
    if (gw == 0 or gh == 0) return null;
    return .{ .x = rx, .y = ry, .width = @intCast(gw), .height = @intCast(gh) };
}

/// 在托盘宿主窗口子树里找带 `_XEMBED_INFO` 的可见图标窗口。
/// 优先 WM_CLASS 与进程名匹配（多图标宿主下不误取别人的图标）。
fn findXembedIcon(dpy: *c.Display, parent: c.Window, depth_left: u8) ?c.Window {
    var root_ret: c.Window = 0;
    var parent_ret: c.Window = 0;
    var children: [*c]c.Window = null;
    var nchildren: c_uint = 0;
    if (c.XQueryTree(dpy, parent, &root_ret, &parent_ret, &children, &nchildren) == 0) return null;
    defer {
        if (children != null) _ = c.XFree(@ptrCast(children));
    }

    var fallback: ?c.Window = null;
    var i: c_uint = 0;
    while (i < nchildren) : (i += 1) {
        const w = children[i];
        if (w == 0) continue;
        var attrs: c.XWindowAttributes = undefined;
        if (c.XGetWindowAttributes(dpy, w, &attrs) == 0) continue;
        if (attrs.class != c.InputOutput or attrs.map_state != c.IsViewable) continue;
        if (hasXembedInfo(dpy, w)) {
            if (wmClassMatchesProcess(dpy, w)) return w;
            if (fallback == null) fallback = w;
        }
        if (depth_left > 1) {
            if (findXembedIcon(dpy, w, depth_left - 1)) |nested| return nested;
        }
    }
    return fallback;
}

fn hasXembedInfo(dpy: *c.Display, w: c.Window) bool {
    var actual_type: c.Atom = 0;
    var actual_format: c_int = 0;
    var nitems: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var prop: [*c]u8 = null;
    const atom = internAtom(dpy, "_XEMBED_INFO");
    const status = c.XGetWindowProperty(dpy, w, atom, 0, 0, c.False, 0, &actual_type, &actual_format, &nitems, &bytes_after, &prop);
    if (prop != null) _ = c.XFree(@ptrCast(prop));
    return status == 0 and actual_type != 0;
}

/// WM_CLASS 的 instance/class 任一等于进程名（g_get_prgname，如 "zilt-app"）。
fn wmClassMatchesProcess(dpy: *c.Display, w: c.Window) bool {
    const prgname = c.g_get_prgname() orelse return false;
    const want = std.mem.span(prgname);
    if (want.len == 0) return false;
    var actual_type: c.Atom = 0;
    var actual_format: c_int = 0;
    var nitems: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var prop: [*c]u8 = null;
    const wm_class_atom = internAtom(dpy, "WM_CLASS");
    const status = c.XGetWindowProperty(dpy, w, wm_class_atom, 0, 256, c.False, 0, &actual_type, &actual_format, &nitems, &bytes_after, &prop);
    defer {
        if (prop != null) _ = c.XFree(@ptrCast(prop));
    }
    if (status != 0 or prop == null or nitems == 0) return false;
    const raw: [*]const u8 = @ptrCast(prop);
    // WM_CLASS = "instance\0class\0"
    var start: usize = 0;
    var i: usize = 0;
    while (i < nitems) : (i += 1) {
        if (raw[i] != 0) continue;
        if (std.ascii.eqlIgnoreCase(raw[start..i], want)) return true;
        start = i + 1;
    }
    return false;
}

/// 指针 warp（cursor_position op）。GTK4：gdk_device_warp 目标是 GdkSurface。
pub fn deviceWarp(widget: [*c]c.GtkWidget, pointer: ?*c.GdkDevice, x: c_int, y: c_int) bool {
    if (comptime isGtk4()) {
        // 4.14 capi 无 gdk_device_warp → X11 XWarpPointer（根坐标）；Wayland → false
        const x11 = x11Of(widget) orelse return false;
        _ = c.XWarpPointer(x11.dpy, 0, rootWindowOf(x11.dpy), 0, 0, 0, 0, @intCast(x), @intCast(y));
        _ = c.XFlush(x11.dpy);
        return true;
    }
    const screen = c.gdk_window_get_screen(c.gtk_widget_get_window(widget) orelse return false) orelse return false;
    c.gdk_device_warp(pointer, screen, x, y);
    return true;
}

/// 指针事件穿透（ignore_cursor op）。GTK4：X11 XShape ShapeInput；
/// Wayland 无对等 → false（skip 文档化）。
pub fn inputShapeSetIgnore(widget: [*c]c.GtkWidget, ignore: bool) bool {
    if (comptime isGtk4()) {
        const x11 = x11Of(widget) orelse return false;
        if (ignore) {
            // 空 input shape = 该窗口不接收指针事件（穿透到下层窗口）
            var empty = EMPTY_SHAPE_SENTINEL;
            c.XShapeCombineRectangles(x11.dpy, x11.xwin, c.ShapeInput, 0, 0, &empty, 0, c.ShapeSet, c.YXBanded);
        } else {
            // 恢复默认事件接收 = input shape 覆盖整窗（XShape 无显式清除面）
            var root: c.Window = 0;
            var px: c_int = 0;
            var py: c_int = 0;
            var w: c_uint = 0;
            var h: c_uint = 0;
            var bw: c_uint = 0;
            var depth: c_uint = 0;
            if (c.XGetGeometry(x11.dpy, x11.xwin, &root, &px, &py, &w, &h, &bw, &depth) == 0) return false;
            var full = c.XRectangle{ .x = 0, .y = 0, .width = @intCast(@min(w, 65535)), .height = @intCast(@min(h, 65535)) };
            c.XShapeCombineRectangles(x11.dpy, x11.xwin, c.ShapeInput, 0, 0, &full, 1, c.ShapeSet, c.YXBanded);
        }
        _ = c.XFlush(x11.dpy);
        return true;
    }
    return false;
}

/// XShapeCombineRectangles 的 0 矩形哨兵（空 shape）。
const EMPTY_SHAPE_SENTINEL = c.XRectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// 光标落到 surface（GTK3 GdkWindow / GTK4 GdkSurface 面）。
pub fn surfaceSetCursor(widget: [*c]c.GtkWidget, cursor: ?*anyopaque) bool {
    if (comptime isGtk4()) {
        const surface = c.gtk_native_get_surface(@ptrCast(widget)) orelse return false;
        c.gdk_surface_set_cursor(surface, @ptrCast(@alignCast(cursor)));
        return true;
    }
    const gdk_win = c.gtk_widget_get_window(widget) orelse return false;
    c.gdk_window_set_cursor(gdk_win, @ptrCast(@alignCast(cursor)));
    return true;
}

/// 1×1 全透明光标（隐藏光标用；GDK3 没有 ShowCursor 式的全局开关）。
/// GTK4：gdk_cursor_new_from_texture（pixbuf 构造面已移除）。
pub fn blankCursorFor(widget: [*c]c.GtkWidget) ?*anyopaque {
    if (comptime isGtk4()) {
        const display = c.gtk_widget_get_display(widget) orelse return null;
        var pixels = [_]u8{ 0, 0, 0, 0 };
        const bytes = c.g_bytes_new_static(&pixels, pixels.len) orelse return null;
        defer c.g_object_unref(@ptrCast(bytes));
        const texture = c.gdk_memory_texture_new(1, 1, c.GDK_MEMORY_R8G8B8A8, bytes, 4) orelse return null;
        defer c.g_object_unref(@ptrCast(texture));
        _ = display;
        return c.gdk_cursor_new_from_texture(texture, 0, 0, null);
    }
    const display = c.gtk_widget_get_display(widget) orelse return null;
    const pixbuf = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, 1, 1) orelse return null;
    defer c.g_object_unref(@ptrCast(pixbuf));
    c.gdk_pixbuf_fill(pixbuf, 0);
    return c.gdk_cursor_new_from_pixbuf(display, pixbuf, 0, 0);
}

/// 窗口形状 mask（cairo region）。GTK3：gdk_window shape 面；
/// GTK4：GDK 无 shape API → XShape 直连（libXext）；Wayland → false（skip）。
pub fn applySurfaceMask(widget: [*c]c.GtkWidget, region: ?*anyopaque) bool {
    if (comptime isGtk4()) {
        const x11 = x11Of(widget) orelse return false;
        const cr: ?*c.cairo_region_t = @ptrCast(@alignCast(region));
        if (cr == null) return false;
        const n = c.cairo_region_num_rectangles(cr);
        if (n <= 0) return false;
        const rects = std.heap.c_allocator.alloc(c.XRectangle, @intCast(n)) catch return false;
        defer std.heap.c_allocator.free(rects);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            var r: c.cairo_rectangle_int_t = std.mem.zeroes(c.cairo_rectangle_int_t);
            c.cairo_region_get_rectangle(cr, i, &r);
            rects[@intCast(i)] = .{
                .x = @intCast(@max(-32768, @min(32767, r.x))),
                .y = @intCast(@max(-32768, @min(32767, r.y))),
                .width = @intCast(@max(0, @min(65535, r.width))),
                .height = @intCast(@max(0, @min(65535, r.height))),
            };
        }
        // ShapeBounding（视觉裁剪）+ ShapeInput（事件穿透）双面，与 GTK3 语义一致
        c.XShapeCombineRectangles(x11.dpy, x11.xwin, c.ShapeBounding, 0, 0, rects.ptr, @intCast(n), c.ShapeSet, c.YXBanded);
        c.XShapeCombineRectangles(x11.dpy, x11.xwin, c.ShapeInput, 0, 0, rects.ptr, @intCast(n), c.ShapeSet, c.YXBanded);
        _ = c.XFlush(x11.dpy);
        return true;
    }
    return false; // GTK3 走既有 gdk_window shape 面（调用点变体分支）
}

// ---------------------------------------------------------------------------
// 窗口图标（set_icon / set_icon_from_file）
// GTK3：原生 API。GTK4：icon 属性面已移除 → X11 写 _NET_WM_ICON（RGBA→ARGB），
// Wayland → no-op（文档化）。
// ---------------------------------------------------------------------------

pub fn setIconFromPath(win: [*c]c.GtkWindow, path_z: [*c]const u8) bool {
    if (comptime isGtk4()) {
        var err: ?*c.GError = null;
        const pixbuf = c.gdk_pixbuf_new_from_file(path_z, &err);
        if (err) |e| c.g_error_free(e);
        if (pixbuf == null) return false;
        defer c.g_object_unref(@ptrCast(pixbuf));
        if (x11Of(@ptrCast(win)) == null) return true; // Wayland：无对等，接受请求（文档化）
        return x11SetIconFromPixbuf(win, pixbuf);
    }
    var err: ?*c.GError = null;
    const ok = c.gtk_window_set_icon_from_file(win, path_z, &err);
    if (err) |e| c.g_error_free(e);
    return ok != 0;
}

pub fn setIcon(win: [*c]c.GtkWindow, pixbuf: ?*anyopaque) void {
    if (comptime isGtk4()) {
        if (pixbuf != null) _ = x11SetIconFromPixbuf(win, @ptrCast(@alignCast(pixbuf)));
        return;
    }
    c.gtk_window_set_icon(win, @ptrCast(@alignCast(pixbuf)));
}

/// RGBA pixbuf → _NET_WM_ICON（CARD32 ARGB 数组，little-endian 属性）。
fn x11SetIconFromPixbuf(win: [*c]c.GtkWindow, pixbuf: ?*anyopaque) bool {
    const x11 = x11Of(@ptrCast(win)) orelse return false;
    const pb: ?*c.GdkPixbuf = @ptrCast(@alignCast(pixbuf));
    const width: usize = @intCast(c.gdk_pixbuf_get_width(pb));
    const height: usize = @intCast(c.gdk_pixbuf_get_height(pb));
    if (width == 0 or height == 0) return false;
    const channels: usize = @intCast(c.gdk_pixbuf_get_n_channels(pb));
    const rowstride: usize = @intCast(c.gdk_pixbuf_get_rowstride(pb));
    const pixels = c.gdk_pixbuf_get_pixels(pb) orelse return false;
    // 数据布局：[0]=宽 [1]=高 [2..]=ARGB（每像素一个 u32）
    const total = 2 + width * height;
    const buf = std.heap.c_allocator.alloc(c_ulong, total) catch return false;
    defer std.heap.c_allocator.free(buf);
    buf[0] = @intCast(width);
    buf[1] = @intCast(height);
    var i: usize = 2;
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const src = pixels + row * rowstride;
        var col: usize = 0;
        while (col < width) : (col += 1) {
            const s = src + col * channels;
            const a: u32 = if (channels >= 4) s[3] else 255;
            const r: u32 = s[0];
            const g: u32 = s[1];
            const b: u32 = s[2];
            buf[i] = (a << 24) | (r << 16) | (g << 8) | b;
            i += 1;
        }
    }
    const icon_atom = internAtom(x11.dpy, "_NET_WM_ICON");
    _ = c.XChangeProperty(x11.dpy, x11.xwin, icon_atom, @as(c.Atom, 6), 32, c.PropModeReplace, @ptrCast(buf.ptr), @intCast(total)); // XA_CARDINAL=6
    _ = c.XFlush(x11.dpy);
    return true;
}

// ---------------------------------------------------------------------------
// 透明窗口（GTK3：rgba visual + app_paintable + draw 清屏；
// GTK4：display 级 CSS provider + .zilt-transparent 窗口类）
// ---------------------------------------------------------------------------

var transparent_css_loaded = false;

pub fn applyTransparentWindow(widget: [*c]c.GtkWidget) void {
    if (comptime isGtk4()) {
        if (!transparent_css_loaded) {
            const provider = c.gtk_css_provider_new();
            c.gtk_css_provider_load_from_data(provider, "window.zilt-transparent { background-color: transparent; }", -1);
            c.gtk_style_context_add_provider_for_display(
                c.gdk_display_get_default(),
                @ptrCast(@alignCast(provider)),
                c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
            c.g_object_unref(@ptrCast(provider));
            transparent_css_loaded = true;
        }
        c.gtk_widget_add_css_class(widget, "zilt-transparent");
        return;
    }
    const screen = c.gtk_widget_get_screen(widget);
    var rgba_visual = false;
    if (screen != null) {
        if (c.gdk_screen_get_rgba_visual(screen)) |visual| {
            c.gtk_widget_set_visual(widget, visual);
            rgba_visual = true;
        }
    }
    c.gtk_widget_set_app_paintable(widget, 1);
}

// ---------------------------------------------------------------------------
// 信号面收敛（事件信号在 GTK4 移除 → 属性信号 / 事件控制器 / 同名替代）
// ---------------------------------------------------------------------------

/// 焦点事件（GTK3 focus-in/out + has-toplevel-focus；GTK4 notify::is-active）。
/// cb(focused, user_data)。
pub fn connectFocusSignals(
    win: [*c]c.GtkWindow,
    cb: *const fn (focused: bool, user_data: c.gpointer) callconv(.c) void,
    user_data: c.gpointer,
) void {
    // 每连接 user_data 直通（多窗口/销毁安全）——信号源对象经首参取回
    //（is-active 判定用窗口），回调的 user_data 用连接时绑定的调用方数据。
    if (comptime isGtk4()) {
        const Ctx = struct {
            var handler: ?*const fn (focused: bool, user_data: c.gpointer) callconv(.c) void = null;
            fn onFocus(source: ?*c.GObject, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
                const win_ptr: [*c]c.GtkWindow = @ptrCast(@alignCast(source));
                const focused = c.gtk_window_is_active(win_ptr) != 0;
                if (handler) |h| h(focused, data);
            }
        };
        Ctx.handler = cb;
        _ = c.g_signal_connect_data(@ptrCast(win), "notify::is-active", @ptrCast(&Ctx.onFocus), user_data, null, 0);
        return;
    }
    const Ctx = struct {
        var handler: ?*const fn (focused: bool, user_data: c.gpointer) callconv(.c) void = null;
        fn onFocusIn(source: [*c]c.GtkWidget, _: ?*anyopaque, data: c.gpointer) callconv(.c) c.gboolean {
            _ = source;
            if (handler) |h| h(true, data);
            return 0;
        }
        fn onFocusOut(source: [*c]c.GtkWidget, _: ?*anyopaque, data: c.gpointer) callconv(.c) c.gboolean {
            _ = source;
            if (handler) |h| h(false, data);
            return 0;
        }
    };
    Ctx.handler = cb;
    _ = c.g_signal_connect_data(@ptrCast(win), "focus-in-event", @ptrCast(&Ctx.onFocusIn), user_data, null, 0);
    _ = c.g_signal_connect_data(@ptrCast(win), "focus-out-event", @ptrCast(&Ctx.onFocusOut), user_data, null, 0);
}

/// 关闭请求（GTK3 delete-event / GTK4 close-request）。返回 TRUE 拦截销毁。
pub fn connectCloseRequest(
    win: [*c]c.GtkWindow,
    cb: *const fn (user_data: c.gpointer) callconv(.c) c.gboolean,
    user_data: c.gpointer,
) void {
    if (comptime isGtk4()) {
        const Ctx = struct {
            var handler: ?*const fn (user_data: c.gpointer) callconv(.c) c.gboolean = null;
            var ud: c.gpointer = null;
            fn onClose(_: ?*c.GtkWindow, data: c.gpointer) callconv(.c) c.gboolean {
                if (handler) |h| return h(data);
                return 0;
            }
        };
        Ctx.handler = cb;
        Ctx.ud = user_data;
        _ = c.g_signal_connect_data(@ptrCast(win), "close-request", @ptrCast(&Ctx.onClose), user_data, null, 0);
        return;
    }
    const Ctx = struct {
        var handler: ?*const fn (user_data: c.gpointer) callconv(.c) c.gboolean = null;
        var ud: c.gpointer = null;
        fn onDelete(_: [*c]c.GtkWidget, _: ?*anyopaque, data: c.gpointer) callconv(.c) c.gboolean {
            if (handler) |h| return h(data);
            return 0;
        }
    };
    Ctx.handler = cb;
    Ctx.ud = user_data;
    _ = c.g_signal_connect_data(@ptrCast(win), "delete-event", @ptrCast(&Ctx.onDelete), user_data, null, 0);
}

/// 程序化关闭请求派发（close op 的 opt-in 路径：直接 emit 变体信号）。
/// 返回是否被拦截（TRUE = 应用要处理，不销毁）。
pub fn emitCloseRequest(win: [*c]c.GtkWindow) bool {
    if (comptime isGtk4()) {
        var handled: c.gboolean = 0;
        c.g_signal_emit_by_name(@ptrCast(win), "close-request", @as(?*anyopaque, null), &handled);
        return handled != 0;
    }
    var handled: c.gboolean = 0;
    c.g_signal_emit_by_name(@ptrCast(win), "delete-event", @as(?*anyopaque, null), &handled);
    return handled != 0;
}

/// map 信号（恢复几何补 move；GTK3 map-event / GTK4 map）。
pub fn connectMap(
    win: [*c]c.GtkWindow,
    cb: *const fn (user_data: c.gpointer) callconv(.c) c.gboolean,
    user_data: c.gpointer,
) void {
    if (comptime isGtk4()) {
        const Ctx = struct {
            var handler: ?*const fn (user_data: c.gpointer) callconv(.c) c.gboolean = null;
            var ud: c.gpointer = null;
            fn onMap(_: ?*c.GtkWindow, data: c.gpointer) callconv(.c) c.gboolean {
                if (handler) |h| return h(data);
                return 0;
            }
        };
        Ctx.handler = cb;
        Ctx.ud = user_data;
        _ = c.g_signal_connect_data(@ptrCast(win), "map", @ptrCast(&Ctx.onMap), user_data, null, 0);
        return;
    }
    const Ctx = struct {
        var handler: ?*const fn (user_data: c.gpointer) callconv(.c) c.gboolean = null;
        var ud: c.gpointer = null;
        fn onMapEvent(_: [*c]c.GtkWidget, _: ?*anyopaque, data: c.gpointer) callconv(.c) c.gboolean {
            if (handler) |h| return h(data);
            return 0;
        }
    };
    Ctx.handler = cb;
    Ctx.ud = user_data;
    _ = c.g_signal_connect_data(@ptrCast(win), "map-event", @ptrCast(&Ctx.onMapEvent), user_data, null, 0);
}

/// 按键事件（GTK3 key-press-event + gdk_event_get_keyval；
/// GTK4 GtkEventControllerKey）。cb(keyval, mods, user_data) → TRUE 已消费。
pub fn connectKeyPress(
    widget: [*c]c.GtkWidget,
    cb: *const fn (keyval: c.guint, mods: c.GdkModifierType, user_data: c.gpointer) callconv(.c) c.gboolean,
    user_data: c.gpointer,
) void {
    if (comptime isGtk4()) {
        const Ctx = struct {
            var handler: ?*const fn (keyval: c.guint, mods: c.GdkModifierType, user_data: c.gpointer) callconv(.c) c.gboolean = null;
            var ud: c.gpointer = null;
            fn onKeyPressed(
                _: ?*c.GtkEventControllerKey,
                keyval: c.guint,
                _: c.guint,
                mods: c.GdkModifierType,
                data: c.gpointer,
            ) callconv(.c) c.gboolean {
                if (handler) |h| return h(keyval, mods, data);
                return 0;
            }
        };
        Ctx.handler = cb;
        Ctx.ud = user_data;
        const controller = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(@ptrCast(controller), "key-pressed", @ptrCast(&Ctx.onKeyPressed), user_data, null, 0);
        c.gtk_widget_add_controller(widget, controller);
        return;
    }
    const Ctx = struct {
        var handler: ?*const fn (keyval: c.guint, mods: c.GdkModifierType, user_data: c.gpointer) callconv(.c) c.gboolean = null;
        var ud: c.gpointer = null;
        fn onKeyPressEv(_: [*c]c.GtkWidget, event: ?*anyopaque, data: c.gpointer) callconv(.c) c.gboolean {
            var keyval: c.guint = 0;
            var mods: c.GdkModifierType = 0;
            if (event != null) {
                _ = c.gdk_event_get_keyval(@ptrCast(event), &keyval);
                _ = c.gdk_event_get_state(@ptrCast(event), &mods);
            }
            if (handler) |h| return h(keyval, mods, data);
            return 0;
        }
    };
    Ctx.handler = cb;
    Ctx.ud = user_data;
    _ = c.g_signal_connect_data(@ptrCast(widget), "key-press-event", @ptrCast(&Ctx.onKeyPressEv), user_data, null, 0);
}

/// 窗口焦点判定回退（GTK3 has-toplevel-focus / GTK4 is-active）。
pub fn windowHasFocus(win: [*c]c.GtkWindow) bool {
    if (comptime isGtk4()) {
        return c.gtk_window_is_active(win) != 0;
    }
    return c.gtk_window_has_toplevel_focus(win) != 0;
}

/// 尺寸跟踪（GTK3 configure-event 覆盖；GTK4 size-allocate——只回调客户区尺寸，
/// 位置由 X11 轮询面补齐）。返回连接句柄（GTK4 使用；GTK3 返回 0）。
pub fn connectSizeAllocate(
    win: [*c]c.GtkWindow,
    cb: *const fn (width: c.gint, height: c.gint, user_data: c.gpointer) callconv(.c) void,
    user_data: c.gpointer,
) void {
    if (comptime isGtk4()) {
        const Ctx = struct {
            var handler: ?*const fn (width: c.gint, height: c.gint, user_data: c.gpointer) callconv(.c) void = null;
            var ud: c.gpointer = null;
            fn onSizeAllocate(_: [*c]c.GtkWidget, alloc_rect: [*c]c.GtkAllocation, data: c.gpointer) callconv(.c) void {
                if (handler) |h| h(alloc_rect.*.width, alloc_rect.*.height, data);
            }
        };
        Ctx.handler = cb;
        Ctx.ud = user_data;
        _ = c.g_signal_connect_data(@ptrCast(win), "size-allocate", @ptrCast(&Ctx.onSizeAllocate), user_data, null, 0);
        return;
    }
}

// ---------------------------------------------------------------------------
// 剪贴板（GtkClipboard → GdkClipboard）
// 读面：GDK4 全异步 → SyncWait 桥保持同步接口。
// ---------------------------------------------------------------------------

pub fn clipboardGet() ?*anyopaque {
    if (comptime isGtk4()) {
        return c.gdk_display_get_clipboard(c.gdk_display_get_default());
    }
    return c.gtk_clipboard_get(c.GDK_SELECTION_CLIPBOARD);
}

pub fn clipboardWriteText(cb: ?*anyopaque, z_ptr: [*c]const u8, len: usize) void {
    if (comptime isGtk4()) {
        c.gdk_clipboard_set_text(@ptrCast(@alignCast(cb)), z_ptr);
        clipboardStore(cb);
        return;
    }
    c.gtk_clipboard_set_text(@ptrCast(@alignCast(cb)), z_ptr, @intCast(len));
    clipboardStore(cb);
}

pub fn clipboardStore(cb: ?*anyopaque) void {
    if (comptime isGtk4()) {
        // fire-and-forget：store 异步完成即可（进程退出前主循环仍在跑）。
        // 上下文堆分配（栈槽会在回调前悬垂）；回调内 finish + 释放。
        const ctx = std.heap.c_allocator.create(StoreCtx) catch return;
        ctx.* = .{ .clip = @ptrCast(@alignCast(cb)) };
        c.gdk_clipboard_store_async(@ptrCast(@alignCast(cb)), 0, null, @ptrCast(&onStoreFinish), @ptrCast(ctx));
        return;
    }
    c.gtk_clipboard_store(@ptrCast(@alignCast(cb)));
}

const StoreCtx = struct { clip: ?*c.GdkClipboard };

fn onStoreFinish(_: ?*c.GObject, result: ?*c.GAsyncResult, ud: c.gpointer) callconv(.c) void {
    const ctx: *StoreCtx = @ptrCast(@alignCast(ud orelse return));
    defer std.heap.c_allocator.destroy(ctx);
    var err: ?*c.GError = null;
    _ = c.gdk_clipboard_store_finish(ctx.clip, result, &err);
    if (err) |e| c.g_error_free(e);
}

pub fn clipboardClear(cb: ?*anyopaque) void {
    if (comptime isGtk4()) {
        c.gdk_clipboard_set_content(@ptrCast(@alignCast(cb)), null);
        return;
    }
    c.gtk_clipboard_clear(@ptrCast(@alignCast(cb)));
}

/// 文本读取（utf-8）。无文本 → null。
pub fn clipboardReadText(cb: ?*anyopaque, alloc: std.mem.Allocator) ?[]u8 {
    if (comptime isGtk4()) {
        // read_text_async 由 GDK 协商 charset（UTF8_STRING / text/plain;charset=utf-8）
        const clip: ?*c.GdkClipboard = @ptrCast(@alignCast(cb));
        var w = SyncWait.begin();
        c.gdk_clipboard_read_text_async(clip, null, @ptrCast(&onAsyncReady), @ptrCast(&w));
        w.wait();
        if (!w.done or w.result == null) return null;
        defer w.releaseResult();
        var err: ?*c.GError = null;
        const text = c.gdk_clipboard_read_text_finish(clip, w.result, &err);
        if (err) |e| c.g_error_free(e);
        if (text == null) return null;
        defer c.g_free(@ptrCast(text));
        return alloc.dupe(u8, std.mem.span(text)) catch null;
    }
    const text = c.gtk_clipboard_wait_for_text(@ptrCast(@alignCast(cb)));
    if (text == null) return null;
    defer c.g_free(@ptrCast(text));
    return alloc.dupe(u8, std.mem.span(text)) catch null;
}

/// 指定 MIME 读取（text/html 等）。GTK3 走 wait_for_contents(atom)。
pub fn clipboardReadMime(cb: ?*anyopaque, mime: [:0]const u8, alloc: std.mem.Allocator) ?[]u8 {
    if (comptime isGtk4()) {
        return clipboardReadBytes(cb, mime, alloc);
    }
    const atom = c.gdk_atom_intern(mime.ptr, 0);
    const sel = c.gtk_clipboard_wait_for_contents(@ptrCast(@alignCast(cb)), atom) orelse return null;
    defer c.gtk_selection_data_free(sel);
    const len = c.gtk_selection_data_get_length(sel);
    if (len <= 0) return null;
    const raw = c.gtk_selection_data_get_data(sel) orelse return null;
    return alloc.dupe(u8, raw[0..@intCast(len)]) catch null;
}

/// uri-list 读取（files 格式）。GTK3 的 wait_for_uris → 重组 CRLF 字节流
///（解析仍归调用方，两栈输入形状一致）。
pub fn clipboardReadUriList(cb: ?*anyopaque, alloc: std.mem.Allocator) ?[]u8 {
    if (comptime isGtk4()) {
        // 写入面用 gdk_content_provider_new_for_bytes("text/uri-list", …)，
        // 读回同一 MIME 即得同样的 CRLF 字节流（两栈形状一致）
        return clipboardReadBytes(cb, "text/uri-list", alloc);
    }
    const uris = c.gtk_clipboard_wait_for_uris(@ptrCast(@alignCast(cb))) orelse return null;
    defer c.g_strfreev(uris);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (uris[i] != null) : (i += 1) {
        if (out.items.len != 0) out.appendSlice(alloc, "\r\n") catch return null;
        out.appendSlice(alloc, std.mem.span(uris[i])) catch return null;
    }
    if (out.items.len == 0) return null;
    return out.items;
}

/// GDK4 read_async → GInputStream → 全量字节。
fn clipboardReadBytes(cb: ?*anyopaque, mime: [:0]const u8, alloc: std.mem.Allocator) ?[]u8 {
    const clip: ?*c.GdkClipboard = @ptrCast(@alignCast(cb));
    var mimes = [_:null]?[*c]const u8{ mime.ptr, null };
    var w = SyncWait.begin();
    c.gdk_clipboard_read_async(clip, @as([*c][*c]const u8, @ptrCast(&mimes)), 0, null, @ptrCast(&onAsyncReady), @ptrCast(&w));
    w.wait();
    if (!w.done or w.result == null) return null;
    defer w.releaseResult();
    var out_mime: [*c]const u8 = null;
    var err: ?*c.GError = null;
    const stream = c.gdk_clipboard_read_finish(clip, w.result, &out_mime, &err);
    if (err) |e| c.g_error_free(e);
    if (stream == null) return null;
    defer c.g_object_unref(@ptrCast(stream));
    // 读到 EOF（1MB 封顶——剪贴板载荷不合理的超大值按截断处理）
    const bytes = c.g_input_stream_read_bytes(stream, 1 << 20, null, &err);
    if (err) |e| c.g_error_free(e);
    if (bytes == null) return null;
    defer c.g_object_unref(@ptrCast(bytes));
    var size: c.gsize = 0;
    const raw_data = c.g_bytes_get_data(bytes, &size) orelse return null;
    if (size == 0) return null;
    const data: [*c]const u8 = @ptrCast(@alignCast(raw_data));
    return alloc.dupe(u8, data[0..size]) catch null;
}

/// 图片读取（RGBA 非预乘——与 GTK3 pixbuf 语义一致）。
pub fn clipboardReadImage(cb: ?*anyopaque, alloc: std.mem.Allocator) ?ImageRGBA {
    if (comptime isGtk4()) {
        const clip: ?*c.GdkClipboard = @ptrCast(@alignCast(cb));
        var w = SyncWait.begin();
        c.gdk_clipboard_read_texture_async(clip, null, @ptrCast(&onAsyncReady), @ptrCast(&w));
        w.wait();
        if (!w.done or w.result == null) return null;
        defer w.releaseResult();
        var err: ?*c.GError = null;
        const tex = c.gdk_clipboard_read_texture_finish(clip, w.result, &err);
        if (err) |e| c.g_error_free(e);
        if (tex == null) return null;
        defer c.g_object_unref(@ptrCast(tex));
        return textureToRgba(tex, alloc);
    }
    const pixbuf = c.gtk_clipboard_wait_for_image(@ptrCast(@alignCast(cb))) orelse return null;
    defer c.g_object_unref(@ptrCast(pixbuf));
    return pixbufToRgba(pixbuf, alloc);
}

pub const ImageRGBA = struct { width: u32, height: u32, rgba: []u8 };

/// GdkTexture（GDK_MEMORY_R8G8B8A8_PREMULTIPLIED）→ 非预乘 RGBA。
fn textureToRgba(texture: ?*c.GdkTexture, alloc: std.mem.Allocator) ?ImageRGBA {
    const width: u32 = @intCast(c.gdk_texture_get_width(texture));
    const height: u32 = @intCast(c.gdk_texture_get_height(texture));
    if (width == 0 or height == 0) return null;
    const buf = alloc.alloc(u8, @as(usize, width) * height * 4) catch return null;
    errdefer alloc.free(buf);
    c.gdk_texture_download(texture, buf.ptr, @intCast(width * 4));
    // 预乘 → 非预乘（与 GTK3 pixbuf 语义对齐）
    for (0..@as(usize, width) * height) |i| {
        const px = buf[i * 4 ..][0..4];
        const a = px[3];
        if (a != 255 and a != 0) {
            px[0] = @intCast(@min(255, (@as(u32, px[0]) * 255 + a / 2) / a));
            px[1] = @intCast(@min(255, (@as(u32, px[1]) * 255 + a / 2) / a));
            px[2] = @intCast(@min(255, (@as(u32, px[2]) * 255 + a / 2) / a));
        }
    }
    return .{ .width = width, .height = height, .rgba = buf };
}

fn pixbufToRgba(pixbuf: ?*c.GdkPixbuf, alloc: std.mem.Allocator) ?ImageRGBA {
    const width: u32 = @intCast(c.gdk_pixbuf_get_width(pixbuf));
    const height: u32 = @intCast(c.gdk_pixbuf_get_height(pixbuf));
    if (width == 0 or height == 0) return null;
    const channels = c.gdk_pixbuf_get_n_channels(pixbuf);
    const rowstride: usize = @intCast(c.gdk_pixbuf_get_rowstride(pixbuf));
    const pixels = c.gdk_pixbuf_get_pixels(pixbuf) orelse return null;
    const rgba = alloc.alloc(u8, @as(usize, width) * height * 4) catch return null;
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
    return .{ .width = width, .height = height, .rgba = rgba };
}

/// RGBA 图片写入（image data）。失败返回 false。
pub fn clipboardWriteImage(cb: ?*anyopaque, rgba: []const u8, width: u32, height: u32) bool {
    if (comptime isGtk4()) {
        const clip: ?*c.GdkClipboard = @ptrCast(@alignCast(cb));
        if (width == 0 or height == 0 or rgba.len != @as(usize, width) * height * 4) return false;
        // 非预乘 → 预乘（GDK_MEMORY_R8G8B8A8_PREMULTIPLIED）
        const src = std.heap.c_allocator.dupe(u8, rgba) catch return false;
        defer std.heap.c_allocator.free(src);
        for (0..@as(usize, width) * height) |i| {
            const px = src[i * 4 ..][0..4];
            const a = px[3];
            if (a != 255 and a != 0) {
                px[0] = @intCast((@as(u32, px[0]) * a + 127) / 255);
                px[1] = @intCast((@as(u32, px[1]) * a + 127) / 255);
                px[2] = @intCast((@as(u32, px[2]) * a + 127) / 255);
            }
        }
        const bytes = c.g_bytes_new_take(src.ptr, src.len);
        // g_bytes 接管 src 内存 → 不再 free
        const texture = c.gdk_memory_texture_new(@intCast(width), @intCast(height), c.GDK_MEMORY_R8G8B8A8_PREMULTIPLIED, bytes, @intCast(width * 4));
        c.g_object_unref(@ptrCast(bytes));
        defer c.g_object_unref(@ptrCast(texture));
        c.gdk_clipboard_set_texture(clip, texture);
        clipboardStore(cb);
        return true;
    }
    const pixbuf = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, @intCast(width), @intCast(height)) orelse return false;
    defer c.g_object_unref(@ptrCast(pixbuf));
    const rowstride: usize = @intCast(c.gdk_pixbuf_get_rowstride(pixbuf));
    const pixels = c.gdk_pixbuf_get_pixels(pixbuf) orelse return false;
    for (0..height) |row| {
        const src = rgba[row * width * 4 ..];
        const dst = pixels + row * rowstride;
        @memcpy(dst[0 .. width * 4], src[0 .. width * 4]);
    }
    c.gtk_clipboard_set_image(@ptrCast(@alignCast(cb)), pixbuf);
    clipboardStore(cb);
    return true;
}

/// 剪贴板变化监听（GTK3 owner-change / GTK4 changed）。
/// cb(user_data)——信号对象差异在 trampoline 内消化。
pub fn clipboardConnectChanged(
    cb_handle: ?*anyopaque,
    cb: *const fn (user_data: c.gpointer) callconv(.c) void,
    user_data: c.gpointer,
) void {
    if (comptime isGtk4()) {
        const Ctx = struct {
            var handler: ?*const fn (user_data: c.gpointer) callconv(.c) void = null;
            var ud: c.gpointer = null;
            fn onChanged(_: ?*c.GdkClipboard, data: c.gpointer) callconv(.c) void {
                if (handler) |h| h(data);
            }
        };
        Ctx.handler = cb;
        Ctx.ud = user_data;
        _ = c.g_signal_connect_data(@ptrCast(cb_handle), "changed", @ptrCast(&Ctx.onChanged), user_data, null, 0);
        return;
    }
    const Ctx = struct {
        var handler: ?*const fn (user_data: c.gpointer) callconv(.c) void = null;
        var ud: c.gpointer = null;
        fn onOwnerChange(_: ?*c.GtkClipboard, _: ?*anyopaque, data: c.gpointer) callconv(.c) void {
            if (handler) |h| h(data);
        }
    };
    Ctx.handler = cb;
    Ctx.ud = user_data;
    _ = c.g_signal_connect_data(@ptrCast(cb_handle), "owner-change", @ptrCast(&Ctx.onOwnerChange), user_data, null, 0);
}

// ---------------------------------------------------------------------------
// 菜单（GtkMenu 族 → GMenu 模型 + GtkPopoverMenu + GSimpleActionGroup）
// 托盘/菜单栏在 GTK4 不可用（见文件头限制）；这里收敛 **上下文弹出菜单**。
// ---------------------------------------------------------------------------

/// GMenu 模型构造。
pub fn menuModelNew() ?*anyopaque {
    return c.g_menu_new();
}

pub fn menuModelAppendItem(model: ?*anyopaque, label_z: [*c]const u8, action_z: [*c]const u8) void {
    c.g_menu_append(@ptrCast(@alignCast(model)), label_z, action_z);
}

pub fn menuModelAppendSubmenu(model: ?*anyopaque, label_z: [*c]const u8, sub: ?*anyopaque) void {
    c.g_menu_append_submenu(@ptrCast(@alignCast(model)), label_z, @ptrCast(@alignCast(sub)));
}

/// 分隔符：GMenuModel 无独立 separator——空 section 由 GtkPopoverMenu 渲染为分隔。
pub fn menuModelAppendSeparator(model: ?*anyopaque) void {
    const sect = c.g_menu_new();
    c.g_menu_append_section(@ptrCast(@alignCast(model)), null, @ptrCast(@alignCast(sect)));
    c.g_object_unref(@ptrCast(sect));
}

/// 动作组构造。
pub fn menuActionGroupNew() ?*anyopaque {
    return c.g_simple_action_group_new();
}

/// 添加动作。stateful=true → 布尔状态动作（勾选项）；否则普通激活动作。
/// 返回动作句柄（连接 activate / change-state 用）。
pub fn menuActionAdd(group: ?*anyopaque, name_z: [*c]const u8, stateful: bool, initial: bool) ?*anyopaque {
    const action: ?*c.GSimpleAction = if (stateful)
        c.g_simple_action_new_stateful(name_z, null, c.g_variant_new_boolean(@intFromBool(initial)))
    else
        c.g_simple_action_new(name_z, null);
    if (action == null) return null;
    c.g_action_map_add_action(@ptrCast(@alignCast(group)), @ptrCast(@alignCast(action)));
    return action;
}

pub fn menuActionSetEnabled(action: ?*anyopaque, enabled: bool) void {
    c.g_simple_action_set_enabled(@ptrCast(@alignCast(action)), @intFromBool(enabled));
}

/// 勾选状态更新（change-state 路径回写）。
pub fn menuActionSetState(action: ?*anyopaque, state: bool) void {
    c.g_simple_action_set_state(@ptrCast(@alignCast(action)), c.g_variant_new_boolean(@intFromBool(state)));
}

/// 激活/状态回调：cb(action, value(GVariant*), user_data)。
/// stateful 动作的勾选切换走 change-state；无参激活走 activate。
/// action 指针经信号 user_data 传递（多动作并存安全）。
pub fn menuActionConnect(
    action: ?*anyopaque,
    stateful: bool,
    cb: *const fn (action: ?*anyopaque, value: ?*anyopaque, user_data: c.gpointer) callconv(.c) void,
    user_data: c.gpointer,
) void {
    const Ctx = struct {
        var handler: ?*const fn (action: ?*anyopaque, value: ?*anyopaque, user_data: c.gpointer) callconv(.c) void = null;
        var ud: c.gpointer = null;
        fn onActivate(_: ?*c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
            if (handler) |h| h(data, null, ud);
        }
        fn onChangeState(_: ?*c.GSimpleAction, value: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
            if (handler) |h| h(data, value, ud);
        }
    };
    Ctx.handler = cb;
    Ctx.ud = user_data;
    if (stateful) {
        _ = c.g_signal_connect_data(@ptrCast(action), "change-state", @ptrCast(&Ctx.onChangeState), action, null, 0);
    } else {
        _ = c.g_signal_connect_data(@ptrCast(action), "activate", @ptrCast(&Ctx.onActivate), action, null, 0);
    }
}

/// 布尔 GVariant → bool（勾选状态读取）。
pub fn variantBoolean(value: ?*anyopaque) bool {
    const v: ?*c.GVariant = @ptrCast(@alignCast(value));
    if (v == null) return false;
    return c.g_variant_get_boolean(v) != 0;
}

/// 弹出上下文菜单：GMenu 模型 + 动作组 → GtkPopoverMenu。
/// 模型/弹出器生命周期归 compat：关闭即 unparent + unref。
/// x/y 为窗口客户区坐标（与 GTK3 popup_at_rect 的 surface 坐标一致）。
pub fn menuPopupAt(
    win: [*c]c.GtkWidget,
    model: ?*anyopaque,
    group: ?*anyopaque,
    x: c_int,
    y: c_int,
) bool {
    const popover = c.gtk_popover_menu_new_from_model(@ptrCast(@alignCast(model))) orelse return false;
    c.gtk_widget_insert_action_group(popover, "ziltmenu", @ptrCast(@alignCast(group)));
    // GMenu 树在弹出后仍被 popover 引用（model 属性持有）——构造方 unref 后
    // 生命周期归 popover。
    c.g_object_unref(@ptrCast(model));
    c.g_object_unref(@ptrCast(group));
    // 定位：popover 挂到窗口上，pointing_to 用客户区坐标
    c.gtk_widget_set_parent(popover, win);
    var rect = c.GdkRectangle{ .x = x, .y = y, .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(@alignCast(popover)), &rect);
    c.gtk_popover_set_position(@ptrCast(@alignCast(popover)), c.GTK_POS_BOTTOM);
    const Ctx = struct {
        fn onClosed(_: ?*c.GtkPopover, data: c.gpointer) callconv(.c) void {
            const pop: [*c]c.GtkWidget = @ptrCast(@alignCast(data));
            c.gtk_widget_unparent(pop);
            c.g_object_unref(@ptrCast(pop));
        }
    };
    _ = c.g_signal_connect_data(@ptrCast(popover), "closed", @ptrCast(&Ctx.onClosed), popover, null, 0);
    c.gtk_popover_popup(@ptrCast(@alignCast(popover)));
    return true;
}

// ---------------------------------------------------------------------------
// 对话框（gtk_dialog_run / gtk_native_dialog_run 移除 → 嵌套循环桥）
// ---------------------------------------------------------------------------

/// GtkDialog 模态运行（message/color/font chooser 共用）。
/// GTK3 = gtk_dialog_run 逐字；GTK4 = response 信号 + SyncWait。
pub fn runDialog(dlg: [*c]c.GtkDialog) c.gint {
    if (comptime isGtk4()) {
        const Ctx = struct {
            var response: c.gint = -1;
            fn onResponse(_: ?*c.GtkDialog, id: c.gint, data: c.gpointer) callconv(.c) void {
                const w: *SyncWait = @ptrCast(@alignCast(data orelse return));
                response = id;
                w.finish();
            }
        };
        var w = SyncWait.begin();
        Ctx.response = -1;
        _ = c.g_signal_connect_data(@ptrCast(dlg), "response", @ptrCast(&Ctx.onResponse), @ptrCast(&w), null, 0);
        c.gtk_window_present(@ptrCast(dlg));
        w.wait();
        return Ctx.response;
    }
    return c.gtk_dialog_run(dlg);
}

/// 对话框销毁（GtkDialog 是 GtkWindow 子类 → 两栈统一走窗口销毁面）。
pub fn destroyDialog(dlg: [*c]c.GtkDialog) void {
    if (comptime isGtk4()) {
        c.gtk_window_destroy(@ptrCast(@alignCast(dlg)));
        return;
    }
    c.gtk_widget_destroy(@ptrCast(dlg));
}

/// GtkFileChooserNative 运行（GTK3 既有语义；GTK4 无 run）。
/// 仅 GTK3 使用：GTK4 文件对话框走 fileDialog*Sync 面。
pub fn nativeDialogRun(native: ?*anyopaque) c.gint {
    if (comptime isGtk4()) {
        return -1;
    }
    return c.gtk_native_dialog_run(@ptrCast(@alignCast(native)));
}

// --------------------- GTK4 文件对话框（GtkFileDialog） ---------------------

/// 打开单文件。返回路径（alloc 分配）或 null（取消）。
pub fn fileDialogOpenSync(
    parent: [*c]c.GtkWindow,
    title_z: [*c]const u8,
    default_name_z: ?[*c]const u8,
    filters: []const FileFilterSpec,
    alloc: std.mem.Allocator,
) ?[]u8 {
    const fd = buildFileDialog(title_z, default_name_z, filters, alloc) orelse return null;
    defer c.g_object_unref(@ptrCast(fd));
    var w = SyncWait.begin();
    c.gtk_file_dialog_open(fd, parent, null, @ptrCast(&onAsyncReady), @ptrCast(&w));
    w.wait();
    if (!w.done or w.result == null) return null;
    defer w.releaseResult();
    var err: ?*c.GError = null;
    const file = c.gtk_file_dialog_open_finish(fd, w.result, &err);
    if (err) |e| c.g_error_free(e);
    return gFilePath(file, alloc);
}

pub fn fileDialogSaveSync(
    parent: [*c]c.GtkWindow,
    title_z: [*c]const u8,
    default_name_z: ?[*c]const u8,
    filters: []const FileFilterSpec,
    alloc: std.mem.Allocator,
) ?[]u8 {
    const fd = buildFileDialog(title_z, default_name_z, filters, alloc) orelse return null;
    defer c.g_object_unref(@ptrCast(fd));
    var w = SyncWait.begin();
    c.gtk_file_dialog_save(fd, parent, null, @ptrCast(&onAsyncReady), @ptrCast(&w));
    w.wait();
    if (!w.done or w.result == null) return null;
    defer w.releaseResult();
    var err: ?*c.GError = null;
    const file = c.gtk_file_dialog_save_finish(fd, w.result, &err);
    if (err) |e| c.g_error_free(e);
    return gFilePath(file, alloc);
}

pub fn fileDialogSelectFolderSync(
    parent: [*c]c.GtkWindow,
    title_z: [*c]const u8,
    alloc: std.mem.Allocator,
) ?[]u8 {
    const fd = c.gtk_file_dialog_new() orelse return null;
    defer c.g_object_unref(@ptrCast(fd));
    c.gtk_file_dialog_set_title(fd, title_z);
    var w = SyncWait.begin();
    c.gtk_file_dialog_select_folder(fd, parent, null, @ptrCast(&onAsyncReady), @ptrCast(&w));
    w.wait();
    if (!w.done or w.result == null) return null;
    defer w.releaseResult();
    var err: ?*c.GError = null;
    const file = c.gtk_file_dialog_select_folder_finish(fd, w.result, &err);
    if (err) |e| c.g_error_free(e);
    return gFilePath(file, alloc);
}

/// 多选打开。返回路径数组（alloc 分配）或 null。
pub fn fileDialogOpenMultipleSync(
    parent: [*c]c.GtkWindow,
    title_z: [*c]const u8,
    filters: []const FileFilterSpec,
    alloc: std.mem.Allocator,
) ?[][]u8 {
    const fd = buildFileDialog(title_z, null, filters, alloc) orelse return null;
    defer c.g_object_unref(@ptrCast(fd));
    var w = SyncWait.begin();
    c.gtk_file_dialog_open_multiple(fd, parent, null, @ptrCast(&onAsyncReady), @ptrCast(&w));
    w.wait();
    if (!w.done or w.result == null) return null;
    defer w.releaseResult();
    var err: ?*c.GError = null;
    const list = c.gtk_file_dialog_open_multiple_finish(fd, w.result, &err);
    if (err) |e| c.g_error_free(e);
    if (list == null) return null;
    defer c.g_object_unref(@ptrCast(list));
    const n = c.g_list_model_get_n_items(@ptrCast(@alignCast(list)));
    if (n == 0) return null;
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const item = c.g_list_model_get_item(@ptrCast(@alignCast(list)), i) orelse continue;
        defer c.g_object_unref(@ptrCast(item));
        if (gFilePath(item, alloc)) |p| {
            paths.append(alloc, p) catch {
                alloc.free(p);
                continue;
            };
        }
    }
    if (paths.items.len == 0) return null;
    return paths.items;
}

/// 过滤器 spec（IPC 原始切片；compat 内部做 null 终结拷贝）。
pub const FileFilterSpec = struct {
    name: []const u8,
    pattern: []const u8, // 分号分隔（与 IPC 面一致）
};

fn buildFileDialog(title_z: [*c]const u8, default_name_z: ?[*c]const u8, filters: []const FileFilterSpec, alloc: std.mem.Allocator) ?*c.GtkFileDialog {
    const fd = c.gtk_file_dialog_new() orelse return null;
    c.gtk_file_dialog_set_title(fd, title_z);
    if (default_name_z) |name| c.gtk_file_dialog_set_initial_name(fd, name);
    if (filters.len > 0) {
        const store = c.g_list_store_new(c.g_object_get_type()) orelse {
            c.g_object_unref(@ptrCast(fd));
            return null;
        };
        for (filters) |f| {
            const filter = c.gtk_file_filter_new() orelse continue;
            if (f.name.len > 0) {
                const name_z = alloc.allocSentinel(u8, f.name.len, 0) catch continue;
                @memcpy(name_z, f.name);
                c.gtk_file_filter_set_name(filter, name_z.ptr);
            }
            var it = std.mem.splitScalar(u8, f.pattern, ';');
            while (it.next()) |pattern| {
                const trimmed = std.mem.trim(u8, pattern, " \t");
                if (trimmed.len == 0) continue;
                const pat_z = alloc.allocSentinel(u8, trimmed.len, 0) catch continue;
                @memcpy(pat_z, trimmed);
                c.gtk_file_filter_add_pattern(filter, pat_z.ptr);
            }
            c.g_list_store_append(@ptrCast(@alignCast(store)), @ptrCast(@alignCast(filter)));
            c.g_object_unref(@ptrCast(filter)); // store 已持引用
        }
        c.gtk_file_dialog_set_filters(fd, @ptrCast(@alignCast(store)));
        c.g_object_unref(@ptrCast(store));
    }
    return fd;
}

fn gFilePath(file: ?*anyopaque, alloc: std.mem.Allocator) ?[]u8 {
    const f: ?*c.GFile = @ptrCast(@alignCast(file));
    if (f == null) return null;
    defer c.g_object_unref(@ptrCast(f));
    const path = c.g_file_get_path(f) orelse return null;
    defer c.g_free(@ptrCast(path));
    return alloc.dupe(u8, std.mem.span(path)) catch null;
}

// ---------------------------------------------------------------------------
// 拖放（GtkDropTarget 替代 gtk_drag_dest_*；drop 信号内读 uri-list）
// ---------------------------------------------------------------------------

/// 每窗口拖入目标（文件拖入 → uri-list）。挂在 WebView 上。
/// mimes 必须是 null 终结的字面量切片（GTK3 分支的声明形参）。
pub fn dropTargetAttach(
    view: [*c]c.GtkWidget,
    mimes: []const [*:0]const u8,
    on_drop: *const fn (user_data: c.gpointer, data: ?*const anyopaque, len: usize) callconv(.c) void,
    user_data: c.gpointer,
) bool {
    // 双分支参数用法互斥（gtk4 用 view/on_drop，gtk3 全不用）→ 变体命名空间：
    // 未选中的 impl 不被分析，param 用法/弃用矛盾消解。
    const Impl = if (comptime isGtk4()) Gtk4Drop else Gtk3Drop;
    return Impl.attach(view, mimes, on_drop, user_data);
}

const Gtk3Drop = struct {
    fn attach(
        view: [*c]c.GtkWidget,
        mimes: []const [*:0]const u8,
        on_drop: *const fn (user_data: c.gpointer, data: ?*const anyopaque, len: usize) callconv(.c) void,
        user_data: c.gpointer,
    ) bool {
        _ = view;
        _ = mimes;
        _ = on_drop;
        _ = user_data;
        return false;
    }
};

const Gtk4Drop = struct {
    fn attach(
        view: [*c]c.GtkWidget,
        mimes: []const [*:0]const u8,
        on_drop: *const fn (user_data: c.gpointer, data: ?*const anyopaque, len: usize) callconv(.c) void,
        user_data: c.gpointer,
    ) bool {
        _ = mimes;
        const Ctx = struct {
            var handler: ?*const fn (user_data: c.gpointer, data: ?*const anyopaque, len: usize) callconv(.c) void = null;
            var ud: c.gpointer = null;
            fn onDrop(target: ?*c.GtkDropTarget, _: c.gdouble, _: c.gdouble, value: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
                const drop = c.gtk_drop_target_get_drop(target) orelse return 1; // 已消费但无数据
                // GValue → GdkFileList → GSList(GFile) → uri-list CRLF 字节流
                const obj = c.g_value_get_object(value);
                const list: ?*c.GdkFileList = @ptrCast(@alignCast(obj));
                var out: std.ArrayListUnmanaged(u8) = .empty;
                defer out.deinit(std.heap.c_allocator);
                if (list != null) {
                    const node = c.gdk_file_list_get_files(list);
                    var it: [*c]c.GSList = node;
                    while (it != null) : (it = it.*.next) {
                        const file: ?*c.GFile = @ptrCast(@alignCast(it.*.data orelse continue));
                        const uri = c.g_file_get_uri(file) orelse continue;
                        defer c.g_free(@ptrCast(uri));
                        if (out.items.len != 0) out.appendSlice(std.heap.c_allocator, "\r\n") catch break;
                        out.appendSlice(std.heap.c_allocator, std.mem.span(uri)) catch break;
                    }
                }
                if (handler) |h| {
                    if (out.items.len > 0) {
                        h(data, out.items.ptr, out.items.len);
                    } else {
                        h(data, null, 0);
                    }
                }
                c.gdk_drop_finish(drop, c.GDK_ACTION_COPY);
                return 1;
            }
        };
        Ctx.handler = on_drop;
        Ctx.ud = user_data;
        // GTK4 4.10+：GtkDropTarget 为 GType 值模型——GDK_TYPE_FILE_LIST 让 GDK
        // 自动把 uri-list 转成 GdkFileList（多文件），drop 信号内同步取值。
        const target = c.gtk_drop_target_new(c.gdk_file_list_get_type(), c.GDK_ACTION_COPY);
        if (target == null) return false;
        _ = c.g_signal_connect_data(@ptrCast(target), "drop", @ptrCast(&Ctx.onDrop), user_data, null, 0);
        c.gtk_widget_add_controller(view, @ptrCast(@alignCast(target)));
        return true;
    }
};

// ---------------------------------------------------------------------------
// 透明窗口 draw 清屏（GTK3 专用——CSS 面接管后 GTK4 不需要）
// ---------------------------------------------------------------------------

pub fn transparentDrawNeeded() bool {
    return isGtk3();
}

// ---------------------------------------------------------------------------
// 拖出（drag.start）：GTK3 保留既有 begin_with_coordinates 路径（backend 内）；
// GTK4 无公开的脚本发起拖拽入口 → 调用方返回 DragNotAvailable（文档化）。
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// WebKitGTK 6.0 构造器收敛（6.0 移除 *_with_context / *_with_user_content_manager /
// website_data_manager_new / web_context_new_with_website_data_manager →
// g_object_new 属性面；GTK3 分支保持原生构造器逐字不变）
// ---------------------------------------------------------------------------

pub fn webViewNew(ucm: ?*anyopaque, ctx: ?*anyopaque, session: ?*anyopaque) ?*anyopaque {
    if (comptime isGtk4()) {
        // 6.0：网络面（cookie/代理/存储）在 WebKitNetworkSession——有 session 时
        // 显式传入（与 ctx 的 data manager 同源）。NULL 属性值不传（g_object_new
        // 对构造属性显式 NULL 实测 GPF——按非空逐项构造）。
        const wtype = c.webkit_web_view_get_type();
        if (ctx != null and session != null and ucm != null) {
            return c.g_object_new(wtype, "user-content-manager", ucm, "web-context", ctx, "network-session", session, @as(?*anyopaque, null));
        }
        if (ctx != null and session != null) {
            return c.g_object_new(wtype, "web-context", ctx, "network-session", session, @as(?*anyopaque, null));
        }
        if (ctx != null) {
            return c.g_object_new(wtype, "web-context", ctx, @as(?*anyopaque, null));
        }
        if (ucm != null) {
            return c.g_object_new(wtype, "user-content-manager", ucm, @as(?*anyopaque, null));
        }
        return c.webkit_web_view_new();
    }
    if (ctx) |wctx| {
        return c.webkit_web_view_new_with_context(@ptrCast(@alignCast(wctx)));
    }
    return c.webkit_web_view_new_with_user_content_manager(@ptrCast(@alignCast(ucm)));
}

/// 6.0 的网络会话（cookie/代理/下载/缓存的宿主；目录承载持久化）。
/// GTK3 无此概念 → null（调用方按 null 走 context 面）。
pub fn networkSessionNew(data_dir_z: [*:0]const u8, cache_dir_z: [*:0]const u8) ?*anyopaque {
    if (comptime isGtk4()) {
        return c.webkit_network_session_new(data_dir_z, cache_dir_z);
    }
    return null;
}

/// 6.0 的无痕网络会话（内存态；GTK3 → null）。
pub fn networkSessionNewEphemeral() ?*anyopaque {
    if (comptime isGtk4()) {
        return c.webkit_network_session_new_ephemeral();
    }
    return null;
}

/// 默认网络会话（6.0：主窗口下载面挂这里）。GTK3 → null。
pub fn networkSessionDefault() ?*anyopaque {
    if (comptime isGtk4()) {
        return c.webkit_network_session_get_default();
    }
    return null;
}

/// 代理设置（6.0：session 面；GTK3：context 面）。settings 句柄由调用方释放。
pub fn setNetworkProxySettings(target: ?*anyopaque, mode_int: c_uint, settings: ?*anyopaque) void {
    if (comptime isGtk4()) {
        // 6.0：webkit_network_session_set_proxy_settings（mode 类型是 c_uint typedef）
        c.webkit_network_session_set_proxy_settings(
            @ptrCast(@alignCast(target)),
            mode_int,
            @ptrCast(@alignCast(settings)),
        );
        return;
    }
    c.webkit_web_context_set_network_proxy_settings(
        @ptrCast(@alignCast(target)),
        mode_int,
        @ptrCast(@alignCast(settings)),
    );
}

/// script-message 注册（6.0 三参带 realm；4.1 两参）。
pub fn registerScriptMessageHandler(ucm: ?*anyopaque, name_z: [*:0]const u8) bool {
    if (comptime isGtk4()) {
        return c.webkit_user_content_manager_register_script_message_handler(
            @ptrCast(@alignCast(ucm)),
            name_z,
            null, // realm：默认分区
        ) != 0;
    }
    return c.webkit_user_content_manager_register_script_message_handler(
        @ptrCast(@alignCast(ucm)),
        name_z,
    ) != 0;
}

pub fn websiteDataManagerNew(base_data_dir_z: [*:0]const u8) ?*anyopaque {
    if (comptime isGtk4()) {
        return c.g_object_new(
            c.webkit_website_data_manager_get_type(),
            "base-data-directory",
            base_data_dir_z,
            @as(?*anyopaque, null),
        );
    }
    return c.webkit_website_data_manager_new(
        "base-data-directory",
        @as(?*const anyopaque, base_data_dir_z),
        @as(?*anyopaque, null),
    );
}

pub fn websiteDataManagerNewEphemeral() ?*anyopaque {
    if (comptime isGtk4()) {
        return c.g_object_new(
            c.webkit_website_data_manager_get_type(),
            "ephemeral",
            @as(c.gboolean, 1),
            @as(?*anyopaque, null),
        );
    }
    return c.webkit_website_data_manager_new_ephemeral();
}

pub fn webContextNewWithManager(mgr: ?*anyopaque) ?*anyopaque {
    if (comptime isGtk4()) {
        // 6.0：data manager 移到 WebKitNetworkSession，ctx 只承载 scheme/进程策略
        return c.webkit_web_context_new();
    }
    return c.webkit_web_context_new_with_website_data_manager(@ptrCast(@alignCast(mgr)));
}

/// Cookie manager 归属：6.0 在 session；GTK3 在 context。
pub fn cookieManagerFromSessionOrContext(session: ?*anyopaque, ctx: ?*anyopaque) ?*anyopaque {
    if (comptime isGtk4()) {
        const s: ?*c.WebKitNetworkSession = @ptrCast(@alignCast(session));
        if (s == null) return null;
        return c.webkit_network_session_get_cookie_manager(s);
    }
    return c.webkit_web_context_get_cookie_manager(@ptrCast(@alignCast(ctx)));
}

/// script-message 载荷 → JSCValue（GTK3：WebKitJavascriptResult 解包；
/// 6.0：信号直接携带 JSCValue）。
pub fn scriptMessageJscValue(payload: ?*anyopaque) ?*anyopaque {
    if (comptime isGtk4()) {
        return payload;
    }
    const value = c.webkit_javascript_result_get_js_value(@ptrCast(@alignCast(payload)));
    return value;
}

pub fn programmaticDragAvailable() bool {
    return caps().programmatic_drag;
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

test "SyncWait：finish→wait 唤醒语义" {
    var w = SyncWait.begin();
    defer {
        if (w.loop) |lp| c.g_main_loop_unref(lp);
    }
    w.result = null;
    w.finish();
    // finish 后 wait 立即返回（loop 已 quit；这里 loop 可能已 unref——防重入）
    try std.testing.expect(w.done);
}

test "MOD1/MOD2 掩码：双栈数值一致（X11 位序）" {
    const m1: c.GdkModifierType = MOD1_MASK;
    const m2: c.GdkModifierType = MOD2_MASK;
    try std.testing.expectEqual(@as(c.GdkModifierType, 1 << 3), m1);
    try std.testing.expectEqual(@as(c.GdkModifierType, 1 << 4), m2);
}

test "variant 探测：本构建按 gtk_init 签名判定" {
    const F = @TypeOf(c.gtk_init);
    const n = @typeInfo(F).@"fn".param_types.len;
    if (n == 0) {
        try std.testing.expectEqual(Variant.gtk4, variant);
        try std.testing.expect(isGtk4());
    } else {
        try std.testing.expectEqual(Variant.gtk3, variant);
        try std.testing.expect(isGtk3());
    }
}

test "caps：GTK3 全能力；GTK4 五面降级、剪贴板读两栈都在" {
    const cp = caps();
    const full = isGtk3();
    try std.testing.expectEqual(full, cp.tray);
    try std.testing.expectEqual(full, cp.menu_bar);
    try std.testing.expectEqual(full, cp.programmatic_drag);
    try std.testing.expectEqual(full, cp.cursor_grab);
    try std.testing.expectEqual(full, cp.cookie_clear_by_domain);
    try std.testing.expect(cp.clipboard_read);
}

test "capsJson：冒烟注入载荷六键齐全、值随变体" {
    var buf: [256]u8 = undefined;
    const s = capsJson(&buf) orelse return error.BufferTooSmall;
    inline for (.{
        "tray", "menu_bar", "programmatic_drag", "cursor_grab", "cookie_clear_by_domain", "clipboard_read",
    }) |k| {
        try std.testing.expect(std.mem.indexOf(u8, s, "\"" ++ k ++ "\":") != null);
    }
    const tray_lit = if (isGtk3()) "\"tray\":true" else "\"tray\":false";
    try std.testing.expect(std.mem.indexOf(u8, s, tray_lit) != null);
}

// GAsyncResult 的生命周期只到 GAsyncReadyCallback 返回为止：回调里不 ref，
// 消费方随后 xxx_finish(result) 就是 use-after-free，再 unref 就是二次释放
//（GTK4 剪贴板读面此前被记为「并发读触发 g_task 断言 + 堆破坏」的形态）。
test "SyncWait：结果引用归 SyncWait——调用方 unref 后仍存活，releaseResult 后析构" {
    const task = c.g_task_new(null, null, null, null);
    try std.testing.expect(task != null);
    const obj: *c.GObject = @ptrCast(@alignCast(task.?));
    std.debug.print("DIAG glib={d}.{d}.{d} rc_new={d}\n", .{ c.glib_major_version, c.glib_minor_version, c.glib_micro_version, obj.ref_count });
    c.g_task_return_boolean(@ptrCast(task), 1);
    std.debug.print("DIAG rc_returned={d}\n", .{obj.ref_count});
    var weak: ?*anyopaque = null;
    c.g_object_add_weak_pointer(@ptrCast(@alignCast(task)), @ptrCast(&weak));
    std.debug.print("DIAG weak_added={any}\n", .{weak != null});

    var w = SyncWait.begin();
    defer if (w.loop) |lp| c.g_main_loop_unref(lp);
    onAsyncReady(null, @ptrCast(task), @ptrCast(&w));
    std.debug.print("DIAG rc_cb={d} held={any}\n", .{ obj.ref_count, w.result != null });
    // 调用方交出唯一引用：回调若没自己 ref，对象此刻已析构
    c.g_object_unref(@ptrCast(task));
    std.debug.print("DIAG weak_after_unref={any}\n", .{weak != null});
    if (weak != null) std.debug.print("DIAG rc_unref={d}\n", .{obj.ref_count});
    try std.testing.expect(w.done);
    try std.testing.expect(weak != null);
    w.releaseResult();
    try std.testing.expect(weak == null);
}

// 诊断对照：换成无异步语义的普通 GObject（GCancellable），隔离 GTask 的
// return/idle 机制是否才是 weak 变 null 的原因。
test "DIAG: GCancellable 走同一序列" {
    const o = c.g_cancellable_new();
    try std.testing.expect(o != null);
    const obj: *c.GObject = @ptrCast(@alignCast(o.?));
    std.debug.print("DIAG2 rc_new={d}\n", .{obj.ref_count});
    var weak: ?*anyopaque = null;
    c.g_object_add_weak_pointer(@ptrCast(@alignCast(o)), @ptrCast(&weak));
    var w = SyncWait.begin();
    defer if (w.loop) |lp| c.g_main_loop_unref(lp);
    onAsyncReady(null, @ptrCast(o), @ptrCast(&w));
    std.debug.print("DIAG2 rc_cb={d} held={any}\n", .{ obj.ref_count, w.result != null });
    c.g_object_unref(@ptrCast(o));
    std.debug.print("DIAG2 weak_after_unref={any}\n", .{weak != null});
    if (weak != null) std.debug.print("DIAG2 rc_unref={d}\n", .{obj.ref_count});
    try std.testing.expect(weak != null);
    w.releaseResult();
    try std.testing.expect(weak == null);
}
