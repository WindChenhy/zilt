//! v0.1.17：WebDriver 自动化（`zilt-driver`）。
//!
//! 对齐 Tauri 的 WebDriver 测试能力：不注入 JS，而是通过 W3C WebDriver 协议
//! 真实驱动系统 WebView。
//!
//! Windows（msedgedriver）链路：
//!   1. 启动应用（附加 ZILT_WEBVIEW2_ARGS=--remote-debugging-port=<debug_port>）
//!   2. 启动 msedgedriver --port=<driver_port>
//!   3. POST /session（ms:edgeOptions.debuggerAddress 指向上面的调试端口）
//!   4. POST /session/{id}/execute/sync 逐条执行断言脚本
//!   5. DELETE /session，杀应用与驱动
//!
//! Linux（WebKitWebDriver，v0.2.9）链路：
//!   1. 注入 ZILT_AUTOMATION=1（app 侧 webkit_web_context_set_automation_allowed）
//!   2. 启动 WebKitWebDriver -p <driver_port>（webkit2gtk-driver 包）
//!   3. POST /session（webkitgtk:browserOptions.binary = 应用 exe——WebKitWebDriver
//!      自己拉起应用，断言脚本同 W3C execute/sync）
//!   4. DELETE /session（WebKitWebDriver 终止它拉起的应用）
//!
//! 找不到驱动时打印 SKIP 并以退出码 3 结束（CI 里可区分「没环境」和「真失败」）。
//! 取得 msedgedriver：
//!   https://developer.microsoft.com/microsoft-edge/tools/webdriver/
//! Linux：sudo apt install webkit2gtk-driver

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

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

