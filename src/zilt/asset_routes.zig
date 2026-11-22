const std = @import("std");

pub fn decodePath(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const end = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
    const input = raw[0..end];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        var c = input[i];
        if (c == '%') {
            if (i + 2 >= input.len) return error.InvalidPath;
            c = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch return error.InvalidPath;
            i += 2;
            if (c == '/' or c == '\\' or c == '%') return error.InvalidPath;
        }
        if (c < 0x20 or c == '\\' or c == ':' or c == 0x7f) return error.InvalidPath;
        try out.append(alloc, c);
    }
    if (out.items.len == 0) try out.append(alloc, '/');
    if (out.items[0] != '/' or !std.unicode.utf8ValidateSlice(out.items)) return error.InvalidPath;
    var segments = std.mem.splitScalar(u8, out.items, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPath;
        if (segment.len != 0 and (segment[segment.len - 1] == '.' or segment[segment.len - 1] == ' ')) return error.InvalidPath;
    }
    return out.toOwnedSlice(alloc);
}

/// 从 `scheme://app/...` 取路径（WKURLSchemeHandler 的 URL → 资产路径）。
/// 只接受空 host 或 `app` host；无路径时视为入口 `/index.html`。
pub fn pathFromCustomScheme(url: []const u8, scheme: []const u8) ?[]const u8 {
    // scheme + "://"（scheme 是运行时参数，不能 comptimePrint）
    if (url.len < scheme.len + 3) return null;
    if (!std.mem.startsWith(u8, url, scheme)) return null;
    if (!std.mem.eql(u8, url[scheme.len..][0..3], "://")) return null;
    const rest = url[scheme.len + 3 ..];
    if (rest.len == 0) return "/index.html";
    if (rest[0] == '/') return rest; // scheme:///path
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/index.html";
    const host = rest[0..slash];
    if (host.len != 0 and !std.mem.eql(u8, host, "app")) return null;
    const path = rest[slash..];
    // 去 query/fragment（资产查找只认路径；decodePath 也会去，但先收敛更直观）
    const end = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    const clean = path[0..end];
    if (clean.len == 0 or std.mem.eql(u8, clean, "/")) return "/index.html";
    return clean;
}

/// `config.url` → 自有 scheme 下的入口路径（默认 `/index.html`）。
/// `https://zilt.app/sub/` → `/sub/`；开发服务器 URL 只取路径部分。
pub fn appEntryPath(url: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, url, "://") orelse return "/index.html";
    const after = url[idx + 3 ..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return "/index.html";
    const p = after[slash..];
    // 去掉 query/fragment（入口只认路径），再判断是否等同根
    const end = std.mem.indexOfAny(u8, p, "?#") orelse p.len;
    const clean = p[0..end];
    if (clean.len == 0 or std.mem.eql(u8, clean, "/")) return "/index.html";
    return clean;
}

/// `config.url` → 实际加载的 URL：
/// - 内嵌模式（默认 `https://zilt.app/...`）→ `<scheme>://<scheme_host>/<entry>`
/// - 开发服务器/外部站点（其它 http(s)）→ 原样返回
pub fn resolveEntryUrl(
    alloc: std.mem.Allocator,
    url: []const u8,
    scheme: []const u8,
    scheme_host: []const u8,
    embedded_host: []const u8,
) ![]u8 {
    if (std.mem.indexOf(u8, url, "://")) |i| {
        const rest = url[i + 3 ..];
        const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        const host = rest[0..host_end];
        const is_http = std.mem.startsWith(u8, url, "http://") or
            std.mem.startsWith(u8, url, "https://");
        if (is_http and !std.mem.eql(u8, host, embedded_host)) {
            return alloc.dupe(u8, url);
        }
    }
    return std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ scheme, scheme_host, appEntryPath(url) });
}

/// 扩展名 → Content-Type（两平台共用；未知类型按二进制流）。
pub fn contentTypeOf(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const ext = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[i + 1 ..] else "";
    const map = [_]struct { ext: []const u8, ct: []const u8 }{
        .{ .ext = "html", .ct = "text/html; charset=utf-8" },
        .{ .ext = "js", .ct = "text/javascript; charset=utf-8" },
        .{ .ext = "mjs", .ct = "text/javascript; charset=utf-8" },
        .{ .ext = "css", .ct = "text/css; charset=utf-8" },
        .{ .ext = "json", .ct = "application/json" },
        .{ .ext = "svg", .ct = "image/svg+xml" },
        .{ .ext = "png", .ct = "image/png" },
        .{ .ext = "jpg", .ct = "image/jpeg" },
        .{ .ext = "ico", .ct = "image/x-icon" },
        .{ .ext = "woff2", .ct = "font/woff2" },
        .{ .ext = "ts", .ct = "text/plain; charset=utf-8" },
    };
    for (map) |m| {
        if (std.ascii.eqlIgnoreCase(ext, m.ext)) return m.ct;
    }
    return "application/octet-stream";
}

