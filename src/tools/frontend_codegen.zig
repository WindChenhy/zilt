//! 前端资产 codegen（build.zig 执行期调用）：
//! 遍历前端 dist 目录（win32 FindFirstFile，自包含实现）→ 生成 zilt-assets 模块
//! （@embedFile 相对路径表 + payload 副本）。
//!
//! 设计要点（对标 tauri-codegen，见 docs/research/frontend-integration.md §4.2）：
//!  - 遍历结果按路径排序 → 生成文件内容确定 → zig 缓存命中（资产未变不重编）
//!  - 内建排除：node_modules/.git/zig-cache 等（防误嵌，Tauri build.rs 同款防御）
//!  - dist 缺失 → 空资产表 + 生成文件内注释警告（应用可构建，运行时 404）
//!  - 资产预压缩（Phase C，对标 tauri-codegen brotli）：>gzip_min_size 且 gzip
//!    收益 ≥10% 的文件附 .gz 变体（std.compress.flate，输出确定）→ 运行时按
//!    Accept-Encoding 直接下发 + Content-Encoding: gzip

const std = @import("std");
const Io = std.Io;

// ---- 文件系统：std.Io（Windows / Linux 同一份实现） ----
//
// v0.2.0：原实现直接调 kernel32（FindFirstFileW / CreateFileW / …），Linux 上
// `zig build` 连 configure 阶段都过不去（build.zig 在求值期就要遍历 dist）。
// 改用 `std.Io.Dir`：跨平台、无 extern、Windows 语义不变（WTF-8 路径由 std 处理）。
//
// 约定：所有公开函数第一个参数是 `io`（build.zig 用 `b.graph.io`，CLI 自建
// `std.Io.Threaded`）；路径分隔符对外统一 `'/'`（Zig 的 @embedFile / b.path 均接受）。

/// 递归建目录（幂等；已存在不算错误）。
pub fn ensureDirDeep(alloc: std.mem.Allocator, io: Io, path: []const u8) !void {
    _ = alloc;
    _ = try Io.Dir.cwd().createDirPathStatus(io, path, .default_dir);
}

/// 写文件（覆盖；成功 true）。构建期 payload 落盘用。
pub fn writeFilePayload(alloc: std.mem.Allocator, io: Io, path: []const u8, data: []const u8) bool {
    _ = alloc;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch return false;
    return true;
}

/// 相对路径拼接（'/' 分隔；b.path() 用）。
pub fn fsJoinRel(alloc: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, rel });
}

/// 构建期状态：内容寻址资产目录（build.zig 填充）
pub var payload_dir_buf: ?[]const u8 = null;

/// 排除的目录/文件名（任一路径段命中即跳过）。
pub const default_excludes = [_][]const u8{
    "node_modules", ".git",      "zig-cache", ".zig-cache", "zig-out",
    "src-tauri",    ".DS_Store", "Thumbs.db", "desktop.ini",
};

/// 递归收集文件相对路径（'/' 分隔，无前导 ./，按字典序排序）。
/// dist 不存在 → 空表（应用仍可构建，运行时 404）。
pub fn collectFiles(
    alloc: std.mem.Allocator,
    io: Io,
    root: []const u8,
    excludes: []const []const u8,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |it| alloc.free(it);
        list.deinit(alloc);
    }

    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list.toOwnedSlice(alloc),
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (excludedPath(entry.path, excludes)) continue;
        try list.append(alloc, try normalizePath(alloc, entry.path));
    }

    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return list.toOwnedSlice(alloc);
}

/// 任一路径段命中排除名，或以 '.' 开头（隐藏项）→ 跳过。
fn excludedPath(path: []const u8, excludes: []const []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (seg[0] == '.') return true;
        for (excludes) |e| {
            if (std.ascii.eqlIgnoreCase(seg, e)) return true;
        }
    }
    return false;
}

