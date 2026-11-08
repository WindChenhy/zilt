//! WebSocket 客户端协议（RFC 6455 必需子集，纯逻辑，可离线单测）。
//!
//! Zig 0.17 标准库**没有 WebSocket 客户端**（`std/Io/net.zig` 只有 TCP，
//! `std/http/Server.zig` 里那点 websocket 代码是服务端用的），所以这里手写：
//!   - Upgrade 握手：`Sec-WebSocket-Key` → `Sec-WebSocket-Accept`
//!     = base64(sha1(client_key + GUID))
//!   - 帧编码：客户端帧**必须**加掩码（RFC 6455 §5.3），长度分 7/16/64 位
//!   - 帧解析：服务端帧不该带掩码，但收到带掩码的也容忍（不信任对端实现）
//!
//! 不支持：分片（FIN=0 续帧）、扩展协商（permessage-deflate）。收到分片帧
//! 上层应视为错误并关闭 —— 静默拼装会让错误表现成「消息莫名其妙不完整」。

const std = @import("std");

/// RFC 6455 §1.3 固定魔数
pub const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,

    pub fn isControl(self: Opcode) bool {
        return @intFromEnum(self) >= 0x8;
    }

    pub fn fromInt(v: u4) ?Opcode {
        return switch (v) {
            0x0 => .continuation,
            0x1 => .text,
            0x2 => .binary,
            0x8 => .close,
            0x9 => .ping,
            0xA => .pong,
            else => null,
        };
    }
};

/// close 状态码（常用值）
pub const CloseCode = struct {
    pub const normal: u16 = 1000;
    pub const going_away: u16 = 1001;
    pub const protocol_error: u16 = 1002;
    pub const unsupported_data: u16 = 1003;
};

/// base64(sha1(key ++ GUID))，固定 28 字符（带 "=" 填充）。
pub fn acceptKey(client_key: []const u8) [28]u8 {
    var sha: [20]u8 = undefined;
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(client_key);
    h.update(GUID);
    h.final(&sha);

    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &sha);
    return out;
}

/// 把 16 字节随机量编成握手用的 base64 key（24 字符）。
/// 随机源由调用方提供（IO 层用 `Io.random`），本模块保持纯函数。
pub fn encodeKey(alloc: std.mem.Allocator, seed: [16]u8) ![]u8 {
    const out = try alloc.alloc(u8, 24);
    _ = std.base64.standard.Encoder.encode(out, &seed);
    return out;
}

/// 生成 Upgrade 请求。path 需以 '/' 开头。
pub fn handshakeRequest(
    alloc: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    key: []const u8,
) ![]u8 {
    const host_hdr = if (port == 80 or port == 443)
        try std.fmt.allocPrint(alloc, "{s}", .{host})
    else
        try std.fmt.allocPrint(alloc, "{s}:{d}", .{ host, port });
    defer alloc.free(host_hdr);

    // 必须用显式 CRLF：Zig 多行字符串的行尾是 \n，HTTP 规范要求 \r\n，
    // 严格的服务器会直接拒绝（这里踩过一次，握手请求测试才暴露）。
    return std.fmt.allocPrint(alloc,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
        .{ path, host_hdr, key },
    );
}

/// 校验握手响应：必须是 101，且 Sec-WebSocket-Accept 等于预期值。
pub fn verifyHandshake(response: []const u8, expected_accept: []const u8) !void {
    const status_end = std.mem.indexOf(u8, response, "\r\n") orelse return error.MalformedResponse;
    const status_line = response[0..status_end];
    // 形如 "HTTP/1.1 101 Switching Protocols"
    var it = std.mem.splitScalar(u8, status_line, ' ');
    _ = it.next() orelse return error.MalformedResponse; // HTTP/1.1
    const code = it.next() orelse return error.MalformedResponse;
    if (!std.mem.eql(u8, code, "101")) return error.HandshakeRejected;

    var found_accept = false;
    var lines = std.mem.splitSequence(u8, response, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            if (!std.mem.eql(u8, value, expected_accept)) return error.AcceptMismatch;
            found_accept = true;
        }
    }
    if (!found_accept) return error.MissingAccept;
}

