//! WinHTTP 客户端（v0.1.20）：HTTP(S) 请求 + WebSocket（含 wss）。
//!
//! 为什么换 WinHTTP（而不是继续 std.http + 手写 RFC6455）：
//!  - wss 需要 TLS；WinHTTP 自带 Schannel，`WinHttpWebSocketCompleteUpgrade`
//!    一条链路同时拿到 https/wss、系统代理、超时、重定向、证书策略
//!  - 流式下载靠 `WinHttpReadData` 分块，不需要把整个响应读进内存
//!
//! 动态加载 winhttp.dll（与本项目 sqlite/WebView2 的做法一致）：不改 build.zig
//! 的链接配置，缺失时给出可诊断错误，而不是链接期失败。
const std = @import("std");
const win32 = @import("win32.zig");
const net = @import("../../net.zig");

pub const HINTERNET = ?*anyopaque;

// ---- 常量（winhttp.h）----
const WINHTTP_ACCESS_TYPE_DEFAULT_PROXY: u32 = 0;
const WINHTTP_ACCESS_TYPE_NO_PROXY: u32 = 1;
const WINHTTP_ACCESS_TYPE_NAMED_PROXY: u32 = 3;

const WINHTTP_FLAG_SECURE: u32 = 0x00800000;

const WINHTTP_OPTION_CONNECT_TIMEOUT: u32 = 3;
const WINHTTP_OPTION_SEND_TIMEOUT: u32 = 5;
const WINHTTP_OPTION_RECEIVE_TIMEOUT: u32 = 6;
/// WinHttpSetTimeouts 的 receive 超时不覆盖「等响应头」阶段，必须单独设这个选项。
const WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT: u32 = 7;
const WINHTTP_OPTION_SECURITY_FLAGS: u32 = 31;
const WINHTTP_OPTION_REDIRECT_POLICY: u32 = 88;
const WINHTTP_OPTION_DISABLE_FEATURE: u32 = 63;
const WINHTTP_DISABLE_REDIRECTS: u32 = 2;
const WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET: u32 = 114;

const WINHTTP_QUERY_STATUS_CODE: u32 = 19;
const WINHTTP_QUERY_FLAG_NUMBER: u32 = 0x20000000;

const WINHTTP_OPTION_REDIRECT_POLICY_NEVER: u32 = 2;

const SECURITY_FLAG_IGNORE_UNKNOWN_CA: u32 = 0x00000100;
const SECURITY_FLAG_IGNORE_CERT_CN_INVALID: u32 = 0x00001000;
const SECURITY_FLAG_IGNORE_CERT_DATE_INVALID: u32 = 0x00002000;

/// WINHTTP_WEB_SOCKET_*_BUFFER_TYPE
pub const WebSocketBuffer = enum(u32) {
    binary_message = 0,
    binary_fragment = 1,
    utf8_message = 2,
    utf8_fragment = 3,
    close = 4,
};

/// 常见错误码 → 语义名（前端能直接判别的稳定字符串）
fn errorNameFor(code: u32) []const u8 {
    return switch (code) {
        12001 => "OutOfHandles",
        12002 => "Timeout",
        12007 => "NameNotResolved",
        12017 => "OperationCancelled",
        12029 => "CannotConnect",
        12030 => "ConnectionError",
        12032 => "InvalidServerResponse",
        12037 => "ClientAuthCertNeeded",
        12175 => "SecureFailure",
        0 => "Ok",
        else => "WinHttpError",
    };
}

fn errFor(code: u32) anyerror {
    return switch (code) {
        12002 => error.Timeout,
        12007 => error.NameNotResolved,
        12029 => error.CannotConnect,
        12030 => error.ConnectionError,
        12175 => error.SecureFailure,
        else => error.WinHttpFailed,
    };
}

// ---- 动态加载 ----

