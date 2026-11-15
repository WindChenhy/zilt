//! 更新签名密钥对生成：`zig-out/bin/zilt-keygen`
//! 输出 PUBLIC_KEY_HEX（进应用 config.update.public_key_hex）
//!     与 SECRET_KEY_HEX（签名时经 ZILT_SIGN_KEY 传入，妥善保管）。
//!
//! v0.3.1：跨平台——熵源改用 std.Io.random（Windows 原 BCryptGenRandom）。

const std = @import("std");

fn hexLower(out: *[64]u8, bytes: []const u8) void {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

pub fn main(init: std.process.Init) !void {
    var seed: [32]u8 = undefined;
    std.Io.random(init.io, &seed);

    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    var pk_hex: [64]u8 = undefined;
    var sk_hex: [64]u8 = undefined;
    hexLower(&pk_hex, &kp.public_key.bytes);
    hexLower(&sk_hex, &seed);
    std.debug.print("PUBLIC_KEY_HEX={s}\n", .{pk_hex});
    std.debug.print("SECRET_KEY_HEX={s}\n", .{sk_hex});
}
