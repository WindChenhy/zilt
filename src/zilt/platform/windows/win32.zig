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
pub const HDC = ?*anyopaque;
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
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
pub const WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x00200000;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const SW_SHOW: i32 = 5;
pub const SW_HIDE: i32 = 0;

pub const WM_NULL: UINT = 0x0000;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_MOVE: UINT = 0x0003;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_SETTINGCHANGE: UINT = 0x001A;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
// v0.1.23：无边框覆盖式标题栏（WM_NCCALCSIZE / 命中测试）
pub const WM_NCCALCSIZE: UINT = 0x0083;
pub const WM_NCHITTEST: UINT = 0x0084;
pub const WM_NCACTIVATE: UINT = 0x0086;
pub const HTCLIENT: LRESULT = 1;
pub const HTLEFT: LRESULT = 10;
pub const HTRIGHT: LRESULT = 11;
pub const HTTOP: LRESULT = 12;
pub const HTTOPLEFT: LRESULT = 13;
pub const HTTOPRIGHT: LRESULT = 14;
pub const HTBOTTOM: LRESULT = 15;
pub const HTBOTTOMLEFT: LRESULT = 16;
pub const HTBOTTOMRIGHT: LRESULT = 17;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_COPYDATA: UINT = 0x004A;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_SETICON: UINT = 0x0080;
pub const WM_NCLBUTTONDOWN: UINT = 0x00A1;
pub const WM_TIMER: UINT = 0x0113;
// v0.3.3：窗口体验包 II
pub const WM_NCLBUTTONDBLCLK: UINT = 0x00A3;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WA_INACTIVE: WPARAM = 0;
pub const WM_EXITSIZEMOVE: UINT = 0x0232;
pub const SC_SIZE: DWORD = 0xF000;
pub const SC_CLOSE: DWORD = 0xF060;
pub const SC_MINIMIZE: DWORD = 0xF020;
pub const SC_MAXIMIZE: DWORD = 0xF030;
pub const MF_ENABLED: UINT = 0x00000000;
pub const MF_GRAYED: UINT = 0x00000001;
pub const RGN_OR: c_int = 2;
pub extern "user32" fn GetSystemMenu(hwnd: HWND, revert: BOOL) ?*anyopaque;
pub extern "user32" fn EnableMenuItem(hMenu: ?*anyopaque, uIDEnableItem: DWORD, uEnable: UINT) BOOL;
pub extern "gdi32" fn CreateRectRgn(x1: c_int, y1: c_int, x2: c_int, y2: c_int) ?*anyopaque;
pub extern "gdi32" fn CombineRgn(hrgnDest: *anyopaque, hrgnSrc1: *anyopaque, hrgnSrc2: *anyopaque, mode: c_int) c_int;
pub extern "user32" fn SetWindowRgn(hwnd: HWND, hRgn: ?*anyopaque, redraw: BOOL) c_int;
pub const RECT_NIF = extern struct { left: c_int, top: c_int, right: c_int, bottom: c_int };
pub extern "shell32" fn Shell_NotifyIconGetRect(dwIdentifier: DWORD, hWnd: HWND, uID: DWORD, iconLocation: *RECT_NIF) c_int;
pub extern "user32" fn CopyAcceleratorTableW(hacc: ?*anyopaque, paccel: ?[*]ACCEL, cAccel: c_int) c_int;
pub const WM_DROPFILES: UINT = 0x0233;
pub const WM_DPICHANGED: UINT = 0x02E0;
// v0.3.2：电源/会话事件
pub const WM_POWERBROADCAST: UINT = 0x0218;
pub const WM_WTSSESSION_CHANGE: UINT = 0x02B1;
pub const PBT_APMSUSPEND: DWORD = 4;
pub const PBT_APMRESUMESUSPEND: DWORD = 7;
pub const PBT_APMPOWERSTATUSCHANGE: DWORD = 10;
pub const PBT_APMRESUMEAUTOMATIC: DWORD = 18;
pub const WTS_SESSION_LOGON: DWORD = 5;
pub const WTS_SESSION_LOGOFF: DWORD = 6;
pub const WTS_SESSION_LOCK: DWORD = 7;
pub const WTS_SESSION_UNLOCK: DWORD = 8;
pub const NOTIFY_FOR_THIS_SESSION: DWORD = 0;