const Api = struct {
    Open: *const fn ([*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.c) HINTERNET,
    Connect: *const fn (HINTERNET, [*:0]const u16, u16, u32) callconv(.c) HINTERNET,
    OpenRequest: *const fn (HINTERNET, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, ?*const ?[*:0]const u16, u32) callconv(.c) HINTERNET,
    SetOption: *const fn (HINTERNET, u32, ?*const anyopaque, u32) callconv(.c) win32.BOOL,
    SendRequest: *const fn (HINTERNET, ?[*:0]const u16, u32, ?*const anyopaque, u32, u32, usize) callconv(.c) win32.BOOL,
    ReceiveResponse: *const fn (HINTERNET, ?*anyopaque) callconv(.c) win32.BOOL,
    QueryHeaders: *const fn (HINTERNET, u32, ?[*:0]const u16, ?*anyopaque, *u32, ?*u32) callconv(.c) win32.BOOL,
    ReadData: *const fn (HINTERNET, [*]u8, u32, *u32) callconv(.c) win32.BOOL,
    /// v0.3.8 E6：分块写请求体（SendRequest 传 NULL body + dwTotalLength 后逐块写，
    /// 每块回调节流上报上传进度）
    WriteData: *const fn (HINTERNET, *const anyopaque, u32, *u32) callconv(.c) win32.BOOL,
    CloseHandle: *const fn (HINTERNET) callconv(.c) win32.BOOL,
    SetTimeouts: *const fn (HINTERNET, i32, i32, i32, i32) callconv(.c) win32.BOOL,
    QueryOption: *const fn (HINTERNET, u32, ?*anyopaque, *u32) callconv(.c) win32.BOOL,
    WebSocketCompleteUpgrade: *const fn (HINTERNET, ?*anyopaque) callconv(.c) HINTERNET,
    WebSocketSend: *const fn (HINTERNET, WebSocketBuffer, ?[*]const u8, u32) callconv(.c) u32,
    WebSocketReceive: *const fn (HINTERNET, [*]u8, u32, *u32, *WebSocketBuffer) callconv(.c) u32,
    WebSocketClose: *const fn (HINTERNET, u16, ?[*]const u8, u32) callconv(.c) u32,
    WebSocketQueryCloseStatus: *const fn (HINTERNET, *u16, ?[*]u8, u32, *u32) callconv(.c) u32,
};

var api_state: union(enum) {
    uninit,
    missing,
    ready: Api,
} = .uninit;

fn api() ?*const Api {
    switch (api_state) {
        .ready => |*a| return a,
        .missing => return null,
        .uninit => {},
    }
    const lib = win32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("winhttp.dll")) orelse {
        api_state = .missing;
        return null;
    };
    const p = struct {
        fn get(l: win32.HMODULE, comptime name: [:0]const u8) ?*anyopaque {
            return win32.GetProcAddress(l, name);
        }
    };
    const a = Api{
        .Open = @ptrCast(p.get(lib, "WinHttpOpen") orelse {
            api_state = .missing;
            return null;
        }),
        .Connect = @ptrCast(p.get(lib, "WinHttpConnect") orelse {
            api_state = .missing;
            return null;
        }),
        .OpenRequest = @ptrCast(p.get(lib, "WinHttpOpenRequest") orelse {
            api_state = .missing;
            return null;
        }),
        .SetOption = @ptrCast(p.get(lib, "WinHttpSetOption") orelse {
            api_state = .missing;
            return null;
        }),
        .SendRequest = @ptrCast(p.get(lib, "WinHttpSendRequest") orelse {
            api_state = .missing;
            return null;
        }),
        .ReceiveResponse = @ptrCast(p.get(lib, "WinHttpReceiveResponse") orelse {
            api_state = .missing;
            return null;
        }),
        .QueryHeaders = @ptrCast(p.get(lib, "WinHttpQueryHeaders") orelse {
            api_state = .missing;
            return null;
        }),
        .ReadData = @ptrCast(p.get(lib, "WinHttpReadData") orelse {
            api_state = .missing;
            return null;
        }),
        .CloseHandle = @ptrCast(p.get(lib, "WinHttpCloseHandle") orelse {
            api_state = .missing;
            return null;
        }),
        .QueryOption = @ptrCast(p.get(lib, "WinHttpQueryOption") orelse {
            api_state = .missing;
            return null;
        }),
        .SetTimeouts = @ptrCast(p.get(lib, "WinHttpSetTimeouts") orelse {
            api_state = .missing;
            return null;
        }),
        .WebSocketCompleteUpgrade = @ptrCast(p.get(lib, "WinHttpWebSocketCompleteUpgrade") orelse {
            api_state = .missing;
            return null;
        }),
        .WebSocketSend = @ptrCast(p.get(lib, "WinHttpWebSocketSend") orelse {
            api_state = .missing;
            return null;
        }),
        .WebSocketReceive = @ptrCast(p.get(lib, "WinHttpWebSocketReceive") orelse {
            api_state = .missing;
            return null;
        }),
        .WebSocketClose = @ptrCast(p.get(lib, "WinHttpWebSocketClose") orelse {
            api_state = .missing;
            return null;
        }),
        .WebSocketQueryCloseStatus = @ptrCast(p.get(lib, "WinHttpWebSocketQueryCloseStatus") orelse {
            api_state = .missing;
            return null;
        }),
        .WriteData = @ptrCast(p.get(lib, "WinHttpWriteData") orelse {
            api_state = .missing;
            return null;
        }),
    };
    api_state = .{ .ready = a };
    return &api_state.ready;
}

