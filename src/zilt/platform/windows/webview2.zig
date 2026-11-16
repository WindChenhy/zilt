//! WebView2 COM 接口绑定（消费侧）—— vtable 槽位与 IID 逐字对齐官方 SDK 头文件。
//!
//! ABI 依据：Microsoft.Web.WebView2 1.0.4314.35 / build/native/include/WebView2.h
//! （逐槽核对记录见 docs/reference/webview2-binding-notes.md，勿凭记忆改动槽序）。
//!
//! 约定：
//!  - 接口 = extern struct { lpVtbl: *const VTable }；方法通过便捷包装调用。
//!  - 未使用的事件处理器参数类型一律 *anyopaque（指针 ABI 等价，避免声明无用接口）。
//!  - HRESULT/BOOL/枚举均为 4 字节；LPWSTR 出参由调用方 CoTaskMemFree。

const std = @import("std");
const com = @import("com.zig");
const win32 = @import("win32.zig");

pub const HRESULT = com.HRESULT;
pub const BOOL = win32.BOOL;
pub const LPCWSTR = win32.LPCWSTR;
pub const LPWSTR = win32.LPWSTR;
pub const EventRegistrationToken = com.EventRegistrationToken;

/// IStream 仅作透传（CreateWebResourceResponse / CapturePreview），不调用其方法。
pub const IStream = opaque {};

// ============================== IID ==============================

pub const IID_ICoreWebView2: com.GUID = .parse("{76ECEACB-0462-4D94-AC83-423A6793775E}");
pub const IID_ICoreWebView2Environment: com.GUID = .parse("{B96D755E-0319-4E92-A296-23436F46A1FC}");
pub const IID_ICoreWebView2Controller: com.GUID = .parse("{4D00C0D1-9434-4EB6-8078-8697A560334F}");
pub const IID_ICoreWebView2Settings: com.GUID = .parse("{E562E4F0-D7FA-43AC-8D71-C05150499F00}");
pub const IID_ICoreWebView2EnvironmentOptions: com.GUID = .parse("{2FDE08A8-1E9A-4766-8C05-95A9CEB9D1C5}");
pub const IID_ICoreWebView2WebMessageReceivedEventArgs: com.GUID = .parse("{0F99A40C-E962-4207-9E92-E3D542EFF849}");
pub const IID_ICoreWebView2WebResourceRequestedEventArgs: com.GUID = .parse("{453E667F-12C7-49D4-BE6D-DDBE7956F57A}");
pub const IID_ICoreWebView2WebResourceRequest: com.GUID = .parse("{97055CD4-512C-4264-8B5F-E3F446CEA6A5}");
pub const IID_ICoreWebView2WebResourceResponse: com.GUID = .parse("{AAFCC94F-FA27-48FD-97DF-830EF75AAEC9}");

pub const IID_EnvironmentCompletedHandler: com.GUID = .parse("{4E8A3389-C9D8-4BD2-B6B5-124FEE6CC14D}");
pub const IID_ControllerCompletedHandler: com.GUID = .parse("{6C4819F3-C9B7-4260-8127-C9F5BDE7F68C}");
pub const IID_ExecuteScriptCompletedHandler: com.GUID = .parse("{49511172-CC67-4BCA-9923-137112F4C4CC}");
pub const IID_WebMessageReceivedEventHandler: com.GUID = .parse("{57213F19-00E6-49FA-8E07-898EA01ECBD2}");
pub const IID_WebResourceRequestedEventHandler: com.GUID = .parse("{AB00B74C-15F1-4646-80E8-E76341D25D71}");
pub const IID_NavigationCompletedEventHandler: com.GUID = .parse("{D33A35BF-1C49-4F98-93AB-006E0533FE1C}");
pub const IID_ICoreWebView2NavigationCompletedEventArgs: com.GUID = .parse("{30D68B7D-20D9-4752-A9CA-EC8448FBB5C1}");
pub const IID_AddScriptToExecuteOnDocumentCreatedCompletedHandler: com.GUID = .parse("{B99369F3-9B11-47B5-BC6F-8E7895FCEA17}");
/// ICoreWebView2CallDevToolsProtocolMethodCompletedHandler（WebView2.h）
pub const IID_CallDevToolsProtocolMethodCompletedHandler: com.GUID = .parse("{5C4889F0-5EF6-4C5A-952C-D8F1B92D0574}");

// ============================== 枚举 ==============================

/// COREWEBVIEW2_WEB_RESOURCE_CONTEXT（WebView2.h 2966–2985）
pub const WEB_RESOURCE_CONTEXT_ALL: u32 = 0;
pub const WEB_RESOURCE_CONTEXT_DOCUMENT: u32 = 1;
pub const WEB_RESOURCE_CONTEXT_SCRIPT: u32 = 6;

