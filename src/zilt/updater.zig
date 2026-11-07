//! 自动更新器（对齐 Tauri updater 方案，平台无关核心 + Windows staging）。
//!
//! 发布物签名方案：
//!   manifest.json = { "version", "notes", "pub_date", "url", "sha256", "signature" }
//!   - signature：对**安装包原始字节**的 ed25519 签名（base64）
//!   - sha256：安装包十六进制摘要
//!   - 公钥内置于应用配置（UpdateConfig.public_key_hex）
//!   流程：取 manifest → 版本比较 → 下载包 → sha256 比对 → ed25519 验签 →
//!         从 zip 提取 exe → 原子替换（.zilt-new/.zilt-old）→ 可重启生效。
//!
//! 网络传输经 Fetcher 注入（运行时 = std.http.Client；测试 = 固定数据），
//! 使全部决策/验签/staging 逻辑可离线单测。

const std = @import("std");
const bundler = @import("bundler.zig");

pub const Manifest = struct {
    version: []const u8,
    notes: []const u8 = "",
    pub_date: []const u8 = "",
    url: []const u8,
    sha256: []const u8,
    signature: []const u8,
    /// 增量/差分包（v0.1.5）：from == 当前版本且基线校验通过时优先走差分，失败自动回退全量
    patch: ?PatchInfo = null,
};

/// 差分包描述（zilt-patch v1 格式，见 patch.zig）。
pub const PatchInfo = struct {
    /// 基线版本（差分基线的应用版本）
    from: []const u8,
    /// 基线 exe 的 sha256（防基线漂移——不匹配则回退全量）
    from_sha256: []const u8,
    url: []const u8,
    sha256: []const u8,
    signature: []const u8,
};

pub const UpdateError = error{
    ManifestInvalid,
    VersionNotNewer,
    Sha256Mismatch,
    SignatureInvalid,
    KeyInvalid,
} || bundler.ZipReadError || std.base64.Error || std.mem.Allocator.Error;

/// 解析 manifest（字符串指向调用方 allocator——建议传 arena）。
pub fn parseManifest(arena: std.mem.Allocator, json_bytes: []const u8) UpdateError!Manifest {
    return std.json.parseFromSliceLeaky(Manifest, arena, json_bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ManifestInvalid,
    };
}

/// 语义化版本比较：candidate 比 current 新则 true（逐段数值比较，缺段补 0）。
pub fn versionNewer(current: []const u8, candidate: []const u8) bool {
    return versionCmp(current, candidate) < 0;
}

fn versionCmp(a: []const u8, b: []const u8) i32 {
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const av_s = ai.next();
        const bv_s = bi.next();
        if (av_s == null and bv_s == null) return 0;
        const av = if (av_s) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        const bv = if (bv_s) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        if (av != bv) return if (av < bv) -1 else 1;
    }
}

pub fn sha256Hex(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    var buf = try alloc.alloc(u8, 64);
    const hex = "0123456789abcdef";
    for (out, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0xf];
    }
    return buf;
}

/// ed25519 验签：signature_b64 覆盖 artifact 原始字节，公钥 32 字节。
pub fn verifyArtifact(artifact: []const u8, signature_b64: []const u8, public_key: [32]u8) UpdateError!void {
    const Ed25519 = std.crypto.sign.Ed25519;
    var sig_bytes: [64]u8 = undefined;
    const b64dec = std.base64.standard.Decoder;
    const sig_len = b64dec.calcSizeForSlice(signature_b64) catch return error.SignatureInvalid;
    if (sig_len != 64) return error.SignatureInvalid;
    b64dec.decode(&sig_bytes, signature_b64) catch return error.SignatureInvalid;

    const pk = Ed25519.PublicKey.fromBytes(public_key) catch return error.KeyInvalid;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    sig.verify(artifact, pk) catch return error.SignatureInvalid;
}

/// 下载器注入接口。
pub const Fetcher = struct {
    ctx: *anyopaque,
    fetchFn: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8) anyerror![]u8,
};

