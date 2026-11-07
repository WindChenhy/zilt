//! 深链接 / 文件关联 / 第二实例参数转发（纯 Zig）。
//!
//! 启动参数分类：`scheme://…` → URL；存在于磁盘的路径 → 文件；`--flag` 忽略。
//! 第二实例把参数以 `\n` 连接的载荷经 WM_COPYDATA 转发给首个实例。
//! 注册走 HKCU\Software\Classes（per-user，无需管理员）。

const std = @import("std");
const win32 = @import("win32.zig");

pub const Launch = struct {
    url: ?[]u8 = null,
    files: [][]u8 = &.{},

    pub fn deinit(self: *Launch, alloc: std.mem.Allocator) void {
        if (self.url) |u| alloc.free(u);
        for (self.files) |f| alloc.free(f);
        if (self.files.len > 0) alloc.free(self.files);
        self.* = .{};
    }

    pub fn isEmpty(self: Launch) bool {
        return self.url == null and self.files.len == 0;
    }
};

/// 参数列表 → Launch（跳过 `--` 开头的框架旗标与不存在的路径）。
pub fn parseArgs(alloc: std.mem.Allocator, args: []const []const u8, scheme: []const u8) !Launch {
    var out: Launch = .{};
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
        if (isExistingPath(arg)) {
            try files.append(alloc, try alloc.dupe(u8, arg));
        }
    }
    out.files = try files.toOwnedSlice(alloc);
    return out;
}

/// 第二实例转发载荷：参数以 `\n` 连接（参数本身不含换行，足够安全）。
pub fn payloadOfArgs(alloc: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (args, 0..) |a, i| {
        if (i > 0) try buf.append(alloc, '\n');
        try buf.appendSlice(alloc, a);
    }
    return buf.toOwnedSlice(alloc);
}

/// WM_COPYDATA 载荷 → Launch。
pub fn parsePayload(alloc: std.mem.Allocator, payload: []const u8, scheme: []const u8) !Launch {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer list.deinit(alloc);
    var it = std.mem.splitScalar(u8, payload, '\n');
    while (it.next()) |part| {
        if (part.len > 0) try list.append(alloc, part);
    }
    return parseArgs(alloc, list.items, scheme);
}

/// 注册 URL 协议处理器（HKCU\Software\Classes\<scheme>）。
pub fn registerProtocol(alloc: std.mem.Allocator, scheme: []const u8, app_name: []const u8, exe: []const u8) bool {
    var ok = true;
    const root = std.fmt.allocPrint(alloc, "Software\\Classes\\{s}", .{scheme}) catch return false;
    defer alloc.free(root);
    var hkey: win32.HKEY = undefined;
    if (!createKey(hkeyOf(root), &hkey)) return false;
    defer _ = win32.RegCloseKey(hkey);

    const display = std.fmt.allocPrint(alloc, "URL:{s}", .{app_name}) catch return false;
    defer alloc.free(display);
    ok = setString(alloc, hkey, "", display) and ok;
    ok = setString(alloc, hkey, "URL Protocol", "") and ok;

    const cmd_key = std.fmt.allocPrint(alloc, "{s}\\shell\\open\\command", .{root}) catch return false;
    defer alloc.free(cmd_key);
    var hcmd: win32.HKEY = undefined;
    if (!createKey(hkeyOf(cmd_key), &hcmd)) return false;
    defer _ = win32.RegCloseKey(hcmd);
    const cmd = std.fmt.allocPrint(alloc, "\"{s}\" \"%1\"", .{exe}) catch return false;
    defer alloc.free(cmd);
    ok = setString(alloc, hcmd, "", cmd) and ok;
    return ok;
}