/// COREWEBVIEW2_MOVE_FOCUS_REASON
pub const MOVE_FOCUS_REASON_PROGRAMMATIC: u32 = 0;
pub const MOVE_FOCUS_REASON_NEXT: u32 = 1;
pub const MOVE_FOCUS_REASON_PREVIOUS: u32 = 2;

// ============================== ICoreWebView2Environment ==============================

pub const ICoreWebView2Environment = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Environment, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2Environment) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2Environment) callconv(.c) u32,
        CreateCoreWebView2Controller: *const fn (*ICoreWebView2Environment, win32.HWND, *anyopaque) callconv(.c) HRESULT,
        CreateWebResourceResponse: *const fn (*ICoreWebView2Environment, ?*IStream, c_int, LPCWSTR, LPCWSTR, *?*ICoreWebView2WebResourceResponse) callconv(.c) HRESULT,
        get_BrowserVersionString: *const fn (*ICoreWebView2Environment, *?LPWSTR) callconv(.c) HRESULT,
        add_NewBrowserVersionAvailable: *const fn (*ICoreWebView2Environment, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
        remove_NewBrowserVersionAvailable: *const fn (*ICoreWebView2Environment, EventRegistrationToken) callconv(.c) HRESULT,
    };

    pub fn createController(self: *ICoreWebView2Environment, parent_window: win32.HWND, handler: *anyopaque) HRESULT {
        return self.lpVtbl.CreateCoreWebView2Controller(self, parent_window, handler);
    }

    pub fn createWebResourceResponse(
        self: *ICoreWebView2Environment,
        content: ?*IStream,
        status_code: c_int,
        reason_phrase: LPCWSTR,
        headers: LPCWSTR,
    ) struct { hr: HRESULT, response: ?*ICoreWebView2WebResourceResponse } {
        var response: ?*ICoreWebView2WebResourceResponse = null;
        const hr = self.lpVtbl.CreateWebResourceResponse(self, content, status_code, reason_phrase, headers, &response);
        return .{ .hr = hr, .response = response };
    }

    pub fn getBrowserVersionString(self: *ICoreWebView2Environment) struct { hr: HRESULT, value: ?LPWSTR } {
        var value: ?LPWSTR = null;
        const hr = self.lpVtbl.get_BrowserVersionString(self, &value);
        return .{ .hr = hr, .value = value };
    }
};

// ============================== ICoreWebView2Environment10 ==============================
// v0.3.2：ControllerOptions（无痕窗口）。ABI/IID 取自官方 WebView2.h：
// IID {ee0eb9df-6f12-46ce-b53f-3f47b9c928e0}。flat vtable 22 槽（0–19 既有）+
// CreateCoreWebView2ControllerOptions(20) / CreateCoreWebView2ControllerWithOptions(21)
// / CreateCoreWebView2CompositionControllerWithOptions(22)。

pub const IID_ICoreWebView2Environment10: com.GUID = .parse("{ee0eb9df-6f12-46ce-b53f-3f47b9c928e0}");

pub const ICoreWebView2Environment10 = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        base: [20]?*const anyopaque, // QI..CreateContextMenuItem（槽 0–19）
        CreateCoreWebView2ControllerOptions: *const fn (*ICoreWebView2Environment10, *?*ICoreWebView2ControllerOptions) callconv(.c) HRESULT, // 20
        CreateCoreWebView2ControllerWithOptions: *const fn (*ICoreWebView2Environment10, win32.HWND, ?*ICoreWebView2ControllerOptions, *anyopaque) callconv(.c) HRESULT, // 21
        CreateCoreWebView2CompositionControllerWithOptions: *const fn (*ICoreWebView2Environment10, win32.HWND, ?*ICoreWebView2ControllerOptions, ?*anyopaque, *anyopaque) callconv(.c) HRESULT, // 22
    };

    /// QI 失败（老运行时 < 1.0.1722）返回 null——调用方回退普通 controller。
    pub fn fromEnvironment(env: *ICoreWebView2Environment) ?*ICoreWebView2Environment10 {
        var out: ?*anyopaque = null;
        const hr = env.lpVtbl.QueryInterface(env, &IID_ICoreWebView2Environment10, &out);
        if (com.failed(hr)) return null;
        return @ptrCast(@alignCast(out.?));
    }

    pub fn release(self: *ICoreWebView2Environment10) void {
        const f: *const fn (*ICoreWebView2Environment10) callconv(.c) u32 = @ptrCast(self.lpVtbl.base[2] orelse return);
        _ = f(self);
    }

    pub fn createControllerOptions(self: *ICoreWebView2Environment10) struct { hr: HRESULT, options: ?*ICoreWebView2ControllerOptions } {
        var options: ?*ICoreWebView2ControllerOptions = null;
        const hr = self.lpVtbl.CreateCoreWebView2ControllerOptions(self, &options);
        return .{ .hr = hr, .options = options };
    }

    pub fn createControllerWithOptions(self: *ICoreWebView2Environment10, parent: win32.HWND, options: ?*ICoreWebView2ControllerOptions, handler: *anyopaque) HRESULT {
        return self.lpVtbl.CreateCoreWebView2ControllerWithOptions(self, parent, options, handler);
    }
};