/// 工具进程的 Io（Threaded 惰性创建；HTTP 客户端/文件/进程 API 都走它）。
var g_threaded: Io.Threaded = undefined;
var g_threaded_ready = false;
/// v0.5.11：`Io.Threaded.init(.{})` 的默认 environ 是**空的**，`Child.spawn`
/// 会据此给子进程一个空环境——WebKitWebDriver 因此拿不到 DISPLAY，拉起的 app
/// 直接 `Gtk-WARNING cannot open display`。这里保存 main 收到的完整环境，
/// spawn 时显式传入（CI 46020253733 定位）。
var g_environ_map: ?*std.process.Environ.Map = null;
fn toolIo() Io {
    if (!g_threaded_ready) {
        g_threaded = .init(std.heap.page_allocator, .{});
        g_threaded_ready = true;
    }
    return g_threaded.io();
}

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const opts = parseArgs(alloc, init) catch |e| {
        std.debug.print("usage: zilt-driver <app.exe> [--driver msedgedriver.exe] [--script file.js] [--port 9516] [--debug-port 9223]\n", .{});
        std.debug.print("error: {s}\n", .{@errorName(e)});
        std.process.exit(2);
    };
    g_environ_map = init.environ_map;

    // Linux 自动化要求应用继承 DISPLAY；打出来便于区分「driver 没有」与
    // 「WebKitWebDriver 把环境洗掉了」两种 CI 失败（v0.5.11）。
    if (builtin.os.tag != .windows) {
        const disp = std.c.getenv("DISPLAY");
        log.info("DISPLAY={s}", .{if (disp) |p| std.mem.span(p) else "<unset>"});
    }

    const driver_path = findDriver(alloc, opts) orelse {
        log.info("SKIP — 未找到 WebDriver 实现（WebDriver 不可用）", .{});
        if (builtin.os.tag == .windows) {
            log.info("  获取: https://developer.microsoft.com/microsoft-edge/tools/webdriver/", .{});
            log.info("  然后: set ZILT_EDGEDRIVER_PATH=<path>\\msedgedriver.exe", .{});
        } else {
            log.info("  Linux: sudo apt install webkit2gtk-driver", .{});
            log.info("  或: ZILT_WEBKITDRIVER_PATH=/path/WebKitWebDriver zilt-driver ...", .{});
        }
        std.process.exit(3);
    };
    log.info("driver: {s}", .{driver_path});

    // 冒烟安全网不应干扰 driver（driver 自己负责退出；两平台 env 名都清）
    setEnv("ZILT_SMOKE_TEST_MS", "");
    setEnv("ZILT_LINUX_SMOKE", "");

    var io_ctx = IoCtx.init(alloc);
    defer io_ctx.deinit();

    if (builtin.os.tag == .windows) {
        // WebView2 需要打开 DevTools 调试端口（backend 读取该 env）
        {
            const args = std.fmt.allocPrint(alloc, "--remote-debugging-port={d}", .{opts.debug_port}) catch return error.OutOfMemory;
            defer alloc.free(args);
            setEnv("ZILT_WEBVIEW2_ARGS", args);
        }

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

        const session_id = createSession(alloc, &io_ctx, opts) catch |e| {
            log.fail("create session: {s}（调试端口是否就绪？）", .{@errorName(e)});
            killProcess(&app);
            if (driver) |*d| killProcess(d);
            std.process.exit(1);
        };
        defer destroySession(alloc, &io_ctx, opts, session_id);
        log.info("session {s} ready", .{session_id});

        const result = runAllChecks(alloc, &io_ctx, opts, session_id);
        log.info("done: {d}/{d} passed", .{ result.total - result.failed, result.total });
        killProcess(&app);
        if (driver) |*d| killProcess(d);
        if (result.failed > 0) std.process.exit(1);
        return;
    }

    // ---- Linux：WebKitWebDriver 自己拉起应用（browserOptions.binary）----
    // ZILT_AUTOMATION=1 经 env 继承传给应用 → webkit_web_context_set_automation_allowed
    setEnv("ZILT_AUTOMATION", "1");
    if (g_environ_map) |m| m.put("ZILT_AUTOMATION", "1") catch {};

    // v0.5.11：WebKitWebDriver 只认 `--port=<n>` 单参数形式（Ubuntu 24.04 的
    // webkit2gtk-driver 对 `--port <n>` 直接打 Usage 退出，CI 上表现为 session
    // 创建前 ABRT）。GOption 对两种写法都接受，故统一改等号形式。
    const port_arg = std.fmt.allocPrint(alloc, "--port={d}", .{opts.driver_port}) catch return error.OutOfMemory;
    var driver_child = spawnProcessLinux(alloc, &.{ driver_path, port_arg }, ".") orelse {
        log.fail("spawn WebKitWebDriver failed", .{});
        std.process.exit(1);
    };
    log.info("WebKitWebDriver pid={d} port={d}", .{ driver_child.id orelse 0, opts.driver_port });

    const session_id = createSessionLinux(alloc, &io_ctx, opts) catch |e| {
        log.fail("create session: {s}", .{@errorName(e)});
        killChild(&driver_child);
        std.process.exit(1);
    };
    defer destroySession(alloc, &io_ctx, opts, session_id);
    log.info("session {s} ready", .{session_id});

    const result = runAllChecks(alloc, &io_ctx, opts, session_id);
    log.info("done: {d}/{d} passed", .{ result.total - result.failed, result.total });
    killChild(&driver_child);
    if (result.failed > 0) std.process.exit(1);
}

/// 断言循环（默认 4 条 + 可选 --script 文件）；返回 {failed, total} 供收尾判定。
fn runAllChecks(alloc: std.mem.Allocator, io_ctx: *IoCtx, opts: Options, session_id: []const u8) struct { failed: usize, total: usize } {
    var failed: usize = 0;
    var total: usize = 0;
    for (default_checks) |c| {
        total += 1;
        if (runCheck(alloc, io_ctx, opts, session_id, c)) {
            log.info("PASS {s}", .{c.name});
        } else {
            failed += 1;
            log.fail("{s}", .{c.name});
        }
    }
    if (opts.script_file) |sf| {
        total += 1;
        const script = readFileAlloc(alloc, sf, 1 << 20) catch |e| {
            failed += 1;
            log.fail("read script {s}: {s}", .{ sf, @errorName(e) });
            return .{ .failed = failed, .total = total };
        };
        defer alloc.free(script);
        if (runCheck(alloc, io_ctx, opts, session_id, .{ .name = sf, .script = script })) {
            log.info("PASS {s}", .{sf});
        } else {
            failed += 1;
            log.fail("{s}", .{sf});
        }
    }
    return .{ .failed = failed, .total = total };
}

