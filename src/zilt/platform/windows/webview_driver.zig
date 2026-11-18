//! Isolated WebView2 engine (v0.1.9/v0.1.10). No backend/IPC/loader dependencies.
//! attach/action/cancel/dispatchDeferred/destroy must run on the owning COM STA.
//! destroy revokes handlers and completes pending requests before returning. Late
//! COM callbacks hold detached handler objects, never a borrowed main context.
//!
//! Additional ABI declarations checked against Microsoft.Web.WebView2
//! 1.0.4314.35 WebView2.h supplied with the task. Unused inherited slots are
//! pointer-sized placeholders; offsets are tested below. Existing bindings use
//! .c, which is the Windows COM ABI on x64/ARM64 (not 32-bit stdcall).
const std = @import("std");
const builtin = @import("builtin");
const shared = @import("../../webview.zig");
const wv2 = @import("webview2.zig");
const com = @import("com.zig");
const win32 = @import("win32.zig");
const Allocator = std.mem.Allocator;
const HRESULT = com.HRESULT;
const Token = com.EventRegistrationToken;
const W = win32.LPCWSTR;
const PW = win32.LPWSTR;
const Slot = ?*const anyopaque;
const U = extern struct {
    QueryInterface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) u32,
    Release: *const fn (*anyopaque) callconv(.c) u32,
};
const GetString = *const fn (*anyopaque, *?PW) callconv(.c) HRESULT;
const PutString = *const fn (*anyopaque, W) callconv(.c) HRESULT;
const GetInt = *const fn (*anyopaque, *i32) callconv(.c) HRESULT;
const PutInt = *const fn (*anyopaque, i32) callconv(.c) HRESULT;
const GetId = *const fn (*anyopaque, *u64) callconv(.c) HRESULT;
const GetBytes = *const fn (*anyopaque, *i64) callconv(.c) HRESULT;
const Simple = *const fn (*anyopaque) callconv(.c) HRESULT;
const AddEvent = *const fn (*anyopaque, *anyopaque, *Token) callconv(.c) HRESULT;
const RemoveEvent = *const fn (*anyopaque, Token) callconv(.c) HRESULT;
fn Interface(comptime V: type) type {
    return extern struct { lpVtbl: *const V };
}
const Unknown = Interface(U);

// Header 54997, 55457, 56704, 58855, 67792, 43069 respectively.
const NavigationArgs = Interface(extern struct {
    base: U,
    get_Uri: GetString,
    get_IsUserInitiated: GetInt,
    get_IsRedirected: GetInt,
    get_RequestHeaders: Slot,
    get_Cancel: GetInt,
    put_Cancel: PutInt,
    get_NavigationId: GetId,
});
const NewWindowArgs = Interface(extern struct {
    base: U,
    get_Uri: GetString,
    put_NewWindow: Slot,
    get_NewWindow: Slot,
    put_Handled: PutInt,
    get_Handled: GetInt,
    get_IsUserInitiated: GetInt,
    GetDeferral: Slot,
    get_WindowFeatures: Slot,
});
const PermissionArgs = Interface(extern struct {
    base: U,
    get_Uri: GetString,
    get_PermissionKind: GetInt,
    get_IsUserInitiated: GetInt,
    get_State: GetInt,
    put_State: PutInt,
    GetDeferral: *const fn (*anyopaque, *?*Deferral) callconv(.c) HRESULT,
});
const ProcessArgs = Interface(extern struct { base: U, get_ProcessFailedKind: GetInt });
const SourceArgs = Interface(extern struct { base: U, get_IsNewDocument: GetInt });
const Deferral = Interface(extern struct { base: U, Complete: Simple });
// Header 43511: INT64 byte counts (not unsigned); unknown total is -1.
const DownloadOperation = Interface(extern struct {
    base: U,
    add_BytesReceivedChanged: AddEvent,
    remove_BytesReceivedChanged: RemoveEvent,
    add_EstimatedEndTimeChanged: AddEvent,
    remove_EstimatedEndTimeChanged: RemoveEvent,
    add_StateChanged: AddEvent,
    remove_StateChanged: RemoveEvent,
    get_Uri: GetString,
    get_ContentDisposition: GetString,
    get_MimeType: GetString,
    get_TotalBytesToReceive: GetBytes,
    get_BytesReceived: GetBytes,
    get_EstimatedEndTime: GetString,
    get_ResultFilePath: GetString,
    get_State: GetInt,
    get_InterruptReason: GetInt,
    Cancel: Simple,
    Pause: Simple,
    Resume: Simple,
    get_CanResume: GetInt,
});
// Header 44051.
const DownloadArgs = Interface(extern struct {
    base: U,
    get_DownloadOperation: *const fn (*anyopaque, *?*DownloadOperation) callconv(.c) HRESULT,
    get_Cancel: GetInt,
    put_Cancel: PutInt,
    get_ResultFilePath: GetString,
    put_ResultFilePath: PutString,
    get_Handled: GetInt,
    put_Handled: PutInt,
    GetDeferral: Slot,
});
// Header 5334/6146/6907: 61 base + 7 (_2) + 5 (_3) + 2 frame slots.
const WebView4 = Interface(extern struct {
    base: [75]Slot,
    add_DownloadStarting: AddEvent,
    remove_DownloadStarting: RemoveEvent,
});
const iid_webview4: com.GUID = .parse("20d02d59-6df2-42dc-bd06-f98a694b1302");
// Header 64491: 21 Settings slots, then user agent get/put.
const Settings2 = Interface(extern struct { base: [21]Slot, get_UserAgent: GetString, put_UserAgent: PutString });
const iid_settings2: com.GUID = .parse("ee9a0f68-f46c-4e32-ac23-ef8cac224d2a");
// Header 18395. Inherited slot counts through _15:
// 61+7+5+4+2+1+1+7+9+2+3+3+1+3+4 = 113.
const WebView16 = Interface(extern struct { base: [113]Slot, Print: Slot, ShowPrintUI: PutInt, PrintToPdfStream: Slot });
const iid_webview16: com.GUID = .parse("0eb34dc9-9f91-41e1-8639-95cd5943906b");
const iid_cdp: com.GUID = .parse("5c4889f0-5ef6-4c5a-952c-d8f1b92d0574");

pub const Callbacks = struct {
    /// All strings are borrowed until return. Copy before queuing work.
    emit: *const fn (context: *anyopaque, name: []const u8, payload_json: []const u8) void,
    navigation: *const fn (context: *anyopaque, url: []const u8) shared.NavigationPolicy,
    new_window: *const fn (context: *anyopaque, url: []const u8) void,
    /// Main performs its approved external-URL opening here; policy is already set.
    external: *const fn (context: *anyopaque, url: []const u8) void,
    /// Enqueue a UI message, then call dispatchDeferred() in a later message-loop
    /// turn. NEVER call dispatchDeferred inline. Ignore queued wakes after destroy.
    schedule: *const fn (context: *anyopaque) void,
    /// Called by dispatchDeferred OUTSIDE the WebView callback. Main may destroy
    /// this driver and rebuild the environment/controller here.
    recover: *const fn (context: *anyopaque) void,
};

