//! v0.1.17：Server / headless 模式（对齐 Wails v3 server build）。
//!
//! `ZILT_HEADLESS=1` 时跳过窗口与 WebView：应用作为 HTTP 服务运行——
//!   GET  /zilt/health → "ok"
//!   GET  /zilt/info   → 应用元数据 JSON
//!   POST /zilt/ipc    → body {"method":"<command>","args":{...}}，走与前端
//!                       invoke 相同的 dispatch 链路，返回结果 JSON
//!   GET  /*           → 资产服务（asset_routes 候选 + gzip 惰性解压）
//!
//! 端口：ZILT_HEADLESS_PORT（默认 8790）；仅绑定 127.0.0.1。
//! 事件：headless 下 emit 打到日志（无前端可收）。
//!
//! v0.2.8：跨平台（Linux 接线）——全 std.Io 实现，仅两处平台点：
//! env 读取（Win32 / std.c.getenv）与 SQL 后端（winsqlite3.dll / libsqlite3 dlopen），
//! 都经 comptime 按 os.tag 分派；两平台的 sqlite run/migrate 签名逐字同构。

const std = @import("std");
const builtin = @import("builtin");
const zilt = @import("../../root.zig");
const asset_routes = @import("../../asset_routes.zig");
const services_mod = @import("../../services.zig");
const server_session = @import("../../server_session.zig");
const ws_mod = @import("../../ws.zig");

const log = zilt.log;
const ipc = zilt.ipc;
const mcp = zilt.mcp;
const builtin_commands = zilt.builtin_commands;
const shared_system = zilt.system_api;
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else {};
const sqlite_backend = if (builtin.os.tag == .windows)
    @import("sqlite.zig")
else
    @import("../linux/sqlite.zig");

/// 可移植 env 读取（返回堆拷贝）。
fn envUtf8(alloc: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
    if (builtin.os.tag == .windows) {
        return win32.getEnvUtf8(alloc, name);
    }
    const raw = std.c.getenv(name.ptr) orelse return null;
    return alloc.dupe(u8, std.mem.span(raw)) catch null;
}

/// headless 的系统能力：SQL 直接本地执行（无窗口可依赖）；其余一律 Unsupported。
/// 前端在 GUI 模式拿到的系统 API 面不变，headless 只是最小可用子集。
fn headlessSystem(backend: *anyopaque, window_id: u32, alloc: std.mem.Allocator, req: shared_system.Request) anyerror!shared_system.Result {
    _ = backend;
    _ = window_id;
    return switch (req) {
        .sql => |op| {
            if (op == .migrate) {
                const m = op.migrate;
                sqlite_backend.migrate(alloc, m.db, m.statements, m.version) catch |e| {
                    log.print("[headless:sql] migrate failed: {s}", .{@errorName(e)});
                    return e;
                };
                return .{ .ok = true };
            }
            const q = switch (op) {
                .query => |x| x,
                .execute => |x| x,
                .migrate => unreachable,
            };
            const want_rows = switch (op) {
                .query => true,
                .execute, .migrate => false,
            };
            const out = sqlite_backend.run(alloc, q.db, q.sql, q.params, want_rows) catch |e| {
                log.print("[headless:sql] failed: {s} (db={s})", .{ @errorName(e), q.db });
                return e;
            };
            return .{ .json = out };
        },
        else => error.UnsupportedInHeadless,
    };
}

const DEFAULT_PORT: u16 = 8790;
const MAX_HEADER: usize = 16 * 1024;
const MAX_BODY: usize = 4 * 1024 * 1024;

/// headless 下的事件落点：打日志（事件广播无前端）。
fn headlessEmit(backend: *anyopaque, window_id: u32, message_json: []const u8) void {
    _ = backend;
    log.print("[headless:emit] win={d} {s}", .{ window_id, message_json });
}

fn headlessQuit(backend: *anyopaque, code: u8) void {
    _ = backend;
    log.print("[headless] quit({d}) requested via command", .{code});
    std.process.exit(code);
}