// ============================== ICoreWebView2ControllerOptions ==============================
// v0.3.2：无痕窗口开关。IID {12aae616-8ccb-44ec-bcb3-eb18311881635}，vtable：
// QI/AddRef/Release + get/put_ProfileName + get/put_IsInPrivateModeEnabled。

pub const IID_ICoreWebView2ControllerOptions: com.GUID = .parse("{12aae616-8ccb-44ec-bcb3-eb18311881635}");

pub const ICoreWebView2ControllerOptions = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2ControllerOptions, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2ControllerOptions) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2ControllerOptions) callconv(.c) u32,
        get_ProfileName: *const fn (*ICoreWebView2ControllerOptions, *?LPWSTR) callconv(.c) HRESULT,
        put_ProfileName: *const fn (*ICoreWebView2ControllerOptions, LPCWSTR) callconv(.c) HRESULT,
        get_IsInPrivateModeEnabled: *const fn (*ICoreWebView2ControllerOptions, *BOOL) callconv(.c) HRESULT,
        put_IsInPrivateModeEnabled: *const fn (*ICoreWebView2ControllerOptions, BOOL) callconv(.c) HRESULT,
    };

    pub fn putInPrivateMode(self: *ICoreWebView2ControllerOptions, enabled: bool) HRESULT {
        return self.lpVtbl.put_IsInPrivateModeEnabled(self, if (enabled) 1 else 0);
    }

    pub fn release(self: *ICoreWebView2ControllerOptions) void {
        _ = self.lpVtbl.Release(self);
    }
};

// ============================== ICoreWebView2Controller ==============================

pub const ICoreWebView2Controller = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Controller, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2Controller) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2Controller) callconv(.c) u32,
        get_IsVisible: *const fn (*ICoreWebView2Controller, *BOOL) callconv(.c) HRESULT,
        put_IsVisible: *const fn (*ICoreWebView2Controller, BOOL) callconv(.c) HRESULT,
        get_Bounds: *const fn (*ICoreWebView2Controller, *win32.RECT) callconv(.c) HRESULT,
        put_Bounds: *const fn (*ICoreWebView2Controller, win32.RECT) callconv(.c) HRESULT,
        get_ZoomFactor: *const fn (*ICoreWebView2Controller, *f64) callconv(.c) HRESULT,
        put_ZoomFactor: *const fn (*ICoreWebView2Controller, f64) callconv(.c) HRESULT,
        add_ZoomFactorChanged: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
        remove_ZoomFactorChanged: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.c) HRESULT,
        SetBoundsAndZoomFactor: *const fn (*ICoreWebView2Controller, win32.RECT, f64) callconv(.c) HRESULT,
        MoveFocus: *const fn (*ICoreWebView2Controller, u32) callconv(.c) HRESULT,
        add_MoveFocusRequested: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
        remove_MoveFocusRequested: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.c) HRESULT,
        add_GotFocus: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
        remove_GotFocus: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.c) HRESULT,
        add_LostFocus: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
        remove_LostFocus: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.c) HRESULT,
        add_AcceleratorKeyPressed: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
        remove_AcceleratorKeyPressed: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.c) HRESULT,
        get_ParentWindow: *const fn (*ICoreWebView2Controller, *win32.HWND) callconv(.c) HRESULT,
        put_ParentWindow: *const fn (*ICoreWebView2Controller, win32.HWND) callconv(.c) HRESULT,
        NotifyParentWindowPositionChanged: *const fn (*ICoreWebView2Controller) callconv(.c) HRESULT,
        Close: *const fn (*ICoreWebView2Controller) callconv(.c) HRESULT,
        get_CoreWebView2: *const fn (*ICoreWebView2Controller, *?*ICoreWebView2) callconv(.c) HRESULT,
    };

    pub fn putIsVisible(self: *ICoreWebView2Controller, visible: BOOL) HRESULT {
        return self.lpVtbl.put_IsVisible(self, visible);
    }
    pub fn putBounds(self: *ICoreWebView2Controller, bounds: win32.RECT) HRESULT {
        return self.lpVtbl.put_Bounds(self, bounds);
    }
    pub fn getCoreWebView2(self: *ICoreWebView2Controller) struct { hr: HRESULT, webview: ?*ICoreWebView2 } {
        var webview: ?*ICoreWebView2 = null;
        const hr = self.lpVtbl.get_CoreWebView2(self, &webview);
        return .{ .hr = hr, .webview = webview };
    }

    /// ICoreWebView2Controller2（DefaultBackgroundColor：透明/背景色）。
    pub fn getController2(self: *ICoreWebView2Controller) ?*ICoreWebView2Controller2 {
        var out: ?*anyopaque = null;
        const hr = self.lpVtbl.QueryInterface(self, &IID_Controller2, &out);
        if (com.failed(hr) or out == null) return null;
        return @ptrCast(@alignCast(out.?));
    }
};

