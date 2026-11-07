//! 系统托盘 + 通知（Shell_NotifyIconW）。
//!
//! Windows 10+ 会把经典气球通知（NIF_INFO）自动渲染为 Toast 通知，
//! 因此无需 WinRT/COM 即可发系统通知——这是纯 Zig 路线的关键取舍。
//! 左键点击回调由宿主窗口过程接收（uCallbackMessage），行为由 backend 决定。

const std = @import("std");
const win32 = @import("win32.zig");

pub const TRAY_ID: win32.UINT = 1;

pub const Tray = struct {
    allocator: std.mem.Allocator,
    hwnd: win32.HWND,
    nid: win32.NOTIFYICONDATAW,
    active: bool = false,

    /// 构造托盘数据（不注册）。tooltip 最长 127 个 UTF-16 码元（截断）。
    pub fn init(allocator: std.mem.Allocator, hwnd: win32.HWND, callback_msg: win32.UINT, tooltip_u8: []const u8) !Tray {
        var nid: win32.NOTIFYICONDATAW = std.mem.zeroes(win32.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(win32.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = TRAY_ID;
        nid.uFlags = win32.NIF_MESSAGE | win32.NIF_ICON | win32.NIF_TIP;
        nid.uCallbackMessage = callback_msg;
        nid.hIcon = win32.LoadIconW(null, @ptrFromInt(win32.IDI_APPLICATION));

        const tip = try utf16Trunc(128, allocator, tooltip_u8);
        defer allocator.free(tip);
        @memcpy(nid.szTip[0..tip.len], tip);

        return .{ .allocator = allocator, .hwnd = hwnd, .nid = nid };
    }

    /// 注册托盘图标。
    pub fn add(self: *Tray) bool {
        self.active = win32.Shell_NotifyIconW(win32.NIM_ADD, &self.nid) != 0;
        return self.active;
    }

    /// 移除托盘图标（退出前必须调用，否则残留幽灵图标）。
    pub fn remove(self: *Tray) bool {
        if (!self.active) return true;
        self.active = false;
        return win32.Shell_NotifyIconW(win32.NIM_DELETE, &self.nid) != 0;
    }

    /// 发送系统通知（Win10+ 渲染为 Toast）。title 最长 63 码元、body 最长 255 码元（截断）。
    pub fn notify(self: *Tray, title_u8: []const u8, body_u8: []const u8) bool {
        if (!self.active) return false;
        var nid = self.nid;
        nid.uFlags = win32.NIF_INFO;
        nid.dwInfoFlags = win32.NIIF_INFO;
        nid.uTimeout = 3000;

        const title = self.allocator.alloc(u16, 64) catch return false;
        defer self.allocator.free(title);
        @memset(title, 0);
        copyTrunc(title[0..63], title_u8);

        const body = self.allocator.alloc(u16, 256) catch return false;
        defer self.allocator.free(body);
        @memset(body, 0);
        copyTrunc(body[0..255], body_u8);

        @memcpy(nid.szInfoTitle[0..title.len], title);
        @memcpy(nid.szInfo[0..body.len], body);
        return win32.Shell_NotifyIconW(win32.NIM_MODIFY, &nid) != 0;
    }
};

/// UTF-8 → UTF-16（NUL 结尾），截断到 max-1 个码元。
pub fn utf16Trunc(comptime max: usize, allocator: std.mem.Allocator, src: []const u8) ![:0]u16 {
    const full = try std.unicode.utf8ToUtf16LeAllocZ(allocator, src);
    defer allocator.free(full);
    const n = @min(full.len, max - 1);
    const out = try allocator.allocSentinel(u16, n, 0);
    @memcpy(out[0..n], full[0..n]);
    return out;
}

/// 把 UTF-8 截断复制进定长 UTF-16 缓冲（不含 NUL 的部分，缓冲须已清零）。
fn copyTrunc(dest_u16: []u16, src_u8: []const u8) void {
    var i: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(src_u8).iterator();
    while (it.nextCodepointSlice()) |cp_slice| {
        const cp = std.unicode.utf8Decode(cp_slice) catch continue;
        const n = encodeUtf16Cp(cp, dest_u16[i..]);
        if (n == 0) break;
        i += n;
    }
}

/// 单码点 UTF-16 编码（0.17 std 无 utf16EncodeCodepoint，手写）。
fn encodeUtf16Cp(cp: u21, dest: []u16) usize {
    if (cp < 0x10000) {
        if (dest.len < 1) return 0;
        dest[0] = @intCast(cp);
        return 1;
    }
    if (dest.len < 2) return 0;
    const v = cp - 0x10000;
    dest[0] = @intCast(0xD800 + (v >> 10));
    dest[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

/// 单实例互斥体名。
pub fn singleInstanceMutexName(allocator: std.mem.Allocator, app_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Local\\zilt-single-{s}", .{app_id});
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Tray.init: 结构体字段与 tooltip" {
    var tray = try Tray.init(testing.allocator, @ptrFromInt(0x1000), 0x8100, "Zilt 托盘");
    defer tray.allocator.free(tray.nid.szTip[0..0]); // szTip 内嵌数组无需释放

    try testing.expectEqual(@sizeOf(win32.NOTIFYICONDATAW), tray.nid.cbSize);
    try testing.expectEqual(@as(win32.UINT, 1), tray.nid.uID);
    try testing.expect(win32.NIF_MESSAGE | win32.NIF_ICON | win32.NIF_TIP == tray.nid.uFlags);
    try testing.expectEqual(@as(win32.UINT, 0x8100), tray.nid.uCallbackMessage);
    try testing.expectEqualSlices(u16, &.{ 'Z', 'i', 'l', 't', ' ', 0x6258, 0x76D8 }, tray.nid.szTip[0..6]);
    try testing.expectEqual(@as(u16, 0), tray.nid.szTip[6]);
    try testing.expect(!tray.active);
}

test "utf16Trunc: 边界截断 + NUL" {
    // 5 码元上限 → 保留 4 个
    const t = try utf16Trunc(5, testing.allocator, "12345");
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(usize, 4), t.len);
    try testing.expectEqual(@as(u16, 0), t[4]);

    // 短于上限 → 原样
    const s = try utf16Trunc(16, testing.allocator, "hi");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hi", std.unicode.utf16LeToUtf8Alloc(testing.allocator, s) catch unreachable);

    // 多字节字符不跨界截断（按码元数）
    const c = try utf16Trunc(3, testing.allocator, "你a你b");
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 2), c.len); // 你 + a
}

test "Tray.notify 字段构造（不发系统调用）" {
    // 直接验证 copyTrunc 逻辑路径：notify 需要 active=true + 真实 hwnd，
    // 这里只测数据准备函数的行为边界。
    var buf: [64]u16 = @splat(0);
    copyTrunc(buf[0..63], "标题");
    try testing.expectEqual(@as(u16, 0x6807), buf[0]); // '标'
    try testing.expectEqual(@as(u16, 0), buf[2]); // NUL 后清零区
}

test "singleInstanceMutexName" {
    const n = try singleInstanceMutexName(testing.allocator, "app.zilt.desktop");
    defer testing.allocator.free(n);
    try testing.expectEqualStrings("Local\\zilt-single-app.zilt.desktop", n);
}
