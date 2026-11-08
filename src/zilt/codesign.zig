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

// ---------------------------------------------------------------------------
// 凭据来源（对齐 Tauri / Wails 的 CI 友好做法）
//
// Tauri：WINDOWS_CERTIFICATE（base64 PFX）+ WINDOWS_CERTIFICATE_PASSWORD
// Wails：SIGN_CERTIFICATE 路径 / SIGN_THUMBPRINT，密码进系统钥匙串
// 这里两种都支持：路径、base64（给 CI secret）、指纹（证书已在存储）。
// ---------------------------------------------------------------------------

pub const Source = enum {
    /// 已解压的 .pfx 文件路径
    pfx_path,
    /// base64 编码的 .pfx（CI secret 常见形态）
    pfx_base64,
    /// 证书已在当前用户/机器证书存储中
    thumbprint,
};

/// 按优先级挑选凭据来源；都为空返回 null（调用方应跳过签名）。
/// 显式文件路径优先于 base64（更可控），两者都优先于指纹。
pub fn pickSource(pfx_path: ?[]const u8, pfx_base64: ?[]const u8, thumbprint: ?[]const u8) ?Source {
    if (nonBlank(pfx_path)) return .pfx_path;
    if (nonBlank(pfx_base64)) return .pfx_base64;
    if (nonBlank(thumbprint)) return .thumbprint;
    return null;
}

fn nonBlank(v: ?[]const u8) bool {
    const s = v orelse return false;
    return std.mem.trim(u8, s, " \t\r\n").len > 0;
}

/// 解码 base64 的 PFX。容忍：
///   - 折行/空格/CRLF（secret 里粘贴常被折行）
///   - 缺失的尾部 padding
///   - PEM 头尾（`certutil -encode` 的产物）
pub fn decodePfxBase64(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const body = stripPemArmor(std.mem.trim(u8, input, " \t\r\n"));

    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(alloc);
    for (body) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
        try clean.append(alloc, c);
    }
    if (clean.items.len == 0) return error.EmptyInput;

    // 补齐 padding：长度必须是 4 的倍数，否则解码器直接报错
    const pad = (4 - clean.items.len % 4) % 4;
    for (0..pad) |_| try clean.append(alloc, '=');

    const dec = std.base64.standard.Decoder;
    const size = try dec.calcSizeForSlice(clean.items);
    const out = try alloc.alloc(u8, size);
    errdefer alloc.free(out);
    try dec.decode(out, clean.items);
    return out;
}

fn stripPemArmor(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    if (std.mem.startsWith(u8, s, "-----BEGIN")) {
        if (std.mem.indexOfScalar(u8, s, '\n')) |nl| start = nl + 1;
    }
    if (std.mem.lastIndexOf(u8, s, "-----END")) |idx| {
        if (idx > start) end = idx;
    }
    return s[start..end];
}

test "pickSource: path beats base64 beats thumbprint, blanks ignored" {
    try testing.expectEqual(Source.pfx_path, pickSource("a.pfx", "AAAA", "ABCD").?);
    try testing.expectEqual(Source.pfx_base64, pickSource(null, "AAAA", "ABCD").?);
    try testing.expectEqual(Source.pfx_base64, pickSource("  ", "AAAA", "ABCD").?);
    try testing.expectEqual(Source.thumbprint, pickSource(null, null, "ABCD").?);
    try testing.expectEqual(@as(?Source, null), pickSource(null, null, null));
    try testing.expectEqual(@as(?Source, null), pickSource("", "  \n", ""));
}

test "decodePfxBase64 handles plain, wrapped and unpadded input" {
    const a = testing.allocator;
    // "hello" 的 base64
    const expect = "hello";

    const plain = try decodePfxBase64(a, "aGVsbG8=");
    defer a.free(plain);
    try testing.expectEqualStrings(expect, plain);

    // 折行 + CRLF
    const wrapped = try decodePfxBase64(a, "aGVs\r\nbG8=\n");
    defer a.free(wrapped);
    try testing.expectEqualStrings(expect, wrapped);

    // 丢掉 padding
    const unpadded = try decodePfxBase64(a, "aGVsbG8");
    defer a.free(unpadded);
    try testing.expectEqualStrings(expect, unpadded);
}

test "decodePfxBase64 strips PEM armor" {
    const a = testing.allocator;
    const pem =
        \\-----BEGIN PKCS12-----
        \\aGVsbG8=
        \\-----END PKCS12-----
    ;
    const out = try decodePfxBase64(a, pem);
    defer a.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "decodePfxBase64 rejects empty payload" {
    const a = testing.allocator;
    try testing.expectError(error.EmptyInput, decodePfxBase64(a, "   \n\t "));
}
