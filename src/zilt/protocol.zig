//! 应用自定义协议（v0.1.24）。
//!
//! 语义对齐 Tauri `register_uri_scheme_protocol`：应用注册一个名字 + 处理函数，
//! 由框架把请求交给它，响应体/状态码/内容类型由应用决定。
//!
//! **Windows 实现是路径式**：`https://<app-origin>/__proto/<name>/<rest>?<query>`。
//! 原因：WebView2 的「真 scheme」（`media://…`）必须经
//! `ICoreWebView2EnvironmentOptions4::SetCustomSchemeRegistrations` 注册，而该接口需要
//! 自行实现 17 槽 vtable + `ICoreWebView2CustomSchemeRegistration`（含版本间有差异的
//! 方法序）。路径式在同一 origin 内经 `WebResourceRequested` 拦截，零 CORS 成本，
//! 能力等价（动态响应/自定义头/二进制流）；真 scheme 列为后续项（见 ROADMAP）。
//!
//! 限制：WebView2 的 `WebResourceRequested` 拿不到请求体，因此 POST 的 body 不可读——
//! 需要上传内容时用 `zilt.invoke` 命令或 `zilt.http`。
const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    /// 注册名（`/__proto/<name>/…` 中的 name）
    name: []const u8,
    /// name 之后的部分，已去掉前导 `/`（可能为空串）
    path: []const u8,
    /// `?` 之后（不含 `?`；无查询串时为空串）
    query: []const u8,
    /// HTTP 方法（GET/POST/…）
    method: []const u8,
    /// 请求的 `User-Agent` 头（无该头时为 null）
    user_agent: ?[]const u8 = null,
    /// 完整请求 URI（调试用）
    url: []const u8,
};

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "text/plain; charset=utf-8",
    /// 由处理函数用传入的 allocator 分配（框架写回后释放）；
    /// 返回静态字面量时把 `owned` 置 false。
    body: []const u8 = "",
    owned: bool = true,
    headers: []const Header = &.{},
};

pub const Handler = *const fn (req: Request, alloc: std.mem.Allocator) anyerror!Response;

pub const Protocol = struct {
    /// 注册名：只允许 `[a-z0-9-]`，避免与路径段混淆
    name: []const u8,
    handle: Handler,
};

pub const prefix = "/__proto/";

pub const Route = struct {
    name: []const u8,
    path: []const u8,
    query: []const u8,
};

/// 从已解码的路径 + 原始 URI 解析出协议路由；不是协议请求返回 null。
pub fn parseRoute(path: []const u8, uri: []const u8) ?Route {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    if (rest.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const name = rest[0..slash];
    if (!validName(name)) return null;
    const tail = if (slash < rest.len) rest[slash + 1 ..] else "";
    const query = if (std.mem.indexOfScalar(u8, uri, '?')) |q| uri[q + 1 ..] else "";
    return .{ .name = name, .path = tail, .query = if (query.len == 0) "" else query };
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    }
    return true;
}

pub fn find(protocols: []const Protocol, name: []const u8) ?Protocol {
    for (protocols) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

pub fn reasonFor(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        416 => "Range Not Satisfiable",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "OK",
    };
}

const testing = std.testing;

fn echo(req: Request, alloc: std.mem.Allocator) anyerror!Response {
    return .{ .body = try std.fmt.allocPrint(alloc, "{s}|{s}|{s}", .{ req.name, req.path, req.query }) };
}

test "v0.1.24: 协议路由解析" {
    const r = parseRoute("/__proto/media/clip/1.bin", "https://zilt.app/__proto/media/clip/1.bin?a=1&b=2").?;
    try testing.expectEqualStrings("media", r.name);
    try testing.expectEqualStrings("clip/1.bin", r.path);
    try testing.expectEqualStrings("a=1&b=2", r.query);

    const bare = parseRoute("/__proto/echo", "https://zilt.app/__proto/echo").?;
    try testing.expectEqualStrings("echo", bare.name);
    try testing.expectEqualStrings("", bare.path);
    try testing.expectEqualStrings("", bare.query);

    // 非协议路径 / 空名 / 非法名
    try testing.expect(parseRoute("/index.html", "https://zilt.app/index.html") == null);
    try testing.expect(parseRoute("/__proto/", "https://zilt.app/__proto/") == null);
    try testing.expect(parseRoute("/__proto/Bad_Name/x", "https://zilt.app/__proto/Bad_Name/x") == null);
    try testing.expect(parseRoute("/__proto/../../etc", "https://zilt.app/__proto/../../etc") == null);
}

test "v0.1.24: 注册表查找与状态短语" {
    const list = [_]Protocol{.{ .name = "media", .handle = echo }};
    try testing.expect(find(&list, "media") != null);
    try testing.expect(find(&list, "video") == null);
    try testing.expectEqualStrings("Not Found", reasonFor(404));
    try testing.expectEqualStrings("Internal Server Error", reasonFor(500));
    try testing.expectEqualStrings("OK", reasonFor(299));
}

test "v0.1.24: 处理函数通过 allocator 产出响应体" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try echo(.{ .name = "echo", .path = "a/b", .query = "q=1", .method = "GET", .url = "u" }, arena.allocator());
    try testing.expectEqualStrings("echo|a/b|q=1", res.body);
    try testing.expect(res.owned);
}