// ---- HTTP ----

pub const RequestOptions = struct {
    method: []const u8 = "GET",
    /// 原始头（"A: 1\nB: 2"），内部规范化
    headers: []const u8 = "",
    body: []const u8 = "",
    timeout_ms: u32 = 30_000,
    /// 显式代理（"http://127.0.0.1:7890" / "127.0.0.1:7890"）；null = 系统代理
    proxy: ?[]const u8 = null,
    insecure_tls: bool = false,
    follow_redirects: bool = true,
};

pub const Sink = struct {
    ctx: *anyopaque,
    /// 返回 false 表示中止读取（流式下载；与 on_upload 互斥使用）
    on_chunk: ?*const fn (ctx: *anyopaque, data: []const u8) bool = null,
    /// v0.3.8 E6：上传进度（body 按块 WriteData 时回调；返回 false 表示中止）。
    /// null = 不上报进度（body 整块随 SendRequest 发送）
    on_upload: ?*const fn (ctx: *anyopaque, written: usize, total: usize) bool = null,
};

const Watchdog = struct {
    handle: HINTERNET,
    ms: u32,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn watchdogMain(w: *Watchdog) void {
    var waited: u32 = 0;
    while (waited < w.ms) : (waited += 20) {
        if (w.done.load(.acquire)) return;
        win32.Sleep(20);
    }
    if (w.done.load(.acquire)) return;
    w.fired.store(true, .release);
    if (api()) |a| _ = a.CloseHandle(w.handle);
}

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
    }
};

