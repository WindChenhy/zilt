//! 应用自定义协议（v0.1.24 路径式 + v0.3.2 真 scheme 式）。
//!
//! 语义对齐 Tauri `register_uri_scheme_protocol`：应用注册一个名字 + 处理函数，
//! 由框架把请求交给它，响应体/状态码/内容类型由应用决定。
//!
//! **两种访问形态并存**：
//! - 路径式（v0.1.24，所有平台可用）：`https://<app-origin>/__proto/<name>/<rest>?<query>`。
//!   同一 origin 内经 `WebResourceRequested` 拦截，零 CORS 成本。
//! - 真 scheme 式（v0.3.2）：`<scheme>://localhost/<rest>?<query>`。
//!   Windows 经 `ICoreWebView2EnvironmentOptions4::SetCustomSchemeRegistrations` +
//!   `ICoreWebView2CustomSchemeRegistration` 注册（见 platform/windows/custom_scheme.zig；
//!   注册名沿用 `validName` 规则，`hasAuthorityComponent=true` 因此统一用 `localhost`
//!   作为 authority）；Linux 侧本就是真 scheme。老运行时不支持 Options4 时 QI 失败，
//!   自动回退路径式（仅记录日志，不视为致命）。
//!
//! 限制（Windows/WebView2，实测 runtime 157→157+；v0.3.8 B8 解除 body 限制）：
//! 1. ~~POST body 不可读~~ **v0.3.8 已支持**：WebView2 对带 body 的请求不回传
//!    `Content-Length` 头，但 `ICoreWebView2WebResourceRequest::get_Content`
//!    （IStream）拿得到完整请求体（Wails PR#6326 核实同款行为与修复方式）。
//!    `Request.body` 携带读取结果（同步读，10MB 上限；无 body 的请求为 null）。
//!    Linux 侧经 `webkit_uri_scheme_request_get_http_body`（SoupMessageBody）。
//! 2. **fetch/XHR 对自定义 scheme 不发请求（Windows，v0.3.8 B8 实测）**：Chromium 的
//!    fetch()/XHR 只允许 http(s)/blob/data 等 scheme——无论跨 origin（https 页面 →
//!    `echo://`）还是同 scheme 文档内（`echo://` 页面 → `echo://`），请求根本不会
//!    发出（响应侧 ACAO/AllowedOrigins 与此无关）。可用的自定义 scheme 请求通道 =
//!    **导航类**（iframe/frame 导航、表单 POST、`<img>` 等，经 WebResourceRequested
//!    全链可达，POST body 经 `get_Content` 读取）+ 同源路径式 `/__proto/<name>/…`
//!    （fetch 全功能可用）。Linux/WebKit 的 fetch 自定义 scheme 正常（v0.2.3 实测）
//!    ——平台差异文档化。
//! 3. `HasAuthorityComponent=false`（opaque origin）会在 iframe 导航时直接崩溃
//!    浏览器进程——保持 true（tuple origin），authority 段并入 path 由处理函数
//!    自行解释。
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
    /// v0.3.8 B8：请求体（POST/PUT 等；无 body 的请求为 null）。
    /// Windows 经 `get_Content` IStream 同步读取（10MB 上限，超限返回 null 并记
    /// 日志）；Linux 经 `webkit_uri_scheme_request_get_http_body`。所有权归框架，
    /// 处理函数返回后释放——如需保留请 `alloc.dupe`。
    body: ?[]const u8 = null,
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

/// 提取 URI 的 scheme 名（`name://…` 的 name）；无 scheme 形态返回 null。
/// 调用方必须再用 `find` 门控——`https`/`http` 等内置 scheme 也会通过本解析，
/// 只有注册过的名字才按自定义协议处理。
pub fn schemeNameOf(uri: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, uri, "://") orelse return null;
    if (sep == 0) return null;
    const name = uri[0..sep];
    if (!validName(name)) return null;
    return name;
}