pub const IID_Controller2: com.GUID = .parse("{c979903e-d4ca-4228-92eb-47ee3fa96eab}");

/// COREWVIEW2_COLOR（IDL 字段序 A,R,G,B；整体 4 字节按值传递）。
pub const Color = extern struct {
    a: u8,
    r: u8,
    g: u8,
    b: u8,
};

/// ICoreWebView2Controller2：在 Controller 的 26 个槽后追加
/// get_DefaultBackgroundColor / put_DefaultBackgroundColor。
pub const ICoreWebView2Controller2 = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        base: [26]?*const anyopaque,
        get_DefaultBackgroundColor: *const fn (*ICoreWebView2Controller2, *Color) callconv(.c) HRESULT,
        put_DefaultBackgroundColor: *const fn (*ICoreWebView2Controller2, Color) callconv(.c) HRESULT,
    };

    pub fn putDefaultBackgroundColor(self: *ICoreWebView2Controller2, color: Color) HRESULT {
        return self.lpVtbl.put_DefaultBackgroundColor(self, color);
    }

    pub fn release(self: *ICoreWebView2Controller2) void {
        const f: *const fn (*ICoreWebView2Controller2) callconv(.c) u32 = @ptrCast(self.lpVtbl.base[2] orelse return);
        _ = f(self);
    }
};

// ============================== ICoreWebView2Settings ==============================

pub const ICoreWebView2Settings = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Settings, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2Settings) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2Settings) callconv(.c) u32,
        get_IsScriptEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
        put_IsScriptEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
        get_IsWebMessageEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
        put_IsWebMessageEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
        get_AreDefaultScriptDialogsEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
        put_AreDefaultScriptDialogsEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
        get_IsStatusBarEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
        put_IsStatusBarEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
        get_AreDevToolsEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
        put_AreDevToolsEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
        get_AreDefaultContextMenusEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
        put_AreDefaultContextMenusEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
        get_AreHostObjectsAllowed: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
        put_AreHostObjectsAllowed: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
        get_IsZoomControlEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
        put_IsZoomControlEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
        get_IsBuiltInErrorPageEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
        put_IsBuiltInErrorPageEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
    };
};

// ============================== ICoreWebView2 ==============================

