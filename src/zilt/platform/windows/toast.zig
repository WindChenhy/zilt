//! WinRT Toast 通知（纯 Zig，Phase 0 口径延续：零 C 胶水、无官方 SDK 依赖）。
//!
//! 背景（v0.1.5）：此前通知走托盘气球（Shell_NotifyIconW NIF_INFO），Win10+ 会把气球
//! 转入 **Toast 通道** 渲染——受系统 Toast 总开关抑制（实测 ToastEnabled=0 时静默吞掉，
//! API 仍返回 TRUE），且无 Action Center、不能带按钮。本模块改为 Tauri/Wails 同款的
//! WinRT ToastNotificationManager 主通道，气球保留为降级路径。
//!
//! ABI（IID/槽位取自 microsoft/win32metadata recompiled IDL）：
//!   IToastNotificationManagerStatics {50AC103F-D235-4598-BBEF-98FE4D1A3AD4}
//!     slot7 CreateToastNotifierWithId(HSTRING, **IToastNotifier)
//!     slot8 GetTemplateContent(u32, **IXmlDocument)
//!   IXmlDocumentIO {6CD0E74E-EE65-4489-9EBF-CA43E87BA637}  slot6 LoadXml(HSTRING)
//!   IToastNotificationFactory {04124B20-82C6-4229-B109-FD9ED4662B53}
//!     slot6 CreateToastNotification(*IXmlDocument, **IToastNotification)
//!   IToastNotifier {75927B93-03F3-41EC-91D3-6E5BAC1B38E7}  slot6 Show(*IToastNotification)
//!
//! AUMID 供给：桌面应用发 Toast 需要「开始菜单快捷方式 + System.AppUserModel.ID」
//! （tauri-winrt-notification 同款策略）——首次发送前自动创建
//! `%APPDATA%\Microsoft\Windows\Start Menu\Programs\<应用名>.lnk`。

const std = @import("std");
const win32 = @import("win32.zig");
const com = @import("com.zig");
const log = @import("../../log.zig");
pub const notification = @import("../../notification.zig");
pub const Options = notification.Options;
pub const Action = notification.Action;
pub const Input = notification.Input;
pub const Progress = notification.Progress;
pub const Callback = notification.Callback;
pub const Event = notification.Event;
pub const Status = notification.Status;

const HRESULT = com.HRESULT;
const GUID = com.GUID;
const HSTRING = ?*anyopaque;
const HMODULE = win32.HMODULE;

// ---- WinRT 激活类名（UTF-16 字面量）----
const cls_manager = std.unicode.utf8ToUtf16LeStringLiteral("Windows.UI.Notifications.ToastNotificationManager");
const cls_toast = std.unicode.utf8ToUtf16LeStringLiteral("Windows.UI.Notifications.ToastNotification");

const IID_IToastNotificationManagerStatics = GUID.parse("{50AC103F-D235-4598-BBEF-98FE4D1A3AD4}");
const IID_IXmlDocumentIO = GUID.parse("{6CD0E74E-EE65-4489-9EBF-CA43E87BA637}");
const IID_IToastNotificationFactory = GUID.parse("{04124B20-82C6-4229-B109-FD9ED4662B53}");
const IID_IToastNotifier = GUID.parse("{75927B93-03F3-41EC-91D3-6E5BAC1B38E7}");

// ---- 快捷方式供给所需的 COM 常量 ----
const CLSID_ShellLink = GUID.parse("{00021401-0000-0000-C000-000000000046}");
const IID_IShellLinkW = GUID.parse("{000214F9-0000-0000-C000-000000000046}");
const IID_IPersistFile = GUID.parse("{0000010B-0000-0000-C000-000000000046}");
const IID_IPropertyStore = GUID.parse("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}");
const FOLDERID_StartMenuPrograms = GUID.parse("{A77F5D77-2E2B-44C3-A6A2-ABA601054A51}");
/// PKEY_AppUserModel_ID（propkey.h）
const PKEY_AppUserModel_ID: PROPERTYKEY = .{ .fmtid = GUID.parse("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}"), .pid = 5 };
const CLSCTX_INPROC_SERVER: u32 = 1;
const VT_LPWSTR: u16 = 31;

const RO_INIT_SINGLETHREADED: u32 = 0; // roapi.h (1 is MULTITHREADED)
const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));

/// 文件存在探测（CreateFileW 打开即存在；避免引 shlwapi）。
fn fileExists(path_w: [:0]const u16) bool {
    const GENERIC_READ: u32 = 0x80000000;
    const OPEN_EXISTING: u32 = 3;
    const f = win32.CreateFileW(path_w.ptr, GENERIC_READ, 0, null, OPEN_EXISTING, 0, null);
    if (f == win32.INVALID_HANDLE_VALUE) return false;
    _ = win32.CloseHandle(f);
    return true;
}

// ---- combase 导入（运行时加载，与 loader.zig 同款策略）----
const RoInitializeFn = *const fn (initType: u32) callconv(.c) HRESULT;
const RoGetActivationFactoryFn = *const fn (classId: HSTRING, iid: *const GUID, factory: *?*anyopaque) callconv(.c) HRESULT;
const WindowsCreateStringFn = *const fn (src: [*:0]const u16, len: u32, hstr: *HSTRING) callconv(.c) HRESULT;
const WindowsDeleteStringFn = *const fn (hstr: HSTRING) callconv(.c) HRESULT;

// ---------------------------------------------------------------------------
// WinRT 接口绑定（只声明到会被调用的槽位）
// ---------------------------------------------------------------------------

pub const IToastNotificationManagerStatics = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IInspectable（0-5，不调用但槽位必须占位）
        QueryInterface: *const fn (*IToastNotificationManagerStatics, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IToastNotificationManagerStatics) callconv(.c) u32,
        Release: *const fn (*IToastNotificationManagerStatics) callconv(.c) u32,
        GetIids: *const fn (*IToastNotificationManagerStatics, *u32, ?*?*anyopaque) callconv(.c) HRESULT,
        GetRuntimeClassName: *const fn (*IToastNotificationManagerStatics, *HSTRING) callconv(.c) HRESULT,
        GetTrustLevel: *const fn (*IToastNotificationManagerStatics, *u32) callconv(.c) HRESULT,
        // 6: CreateToastNotifier（不使用）
        CreateToastNotifier: *const fn (*IToastNotificationManagerStatics, ?*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
        // 7: CreateToastNotifierWithId(HSTRING applicationId, IToastNotifier** notifier)
        CreateToastNotifierWithId: *const fn (*IToastNotificationManagerStatics, HSTRING, *?*IToastNotifier) callconv(.c) HRESULT,
        // 8: GetTemplateContent(ToastTemplateType, IXmlDocument** value)
        GetTemplateContent: *const fn (*IToastNotificationManagerStatics, u32, *?*anyopaque) callconv(.c) HRESULT,
    };

    pub fn createToastNotifierWithId(self: *IToastNotificationManagerStatics, app_id: HSTRING, out: *?*IToastNotifier) HRESULT {
        return self.lpVtbl.CreateToastNotifierWithId(self, app_id, out);
    }
};

pub const IToastNotifier = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IToastNotifier, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IToastNotifier) callconv(.c) u32,
        Release: *const fn (*IToastNotifier) callconv(.c) u32,
        GetIids: *const fn (*IToastNotifier, *u32, ?*?*anyopaque) callconv(.c) HRESULT,
        GetRuntimeClassName: *const fn (*IToastNotifier, *HSTRING) callconv(.c) HRESULT,
        GetTrustLevel: *const fn (*IToastNotifier, *u32) callconv(.c) HRESULT,
        // 6: Show(IToastNotification* notification)
        Show: *const fn (*IToastNotifier, ?*anyopaque) callconv(.c) HRESULT,
        // 7: Hide（不使用）
        Hide: *const fn (*IToastNotifier, ?*anyopaque) callconv(.c) HRESULT,
        // 8: Setting propget → NotificationSetting（0=Enabled 1=DisabledForApplication
        //    2=DisabledForUser 3=DisabledByGroupPolicy 4=DisabledByManifest）
        get_Setting: *const fn (*IToastNotifier, *u32) callconv(.c) HRESULT,
    };

    pub fn show(self: *IToastNotifier, toast: ?*anyopaque) HRESULT {
        return self.lpVtbl.Show(self, toast);
    }

    pub fn setting(self: *IToastNotifier) struct { hr: HRESULT, value: u32 } {
        var v: u32 = 0xff;
        const hr = self.lpVtbl.get_Setting(self, &v);
        return .{ .hr = hr, .value = v };
    }
};