/// 同步请求。sink != null 时边读边回调（body 只保留空串）。
pub fn request(alloc: std.mem.Allocator, url: net.Url, opts: RequestOptions, sink: ?Sink) !Response {
    const a = api() orelse return error.WinHttpUnavailable;

    const agent = std.unicode.utf8ToUtf16LeStringLiteral("Zilt/0.1");
    const proxy_w: ?[*:0]const u16 = if (opts.proxy) |p| blk: {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, p);
        break :blk w.ptr;
    } else null;
    defer if (opts.proxy) |_| alloc.free(std.mem.span(proxy_w.?));

    const session = a.Open(agent, accessTypeFor(url.host, opts.proxy != null), proxy_w, null, 0) orelse return error.WinHttpOpenFailed;
    defer _ = a.CloseHandle(session);

    const t: i32 = @intCast(@min(opts.timeout_ms, 600_000));
    _ = a.SetTimeouts(session, t, t, t, t);

    const host_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, stripBrackets(url.host));
    defer alloc.free(host_w);
    const connect = a.Connect(session, host_w.ptr, url.port, 0) orelse return error.WinHttpConnectFailed;
    defer _ = a.CloseHandle(connect);

    const verb_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, opts.method);
    defer alloc.free(verb_w);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, url.path);
    defer alloc.free(path_w);

    const req = a.OpenRequest(
        connect,
        verb_w.ptr,
        path_w.ptr,
        null,
        null,
        null,
        if (url.secure) WINHTTP_FLAG_SECURE else 0,
    ) orelse return error.WinHttpRequestFailed;
    var handle_owned = true;
    defer if (handle_owned) {
        _ = a.CloseHandle(req);
    };

    _ = a.SetTimeouts(req, t, t, t, t);
    var tv: u32 = @intCast(t);
    _ = a.SetOption(req, WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT, @ptrCast(&tv), @sizeOf(u32));

    if (!opts.follow_redirects) {
        var v: u32 = WINHTTP_DISABLE_REDIRECTS;
        _ = a.SetOption(req, WINHTTP_OPTION_DISABLE_FEATURE, @ptrCast(&v), @sizeOf(u32));
    }
    if (opts.insecure_tls) {
        const flags: u32 = SECURITY_FLAG_IGNORE_UNKNOWN_CA | SECURITY_FLAG_IGNORE_CERT_CN_INVALID | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID;
        _ = a.SetOption(req, WINHTTP_OPTION_SECURITY_FLAGS, @ptrCast(&flags), @sizeOf(u32));
    }

    const hdrs = try net.normalizeHeaders(alloc, opts.headers);
    defer alloc.free(hdrs);
    const hdrs_w: ?[*:0]const u16 = if (hdrs.len == 0) null else blk: {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, hdrs);
        break :blk w.ptr;
    };
    defer if (hdrs_w) |w| alloc.free(std.mem.span(w));

    // dwHeadersLength 的单位是 **WCHAR 数**，不是 UTF-8 字节数。含非 ASCII 头值
    // （如 `X-Note: 测试`）时两者不相等，传字节数会让 WinHTTP 读过缓冲区末尾。
    const hdrs_len: u32 = if (hdrs_w) |w| @intCast(std.mem.span(w).len) else 0;

    // 看门狗必须在 SendRequest **之前**启动：SendRequest 会一直阻塞到收到响应头，
    // 「TCP 已连上但服务器永不响应」的场景卡在这里，原先放在其后等于没有超时。
    var wd = Watchdog{ .handle = req, .ms = if (opts.timeout_ms == 0) 600_000 else opts.timeout_ms };
    const wd_thread: ?std.Thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, watchdogMain, .{&wd}) catch null;
    defer if (wd_thread) |th| {
        wd.done.store(true, .release);
        th.join();
        if (wd.fired.load(.acquire)) handle_owned = false;
    };

    const body_ptr: ?*const anyopaque = if (opts.body.len == 0) null else opts.body.ptr;
    // v0.3.8 E6：带上传进度时 SendRequest 只发头（dwTotalLength 声明 Content-Length），
    // body 经 WinHttpWriteData 分块写出并逐块回调
    const upload_cb: ?*const fn (*anyopaque, usize, usize) bool = if (sink) |s| s.on_upload else null;
    if (upload_cb != null and opts.body.len > 0) blk: {
        if (a.SendRequest(req, hdrs_w, hdrs_len, null, 0, @intCast(opts.body.len), 0) == 0) {
            if (wd.fired.load(.acquire)) return error.Timeout;
            return errFor(win32.GetLastError());
        }
        var off: usize = 0;
        while (off < opts.body.len) {
            const chunk_len: u32 = @intCast(@min(@as(usize, 64 * 1024), opts.body.len - off));
            var written: u32 = 0;
            if (a.WriteData(req, opts.body[off..].ptr, chunk_len, &written) == 0) {
                if (wd.fired.load(.acquire)) return error.Timeout;
                return errFor(win32.GetLastError());
            }
            if (written == 0) return error.WriteFailed;
            off += written;
            if (!upload_cb.?(sink.?.ctx, off, opts.body.len)) return error.Aborted;
        }
        break :blk;
    } else if (a.SendRequest(req, hdrs_w, hdrs_len, body_ptr, @intCast(opts.body.len), @intCast(opts.body.len), 0) == 0) {
        if (wd.fired.load(.acquire)) return error.Timeout;
        return errFor(win32.GetLastError());
    }

    if (a.ReceiveResponse(req, null) == 0) {
        if (wd.fired.load(.acquire)) return error.Timeout;
        return errFor(win32.GetLastError());
    }

    // 状态码
    var status: u32 = 0;
    var len: u32 = @sizeOf(u32);
    _ = a.QueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, null, @ptrCast(&status), &len, null);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    // 流式模式 = sink 带 on_chunk（v0.3.8：上传进度 sink 只有 on_upload——响应体
    // 必须正常累积，不能因为 sink 非 null 就当流式丢弃）
    const streaming = if (sink) |s| s.on_chunk != null else false;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        var read: u32 = 0;
        if (a.ReadData(req, &buf, buf.len, &read) == 0) {
            if (wd.fired.load(.acquire)) return error.Timeout;
            return errFor(win32.GetLastError());
        }
        if (read == 0) break;
        if (streaming) {
            if (!sink.?.on_chunk.?(sink.?.ctx, buf[0..read])) return error.Aborted;
        } else {
            try out.appendSlice(alloc, buf[0..read]);
        }
    }
    return .{ .status = @intCast(status & 0xFFFF), .body = try out.toOwnedSlice(alloc) };
}

