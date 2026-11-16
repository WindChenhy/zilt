//! DPAPI 加密（v0.3.5，Windows 独占）：CryptProtectData/CryptUnprotectData
//! （crypt32 动态加载，对齐 sqlite/winhttp 的运行时解析模式）。
//!
//! 语义：当前用户作用域（CRYPTPROTECT_UI_FORBIDDEN；无熵附加）——加密后的数据
//! 只能在同一 Windows 用户 + 同一机器上解密。落盘格式：`dpapi:` 前缀 + base64
//! （store 值以该前缀标记加密形态，读取时自动解密）。
//!
//! 平台差异：Linux 无 DPAPI（libsecret 列为 v0.4+）——加密开关在 Linux 忽略
//! （值明文落盘，文档化）。
const std = @import("std");
const win32 = @import("win32.zig");

pub const prefix = "dpapi:";

/// DATA_BLOB（crypt32 ABI：cbData + pbData）
const Blob = extern struct {
    cb_data: win32.DWORD,
    pb_data: ?*anyopaque,
};

var crypt32_mod: ?win32.HMODULE = null;
var crypt32_resolved = false;

const ProtectDataFn = *const fn (
    pDataIn: *const Blob,
    szDataDescr: ?[*:0]const u16,
    pOptionalEntropy: ?*const Blob,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: win32.DWORD,
    pDataOut: *Blob,
) callconv(.winapi) win32.BOOL;

const CRYPTPROTECT_UI_FORBIDDEN: win32.DWORD = 0x1;

fn resolve() ?struct { protect: ProtectDataFn, unprotect: ProtectDataFn } {
    if (crypt32_resolved) {
        const mod = crypt32_mod orelse return null;
        const protect = win32.GetProcAddress(mod, "CryptProtectData") orelse return null;
        const unprotect = win32.GetProcAddress(mod, "CryptUnprotectData") orelse return null;
        return .{
            .protect = @ptrCast(@alignCast(protect)),
            .unprotect = @ptrCast(@alignCast(unprotect)),
        };
    }
    crypt32_resolved = true;
    const mod = win32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("crypt32.dll")) orelse {
        crypt32_mod = null;
        return null;
    };
    crypt32_mod = mod;
    const protect = win32.GetProcAddress(mod, "CryptProtectData") orelse return null;
    const unprotect = win32.GetProcAddress(mod, "CryptUnprotectData") orelse return null;
    return .{
        .protect = @ptrCast(@alignCast(protect)),
        .unprotect = @ptrCast(@alignCast(unprotect)),
    };
}

pub fn available() bool {
    return resolve() != null;
}

/// 加密为 `dpapi:` + base64（调用方 free 返回值）。
pub fn encrypt(alloc: std.mem.Allocator, plaintext: []const u8) ![]u8 {
    const api = resolve() orelse return error.DpapiUnavailable;
    const blob_in = Blob{
        .cb_data = @intCast(plaintext.len),
        .pb_data = @constCast(@ptrCast(plaintext.ptr)),
    };
    var blob_out: Blob = .{ .cb_data = 0, .pb_data = null };
    if (api.protect(&blob_in, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &blob_out) == 0) {
        return error.DpapiProtectFailed;
    }
    defer _ = win32.LocalFree(@ptrCast(blob_out.pb_data));
    const encrypted = blob_out.pb_data orelse return error.DpapiProtectFailed;
    const bytes = @as([*]const u8, @ptrCast(encrypted))[0..blob_out.cb_data];
    const encoder = std.base64.standard.Encoder;
    const b64 = try alloc.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(b64, bytes);
    defer alloc.free(b64);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, b64 });
}

/// 解密 `dpapi:` 前缀值（非前缀值原样返回拷贝——混合形态 store 兼容）。
pub fn decrypt(alloc: std.mem.Allocator, stored: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, stored, prefix)) {
        return alloc.dupe(u8, stored);
    }
    const api = resolve() orelse return error.DpapiUnavailable;
    const b64 = stored[prefix.len..];
    const decoder = std.base64.standard.Decoder;
    const bin_len = decoder.calcSizeForSlice(b64) catch return error.DpapiDecodeFailed;
    const bin = try alloc.alloc(u8, bin_len);
    defer alloc.free(bin);
    decoder.decode(bin, b64) catch return error.DpapiDecodeFailed;
    const blob_in = Blob{ .cb_data = @intCast(bin.len), .pb_data = @ptrCast(bin.ptr) };
    var blob_out: Blob = .{ .cb_data = 0, .pb_data = null };
    if (api.unprotect(&blob_in, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &blob_out) == 0) {
        return error.DpapiUnprotectFailed;
    }
    defer _ = win32.LocalFree(@ptrCast(blob_out.pb_data));
    const plain = blob_out.pb_data orelse return error.DpapiUnprotectFailed;
    return alloc.dupe(u8, @as([*]const u8, @ptrCast(plain))[0..blob_out.cb_data]);
}

const testing = std.testing;

test "v0.3.5: DPAPI 前缀判定（纯逻辑）" {
    try testing.expect(std.mem.startsWith(u8, "dpapi:AAAA", prefix));
    try testing.expect(!std.mem.startsWith(u8, "plaintext", prefix));
}

test "v0.3.5: DPAPI encrypt/decrypt 往返（真实 crypt32；不可用则 SKIP）" {
    if (!available()) {
        std.debug.print("crypt32 unavailable — SKIP\n", .{});
        return error.SkipZigTest;
    }
    const alloc = testing.allocator;
    const secret = "dpapi-roundtrip-secret-0.3.5";
    const encrypted = try encrypt(alloc, secret);
    defer alloc.free(encrypted);
    try testing.expect(std.mem.startsWith(u8, encrypted, prefix));
    try testing.expect(std.mem.indexOf(u8, encrypted, secret) == null); // 密文不含明文
    const decrypted = try decrypt(alloc, encrypted);
    defer alloc.free(decrypted);
    try testing.expectEqualStrings(secret, decrypted);
    // 非前缀值原样返回
    const plain = try decrypt(alloc, "plain-value");
    defer alloc.free(plain);
    try testing.expectEqualStrings("plain-value", plain);
}
