//! v0.1.5 对话框扩展：文件夹选择 / 多选文件 / 颜色 / 字体。
//!
//! - 文件夹/多选：IFileOpenDialog（Vista+ 现代对话框，COM 自包含绑定）。
//!   槽位序（shobjidl_core.idl）：IUnknown(0-2) + IFileDialog[Show(3)..GetResult(26)]
//!   + IFileOpenDialog[GetResults(27), GetSelectedItems(28)]。
//! - 颜色/字体：comdlg32 ChooseColorW / ChooseFontW。
//! 约定与 dialog.zig 一致：仅 UI 线程调用（模态阻塞与 Tauri 语义一致）。

const std = @import("std");
const win32 = @import("win32.zig");
const com = @import("com.zig");
const ipc = @import("../../ipc.zig");

const testing = std.testing;

const LPCWSTR = [*:0]const u16;

// ---------------------------------------------------------------------------
// comdlg32（颜色/字体）
// ---------------------------------------------------------------------------

pub const CHOOSECOLORW = extern struct {
    lStructSize: u32,
    hwndOwner: ?*anyopaque,
    hInstance: ?*anyopaque,
    rgbResult: u32,
    lpCustColors: [*]u32,
    Flags: u32,
    lCustData: isize,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?LPCWSTR = null,
};

pub const LOGFONTW = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 0,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = 0,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 0,
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [32]u16 = @splat(0),
};

pub const CHOOSEFONTW = extern struct {
    lStructSize: u32,
    hwndOwner: ?*anyopaque,
    hDC: ?*anyopaque,
    lpLogFont: *LOGFONTW,
    iPointSize: i32,
    Flags: u32,
    rgbColors: u32,
    lCustData: isize,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?LPCWSTR = null,
    hInstance: ?*anyopaque = null,
    lpszStyle: ?LPCWSTR = null,
    nFontType: u16 = 0,
    ___MISSING_ALIGNMENT__: u16 = 0,
    nSizeMin: i32 = 0,
    nSizeMax: i32 = 0,
};

pub extern "comdlg32" fn ChooseColorW(lpcc: *CHOOSECOLORW) callconv(.c) i32;
pub extern "comdlg32" fn ChooseFontW(lpcf: *CHOOSEFONTW) callconv(.c) i32;

pub extern "ole32" fn CoCreateInstance(clsid: *const com.GUID, outer: ?*anyopaque, clsctx: u32, iid: *const com.GUID, out: *?*anyopaque) callconv(.c) com.HRESULT;

const CC_RGBINIT: u32 = 0x1;
const CC_FULLOPEN: u32 = 0x2;
const CC_ANYCOLOR: u32 = 0x100;
const CF_SCREEN_FONTS: u32 = 0x1;
const CF_INITTOLOGFONTSTRUCT: u32 = 0x40;
const CF_EFFECTS: u32 = 0x100;
const FW_BOLD: i32 = 700;
const DEFAULT_CHARSET: u8 = 1;

// ---------------------------------------------------------------------------
// IFileOpenDialog（COM 绑定）
// ---------------------------------------------------------------------------

const CLSID_FileOpenDialog = com.GUID.parse("{DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7}");
const IID_IFileOpenDialog = com.GUID.parse("{D57C7288-D4AD-4768-BE02-9D969532D960}");

const CLSCTX_INPROC_SERVER: u32 = 1;
const SIGDN_FILESYSPATH: u32 = 0x80058000;
const FOS_NOCHANGEDIR: u32 = 0x8;
const FOS_PICKFOLDERS: u32 = 0x20;
const FOS_FORCEFILESYSTEM: u32 = 0x40;
const FOS_ALLOWMULTISELECT: u32 = 0x200;
const FOS_PATHMUSTEXIST: u32 = 0x800;
const FOS_FILEMUSTEXIST: u32 = 0x1000;
const E_CANCELLED: com.HRESULT = @bitCast(@as(u32, 0x800704C7)); // HRESULT_FROM_WIN32(ERROR_CANCELLED)

const ComHeader = extern struct {
    lpVtbl: *const anyopaque,
};

