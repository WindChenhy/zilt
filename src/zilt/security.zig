const std = @import("std");
const fs_api = @import("fs_api.zig");

pub const ExternalLinks = enum { allow, system_browser, deny };
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Capability = struct {
    name: []const u8,
    windows: []const []const u8 = &.{"main"},
    local: bool = true,
    remote_origins: []const []const u8 = &.{},
    commands: []const []const u8 = &.{},
    events: []const []const u8 = &.{},
    receive_events: []const []const u8 = &.{},
    /// v0.1.19：资源 scope 模式（`"fs:documents/**"` / `"shell:git"` /
    /// `"http:https://api.example.com/*"`）。声明了 scopes 的能力才触发 scope 校验。
    scopes: []const []const u8 = &.{},
};
pub const Options = struct {
    csp: ?[]const u8 = null,
    headers: []const Header = &.{},
    navigation_origins: []const []const u8 = &.{},
    external_links: ExternalLinks = .deny,
    capabilities: []const Capability = &.{},
    /// 显式拒绝名单优先于任何 capability 授权（用于 E2E 验证拒绝路径）。
    deny_commands: []const []const u8 = &.{},
    deny_events: []const []const u8 = &.{},
    dev_relaxed: bool = false,
    isolation: bool = false,
    /// v0.1.21：运行时冻结 window.zilt 与内建原型（防原型链篡改）。
    freeze_prototype: bool = false,
};
pub const Direction = enum { command, event, receive_event };

const Origin = struct { scheme: []const u8, host: []const u8, port: u16 };
fn parseOrigin(url: []const u8) ?Origin {
    for (url) |c| if (c <= 0x20 or c == '\\' or c == 0x7f) return null;
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..sep];
    const secure = std.ascii.eqlIgnoreCase(scheme, "https");
    if (!secure and !std.ascii.eqlIgnoreCase(scheme, "http")) return null;
    const rest = url[sep + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "@%") != null) return null;
    var host = authority;
    var port: u16 = if (secure) 443 else 80;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        host = authority[0 .. close + 1];
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return null;
            port = std.fmt.parseInt(u16, authority[close + 2 ..], 10) catch return null;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
    }
    if (host.len == 0 or port == 0) return null;
    return .{ .scheme = scheme, .host = host, .port = port };
}
pub fn sameOrigin(a: []const u8, b: []const u8) bool {
    const x = parseOrigin(a) orelse return false;
    const y = parseOrigin(b) orelse return false;
    return std.ascii.eqlIgnoreCase(x.scheme, y.scheme) and std.ascii.eqlIgnoreCase(x.host, y.host) and x.port == y.port;
}
pub fn isWebUrl(url: []const u8) bool {
    return parseOrigin(url) != null;
}
pub fn matches(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, "*") or std.mem.eql(u8, item, name)) return true;
    return false;
}
pub fn navigation(options: Options, app_url: []const u8, dev_url: ?[]const u8, url: []const u8) ExternalLinks {
    if (!isWebUrl(url)) return .deny;
    if (sameOrigin(app_url, url)) return .allow;
    if (dev_url) |dev| if (sameOrigin(dev, url)) return .allow;
    for (options.navigation_origins) |origin| if (sameOrigin(origin, url)) return .allow;
    return options.external_links;
}
pub fn allowed(options: Options, app_url: []const u8, dev_url: ?[]const u8, source: []const u8, window: []const u8, direction: Direction, name: []const u8) bool {
    if (!isWebUrl(source)) return false;
    if (matches(switch (direction) {
        .command => options.deny_commands,
        .event, .receive_event => options.deny_events,
    }, name)) return false;
    const local = sameOrigin(source, app_url) or (if (dev_url) |dev| sameOrigin(source, dev) else false);
    if (options.dev_relaxed and dev_url != null and local and @import("builtin").mode == .debug) return true;
    for (options.capabilities) |cap| {
        if (!matches(cap.windows, window)) continue;
        var origin_allowed = cap.local and local;
        for (cap.remote_origins) |origin| if (sameOrigin(source, origin)) { origin_allowed = true; };
        if (!origin_allowed) continue;
        const names = switch (direction) { .command => cap.commands, .event => cap.events, .receive_event => cap.receive_events };
        if (matches(names, name)) return true;
    }
    return false;
}
/// v0.1.19：是否有任何 capability 声明了 scopes。
/// 没声明时保持 v0.1.16 的行为（仅应用私有目录可用），避免破坏既有项目。
pub fn scopesDeclared(options: Options) bool {
    for (options.capabilities) |cap| {
        if (cap.scopes.len != 0) return true;
    }
    return false;
}

