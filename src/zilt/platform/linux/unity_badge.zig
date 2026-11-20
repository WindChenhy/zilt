//! v0.4.0 H10：Unity LauncherEntry 数值徽标（com.canonical.Unity.LauncherEntry
//! D-Bus 信号，fire-and-forget——无 Unity 监听也无害；无会话总线 → error）。
//!
//! 信号：`Update(s app_uri, a{sv} properties)` @ session bus，
//! 广播目标 com.canonical.Unity。properties：count (x)、count_visible (b)。
//! app_uri = "application://<desktop-file-id>"（与 desktop_entry 写入
//! ~/.local/share/applications/<app_id>.desktop 的文件名约定一致）。
//! 参数文本经 g_variant_parse 构造（portal_hotkey 同款——文本形式可测不易错）。

const std = @import("std");
const Allocator = std.mem.Allocator;

extern fn g_bus_get_sync(bus_type: c_int, err_ptr: ?*?*anyopaque) ?*anyopaque;
extern fn g_dbus_connection_emit_signal(
    connection: *anyopaque,
    sender_bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: [*:0]const u8,
    signal_name: [*:0]const u8,
    parameters: *anyopaque,
    err_ptr: ?*?*anyopaque,
) c_int;
extern fn g_variant_parse(
    type_ptr: ?*anyopaque,
    text: [*:0]const u8,
    limit: ?[*:0]const u8,
    endptr: ?*[*:0]const u8,
    err_ptr: ?*?*anyopaque,
) ?*anyopaque;
extern fn g_variant_unref(v: *anyopaque) void;
extern fn g_error_free(e: *anyopaque) void;

const bus_session = 2; // G_BUS_TYPE_SESSION
const unity_name = "com.canonical.Unity";
const entry_path = "/com/canonical/unity/launcherentry/zilt";
const entry_iface = "com.canonical.Unity.LauncherEntry";

/// 应用 desktop 文件 ID（LauncherEntry app_uri 基础；app_id 已带 .desktop
/// 后缀时去重——对齐 desktop_entry 的文件名约定）。
pub fn desktopId(alloc: Allocator, app_id: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, app_id, ".desktop")) return alloc.dupe(u8, app_id);
    return std.fmt.allocPrint(alloc, "{s}.desktop", .{app_id});
}

/// Update 信号参数的 GVariant 文本（(s a{sv})；count 为 int64 文本）。
pub fn buildSignalText(alloc: Allocator, desktop_id: []const u8, count: i64) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "('application://{s}', {{'count': <{d}>, 'count_visible': <true>}})",
        .{ desktop_id, count },
    );
}

/// 启动时一次性获取会话总线连接（backend init 上下文——**严禁**在 WebKit
/// script-message 回调内调用：g_bus_get_sync 的同步 I/O 会重入主循环并 abort，
/// 实测堆栈 gio→glib→JSC→WebKit→g_application_run）。无总线 → null
///（CI/Xvfb 文档化降级；WSLg 有会话总线）。
pub fn acquireSessionBus() ?*anyopaque {
    var gerr: ?*anyopaque = null;
    const conn = g_bus_get_sync(bus_session, &gerr) orelse {
        if (gerr) |e| g_error_free(e);
        return null;
    };
    return conn;
}

/// 发射 count 徽标信号（fire-and-forget；emit_signal 不阻塞、不嵌套泵——
/// 在 script-message 回调内安全）。连接来自 acquireSessionBus 的缓存。
pub fn emitBadgeCount(conn: *anyopaque, alloc: Allocator, desktop_id: []const u8, count: i64) !void {
    const text = try buildSignalText(alloc, desktop_id, count);
    defer alloc.free(text);
    const text_z = try alloc.allocSentinel(u8, text.len, 0);
    defer alloc.free(text_z);
    @memcpy(text_z, text);
    var gerr: ?*anyopaque = null;
    const v = g_variant_parse(null, text_z.ptr, null, null, &gerr) orelse {
        if (gerr) |e| g_error_free(e);
        return error.VariantParseFailed;
    };
    defer g_variant_unref(v);
    if (g_dbus_connection_emit_signal(conn, null, entry_path, entry_iface, "Update", v, &gerr) == 0) {
        if (gerr) |e| g_error_free(e);
        return error.EmitFailed;
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "desktopId 去重 .desktop 后缀" {
    const a = try desktopId(testing.allocator, "app.zilt");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("app.zilt.desktop", a);
    const b = try desktopId(testing.allocator, "app.zilt.desktop");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("app.zilt.desktop", b);
}

test "buildSignalText 形状（a{sv} 变体条目）" {
    const t = try buildSignalText(testing.allocator, "app.zilt.desktop", 5);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings(
        "('application://app.zilt.desktop', {'count': <5>, 'count_visible': <true>})",
        t,
    );
    const z = try buildSignalText(testing.allocator, "x.desktop", 0);
    defer testing.allocator.free(z);
    try testing.expect(std.mem.indexOf(u8, z, "'count': <0>") != null);
}
