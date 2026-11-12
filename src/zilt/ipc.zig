//! IPC 协议层（平台无关）：JSON 消息协议、comptime 命令/事件分发、Context。
//!
//! 协议（v1）：
//!   JS→Zig  {"zilt":1,"kind":"invoke","id":N,"method":"greet","args":{...}}
//!           {"zilt":1,"kind":"event","name":"frontendLog","payload":{...}}
//!   Zig→JS  {"zilt":1,"kind":"resolve","id":N,"result":<json>}
//!           {"zilt":1,"kind":"reject","id":N,"error":"ErrorName"}
//!           {"zilt":1,"kind":"event","name":"tick","payload":{...}}
//!
//! 约定：用户在 Config.commands 定义 `pub fn 名字(ctx: Context, args: struct{...}) !结果`，
//! comptime 反射自动生成分发表与 TS 绑定（见 bindings.zig）。`zilt` 标记字段用于
//! 忽略页面上其他 postMessage 流量。

const std = @import("std");
const updater = @import("updater.zig");
const clipboard = @import("clipboard.zig");
const notification = @import("notification.zig");
const webview = @import("webview.zig");
pub const system_api = @import("system_api.zig");

pub const EvalCallback = @FieldType(webview.Completion, "callback");

// ---------------------------------------------------------------------------
// 原生对话框（平台后端实现；Context 暴露类型安全接口）
// ---------------------------------------------------------------------------

pub const MsgKind = enum { info, warning, err };
pub const MsgButtons = enum { ok, ok_cancel, yes_no };
pub const Button = enum { ok, cancel, yes, no };

pub const MessageBoxOptions = struct {
    text: []const u8,
    caption: []const u8 = "提示",
    kind: MsgKind = .info,
    buttons: MsgButtons = .ok,
};

pub const Filter = struct {
    /// 显示名（如 "文本文件"）
    name: []const u8,
    /// 模式（如 "*.txt"）
    pattern: []const u8,
};

pub const FileDialogOptions = struct {
    title: []const u8 = "",
    filters: []const Filter = &.{},
    default_name: []const u8 = "",
};

pub const FolderDialogOptions = struct {
    title: []const u8 = "选择文件夹",
};

pub const ColorDialogOptions = struct {
    title: []const u8 = "选择颜色",
    /// 初始颜色（0xRRGGBB）
    default_rgb: u32 = 0x3B82F6,
    /// 展开自定义颜色区
    full_open: bool = true,
};

pub const FontDialogOptions = struct {
    title: []const u8 = "选择字体",
    /// 初始颜色（0xRRGGBB；需 effects = true 才可见颜色下拉）
    color_rgb: u32 = 0x000000,
    effects: bool = true,
};

/// 字体选择结果。
pub const FontChoice = struct {
    name: []const u8,
    /// 点大小（1/10 磅为单位的 iPointSize / 10）
    size_points: i32,
    bold: bool,
    italic: bool,
    underline: bool,
    strikeout: bool,
    color_rgb: u32,
};

pub const DialogRequest = union(enum) {
    message_box: MessageBoxOptions,
    open_file: FileDialogOptions,
    save_file: FileDialogOptions,
    /// 文件夹选择（IFileDialog FOS_PICKFOLDERS；v0.1.5）
    pick_folder: FolderDialogOptions,
    /// 多选文件（FOS_ALLOWMULTISELECT；v0.1.5）
    pick_files: FileDialogOptions,
    /// 颜色选择（ChooseColorW；v0.1.5）
    pick_color: ColorDialogOptions,
    /// 字体选择（ChooseFontW；v0.1.5）
    pick_font: FontDialogOptions,
};

pub const DialogResponse = union(enum) {
    button: Button,
    path: ?[]u8,
    /// 多选文件（每个路径与外层切片均用请求的 allocator 分配）
    paths: ?[][]u8,
    /// RGB（0xRRGGBB）
    color: ?u32,
    font: ?FontChoice,
};

// ---------------------------------------------------------------------------
// 多窗口 / 窗口控制 / 剪贴板（平台后端实现；Context 暴露类型安全接口）
// ---------------------------------------------------------------------------

pub const WindowOptions = struct {
    label: ?[]const u8 = null,
    parent: ?u32 = null,
    modal: bool = false,
    child: bool = false,
    menu: ?[]const @import("config.zig").Config.MenuItem = null,
    state_key: ?[]const u8 = null,
    title: []const u8 = "Zilt Window",
    width: u32 = 900,
    height: u32 = 640,
    /// 完整 URL（如 "https://zilt.app/second.html"）；null = 应用主 URL
    url: ?[]const u8 = null,
    /// 初始位置（null = 系统默认）
    x: ?i32 = null,
    y: ?i32 = null,
    /// 创建时是否可见（false = 隐藏创建，后续 show）
    visible: bool = true,
    /// 是否可调整大小
    resizable: bool = true,
    /// 是否带原生标题栏/边框
    decorations: bool = true,
    /// WebView 背景透明（桌面透出）
    transparent: bool = false,
    /// 置顶
    always_on_top: bool = false,
    /// 从任务栏/Alt-Tab 隐藏
    skip_taskbar: bool = false,
    /// 最小/最大窗口尺寸（外层像素，null = 不限）
    min_width: ?u32 = null,
    min_height: ?u32 = null,
    max_width: ?u32 = null,
    max_height: ?u32 = null,
    /// WebView 默认背景色（0xRRGGBB；null = 白色）
    background_color: ?u32 = null,
    /// 关闭前发 windowCloseRequested，由前端调用 windowClose 才真正关闭
    close_requested_event: bool = false,
    /// 每窗口图标（资产路径；null = 应用默认图标）
    icon: ?[]const u8 = null,
    /// v0.1.23：本窗口专用代理（`127.0.0.1:7890` / `http://host:port`）。
    /// WebView2 的代理是 **Environment 级**选项，因此指定后该窗口会使用独立环境 +
    /// 独立 profile 目录（cookie/缓存不与其他窗口共享）。
    proxy: ?[]const u8 = null,
    /// v0.1.23：覆盖式标题栏（无原生标题栏，WebView 铺满窗口；前端用
    /// `data-zilt-drag-region` 拖动，窗口按钮用 window.minimize/maximize/close）。
    /// 四边仍可缩放（8px 命中区）。
    titlebar_overlay: bool = false,
};

/// v0.1.18：窗口光标形状（对齐 Tauri `CursorIcon` 的 Windows 子集）。
pub const CursorKind = enum {
    default,
    arrow,
    ibeam,
    crosshair,
    hand,
    wait,
    help,
    not_allowed,
    size_ns,
    size_ew,
    size_nwse,
    size_nesw,
    move,
    up_arrow,

    pub fn fromName(name: []const u8) ?CursorKind {
        const eql = std.ascii.eqlIgnoreCase;
        if (eql(name, "default") or eql(name, "arrow")) return .arrow;
        if (eql(name, "ibeam") or eql(name, "text")) return .ibeam;
        if (eql(name, "crosshair")) return .crosshair;
        if (eql(name, "hand") or eql(name, "pointer")) return .hand;
        if (eql(name, "wait") or eql(name, "progress")) return .wait;
        if (eql(name, "help")) return .help;
        if (eql(name, "not-allowed") or eql(name, "notallowed") or eql(name, "no")) return .not_allowed;
        if (eql(name, "size-ns") or eql(name, "ns-resize") or eql(name, "ns")) return .size_ns;
        if (eql(name, "size-ew") or eql(name, "ew-resize") or eql(name, "ew")) return .size_ew;
        if (eql(name, "size-nwse") or eql(name, "nwse-resize")) return .size_nwse;
        if (eql(name, "size-nesw") or eql(name, "nesw-resize")) return .size_nesw;
        if (eql(name, "move") or eql(name, "grabbing")) return .move;
        if (eql(name, "up-arrow") or eql(name, "uparrow")) return .up_arrow;
        return null;
    }
};

/// v0.1.18：每窗口外观覆盖（Win11 标题栏配色，颜色为 0xRRGGBB）。
pub const WindowTheme = struct {
    dark: ?bool = null,
    caption: ?u32 = null,
    text: ?u32 = null,
    border: ?u32 = null,
};

/// v0.1.18：运行时改尺寸约束（null = 不改；0 = 清除该约束）。
pub const WindowLimits = struct {
    min_width: ?u32 = null,
    min_height: ?u32 = null,
    max_width: ?u32 = null,
    max_height: ?u32 = null,
};