pub fn attach(alloc: Allocator, webview: *wv2.ICoreWebView2, controller: ?*wv2.ICoreWebView2Controller, options: shared.Options, context: *anyopaque, callbacks: Callbacks) !*Driver {
    // v0.3.12 A11：controller 可为 null（CompositionController 模式——CC 不实现
    // Controller；bounds/visibility/zoom 由 DComp 视觉树接管，相关请求降级）
    if (@sizeOf(usize) != 8) @compileError("WebView2 base bindings require 64-bit Windows");
    try validateOrigin(options.origin);
    if (options.downloads.save_directory) |dir| try validateDirectory(dir);
    const d = try alloc.create(Driver);
    d.* = .{ .allocator = alloc, .arena = std.heap.ArenaAllocator.init(alloc), .webview = webview, .controller = controller, .options = options, .context = context, .callbacks = callbacks };
    retain(webview);
    if (controller) |c| retain(c);
    errdefer d.destroy();
    const a = d.arena.allocator();
    d.options.origin = try a.dupe(u8, options.origin);
    if (options.settings.user_agent) |s| d.options.settings.user_agent = try a.dupe(u8, s);
    if (options.downloads.save_directory) |s| d.options.downloads.save_directory = try a.dupe(u8, s);
    try d.applySettings();
    d.webview4 = try query(WebView4, webview, &iid_webview4);
    inline for ([_]Kind{ .navigation, .source, .completed, .new_window, .permission, .process, .download }) |kind| {
        const h = try Handler.create(alloc, d, kind, 0);
        const index = @backingInt(kind);
        d.events[index] = .{ .handler = h };
        var token: Token = undefined;
        const hr = switch (kind) {
            .navigation => webview.lpVtbl.add_NavigationStarting(webview, &h.iface, &token),
            .source => webview.lpVtbl.add_SourceChanged(webview, &h.iface, &token),
            .completed => webview.lpVtbl.add_NavigationCompleted(webview, &h.iface, &token),
            .new_window => webview.lpVtbl.add_NewWindowRequested(webview, &h.iface, &token),
            .permission => webview.lpVtbl.add_PermissionRequested(webview, &h.iface, &token),
            .process => webview.lpVtbl.add_ProcessFailed(webview, &h.iface, &token),
            .download => d.webview4.?.lpVtbl.add_DownloadStarting(d.webview4.?, &h.iface, &token),
            else => unreachable,
        };
        try check(hr);
        d.events[index].?.token = token;
    }
    return d;
}