/// 路径分隔符统一为 '/'（@embedFile 与 b.path 都接受）。
fn normalizePath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// 生成 zilt-assets/assets.zig 源码（payload 相对路径与 collectFiles 顺序一致；
/// gz_flags[i] 为 true 的条目只嵌 .gz 字节并标记 encoding=.gzip（Tauri 式缩 exe，
/// 服务端惰性解压后以 identity 下发）。
pub fn generateAssetsZig(alloc: std.mem.Allocator, files: []const []const u8, gz_flags: []const bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    if (files.len == 0) {
        try out.appendSlice(alloc, "// 警告：前端 dist 目录为空或不存在——先运行前端构建（zig build frontend）。\n");
    }
    try out.appendSlice(alloc, "// 由 build.zig 资产 codegen 自动生成（排序稳定，勿手改）。\nconst zilt = @import(\"zilt\");\n\npub const assets = [_]zilt.Asset{\n");
    for (files, 0..) |rel, i| {
        const url = try urlPath(alloc, rel);
        defer alloc.free(url);
        const esc = try zigEscape(alloc, url);
        defer alloc.free(esc);
        if (i < gz_flags.len and gz_flags[i]) {
            try out.print(alloc, "    .{{ .path = \"{s}\", .content = @embedFile(\"payload/{s}.gz\"), .encoding = .gzip }},\n", .{ esc, rel });
        } else {
            try out.print(alloc, "    .{{ .path = \"{s}\", .content = @embedFile(\"payload/{s}\") }},\n", .{ esc, rel });
        }
    }
    try out.appendSlice(alloc, "};\n");
    return out.toOwnedSlice(alloc);
}

/// 相对路径 → URL 路径（'/' 分隔，'/' 开头）。
pub fn urlPath(alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
    const out = try std.fmt.allocPrint(alloc, "/{s}", .{rel});
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Zig 字符串字面量转义（" \ 与控制字符）。
pub fn zigEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// 绝对路径与相对路径拼接（统一 '/' 分隔：Windows 的 Zig 构建系统同样接受）。
pub fn fsJoin(alloc: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    if (base.len == 0) return alloc.dupe(u8, rel);
    const trimmed = std.mem.trimEnd(u8, base, "/\\");
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ trimmed, rel });
}

// ---------------------------------------------------------------------------
// 资产预压缩（Phase C；tauri-codegen brotli 的 flate 对应物）
// ---------------------------------------------------------------------------

/// 小于该值的文件不预压缩（收益抵不过元数据/解压开销）。
pub const gzip_min_size = 8 * 1024;

/// gzip 变体是否值得附带：压缩后体积需减少 ≥10%（图片等已压缩格式自然落选）。
pub fn gzipWorthwhile(raw_len: usize, gz_len: usize) bool {
    return gz_len * 10 < raw_len * 9;
}

/// gzip 预压缩（std.compress.flate，gzip 容器；相同输入输出确定 → 缓存友好）。
pub fn gzipCompress(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try aw.ensureTotalCapacity(256); // Compress.init 断言 output.buffer.len > 8
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&aw.writer, &window, .gzip, .default);
    _ = try comp.writer.writeAll(raw);
    try comp.finish();
    return alloc.dupe(u8, aw.written());
}

/// gzip 解压（运行时回退路径：客户端不接受 gzip 时还原原始字节）。
pub fn gzipDecompress(alloc: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const n = try dec.reader.streamRemaining(&aw.writer);
    const out = try alloc.dupe(u8, aw.written());
    std.debug.assert(n == out.len);
    return out;
}

/// 读取整个文件（构建期压缩输入；失败返回 null）。
pub fn readFileAlloc(alloc: std.mem.Allocator, io: Io, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(512 * 1024 * 1024)) catch null;
}

/// 测试用临时目录（相对 cwd，落在 .zig-cache 下；跨平台且不污染系统 TEMP）。
var test_seq: std.atomic.Value(u32) = .init(0);

fn testRoot(alloc: std.mem.Allocator, tag: []const u8) ![]u8 {
    // 0.17 的 std.time / std.crypto.random 均已迁移；用进程内自增序号即可
    const n = test_seq.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(alloc, ".zig-cache/zilt-tests/{s}-{d}", .{ tag, n });
}

// ---------------------------------------------------------------------------
// 测试（zig build test-tools）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "zigEscape" {
    const e = try zigEscape(testing.allocator, "a\"b\\c");
    defer testing.allocator.free(e);
    try testing.expectEqualStrings("a\\\"b\\\\c", e);
}

test "urlPath: 反斜杠转正斜杠 + 前导斜杠" {
    const u = try urlPath(testing.allocator, "assets\\index.js");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("/assets/index.js", u);
}

