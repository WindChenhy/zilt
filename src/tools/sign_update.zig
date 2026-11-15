//! 更新包签名：`ZILT_SIGN_FILE=<安装包路径> ZILT_SIGN_KEY=<64hex种子> zig-out/bin/zilt-sign`
//! 输出可直接使用的 manifest JSON（url/version 字段需手动填）。
//!
//! v0.3.1：跨平台（Windows/Linux 共用）——env 走 Init.environ_map，文件走 std.Io。

const std = @import("std");

fn hexLower(out: *[64]u8, bytes: []const u8) void {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

pub fn main(init: std.process.Init) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    const alloc = gpa_state.allocator();
    const io = init.io;

    const file_path = init.environ_map.get("ZILT_SIGN_FILE") orelse {
        std.debug.print("error: set ZILT_SIGN_FILE\n", .{});
        return error.MissingArgs;
    };
    const key_hex = init.environ_map.get("ZILT_SIGN_KEY") orelse {
        std.debug.print("error: set ZILT_SIGN_KEY (64 hex chars)\n", .{});
        return error.MissingArgs;
    };
    if (key_hex.len != 64) {
        std.debug.print("error: ZILT_SIGN_KEY must be 64 hex chars\n", .{});
        return error.BadKey;
    }

    var seed: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&seed, key_hex) catch {
        std.debug.print("error: bad hex in ZILT_SIGN_KEY\n", .{});
        return error.BadKey;
    };
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    const artifact = std.Io.Dir.cwd().readFileAlloc(io, file_path, alloc, .limited(256 * 1024 * 1024)) catch {
        std.debug.print("error: cannot read {s}\n", .{file_path});
        return error.ReadFileFailed;
    };
    defer alloc.free(artifact);

    const sig = try kp.sign(artifact, null);
    const enc = std.base64.standard.Encoder;
    const sig_b64_buf = try alloc.alloc(u8, enc.calcSize(sig.toBytes().len));
    defer alloc.free(sig_b64_buf);
    _ = enc.encode(sig_b64_buf, &sig.toBytes());

    var sha_buf: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(artifact, &sha_buf, .{});
    var sha_hex: [64]u8 = undefined;
    hexLower(&sha_hex, &sha_buf);

    std.debug.print(
        \\{{
        \\  "version": "<填新版本号>",
        \\  "notes": "<更新说明>",
        \\  "pub_date": "<RFC3339 时间>",
        \\  "url": "<安装包下载 URL>",
        \\  "sha256": "{s}",
        \\  "signature": "{s}"
        \\}}
        \\
    , .{ sha_hex, sig_b64_buf });
}