pub const Driver = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    webview: *wv2.ICoreWebView2,
    controller: ?*wv2.ICoreWebView2Controller,
    webview4: ?*WebView4 = null,
    options: shared.Options,
    context: *anyopaque,
    callbacks: Callbacks,
    alive: bool = true,
    refs: usize = 1,
    events: [7]?Subscription = @splat(null),
    pending: ?*Pending = null,
    downloads: ?*Download = null,
    next_download_id: u64 = 1,
    permissions: ?*PermissionPrompt = null,
    wake_pending: bool = false,
    reload_pending: bool = false,
    recover_pending: bool = false,
    dispatching: bool = false,
    callback_depth: usize = 0,

    fn pin(self: *Driver) void {
        self.refs += 1;
    }
    fn unpin(self: *Driver) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.webview4) |w| release(w);
        if (self.controller) |c| release(c);
        release(self.webview);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Call before controller.Close() and before freeing main/completion contexts.
    /// Do not use this pointer again after destroy returns.
    pub fn destroy(self: *Driver) void {
        if (!self.alive) return;
        self.alive = false;
        // Detach ALL handlers before any remove_ call can reenter COM.
        for (&self.events) |*s| if (s.*) |sub| {
            sub.handler.driver = null;
        };
        for (&self.events, 0..) |*s, i| {
            if (s.*) |sub| {
                if (sub.token) |token| {
                    const w = self.webview;
                    _ = switch (@as(Kind, @fromBackingInt(@intCast(i)))) {
                        .navigation => w.lpVtbl.remove_NavigationStarting(w, token),
                        .source => w.lpVtbl.remove_SourceChanged(w, token),
                        .completed => w.lpVtbl.remove_NavigationCompleted(w, token),
                        .new_window => w.lpVtbl.remove_NewWindowRequested(w, token),
                        .permission => w.lpVtbl.remove_PermissionRequested(w, token),
                        .process => w.lpVtbl.remove_ProcessFailed(w, token),
                        .download => self.webview4.?.lpVtbl.remove_DownloadStarting(self.webview4.?, token),
                        else => unreachable,
                    };
                }
                sub.handler.drop();
                s.* = null;
            }
        }
        while (self.pending) |p| p.finish(error.DriverDestroyed);
        while (self.permissions) |p| {
            self.permissions = p.next;
            p.finish(false);
        }
        while (self.downloads) |d| self.removeDownload(d, true);
        self.unpin();
    }

    fn applySettings(self: *Driver) !void {
        var settings: ?*wv2.ICoreWebView2Settings = null;
        try check(self.webview.lpVtbl.get_Settings(self.webview, &settings));
        const s = settings orelse return error.WebViewCallFailed;
        defer release(s);
        const o = self.options.settings;
        const pairs = .{
            .{ "put_AreDevToolsEnabled", o.devtools },
            .{ "put_AreDefaultContextMenusEnabled", o.context_menus },
            .{ "put_IsStatusBarEnabled", o.status_bar },
            .{ "put_IsZoomControlEnabled", o.zoom_controls },
            .{ "put_IsBuiltInErrorPageEnabled", o.built_in_error_page },
            .{ "put_AreDefaultScriptDialogsEnabled", o.script_dialogs },
            .{ "put_AreHostObjectsAllowed", o.host_objects },
        };
        inline for (pairs) |pair| try check(@field(s.lpVtbl, pair[0])(s, @intFromBool(pair[1])));
        if (o.user_agent) |ua| {
            const s2 = try query(Settings2, s, &iid_settings2);
            defer release(s2);
            const wide = try wideZ(self.allocator, ua);
            defer self.allocator.free(wide);
            try check(s2.lpVtbl.put_UserAgent(s2, wide.ptr));
        }
        // v0.3.2：Profile6 autofill / password autosave（Profile 级设置）。
        // Profile6 需 WebView2 运行时 1.0.1661+——QI 失败仅跳过，不视为致命
        // （与 transparent 依赖 Controller2 的降级策略一致）。
        if (wv2.ICoreWebView2_4.fromWebView(self.webview)) |wv4| {
            defer wv4.release();
            const gp = wv4.getProfile();
            if (com.succeeded(gp.hr)) {
                if (gp.profile) |profile| {
                    if (profile.asProfile6()) |p6| {
                        defer p6.release();
                        _ = p6.putGeneralAutofill(o.autofill);
                        _ = p6.putPasswordAutosave(o.password_autosave);
                    }
                }
            }
        }
    }

    fn emit(self: *Driver, name: []const u8, value: anytype) void {
        if (!self.alive) return;
        const json = std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch return;
        defer self.allocator.free(json);
        self.callbacks.emit(self.context, name, json);
    }
    fn report(self: *Driver, err: anyerror) void {
        self.emit(shared.Event.action_failed, .{ .@"error" = @errorName(err) });
    }
    fn wake(self: *Driver) void {
        if (!self.alive or self.wake_pending) return;
        self.wake_pending = true;
        self.callbacks.schedule(self.context);
    }

    /// Run from main's posted UI message. Guards against accidental inline use.
    pub fn dispatchDeferred(self: *Driver) !void {
        if (!self.alive) return error.DriverDestroyed;
        if (self.callback_depth != 0 or self.dispatching) return error.ReentrantDispatch;
        self.pin();
        defer self.unpin();
        self.dispatching = true;
        defer self.dispatching = false;
        self.wake_pending = false;
        if (self.recover_pending) {
            self.recover_pending = false;
            self.reload_pending = false;
            self.callbacks.recover(self.context);
            if (!self.alive) return;
        }
        if (self.reload_pending) {
            self.reload_pending = false;
            check(self.webview.lpVtbl.Reload(self.webview)) catch |err| self.report(err);
            if (!self.alive) return;
        }
        while (self.alive) {
            const p = self.permissions orelse break;
            self.permissions = p.next;
            // p owns args/deferral while the native modal loop runs. destroy()
            // may occur in that loop, so never call main afterwards unless alive.
            var hwnd: win32.HWND = null;
            var allowed = false;
            if (self.controller != null and com.succeeded(self.controller.?.lpVtbl.get_ParentWindow(self.controller.?, &hwnd)) and hwnd != null) {
                allowed = win32.MessageBoxW(hwnd, p.message.ptr, std.unicode.utf8ToUtf16LeStringLiteral("Website permission"), win32.MB_YESNO | 0x20 | 0x100) == win32.IDYES;
            }
            allowed = allowed and self.alive;
            p.finish(allowed);
        }
    }

    /// With completion, all failures are delivered exactly once to it and this
    /// returns success. Without completion, startup failures are returned and
    /// later asynchronous failures emit webview.action_failed.
    pub fn action(self: *Driver, request: shared.Request, completion: ?shared.Completion) !void {
        self.pin();
        defer self.unpin();
        // Register even synchronous requests BEFORE calling native code. A native
        // call can emit an event whose host callback destroys the driver/context.
        const p = Pending.create(self, .{}, completion) catch |err| {
            if (completion) |c| { c.callback(c.context, err); return; }
            return err;
        };
        defer p.drop(); // creator ref also protects synchronous COM completions
        const result = self.perform(request, p) catch |err| {
            p.silent = true; // without completion, startup errors use !void only
            p.finish(err);
            if (completion != null) return;
            return err;
        };
        if (result) |json| {
            defer self.allocator.free(json);
            p.finish(json); // no-op if teardown already completed this request
        }
    }
    fn perform(self: *Driver, request: shared.Request, pending: *Pending) !?[]u8 {
        if (!self.alive) return error.DriverDestroyed;
        const w = self.webview;
        switch (request) {
            .reload => try check(w.lpVtbl.Reload(w)),
            .stop => try check(w.lpVtbl.Stop(w)),
            .zoom => |factor| {
                if (!std.math.isFinite(factor) or factor <= 0) return error.InvalidZoom;
                const c = self.controller orelse return error.CompositionModeNoController;
                try check(c.lpVtbl.put_ZoomFactor(c, factor));
            },
            .get_zoom => {
                const c = self.controller orelse return error.CompositionModeNoController;
                var factor: f64 = 0;
                try check(c.lpVtbl.get_ZoomFactor(c, &factor));
                return try std.json.Stringify.valueAlloc(self.allocator, .{ .factor = factor }, .{});
            },
            .history => {
                var back: i32 = 0;
                var forward: i32 = 0;
                try check(w.lpVtbl.get_CanGoBack(w, &back));
                try check(w.lpVtbl.get_CanGoForward(w, &forward));
                return try std.json.Stringify.valueAlloc(self.allocator, .{ .can_go_back = back != 0, .can_go_forward = forward != 0 }, .{});
            },
            .back => try check(w.lpVtbl.GoBack(w)),
            .forward => try check(w.lpVtbl.GoForward(w)),
            .devtools => {
                if (!self.options.settings.devtools) return error.DevToolsDisabled;
                try check(w.lpVtbl.OpenDevToolsWindow(w));
            },
            .print => |kind| {
                const w16 = try query(WebView16, w, &iid_webview16);
                defer release(w16);
                try check(w16.lpVtbl.ShowPrintUI(w16, if (kind == .browser) 0 else 1));
            },
            .cancel_download => |id| try self.cancel(id),
            // v0.1.24：运行时改 UA（Settings2.put_UserAgent；空串恢复默认）
            .set_user_agent => |ua| {
                var settings: ?*wv2.ICoreWebView2Settings = null;
                try check(w.lpVtbl.get_Settings(w, &settings));
                const s = settings orelse return error.WebViewCallFailed;
                defer release(s);
                const s2 = try query(Settings2, s, &iid_settings2);
                defer release(s2);
                const wide = try wideZ(self.allocator, ua);
                defer self.allocator.free(wide);
                try check(s2.lpVtbl.put_UserAgent(s2, wide.ptr));
            },
            // v0.1.23：CDP 是异步的——发起后立刻以 "{}" 完成本次请求，真正的结果
            // 由 CdpHandler 以 webviewCdp 事件送回（rid 匹配）。
            .cdp => |c| {
                const h = try CdpHandler.create(self.allocator, self, c.rid);
                defer h.dropRef();
                const method = try wideZ(self.allocator, c.method);
                defer self.allocator.free(method);
                const params = try wideZ(self.allocator, c.params);
                defer self.allocator.free(params);
                try check(w.lpVtbl.CallDevToolsProtocolMethod(w, method.ptr, params.ptr, @ptrCast(&h.iface)));
                return try self.allocator.dupe(u8, "{}");
            },
            .eval, .cookies, .clear_storage => {
                pending.plan = try encode(self.allocator, request, self.options.origin);
                if (pending.plan.count == 0) return try self.allocator.dupe(u8, "null");
                try pending.issue();
                return null;
            },
        }
        return try self.allocator.dupe(u8, "null");
    }

    pub fn cancel(self: *Driver, id: u64) !void {
        if (!self.alive) return error.DriverDestroyed;
        self.pin();
        defer self.unpin();
        const d = self.findDownload(id) orelse return error.UnknownDownload;
        // Cancel may synchronously deliver StateChanged and remove the entry.
        const op = d.operation;
        retain(op);
        defer release(op);
        try check(op.lpVtbl.Cancel(op));
    }

    fn onEvent(self: *Driver, kind: Kind, id: u64, args: ?*anyopaque) !void {
        if (kind == .bytes or kind == .state) {
            try self.downloadChanged(id, kind == .state);
            return;
        }
        const raw = args orelse return error.MissingEventArgs;
        switch (kind) {
            .navigation => {
                const a: *NavigationArgs = @ptrCast(@alignCast(raw));
                // Fail closed if URL decoding or host policy fails/tears down.
                try check(a.lpVtbl.put_Cancel(a, 1));
                const url = try getString(self.allocator, a, a.lpVtbl.get_Uri);
                defer self.allocator.free(url);
                var nav_id: u64 = 0;
                var redirected: i32 = 0;
                try check(a.lpVtbl.get_NavigationId(a, &nav_id));
                try check(a.lpVtbl.get_IsRedirected(a, &redirected));
                const policy = self.callbacks.navigation(self.context, url);
                if (!self.alive) return;
                try check(a.lpVtbl.put_Cancel(a, @intFromBool(policy != .allow)));
                self.emit(shared.Event.navigation_starting, .{ .url = url, .id = nav_id, .redirected = redirected != 0, .policy = @tagName(policy) });
                if (self.alive and policy == .external) self.callbacks.external(self.context, url);
            },
            .source => {
                const a: *SourceArgs = @ptrCast(@alignCast(raw));
                var is_new: i32 = 0;
                try check(a.lpVtbl.get_IsNewDocument(a, &is_new));
                var wide: ?PW = null;
                try check(self.webview.lpVtbl.get_Source(self.webview, &wide));
                defer wv2.freeCoString(wide);
                const url = try fromWide(self.allocator, wide);
                defer self.allocator.free(url);
                self.emit(shared.Event.source_changed, .{ .url = url, .is_new_document = is_new != 0 });
            },
            .completed => {
                const a: *wv2.ICoreWebView2NavigationCompletedEventArgs = @ptrCast(@alignCast(raw));
                var success: i32 = 0;
                var status: u32 = 0;
                var nav_id: u64 = 0;
                try check(a.lpVtbl.get_IsSuccess(a, &success));
                try check(a.lpVtbl.get_WebErrorStatus(a, &status));
                try check(a.lpVtbl.get_NavigationId(a, &nav_id));
                self.emit(shared.Event.navigation_completed, .{ .id = nav_id, .success = success != 0, .web_error_status = status });
            },
            .new_window => {
                const a: *NewWindowArgs = @ptrCast(@alignCast(raw));
                try check(a.lpVtbl.put_Handled(a, 1));
                const url = try getString(self.allocator, a, a.lpVtbl.get_Uri);
                defer self.allocator.free(url);
                const policy = self.options.new_window;
                self.emit(shared.Event.new_window, .{ .url = url, .policy = @tagName(policy) });
                if (!self.alive) return;
                switch (policy) {
                    .deny => {},
                    .external => self.callbacks.external(self.context, url),
                    .new_window => self.callbacks.new_window(self.context, url),
                }
            },
            .permission => try self.permissionRequested(@ptrCast(@alignCast(raw))),
            .process => {
                const a: *ProcessArgs = @ptrCast(@alignCast(raw));
                var failed_kind: i32 = -1;
                try check(a.lpVtbl.get_ProcessFailedKind(a, &failed_kind));
                self.emit(shared.Event.process_failed, .{ .kind = failed_kind });
                if (!self.alive) return;
                if (failed_kind == 0) self.recover_pending = true;
                if ((failed_kind == 1 or failed_kind == 2) and self.options.recover_renderer) self.reload_pending = true;
                if (self.recover_pending or self.reload_pending) self.wake();
            },
            .download => try self.downloadStarting(@ptrCast(@alignCast(raw))),
            else => unreachable,
        }
    }

    fn permissionRequested(self: *Driver, a: *PermissionArgs) !void {
        try check(a.lpVtbl.put_State(a, 2)); // DENY, including failure paths.
        var native_kind: i32 = 0;
        try check(a.lpVtbl.get_PermissionKind(a, &native_kind));
        const kind = permissionKind(native_kind);
        const policy = self.options.permissions.policy(kind);
        const url = try getString(self.allocator, a, a.lpVtbl.get_Uri);
        defer self.allocator.free(url);
        if (policy == .ask) {
            const p = try PermissionPrompt.create(self.allocator, a, kind, url);
            p.next = self.permissions;
            self.permissions = p;
        } else {
            try check(a.lpVtbl.put_State(a, if (policy == .allow) 1 else 2));
        }
        self.emit(shared.Event.permission, .{ .url = url, .kind = @tagName(kind), .policy = @tagName(policy) });
        if (policy == .ask and self.alive) self.wake();
    }

    fn findDownload(self: *Driver, id: u64) ?*Download {
        var cursor = self.downloads;
        while (cursor) |d| : (cursor = d.next) if (d.id == id) return d;
        return null;
    }
    fn removeDownload(self: *Driver, d: *Download, cancel_operation: bool) void {
        var link = &self.downloads;
        while (link.*) |entry| {
            if (entry == d) {
                link.* = d.next;
                break;
            }
            link = &entry.next;
        }
        d.bytes.handler.driver = null;
        d.state.handler.driver = null;
        if (d.bytes.token) |t| _ = d.operation.lpVtbl.remove_BytesReceivedChanged(d.operation, t);
        if (d.state.token) |t| _ = d.operation.lpVtbl.remove_StateChanged(d.operation, t);
        if (cancel_operation) _ = d.operation.lpVtbl.Cancel(d.operation);
        d.bytes.handler.drop();
        d.state.handler.drop();
        release(d.operation);
        self.allocator.destroy(d);
    }
    fn downloadStarting(self: *Driver, a: *DownloadArgs) !void {
        try check(a.lpVtbl.put_Cancel(a, 1));
        if (!self.options.downloads.enabled) return;
        var operation: ?*DownloadOperation = null;
        try check(a.lpVtbl.get_DownloadOperation(a, &operation));
        const op = operation orelse return error.WebViewCallFailed;
        // Ownership transfers to the registry only after all allocations succeed.
        var transferred = false;
        defer if (!transferred) release(op);
        const id = self.next_download_id;
        self.next_download_id = std.math.add(u64, id, 1) catch return error.DownloadIdExhausted;
        const suggested = try getString(self.allocator, a, a.lpVtbl.get_ResultFilePath);
        defer self.allocator.free(suggested);
        const path = if (self.options.downloads.save_directory) |dir|
            try downloadPath(self.allocator, dir, suggested, id)
        else
            try self.allocator.dupe(u8, suggested);
        defer self.allocator.free(path);
        if (self.options.downloads.save_directory != null) {
            const pw = try wideZ(self.allocator, path);
            defer self.allocator.free(pw);
            // Do not truncate a user's existing file. The caller can retry with
            // another directory/name after a collision; no silent overwrite.
            if (win32.GetFileAttributesW(pw.ptr) != 0xFFFFFFFF) return error.DownloadDestinationExists;
            try check(a.lpVtbl.put_ResultFilePath(a, pw.ptr));
        }
        const bytes = try Handler.create(self.allocator, self, .bytes, id);
        errdefer if (!transferred) bytes.drop();
        const state = try Handler.create(self.allocator, self, .state, id);
        errdefer if (!transferred) state.drop();
        const d = try self.allocator.create(Download);
        d.* = .{ .id = id, .operation = op, .bytes = .{ .handler = bytes }, .state = .{ .handler = state }, .next = self.downloads };
        self.downloads = d;
        transferred = true;
        errdefer if (self.findDownload(id)) |entry| self.removeDownload(entry, true);
        var token: Token = undefined;
        try check(op.lpVtbl.add_BytesReceivedChanged(op, &bytes.iface, &token));
        d.bytes.token = token;
        try check(op.lpVtbl.add_StateChanged(op, &state.iface, &token));
        d.state.token = token;
        try check(a.lpVtbl.put_Handled(a, @intFromBool(!self.options.downloads.show_dialog)));
        try check(a.lpVtbl.put_Cancel(a, 0));
        const url = try getString(self.allocator, op, op.lpVtbl.get_Uri);
        defer self.allocator.free(url);
        self.emit(shared.Event.download_started, .{ .id = id, .url = url, .path = path });
        if (self.alive) try self.downloadChanged(id, true);
    }
    fn downloadChanged(self: *Driver, id: u64, check_state: bool) !void {
        const d = self.findDownload(id) orelse return;
        var received: i64 = 0;
        var total: i64 = -1;
        var state: i32 = 0;
        var reason: i32 = 0;
        const op = d.operation;
        try check(op.lpVtbl.get_BytesReceived(op, &received));
        try check(op.lpVtbl.get_TotalBytesToReceive(op, &total));
        if (check_state) try check(op.lpVtbl.get_State(op, &state));
        if (state == 1) try check(op.lpVtbl.get_InterruptReason(op, &reason));
        const event = switch (state) {
            1 => shared.Event.download_failed,
            2 => shared.Event.download_completed,
            else => shared.Event.download_progress,
        };
        // Remove before calling main: cancel(id) after a terminal event is invalid.
        if (state == 1 or state == 2) self.removeDownload(d, false);
        self.emit(event, .{ .id = id, .received = received, .total = total, .interrupt_reason = reason });
    }
};