pub const WM_THEMECHANGED: UINT = 0x031A;
pub const WM_APP: UINT = 0x8000;
pub const HTCAPTION: usize = 2;
pub const HTMINBUTTON: usize = 8;
pub const HTMAXBUTTON: usize = 9;
pub const HTCLOSE: usize = 20;


// 窗口控制
pub const SW_MINIMIZE: i32 = 6;
pub const SW_MAXIMIZE: i32 = 3;
pub const SW_RESTORE: i32 = 9;
pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;
pub const WS_POPUP: DWORD = 0x80000000;
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_SHOWWINDOW: UINT = 0x0040;
pub const ICON_SMALL: UINT = 0;
pub const ICON_BIG: UINT = 1;
pub const LR_DEFAULTCOLOR: UINT = 0x0000;
pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SM_CXSCREEN: i32 = 0;
pub const SM_CYSCREEN: i32 = 1;
pub const SM_CXICON: i32 = 11;
pub const SM_CYICON: i32 = 12;
/// 小图标（托盘/titlebar）：100% DPI = 16，150% = 24，200% = 32
pub const SM_CXSMICON: i32 = 49;
pub const SM_CYSMICON: i32 = 50;

// 剪贴板格式
pub const CF_UNICODETEXT: UINT = 13;

// 托盘弹出菜单
pub const TPM_RIGHTBUTTON: UINT = 0x0002;
pub const TPM_RETURNCMD: UINT = 0x0100;

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
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
pub const RRF_RT_REG_DWORD: DWORD = 0x00000010;

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

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const COPYDATASTRUCT = extern struct {
    dwData: usize,
    cbData: DWORD,
    lpData: ?*anyopaque,
};

pub const TIMERPROC = ?*const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) void;

// ---- user32 ----

pub extern "user32" fn SetFocus(hWnd: HWND) callconv(.c) HWND;
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
pub extern "user32" fn PostThreadMessageW(idThread: DWORD, msg: UINT, wParam: usize, lParam: isize) callconv(.c) BOOL;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.c) DWORD;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.c) i32;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.c) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.c) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.c) void;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;
pub extern "user32" fn SetTimer(hWnd: HWND, nIDEvent: usize, uElapse: UINT, lpTimerFunc: TIMERPROC) callconv(.c) usize;
pub extern "user32" fn KillTimer(hWnd: HWND, uIDEvent: usize) callconv(.c) BOOL;
pub extern "user32" fn AdjustWindowRect(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL) callconv(.c) BOOL;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.c) HWND;
pub extern "user32" fn LoadCursorW(hInstance: HINSTANCE, lpCursorName: ?*const anyopaque) callconv(.c) HCURSOR;
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.c) BOOL;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: HWND, x: i32, y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.c) BOOL;
pub extern "user32" fn SetWindowLongW(hWnd: HWND, nIndex: i32, dwNewLong: LONG) callconv(.c) LONG;
pub extern "user32" fn GetWindowLongW(hWnd: HWND, nIndex: i32) callconv(.c) LONG;
pub extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.c) i32;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.c) BOOL;
pub extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const RECT) callconv(.c) BOOL;
pub extern "user32" fn FindWindowW(lpClassName: ?LPCWSTR, lpWindowName: ?LPCWSTR) callconv(.c) HWND;
pub extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;
pub extern "user32" fn CreateIconFromResourceEx(presbits: [*]u8, dwResSize: DWORD, fIcon: BOOL, dwVer: DWORD, cx: i32, cy: i32, uFlags: UINT) callconv(.c) HICON;
pub extern "user32" fn DestroyIcon(hIcon: HICON) callconv(.c) BOOL;
pub extern "user32" fn IsIconic(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn ReleaseCapture() callconv(.c) BOOL;
pub extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(.c) UINT;
pub extern "user32" fn FillRect(hdc: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.c) i32;
pub extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.c) BOOL;
pub extern "gdi32" fn CreateSolidBrush(color: DWORD) callconv(.c) HBRUSH;
pub extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(.c) BOOL;
pub extern "user32" fn MonitorFromPoint(pt: POINT, flags: DWORD) ?*anyopaque;
pub extern "user32" fn SystemParametersInfoW(uiAction: UINT, uiParam: UINT, pvParam: ?*anyopaque, fWinIni: UINT) BOOL;


// ---- 剪贴板（user32）----

pub extern "user32" fn OpenClipboard(hWndNewOwner: HWND) callconv(.c) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.c) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.c) BOOL;
pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.c) ?*anyopaque;

