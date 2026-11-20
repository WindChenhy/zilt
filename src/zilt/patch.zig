//! v0.1.5 增量/差分更新：自研 zilt-patch v1 二进制差分格式（纯 Zig）。
//!
//! 格式（小端）：
//!   magic   "ZILTPATCH1"（10 字节）
//!   u64     new_size（重建后文件大小）
//!   u8[32]  new_sha256（重建后内容摘要——应用后强校验，基线错误/损坏必被拦截）
//!   ops...直到 EOF：
//!     0x01 COPY    u64 old_offset, u64 len      （从旧文件对应偏移拷贝 len 字节）
//!     0x02 LITERAL u64 len, len bytes           （内联字面量）
//!
//! 生成策略（buildPatch）：旧文件按 4KiB 对齐块建哈希索引，新文件贪心匹配——
//! 命中则整段 COPY（向后延伸至失配），未命中累积 LITERAL。未对齐/移位内容退化为
//! LITERAL（正确性不受影响）。典型应用更新（大部分块未变）PATCH 体积为全量的百分位。
//!
//! 正确性三重防线：补丁文件本身有 sha256+ed25519（manifest.patch 字段，验签在
//! updater 流程）；重建结果与头部 new_sha256 比对；结果与 manifest 全量 sha256/
//! signature 复核（updaterFlow）。

const std = @import("std");

const testing = std.testing;

pub const magic = "ZILTPATCH1";
pub const block_size = 4096;

pub const PatchError = error{
    PatchInvalid,
    PatchChecksumMismatch,
    OutOfMemory,
};

fn readU64(bytes: []const u8, pos: usize) PatchError!u64 {
    if (pos + 8 > bytes.len) return error.PatchInvalid;
    return std.mem.readInt(u64, bytes[pos..][0..8], .little);
}

/// 从补丁字节流重建新文件（old 为基线内容）。结果用调用方 allocator 分配。
pub fn applyPatch(alloc: std.mem.Allocator, old: []const u8, patch: []const u8) PatchError![]u8 {
    if (patch.len < 10 + 8 + 32 or !std.mem.eql(u8, patch[0..10], magic))
        return error.PatchInvalid;
    const new_size: usize = @intCast(try readU64(patch, 10));
    const expect_sha: [32]u8 = patch[18..50][0..32].*;

    var out = try alloc.alloc(u8, new_size);
    errdefer alloc.free(out);
    @memset(out, 0xAA); // 填充哨兵：漏拷贝区域在 sha 校验时暴露

    var pos: usize = 50; // ops 起点
    var out_pos: usize = 0;
    while (pos < patch.len) {
        const op = patch[pos];
        pos += 1;
        switch (op) {
            0x01 => { // COPY
                const off: usize = @intCast(try readU64(patch, pos));
                const len: usize = @intCast(try readU64(patch, pos + 8));
                pos += 16;
                if (off + len > old.len or out_pos + len > new_size) return error.PatchInvalid;
                @memcpy(out[out_pos..][0..len], old[off..][0..len]);
                out_pos += len;
            },
            0x02 => { // LITERAL
                const len: usize = @intCast(try readU64(patch, pos));
                pos += 8;
                if (pos + len > patch.len or out_pos + len > new_size) return error.PatchInvalid;
                @memcpy(out[out_pos..][0..len], patch[pos..][0..len]);
                pos += len;
                out_pos += len;
            },
            else => return error.PatchInvalid,
        }
    }
    if (out_pos != new_size) return error.PatchInvalid;

    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out, &actual, .{});
    if (!std.mem.eql(u8, &actual, &expect_sha)) return error.PatchChecksumMismatch;
    return out;
}

/// 生成补丁（old → new）。确定性输出（同输入同补丁）。
pub fn buildPatch(alloc: std.mem.Allocator, old: []const u8, new: []const u8) PatchError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, magic);
    var size_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &size_buf, new.len, .little);
    try out.appendSlice(alloc, &size_buf);
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(new, &sha, .{});
    try out.appendSlice(alloc, &sha);

    // 旧文件 4KiB 块哈希索引（对齐块；FNV-1a 64 足够初筛 + 字节精比兜底）
    var index = std.AutoHashMap(u64, std.ArrayList(usize)).init(alloc);
    defer {
        var it = index.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        index.deinit();
    }
    if (old.len >= block_size) {
        var off: usize = 0;
        while (off + block_size <= old.len) : (off += block_size) {
            const h = std.hash.Fnv1a_64.hash(old[off..][0..block_size]);
            const gop = try index.getOrPut(h);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(alloc, off);
        }
    }

    var literal_start: usize = 0; // new 中的字面量累积起点
    var i: usize = 0;
    var buf: [8]u8 = undefined;
    while (i < new.len) {
        var matched_len: usize = 0;
        var matched_off: usize = 0;
        if (i + block_size <= new.len) {
            const h = std.hash.Fnv1a_64.hash(new[i..][0..block_size]);
            if (index.get(h)) |offs| {
                for (offs.items) |o| {
                    if (!std.mem.eql(u8, old[o..][0..block_size], new[i..][0..block_size])) continue;
                    // 精比通过 → 向后延伸
                    var l: usize = block_size;
                    while (o + l < old.len and i + l < new.len and old[o + l] == new[i + l]) l += 1;
                    // 保持 4KiB 对齐：COPY 只在块边界收尾（除非已到 new 末尾）。否则一次
                    // 块内改动会让 i 相对块栅格漂移，后续块再也命中不了旧文件的块索引，
                    // 剩余内容整段退化为 LITERAL（200KB 文件改 100 字节 → 150KB 补丁）。
                    if (i + l != new.len) l = l / block_size * block_size;
                    if (l > matched_len) {
                        matched_len = l;
                        matched_off = o;
                    }
                }
            }
        }

        if (matched_len >= block_size) {
            // 先冲刷累积字面量
            if (i > literal_start) try appendLiteral(&out, alloc, new[literal_start..i]);
            try out.append(alloc, 0x01);
            std.mem.writeInt(u64, &buf, matched_off, .little);
            try out.appendSlice(alloc, &buf);
            std.mem.writeInt(u64, &buf, matched_len, .little);
            try out.appendSlice(alloc, &buf);
            i += matched_len;
            literal_start = i;
        } else {
            i += block_size; // 字面量按块步进（简单、够用）
        }
    }
    if (new.len > literal_start) try appendLiteral(&out, alloc, new[literal_start..new.len]);

    return out.toOwnedSlice(alloc);
}

