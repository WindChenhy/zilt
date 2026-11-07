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

    fn emitJsonTo(self: Context, window_id: u32, name: []const u8, payload_json: []const u8) void {
        const msg = encodeEvent(self.msg_allocator, name, payload_json) catch return;
        self.emit_fn(self.backend, window_id, msg); // 所有权转移给后端（UI 线程用完用 msg_allocator 释放）
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

/// 提取命令命名空间的全部元数据（跳过非函数 decl）。
pub fn commandMetas(comptime Commands: type) []const Meta {
    const decl_names = @typeInfo(Commands).@"struct".decl_names;
    var count: usize = 0;
    for (decl_names) |name| {
        if (@typeInfo(@TypeOf(@field(Commands, name))) == .@"fn") count += 1;
    }
    var metas: [count]Meta = undefined;
    var i: usize = 0;
    for (decl_names) |name| {
        const f = @field(Commands, name);
        if (@typeInfo(@TypeOf(f)) != .@"fn") continue;
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
        if (@typeInfo(@TypeOf(f)) == .@"fn" and std.mem.eql(u8, name, method)) {
            return makeHandler(f)(ctx, args_json);
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

pub const runtime_js =
    \\(() => {
    \\  const resolvers = new Map();
    \\  const listeners = new Map();
    \\  let nextId = 1;
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
    \\    version: '0.1.12',
    \\  };
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

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

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