/// 本机地址：系统代理（如 Clash）默认会把 127.0.0.1 也代理走 → 连不上。
/// 显式代理优先；否则 loopback 直接 NO_PROXY，其余跟随系统代理。
fn accessTypeFor(host: []const u8, has_explicit_proxy: bool) u32 {
    if (has_explicit_proxy) return WINHTTP_ACCESS_TYPE_NAMED_PROXY;
    const h = stripBrackets(host);
    if (std.mem.eql(u8, h, "127.0.0.1") or std.mem.eql(u8, h, "::1") or
        std.ascii.eqlIgnoreCase(h, "localhost")) return WINHTTP_ACCESS_TYPE_NO_PROXY;
    return WINHTTP_ACCESS_TYPE_DEFAULT_PROXY;
}

fn stripBrackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return host;
}

// ---- WebSocket ----

pub const WebSocket = struct {
    ws: HINTERNET,
    session: HINTERNET,
    connect: HINTERNET,
    alloc: std.mem.Allocator,

    pub fn sendText(self: *WebSocket, text: []const u8) !void {
        const a = api() orelse return error.WinHttpUnavailable;
        const rc = a.WebSocketSend(self.ws, .utf8_message, text.ptr, @intCast(text.len));
        if (rc != 0) return errFor(rc);
    }

    pub fn sendBinary(self: *WebSocket, data: []const u8) !void {
        const a = api() orelse return error.WinHttpUnavailable;
        const rc = a.WebSocketSend(self.ws, .binary_message, data.ptr, @intCast(data.len));
        if (rc != 0) return errFor(rc);
    }

    pub const Recv = struct { n: usize, kind: WebSocketBuffer, code: u16 = 0 };

    pub fn receive(self: *WebSocket, buf: []u8) !Recv {
        const a = api() orelse return error.WinHttpUnavailable;
        var read: u32 = 0;
        var kind: WebSocketBuffer = .utf8_message;
        const rc = a.WebSocketReceive(self.ws, buf.ptr, @intCast(buf.len), &read, &kind);
        if (rc != 0) {
            // 对端关闭 / 连接中断：尽力取关闭码，统一按 close 事件上报
            var status: u16 = 1006;
            var reason: [123]u8 = undefined;
            var consumed: u32 = 0;
            if (a.WebSocketQueryCloseStatus(self.ws, &status, &reason, reason.len, &consumed) != 0) status = 1006;
            if (status < 1000) status = 1006;
            return .{ .n = 0, .kind = .close, .code = status };
        }
        if (kind == .close) {
            var status: u16 = 1000;
            var reason: [123]u8 = undefined;
            var consumed: u32 = 0;
            if (a.WebSocketQueryCloseStatus(self.ws, &status, &reason, reason.len, &consumed) != 0) status = 1006;
            return .{ .n = 0, .kind = .close, .code = status };
        }
        return .{ .n = read, .kind = kind };
    }

    pub fn close(self: *WebSocket, code: u16, reason: []const u8) void {
        const a = api() orelse return;
        _ = a.WebSocketClose(self.ws, code, reason.ptr, @intCast(reason.len));
    }

    pub fn deinit(self: *WebSocket) void {
        const a = api() orelse return;
        if (self.ws != null) _ = a.CloseHandle(self.ws);
        if (self.connect != null) _ = a.CloseHandle(self.connect);
        if (self.session != null) _ = a.CloseHandle(self.session);
        self.alloc.destroy(self);
    }
};

