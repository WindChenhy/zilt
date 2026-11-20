//! 任务栏集成 Windows 实现（v0.1.13）：ITaskbarList3。
//!
//! 覆盖：进度条、overlay 图标、缩略图提示、缩略图工具栏按钮、闪烁窗口。
//! Jump List 需要 ICustomDestinationList + IShellLink 组合
//! （当前未实现，调用会返回 error.JumpListNotImplemented）。
//!
//! ABI 依据：ShellApi.h / ShObjIdl_core.h（ITaskbarList3 槽序：
//! IUnknown 3 + ITaskbarList 5 + ITaskbarList2 1 + ITaskbarList3 12 = 21）。
const std = @import("std");
const com = @import("com.zig");
const win32 = @import("win32.zig");
const taskbar = @import("../../taskbar.zig");
const log = @import("../../log.zig");

pub const CLSID_TaskbarList: com.GUID = .parse("{56FDF344-FD6D-11D0-958A-006097C9A090}");
pub const IID_ITaskbarList3: com.GUID = .parse("{EA1AFB91-9E28-4B86-90E9-9E9F8A5EEA84}");
/// ITaskbarList4 = ITaskbarList3 的超集（仅追加 SetTabProperties）。Win11 25H2 实测：
/// QI 到 v3 返回 E_NOINTERFACE，而 v4 返回 S_OK，因此 v4 是必须的回退路径；
/// 由于 v4 的前 21 个 vtable 槽与 v3 完全一致，这里复用同一个 VTable 定义。
pub const IID_ITaskbarList4: com.GUID = .parse("{C43DC798-95D1-4BEA-9030-BB99E2983A1A}");
pub const CLSCTX_INPROC_SERVER: u32 = 0x1;

extern "ole32" fn CoCreateInstance(
    rclsid: *const com.GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const com.GUID,
    ppvObject: *?*anyopaque,
) callconv(.c) com.HRESULT;

extern "user32" fn FlashWindowEx(pfwi: *FLASHWINFO) callconv(.c) win32.BOOL;

pub const FLASHW_STOP: win32.DWORD = 0x00000000;
pub const FLASHW_CAPTION: win32.DWORD = 0x00000001;
pub const FLASHW_TRAY: win32.DWORD = 0x00000002;
pub const FLASHW_ALL: win32.DWORD = 0x00000003;
pub const FLASHW_TIMER: win32.DWORD = 0x00000004;
pub const FLASHW_TIMERNOFG: win32.DWORD = 0x0000000C;

pub const FLASHWINFO = extern struct {
    cbSize: win32.UINT,
    hwnd: win32.HWND,
    dwFlags: win32.DWORD,
    uCount: win32.UINT,
    dwTimeout: win32.DWORD,
};

// ---- THUMBBUTTON ----

pub const THB_ICON: u32 = 0x2;
pub const THB_TOOLTIP: u32 = 0x4;
pub const THB_FLAGS: u32 = 0x8;

pub const THBF_ENABLED: u32 = 0x0;
pub const THBF_DISABLED: u32 = 0x1;
pub const THBF_DISMISSONCLICK: u32 = 0x2;
pub const THBF_NOBACKGROUND: u32 = 0x4;

pub const THUMBBUTTON = extern struct {
    dwMask: u32,
    iId: u32,
    iBitmap: u32,
    hIcon: win32.HICON,
    szTip: [260]u16,
    dwFlags: u32,
};