const Kind = enum(u8) { navigation, source, completed, new_window, permission, process, download, bytes, state };
const Subscription = struct { handler: *Handler, token: ?Token = null };
const Download = struct { id: u64, operation: *DownloadOperation, bytes: Subscription, state: Subscription, next: ?*Download };
const EventVTable = extern struct {
    base: U,
    Invoke: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
};
const Handler = struct {
    iface: Interface(EventVTable) = .{ .lpVtbl = &vtable },
    allocator: Allocator,
    refs: u32 = 1,
    driver: ?*Driver,
    kind: Kind,
    id: u64,
    const vtable: EventVTable = .{ .base = .{ .QueryInterface = qi, .AddRef = addRef, .Release = subRef }, .Invoke = invoke };
    // WebView2.h 4218,4648,4132,4304,4390,4476,7615,43793,43965.
    const iids = [_]com.GUID{
        .parse("9adbe429-f36d-432b-9ddc-f8881fbd76e3"),
        .parse("3c067f9f-5388-4772-8b48-79f7ef1ab37c"),
        .parse("d33a35bf-1c49-4f98-93ab-006e0533fe1c"),
        .parse("d4c185fe-c81c-4989-97af-2d3fa7ab5651"),
        .parse("15e1c6a3-c72a-4df3-91d7-d097fbec6bfd"),
        .parse("79e0aea4-990b-42d9-aa1d-0fcc2e5bc7f1"),
        .parse("efedc989-c396-41ca-83f7-07f845a55724"),
        .parse("828e8ab6-d94c-4264-9cef-5217170d6251"),
        .parse("81336594-7ede-4ba9-bf71-acf0a95b58dd"),
    };
    fn create(a: Allocator, d: *Driver, kind: Kind, id: u64) !*Handler {
        const h = try a.create(Handler);
        h.* = .{ .allocator = a, .driver = d, .kind = kind, .id = id };
        return h;
    }
    fn from(raw: *anyopaque) *Handler {
        const iface: *Interface(EventVTable) = @ptrCast(@alignCast(raw));
        return @fieldParentPtr("iface", iface);
    }
    fn qi(raw: *anyopaque, iid: *const com.GUID, out: *?*anyopaque) callconv(.c) HRESULT {
        out.* = null;
        const h = from(raw);
        if (!iid.eql(com.IID_IUnknown) and !iid.eql(iids[@backingInt(h.kind)])) return com.E_NOINTERFACE;
        out.* = raw;
        _ = addRef(raw);
        return com.S_OK;
    }
    fn addRef(raw: *anyopaque) callconv(.c) u32 {
        return @atomicRmw(u32, &from(raw).refs, .Add, 1, .monotonic) + 1;
    }
    fn subRef(raw: *anyopaque) callconv(.c) u32 {
        const h = from(raw);
        const n = @atomicRmw(u32, &h.refs, .Sub, 1, .acq_rel) - 1;
        if (n == 0) h.allocator.destroy(h);
        return n;
    }
    fn drop(h: *Handler) void {
        _ = subRef(&h.iface);
    }
    fn invoke(raw: *anyopaque, _: ?*anyopaque, args: ?*anyopaque) callconv(.c) HRESULT {
        const h = from(raw);
        _ = addRef(raw);
        defer h.drop();
        const d = h.driver orelse return com.S_OK;
        if (!d.alive) return com.S_OK;
        d.pin();
        defer d.unpin();
        d.callback_depth += 1;
        defer d.callback_depth -= 1;
        d.onEvent(h.kind, h.id, args) catch |err| d.report(err);
        return com.S_OK;
    }
};

