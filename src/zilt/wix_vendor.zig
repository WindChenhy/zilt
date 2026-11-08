//! WiX Toolset 3.14.1 vendor（Tauri 式：把工具链拉进来，而不是要求用户装）。
//!
//! 背景：MSI 只能由 WiX 生成，而 WiX 不在 Windows SDK 里（candle/light/wix
//! 都不在 Kits 目录下）。Tauri 的做法是首次 `--bundles msi` 时下载
//! `wix314-binaries.zip` 到 `%LOCALAPPDATA%\tauri\WixTools` 并校验；
//! 这里照同一思路，缓存到 `%LOCALAPPDATA%\zilt\WixTools`。
//!
//! 本模块只做纯逻辑（常量 / 候选目录排序 / 摘要比对），文件存在性、下载、
//! 解压由 tools 层完成 —— 这样全部可离线单测。
//!
//! 注意版本：**必须 v3**。v7 把 candle/light 合并成 `wix.exe build`，语法与
//! 现有 `.wxs`（WiX 2006 schema）不兼容。

const std = @import("std");

pub const version = "3.14.1";

/// GitHub release tag 是 `wix3141rtm`。网络上不少文档/博客写的
/// `wix3142rtm` 并不存在（实测 404），别照抄。
pub const download_url =
    "https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip";

/// 与 Scoop `versions/wixtoolset3` manifest 内的 hash 一致（实测下载比对通过）。
pub const download_sha256 = "6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d31";

/// 实测 41,297,555 字节（约 40 MB）。仅用于下载前后的合理性校验。
pub const download_size: u64 = 41_297_555;

/// 判定一个目录"可用"的最低要求：candle 编译 .wxs，light 链接出 .msi。
pub const required_bins = [_][]const u8{ "candle.exe", "light.exe" };

/// 缓存目录，相对 `%LOCALAPPDATA%`。
pub const cache_subdir = "zilt\\WixTools";

/// WiX 目录来源（优先级由高到低）。
pub const Source = enum {
    /// `ZILT_WIX_TOOLPATH` 显式指定（最高优先级，且严格：无效即报错不回退）
    explicit,
    /// 环境变量 `WixToolPath`（Scoop 安装 wixtoolset3 会写入）
    environment,
    /// 本模块管理的下载缓存
    cache,
};

pub const Candidate = struct {
    dir: []u8,
    source: Source,
};

/// 按优先级列出候选目录（高 → 低），调用方逐个做存在性检查。
///
/// 语义约定：`explicit` 非空时**必须**用它；若它无效，调用方应报错而不是
/// 继续往后回退 —— 用户明确指定了路径，静默改用别处的 WiX 会让构建结果
/// 变得不可预期。`environment` / `cache` 则允许逐级回退。
pub fn candidates(
    alloc: std.mem.Allocator,
    explicit: ?[]const u8,
    environment: ?[]const u8,
    local_app_data: []const u8,
) ![]Candidate {
    var out: std.ArrayListUnmanaged(Candidate) = .empty;
    errdefer {
        for (out.items) |c| alloc.free(c.dir);
        out.deinit(alloc);
    }

    if (nonEmpty(explicit)) |p| {
        try out.append(alloc, .{ .dir = try alloc.dupe(u8, p), .source = .explicit });
    }
    if (nonEmpty(environment)) |p| {
        if (!hasDir(out.items, p)) {
            try out.append(alloc, .{ .dir = try alloc.dupe(u8, p), .source = .environment });
        }
    }
    const cached = try cacheDir(alloc, local_app_data);
    if (!hasDir(out.items, cached)) {
        try out.append(alloc, .{ .dir = cached, .source = .cache });
    } else {
        alloc.free(cached);
    }

    return out.toOwnedSlice(alloc);
}

pub fn freeCandidates(alloc: std.mem.Allocator, list: []Candidate) void {
    for (list) |c| alloc.free(c.dir);
    alloc.free(list);
}

/// `%LOCALAPPDATA%\zilt\WixTools`
pub fn cacheDir(alloc: std.mem.Allocator, local_app_data: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ std.mem.trimEnd(u8, local_app_data, "\\/"), cache_subdir });
}

/// 缓存目录下的解压标记文件：写它表示"这个目录已经解压完成且校验过"，
/// 避免每次构建都重新校验 40 MB。
pub const stamp_file = ".zilt-wix-ok";

/// 标记文件内容（含版本与摘要，版本升级后旧标记自动失效）。
pub fn stampContent(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "wix {s}\nsha256 {s}\n", .{ version, download_sha256 });
}

