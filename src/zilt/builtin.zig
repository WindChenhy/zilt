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
    zoom: ?f64 = null,
    download_id: ?u64 = null,
    tag: ?[]const u8 = null,
    group: ?[]const u8 = null,
    progress: ?f64 = null,
    progress_status: ?[]const u8 = null,
    actions: ?[]const ActionArg = null,
    input: ?InputArg = null,
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
    return error.UnknownBuiltin;
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
        };
        if (a.window_id) |_| opts.parent = a.window_id;
        const id = spawn(ctx.backend, opts);
        return if (id) |n|
            std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{n})
        else
            ctx.allocator.dupe(u8, "{\"id\":null}");
    }
    const f = ctx.window_fn orelse return error.WindowNotAvailable;
    const cmd = try windowCmdFromArgs(a, ctx.window_id);
    const target = a.window_id orelse ctx.window_id;
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