pub const WindowCmd = union(enum) {
    set_title: []const u8,
    minimize,
    maximize,
    restore,
    fullscreen: bool,
    size: struct { width: u32, height: u32 },
    position: struct { x: i32, y: i32 },
    show,
    hide,
    focus,
    close,
    start_dragging,
    always_on_top: bool,
    skip_taskbar: bool,
    // ---- v0.1.18：对齐 Tauri/Wails 的窗口精细控制 ----
    cursor: CursorKind,
    cursor_visible: bool,
    cursor_grab: bool,
    cursor_position: struct { x: i32, y: i32 },
    /// 鼠标事件穿透到下层窗口（WS_EX_LAYERED | WS_EX_TRANSPARENT）
    ignore_cursor: bool,
    /// 禁止截图/录屏捕获（SetWindowDisplayAffinity WDA_EXCLUDEFROMCAPTURE）
    content_protected: bool,
    /// DWM 边框阴影（对无边框窗口有效）
    shadow: bool,
    always_on_bottom: bool,
    /// 不参与激活（WS_EX_NOACTIVATE）
    focusable: bool,
    enabled: bool,
    theme: WindowTheme,
    limits: WindowLimits,
    /// 全屏到指定显示器（0 基索引，按 EnumDisplayMonitors 顺序）
    fullscreen_monitor: u32,
    /// 运行时替换窗口图标；null = 恢复应用默认图标
    icon: ?[]const u8,
    /// 查询窗口当前状态（JSON），用于调试与自动化断言
    state,
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// 命令/事件处理器拿到的执行环境。
///
/// 两个分配器的契约：
///  - `allocator`：当前调用域（分发时是 per-message arena，响应发出后销毁）。
///  - `msg_allocator`：长生命周期分配器——emit 消息用它分配（可能比本次调用活得久，
///    需要跨线程 marshal），后端收到后用同一分配器释放。
///
/// emit 线程安全：平台后端负责把事件编排（marshal）到 UI 线程后再投递。
/// emit 默认发往 `window_id` 对应窗口（0 = 主窗口）；`emitTo` 可指定目标窗口。
pub const Context = struct {
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    backend: *anyopaque,
    /// 当前上下文所属窗口 id（0 = 主窗口/应用级）
    window_id: u32 = 0,
    emit_fn: *const fn (backend: *anyopaque, window_id: u32, message_json: []const u8) void,
    quit_fn: *const fn (backend: *anyopaque, code: u8) void,
    /// 系统通知（由平台后端 marshal 到 UI 线程）。null = 未启用。
    notify_fn: ?*const fn (backend: *anyopaque, title: []const u8, body: []const u8) void = null,
    /// 原生对话框（UI 线程调用；模态会阻塞至用户关闭）。null = 不可用。
    dialog_fn: ?*const fn (backend: *anyopaque, alloc: std.mem.Allocator, req: DialogRequest) anyerror!DialogResponse = null,
    /// 自动更新器环境（config.update 存在时由后端组装）。null = 未配置。
    updater_env: ?updater.Env = null,
    /// 重启以应用已暂存的更新（v0.1.5：分离接力进程拉起新 exe 后退出）。null = 不可用。
    restart_fn: ?*const fn (backend: *anyopaque) void = null,
    /// 窗口控制（v0.1.6：跨线程安全 marshal 到 UI 线程）。null = 平台不支持。
    window_fn: ?*const fn (backend: *anyopaque, window_id: u32, cmd: WindowCmd) bool = null,
    /// v0.1.18：窗口状态查询（返回 allocator 分配的 JSON，所有权归调用方）。
    window_query_fn: ?*const fn (backend: *anyopaque, window_id: u32, alloc: std.mem.Allocator) ?[]u8 = null,
    /// 新建窗口（返回新窗口 id；null = 创建失败/平台不支持）。
    spawn_window_fn: ?*const fn (backend: *anyopaque, opts: WindowOptions) ?u32 = null,
    /// 剪贴板写文本（成功 true）。
    clipboard_write_fn: ?*const fn (backend: *anyopaque, text: []const u8) bool = null,
    /// 剪贴板读文本（调用方 allocator 分配；无文本 null）。
    clipboard_read_fn: ?*const fn (backend: *anyopaque, alloc: std.mem.Allocator) ?[]u8 = null,

    /// Returned clipboard data and JSON belong to the supplied allocator.
    clipboard_read_data_fn: ?*const fn (backend: *anyopaque, window_id: u32, alloc: std.mem.Allocator, format: clipboard.Format) anyerror!?clipboard.Data = null,
    clipboard_write_data_fn: ?*const fn (backend: *anyopaque, window_id: u32, data: clipboard.Data) anyerror!void = null,
    start_drag_fn: ?*const fn (backend: *anyopaque, window_id: u32, files: []const []const u8) anyerror!void = null,
    notification_show_fn: ?*const fn (backend: *anyopaque, window_id: u32, options: notification.Options) anyerror!void = null,
    notification_update_fn: ?*const fn (backend: *anyopaque, window_id: u32, tag: []const u8, group: ?[]const u8, progress: notification.Progress) anyerror!void = null,
    notification_status_fn: ?*const fn (backend: *anyopaque, window_id: u32) anyerror!notification.Status = null,
    webview_request_fn: ?*const fn (backend: *anyopaque, window_id: u32, alloc: std.mem.Allocator, request: webview.Request) anyerror![]u8 = null,
    /// Backend copies script before returning; completion JSON is borrowed.
    eval_async_fn: ?*const fn (backend: *anyopaque, window_id: u32, script: []const u8, completion: webview.Completion) anyerror!void = null,
    /// 系统能力统一通道（v0.1.13/v0.1.14）：菜单 / 托盘 / 快捷键 / 任务栏 /
    /// 系统信息 / Shell / 开机自启 / 窗口效果。null = 平台不支持。
    system_fn: ?*const fn (backend: *anyopaque, window_id: u32, alloc: std.mem.Allocator, req: system_api.Request) anyerror!system_api.Result = null,

    pub fn systemRequest(self: Context, req: system_api.Request) !system_api.Result {
        return (self.system_fn orelse return error.SystemNotAvailable)(self.backend, self.window_id, self.allocator, req);
    }

    pub fn clipboardRead(self: Context, format: clipboard.Format) !?clipboard.Data {
        return (self.clipboard_read_data_fn orelse return error.ClipboardNotAvailable)(self.backend, self.window_id, self.allocator, format);
    }

    pub fn clipboardWrite(self: Context, data: clipboard.Data) !void {
        return (self.clipboard_write_data_fn orelse return error.ClipboardNotAvailable)(self.backend, self.window_id, data);
    }

    pub fn startDrag(self: Context, files: []const []const u8) !void {
        return (self.start_drag_fn orelse return error.DragNotAvailable)(self.backend, self.window_id, files);
    }

    pub fn notificationShow(self: Context, options: notification.Options) !void {
        return (self.notification_show_fn orelse return error.NotificationNotAvailable)(self.backend, self.window_id, options);
    }

    pub fn notificationUpdate(self: Context, tag: []const u8, group: ?[]const u8, progress: notification.Progress) !void {
        return (self.notification_update_fn orelse return error.NotificationNotAvailable)(self.backend, self.window_id, tag, group, progress);
    }

    pub fn notificationStatus(self: Context) !notification.Status {
        return (self.notification_status_fn orelse return error.NotificationNotAvailable)(self.backend, self.window_id);
    }

    /// Returns owned JSON. The backend may return WouldBlock on the UI thread.
    pub fn webviewRequest(self: Context, request: webview.Request) ![]u8 {
        return (self.webview_request_fn orelse return error.WebViewNotAvailable)(self.backend, self.window_id, self.allocator, request);
    }

    pub fn eval(self: Context, script: []const u8) ![]u8 {
        return self.webviewRequest(.{ .eval = .{ .script = script } });
    }

    /// If submission returns an error, no callback is owed. Otherwise completion
    /// runs exactly once (possibly inline), including action errors. Keep context
    /// alive until completion; its JSON is borrowed only for the callback.
    pub fn evalAsync(self: Context, script: []const u8, context: *anyopaque, completion: EvalCallback) !void {
        return (self.eval_async_fn orelse return error.WebViewNotAvailable)(self.backend, self.window_id, script, .{ .context = context, .callback = completion });
    }

    /// 发送系统通知（Windows: 托盘气球 → Toast）。
    pub fn notify(self: Context, title: []const u8, body: []const u8) void {
        if (self.notify_fn) |f| {
            f(self.backend, title, body);
        } else {
            std.log.warn("[zilt] notify ignored (tray not enabled in config)", .{});
        }
    }

    /// 消息框（模态）。返回用户点击的按钮。
    pub fn messageBox(self: Context, opts: MessageBoxOptions) anyerror!Button {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, self.allocator, .{ .message_box = opts });
        return switch (r) {
            .button => |b| b,
            else => error.DialogNotAvailable,
        };
    }

    /// 打开文件对话框。取消返回 null（路径用传入的 allocator 分配）。
    pub fn openFile(self: Context, alloc: std.mem.Allocator, opts: FileDialogOptions) anyerror!?[]u8 {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, alloc, .{ .open_file = opts });
        return switch (r) {
            .path => |p| p,
            else => error.DialogNotAvailable,
        };
    }

    /// 保存文件对话框（覆盖提示）。取消返回 null。
    pub fn saveFile(self: Context, alloc: std.mem.Allocator, opts: FileDialogOptions) anyerror!?[]u8 {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, alloc, .{ .save_file = opts });
        return switch (r) {
            .path => |p| p,
            else => error.DialogNotAvailable,
        };
    }

    /// 选择文件夹（IFileDialog FOS_PICKFOLDERS；模态）。取消返回 null。
    pub fn pickFolder(self: Context, alloc: std.mem.Allocator, opts: FolderDialogOptions) anyerror!?[]u8 {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, alloc, .{ .pick_folder = opts });
        return switch (r) {
            .path => |p| p,
            else => error.DialogNotAvailable,
        };
    }

    /// 多选文件（模态）。取消返回 null；路径按选择顺序排列。
    pub fn pickFiles(self: Context, alloc: std.mem.Allocator, opts: FileDialogOptions) anyerror!?[][]u8 {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, alloc, .{ .pick_files = opts });
        return switch (r) {
            .paths => |ps| ps,
            else => error.DialogNotAvailable,
        };
    }

    /// 颜色选择（模态）。返回 0xRRGGBB；取消返回 null。
    pub fn pickColor(self: Context, opts: ColorDialogOptions) anyerror!?u32 {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, self.allocator, .{ .pick_color = opts });
        return switch (r) {
            .color => |c| c,
            else => error.DialogNotAvailable,
        };
    }

    /// 字体选择（模态）。取消返回 null（字符串用传入的 allocator 分配）。
    pub fn pickFont(self: Context, alloc: std.mem.Allocator, opts: FontDialogOptions) anyerror!?FontChoice {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, alloc, .{ .pick_font = opts });
        return switch (r) {
            .font => |f| f,
            else => error.DialogNotAvailable,
        };
    }

    /// 重启以应用已暂存的更新（stageUpdate 后调用；接力进程负责拉起新版本）。
    pub fn restartToApply(self: Context) void {
        if (self.restart_fn) |f| {
            f(self.backend);
        } else {
            std.log.warn("[zilt] restartToApply ignored (restart_fn not wired)", .{});
        }
    }

    // ---- 窗口控制（v0.1.6）----

    fn winCmd(self: Context, cmd: WindowCmd) bool {
        const f = self.window_fn orelse return false;
        return f(self.backend, self.window_id, cmd);
    }

    pub fn windowSetTitle(self: Context, title: []const u8) void {
        _ = self.winCmd(.{ .set_title = title });
    }
    pub fn windowMinimize(self: Context) void {
        _ = self.winCmd(.minimize);
    }
    pub fn windowMaximize(self: Context) void {
        _ = self.winCmd(.maximize);
    }
    pub fn windowRestore(self: Context) void {
        _ = self.winCmd(.restore);
    }
    pub fn windowSetFullscreen(self: Context, on: bool) void {
        _ = self.winCmd(.{ .fullscreen = on });
    }
    pub fn windowSetSize(self: Context, width: u32, height: u32) void {
        _ = self.winCmd(.{ .size = .{ .width = width, .height = height } });
    }
    pub fn windowSetPosition(self: Context, x: i32, y: i32) void {
        _ = self.winCmd(.{ .position = .{ .x = x, .y = y } });
    }
    pub fn windowShow(self: Context) void {
        _ = self.winCmd(.show);
    }
    pub fn windowHide(self: Context) void {
        _ = self.winCmd(.hide);
    }
    pub fn windowFocus(self: Context) void {
        _ = self.winCmd(.focus);
    }
    pub fn windowClose(self: Context) void {
        _ = self.winCmd(.close);
    }
    /// 拖动当前窗口（自定义标题栏用；阻塞到拖动结束）。
    pub fn windowStartDragging(self: Context) void {
        _ = self.winCmd(.start_dragging);
    }
    pub fn windowSetAlwaysOnTop(self: Context, on: bool) void {
        _ = self.winCmd(.{ .always_on_top = on });
    }
    pub fn windowSetSkipTaskbar(self: Context, skip: bool) void {
        _ = self.winCmd(.{ .skip_taskbar = skip });
    }

    /// 新建窗口（title/width/height/url）。失败返回 error.WindowCreateFailed。
    pub fn newWindow(self: Context, opts: WindowOptions) !u32 {
        const f = self.spawn_window_fn orelse return error.WindowCreateFailed;
        return f(self.backend, opts) orelse error.WindowCreateFailed;
    }

    // ---- 剪贴板（v0.1.6；文本）----

    pub fn clipboardWriteText(self: Context, text: []const u8) !void {
        const f = self.clipboard_write_fn orelse return error.ClipboardNotAvailable;
        if (!f(self.backend, text)) return error.ClipboardWriteFailed;
    }

    /// 读剪贴板文本（调用方 allocator 分配）。无文本/不支持返回 null。
    pub fn clipboardReadText(self: Context, alloc: std.mem.Allocator) !?[]u8 {
        const f = self.clipboard_read_fn orelse return error.ClipboardNotAvailable;
        return f(self.backend, alloc);
    }

    /// 向前端发事件（payload 序列化为 JSON）。发往当前窗口。
    /// 注意：全程使用 msg_allocator——emit 可能发生在本次调用的 arena 销毁之后
    /// （如后台线程继续 emit）。
    pub fn emit(self: Context, name: []const u8, payload: anytype) void {
        self.emitTo(self.window_id, name, payload);
    }

    /// 向前端发事件（无 payload，当前窗口）。
    pub fn emitNull(self: Context, name: []const u8) void {
        self.emitToNull(self.window_id, name);
    }

    /// 向指定窗口发事件（window_id 0 = 主窗口）。
    pub fn emitTo(self: Context, window_id: u32, name: []const u8, payload: anytype) void {
        const payload_json = std.json.Stringify.valueAlloc(self.msg_allocator, payload, .{}) catch return;
        defer self.msg_allocator.free(payload_json);
        self.emitJsonTo(window_id, name, payload_json);
    }

    pub fn emitToNull(self: Context, window_id: u32, name: []const u8) void {
        self.emitJsonTo(window_id, name, "null");
    }

    pub fn emitJsonTo(self: Context, window_id: u32, name: []const u8, payload_json: []const u8) void {
        const msg = encodeEvent(self.msg_allocator, name, payload_json) catch return;
        self.emit_fn(self.backend, window_id, msg); // 所有权转移给后端（UI 线程用完用 msg_allocator 释放）
    }

    /// v0.1.19：流式通道——推送一段数据（data_json 必须是已序列化的 JSON 值）。
    /// 语义对齐 Tauri `Channel`：同一 id 内按 seq 有序，结束时 close（可带 error）。
    /// 传输仍走事件管道（窗口投递），**没有背压**——调用方需自行控制速率。
    pub fn channelSendJson(self: Context, id: u32, seq: u32, data_json: []const u8) void {
        const payload = std.fmt.allocPrint(self.msg_allocator, "{{\"id\":{d},\"seq\":{d},\"done\":false,\"data\":{s}}}", .{ id, seq, data_json }) catch return;
        defer self.msg_allocator.free(payload);
        self.emitJsonTo(self.window_id, "__zilt.channel", payload);
    }

    pub fn channelSend(self: Context, id: u32, seq: u32, data: anytype) void {
        const json = std.json.Stringify.valueAlloc(self.msg_allocator, data, .{}) catch return;
        defer self.msg_allocator.free(json);
        self.channelSendJson(id, seq, json);
    }

    pub fn channelSendText(self: Context, id: u32, seq: u32, text: []const u8) void {
        const json = std.json.Stringify.valueAlloc(self.msg_allocator, text, .{}) catch return;
        defer self.msg_allocator.free(json);
        self.channelSendJson(id, seq, json);
    }

    pub fn channelClose(self: Context, id: u32, err: ?[]const u8) void {
        const err_json = if (err) |e|
            (std.json.Stringify.valueAlloc(self.msg_allocator, e, .{}) catch return)
        else
            (self.msg_allocator.dupe(u8, "null") catch return);
        defer self.msg_allocator.free(err_json);
        const payload = std.fmt.allocPrint(self.msg_allocator, "{{\"id\":{d},\"done\":true,\"err\":{s}}}", .{ id, err_json }) catch return;
        defer self.msg_allocator.free(payload);
        self.emitJsonTo(self.window_id, "__zilt.channel", payload);
    }

    /// 请求退出应用（在 UI 线程的命令/事件回调内调用）。
    pub fn quit(self: Context, code: u8) void {
        self.quit_fn(self.backend, code);
    }
};