fn parseArgs(alloc: std.mem.Allocator, init: std.process.Init) !Options {
    // v0.2.9：argv 跨平台（Args.Iterator 两平台同用；替代 CommandLineToArgvW）
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer it.deinit();
    _ = it.skip(); // argv[0]

    const app = it.next() orelse return error.MissingAppPath;
    var opts = Options{ .app_exe = try alloc.dupe(u8, app) };
    while (it.next()) |raw| {
        const a: []const u8 = raw;
        if (std.mem.eql(u8, a, "--driver")) {
            if (it.next()) |v| opts.driver_exe = try alloc.dupe(u8, v);
        } else if (std.mem.eql(u8, a, "--script")) {
            if (it.next()) |v| opts.script_file = try alloc.dupe(u8, v);
        } else if (std.mem.eql(u8, a, "--port")) {
            if (it.next()) |v| opts.driver_port = std.fmt.parseInt(u16, v, 10) catch opts.driver_port;
        } else if (std.mem.eql(u8, a, "--debug-port")) {
            if (it.next()) |v| opts.debug_port = std.fmt.parseInt(u16, v, 10) catch opts.debug_port;
        } else if (std.mem.eql(u8, a, "--timeout")) {
            if (it.next()) |v| opts.startup_timeout_ms = (std.fmt.parseInt(u32, v, 10) catch 20) * 1000;
        }
    }
    return opts;
}

fn findDriver(alloc: std.mem.Allocator, opts: Options) ?[]const u8 {
    if (builtin.os.tag == .windows) {
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
    // Linux：WebKitWebDriver（webkit2gtk-driver 包）——显式路径 / env / PATH 扫描
    if (opts.driver_exe) |d| {
        if (fileExists(alloc, d)) return d;
    }
    if (getEnv(alloc, "ZILT_WEBKITDRIVER_PATH")) |p| {
        if (fileExists(alloc, p)) return p;
    }
    if (findInPath(alloc, "WebKitWebDriver")) |p| return p;
    return null;
}

/// PATH 扫描（WebKitWebDriver 用；与 cli.zig 的 findInPath 同规则）。
fn findInPath(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    const path_env = std.c.getenv("PATH") orelse return null;
    var dirs = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const cand = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch return null;
        defer alloc.free(cand);
        if (fileExists(alloc, cand)) return alloc.dupe(u8, cand) catch null;
    }
    return null;
}

fn fileExists(alloc: std.mem.Allocator, path: []const u8) bool {
    _ = alloc;
    _ = Io.Dir.cwd().statFile(toolIo(), path, .{}) catch return false;
    return true;
}

/// 读文件（v0.2.9：std.Io 化，两平台同用）。
fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(toolIo(), path, alloc, .limited(max));
}

fn getEnv(alloc: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
    if (builtin.os.tag == .windows) {
        const nw = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
        defer alloc.free(nw);
        var buf: [1024]u16 = undefined;
        const got = GetEnvironmentVariableW(nw.ptr, &buf, buf.len);
        if (got == 0 or got >= buf.len) return null;
        return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..got]) catch null;
    }
    const v = std.c.getenv(name.ptr) orelse return null;
    return alloc.dupe(u8, std.mem.span(v)) catch null;
}

extern "kernel32" fn GetEnvironmentVariableW(lpName: LPCWSTR, lpBuffer: [*]u16, nSize: DWORD) callconv(.c) DWORD;

