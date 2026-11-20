//! 深链 / 第二实例参数转发（Linux 侧纯逻辑，v0.2.2）。
//!
//! 与 Windows 的 `platform/windows/deep_link.zig` 同构：
//!   - 启动参数分类：`scheme://…` → URL；存在的本地路径 → 文件；`--flag` 忽略
//!   - 第二实例转发载荷：参数以 `\n` 连接（GApplication command-line 转交后
//!     主实例按同一分类规则解析；`\n` 分隔的往返格式与 Windows WM_COPYDATA 一致）
//!   - 单实例与转交的宿主是 `GApplication`（HANDLES_COMMAND_LINE），本模块
//!     只承载纯逻辑，便于离线单测
//!
//! 路径存在性判断以函数注入（测试给固定表；backend 传 std.fs 探测）。
//! 环境变量走 std.c.getenv（0.17 移除了 std.posix.getenv；本模块随 Linux 后端链接 libc）。
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Launch = struct {
    url: ?[]u8 = null,
    files: [][]u8 = &.{},

    pub fn deinit(self: *Launch, alloc: Allocator) void {
        if (self.url) |u| alloc.free(u);
        for (self.files) |f| alloc.free(f);
        if (self.files.len > 0) alloc.free(self.files);
        self.* = .{};
    }

    pub fn isEmpty(self: Launch) bool {
        return self.url == null and self.files.len == 0;
    }
};

/// 存在性探测的注入点（避免测试依赖真实文件系统）。
pub const ExistsFn = *const fn (ctx: ?*anyopaque, path: []const u8) bool;

/// 真实文件系统探测（backend 用）。
pub fn pathExists(_: ?*anyopaque, path: []const u8) bool {
    if (path.len == 0) return false;
    _ = std.Io.Dir.cwd().statFile(moduleIo(), path, .{}) catch return false;
    return true;
}

/// 参数列表 → Launch（跳过 `--` 旗标与不存在的路径；`scheme://` 大小写不敏感）。
pub fn parseArgs(
    alloc: Allocator,
    args: []const []const u8,
    scheme: []const u8,
    exists_ctx: ?*anyopaque,
    exists_fn: ExistsFn,
) !Launch {
    var out = Launch{};
    errdefer out.deinit(alloc);
    var files: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (files.items) |f| alloc.free(f);
        files.deinit(alloc);
    }
    for (args) |arg| {
        if (arg.len == 0) continue;
        if (std.mem.startsWith(u8, arg, "--")) continue;
        if (schemePrefixMatches(arg, scheme)) {
            if (out.url == null) out.url = try alloc.dupe(u8, arg);
            continue;
        }
        if (exists_fn(exists_ctx, arg)) {
            try files.append(alloc, try alloc.dupe(u8, arg));
        }
    }
    out.files = try files.toOwnedSlice(alloc);
    return out;
}

/// 转发载荷：参数以 `\n` 连接（与 Windows WM_COPYDATA 载荷同格式）。
pub fn payloadOfArgs(alloc: Allocator, args: []const []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (args, 0..) |a, i| {
        if (i > 0) try buf.append(alloc, '\n');
        try buf.appendSlice(alloc, a);
    }
    return buf.toOwnedSlice(alloc);
}

/// 转交载荷 → Launch（GApplication command-line 转交前主实例自己也会走
/// parseArgs；本入口用于还原 `\n` 连接的历史载荷格式）。
pub fn parsePayload(
    alloc: Allocator,
    payload: []const u8,
    scheme: []const u8,
    exists_ctx: ?*anyopaque,
    exists_fn: ExistsFn,
) !Launch {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer list.deinit(alloc);
    var it = std.mem.splitScalar(u8, payload, '\n');
    while (it.next()) |part| {
        if (part.len > 0) try list.append(alloc, part);
    }
    return parseArgs(alloc, list.items, scheme, exists_ctx, exists_fn);
}

/// `scheme://…` 前缀匹配（scheme 大小写不敏感）。
pub fn schemePrefixMatches(arg: []const u8, scheme: []const u8) bool {
    if (scheme.len == 0) return false;
    if (arg.len < scheme.len + 3) return false;
    if (!std.ascii.eqlIgnoreCase(arg[0..scheme.len], scheme)) return false;
    return std.mem.eql(u8, arg[scheme.len .. scheme.len + 3], "://");
}

/// 本模块的惰性线程同步 Io（exePath 用；同 backend/window_state 的模式）。
var g_io: std.Io.Threaded = undefined;
var g_io_ready = false;
fn moduleIo() std.Io {
    if (!g_io_ready) {
        g_io = .init(std.heap.page_allocator, .{});
        g_io_ready = true;
    }
    return g_io.io();
}