pub const WebSocketOptions = struct {
    proxy: ?[]const u8 = null,
    insecure_tls: bool = false,
    timeout_ms: u32 = 30_000,
    headers: []const u8 = "",
};

/// 建立 ws/wss 连接（同步；调用方放到后台线程）。
pub fn openWebSocket(alloc: std.mem.Allocator, url: net.Url, opts: WebSocketOptions) !*WebSocket {
    const a = api() orelse return error.WinHttpUnavailable;

    const agent = std.unicode.utf8ToUtf16LeStringLiteral("Zilt/0.1");
    const proxy_w: ?[*:0]const u16 = if (opts.proxy) |p| blk: {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, p);
        break :blk w.ptr;
    } else null;
    defer if (opts.proxy) |_| alloc.free(std.mem.span(proxy_w.?));

    const session = a.Open(agent, accessTypeFor(url.host, opts.proxy != null), proxy_w, null, 0) orelse return error.WinHttpOpenFailed;
    errdefer _ = a.CloseHandle(session);

    const t: i32 = @intCast(@min(opts.timeout_ms, 600_000));
    _ = a.SetTimeouts(session, t, t, t, t);

    const host_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, stripBrackets(url.host));
    defer alloc.free(host_w);
    const connect = a.Connect(session, host_w.ptr, url.port, 0) orelse return error.WinHttpConnectFailed;
    errdefer _ = a.CloseHandle(connect);

    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, url.path);
    defer alloc.free(path_w);
    const verb_w = std.unicode.utf8ToUtf16LeStringLiteral("GET");
    const req = a.OpenRequest(connect, verb_w, path_w.ptr, null, null, null, if (url.secure) WINHTTP_FLAG_SECURE else 0) orelse return error.WinHttpRequestFailed;
    var handle_owned = true;
    defer if (handle_owned) {
        _ = a.CloseHandle(req);
    };

    var yes: win32.BOOL = 1;
    var up = a.SetOption(req, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, @ptrCast(&yes), @sizeOf(win32.BOOL));
    if (up == 0) {
        // 实测：本机 WinHTTP 要求 NULL/0（等价于 TRUE），传 &BOOL 会 ERROR_INVALID_PARAMETER
        up = a.SetOption(req, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, null, 0);
    }
    if (up == 0) return error.WinHttpUpgradeFailed;
    if (opts.insecure_tls) {
        const flags: u32 = SECURITY_FLAG_IGNORE_UNKNOWN_CA | SECURITY_FLAG_IGNORE_CERT_CN_INVALID | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID;
        _ = a.SetOption(req, WINHTTP_OPTION_SECURITY_FLAGS, @ptrCast(&flags), @sizeOf(u32));
    }

    const hdrs = try net.normalizeHeaders(alloc, opts.headers);
    defer alloc.free(hdrs);
    const hdrs_w: ?[*:0]const u16 = if (hdrs.len == 0) null else blk: {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, hdrs);
        break :blk w.ptr;
    };
    defer if (hdrs_w) |w| alloc.free(std.mem.span(w));
    // 同 request()：dwHeadersLength 以 WCHAR 计，不是 UTF-8 字节数。
    const hdrs_len: u32 = if (hdrs_w) |w| @intCast(std.mem.span(w).len) else 0;

    // 看门狗先于 SendRequest 启动（服务器不返回响应头时也能超时）
    var wd = Watchdog{ .handle = req, .ms = if (opts.timeout_ms == 0) 600_000 else opts.timeout_ms };
    const wd_thread: ?std.Thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, watchdogMain, .{&wd}) catch null;
    defer if (wd_thread) |th| {
        wd.done.store(true, .release);
        th.join();
        if (wd.fired.load(.acquire)) handle_owned = false;
    };

    if (a.SendRequest(req, hdrs_w, hdrs_len, null, 0, 0, 0) == 0) {
        if (wd.fired.load(.acquire)) return error.Timeout;
        return errFor(win32.GetLastError());
    }

    if (a.ReceiveResponse(req, null) == 0) {
        if (wd.fired.load(.acquire)) return error.Timeout;
        return errFor(win32.GetLastError());
    }

    const ws = a.WebSocketCompleteUpgrade(req, null) orelse {
        std.debug.print("[wh] CompleteUpgrade failed err={d}\n", .{win32.GetLastError()});
        return error.WinHttpUpgradeFailed;
    };
    errdefer _ = a.CloseHandle(ws);

    const self = try alloc.create(WebSocket);
    self.* = .{ .ws = ws, .session = session, .connect = connect, .alloc = alloc };
    return self;
}