pub const ICoreWebView2 = extern struct {
    lpVtbl: *const VTable,

    /// WebView2.h 3035–3234（58 个自有方法，槽 3–60），顺序已逐槽核对。
    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2) callconv(.c) u32,
        get_Settings: *const fn (*ICoreWebView2, *?*ICoreWebView2Settings) callconv(.c) HRESULT, // 3
        get_Source: *const fn (*ICoreWebView2, *?LPWSTR) callconv(.c) HRESULT, // 4
        Navigate: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT, // 5
        NavigateToString: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT, // 6
        add_NavigationStarting: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 7
        remove_NavigationStarting: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 8
        add_ContentLoading: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 9
        remove_ContentLoading: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 10
        add_SourceChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 11
        remove_SourceChanged: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 12
        add_HistoryChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 13
        remove_HistoryChanged: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 14
        add_NavigationCompleted: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 15
        remove_NavigationCompleted: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 16
        add_FrameNavigationStarting: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 17
        remove_FrameNavigationStarting: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 18
        add_FrameNavigationCompleted: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 19
        remove_FrameNavigationCompleted: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 20
        add_ScriptDialogOpening: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 21
        remove_ScriptDialogOpening: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 22
        add_PermissionRequested: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 23
        remove_PermissionRequested: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 24
        add_ProcessFailed: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 25
        remove_ProcessFailed: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 26
        AddScriptToExecuteOnDocumentCreated: *const fn (*ICoreWebView2, LPCWSTR, *anyopaque) callconv(.c) HRESULT, // 27
        RemoveScriptToExecuteOnDocumentCreated: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT, // 28
        ExecuteScript: *const fn (*ICoreWebView2, LPCWSTR, *anyopaque) callconv(.c) HRESULT, // 29
        CapturePreview: *const fn (*ICoreWebView2, u32, ?*IStream, *anyopaque) callconv(.c) HRESULT, // 30
        Reload: *const fn (*ICoreWebView2) callconv(.c) HRESULT, // 31
        PostWebMessageAsJson: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT, // 32
        PostWebMessageAsString: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT, // 33
        add_WebMessageReceived: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 34
        remove_WebMessageReceived: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 35
        CallDevToolsProtocolMethod: *const fn (*ICoreWebView2, LPCWSTR, LPCWSTR, *anyopaque) callconv(.c) HRESULT, // 36
        get_BrowserProcessId: *const fn (*ICoreWebView2, *u32) callconv(.c) HRESULT, // 37
        get_CanGoBack: *const fn (*ICoreWebView2, *BOOL) callconv(.c) HRESULT, // 38
        get_CanGoForward: *const fn (*ICoreWebView2, *BOOL) callconv(.c) HRESULT, // 39
        GoBack: *const fn (*ICoreWebView2) callconv(.c) HRESULT, // 40
        GoForward: *const fn (*ICoreWebView2) callconv(.c) HRESULT, // 41
        GetDevToolsProtocolEventReceiver: *const fn (*ICoreWebView2, LPCWSTR, *?*anyopaque) callconv(.c) HRESULT, // 42
        Stop: *const fn (*ICoreWebView2) callconv(.c) HRESULT, // 43
        add_NewWindowRequested: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 44
        remove_NewWindowRequested: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 45
        add_DocumentTitleChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 46
        remove_DocumentTitleChanged: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 47
        get_DocumentTitle: *const fn (*ICoreWebView2, *?LPWSTR) callconv(.c) HRESULT, // 48
        AddHostObjectToScript: *const fn (*ICoreWebView2, LPCWSTR, ?*anyopaque) callconv(.c) HRESULT, // 49
        RemoveHostObjectFromScript: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT, // 50
        OpenDevToolsWindow: *const fn (*ICoreWebView2) callconv(.c) HRESULT, // 51
        add_ContainsFullScreenElementChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 52
        remove_ContainsFullScreenElementChanged: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 53
        get_ContainsFullScreenElement: *const fn (*ICoreWebView2, *BOOL) callconv(.c) HRESULT, // 54
        add_WebResourceRequested: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 55
        remove_WebResourceRequested: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 56
        AddWebResourceRequestedFilter: *const fn (*ICoreWebView2, LPCWSTR, u32) callconv(.c) HRESULT, // 57
        RemoveWebResourceRequestedFilter: *const fn (*ICoreWebView2, LPCWSTR, u32) callconv(.c) HRESULT, // 58
        add_WindowCloseRequested: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT, // 59
        remove_WindowCloseRequested: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT, // 60
    };

    pub fn navigate(self: *ICoreWebView2, uri: LPCWSTR) HRESULT {
        return self.lpVtbl.Navigate(self, uri);
    }
    pub fn navigateToString(self: *ICoreWebView2, html: LPCWSTR) HRESULT {
        return self.lpVtbl.NavigateToString(self, html);
    }
    pub fn addScriptToExecuteOnDocumentCreated(self: *ICoreWebView2, js: LPCWSTR, handler: *anyopaque) HRESULT {
        return self.lpVtbl.AddScriptToExecuteOnDocumentCreated(self, js, handler);
    }
    pub fn executeScript(self: *ICoreWebView2, js: LPCWSTR, handler: *anyopaque) HRESULT {
        return self.lpVtbl.ExecuteScript(self, js, handler);
    }
    pub fn reload(self: *ICoreWebView2) HRESULT {
        return self.lpVtbl.Reload(self);
    }
    pub fn postWebMessageAsJson(self: *ICoreWebView2, json: LPCWSTR) HRESULT {
        return self.lpVtbl.PostWebMessageAsJson(self, json);
    }
    pub fn postWebMessageAsString(self: *ICoreWebView2, message: LPCWSTR) HRESULT {
        return self.lpVtbl.PostWebMessageAsString(self, message);
    }
    pub fn addWebMessageReceived(self: *ICoreWebView2, handler: *anyopaque, token: *EventRegistrationToken) HRESULT {
        return self.lpVtbl.add_WebMessageReceived(self, handler, token);
    }
    pub fn addWebResourceRequested(self: *ICoreWebView2, handler: *anyopaque, token: *EventRegistrationToken) HRESULT {
        return self.lpVtbl.add_WebResourceRequested(self, handler, token);
    }
    pub fn addNavigationCompleted(self: *ICoreWebView2, handler: *anyopaque, token: *EventRegistrationToken) HRESULT {
        return self.lpVtbl.add_NavigationCompleted(self, handler, token);
    }
    pub fn addWebResourceRequestedFilter(self: *ICoreWebView2, uri: LPCWSTR, context: u32) HRESULT {
        return self.lpVtbl.AddWebResourceRequestedFilter(self, uri, context);
    }
};