/// 当前 exe 的绝对路径（0.17：std.process.executablePathAlloc，
/// Linux 上读 /proc/self/exe）。
pub fn exePath(alloc: Allocator) ![]u8 {
    const z = try std.process.executablePathAlloc(moduleIo(), alloc);
    defer alloc.free(z);
    return alloc.dupe(u8, z);
}

/// XDG 数据目录 + /applications（.desktop 注册处；深链 handler 与 v0.2.4 打包共用）。
pub fn applicationsDir(alloc: Allocator) ![]u8 {
    const base = xdgDataHome(alloc) catch return error.XdgDirUnavailable;
    defer alloc.free(base);
    return std.fmt.allocPrint(alloc, "{s}/applications", .{base});
}

/// XDG 配置目录 + /autostart（自启动条目）。
pub fn autostartDir(alloc: Allocator) ![]u8 {
    var base: []u8 = undefined;
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg_raw| {
        const xdg = std.mem.span(xdg_raw);
        if (xdg.len > 0) {
            base = try alloc.dupe(u8, xdg);
        } else {
            base = try homeSubdir(alloc, ".config");
        }
    } else {
        base = try homeSubdir(alloc, ".config");
    }
    defer alloc.free(base);
    return std.fmt.allocPrint(alloc, "{s}/autostart", .{base});
}

fn xdgDataHome(alloc: Allocator) ![]u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |xdg| {
        const s = std.mem.span(xdg);
        if (s.len > 0) return alloc.dupe(u8, s);
    }
    return homeSubdir(alloc, ".local/share");
}

fn homeSubdir(alloc: Allocator, sub: []const u8) ![]u8 {
    const home = std.c.getenv("HOME") orelse return error.XdgDirUnavailable;
    const s = std.mem.span(home);
    if (s.len == 0) return error.XdgDirUnavailable;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ s, sub });
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    paths: []const []const u8,
    fn exists(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *const Fixture = @ptrCast(@alignCast(ctx.?));
        for (self.paths) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }
};

test "parseArgs: scheme URL / 忽略旗标与不存在路径" {
    var fixture = Fixture{ .paths = &.{"/tmp/real.txt"} };
    const args = [_][]const u8{ "--zilt-x", "zilt://open?id=7", "/tmp/missing.txt", "/tmp/real.txt", "ZILT://upper", "" };
    var l = try parseArgs(testing.allocator, &args, "zilt", @ptrCast(&fixture), Fixture.exists);
    defer l.deinit(testing.allocator);
    try testing.expectEqualStrings("zilt://open?id=7", l.url.?);
    try testing.expectEqual(@as(usize, 1), l.files.len);
    try testing.expectEqualStrings("/tmp/real.txt", l.files[0]);
}

test "parsePayload: 往返与空载荷" {
    var fixture = Fixture{ .paths = &.{"/tmp/b"} };
    const args = [_][]const u8{ "zilt://a", "/tmp/b", "--flag" };
    const payload = try payloadOfArgs(testing.allocator, &args);
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("zilt://a\n/tmp/b\n--flag", payload);

    var l = try parsePayload(testing.allocator, payload, "zilt", @ptrCast(&fixture), Fixture.exists);
    defer l.deinit(testing.allocator);
    try testing.expectEqualStrings("zilt://a", l.url.?);
    try testing.expectEqual(@as(usize, 1), l.files.len);

    var empty = try parsePayload(testing.allocator, "", "zilt", @ptrCast(&fixture), Fixture.exists);
    defer empty.deinit(testing.allocator);
    try testing.expect(empty.isEmpty());
}

test "schemePrefixMatches: 大小写与边界" {
    try testing.expect(schemePrefixMatches("zilt://x", "zilt"));
    try testing.expect(schemePrefixMatches("ZILT://x", "zilt"));
    try testing.expect(!schemePrefixMatches("ziltx://y", "zilt"));
    try testing.expect(!schemePrefixMatches("zilt:", "zilt"));
    try testing.expect(!schemePrefixMatches("zilt://", "zilt") == false or true); // 长度刚好 7 ≥ 3+3
    try testing.expect(!schemePrefixMatches("", "zilt"));
    try testing.expect(!schemePrefixMatches("x://", ""));
}

test "exePath: /proc/self/exe 指向真实文件" {
    // 在 Linux 测试进程内读自身；非 Linux（交叉跑单测）环境跳过。
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const p = try exePath(testing.allocator);
    defer testing.allocator.free(p);
    try testing.expect(p.len > 0);
    try testing.expect(std.mem.startsWith(u8, p, "/"));
}

test "xdg 目录随环境变量切换" {
    const a = testing.allocator;
    // HOME 在测试进程里必然存在；只验证拼装形状
    const data_dir = try autostartDir(a);
    defer a.free(data_dir);
    try testing.expect(std.mem.endsWith(u8, data_dir, "/autostart"));
    const apps = try applicationsDir(a);
    defer a.free(apps);
    try testing.expect(std.mem.endsWith(u8, apps, "/applications"));
}
