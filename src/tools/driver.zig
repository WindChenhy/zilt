//! v0.1.17：WebDriver 自动化（`zilt-driver`）。
//!
//! 对齐 Tauri 的 WebDriver 测试能力：不注入 JS，而是通过 **msedgedriver**
//! （W3C WebDriver 协议）真实驱动 WebView2。
//!
//! 链路：
//!   1. 启动应用（附加 ZILT_WEBVIEW2_ARGS=--remote-debugging-port=<debug_port>）
//!   2. 启动 msedgedriver --port=<driver_port>
//!   3. POST /session（ms:edgeOptions.debuggerAddress 指向上面的调试端口）
//!   4. POST /session/{id}/execute/sync 逐条执行断言脚本
//!   5. DELETE /session，杀应用与驱动
//!
//! 找不到 msedgedriver 时打印 SKIP 并以退出码 3 结束（CI 里可区分「没环境」和
//! 「真失败」）。取得 msedgedriver：
//!   https://developer.microsoft.com/microsoft-edge/tools/webdriver/
//!   或 `npx --yes @puppeteer/browsers install chromedriver` 同类工具。

const std = @import("std");

const DWORD = u32;
const BOOL = i32;
const HANDLE = *anyopaque;
const LPCWSTR = [*:0]const u16;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

extern "kernel32" fn CreateProcessW(lpApplicationName: ?LPCWSTR, lpCommandLine: ?[*:0]u16, lpProcessAttributes: ?*anyopaque, lpThreadAttributes: ?*anyopaque, bInheritHandles: BOOL, dwCreationFlags: DWORD, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?LPCWSTR, lpStartupInfo: *STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.c) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.c) DWORD;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.c) BOOL;
extern "kernel32" fn SetEnvironmentVariableW(lpName: LPCWSTR, lpValue: ?LPCWSTR) callconv(.c) BOOL;
extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.c) void;
extern "kernel32" fn GetLastError() callconv(.c) u32;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: DWORD) callconv(.c) DWORD;
extern "kernel32" fn GetFileAttributesW(lpFileName: LPCWSTR) callconv(.c) DWORD;
extern "shell32" fn CommandLineToArgvW(lpCmdLine: LPCWSTR, pNumArgs: *i32) callconv(.c) ?[*][*:0]u16;
extern "kernel32" fn GetCommandLineW() callconv(.c) [*:0]u16;
extern "kernel32" fn LocalFree(p: ?*anyopaque) callconv(.c) ?*anyopaque;

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

const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;

const log = struct {
    fn info(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[driver] " ++ fmt ++ "\n", args);
    }
    fn fail(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[driver] FAIL: " ++ fmt ++ "\n", args);
    }
};

const Options = struct {
    app_exe: []const u8,
    driver_exe: ?[]const u8 = null,
    script_file: ?[]const u8 = null,
    driver_port: u16 = 9516,
    debug_port: u16 = 9223,
    startup_timeout_ms: u32 = 20000,
};

/// 一条断言：执行 JS，返回值必须为真（truthy）。
const Check = struct {
    name: []const u8,
    script: []const u8,
};

