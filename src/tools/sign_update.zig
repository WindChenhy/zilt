//! 更新包签名：`ZILT_SIGN_FILE=<安装包路径> ZILT_SIGN_KEY=<64hex种子> zig-out/bin/zilt-sign`
//! 输出可直接使用的 manifest JSON（url/version 字段需手动填）。

const std = @import("std");

// 自带最小 Win32 助手（独立工具，不依赖 zilt 模块）
const DWORD = u32;
const BOOL = i32;
const HANDLE = *anyopaque;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.c) DWORD;
pub extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?*anyopaque) callconv(.c) HANDLE;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.c) BOOL;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;

/// v0.1.23：三份拷贝合一（实现见 win_env.zig）。
const getEnv = @import("win_env.zig").get;

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return null;
    defer alloc.free(pw);
    const GENERIC_READ: DWORD = 0x80000000;
    const OPEN_EXISTING: DWORD = 3;
    const f = CreateFileW(pw.ptr, GENERIC_READ, 1, null, OPEN_EXISTING, 0x80, null);
    if (f == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(f);
    var size: i64 = 0;
    if (GetFileSizeEx(f, &size) == 0 or size < 0 or size > 256 * 1024 * 1024) return null;
    const buf = alloc.alloc(u8, @intCast(size)) catch return null;
    var total: DWORD = 0;
    while (total < buf.len) {
        var got: DWORD = 0;
        if (ReadFile(f, buf.ptr + total, @intCast(buf.len - total), &got, null) == 0 or got == 0) {
            alloc.free(buf);
            return null;
        }
        total += got;
    }
    return buf;
}

fn hexLower(out: *[64]u8, bytes: []const u8) void {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    const alloc = gpa_state.allocator();

    const file_path = getEnv(alloc, "ZILT_SIGN_FILE") orelse {
        std.debug.print("error: set ZILT_SIGN_FILE\n", .{});
        return error.MissingArgs;
    };
    defer alloc.free(file_path);
    const key_hex = getEnv(alloc, "ZILT_SIGN_KEY") orelse {
        std.debug.print("error: set ZILT_SIGN_KEY (64 hex chars)\n", .{});
        return error.MissingArgs;
    };
    defer alloc.free(key_hex);
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

    const artifact = readFileAlloc(alloc, file_path) orelse {
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