pub fn run(comptime config: zilt.Config, alloc: std.mem.Allocator) !void {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 服务注册表：与 GUI 模式同一生命周期（init → startAll → 逆序 deinit）
    var registry = services_mod.Registry.init(alloc);
    defer registry.deinit();
    var service_count: usize = 0;
    for (config.services) |s| {
        registry.register(s) catch |e| {
            log.print("[headless] service '{s}' register failed: {s}", .{ s.name, @errorName(e) });
            continue;
        };
        service_count += 1;
    }
    registry.startAll() catch |e| {
        log.print("[headless] startAll failed: {s}", .{@errorName(e)});
    };
    log.print("[headless] {d} service(s) started", .{service_count});

    const mcp_opts = buildMcpOptions(config, alloc);

    // v0.3.1：MCP stdio 传输（`zilt mcp` 直连 / Claude Desktop 本地进程）
    if (mcpStdioEnabled(alloc)) {
        log.print("[headless] MCP stdio mode (no HTTP listener)", .{});
        return runMcpStdio(config, alloc, io, mcp_opts);
    }

    const port: u16 = if (envUtf8(alloc, "ZILT_HEADLESS_PORT")) |p| blk: {
        defer alloc.free(p);
        break :blk std.fmt.parseInt(u16, p, 10) catch DEFAULT_PORT;
    } else DEFAULT_PORT;

    const addr = std.Io.net.IpAddress.resolve(io, "127.0.0.1", port) catch |e| {
        log.print("[headless] resolve failed: {s}", .{@errorName(e)});
        return error.HeadlessListenFailed;
    };
    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        log.print("[headless] listen failed: {s}", .{@errorName(e)});
        return error.HeadlessListenFailed;
    };
    defer server.deinit(io);
    log.print("[headless] serving http://127.0.0.1:{d}/ (app={s})", .{ port, config.app_id });

    log.print("[headless] ready — Ctrl+C 终止（或父进程 Job 清理）", .{});
    while (true) {
        var stream = server.accept(io) catch |e| {
            log.print("[headless] accept failed: {s}", .{@errorName(e)});
            continue;
        };
        // v0.3.7：每连接一线程——WS 会话的阻塞帧读循环不能阻塞 accept 与
        // 其他连接（HTTP 短连接与长会话并存）。
        const conn = try alloc.create(ConnJob);
        conn.* = .{ .io = io, .stream = stream, .mcp_opts = mcp_opts };
        const t = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, connThread, .{ config, alloc, conn }) catch {
            alloc.destroy(conn);
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

/// 连接线程参数（stream 所有权移入线程；线程结束时关闭）。
/// config 是 comptime-only——经 spawn 的参数剥离传给泛型 connThread。
const ConnJob = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    mcp_opts: mcp.Options,
};

fn connThread(comptime config: zilt.Config, alloc: std.mem.Allocator, job: *ConnJob) void {
    defer {
        job.stream.close(job.io);
        alloc.destroy(job);
    }
    var stream = job.stream;
    handleConnection(config, alloc, job.io, &stream, job.mcp_opts) catch |e| {
        log.print("[headless] connection error: {s}", .{@errorName(e)});
    };
}

/// MCP 运行选项：`ZILT_MCP_TOOLS=greet,add` 白名单（逗号分隔）。
/// 切片指向 env 原始字符串——headless 进程生命周期内不释放。
fn buildMcpOptions(comptime config: zilt.Config, alloc: std.mem.Allocator) mcp.Options {
    var opts = mcp.Options{ .app_id = config.app_id };
    if (envUtf8(alloc, "ZILT_MCP_TOOLS")) |raw| {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const t = std.mem.trim(u8, part, " \t");
            if (t.len == 0) continue;
            list.append(alloc, t) catch continue;
        }
        opts.tools_allowlist = list.toOwnedSlice(alloc) catch null;
    }
    return opts;
}

fn mcpStdioEnabled(alloc: std.mem.Allocator) bool {
    const raw = envUtf8(alloc, "ZILT_MCP_STDIO") orelse return false;
    defer alloc.free(raw);
    return std.mem.eql(u8, raw, "1");
}