/// 真 scheme 路由解析（v0.3.2）：`<scheme>://<path>?<query>`——两平台同约定
/// （与 Linux v0.2.3 的 `serveProtocol` 逐字一致：去掉**一个**前导 `/`，首个 `?`
/// 之后是 query）。authority 段（若 URL 携带）**并入 path**——fetch 方决定
/// URL 形态，处理函数只看 path/query。`media://clip/1.bin` 与
/// `media://localhost/clip/1.bin` 分别给出 path=`clip/1.bin` /
/// `localhost/clip/1.bin`（文档化：demo/冒烟统一用无 authority 形态）。
/// **调用方必须先经 `schemeNameOf` + `find` 门控**——本函数对任何合法 scheme 名
/// 都会解析成功（包括 https），门控是防误拦内置 scheme 的关键。
pub fn parseSchemeRoute(uri: []const u8) ?Route {
    const sep = std.mem.indexOf(u8, uri, "://") orelse return null;
    const name = uri[0..sep];
    if (!validName(name)) return null;
    var rest = uri[sep + 3 ..];
    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    var path = rest;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        path = rest[0..q];
        query = rest[q + 1 ..];
    }
    return .{ .name = name, .path = path, .query = query };
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

test "v0.3.2: 真 scheme 路由解析（两平台同约定：去一个前导斜杠 + query 分离 + 门控）" {
    // 与 Linux 冒烟一致的形态：echo://a/b?x=1 → path=a/b query=x=1
    const r = parseSchemeRoute("media://clip/1.bin?a=1&b=2").?;
    try testing.expectEqualStrings("media", r.name);
    try testing.expectEqualStrings("clip/1.bin", r.path);
    try testing.expectEqualStrings("a=1&b=2", r.query);

    // 显式前导 '/'（Chromium 规范化可能补）→ 同样去掉一个
    const slashed = parseSchemeRoute("media:///clip/2.bin").?;
    try testing.expectEqualStrings("clip/2.bin", slashed.path);
    try testing.expectEqualStrings("", slashed.query);

    // authority 形态：并入 path（文档化；demo/冒烟统一用无 authority 形态）
    const localhosted = parseSchemeRoute("media://localhost/clip/1.bin?a=1").?;
    try testing.expectEqualStrings("localhost/clip/1.bin", localhosted.path);
    try testing.expectEqualStrings("a=1", localhosted.query);

    // 裸 path（无 query / 无斜杠）
    const bare = parseSchemeRoute("app://ping").?;
    try testing.expectEqualStrings("app", bare.name);
    try testing.expectEqualStrings("ping", bare.path);

    // 非法 scheme 名 / 非 scheme 形态 → null
    try testing.expect(parseSchemeRoute("Bad_Name://x") == null);
    try testing.expect(parseSchemeRoute("notaurl") == null);

    // **门控**：https 是合法 scheme 名、parseSchemeRoute 也会解析它——
    // 调用方必须经 schemeNameOf + find 只放行注册过的名字
    try testing.expectEqualStrings("https", schemeNameOf("https://zilt.app/index.html").?);
    const gated = [_]Protocol{.{ .name = "media", .handle = echo }};
    const uri = "https://zilt.app/index.html";
    if (schemeNameOf(uri)) |name| {
        try testing.expect(find(&gated, name) == null); // 未注册 → 不按协议处理
    }
    const media_uri = "media://clip/1.bin";
    if (schemeNameOf(media_uri)) |name| {
        try testing.expect(find(&gated, name) != null); // 已注册 → 协议处理
    }
    try testing.expect(schemeNameOf("://no-name") == null);
}

test "v0.1.24: 处理函数通过 allocator 产出响应体" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try echo(.{ .name = "echo", .path = "a/b", .query = "q=1", .method = "GET", .url = "u" }, arena.allocator());
    try testing.expectEqualStrings("echo|a/b|q=1", res.body);
    try testing.expect(res.owned);
}

test "v0.3.8 B8: Request.body 传入处理函数（POST 回显契约）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bodyEcho = struct {
        fn handle(req: Request, alloc: std.mem.Allocator) anyerror!Response {
            const b = req.body orelse "";
            return .{ .body = try std.fmt.allocPrint(alloc, "post|{d}|{s}", .{ b.len, b }) };
        }
    }.handle;
    const with_body = try bodyEcho(.{ .name = "postecho", .path = "upload", .query = "", .method = "POST", .body = "hello-post-body-42", .url = "u" }, arena.allocator());
    try testing.expectEqualStrings("post|18|hello-post-body-42", with_body.body);
    const without_body = try bodyEcho(.{ .name = "postecho", .path = "upload", .query = "", .method = "GET", .body = null, .url = "u" }, arena.allocator());
    try testing.expectEqualStrings("post|0|", without_body.body);
}