// ---------------------------------------------------------------------------
// 编码（Zig → JS）
// ---------------------------------------------------------------------------

/// JSON 字符串字面量转义（覆盖 " \ 与控制字符；输入按 UTF-8 原样透传）。
fn jsonEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.print(alloc, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(alloc, c);
                }
            },
        }
    }
    try buf.append(alloc, '"');
    return buf.toOwnedSlice(alloc);
}

pub fn encodeResolve(alloc: std.mem.Allocator, id: u64, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"zilt\":1,\"kind\":\"resolve\",\"id\":{d},\"result\":{s}}}", .{ id, result_json });
}

pub fn encodeReject(alloc: std.mem.Allocator, id: u64, error_name: []const u8) ![]u8 {
    const name_json = try jsonEscape(alloc, error_name);
    defer alloc.free(name_json);
    return std.fmt.allocPrint(alloc, "{{\"zilt\":1,\"kind\":\"reject\",\"id\":{d},\"error\":{s}}}", .{ id, name_json });
}

pub fn encodeEvent(alloc: std.mem.Allocator, name: []const u8, payload_json: []const u8) ![]u8 {
    const name_json = try jsonEscape(alloc, name);
    defer alloc.free(name_json);
    return std.fmt.allocPrint(alloc, "{{\"zilt\":1,\"kind\":\"event\",\"name\":{s},\"payload\":{s}}}", .{ name_json, payload_json });
}

// ---------------------------------------------------------------------------
// 解码（JS → Zig）
// ---------------------------------------------------------------------------

pub const Message = union(enum) {
    invoke: struct { id: u64, method: []const u8, args_json: []const u8 },
    event: struct { name: []const u8, payload_json: []const u8 },
    ignore,
};

/// 解码结果。字段字符串指向内部 arena，须在 deinit 前用完。
pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    msg: Message,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
    }
};