pub const IToastNotificationFactory = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IToastNotificationFactory, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IToastNotificationFactory) callconv(.c) u32,
        Release: *const fn (*IToastNotificationFactory) callconv(.c) u32,
        GetIids: *const fn (*IToastNotificationFactory, *u32, ?*?*anyopaque) callconv(.c) HRESULT,
        GetRuntimeClassName: *const fn (*IToastNotificationFactory, *HSTRING) callconv(.c) HRESULT,
        GetTrustLevel: *const fn (*IToastNotificationFactory, *u32) callconv(.c) HRESULT,
        // 6: CreateToastNotification(IXmlDocument* content, IToastNotification** value)
        CreateToastNotification: *const fn (*IToastNotificationFactory, ?*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    };

    pub fn create(self: *IToastNotificationFactory, content_xml: ?*anyopaque) struct { hr: HRESULT, toast: ?*anyopaque } {
        var toast: ?*anyopaque = null;
        const hr = self.lpVtbl.CreateToastNotification(self, content_xml, &toast);
        return .{ .hr = hr, .toast = toast };
    }
};

pub const IXmlDocumentIO = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IXmlDocumentIO, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IXmlDocumentIO) callconv(.c) u32,
        Release: *const fn (*IXmlDocumentIO) callconv(.c) u32,
        GetIids: *const fn (*IXmlDocumentIO, *u32, ?*?*anyopaque) callconv(.c) HRESULT,
        GetRuntimeClassName: *const fn (*IXmlDocumentIO, *HSTRING) callconv(.c) HRESULT,
        GetTrustLevel: *const fn (*IXmlDocumentIO, *u32) callconv(.c) HRESULT,
        // 6: LoadXml(HSTRING xml)
        LoadXml: *const fn (*IXmlDocumentIO, HSTRING) callconv(.c) HRESULT,
    };

    pub fn loadXml(self: *IXmlDocumentIO, xml: HSTRING) HRESULT {
        return self.lpVtbl.LoadXml(self, xml);
    }
};

/// 通用 QI/Release（WinRT 与 classic COM 对象通吃：`lpVtbl` 首字段 + 前三槽位一致）。
const IUnknownHeader = extern struct {
    lpVtbl: *const extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.c) u32,
        Release: *const fn (*anyopaque) callconv(.c) u32,
    },
};

fn qiObj(obj: *anyopaque, iid: *const GUID) ?*anyopaque {
    const hdr: *const IUnknownHeader = @ptrCast(@alignCast(obj));
    var out: ?*anyopaque = null;
    if (com.succeeded(hdr.lpVtbl.QueryInterface(obj, iid, &out))) return out;
    return null;
}

fn releaseObj(obj: ?*anyopaque) void {
    const o = obj orelse return;
    const hdr: *const IUnknownHeader = @ptrCast(@alignCast(o));
    _ = hdr.lpVtbl.Release(o);
}

// Interactive ABI verified against microsoft/win32metadata, revision
// 15fc870a5e96df7c560877ff30136c0fb5a21e9b, generation/WinSDK/
// RecompiledIdlHeaders/winrt/{windows.ui.notifications.h,windows.foundation.h}.
// IAgileObject is also verified in Zig's mingw objidl.h. Delegates inherit
// IUnknown (Invoke slot 3), NOT IInspectable. WinRT boolean is one byte.
const IID_IToastNotification2 = GUID.parse("9dfb9fd1-143a-490e-90bf-b9fba7132de7");
const IID_IToastActivatedEventArgs = GUID.parse("e3bf92f3-c197-436f-8265-0625824f8dac");
const IID_IToastActivatedEventArgs2 = GUID.parse("ab7da512-cc61-568e-81be-304ac31038fa");
const IID_IPropertyValue = GUID.parse("4bd682dd-7554-40e9-9a9b-82654ede7e62");
const IID_IIterableStringObject = GUID.parse("fe2f3d47-5d47-5499-8374-430c7cda0204");
const IID_IAgileObject = GUID.parse("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");
const delegate_iids = [_]GUID{
    .parse("ab54de2d-97d9-5528-b6ad-105afe156530"),
    .parse("61c2402f-0ed0-5a18-ab69-59f4aa99a368"),
    .parse("95e3e803-c969-5e3a-9753-ea2ad22a9a33"),
};
const WindowsGetStringRawBufferFn = *const fn (HSTRING, *u32) callconv(.c) ?[*]const u16;
const RoUninitializeFn = *const fn () callconv(.c) void;
const EventRegistrationToken = extern struct { value: i64 };

/// Only use with the documented SDK interface and slot at each call site.
fn method(obj: *anyopaque, comptime slot: usize, comptime F: type) F {
    const header: *const extern struct { vtable: [*]const *const anyopaque } = @ptrCast(@alignCast(obj));
    return @ptrCast(header.vtable[slot]);
}
const GetObjectFn = *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT;
const GetStringFn = *const fn (*anyopaque, *HSTRING) callconv(.c) HRESULT;
const GetBooleanFn = *const fn (*anyopaque, *u8) callconv(.c) HRESULT;
const GetU32Fn = *const fn (*anyopaque, *u32) callconv(.c) HRESULT;
const GetErrorFn = *const fn (*anyopaque, *HRESULT) callconv(.c) HRESULT;
const PutStringFn = *const fn (*anyopaque, HSTRING) callconv(.c) HRESULT;
const PutBooleanFn = *const fn (*anyopaque, u8) callconv(.c) HRESULT;
const AddEventFn = *const fn (*anyopaque, *Handler, *EventRegistrationToken) callconv(.c) HRESULT;
const RemoveEventFn = *const fn (*anyopaque, EventRegistrationToken) callconv(.c) HRESULT;

// SRWLOCK's pointer-sized zero initializer needs no allocation/destruction.
// This gate is held throughout the callback; disconnect waits for in-flight
// callbacks, clears their context, then revokes outside the gate (COM may reenter).
extern "kernel32" fn AcquireSRWLockExclusive(*usize) callconv(.c) void;
extern "kernel32" fn ReleaseSRWLockExclusive(*usize) callconv(.c) void;

const CallbackState = struct {
    refs: std.atomic.Value(u32) = .init(1),
    gate: usize = 0,
    enabled: bool = true,
    terminal: std.atomic.Value(bool) = .init(false),
    callback: ?Callback,
    tag: ?[]const u8,
    group: ?[]const u8,
    get_buffer: WindowsGetStringRawBufferFn,
    delete_string: WindowsDeleteStringFn,

    fn release(self: *CallbackState) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const alloc = std.heap.page_allocator;
        if (self.tag) |s| alloc.free(s);
        if (self.group) |s| alloc.free(s);
        alloc.destroy(self);
    }
    fn disconnect(self: *CallbackState) void {
        AcquireSRWLockExclusive(&self.gate);
        self.enabled = false;
        self.callback = null;
        ReleaseSRWLockExclusive(&self.gate);
    }
    fn string(self: *CallbackState, alloc: std.mem.Allocator, obj: *anyopaque, comptime slot: usize) ![]const u8 {
        var h: HSTRING = null;
        const hr = method(obj, slot, GetStringFn)(obj, &h);
        defer if (h != null) {
            _ = self.delete_string(h);
        };
        if (!com.succeeded(hr)) return error.EventDataFailed;
        var len: u32 = 0;
        const raw = self.get_buffer(h, &len);
        if (len == 0) return "";
        const ptr = raw orelse return error.EventDataFailed;
        return std.unicode.utf16LeToUtf8Alloc(alloc, ptr[0..len]);
    }
    fn userInput(self: *CallbackState, alloc: std.mem.Allocator, args: *anyopaque) ![]const notification.UserInput {
        const args2 = qiObj(args, &IID_IToastActivatedEventArgs2) orelse return error.EventDataFailed;
        defer releaseObj(args2);
        // IToastActivatedEventArgs2.get_UserInput -> IPropertySet.
        var map: ?*anyopaque = null;
        const hr = method(args2, 6, GetObjectFn)(args2, &map);
        defer releaseObj(map);
        if (!com.succeeded(hr) or map == null) return error.EventDataFailed;
        // IPropertySet inherits IInspectable, not IMap. QI for the iterable.
        const iterable = qiObj(map.?, &IID_IIterableStringObject) orelse return error.EventDataFailed;
        defer releaseObj(iterable);
        var iter: ?*anyopaque = null;
        const first_hr = method(iterable, 6, GetObjectFn)(iterable, &iter); // First
        defer releaseObj(iter);
        if (!com.succeeded(first_hr) or iter == null) return error.EventDataFailed;
        var result: std.ArrayList(notification.UserInput) = .empty;
        var has_current: u8 = 0;
        if (!com.succeeded(method(iter.?, 7, GetBooleanFn)(iter.?, &has_current))) return error.EventDataFailed;
        while (has_current != 0) {
            var pair: ?*anyopaque = null;
            const current_hr = method(iter.?, 6, GetObjectFn)(iter.?, &pair); // get_Current
            defer releaseObj(pair);
            if (!com.succeeded(current_hr) or pair == null) return error.EventDataFailed;
            const key = try self.string(alloc, pair.?, 6); // IKeyValuePair.get_Key
            var value: ?*anyopaque = null;
            const value_hr = method(pair.?, 7, GetObjectFn)(pair.?, &value); // get_Value
            defer releaseObj(value);
            if (!com.succeeded(value_hr) or value == null) return error.EventDataFailed;
            const property = qiObj(value.?, &IID_IPropertyValue) orelse return error.EventDataFailed;
            defer releaseObj(property);
            // IPropertyValue.GetString is slot 19, following the 13 scalar getters.
            const text = try self.string(alloc, property, 19);
            try result.append(alloc, .{ .id = key, .value = text });
            if (!com.succeeded(method(iter.?, 8, GetBooleanFn)(iter.?, &has_current))) return error.EventDataFailed;
        }
        return result.items; // arena belongs to Invoke, never to Toast/main
    }
};