/// libc setenv（0.17 的 std.c 无绑定；extern 名即 C 符号名）。
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn setEnv(name: [:0]const u8, value: []const u8) void {
    if (builtin.os.tag == .windows) {
        const alloc = std.heap.page_allocator;
        const nw = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return;
        defer alloc.free(nw);
        const vw = std.unicode.utf8ToUtf16LeAllocZ(alloc, value) catch return;
        defer alloc.free(vw);
        _ = SetEnvironmentVariableW(nw.ptr, vw.ptr);
        return;
    }
    // libc setenv（0.17 的 std.c 无绑定——直接 extern；driver 是工具进程，
    // 环境变量进程生命周期内有效）
    const name_z = std.heap.page_allocator.allocSentinel(u8, name.len, 0) catch return;
    defer std.heap.page_allocator.free(name_z);
    @memcpy(name_z, name);
    const value_z = std.heap.page_allocator.allocSentinel(u8, value.len, 0) catch return;
    defer std.heap.page_allocator.free(value_z);
    @memcpy(value_z, value);
    _ = setenv(name_z.ptr, value_z.ptr, 1);
}

/// Windows：CreateProcessW 命令行串；Linux：argv 数组。
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

/// Linux：std.process.spawn（argv 形式；stdio ignore——driver 的输出就够）。
fn spawnProcessLinux(alloc: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) ?std.process.Child {
    _ = cwd; // 继承当前目录（仓库根）
    _ = alloc;
    return std.process.spawn(toolIo(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = g_environ_map,
    }) catch null;
}

/// Linux：杀子进程（WebKitWebDriver；SIGKILL 直达）。
fn killChild(child: *std.process.Child) void {
    child.kill(toolIo()); // 0.17 的 Child.kill 返回 void（内部已兜底）
    _ = child.wait(toolIo()) catch {};
}

/// 跨平台毫秒睡眠（Clock.Duration；Windows 的 Sleep 与 createSession 轮询共用）。
fn sleepMs(ms: u64) void {
    if (builtin.os.tag == .windows) {
        Sleep(@intCast(ms));
        return;
    }
    const d: Io.Clock.Duration = .{ .raw = .{ .nanoseconds = @intCast(ms * 1_000_000) }, .clock = .real };
    d.sleep(toolIo()) catch {};
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
            sleepMs(500);
            continue;
        };
        break;
    }
    // 还要等 WebView2 的调试端口就绪：driver 的 /status 只说明驱动自己起来了，
    // POST /session 时 WebView2 若还没开 9223，msedgedriver 返回
    // 「session not created」（响应里没有 sessionId，表现为 NoSessionId）。
    if (!waitPort(io_ctx, opts.debug_port, opts.startup_timeout_ms)) {
        log.fail("debug port {d} not ready after {d}ms", .{ opts.debug_port, opts.startup_timeout_ms });
        return error.DebugPortNotReady;
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
    const sid = val.object.get("sessionId") orelse {
        log.fail("session response: {s}", .{resp[0..@min(resp.len, 600)]});
        return error.NoSessionId;
    };
    return alloc.dupe(u8, sid.string);
}

/// 等一个本地 TCP 端口可连（不读不写）。仅用于确认 WebView2 调试端口就绪。
fn waitPort(io_ctx: *IoCtx, port: u16, timeout_ms: u32) bool {
    const io = io_ctx.threaded.io();
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 200) {
        const addr = std.Io.net.IpAddress.resolve(io, "127.0.0.1", port) catch {
            sleepMs(200);
            continue;
        };
        var stream = addr.connect(io, .{ .mode = .stream }) catch {
            sleepMs(200);
            continue;
        };
        stream.close(io);
        return true;
    }
    return false;
}

/// Linux 会话：WebKitWebDriver 自己拉起 browserOptions.binary 指向的应用。
/// （W3C 端点与 Windows 同形——差异只在 capabilities 的方言。）
fn createSessionLinux(alloc: std.mem.Allocator, io_ctx: *IoCtx, opts: Options) ![]u8 {
    var waited: u32 = 0;
    while (waited < opts.startup_timeout_ms) : (waited += 500) {
        _ = httpRequest(alloc, io_ctx, opts.driver_port, "GET", "/status", null) catch {
            sleepMs(500);
            continue;
        };
        break;
    }
    const binary_json = try jsonEscape(alloc, opts.app_exe);
    defer alloc.free(binary_json);
    const body = try std.fmt.allocPrint(alloc,
        \\{{"capabilities":{{"alwaysMatch":{{"browserName":"webkitgtk","webkitgtk:browserOptions":{{"binary":"{s}","args":[]}}}}}}}}
    , .{binary_json});
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
