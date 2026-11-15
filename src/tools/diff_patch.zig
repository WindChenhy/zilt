//! 差分包生成工具：`ZILT_DIFF_OLD=<旧exe> ZILT_DIFF_NEW=<新exe> ZILT_DIFF_OUT=<补丁输出> zig build diff`
//! 生成 zilt-patch v1 补丁（见 src/zilt/patch.zig），随后用 zilt-sign 对补丁文件签名
//! （manifest.patch.{url,sha256,signature,from,from_sha256}）。
//!
//! v0.3.1：跨平台（Windows/Linux 共用）——env 走 Init.environ_map，文件走 std.Io。

const std = @import("std");
const zilt = @import("zilt");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = init.io;

    const old_path = init.environ_map.get("ZILT_DIFF_OLD") orelse {
        std.debug.print("usage: ZILT_DIFF_OLD=<old> ZILT_DIFF_NEW=<new> ZILT_DIFF_OUT=<patch> zig build diff\n", .{});
        return error.MissingArgs;
    };
    const new_path = init.environ_map.get("ZILT_DIFF_NEW") orelse return error.MissingArgs;
    const out_path = init.environ_map.get("ZILT_DIFF_OUT") orelse return error.MissingArgs;

    const dir = std.Io.Dir.cwd();
    const old = dir.readFileAlloc(io, old_path, alloc, .limited(512 * 1024 * 1024)) catch return error.OldReadFailed;
    const new = dir.readFileAlloc(io, new_path, alloc, .limited(512 * 1024 * 1024)) catch return error.NewReadFailed;

    const patch_bytes = try zilt.patch.buildPatch(alloc, old, new);
    dir.writeFile(io, .{ .sub_path = out_path, .data = patch_bytes }) catch return error.OutWriteFailed;

    const new_sha = try zilt.updater.sha256Hex(alloc, new);
    const old_sha = try zilt.updater.sha256Hex(alloc, old);
    const patch_sha = try zilt.updater.sha256Hex(alloc, patch_bytes);
    std.debug.print(
        "[zilt-diff] old={d} new={d} patch={d} bytes ({d:.1}% of full)\n" ++
            "[zilt-diff] from_sha256={s}\n[zilt-diff] new_sha256={s}\n[zilt-diff] patch_sha256={s}\n" ++
            "[zilt-diff] manifest.patch = {{ \"from\": <当前版本>, \"from_sha256\": \"{s}\", \"url\": <补丁URL>, \"sha256\": \"{s}\", \"signature\": <zilt-sign 输出> }}\n",
        .{ old.len, new.len, patch_bytes.len, @as(f64, @floatFromInt(patch_bytes.len)) / @as(f64, @floatFromInt(@max(new.len, 1))) * 100.0, old_sha, new_sha, patch_sha, old_sha, patch_sha },
    );
}