const Handler = extern struct {
    lpVtbl: *const VTable = &vtable,
    refs: u32 = 1,
    state: *CallbackState,
    kind: enum(u32) { activated, dismissed, failed },

    const VTable = extern struct {
        QueryInterface: *const fn (*Handler, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*Handler) callconv(.c) u32,
        Release: *const fn (*Handler) callconv(.c) u32,
        Invoke: *const fn (*Handler, ?*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
    };
    const vtable = VTable{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release, .Invoke = invoke };
    fn queryInterface(self: *Handler, iid: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT {
        out.* = null;
        if (!iid.eql(com.IID_IUnknown) and !iid.eql(IID_IAgileObject) and !iid.eql(delegate_iids[@backingInt(self.kind)])) return com.E_NOINTERFACE;
        out.* = self;
        _ = addRef(self);
        return com.S_OK;
    }
    fn addRef(self: *Handler) callconv(.c) u32 {
        return @atomicRmw(u32, &self.refs, .Add, 1, .monotonic) + 1;
    }
    fn release(self: *Handler) callconv(.c) u32 {
        const count = @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel) - 1;
        if (count == 0) {
            self.state.release();
            std.heap.page_allocator.destroy(self);
        }
        return count;
    }
    fn invoke(self: *Handler, _: ?*anyopaque, args: ?*anyopaque) callconv(.c) HRESULT {
        const state = self.state;
        AcquireSRWLockExclusive(&state.gate);
        defer ReleaseSRWLockExclusive(&state.gate);
        if (!state.enabled) return com.S_OK;
        // Timeout removes only the banner: keep activation alive in Action Center.
        if (self.kind != .dismissed) state.terminal.store(true, .release);
        const callback = state.callback orelse return com.S_OK;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var event = Event{ .tag = state.tag, .group = state.group, .kind = undefined };
        switch (self.kind) {
            .activated => {
                var data_error = false;
                var arguments: []const u8 = "";
                var input: []const notification.UserInput = &.{};
                if (args) |a| {
                    if (qiObj(a, &IID_IToastActivatedEventArgs)) |activated| {
                        defer releaseObj(activated);
                        arguments = state.string(arena.allocator(), activated, 6) catch blk: {
                            data_error = true;
                            break :blk "";
                        };
                    } else data_error = true;
                    input = state.userInput(arena.allocator(), a) catch blk: {
                        data_error = true;
                        break :blk &.{};
                    };
                } else data_error = true;
                event.kind = .{ .activated = .{ .arguments = arguments, .user_input = input, .data_error = data_error } };
            },
            .dismissed => {
                var reason: u32 = 0xffffffff;
                if (args) |a| {
                    _ = method(a, 6, GetU32Fn)(a, &reason);
                }
                if (reason == 0 or reason == 1) state.terminal.store(true, .release);
                event.kind = .{ .dismissed = @fromBackingInt(@intCast(reason)) };
            },
            .failed => {
                var hr: HRESULT = com.E_FAIL;
                if (args) |a| {
                    _ = method(a, 6, GetErrorFn)(a, &hr);
                }
                event.kind = .{ .failed = hr };
            },
        }
        callback.function(callback.context, event);
        return com.S_OK;
    }
};

const Registration = struct {
    toast: *anyopaque,
    state: *CallbackState,
    handlers: [3]?*Handler = @splat(null),
    tokens: [3]?EventRegistrationToken = @splat(null),

    fn deinit(self: *Registration) void {
        self.state.disconnect(); // context can be destroyed after this returns
        // IToastNotification: remove_Activated=12, Dismissed=10, Failed=14.
        inline for (.{ 12, 10, 14 }, 0..) |slot, i| {
            if (self.tokens[i]) |token| {
                const hr = method(self.toast, slot, RemoveEventFn)(self.toast, token);
                if (!com.succeeded(hr)) log.print("[toast] revoke handler failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            }
            if (self.handlers[i]) |h| _ = Handler.release(h);
        }
        releaseObj(self.toast);
        self.state.release();
    }
    fn init(owner: *Toast, toast: *anyopaque, options: Options) !Registration {
        // A thread-safe allocator is required even if owner's allocator is not.
        const alloc = std.heap.page_allocator;
        const state = try alloc.create(CallbackState);
        state.* = .{ .callback = owner.callback, .tag = null, .group = null, .get_buffer = owner.get_string_buffer.?, .delete_string = owner.delete_string.? };
        const hdr: *IUnknownHeader = @ptrCast(@alignCast(toast));
        _ = hdr.lpVtbl.AddRef(toast);
        var result = Registration{ .toast = toast, .state = state };
        errdefer result.deinit();
        if (options.tag) |s| state.tag = try alloc.dupe(u8, s);
        if (options.group) |s| state.group = try alloc.dupe(u8, s);
        // IToastNotification: add_Activated=11, Dismissed=9, Failed=13.
        inline for (.{ 11, 9, 13 }, 0..) |slot, i| {
            const h = try alloc.create(Handler);
            h.* = .{ .state = state, .kind = @fromBackingInt(@intCast(i)) };
            _ = state.refs.fetchAdd(1, .monotonic);
            result.handlers[i] = h;
            var token: EventRegistrationToken = undefined;
            if (!com.succeeded(method(toast, slot, AddEventFn)(toast, h, &token))) return error.EventRegistrationFailed;
            result.tokens[i] = token;
        }
        return result;
    }
};

// ---------------------------------------------------------------------------
// 快捷方式供给（AUMID）
// ---------------------------------------------------------------------------

const PROPVARIANT = extern struct {
    vt: u16,
    reserved: [6]u8 = @splat(0),
    data: extern union {
        pwszVal: ?[*:0]u16,
        tail: [16]u8, // 对齐真实 PROPVARIANT 尺寸（x64 = 24 字节）
    },
};

const PROPERTYKEY = extern struct { fmtid: GUID, pid: u32 };

const IShellLinkW = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IShellLinkW, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IShellLinkW) callconv(.c) u32,
        Release: *const fn (*IShellLinkW) callconv(.c) u32,
        GetPath: *const fn (*IShellLinkW, ?[*]u16, i32, ?*anyopaque, u32) callconv(.c) HRESULT,
        GetIDList: *const fn (*IShellLinkW, *?*anyopaque) callconv(.c) HRESULT,
        SetIDList: *const fn (*IShellLinkW, ?*anyopaque) callconv(.c) HRESULT,
        GetDescription: *const fn (*IShellLinkW, [*]u16, i32) callconv(.c) HRESULT,
        SetDescription: *const fn (*IShellLinkW, LPCWSTR) callconv(.c) HRESULT,
        GetWorkingDirectory: *const fn (*IShellLinkW, [*]u16, i32) callconv(.c) HRESULT,
        SetWorkingDirectory: *const fn (*IShellLinkW, LPCWSTR) callconv(.c) HRESULT,
        GetArguments: *const fn (*IShellLinkW, [*]u16, i32) callconv(.c) HRESULT,
        SetArguments: *const fn (*IShellLinkW, LPCWSTR) callconv(.c) HRESULT,
        GetHotkey: *const fn (*IShellLinkW, *u16) callconv(.c) HRESULT,
        SetHotkey: *const fn (*IShellLinkW, u16) callconv(.c) HRESULT,
        GetShowCmd: *const fn (*IShellLinkW, *i32) callconv(.c) HRESULT,
        SetShowCmd: *const fn (*IShellLinkW, i32) callconv(.c) HRESULT,
        GetIconLocation: *const fn (*IShellLinkW, [*]u16, i32, *i32) callconv(.c) HRESULT,
        SetIconLocation: *const fn (*IShellLinkW, LPCWSTR, i32) callconv(.c) HRESULT,
        SetRelativePath: *const fn (*IShellLinkW, LPCWSTR, u32) callconv(.c) HRESULT,
        Resolve: *const fn (*IShellLinkW, ?*anyopaque, u32) callconv(.c) HRESULT,
        // 20: SetPath(LPCWSTR pszFile)
        SetPath: *const fn (*IShellLinkW, LPCWSTR) callconv(.c) HRESULT,
    };

    pub fn setPath(self: *IShellLinkW, path: LPCWSTR) HRESULT {
        return self.lpVtbl.SetPath(self, path);
    }
};

