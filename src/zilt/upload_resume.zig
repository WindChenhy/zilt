//! v0.4.1 H14：断点续传分块上传协议（JSON-tus-lite）——纯函数 + 状态文件。
//!
//! 协议约定（与 scripts/http_echo.py 的 /resume-upload 端点配套）：
//!   * 分块 PATCH：请求头 `Upload-Offset: <N>`，body = 分块字节；
//!     响应体 `{"offset": <新偏移>}` 作为回执（tus 标准走响应头——本协议
//!     走响应体，规避 http.request 面无响应头读取的现状，文档化差异）
//!   * 状态文件 `<state_dir>/upload-<key 前 16 hex>.json`：
//!     `{"key":"<sha256 hex>","offset":N,"total":N}`，每块成功后原子覆盖；
//!     重启后 loadOffset 恢复（跨进程续传）
//!   * key = sha256(url ++ "\x00" ++ path)——同目标同文件的续传共享状态

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 64 hex 字符的 sha256（小写）。
pub fn stateKeyHex(alloc: Allocator, url: []const u8, path: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(url);
    h.update("\x00");
    h.update(path);
    h.final(&digest);
    return std.fmt.allocPrint(alloc, "{x}", .{&digest});
}

/// 状态文件路径：`<dir>/upload-<key 前 16 hex>.json`。
pub fn statePath(alloc: Allocator, dir: []const u8, key_hex: []const u8) ![]u8 {
    if (key_hex.len < 16) return error.InvalidKey;
    return std.fmt.allocPrint(alloc, "{s}/upload-{s}.json", .{ dir, key_hex[0..16] });
}

pub const State = struct {
    key: []const u8,
    offset: u64,
    total: u64,
    /// 服务端上传 id（PUT 初始化后获得；跨重启 PATCH 复用）
    upload_id: []const u8 = "",
};

/// 读取已持久化的续传状态。key 不匹配 / 损坏 / 缺文件 → null（从头上传）。
pub fn loadState(io: std.Io, alloc: Allocator, path: []const u8, key_hex: []const u8) ?State {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4096)) catch return null;
    defer alloc.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    const obj = parsed.value.object;
    const k = obj.get("key") orelse return null;
    if (!std.mem.eql(u8, k.string, key_hex)) return null; // 状态属于另一次上传
    const off = obj.get("offset") orelse return null;
    if (off != .integer or off.integer < 0) return null;
    const tot = obj.get("total") orelse return null;
    if (tot != .integer or tot.integer < 0) return null;
    var uid: []const u8 = "";
    if (obj.get("upload_id")) |u| {
        if (u == .string) uid = u.string;
    }
    return .{
        .key = key_hex,
        .offset = @intCast(off.integer),
        .total = @intCast(tot.integer),
        .upload_id = alloc.dupe(u8, uid) catch return null,
    };
}

/// 原子落盘（临时文件 + rename；写入失败返回错误，调用方记录日志）。
pub fn saveState(io: std.Io, alloc: Allocator, path: []const u8, st: State) !void {
    const content = try std.fmt.allocPrint(
        alloc,
        "{{\"key\":\"{s}\",\"offset\":{d},\"total\":{d},\"upload_id\":\"{s}\"}}",
        .{ st.key, st.offset, st.total, st.upload_id },
    );
    defer alloc.free(content);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = content });
    cwd.rename(tmp, cwd, path, io) catch {
        cwd.deleteFile(io, tmp) catch {};
        return error.RenameFailed;
    };
}

/// 删除状态文件（上传完成/放弃时）。
pub fn clearState(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// 分块数学：第 index 块的长度（0 = 越界）。
pub fn chunkLen(total: u64, chunk_size: u32, index: u64) u64 {
    if (chunk_size == 0) return 0;
    const start = index * @as(u64, chunk_size);
    if (start >= total) return 0;
    return @min(@as(u64, chunk_size), total - start);
}

/// 总块数（向上取整）。
pub fn chunkCount(total: u64, chunk_size: u32) u64 {
    if (chunk_size == 0 or total == 0) return 1;
    return (total + chunk_size - 1) / chunk_size;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "stateKeyHex 确定性且区分 url/path" {
    const a = try stateKeyHex(testing.allocator, "http://x/u", "/tmp/f.bin");
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 64), a.len);
    const b = try stateKeyHex(testing.allocator, "http://x/u", "/tmp/f.bin");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
    const c = try stateKeyHex(testing.allocator, "http://x/u", "/tmp/g.bin");
    defer testing.allocator.free(c);
    try testing.expect(!std.mem.eql(u8, a, c));
}

test "chunkLen/chunkCount 数学" {
    try testing.expectEqual(@as(u64, 64 * 1024), chunkLen(200 * 1024, 64 * 1024, 0));
    try testing.expectEqual(@as(u64, 8 * 1024), chunkLen(200 * 1024, 64 * 1024, 3));
    try testing.expectEqual(@as(u64, 0), chunkLen(200 * 1024, 64 * 1024, 4));
    try testing.expectEqual(@as(u64, 4), chunkCount(200 * 1024, 64 * 1024));
    try testing.expectEqual(@as(u64, 1), chunkCount(0, 64 * 1024));
    try testing.expectEqual(@as(u64, 1), chunkCount(1, 0));
}

test "state 文件保存/读取/清理（真实临时文件）" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const key = try stateKeyHex(testing.allocator, "http://x/u", "/tmp/f.bin");
    defer testing.allocator.free(key);
    const path = try statePath(testing.allocator, "/tmp", key);
    defer testing.allocator.free(path);
    defer clearState(io, path);

    try testing.expect(loadState(io, testing.allocator, path, key) == null);
    try saveState(io, testing.allocator, path, .{ .key = key, .offset = 32768, .total = 65536, .upload_id = "abc123" });
    const s1 = loadState(io, testing.allocator, path, key).?;
    defer testing.allocator.free(s1.upload_id);
    try testing.expectEqual(@as(u64, 32768), s1.offset);
    try testing.expectEqualStrings("abc123", s1.upload_id);
    try saveState(io, testing.allocator, path, .{ .key = key, .offset = 65536, .total = 65536, .upload_id = "abc123" });
    const s2 = loadState(io, testing.allocator, path, key).?;
    defer testing.allocator.free(s2.upload_id);
    try testing.expectEqual(@as(u64, 65536), s2.offset);
    clearState(io, path);
    try testing.expect(loadState(io, testing.allocator, path, key) == null);
}

test "state key 不匹配 → null（另一次上传的状态）" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const key = try stateKeyHex(testing.allocator, "http://x/u", "/tmp/f.bin");
    defer testing.allocator.free(key);
    const path = try statePath(testing.allocator, "/tmp", key);
    defer testing.allocator.free(path);
    defer clearState(io, path);
    const other = try stateKeyHex(testing.allocator, "http://x/u", "/tmp/other.bin");
    defer testing.allocator.free(other);
    try saveState(io, testing.allocator, path, .{ .key = other, .offset = 100, .total = 200 });
    try testing.expect(loadState(io, testing.allocator, path, key) == null);
}
