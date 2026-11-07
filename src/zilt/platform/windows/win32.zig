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
pub const SW_HIDE: i32 = 0;

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
pub const MOVEFILE_REPLACE_EXISTING: DWORD = 0x1;

// 托盘 / 通知（shellapi.h）
pub const NIM_ADD: DWORD = 0x00000000;
pub const NIM_MODIFY: DWORD = 0x00000001;
pub const NIM_DELETE: DWORD = 0x00000002;
pub const NIM_SETVERSION: DWORD = 0x00000004;
pub const NIF_MESSAGE: UINT = 0x00000001;
pub const NIF_ICON: UINT = 0x00000002;
pub const NIF_TIP: UINT = 0x00000004;
pub const NIF_INFO: UINT = 0x00000010;
pub const NIIF_INFO: DWORD = 0x00000001;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const IDI_APPLICATION: usize = 32512;
pub const ERROR_ALREADY_EXISTS: DWORD = 183;

// 菜单 / 对话框 / 全局快捷键
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_HOTKEY: UINT = 0x0312;
pub const MF_STRING: UINT = 0x00000000;
pub const MF_POPUP: UINT = 0x00000010;
pub const MF_SEPARATOR: UINT = 0x00000800;
pub const MB_ICONERROR: DWORD = 0x00000010;
pub const MB_ICONWARNING: DWORD = 0x00000030;
pub const MB_ICONINFORMATION: DWORD = 0x00000040;
pub const MB_OK: DWORD = 0x00000000;
pub const MB_OKCANCEL: DWORD = 0x00000001;
pub const MB_YESNO: DWORD = 0x00000004;
pub const MB_SETFOREGROUND: DWORD = 0x00010000;
pub const IDOK: i32 = 1;
pub const IDCANCEL: i32 = 2;
pub const IDYES: i32 = 6;
pub const IDNO: i32 = 7;
pub const MOD_ALT: UINT = 0x0001;
pub const MOD_CONTROL: UINT = 0x0002;
pub const MOD_SHIFT: UINT = 0x0004;
pub const MOD_WIN: UINT = 0x0008;
pub const OFN_OVERWRITEPROMPT: DWORD = 0x00000002;
pub const OFN_HIDEREADONLY: DWORD = 0x00000004;
pub const OFN_NOCHANGEDIR: DWORD = 0x00000008;
pub const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
pub const OFN_FILEMUSTEXIST: DWORD = 0x00001000;

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

// ---- 托盘 / 通知 / 单实例 / 文件原子替换 ----

pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: HICON,
    szTip: [128]u16,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]u16,
    uTimeout: UINT, // union{uTimeout, uVersion} —— 布局等价
    szInfoTitle: [64]u16,
    dwInfoFlags: DWORD,
    guidItem: [16]u8,
    hBalloonIcon: HICON,
};

pub extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *NOTIFYICONDATAW) callconv(.c) BOOL;
pub extern "user32" fn LoadIconW(hInstance: HINSTANCE, lpIconName: LPCWSTR) callconv(.c) HICON;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.c) BOOL;
pub extern "kernel32" fn CreateMutexW(lpMutexAttributes: ?*anyopaque, bInitialOwner: BOOL, lpName: LPCWSTR) callconv(.c) HANDLE;
pub extern "kernel32" fn GetLastError() callconv(.c) DWORD;
pub extern "kernel32" fn MoveFileExW(lpExistingFileName: LPCWSTR, lpNewFileName: LPCWSTR, dwFlags: DWORD) callconv(.c) BOOL;
pub extern "kernel32" fn DeleteFileW(lpFileName: LPCWSTR) callconv(.c) BOOL;
pub extern "kernel32" fn RemoveDirectoryW(lpPathName: LPCWSTR) callconv(.c) BOOL;

// ---- 菜单 / 对话框 / 全局快捷键 ----

pub const OPENFILENAMEW = extern struct {
    lStructSize: DWORD,
    hwndOwner: HWND,
    hInstance: HINSTANCE,
    lpstrFilter: ?LPCWSTR,
    lpstrCustomFilter: ?LPWSTR,
    nMaxCustFilter: DWORD,
    nFilterIndex: DWORD,
    lpstrFile: LPWSTR,
    nMaxFile: DWORD,
    lpstrFileTitle: ?LPWSTR,
    nMaxFileTitle: DWORD,
    lpstrInitialDir: ?LPCWSTR,
    lpstrTitle: ?LPCWSTR,
    Flags: DWORD,
    nFileOffset: WORD,
    nFileExtension: WORD,
    lpstrDefExt: ?LPCWSTR,
    lCustData: LONG,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?*anyopaque,
    pvReserved: ?*anyopaque,
    dwReserved: DWORD,
    FlagsEx: DWORD,
};