/// 编码一个客户端帧（必掩码）。
pub fn encodeFrame(
    alloc: std.mem.Allocator,
    opcode: Opcode,
    payload: []const u8,
    mask: [4]u8,
) ![]u8 {
    const len = payload.len;
    var header_len: usize = 2;
    if (len >= 126 and len <= 0xFFFF) header_len += 2 else if (len > 0xFFFF) header_len += 8;
    header_len += 4; // mask key

    const out = try alloc.alloc(u8, header_len + len);
    var i: usize = 0;

    out[i] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN=1
    i += 1;

    if (len < 126) {
        out[i] = 0x80 | @as(u8, @intCast(len));
        i += 1;
    } else if (len <= 0xFFFF) {
        out[i] = 0x80 | 126;
        i += 1;
        out[i] = @intCast((len >> 8) & 0xFF);
        out[i + 1] = @intCast(len & 0xFF);
        i += 2;
    } else {
        out[i] = 0x80 | 127;
        i += 1;
        var shift: u6 = 56;
        while (true) {
            out[i] = @intCast((len >> shift) & 0xFF);
            i += 1;
            if (shift == 0) break;
            shift -= 8;
        }
    }

    @memcpy(out[i .. i + 4], &mask);
    i += 4;

    for (payload, 0..) |b, k| out[i + k] = b ^ mask[k % 4];
    return out;
}

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
    /// 从输入里消耗的字节数（含头与掩码）
    consumed: usize,
};

/// 解析一帧。字节不够时返回 error.NeedMore（调用方继续读 socket）。
/// 返回的 payload 由 alloc 分配，调用方负责释放。
pub fn parseFrame(alloc: std.mem.Allocator, bytes: []const u8) !Frame {
    if (bytes.len < 2) return error.NeedMore;

    const b1 = bytes[0];
    const b2 = bytes[1];
    const fin = (b1 & 0x80) != 0;
    const opcode_raw: u4 = @intCast(b1 & 0x0F);
    const opcode = Opcode.fromInt(opcode_raw) orelse return error.UnknownOpcode;
    const masked = (b2 & 0x80) != 0;
    var len: usize = b2 & 0x7F;

    var i: usize = 2;
    if (len == 126) {
        if (bytes.len < i + 2) return error.NeedMore;
        len = (@as(usize, bytes[i]) << 8) | bytes[i + 1];
        i += 2;
    } else if (len == 127) {
        if (bytes.len < i + 8) return error.NeedMore;
        len = 0;
        for (bytes[i .. i + 8]) |b| len = (len << 8) | b;
        i += 8;
    }

    var mask: ?[4]u8 = null;
    if (masked) {
        if (bytes.len < i + 4) return error.NeedMore;
        mask = .{ bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3] };
        i += 4;
    }

    if (bytes.len < i + len) return error.NeedMore;

    const payload = try alloc.alloc(u8, len);
    @memcpy(payload, bytes[i .. i + len]);
    if (mask) |m| {
        for (payload, 0..) |*b, k| b.* ^= m[k % 4];
    }

    return .{
        .fin = fin,
        .opcode = opcode,
        .payload = payload,
        .consumed = i + len,
    };
}

/// close 帧载荷：2 字节大端状态码 + 可选原因。
pub fn closePayload(alloc: std.mem.Allocator, code: u16, reason: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, 2 + reason.len);
    out[0] = @intCast((code >> 8) & 0xFF);
    out[1] = @intCast(code & 0xFF);
    @memcpy(out[2..], reason);
    return out;
}

pub const Url = struct {
    host: []const u8,
    port: u16,
    /// 总以 '/' 开头；无 path 时为 "/"
    path: []const u8,
    secure: bool,
};

/// 解析 ws:// / wss:// URL。这是纯切片运算：host/path 指向输入内存。
/// wss 需要 TLS 客户端接线（std.crypto.tls + net stream），当前明确报错
/// 而不是静默当明文发 —— 配置写错 `wss://` 比连不上更糟。
pub fn parseUrl(url: []const u8) !Url {
    if (std.mem.startsWith(u8, url, "ws://")) {
        const rest = url["ws://".len..];
        return parseAuthority(rest, 80, false);
    }
    if (std.mem.startsWith(u8, url, "wss://")) {
        return error.UnsupportedScheme;
    }
    return error.UnsupportedScheme;
}