fn vtableFn(obj: *anyopaque, comptime slot: usize, comptime Fn: type) Fn {
    const hdr: *const ComHeader = @ptrCast(@alignCast(obj));
    const base: [*]const *const anyopaque = @ptrCast(@alignCast(hdr.lpVtbl));
    return @ptrFromInt(@intFromPtr(base[slot]));
}

/// 通用 QI/Release（前三槽位布局一致）。
fn qiCom(obj: *anyopaque, iid: *const com.GUID) ?*anyopaque {
    const qi = vtableFn(obj, 0, *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) com.HRESULT);
    var out: ?*anyopaque = null;
    if (com.succeeded(qi(obj, iid, &out))) return out;
    return null;
}

fn releaseCom(obj: *anyopaque) void {
    const rel = vtableFn(obj, 2, *const fn (*anyopaque) callconv(.c) u32);
    _ = rel(obj);
}

fn showOpenDialog(obj: *anyopaque, hwnd: win32.HWND) com.HRESULT {
    const show = vtableFn(obj, 3, *const fn (*anyopaque, ?*anyopaque) callconv(.c) com.HRESULT);
    return show(obj, hwnd);
}

fn setOpenDialogOptions(obj: *anyopaque, flags: u32) com.HRESULT {
    const setopts = vtableFn(obj, 9, *const fn (*anyopaque, u32) callconv(.c) com.HRESULT);
    return setopts(obj, flags);
}

fn setDialogTitle(obj: *anyopaque, title_w: LPCWSTR) com.HRESULT {
    const settitle = vtableFn(obj, 17, *const fn (*anyopaque, LPCWSTR) callconv(.c) com.HRESULT);
    return settitle(obj, title_w);
}

/// GetResult（IFileDialog 末槽 = 26）。
fn getDialogResult(obj: *anyopaque, out: *?*anyopaque) com.HRESULT {
    const getresult = vtableFn(obj, 26, *const fn (*anyopaque, *?*anyopaque) callconv(.c) com.HRESULT);
    return getresult(obj, out);
}

/// GetResults（IFileOpenDialog = 27）。
fn getDialogResults(obj: *anyopaque, out: *?*anyopaque) com.HRESULT {
    const getresults = vtableFn(obj, 27, *const fn (*anyopaque, *?*anyopaque) callconv(.c) com.HRESULT);
    return getresults(obj, out);
}

fn shellItemPath(item: *anyopaque, alloc: std.mem.Allocator) !?[]u8 {
    const getdn = vtableFn(item, 5, *const fn (*anyopaque, u32, *?LPCWSTR) callconv(.c) com.HRESULT);
    var pw: ?LPCWSTR = null;
    const hr = getdn(item, SIGDN_FILESYSPATH, &pw);
    if (!com.succeeded(hr) or pw == null) return null;
    defer win32.CoTaskMemFree(@ptrCast(@constCast(pw.?)));
    return try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(pw.?));
}

// ---------------------------------------------------------------------------
// 纯函数（单测覆盖）
// ---------------------------------------------------------------------------

/// 0xRRGGBB → COLORREF(0x00BBGGRR)。
pub fn rgbToColorref(rgb: u32) u32 {
    const r = (rgb >> 16) & 0xff;
    const g = (rgb >> 8) & 0xff;
    const b = rgb & 0xff;
    return (b << 16) | (g << 8) | r;
}

/// COLORREF(0x00BBGGRR) → 0xRRGGBB。
pub fn colorrefToRgb(c: u32) u32 {
    const b = (c >> 16) & 0xff;
    const g = (c >> 8) & 0xff;
    const r = c & 0xff;
    return (r << 16) | (g << 8) | b;
}

/// FOS 标志组装（folder=选文件夹；multi=多选；公共：不变更目录/路径必须存在/文件系统路径）。
pub fn composeFosFlags(folder: bool, multi: bool) u32 {
    var f: u32 = FOS_NOCHANGEDIR | FOS_PATHMUSTEXIST | FOS_FORCEFILESYSTEM;
    if (folder) {
        f |= FOS_PICKFOLDERS;
    } else {
        f |= FOS_FILEMUSTEXIST;
        if (multi) f |= FOS_ALLOWMULTISELECT;
    }
    return f;
}