// ============================== ICoreWebView2_4（Profile 入口） ==============================
// v0.3.2：autofill/password 设置走 Profile6。IID {20d02d59-6df2-42dc-bd06-f98a694b1302}，
// 自有方法仅 get_Profile（QI/AddRef/Release 之后第 4 槽）。

pub const IID_ICoreWebView2_4: com.GUID = .parse("{20d02d59-6df2-42dc-bd06-f98a694b1302}");

pub const ICoreWebView2_4 = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2_4, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2_4) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2_4) callconv(.c) u32,
        get_Profile: *const fn (*ICoreWebView2_4, *?*ICoreWebView2Profile) callconv(.c) HRESULT,
    };

    /// QI 失败（老运行时）返回 null。
    pub fn fromWebView(webview: *ICoreWebView2) ?*ICoreWebView2_4 {
        var out: ?*anyopaque = null;
        const hr = webview.lpVtbl.QueryInterface(webview, &IID_ICoreWebView2_4, &out);
        if (com.failed(hr)) return null;
        return @ptrCast(@alignCast(out.?));
    }

    pub fn release(self: *ICoreWebView2_4) void {
        _ = self.lpVtbl.Release(self);
    }

    pub fn getProfile(self: *ICoreWebView2_4) struct { hr: HRESULT, profile: ?*ICoreWebView2Profile } {
        var profile: ?*ICoreWebView2Profile = null;
        const hr = self.lpVtbl.get_Profile(self, &profile);
        return .{ .hr = hr, .profile = profile };
    }
};

// ============================== ICoreWebView2Profile6 ==============================
// v0.3.2：autofill / password autosave 开关。IID {bd82fa6a-1d65-4c33-b2b4-0393020cc61b}。
// flat vtable：0–2 IUnknown + Profile(3–9) + Profile2(10–12) + Profile3(13–14) +
// Profile4(15–16) + Profile5 get_CookieManager(17) + Profile6 自有四槽（18–21）。

pub const IID_ICoreWebView2Profile6: com.GUID = .parse("{bd82fa6a-1d65-4c33-b2b4-0393020cc61b}");

pub const ICoreWebView2Profile = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Profile, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2Profile) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2Profile) callconv(.c) u32,
    };

    pub fn release(self: *ICoreWebView2Profile) void {
        _ = self.lpVtbl.Release(self);
    }

    /// QI 到 Profile6（老运行时返回 null）。
    pub fn asProfile6(self: *ICoreWebView2Profile) ?*ICoreWebView2Profile6 {
        var out: ?*anyopaque = null;
        const hr = self.lpVtbl.QueryInterface(self, &IID_ICoreWebView2Profile6, &out);
        if (com.failed(hr)) return null;
        return @ptrCast(@alignCast(out.?));
    }
};

pub const ICoreWebView2Profile6 = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        base: [18]?*const anyopaque, // QI..get_CookieManager（槽 0–17）
        get_IsPasswordAutosaveEnabled: *const fn (*ICoreWebView2Profile6, *BOOL) callconv(.c) HRESULT, // 18
        put_IsPasswordAutosaveEnabled: *const fn (*ICoreWebView2Profile6, BOOL) callconv(.c) HRESULT, // 19
        get_IsGeneralAutofillEnabled: *const fn (*ICoreWebView2Profile6, *BOOL) callconv(.c) HRESULT, // 20
        put_IsGeneralAutofillEnabled: *const fn (*ICoreWebView2Profile6, BOOL) callconv(.c) HRESULT, // 21
    };

    pub fn putPasswordAutosave(self: *ICoreWebView2Profile6, enabled: bool) HRESULT {
        return self.lpVtbl.put_IsPasswordAutosaveEnabled(self, if (enabled) 1 else 0);
    }

    pub fn putGeneralAutofill(self: *ICoreWebView2Profile6, enabled: bool) HRESULT {
        return self.lpVtbl.put_IsGeneralAutofillEnabled(self, if (enabled) 1 else 0);
    }

    pub fn release(self: *ICoreWebView2Profile6) void {
        const f: *const fn (*ICoreWebView2Profile6) callconv(.c) u32 = @ptrCast(self.lpVtbl.base[2] orelse return);
        _ = f(self);
    }
};

// ============================== 事件参数 / 请求 / 响应 ==============================