fn appendLiteral(out: *std.ArrayList(u8), alloc: std.mem.Allocator, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    var buf: [8]u8 = undefined;
    try out.append(alloc, 0x02);
    std.mem.writeInt(u64, &buf, bytes.len, .little);
    try out.appendSlice(alloc, &buf);
    try out.appendSlice(alloc, bytes);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

fn randomBytes(alloc: std.mem.Allocator, n: usize, seed: u32) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const b = try alloc.alloc(u8, n);
    r.bytes(b);
    return b;
}

test "buildPatch/applyPatch: 完全相同（全 COPY）" {
    const old = try randomBytes(testing.allocator, 100_000, 1);
    defer testing.allocator.free(old);
    const patch = try buildPatch(testing.allocator, old, old);
    defer testing.allocator.free(patch);
    try testing.expect(patch.len < 10_000); // 全量 100KB → 补丁应极小

    const back = try applyPatch(testing.allocator, old, patch);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, old, back);
}

test "buildPatch/applyPatch: 小改动（大部分 COPY）" {
    const old = try randomBytes(testing.allocator, 200_000, 2);
    defer testing.allocator.free(old);
    const new = try testing.allocator.dupe(u8, old);
    defer testing.allocator.free(new);
    @memset(new[50_000..50_100], 0x5A); // 100 字节改动（原字面量仅 41 字节 → 编译期长度不符）
    const patch = try buildPatch(testing.allocator, old, new);
    defer testing.allocator.free(patch);
    try testing.expect(patch.len < 20_000); // 远小于全量

    const back = try applyPatch(testing.allocator, old, patch);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, new, back);
}

test "buildPatch/applyPatch: 全新内容（全 LITERAL）+ 追加尾部" {
    const old = try randomBytes(testing.allocator, 10_000, 3);
    defer testing.allocator.free(old);
    const new = try randomBytes(testing.allocator, 30_000, 4);
    defer testing.allocator.free(new);

    const patch = try buildPatch(testing.allocator, old, new);
    defer testing.allocator.free(patch);
    const back = try applyPatch(testing.allocator, old, patch);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, new, back);
}

test "applyPatch: 基线错误 → sha256 拦截" {
    const old_a = try randomBytes(testing.allocator, 50_000, 5);
    defer testing.allocator.free(old_a);
    const old_b = try randomBytes(testing.allocator, 50_000, 6); // 同长度、不同内容
    defer testing.allocator.free(old_b);
    // 补丁必须含 COPY 才能检验基线：全 LITERAL 补丁与基线无关（重建结果仍正确）
    const new = try testing.allocator.dupe(u8, old_a);
    defer testing.allocator.free(new);
    new[1000] ^= 0xFF;

    const patch = try buildPatch(testing.allocator, old_a, new);
    defer testing.allocator.free(patch);
    try testing.expectError(error.PatchChecksumMismatch, applyPatch(testing.allocator, old_b, patch));
}

test "applyPatch: 补丁篡改 → 拒绝" {
    const old = try randomBytes(testing.allocator, 40_000, 8);
    defer testing.allocator.free(old);
    const new = try randomBytes(testing.allocator, 40_000, 9);
    defer testing.allocator.free(new);
    const patch = try buildPatch(testing.allocator, old, new);
    defer testing.allocator.free(patch);

    const tampered = try testing.allocator.dupe(u8, patch);
    defer testing.allocator.free(tampered);
    tampered[tampered.len / 2] ^= 0xFF;
    const r = applyPatch(testing.allocator, old, tampered);
    try testing.expect(r == error.PatchChecksumMismatch or r == error.PatchInvalid);
}

test "applyPatch: 魔数/截断 → PatchInvalid" {
    const old = "old data";
    try testing.expectError(error.PatchInvalid, applyPatch(testing.allocator, old, "WRONGMAGIC"));
    const patch = try buildPatch(testing.allocator, old, "new data entirely");
    defer testing.allocator.free(patch);
    try testing.expectError(error.PatchInvalid, applyPatch(testing.allocator, old, patch[0..20]));
}

test "buildPatch: 确定性输出" {
    const old = try randomBytes(testing.allocator, 30_000, 10);
    defer testing.allocator.free(old);
    var new = try testing.allocator.dupe(u8, old);
    defer testing.allocator.free(new);
    new[100] ^= 1;
    const p1 = try buildPatch(testing.allocator, old, new);
    defer testing.allocator.free(p1);
    const p2 = try buildPatch(testing.allocator, old, new);
    defer testing.allocator.free(p2);
    try testing.expectEqualSlices(u8, p1, p2);
}