fn parseAuthority(rest: []const u8, default_port: u16, secure: bool) !Url {
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const authority = if (slash) |i| rest[0..i] else rest;
    const path = if (slash) |i| rest[i..] else "/";

    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.UserInfoNotSupported;
    if (authority.len == 0) return error.MissingHost;

    // IPv6 字面量 [::1]:8080
    if (std.mem.startsWith(u8, authority, "[")) {
        const close_bracket = std.mem.indexOfScalar(u8, authority, ']') orelse return error.MalformedHost;
        const host = authority[1..close_bracket];
        if (host.len == 0) return error.MissingHost;
        const after = authority[close_bracket + 1 ..];
        if (after.len == 0) return .{ .host = host, .port = default_port, .path = path, .secure = secure };
        if (after[0] != ':' or after.len < 2) return error.MalformedHost;
        const port = std.fmt.parseInt(u16, after[1..], 10) catch return error.MalformedPort;
        return .{ .host = host, .port = port, .path = path, .secure = secure };
    }

    const colon = std.mem.indexOfScalar(u8, authority, ':');
    if (colon) |i| {
        const host = authority[0..i];
        if (host.len == 0) return error.MissingHost;
        const port = std.fmt.parseInt(u16, authority[i + 1 ..], 10) catch return error.MalformedPort;
        return .{ .host = host, .port = port, .path = path, .secure = secure };
    }
    return .{ .host = authority, .port = default_port, .path = path, .secure = secure };
}

const testing = std.testing;

test "acceptKey matches RFC 6455 example" {
    // RFC 6455 §1.3 的官方示例
    const got = acceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &got);
}

test "encodeKey produces 24 chars of base64" {
    const a = testing.allocator;
    var seed: [16]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i);
    const k = try encodeKey(a, seed);
    defer a.free(k);
    try testing.expectEqual(@as(usize, 24), k.len);
    try testing.expectEqualStrings("AAECAwQFBgcICQoLDA0ODw==", k);
}

test "handshake request carries required headers" {
    const a = testing.allocator;
    const req = try handshakeRequest(a, "127.0.0.1", 8765, "/chat", "dGhlIHNhbXBsZSBub25jZQ==");
    defer a.free(req);

    try testing.expect(std.mem.startsWith(u8, req, "GET /chat HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, req, "Host: 127.0.0.1:8765") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Upgrade: websocket") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Connection: Upgrade") != null);
    try testing.expect(std.mem.indexOf(u8, req, "Sec-WebSocket-Version: 13") != null);
    try testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));

    // 默认端口不写 :port
    const req2 = try handshakeRequest(a, "example.com", 80, "/", "k");
    defer a.free(req2);
    try testing.expect(std.mem.indexOf(u8, req2, "Host: example.com\r\n") != null);
}

test "verifyHandshake accepts a good response" {
    const accept = acceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    const ok =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    try verifyHandshake(ok, &accept);
}

test "verifyHandshake rejects wrong status / accept / missing accept" {
    const accept = acceptKey("k");
    try testing.expectError(error.HandshakeRejected, verifyHandshake(
        "HTTP/1.1 400 Bad Request\r\n\r\n",
        &accept,
    ));
    try testing.expectError(error.AcceptMismatch, verifyHandshake(
        "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: WRONG\r\n\r\n",
        &accept,
    ));
    try testing.expectError(error.MissingAccept, verifyHandshake(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n",
        &accept,
    ));
}

test "frame round-trip for small / medium / large payloads" {
    const a = testing.allocator;
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

    const sizes = [_]usize{ 0, 1, 5, 125, 126, 200, 65535, 65536 };
    for (sizes) |n| {
        const payload = try a.alloc(u8, n);
        defer a.free(payload);
        for (payload, 0..) |*b, i| b.* = @intCast(i % 251);

        const wire = try encodeFrame(a, .text, payload, mask);
        defer a.free(wire);

        // 客户端帧必须置掩码位
        try testing.expect((wire[1] & 0x80) != 0);

        const f = try parseFrame(a, wire);
        defer a.free(f.payload);
        try testing.expectEqual(true, f.fin);
        try testing.expectEqual(Opcode.text, f.opcode);
        try testing.expectEqual(n, f.payload.len);
        try testing.expectEqual(n, f.consumed - (wire.len - n));
        try testing.expectEqualSlices(u8, payload, f.payload);
    }
}