/// 字重 → 加粗判定（FW_BOLD = 700）。
pub fn weightIsBold(weight: i32) bool {
    return weight >= FW_BOLD;
}

// ---------------------------------------------------------------------------
// 对话框实现
// ---------------------------------------------------------------------------

/// 选择文件夹（IFileDialog FOS_PICKFOLDERS）。取消返回 null；路径用 alloc 分配。
pub fn runPickFolder(alloc: std.mem.Allocator, hwnd: win32.HWND, opts: ipc.FolderDialogOptions) !?[]u8 {
    var dlg: ?*anyopaque = null;
    if (!com.succeeded(CoCreateInstance(&CLSID_FileOpenDialog, null, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, &dlg)) or dlg == null)
        return error.DialogFailed;
    defer releaseCom(dlg.?);

    _ = setOpenDialogOptions(dlg.?, composeFosFlags(true, false));
    const title_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, opts.title);
    defer alloc.free(title_w);
    _ = setDialogTitle(dlg.?, title_w.ptr);

    const hr = showOpenDialog(dlg.?, hwnd);
    if (hr == E_CANCELLED) return null;
    if (!com.succeeded(hr)) return error.DialogFailed;

    var item: ?*anyopaque = null;
    if (!com.succeeded(getDialogResult(dlg.?, &item)) or item == null) return error.DialogFailed;
    defer releaseCom(item.?);
    return shellItemPath(item.?, alloc) catch null;
}

/// 多选文件（FOS_ALLOWMULTISELECT）。取消返回 null；按选择顺序返回（alloc 分配）。
pub fn runPickFiles(alloc: std.mem.Allocator, hwnd: win32.HWND, opts: ipc.FileDialogOptions) !?[][]u8 {
    var dlg: ?*anyopaque = null;
    if (!com.succeeded(CoCreateInstance(&CLSID_FileOpenDialog, null, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, &dlg)) or dlg == null)
        return error.DialogFailed;
    defer releaseCom(dlg.?);

    _ = setOpenDialogOptions(dlg.?, composeFosFlags(false, true));
    const title_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, if (opts.title.len > 0) opts.title else "选择文件");
    defer alloc.free(title_w);
    _ = setDialogTitle(dlg.?, title_w.ptr);

    const hr = showOpenDialog(dlg.?, hwnd);
    if (hr == E_CANCELLED) return null;
    if (!com.succeeded(hr)) return error.DialogFailed;

    var arr: ?*anyopaque = null;
    if (!com.succeeded(getDialogResults(dlg.?, &arr)) or arr == null) return error.DialogFailed;
    defer releaseCom(arr.?);

    const get_count = vtableFn(arr.?, 7, *const fn (*anyopaque, *u32) callconv(.c) com.HRESULT);
    const get_at = vtableFn(arr.?, 8, *const fn (*anyopaque, u32, *?*anyopaque) callconv(.c) com.HRESULT);

    var n: u32 = 0;
    if (!com.succeeded(get_count(arr.?, &n))) return error.DialogFailed;
    var paths = try alloc.alloc([]u8, n);
    errdefer {
        for (paths[0..n]) |pp| alloc.free(pp);
        alloc.free(paths);
    }
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var item: ?*anyopaque = null;
        if (!com.succeeded(get_at(arr.?, i, &item)) or item == null) return error.DialogFailed;
        defer releaseCom(item.?);
        paths[i] = (try shellItemPath(item.?, alloc)) orelse return error.DialogFailed;
    }
    return paths;
}

/// 自定义颜色（进程级共享，UI 线程独占——comdlg32 惯例）。
var custom_colors = [_]u32{ 0xFFFFFF, 0xC0C0C0, 0x808080, 0x000000, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF, 0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080 };

