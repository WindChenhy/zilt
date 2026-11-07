//! `zig build dev` 编排工具：
//!   1. （可选）spawn 前端 dev 命令（cmd /S /C 包装，Tauri dev.rs 同款）
//!   2. TCP 轮询等待 dev_url 就绪（2s 间隔 × N，Tauri 策略；TCP 而非 HTTP——
//!      Wails #6209 教训：vite 对无 Accept 头的探活回 404）
//!   3. spawn 应用 exe（继承环境 + 注入 ZILT_DEV_URL）
//!   4. dev server 与应用同挂 Job Object（KILL_ON_JOB_CLOSE）——退出即整树清理
//!
//! argv: <exe-path> <dev-command|-> <dev-url|-> <wait-timeout-secs> <frontend-dir> [proxy]
//!   proxy="1"（Phase C 反代模式）：注入 ZILT_DEV_PROXY=<dev-url> 而非 ZILT_DEV_URL
//!   ——应用保持自身 origin（custom scheme），资产请求转发上游（同源 cookie/fetch 场景）

const std = @import("std");

const DWORD = u32;
const BOOL = i32;
const HANDLE = *anyopaque;
const LPCWSTR = [*:0]const u16;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub extern "kernel32" fn CreateProcessW(lpApplicationName: ?LPCWSTR, lpCommandLine: ?[*:0]u16, lpProcessAttributes: ?*anyopaque, lpThreadAttributes: ?*anyopaque, bInheritHandles: BOOL, dwCreationFlags: DWORD, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?LPCWSTR, lpStartupInfo: *STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.c) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.c) DWORD;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.c) BOOL;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.c) HANDLE;
pub extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*anyopaque, lpName: ?LPCWSTR) callconv(.c) HANDLE;
pub extern "kernel32" fn SetInformationJobObject(hJob: HANDLE, JobObjectInformationClass: DWORD, lpJobObjectInformation: *anyopaque, cbJobObjectInformationLength: DWORD) callconv(.c) BOOL;
pub extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn GetFullPathNameW(lpFileName: LPCWSTR, nBufferLength: DWORD, lpBuffer: ?[*]u16, lpFilePart: ?*?[*]u16) callconv(.c) DWORD;
pub extern "kernel32" fn SetEnvironmentVariableW(lpName: LPCWSTR, lpValue: ?LPCWSTR) callconv(.c) BOOL;
pub extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) callconv(.c) i32;
pub extern "ws2_32" fn getaddrinfo(pNodeName: LPCWSTR, pServiceName: ?LPCWSTR, pHints: ?*const ADDRINFOW, ppResult: *?*ADDRINFOW) callconv(.c) i32;
pub extern "ws2_32" fn freeaddrinfo(pAddrInfo: *ADDRINFOW) callconv(.c) void;
pub extern "ws2_32" fn socket(af: i32, type_: i32, protocol: i32) callconv(.c) HANDLE;
pub extern "ws2_32" fn closesocket(s: HANDLE) callconv(.c) i32;
pub extern "ws2_32" fn connect(s: HANDLE, name: *const SOCKADDR, namelen: i32) callconv(.c) i32;

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
    wShowWindow: u16,
    cbReserved2: u16,
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

pub const WSADATA = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    ifVendorInfo: ?*anyopaque,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?*u8,
    szPad: [2]u8,
};

pub const ADDRINFOW = extern struct {
    aiFlags: i32,
    aiFamily: i32,
    aiSockType: i32,
    aiProtocol: i32,
    aiAddrlen: usize,
    aiCanonname: ?*u16,
    aiAddr: *SOCKADDR,
    aiNext: ?*ADDRINFOW,
};

pub const SOCKADDR = extern struct {
    family: u16,
    data: [14]u8,
};

pub const SOCKADDR_IN = extern struct {
    family: u16,
    port: u16,
    addr: [4]u8,
    zero: [8]u8,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: DWORD,
    Affinity: ?*anyopaque,
    PriorityClass: DWORD,
    UIRestrictionsClass: DWORD,
    IOReadLimit: usize,
    IOWriteLimit: usize,
    IOReadCount: usize,
    IOWriteCount: usize,
    PeakWorkingSetSize: usize,
    PeakPagefileUsage: usize,
};

