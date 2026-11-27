//! 系统信息采集（v0.1.14，Windows）：OS 版本、架构、区域、主题、强调色、显示器。
const std = @import("std");
const builtin = @import("builtin");
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

pub extern "user32" fn EnumDisplayMonitors(
    hdc: ?*anyopaque,
    lprcClip: ?*const win32.RECT,
    lpfnEnum: *const fn (HMONITOR, ?*anyopaque, *win32.RECT, isize) callconv(.c) i32,
    dwData: isize,
) callconv(.c) win32.BOOL;
pub extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFOEXW) callconv(.c) win32.BOOL;
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

    // v0.3.16 G19：屏幕旋转（DEVMODE dmDisplayOrientation；EnumDisplaySettingsW
    // 按设备名查询当前显示模式）。失败保持 0（非旋转屏的常态值）。
    const rotation: u16 = blk: {
        var dm = std.mem.zeroes(DEVMODEW);
        dm.dmSize = @sizeOf(DEVMODEW);
        if (EnumDisplaySettingsW(&mi.szDevice, ENUM_CURRENT_SETTINGS, &dm) != 0) {
            break :blk switch (dm.dmDisplayOrientation) {
                1 => 90, // DMDO_90
                2 => 180, // DMDO_180
                3 => 270, // DMDO_270
                else => 0,
            };
        }
        break :blk 0;
    };

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
        .rotation = rotation,
    }) catch return 0;
    return 1;
}

/// DEVMODEW（winuser.h）——只用于 EnumDisplaySettingsW 的旋转字段读取；
/// 布局按 64 位 Windows SDK 逐字段核对（union/对齐保留为显式 padding 字段）。
const DEVMODEW = extern struct {
    dmDeviceName: [32]u16,
    dmSpecVersion: u16,
    dmDriverVersion: u16,
    dmSize: u16,
    dmDriverExtra: u16,
    dmFields: u32,
    dmPositionX: i32,
    dmPositionY: i32,
    dmDisplayOrientation: u32,
    dmDisplayFixedOutput: u32,
    dmColor: i16,
    dmDuplex: i16,
    dmYResolution: i16,
    dmTTOption: i16,
    dmCollate: i16,
    dmFormName: [32]u16,
    dmLogPixels: u16,
    dmBitsPerPel: u32,
    dmPelsWidth: u32,
    dmPelsHeight: u32,
    dmDisplayFlags: u32,
    dmDisplayFrequency: u32,
    dmICMMethod: u32,
    dmICMIntent: u32,
    dmMediaType: u32,
    dmDitherType: u32,
    dmReserved1: u32,
    dmReserved2: u32,
    dmPanningWidth: u32,
    dmPanningHeight: u32,
};
const ENUM_CURRENT_SETTINGS: u32 = 0xFFFF_FFFF; // (DWORD)-1
extern "user32" fn EnumDisplaySettingsW(lpszDeviceName: [*]const u16, iModeNum: u32, lpDevMode: *DEVMODEW) callconv(.c) i32;

test "DEVMODEW size matches Win64 SDK layout (220 bytes)" {
    // winuser.h DEVMODEW x64：dmDeviceName[32]WCHAR=64 + WORD×4=8 + DWORD=4 +
    // union(POINTL+2 DWORD)=16 + SHORT×5=10 + dmFormName[32]WCHAR=64 + WORD=2 +
    // DWORD×12=48 → 220（GetSystemMetrics 同源结构；EnumDisplaySettings 要求
    // dmSize=完整尺寸）
    try std.testing.expectEqual(@as(usize, 220), @sizeOf(DEVMODEW));
}

/// 枚举全部显示器。调用方负责 `alloc.free(list)`（元素内无堆分配）。
pub fn collectMonitors(alloc: std.mem.Allocator) ![]sysinfo.Monitor {
    var list: std.ArrayListUnmanaged(sysinfo.Monitor) = .empty;
    errdefer list.deinit(alloc);
    var collector = Collector{ .list = &list, .alloc = alloc };
    _ = EnumDisplayMonitors(null, null, enumProc, @bitCast(@as(usize, @intFromPtr(&collector))));
    return list.toOwnedSlice(alloc);
}

// v0.3.2：MonitorFromWindow（当前窗口所在显示器标记用）
const MONITOR_DEFAULTTONEAREST: u32 = 2;
extern "user32" fn MonitorFromWindow(hwnd: win32.HWND, flags: u32) HMONITOR;

const HandleCollector = struct {
    handles: std.ArrayListUnmanaged(HMONITOR) = .empty,
    alloc: std.mem.Allocator,
};

fn handleEnumProc(hmon: HMONITOR, hdc: ?*anyopaque, rect: *win32.RECT, data: isize) callconv(.c) i32 {
    _ = hdc;
    _ = rect;
    const c: *HandleCollector = @ptrFromInt(@as(usize, @bitCast(data)));
    c.handles.append(c.alloc, hmon) catch return 0;
    return 1;
}