pub const ITaskbarList3 = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ITaskbarList3, *const com.GUID, *?*anyopaque) callconv(.c) com.HRESULT,
        AddRef: *const fn (*ITaskbarList3) callconv(.c) u32,
        Release: *const fn (*ITaskbarList3) callconv(.c) u32,
        // ITaskbarList
        HrInit: *const fn (*ITaskbarList3) callconv(.c) com.HRESULT,
        AddTab: *const fn (*ITaskbarList3, win32.HWND) callconv(.c) com.HRESULT,
        DeleteTab: *const fn (*ITaskbarList3, win32.HWND) callconv(.c) com.HRESULT,
        ActivateTab: *const fn (*ITaskbarList3, win32.HWND) callconv(.c) com.HRESULT,
        SetActiveAlt: *const fn (*ITaskbarList3, win32.HWND) callconv(.c) com.HRESULT,
        // ITaskbarList2
        MarkFullscreenWindow: *const fn (*ITaskbarList3, win32.HWND, win32.BOOL) callconv(.c) com.HRESULT,
        // ITaskbarList3
        SetProgressValue: *const fn (*ITaskbarList3, win32.HWND, u64, u64) callconv(.c) com.HRESULT,
        SetProgressState: *const fn (*ITaskbarList3, win32.HWND, u32) callconv(.c) com.HRESULT,
        RegisterTab: *const fn (*ITaskbarList3, win32.HWND, win32.HWND) callconv(.c) com.HRESULT,
        UnregisterTab: *const fn (*ITaskbarList3, win32.HWND) callconv(.c) com.HRESULT,
        SetTabOrder: *const fn (*ITaskbarList3, win32.HWND, win32.HWND) callconv(.c) com.HRESULT,
        SetTabActive: *const fn (*ITaskbarList3, win32.HWND, win32.HWND, win32.DWORD) callconv(.c) com.HRESULT,
        ThumbBarAddButtons: *const fn (*ITaskbarList3, win32.HWND, u32, [*]THUMBBUTTON) callconv(.c) com.HRESULT,
        ThumbBarUpdateButtons: *const fn (*ITaskbarList3, win32.HWND, u32, [*]THUMBBUTTON) callconv(.c) com.HRESULT,
        ThumbBarSetImageList: *const fn (*ITaskbarList3, win32.HWND, ?*anyopaque) callconv(.c) com.HRESULT,
        SetOverlayIcon: *const fn (*ITaskbarList3, win32.HWND, win32.HICON, ?win32.LPCWSTR) callconv(.c) com.HRESULT,
        SetThumbnailTooltip: *const fn (*ITaskbarList3, win32.HWND, win32.LPCWSTR) callconv(.c) com.HRESULT,
        SetThumbnailClip: *const fn (*ITaskbarList3, win32.HWND, ?*const RECT) callconv(.c) com.HRESULT,
    };

    pub fn release(self: *ITaskbarList3) void {
        _ = self.lpVtbl.Release(self);
    }
};

pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