const JobObjectExtendedLimitInformation: DWORD = 9;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x2000;
const PROCESS_TERMINATE: DWORD = 0x0001;
const INFINITE: DWORD = 0xFFFFFFFF;
const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    // ---- argv ----
    var argc: i32 = 0;
    const argv_w = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return error.ArgsFailed;
    defer _ = LocalFree(@ptrCast(argv_w));
    if (argc < 6) {
        log("usage: zilt-dev <exe-path> <dev-command|-> <dev-url|-> <wait-timeout-secs> <frontend-dir>", .{});
        return error.MissingArgs;
    }
    const exe_path = argUtf8(argv_w, 1);
    defer alloc.free(exe_path);
    const dev_command = argUtf8(argv_w, 2);
    defer alloc.free(dev_command);
    const dev_url = argUtf8(argv_w, 3);
    defer alloc.free(dev_url);
    const wait_secs = std.fmt.parseInt(u32, argUtf8(argv_w, 4), 10) catch 90;
    const frontend_dir_rel = argUtf8(argv_w, 5);
    defer alloc.free(frontend_dir_rel);
    // 反代标志（可选第 6 参；"1" = dev_proxy 模式）
    const proxy_flag = if (argc >= 7) argUtf8(argv_w, 6) else try alloc.dupe(u8, "-");
    defer alloc.free(proxy_flag);
    // CreateProcessW 的 lpCurrentDirectory 需要绝对路径
    const frontend_dir = blk: {
        const rel_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, frontend_dir_rel) catch break :blk frontend_dir_rel;
        defer alloc.free(rel_w);
        const need = GetFullPathNameW(rel_w.ptr, 0, null, null);
        if (need == 0) break :blk frontend_dir_rel;
        const buf = alloc.alloc(u16, need) catch break :blk frontend_dir_rel;
        defer alloc.free(buf);
        const got = GetFullPathNameW(rel_w.ptr, need, buf.ptr, null);
        if (got == 0) break :blk frontend_dir_rel;
        break :blk std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..got]) catch frontend_dir_rel;
    };
    defer alloc.free(frontend_dir);


    var wsa = WSADATA{ .wVersion = 0, .wHighVersion = 0, .ifVendorInfo = null, .szDescription = undefined, .szSystemStatus = undefined, .iMaxSockets = 0, .iMaxUdpDg = 0, .lpVendorInfo = null, .szPad = undefined };
    if (WSAStartup(0x0202, &wsa) != 0) return error.WSAStartupFailed;

    // ---- Job Object：整树清理 ----
    const job = CreateJobObjectW(null, null);
    if (job != INVALID_HANDLE_VALUE) {
        var info = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        info.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        _ = SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    }

    var dev_proc: ?PROCESS_INFORMATION = null;

    // ---- spawn dev 命令 ----
    if (dev_command.len > 0 and !std.mem.eql(u8, dev_command, "-")) {
        log("[dev] frontend dev command: {s}", .{dev_command});
        dev_proc = spawnWrapped(dev_command, frontend_dir) orelse {
            log("[dev] spawn failed", .{});
            return error.SpawnFailed;
        };
        if (job != INVALID_HANDLE_VALUE) {
            const h = OpenProcess(PROCESS_TERMINATE, 0, dev_proc.?.dwProcessId);
            if (h != INVALID_HANDLE_VALUE) {
                _ = AssignProcessToJobObject(job, h);
                _ = CloseHandle(h);
            }
        }
        log("[dev] pid={d}", .{dev_proc.?.dwProcessId});
    }

    // ---- TCP 轮询等待 dev_url ----
    if (dev_url.len > 0 and !std.mem.eql(u8, dev_url, "-")) {
        const host_port = parseHostPort(dev_url) orelse {
            log("[dev] cannot parse dev url: {s}", .{dev_url});
            return error.BadDevUrl;
        };
        const max_attempts = wait_secs / 2;
        log("[dev] waiting for frontend dev server on http://{s}:{d}/ ...", .{ host_port.host, host_port.port });
        var ok = false;
        var attempt: u32 = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            if (tcpProbe(host_port.host, host_port.port)) {
                ok = true;
                break;
            }
            Sleep(2000);
        }
        if (!ok) {
            log("[dev] dev server not reachable after {d}s", .{wait_secs});
            return error.DevServerTimeout;
        }
        log("[dev] dev server ready", .{});
    }

    // ---- 注入 dev 模式环境变量并启动应用 ----
    if (dev_url.len > 0 and !std.mem.eql(u8, dev_url, "-")) {
        if (std.mem.eql(u8, proxy_flag, "1")) {
            setEnvUtf8("ZILT_DEV_PROXY", dev_url);
            log("[dev] ZILT_DEV_PROXY={s}（反代模式：应用保持自身 origin）", .{dev_url});
        } else {
            setEnvUtf8("ZILT_DEV_URL", dev_url);
            log("[dev] ZILT_DEV_URL={s}", .{dev_url});
        }
    }
    log("[dev] launching app: {s}", .{exe_path});
    const app_proc = spawnDirect(exe_path, ".") orelse {
        log("[dev] spawn app failed", .{});
        return error.SpawnFailed;
    };
    if (job != INVALID_HANDLE_VALUE) {
        const h = OpenProcess(PROCESS_TERMINATE, 0, app_proc.dwProcessId);
        if (h != INVALID_HANDLE_VALUE) {
            _ = AssignProcessToJobObject(job, h);
            _ = CloseHandle(h);
        }
    }

    // ---- 等应用退出；随后 Job 句柄随进程关闭 → dev server 整树被杀 ----
    _ = WaitForSingleObject(app_proc.hProcess, INFINITE);
    log("[dev] app exited", .{});
    _ = CloseHandle(app_proc.hProcess);
    _ = CloseHandle(app_proc.hThread);
    if (dev_proc) |dp| {
        _ = TerminateProcess(dp.hProcess, 0);
        _ = CloseHandle(dp.hProcess);
        _ = CloseHandle(dp.hThread);
    }
    // job 句柄刻意不关闭直到进程退出（KILL_ON_JOB_CLOSE 生效点）——显式关闭以即时生效
    if (job != INVALID_HANDLE_VALUE) _ = CloseHandle(job);
}