/// v0.1.23：ICoreWebView2CallDevToolsProtocolMethodCompletedHandler。
/// 结果以 `webviewCdp` 事件回主机（前端按 rid 匹配 Promise）。
const CdpHandler = struct {
    iface: Interface(VTable) = .{ .lpVtbl = &vtable },
    allocator: Allocator,
    refs: u32 = 1,
    driver: ?*Driver,
    rid: i64,

    const VTable = extern struct {
        base: U,
        Invoke: *const fn (*anyopaque, HRESULT, ?W) callconv(.c) HRESULT,
    };
    const vtable = VTable{
        .base = .{ .QueryInterface = qi, .AddRef = addRef, .Release = subRef },
        .Invoke = invoke,
    };

    fn create(a: Allocator, d: *Driver, rid: i64) !*CdpHandler {
        const h = try a.create(CdpHandler);
        h.* = .{ .allocator = a, .driver = d, .rid = rid };
        return h;
    }
    fn from(raw: *anyopaque) *CdpHandler {
        const iface: *Interface(VTable) = @ptrCast(@alignCast(raw));
        return @fieldParentPtr("iface", iface);
    }
    fn qi(raw: *anyopaque, iid: *const com.GUID, out: *?*anyopaque) callconv(.c) HRESULT {
        out.* = null;
        if (!iid.eql(com.IID_IUnknown) and !iid.eql(wv2.IID_CallDevToolsProtocolMethodCompletedHandler)) return com.E_NOINTERFACE;
        out.* = raw;
        _ = addRef(raw);
        return com.S_OK;
    }
    fn addRef(raw: *anyopaque) callconv(.c) u32 {
        return @atomicRmw(u32, &from(raw).refs, .Add, 1, .monotonic) + 1;
    }
    fn subRef(raw: *anyopaque) callconv(.c) u32 {
        const h = from(raw);
        const n = @atomicRmw(u32, &h.refs, .Sub, 1, .acq_rel) - 1;
        if (n == 0) h.allocator.destroy(h);
        return n;
    }
    fn dropRef(h: *CdpHandler) void {
        _ = subRef(&h.iface);
    }

    fn invoke(raw: *anyopaque, hr: HRESULT, wide: ?W) callconv(.c) HRESULT {
        const h = from(raw);
        _ = addRef(raw);
        defer h.dropRef();
        const d = h.driver orelse return com.S_OK;
        if (!d.alive) return com.S_OK;
        d.pin();
        defer d.unpin();
        d.callback_depth += 1;
        defer d.callback_depth -= 1;
        const a = d.allocator;
        const payload = if (com.failed(hr) or wide == null)
            std.fmt.allocPrint(a, "{{\"rid\":{d},\"ok\":false,\"error\":\"CdpFailed\"}}", .{h.rid}) catch return com.S_OK
        else blk: {
            const json = std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(wide.?)) catch return com.S_OK;
            defer a.free(json);
            break :blk std.fmt.allocPrint(a, "{{\"rid\":{d},\"ok\":true,\"result\":{s}}}", .{ h.rid, json }) catch return com.S_OK;
        };
        defer a.free(payload);
        d.callbacks.emit(d.context, "webviewCdp", payload);
        return com.S_OK;
    }
};

