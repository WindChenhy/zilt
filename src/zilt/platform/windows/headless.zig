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
        handleConnection(config, alloc, io, &stream, mcp_opts) catch |e| {
            log.print("[headless] connection error: {s}", .{@errorName(e)});
        };
        stream.close(io);
    }
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