pub fn decode(gpa: std.mem.Allocator, raw: []const u8) !Decoded {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return .{ .arena = arena, .msg = .ignore };
    if (v != .object) return .{ .arena = arena, .msg = .ignore };
    const obj = v.object;

    const tag = obj.get("zilt") orelse return .{ .arena = arena, .msg = .ignore };
    if (tag != .integer or tag.integer != 1) return .{ .arena = arena, .msg = .ignore };

    const kind = obj.get("kind") orelse return .{ .arena = arena, .msg = .ignore };
    if (kind != .string) return .{ .arena = arena, .msg = .ignore };

    if (std.mem.eql(u8, kind.string, "invoke")) {
        const id_v = obj.get("id") orelse return .{ .arena = arena, .msg = .ignore };
        if (id_v != .integer or id_v.integer < 0) return .{ .arena = arena, .msg = .ignore };
        const method_v = obj.get("method") orelse return .{ .arena = arena, .msg = .ignore };
        if (method_v != .string) return .{ .arena = arena, .msg = .ignore };
        const args_v = obj.get("args") orelse std.json.Value{ .null = {} };
        const args_json = std.json.Stringify.valueAlloc(a, args_v, .{}) catch return .{ .arena = arena, .msg = .ignore };
        return .{ .arena = arena, .msg = .{ .invoke = .{
            .id = @intCast(id_v.integer),
            .method = method_v.string,
            .args_json = args_json,
        } } };
    }

    if (std.mem.eql(u8, kind.string, "event")) {
        const name_v = obj.get("name") orelse return .{ .arena = arena, .msg = .ignore };
        if (name_v != .string) return .{ .arena = arena, .msg = .ignore };
        const payload_v = obj.get("payload") orelse std.json.Value{ .null = {} };
        const payload_json = std.json.Stringify.valueAlloc(a, payload_v, .{}) catch return .{ .arena = arena, .msg = .ignore };
        return .{ .arena = arena, .msg = .{ .event = .{ .name = name_v.string, .payload_json = payload_json } } };
    }

    return .{ .arena = arena, .msg = .ignore };
}

// ---------------------------------------------------------------------------
// comptime 命令表
// ---------------------------------------------------------------------------

pub const ContextType = Context;

/// 命令元数据（codegen 与运行时分发共用）。
pub const Meta = struct {
    name: []const u8,
    args: ?type, // null = 无参数
    result: type, // void 表示无返回
};

fn fnMeta(comptime f: anytype) Meta {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const has_args = info.param_types.len == 2;
    return .{
        .name = "", // 由调用方填
        .args = if (has_args) info.param_types[1].? else null,
        .result = info.return_type.?,
    };
}

/// 命令命名空间里是否为可分发命令：普通 fn（带 ctx 参数）而非泛型函数。
/// 泛型 fn（含 comptime 参数）视为应用侧辅助类型函数（如信封构造器），
/// 不暴露为命令——避免 dispatch/绑定代码生成把它们当命令展开。
fn isCommandFn(comptime f: anytype) bool {
    const info = @typeInfo(@TypeOf(f));
    if (info != .@"fn") return false;
    // Zig 0.17：泛型函数（含 anytype/comptime 参数）由 is_generic 标记
    if (info.@"fn".is_generic) return false;
    return true;
}

/// 提取命令命名空间的全部元数据（跳过非函数 decl 与泛型函数）。
pub fn commandMetas(comptime Commands: type) []const Meta {
    const decl_names = @typeInfo(Commands).@"struct".decl_names;
    var count: usize = 0;
    for (decl_names) |name| {
        if (comptime isCommandFn(@field(Commands, name))) count += 1;
    }
    var metas: [count]Meta = undefined;
    var i: usize = 0;
    for (decl_names) |name| {
        const f = @field(Commands, name);
        if (comptime !isCommandFn(f)) continue;
        var m = fnMeta(f);
        m.name = name;
        // 剥掉 error union：result 存 payload 类型
        const r = m.result;
        m.result = switch (@typeInfo(r)) {
            .error_union => |eu| eu.payload,
            else => r,
        };
        metas[i] = m;
        i += 1;
    }
    const frozen = metas;
    return &frozen;
}

