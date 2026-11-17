//! 网络辅助（平台无关）：URL 解析、multipart 构造、base64。
//!
//! v0.1.20：WinHTTP 客户端需要自己拆 URL；multipart 与 base64 分块是
//! 「HTTP 上传 / 流式下载」的纯逻辑部分，单独放这里便于单测。
const std = @import("std");

pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    /// 以 `/` 开头的路径（含 query，不含 fragment）
    path: []const u8,
    secure: bool,
};

pub const UrlError = error{
    EmptyUrl,
    UnsupportedScheme,
    MissingHost,
    BadPort,
    InvalidCharacter,
    UserInfoNotAllowed,
};

/// 解析 http/https/ws/wss URL。只接受绝对 URL（服务端请求用）。
pub fn parseUrl(raw: []const u8) UrlError!Url {
    if (raw.len == 0) return error.EmptyUrl;
    if (raw.len > 8192) return error.EmptyUrl;
    for (raw) |c| {
        if (c <= 0x20 or c == 0x7f) return error.InvalidCharacter;
    }
    const sep = std.mem.indexOf(u8, raw, "://") orelse return error.UnsupportedScheme;
    const scheme = raw[0..sep];
    const secure = std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "wss");
    if (!secure and !std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "ws")) {
        return error.UnsupportedScheme;
    }

    const rest = raw[sep + 3 ..];
    const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..auth_end];
    if (authority.len == 0) return error.MissingHost;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.UserInfoNotAllowed;

    var host = authority;
    var port: u16 = if (secure) 443 else 80;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.MissingHost;
        host = authority[0 .. close + 1];
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return error.BadPort;
            port = parsePort(authority[close + 2 ..]) catch return error.BadPort;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        if (host.len == 0) return error.MissingHost;
        port = parsePort(authority[colon + 1 ..]) catch return error.BadPort;
    }

    var path: []const u8 = "/";
    if (auth_end < rest.len) {
        const tail = rest[auth_end..];
        if (tail[0] == '#') {
            path = "/";
        } else if (tail[0] == '?') {
            // 没有路径但有 query：补一个 `/`
            path = raw[sep + 3 + auth_end ..];
        } else {
            path = raw[sep + 3 + auth_end ..];
        }
    }
    // 去掉 fragment
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
    if (path.len == 0) path = "/";
    return .{ .scheme = scheme, .host = host, .port = port, .path = path, .secure = secure };
}

fn parsePort(text: []const u8) !u16 {
    if (text.len == 0 or text.len > 5) return error.BadPort;
    const p = try std.fmt.parseInt(u16, text, 10);
    if (p == 0) return error.BadPort;
    return p;
}

/// 把 `"A: 1\nB: 2"` 规范成 WinHTTP 需要的 `A: 1\r\nB: 2\r\n`。
pub fn normalizeHeaders(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitAny(u8, raw, "\r\n");
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0) continue;
        if (std.mem.indexOfScalar(u8, t, ':') == null) continue;
        try out.appendSlice(alloc, t);
        try out.appendSlice(alloc, "\r\n");
    }
    return out.toOwnedSlice(alloc);
}

pub const Part = struct {
    name: []const u8,
    data: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

pub const Multipart = struct {
    body: []u8,
    content_type: []u8,

    pub fn deinit(self: *Multipart, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        alloc.free(self.content_type);
    }
};

/// 生成 multipart/form-data 请求体。boundary 由调用方给（测试可确定）。
pub fn buildMultipart(alloc: std.mem.Allocator, boundary: []const u8, parts: []const Part) !Multipart {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(alloc);

    for (parts) |p| {
        try body.appendSlice(alloc, "--");
        try body.appendSlice(alloc, boundary);
        try body.appendSlice(alloc, "\r\n");
        try body.appendSlice(alloc, "Content-Disposition: form-data; name=\"");
        try appendEscaped(&body, alloc, p.name);
        try body.append(alloc, '"');
        if (p.filename) |fname| {
            try body.appendSlice(alloc, "; filename=\"");
            try appendEscaped(&body, alloc, fname);
            try body.append(alloc, '"');
        }
        try body.appendSlice(alloc, "\r\n");
        if (p.content_type) |ct| {
            try body.appendSlice(alloc, "Content-Type: ");
            try body.appendSlice(alloc, ct);
            try body.appendSlice(alloc, "\r\n");
        }
        try body.appendSlice(alloc, "\r\n");
        try body.appendSlice(alloc, p.data);
        try body.appendSlice(alloc, "\r\n");
    }
    try body.appendSlice(alloc, "--");
    try body.appendSlice(alloc, boundary);
    try body.appendSlice(alloc, "--\r\n");

    return .{
        .body = try body.toOwnedSlice(alloc),
        .content_type = try std.fmt.allocPrint(alloc, "multipart/form-data; boundary={s}", .{boundary}),
    };
}

var boundary_counter = std.atomic.Value(u64).init(0);

/// 生成进程内唯一 boundary（计数器 + 栈地址；无需 CSPRNG——boundary 只需不冲突）。
pub fn randomBoundary(buf: *[32]u8) []const u8 {
    var seed: [16]u8 = undefined;
    const n = boundary_counter.fetchAdd(1, .monotonic);
    const addr: u64 = @intFromPtr(buf);
    std.mem.writeInt(u64, seed[0..8], n, .little);
    std.mem.writeInt(u64, seed[8..16], addr, .little);
    return std.fmt.bufPrint(buf, "zilt-{x}", .{seed}) catch "zilt-boundary";
}

fn appendEscaped(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        if (c == '"' or c == '\\') try out.append(alloc, '\\');
        if (c == '\r' or c == '\n' or c == 0) continue;
        try out.append(alloc, c);
    }
}