// ---- 文件拖放（shell32）----

pub extern "shell32" fn DragAcceptFiles(hWnd: HWND, fAccept: BOOL) callconv(.c) void;
pub extern "shell32" fn DragQueryFileW(hDrop: HANDLE, iFile: UINT, lpszFile: ?[*]u16, cch: UINT) callconv(.c) UINT;
pub extern "shell32" fn DragFinish(hDrop: HANDLE) callconv(.c) void;

// ---- kernel32 ----

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.c) HINSTANCE;
pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.c) BOOL;
pub extern "kernel32" fn LoadLibraryExW(lpLibFileName: LPCWSTR, hFile: ?*anyopaque, dwFlags: DWORD) callconv(.c) HMODULE;
pub extern "kernel32" fn LoadLibraryW(lpLibFileName: LPCWSTR) callconv(.c) HMODULE;
pub const MAX_PATH_W: u32 = 260;
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
pub extern "kernel32" fn CopyFileW(lpExistingFileName: LPCWSTR, lpNewFileName: LPCWSTR, bFailIfExists: BOOL) callconv(.c) BOOL;
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
pub extern "kernel32" fn SetCurrentDirectoryW(lpPathName: LPCWSTR) callconv(.c) BOOL;
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

pub extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *u32) callconv(.c) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.c) u32;

const DETACHED_PROCESS: u32 = 0x8;
const CREATE_NEW_PROCESS_GROUP: u32 = 0x200;
const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x1000000;

/// 分离进程 spawn（更新重启接力用）：先尝试脱离 Job（dev 编排下 Job 会整树清理，
/// 接力进程必须幸存）；不允许脱离则原样创建（生产环境无 Job，本就无影响）。
pub fn spawnDetached(exe_path: []const u8, args: []const u8) ?PROCESS_INFORMATION {
    const cl = std.fmt.allocPrintSentinel(std.heap.page_allocator, "\"{s}\" {s}", .{ exe_path, args }, 0) catch return null;
    defer std.heap.page_allocator.free(cl);
    const exe_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, exe_path) catch return null;
    defer std.heap.page_allocator.free(exe_w);
    const cl_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, cl) catch return null;
    defer std.heap.page_allocator.free(cl_w);

    var si = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    var pi = std.mem.zeroes(PROCESS_INFORMATION);
    const flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB;
    if (CreateProcessW(exe_w.ptr, cl_w.ptr, null, null, 0, flags, null, null, &si, &pi) != 0) return pi;
    if (CreateProcessW(exe_w.ptr, cl_w.ptr, null, null, 0, DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP, null, null, &si, &pi) != 0) return pi;
    return null;
}
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

pub const REG_SZ: DWORD = 1;
pub const KEY_WRITE: DWORD = 0x20006;

pub extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    Reserved: DWORD,
    lpClass: ?LPCWSTR,
    dwOptions: DWORD,
    samDesired: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*DWORD,
) callconv(.c) LONG;
pub extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    lpValueName: LPCWSTR,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: ?[*]const u8,
    cbData: DWORD,
) callconv(.c) LONG;
pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.c) LONG;

// ---------------------------------------------------------------------------
// v0.1.18：窗口精细控制（光标/穿透/截屏保护/阴影/层序/菜单加速键/托盘 hover）
// ---------------------------------------------------------------------------

pub const HCURSOR_ALIAS = HCURSOR;
pub const HBITMAP = ?*anyopaque;
pub const HACCEL = ?*anyopaque;

/// 系统光标 id（IDC_*）
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_UPARROW: usize = 32516;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;
pub const IDC_HELP: usize = 32651;

pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_LBUTTONDBLCLK: UINT = 0x0203;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_RBUTTONDBLCLK: UINT = 0x0206;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MBUTTONDBLCLK: UINT = 0x0209;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const WM_WINDOWPOSCHANGING: UINT = 0x0046;
pub const WM_GETICON: UINT = 0x007F;

pub const WS_EX_TRANSPARENT: DWORD = 0x00000020;
pub const WS_EX_LAYERED: DWORD = 0x00080000;
pub const WS_EX_NOACTIVATE: DWORD = 0x08000000;

pub const HWND_BOTTOM: HWND = @ptrFromInt(1);


pub const WDA_NONE: DWORD = 0x00000000;
pub const WDA_EXCLUDEFROMCAPTURE: DWORD = 0x00000011;