/// 检查更新：取 manifest → 比较 → 返回新版本 manifest；已是最新返回 null。
/// 返回的 Manifest 字符串指向 arena。
pub fn checkForUpdate(arena: std.mem.Allocator, fetcher: Fetcher, manifest_url: []const u8, current_version: []const u8) UpdateError!?Manifest {
    const raw = fetcher.fetchFn(fetcher.ctx, arena, manifest_url) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ManifestInvalid,
    };
    const m = try parseManifest(arena, raw);
    if (!versionNewer(current_version, m.version)) return null;
    return m;
}

/// 下载并验签安装包（返回包字节；调用方负责释放）。
pub fn downloadAndVerify(alloc: std.mem.Allocator, fetcher: Fetcher, m: Manifest, public_key: [32]u8) UpdateError![]u8 {
    const artifact = fetcher.fetchFn(fetcher.ctx, alloc, m.url) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ManifestInvalid,
    };
    errdefer alloc.free(artifact);

    // sha256 比对（大小写不敏感）
    const actual_hex = try sha256Hex(alloc, artifact);
    defer alloc.free(actual_hex);
    if (!std.ascii.eqlIgnoreCase(actual_hex, m.sha256)) return error.Sha256Mismatch;

    try verifyArtifact(artifact, m.signature, public_key);
    return artifact;
}

/// 从更新包提取 exe 并原子替换当前运行中的 exe：
///   写 `<exe>.zilt-new` → 当前 exe 改名 `.zilt-old`（运行中允许改名）→ new 接管原名。
/// 重启后生效；`cleanupOld` 在下次启动时清理备份。
pub fn stageUpdate(alloc: std.mem.Allocator, exe_path: []const u8, exe_name_in_zip: []const u8, zip_bytes: []const u8) UpdateError!void {
    // 兼容 zip 内目录前缀不固定
    const suffix = try std.fmt.allocPrint(alloc, "/{s}", .{exe_name_in_zip});
    defer alloc.free(suffix);
    const new_exe = bundler.readZipStoreEntrySuffix(alloc, zip_bytes, suffix) catch |err| switch (err) {
        error.EntryNotFound => try bundler.readZipStoreEntry(alloc, zip_bytes, exe_name_in_zip),
        else => return err,
    };
    defer alloc.free(new_exe);
    return stageBytes(alloc, exe_path, new_exe);
}

/// 将新 exe 字节原子替换当前运行中的 exe（写 .zilt-new → 旧改名 .zilt-old → new 接管原名）。
pub fn stageBytes(alloc: std.mem.Allocator, exe_path: []const u8, new_exe: []const u8) UpdateError!void {
    const win32 = @import("platform/windows/win32.zig");

    const new_path = try std.fmt.allocPrint(alloc, "{s}.zilt-new", .{exe_path});
    defer alloc.free(new_path);
    const old_path = try std.fmt.allocPrint(alloc, "{s}.zilt-old", .{exe_path});
    defer alloc.free(old_path);

    if (!win32.writeFileAlloc(alloc, new_path, new_exe)) return error.ManifestInvalid;

    const exe_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, exe_path) catch return error.ManifestInvalid;
    defer alloc.free(exe_w);
    const old_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, old_path) catch return error.ManifestInvalid;
    defer alloc.free(old_w);
    const new_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, new_path) catch return error.ManifestInvalid;
    defer alloc.free(new_w);

    if (win32.MoveFileExW(exe_w.ptr, old_w.ptr, win32.MOVEFILE_REPLACE_EXISTING) == 0) return error.ManifestInvalid;
    if (win32.MoveFileExW(new_w.ptr, exe_w.ptr, win32.MOVEFILE_REPLACE_EXISTING) == 0) return error.ManifestInvalid;
}

/// 重启触发标志：`<exe> --zilt-restart <target>`（helper 进程：等旧实例退出并释放
/// 单实例互斥体后拉起 target；自身即当前 exe，在 zilt.run 最早期拦截，不创建窗口）。
pub const restart_flag = "--zilt-restart";

/// argv 中检测重启 helper 调用（返回 target 路径；非 helper 调用返回 null）。
pub fn isRestartHelperCall(argv: []const []const u8) ?[]const u8 {
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, restart_flag) and i + 1 < argv.len) return argv[i + 1];
    }
    return null;
}

