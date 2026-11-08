//! 代码签名（v0.1.15）：signtool 命令构造、配置校验、指纹规范化。
//!
//! 平台无关：只产出 argv 片段与命令文本；实际执行在 `tools/bundle.zig`
//! （Windows：SearchPathW 找 signtool → spawn → 等待退出码）。
const std = @import("std");

pub const Digest = enum {
    sha1,
    sha256,
    sha384,
    sha512,

    pub fn name(self: Digest) []const u8 {
        return @tagName(self);
    }
};

pub const Options = struct {
    /// signtool.exe 路径；null = 由调用方自动发现
    signtool: ?[]const u8 = null,
    /// PFX 证书文件（与 thumbprint 二选一）
    pfx_path: ?[]const u8 = null,
    pfx_password: ?[]const u8 = null,
    /// 证书存储中的指纹（与 pfx 二选一）；大小写/空格不敏感
    cert_thumbprint: ?[]const u8 = null,
    /// RFC3161 时间戳服务；空串表示不签名时间戳（不推荐）
    timestamp_url: []const u8 = "http://timestamp.digicert.com",
    digest: Digest = .sha256,
    /// 写入签名描述（资源管理器「数字签名」页可见）
    description: ?[]const u8 = null,
    /// 描述链接
    url: ?[]const u8 = null,
};

pub const ConfigError = error{
    MissingCertificate,
    AmbiguousCertificate,
    EmptyTimestamp,
    EmptyFile,
};

/// 校验：必须且只能指定 pfx 或 thumbprint；SHA-1 摘要不允许配时间戳（signtool 限制）。
pub fn validate(opts: Options) ConfigError!void {
    const has_pfx = opts.pfx_path != null and opts.pfx_path.?.len > 0;
    const has_thumb = opts.cert_thumbprint != null and opts.cert_thumbprint.?.len > 0;
    if (has_pfx and has_thumb) return error.AmbiguousCertificate;
    if (!has_pfx and !has_thumb) return error.MissingCertificate;
    if (opts.timestamp_url.len == 0 and opts.digest != .sha1) return error.EmptyTimestamp;
}

fn needsQuotes(s: []const u8) bool {
    if (s.len == 0) return true;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '"') return true;
    }
    return false;
}

fn appendQuoted(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    if (needsQuotes(s)) {
        try out.append(alloc, '"');
        try out.appendSlice(alloc, s);
        try out.append(alloc, '"');
    } else {
        try out.appendSlice(alloc, s);
    }
}

fn appendOpt(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), flag: []const u8, value: []const u8) !void {
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, flag);
    try out.append(alloc, ' ');
    try appendQuoted(alloc, out, value);
}

/// 生成 `sign ...` 的参数串（不含 signtool.exe 本身）。
pub fn signArgs(alloc: std.mem.Allocator, opts: Options, file: []const u8) ![]u8 {
    if (file.len == 0) return error.EmptyFile;
    try validate(opts);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "sign");
    try appendOpt(alloc, &out, "/fd", opts.digest.name());

    // 非 SHA-1 时 /td 必须与 /fd 一致
    if (opts.digest != .sha1) {
        try appendOpt(alloc, &out, "/td", opts.digest.name());
        try appendOpt(alloc, &out, "/tr", opts.timestamp_url);
    } else if (opts.timestamp_url.len > 0) {
        try appendOpt(alloc, &out, "/t", opts.timestamp_url);
    }

    if (opts.pfx_path) |pfx| {
        try appendOpt(alloc, &out, "/f", pfx);
        if (opts.pfx_password) |pw| try appendOpt(alloc, &out, "/p", pw);
    } else if (opts.cert_thumbprint) |thumb| {
        const normalized = try normalizeThumbprint(alloc, thumb);
        defer alloc.free(normalized);
        try appendOpt(alloc, &out, "/sha1", normalized);
    }

    if (opts.description) |d| try appendOpt(alloc, &out, "/d", d);
    if (opts.url) |u| try appendOpt(alloc, &out, "/du", u);

    // 被签名的文件始终加引号：路径可能出现空格/特殊字符，signtool 对引号无副作用
    try out.appendSlice(alloc, " \"");
    try out.appendSlice(alloc, file);
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

