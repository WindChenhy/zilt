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