fn argUtf8(argv: [*][*:0]u16, i: usize) []u8 {
    return std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, std.mem.span(argv[i])) catch "";
}

fn spawnWrapped(command: []const u8, cwd: []const u8) ?PROCESS_INFORMATION {
    // cmd /S /C <command>（Tauri dev.rs 同款；.cmd shim 必需）；cwd = frontend 目录
    // 注意 /S 语法：cmd /S /C "整条命令"——引号内完整保留
    const full = std.fmt.allocPrint(std.heap.page_allocator, "cmd /S /C \"{s}\"", .{command}) catch return null;
    defer std.heap.page_allocator.free(full);
    const r = spawnDirect(full, cwd);
    if (r == null) {
        std.debug.print("[dev] CreateProcessW failed GLE={d}\n", .{GetLastError()});
    }
    return r;
}
extern "kernel32" fn GetLastError() callconv(.c) u32;

fn spawnDirect(command_line: []const u8, cwd: []const u8) ?PROCESS_INFORMATION {
    const cl_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, command_line) catch return null;
    defer std.heap.page_allocator.free(cl_w);
    const cwd_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, cwd) catch return null;
    defer std.heap.page_allocator.free(cwd_w);

    var si = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    var pi = std.mem.zeroes(PROCESS_INFORMATION);

    if (CreateProcessW(null, cl_w.ptr, null, null, 0, 0, null, cwd_w.ptr, &si, &pi) == 0) return null;
    return pi;
}

const HostPort = struct { host: []u8, port: u16 };

/// "http://localhost:1420/..." → { host, port }（默认 80/443）
fn parseHostPort(url: []const u8) ?HostPort {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[scheme_end + 3 ..];
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..path_start];
    const default_port: u16 = if (std.mem.startsWith(u8, url, "https://")) 443 else 80;

    var host: []const u8 = authority;
    var port: u16 = default_port;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        // 排除 IPv6 字面量（[::1]:1420 形态暂不支持——dev 场景够用）
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch default_port;
    }
    const host_copy = std.heap.page_allocator.dupe(u8, host) catch return null;
    return .{ .host = host_copy, .port = port };
}

/// TCP 探测（直连 127.0.0.1:port——vite 默认绑定 loopback，避免 localhost 解析歧义）。
fn tcpProbe(host: []const u8, port: u16) bool {
    _ = host;
    var sa = std.mem.zeroes(SOCKADDR_IN);
    sa.family = AF_INET;
    sa.port = @byteSwap(port); // 网络字节序
    sa.addr = [4]u8{ 127, 0, 0, 1 };

    const s = socket(AF_INET, SOCK_STREAM, 0);
    if (s == INVALID_HANDLE_VALUE) return false;
    defer _ = closesocket(s);
    return connect(s, @ptrCast(&sa), @sizeOf(SOCKADDR_IN)) == 0;
}

fn setEnvUtf8(name: [:0]const u8, value: []const u8) void {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name) catch return;
    defer std.heap.page_allocator.free(name_w);
    const value_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, value) catch return;
    defer std.heap.page_allocator.free(value_w);
    _ = SetEnvironmentVariableW(name_w.ptr, value_w.ptr);
}

extern "kernel32" fn GetCommandLineW() callconv(.c) [*:0]u16;
extern "kernel32" fn LocalFree(p: ?*anyopaque) callconv(.c) ?*anyopaque;
extern "shell32" fn CommandLineToArgvW(lpCmdLine: LPCWSTR, pNumArgs: *i32) callconv(.c) ?[*][*:0]u16;
extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.c) void;