/// MCP stdio：一行一条 JSON-RPC（MCP 标准传输）。
/// stdout 只写响应；日志走 stderr / zilt.log，保证客户端读到干净流。
fn runMcpStdio(
    comptime config: zilt.Config,
    alloc: std.mem.Allocator,
    io: std.Io,
    opts: mcp.Options,
) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var wbuf: [64 * 1024]u8 = undefined;
    var rd = std.Io.File.stdin().reader(io, &rbuf);
    var wr = std.Io.File.stdout().writer(io, &wbuf);

    var dummy: u8 = 0;
    const ctx = ipc.Context{
        .allocator = alloc,
        .msg_allocator = alloc,
        .backend = @ptrCast(&dummy),
        .window_id = 0,
        .emit_fn = headlessEmit,
        .quit_fn = headlessQuit,
        .system_fn = headlessSystem,
    };

    while (true) {
        const line = rd.interface.takeDelimiter('\n') catch |e| {
            log.print("[mcp:stdio] read failed: {s}", .{@errorName(e)});
            return;
        } orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const resp = mcp.handle(alloc, trimmed, ctx, config.commands, opts) catch |e| {
            log.print("[mcp:stdio] {s}", .{@errorName(e)});
            continue;
        } orelse continue; // 通知不回包
        defer alloc.free(resp);
        wr.interface.writeAll(resp) catch return;
        wr.interface.writeAll("\n") catch return;
        wr.interface.flush() catch return;
    }
    log.print("[mcp:stdio] stdin closed -> exit", .{});
}

/// v0.3.7：server 会话主循环——握手 → 帧读循环（invoke → dispatch → 响应帧）
/// + 每帧间 drain 事件队列（帧回写）。会话持有独立 server 窗口 id。
fn runServerSession(
    comptime config: zilt.Config,
    alloc: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    client_key: []const u8,
) !void {
    // 握手响应（缓冲 writer 与 handleConnection 同款）
    var wbuf: [16 * 1024]u8 = undefined;
    var wr = stream.writer(io, &wbuf);
    const out = &wr.interface;
    const resp = try server_session.upgradeResponse(alloc, client_key);
    out.writeAll(resp) catch return error.HandshakeFailed;
    out.flush() catch return error.HandshakeFailed;

    // 会话注册（server 窗口 id 空间）
    const session = try alloc.create(server_session.Session);
    session.* = .{ .window_id = server_session.nextWindowId(), .alloc = alloc };
    server_session.register(session);
    defer {
        server_session.unregister(session);
        alloc.destroy(session);
    }
    log.print("[server] session #{x} connected (total={d})", .{ session.window_id, server_session.sessionCount() });

    // 帧读循环：文本帧 = JSON 消息（invoke/event）；ping → pong；close → 退出
    //（dispatch 上下文在 handleIpcJson 内逐条构造，backend = Session）
    while (true) {
        // 先 drain 待发事件（非阻塞；队列空即跳过）
        const drained = session.drain(alloc);
        defer {
            for (drained) |item| alloc.free(item);
            alloc.free(drained);
        }
        for (drained) |item| {
            const frame = ws_mod.encodeFrame(alloc, .text, item, .{ 0, 0, 0, 0 }) catch continue;
            defer alloc.free(frame);
            out.writeAll(frame) catch return error.SessionWriteFailed;
            out.flush() catch return error.SessionWriteFailed;
        }

        // 读一帧（阻塞 read；逐字节进入累积缓冲直至完整帧）
        const frame = readWsFrame(alloc, io, stream) catch |err| {
            if (err != error.EndOfStream) log.print("[server] session #{x} read failed: {s}", .{ session.window_id, @errorName(err) });
            return;
        };
        defer alloc.free(frame.payload);
        switch (frame.op) {
            .close => {
                log.print("[server] session #{x} closed", .{session.window_id});
                return;
            },
            .ping => {
                const pong = ws_mod.encodeFrame(alloc, .pong, frame.payload, .{ 0, 0, 0, 0 }) catch continue;
                defer alloc.free(pong);
                out.writeAll(pong) catch return error.SessionWriteFailed;
                out.flush() catch return error.SessionWriteFailed;
                continue;
            },
            .text => {},
            else => continue, // 二进制帧等暂不处理
        }

        // JSON 消息 → dispatch（与 POST /zilt/ipc 同链路）
        const response = handleIpcJson(alloc, config, session, frame.payload) catch |err| {
            log.print("[server] session #{x} dispatch failed: {s}", .{ session.window_id, @errorName(err) });
            continue;
        };
        const frame_out = ws_mod.encodeFrame(alloc, .text, response, .{ 0, 0, 0, 0 }) catch continue;
        defer alloc.free(frame_out);
        out.writeAll(frame_out) catch return error.SessionWriteFailed;
        out.flush() catch return error.SessionWriteFailed;
    }
}