/// 摘要比对（大小写不敏感）。长度不符直接 false。
pub fn sha256Matches(actual_hex: []const u8, expected_hex: []const u8) bool {
    if (actual_hex.len != expected_hex.len) return false;
    if (actual_hex.len != 64) return false;
    for (actual_hex, expected_hex) |a, e| {
        if (std.ascii.toLower(a) != std.ascii.toLower(e)) return false;
    }
    return true;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var buf: [64]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0xf];
    }
    return buf;
}

/// 下载体积合理性：容忍 ±2%（CDN 不应改内容，这里只拦明显异常的响应）。
pub fn sizeSane(actual: u64) bool {
    const lo = download_size - download_size / 50;
    const hi = download_size + download_size / 50;
    return actual >= lo and actual <= hi;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    const t = std.mem.trim(u8, s, " \t\r\n");
    return if (t.len == 0) null else t;
}

fn hasDir(items: []const Candidate, dir: []const u8) bool {
    for (items) |c| {
        if (std.mem.eql(u8, c.dir, dir)) return true;
    }
    return false;
}

const testing = std.testing;

test "cache dir sits under LOCALAPPDATA and tolerates trailing separators" {
    const a = testing.allocator;
    const p1 = try cacheDir(a, "C:\\Users\\me\\AppData\\Local");
    defer a.free(p1);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\zilt\\WixTools", p1);

    const p2 = try cacheDir(a, "C:\\Users\\me\\AppData\\Local\\");
    defer a.free(p2);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\zilt\\WixTools", p2);
}

test "candidates: explicit wins, then environment, then cache" {
    const a = testing.allocator;
    const list = try candidates(a, "D:\\wix\\bin", "C:\\Scoop\\apps\\wixtoolset3\\current", "C:\\Users\\me\\AppData\\Local");
    defer freeCandidates(a, list);

    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqual(Source.explicit, list[0].source);
    try testing.expectEqualStrings("D:\\wix\\bin", list[0].dir);
    try testing.expectEqual(Source.environment, list[1].source);
    try testing.expectEqual(Source.cache, list[2].source);
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\zilt\\WixTools", list[2].dir);
}

test "candidates: blank values are ignored, duplicates collapse" {
    const a = testing.allocator;

    const blank = try candidates(a, "   ", "", "C:\\LAD");
    defer freeCandidates(a, blank);
    try testing.expectEqual(@as(usize, 1), blank.len);
    try testing.expectEqual(Source.cache, blank[0].source);

    // env 与 cache 指向同一目录 → 只保留一次，且保留优先级更高的 environment
    const dup = try candidates(a, null, "C:\\LAD\\zilt\\WixTools", "C:\\LAD");
    defer freeCandidates(a, dup);
    try testing.expectEqual(@as(usize, 1), dup.len);
    try testing.expectEqual(Source.environment, dup[0].source);
}

test "required bins are candle and light (WiX v3, not v7 wix.exe)" {
    try testing.expectEqualStrings("candle.exe", required_bins[0]);
    try testing.expectEqualStrings("light.exe", required_bins[1]);
    // v7 只有单一 wix.exe，绝不能当成可用目录
    for (required_bins) |b| {
        try testing.expect(!std.mem.eql(u8, b, "wix.exe"));
    }
}

test "sha256 comparison is case-insensitive and length-strict" {
    try testing.expect(sha256Matches(
        "6AC824E1642D6F7277D0ED7EA09411A508F6116BA6FAE0AA5F2C7DAA2FF43D31",
        download_sha256,
    ));
    try testing.expect(sha256Matches(download_sha256, download_sha256));

    // 长度不符
    try testing.expect(!sha256Matches("6ac824e1", download_sha256));
    // 位数对但内容不同
    const wrong = "6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d32";
    try testing.expect(!sha256Matches(wrong, download_sha256));
    // 空
    try testing.expect(!sha256Matches("", download_sha256));
}

test "sha256Hex produces the pinned digest for known bytes" {
    // "abc" 的 SHA-256 是标准公开值，用来确认不是自己算自己
    const h = sha256Hex("abc");
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &h,
    );
}

test "download size sanity window is sane but not toothless" {
    try testing.expect(sizeSane(download_size));
    try testing.expect(sizeSane(download_size - 100_000));
    // 明显不对：空响应 / 半个包 / 多一倍
    try testing.expect(!sizeSane(0));
    try testing.expect(!sizeSane(download_size / 2));
    try testing.expect(!sizeSane(download_size * 2));
}

test "stamp content pins version and digest so upgrades invalidate it" {
    const a = testing.allocator;
    const s = try stampContent(a);
    defer a.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "wix 3.14.1") != null);
    try testing.expect(std.mem.indexOf(u8, s, download_sha256) != null);
}