test "collectFiles: 排序 + 排除 + 递归（真实临时目录）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const root = try testRoot(alloc, "cg");
    defer alloc.free(root);

    try mkDir(root);
    try mkDir(try std.fmt.allocPrint(alloc, "{s}/assets", .{root}));
    try mkDir(try std.fmt.allocPrint(alloc, "{s}/node_modules", .{root}));
    try writeFileTree(try std.fmt.allocPrint(alloc, "{s}/index.html", .{root}), "<html></html>");
    try writeFileTree(try std.fmt.allocPrint(alloc, "{s}/assets/app.js", .{root}), "console.log(1)");
    try writeFileTree(try std.fmt.allocPrint(alloc, "{s}/node_modules/x.js", .{root}), "junk");
    defer cleanupTree(alloc, root);

    const files = try collectFiles(alloc, testIo(), root, &default_excludes);
    defer {
        for (files) |f| alloc.free(f);
        alloc.free(files);
    }
    try testing.expectEqual(@as(usize, 2), files.len); // node_modules 被排除
    try testing.expectEqualStrings("assets/app.js", files[0]); // 排序稳定
    try testing.expectEqualStrings("index.html", files[1]);

    const src = try generateAssetsZig(alloc, files, &.{ false, false });
    defer alloc.free(src);
    try testing.expect(std.mem.indexOf(u8, src, ".path = \"/index.html\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "@embedFile(\"payload/index.html\")") != null);
    try testing.expect(std.mem.indexOf(u8, src, "@import(\"zilt\")") != null);
}

test "gzipCompress/gzipDecompress: magic + 往返 + 确定性" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var raw: std.ArrayList(u8) = .empty;
    for (0..500) |i| {
        try raw.print(alloc, "zilt asset line {d}: the quick brown fox jumps over the lazy dog\n", .{i});
    }

    const gz1 = try gzipCompress(alloc, raw.items);
    const gz2 = try gzipCompress(alloc, raw.items);
    try testing.expect(gz1.len > 2);
    try testing.expectEqual(@as(u8, 0x1f), gz1[0]); // gzip magic
    try testing.expectEqual(@as(u8, 0x8b), gz1[1]);
    try testing.expect(gzipWorthwhile(raw.items.len, gz1.len));
    try testing.expectEqualSlices(u8, gz1, gz2); // 确定性（缓存友好）

    const back = try gzipDecompress(alloc, gz1);
    try testing.expectEqualSlices(u8, raw.items, back);
}

test "gzipWorthwhile: 已压缩格式落选" {
    // 随机样式的数据（近似不可压）→ gzip 不省 10% → 不附带
    var raw: [8193]u8 = undefined;
    var x: u32 = 12345;
    for (&raw, 0..) |*b, i| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 16);
        _ = i;
    }
    const gz = try gzipCompress(testing.allocator, &raw);
    defer testing.allocator.free(gz);
    try testing.expect(!gzipWorthwhile(raw.len, gz.len));
}

test "generateAssetsZig: gz_flags 控制存储编码" {
    const files = [_][]const u8{ "a.js", "big.js" };
    const src = try generateAssetsZig(testing.allocator, &files, &.{ false, true });
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, ".path = \"/a.js\", .content = @embedFile(\"payload/a.js\") }") != null);
    try testing.expect(std.mem.indexOf(u8, src, ".content = @embedFile(\"payload/big.js.gz\"), .encoding = .gzip }") != null);
    // 压缩条目不再嵌原始字节（单份拷贝，缩 exe）
    try testing.expect(std.mem.indexOf(u8, src, "@embedFile(\"payload/big.js\")") == null);
}

test "readFileAlloc: 往返（真实临时文件）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const root = try testRoot(alloc, "rf");
    defer alloc.free(root);
    try mkDir(root);
    const path = try std.fmt.allocPrint(alloc, "{s}/data.bin", .{root});
    defer alloc.free(path);
    const payload = "bin\x00ary\xff bytes";
    try writeFileTree(path, payload);
    defer cleanupTree(alloc, root);

    const io = testIo();
    const got = readFileAlloc(alloc, io, path) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, payload, got);
    const missing = try std.fmt.allocPrint(alloc, "{s}/missing.bin", .{root});
    defer alloc.free(missing);
    try testing.expect(readFileAlloc(alloc, io, missing) == null);
}

/// 测试用 Io：只做同步目录操作，用 page_allocator 避免与 testing.allocator 的
/// 泄漏检查纠缠（Threaded 只在需要 async/concurrent 时才分配）。
var test_threaded: std.Io.Threaded = undefined;
var test_threaded_ready = false;
fn testIo() std.Io {
    if (!test_threaded_ready) {
        test_threaded = .init(std.heap.page_allocator, .{});
        test_threaded_ready = true;
    }
    return test_threaded.io();
}

fn mkDir(path: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(testIo(), path, .default_dir);
}

fn cleanupTree(alloc: std.mem.Allocator, root: []const u8) void {
    _ = alloc;
    std.Io.Dir.cwd().deleteTree(testIo(), root) catch {};
}

fn writeFileTree(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(testIo(), .{ .sub_path = path, .data = data });
}
