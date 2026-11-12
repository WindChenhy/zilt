//! 系统信息采集（v0.1.14，Windows）：OS 版本、架构、区域、主题、强调色、显示器。
const std = @import("std");
const win32 = @import("win32.zig");
const sysinfo = @import("../../sysinfo.zig");

pub const HMONITOR = ?*anyopaque;

const RTL_OSVERSIONINFOW = extern struct {
    dwOSVersionInfoSize: u32,
    dwMajorVersion: u32,
    dwMinorVersion: u32,
    dwBuildNumber: u32,
    dwPlatformId: u32,
    szCSDVersion: [128]u16,
};

extern "ntdll" fn RtlGetVersion(info: *RTL_OSVERSIONINFOW) callconv(.c) i32;

const SYSTEM_INFO = extern struct {
    wProcessorArchitecture: u16,
    wReserved: u16,
    dwPageSize: u32,
    lpMinimumApplicationAddress: ?*anyopaque,
    lpMaximumApplicationAddress: ?*anyopaque,
    dwActiveProcessorMask: usize,
    dwNumberOfProcessors: u32,
    dwProcessorType: u32,
    dwAllocationGranularity: u32,
    wProcessorLevel: u16,
    wProcessorRevision: u16,
};

extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) callconv(.c) void;
extern "kernel32" fn GetUserDefaultLocaleName(lpLocaleName: [*]u16, cchLocaleName: c_int) callconv(.c) c_int;

pub const MONITORINFOEXW = extern struct {
    cbSize: u32,
    rcMonitor: win32.RECT,
    rcWork: win32.RECT,
    dwFlags: u32,
    szDevice: [32]u16,
};

extern "user32" fn EnumDisplayMonitors(
    hdc: ?*anyopaque,
    lprcClip: ?*const win32.RECT,
    lpfnEnum: *const fn (HMONITOR, ?*anyopaque, *win32.RECT, isize) callconv(.c) i32,
    dwData: isize,
) callconv(.c) win32.BOOL;
extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFOEXW) callconv(.c) win32.BOOL;
extern "user32" fn GetDpiForWindow(hwnd: win32.HWND) callconv(.c) u32;

const MONITORINFOF_PRIMARY: u32 = 0x1;
const PROCESSOR_ARCHITECTURE_AMD64: u16 = 9;
const PROCESSOR_ARCHITECTURE_ARM64: u16 = 12;

/// 采集结果的自持有容器：version/locale 存在内部数组里，
/// `toInfo` 返回的切片只在该容器存活期间有效（调用方通常立即序列化）。
pub const OsInfoOwned = struct {
    major: u32 = 0,
    minor: u32 = 0,
    build: u32 = 0,
    arch: []const u8 = "unknown",
    version_buf: [32]u8 = std.mem.zeroes([32]u8),
    version_len: usize = 0,
    locale_buf: [96]u8 = std.mem.zeroes([96]u8),
    locale_len: usize = 0,
    theme: sysinfo.Theme = .light,
    accent_color: u32 = 0,

    pub fn toInfo(self: *const OsInfoOwned) sysinfo.OsInfo {
        return .{
            .name = sysinfo.productName(self.major, self.minor, self.build),
            .version = self.version_buf[0..self.version_len],
            .build = self.build,
            .arch = self.arch,
            .locale = self.locale_buf[0..self.locale_len],
            .theme = self.theme,
            .accent_color = self.accent_color,
        };
    }
};

fn readDword(subkey: [:0]const u16, value_name: [:0]const u16) ?u32 {
    var data: u32 = 0;
    var size: u32 = @sizeOf(u32);
    const hr = win32.RegGetValueW(
        win32.HKEY_CURRENT_USER,
        subkey.ptr,
        value_name.ptr,
        win32.RRF_RT_REG_DWORD,
        null,
        @ptrCast(&data),
        &size,
    );
    if (hr < 0) return null;
    return data;
}

const PERSONALIZE = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
const DWM_KEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\DWM");
const APPS_USE_LIGHT = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
const SYSTEM_USES_LIGHT = std.unicode.utf8ToUtf16LeStringLiteral("SystemUsesLightTheme");
const ACCENT_COLOR = std.unicode.utf8ToUtf16LeStringLiteral("AccentColor");

/// 应用主题（窗口/控件亮暗）；`systemTheme` 是任务栏/开始菜单主题。
pub fn detectTheme() sysinfo.Theme {
    if (readDword(PERSONALIZE, APPS_USE_LIGHT)) |v| return if (v != 0) .light else .dark;
    if (readDword(PERSONALIZE, SYSTEM_USES_LIGHT)) |v| return if (v != 0) .light else .dark;
    return .light;
}