const default_checks = [_]Check{
    .{ .name = "runtime", .script = "return !!(window.zilt && typeof window.zilt.version === 'string' && window.zilt.version.length > 0);" },
    .{ .name = "invoke", .script = "return typeof window.zilt.invoke === 'function';" },
    .{ .name = "dom", .script = "return !!document.body && document.body.children.length > 0;" },
    .{ .name = "title", .script = "return document.title.length > 0;" },
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const opts = parseArgs(alloc) catch |e| {
        std.debug.print("usage: zilt-driver <app.exe> [--driver msedgedriver.exe] [--script file.js] [--port 9516] [--debug-port 9223]\n", .{});
        std.debug.print("error: {s}\n", .{@errorName(e)});
        std.process.exit(2);
    };

    const driver_path = findDriver(alloc, opts) orelse {
        log.info("SKIP — 未找到 msedgedriver（WebDriver 不可用）", .{});
        log.info("  获取: https://developer.microsoft.com/microsoft-edge/tools/webdriver/", .{});
        log.info("  然后: set ZILT_EDGEDRIVER_PATH=<path>\\msedgedriver.exe", .{});
        std.process.exit(3);
    };
    log.info("msedgedriver: {s}", .{driver_path});

    // 关键：让 WebView2 打开 DevTools 调试端口（backend 读取该 env）
    {
        const args = std.fmt.allocPrint(alloc, "--remote-debugging-port={d}", .{opts.debug_port}) catch return error.OutOfMemory;
        defer alloc.free(args);
        setEnv("ZILT_WEBVIEW2_ARGS", args);
    }
    // 冒烟安全网不应干扰 driver（driver 自己负责退出）
    setEnv("ZILT_SMOKE_TEST_MS", "");

    var app = spawnProcess(alloc, opts.app_exe, ".") orelse {
        log.fail("spawn app failed GLE={d}", .{GetLastError()});
        std.process.exit(1);
    };
    log.info("app pid={d}", .{app.dwProcessId});

    var driver: ?PROCESS_INFORMATION = null;
    {
        const cmd = std.fmt.allocPrint(alloc, "{s} --port={d}", .{ driver_path, opts.driver_port }) catch {
            killProcess(&app);
            std.process.exit(1);
        };
        defer alloc.free(cmd);
        driver = spawnProcess(alloc, cmd, ".") orelse {
            log.fail("spawn msedgedriver failed GLE={d}", .{GetLastError()});
            killProcess(&app);
            std.process.exit(1);
        };
        log.info("msedgedriver pid={d} port={d}", .{ driver.?.dwProcessId, opts.driver_port });
    }

    var io_ctx = IoCtx.init(alloc);
    defer io_ctx.deinit();

    const session_id = createSession(alloc, &io_ctx, opts) catch |e| {
        log.fail("create session: {s}（调试端口是否就绪？）", .{@errorName(e)});
        killProcess(&app);
        if (driver) |*d| killProcess(d);
        std.process.exit(1);
    };
    defer destroySession(alloc, &io_ctx, opts, session_id);
    log.info("session {s} ready", .{session_id});

    var failed: usize = 0;
    var total: usize = 0;
    for (default_checks) |c| {
        total += 1;
        if (runCheck(alloc, &io_ctx, opts, session_id, c)) {
            log.info("PASS {s}", .{c.name});
        } else {
            failed += 1;
            log.fail("{s}", .{c.name});
        }
    }
    if (opts.script_file) |sf| {
        total += 1;
        const script = readFileAlloc(alloc, sf, 1 << 20) catch |e| {
            log.fail("read script {s}: {s}", .{ sf, @errorName(e) });
            killProcess(&app);
            if (driver) |*d| killProcess(d);
            std.process.exit(1);
        };
        defer alloc.free(script);
        if (runCheck(alloc, &io_ctx, opts, session_id, .{ .name = sf, .script = script })) {
            log.info("PASS {s}", .{sf});
        } else {
            failed += 1;
            log.fail("{s}", .{sf});
        }
    }

    log.info("done: {d}/{d} passed", .{ total - failed, total });
    killProcess(&app);
    if (driver) |*d| killProcess(d);
    if (failed > 0) std.process.exit(1);
}

fn parseArgs(alloc: std.mem.Allocator) !Options {
    var argc: i32 = 0;
    const argv_w = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return error.ArgsFailed;
    defer _ = LocalFree(@ptrCast(argv_w));
    if (argc < 2) return error.MissingAppPath;

    var opts = Options{ .app_exe = try utf8Arg(alloc, argv_w[1]) };
    var i: usize = 2;
    while (i < argc) : (i += 1) {
        const a = try utf8Arg(alloc, argv_w[i]);
        if (std.mem.eql(u8, a, "--driver")) {
            i += 1;
            if (i < argc) opts.driver_exe = try utf8Arg(alloc, argv_w[i]);
        } else if (std.mem.eql(u8, a, "--script")) {
            i += 1;
            if (i < argc) opts.script_file = try utf8Arg(alloc, argv_w[i]);
        } else if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            if (i < argc) {
                const p = try utf8Arg(alloc, argv_w[i]);
                opts.driver_port = std.fmt.parseInt(u16, p, 10) catch opts.driver_port;
            }
        } else if (std.mem.eql(u8, a, "--debug-port")) {
            i += 1;
            if (i < argc) {
                const p = try utf8Arg(alloc, argv_w[i]);
                opts.debug_port = std.fmt.parseInt(u16, p, 10) catch opts.debug_port;
            }
        } else if (std.mem.eql(u8, a, "--timeout")) {
            i += 1;
            if (i < argc) {
                const p = try utf8Arg(alloc, argv_w[i]);
                opts.startup_timeout_ms = (std.fmt.parseInt(u32, p, 10) catch 20) * 1000;
            }
        }
    }
    return opts;
}

fn utf8Arg(alloc: std.mem.Allocator, w: [*:0]const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(w)) catch error.InvalidArg;
}