const IPersistFile = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IPersistFile, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IPersistFile) callconv(.c) u32,
        Release: *const fn (*IPersistFile) callconv(.c) u32,
        GetClassID: *const fn (*IPersistFile, *GUID) callconv(.c) HRESULT,
        IsDirty: *const fn (*IPersistFile) callconv(.c) HRESULT,
        // 5: Load（不使用）
        Load: *const fn (*IPersistFile, LPCWSTR, u32) callconv(.c) HRESULT,
        // 6: Save(LPCWSTR pszFileName, BOOL fRemember)
        Save: *const fn (*IPersistFile, LPCWSTR, i32) callconv(.c) HRESULT,
        // 7: SaveCompleted（槽位占位——曾误占 6/7，"Save 成功"实为 SaveCompleted）
        SaveCompleted: *const fn (*IPersistFile, LPCWSTR) callconv(.c) HRESULT,
        // 8: GetCurFile（不使用）
        GetCurFile: *const fn (*IPersistFile, *?LPCWSTR) callconv(.c) HRESULT,
    };

    pub fn save(self: *IPersistFile, path: LPCWSTR, remember: i32) HRESULT {
        return self.lpVtbl.Save(self, path, remember);
    }
};

const IPropertyStore = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IPropertyStore, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IPropertyStore) callconv(.c) u32,
        Release: *const fn (*IPropertyStore) callconv(.c) u32,
        GetCount: *const fn (*IPropertyStore, *u32) callconv(.c) HRESULT,
        GetAt: *const fn (*IPropertyStore, u32, *PROPERTYKEY) callconv(.c) HRESULT,
        GetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *PROPVARIANT) callconv(.c) HRESULT,
        // 6: SetValue(REFPROPERTYKEY, REFPROPVARIANT)
        SetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *const PROPVARIANT) callconv(.c) HRESULT,
        // 7: Commit()
        Commit: *const fn (*IPropertyStore) callconv(.c) HRESULT,
    };

    pub fn setValue(self: *IPropertyStore, key: *const PROPERTYKEY, value: *const PROPVARIANT) HRESULT {
        return self.lpVtbl.SetValue(self, key, value);
    }
    pub fn commit(self: *IPropertyStore) HRESULT {
        return self.lpVtbl.Commit(self);
    }
};

const LPCWSTR = [*:0]const u16;

pub extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, clsctx: u32, iid: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT;
pub extern "shell32" fn SHGetKnownFolderPath(rfid: *const GUID, flags: u32, token: ?*anyopaque, path: *?[*:0]u16) callconv(.c) HRESULT;

// ---------------------------------------------------------------------------
// 纯函数（单测覆盖）
// ---------------------------------------------------------------------------

