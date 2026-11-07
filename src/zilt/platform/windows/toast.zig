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

const RO_INIT_SINGLETHREADED: u32 = 1;
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

    pub fn show(self: *IToastNotifier, notification: ?*anyopaque) HRESULT {
        return self.lpVtbl.Show(self, notification);
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

/// Toast XML（ToastGeneric：标题 + 正文；Win10/11 通用模板）。
pub fn buildToastXml(alloc: std.mem.Allocator, title: []const u8, body: []const u8) ![]u8 {
    const t = try xmlEscape(alloc, title);
    defer alloc.free(t);
    const b = try xmlEscape(alloc, body);
    defer alloc.free(b);
    return std.fmt.allocPrint(alloc, "<toast><visual><binding template=\"ToastGeneric\"><text>{s}</text><text>{s}</text></binding></visual></toast>", .{ t, b });
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

    /// 初始化：加载 combase + 预编码 AUMID/exe 路径。失败抛错（调用方降级气球）。
    pub fn init(alloc: std.mem.Allocator, app_id: []const u8, app_name: []const u8, exe_path: []const u8) !Toast {
        const combase = win32.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("combase.dll"), null, win32.LOAD_WITH_ALTERED_SEARCH_PATH) orelse
            return error.CombaseNotFound;
        const get_proc = struct {
            fn f(h: HMODULE, name: [*:0]const u8) ?*anyopaque {
                return win32.GetProcAddress(h, name);
            }
        }.f;
        const ro_gaf: RoGetActivationFactoryFn = @ptrCast(get_proc(combase, "RoGetActivationFactory") orelse return error.RoMissing);
        const create_str: WindowsCreateStringFn = @ptrCast(get_proc(combase, "WindowsCreateString") orelse return error.RoMissing);
        const delete_str: WindowsDeleteStringFn = @ptrCast(get_proc(combase, "WindowsDeleteString") orelse return error.RoMissing);
        const ro_init: RoInitializeFn = @ptrCast(get_proc(combase, "RoInitialize") orelse return error.RoMissing);

        // UI 线程已 CoInitializeEx(STA)；RO_INIT_SINGLETHREADED → S_FALSE（已初始化）属正常。
        // RPC_E_CHANGED_MODE 亦不阻断（线程已初始化即可用）。
        const hr_init = ro_init(RO_INIT_SINGLETHREADED);
        if (!com.succeeded(hr_init) and hr_init != RPC_E_CHANGED_MODE)
            log.print("[toast] RoInitialize hr=0x{x}（继续）", .{@as(u32, @bitCast(hr_init))});

        return .{
            .allocator = alloc,
            .combase = combase,
            .ro_get_activation_factory = ro_gaf,
            .create_string = create_str,
            .delete_string = delete_str,
            .aumid = try std.unicode.utf8ToUtf16LeAllocZ(alloc, app_id),
            .exe_path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, exe_path),
            .shortcut_name = blk: {
                const clean = try shortcutFileName(alloc, app_name);
                defer alloc.free(clean);
                break :blk try std.unicode.utf8ToUtf16LeAllocZ(alloc, clean);
            },
        };
    }

    pub fn deinit(self: *Toast) void {
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

    /// 发送 Toast。true = WinRT 通道成功；false = 调用方降级（托盘气球）。
    pub fn send(self: *Toast, title: []const u8, body: []const u8) bool {
        const alloc = self.allocator;
        self.ensureShortcut();

        const xml_u8 = buildToastXml(alloc, title, body) catch return false;
        defer alloc.free(xml_u8);
        const xml_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, xml_u8) catch return false;
        defer alloc.free(xml_w);

        var hr_last: HRESULT = 0;
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

            // 5) Show
            hr_last = @as(*IToastNotifier, @ptrCast(@alignCast(notifier_ptr.?))).show(created.toast);
            if (!com.succeeded(hr_last)) break :step;
            return true;
        }
        log.print("[toast] winrt failed hr=0x{x}", .{@as(u32, @bitCast(hr_last))});
        return false;
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
    try testing.expectEqualStrings("a___", b);
    const c = try shortcutFileName(testing.allocator, "...");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("App", c);
}