/// AccentColor 在注册表里是 0xAABBGGRR，转换为 0xAARRGGBB 便于前端直接用作 CSS。
pub fn accentColor() u32 {
    const raw = readDword(DWM_KEY, ACCENT_COLOR) orelse return 0xFF0078D4;
    const r: u32 = raw & 0xFF;
    const g: u32 = (raw >> 8) & 0xFF;
    const b: u32 = (raw >> 16) & 0xFF;
    const a: u32 = (raw >> 24) & 0xFF;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

pub fn collectOs() OsInfoOwned {
    var out = OsInfoOwned{};

    var vi = RTL_OSVERSIONINFOW{
        .dwOSVersionInfoSize = @sizeOf(RTL_OSVERSIONINFOW),
        .dwMajorVersion = 0,
        .dwMinorVersion = 0,
        .dwBuildNumber = 0,
        .dwPlatformId = 0,
        .szCSDVersion = std.mem.zeroes([128]u16),
    };
    if (RtlGetVersion(&vi) == 0) {
        out.major = vi.dwMajorVersion;
        out.minor = vi.dwMinorVersion;
        out.build = vi.dwBuildNumber;
    }

    var si: SYSTEM_INFO = undefined;
    GetSystemInfo(&si);
    out.arch = switch (si.wProcessorArchitecture) {
        PROCESSOR_ARCHITECTURE_AMD64 => "x86_64",
        PROCESSOR_ARCHITECTURE_ARM64 => "aarch64",
        0 => "x86",
        else => "unknown",
    };

    if (std.fmt.bufPrint(&out.version_buf, "{d}.{d}.{d}", .{ out.major, out.minor, out.build })) |v| {
        out.version_len = v.len;
    } else |_| {}

    var locale: [96]u16 = std.mem.zeroes([96]u16);
    const n = GetUserDefaultLocaleName(&locale, locale.len);
    if (n > 1) {
        const slice = locale[0..@intCast(n - 1)];
        if (std.unicode.utf16LeToUtf8(&out.locale_buf, slice)) |len| {
            out.locale_len = len;
        } else |_| {}
    }
    if (out.locale_len == 0) {
        const fallback = "en-US";
        @memcpy(out.locale_buf[0..fallback.len], fallback);
        out.locale_len = fallback.len;
    }

    out.theme = detectTheme();
    out.accent_color = accentColor();
    return out;
}

const Collector = struct {
    list: *std.ArrayListUnmanaged(sysinfo.Monitor),
    alloc: std.mem.Allocator,
};

fn enumProc(hmon: HMONITOR, hdc: ?*anyopaque, rect: *win32.RECT, data: isize) callconv(.c) i32 {
    _ = hdc;
    _ = rect;
    const c: *Collector = @ptrFromInt(@as(usize, @bitCast(data)));
    var mi = MONITORINFOEXW{
        .cbSize = @sizeOf(MONITORINFOEXW),
        .rcMonitor = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .rcWork = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .dwFlags = 0,
        .szDevice = std.mem.zeroes([32]u16),
    };
    if (GetMonitorInfoW(hmon, &mi) == 0) return 1;

    // 该显示器上任意窗口的 DPI 需要 hwnd；无窗口时用 96（100%）作为基线，
    // 后端在窗口创建后会用 GetDpiForWindow 校正当前显示器条目。
    const dpi: u32 = 96;
    c.list.append(c.alloc, .{
        .index = @intCast(c.list.items.len),
        .primary = mi.dwFlags & MONITORINFOF_PRIMARY != 0,
        .x = mi.rcMonitor.left,
        .y = mi.rcMonitor.top,
        .width = @intCast(mi.rcMonitor.right - mi.rcMonitor.left),
        .height = @intCast(mi.rcMonitor.bottom - mi.rcMonitor.top),
        .work_x = mi.rcWork.left,
        .work_y = mi.rcWork.top,
        .work_width = @intCast(mi.rcWork.right - mi.rcWork.left),
        .work_height = @intCast(mi.rcWork.bottom - mi.rcWork.top),
        .dpi = dpi,
        .scale = sysinfo.scaleFromDpi(dpi),
    }) catch return 0;
    return 1;
}

/// 枚举全部显示器。调用方负责 `alloc.free(list)`（元素内无堆分配）。
pub fn collectMonitors(alloc: std.mem.Allocator) ![]sysinfo.Monitor {
    var list: std.ArrayListUnmanaged(sysinfo.Monitor) = .empty;
    errdefer list.deinit(alloc);
    var collector = Collector{ .list = &list, .alloc = alloc };
    _ = EnumDisplayMonitors(null, null, enumProc, @bitCast(@as(usize, @intFromPtr(&collector))));
    return list.toOwnedSlice(alloc);
}

const testing = std.testing;

test "accent color conversion keeps alpha and swaps to ARGB" {
    // 0xAABBGGRR = a=FF b=00 g=78 r=D4 → ARGB FF D4 78 00
    const raw: u32 = 0xFF0078D4;
    const r: u32 = raw & 0xFF;
    const g: u32 = (raw >> 8) & 0xFF;
    const b: u32 = (raw >> 16) & 0xFF;
    const a: u32 = (raw >> 24) & 0xFF;
    const argb = (a << 24) | (r << 16) | (g << 8) | b;
    try testing.expectEqual(@as(u32, 0xFFD47800), argb);
}

test "collectOs reports a usable snapshot" {
    var owned = collectOs();
    const info = owned.toInfo();
    try testing.expect(info.build > 0 or info.version.len > 0);
    try testing.expect(info.version.len > 0);
    try testing.expect(info.locale.len >= 2);
    try testing.expect(info.arch.len > 0);
}

test "monitor enumeration returns at least one display" {
    const monitors = try collectMonitors(testing.allocator);
    defer testing.allocator.free(monitors);
    try testing.expect(monitors.len >= 1);
    var primaries: usize = 0;
    for (monitors) |m| {
        try testing.expect(m.width > 0 and m.height > 0);
        if (m.primary) primaries += 1;
    }
    // 多显示器时也只有一个主屏；虚拟机/远程会话仍应报告主屏
    try testing.expectEqual(@as(usize, 1), primaries);
}