/// XML 文本转义（& < > " '）。
pub fn xmlEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '"' => try out.appendSlice(alloc, "&quot;"),
            '\'' => try out.appendSlice(alloc, "&apos;"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Reject malformed UTF-8 and characters XML 1.0 cannot represent.
fn validateText(s: []const u8) !void {
    var it = (std.unicode.Utf8View.init(s) catch return error.InvalidText).iterator();
    while (it.nextCodepoint()) |c| {
        if (!(c == 9 or c == 10 or c == 13 or (c >= 0x20 and c <= 0xd7ff) or
            (c >= 0xe000 and c <= 0xfffd) or (c >= 0x10000 and c <= 0x10ffff))) return error.InvalidText;
    }
}

fn validateKey(key: []const u8) !void {
    try validateText(key);
    var it = (try std.unicode.Utf8View.init(key)).iterator();
    var units: usize = 0;
    while (it.nextCodepoint()) |c| units += if (c > 0xffff) @as(usize, 2) else 1;
    if (units == 0 or units > 16) return error.InvalidTagOrGroup;
}

fn validateLaunch(uri: []const u8) !void {
    try validateText(uri);
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return error.InvalidLaunch;
    if (colon == 0 or colon + 1 == uri.len or !std.ascii.isAlphabetic(uri[0])) return error.InvalidLaunch;
    for (uri[1..colon]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return error.InvalidLaunch;
    for (uri) |c| if (c <= 0x20 or c == 0x7f) return error.InvalidLaunch;
}

pub fn validateOptions(options: Options) !void {
    try validateText(options.title);
    try validateText(options.body);
    if (options.tag) |v| try validateKey(v);
    if (options.group) |v| {
        if (options.tag == null) return error.GroupRequiresTag;
        try validateKey(v);
    }
    if (options.launch) |v| try validateLaunch(v);
    if (options.actions.len > 5) return error.TooManyActions;
    if (options.input) |v| {
        try validateText(v.id);
        if (v.id.len == 0) return error.InvalidInput;
        try validateText(v.placeholder);
        try validateText(v.title);
    }
    for (options.actions) |action| {
        try validateText(action.title);
        try validateText(action.arguments);
        if (action.title.len == 0) return error.InvalidAction;
        if (action.launch) |v| {
            try validateLaunch(v);
            // Protocol activation cannot return user input or separate arguments.
            if (action.input_id != null or action.arguments.len != 0) return error.InvalidAction;
        }
        if (action.input_id) |id| {
            const input = options.input orelse return error.InvalidInput;
            if (!std.mem.eql(u8, input.id, id)) return error.InvalidInput;
        }
    }
    if (options.progress) |v| {
        try validateText(v.title);
        try validateText(v.value_string);
        try validateText(v.status);
        if (v.status.len == 0) return error.InvalidProgress;
        if (v.value) |n| if (!std.math.isFinite(n) or n < 0 or n > 1) return error.InvalidProgress;
    }
}

const XmlBuilder = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn raw(self: *XmlBuilder, value: []const u8) !void {
        try self.out.appendSlice(self.alloc, value);
    }
    fn text(self: *XmlBuilder, value: []const u8) !void {
        const escaped = try xmlEscape(self.alloc, value);
        defer self.alloc.free(escaped);
        try self.raw(escaped);
    }
    fn attr(self: *XmlBuilder, name: []const u8, value: []const u8) !void {
        try self.raw(" ");
        try self.raw(name);
        try self.raw("=\"");
        // XML normalizes literal whitespace in attributes. Preserve it as entities.
        var start: usize = 0;
        for (value, 0..) |c, i| {
            const entity: ?[]const u8 = switch (c) {
                9 => "&#9;",
                10 => "&#10;",
                13 => "&#13;",
                else => null,
            };
            if (entity) |e| {
                try self.text(value[start..i]);
                try self.raw(e);
                start = i + 1;
            }
        }
        try self.text(value[start..]);
        try self.raw("\"");
    }
};

/// Tag and Group are WinRT properties, deliberately not XML attributes.
pub fn buildOptionsXml(alloc: std.mem.Allocator, options: Options) ![]u8 {
    try validateOptions(options);
    var x = XmlBuilder{ .alloc = alloc };
    errdefer x.out.deinit(alloc);
    try x.raw("<toast");
    if (options.launch) |uri| {
        try x.attr("activationType", "protocol");
        try x.attr("launch", uri);
    }
    try x.raw("><visual><binding template=\"ToastGeneric\"><text>");
    try x.text(options.title);
    try x.raw("</text><text>");
    try x.text(options.body);
    try x.raw("</text>");
    if (options.progress) |p| {
        try x.raw("<progress");
        try x.attr("title", p.title);
        if (p.value) |value| {
            const number = try std.fmt.allocPrint(alloc, "{d}", .{value});
            defer alloc.free(number);
            try x.attr("value", number);
        } else try x.attr("value", "indeterminate");
        try x.attr("valueStringOverride", p.value_string);
        try x.attr("status", p.status);
        try x.raw("/>");
    }
    try x.raw("</binding></visual>");
    if (options.actions.len > 0 or options.input != null) {
        try x.raw("<actions>");
        if (options.input) |input| {
            try x.raw("<input type=\"text\"");
            try x.attr("id", input.id);
            try x.attr("placeHolderContent", input.placeholder);
            try x.attr("title", input.title);
            try x.raw("/>");
        }
        for (options.actions) |action| {
            try x.raw("<action");
            try x.attr("content", action.title);
            try x.attr("arguments", action.launch orelse action.arguments);
            try x.attr("activationType", if (action.launch != null) "protocol" else "foreground");
            if (action.input_id) |id| try x.attr("hint-inputId", id);
            try x.raw("/>");
        }
        try x.raw("</actions>");
    }
    try x.raw("</toast>");
    return x.out.toOwnedSlice(alloc);
}

/// Compatibility XML wrapper.
pub fn buildToastXml(alloc: std.mem.Allocator, title: []const u8, body: []const u8) ![]u8 {
    return buildOptionsXml(alloc, .{ .title = title, .body = body });
}

/// 快捷方式文件名清洗（Windows 文件名非法字符 → '_'；去除结尾点/空格）。
pub fn shortcutFileName(alloc: std.mem.Allocator, app_name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (app_name) |c| {
        const bad = c < 0x20 or c == '<' or c == '>' or c == ':' or c == '"' or
            c == '/' or c == '\\' or c == '|' or c == '?' or c == '*';
        try out.append(alloc, if (bad) '_' else c);
    }
    while (out.items.len > 0 and (out.items[out.items.len - 1] == '.' or out.items[out.items.len - 1] == ' ')) {
        _ = out.pop();
    }
    if (out.items.len == 0) try out.appendSlice(alloc, "App");
    return out.toOwnedSlice(alloc);
}

fn sameKey(a_tag: ?[]const u8, a_group: ?[]const u8, b_tag: ?[]const u8, b_group: ?[]const u8) bool {
    const a = a_tag orelse return false;
    const b = b_tag orelse return false;
    return std.mem.eql(u8, a, b) and std.mem.eql(u8, a_group orelse "", b_group orelse "");
}

// ---------------------------------------------------------------------------
// Toast 主结构
// ---------------------------------------------------------------------------

pub const Toast = struct {
    allocator: std.mem.Allocator,
    combase: HMODULE = null,
    ro_get_activation_factory: ?RoGetActivationFactoryFn = null,
    create_string: ?WindowsCreateStringFn = null,
    delete_string: ?WindowsDeleteStringFn = null,
    aumid: [:0]u16,
    exe_path_w: [:0]u16,
    shortcut_name: [:0]u16,
    shortcut_ready: bool = false,
    get_string_buffer: ?WindowsGetStringRawBufferFn = null,
    ro_uninitialize: ?RoUninitializeFn = null,
    ro_initialized: bool = false,
    /// Set before showing; each notification snapshots this callback. Changing it
    /// affects future shows only. All Toast methods run on the init/owner thread.
    callback: ?Callback = null,
    registrations: std.ArrayList(Registration) = .empty,

    /// 初始化：加载 combase + 预编码 AUMID/exe 路径。失败抛错（调用方降级气球）。
    pub fn init(alloc: std.mem.Allocator, app_id: []const u8, app_name: []const u8, exe_path: []const u8) !Toast {
        const combase = win32.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("combase.dll"), null, win32.LOAD_WITH_ALTERED_SEARCH_PATH) orelse
            return error.CombaseNotFound;
        errdefer _ = win32.FreeLibrary(combase);
        const get_proc = struct {
            fn f(h: HMODULE, name: [*:0]const u8) ?*anyopaque {
                return win32.GetProcAddress(h, name);
            }
        }.f;
        const ro_gaf: RoGetActivationFactoryFn = @ptrCast(get_proc(combase, "RoGetActivationFactory") orelse return error.RoMissing);
        const create_str: WindowsCreateStringFn = @ptrCast(get_proc(combase, "WindowsCreateString") orelse return error.RoMissing);
        const delete_str: WindowsDeleteStringFn = @ptrCast(get_proc(combase, "WindowsDeleteString") orelse return error.RoMissing);
        const ro_init: RoInitializeFn = @ptrCast(get_proc(combase, "RoInitialize") orelse return error.RoMissing);
        const ro_uninit: RoUninitializeFn = @ptrCast(get_proc(combase, "RoUninitialize") orelse return error.RoMissing);
        const get_buffer: WindowsGetStringRawBufferFn = @ptrCast(get_proc(combase, "WindowsGetStringRawBuffer") orelse return error.RoMissing);

        // UI 线程已 CoInitializeEx(STA)；RO_INIT_SINGLETHREADED → S_FALSE（已初始化）属正常。
        // RPC_E_CHANGED_MODE 亦不阻断（线程已初始化即可用）。
        const hr_init = ro_init(RO_INIT_SINGLETHREADED);
        if (!com.succeeded(hr_init) and hr_init != RPC_E_CHANGED_MODE)
            log.print("[toast] RoInitialize hr=0x{x}（继续）", .{@as(u32, @bitCast(hr_init))});

        errdefer if (com.succeeded(hr_init)) ro_uninit();
        const aumid = try std.unicode.utf8ToUtf16LeAllocZ(alloc, app_id);
        errdefer alloc.free(aumid);
        const exe = try std.unicode.utf8ToUtf16LeAllocZ(alloc, exe_path);
        errdefer alloc.free(exe);
        const clean = try shortcutFileName(alloc, app_name);
        defer alloc.free(clean);
        const shortcut = try std.unicode.utf8ToUtf16LeAllocZ(alloc, clean);
        return .{
            .allocator = alloc,
            .combase = combase,
            .ro_get_activation_factory = ro_gaf,
            .create_string = create_str,
            .delete_string = delete_str,
            .get_string_buffer = get_buffer,
            .ro_uninitialize = ro_uninit,
            .ro_initialized = com.succeeded(hr_init),
            .aumid = aumid,
            .exe_path_w = exe,
            .shortcut_name = shortcut,
        };
    }

    pub fn deinit(self: *Toast) void {
        // Disconnect every callback before revoking any event. Even if Windows
        // retains a delegate after failed revocation, it has no live context and
        // cannot call unloaded string functions. Delegates own their state.
        for (self.registrations.items) |*r| r.state.disconnect();
        for (self.registrations.items) |*r| r.deinit();
        self.registrations.deinit(self.allocator);
        if (self.ro_initialized) self.ro_uninitialize.?();
        self.allocator.free(self.aumid);
        self.allocator.free(self.exe_path_w);
        self.allocator.free(self.shortcut_name);
        if (self.combase != null) {
            _ = win32.FreeLibrary(self.combase);
            self.combase = null;
        }
    }

    fn createHString(self: *Toast, w: [:0]const u16) ?HSTRING {
        var h: HSTRING = null;
        const hr = self.create_string.?(w.ptr, @intCast(w.len), &h);
        if (!com.succeeded(hr)) return null;
        return h;
    }

    fn deleteHString(self: *Toast, h: HSTRING) void {
        if (h != null) _ = self.delete_string.?(h);
    }

    /// Compatibility wrappers: true means accepted by Show, not visible.
    pub fn show(self: *Toast, title: []const u8, body: []const u8) bool {
        self.showOptions(.{ .title = title, .body = body }) catch return false;
        return true;
    }
    pub fn send(self: *Toast, title: []const u8, body: []const u8) bool {
        return self.show(title, body);
    }

    pub fn showOptions(self: *Toast, options: Options) !void {
        try self.sendOptions(options, false);
    }

    /// Full replacement, NOT NotificationData/sequence-number Update:
    /// requires tag + progress; caller resends all title/body/actions/input/launch.
    /// Same (AUMID, tag, group) replaces history and revokes old callbacks after
    /// Show succeeds. SuppressPopup=true; if absent in history, creates a silent
    /// history item. No existence or stale-sequence detection is performed.
    pub fn updateProgress(self: *Toast, options: Options) !void {
        if (options.tag == null or options.progress == null) return error.ProgressRequiresTag;
        try self.sendOptions(options, true);
    }

    /// Query OS notifier setting without provisioning a shortcut or showing UI.
    pub fn status(self: *Toast) !Status {
        const cls = self.createHString(cls_manager) orelse return error.StringCreationFailed;
        defer self.deleteHString(cls);
        const id = self.createHString(self.aumid) orelse return error.StringCreationFailed;
        defer self.deleteHString(id);
        var statics_ptr: ?*anyopaque = null;
        const hr = self.ro_get_activation_factory.?(cls, &IID_IToastNotificationManagerStatics, &statics_ptr);
        defer releaseObj(statics_ptr);
        if (!com.succeeded(hr) or statics_ptr == null) return error.NotifierUnavailable;
        const statics: *IToastNotificationManagerStatics = @ptrCast(@alignCast(statics_ptr.?));
        var notifier: ?*IToastNotifier = null;
        const notifier_hr = statics.createToastNotifierWithId(id, &notifier);
        defer releaseObj(notifier);
        if (!com.succeeded(notifier_hr) or notifier == null) return error.NotifierUnavailable;
        const result = notifier.?.setting();
        if (!com.succeeded(result.hr)) return error.StatusUnavailable;
        return @fromBackingInt(@intCast(result.value));
    }

    fn prune(self: *Toast, replacement: ?Options) void {
        var i: usize = 0;
        while (i < self.registrations.items.len) {
            const r = &self.registrations.items[i];
            const replaced = if (replacement) |o| sameKey(r.state.tag, r.state.group, o.tag, o.group) else false;
            if (replaced or r.state.terminal.load(.acquire)) {
                r.deinit();
                _ = self.registrations.swapRemove(i);
            } else i += 1;
        }
    }

    fn setIdentity(self: *Toast, toast: *anyopaque, options: Options, suppress_popup: bool) !void {
        if (options.tag == null and options.group == null and !suppress_popup) return;
        const toast2 = qiObj(toast, &IID_IToastNotification2) orelse return error.IdentityUnavailable;
        defer releaseObj(toast2);
        inline for (.{ options.tag, options.group }, .{ 6, 8 }) |value, slot| {
            if (value) |s| {
                const w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, s);
                defer self.allocator.free(w);
                const h = self.createHString(w) orelse return error.StringCreationFailed;
                defer self.deleteHString(h);
                if (!com.succeeded(method(toast2, slot, PutStringFn)(toast2, h))) return error.IdentityFailed;
            }
        }
        if (suppress_popup and !com.succeeded(method(toast2, 10, PutBooleanFn)(toast2, 1))) return error.SuppressPopupFailed;
    }

    fn sendOptions(self: *Toast, options: Options, suppress_popup: bool) !void {
        const alloc = self.allocator;
        const xml_u8 = try buildOptionsXml(alloc, options);
        defer alloc.free(xml_u8);
        const xml_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, xml_u8);
        defer alloc.free(xml_w);
        self.prune(null);
        try self.registrations.ensureUnusedCapacity(alloc, 1);
        self.ensureShortcut();

        var hr_last: HRESULT = com.E_FAIL;
        step: {
            const h_cls_manager = self.createHString(cls_manager) orelse break :step;
            defer self.deleteHString(h_cls_manager);
            const h_cls_toast = self.createHString(cls_toast) orelse break :step;
            defer self.deleteHString(h_cls_toast);
            const h_aumid = self.createHString(self.aumid) orelse break :step;
            defer self.deleteHString(h_aumid);
            const h_xml = self.createHString(xml_w) orelse break :step;
            defer self.deleteHString(h_xml);

            // 1) ToastNotificationManager statics
            var statics_ptr: ?*anyopaque = null;
            hr_last = self.ro_get_activation_factory.?(h_cls_manager, &IID_IToastNotificationManagerStatics, &statics_ptr);
            if (!com.succeeded(hr_last)) break :step;
            const statics: *IToastNotificationManagerStatics = @ptrCast(@alignCast(statics_ptr.?));
            defer releaseObj(statics);

            // 2) 模板文档 + LoadXml 覆写内容
            var doc_ptr: ?*anyopaque = null;
            hr_last = statics.lpVtbl.GetTemplateContent(statics, 0, &doc_ptr);
            if (!com.succeeded(hr_last) or doc_ptr == null) break :step;
            defer releaseObj(doc_ptr);
            const io_ptr = qiObj(doc_ptr.?, &IID_IXmlDocumentIO) orelse {
                hr_last = com.E_FAIL;
                break :step;
            };
            defer releaseObj(io_ptr);
            hr_last = @as(*IXmlDocumentIO, @ptrCast(@alignCast(io_ptr))).loadXml(h_xml);
            if (!com.succeeded(hr_last)) break :step;

            // 3) notifier（AUMID 归属）
            var notifier_ptr: ?*anyopaque = null;
            hr_last = statics.lpVtbl.CreateToastNotifierWithId(statics, h_aumid, @ptrCast(&notifier_ptr));
            if (!com.succeeded(hr_last) or notifier_ptr == null) break :step;
            defer releaseObj(notifier_ptr);
            {
                const st = @as(*IToastNotifier, @ptrCast(@alignCast(notifier_ptr))).setting();
                const names = [_][]const u8{ "Enabled", "DisabledForApplication", "DisabledForUser", "DisabledByGroupPolicy", "DisabledByManifest" };
                const name = if (st.value < names.len) names[st.value] else "Unknown";
                log.print("[toast] notifier.Setting = {s} ({d}){s}", .{ name, st.value, if (st.value != 0) "（通知被系统设置抑制，横幅不可见——检查 设置→系统→通知/勿扰）" else "" });
            }

            // 4) toast 对象
            var factory_ptr: ?*anyopaque = null;
            hr_last = self.ro_get_activation_factory.?(h_cls_toast, &IID_IToastNotificationFactory, &factory_ptr);
            if (!com.succeeded(hr_last)) break :step;
            defer releaseObj(factory_ptr);
            const created = @as(*IToastNotificationFactory, @ptrCast(@alignCast(factory_ptr.?))).create(doc_ptr);
            hr_last = created.hr;
            if (!com.succeeded(hr_last) or created.toast == null) break :step;
            defer releaseObj(created.toast);

            try self.setIdentity(created.toast.?, options, suppress_popup);
            var registration = try Registration.init(self, created.toast.?, options);
            // Events must be registered before Show. Failure unwinds all tokens.
            var retained = false;
            defer if (!retained) registration.deinit();
            hr_last = @as(*IToastNotifier, @ptrCast(@alignCast(notifier_ptr.?))).show(created.toast);
            if (!com.succeeded(hr_last)) break :step;
            self.prune(options);
            self.registrations.appendAssumeCapacity(registration);
            retained = true;
            return;
        }
        log.print("[toast] winrt failed hr=0x{x}", .{@as(u32, @bitCast(hr_last))});
        return error.ShowFailed;
    }

    /// 首次发送前确保开始菜单快捷方式（AUMID 载体）存在；失败不阻断发送。
    fn ensureShortcut(self: *Toast) void {
        if (self.shortcut_ready) return;
        self.shortcut_ready = true;
        ensureShortcutInner(self) catch |err| {
            log.print("[toast] shortcut provision failed: {s}（继续尝试发送）", .{@errorName(err)});
        };
    }

    fn ensureShortcutInner(self: *Toast) !void {
        const alloc = self.allocator;
        var start_menu: ?[*:0]u16 = null;
        const hr = SHGetKnownFolderPath(&FOLDERID_StartMenuPrograms, 0, null, &start_menu);
        if (!com.succeeded(hr) or start_menu == null) return error.KnownFolderFailed;
        defer win32.CoTaskMemFree(start_menu.?);

        const sm_u8 = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(start_menu.?)) catch return error.OutOfMemory;
        defer alloc.free(sm_u8);
        const name_u8 = std.unicode.utf16LeToUtf8Alloc(alloc, self.shortcut_name) catch return error.OutOfMemory;
        defer alloc.free(name_u8);
        const lnk_u8 = try std.fmt.allocPrint(alloc, "{s}\\{s}.lnk", .{ sm_u8, name_u8 });
        defer alloc.free(lnk_u8);
        const lnk_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, lnk_u8);
        defer alloc.free(lnk_w);

        // 已存在 → 视为已供给（不校验属性，避免每次通知的额外开销）
        if (fileExists(lnk_w)) {
            log.print("[toast] shortcut exists: {s}", .{lnk_u8});
            return;
        }

        var link_ptr: ?*anyopaque = null;
        const hr_cc = CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &link_ptr);
        if (!com.succeeded(hr_cc) or link_ptr == null) return error.ShellLinkFailed;
        defer releaseObj(link_ptr);
        const link: *IShellLinkW = @ptrCast(@alignCast(link_ptr.?));

        const hr_sp = link.setPath(self.exe_path_w.ptr);
        if (!com.succeeded(hr_sp)) return error.SetPathFailed;

        // System.AppUserModel.ID = AUMID（Toast 归属的关键属性）
        const props_ptr = qiObj(link_ptr.?, &IID_IPropertyStore) orelse return error.NoPropertyStore;
        defer releaseObj(props_ptr);
        const props: *IPropertyStore = @ptrCast(@alignCast(props_ptr));
        var pv = PROPVARIANT{ .vt = VT_LPWSTR, .data = .{ .pwszVal = self.aumid.ptr } };
        const hr_sv = props.setValue(&PKEY_AppUserModel_ID, &pv);
        if (!com.succeeded(hr_sv)) return error.SetValueFailed;
        const hr_cm = props.commit();
        if (!com.succeeded(hr_cm)) return error.CommitFailed;

        const pf_ptr = qiObj(link_ptr.?, &IID_IPersistFile) orelse return error.NoPersistFile;
        defer releaseObj(pf_ptr);
        const hr_save = @as(*IPersistFile, @ptrCast(@alignCast(pf_ptr))).save(lnk_w.ptr, 1);
        if (!com.succeeded(hr_save)) return error.SaveFailed;

        log.print("[toast] shortcut created: {s}", .{lnk_u8});
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "xmlEscape: 实体替换" {
    const e = try xmlEscape(testing.allocator, "a&b<c>\"d'e");
    defer testing.allocator.free(e);
    try testing.expectEqualStrings("a&amp;b&lt;c&gt;&quot;d&apos;e", e);
    const n = try xmlEscape(testing.allocator, "普通文本-12");
    defer testing.allocator.free(n);
    try testing.expectEqualStrings("普通文本-12", n);
}