/// v0.1.19：资源是否被授权。kind = fs/shell/http/sql…
/// 未声明任何 scope 时返回 true（opt-in）。
pub fn scopeAllowed(options: Options, kind: []const u8, resource: []const u8) bool {
    return scopeAllowedWith(options, &.{}, kind, resource);
}

/// v0.1.21：是否处于「已声明 scopes 或存在运行时授权」的强制模式。
pub fn aclEnforced(options: Options, extra: []const []const u8) bool {
    return scopesDeclared(options) or extra.len != 0;
}

/// v0.1.21：把编译期 capability scopes 与运行时持久化授权合并判断。
pub fn scopeAllowedWith(options: Options, extra: []const []const u8, kind: []const u8, resource: []const u8) bool {
    if (!aclEnforced(options, extra)) return true;
    for (options.capabilities) |cap| {
        for (cap.scopes) |pat| {
            if (matchScopePattern(pat, kind, resource)) return true;
        }
    }
    for (extra) |pat| {
        if (matchScopePattern(pat, kind, resource)) return true;
    }
    return false;
}

fn matchScopePattern(pat: []const u8, kind: []const u8, resource: []const u8) bool {
    const sep = std.mem.indexOfScalar(u8, pat, ':') orelse return false;
    if (!std.ascii.eqlIgnoreCase(pat[0..sep], kind)) return false;
    return matchScopeBody(pat[sep + 1 ..], resource);
}

fn matchScopeBody(body: []const u8, resource: []const u8) bool {
    if (body.len == 0) return false;
    // 尾部 * 当作前缀（"documents/**" → "documents/"；"https://api.x/*" → "https://api.x/"）
    if (body[body.len - 1] == '*') {
        var end = body.len;
        while (end > 0 and body[end - 1] == '*') end -= 1;
        return std.mem.startsWith(u8, resource, body[0..end]);
    }
    if (std.mem.indexOfAny(u8, body, "*?") != null) return fs_api.globMatch(body, resource);
    if (std.mem.eql(u8, body, resource)) return true;
    // 目录前缀（"documents/"）
    return body[body.len - 1] == '/' and std.mem.startsWith(u8, resource, body);
}

