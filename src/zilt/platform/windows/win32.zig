//! Win32 最小绑定 —— 仅 PoC 所需（窗口/消息循环/定时器/COM 内存/注册表/动态库）。
//! 手写声明，零依赖；x64 编写（Windows x64 上 .c 即标准 x64 调用约定）。
//! ABI 依据：Win32 官方头文件结构（见 docs/reference/）。

const std = @import("std");
const com = @import("com.zig");

// ---- 基础类型 ----

pub const BOOL = i32;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WORD = u16;
pub const LONG = i32;
pub const ATOM = u16;
pub const LRESULT = isize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const HRESULT = com.HRESULT;

pub const HWND = ?*anyopaque;
pub const HINSTANCE = ?*anyopaque;
pub const HMODULE = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const HICON = ?*anyopaque;
pub const HCURSOR = ?*anyopaque;
pub const HBRUSH = ?*anyopaque;
pub const HANDLE = *anyopaque;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;

// ---- 常量 ----

pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const IDC_ARROW: usize = 32512;
pub const COLOR_WINDOW: usize = 5;

pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const SW_SHOW: i32 = 5;

pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_APP: UINT = 0x8000;

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const OPEN_EXISTING: DWORD = 3;
pub const CREATE_ALWAYS: DWORD = 2;

pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const LOAD_WITH_ALTERED_SEARCH_PATH: DWORD = 0x00000008;
pub const FILE_APPEND_DATA: DWORD = 0x0004;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const OPEN_ALWAYS: DWORD = 4;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x00000010;

pub const GMEM_MOVEABLE: UINT = 0x0002;

pub const COINIT_APARTMENTTHREADED: u32 = 0x2;

pub const RRF_RT_REG_SZ: DWORD = 0x00000002;

/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2（伪句柄 -4）
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: *anyopaque =
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

// ---- 结构体 ----

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: HICON,
};

pub const POINT = extern struct {
    x: LONG,
    y: LONG,
};

pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,
};

pub const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const TIMERPROC = ?*const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) void;

// ---- user32 ----

pub extern "user32" fn SetProcessDpiAwarenessContext(value: *anyopaque) callconv(.c) BOOL;
pub extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.c) ATOM;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: DWORD,
    x: i32,
    y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: HWND,
    hMenu: HMENU,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.c) HWND;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.c) BOOL;
pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.c) i32;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.c) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.c) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.c) void;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;
pub extern "user32" fn SetTimer(hWnd: HWND, nIDEvent: usize, uElapse: UINT, lpTimerFunc: TIMERPROC) callconv(.c) usize;
pub extern "user32" fn KillTimer(hWnd: HWND, uIDEvent: usize) callconv(.c) BOOL;
pub extern "user32" fn AdjustWindowRect(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL) callconv(.c) BOOL;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
pub extern "user32" fn LoadCursorW(hInstance: HINSTANCE, lpCursorName: LPCWSTR) callconv(.c) HCURSOR;

// ---- kernel32 ----

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.c) HINSTANCE;
pub extern "kernel32" fn LoadLibraryExW(lpLibFileName: LPCWSTR, hFile: ?*anyopaque, dwFlags: DWORD) callconv(.c) HMODULE;
pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.c) ?*anyopaque;
pub extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.c) BOOL;
pub extern "kernel32" fn GetFileAttributesW(lpFileName: LPCWSTR) callconv(.c) DWORD;
pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.c) ?*anyopaque;
pub extern "kernel32" fn GlobalLock(hMem: *anyopaque) callconv(.c) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: *anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?*anyopaque,
) callconv(.c) HANDLE;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn CreateDirectoryW(lpPathName: LPCWSTR, lpSecurityAttributes: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: LPCWSTR, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.c) DWORD;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.c) void;
pub extern "kernel32" fn GetFullPathNameW(lpFileName: LPCWSTR, nBufferLength: DWORD, lpBuffer: ?[*]u16, lpFilePart: ?*?[*]u16) callconv(.c) DWORD;
pub extern "kernel32" fn GetFileAttributesExW(lpFileName: LPCWSTR, fInfoLevelId: DWORD, lpFileInformation: *WIN32_FILE_ATTRIBUTE_DATA) callconv(.c) BOOL;
pub extern "kernel32" fn GetCommandLineW() callconv(.c) [*:0]u16;
pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern "shell32" fn CommandLineToArgvW(lpCmdLine: LPCWSTR, pNumArgs: *i32) callconv(.c) ?[*][*:0]u16;

pub const WIN32_FILE_ATTRIBUTE_DATA = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
};

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

pub extern "kernel32" fn FindFirstFileW(lpFileName: LPCWSTR, lpFindFileData: *WIN32_FIND_DATAW) callconv(.c) HANDLE;
pub extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.c) BOOL;
pub extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.c) BOOL;

pub const LARGE_INTEGER = extern struct {
    QuadPart: i64,
};

pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *LARGE_INTEGER) callconv(.c) BOOL;
pub extern "kernel32" fn SetFilePointer(hFile: HANDLE, lDistanceToMove: LONG, lpDistanceToMoveHigh: ?*LONG, dwMoveMethod: DWORD) callconv(.c) DWORD;
pub extern "user32" fn PostMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) BOOL;

/// 读取整个文件（UTF-8 路径）。失败返回 null。
pub fn readFileAlloc(alloc: std.mem.Allocator, path_u8: []const u8) ?[]u8 {
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path_u8) catch return null;
    defer alloc.free(path_w);
    const f = CreateFileW(path_w.ptr, GENERIC_READ, FILE_SHARE_READ | 0x2, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (f == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(f);

    var size: LARGE_INTEGER = .{ .QuadPart = 0 };
    if (GetFileSizeEx(f, &size) == 0 or size.QuadPart < 0 or size.QuadPart > 64 * 1024 * 1024) return null;

    const buf = alloc.alloc(u8, @intCast(size.QuadPart)) catch return null;
    var total: DWORD = 0;
    while (total < buf.len) {
        var got: DWORD = 0;
        if (ReadFile(f, buf.ptr + total, @intCast(buf.len - total), &got, null) == 0 or got == 0) {
            alloc.free(buf);
            return null;
        }
        total += got;
    }
    return buf;
}

/// 环境变量读取（UTF-8，Zig 0.17 移除 std.process.getEnvVarOwned 后的原生替代）。
pub fn getEnvUtf8(alloc: std.mem.Allocator, name_u8: []const u8) ?[]u8 {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, name_u8) catch return null;
    defer alloc.free(name_w);
    const need = GetEnvironmentVariableW(name_w.ptr, null, 0); // 字符数（不含 NUL）
    if (need == 0) return null;
    const buf = alloc.alloc(u16, need + 1) catch return null;
    defer alloc.free(buf);
    const got = GetEnvironmentVariableW(name_w.ptr, buf.ptr, @intCast(need + 1));
    if (got == 0 or got > need) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..got]) catch null;
}

// ---- ole32 ----

pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.c) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.c) void;
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.c) void;
pub extern "ole32" fn CreateStreamOnHGlobal(hGlobal: ?*anyopaque, fDeleteOnRelease: BOOL, ppstm: *?*anyopaque) callconv(.c) HRESULT;

// ---- advapi32 ----

pub const HKEY = *anyopaque;
pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);

pub extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    lpSubKey: LPCWSTR,
    lpValue: LPCWSTR,
    dwFlags: DWORD,
    pdwType: ?*DWORD,
    pvData: ?*anyopaque,
    pcbData: ?*DWORD,
) callconv(.c) HRESULT;