const PermissionPrompt = struct {    allocator: Allocator,
    args: *PermissionArgs,
    deferral: *Deferral,
    message: [:0]u16,
    next: ?*PermissionPrompt = null,
    fn create(a: Allocator, args: *PermissionArgs, kind: shared.PermissionKind, url: []const u8) !*PermissionPrompt {
        const message = try std.fmt.allocPrint(a, "Allow {s}?\n\nRequesting page:\n{s}", .{ @tagName(kind), url });
        defer a.free(message);
        const wide = try wideZ(a, message);
        errdefer a.free(wide);
        const p = try a.create(PermissionPrompt);
        errdefer a.destroy(p);
        var deferral: ?*Deferral = null;
        try check(args.lpVtbl.GetDeferral(args, &deferral));
        const def = deferral orelse return error.WebViewCallFailed;
        retain(args);
        p.* = .{ .allocator = a, .args = args, .deferral = def, .message = wide };
        return p;
    }
    fn finish(p: *PermissionPrompt, allowed: bool) void {
        _ = p.args.lpVtbl.put_State(p.args, if (allowed) 1 else 2);
        _ = p.deferral.lpVtbl.Complete(p.deferral);
        release(p.deferral);
        release(p.args);
        p.allocator.free(p.message);
        p.allocator.destroy(p);
    }
};

const ResultKind = enum { raw, eval, cookie_set };
const Command = struct { method: []const u8, params: []u8 };
const Plan = struct {
    commands: [2]Command = undefined,
    count: usize = 0,
    result_kind: ResultKind = .raw,
    fn add(self: *Plan, a: Allocator, method: []const u8, params: anytype) !void {
        self.commands[self.count] = .{ .method = method, .params = try std.json.Stringify.valueAlloc(a, params, .{ .emit_null_optional_fields = false }) };
        self.count += 1;
    }
    fn deinit(self: *Plan, a: Allocator) void {
        for (self.commands[0..self.count]) |command| a.free(command.params);
        self.count = 0;
    }
};

/// All CDP input passes through the JSON encoder; no JS/string interpolation.
fn encode(a: Allocator, request: shared.Request, default_origin: []const u8) !Plan {
    var plan: Plan = .{};
    errdefer plan.deinit(a);
    switch (request) {
        .eval => |e| {
            if (e.timeout_ms == 0) return error.InvalidTimeout;
            plan.result_kind = .eval;
            try plan.add(a, "Runtime.evaluate", .{ .expression = e.script, .awaitPromise = true, .returnByValue = true, .timeout = e.timeout_ms, .userGesture = false });
        },
        .cookies => |cookies| switch (cookies) {
            .get => |get| try plan.add(a, "Network.getCookies", .{ .urls = [_][]const u8{get.url orelse default_origin} }),
            .set => |cookie| {
                if (cookie.expires) |expires| if (!std.math.isFinite(expires)) return error.InvalidCookie;
                plan.result_kind = .cookie_set;
                try plan.add(a, "Network.setCookie", .{
                    .name = cookie.name,
                    .value = cookie.value,
                    .url = cookie.url orelse default_origin,
                    .domain = cookie.domain,
                    .path = cookie.path,
                    .secure = cookie.secure,
                    .httpOnly = cookie.http_only,
                    .sameSite = cookie.same_site,
                    .expires = cookie.expires,
                });
            },
            .delete => |cookie| try plan.add(a, "Network.deleteCookies", .{ .name = cookie.name, .url = cookie.url orelse default_origin, .domain = cookie.domain, .path = cookie.path }),
            .clear => |clear| {
                const origin = clear.origin orelse default_origin;
                try validateOrigin(origin);
                try plan.add(a, "Storage.clearDataForOrigin", .{ .origin = origin, .storageTypes = "cookies" });
            },
        },
        .clear_storage => |clear| {
            const origin = clear.origin orelse default_origin;
            try validateOrigin(origin);
            var types: std.ArrayList(u8) = .empty;
            defer types.deinit(a);
            const pairs = .{
                .{ clear.local_storage, "local_storage" },
                .{ clear.indexed_db, "indexeddb" },
                .{ clear.cache, "cache_storage,service_workers" },
                .{ clear.cookies, "cookies" },
            };
            inline for (pairs) |pair| {
                if (pair[0]) {
                    if (types.items.len != 0) try types.append(a, ',');
                    try types.appendSlice(a, pair[1]);
                }
            }
            if (types.items.len != 0) try plan.add(a, "Storage.clearDataForOrigin", .{ .origin = origin, .storageTypes = types.items });
            // HTTP resource cache is NOT Cache Storage and CDP only offers a
            // profile-wide purge. This second command is intentional/public.
            if (clear.cache) try plan.add(a, "Network.clearBrowserCache", .{});
        },
        else => return error.NotCdpAction,
    }
    return plan;
}

fn decodeResult(a: Allocator, kind: ResultKind, json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCdpResponse;
    const object = parsed.value.object;
    if (object.get("error")) |err| if (err != .null) return error.CdpError;
    if (kind == .eval) {
        if (object.get("exceptionDetails")) |exception| if (exception != .null) return error.JavaScriptException;
        const result = object.get("result") orelse return error.InvalidCdpResponse;
        if (result != .object) return error.InvalidCdpResponse;
        if (result.object.get("value")) |value| return std.json.Stringify.valueAlloc(a, value, .{});
        if (result.object.get("type")) |t| {
            if (t == .string and std.mem.eql(u8, t.string, "undefined")) return a.dupe(u8, "null");
        }
        return error.NonJsonResult;
    }
    if (kind == .cookie_set) {
        if (object.get("success")) |success| {
            if (success != .bool or !success.bool) return error.CookieRejected;
        }
    }
    return a.dupe(u8, json);
}