pub fn validateHeaders(options: Options) !void {
    if (options.csp) |csp| if (std.mem.indexOfAny(u8, csp, "\r\n\x00") != null) return error.InvalidHeader;
    for (options.headers) |header| {
        if (header.name.len == 0 or std.mem.indexOfAny(u8, header.value, "\r\n\x00") != null) return error.InvalidHeader;
        for (header.name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return error.InvalidHeader;
        for ([_][]const u8{ "Content-Type", "Content-Length", "Content-Encoding", "Content-Security-Policy", "Transfer-Encoding" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(header.name, reserved)) return error.ReservedHeader;
        }
    }
}
pub fn cspHash(alloc: std.mem.Allocator, script: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
    var encoded: [44]u8 = undefined;
    return std.fmt.allocPrint(alloc, "'sha256-{s}'", .{std.base64.standard.Encoder.encode(&encoded, &digest)});
}

test "origins reject lookalikes credentials and unsafe schemes" {
    const t = std.testing;
    try t.expect(sameOrigin("HTTPS://zilt.app:443/a", "https://zilt.app/b"));
    for ([_][]const u8{ "https://zilt.app.evil/a", "https://zilt.app@evil/a", "https://zilt.app\\@evil", "file:///x", "javascript:alert(1)", "https://zilt.app:444" }) |url| try t.expect(!sameOrigin("https://zilt.app", url));
}
test "capabilities deny by default and separate origins windows and directions" {
    const t = std.testing;
    const opts = Options{ .capabilities = &.{.{ .name = "main", .commands = &.{"greet"}, .events = &.{"ready"}, .receive_events = &.{"tick"} }} };
    try t.expect(allowed(opts, "https://zilt.app", null, "https://zilt.app/index.html", "main", .command, "greet"));
    try t.expect(!allowed(opts, "https://zilt.app", null, "https://remote.test", "main", .command, "greet"));
    try t.expect(!allowed(opts, "https://zilt.app", null, "https://zilt.app", "child", .command, "greet"));
    try t.expect(!allowed(opts, "https://zilt.app", null, "https://zilt.app", "main", .event, "greet"));
    try t.expect(!allowed(.{}, "https://zilt.app", null, "https://zilt.app", "main", .command, "greet"));
    const denied = Options{
        .capabilities = &.{.{ .name = "all", .commands = &.{"*"}, .events = &.{"*"} }},
        .deny_commands = &.{"blockedDemo"},
        .deny_events = &.{"blockedEvent"},
    };
    try t.expect(allowed(denied, "https://zilt.app", null, "https://zilt.app", "main", .command, "greet"));
    try t.expect(!allowed(denied, "https://zilt.app", null, "https://zilt.app", "main", .command, "blockedDemo"));
    try t.expect(!allowed(denied, "https://zilt.app", null, "https://zilt.app", "main", .event, "blockedEvent"));
}
test "navigation policy: app/dev/whitelist allow, external links configurable, unsafe schemes deny" {
    const t = std.testing;
    const opts = Options{
        .navigation_origins = &.{"https://docs.example"},
        .external_links = .system_browser,
    };
    try t.expectEqual(ExternalLinks.allow, navigation(opts, "https://zilt.app/index.html", null, "https://zilt.app/deep/route"));
    try t.expectEqual(ExternalLinks.allow, navigation(opts, "https://zilt.app", "http://localhost:5173", "http://localhost:5173/src/main.js"));
    try t.expectEqual(ExternalLinks.allow, navigation(opts, "https://zilt.app", null, "https://docs.example/guide"));
    try t.expectEqual(ExternalLinks.system_browser, navigation(opts, "https://zilt.app", null, "https://other.example"));
    try t.expectEqual(ExternalLinks.deny, navigation(opts, "https://zilt.app", null, "javascript:alert(1)"));
    try t.expectEqual(ExternalLinks.deny, navigation(.{ .external_links = .deny }, "https://zilt.app", null, "https://other.example"));
}

test "headers reject injection and CSP hash is stable" {
    try std.testing.expectError(error.InvalidHeader, validateHeaders(.{ .headers = &.{.{ .name = "X-Test", .value = "ok\r\nInjected: yes" }} }));
    const hash = try cspHash(std.testing.allocator, "");
    defer std.testing.allocator.free(hash);
    try std.testing.expectEqualStrings("'sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU='", hash);
}

test "v0.1.19: scope opt-in and matching" {
    const no_scopes_caps = [_]Capability{.{ .name = "main", .commands = &.{"a"} }};
    const no_scopes = Options{ .capabilities = &no_scopes_caps };
    try std.testing.expect(!scopesDeclared(no_scopes));
    try std.testing.expect(scopeAllowed(no_scopes, "fs", "documents/secret.txt"));

    const caps = [_]Capability{
        .{ .name = "main", .scopes = &.{ "fs:documents/**", "fs:appData/**", "shell:git", "http:https://api.example.com/*" } },
    };
    const opts = Options{ .capabilities = &caps };
    try std.testing.expect(scopesDeclared(opts));
    try std.testing.expect(scopeAllowed(opts, "fs", "documents/notes/a.txt"));
    try std.testing.expect(scopeAllowed(opts, "fs", "appData/store.json"));
    try std.testing.expect(!scopeAllowed(opts, "fs", "downloads/x.zip"));
    try std.testing.expect(!scopeAllowed(opts, "fs", "home/Desktop/x"));
    try std.testing.expect(scopeAllowed(opts, "shell", "git"));
    try std.testing.expect(!scopeAllowed(opts, "shell", "powershell"));
    try std.testing.expect(scopeAllowed(opts, "http", "https://api.example.com/v1/x"));
    try std.testing.expect(!scopeAllowed(opts, "http", "https://evil.example.com/x"));
    try std.testing.expect(!scopeAllowed(opts, "sql", "app.db"));
}

test "v0.1.21: runtime grants extend capability scopes" {
    const caps = [_]Capability{
        .{ .name = "main", .scopes = &.{"fs:appData/**"} },
    };
    const opts = Options{ .capabilities = &caps };
    try std.testing.expect(aclEnforced(opts, &.{}));
    try std.testing.expect(scopeAllowedWith(opts, &.{}, "fs", "appData/a.txt"));
    try std.testing.expect(!scopeAllowedWith(opts, &.{}, "fs", "documents/a.txt"));
    // 运行时授权后放行
    const grants = [_][]const u8{"fs:documents/**"};
    try std.testing.expect(scopeAllowedWith(opts, &grants, "fs", "documents/a.txt"));
    try std.testing.expect(!scopeAllowedWith(opts, &grants, "fs", "downloads/a.txt"));
    // 没有编译期 scopes、只有运行时授权 → 也进入强制模式
    const empty = Options{};
    try std.testing.expect(!aclEnforced(empty, &.{}));
    try std.testing.expect(scopeAllowedWith(empty, &.{}, "fs", "anything"));
    try std.testing.expect(!scopeAllowedWith(empty, &grants, "fs", "downloads/a.txt"));
    try std.testing.expect(scopeAllowedWith(empty, &grants, "fs", "documents/a.txt"));
}