/// 颜色选择（ChooseColorW）。取消返回 null；返回 0xRRGGBB。
pub fn runPickColor(opts: ipc.ColorDialogOptions) ?u32 {
    var cust = custom_colors;
    var cc = CHOOSECOLORW{
        .lStructSize = @sizeOf(CHOOSECOLORW),
        .hwndOwner = null,
        .hInstance = null,
        .rgbResult = rgbToColorref(opts.default_rgb),
        .lpCustColors = &cust,
        .Flags = CC_RGBINIT | CC_ANYCOLOR | (if (opts.full_open) CC_FULLOPEN else 0),
        .lCustData = 0,
        .lpfnHook = null,
    };
    if (ChooseColorW(&cc) == 0) return null;
    return colorrefToRgb(cc.rgbResult);
}

/// 字体选择（ChooseFontW）。取消返回 null（name 用 alloc 分配）。
pub fn runPickFont(alloc: std.mem.Allocator, hwnd: win32.HWND, opts: ipc.FontDialogOptions) !?ipc.FontChoice {
    var lf = LOGFONTW{
        .lfHeight = -12,
        .lfWeight = 400,
        .lfCharSet = DEFAULT_CHARSET,
    };
    var cf = CHOOSEFONTW{
        .lStructSize = @sizeOf(CHOOSEFONTW),
        .hwndOwner = hwnd,
        .hDC = null,
        .lpLogFont = &lf,
        .iPointSize = 0,
        .Flags = CF_SCREEN_FONTS | CF_INITTOLOGFONTSTRUCT | (if (opts.effects) CF_EFFECTS else 0),
        .rgbColors = rgbToColorref(opts.color_rgb),
        .lCustData = 0,
        .lpfnHook = null,
    };
    if (ChooseFontW(&cf) == 0) return null;

    const name_len = std.mem.indexOfScalar(u16, &lf.lfFaceName, 0) orelse lf.lfFaceName.len;
    const name = try std.unicode.utf16LeToUtf8Alloc(alloc, lf.lfFaceName[0..name_len]);
    return .{
        .name = name,
        .size_points = @divTrunc(cf.iPointSize, 10),
        .bold = weightIsBold(lf.lfWeight),
        .italic = lf.lfItalic != 0,
        .underline = lf.lfUnderline != 0,
        .strikeout = lf.lfStrikeOut != 0,
        .color_rgb = colorrefToRgb(cf.rgbColors),
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "rgbToColorref/colorrefToRgb: 双向往返" {
    try testing.expectEqual(@as(u32, 0x0000FF), rgbToColorref(0xFF0000)); // 红 → BGR
    try testing.expectEqual(@as(u32, 0xFF0000), rgbToColorref(0x0000FF)); // 蓝 → 高位
    try testing.expectEqual(@as(u32, 0x123456), colorrefToRgb(rgbToColorref(0x123456)));
    try testing.expectEqual(@as(u32, 0xAB12CD), colorrefToRgb(rgbToColorref(0xAB12CD)));
}

test "composeFosFlags: 文件夹/多选/单选组合" {
    const folder = composeFosFlags(true, false);
    try testing.expect(folder & FOS_PICKFOLDERS != 0);
    try testing.expect(folder & FOS_ALLOWMULTISELECT == 0);
    try testing.expect(folder & FOS_FORCEFILESYSTEM != 0);

    const multi = composeFosFlags(false, true);
    try testing.expect(multi & FOS_PICKFOLDERS == 0);
    try testing.expect(multi & FOS_ALLOWMULTISELECT != 0);
    try testing.expect(multi & FOS_FILEMUSTEXIST != 0);

    const single = composeFosFlags(false, false);
    try testing.expect(single & FOS_ALLOWMULTISELECT == 0);
    try testing.expect(single & FOS_FILEMUSTEXIST != 0);
}

test "weightIsBold: 阈值 700" {
    try testing.expect(!weightIsBold(400));
    try testing.expect(!weightIsBold(699));
    try testing.expect(weightIsBold(700));
    try testing.expect(weightIsBold(900));
}

test "LOGFONTW: x64 布局（92 字节稳定 ABI；lfFaceName 偏移 28）" {
    try testing.expectEqual(@as(usize, 92), @sizeOf(LOGFONTW));
    try testing.expectEqual(@as(usize, 28), @offsetOf(LOGFONTW, "lfFaceName"));
}