/// 单条 JSON 消息 dispatch（与 POST /zilt/ipc 同链路：builtin 优先 + 应用命令）。
/// 会话上下文 backend = Session（sessionEmit 把事件路由回本会话）。
fn handleIpcJson(
    alloc: std.mem.Allocator,
    comptime config: zilt.Config,
    session: *server_session.Session,
    payload_json: []const u8,
) ![]u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, payload_json, .{}) catch return error.BadPayload;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.BadPayload,
    };
    const kind = switch (obj.get("kind") orelse return error.BadPayload) {
        .string => |str| str,
        else => return error.BadPayload,
    };
    if (!std.mem.eql(u8, kind, "invoke")) return try alloc.dupe(u8, "{}"); // 上行 event 暂不处理
    const id: i64 = switch (obj.get("id") orelse return error.BadPayload) {
        .integer => |v| v,
        else => 0,
    };
    const method = switch (obj.get("method") orelse return error.BadPayload) {
        .string => |str| str,
        else => return error.BadPayload,
    };
    const args_json = if (obj.get("args")) |args_v| switch (args_v) {
        .object, .array => try std.json.Stringify.valueAlloc(alloc, args_v, .{}),
        else => try alloc.dupe(u8, "{}"),
    } else try alloc.dupe(u8, "{}");

    const ctx = zilt.ipc.Context{
        .allocator = alloc,
        .msg_allocator = alloc,
        .backend = @ptrCast(session),
        .window_id = session.window_id,
        .emit_fn = sessionEmit,
        .quit_fn = headlessQuit,
        .system_fn = headlessSystem,
    };

    if (zilt.builtin_commands.isBuiltin(method)) {
        const builtin_result = zilt.builtin_commands.dispatch(ctx, method, args_json) catch |e| {
            log.print("[server] builtin {s} failed: {s}", .{ method, @errorName(e) });
            return try std.fmt.allocPrint(alloc, "{{\"zilt\":1,\"kind\":\"reject\",\"id\":{d},\"error\":\"{s}\"}}", .{ id, @errorName(e) });
        };
        if (builtin_result) |res| {
            defer alloc.free(res);
            return try std.fmt.allocPrint(alloc, "{{\"zilt\":1,\"kind\":\"resolve\",\"id\":{d},\"result\":{s}}}", .{ id, res });
        }
    }
    const result = zilt.ipc.dispatch(config.commands, ctx, method, args_json) catch |e| {
        log.print("[server] {s} failed: {s}", .{ method, @errorName(e) });
        return try std.fmt.allocPrint(alloc, "{{\"zilt\":1,\"kind\":\"reject\",\"id\":{d},\"error\":\"{s}\"}}", .{ id, @errorName(e) });
    };
    defer alloc.free(result);
    return try std.fmt.allocPrint(alloc, "{{\"zilt\":1,\"kind\":\"resolve\",\"id\":{d},\"result\":{s}}}", .{ id, result });
}

/// 会话 emit：事件 JSON → server_session.routeEvent（本会话命中 → 回帧；否则广播）。
fn sessionEmit(backend: *anyopaque, window_id: u32, message_json: []const u8) void {
    const session: *server_session.Session = @ptrCast(@alignCast(backend));
    _ = window_id;
    server_session.routeEvent(session.window_id, message_json);
}