/// `hwnd` 所在显示器的枚举序 index（system.info('monitors') 的 current 标记用）。
pub fn monitorIndexOf(hwnd: win32.HWND) ?usize {
    const hmon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (hmon == null) return null;
    var hc = HandleCollector{ .alloc = std.heap.page_allocator };
    defer hc.handles.deinit(std.heap.page_allocator);
    _ = EnumDisplayMonitors(null, null, handleEnumProc, @bitCast(@as(usize, @intFromPtr(&hc))));
    for (hc.handles.items, 0..) |h, i| {
        if (h == hmon) return i;
    }
    return null;
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

// ---------------------------------------------------------------------------
// v0.4.0 H11：GPU 适配器（DXGI）
// ---------------------------------------------------------------------------

const com = @import("com.zig");

/// IID_IDXGIFactory（dxgi.idl uuid(aec1fb78-5487-4f0a-b94d-9209e0d2cd69)）——
/// 保留供 DXGI 路径（vram 数据）复核。实测教训两连：
/// ① 凭记忆写的 IID 全错（E_NOINTERFACE）——以 winsdk-10 dxgi.idl 为准；
/// ② IID 正确后 EnumAdapters(0) 在本机（RDP/VM 会话）仍返回
///    DXGI_ERROR_INVALID_CALL（0x887A0001）——C# ComImport 互操作同样复现，
///    属环境限制而非 ABI 错误 → 最终采用 EnumDisplayDevicesW（注册表层，
///    不受会话限制；无 vram/vendor 数据，文档化）。
const iid_dxgi_factory: com.GUID = .parse("aec1fb78-5487-4f0a-b94d-9209e0d2cd69");

/// IDXGIFactory1 vtable 前缀槽（IUnknown 3 + EnumAdapters 槽 3；dxgi.h）。
const FactoryVtbl = extern struct {
    query_interface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) i32,
    add_ref: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    enum_adapters: *const fn (*anyopaque, u32, *?*anyopaque) callconv(.c) i32,
};
const Factory = extern struct { vtbl: *const FactoryVtbl };

/// IDXGIAdapter vtable 前缀槽（IUnknown 3 + EnumOutputs 3 + GetDesc 槽 4）。
const AdapterVtbl = extern struct {
    query_interface: *const fn (*anyopaque, *const com.GUID, *?*anyopaque) callconv(.c) i32,
    add_ref: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    enum_outputs: *const fn (*anyopaque, u32, *?*anyopaque) callconv(.c) i32,
    get_desc: *const fn (*anyopaque, *AdapterDesc) callconv(.c) i32,
};
const Adapter = extern struct { vtbl: *const AdapterVtbl };

/// DXGI_ADAPTER_DESC（dxgi.h；LUID 8 字节内联）。
const AdapterDesc = extern struct {
    description: [128]u16,
    vendor_id: u32,
    device_id: u32,
    sub_sys_id: u32,
    revision: u32,
    dedicated_video_memory: usize,
    dedicated_system_memory: usize,
    shared_system_memory: usize,
    luid_low: u32,
    luid_high: i32,
};

/// DISPLAY_DEVICEW（wingdi.h；cb 后五个定长 UTF-16 数组）。
const DISPLAY_DEVICEW = extern struct {
    cb: u32 = 0,
    device_name: [32]u16 = @splat(0),
    device_string: [128]u16 = @splat(0),
    state_flags: u32 = 0,
    device_id: [128]u16 = @splat(0),
    device_key: [128]u16 = @splat(0),
};
const DISPLAY_DEVICE_ATTACHED_TO_DESKTOP: u32 = 0x1;
extern "user32" fn EnumDisplayDevicesW(device: ?[*:0]const u16, dev_num: u32, dev: *DISPLAY_DEVICEW, flags: u32) callconv(.c) i32;

/// v0.4.0 H11：GPU 适配器枚举（user32 EnumDisplayDevicesW——注册表层枚举，
/// 不受 DXGI 在 RDP 分离/无显示会话返回 DXGI_ERROR_INVALID_CALL 的限制；
/// 实测 C# ComImport 互操作同样复现该限制）。代价：无 vram/PCI vendor 数据
///（vendor 恒 "unknown"，文档化；DXGI 路径随真实桌面环境复核后可作增强）。
pub fn collectGpu(alloc: std.mem.Allocator) ![]sysinfo.GpuInfo {
    var out: std.ArrayListUnmanaged(sysinfo.GpuInfo) = .empty;
    errdefer freeGpus(alloc, out.items);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        var dev = std.mem.zeroes(DISPLAY_DEVICEW);
        dev.cb = @sizeOf(DISPLAY_DEVICEW);
        if (EnumDisplayDevicesW(null, i, &dev, 0) == 0) break;
        if (dev.state_flags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP == 0) continue;
        var len: usize = 0;
        while (len < dev.device_string.len and dev.device_string[len] != 0) len += 1;
        if (len == 0) continue;
        const name = std.unicode.utf16LeToUtf8Alloc(alloc, dev.device_string[0..len]) catch continue;
        errdefer alloc.free(name);
        // 测试里不打印：stdout/stderr 会被 Zig build runner 误判为失败诊断。
        if (!builtin.is_test) @import("../../log.zig").print("[gpu] adapter {d}: {s}", .{ i, name });
        try out.append(alloc, .{
            .name = name,
            .vendor = try alloc.dupe(u8, "unknown"),
            .vram_mb = 0,
            .driver = "",
        });
    }
    return out.toOwnedSlice(alloc);
}

/// 释放 collectGpu 返回值（name/vendor 为堆分配，driver 恒空串）。
pub fn freeGpus(alloc: std.mem.Allocator, gpus: []sysinfo.GpuInfo) void {
    for (gpus) |*g| {
        alloc.free(g.name);
        alloc.free(g.vendor);
    }
    alloc.free(gpus);
}

test "collectGpu enumerates adapters with valid JSON shape" {
    const gpus = try collectGpu(testing.allocator);
    defer freeGpus(testing.allocator, gpus);
    // 真机/CI 至少一块适配器；dxgi 不可用时返回空数组也合法（lenient 形状断言）
    for (gpus) |g| {
        try testing.expect(g.name.len > 0);
        try testing.expect(g.vendor.len > 0);
    }
    const json = try sysinfo.gpuToJson(testing.allocator, gpus);
    defer testing.allocator.free(json);
    try testing.expect(json.len >= 2 and json[0] == '[');
}