pub const TME_LEAVE: DWORD = 0x00000002;
pub const TME_HOVER: DWORD = 0x00000001;

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD,
};

pub const WINDOWPOS = extern struct {
    hwnd: HWND,
    hwndInsertAfter: HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: UINT,
};

/// MENUITEMINFOA/W（用 W 版）。
pub const MENUITEMINFOW = extern struct {
    cbSize: UINT,
    fMask: UINT,
    fType: UINT,
    fState: UINT,
    wID: UINT,
    hSubMenu: HMENU,
    hbmpChecked: HBITMAP,
    hbmpUnchecked: HBITMAP,
    dwItemData: usize,
    dwTypeData: ?LPWSTR,
    cch: UINT,
    hbmpItem: HBITMAP,
};

pub const MIIM_STATE: UINT = 0x00000001;
pub const MIIM_ID: UINT = 0x00000002;
pub const MIIM_BITMAP: UINT = 0x00000080;
pub const MF_BYCOMMAND: UINT = 0x00000000;
pub const MF_BYPOSITION: UINT = 0x00000400;

/// 加速键表项（ACCEL）。
pub const ACCEL = extern struct {
    fVirt: u8,
    key: WORD,
    cmd: WORD,
};

pub const FVIRTKEY: u8 = 0x01;
pub const FNOINVERT: u8 = 0x02;
pub const FSHIFT: u8 = 0x04;
pub const FCONTROL: u8 = 0x08;
pub const FALT: u8 = 0x10;

pub const MARGINS = extern struct {
    cxLeftWidth: i32,
    cxRightWidth: i32,
    cyTopHeight: i32,
    cyBottomHeight: i32,
};

pub extern "user32" fn SetCursor(hCursor: HCURSOR) callconv(.c) HCURSOR;
pub extern "user32" fn ShowCursor(bShow: BOOL) callconv(.c) i32;
pub extern "user32" fn SetCapture(hWnd: HWND) callconv(.c) HWND;
pub extern "user32" fn SetCursorPos(X: i32, Y: i32) callconv(.c) BOOL;
pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, crKey: DWORD, bAlpha: u8, dwFlags: DWORD) callconv(.c) BOOL;
pub extern "user32" fn SetWindowDisplayAffinity(hWnd: HWND, dwAffinity: DWORD) callconv(.c) BOOL;
pub extern "user32" fn EnableWindow(hWnd: HWND, bEnable: BOOL) callconv(.c) BOOL;
pub extern "user32" fn IsWindowEnabled(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(.c) BOOL;
pub extern "user32" fn TranslateAcceleratorW(hWnd: HWND, hAccTable: HACCEL, lpMsg: *MSG) callconv(.c) c_int;
pub extern "user32" fn CreateAcceleratorTableW(paccel: [*]ACCEL, cAccel: c_int) callconv(.c) HACCEL;
pub extern "user32" fn DestroyAcceleratorTable(hAccel: HACCEL) callconv(.c) BOOL;
pub extern "user32" fn SetMenuItemBitmaps(hMenu: HMENU, uPosition: UINT, uFlags: UINT, hBitmapUnchecked: HBITMAP, hBitmapChecked: HBITMAP) callconv(.c) BOOL;
pub extern "user32" fn LoadImageW(hinst: HINSTANCE, name: LPCWSTR, type: UINT, cx: c_int, cy: c_int, fuLoad: UINT) callconv(.c) ?*anyopaque;
pub extern "user32" fn GetIconInfo(hIcon: HICON, piconinfo: *ICONINFO) callconv(.c) BOOL;
pub extern "user32" fn GetActiveWindow() callconv(.c) HWND;
pub extern "user32" fn GetFocus() callconv(.c) HWND;
pub extern "user32" fn GetClassNameW(hWnd: HWND, lpClassName: [*]u16, nMaxCount: c_int) callconv(.c) c_int;
pub extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: DWORD) callconv(.c) ?*anyopaque;
pub extern "user32" fn GetMonitorInfoW(hMonitor: ?*anyopaque, lpmi: *MONITORINFO) callconv(.c) BOOL;

pub const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

pub const MONITOR_DEFAULTTONEAREST: DWORD = 0x00000002;

pub const ICONINFO = extern struct {
    fIcon: BOOL,
    xHotspot: DWORD,
    yHotspot: DWORD,
    hbmMask: HBITMAP,
    hbmColor: HBITMAP,
};