fn findDriver(alloc: std.mem.Allocator, opts: Options) ?[]const u8 {
    if (opts.driver_exe) |d| {
        if (fileExists(alloc, d)) return d;
    }
    if (getEnv(alloc, "ZILT_EDGEDRIVER_PATH")) |p| {
        if (fileExists(alloc, p)) return p;
    }
    // app exe 同目录
    if (std.fs.path.dirname(opts.app_exe)) |dir| {
        const p = std.fmt.allocPrint(alloc, "{s}\\msedgedriver.exe", .{dir}) catch return null;
        if (fileExists(alloc, p)) return p;
    }
    // PATH 搜索：用 cmd 的 where 太绕，直接试 cwd / 系统盘常见位置
    if (fileExists(alloc, "msedgedriver.exe")) return "msedgedriver.exe";
    return null;
}

fn fileExists(alloc: std.mem.Allocator, path: []const u8) bool {
    const w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return false;
    defer alloc.free(w);
    return GetFileAttributesW(w.ptr) != INVALID_FILE_ATTRIBUTES;
}

/// 读文件（0.17 无 std.fs.cwd：用 CreateFileW + ReadFile 直读）。
fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(w);
    const GENERIC_READ: DWORD = 0x80000000;
    const FILE_SHARE_READ: DWORD = 0x1;
    const OPEN_EXISTING: DWORD = 3;
    const f = CreateFileW(w.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
    if (f == INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer _ = CloseHandle(f);
    const buf = try alloc.alloc(u8, max);
    errdefer alloc.free(buf);
    var read: DWORD = 0;
    if (ReadFile(f, buf.ptr, @intCast(max), &read, null) == 0) return error.ReadFailed;
    return try alloc.realloc(buf, read);
}

extern "kernel32" fn CreateFileW(lpFileName: LPCWSTR, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?*anyopaque) callconv(.c) HANDLE;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: *DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;

fn getEnv(alloc: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
    const nw = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
    defer alloc.free(nw);
    var buf: [1024]u16 = undefined;
    const got = GetEnvironmentVariableW(nw.ptr, &buf, buf.len);
    if (got == 0 or got >= buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..got]) catch null;
}

extern "kernel32" fn GetEnvironmentVariableW(lpName: LPCWSTR, lpBuffer: [*]u16, nSize: DWORD) callconv(.c) DWORD;

fn setEnv(name: [:0]const u8, value: []const u8) void {
    const alloc = std.heap.page_allocator;
    const nw = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return;
    defer alloc.free(nw);
    const vw = std.unicode.utf8ToUtf16LeAllocZ(alloc, value) catch return;
    defer alloc.free(vw);
    _ = SetEnvironmentVariableW(nw.ptr, vw.ptr);
}

fn spawnProcess(alloc: std.mem.Allocator, cmd: []const u8, cwd: []const u8) ?PROCESS_INFORMATION {
    const cl_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, cmd) catch return null;
    defer alloc.free(cl_w);
    const cwd_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, cwd) catch return null;
    defer alloc.free(cwd_w);
    var si = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    var pi = std.mem.zeroes(PROCESS_INFORMATION);
    if (CreateProcessW(null, cl_w.ptr, null, null, 0, 0, null, cwd_w.ptr, &si, &pi) == 0) return null;
    return pi;
}

fn killProcess(p: *PROCESS_INFORMATION) void {
    _ = TerminateProcess(p.hProcess, 0);
    _ = WaitForSingleObject(p.hProcess, 3000);
    _ = CloseHandle(p.hProcess);
    _ = CloseHandle(p.hThread);
}

// ---------------------------------------------------------------------------
// 极简 HTTP/1.1 客户端（只服务 localhost 的 WebDriver）：Connection: close
// → 读到 EOF 即完整响应。避免依赖 std.http 的版本语义。
// ---------------------------------------------------------------------------

const IoCtx = struct {
    threaded: std.Io.Threaded,

    fn init(alloc: std.mem.Allocator) IoCtx {
        return .{ .threaded = .init(alloc, .{}) };
    }

    fn deinit(self: *IoCtx) void {
        self.threaded.deinit();
    }
};