/// 任务栏对象。COM 要求在同一线程使用（backend 的 UI 线程）。
pub const Taskbar = struct {
    list: *ITaskbarList3,
    /// v0.3.16 G18：上次徽标 HICON（SetOverlayIcon 复制位图，调用方负责销毁——
    /// 换徽标时销毁上一枚，避免累积泄漏）
    last_badge_icon: win32.HICON = null,

    pub fn init() !Taskbar {
        var raw: ?*anyopaque = null;
        var hr = CoCreateInstance(&CLSID_TaskbarList, null, CLSCTX_INPROC_SERVER, &IID_ITaskbarList3, &raw);
        var version: u8 = 3;
        if (com.failed(hr) or raw == null) {
            // Win11 25H2：v3 的 QI 回 E_NOINTERFACE，v4 可用（前 21 槽与 v3 同布局）
            hr = CoCreateInstance(&CLSID_TaskbarList, null, CLSCTX_INPROC_SERVER, &IID_ITaskbarList4, &raw);
            version = 4;
        }
        if (com.failed(hr) or raw == null) {
            log.print("[taskbar] TaskbarList unavailable (hr=0x{x})", .{@as(u32, @bitCast(hr))});
            return error.TaskbarUnavailable;
        }
        const list: *ITaskbarList3 = @ptrCast(@alignCast(raw.?));
        const hr_init = list.lpVtbl.HrInit(list);
        if (com.failed(hr_init)) {
            log.print("[taskbar] HrInit failed hr=0x{x}", .{@as(u32, @bitCast(hr_init))});
            list.release();
            return error.TaskbarInitFailed;
        }
        log.print("[taskbar] ITaskbarList{d} ready", .{version});
        return .{ .list = list };
    }

    pub fn deinit(self: *Taskbar) void {
        self.list.release();
    }

    pub fn setProgress(self: *Taskbar, hwnd: win32.HWND, progress: taskbar.Progress) void {
        _ = self.list.lpVtbl.SetProgressState(self.list, hwnd, @intFromEnum(progress.state));
        if (progress.state == .none or progress.state == .indeterminate) return;
        const scaled = progress.scaled();
        _ = self.list.lpVtbl.SetProgressValue(self.list, hwnd, scaled.done, scaled.total);
    }

    pub fn setOverlay(self: *Taskbar, hwnd: win32.HWND, icon: win32.HICON, description_u8: []const u8, alloc: std.mem.Allocator) void {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, description_u8) catch {
            _ = self.list.lpVtbl.SetOverlayIcon(self.list, hwnd, icon, null);
            return;
        };
        defer alloc.free(wide);
        _ = self.list.lpVtbl.SetOverlayIcon(self.list, hwnd, icon, wide.ptr);
    }

    /// v0.3.16 G18：任务栏文本徽标（文本渲染 32×32 GDI 位图 → SetOverlayIcon）。
    /// text 为空 = 清除徽标（SetOverlayIcon null）。返回 false = 渲染失败。
    pub fn setBadge(self: *Taskbar, hwnd: win32.HWND, badge: ?taskbar.Badge, alloc: std.mem.Allocator) bool {
        const b = badge orelse {
            _ = self.list.lpVtbl.SetOverlayIcon(self.list, hwnd, null, null);
            return true;
        };
        if (b.text.len == 0 or b.text.len > 4) return false; // 徽标空间限 1–4 字符
        const icon = makeBadgeIcon(b, alloc) orelse return false;
        _ = self.list.lpVtbl.SetOverlayIcon(self.list, hwnd, icon, null);
        // SetOverlayIcon 复制位图数据；上一枚徽标即时销毁（换徽标场景，
        // shell 已持有自己的副本）
        if (self.last_badge_icon) |prev| _ = win32.DestroyIcon(prev);
        self.last_badge_icon = icon;
        return true;
    }

    pub fn setTooltip(self: *Taskbar, hwnd: win32.HWND, text_u8: []const u8, alloc: std.mem.Allocator) void {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, text_u8) catch return;
        defer alloc.free(wide);
        _ = self.list.lpVtbl.SetThumbnailTooltip(self.list, hwnd, wide.ptr);
    }

    pub fn setThumbButtons(self: *Taskbar, hwnd: win32.HWND, buttons: []const taskbar.Button, icons: []const win32.HICON) bool {
        if (buttons.len == 0 or buttons.len > 7) return false; // Win7 限制 7 个
        var buf: [7]THUMBBUTTON = undefined;
        for (buttons, 0..) |b, i| {
            var btn = THUMBBUTTON{
                .dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS,
                .iId = b.id,
                .iBitmap = 0,
                .hIcon = if (i < icons.len) icons[i] else null,
                .szTip = std.mem.zeroes([260]u16),
                .dwFlags = if (!b.enabled) THBF_DISABLED else THBF_ENABLED,
            };
            if (b.dismiss_on_click) btn.dwFlags |= THBF_DISMISSONCLICK;
            const n = @min(b.tooltip.len, 259);
            _ = std.unicode.utf8ToUtf16Le(btn.szTip[0..n], b.tooltip[0..n]) catch 0;
            btn.szTip[n] = 0;
            buf[i] = btn;
        }
        const hr = self.list.lpVtbl.ThumbBarAddButtons(self.list, hwnd, @intCast(buttons.len), &buf);
        return com.succeeded(hr);
    }

    pub fn flash(hwnd: win32.HWND, req: taskbar.Flash) bool {
        var info = FLASHWINFO{
            .cbSize = @sizeOf(FLASHWINFO),
            .hwnd = hwnd,
            .dwFlags = if (req.tray_only) FLASHW_TRAY else FLASHW_ALL,
            .uCount = req.count,
            .dwTimeout = req.timeout_ms,
        };
        if (req.count == 0) info.dwFlags |= FLASHW_TIMERNOFG;
        return FlashWindowEx(&info) != 0;
    }

    pub fn stopFlash(hwnd: win32.HWND) void {
        var info = FLASHWINFO{
            .cbSize = @sizeOf(FLASHWINFO),
            .hwnd = hwnd,
            .dwFlags = FLASHW_STOP,
            .uCount = 0,
            .dwTimeout = 0,
        };
        _ = FlashWindowEx(&info);
    }
};