pub const Candidates = struct {
    alloc: std.mem.Allocator,
    paths: [4]?[]u8 = @splat(null),
    pub fn init(alloc: std.mem.Allocator, path: []const u8, document: bool) !Candidates {
        var result = Candidates{ .alloc = alloc };
        errdefer result.deinit();
        result.paths[0] = try alloc.dupe(u8, if (std.mem.eql(u8, path, "/")) "/index.html" else path);
        if (document) {
            const trimmed = std.mem.trimEnd(u8, path, "/");
            result.paths[1] = try std.fmt.allocPrint(alloc, "{s}.html", .{trimmed});
            result.paths[2] = try std.fmt.allocPrint(alloc, "{s}/index.html", .{trimmed});
            result.paths[3] = try alloc.dupe(u8, "/index.html");
        }
        return result;
    }
    pub fn deinit(self: *Candidates) void {
        for (self.paths) |path| if (path) |p| self.alloc.free(p);
    }
};

test "SPA candidates keep missing script responses as 404" {
    const t = std.testing;
    var routes = try Candidates.init(t.allocator, "/account", true);
    defer routes.deinit();
    try t.expectEqualStrings("/account", routes.paths[0].?);
    try t.expectEqualStrings("/account.html", routes.paths[1].?);
    try t.expectEqualStrings("/account/index.html", routes.paths[2].?);
    try t.expectEqualStrings("/index.html", routes.paths[3].?);
    var script = try Candidates.init(t.allocator, "/missing.js", false);
    defer script.deinit();
    try t.expect(script.paths[1] == null);
}
test "asset path decodes Unicode and rejects traversal" {
    const t = std.testing;
    const path = try decodePath(t.allocator, "/hello%20world?test=1");
    defer t.allocator.free(path);
    try t.expectEqualStrings("/hello world", path);
    for ([_][]const u8{ "/../secret", "/%2e%2e/secret", "/a%2fb", "/a%5cb", "/a%00", "/a:secret", "/a%252fb", "/a./file" }) |bad| try t.expectError(error.InvalidPath, decodePath(t.allocator, bad));
}

test "pathFromCustomScheme: WKURLSchemeHandler 的 URL → 路径" {
    try std.testing.expectEqualStrings("/index.html", pathFromCustomScheme("zilt://app/index.html", "zilt").?);
    try std.testing.expectEqualStrings("/assets/app.js", pathFromCustomScheme("zilt://app/assets/app.js?v=1", "zilt").?);
    try std.testing.expectEqualStrings("/index.html", pathFromCustomScheme("zilt://app", "zilt").?);
    try std.testing.expectEqualStrings("/index.html", pathFromCustomScheme("zilt://app/", "zilt").?);
    try std.testing.expectEqualStrings("/x", pathFromCustomScheme("zilt:///x", "zilt").?);
    // 非本 scheme / 未知 host → null（调用方回 404，不泄漏其它 origin）
    try std.testing.expect(pathFromCustomScheme("https://app/index.html", "zilt") == null);
    try std.testing.expect(pathFromCustomScheme("zilt://other/x", "zilt") == null);
    try std.testing.expect(pathFromCustomScheme("zilt://evil.com/x", "zilt") == null);
}

test "appEntryPath: config.url 各形态" {
    try std.testing.expectEqualStrings("/index.html", appEntryPath("https://zilt.app/index.html"));
    try std.testing.expectEqualStrings("/index.html", appEntryPath("https://zilt.app"));
    try std.testing.expectEqualStrings("/index.html", appEntryPath("https://zilt.app/"));
    try std.testing.expectEqualStrings("/app.html", appEntryPath("https://zilt.app/app.html"));
    try std.testing.expectEqualStrings("/sub/", appEntryPath("https://zilt.app/sub/"));
    try std.testing.expectEqualStrings("/index.html", appEntryPath("http://localhost:5173/?debug=1"));
    try std.testing.expectEqualStrings("/index.html", appEntryPath(""));
}

test "resolveEntryUrl: 内嵌 vs 开发服务器" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "https://zilt.app/index.html", .want = "zilt://app/index.html" },
        .{ .in = "https://zilt.app/app.html?x=1", .want = "zilt://app/app.html" },
        .{ .in = "https://zilt.app", .want = "zilt://app/index.html" },
        .{ .in = "https://example.com/x", .want = "https://example.com/x" },
        .{ .in = "http://localhost:5173/", .want = "http://localhost:5173/" },
        .{ .in = "", .want = "zilt://app/index.html" },
    };
    for (cases) |c| {
        const got = try resolveEntryUrl(a, c.in, "zilt", "app", "zilt.app");
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}