const CdpVTable = extern struct {
    base: U,
    Invoke: *const fn (*anyopaque, HRESULT, ?W) callconv(.c) HRESULT,
};
const Pending = struct {
    iface: Interface(CdpVTable) = .{ .lpVtbl = &vtable },
    allocator: Allocator,
    refs: u32 = 2, // registry + creator; runtime holds its own AddRef
    driver: ?*Driver,
    completion: ?shared.Completion,
    next: ?*Pending,
    plan: Plan,
    index: usize = 0,
    silent: bool = false,
    const vtable: CdpVTable = .{ .base = .{ .QueryInterface = qi, .AddRef = addRef, .Release = subRef }, .Invoke = invoke };

    fn create(d: *Driver, plan: Plan, completion: ?shared.Completion) !*Pending {
        const p = try d.allocator.create(Pending);
        p.* = .{ .allocator = d.allocator, .driver = d, .completion = completion, .next = d.pending, .plan = plan };
        d.pending = p;
        return p;
    }
    fn from(raw: *anyopaque) *Pending {
        const iface: *Interface(CdpVTable) = @ptrCast(@alignCast(raw));
        return @fieldParentPtr("iface", iface);
    }
    fn qi(raw: *anyopaque, iid: *const com.GUID, out: *?*anyopaque) callconv(.c) HRESULT {
        out.* = null;
        if (!iid.eql(com.IID_IUnknown) and !iid.eql(iid_cdp)) return com.E_NOINTERFACE;
        out.* = raw;
        _ = addRef(raw);
        return com.S_OK;
    }
    fn addRef(raw: *anyopaque) callconv(.c) u32 {
        return @atomicRmw(u32, &from(raw).refs, .Add, 1, .monotonic) + 1;
    }
    fn subRef(raw: *anyopaque) callconv(.c) u32 {
        const p = from(raw);
        const n = @atomicRmw(u32, &p.refs, .Sub, 1, .acq_rel) - 1;
        if (n == 0) {
            p.plan.deinit(p.allocator);
            p.allocator.destroy(p);
        }
        return n;
    }
    fn drop(p: *Pending) void {
        _ = subRef(&p.iface);
    }
    fn issue(p: *Pending) !void {
        const d = p.driver orelse return error.DriverDestroyed;
        const command = p.plan.commands[p.index];
        const method = try wideZ(p.allocator, command.method);
        defer p.allocator.free(method);
        const params = try wideZ(p.allocator, command.params);
        defer p.allocator.free(params);
        try check(d.webview.lpVtbl.CallDevToolsProtocolMethod(d.webview, method.ptr, params.ptr, &p.iface));
    }
    fn finish(p: *Pending, result: anyerror![]const u8) void {
        const d = p.driver orelse return;
        p.driver = null;
        var link = &d.pending;
        while (link.*) |entry| {
            if (entry == p) {
                link.* = p.next;
                break;
            }
            link = &entry.next;
        }
        p.next = null;
        const completion = p.completion;
        p.completion = null; // no retained main context, even on late Invoke
        defer p.drop(); // registry ref
        if (completion) |c| c.callback(c.context, result) else {
            _ = result catch |err| {
                if (!p.silent) d.report(err);
                return;
            };
        }
    }
    fn invoke(raw: *anyopaque, hr: HRESULT, wide: ?W) callconv(.c) HRESULT {
        const p = from(raw);
        _ = addRef(raw);
        defer p.drop();
        const d = p.driver orelse return com.S_OK;
        d.pin();
        defer d.unpin();
        d.callback_depth += 1;
        defer d.callback_depth -= 1;
        p.receive(hr, wide) catch |err| p.finish(err);
        return com.S_OK;
    }
    fn receive(p: *Pending, hr: HRESULT, wide: ?W) !void {
        try check(hr);
        if (wide == null) return error.InvalidCdpResponse;
        const json = try fromWide(p.allocator, wide);
        defer p.allocator.free(json);
        const result = try decodeResult(p.allocator, p.plan.result_kind, json);
        defer p.allocator.free(result);
        if (p.index + 1 < p.plan.count) {
            p.index += 1;
            try p.issue();
        } else p.finish(result);
    }
};

fn check(hr: HRESULT) !void {
    if (com.failed(hr)) return error.WebViewCallFailed;
}
fn retain(ptr: anytype) void {
    const u: *Unknown = @ptrCast(@alignCast(ptr));
    _ = u.lpVtbl.AddRef(u);
}
fn release(ptr: anytype) void {
    const u: *Unknown = @ptrCast(@alignCast(ptr));
    _ = u.lpVtbl.Release(u);
}
fn query(comptime T: type, ptr: anytype, iid: *const com.GUID) !*T {
    const u: *Unknown = @ptrCast(@alignCast(ptr));
    var out: ?*anyopaque = null;
    const hr = u.lpVtbl.QueryInterface(u, iid, &out);
    if (hr == com.E_NOINTERFACE) return error.UnsupportedRuntime;
    try check(hr);
    return @ptrCast(@alignCast(out orelse return error.WebViewCallFailed));
}
fn wideZ(a: Allocator, s: []const u8) ![:0]u16 {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return error.EmbeddedNul;
    return std.unicode.utf8ToUtf16LeAllocZ(a, s);
}
fn fromWide(a: Allocator, s: ?[*:0]const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(a, if (s) |p| std.mem.span(p) else &.{});
}
fn getString(a: Allocator, ptr: *anyopaque, getter: GetString) ![]u8 {
    var s: ?PW = null;
    defer wv2.freeCoString(s);
    try check(getter(ptr, &s));
    return fromWide(a, s);
}
fn permissionKind(native: i32) shared.PermissionKind {
    return switch (native) {
        1 => .microphone,
        2 => .camera,
        3 => .location,
        4 => .notifications,
        6 => .clipboard,
        else => .unknown,
    };
}
fn validateOrigin(origin: []const u8) !void {
    const start: usize = if (std.mem.startsWith(u8, origin, "https://")) 8 else if (std.mem.startsWith(u8, origin, "http://")) 7 else return error.InvalidOrigin;
    if (origin.len <= start or std.mem.indexOfAny(u8, origin[start..], "/?#@\\ \t\r\n\x00") != null) return error.InvalidOrigin;
}
fn validateDirectory(dir: []const u8) !void {
    if (!std.fs.path.isAbsoluteWindows(dir) or std.mem.indexOfScalar(u8, dir, 0) != null) return error.InvalidDownloadDirectory;
}
fn downloadPath(a: Allocator, dir: []const u8, suggested: []const u8, id: u64) ![]u8 {
    try validateDirectory(dir);
    const start = if (std.mem.lastIndexOfAny(u8, suggested, "/\\")) |i| i + 1 else 0;
    const name = suggested[start..];
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidDownloadName;
    const clean = try a.dupe(u8, name);
    defer a.free(clean);
    for (clean) |*c| if (c.* < 32 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", c.*) != null) {
        c.* = '_';
    };
    // Prefix avoids reserved device names and names colliding within this driver.
    const trimmed = std.mem.trimEnd(u8, clean, " .");
    if (trimmed.len == 0) return error.InvalidDownloadName;
    return std.fmt.allocPrint(a, "{s}\\{d}-{s}", .{ std.mem.trimEnd(u8, dir, "/\\"), id, trimmed });
}