/// v0.3.7：读一个完整 WS 帧（客户端帧带 mask；RFC6455 长度三态 + mask 解包）。
/// 返回 {op, payload}（payload 归调用方 free）。
fn readWsFrame(
    alloc: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
) !struct { op: ws_mod.Opcode, payload: []u8 } {
    var hdr: [2]u8 = undefined;
    try readExact(io, stream, &hdr);
    const b0 = hdr[0];
    const b1 = hdr[1];
    const fin = b0 & 0x80 != 0;
    const op_int: u4 = @intCast(b0 & 0x0f);
    const op = ws_mod.Opcode.fromInt(op_int) orelse return error.BadOpcode;
    const masked = b1 & 0x80 != 0;
    var len: u64 = b1 & 0x7f;
    if (len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(io, stream, &ext);
        len = std.mem.readInt(u16, &ext, .big);
    } else if (len == 127) {
        var ext: [8]u8 = undefined;
        try readExact(io, stream, &ext);
        len = std.mem.readInt(u64, &ext, .big);
    }
    if (len > 32 * 1024 * 1024) return error.FrameTooLarge;
    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) try readExact(io, stream, &mask_key);
    const payload = try alloc.alloc(u8, @intCast(len));
    errdefer alloc.free(payload);
    try readExact(io, stream, payload);
    if (masked) {
        for (payload, 0..) |*b, i| b.* ^= mask_key[i % 4];
    }
    // 分片（FIN=0 续帧）：累积到 FIN（binary/text 起始帧；控制帧不应分片）
    _ = fin;
    return .{ .op = op, .payload = payload };
}

fn readExact(io: std.Io, stream: *std.Io.net.Stream, buf: []u8) !void {
    var at: usize = 0;
    while (at < buf.len) {
        var vec = [_][]u8{buf[at..]};
        const n = stream.read(io, &vec) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        at += n;
    }
}

fn handleConnection(
    comptime config: zilt.Config,
    alloc: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    mcp_opts: mcp.Options,
) !void {
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var rd = stream.reader(io, &rbuf);
    var wr = stream.writer(io, &wbuf);
    const out = &wr.interface;

    // 读请求头（到 \r\n\r\n；takeByte 阻塞但至少 1 字节即返回）
    var head: [MAX_HEADER]u8 = undefined;
    var head_len: usize = 0;
    while (head_len < head.len) {
        const b = rd.interface.takeByte() catch return error.HeadIncomplete;
        head[head_len] = b;
        head_len += 1;
        if (head_len >= 4 and std.mem.eql(u8, head[head_len - 4 .. head_len], "\r\n\r\n")) break;
    }
    const head_text = head[0..head_len];
    const line_end = std.mem.indexOf(u8, head_text, "\r\n") orelse return error.BadRequest;
    const request_line = head_text[0..line_end];
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;

    // v0.3.7：WS upgrade（/zilt/ws）→ server 会话（浏览器客户端作为窗口）
    if (std.mem.indexOf(u8, head_text, "/zilt/ws") != null) {
        if (server_session.isWsUpgrade(head_text)) |client_key| {
            return runServerSession(config, alloc, io, stream, client_key);
        }
    }

    // Content-Length
    var content_length: usize = 0;
    var lines = std.mem.splitSequence(u8, head_text[line_end + 2 ..], "\r\n");
    while (lines.next()) |ln| {
        const colon = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, ln[0..colon], " "), "content-length")) {
            content_length = std.fmt.parseInt(usize, std.mem.trim(u8, ln[colon + 1 ..], " "), 10) catch 0;
        }
    }
    if (content_length > MAX_BODY) {
        try respond(out, 413, "text/plain", "payload too large");
        return;
    }
    const body = if (content_length > 0) blk: {
        const buf = try alloc.alloc(u8, content_length);
        const n = rd.interface.readSliceShort(buf) catch 0;
        break :blk try alloc.realloc(buf, n);
    } else try alloc.alloc(u8, 0);
    defer alloc.free(body);

    const path_only = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

    if (std.mem.eql(u8, path_only, "/zilt/health")) {
        try respond(out, 200, "text/plain", "ok");
        return;
    }
    if (std.mem.eql(u8, path_only, "/zilt/info")) {
        const info = try std.fmt.allocPrint(alloc, "{{\"app_id\":\"{s}\",\"mode\":\"headless\"}}", .{config.app_id});
        defer alloc.free(info);
        try respond(out, 200, "application/json", info);
        return;
    }
    if (std.mem.eql(u8, path_only, "/zilt/ipc") and std.mem.eql(u8, method, "POST")) {
        try handleIpc(config, alloc, out, body);
        return;
    }
    // v0.1.19：MCP（JSON-RPC 2.0，tools = 应用命令）；v0.3.1：resources/prompts + 白名单
    if (std.mem.eql(u8, path_only, "/mcp")) {
        if (std.mem.eql(u8, method, "POST")) {
            try handleMcp(config, alloc, out, body, mcp_opts);
        } else {
            const info = try std.fmt.allocPrint(alloc, "{{\"server\":\"zilt\",\"protocolVersion\":\"{s}\",\"tools\":{d},\"resources\":3,\"prompts\":2}}", .{
                mcp.PROTOCOL_VERSION,
                comptime ipc.commandMetas(config.commands).len,
            });
            defer alloc.free(info);
            try respond(out, 200, "application/json", info);
        }
        return;
    }
    if (std.mem.eql(u8, method, "GET")) {
        try serveAsset(config, alloc, out, path_only);
        return;
    }
    try respond(out, 404, "text/plain", "not found");
}