/// 分块 base64（流式下载用，避免 JS 侧处理二进制）。
pub fn base64Alloc(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const n = std.base64.standard.Encoder.calcSize(data.len);
    const out = try alloc.alloc(u8, n);
    return @constCast(std.base64.standard.Encoder.encode(out, data));
}

/// v0.3.8 E6：base64 解码（multipart 二进制分片 `encoding: "base64"` 用）。
/// 错误归一为 `error.InvalidBase64`（调用方按统一错误名拒绝非法载荷）。
pub fn base64DecodeAlloc(alloc: std.mem.Allocator, data: []const u8) error{OutOfMemory, InvalidBase64}![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(data) catch return error.InvalidBase64;
    const out = alloc.alloc(u8, n) catch return error.OutOfMemory;
    errdefer alloc.free(out);
    dec.decode(out, data) catch return error.InvalidBase64;
    return out;
}

const testing = std.testing;

test "v0.1.20: parse http/https/ws/wss urls" {
    const a = try parseUrl("http://example.com/a/b?q=1");
    try testing.expectEqualStrings("http", a.scheme);
    try testing.expectEqualStrings("example.com", a.host);
    try testing.expectEqual(@as(u16, 80), a.port);
    try testing.expectEqualStrings("/a/b?q=1", a.path);
    try testing.expect(!a.secure);

    const b = try parseUrl("https://api.example.com:8443");
    try testing.expectEqual(@as(u16, 8443), b.port);
    try testing.expectEqualStrings("/", b.path);
    try testing.expect(b.secure);

    const c = try parseUrl("wss://example.com/chat?x=1");
    try testing.expectEqualStrings("wss", c.scheme);
    try testing.expectEqual(@as(u16, 443), c.port);
    try testing.expect(c.secure);

    const d = try parseUrl("ws://127.0.0.1:8765");
    try testing.expectEqualStrings("127.0.0.1", d.host);
    try testing.expectEqual(@as(u16, 8765), d.port);
    try testing.expect(!d.secure);

    const e = try parseUrl("http://[::1]:8080/x");
    try testing.expectEqualStrings("[::1]", e.host);
    try testing.expectEqual(@as(u16, 8080), e.port);
    try testing.expectEqualStrings("/x", e.path);
}

test "v0.1.20: parseUrl rejects bad input" {
    try testing.expectError(error.EmptyUrl, parseUrl(""));
    try testing.expectError(error.UnsupportedScheme, parseUrl("ftp://x/y"));
    try testing.expectError(error.UnsupportedScheme, parseUrl("example.com/x"));
    try testing.expectError(error.MissingHost, parseUrl("http:///x"));
    try testing.expectError(error.UserInfoNotAllowed, parseUrl("http://u:p@x/y"));
    try testing.expectError(error.InvalidCharacter, parseUrl("http://x/a b"));
    try testing.expectError(error.BadPort, parseUrl("http://x:0/"));
    try testing.expectError(error.BadPort, parseUrl("http://x:99999/"));
}

test "v0.1.20: normalizeHeaders" {
    const out = try normalizeHeaders(testing.allocator, "A: 1\nB:2\r\n\r\nbadline\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("A: 1\r\nB:2\r\n", out);
}

test "v0.1.20: multipart body" {
    const parts = [_]Part{
        .{ .name = "field", .data = "value" },
        .{ .name = "file", .filename = "a\"b.txt", .content_type = "text/plain", .data = "hello" },
    };
    var mp = try buildMultipart(testing.allocator, "BOUND", &parts);
    defer mp.deinit(testing.allocator);
    try testing.expectEqualStrings("multipart/form-data; boundary=BOUND", mp.content_type);
    try testing.expect(std.mem.startsWith(u8, mp.body, "--BOUND\r\n"));
    try testing.expect(std.mem.indexOf(u8, mp.body, "name=\"field\"\r\n\r\nvalue\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, mp.body, "filename=\"a\\\"b.txt\"") != null);
    try testing.expect(std.mem.endsWith(u8, mp.body, "--BOUND--\r\n"));
}

test "v0.1.20: base64 chunk" {
    const out = try base64Alloc(testing.allocator, "hello");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aGVsbG8=", out);
}

test "v0.3.8 E6: base64 解码往返 + 篡改拒绝" {
    const raw = "hello-post-body-42\x00\xfe\xffbinary";
    const enc = try base64Alloc(testing.allocator, raw);
    defer testing.allocator.free(enc);
    const dec = try base64DecodeAlloc(testing.allocator, enc);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(raw, dec);
    try testing.expectError(error.InvalidBase64, base64DecodeAlloc(testing.allocator, "a!"));
    // 长度非 4 的倍数
    try testing.expectError(error.InvalidBase64, base64DecodeAlloc(testing.allocator, "abc"));
}