pub const ICoreWebView2WebMessageReceivedEventArgs = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2WebMessageReceivedEventArgs) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2WebMessageReceivedEventArgs) callconv(.c) u32,
        get_Source: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *?LPWSTR) callconv(.c) HRESULT,
        get_WebMessageAsJson: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *?LPWSTR) callconv(.c) HRESULT,
        TryGetWebMessageAsString: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *?LPWSTR) callconv(.c) HRESULT,
    };

    /// 出参字符串需 CoTaskMemFree。
    pub fn getWebMessageAsJson(self: *ICoreWebView2WebMessageReceivedEventArgs) struct { hr: HRESULT, value: ?LPWSTR } {
        var value: ?LPWSTR = null;
        const hr = self.lpVtbl.get_WebMessageAsJson(self, &value);
        return .{ .hr = hr, .value = value };
    }

    /// 出参字符串需 CoTaskMemFree（发消息的文档 URI，用于 origin 校验）。
    pub fn getSource(self: *ICoreWebView2WebMessageReceivedEventArgs) struct { hr: HRESULT, value: ?LPWSTR } {
        var value: ?LPWSTR = null;
        const hr = self.lpVtbl.get_Source(self, &value);
        return .{ .hr = hr, .value = value };
    }
};

pub const ICoreWebView2WebResourceRequestedEventArgs = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2WebResourceRequestedEventArgs) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2WebResourceRequestedEventArgs) callconv(.c) u32,
        get_Request: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, *?*ICoreWebView2WebResourceRequest) callconv(.c) HRESULT,
        get_Response: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, *?*ICoreWebView2WebResourceResponse) callconv(.c) HRESULT,
        put_Response: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, *ICoreWebView2WebResourceResponse) callconv(.c) HRESULT,
        GetDeferral: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, *?*anyopaque) callconv(.c) HRESULT,
        get_ResourceContext: *const fn (*ICoreWebView2WebResourceRequestedEventArgs, *u32) callconv(.c) HRESULT,
    };

    pub fn getRequest(self: *ICoreWebView2WebResourceRequestedEventArgs) struct { hr: HRESULT, request: ?*ICoreWebView2WebResourceRequest } {
        var request: ?*ICoreWebView2WebResourceRequest = null;
        const hr = self.lpVtbl.get_Request(self, &request);
        return .{ .hr = hr, .request = request };
    }
    pub fn putResponse(self: *ICoreWebView2WebResourceRequestedEventArgs, response: *ICoreWebView2WebResourceResponse) HRESULT {
        return self.lpVtbl.put_Response(self, response);
    }
};

pub const ICoreWebView2WebResourceRequest = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebResourceRequest, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2WebResourceRequest) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2WebResourceRequest) callconv(.c) u32,
        get_Uri: *const fn (*ICoreWebView2WebResourceRequest, *?LPWSTR) callconv(.c) HRESULT,
        put_Uri: *const fn (*ICoreWebView2WebResourceRequest, LPCWSTR) callconv(.c) HRESULT,
        get_Method: *const fn (*ICoreWebView2WebResourceRequest, *?LPWSTR) callconv(.c) HRESULT,
        put_Method: *const fn (*ICoreWebView2WebResourceRequest, LPCWSTR) callconv(.c) HRESULT,
        get_Content: *const fn (*ICoreWebView2WebResourceRequest, *?*IStream) callconv(.c) HRESULT,
        put_Content: *const fn (*ICoreWebView2WebResourceRequest, ?*IStream) callconv(.c) HRESULT,
        get_Headers: *const fn (*ICoreWebView2WebResourceRequest, *?*ICoreWebView2HttpRequestHeaders) callconv(.c) HRESULT,
    };

    /// 出参字符串需 CoTaskMemFree。
    pub fn getUri(self: *ICoreWebView2WebResourceRequest) struct { hr: HRESULT, value: ?LPWSTR } {
        var value: ?LPWSTR = null;
        const hr = self.lpVtbl.get_Uri(self, &value);
        return .{ .hr = hr, .value = value };
    }

    pub fn getHeaders(self: *ICoreWebView2WebResourceRequest) struct { hr: HRESULT, headers: ?*ICoreWebView2HttpRequestHeaders } {
        var headers: ?*ICoreWebView2HttpRequestHeaders = null;
        const hr = self.lpVtbl.get_Headers(self, &headers);
        return .{ .hr = hr, .headers = headers };
    }
};