const testing = std.testing;

test "v0.1.20: error mapping is stable" {
    try testing.expectEqualStrings("Timeout", errorNameFor(12002));
    try testing.expectEqualStrings("NameNotResolved", errorNameFor(12007));
    try testing.expectEqualStrings("CannotConnect", errorNameFor(12029));
    try testing.expectEqualStrings("SecureFailure", errorNameFor(12175));
    try testing.expectEqualStrings("WinHttpError", errorNameFor(99999));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(WebSocketBuffer.close));
    _ = testing;
}

// ---------------------------------------------------------------------------
// v0.4.1 H21：等响应头看门狗语义（实现于 v0.3.15——SendRequest 前启动；
// 本组测试锁定 done/fired 原子语义：done 置位 → 线程退出且不点火）。
// ---------------------------------------------------------------------------
test "watchdog: done 置位 → 退出且不点火（CloseHandle 不触达）" {
    var w = Watchdog{ .handle = @ptrFromInt(0xDEADBEEF), .ms = 60 };
    const t = try std.Thread.spawn(.{}, watchdogMain, .{&w});
    w.done.store(true, .release);
    t.join();
    try testing.expect(!w.fired.load(.acquire));
}

test "watchdog: done 在轮询窗口内置位 → 不点火（本机真实时序）" {
    var w = Watchdog{ .handle = @ptrFromInt(0xDEADBEEF), .ms = 5000 };
    const t = try std.Thread.spawn(.{}, watchdogMain, .{&w});
    win32.Sleep(60); // 让看门狗进入轮询循环
    w.done.store(true, .release);
    t.join();
    try testing.expect(!w.fired.load(.acquire));
}