/// helper：延迟等待旧实例退出（互斥体释放）→ 拉起新 exe → 退出。
/// 子进程退出码 5（单实例冲突）时重试——旧实例尚未完全退出。
pub fn runRestartHelper(alloc: std.mem.Allocator, target: []const u8) void {
    _ = alloc;
    const win32 = @import("platform/windows/win32.zig");
    win32.Sleep(800);
    var attempt: u32 = 0;
    while (attempt < 5) : (attempt += 1) {
        const pi = win32.spawnDetached(target, "") orelse {
            @import("log.zig").print("[updater] restart helper: spawn failed", .{});
            return;
        };
        _ = win32.WaitForSingleObject(pi.hProcess, 3000);
        var code: u32 = 0;
        _ = win32.GetExitCodeProcess(pi.hProcess, &code);
        _ = win32.CloseHandle(pi.hProcess);
        _ = win32.CloseHandle(pi.hThread);
        if (code != 5) return; // 非单实例冲突 → 完成
        win32.Sleep(400);
    }
}

/// 启动时清理上次更新留下的备份。
pub fn cleanupOld(alloc: std.mem.Allocator, exe_path: []const u8) void {
    const win32 = @import("platform/windows/win32.zig");
    const old_path = std.fmt.allocPrint(alloc, "{s}.zilt-old", .{exe_path}) catch return;
    defer alloc.free(old_path);
    const old_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, old_path) catch return;
    defer alloc.free(old_w);
    _ = win32.DeleteFileW(old_w.ptr);
}

/// 更新器运行环境（backend 组装后挂到 Context.updater_env）。
pub const Env = struct {
    manifest_url: []const u8,
    public_key: [32]u8,
    current_version: []const u8,
    exe_path: []u8,
    /// 更新包内 exe 的文件名
    exe_name: []const u8,
    fetcher: Fetcher,
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "versionNewer: 逐段比较" {
    try testing.expect(versionNewer("0.1.1", "0.1.2"));
    try testing.expect(versionNewer("0.1.1", "1.0.0"));
    try testing.expect(versionNewer("0.9.9", "0.10.0")); // 数值比较而非字典序
    try testing.expect(versionNewer("1.0", "1.0.1")); // 缺段补 0
    try testing.expect(!versionNewer("0.1.2", "0.1.1"));
    try testing.expect(!versionNewer("0.1.1", "0.1.1"));
    try testing.expect(!versionNewer("2.0.0", "1.9.9"));
    try testing.expect(versionNewer("0.1.1", "0.1.1.1"));
}

test "parseManifest: 字段提取 + 非法 JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const m = try parseManifest(arena.allocator(),
        \\{"version":"9.9.9","notes":"big update","pub_date":"2026-11-08",
        \\ "url":"http://x/update.zip","sha256":"abc123","signature":"c2ln","extra":1}
    );
    try testing.expectEqualStrings("9.9.9", m.version);
    try testing.expectEqualStrings("big update", m.notes);
    try testing.expectEqualStrings("http://x/update.zip", m.url);
    try testing.expectEqualStrings("c2ln", m.signature);

    try testing.expectError(error.ManifestInvalid, parseManifest(arena.allocator(), "{not json"));
    try testing.expectError(error.ManifestInvalid, parseManifest(arena.allocator(), "{}")); // 缺 version/url
}

test "sha256Hex: 已知向量" {
    const h1 = try sha256Hex(testing.allocator, "abc");
    defer testing.allocator.free(h1);
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", h1);
    const h2 = try sha256Hex(testing.allocator, "");
    defer testing.allocator.free(h2);
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", h2);
}

const TestKeys = struct {
    var seed: [32]u8 = undefined;
    var kp: std.crypto.sign.Ed25519.KeyPair = undefined;
    var inited: bool = false;

    fn init() !void {
        if (inited) return;
        @memset(&seed, 0);
        seed[0] = 0xAB;
        seed[31] = 0x42;
        kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        inited = true;
    }
};