fn makeHandler(comptime f: anytype) *const fn (Context, []const u8) anyerror![]u8 {
    const Impl = struct {
        fn run(ctx: Context, args_json: []const u8) anyerror![]u8 {
            const info = @typeInfo(@TypeOf(f)).@"fn";
            const has_args = info.param_types.len == 2;
            const R = info.return_type.?;
            const result_t = switch (@typeInfo(R)) {
                .error_union => |eu| eu.payload,
                else => R,
            };
            const is_err_union = @typeInfo(R) == .error_union;

            if (comptime !has_args) {
                if (comptime is_err_union) {
                    const r = try f(ctx);
                    return serializeResult(ctx, result_t, r);
                } else {
                    const r = f(ctx);
                    return serializeResult(ctx, result_t, r);
                }
            }
            const ArgsT = info.param_types[1].?;
            if (comptime ArgsT == void) {
                if (comptime is_err_union) {
                    const r = try f(ctx, {});
                    return serializeResult(ctx, result_t, r);
                } else {
                    const r = f(ctx, {});
                    return serializeResult(ctx, result_t, r);
                }
            }
            var parsed = try std.json.parseFromSlice(ArgsT, ctx.allocator, args_json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (comptime is_err_union) {
                const r = try f(ctx, parsed.value);
                return serializeResult(ctx, result_t, r);
            } else {
                const r = f(ctx, parsed.value);
                return serializeResult(ctx, result_t, r);
            }
        }

        fn serializeResult(ctx: Context, comptime RT: type, result: RT) ![]u8 {
            if (RT == void) return ctx.allocator.dupe(u8, "null");
            return std.json.Stringify.valueAlloc(ctx.allocator, result, .{});
        }
    };
    return &Impl.run;
}

/// 按方法名分发命令。未知命令返回 error.UnknownCommand。
pub fn dispatch(comptime Commands: type, ctx: Context, method: []const u8, args_json: []const u8) anyerror![]u8 {
    inline for (@typeInfo(Commands).@"struct".decl_names) |name| {
        const f = @field(Commands, name);
        if (comptime isCommandFn(f)) {
            if (std.mem.eql(u8, name, method)) return makeHandler(f)(ctx, args_json);
        }
    }
    return error.UnknownCommand;
}

fn makeEventHandler(comptime f: anytype) *const fn (Context, []const u8) anyerror!void {
    const Impl = struct {
        fn run(ctx: Context, payload_json: []const u8) anyerror!void {
            const info = @typeInfo(@TypeOf(f)).@"fn";
            const has_payload = info.param_types.len == 2;
            const R = info.return_type.?;
            const is_err_union = @typeInfo(R) == .error_union;

            if (comptime !has_payload) {
                if (comptime is_err_union) try f(ctx) else f(ctx);
                return;
            }
            const PT = info.param_types[1].?;
            if (comptime PT == void) {
                if (comptime is_err_union) try f(ctx, {}) else f(ctx, {});
                return;
            }
            var parsed = try std.json.parseFromSlice(PT, ctx.allocator, payload_json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (comptime is_err_union) try f(ctx, parsed.value) else f(ctx, parsed.value);
        }
    };
    return &Impl.run;
}

/// 按事件名分发 JS→Zig 事件；返回是否命中了处理器。
pub fn dispatchEvent(comptime Events: type, ctx: Context, name: []const u8, payload_json: []const u8) bool {
    inline for (@typeInfo(Events).@"struct".decl_names) |ename| {
        const f = @field(Events, ename);
        if (@typeInfo(@TypeOf(f)) == .@"fn" and std.mem.eql(u8, ename, name)) {
            makeEventHandler(f)(ctx, payload_json) catch |err| {
                std.log.warn("[zilt] event '{s}' handler failed: {s}", .{ name, @errorName(err) });
            };
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// 注入到页面的运行时（window.zilt）——命令无关，纯静态
// ---------------------------------------------------------------------------

const runtime_version = @import("version.zig").version;

/// 头/尾拆开只为把版本号拼进来——版本号只在 `version.zig` 维护，避免升版本漏改。
const runtime_js_head =
    \\(() => {
    \\  const resolvers = new Map();
    \\  const listeners = new Map();
    \\  let nextId = 1;
    \\  let httpSeq = 0;
    \\  let wsSeq = 0;
    \\  let webviewEvalSeq = 0;
    \\  let channelSeq = 0;
    \\  let cdpSeq = 0;
    \\  const webviewEvalWaiters = new Map();
    \\  const cdpWaiters = new Map();
    \\  // SQL 参数编码：原生值 → Zig 侧 {kind:'text'|'int'|'real'|'nul', ...}
    \\  const ziltSqlParam = (v) => {
    \\    if (v === null || v === undefined) return { kind: 'nul' };
    \\    if (typeof v === 'number') return Number.isInteger(v) ? { kind: 'int', int: v } : { kind: 'real', real: v };
    \\    if (typeof v === 'string') return { kind: 'text', text: v };
    \\    if (typeof v === 'boolean') return { kind: 'int', int: v ? 1 : 0 };
    \\    if (v instanceof Date) return { kind: 'text', text: v.toISOString() };
    \\    return v;
    \\  };
    \\  const post = (m) => window.chrome.webview.postMessage(m);
    \\  window.chrome.webview.addEventListener('message', (e) => {
    \\    const m = e.data;
    \\    if (!m || m.zilt !== 1) return;
    \\    if (m.kind === 'resolve') {
    \\      const r = resolvers.get(m.id);
    \\      if (r) { resolvers.delete(m.id); r.resolve(m.result); }
    \\    } else if (m.kind === 'reject') {
    \\      const r = resolvers.get(m.id);
    \\      if (r) { resolvers.delete(m.id); r.reject(new Error(m.error)); }
    \\    } else if (m.kind === 'event') {
    \\      const ls = listeners.get(m.name);
    \\      if (ls) for (const cb of ls) { try { cb(m.payload); } catch (err) { console.error('[zilt] listener error', err); } }
    \\    }
    \\  });
    \\  const evalWaiters = new Map();
    \\  let evalId = 1;
    \\  const builtin = (method, args) => window.zilt.invoke(method, args ?? {});
    \\  const winApi = (action, extra) => builtin('__zilt.window', Object.assign({ action }, extra ?? {}));
    \\  window.zilt = {
    \\    invoke: (method, args) => new Promise((resolve, reject) => {
    \\      const id = nextId++;
    \\      resolvers.set(id, { resolve, reject });
    \\      post({ zilt: 1, kind: 'invoke', id, method, args: args ?? {} });
    \\    }),
    \\    emit: (name, payload) => post({ zilt: 1, kind: 'event', name, payload: payload ?? null }),
    \\    on: (name, cb) => {
    \\      const ls = listeners.get(name) ?? [];
    \\      ls.push(cb);
    \\      listeners.set(name, ls);
    \\      // 返回取消函数：一次性请求（如 http）必须能摘掉自己的监听，否则会累积
    \\      return () => {
    \\        const cur = listeners.get(name);
    \\        if (!cur) return;
    \\        const i = cur.indexOf(cb);
    \\        if (i >= 0) cur.splice(i, 1);
    \\      };
    \\    },
    \\    startDragging: () => builtin('__zilt.startDragging', {}),
    \\    // v0.1.11: window.zilt.window
    \\    window: {
    \\      create: (opts) => winApi('create', opts),
    \\      close: (id) => winApi('close', { window_id: id }),
    \\      show: (id) => winApi('show', { window_id: id }),
    \\      hide: (id) => winApi('hide', { window_id: id }),
    \\      minimize: (id) => winApi('minimize', { window_id: id }),
    \\      maximize: (id) => winApi('maximize', { window_id: id }),
    \\      restore: (id) => winApi('restore', { window_id: id }),
    \\      fullscreen: (enabled, id) => winApi('fullscreen', { enabled, window_id: id }),
    \\      setSize: (width, height, id) => winApi('setSize', { width, height, window_id: id }),
    \\      setPosition: (x, y, id) => winApi('setPosition', { x, y, window_id: id }),
    \\      setTitle: (title, id) => winApi('setTitle', { title, window_id: id }),
    \\      alwaysOnTop: (enabled, id) => winApi('alwaysOnTop', { enabled, window_id: id }),
    \\      skipTaskbar: (enabled, id) => winApi('skipTaskbar', { enabled, window_id: id }),
    \\      focus: (id) => winApi('focus', { window_id: id }),
    \\      startDragging: (id) => winApi('startDragging', { window_id: id }),
    \\      // v0.1.18：精细控制（对齐 Tauri set_cursor_* / set_content_protected 等）
    \\      setCursor: (kind, id) => winApi('setCursor', { cursor: kind ?? 'default', window_id: id }),
    \\      setCursorVisible: (visible, id) => winApi('setCursorVisible', { visible: visible !== false, window_id: id }),
    \\      setCursorGrab: (grab, id) => winApi('setCursorGrab', { grab: grab !== false, window_id: id }),
    \\      setCursorPosition: (x, y, id) => winApi('setCursorPosition', { x, y, window_id: id }),
    \\      setIgnoreCursorEvents: (ignore, id) => winApi('setIgnoreCursorEvents', { ignore: ignore !== false, window_id: id }),
    \\      setContentProtected: (on, id) => winApi('setContentProtected', { enabled: on !== false, window_id: id }),
    \\      setShadow: (on, id) => winApi('setShadow', { enabled: on !== false, window_id: id }),
    \\      setAlwaysOnBottom: (on, id) => winApi('setAlwaysOnBottom', { enabled: on !== false, window_id: id }),
    \\      setFocusable: (on, id) => winApi('setFocusable', { enabled: on !== false, window_id: id }),
    \\      setEnabled: (on, id) => winApi('setEnabled', { enabled: on !== false, window_id: id }),
    \\      setTheme: (opts, id) => winApi('setTheme', {
    \\        dark: opts?.dark, caption_color: opts?.captionColor,
    \\        text_color: opts?.textColor, border_color: opts?.borderColor, window_id: id,
    \\      }),
    \\      setMinMax: (opts, id) => winApi('setMinMax', {
    \\        min_width: opts?.minWidth, min_height: opts?.minHeight,
    \\        max_width: opts?.maxWidth, max_height: opts?.maxHeight, window_id: id,
    \\      }),
    \\      fullscreenOnMonitor: (index, id) => winApi('fullscreenOnMonitor', { monitor: index ?? 0, window_id: id }),
    \\      setIcon: (path, id) => winApi('setIcon', { icon: path ?? null, window_id: id }),
    \\      state: (id) => winApi('state', { window_id: id }),
    \\    },
    \\    // v0.1.9: eval returns a Promise resolved by __zilt.evalResult
    \\    eval: (script) => new Promise((resolve, reject) => {
    \\      const id = evalId++;
    \\      evalWaiters.set(id, { resolve, reject });
    \\      builtin('__zilt.eval', { script, id }).catch((err) => {
    \\        evalWaiters.delete(id);
    \\        reject(err);
    \\      });
    \\    }),
    \\    // v0.1.10: runtime WebView API
    \\    webview: {
    \\      reload: () => builtin('__zilt.webview', { action: 'reload' }),
    \\      stop: () => builtin('__zilt.webview', { action: 'stop' }),
    \\      zoom: (factor) => builtin('__zilt.webview', { action: 'zoom', zoom: factor }),
    \\      getZoom: () => builtin('__zilt.webview', { action: 'getZoom' }),
    \\      history: () => builtin('__zilt.webview', { action: 'history' }),
    \\      back: () => builtin('__zilt.webview', { action: 'back' }),
    \\      forward: () => builtin('__zilt.webview', { action: 'forward' }),
    \\      devtools: () => builtin('__zilt.webview', { action: 'devtools' }),
    \\      print: (kind) => builtin('__zilt.webview', { action: 'print', kind: kind ?? 'browser' }),
    \\      cancelDownload: (id) => builtin('__zilt.webview', { action: 'cancelDownload', download_id: id }),
    \\      clearStorage: () => builtin('__zilt.webview', { action: 'clearStorage' }),
    \\      getCookies: (url) => builtin('__zilt.webview', { action: 'cookies.get', url }),
    \\      clearCookies: (origin) => builtin('__zilt.webview', { action: 'cookies.clear', url: origin }),
    \\      // v0.1.23: 任意 CDP 调用（Promise）。逃生口：截图/请求头之外的协议能力
    \\      // 都不必再等框架加 API。
    \\      cdp: (method, params) => new Promise((resolve, reject) => {
    \\        const rid = ++cdpSeq;
    \\        cdpWaiters.set(rid, { resolve, reject });
    \\        builtin('__zilt.webview', { action: 'cdp', method, rid, params_json: JSON.stringify(params ?? {}) })
    \\          .catch((e) => { cdpWaiters.delete(rid); reject(e); });
    \\      }),
    \\      // 截屏：返回 data URL（可直接给 <img src>），format 支持 png/jpeg/webp
    \\      captureScreenshot: async (opts) => {
    \\        const o = opts ?? {};
    \\        const params = { format: o.format ?? 'png' };
    \\        if (o.quality != null) params.quality = o.quality;
    \\        if (o.fromSurface != null) params.fromSurface = !!o.fromSurface;
    \\        const r = await window.zilt.webview.cdp('Page.captureScreenshot', params);
    \\        return r && r.data ? 'data:image/' + (o.format ?? 'png') + ';base64,' + r.data : '';
    \\      },
    \\      // 给页面的所有 HTTP 请求附加请求头（CDP Network.setExtraHTTPHeaders）
    \\      setExtraHeaders: async (headers) => {
    \\        await window.zilt.webview.cdp('Network.enable', {});
    \\        await window.zilt.webview.cdp('Network.setExtraHTTPHeaders', { headers: headers ?? {} });
    \\        return true;
    \\      },
    \\      // 页内查找。Chromium 没有公开的「匹配计数」API，这里用 window.find 做定位
    \\      // （与 Ctrl+F 的导航语义一致，但不产生高亮，需要高亮请自行高亮选区）。
    \\      find: (text, opts) => {
    \\        const o = opts ?? {};
    \\        const s = String(text ?? '');
    \\        if (!s) return false;
    \\        try {
    \\          return window.find(s, !!o.matchCase, !!o.backwards, o.wrap !== false, false, false, false);
    \\        } catch (e) { return false; }
    \\      },
    \\    },
    \\    // v0.1.12: clipboard / drag / notifications
    \\    clipboard: {
    \\      read: (format) => builtin('__zilt.clipboard', { action: 'read', format: format ?? 'text' }),
    \\      writeText: (text) => builtin('__zilt.clipboard', { action: 'write', format: 'text', text }),
    \\      writeHtml: (html) => builtin('__zilt.clipboard', { action: 'write', format: 'html', html }),
    \\      writeFiles: (files) => builtin('__zilt.clipboard', { action: 'write', format: 'files', files }),
    \\    },
    \\    drag: { start: (files) => builtin('__zilt.drag', { action: 'start', files }) },
    \\    notification: {
    \\      show: (opts) => builtin('__zilt.notification', Object.assign({ action: 'show' }, opts ?? {})),
    \\      update: (opts) => builtin('__zilt.notification', Object.assign({ action: 'update' }, opts ?? {})),
    \\      status: () => builtin('__zilt.notification', { action: 'status' }),
    \\    },
    \\    // v0.1.13: tray / menu / hotkey / taskbar
    \\    menu: {
    \\      list: () => builtin('__zilt.menu', { action: 'list' }),
    \\      add: (opts) => builtin('__zilt.menu', Object.assign({ action: 'add' }, opts ?? {})),
    \\      remove: (path) => builtin('__zilt.menu', { action: 'remove', path }),
    \\      set: (path, opts) => builtin('__zilt.menu', Object.assign({ action: 'set', path }, opts ?? {})),
    \\      popup: (x, y) => builtin('__zilt.menu', { action: 'popup', x: x ?? 0, y: y ?? 0 }),
    \\    },
    \\    tray: {
    \\      setTooltip: (tooltip) => builtin('__zilt.tray', { action: 'setTooltip', tooltip }),
    \\      setIcon: (icon) => builtin('__zilt.tray', { action: 'setIcon', icon }),
    \\      setClick: (opts) => builtin('__zilt.tray', Object.assign({ action: 'setClick' }, opts ?? {})),
    \\    },
    \\    hotkey: {
    \\      register: (id, accel) => builtin('__zilt.hotkey', { action: 'register', path: id, accel }),
    \\      unregister: (id) => builtin('__zilt.hotkey', { action: 'unregister', path: id }),
    \\      list: () => builtin('__zilt.hotkey', { action: 'list' }),
    \\    },
    \\    taskbar: {
    \\      progress: (value, state) => builtin('__zilt.taskbar', { action: 'progress', progress: value, kind: state ?? 'normal' }),
    \\      clearProgress: () => builtin('__zilt.taskbar', { action: 'progress', kind: 'none' }),
    \\      overlay: (icon, description) => builtin('__zilt.taskbar', { action: 'overlay', icon, text: description }),
    \\      clearOverlay: () => builtin('__zilt.taskbar', { action: 'overlay' }),
    \\      tooltip: (text) => builtin('__zilt.taskbar', { action: 'tooltip', text }),
    \\      flash: (count) => builtin('__zilt.taskbar', { action: 'flash', count: count ?? 3 }),
    \\    },
    \\    // v0.1.14: system info / shell / autostart / appearance
    \\    system: {
    \\      info: (kind) => builtin('__zilt.system', { action: 'info', kind: kind ?? 'all' }),
    \\      os: () => builtin('__zilt.system', { action: 'info', kind: 'os' }),
    \\      monitors: () => builtin('__zilt.system', { action: 'info', kind: 'monitors' }),
    \\      adminRestart: (args) => builtin('__zilt.system', { action: 'adminRestart', exe_args: args }),
    \\    },
    \\    shell: {
    \\      openUrl: (url) => builtin('__zilt.shell', { action: 'openUrl', url }),
    \\      openPath: (path) => builtin('__zilt.shell', { action: 'openPath', path }),
    \\      reveal: (path) => builtin('__zilt.shell', { action: 'reveal', path }),
    \\    },
    \\    autostart: {
    \\      query: () => builtin('__zilt.autostart', { action: 'query' }),
    \\      enable: (args) => builtin('__zilt.autostart', { action: 'enable', exe_args: args }),
    \\      disable: () => builtin('__zilt.autostart', { action: 'disable' }),
    \\      toggle: () => builtin('__zilt.autostart', { action: 'toggle' }),
    \\    },
    \\    appearance: {
    \\      apply: (opts) => builtin('__zilt.appearance', Object.assign({ action: 'apply' }, opts ?? {})),
    \\    },
    \\    // v0.1.16: KV store / scoped fs
    \\    store: {
    \\      get: (key) => builtin('__zilt.store', { action: 'get', key }),
    \\      set: (key, value) => builtin('__zilt.store', { action: 'set', key, value: String(value) }),
    \\      remove: (key) => builtin('__zilt.store', { action: 'remove', key }),
    \\      keys: () => builtin('__zilt.store', { action: 'keys' }),
    \\      all: () => builtin('__zilt.store', { action: 'all' }),
    \\    },
    \\    // v0.1.21：运行时授权（持久化到 <appData>\acl.json，重启后仍生效）。
    \\    // kind = fs / shell / http；pattern 形如 "documents/**"、"git"、"https://api.x/*"。
    \\    acl: {
    \\      list: () => builtin('__zilt.acl', { action: 'list' }),
    \\      grant: (kind, pattern) => builtin('__zilt.acl', { action: 'grant', acl_kind: kind, pattern }),
    \\      revoke: (kind, pattern) => builtin('__zilt.acl', { action: 'revoke', acl_kind: kind, pattern }),
    \\    },
    \\    // v0.1.19：更新器（info = 当前配置/是否需要重启；check = 立即检查）
    \\    updater: {
    \\      info: () => builtin('__zilt.updater', { action: 'info' }),
    \\      check: () => builtin('__zilt.updater', { action: 'check' }),
    \\    },
    \\    // v0.1.19：流式通道（对齐 Tauri Channel 的最小语义）。Zig 侧用
    \\    // ctx.channelSend(id, seq, data) / ctx.channelClose(id, err) 推送。
    \\    channel: {
    \\      create: (opts) => {
    \\        const o = opts ?? {};
    \\        const id = ++channelSeq;
    \\        const off = window.zilt.on('__zilt.channel', (p) => {
    \\          if (!p || p.id !== id) return;
    \\          if (p.done) {
    \\            off();
    \\            if (typeof o.onclose === 'function') o.onclose(p.err == null ? null : p.err);
    \\          } else if (typeof o.onmessage === 'function') {
    \\            o.onmessage(p.data, p.seq);
    \\          }
    \\        });
    \\        return { id: id, close: () => off() };
    \\      },
    \\    },
    \\    // v0.1.19：fs 全量。scope = appData（默认）/appConfig/appCache/home/desktop/
    \\    // documents/downloads/pictures/videos/temp/exe；非私有目录需 capability 的
    \\    // `scopes` 声明（如 "fs:documents/**"）。
    \\    fs: {
    \\      read: (path, scope) => builtin('__zilt.fs', { action: 'read', path, scope }),
    \\      write: (path, data, scope) => builtin('__zilt.fs', { action: 'write', path, data, scope }),
    \\      append: (path, data, scope) => builtin('__zilt.fs', { action: 'append', path, data, scope }),
    \\      exists: (path, scope) => builtin('__zilt.fs', { action: 'exists', path, scope }),
    \\      remove: (path, scope) => builtin('__zilt.fs', { action: 'remove', path, scope }),
    \\      mkdir: (path, scope) => builtin('__zilt.fs', { action: 'mkdir', path, scope }),
    \\      removeDir: (path, scope) => builtin('__zilt.fs', { action: 'removeDir', path, scope }),
    \\      readDir: (path, scope) => builtin('__zilt.fs', { action: 'readDir', path, scope }),
    \\      stat: (path, scope) => builtin('__zilt.fs', { action: 'stat', path, scope }),
    \\      rename: (from, to, scope) => builtin('__zilt.fs', { action: 'rename', path: from, to, scope }),
    \\      copy: (from, to, scope) => builtin('__zilt.fs', { action: 'copy', path: from, to, scope }),
    \\      roots: () => builtin('__zilt.fs', { action: 'roots' }),
    \\      // v0.1.22：目录监视（fsEvent）与大文件流式读（fsChunk，base64）
    \\      watch: (path, opts) => builtin('__zilt.fs', {
    \\        action: 'watch', path: path ?? '',
    \\        scope: opts?.scope, recursive: opts?.recursive !== false,
    \\      }),
    \\      unwatch: (id) => builtin('__zilt.fs', { action: 'unwatch', id }),
    \\      readStream: (path, opts) => builtin('__zilt.fs', {
    \\        action: 'readStream', path, scope: opts?.scope, chunk_size: opts?.chunkSize,
    \\      }),
    \\    },
    \\    // v0.1.16: path / log / opener / windowState
    \\    path: {
    \\      join: function () { return builtin('__zilt.path', { action: 'join', items: Array.prototype.slice.call(arguments) }); },
    \\      dirname: (path) => builtin('__zilt.path', { action: 'dirname', path }),
    \\      basename: (path) => builtin('__zilt.path', { action: 'basename', path }),
    \\      extname: (path) => builtin('__zilt.path', { action: 'extname', path }),
    \\      normalize: (path) => builtin('__zilt.path', { action: 'normalize', path }),
    \\    },
    \\    log: (level, message) => builtin('__zilt.log', { level: level ?? 'info', message }),
    \\    opener: {
    \\      openUrl: (url) => builtin('__zilt.shell', { action: 'openUrl', url }),
    \\      openPath: (path) => builtin('__zilt.shell', { action: 'openPath', path }),
    \\      reveal: (path) => builtin('__zilt.shell', { action: 'reveal', path }),
    \\    },
    \\    windowState: {
    \\      get: () => builtin('__zilt.windowState', { action: 'get' }),
    \\      save: () => builtin('__zilt.windowState', { action: 'save' }),
    \\    },
    \\    // v0.1.16: 应用服务（只查询状态 + 触发 start/stop；方法调用请用 commands）
    \\    services: {
    \\      list: () => builtin('__zilt.services', { action: 'list' }),
    \\      status: (name) => builtin('__zilt.services', { action: 'status', name }),
    \\      start: (name) => builtin('__zilt.services', { action: 'start', name }),
    \\      stop: (name) => builtin('__zilt.services', { action: 'stop', name }),
    \\    },
    \\    // v0.1.16: HTTP。异步实现 —— 立即返回、后台线程执行、完成走 httpResponse 事件，
    \\    // 所以这里用 Promise 包一层，调用方直接 await，UI 线程不会被阻塞。
    \\    http: {
    \\      request: (opts) => {
    \\        const o = opts ?? {};
    \\        const id = ++httpSeq;
    \\        return new Promise((resolve, reject) => {
    \\          const off = window.zilt.on('httpResponse', (p) => {
    \\            if (!p || p.id !== id) return;
    \\            off();
    \\            if (p.err) reject(new Error(p.err));
    \\            else resolve({ status: p.status, body: p.body });
    \\          });
    \\          builtin('__zilt.http', {
    \\            action: 'request', id,
    \\            url: o.url,
    \\            method: o.method ?? 'GET',
    \\            headers: typeof o.headers === 'string' ? o.headers : Object.entries(o.headers ?? {}).map(([k, v]) => k + ': ' + v).join('\\n'),
    \\            body: o.body ?? '',
    \\            timeout_ms: o.timeout_ms ?? 30000,
    \\            proxy: o.proxy,
    \\            insecure_tls: o.insecureTls === true,
    \\            follow_redirects: o.followRedirects !== false,
    \\            parts: (o.multipart ?? []).length > 0 ? (o.multipart ?? []).map((p) => ({ name: p.name, data: p.data ?? '', filename: p.filename, content_type: p.contentType ?? p.content_type })) : null,
    \\          }).catch((e) => { off(); reject(e); });
    \\        });
    \\      },
    \\      // v0.1.20：流式下载（onChunk(bytes, seq) 边到边回调，结束时给完整 Uint8Array）
    \\      stream: (opts, onChunk) => {
    \\        const o = opts ?? {};
    \\        const id = ++httpSeq;
    \\        const chunks = [];
    \\        return new Promise((resolve, reject) => {
    \\          const offChunk = window.zilt.on('httpChunk', (p) => {
    \\            if (!p || p.id !== id) return;
    \\            const bin = atob(p.data);
    \\            const bytes = new Uint8Array(bin.length);
    \\            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    \\            chunks.push(bytes);
    \\            if (typeof onChunk === 'function') onChunk(bytes, p.seq);
    \\          });
    \\          const off = window.zilt.on('httpResponse', (p) => {
    \\            if (!p || p.id !== id) return;
    \\            off(); offChunk();
    \\            if (p.err) { reject(new Error(p.err)); return; }
    \\            const total = chunks.reduce((n, c) => n + c.length, 0);
    \\            const all = new Uint8Array(total);
    \\            let at = 0;
    \\            for (const c of chunks) { all.set(c, at); at += c.length; }
    \\            resolve({ status: p.status, bytes: all, chunks: chunks.length });
    \\          });
    \\          builtin('__zilt.http', {
    \\            action: 'request', id, stream: true,
    \\            url: o.url,
    \\            method: o.method ?? 'GET',
    \\            headers: typeof o.headers === 'string' ? o.headers : Object.entries(o.headers ?? {}).map(([k, v]) => k + ': ' + v).join('\\n'),
    \\            timeout_ms: o.timeout_ms ?? 60000,
    \\            proxy: o.proxy,
    \\            insecure_tls: o.insecureTls === true,
    \\            follow_redirects: o.followRedirects !== false,
    \\          }).catch((e) => { off(); offChunk(); reject(e); });
    \\        });
    \\      },
    \\    },
    \\    // v0.1.16: WebSocket。connect 异步 —— 握手在后台线程执行，立即返回连接 id；
    \\    // open/message/close/error 全走 wsEvent 事件（kind 字段区分）。
    \\    ws: {
    \\      // v0.1.20：wss:// 走 WinHTTP（TLS/代理）；ws:// 仍走自研帧层
    \\      connect: (url, opts) => {
    \\        const id = ++wsSeq;
    \\        const o = opts ?? {};
    \\        return builtin('__zilt.ws', {
    \\          action: 'connect', id, url,
    \\          proxy: o.proxy,
    \\          insecure_tls: o.insecureTls === true,
    \\          headers: typeof o.headers === 'string' ? o.headers : Object.entries(o.headers ?? {}).map(([k, v]) => k + ': ' + v).join('\\n'),
    \\        }).then(() => id);
    \\      },
    \\      send: (id, data) => builtin('__zilt.ws', { action: 'send', id, data: String(data) }),
    \\      close: (id, code, reason) => builtin('__zilt.ws', { action: 'close', id, code: code ?? 1000, reason: reason ?? '' }),
    \\      on: (id, cb) => window.zilt.on('wsEvent', (p) => { if (p && p.id === id) cb(p); }),
    \\    },
    \\    // v0.1.16: 单窗口多 WebView。create 返回 {id}；controller 异步就绪，
    \\    // 早于就绪的 navigate 会排队。子 webview 的 invoke 可用，事件只广播主页面。
    \\    // v0.1.17: create({partition:'login'}) → 独立 Environment + 独立 user data
    \\    // folder（Cookie/localStorage/IndexedDB 与主页面隔离；同名分区复用同一 env）。
    \\    // eval(id, script) 在子 webview 内执行脚本，返回结果（Promise）。
    \\    webviews: {
    \\      create: (opts) => builtin('__zilt.webviews', Object.assign({ action: 'create' }, opts ?? {})),
    \\      remove: (id) => builtin('__zilt.webviews', { action: 'remove', id }),
    \\      navigate: (id, url) => builtin('__zilt.webviews', { action: 'navigate', id, url }),
    \\      setBounds: (id, x, y, width, height) => builtin('__zilt.webviews', { action: 'setBounds', id, x, y, width, height }),
    \\      focus: (id) => builtin('__zilt.webviews', { action: 'focus', id }),
    \\      list: () => builtin('__zilt.webviews', { action: 'list' }),
    \\      // eval 异步：Zig 侧 ExecuteScript 完成后发 webviewEval 事件，这里包成 Promise
    \\      eval: (id, script) => {
    \\        const rid = ++webviewEvalSeq;
    \\        return new Promise((resolve, reject) => {
    \\          webviewEvalWaiters.set(rid, { resolve, reject });
    \\          builtin('__zilt.webviews', { action: 'eval', id, rid, script: String(script) }).catch((e) => {
    \\            webviewEvalWaiters.delete(rid);
    \\            reject(e);
    \\          });
    \\        });
    \\      },
    \\    },
    \\    // v0.1.16: 原生对话框。模态（UI 线程阻塞），行为与 Tauri 一致。
    \\    dialog: {
    \\      messageBox: (opts) => builtin('__zilt.dialog', Object.assign({ action: 'messageBox' }, opts ?? {})),
    \\      openFile: (opts) => builtin('__zilt.dialog', Object.assign({ action: 'openFile' }, opts ?? {})),
    \\      saveFile: (opts) => builtin('__zilt.dialog', Object.assign({ action: 'saveFile' }, opts ?? {})),
    \\      pickFolder: (opts) => builtin('__zilt.dialog', Object.assign({ action: 'pickFolder' }, opts ?? {})),
    \\      pickFiles: (opts) => builtin('__zilt.dialog', Object.assign({ action: 'pickFiles' }, opts ?? {})),
    \\    },
    \\    // v0.1.16: 子进程。spawn({id, argv, cwd}) → stdout/stderr/exit 走 processEvent 事件。
    \\    process: {
    \\      spawn: (opts) => builtin('__zilt.process', Object.assign({ action: 'spawn' }, opts ?? {})),
    \\      kill: (id, exitCode) => builtin('__zilt.process', { action: 'kill', id, code: exitCode ?? 1 }),
    \\      list: () => builtin('__zilt.process', { action: 'list' }),
    \\      on: (id, cb) => window.zilt.on('processEvent', (p) => { if (p && p.id === id) cb(p); }),
    \\    },
    \\    // v0.1.17: SQL（SQLite）。params 直接传原生值：number→int/real、string→text、
    \\    // null→nul；也可显式传 {text}/{int}/{real}/'nul' 标记形态。
    \\    sql: {
    \\      query: (db, sql, params) => builtin('__zilt.sql', { action: 'query', db, sql: String(sql), params: (params ?? []).map(ziltSqlParam) }),
    \\      execute: (db, sql, params) => builtin('__zilt.sql', { action: 'execute', db, sql: String(sql), params: (params ?? []).map(ziltSqlParam) }),
    \\      // v0.1.22：事务化迁移（成功后 PRAGMA user_version = version；失败整体回滚）
    \\      migrate: (db, version, statements) => builtin('__zilt.sql', {
    \\        action: 'migrate', path: db, version, statements: statements ?? [],
    \\      }),
    \\    },
;
const runtime_js_tail =
    \\  };
    \\  // v0.1.21：原型冻结（security.freezePrototype）——必须在对象建好之后
    \\  if (window.__ZILT_FREEZE__) {
    \\    try {
    \\      Object.freeze(window.zilt);
    \\      [Object.prototype, Array.prototype, Function.prototype, String.prototype, Number.prototype].forEach(function (p) { Object.freeze(p); });
    \\    } catch (e) {}
    \\  }
    \\  window.zilt.on('webviewEval', (p) => {
    \\    const wait = webviewEvalWaiters.get(p && p.rid);
    \\    if (!wait) return;
    \\    webviewEvalWaiters.delete(p.rid);
    \\    if (p.ok) wait.resolve(p.value); else wait.reject(new Error(p.error || 'eval failed'));
    \\  });
    \\  window.zilt.on('webviewCdp', (p) => {
    \\    const wait = cdpWaiters.get(p && p.rid);
    \\    if (!wait) return;
    \\    cdpWaiters.delete(p.rid);
    \\    if (p.ok) wait.resolve(p.result); else wait.reject(new Error(p.error || 'cdp failed'));
    \\  });
    \\  window.zilt.on('__zilt.evalResult', (p) => {
    \\    const w = evalWaiters.get(p.id);
    \\    if (!w) return;
    \\    evalWaiters.delete(p.id);
    \\    if (p.ok) w.resolve(p.result); else w.reject(new Error(p.error));
    \\  });
    \\  // 自定义标题栏：标记 data-zilt-drag-region 的元素可拖动窗口（按钮/输入除外）
    \\  document.addEventListener('mousedown', (e) => {
    \\    if (e.button !== 0) return;
    \\    if (e.target.closest && e.target.closest('button,input,textarea,select,a')) return;
    \\    const region = e.target.closest ? e.target.closest('[data-zilt-drag-region]') : null;
    \\    if (region) { e.preventDefault(); window.zilt.startDragging(); }
    \\  });
    \\  window.zilt.on('__reload', () => window.location.reload());
    \\})();
    \\
;

pub const runtime_js = runtime_js_head ++ "\n" ++
    "    version: '" ++ runtime_version ++ "',\n" ++
    runtime_js_tail;

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "v0.1.23: runtime_js 的版本号来自 version.zig（拼接无语法破坏）" {
    const expected = "    version: '" ++ runtime_version ++ "',\n";
    const at = std.mem.indexOf(u8, runtime_js, expected) orelse {
        std.debug.print("runtime_js 未找到版本行，前 200 字节：{s}\n", .{runtime_js[0..@min(200, runtime_js.len)]});
        return error.VersionLineMissing;
    };
    // 版本行必须自成一行（前后都是换行），否则拼进 JS 会破坏语法
    try testing.expect(at == 0 or runtime_js[at - 1] == '\n');
}

const TestCommands = struct {
    pub fn add(_: Context, args: struct { a: f64, b: f64 }) !f64 {
        return args.a + args.b;
    }
    pub fn greet(ctx: Context, args: struct { name: []const u8 }) !struct { message: []const u8, length: usize } {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{args.name});
        return .{ .message = msg, .length = msg.len };
    }
    pub fn failNow(_: Context, args: struct {}) !void {
        _ = args;
        return error.DemoFailure;
    }
    pub fn noArgs(ctx: Context) !struct { ok: bool } {
        _ = ctx;
        ctx_ok = true;
        return .{ .ok = true };
    }
    var ctx_ok: bool = false;
};

const TestEvents = struct {
    pub var last_name: []const u8 = "";
    pub var last_msg: []const u8 = "";
    pub fn frontendLog(_: Context, payload: struct { msg: []const u8 }) void {
        last_name = "frontendLog";
        last_msg = payload.msg;
    }
};

fn testEmit(backend: *anyopaque, window_id: u32, message_json: []const u8) void {
    _ = window_id;
    const list: *std.ArrayList(u8) = @ptrCast(@alignCast(backend));
    list.appendSlice(testing.allocator, message_json) catch {};
    testing.allocator.free(message_json); // 模拟后端用 msg_allocator 释放的契约
}
fn testQuit(backend: *anyopaque, code: u8) void {
    _ = backend;
    _ = code;
}

fn testContext(allocator: std.mem.Allocator, backend: *anyopaque) Context {
    return .{
        .allocator = allocator,
        .msg_allocator = testing.allocator,
        .backend = backend,
        .emit_fn = testEmit,
        .quit_fn = testQuit,
    };
}

test "decode: invoke / event / ignore" {
    var d = try decode(testing.allocator, "{\"zilt\":1,\"kind\":\"invoke\",\"id\":7,\"method\":\"add\",\"args\":{\"a\":2,\"b\":3}}");
    defer d.deinit();
    try testing.expect(d.msg == .invoke);
    try testing.expectEqual(@as(u64, 7), d.msg.invoke.id);
    try testing.expectEqualStrings("add", d.msg.invoke.method);
    try testing.expectEqualStrings("{\"a\":2,\"b\":3}", d.msg.invoke.args_json);

    var d2 = try decode(testing.allocator, "{\"zilt\":1,\"kind\":\"event\",\"name\":\"x\",\"payload\":[1,2]}");
    defer d2.deinit();
    try testing.expect(d2.msg == .event);
    try testing.expectEqualStrings("[1,2]", d2.msg.event.payload_json);

    var d3 = try decode(testing.allocator, "not json at all");
    defer d3.deinit();
    try testing.expect(d3.msg == .ignore);

    var d4 = try decode(testing.allocator, "{\"hello\":\"world\"}");
    defer d4.deinit();
    try testing.expect(d4.msg == .ignore);
}

test "dispatch: invoke with args, error, no-args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = testContext(arena.allocator(), undefined);

    const r1 = try dispatch(TestCommands, ctx, "add", "{\"a\":2,\"b\":3}");
    try testing.expectEqualStrings("5", r1);

    const r2 = try dispatch(TestCommands, ctx, "greet", "{\"name\":\"Zilt\"}");
    try testing.expectEqualStrings("{\"message\":\"Hello, Zilt!\",\"length\":12}", r2);

    try testing.expectError(error.DemoFailure, dispatch(TestCommands, ctx, "failNow", "{}"));
    try testing.expectError(error.UnknownCommand, dispatch(TestCommands, ctx, "nope", "{}"));

    const r3 = try dispatch(TestCommands, ctx, "noArgs", "null");
    try testing.expectEqualStrings("{\"ok\":true}", r3);
}

test "events: dispatch handled / unhandled" {
    const ctx = testContext(testing.allocator, undefined);
    try testing.expect(dispatchEvent(TestEvents, ctx, "frontendLog", "{\"msg\":\"hi\"}"));
    try testing.expectEqualStrings("hi", TestEvents.last_msg);
    try testing.expect(!dispatchEvent(TestEvents, ctx, "unknownEvent", "null"));
}

test "encode: resolve / reject / event" {
    const r = try encodeResolve(testing.allocator, 3, "{\"x\":1}");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"zilt\":1,\"kind\":\"resolve\",\"id\":3,\"result\":{\"x\":1}}", r);

    const j = try encodeReject(testing.allocator, 4, "Oops");
    defer testing.allocator.free(j);
    try testing.expectEqualStrings("{\"zilt\":1,\"kind\":\"reject\",\"id\":4,\"error\":\"Oops\"}", j);

    const e = try encodeEvent(testing.allocator, "tick", "{\"n\":1}");
    defer testing.allocator.free(e);
    try testing.expectEqualStrings("{\"zilt\":1,\"kind\":\"event\",\"name\":\"tick\",\"payload\":{\"n\":1}}", e);
}

test "context.emit marshals encoded event" {
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const ctx = testContext(testing.allocator, @ptrCast(&captured));
    ctx.emit("tick", .{ .n = 5 });
    try testing.expectEqualStrings("{\"zilt\":1,\"kind\":\"event\",\"name\":\"tick\",\"payload\":{\"n\":5}}", captured.items);
}

const WindowCap = struct {
    cmd: ?WindowCmd = null,
    window_id: u32 = 0,
    spawned: ?WindowOptions = null,
    clip: ?[]const u8 = null,
};

fn capWindow(backend: *anyopaque, window_id: u32, cmd: WindowCmd) bool {
    const cap: *WindowCap = @ptrCast(@alignCast(backend));
    cap.cmd = cmd;
    cap.window_id = window_id;
    return true;
}
fn capSpawn(backend: *anyopaque, opts: WindowOptions) ?u32 {
    const cap: *WindowCap = @ptrCast(@alignCast(backend));
    cap.spawned = opts;
    return 9;
}
fn capClipWrite(backend: *anyopaque, text: []const u8) bool {
    const cap: *WindowCap = @ptrCast(@alignCast(backend));
    cap.clip = text;
    return true;
}

test "context.window/newWindow/clipboard 走回调" {
    var cap: WindowCap = .{};
    const ctx = Context{
        .allocator = testing.allocator,
        .msg_allocator = testing.allocator,
        .backend = @ptrCast(&cap),
        .window_id = 3,
        .emit_fn = testEmit,
        .quit_fn = testQuit,
        .window_fn = capWindow,
        .spawn_window_fn = capSpawn,
        .clipboard_write_fn = capClipWrite,
    };

    ctx.windowSetTitle("新标题");
    try testing.expect(std.meta.activeTag(cap.cmd.?) == .set_title);
    try testing.expectEqualStrings("新标题", cap.cmd.?.set_title);
    try testing.expectEqual(@as(u32, 3), cap.window_id);

    ctx.windowSetFullscreen(true);
    try testing.expect(std.meta.activeTag(cap.cmd.?) == .fullscreen);
    try testing.expect(cap.cmd.?.fullscreen);

    ctx.windowMinimize();
    try testing.expect(std.meta.activeTag(cap.cmd.?) == .minimize);

    const id = try ctx.newWindow(.{ .title = "子窗口", .width = 400, .height = 300 });
    try testing.expectEqual(@as(u32, 9), id);
    try testing.expectEqualStrings("子窗口", cap.spawned.?.title);

    try ctx.clipboardWriteText("hello");
    try testing.expectEqualStrings("hello", cap.clip.?);
}

test "metas reflect command signatures" {
    const metas = comptime commandMetas(TestCommands);
    try testing.expectEqual(@as(usize, 4), metas.len);
    try testing.expectEqualStrings("add", metas[0].name);
    try testing.expect(metas[0].result == f64);
    try testing.expect(metas[2].result == void); // failNow
    try testing.expect(metas[3].args == null); // noArgs
}

test "v0.1.18: cursor kind names" {
    try testing.expectEqual(CursorKind.arrow, CursorKind.fromName("default").?);
    try testing.expectEqual(CursorKind.arrow, CursorKind.fromName("ARROW").?);
    try testing.expectEqual(CursorKind.ibeam, CursorKind.fromName("text").?);
    try testing.expectEqual(CursorKind.hand, CursorKind.fromName("pointer").?);
    try testing.expectEqual(CursorKind.not_allowed, CursorKind.fromName("not-allowed").?);
    try testing.expectEqual(CursorKind.size_ns, CursorKind.fromName("ns-resize").?);
    try testing.expectEqual(CursorKind.size_ew, CursorKind.fromName("ew-resize").?);
    try testing.expectEqual(CursorKind.move, CursorKind.fromName("grabbing").?);
    try testing.expect(CursorKind.fromName("nope") == null);
}
