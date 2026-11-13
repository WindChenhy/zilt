//! gzip 解压（两平台共用）。
//!
//! 构建期 `frontend_codegen` 会把 >8KB 且收益 ≥10% 的资产预压成 `.gz`，运行时
//! 只有在客户端不接受 gzip 时才需要还原。WebView2 的 `CreateWebResourceResponse`
//! 与 WebKitGTK 的 URI scheme 都不做内容解码，因此这条路径是真实需要，不是兜底。
//!
//! 之前 Windows 后端与 headless 各有一份实现，Linux 后端又要第三份——统一到这里。
const std = @import("std");

/// 解压 gzip 容器。返回的字节归调用方所有。
pub fn gunzip(alloc: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    _ = try dec.reader.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}

const testing = std.testing;

test "gunzip: 往返一致" {
    const raw = "hello zilt hello zilt hello zilt hello zilt hello zilt hello zilt ";
    // 用与构建期相同的压缩路径生成样本（std.compress.flate, gzip 容器）
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.ensureTotalCapacity(256);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&aw.writer, &window, .gzip, .default);
    _ = try comp.writer.writeAll(raw);
    try comp.finish();

    const got = try gunzip(testing.allocator, aw.written());
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, raw, got);
}

test "gunzip: 非 gzip 输入报错而不是静默返回空" {
    // std.compress 把解压器的 BadGzipHeader 包成 ReadFailed（Reader.streamRemaining 语义）
    try testing.expectError(error.ReadFailed, gunzip(testing.allocator, "not a gzip stream at all"));
}