test "verifyArtifact: 签名回环 + 篡改拒绝" {
    try TestKeys.init();

    var artifact: [100]u8 = undefined;
    for (&artifact, 0..) |*b, i| b.* = @truncate(i);

    const sig = try TestKeys.kp.sign(&artifact, null);
    const b64enc = std.base64.standard.Encoder;
    var sig_b64_buf: [128]u8 = undefined;
    const sig_b64 = sig_b64_buf[0..b64enc.calcSize(sig.toBytes().len)];
    _ = b64enc.encode(sig_b64, &sig.toBytes());

    // 正确验签
    try verifyArtifact(&artifact, sig_b64, TestKeys.kp.public_key.bytes);

    // 篡改内容 → 拒绝
    var tampered = artifact;
    tampered[10] ^= 0xff;
    try testing.expectError(error.SignatureInvalid, verifyArtifact(&tampered, sig_b64, TestKeys.kp.public_key.bytes));

    // 错误公钥 → 拒绝
    var wrong_pk: [32]u8 = TestKeys.kp.public_key.bytes;
    wrong_pk[0] ^= 0xff;
    try testing.expectError(error.SignatureInvalid, verifyArtifact(&artifact, sig_b64, wrong_pk));

    // 非法 base64 → 拒绝
    try testing.expectError(error.SignatureInvalid, verifyArtifact(&artifact, "!!!not-base64!!!", TestKeys.kp.public_key.bytes));
}

const FakeFetcher = struct {
    responses: []const struct { url: []const u8, body: []const u8 },

    fn fetch(ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8) anyerror![]u8 {
        const self: *FakeFetcher = @ptrCast(@alignCast(ctx));
        for (self.responses) |r| {
            if (std.mem.eql(u8, r.url, url)) return alloc.dupe(u8, r.body);
        }
        return error.HttpNotFound;
    }

    fn make(self: *FakeFetcher) Fetcher {
        return .{ .ctx = @ptrCast(self), .fetchFn = fetch };
    }
};

test "checkForUpdate: 有新版 / 已最新 / fetch 失败" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var f = FakeFetcher{ .responses = &.{
        .{ .url = "http://x/manifest.json", .body = "{\"version\":\"9.9.9\",\"url\":\"http://x/u.zip\",\"sha256\":\"aa\",\"signature\":\"sig\"}" },
    } };
    const fetcher = f.make();

    const m = (try checkForUpdate(arena.allocator(), fetcher, "http://x/manifest.json", "0.1.1")).?;
    try testing.expectEqualStrings("9.9.9", m.version);

    // 已是最新
    try testing.expectEqual(@as(?Manifest, null), try checkForUpdate(arena.allocator(), fetcher, "http://x/manifest.json", "9.9.9"));
    try testing.expectEqual(@as(?Manifest, null), try checkForUpdate(arena.allocator(), fetcher, "http://x/manifest.json", "10.0.0"));

    // fetch 失败
    var f2 = FakeFetcher{ .responses = &.{} };
    try testing.expectError(error.ManifestInvalid, checkForUpdate(arena.allocator(), f2.make(), "http://x/none.json", "0.1.1"));
}

test "downloadAndVerify: 全链路（sha256 + 验签）" {
    try TestKeys.init();

    const artifact = "fake-zip-bytes-for-update-payload";
    const sig = try TestKeys.kp.sign(artifact, null);
    const sig_b64 = try sigB64(testAlloc(), sig.toBytes());
    defer testing.allocator.free(sig_b64);
    const sha = try sha256Hex(testing.allocator, artifact);
    defer testing.allocator.free(sha);

    const manifest_json = try std.fmt.allocPrint(testing.allocator,
        "{{\"version\":\"9.9.9\",\"url\":\"http://x/u.zip\",\"sha256\":\"{s}\",\"signature\":\"{s}\"}}",
        .{ sha, sig_b64 },
    );
    defer testing.allocator.free(manifest_json);

    var f = FakeFetcher{ .responses = &.{
        .{ .url = "http://x/manifest.json", .body = manifest_json },
        .{ .url = "http://x/u.zip", .body = artifact },
    } };
    const fetcher = f.make();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = (try checkForUpdate(arena.allocator(), fetcher, "http://x/manifest.json", "0.1.1")).?;
    const got = try downloadAndVerify(testing.allocator, fetcher, m, TestKeys.kp.public_key.bytes);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, artifact, got);

    // sha256 不匹配 → 拒绝
    var m_bad = m;
    m_bad.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try testing.expectError(error.Sha256Mismatch, downloadAndVerify(testing.allocator, fetcher, m_bad, TestKeys.kp.public_key.bytes));
}