pub extern "user32" fn MessageBoxW(hWnd: HWND, lpText: LPCWSTR, lpCaption: LPCWSTR, uType: UINT) callconv(.c) i32;
pub extern "user32" fn CreateMenu() callconv(.c) HMENU;
pub extern "user32" fn CreatePopupMenu() callconv(.c) HMENU;
pub extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?LPCWSTR) callconv(.c) BOOL;
pub extern "user32" fn SetMenu(hWnd: HWND, hMenu: HMENU) callconv(.c) BOOL;
pub extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.c) BOOL;
pub extern "user32" fn RegisterHotKey(hWnd: HWND, id: i32, fsModifiers: UINT, vk: UINT) callconv(.c) BOOL;
pub extern "user32" fn UnregisterHotKey(hWnd: HWND, id: i32) callconv(.c) BOOL;
pub extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.c) BOOL;
pub extern "comdlg32" fn GetSaveFileNameW(lpofn: *OPENFILENAMEW) callconv(.c) BOOL;

/// 打开/保存文件对话框共用的构造（可单测）。
pub const OfnBuffers = struct {
    filter: [:0]u16,
    file: []u16,
    title: [:0]u16,
    def_ext: ?[:0]u16,
    ofn: OPENFILENAMEW,
};

pub fn makeOfn(
    hwnd: HWND,
    title_u8: []const u8,
    filter_utf16: [:0]u16,
    default_name_u8: []const u8,
    save_mode: bool,
) OfnBuffers {
    const title = utf16zFrom(title_u8);
    const file = utf16zFrom(default_name_u8);
    // 文件缓冲需要额外空间供用户输入长路径
    var file_buf = std.heap.page_allocator.alloc(u16, @max(file.len + 1, 4096)) catch unreachable;
    @memset(file_buf, 0);
    @memcpy(file_buf[0..file.len], file);
    std.heap.page_allocator.free(file);

    var flags: DWORD = OFN_HIDEREADONLY | OFN_NOCHANGEDIR;
    if (save_mode) {
        flags |= OFN_OVERWRITEPROMPT;
    } else {
        flags |= OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST;
    }

    return .{
        .filter = filter_utf16,
        .file = file_buf,
        .title = title,
        .def_ext = null,
        .ofn = .{
            .lStructSize = @sizeOf(OPENFILENAMEW),
            .hwndOwner = hwnd,
            .hInstance = null,
            .lpstrFilter = filter_utf16.ptr,
            .lpstrCustomFilter = null,
            .nMaxCustFilter = 0,
            .nFilterIndex = 1,
            .lpstrFile = @ptrCast(file_buf.ptr),
            .nMaxFile = @intCast(file_buf.len),
            .lpstrFileTitle = null,
            .nMaxFileTitle = 0,
            .lpstrInitialDir = null,
            .lpstrTitle = title.ptr,
            .Flags = flags,
            .nFileOffset = 0,
            .nFileExtension = 0,
            .lpstrDefExt = null,
            .lCustData = 0,
            .lpfnHook = null,
            .lpTemplateName = null,
            .pvReserved = null,
            .dwReserved = 0,
            .FlagsEx = 0,
        },
    };
}

/// UTF-8 → UTF-16Z（页分配器；对话框低频调用可接受）。
pub fn utf16zFrom(s: []const u8) [:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, s) catch unreachable;
}
pub extern "kernel32" fn GetModuleFileNameW(hModule: HMODULE, lpFilename: [*]u16, nSize: DWORD) callconv(.c) DWORD;
pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.c) BOOL;

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?*anyopaque,
    lpDesktop: ?*anyopaque,
    lpTitle: ?*anyopaque,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: WORD,
    cbReserved2: WORD,
    lpReserved2: ?*anyopaque,
    hStdInput: ?*anyopaque,
    hStdOutput: ?*anyopaque,
    hStdError: ?*anyopaque,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

/// 写整个文件（UTF-8 路径）。失败返回 false。
pub fn writeFileAlloc(alloc: std.mem.Allocator, path_u8: []const u8, data: []const u8) bool {
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path_u8) catch return false;
    defer alloc.free(path_w);
    const f = CreateFileW(path_w.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (f == INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(f);
    var written: DWORD = 0;
    return WriteFile(f, data.ptr, @intCast(data.len), &written, null) != 0;
}

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
