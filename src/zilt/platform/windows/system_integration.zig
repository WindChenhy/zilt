//! 系统集成（v0.1.14，Windows）：Shell / 开机自启 / 主题与窗口效果。
const std = @import("std");
const win32 = @import("win32.zig");
const com = @import("com.zig");
const shell = @import("../../shell.zig");
const autostart = @import("../../autostart.zig");
const theme = @import("../../theme.zig");

const LPCWSTR = win32.LPCWSTR;

extern "shell32" fn ShellExecuteW(
    hwnd: win32.HWND,
    lpOperation: LPCWSTR,
    lpFile: LPCWSTR,
    lpParameters: ?LPCWSTR,
    lpDirectory: ?LPCWSTR,
    nShowCmd: c_int,
) callconv(.c) win32.HINSTANCE;

extern "advapi32" fn RegDeleteValueW(hKey: win32.HKEY, lpValueName: LPCWSTR) callconv(.c) win32.LONG;

extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: win32.HWND,
    dwAttribute: u32,
    pvAttribute: *const anyopaque,
    cbAttribute: u32,
) callconv(.c) com.HRESULT;

/// v0.1.18：无边框窗口的 DWM 阴影（负 margin 让 DWM 绘制系统边框阴影）。
extern "dwmapi" fn DwmExtendFrameIntoClientArea(hwnd: win32.HWND, margins: *const win32.MARGINS) callconv(.c) com.HRESULT;

const SW_SHOWNORMAL: c_int = 1;

const REG_RUN: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral(autostart.registry_path);

const VERB_OPEN: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("open");
const VERB_RUNAS: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("runas");
const WIDE_EXPLORER: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("explorer.exe");

fn verbWide(verb: shell.Verb) [:0]const u16 {
    return switch (verb) {
        .open => VERB_OPEN,
        .@"runas" => VERB_RUNAS,
        else => VERB_OPEN,
    };
}

fn shellExecute(alloc: std.mem.Allocator, verb: shell.Verb, file: []const u8, params: ?[]const u8) !void {
    const file_z = try std.unicode.utf8ToUtf16LeAllocZ(alloc, file);
    defer alloc.free(file_z);
    var params_z: ?[:0]u16 = null;
    if (params) |p| params_z = try std.unicode.utf8ToUtf16LeAllocZ(alloc, p);
    defer if (params_z) |p| alloc.free(p);

    const hinst = ShellExecuteW(null, verbWide(verb).ptr, file_z.ptr, if (params_z) |p| p.ptr else null, null, SW_SHOWNORMAL);
    // ShellExecuteW 返回值 <= 32 表示失败（历史约定）
    const code = @intFromPtr(hinst);
    if (code <= 32) return error.ShellExecuteFailed;
}

pub fn open(alloc: std.mem.Allocator, target: shell.Target) !void {
    switch (target) {
        .url => |u| try shellExecute(alloc, .open, u, null),
        .path => |p| try shellExecute(alloc, .open, p, null),
        .reveal => |p| {
            const args = try shell.explorerSelectArgs(alloc, p);
            defer alloc.free(args);
            try shellExecute(alloc, .open, "explorer.exe", args);
        },
    }
}

/// 管理员重启：UAC 提权拉起当前 exe 后由调用方退出当前进程。
pub fn restartAsAdmin(alloc: std.mem.Allocator, exe_path: []const u8, args: ?[]const u8) !void {
    try shellExecute(alloc, .@"runas", exe_path, args);
}

/// 注册开机自启（HKCU Run）。返回写入的命令行（调用方 free）。
pub fn autostartEnable(alloc: std.mem.Allocator, app_id: []const u8, exe_path: []const u8, args: ?[]const u8) ![]u8 {
    const command = try shell.runCommand(alloc, exe_path, args);
    errdefer alloc.free(command);

    var key: win32.HKEY = undefined;
    const sub = try std.unicode.utf8ToUtf16LeAllocZ(alloc, autostart.registry_path);
    defer alloc.free(sub);
    var disp: u32 = 0;
    const rc = win32.RegCreateKeyExW(win32.HKEY_CURRENT_USER, sub.ptr, 0, null, 0, win32.KEY_WRITE, null, &key, &disp);
    if (rc != 0) return error.RegistryOpenFailed;
    defer _ = win32.RegCloseKey(key);

    const name = try std.unicode.utf8ToUtf16LeAllocZ(alloc, autostart.valueName(app_id));
    defer alloc.free(name);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, command);
    defer alloc.free(wide);
    // REG_SZ 的 cbData 含结尾 NUL（字节数）
    const bytes = (wide.len * 2) + 2;
    const rc_set = win32.RegSetValueExW(key, name.ptr, 0, win32.REG_SZ, @ptrCast(wide.ptr), @intCast(bytes));
    if (rc_set != 0) return error.RegistryWriteFailed;
    return command;
}

pub fn autostartDisable(alloc: std.mem.Allocator, app_id: []const u8) bool {
    const sub = std.unicode.utf8ToUtf16LeAllocZ(alloc, autostart.registry_path) catch return false;
    defer alloc.free(sub);
    var key: win32.HKEY = undefined;
    if (win32.RegCreateKeyExW(win32.HKEY_CURRENT_USER, sub.ptr, 0, null, 0, win32.KEY_WRITE, null, &key, null) != 0) return false;
    defer _ = win32.RegCloseKey(key);
    const name = std.unicode.utf8ToUtf16LeAllocZ(alloc, autostart.valueName(app_id)) catch return false;
    defer alloc.free(name);
    return RegDeleteValueW(key, name.ptr) == 0;
}