/// 注册文件关联（HKCU\Software\Classes\<ext> → ProgID，ProgID 下挂 open\command）。
pub fn registerFileExt(alloc: std.mem.Allocator, ext: []const u8, app_id: []const u8, app_name: []const u8, exe: []const u8) bool {
    const ext_key = std.fmt.allocPrint(alloc, "Software\\Classes\\{s}", .{ext}) catch return false;
    defer alloc.free(ext_key);
    const prog_id = std.fmt.allocPrint(alloc, "{s}.File", .{app_id}) catch return false;
    defer alloc.free(prog_id);

    var h_ext: win32.HKEY = undefined;
    if (!createKey(hkeyOf(ext_key), &h_ext)) return false;
    defer _ = win32.RegCloseKey(h_ext);
    if (!setString(alloc, h_ext, "", prog_id)) return false;

    var h_prog: win32.HKEY = undefined;
    const prog_key = std.fmt.allocPrint(alloc, "Software\\Classes\\{s}", .{prog_id}) catch return false;
    defer alloc.free(prog_key);
    if (!createKey(hkeyOf(prog_key), &h_prog)) return false;
    defer _ = win32.RegCloseKey(h_prog);
    const desc = std.fmt.allocPrint(alloc, "{s} Document", .{app_name}) catch return false;
    defer alloc.free(desc);
    if (!setString(alloc, h_prog, "", desc)) return false;

    const cmd_key = std.fmt.allocPrint(alloc, "Software\\Classes\\{s}\\shell\\open\\command", .{prog_id}) catch return false;
    defer alloc.free(cmd_key);
    var h_cmd: win32.HKEY = undefined;
    if (!createKey(hkeyOf(cmd_key), &h_cmd)) return false;
    defer _ = win32.RegCloseKey(h_cmd);
    const cmd = std.fmt.allocPrint(alloc, "\"{s}\" \"%1\"", .{exe}) catch return false;
    defer alloc.free(cmd);
    return setString(alloc, h_cmd, "", cmd);
}

fn hkeyOf(sub: []const u8) struct { win32.HKEY, []const u8 } {
    return .{ win32.HKEY_CURRENT_USER, sub };
}

fn createKey(key: struct { win32.HKEY, []const u8 }, out: *win32.HKEY) bool {
    const sub_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, key[1]) catch return false;
    defer std.heap.page_allocator.free(sub_w);
    var disposition: win32.DWORD = 0;
    return win32.RegCreateKeyExW(key[0], sub_w.ptr, 0, null, 0, win32.KEY_WRITE, null, out, &disposition) == 0;
}

fn setString(alloc: std.mem.Allocator, hkey: win32.HKEY, name: []const u8, value: []const u8) bool {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return false;
    defer alloc.free(name_w);
    const value_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, value) catch return false;
    defer alloc.free(value_w);
    const bytes: [*]const u8 = @ptrCast(value_w.ptr);
    return win32.RegSetValueExW(hkey, name_w.ptr, 0, win32.REG_SZ, bytes, @intCast(value_w.len * 2)) == 0;
}

fn isExistingPath(path: []const u8) bool {
    const w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path) catch return false;
    defer std.heap.page_allocator.free(w);
    const attrs = win32.GetFileAttributesW(w.ptr);
    return attrs != win32.INVALID_FILE_ATTRIBUTES;
}

/// `scheme://…`（scheme 大小写不敏感）。
fn schemePrefixMatches(arg: []const u8, scheme: []const u8) bool {
    if (arg.len < scheme.len + 3) return false;
    if (!std.ascii.eqlIgnoreCase(arg[0..scheme.len], scheme)) return false;
    return std.mem.eql(u8, arg[scheme.len .. scheme.len + 3], "://");
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseArgs: scheme URL / 忽略旗标与不存在路径" {
    const args = [_][]const u8{ "--zilt-x", "zilt://open?id=7", "C:\\definitely\\not\\here.txt", "ZILT://upper", "" };
    const l = try parseArgs(testing.allocator, &args, "zilt");
    defer l.deinit(testing.allocator);
    try testing.expectEqualStrings("zilt://open?id=7", l.url.?);
    try testing.expectEqual(@as(usize, 0), l.files.len);
}

test "payloadOfArgs / parsePayload: 往返" {
    const args = [_][]const u8{ "zilt://a", "b", "--flag" };
    const payload = try payloadOfArgs(testing.allocator, &args);
    defer testing.allocator.free(payload);
    try testing.expectEqualStrings("zilt://a\nb\n--flag", payload);

    const l = try parsePayload(testing.allocator, payload, "zilt");
    defer l.deinit(testing.allocator);
    try testing.expectEqualStrings("zilt://a", l.url.?);
}

test "parsePayload: 空载荷" {
    const l = try parsePayload(testing.allocator, "", "zilt");
    defer l.deinit(testing.allocator);
    try testing.expect(l.isEmpty());
}