/// POST /zilt/ipc：与前端 invoke 完全同一分发链路（builtin → commands）。
fn handleIpc(
    comptime config: zilt.Config,
    alloc: std.mem.Allocator,
    out: anytype,
    body: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        try respond(out, 400, "application/json", "{\"error\":\"invalid JSON\"}");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try respond(out, 400, "application/json", "{\"error\":\"body must be an object\"}");
        return;
    }
    const obj = parsed.value.object;
    const method_v = obj.get("method") orelse {
        try respond(out, 400, "application/json", "{\"error\":\"missing method\"}");
        return;
    };
    if (method_v != .string) {
        try respond(out, 400, "application/json", "{\"error\":\"method must be a string\"}");
        return;
    }
    const method = method_v.string;
    const args_json: []const u8 = if (obj.get("args")) |args_v| blk: {
        if (args_v == .null) break :blk "{}";
        break :blk std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(args_v, .{})}) catch "{}";
    } else "{}";

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var dummy: u8 = 0;
    const ctx = ipc.Context{
        .allocator = alloc,
        .msg_allocator = alloc, // 长生命周期：ctx 可能被应用捕获后跨线程 emit（消息由 emit 侧释放）
        .backend = @ptrCast(&dummy),
        .window_id = 0,
        .emit_fn = headlessEmit,
        .quit_fn = headlessQuit,
        .system_fn = headlessSystem,
    };

    // 与 GUI 一致：内建方法（__zilt.*）优先，其次应用命令。
    if (builtin_commands.isBuiltin(method)) {
        const builtin_result = builtin_commands.dispatch(ctx, method, args_json) catch |e| {
            log.print("[headless:ipc] builtin {s} failed: {s}", .{ method, @errorName(e) });
            const msg = std.fmt.allocPrint(alloc, "{{\"error\":\"{s}\"}}", .{@errorName(e)}) catch "{}";
            defer alloc.free(msg);
            try respond(out, 500, "application/json", msg);
            return;
        };
        if (builtin_result) |res| {
            defer alloc.free(res);
            log.print("[headless:ipc] {s} (builtin) -> {d} bytes", .{ method, res.len });
            try respond(out, 200, "application/json", res);
            return;
        }
    }

    const result = ipc.dispatch(config.commands, ctx, method, args_json) catch |e| {
        log.print("[headless:ipc] {s} failed: {s}", .{ method, @errorName(e) });
        const msg = std.fmt.allocPrint(alloc, "{{\"error\":\"{s}\"}}", .{@errorName(e)}) catch "{}";
        defer alloc.free(msg);
        try respond(out, 500, "application/json", msg);
        return;
    };
    log.print("[headless:ipc] {s} -> {d} bytes", .{ method, result.len });
    try respond(out, 200, "application/json", result);
    alloc.free(result);
}