/// 查询自启状态；`State.command` 由 allocator 分配，调用方负责 free。
pub fn autostartState(alloc: std.mem.Allocator, app_id: []const u8, exe_path: []const u8) !autostart.State {
    const name = try std.unicode.utf8ToUtf16LeAllocZ(alloc, autostart.valueName(app_id));
    defer alloc.free(name);
    var buf: [2048]u16 = undefined;
    var size: u32 = @intCast(@sizeOf(@TypeOf(buf)));
    const hr = win32.RegGetValueW(win32.HKEY_CURRENT_USER, REG_RUN.ptr, name.ptr, win32.RRF_RT_REG_SZ, null, @ptrCast(&buf), &size);
    if (hr < 0) return .{ .enabled = false, .command = null };

    const chars = size / 2;
    var len: usize = 0;
    while (len < chars and len < buf.len and buf[len] != 0) len += 1;
    const cmd = try std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..len]);
    return .{ .enabled = autostart.matchesExe(cmd, exe_path), .command = cmd };
}

fn setDwmAttr(hwnd: win32.HWND, attr: u32, value: u32) bool {
    const hr = DwmSetWindowAttribute(hwnd, attr, @ptrCast(&value), @sizeOf(u32));
    return com.succeeded(hr);
}

pub const AppearResult = struct {
    dark: bool,
    backdrop: bool,
    colors: bool = false,
    /// v0.3.9 A12：tint（SetWindowCompositionAttribute）与圆角偏好（Win11 33）应用结果
    tint: bool = false,
    corner: bool = false,
};

/// SetWindowCompositionAttribute（user32 未公开 API，Tauri windowEffects tint 同款；
/// 进程内一次加载）。
fn setWindowCompositionAttribute() ?*const fn (win32.HWND, *const theme.WindowCompositionAttribData) callconv(.c) win32.BOOL {
    const user32 = win32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse return null;
    return @ptrCast(win32.GetProcAddress(user32, "SetWindowCompositionAttribute"));
}

/// v0.3.9 A12：窗口底色 tint——ACCENT_ENABLE_ACRYLICBLURBEHIND + GradientColor。
pub fn applyTint(hwnd: win32.HWND, tint: u32) bool {
    const setAttr = setWindowCompositionAttribute() orelse return false;
    var policy = theme.AccentPolicy{
        .accent_state = @intFromEnum(theme.AccentState.enable_acrylic_blur_behind),
        .gradient_color = tint,
    };
    var data = theme.WindowCompositionAttribData{
        .attrib = theme.WCA_ACCENT_POLICY,
        .data = @ptrCast(&policy),
        .size = @sizeOf(theme.AccentPolicy),
    };
    return setAttr(hwnd, &data) != 0;
}

/// v0.3.9 A12：Win11 窗口圆角偏好（DWMWA_WINDOW_CORNER_PREFERENCE；旧系统静默失败）。
pub fn applyCornerPreference(hwnd: win32.HWND, pref: theme.CornerPreference) bool {
    return setDwmAttr(hwnd, theme.DWMWA_WINDOW_CORNER_PREFERENCE, @intFromEnum(pref));
}

/// 应用暗色标题栏与背景效果。Win10（无 backdrop 属性）会静默跳过
/// DWMWA_SYSTEMBACKDROP_TYPE；暗色标题栏在 1809 前用旧槽位 19 回退。
pub fn applyAppearance(hwnd: win32.HWND, appearance: theme.Appearance) AppearResult {
    var result = AppearResult{ .dark = false, .backdrop = false };
    if (appearance.dark_titlebar) |dark| {
        const v: u32 = @intFromBool(dark);
        result.dark = setDwmAttr(hwnd, theme.DWMWA_USE_IMMERSIVE_DARK_MODE, v) or
            setDwmAttr(hwnd, theme.DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, v);
    }
    if (appearance.backdrop) |b| {
        result.backdrop = setDwmAttr(hwnd, theme.DWMWA_SYSTEMBACKDROP_TYPE, @intFromEnum(b));
    }
    // v0.1.18：标题栏配色（Win11 22H2+；旧系统静默失败）
    if (appearance.caption_color) |c| {
        result.colors = setDwmAttr(hwnd, theme.DWMWA_CAPTION_COLOR, theme.colorRef(c)) or result.colors;
    }
    if (appearance.text_color) |c| {
        result.colors = setDwmAttr(hwnd, theme.DWMWA_TEXT_COLOR, theme.colorRef(c)) or result.colors;
    }
    if (appearance.border_color) |c| {
        result.colors = setDwmAttr(hwnd, theme.DWMWA_BORDER_COLOR, theme.colorRef(c)) or result.colors;
    }
    // v0.3.9 A12：效果参数（tint / 圆角偏好）
    if (appearance.tint) |t| {
        result.tint = applyTint(hwnd, t);
    }
    if (appearance.corner_preference) |p| {
        result.corner = applyCornerPreference(hwnd, p);
    }
    return result;
}

/// 开关无边框窗口的 DWM 阴影。margin 全 -1 时 DWM 把客户区当作整个边框，
/// 从而绘制系统阴影并保留圆角；全 0 则移除扩展。
pub fn applyShadow(hwnd: win32.HWND, enabled: bool) bool {
    var margins = win32.MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 0, .cyBottomHeight = 0 };
    if (enabled) {
        margins = .{ .cxLeftWidth = -1, .cxRightWidth = -1, .cyTopHeight = -1, .cyBottomHeight = -1 };
    }
    return com.succeeded(DwmExtendFrameIntoClientArea(hwnd, &margins));
}

const testing = std.testing;

test "REG_RUN path matches registry helper" {
    const path_u8 = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, REG_RUN);
    defer testing.allocator.free(path_u8);
    try testing.expectEqualStrings(autostart.registry_path, path_u8);
}
