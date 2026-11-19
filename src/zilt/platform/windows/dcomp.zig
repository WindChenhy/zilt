//! v0.3.12 A11：DirectComposition 最小绑定（dcomp.dll 动态加载）。
//!
//! 组合模式 WebView 的视觉树挂载：DCompositionCreateDevice →
//! CreateTargetForHwnd(hwnd, topmost) → CreateVisual → controller.put_RootVisualTarget
//! → target.SetRoot(visual) → Commit。
//!
//! ABI 槽位以 Windows SDK 10.0.26100.0 um/dcomp.h 逐一核对（DECLARE_INTERFACE_IID_
//! 段）：IDCompositionDevice {C37EA93A-…} Commit(3)/CreateTargetForHwnd(6)/
//! CreateVisual(7)；IDCompositionTarget {EACDD04C-…} SetRoot(3)；
//! IDCompositionVisual {4D93059D-…} SetContent(11)/AddVisual(12)。
//! IID 值同样取自该头（DECLARE_INTERFACE_IID_ 第三参）。
const std = @import("std");
const win32 = @import("win32.zig");
const com = @import("com.zig");

pub const IID_IDCompositionDevice: com.GUID = .parse("{C37EA93A-E7AA-450D-B16F-9746CB0407F3}");

pub const Device = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*Device, *const com.GUID, *?*anyopaque) callconv(.c) com.HRESULT,
        AddRef: *const fn (*Device) callconv(.c) u32,
        Release: *const fn (*Device) callconv(.c) u32,
        Commit: *const fn (*Device) callconv(.c) com.HRESULT, // 3
        WaitForCommitCompletion: *const fn (*Device) callconv(.c) com.HRESULT, // 4
        GetFrameStatistics: *const anyopaque, // 5
        CreateTargetForHwnd: *const fn (*Device, win32.HWND, i32, *?*Target) callconv(.c) com.HRESULT, // 6
        CreateVisual: *const fn (*Device, *?*Visual) callconv(.c) com.HRESULT, // 7
    };

    pub fn release(self: *Device) void {
        _ = self.lpVtbl.Release(self);
    }

    pub fn commit(self: *Device) com.HRESULT {
        return self.lpVtbl.Commit(self);
    }
};

pub const Target = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*Target, *const com.GUID, *?*anyopaque) callconv(.c) com.HRESULT,
        AddRef: *const fn (*Target) callconv(.c) u32,
        Release: *const fn (*Target) callconv(.c) u32,
        SetRoot: *const fn (*Target, ?*Visual) callconv(.c) com.HRESULT, // 3
    };

    pub fn setRoot(self: *Target, visual: ?*Visual) com.HRESULT {
        return self.lpVtbl.SetRoot(self, visual);
    }

    pub fn release(self: *Target) void {
        _ = self.lpVtbl.Release(self);
    }
};

pub const Visual = extern struct {
    lpVtbl: *const VTable,

    /// **v0.3.18 修正（渲染专项实测发现）**：dcomp.h 的 C++ 接口有重载——
    /// SetOffsetX/Y/Transform/Clip 各占 **2 个槽**（float/Vector2F、Matrix/
    /// Transform、rect/geometry），v0.3.12 的核对漏算重载位（SetContent 误记
    /// 11、AddVisual 误记 12——实际调用落到 SetBorderMode 报 E_INVALIDARG）。
    /// 正确槽位以 SDK 10.0.26100.0 dcomp.h 的 C++ 声明序逐项重数：SetContent=15、
    /// AddVisual=16。
    pub const VTable = extern struct {
        QueryInterface: *const fn (*Visual, *const com.GUID, *?*anyopaque) callconv(.c) com.HRESULT,
        AddRef: *const fn (*Visual) callconv(.c) u32,
        Release: *const fn (*Visual) callconv(.c) u32,
        SetOffsetX: *const anyopaque, // 3  SetOffsetX(float)
        SetOffsetXV: *const anyopaque, // 4 SetOffsetX(Vector2F)
        SetOffsetY: *const anyopaque, // 5  SetOffsetY(float)
        SetOffsetYV: *const anyopaque, // 6 SetOffsetY(Vector2F)
        SetTransform: *const anyopaque, // 7  SetTransform(Matrix)
        SetTransformE: *const anyopaque, // 8 SetTransform(Transform)
        SetTransformParent: *const anyopaque, // 9
        SetEffect: *const anyopaque, // 10
        SetBitmapInterpolationMode: *const anyopaque, // 11
        SetBorderMode: *const anyopaque, // 12
        SetClip: *const anyopaque, // 13 SetClip(rect)
        SetClipG: *const anyopaque, // 14 SetClip(geometry)
        SetContent: *const fn (*Visual, ?*anyopaque) callconv(.c) com.HRESULT, // 15
        /// AddVisual(visual, insertAbove: BOOL, referenceVisual: ?*Visual)
        AddVisual: *const fn (*Visual, ?*Visual, i32, ?*Visual) callconv(.c) com.HRESULT, // 16
    };

    pub fn release(self: *Visual) void {
        _ = self.lpVtbl.Release(self);
    }
};

/// dcomp.dll 函数表（进程内一次加载）
var api_state: ?Api = null;

pub const Api = struct {
    createDevice2: *const fn (?*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) com.HRESULT,
    createDevice: *const fn (?*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) com.HRESULT,

    pub fn load() ?*const Api {
        if (api_state == null) {
            const lib = win32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll")) orelse return null;
            const p = struct {
                fn get(l: win32.HMODULE, comptime name: [:0]const u8) ?*anyopaque {
                    return win32.GetProcAddress(l, name);
                }
            };
            // 官方样例用 DCompositionCreateDevice2（AppWindow::DCompositionCreateDevice2
            // 同款动态加载）；DCompositionCreateDevice 作回退
            const create2 = p.get(lib, "DCompositionCreateDevice2");
            const create = p.get(lib, "DCompositionCreateDevice") orelse return null;
            api_state = .{
                .createDevice2 = @ptrCast(create2 orelse create),
                .createDevice = @ptrCast(create),
            };
        }
        return &api_state.?;
    }
};

/// 创建 DComp 设备（rendering_device = null 时引擎自建后台设备）。
/// **顺序契约（v0.3.18）**：必须在 CreateCoreWebView2CompositionController
/// **之前**创建（官方 InitializeWebView 先建设备再建 controller；后建实测
/// 导航段错误——渲染管线在 controller 创建时绑定 compositor）。
pub fn createDevice(rendering_device: ?*anyopaque) ?*Device {
    const api = Api.load() orelse return null;
    var out: ?*anyopaque = null;
    const hr = api.createDevice2(rendering_device, &IID_IDCompositionDevice, &out);
    if (com.failed(hr)) return null;
    return @ptrCast(@alignCast(out.?));
}