test "parseFrame tolerates unmasked server frames" {
    const a = testing.allocator;
    // 服务端帧：FIN|text, len=5, 无掩码
    const wire = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    const f = try parseFrame(a, &wire);
    defer a.free(f.payload);
    try testing.expectEqualStrings("hello", f.payload);
    try testing.expectEqual(@as(usize, 7), f.consumed);
}

test "parseFrame decompresses masked frames from peers" {
    const a = testing.allocator;
    const mask = [4]u8{ 1, 2, 3, 4 };
    const wire = try encodeFrame(a, .binary, "abc", mask);
    defer a.free(wire);
    const f = try parseFrame(a, wire);
    defer a.free(f.payload);
    try testing.expectEqualStrings("abc", f.payload);
    try testing.expectEqual(Opcode.binary, f.opcode);
}

test "parseFrame reports NeedMore on partial input" {
    const a = testing.allocator;
    try testing.expectError(error.NeedMore, parseFrame(a, &.{0x81}));
    try testing.expectError(error.NeedMore, parseFrame(a, &.{ 0x81, 0x05, 'h' }));
    // 16 位长度但只给 1 字节长度字段
    try testing.expectError(error.NeedMore, parseFrame(a, &.{ 0x81, 126, 0x00 }));
}

test "parseFrame rejects unknown opcode" {
    const a = testing.allocator;
    try testing.expectError(error.UnknownOpcode, parseFrame(a, &.{ 0x83, 0x00 }));
}

test "closePayload encodes big-endian code plus reason" {
    const a = testing.allocator;
    const p = try closePayload(a, CloseCode.normal, "bye");
    defer a.free(p);
    try testing.expectEqual(@as(u8, 0x03), p[0]);
    try testing.expectEqual(@as(u8, 0xE8), p[1]); // 1000
    try testing.expectEqualStrings("bye", p[2..]);
}

test "control opcodes are flagged" {
    try testing.expect(Opcode.close.isControl());
    try testing.expect(Opcode.ping.isControl());
    try testing.expect(Opcode.pong.isControl());
    try testing.expect(!Opcode.text.isControl());
    try testing.expect(!Opcode.binary.isControl());
}

test "parseUrl handles host / port / path / defaults" {
    const a1 = try parseUrl("ws://127.0.0.1:8765/chat");
    try testing.expectEqualStrings("127.0.0.1", a1.host);
    try testing.expectEqual(@as(u16, 8765), a1.port);
    try testing.expectEqualStrings("/chat", a1.path);
    try testing.expectEqual(false, a1.secure);

    const a2 = try parseUrl("ws://localhost");
    try testing.expectEqualStrings("localhost", a2.host);
    try testing.expectEqual(@as(u16, 80), a2.port);
    try testing.expectEqualStrings("/", a2.path);

    const a3 = try parseUrl("ws://example.com/api/v1?token=x");
    try testing.expectEqualStrings("example.com", a3.host);
    try testing.expectEqualStrings("/api/v1?token=x", a3.path);

    // IPv6 字面量
    const a4 = try parseUrl("ws://[::1]:9000/ws");
    try testing.expectEqualStrings("::1", a4.host);
    try testing.expectEqual(@as(u16, 9000), a4.port);
    try testing.expectEqualStrings("/ws", a4.path);
}

test "parseUrl rejects wss / userinfo / malformed input" {
    try testing.expectError(error.UnsupportedScheme, parseUrl("wss://example.com"));
    try testing.expectError(error.UnsupportedScheme, parseUrl("http://example.com"));
    try testing.expectError(error.UserInfoNotSupported, parseUrl("ws://user:pass@example.com"));
    try testing.expectError(error.MissingHost, parseUrl("ws://"));
    try testing.expectError(error.MalformedPort, parseUrl("ws://host:notaport"));
    try testing.expectError(error.MalformedHost, parseUrl("ws://[::1"));
}