/// 请求头集合（Phase C：读取 Accept-Encoding / If-None-Match）。
/// vtable 槽位对齐 WebView2.h；无 IID 常量（get_Headers 直接返回该类型，无需 QI）。
pub const ICoreWebView2HttpRequestHeaders = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2HttpRequestHeaders, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2HttpRequestHeaders) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2HttpRequestHeaders) callconv(.c) u32,
        GetHeader: *const fn (*ICoreWebView2HttpRequestHeaders, LPCWSTR, *?LPWSTR) callconv(.c) HRESULT, // 3
        GetHeaders: *const fn (*ICoreWebView2HttpRequestHeaders, LPCWSTR, *?*anyopaque) callconv(.c) HRESULT, // 4
        Contains: *const fn (*ICoreWebView2HttpRequestHeaders, LPCWSTR, *BOOL) callconv(.c) HRESULT, // 5
        RemoveHeader: *const fn (*ICoreWebView2HttpRequestHeaders, LPCWSTR) callconv(.c) HRESULT, // 6
        SetHeader: *const fn (*ICoreWebView2HttpRequestHeaders, LPCWSTR, LPCWSTR) callconv(.c) HRESULT, // 7
        First: *const fn (*ICoreWebView2HttpRequestHeaders, *?*anyopaque) callconv(.c) HRESULT, // 8
    };

    /// 取单个头；头不存在时 hr != 0。出参字符串需 CoTaskMemFree。
    pub fn getHeader(self: *ICoreWebView2HttpRequestHeaders, name: LPCWSTR) struct { hr: HRESULT, value: ?LPWSTR } {
        var value: ?LPWSTR = null;
        const hr = self.lpVtbl.GetHeader(self, name, &value);
        return .{ .hr = hr, .value = value };
    }
};

pub const ICoreWebView2HttpResponseHeaders = extern struct {
    lpVtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2HttpResponseHeaders, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2HttpResponseHeaders) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2HttpResponseHeaders) callconv(.c) u32,
        AppendHeader: *const fn (*ICoreWebView2HttpResponseHeaders, LPCWSTR, LPCWSTR) callconv(.c) HRESULT,
        Contains: *const fn (*ICoreWebView2HttpResponseHeaders, LPCWSTR, *BOOL) callconv(.c) HRESULT,
        GetHeader: *const fn (*ICoreWebView2HttpResponseHeaders, LPCWSTR, *?LPWSTR) callconv(.c) HRESULT,
        GetHeaders: *const fn (*ICoreWebView2HttpResponseHeaders, LPCWSTR, *?*anyopaque) callconv(.c) HRESULT,
        GetIterator: *const fn (*ICoreWebView2HttpResponseHeaders, *?*anyopaque) callconv(.c) HRESULT,
    };
};

pub const ICoreWebView2WebResourceResponse = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2WebResourceResponse, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2WebResourceResponse) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2WebResourceResponse) callconv(.c) u32,
        get_Content: *const fn (*ICoreWebView2WebResourceResponse, *?*IStream) callconv(.c) HRESULT,
        put_Content: *const fn (*ICoreWebView2WebResourceResponse, ?*IStream) callconv(.c) HRESULT,
        get_Headers: *const fn (*ICoreWebView2WebResourceResponse, *?*ICoreWebView2HttpResponseHeaders) callconv(.c) HRESULT,
        get_StatusCode: *const fn (*ICoreWebView2WebResourceResponse, *c_int) callconv(.c) HRESULT,
        put_StatusCode: *const fn (*ICoreWebView2WebResourceResponse, c_int) callconv(.c) HRESULT,
        get_ReasonPhrase: *const fn (*ICoreWebView2WebResourceResponse, *?LPWSTR) callconv(.c) HRESULT,
        put_ReasonPhrase: *const fn (*ICoreWebView2WebResourceResponse, LPCWSTR) callconv(.c) HRESULT,
    };
};

// ============================== ICoreWebView2NavigationCompletedEventArgs ==============================

pub const ICoreWebView2NavigationCompletedEventArgs = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ICoreWebView2NavigationCompletedEventArgs, *const com.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ICoreWebView2NavigationCompletedEventArgs) callconv(.c) u32,
        Release: *const fn (*ICoreWebView2NavigationCompletedEventArgs) callconv(.c) u32,
        get_IsSuccess: *const fn (*ICoreWebView2NavigationCompletedEventArgs, *BOOL) callconv(.c) HRESULT,
        get_WebErrorStatus: *const fn (*ICoreWebView2NavigationCompletedEventArgs, *u32) callconv(.c) HRESULT,
        get_NavigationId: *const fn (*ICoreWebView2NavigationCompletedEventArgs, *u64) callconv(.c) HRESULT,
    };

    pub fn getIsSuccess(self: *ICoreWebView2NavigationCompletedEventArgs) struct { hr: HRESULT, value: BOOL } {
        var value: BOOL = 0;
        const hr = self.lpVtbl.get_IsSuccess(self, &value);
        return .{ .hr = hr, .value = value };
    }
    pub fn getWebErrorStatus(self: *ICoreWebView2NavigationCompletedEventArgs) struct { hr: HRESULT, value: u32 } {
        var value: u32 = 0;
        const hr = self.lpVtbl.get_WebErrorStatus(self, &value);
        return .{ .hr = hr, .value = value };
    }
};

// ============================== 通用小工具 ==============================

pub fn freeCoString(s: ?win32.LPWSTR) void {
    win32.CoTaskMemFree(@ptrCast(s));
}
