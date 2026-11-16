//! Framework built-in commands (v0.1.9–v0.1.12).
//!
//! `window.zilt.*` talks to these methods instead of application commands. All
//! work goes through `ipc.Context` function pointers, so this module has no
//! platform/backend dependency and can be unit tested with mock callbacks.
//! Returned JSON is owned by `ctx.allocator` (the per-message arena).
const std = @import("std");
const ipc = @import("ipc.zig");
const webview = @import("webview.zig");
const clipboard = @import("clipboard.zig");
const notification = @import("notification.zig");
const system_api = @import("system_api.zig");
const taskbar = @import("taskbar.zig");
const theme = @import("theme.zig");
const shared_sql = @import("sql.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;

pub const ActionArg = struct {
    title: []const u8,
    arguments: []const u8 = "",
    launch: ?[]const u8 = null,
    input_id: ?[]const u8 = null,
};

pub const InputArg = struct {
    id: []const u8,
    placeholder: []const u8 = "",
    title: []const u8 = "",
};

/// One flat argument shape shared by all built-in methods; unknown keys are
/// ignored so the JS runtime may add fields without breaking the backend.
pub const Args = struct {
    action: []const u8 = "",
    id: ?i64 = null,
    window_id: ?u32 = null,
    label: ?[]const u8 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    url: ?[]const u8 = null,
    script: ?[]const u8 = null,
    format: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    text: ?[]const u8 = null,
    html: ?[]const u8 = null,
    files: ?[]const []const u8 = null,
    enabled: ?bool = null,
    width: ?u32 = null,
    height: ?u32 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    parent: ?u32 = null,
    modal: ?bool = null,
    child: ?bool = null,
    /// v0.2.1：窗口状态持久化键（window.create({stateKey}) → __zilt.window）
    state_key: ?[]const u8 = null,
    /// v0.2.6：per-window 关闭请求事件（window.create({closeRequested})）
    close_requested_event: ?bool = null,
    /// v0.3.0：窗口创建选项（对齐 ipc.WindowOptions；两平台同接）
    transparent: ?bool = null,
    background_color: ?u32 = null,
    titlebar_overlay: ?bool = null,
    decorations: ?bool = null,
    zoom: ?f64 = null,
    download_id: ?u64 = null,
    /// v0.1.24：窗口/WebView 的 User-Agent
    user_agent: ?[]const u8 = null,
    /// v0.3.2：无痕窗口（window.create({incognito}) / webviews.create({incognito})）
    incognito: ?bool = null,
    tag: ?[]const u8 = null,
    group: ?[]const u8 = null,
    progress: ?f64 = null,
    progress_status: ?[]const u8 = null,
    actions: ?[]const ActionArg = null,
    input: ?InputArg = null,

    // ---- v0.1.13 / v0.1.14（系统能力统一通道）----
    path: ?[]const u8 = null,
    accel: ?[]const u8 = null,
    checked: ?bool = null,
    menu_parent: ?[]const u8 = null,
    index: ?i32 = null,
    tooltip: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    click_left: ?[]const u8 = null,
    click_middle: ?[]const u8 = null,
    click_double: ?[]const u8 = null,
    backdrop: ?[]const u8 = null,
    dark_titlebar: ?bool = null,
    exe_args: ?[]const u8 = null,
    count: ?u32 = null,
    // ---- v0.1.18：窗口精细控制 ----
    cursor: ?[]const u8 = null,
    visible: ?bool = null,
    grab: ?bool = null,
    ignore: ?bool = null,
    dark: ?bool = null,
    caption_color: ?u32 = null,
    text_color: ?u32 = null,
    border_color: ?u32 = null,
    min_width: ?u32 = null,
    min_height: ?u32 = null,
    max_width: ?u32 = null,
    max_height: ?u32 = null,
    monitor: ?u32 = null,
    role: ?[]const u8 = null,
    // ---- v0.1.21：ACL ----
    acl_kind: ?[]const u8 = null,
    recursive: ?bool = null,
    chunk_size: ?u32 = null,
    version: ?i32 = null,
    statements: ?[]const []const u8 = null,
    pattern: ?[]const u8 = null,
    // ---- v0.1.19：fs scope / 目标路径 ----
    scope: ?[]const u8 = null,
    to: ?[]const u8 = null,
    to_scope: ?[]const u8 = null,
    // ---- v0.1.20：网络 ----
    proxy: ?[]const u8 = null,
    insecure_tls: ?bool = null,
    follow_redirects: ?bool = null,
    stream: ?bool = null,
    parts: ?[]const system_api.MultiPart = null,
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    data: ?[]const u8 = null,
    items: ?[]const []const u8 = null,
    level: ?[]const u8 = null,
    message: ?[]const u8 = null,
    /// 服务名（__zilt.services）
    name: ?[]const u8 = null,
    /// HTTP 方法 / 头 / 超时（__zilt.http）；body 复用上面的同名字段
    method: ?[]const u8 = null,
    headers: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
    /// WebSocket close code（__zilt.ws）；url 复用上面的同名字段
    code: ?u16 = null,
    /// 对话框（__zilt.dialog）；kind 复用上面的同名字段
    caption: ?[]const u8 = null,
    buttons: ?[]const u8 = null,
    default_name: ?[]const u8 = null,
    filters: ?[]const ipc.Filter = null,
    /// 子进程 argv（__zilt.process.spawn）
    argv: ?[]const []const u8 = null,
    /// SQL（__zilt.sql）
    db: ?[]const u8 = null,
    sql: ?[]const u8 = null,
    params: ?[]const shared_sql.SqlValue = null,
    /// 子 webview 数据分区名（__zilt.webviews.create）
    partition: ?[]const u8 = null,
    /// 子 webview eval 的请求 id（__zilt.webviews.eval，用于事件匹配）
    rid: ?i64 = null,
    /// v0.1.23：CDP 参数 JSON 文本（__zilt.webview action=cdp）
    params_json: ?[]const u8 = null,
};

pub fn isBuiltin(method: []const u8) bool {
    return std.mem.startsWith(u8, method, "__zilt.");
}

/// null = not a built-in method (application command dispatch should run).
/// Otherwise owned JSON used as the invoke() resolve value.
pub fn dispatch(ctx: ipc.Context, method: []const u8, args_json: []const u8) !?[]u8 {
    if (!isBuiltin(method)) return null;
    const parsed = std.json.parseFromSlice(Args, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch return error.InvalidBuiltinArgs;
    defer parsed.deinit();
    const a = parsed.value;
    if (std.mem.eql(u8, method, "__zilt.window")) return try windowCmd(ctx, a);
    if (std.mem.eql(u8, method, "__zilt.eval")) return try evalCmd(ctx, a);
    if (std.mem.eql(u8, method, "__zilt.webview")) return try webviewCmd(ctx, a);
    if (std.mem.eql(u8, method, "__zilt.clipboard")) return try clipboardCmd(ctx, a);
    if (std.mem.eql(u8, method, "__zilt.notification")) return try notificationCmd(ctx, a);
    if (std.mem.eql(u8, method, "__zilt.drag")) return try dragCmd(ctx, a);
    if (std.mem.eql(u8, method, "__zilt.path")) return try pathCmd(ctx, a);
    if (std.mem.eql(u8, method, "__zilt.log")) return try logCmd(ctx, a);
    if (std.mem.eql(u8, method, "__zilt.dialog")) return try dialogCmd(ctx, a);
    if (isSystemMethod(method)) return try systemCmd(ctx, method, a);
    return error.UnknownBuiltin;
}

/// v0.1.16：前端对话框（window.zilt.dialog）——复用 Context.dialog_fn，
/// 在 UI 线程模态执行（IPC 在消息循环里分发，与 Tauri 行为一致）。
/// ---------------------------------------------------------------------------

/// 扁平 JSON 参数 → 对话框请求。filters 用结构数组：[{name, pattern}]。
fn dialogCmd(ctx: ipc.Context, a: Args) ![]u8 {
    const eql = std.mem.eql;
    const dflt = ipc.Filter{ .name = "所有文件", .pattern = "*.*" };
    const file_opts = ipc.FileDialogOptions{
        .title = a.title orelse "",
        .filters = blk: {
            const raw = a.filters orelse break :blk &[_]ipc.Filter{dflt};
            if (raw.len == 0) break :blk &[_]ipc.Filter{dflt};
            break :blk raw;
        },
        .default_name = a.default_name orelse "",
    };
    const req: ipc.DialogRequest = blk: {
        if (eql(u8, a.action, "messageBox")) {
            const k = a.kind orelse "info";
            const kind: ipc.MsgKind = if (eql(u8, k, "warning")) .warning else if (eql(u8, k, "error")) .err else if (eql(u8, k, "question")) .err else .info;
            const buttons: ipc.MsgButtons = if (eql(u8, a.buttons orelse "ok", "ok_cancel")) .ok_cancel else if (eql(u8, a.buttons orelse "ok", "yes_no")) .yes_no else .ok;
            break :blk .{ .message_box = .{
                .text = a.text orelse a.message orelse "",
                .caption = a.caption orelse a.title orelse "提示",
                .kind = kind,
                .buttons = buttons,
            } };
        }
        if (eql(u8, a.action, "openFile")) break :blk .{ .open_file = file_opts };
        if (eql(u8, a.action, "saveFile")) break :blk .{ .save_file = file_opts };
        if (eql(u8, a.action, "pickFolder")) break :blk .{ .pick_folder = .{ .title = a.title orelse "选择文件夹" } };
        if (eql(u8, a.action, "pickFiles")) break :blk .{ .pick_files = file_opts };
        return error.UnknownDialogAction;
    };
    const resp = try (ctx.dialog_fn orelse return error.DialogNotAvailable)(ctx.backend, ctx.allocator, req);
    const alloc = ctx.allocator;
    return switch (resp) {
        .button => |b| switch (b) {
            .ok => alloc.dupe(u8, "\"ok\""),
            .cancel => alloc.dupe(u8, "\"cancel\""),
            .yes => alloc.dupe(u8, "\"yes\""),
            .no => alloc.dupe(u8, "\"no\""),
        },
        .path => |p| if (p) |path|
            std.json.Stringify.valueAlloc(alloc, path, .{})
        else
            alloc.dupe(u8, "null"),
        .paths => |ps| if (ps) |list|
            std.json.Stringify.valueAlloc(alloc, list, .{})
        else
            alloc.dupe(u8, "null"),
        else => error.DialogNotAvailable,
    };
}

/// v0.1.16：进程执行（window.zilt.process）。spawn 交给后端进程槽，
/// stdout/stderr/exit 走 processEvent 事件；kill/等待接口见 backend。
fn processCmd(ctx: ipc.Context, a: Args) ![]u8 {
    if (std.mem.eql(u8, a.action, "spawn")) {
        const argv = a.items orelse return error.MissingCommand;
        if (argv.len == 0) return error.MissingCommand;
        // 命令统一经 system_api 通道（backend 持有进程槽与事件线）
        const req = system_api.Request{ .process = .{ .spawn = .{
            .id = a.id orelse 0,
            .argv = argv,
            .cwd = a.path,
        } } };
        return try ctx.request_fn.?(ctx.backend, ctx.window_id, req);
    }
    if (std.mem.eql(u8, a.action, "kill")) {
        const req = system_api.Request{ .process = .{ .kill = .{
            .id = a.id orelse return error.MissingId,
            .exit_code = a.code orelse 1,
        } } };
        return try ctx.request_fn.?(ctx.backend, ctx.window_id, req);
    }
    if (std.mem.eql(u8, a.action, "list")) {
        const req = system_api.Request{ .process = .list };
        return try ctx.request_fn.?(ctx.backend, ctx.window_id, req);
    }
    return error.UnknownProcessAction;
}

fn ok(ctx: ipc.Context) ![]u8 {
    return ctx.allocator.dupe(u8, "null");
}

// ---------------------------------------------------------------------------
// v0.1.11: window.zilt.window
// ---------------------------------------------------------------------------

pub fn windowCmdFromArgs(a: Args, current_window: u32) !ipc.WindowCmd {
    const eql = std.mem.eql;
    if (eql(u8, a.action, "close")) return .close;
    if (eql(u8, a.action, "show")) return .show;
    if (eql(u8, a.action, "hide")) return .hide;
    if (eql(u8, a.action, "minimize")) return .minimize;
    if (eql(u8, a.action, "maximize")) return .maximize;
    if (eql(u8, a.action, "restore")) return .restore;
    if (eql(u8, a.action, "focus")) return .focus;
    if (eql(u8, a.action, "startDragging")) return .start_dragging;
    if (eql(u8, a.action, "fullscreen")) return .{ .fullscreen = a.enabled orelse true };
    if (eql(u8, a.action, "alwaysOnTop")) return .{ .always_on_top = a.enabled orelse true };
    if (eql(u8, a.action, "skipTaskbar")) return .{ .skip_taskbar = a.enabled orelse true };
    if (eql(u8, a.action, "setTitle")) return .{ .set_title = a.title orelse "" };
    if (eql(u8, a.action, "setSize")) return .{ .size = .{ .width = a.width orelse return error.MissingSize, .height = a.height orelse return error.MissingSize } };
    if (eql(u8, a.action, "setPosition")) return .{ .position = .{ .x = a.x orelse return error.MissingPosition, .y = a.y orelse return error.MissingPosition } };
    // v0.1.18
    if (eql(u8, a.action, "setCursor")) return .{ .cursor = ipc.CursorKind.fromName(a.cursor orelse "default") orelse return error.UnknownCursor };
    if (eql(u8, a.action, "setCursorVisible")) return .{ .cursor_visible = a.visible orelse true };
    if (eql(u8, a.action, "setCursorGrab")) return .{ .cursor_grab = a.grab orelse true };
    if (eql(u8, a.action, "setCursorPosition")) return .{ .cursor_position = .{ .x = a.x orelse return error.MissingPosition, .y = a.y orelse return error.MissingPosition } };
    if (eql(u8, a.action, "setIgnoreCursorEvents")) return .{ .ignore_cursor = a.ignore orelse true };
    if (eql(u8, a.action, "setContentProtected")) return .{ .content_protected = a.enabled orelse true };
    if (eql(u8, a.action, "setShadow")) return .{ .shadow = a.enabled orelse true };
    if (eql(u8, a.action, "setAlwaysOnBottom")) return .{ .always_on_bottom = a.enabled orelse true };
    if (eql(u8, a.action, "setFocusable")) return .{ .focusable = a.enabled orelse true };
    if (eql(u8, a.action, "setEnabled")) return .{ .enabled = a.enabled orelse true };
    if (eql(u8, a.action, "setTheme")) return .{ .theme = .{
        .dark = a.dark,
        .caption = a.caption_color,
        .text = a.text_color,
        .border = a.border_color,
    } };
    if (eql(u8, a.action, "setMinMax")) return .{ .limits = .{
        .min_width = a.min_width,
        .min_height = a.min_height,
        .max_width = a.max_width,
        .max_height = a.max_height,
    } };
    if (eql(u8, a.action, "fullscreenOnMonitor")) return .{ .fullscreen_monitor = a.monitor orelse 0 };
    if (eql(u8, a.action, "setIcon")) return .{ .icon = a.icon };
    if (eql(u8, a.action, "state")) return .state;
    _ = current_window;
    return error.UnknownWindowAction;
}

fn windowCmd(ctx: ipc.Context, a: Args) ![]u8 {
    if (std.mem.eql(u8, a.action, "create")) {
        const spawn = ctx.spawn_window_fn orelse return error.WindowNotAvailable;
        var opts = ipc.WindowOptions{
            .title = a.title orelse "Zilt Window",
            .width = a.width orelse 900,
            .height = a.height orelse 640,
            .url = a.url,
            .x = a.x,
            .y = a.y,
            .label = a.label,
            .parent = a.parent,
            .modal = a.modal orelse false,
            .child = a.child orelse false,
            .state_key = a.state_key,
            .close_requested_event = a.close_requested_event,
            .proxy = a.proxy,
            .user_agent = a.user_agent,
            // v0.3.0：桌面体验包（透明 / 背景色 / 覆盖式标题栏）
            .transparent = a.transparent orelse false,
            .background_color = a.background_color,
            .titlebar_overlay = a.titlebar_overlay orelse false,
            .decorations = a.decorations orelse true,
            // v0.3.2：无痕窗口
            .incognito = a.incognito orelse false,
        };
        if (a.window_id) |_| opts.parent = a.window_id;
        const id = spawn(ctx.backend, opts);
        return if (id) |n|
            std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{n})
        else
            ctx.allocator.dupe(u8, "{\"id\":null}");
    }
    const cmd = try windowCmdFromArgs(a, ctx.window_id);
    const target = a.window_id orelse ctx.window_id;
    switch (cmd) {
        .state => {
            const q = ctx.window_query_fn orelse return error.WindowNotAvailable;
            return q(ctx.backend, target, ctx.allocator) orelse error.WindowNotAvailable;
        },
        else => {},
    }
    const f = ctx.window_fn orelse return error.WindowNotAvailable;
    const success = f(ctx.backend, target, cmd);
    return ctx.allocator.dupe(u8, if (success) "true" else "false");
}

// ---------------------------------------------------------------------------
// v0.1.9: eval with Promise semantics
// ---------------------------------------------------------------------------

const EvalBox = struct {
    alloc: Allocator,
    backend: *anyopaque,
    window_id: u32,
    emit_fn: *const fn (*anyopaque, u32, []const u8) void,
    id: i64,
};

fn evalDone(context: *anyopaque, result: anyerror![]const u8) void {
    const box: *EvalBox = @ptrCast(@alignCast(context));
    defer box.alloc.destroy(box);
    const alloc = box.alloc;
    const payload = if (result) |json|
        std.fmt.allocPrint(alloc, "{{\"id\":{d},\"ok\":true,\"result\":{s}}}", .{ box.id, json }) catch return
    else |err| blk: {
        const name = std.json.Stringify.valueAlloc(alloc, @errorName(err), .{}) catch return;
        defer alloc.free(name);
        break :blk std.fmt.allocPrint(alloc, "{{\"id\":{d},\"ok\":false,\"error\":{s}}}", .{ box.id, name }) catch return;
    };
    defer alloc.free(payload);
    const msg = ipc.encodeEvent(alloc, "__zilt.evalResult", payload) catch return;
    box.emit_fn(box.backend, box.window_id, msg); // ownership transferred
}

fn evalCmd(ctx: ipc.Context, a: Args) ![]u8 {
    const script = a.script orelse return error.MissingScript;
    const box = try ctx.msg_allocator.create(EvalBox);
    box.* = .{
        .alloc = ctx.msg_allocator,
        .backend = ctx.backend,
        .window_id = ctx.window_id,
        .emit_fn = ctx.emit_fn,
        .id = a.id orelse 0,
    };
    ctx.evalAsync(script, box, evalDone) catch |err| {
        ctx.msg_allocator.destroy(box);
        return err;
    };
    return ok(ctx);
}

// ---------------------------------------------------------------------------
// v0.1.10: runtime WebView API
// ---------------------------------------------------------------------------

pub fn requestFromArgs(a: Args) !webview.Request {
    const eql = std.mem.eql;
    if (eql(u8, a.action, "reload")) return .reload;
    if (eql(u8, a.action, "stop")) return .stop;
    if (eql(u8, a.action, "getZoom")) return .get_zoom;
    if (eql(u8, a.action, "history")) return .history;
    if (eql(u8, a.action, "back")) return .back;
    if (eql(u8, a.action, "forward")) return .forward;
    if (eql(u8, a.action, "devtools")) return .devtools;
    if (eql(u8, a.action, "print")) return .{ .print = if (a.kind != null and eql(u8, a.kind.?, "system")) .system else .browser };
    if (eql(u8, a.action, "cancelDownload")) return .{ .cancel_download = a.download_id orelse return error.MissingDownloadId };
    if (eql(u8, a.action, "zoom")) return .{ .zoom = a.zoom orelse return error.MissingZoom };
    if (eql(u8, a.action, "clearStorage")) return .{ .clear_storage = .{} };
    if (eql(u8, a.action, "cookies.get")) return .{ .cookies = .{ .get = .{ .url = a.url } } };
    if (eql(u8, a.action, "cookies.clear")) return .{ .cookies = .{ .clear = .{ .origin = a.url } } };
    // v0.1.23：任意 CDP 调用（异步，结果走 webviewCdp 事件）
    if (eql(u8, a.action, "cdp")) return .{ .cdp = .{
        .method = a.method orelse return error.MissingCdpMethod,
        .params = a.params_json orelse "{}",
        .rid = a.rid orelse return error.MissingRid,
    } };
    // v0.1.24：运行时 UA（空串 = 恢复引擎默认）
    if (eql(u8, a.action, "setUserAgent")) return .{ .set_user_agent = a.user_agent orelse "" };
    return error.UnknownWebViewAction;
}

fn webviewCmd(ctx: ipc.Context, a: Args) ![]u8 {
    const request = try requestFromArgs(a);
    return ctx.webviewRequest(request);
}

// ---------------------------------------------------------------------------
// v0.1.12: clipboard / drag / notifications
// ---------------------------------------------------------------------------

pub fn formatFromName(name: []const u8) !clipboard.Format {
    const eql = std.mem.eql;
    if (eql(u8, name, "text")) return .text;
    if (eql(u8, name, "html")) return .html;
    if (eql(u8, name, "image")) return .image;
    if (eql(u8, name, "files")) return .files;
    return error.UnknownClipboardFormat;
}

pub fn clipboardJson(alloc: Allocator, data: clipboard.Data) ![]u8 {
    return switch (data) {
        .text => |t| std.json.Stringify.valueAlloc(alloc, t, .{}),
        .html => |h| std.json.Stringify.valueAlloc(alloc, h, .{}),
        .files => |fs| std.json.Stringify.valueAlloc(alloc, fs, .{}),
        .image => |img| std.fmt.allocPrint(alloc, "{{\"width\":{d},\"height\":{d},\"bytes\":{d}}}", .{ img.width, img.height, img.rgba.len }),
    };
}

/// Mirrors the platform clipboard's ownership contract: every slice (including
/// the file-list slice) belongs to the allocator that produced the Data.
pub fn freeClipboard(alloc: Allocator, data: clipboard.Data) void {
    switch (data) {
        .text => |t| alloc.free(t),
        .html => |h| alloc.free(h),
        .image => |img| alloc.free(img.rgba),
        .files => |fs| {
            for (fs) |f| alloc.free(f);
            alloc.free(fs);
        },
    }
}

fn clipboardCmd(ctx: ipc.Context, a: Args) ![]u8 {
    const format = try formatFromName(a.format orelse "text");
    if (std.mem.eql(u8, a.action, "read")) {
        const data = (try ctx.clipboardRead(format)) orelse return ok(ctx);
        defer freeClipboard(ctx.allocator, data);
        return clipboardJson(ctx.allocator, data);
    }
    if (std.mem.eql(u8, a.action, "write")) {
        const data: clipboard.Data = switch (format) {
            .text => .{ .text = a.text orelse return error.MissingClipboardValue },
            .html => .{ .html = a.html orelse return error.MissingClipboardValue },
            .files => .{ .files = a.files orelse return error.MissingClipboardValue },
            .image => return error.ImageWriteRequiresZigApi,
        };
        try ctx.clipboardWrite(data);
        return ok(ctx);
    }
    return error.UnknownClipboardAction;
}

fn dragCmd(ctx: ipc.Context, a: Args) ![]u8 {
    if (!std.mem.eql(u8, a.action, "start")) return error.UnknownDragAction;
    try ctx.startDrag(a.files orelse return error.MissingFiles);
    return ok(ctx);
}

fn notificationCmd(ctx: ipc.Context, a: Args) ![]u8 {
    if (std.mem.eql(u8, a.action, "status")) {
        const status = try ctx.notificationStatus();
        const name = std.json.Stringify.valueAlloc(ctx.allocator, @tagName(status), .{}) catch return error.OutOfMemory;
        return std.fmt.allocPrint(ctx.allocator, "{{\"status\":{s}}}", .{name});
    }
    if (std.mem.eql(u8, a.action, "update")) {
        const tag = a.tag orelse return error.MissingTag;
        try ctx.notificationUpdate(tag, a.group, .{
            .value = a.progress,
            .value_string = a.text orelse "",
            .status = a.progress_status orelse "",
        });
        return ok(ctx);
    }
    if (std.mem.eql(u8, a.action, "show")) {
        var options = notification.Options{
            .title = a.title orelse "",
            .body = a.body orelse "",
            .tag = a.tag,
            .group = a.group,
            .launch = a.url,
        };
        if (a.progress) |value| options.progress = .{
            .value = value,
            .value_string = a.text orelse "",
            .status = a.progress_status orelse "",
        };
        if (a.input) |input| {
            options.input = .{ .id = input.id, .placeholder = input.placeholder, .title = input.title };
        }
        if (a.actions) |list| {
            const actions = try ctx.allocator.alloc(notification.Action, list.len);
            for (list, actions) |src, *dst| {
                dst.* = .{ .title = src.title, .arguments = src.arguments, .launch = src.launch, .input_id = src.input_id };
            }
            options.actions = actions;
        }
        try ctx.notificationShow(options);
        return ok(ctx);
    }
    return error.UnknownNotificationAction;
}

// ---------------------------------------------------------------------------
// v0.1.13 / v0.1.14：系统能力统一通道
// ---------------------------------------------------------------------------

pub fn isSystemMethod(method: []const u8) bool {
    const prefix = "__zilt.";
    if (!std.mem.startsWith(u8, method, prefix)) return false;
    const name = method[prefix.len..];
    const eql = std.mem.eql;
    return eql(u8, name, "menu") or eql(u8, name, "tray") or eql(u8, name, "hotkey") or
        eql(u8, name, "taskbar") or eql(u8, name, "system") or eql(u8, name, "shell") or
        eql(u8, name, "autostart") or eql(u8, name, "appearance") or
        eql(u8, name, "store") or eql(u8, name, "fs") or eql(u8, name, "windowState") or
        eql(u8, name, "services") or eql(u8, name, "http") or eql(u8, name, "ws") or
        eql(u8, name, "webviews") or eql(u8, name, "process") or eql(u8, name, "sql") or
        eql(u8, name, "updater") or eql(u8, name, "acl");
}

pub fn clickActionFromName(name: ?[]const u8) system_api.ClickAction {
    const n = name orelse return .none;
    const eql = std.mem.eql;
    if (eql(u8, n, "toggle") or eql(u8, n, "toggleWindow")) return .toggle_window;
    if (eql(u8, n, "menu") or eql(u8, n, "showMenu")) return .show_menu;
    if (eql(u8, n, "event") or eql(u8, n, "emitEvent")) return .emit_event;
    return .none;
}

/// 把 `window.zilt.*` 的扁平参数映射为类型化请求；未知动作返回明确错误。
pub fn systemRequestFromArgs(method: []const u8, a: Args) !system_api.Request {
    const eql = std.mem.eql;
    const name = method["__zilt.".len..];

    if (eql(u8, name, "menu")) {
        if (eql(u8, a.action, "list")) return .{ .menu = .list };
        if (eql(u8, a.action, "add")) return .{ .menu = .{ .add = .{
            .parent = a.menu_parent,
            .index = a.index orelse -1,
            .id = a.path,
            .label = a.title orelse a.text orelse "",
            .accel = a.accel,
            .checked = a.checked orelse false,
            .enabled = a.enabled orelse true,
        } } };
        if (eql(u8, a.action, "remove")) return .{ .menu = .{ .remove = a.path orelse return error.MissingPath } };
        if (eql(u8, a.action, "set")) return .{ .menu = .{ .set = .{
            .path = a.path orelse return error.MissingPath,
            .label = a.title,
            .checked = a.checked,
            .enabled = a.enabled,
            .accel = a.accel,
        } } };
        if (eql(u8, a.action, "popup")) return .{ .menu = .{ .popup = .{ .x = a.x orelse 0, .y = a.y orelse 0 } } };
        return error.UnknownMenuAction;
    }

    if (eql(u8, name, "tray")) {
        if (eql(u8, a.action, "setTooltip")) return .{ .tray = .{ .set_tooltip = a.tooltip orelse a.text orelse "" } };
        if (eql(u8, a.action, "setIcon")) return .{ .tray = .{ .set_icon = a.icon } };
        if (eql(u8, a.action, "setClick")) return .{ .tray = .{ .set_click = .{
            .left = clickActionFromName(a.click_left),
            .middle = clickActionFromName(a.click_middle),
            .double = clickActionFromName(a.click_double),
        } } };
        return error.UnknownTrayAction;
    }

    if (eql(u8, name, "hotkey")) {
        if (eql(u8, a.action, "register")) return .{ .hotkey = .{ .register = .{
            .id = a.path orelse return error.MissingPath,
            .accel = a.accel orelse return error.MissingAccel,
        } } };
        if (eql(u8, a.action, "unregister")) return .{ .hotkey = .{ .unregister = a.path orelse return error.MissingPath } };
        if (eql(u8, a.action, "list")) return .{ .hotkey = .list };
        return error.UnknownHotkeyAction;
    }

    if (eql(u8, name, "taskbar")) {
        if (eql(u8, a.action, "progress")) {
            var p = taskbar.Progress{ .value = a.progress };
            if (a.kind) |k| p.state = try taskbar.ProgressState.fromName(k);
            return .{ .taskbar = .{ .progress = p } };
        }
        if (eql(u8, a.action, "overlay")) {
            return .{ .taskbar = .{ .overlay = if (a.icon) |i|
                taskbar.Request.Overlay{ .icon = i, .description = a.text orelse "" }
            else
                null } };
        }
        if (eql(u8, a.action, "tooltip")) return .{ .taskbar = .{ .tooltip = a.text orelse "" } };
        if (eql(u8, a.action, "flash")) return .{ .taskbar = .{ .flash = .{
            .count = a.count orelse 3,
            .timeout_ms = 0,
            .tray_only = a.enabled orelse true,
        } } };
        return error.UnknownTaskbarAction;
    }

    if (eql(u8, name, "system")) {
        if (eql(u8, a.action, "info")) {
            const kind = if (a.kind) |k| blk: {
                if (eql(u8, k, "os")) break :blk system_api.InfoKind.os;
                if (eql(u8, k, "monitors")) break :blk system_api.InfoKind.monitors;
                break :blk system_api.InfoKind.all;
            } else system_api.InfoKind.all;
            return .{ .info = kind };
        }
        if (eql(u8, a.action, "adminRestart")) return .{ .admin_restart = a.exe_args };
        return error.UnknownSystemAction;
    }

    if (eql(u8, name, "shell")) {
        if (eql(u8, a.action, "openUrl")) return .{ .shell = .{ .url = a.url orelse a.text orelse return error.MissingUrl } };
        if (eql(u8, a.action, "openPath")) return .{ .shell = .{ .path = a.path orelse return error.MissingPath } };
        if (eql(u8, a.action, "reveal")) return .{ .shell = .{ .reveal = a.path orelse return error.MissingPath } };
        return error.UnknownShellAction;
    }

    if (eql(u8, name, "autostart")) {
        if (eql(u8, a.action, "query")) return .{ .autostart = .query };
        if (eql(u8, a.action, "enable")) return .{ .autostart = .{ .enable = a.exe_args } };
        if (eql(u8, a.action, "disable")) return .{ .autostart = .disable };
        if (eql(u8, a.action, "toggle")) return .{ .autostart = .toggle };
        return error.UnknownAutostartAction;
    }

    if (eql(u8, name, "store")) {
        if (eql(u8, a.action, "get")) return .{ .store = .{ .get = a.key orelse return error.MissingKey } };
        if (eql(u8, a.action, "set")) return .{ .store = .{ .set = .{
            .key = a.key orelse return error.MissingKey,
            .value = a.value orelse return error.MissingValue,
        } } };
        if (eql(u8, a.action, "remove")) return .{ .store = .{ .remove = a.key orelse return error.MissingKey } };
        if (eql(u8, a.action, "keys")) return .{ .store = .keys };
        if (eql(u8, a.action, "all")) return .{ .store = .all };
        return error.UnknownStoreAction;
    }

    if (eql(u8, name, "fs")) {
        if (eql(u8, a.action, "roots")) return .{ .fs = .roots };
        if (eql(u8, a.action, "watch")) return .{ .fs = .{ .watch = .{
            .path = a.path orelse "",
            .scope = a.scope,
            .recursive = a.recursive orelse true,
        } } };
        if (eql(u8, a.action, "unwatch")) return .{ .fs = .{ .unwatch = a.id orelse return error.MissingId } };
        if (eql(u8, a.action, "readStream") or eql(u8, a.action, "read_stream")) return .{ .fs = .{ .read_stream = .{
            .path = a.path orelse return error.MissingPath,
            .scope = a.scope,
            .chunk_size = a.chunk_size orelse 64 * 1024,
        } } };
        const target = system_api.FsTarget{ .path = a.path orelse return error.MissingPath, .scope = a.scope };
        if (eql(u8, a.action, "read")) return .{ .fs = .{ .read = target } };
        if (eql(u8, a.action, "write")) return .{ .fs = .{ .write = .{
            .path = target.path,
            .data = a.data orelse a.text orelse "",
            .scope = target.scope,
        } } };
        if (eql(u8, a.action, "append")) return .{ .fs = .{ .append = .{
            .path = target.path,
            .data = a.data orelse a.text orelse "",
            .scope = target.scope,
        } } };
        if (eql(u8, a.action, "exists")) return .{ .fs = .{ .exists = target } };
        if (eql(u8, a.action, "remove")) return .{ .fs = .{ .remove = target } };
        if (eql(u8, a.action, "mkdir")) return .{ .fs = .{ .mkdir = target } };
        if (eql(u8, a.action, "removeDir") or eql(u8, a.action, "remove_dir")) return .{ .fs = .{ .remove_dir = target } };
        if (eql(u8, a.action, "readDir") or eql(u8, a.action, "read_dir")) return .{ .fs = .{ .read_dir = target } };
        if (eql(u8, a.action, "stat")) return .{ .fs = .{ .stat = target } };
        if (eql(u8, a.action, "rename")) return .{ .fs = .{ .rename = .{
            .from = target.path,
            .to = a.to orelse return error.MissingPath,
            .scope = target.scope,
            .to_scope = a.to_scope,
        } } };
        if (eql(u8, a.action, "copy")) return .{ .fs = .{ .copy = .{
            .from = target.path,
            .to = a.to orelse return error.MissingPath,
            .scope = target.scope,
            .to_scope = a.to_scope,
        } } };
        if (eql(u8, a.action, "roots")) return .{ .fs = .roots };
        if (eql(u8, a.action, "watch")) return .{ .fs = .{ .watch = .{
            .path = a.path orelse "",
            .scope = a.scope,
            .recursive = a.recursive orelse true,
        } } };
        if (eql(u8, a.action, "unwatch")) return .{ .fs = .{ .unwatch = a.id orelse return error.MissingId } };
        if (eql(u8, a.action, "readStream") or eql(u8, a.action, "read_stream")) return .{ .fs = .{ .read_stream = .{
            .path = a.path orelse return error.MissingPath,
            .scope = a.scope,
            .chunk_size = a.chunk_size orelse 64 * 1024,
        } } };
        return error.UnknownFsAction;
    }

    if (eql(u8, name, "acl")) {
        if (eql(u8, a.action, "list")) return .{ .acl = .list };
        if (eql(u8, a.action, "grant")) return .{ .acl = .{ .grant = .{
            .kind = a.acl_kind orelse "fs",
            .pattern = a.pattern orelse return error.MissingPath,
        } } };
        if (eql(u8, a.action, "revoke")) return .{ .acl = .{ .revoke = .{
            .kind = a.acl_kind orelse "fs",
            .pattern = a.pattern orelse return error.MissingPath,
        } } };
        return error.UnknownAclAction;
    }

    if (eql(u8, name, "updater")) {
        if (eql(u8, a.action, "info")) return .{ .updater = .info };
        if (eql(u8, a.action, "check")) return .{ .updater = .check };
        return error.UnknownUpdaterAction;
    }

    if (eql(u8, name, "http")) {
        if (eql(u8, a.action, "request")) {
            return .{ .http = .{ .request = .{
                .id = a.id orelse 0,
                .url = a.url orelse return error.MissingUrl,
                .method = a.method orelse "GET",
                .headers = a.headers orelse "",
                .body = a.body orelse a.text orelse a.data orelse "",
                .timeout_ms = a.timeout_ms orelse 30_000,
                .proxy = a.proxy,
                .insecure_tls = a.insecure_tls orelse false,
                .follow_redirects = a.follow_redirects orelse true,
                .stream = a.stream orelse false,
                .multipart = a.parts,
            } } };
        }
        return error.UnknownHttpAction;
    }

    if (eql(u8, name, "services")) {
        if (eql(u8, a.action, "list")) return .{ .services = .list };
        if (eql(u8, a.action, "status")) return .{ .services = .{ .status = a.name orelse return error.MissingName } };
        if (eql(u8, a.action, "start")) return .{ .services = .{ .start = a.name orelse return error.MissingName } };
        if (eql(u8, a.action, "stop")) return .{ .services = .{ .stop = a.name orelse return error.MissingName } };
        return error.UnknownServicesAction;
    }

    if (eql(u8, name, "windowState")) {
        if (eql(u8, a.action, "get")) return .{ .window_state = .get };
        if (eql(u8, a.action, "save")) return .{ .window_state = .save };
        return error.UnknownWindowStateAction;
    }

    if (eql(u8, name, "ws")) {
        if (eql(u8, a.action, "connect")) return .{ .ws = .{ .connect = .{
            .id = a.id orelse 0,
            .url = a.url orelse return error.MissingUrl,
            .proxy = a.proxy,
            .insecure_tls = a.insecure_tls orelse false,
            .headers = a.headers orelse "",
        } } };
        if (eql(u8, a.action, "send")) return .{ .ws = .{ .send = .{
            .id = a.id orelse return error.MissingId,
            .data = a.data orelse a.body orelse "",
        } } };
        if (eql(u8, a.action, "close")) return .{ .ws = .{ .close = .{
            .id = a.id orelse return error.MissingId,
            .code = a.code orelse 1000,
            .reason = a.message orelse "",
        } } };
        return error.UnknownWsAction;
    }

    if (eql(u8, name, "webviews")) {
        if (eql(u8, a.action, "create")) return .{ .webviews = .{ .create = .{
            .x = a.x orelse 0,
            .y = a.y orelse 0,
            .width = @intCast(a.width orelse 400),
            .height = @intCast(a.height orelse 300),
            .url = a.url orelse "",
            .partition = a.partition,
            .incognito = a.incognito orelse false,
        } } };
        if (eql(u8, a.action, "remove")) return .{ .webviews = .{ .remove = a.id orelse return error.MissingId } };
        if (eql(u8, a.action, "navigate")) return .{ .webviews = .{ .navigate = .{
            .id = a.id orelse return error.MissingId,
            .url = a.url orelse return error.MissingUrl,
        } } };
        if (eql(u8, a.action, "setBounds")) return .{ .webviews = .{ .set_bounds = .{
            .id = a.id orelse return error.MissingId,
            .x = a.x orelse 0,
            .y = a.y orelse 0,
            .width = @intCast(a.width orelse 400),
            .height = @intCast(a.height orelse 300),
        } } };
        if (eql(u8, a.action, "focus")) return .{ .webviews = .{ .focus = a.id orelse return error.MissingId } };
        if (eql(u8, a.action, "list")) return .{ .webviews = .list };
        if (eql(u8, a.action, "eval")) return .{ .webviews = .{ .eval = .{
            .id = a.id orelse return error.MissingId,
            .script = a.script orelse return error.MissingScript,
            .rid = a.rid orelse 0,
        } } };
        return error.UnknownWebviewsAction;
    }

    if (eql(u8, name, "sql")) {
        if (eql(u8, a.action, "migrate")) return .{ .sql = .{ .migrate = .{
            .db = a.path orelse a.db orelse return error.MissingPath,
            .version = a.version orelse return error.MissingVersion,
            .statements = a.statements orelse &.{},
        } } };
        const q = system_api.SqlQuery{
            .db = a.db orelse return error.MissingDb,
            .sql = a.sql orelse return error.MissingSql,
            .params = a.params orelse &.{},
        };
        if (eql(u8, a.action, "query")) return .{ .sql = .{ .query = q } };
        if (eql(u8, a.action, "execute")) return .{ .sql = .{ .execute = q } };
        return error.UnknownSqlAction;
    }

    if (eql(u8, name, "process")) {
        if (eql(u8, a.action, "spawn")) return .{ .process = .{ .spawn = .{
            .id = a.id orelse 0,
            .argv = a.argv orelse a.items orelse return error.MissingCommand,
            .cwd = a.path,
        } } };
        if (eql(u8, a.action, "kill")) return .{ .process = .{ .kill = .{
            .id = a.id orelse return error.MissingId,
            .exit_code = a.code orelse 1,
        } } };
        if (eql(u8, a.action, "list")) return .{ .process = .list };
        return error.UnknownProcessAction;
    }

    if (eql(u8, name, "appearance")) {
        var ap = theme.Appearance{};
        if (a.dark_titlebar) |d| ap.dark_titlebar = d;
        if (a.backdrop) |b| ap.backdrop = try theme.Backdrop.fromName(b);
        return .{ .appearance = ap };
    }

    return error.UnknownBuiltin;
}

/// `window.zilt.path.*`（v0.1.16）：纯路径运算，不触碰文件系统。
fn pathCmd(ctx: ipc.Context, a: Args) ![]u8 {
    const eql = std.mem.eql;
    const alloc = ctx.allocator;

    if (eql(u8, a.action, "join")) {
        const items = a.items orelse return error.MissingItems;
        const joined = try std.fs.path.join(alloc, items);
        defer alloc.free(joined);
        return std.json.Stringify.valueAlloc(alloc, joined, .{});
    }

    const p = a.path orelse return error.MissingPath;
    var value: []const u8 = "";
    if (eql(u8, a.action, "dirname")) {
        value = std.fs.path.dirname(p) orelse "";
    } else if (eql(u8, a.action, "basename")) {
        value = std.fs.path.basename(p);
    } else if (eql(u8, a.action, "extname")) {
        value = std.fs.path.extension(p);
    } else if (eql(u8, a.action, "normalize")) {
        const resolved = try std.fs.path.resolve(alloc, &.{p});
        defer alloc.free(resolved);
        return std.json.Stringify.valueAlloc(alloc, resolved, .{});
    } else {
        return error.UnknownPathAction;
    }
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

/// `window.zilt.log(level, message)`（v0.1.16）：前端日志汇入 Zig 日志。
fn logCmd(ctx: ipc.Context, a: Args) ![]u8 {
    const level = a.level orelse "info";
    const msg = a.message orelse a.text orelse "";
    if (std.mem.eql(u8, level, "debug")) {
        log.print("[fe:debug] {s}", .{msg});
    } else if (std.mem.eql(u8, level, "warn")) {
        log.print("[fe:warn] {s}", .{msg});
    } else if (std.mem.eql(u8, level, "error")) {
        log.print("[fe:error] {s}", .{msg});
    } else {
        log.print("[fe:info] {s}", .{msg});
    }
    return ok(ctx);
}

fn systemCmd(ctx: ipc.Context, method: []const u8, a: Args) ![]u8 {
    const req = try systemRequestFromArgs(method, a);
    const result = try ctx.systemRequest(req);
    return system_api.encodeResult(ctx.allocator, result);
}

// ---------------------------------------------------------------------------
// Tests (no platform calls; mock Context function pointers)
// ---------------------------------------------------------------------------

fn mockEmit(_: *anyopaque, _: u32, msg: []const u8) void {
    std.heap.page_allocator.free(msg);
}
fn mockQuit(_: *anyopaque, _: u8) void {}
var last_cmd: ?ipc.WindowCmd = null;
var last_window: u32 = 0;
fn mockWindow(_: *anyopaque, id: u32, cmd: ipc.WindowCmd) bool {
    last_cmd = cmd;
    last_window = id;
    return true;
}
fn mockSpawn(_: *anyopaque, _: ipc.WindowOptions) ?u32 {
    return 7;
}

var last_system: ?system_api.Request = null;

fn mockSystem(_: *anyopaque, _: u32, alloc: std.mem.Allocator, req: system_api.Request) anyerror!system_api.Result {
    last_system = req;
    return switch (req) {
        .menu => |op| switch (op) {
            .list => .{ .json = try alloc.dupe(u8, "[]") },
            else => .{ .ok = true },
        },
        .info => .{ .json = try alloc.dupe(u8, "{}") },
        .autostart => .{ .state = .{ .enabled = false, .command = null } },
        else => .{ .ok = true },
    };
}

fn testContext(alloc: Allocator) ipc.Context {
    return .{
        .allocator = alloc,
        .msg_allocator = alloc,
        .backend = @ptrFromInt(0x1234),
        .window_id = 3,
        .emit_fn = mockEmit,
        .quit_fn = mockQuit,
        .window_fn = mockWindow,
        .spawn_window_fn = mockSpawn,
        .system_fn = mockSystem,
    };
}

test "builtin method detection and unknown methods" {
    const t = std.testing;
    try t.expect(isBuiltin("__zilt.window"));
    try t.expect(!isBuiltin("greet"));
    try t.expectError(error.UnknownBuiltin, dispatch(testContext(t.allocator), "__zilt.nope", "{}"));
}

test "window action mapping covers the full JS surface" {
    const t = std.testing;
    const cases = [_]struct { action: []const u8, tag: []const u8 }{
        .{ .action = "close", .tag = "close" },
        .{ .action = "show", .tag = "show" },
        .{ .action = "hide", .tag = "hide" },
        .{ .action = "minimize", .tag = "minimize" },
        .{ .action = "maximize", .tag = "maximize" },
        .{ .action = "restore", .tag = "restore" },
        .{ .action = "focus", .tag = "focus" },
        .{ .action = "startDragging", .tag = "start_dragging" },
        .{ .action = "fullscreen", .tag = "fullscreen" },
        .{ .action = "alwaysOnTop", .tag = "always_on_top" },
        .{ .action = "skipTaskbar", .tag = "skip_taskbar" },
        .{ .action = "setTitle", .tag = "set_title" },
        .{ .action = "setSize", .tag = "size" },
        .{ .action = "setPosition", .tag = "position" },
    };
    for (cases) |c| {
        const a = Args{ .action = c.action, .title = "t", .width = 10, .height = 20, .x = 1, .y = 2 };
        const cmd = try windowCmdFromArgs(a, 3);
        try t.expectEqualStrings(c.tag, @tagName(std.meta.activeTag(cmd)));
    }
    try t.expectError(error.UnknownWindowAction, windowCmdFromArgs(.{ .action = "explode" }, 3));
    try t.expectError(error.MissingSize, windowCmdFromArgs(.{ .action = "setSize" }, 3));
}

test "window create and control dispatch through Context" {
    const t = std.testing;
    const created = try dispatch(testContext(t.allocator), "__zilt.window", "{\"action\":\"create\",\"title\":\"child\"}");
    defer t.allocator.free(created.?);
    try t.expectEqualStrings("{\"id\":7}", created.?);
    const applied = try dispatch(testContext(t.allocator), "__zilt.window", "{\"action\":\"minimize\",\"window_id\":9}");
    defer t.allocator.free(applied.?);
    try t.expectEqualStrings("true", applied.?);
    try t.expectEqual(@as(u32, 9), last_window);
    try t.expectEqualStrings("minimize", @tagName(std.meta.activeTag(last_cmd.?)));
}

test "webview request mapping and clipboard format mapping" {
    const t = std.testing;
    try t.expectEqualStrings("reload", @tagName(std.meta.activeTag(try requestFromArgs(.{ .action = "reload" }))));
    try t.expectEqualStrings("get_zoom", @tagName(std.meta.activeTag(try requestFromArgs(.{ .action = "getZoom" }))));
    try t.expectEqualStrings("zoom", @tagName(std.meta.activeTag(try requestFromArgs(.{ .action = "zoom", .zoom = 1.5 }))));
    try t.expectError(error.MissingZoom, requestFromArgs(.{ .action = "zoom" }));
    try t.expectError(error.UnknownWebViewAction, requestFromArgs(.{ .action = "bogus" }));
    try t.expectEqual(clipboard.Format.html, try formatFromName("html"));
    try t.expectError(error.UnknownClipboardFormat, formatFromName("bogus"));
}

test "clipboard JSON roundtrip for every format" {
    const t = std.testing;
    const cases = [_]clipboard.Data{
        .{ .text = "hello" },
        .{ .html = "<b>x</b>" },
        .{ .files = &.{"C:\\a.txt"} },
        .{ .image = .{ .width = 2, .height = 1, .rgba = &.{ 0, 0, 0, 0, 1, 2, 3, 4 } } },
    };
    for (cases) |data| {
        const json = try clipboardJson(t.allocator, data);
        defer t.allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, json, .{});
        defer parsed.deinit();
    }
    const owned = try t.allocator.dupe(u8, "text");
    freeClipboard(t.allocator, .{ .text = owned });
}

test "system method detection and request mapping" {
    const t = std.testing;
    try t.expect(isSystemMethod("__zilt.menu"));
    try t.expect(isSystemMethod("__zilt.taskbar"));
    try t.expect(!isSystemMethod("__zilt.window"));
    try t.expect(!isSystemMethod("greet"));

    const hk = try systemRequestFromArgs("__zilt.hotkey", .{ .action = "register", .path = "save", .accel = "Ctrl+S" });
    try t.expectEqualStrings("save", hk.hotkey.register.id);
    try t.expectEqualStrings("Ctrl+S", hk.hotkey.register.accel);

    const info = try systemRequestFromArgs("__zilt.system", .{ .action = "info", .kind = "monitors" });
    try t.expectEqual(system_api.InfoKind.monitors, info.info);

    const progress = try systemRequestFromArgs("__zilt.taskbar", .{ .action = "progress", .progress = 0.25, .kind = "paused" });
    try t.expectEqual(taskbar.ProgressState.paused, progress.taskbar.progress.state);
    try t.expect(progress.taskbar.progress.value.? == 0.25);

    const overlay_clear = try systemRequestFromArgs("__zilt.taskbar", .{ .action = "overlay" });
    try t.expect(overlay_clear.taskbar.overlay == null);

    const ap = try systemRequestFromArgs("__zilt.appearance", .{ .action = "apply", .dark_titlebar = true, .backdrop = "mica" });
    try t.expectEqual(true, ap.appearance.dark_titlebar.?);
    try t.expectEqual(theme.Backdrop.mica, ap.appearance.backdrop.?);

    const tray = try systemRequestFromArgs("__zilt.tray", .{ .action = "setClick", .click_left = "menu", .click_double = "toggle" });
    try t.expectEqual(system_api.ClickAction.show_menu, tray.tray.set_click.left);
    try t.expectEqual(system_api.ClickAction.toggle_window, tray.tray.set_click.double);

    const auto = try systemRequestFromArgs("__zilt.autostart", .{ .action = "toggle" });
    try t.expectEqual(system_api.AutostartOp.toggle, auto.autostart);

    try t.expectError(error.UnknownMenuAction, systemRequestFromArgs("__zilt.menu", .{ .action = "explode" }));
    try t.expectError(error.UnknownTaskbarAction, systemRequestFromArgs("__zilt.taskbar", .{ .action = "explode" }));
    try t.expectError(error.MissingAccel, systemRequestFromArgs("__zilt.hotkey", .{ .action = "register", .path = "x" }));
}

test "system dispatch goes through Context and encodes results" {
    const t = std.testing;
    const list = try dispatch(testContext(t.allocator), "__zilt.menu", "{\"action\":\"list\"}");
    defer t.allocator.free(list.?);
    try t.expectEqualStrings("[]", list.?);

    const state = try dispatch(testContext(t.allocator), "__zilt.autostart", "{\"action\":\"query\"}");
    defer t.allocator.free(state.?);
    try t.expect(std.mem.indexOf(u8, state.?, "\"enabled\":false") != null);

    const shell = try dispatch(testContext(t.allocator), "__zilt.shell", "{\"action\":\"openUrl\",\"url\":\"https://example.com\"}");
    defer t.allocator.free(shell.?);
    try t.expectEqualStrings("true", shell.?);
}