/// POST /mcp：MCP JSON-RPC（initialize / ping / tools / resources / prompts）。
fn handleMcp(
    comptime config: zilt.Config,
    alloc: std.mem.Allocator,
    out: anytype,
    body: []const u8,
    opts: mcp.Options,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var dummy: u8 = 0;
    const ctx = ipc.Context{
        .allocator = alloc,
        .msg_allocator = alloc, // 长生命周期：ctx 可能被应用捕获后跨线程 emit（消息由 emit 侧释放）
        .backend = @ptrCast(&dummy),
        .window_id = 0,
        .emit_fn = headlessEmit,
        .quit_fn = headlessQuit,
        .system_fn = headlessSystem,
    };
    const maybe_resp = mcp.handle(alloc, body, ctx, config.commands, opts) catch |e| {
        log.print("[headless:mcp] {s}", .{@errorName(e)});
        const msg = std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":-32603,\"message\":\"{s}\"}}}}", .{@errorName(e)}) catch "{}";
        defer alloc.free(msg);
        try respond(out, 200, "application/json", msg);
        return;
    };
    const resp = maybe_resp orelse {
        // 通知（无 id）：HTTP 语义用 202 + 空体
        log.print("[headless:mcp] notification accepted", .{});
        try respondWith(out, 202, "application/json", "");
        return;
    };
    defer alloc.free(resp);
    log.print("[headless:mcp] {d} bytes", .{resp.len});
    try respond(out, 200, "application/json", resp);
}

/// GET 资产：asset_routes 候选匹配 + gzip 惰性解压（身份编码输出）。
fn serveAsset(
    comptime config: zilt.Config,
    alloc: std.mem.Allocator,
    out: anytype,
    raw_path: []const u8,
) !void {
    const path = asset_routes.decodePath(alloc, raw_path) catch {
        try respond(out, 400, "text/plain", "bad path");
        return;
    };
    defer alloc.free(path);
    const is_document = std.mem.endsWith(u8, path, "/") or std.mem.indexOfScalar(u8, path, '.') == null;
    var routes = asset_routes.Candidates.init(alloc, path, is_document) catch {
        try respond(out, 500, "text/plain", "route alloc failed");
        return;
    };
    defer routes.deinit();
    for (routes.paths) |candidate| {
        const cp = candidate orelse continue;
        for (config.assets) |asset| {
            if (!std.mem.eql(u8, asset.path, cp)) continue;
            switch (asset.encoding) {
                .identity => {
                    try respondWith(out, 200, contentTypeOf(cp), asset.content);
                    return;
                },
                .gzip => {
                    const raw = flateDecompressGzip(alloc, asset.content) catch continue;
                    defer alloc.free(raw);
                    try respondWith(out, 200, contentTypeOf(cp), raw);
                    return;
                },
            }
        }
    }
    try respond(out, 404, "text/plain", "not found");
}

/// v0.2.0：gzip 解压统一到 inflate.zig。
const flateDecompressGzip = @import("../../inflate.zig").gunzip;

/// v0.2.0：MIME 映射统一到 asset_routes（此前这里是一份较短的重复实现，
/// 缺少 .mjs/.woff2/.ts 且大小写敏感）。
const contentTypeOf = asset_routes.contentTypeOf;

fn respond(out: anytype, status: u16, content_type: []const u8, body: []const u8) !void {
    try respondWith(out, status, content_type, body);
}

fn respondWith(out: anytype, status: u16, content_type: []const u8, body: []const u8) !void {
    const reason: []const u8 = switch (status) {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        404 => "Not Found",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        else => "OK",
    };
    try out.print("HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, content_type, body.len });
    try out.writeAll(body);
    try out.flush();
}