test "buildToastXml: 模板结构 + 转义" {
    const x = try buildToastXml(testing.allocator, "标题<&>", "正文");
    defer testing.allocator.free(x);
    try testing.expect(std.mem.startsWith(u8, x, "<toast><visual><binding template=\"ToastGeneric\">"));
    try testing.expect(std.mem.indexOf(u8, x, "<text>标题&lt;&amp;&gt;</text>") != null);
    try testing.expect(std.mem.endsWith(u8, x, "</binding></visual></toast>"));
}

test "shortcutFileName: 非法字符清洗 + 空名兜底" {
    const a = try shortcutFileName(testing.allocator, "Zilt: Demo?* v1");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("Zilt_ Demo__ v1", a);
    const b = try shortcutFileName(testing.allocator, "a<b>:");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("a_b__", b);
    const c = try shortcutFileName(testing.allocator, "...");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("App", c);
}

test "toast: interactive XML escapes attributes, protocol actions, input and progress" {
    const xml = try buildOptionsXml(testing.allocator, .{
        .title = "Title<&>",
        .body = "Body",
        .tag = "job",
        .group = "downloads",
        .launch = "zilt://open?a=1&b=2",
        .input = .{ .id = "reply", .placeholder = "Say \"hello\"", .title = "Reply" },
        .actions = &.{
            .{ .title = "Send & go", .arguments = "reply='yes'\nnext", .input_id = "reply" },
            .{ .title = "Open", .launch = "zilt://action?x=1&y=2" },
        },
        .progress = .{ .title = "Download", .value = 0.5, .value_string = "50%", .status = "Working & waiting" },
    });
    defer testing.allocator.free(xml);
    for ([_][]const u8{
        "<toast activationType=\"protocol\" launch=\"zilt://open?a=1&amp;b=2\">",
        "<text>Title&lt;&amp;&gt;</text>",
        "<input type=\"text\" id=\"reply\" placeHolderContent=\"Say &quot;hello&quot;\" title=\"Reply\"/>",
        "content=\"Send &amp; go\" arguments=\"reply=&apos;yes&apos;&#10;next\" activationType=\"foreground\" hint-inputId=\"reply\"",
        "arguments=\"zilt://action?x=1&amp;y=2\" activationType=\"protocol\"",
        "value=\"0.5\"",
        "valueStringOverride=\"50%\"",
        "status=\"Working &amp; waiting\"",
    }) |fragment| try testing.expect(std.mem.indexOf(u8, xml, fragment) != null);
    try testing.expect(std.mem.indexOf(u8, xml, "tag=") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "group=") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<input").? < std.mem.indexOf(u8, xml, "<action ").?);
}

