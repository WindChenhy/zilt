//! 单实例保护：命名互斥体。第二实例立即退出（退出码 5）。

const std = @import("std");
const win32 = @import("win32.zig");
const tray = @import("tray.zig");

pub const SECOND_INSTANCE_EXIT_CODE: u8 = 5;

pub const Guard = struct {
    handle: win32.HANDLE,
    name: []u8,
    allocator: std.mem.Allocator,

    /// 尝试持有单实例锁。返回 null = 已有实例在运行（调用方应退出）。
    pub fn acquire(allocator: std.mem.Allocator, app_id: []const u8) ?Guard {
        const name = tray.singleInstanceMutexName(allocator, app_id) catch return null;
        const name_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, name) catch {
            allocator.free(name);
            return null;
        };
        defer allocator.free(name_w);

        const h = win32.CreateMutexW(null, 0, name_w.ptr);
        if (h == win32.INVALID_HANDLE_VALUE) {
            allocator.free(name);
            return null;
        }
        if (win32.GetLastError() == win32.ERROR_ALREADY_EXISTS) {
            _ = win32.CloseHandle(h);
            allocator.free(name);
            return null;
        }
        return .{ .handle = h, .name = name, .allocator = allocator };
    }

    pub fn release(self: *Guard) void {
        _ = win32.CloseHandle(self.handle);
        self.allocator.free(self.name);
    }
};

// ---------------------------------------------------------------------------
// v0.3.16 G22：第二实例数据 HMAC 加固（Wails SingleInstanceOptions.EncryptionKey
// 对齐——AES-256-GCM 换成项目已有的 HMAC-SHA256 基建）。Config.single_instance_key
// 设置后：WM_COPYDATA 载荷从明文升级为 {n,s,p} 密封形态——n=16B 随机 nonce hex、
// s=HMAC-SHA256(key, payload||nonce) hex、p=载荷原样字节。明文载荷在启用密钥时
// 一律拒绝（伪造路径：本机任意进程可 SendMessage 伪启动参数 → 深链/文件打开被
// 劫持；密封后攻击者无密钥不可伪造）。
// ---------------------------------------------------------------------------

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const SealError = error{ InvalidKey, InvalidFormat, BadSignature };

/// 解析 64 字符 hex → 32 字节密钥（与 isolation.keyFromHex 同语义）。
fn keyFromHex(hex: []const u8) SealError![32]u8 {
    if (hex.len != 64) return SealError.InvalidKey;
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, hex) catch return SealError.InvalidKey;
    return key;
}

/// 密封第二实例载荷（alloc 拥有返回值）："zilt1|<n>|<s>|<payload>"。
/// payload 为原样字节（deep_link.parsePayload 的 JSON），nonce 随机防重放。
pub fn sealPayload(alloc: std.mem.Allocator, key_hex: []const u8, payload: []const u8, nonce: [16]u8) SealError![]u8 {
    const key = try keyFromHex(key_hex);
    var nonce_hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&nonce_hex, "{x:0>2}{x:0>2}", .{ nonce[0..8], nonce[8..16] }) catch unreachable;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, payload, &key);
    var mac_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&mac_hex, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ mac[0..8], mac[8..16], mac[16..24], mac[24..32] }) catch unreachable;
    // nonce_hex 是 64 字符（每字节 2 hex × 16B）——修正：32 字符
    return std.fmt.allocPrint(alloc, "zilt1|{s}|{s}|{s}", .{ nonce_hex[0..32], mac_hex, payload });
}

/// 验封：校验前缀 + HMAC；成功返回载荷副本（alloc 拥有），失败返回 null。
pub fn openPayload(alloc: std.mem.Allocator, key_hex: []const u8, sealed: []const u8) ?[]u8 {
    const key = keyFromHex(key_hex) catch {
        std.log.warn("[single-instance] seal key invalid — payload rejected", .{});
        return null;
    };
    const prefix = "zilt1|";
    if (!std.mem.startsWith(u8, sealed, prefix)) {
        std.log.warn("[single-instance] plaintext payload rejected (sealing required)", .{});
        return null;
    }
    var it = std.mem.splitScalar(u8, sealed[prefix.len..], '|');
    const nonce_hex = it.next() orelse return null;
    const mac_hex = it.next() orelse return null;
    const payload = it.next() orelse return null;
    if (nonce_hex.len != 32 or mac_hex.len != 64) return null;

    var nonce: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&nonce, nonce_hex) catch return null;
    var want: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&want, payload, &key);
    var got: [Hmac.mac_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&got, mac_hex) catch return null;
    if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, got, want)) {
        std.log.warn("[single-instance] HMAC mismatch — payload rejected", .{});
        return null;
    }
    return alloc.dupe(u8, payload) catch null;
}

test "seal/open roundtrip and tamper rejection" {
    const t = std.testing;
    const alloc = t.allocator;
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const nonce: [16]u8 = @splat(0xAB);
    const sealed = try sealPayload(alloc, key, "deepLink|hello", nonce);
    defer alloc.free(sealed);
    const opened = openPayload(alloc, key, sealed) orelse return error.TestExpectedEqual;
    defer alloc.free(opened);
    try t.expectEqualStrings("deepLink|hello", opened);
    // 篡改载荷 → HMAC 不匹配
    const tampered = try std.fmt.allocPrint(alloc, "zilt1|{s}|{s}|EVIL", .{ sealed[6..38], sealed[39..103] });
    defer alloc.free(tampered);
    try t.expect(openPayload(alloc, key, tampered) == null);
    // 明文载荷在启用密封时拒绝
    try t.expect(openPayload(alloc, key, "deepLink|plaintext") == null);
    // 非法密钥
    try t.expectError(SealError.InvalidKey, sealPayload(alloc, "short", "x", nonce));
}

test "seal payload structure fields" {
    const alloc = std.testing.allocator;
    const key = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    const sealed = try sealPayload(alloc, key, "abc", @splat(1));
    defer alloc.free(sealed);
    try std.testing.expect(std.mem.startsWith(u8, sealed, "zilt1|"));
    // n(32 hex) + s(64 hex) + 载荷，三段以 | 分隔
    var it = std.mem.splitScalar(u8, sealed["zilt1|".len..], '|');
    try std.testing.expectEqual(@as(usize, 32), it.next().?.len);
    try std.testing.expectEqual(@as(usize, 64), it.next().?.len);
    try std.testing.expectEqualStrings("abc", it.next().?);
}