/// `verify /pa /all <file>`
pub fn verifyArgs(alloc: std.mem.Allocator, file: []const u8) ![]u8 {
    if (file.len == 0) return error.EmptyFile;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "verify /pa /all ");
    try appendQuoted(alloc, &out, file);
    return out.toOwnedSlice(alloc);
}

/// 指纹规范化：去掉空格与连字符，转大写（signtool /sha1 的期望形式）。
pub fn normalizeThumbprint(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (raw) |c| {
        if (c == ' ' or c == '-' or c == ':') continue;
        try out.append(alloc, std.ascii.toUpper(c));
    }
    return out.toOwnedSlice(alloc);
}

/// 完整命令行（含 signtool.exe），便于打印给用户手动执行。
pub fn fullCommand(alloc: std.mem.Allocator, opts: Options, file: []const u8) ![]u8 {
    const args = try signArgs(alloc, opts, file);
    defer alloc.free(args);
    const tool = opts.signtool orelse "signtool.exe";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendQuoted(alloc, &out, tool);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, args);
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "validate requires exactly one certificate source" {
    try testing.expectError(error.MissingCertificate, validate(.{}));
    try testing.expectError(error.AmbiguousCertificate, validate(.{
        .pfx_path = "a.pfx",
        .cert_thumbprint = "ABCD",
    }));
    try validate(.{ .pfx_path = "a.pfx" });
    try validate(.{ .cert_thumbprint = "ABCD" });
    try testing.expectError(error.EmptyTimestamp, validate(.{ .pfx_path = "a.pfx", .timestamp_url = "" }));
}

test "pfx signing args" {
    const args = try signArgs(testing.allocator, .{
        .pfx_path = "C:\\certs\\my cert.pfx",
        .pfx_password = "s3cret",
        .timestamp_url = "http://timestamp.digicert.com",
    }, "C:\\out\\zilt-app.exe");
    defer testing.allocator.free(args);

    try testing.expect(std.mem.startsWith(u8, args, "sign /fd sha256 /td sha256 /tr"));
    try testing.expect(std.mem.indexOf(u8, args, "/f \"C:\\certs\\my cert.pfx\"") != null);
    try testing.expect(std.mem.indexOf(u8, args, "/p s3cret") != null);
    try testing.expect(std.mem.endsWith(u8, args, "\"C:\\out\\zilt-app.exe\""));
}

test "thumbprint signing normalizes and uses /sha1" {
    const args = try signArgs(testing.allocator, .{
        .cert_thumbprint = "ab cd-ef 12",
    }, "C:\\app.exe");
    defer testing.allocator.free(args);
    try testing.expect(std.mem.indexOf(u8, args, "/sha1 ABCDEF12") != null);
    try testing.expect(std.mem.indexOf(u8, args, "/f ") == null);
}

test "sha1 digest uses legacy /t timestamp" {
    const args = try signArgs(testing.allocator, .{
        .pfx_path = "a.pfx",
        .digest = .sha1,
        .timestamp_url = "http://ts.example",
    }, "a.exe");
    defer testing.allocator.free(args);
    try testing.expect(std.mem.indexOf(u8, args, "/t http://ts.example") != null);
    try testing.expect(std.mem.indexOf(u8, args, "/td ") == null);
}

test "description, url and verify args" {
    const args = try signArgs(testing.allocator, .{
        .pfx_path = "a.pfx",
        .description = "Zilt App",
        .url = "https://zilt.app",
    }, "a.exe");
    defer testing.allocator.free(args);
    try testing.expect(std.mem.indexOf(u8, args, "/d \"Zilt App\"") != null);
    try testing.expect(std.mem.indexOf(u8, args, "/du https://zilt.app") != null);

    const verify = try verifyArgs(testing.allocator, "C:\\a b\\app.exe");
    defer testing.allocator.free(verify);
    try testing.expectEqualStrings("verify /pa /all \"C:\\a b\\app.exe\"", verify);
}

test "full command quotes the tool path" {
    const cmd = try fullCommand(testing.allocator, .{
        .signtool = "C:\\Program Files (x86)\\Windows Kits\\10\\bin\\signtool.exe",
        .pfx_path = "a.pfx",
    }, "app.exe");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.startsWith(u8, cmd, "\"C:\\Program Files (x86)\\Windows Kits\\10\\bin\\signtool.exe\" sign"));
    try testing.expectError(error.EmptyFile, signArgs(testing.allocator, .{ .pfx_path = "a.pfx" }, ""));
}