fn httpRequest(alloc: std.mem.Allocator, io_ctx: *IoCtx, port: u16, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
    const io = io_ctx.threaded.io();
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [8192]u8 = undefined;
    var wr = stream.writer(io, &wbuf);
    const out = &wr.interface;
    if (body) |b| {
        try out.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ method, path, port, b.len });
        try out.writeAll(b);
    } else {
        try out.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ method, path, port });
    }
    try out.flush();

    var rbuf: [8192]u8 = undefined;
    var rd = stream.reader(io, &rbuf);
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    errdefer acc.deinit(alloc);

    // 先读头（到 \r\n\r\n）；再按 Content-Length 精确读体。
    // 读 EOF 的做法会挂住——msedgedriver 会忽略 Connection: close 保持连接（实测）。
    var head_end: ?usize = null;
    var content_length: ?usize = null;
    while (acc.items.len < (1 << 20)) {
        const b = rd.interface.takeByte() catch break;
        try acc.append(alloc, b);
        if (head_end == null and acc.items.len >= 4 and std.mem.eql(u8, acc.items[acc.items.len - 4 ..], "\r\n\r\n")) {
            head_end = acc.items.len;
            const head = acc.items[0..head_end.?];
            var lines = std.mem.splitSequence(u8, head, "\r\n");
            _ = lines.next(); // status line
            while (lines.next()) |ln| {
                if (ln.len == 0) break;
                const colon = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, ln[0..colon], " "), "content-length")) {
                    content_length = std.fmt.parseInt(usize, std.mem.trim(u8, ln[colon + 1 ..], " "), 10) catch null;
                }
            }
            if (content_length == null) break; // 无体响应（204 等）
            if (content_length.? == 0) break;
            const want = head_end.? + content_length.?;
            while (acc.items.len < want) {
                const nb = rd.interface.takeByte() catch break;
                try acc.append(alloc, nb);
            }
            break;
        }
    }
    const raw = try acc.toOwnedSlice(alloc);
    defer alloc.free(raw);
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadResponse;
    return alloc.dupe(u8, raw[sep + 4 ..]);
}

fn createSession(alloc: std.mem.Allocator, io_ctx: *IoCtx, opts: Options) ![]u8 {
    // 等 msedgedriver 起来
    var waited: u32 = 0;
    while (waited < opts.startup_timeout_ms) : (waited += 500) {
        _ = httpRequest(alloc, io_ctx, opts.driver_port, "GET", "/status", null) catch {
            Sleep(500);
            continue;
        };
        break;
    }
    const body = try std.fmt.allocPrint(alloc,
        \\{{"capabilities":{{"alwaysMatch":{{"browserName":"webview2","ms:edgeOptions":{{"debuggerAddress":"127.0.0.1:{d}","args":["--remote-debugging-port={d}"]}}}}}}}}
    , .{ opts.debug_port, opts.debug_port });
    defer alloc.free(body);
    const resp = try httpRequest(alloc, io_ctx, opts.driver_port, "POST", "/session", body);
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const val = parsed.value.object.get("value") orelse return error.BadResponse;
    const sid = val.object.get("sessionId") orelse return error.NoSessionId;
    return alloc.dupe(u8, sid.string);
}

fn destroySession(alloc: std.mem.Allocator, io_ctx: *IoCtx, opts: Options, session_id: []const u8) void {
    const path = std.fmt.allocPrint(alloc, "/session/{s}", .{session_id}) catch return;
    defer alloc.free(path);
    const resp = httpRequest(alloc, io_ctx, opts.driver_port, "DELETE", path, null) catch return;
    alloc.free(resp);
}

fn runCheck(alloc: std.mem.Allocator, io_ctx: *IoCtx, opts: Options, session_id: []const u8, check: Check) bool {
    const path = std.fmt.allocPrint(alloc, "/session/{s}/execute/sync", .{session_id}) catch return false;
    defer alloc.free(path);
    // script 需要 JSON 转义
    const esc = jsonEscape(alloc, check.script) catch return false;
    defer alloc.free(esc);
    const body = std.fmt.allocPrint(alloc, "{{\"script\":\"{s}\",\"args\":[]}}", .{esc}) catch return false;
    defer alloc.free(body);
    const resp = httpRequest(alloc, io_ctx, opts.driver_port, "POST", path, body) catch return false;
    defer alloc.free(resp);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp, .{}) catch return false;
    defer parsed.deinit();
    const val = parsed.value.object.get("value") orelse return false;
    return switch (val) {
        .bool => |b| b,
        .string => |s| s.len > 0,
        .integer => |n| n != 0,
        .null => false,
        else => true,
    };
}

fn jsonEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

test "jsonEscape quotes newlines and backslashes" {
    const a = std.testing.allocator;
    const s = try jsonEscape(a, "a\"b\\c\nd");
    defer a.free(s);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd", s);
}