test "toast: progress indeterminate and numeric boundaries" {
    for ([_]?f64{ null, 0, 1 }) |value| {
        const xml = try buildOptionsXml(testing.allocator, .{ .title = "", .body = "", .progress = .{ .value = value, .status = "Working" } });
        defer testing.allocator.free(xml);
        const expected = if (value == null) "value=\"indeterminate\"" else if (value.? == 0) "value=\"0\"" else "value=\"1\"";
        try testing.expect(std.mem.indexOf(u8, xml, expected) != null);
    }
}

test "toast: validation rejects invalid XML, keys, actions, input, URI and progress" {
    try testing.expectError(error.InvalidText, validateOptions(.{ .title = "\x00", .body = "" }));
    try testing.expectError(error.InvalidText, validateOptions(.{ .title = "", .body = "\xff" }));
    try testing.expectError(error.InvalidText, validateOptions(.{ .title = "\x01", .body = "" }));
    try testing.expectError(error.InvalidText, validateOptions(.{ .title = "\xef\xbf\xbe", .body = "" }));
    try testing.expectError(error.InvalidTagOrGroup, validateOptions(.{ .title = "", .body = "", .tag = "" }));
    try testing.expectError(error.InvalidTagOrGroup, validateOptions(.{ .title = "", .body = "", .tag = "12345678901234567" }));
    try testing.expectError(error.GroupRequiresTag, validateOptions(.{ .title = "", .body = "", .group = "g" }));
    try validateOptions(.{ .title = "\t\r\n中文", .body = "", .tag = "1234567890123456" });
    try validateKey("𐀀𐀀𐀀𐀀𐀀𐀀𐀀𐀀");
    try testing.expectError(error.InvalidTagOrGroup, validateKey("𐀀𐀀𐀀𐀀𐀀𐀀𐀀𐀀x"));
    for ([_][]const u8{ "relative", ":value", "1bad:value", "app:", "app:has space" }) |uri| {
        try testing.expectError(error.InvalidLaunch, validateOptions(.{ .title = "", .body = "", .launch = uri }));
    }
    const many: [6]Action = @splat(.{ .title = "a" });
    try testing.expectError(error.TooManyActions, validateOptions(.{ .title = "", .body = "", .actions = &many }));
    try testing.expectError(error.InvalidAction, validateOptions(.{ .title = "", .body = "", .actions = &.{.{ .title = "" }} }));
    try testing.expectError(error.InvalidAction, validateOptions(.{ .title = "", .body = "", .actions = &.{.{ .title = "a", .launch = "app:go", .arguments = "lost" }} }));
    try testing.expectError(error.InvalidInput, validateOptions(.{ .title = "", .body = "", .input = .{ .id = "" } }));
    try testing.expectError(error.InvalidInput, validateOptions(.{ .title = "", .body = "", .actions = &.{.{ .title = "a", .input_id = "missing" }} }));
    try testing.expectError(error.InvalidInput, validateOptions(.{ .title = "", .body = "", .input = .{ .id = "reply" }, .actions = &.{.{ .title = "a", .input_id = "other" }} }));
    for ([_]f64{ -0.1, 1.1, std.math.nan(f64), std.math.inf(f64) }) |value| {
        try testing.expectError(error.InvalidProgress, validateOptions(.{ .title = "", .body = "", .progress = .{ .value = value, .status = "Working" } }));
    }
    try testing.expectError(error.InvalidProgress, validateOptions(.{ .title = "", .body = "", .progress = .{ .status = "" } }));
}

test "toast: replacement key semantics" {
    try testing.expect(sameKey("job", null, "job", null));
    try testing.expect(sameKey("job", "g", "job", "g"));
    try testing.expect(!sameKey(null, null, null, null));
    try testing.expect(!sameKey("job", "g", "job", "other"));
    try testing.expect(!sameKey("job", null, "other", null));
}

fn testXmlAllocation(alloc: std.mem.Allocator) !void {
    const xml = try buildOptionsXml(alloc, .{
        .title = "<&",
        .body = "body",
        .launch = "app:open",
        .actions = &.{.{ .title = "reply", .arguments = "arg", .input_id = "id" }},
        .input = .{ .id = "id" },
        .progress = .{ .value = 0.25, .status = "Working" },
    });
    defer alloc.free(xml);
}

test "toast: XML allocation failure cleanup" {
    try testing.checkAllAllocationFailures(testing.allocator, testXmlAllocation, .{});
}