fn testAlloc() std.mem.Allocator {
    return testing.allocator;
}

fn sigB64(alloc: std.mem.Allocator, sig_bytes: [64]u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try alloc.alloc(u8, enc.calcSize(sig_bytes.len));
    _ = enc.encode(buf, &sig_bytes);
    return buf;
}

test "stageUpdate: 原子替换舞步 + cleanupOld" {
    const win32 = @import("platform/windows/win32.zig");
    const alloc2 = testing.allocator;

    // 临时目录：%TEMP%\zilt-utest-<pid>
    const pid = std.os.windows.GetCurrentProcessId();
    const temp_dir = win32.getEnvUtf8(alloc2, "TEMP") orelse try alloc2.dupe(u8, "C:\\Windows\\Temp");
    defer alloc2.free(temp_dir);
    const dir = try std.fmt.allocPrint(alloc2, "{s}\\zilt-utest-{d}", .{ temp_dir, pid });
    defer alloc2.free(dir);
    {
        const dir_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc2, dir);
        defer alloc2.free(dir_w);
        _ = win32.CreateDirectoryW(dir_w.ptr, null);
    }
    defer cleanupTestDir(alloc2, dir);

    // 假"运行中 exe" + 假更新包（含一个 exe 条目）
    const exe_path = try std.fmt.allocPrint(alloc2, "{s}\\zilt-app.exe", .{dir});
    defer alloc2.free(exe_path);
    try testing.expect(win32.writeFileAlloc(alloc2, exe_path, "OLD-RUNNING-EXE"));

    const entries = [_]bundler.ZipEntry{
        .{ .name = "Zilt-9.9.9-x64/zilt-app.exe", .content = "NEW-EXE-BYTES" },
    };
    var zip_bytes: std.ArrayList(u8) = .empty;
    defer zip_bytes.deinit(alloc2);
    try bundler.writeZip(alloc2, &entries, &zip_bytes);

    // stage：运行中替换
    try stageUpdate(alloc2, exe_path, "zilt-app.exe", zip_bytes.items);

    const now = win32.readFileAlloc(alloc2, exe_path) orelse return error.TestUnexpectedResult;
    defer alloc2.free(now);
    try testing.expectEqualStrings("NEW-EXE-BYTES", now);

    const old_path = try std.fmt.allocPrint(alloc2, "{s}.zilt-old", .{exe_path});
    defer alloc2.free(old_path);
    const backup = win32.readFileAlloc(alloc2, old_path) orelse return error.TestUnexpectedResult;
    defer alloc2.free(backup);
    try testing.expectEqualStrings("OLD-RUNNING-EXE", backup);

    // cleanupOld：备份被删除
    cleanupOld(alloc2, exe_path);
    const old_gone = win32.readFileAlloc(alloc2, old_path);
    try testing.expect(old_gone == null);
}

fn cleanupTestDir(alloc: std.mem.Allocator, dir: []const u8) void {
    const win32 = @import("platform/windows/win32.zig");
    const names = [_][]const u8{ "zilt-app.exe", "zilt-app.exe.zilt-old", "zilt-app.exe.zilt-new" };
    for (names) |n| {
        const p = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ dir, n }) catch continue;
        defer alloc.free(p);
        const pw = std.unicode.utf8ToUtf16LeAllocZ(alloc, p) catch continue;
        defer alloc.free(pw);
        _ = win32.DeleteFileW(pw.ptr);
    }
    const dir_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, dir) catch return;
    defer alloc.free(dir_w);
    _ = win32.RemoveDirectoryW(dir_w.ptr);
}