fn vtableType(comptime T: type) type {
    return @typeInfo(@FieldType(T, "lpVtbl")).pointer.child;
}
fn expectSlot(comptime T: type, comptime field: []const u8, slot: usize) !void {
    try std.testing.expectEqual(slot * @sizeOf(Slot), @offsetOf(vtableType(T), field));
}
test "SDK ABI slot offsets and GUID bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(HRESULT));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Token));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(com.GUID));
    try expectSlot(NavigationArgs, "put_Cancel", 8);
    try expectSlot(NavigationArgs, "get_NavigationId", 9);
    try expectSlot(NewWindowArgs, "put_Handled", 6);
    try expectSlot(PermissionArgs, "put_State", 7);
    try expectSlot(PermissionArgs, "GetDeferral", 8);
    try expectSlot(DownloadArgs, "get_DownloadOperation", 3);
    try expectSlot(DownloadArgs, "put_ResultFilePath", 7);
    try expectSlot(DownloadOperation, "add_StateChanged", 7);
    try expectSlot(DownloadOperation, "get_TotalBytesToReceive", 12);
    try expectSlot(DownloadOperation, "get_State", 16);
    try expectSlot(DownloadOperation, "Cancel", 18);
    try expectSlot(WebView4, "add_DownloadStarting", 75);
    try expectSlot(WebView4, "remove_DownloadStarting", 76);
    try expectSlot(Settings2, "put_UserAgent", 22);
    try expectSlot(WebView16, "ShowPrintUI", 114);
    try expectSlot(wv2.ICoreWebView2, "CallDevToolsProtocolMethod", 36);
    try std.testing.expectEqualSlices(u8, &.{ 0x59, 0x2d, 0xd0, 0x20, 0xf2, 0x6d, 0xdc, 0x42, 0xbd, 0x06, 0xf9, 0x8a, 0x69, 0x4b, 0x13, 0x02 }, std.mem.asBytes(&iid_webview4));
    try std.testing.expect(Handler.iids[@backingInt(Kind.completed)].eql(wv2.IID_NavigationCompletedEventHandler));
}
test "CDP encoding escapes scripts and cookies without interpolation" {
    const a = std.testing.allocator;
    const script = "Promise.resolve({s: '\"\\\n', n: 3})";
    var plan = try encode(a, .{ .eval = .{ .script = script } }, "https://app.test");
    defer plan.deinit(a);
    try std.testing.expectEqualStrings("Runtime.evaluate", plan.commands[0].method);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, plan.commands[0].params, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(script, parsed.value.object.get("expression").?.string);
    try std.testing.expect(parsed.value.object.get("awaitPromise").?.bool);
    try std.testing.expect(parsed.value.object.get("returnByValue").?.bool);
    var cookies = try encode(a, .{ .cookies = .{ .set = .{ .name = "a\"", .value = "b\\\n", .http_only = true, .same_site = .Strict } } }, "https://app.test");
    defer cookies.deinit(a);
    const c = try std.json.parseFromSlice(std.json.Value, a, cookies.commands[0].params, .{});
    defer c.deinit();
    try std.testing.expectEqualStrings("a\"", c.value.object.get("name").?.string);
    try std.testing.expectEqualStrings("b\\\n", c.value.object.get("value").?.string);
    try std.testing.expectEqualStrings("https://app.test", c.value.object.get("url").?.string);
    try std.testing.expect(c.value.object.get("httpOnly").?.bool);
    try std.testing.expect(c.value.object.get("expires") == null);
}
test "storage clearing covers origin stores and HTTP cache separately" {
    const a = std.testing.allocator;
    var plan = try encode(a, .{ .clear_storage = .{} }, "https://app.test:8443");
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), plan.count);
    try std.testing.expectEqualStrings("Storage.clearDataForOrigin", plan.commands[0].method);
    try std.testing.expectEqualStrings("Network.clearBrowserCache", plan.commands[1].method);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, plan.commands[0].params, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://app.test:8443", parsed.value.object.get("origin").?.string);
    try std.testing.expectEqualStrings("local_storage,indexeddb,cache_storage,service_workers,cookies", parsed.value.object.get("storageTypes").?.string);
    var none = try encode(a, .{ .clear_storage = .{ .local_storage = false, .indexed_db = false, .cache = false, .cookies = false } }, "https://app.test");
    defer none.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), none.count);
    try std.testing.expectError(error.InvalidOrigin, encode(a, .{ .clear_storage = .{ .origin = "https://app.test/path" } }, "https://app.test"));
}
test "async evaluation extracts JSON and rejects exceptions and non-JSON values" {
    const a = std.testing.allocator;
    const result = try decodeResult(a, .eval, "{\"result\":{\"type\":\"object\",\"value\":{\"answer\":42}}}");
    defer a.free(result);
    try std.testing.expectEqualStrings("{\"answer\":42}", result);
    const undef = try decodeResult(a, .eval, "{\"result\":{\"type\":\"undefined\"}}");
    defer a.free(undef);
    try std.testing.expectEqualStrings("null", undef);
    try std.testing.expectError(error.JavaScriptException, decodeResult(a, .eval, "{\"exceptionDetails\":{\"text\":\"Uncaught\"}}"));
    try std.testing.expectError(error.NonJsonResult, decodeResult(a, .eval, "{\"result\":{\"type\":\"number\",\"unserializableValue\":\"NaN\"}}"));
    try std.testing.expectError(error.CdpError, decodeResult(a, .raw, "{\"error\":{\"message\":\"bad\"}}"));
    try std.testing.expectError(error.CookieRejected, decodeResult(a, .cookie_set, "{\"success\":false}"));
}
test "permission mapping and safe download filenames" {
    try std.testing.expectEqual(shared.PermissionKind.camera, permissionKind(2));
    try std.testing.expectEqual(shared.PermissionKind.clipboard, permissionKind(6));
    try std.testing.expectEqual(shared.PermissionKind.unknown, permissionKind(500));
    const a = std.testing.allocator;
    const path = try downloadPath(a, "C:\\Downloads\\", "..\\..\\CON:bad.txt. ", 7);
    defer a.free(path);
    try std.testing.expectEqualStrings("C:\\Downloads\\7-CON_bad.txt", path);
    try std.testing.expectError(error.InvalidDownloadDirectory, downloadPath(a, "relative", "a", 1));
    try std.testing.expectError(error.InvalidDownloadName, downloadPath(a, "C:\\Downloads", "..", 1));
    try std.testing.expectError(error.EmbeddedNul, wideZ(a, "bad\x00suffix"));
}
test "force code generation of integration entrypoints and COM callbacks" {
    const methods = .{ attach, Driver.destroy, Driver.action, Driver.cancel, Driver.dispatchDeferred, Handler.invoke, Pending.invoke };
    inline for (methods) |f| std.mem.doNotOptimizeAway(&f);
}