pub const IMAGE_ICON: UINT = 1;
pub const IMAGE_BITMAP: UINT = 0;
pub const LR_LOADFROMFILE: UINT = 0x00000010;
pub const LR_DEFAULTSIZE: UINT = 0x00000040;
pub const LR_SHARED: UINT = 0x00008000;

pub const WS_EX_TOPMOST: DWORD = 0x00000008;

// 编辑命令（菜单角色用）
pub const WM_CUT: UINT = 0x0300;
pub const WM_COPY: UINT = 0x0301;
pub const WM_PASTE: UINT = 0x0302;
pub const WM_CLEAR: UINT = 0x0303;
pub const WM_UNDO: UINT = 0x0304;
pub const EM_SETSEL: UINT = 0x00B1;

pub extern "kernel32" fn GetTickCount64() callconv(.c) u64;

// ---------------------------------------------------------------------------
// v0.1.22：目录监视（fs.watch）
// ---------------------------------------------------------------------------
pub const FILE_LIST_DIRECTORY: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const FILE_SHARE_DELETE: DWORD = 0x00000004;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;

pub const FILE_NOTIFY_CHANGE_FILE_NAME: DWORD = 0x00000001;
pub const FILE_NOTIFY_CHANGE_DIR_NAME: DWORD = 0x00000002;
pub const FILE_NOTIFY_CHANGE_LAST_WRITE: DWORD = 0x00000010;
pub const FILE_NOTIFY_CHANGE_SIZE: DWORD = 0x00000008;

pub const FILE_ACTION_ADDED: DWORD = 1;
pub const FILE_ACTION_REMOVED: DWORD = 2;
pub const FILE_ACTION_MODIFIED: DWORD = 3;
pub const FILE_ACTION_RENAMED_OLD_NAME: DWORD = 4;
pub const FILE_ACTION_RENAMED_NEW_NAME: DWORD = 5;

pub const FILE_NOTIFY_INFORMATION = extern struct {
    NextEntryOffset: DWORD,
    Action: DWORD,
    FileNameLength: DWORD,
    // 变长文件名紧随其后（UTF-16，无 NUL）
};

pub extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferLength: DWORD,
    bWatchSubtree: BOOL,
    dwNotifyFilter: DWORD,
    lpBytesReturned: ?*DWORD,
    lpOverlapped: ?*anyopaque,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.c) BOOL;
pub extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;

// ---------------------------------------------------------------------------
// v0.3.16 G18：任务栏文本徽标（内存位图 + GDI 文本渲染 → CreateIconIndirect）
// ---------------------------------------------------------------------------

pub const BITMAPINFOHEADER = extern struct {
    biSize: u32,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: u32,
    biSizeImage: u32,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: u32,
    biClrImportant: u32,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 align(4),
};

pub extern "gdi32" fn CreateCompatibleDC(hdc: HDC) callconv(.c) HDC;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.c) BOOL;
pub extern "gdi32" fn CreateDIBSection(hdc: HDC, pbmi: *const BITMAPINFO, usage: u32, ppvBits: *?*anyopaque, hSection: ?*anyopaque, offset: u32) callconv(.c) HBITMAP;
pub extern "gdi32" fn CreateBitmap(width: i32, height: i32, planes: u32, bits_pixel: u32, bits: ?*const anyopaque) callconv(.c) HBITMAP;
pub extern "gdi32" fn SelectObject(hdc: HDC, hgdiobj: HGDIOBJ) callconv(.c) HGDIOBJ;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: u32) callconv(.c) u32;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.c) i32;
pub extern "gdi32" fn GetStockObject(i: i32) callconv(.c) HGDIOBJ;
pub extern "user32" fn DrawTextW(hdc: HDC, text: [*]const u16, cch: i32, lprc: *RECT, format: u32) callconv(.c) i32;
pub extern "user32" fn CreateIconIndirect(iconinfo: *const ICONINFO) callconv(.c) HICON;

pub const HGDIOBJ = ?*anyopaque;
pub const DIB_RGB_COLORS: u32 = 0;
pub const TRANSPARENT_BK: i32 = 1;
pub const DT_CENTER: u32 = 0x1;
pub const DT_VCENTER: u32 = 0x4;
pub const DT_SINGLELINE: u32 = 0x20;
pub const DEFAULT_GUI_FONT: i32 = 17;