// In-process ABI doubles: exercise event extraction and revocation without
// notifying Windows, changing permissions, or creating a Start Menu shortcut.
const EventMock = struct {
    const Kind = enum(u32) { args, args2, map, iterator, pair, property, toast };
    const Object = extern struct {
        vtable: [*]const *const anyopaque,
        fixture: *EventMock,
        kind: Kind,
        refs: u32 = 1,
    };
    const String = struct { value: []const u16 };
    args: Object = undefined,
    args2: Object = undefined,
    map: Object = undefined,
    iterator: Object = undefined,
    pair: Object = undefined,
    property: Object = undefined,
    toast: Object = undefined,
    position: u32 = 0,
    deletes: u32 = 0,
    revoked: u32 = 0,
    fail_add: ?u32 = null,
    handlers: [3]?*Handler = @splat(null),
    arguments: String = .{ .value = std.unicode.utf8ToUtf16LeStringLiteral("reply&open") },
    keys: [2]String = .{
        .{ .value = std.unicode.utf8ToUtf16LeStringLiteral("reply") },
        .{ .value = std.unicode.utf8ToUtf16LeStringLiteral("second") },
    },
    values: [2]String = .{
        .{ .value = std.unicode.utf8ToUtf16LeStringLiteral("你好 <text>") },
        .{ .value = std.unicode.utf8ToUtf16LeStringLiteral("another answer") },
    },
    fn init(self: *EventMock) void {
        inline for (.{ "args", "args2", "map", "iterator", "pair", "property", "toast" }) |name| {
            const kind: Kind = @field(Kind, name);
            @field(self, name) = .{ .vtable = &(comptime table(kind)), .fixture = self, .kind = kind };
        }
    }
    fn table(comptime kind: Kind) [20]*const anyopaque {
        var t: [20]*const anyopaque = @splat(@ptrCast(&unused));
        t[0] = @ptrCast(&query);
        t[1] = @ptrCast(&addRef);
        t[2] = @ptrCast(&release);
        t[6] = @ptrCast(&get);
        t[7] = if (kind == .iterator) @ptrCast(&hasCurrent) else @ptrCast(&get);
        t[8] = @ptrCast(&moveNext);
        t[19] = @ptrCast(&get);
        if (kind == .toast) {
            for ([_]usize{ 9, 11, 13 }) |slot| t[slot] = @ptrCast(&addEvent);
            for ([_]usize{ 10, 12, 14 }) |slot| t[slot] = @ptrCast(&removeEvent);
        }
        return t;
    }
    fn unused(_: *Object) callconv(.c) HRESULT { return com.E_NOTIMPL; }
    fn query(self: *Object, iid: *const GUID, out: *?*anyopaque) callconv(.c) HRESULT {
        out.* = null;
        var target: ?*Object = null;
        if (iid.eql(IID_IToastActivatedEventArgs)) target = &self.fixture.args;
        if (iid.eql(IID_IToastActivatedEventArgs2)) target = &self.fixture.args2;
        if (iid.eql(IID_IIterableStringObject)) target = &self.fixture.map;
        if (iid.eql(IID_IPropertyValue)) target = &self.fixture.property;
        if (target) |obj| {
            out.* = obj;
            _ = addRef(obj);
            return com.S_OK;
        }
        return com.E_NOINTERFACE;
    }
    fn addRef(self: *Object) callconv(.c) u32 { self.refs += 1; return self.refs; }
    fn release(self: *Object) callconv(.c) u32 { self.refs -= 1; return self.refs; }
    fn get(self: *Object, out: *?*anyopaque) callconv(.c) HRESULT {
        const f = self.fixture;
        switch (self.kind) {
            .args => out.* = &f.arguments,
            .args2 => { out.* = &f.map; _ = addRef(&f.map); },
            .map => { f.position = 0; out.* = &f.iterator; _ = addRef(&f.iterator); },
            .iterator => { out.* = &f.pair; _ = addRef(&f.pair); },
            .pair => out.* = &f.keys[f.position],
            .property => out.* = &f.values[f.position],
            else => return com.E_FAIL,
        }
        return com.S_OK;
    }
    fn pairValue(self: *Object, out: *?*anyopaque) callconv(.c) HRESULT {
        out.* = &self.fixture.property;
        _ = addRef(&self.fixture.property);
        return com.S_OK;
    }
    fn hasCurrent(self: *Object, out: *u8) callconv(.c) HRESULT {
        out.* = @intFromBool(self.fixture.position < 2);
        return com.S_OK;
    }
    fn moveNext(self: *Object, out: *u8) callconv(.c) HRESULT {
        self.fixture.position += 1;
        return hasCurrent(self, out);
    }
    fn buffer(h: HSTRING, len: *u32) callconv(.c) ?[*]const u16 {
        const s: *const String = @ptrCast(@alignCast(h.?));
        len.* = @intCast(s.value.len);
        return s.value.ptr;
    }
    fn delete(_: HSTRING) callconv(.c) HRESULT { return com.S_OK; }
    fn addEvent(self: *Object, handler: *Handler, token: *EventRegistrationToken) callconv(.c) HRESULT {
        const index = @intFromEnum(handler.kind);
        if (self.fixture.fail_add == index) return com.E_FAIL;
        token.* = .{ .value = @intCast(index) }; // zero is a valid token
        self.fixture.handlers[index] = handler;
        _ = Handler.addRef(handler);
        return com.S_OK;
    }
    fn removeEvent(self: *Object, token: EventRegistrationToken) callconv(.c) HRESULT {
        const index: usize = @intCast(token.value);
        const h = self.fixture.handlers[index].?;
        self.fixture.handlers[index] = null;
        self.fixture.revoked += 1;
        _ = Handler.release(h);
        return com.S_OK;
    }
};

test "toast: activation map iteration, delegate QI and safe disconnected late delivery" {
    const Capture = struct {
        calls: u32 = 0,
        good: bool = false,
        fn callback(ctx: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            const a = event.kind.activated;
            self.good = !a.data_error and std.mem.eql(u8, a.arguments, "reply&open") and
                a.user_input.len == 2 and std.mem.eql(u8, a.user_input[0].id, "reply") and
                std.mem.eql(u8, a.user_input[0].value, "你好 <text>") and
                std.mem.eql(u8, a.user_input[1].id, "second") and
                std.mem.eql(u8, a.user_input[1].value, "another answer") and
                std.mem.eql(u8, event.tag.?, "job");
        }
    };
    var capture = Capture{};
    var fixture = EventMock{};
    fixture.init();
    var pair_table = EventMock.table(.pair);
    pair_table[7] = @ptrCast(&EventMock.pairValue);
    fixture.pair.vtable = &pair_table;
    var owner = Toast{
        .allocator = testing.allocator, .aumid = undefined, .exe_path_w = undefined, .shortcut_name = undefined,
        .get_string_buffer = EventMock.buffer, .delete_string = EventMock.delete,
        .callback = .{ .context = &capture, .function = Capture.callback },
    };
    var registration = try Registration.init(&owner, &fixture.toast, .{ .title = "", .body = "", .tag = "job" });
    const handler = registration.handlers[0].?;
    _ = Handler.addRef(handler); // simulate WinRT retaining an in-flight delegate
    defer _ = Handler.release(handler);
    var result: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, Handler.queryInterface(handler, &delegate_iids[0], &result));
    releaseObj(result);
    try testing.expectEqual(com.E_NOINTERFACE, Handler.queryInterface(handler, &delegate_iids[1], &result));
    try testing.expect(result == null);
    try testing.expectEqual(com.S_OK, Handler.invoke(handler, null, &fixture.args));
    try testing.expect(capture.good);
    try testing.expectEqual(@as(u32, 1), capture.calls);
    registration.deinit();
    try testing.expectEqual(@as(u32, 3), fixture.revoked);
    try testing.expectEqual(com.S_OK, Handler.invoke(handler, null, &fixture.args));
    try testing.expectEqual(@as(u32, 1), capture.calls);
    inline for (.{ "args", "args2", "map", "iterator", "pair", "property", "toast" }) |name| {
        try testing.expectEqual(@as(u32, 1), @field(fixture, name).refs);
    }
}

test "toast: partially registered handlers unwind including token zero" {
    var fixture = EventMock{ .fail_add = 2 };
    fixture.init();
    var owner = Toast{
        .allocator = testing.allocator, .aumid = undefined, .exe_path_w = undefined, .shortcut_name = undefined,
        .get_string_buffer = EventMock.buffer, .delete_string = EventMock.delete,
    };
    try testing.expectError(error.EventRegistrationFailed, Registration.init(&owner, &fixture.toast, .{ .title = "", .body = "" }));
    try testing.expectEqual(@as(u32, 2), fixture.revoked);
    try testing.expectEqual(@as(u32, 1), fixture.toast.refs);
    for (fixture.handlers) |h| try testing.expect(h == null);
}

test "toast: compile all public backend entry points without showing notifications" {
    // Taking their addresses forces semantic analysis without side effects.
    const methods = .{ Toast.init, Toast.deinit, Toast.show, Toast.send, Toast.showOptions, Toast.updateProgress, Toast.status };
    inline for (methods) |f| std.mem.doNotOptimizeAway(&f);
}