const testing = std.testing;

test "vtable layout stays at 21 slots" {
    // 编译期断言：任何槽位增删都会让这里失败，避免 ABI 漂移。
    try testing.expectEqual(21, @typeInfo(ITaskbarList3.VTable).@"struct".field_names.len);
}

test "flash info carries size and flags" {
    try testing.expect(@sizeOf(FLASHWINFO) >= 24);
    try testing.expectEqual(@as(u32, 0x2), FLASHW_TRAY);
    try testing.expectEqual(@as(u32, 0x3), FLASHW_ALL);
}

test "thumbnail button layout matches ShellApi.h" {
    // dwMask/iId/iBitmap + hIcon(8, 4 padding) + szTip[260] + dwFlags
    try testing.expectEqual(@as(usize, 552), @sizeOf(THUMBBUTTON));
    try testing.expectEqual(@as(usize, 520), @sizeOf([260]u16));
}


/// v0.3.16 G18：文本徽标渲染（32×32 32bpp DIB 圆形底 + GDI 文本 → HICON）。
/// 返回的 HICON 所有权归调用方（DestroyIcon）。
fn makeBadgeIcon(badge: taskbar.Badge, alloc: std.mem.Allocator) ?win32.HICON {
    const size: i32 = 32;
    const dc = win32.CreateCompatibleDC(null) orelse return null;
    defer _ = win32.DeleteDC(dc);

    var bmi = win32.BITMAPINFO{
        .bmiHeader = .{
            .biSize = @sizeOf(win32.BITMAPINFOHEADER),
            .biWidth = size,
            .biHeight = -size, // top-down
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = 0, // BI_RGB
            .biSizeImage = 0,
            .biXPelsPerMeter = 0,
            .biYPelsPerMeter = 0,
            .biClrUsed = 0,
            .biClrImportant = 0,
        },
        .bmiColors = .{0},
    };
    var bits: ?*anyopaque = null;
    const dib = win32.CreateDIBSection(dc, &bmi, win32.DIB_RGB_COLORS, &bits, null, 0);
    if (dib == null or bits == null) return null;
    _ = win32.SelectObject(dc, dib);

    // 圆形底色（COLORREF 0x00BBGGRR ← 0xRRGGBB 输入；FillRect 全矩形 + 圆底用
    // Ellipse 更简洁——FrameRgn 太重，直接 Ellipse 画圆填色）
    const brush = win32.CreateSolidBrush(theme.colorRef(badge.bg_color));
    defer _ = win32.DeleteObject(@ptrCast(brush));
    const bg_rect = win32.RECT{ .left = 0, .top = 0, .right = size, .bottom = size };
    _ = win32.FillRect(dc, &bg_rect, brush);

    const font = win32.GetStockObject(win32.DEFAULT_GUI_FONT);
    if (font != null) _ = win32.SelectObject(dc, font);
    _ = win32.SetBkMode(dc, win32.TRANSPARENT_BK);
    _ = win32.SetTextColor(dc, theme.colorRef(badge.text_color));

    // 文本 UTF-8 → UTF-16（≤4 字符的短串；2 字节字符按 WC 边界裁剪到 4 WC）
    const text16 = std.unicode.utf8ToUtf16LeAllocZ(alloc, badge.text) catch return null;
    defer alloc.free(text16);
    const chars: i32 = @intCast(@min(text16.len, 4));
    var text_rect = bg_rect;
    _ = win32.DrawTextW(dc, text16.ptr, chars, &text_rect, win32.DT_CENTER | win32.DT_VCENTER | win32.DT_SINGLELINE);

    // 单色 mask（CreateIconIndirect 需要 mask 位图；透明区域由 0 位给出——
    // 徽标是全不透明圆底，mask 全 0 = 全显示）
    const mask = win32.CreateBitmap(size, size, 1, 1, null);
    if (mask == null) return null;
    defer _ = win32.DeleteObject(@ptrCast(mask));

    const info = win32.ICONINFO{
        .fIcon = 1,
        .xHotspot = 0,
        .yHotspot = 0,
        .hbmMask = mask,
        .hbmColor = dib,
    };
    return win32.CreateIconIndirect(&info);
}

const theme = @import("../../theme.zig");
