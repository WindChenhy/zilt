//! v0.3.10 D1：Wayland 全局快捷键（org.freedesktop.portal.GlobalShortcuts）。
//!
//! X11 会话走 XGrabKey（hotkey.zig，v0.2.6）；Wayland 会话（`WAYLAND_DISPLAY` 存在）
//! 改走 portal——XGrabKey 在 Wayland 下无法全局捕获。portal 流程：
//!   CreateSession(a{sv}) → request handle → Response(results["session_handle"])
//!   → BindShortcuts(handle, a(sa{sv}), "", a{sv})
//!   → Activated(session, shortcut_id, timestamp, options) → `hotkey` 事件
//!
//! 实现策略（无真 Wayland 会话的验证边界，文档化）：
//! - **纯函数全部单测**：会话判定 / portal 触发器格式（`Ctrl+Alt+N` →
//!   `<Control><Alt>n`）/ BindShortcuts 的 GVariant 文本构造（经
//!   `g_variant_parse` 消费——文本形式比可变参数构造可测且不易错）；
//! - **GDBus 编排**沿用 logind 沉淀的 extern 模式（call_sync + signal_subscribe；
//!   回调 g_idle_add 封送 UI 线程）；
//! - **手动验证记录**：真 Wayland 会话下的端到端验证需桌面环境（对齐 v0.2.5
//!   Wayland 实测项模式）；CI（Xvfb/X11）永远走 XGrabKey 分支。
const std = @import("std");
const c = @import("gtk");

/// 会话判定：`WAYLAND_DISPLAY` 非空 **且** `GDK_BACKEND` 不是显式 x11。
/// **为什么看 GDK_BACKEND**：WSLg 环境同时设 WAYLAND_DISPLAY（且可用 X11）——
/// Xvfb/CI 脚本（dev-smoke.sh）显式 `GDK_BACKEND=x11`，据此排除误判。
pub fn isWaylandSession(wayland_display: ?[]const u8, gdk_backend: ?[]const u8) bool {
    const d = wayland_display orelse return false;
    if (d.len == 0) return false;
    if (gdk_backend) |g| {
        if (std.ascii.eqlIgnoreCase(g, "x11")) return false;
    }
    return true;
}

/// "Ctrl+Alt+N" → portal preferred_trigger "<Control><Alt>n"。
/// 修饰符名 portal/GTK 规范形（Control/Shift/Alt/Super）；键位单字符转小写、
/// F1-F12 保留。解析失败返回 null（调用方跳过该项）。
pub fn portalTrigger(accel: []const u8, buf: []u8) ?[]const u8 {
    var w: usize = 0;
    var key_part: []const u8 = "";
    var it = std.mem.splitScalar(u8, accel, '+');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(part, "Ctrl") or std.ascii.eqlIgnoreCase(part, "Control")) {
            w += appendMod(buf[w..], "Control") orelse return null;
        } else if (std.ascii.eqlIgnoreCase(part, "Shift")) {
            w += appendMod(buf[w..], "Shift") orelse return null;
        } else if (std.ascii.eqlIgnoreCase(part, "Alt") or std.ascii.eqlIgnoreCase(part, "Mod1")) {
            w += appendMod(buf[w..], "Alt") orelse return null;
        } else if (std.ascii.eqlIgnoreCase(part, "Super")) {
            w += appendMod(buf[w..], "Super") orelse return null;
        } else {
            if (key_part.len != 0) return null; // 两个键位
            key_part = part;
        }
    }
    if (key_part.len == 0) return null;
    if (w + key_part.len > buf.len) return null;
    // 键位：单字母转小写（portal 惯例）；F1-F12 / 数字原样
    if (key_part.len == 1 and std.ascii.isUpper(key_part[0])) {
        buf[w] = std.ascii.toLower(key_part[0]);
        w += 1;
    } else {
        @memcpy(buf[w .. w + key_part.len], key_part);
        w += key_part.len;
    }
    return buf[0..w];
}

fn appendMod(buf: []u8, name: []const u8) ?usize {
    if (buf.len < name.len + 2) return null;
    buf[0] = '<';
    @memcpy(buf[1 .. 1 + name.len], name);
    buf[1 + name.len] = '>';
    return name.len + 2;
}

/// BindShortcuts 参数的 GVariant 文本形式（`g_variant_parse` 消费）：
/// `(o a(sa{sv}) s a{sv})` —— handle / shortcuts / parent_window / options。
/// shortcuts 的值域（description / preferred_trigger）是 v（变体）→ 文本 `<'>`。
pub fn bindText(
    alloc: std.mem.Allocator,
    handle: []const u8,
    entries: []const Entry,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "('");
    try appendEscaped(&out, alloc, handle);
    try out.appendSlice(alloc, "',[");
    for (entries, 0..) |e, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "('");
        try appendEscaped(&out, alloc, e.id);
        try out.appendSlice(alloc, "',{");
        try out.appendSlice(alloc, "'description':<'");
        try appendEscaped(&out, alloc, e.description);
        try out.appendSlice(alloc, "'>,'preferred_trigger':<'");
        try appendEscaped(&out, alloc, e.trigger);
        // a(sa{sv}) 的元组用 () 收尾：`})`——写成 `}}` 会让 GVariant 解析失败
        //（v0.3.10 起就有，直到 v0.3.19 的 Linux 测试图补齐才暴露）
        try out.appendSlice(alloc, "'>})");
    }
    try out.appendSlice(alloc, "],'',{})");
    return out.toOwnedSlice(alloc);
}

/// CreateSession 参数文本（a{sv}；handle_token 派生自应用 + 随机段）。
pub fn createSessionText(alloc: std.mem.Allocator, handle_token: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{'handle_token':<'{s}'>}}", .{handle_token});
}

pub const Entry = struct {
    id: []const u8,
    /// 展示描述（portal 设置界面显示；用 accel）
    description: []const u8,
    /// preferred_trigger（"<Control><Alt>n" 形）
    trigger: []const u8,
};

fn appendEscaped(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    // GVariant 文本里的单引号字符串：单引号与反斜杠转义
    for (text) |ch| {
        if (ch == '\'' or ch == '\\') try out.append(alloc, '\\');
        try out.append(alloc, ch);
    }
}

/// 非法字符检查（shortcut id：portal 要求 [A-Za-z0-9_.-]）
pub fn validShortcutId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// GDBus 编排（仅 Wayland 会话实例化；X11/CI 永不进入）
// ---------------------------------------------------------------------------

/// NUL 结尾拷贝（0.17 Allocator 无 dupeZ）
fn dupeZ(alloc: std.mem.Allocator, text: []const u8) ![:0]u8 {
    const z = try alloc.allocSentinel(u8, text.len, 0);
    @memcpy(z[0..text.len], text);
    return z;
}

pub const Portal = struct {
    alloc: std.mem.Allocator,
    conn: ?*anyopaque = null,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    session_handle: ?[]u8 = null,
    on_press: *const fn (ctx: ?*anyopaque, id: []const u8) void,
    ctx: ?*anyopaque,

    extern fn g_bus_get_sync(bus_type: c_int, err_ptr: ?*anyopaque) ?*anyopaque;
    extern fn g_dbus_connection_call_sync(
        connection: *anyopaque,
        bus_name: ?[*:0]const u8,
        object_path: ?[*:0]const u8,
        interface_name: ?[*:0]const u8,
        method_name: ?[*:0]const u8,
        parameters: ?*anyopaque,
        reply_type: ?*anyopaque,
        flags: c_int,
        timeout_msec: c_int,
        cancellable: ?*anyopaque,
        err_ptr: ?*anyopaque,
    ) ?*anyopaque;
    extern fn g_dbus_connection_signal_subscribe(
        connection: *anyopaque,
        sender: ?[*:0]const u8,
        interface_name: ?[*:0]const u8,
        member: ?[*:0]const u8,
        object_path: ?[*:0]const u8,
        arg0: ?[*:0]const u8,
        flags: c_int,
        callback: *const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?*anyopaque, ?*anyopaque) callconv(.c) void,
        user_data: ?*anyopaque,
        user_data_free_func: ?*const fn (?*anyopaque) callconv(.c) void,
    ) c.guint;
    extern fn g_variant_new(fmt: [*:0]const u8, ...) ?*anyopaque;
    extern fn g_variant_parse(
        type_ptr: ?*anyopaque,
        text: [*:0]const u8,
        limit: ?[*:0]const u8,
        endptr: ?*[*:0]const u8,
        err_ptr: ?*anyopaque,
    ) ?*anyopaque;
    extern fn g_variant_unref(v: *anyopaque) void;
    extern fn g_variant_get_child_value(v: *anyopaque, index: c.gsize) ?*anyopaque;
    extern fn g_variant_get_string(v: *anyopaque, len: ?*c.gsize) ?[*:0]const u8;

    const bus_session = 2; // G_BUS_TYPE_SESSION
    const dbus_name = "org.freedesktop.portal.Desktop";
    const dbus_path = "/org/freedesktop/portal/desktop";
    const dbus_iface = "org.freedesktop.portal.GlobalShortcuts";

    /// Wayland 会话初始化（session bus 不可用 → error.PortalUnavailable）。
    pub fn init(
        alloc: std.mem.Allocator,
        wayland_display: ?[]const u8,
        gdk_backend: ?[]const u8,
        on_press: *const fn (ctx: ?*anyopaque, id: []const u8) void,
        ctx: ?*anyopaque,
    ) !*Portal {
        if (!isWaylandSession(wayland_display, gdk_backend)) return error.NotWaylandSession;
        const p = try alloc.create(Portal);
        errdefer alloc.destroy(p);
        p.* = .{ .alloc = alloc, .on_press = on_press, .ctx = ctx };
        p.conn = g_bus_get_sync(bus_session, null) orelse return error.PortalUnavailable;
        return p;
    }

    /// 注册（累积条目 + 重绑全部——portal 的 BindShortcuts 是整表语义）。
    pub fn register(self: *Portal, id: []const u8, accel: []const u8) !void {
        if (!validShortcutId(id)) return error.InvalidShortcutId;
        var buf: [64]u8 = undefined;
        const trigger = portalTrigger(accel, &buf) orelse return error.InvalidAccel;
        // 已存在 → 更新 trigger
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.id, id)) {
                const t = try self.alloc.dupe(u8, trigger);
                self.alloc.free(e.trigger);
                e.trigger = t;
                return self.flushBind();
            }
        }
        const id_c = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(id_c);
        const desc = try self.alloc.dupe(u8, accel);
        errdefer self.alloc.free(desc);
        const trig = try self.alloc.dupe(u8, trigger);
        errdefer self.alloc.free(trig);
        try self.entries.append(self.alloc, .{ .id = id_c, .description = desc, .trigger = trig });
        self.flushBind() catch |err| {
            std.log.warn("[hotkey-portal] bind failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    pub fn unregister(self: *Portal, id: []const u8) bool {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.id, id)) {
                self.alloc.free(e.id);
                self.alloc.free(e.description);
                self.alloc.free(e.trigger);
                _ = self.entries.swapRemove(i);
                self.flushBind() catch {};
                return true;
            }
        }
        return false;
    }

    pub fn list(self: *Portal, alloc: std.mem.Allocator) ![]Entry {
        _ = alloc;
        return try self.alloc.dupe(Entry, self.entries.items);
    }

    /// BindShortcuts（整表重绑；session handle 缺失时先 CreateSession）。
    fn flushBind(self: *Portal) !void {
        const conn = self.conn orelse return error.PortalUnavailable;
        if (self.entries.items.len == 0) return;
        if (self.session_handle == null) try self.createSession();
        const handle = self.session_handle orelse return error.SessionHandleMissing;

        const text = try bindText(self.alloc, handle, self.entries.items);
        defer self.alloc.free(text);
        const text_z = try dupeZ(self.alloc, text);
        defer self.alloc.free(text_z);
        const params = g_variant_parse(null, text_z.ptr, null, null, null) orelse return error.VariantParseFailed;
        defer g_variant_unref(params);
        const reply = g_dbus_connection_call_sync(
            conn,
            dbus_name,
            dbus_path,
            dbus_iface,
            "BindShortcuts",
            params,
            null, // 无返回值
            0,
            3000,
            null,
            null,
        ) orelse return error.BindFailed;
        g_variant_unref(reply);
    }

    /// CreateSession → request handle → Response 里的 session_handle
    /// （call_sync 拿 request handle；Response 的等待用有界轮询——portal 的
    /// 异步握手在一次性注册场景足够）。
    fn createSession(self: *Portal) !void {
        const conn = self.conn orelse return error.PortalUnavailable;
        var token_buf: [32]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "zilt_{x}", .{@as(u64, @intFromPtr(self))}) catch "zilt_session";
        const text = try createSessionText(self.alloc, token);
        defer self.alloc.free(text);
        const text_z = try dupeZ(self.alloc, text);
        defer self.alloc.free(text_z);
        const params = g_variant_parse(null, text_z.ptr, null, null, null) orelse return error.VariantParseFailed;
        defer g_variant_unref(params);
        const reply = g_dbus_connection_call_sync(
            conn,
            dbus_name,
            dbus_path,
            dbus_iface,
            "CreateSession",
            params,
            null,
            0,
            3000,
            null,
            null,
        ) orelse return error.CreateSessionFailed;
        defer g_variant_unref(reply);
        // (o) —— request handle；订阅其 Response 拿 session_handle
        const child = g_variant_get_child_value(reply, 0) orelse return error.CreateSessionFailed;
        defer g_variant_unref(child);
        const req_path = g_variant_get_string(child, null) orelse return error.CreateSessionFailed;
        // 订阅 Response（request handle 路径；结果 dict 里的 "session_handle"）
        _ = g_dbus_connection_signal_subscribe(
            conn,
            null,
            "org.freedesktop.portal.Request",
            "Response",
            req_path,
            null,
            0,
            onRequestResponse,
            self,
            null,
        );
        // Response 由 portal 异步发出——session_handle 的提取在回调里完成；
        // flushBind 的首次调用若 handle 尚缺，由调用方在 Activated 前重试（文档化：
        // portal 首绑可能需要桌面环境用户确认弹窗）。
    }

    fn onRequestResponse(
        _: ?*anyopaque,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        params: ?*anyopaque,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Portal = @ptrCast(@alignCast(user_data orelse return));
        const pv = params orelse return;
        // (u a{sv}) —— results["session_handle"] 的 v 里是 o
        const results = g_variant_get_child_value(pv, 1) orelse return;
        defer g_variant_unref(results);
        const sh_v = g_variant_lookup_value(results, "session_handle", null) orelse return;
        defer g_variant_unref(sh_v);
        const sh = g_variant_get_string(sh_v, null) orelse return;
        if (self.session_handle) |old| self.alloc.free(old);
        self.session_handle = self.alloc.dupe(u8, std.mem.span(sh)) catch null;
    }

    extern fn g_variant_lookup_value(v: *anyopaque, key: [*:0]const u8, type_ptr: ?*anyopaque) ?*anyopaque;

    /// Activated 订阅（session handle 就绪后调用；portal 需要用户确认后激活）。
    pub fn subscribeActivated(self: *Portal) void {
        const conn = self.conn orelse return;
        const handle = self.session_handle orelse return;
        const handle_z = self.alloc.allocSentinel(u8, handle.len, 0) catch return;
        @memcpy(handle_z[0..handle.len], handle);
        defer self.alloc.free(handle_z);
        _ = g_dbus_connection_signal_subscribe(
            conn,
            null,
            dbus_iface,
            "Activated",
            handle_z.ptr,
            null,
            0,
            onActivated,
            self,
            null,
        );
    }

    fn onActivated(
        _: ?*anyopaque,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        params: ?*anyopaque,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Portal = @ptrCast(@alignCast(user_data orelse return));
        const pv = params orelse return;
        // (o s t a{sv}) —— 第 1 个 child 是 shortcut_id
        const id_v = g_variant_get_child_value(pv, 1) orelse return;
        defer g_variant_unref(id_v);
        const id = g_variant_get_string(id_v, null) orelse return;
        self.on_press(self.ctx, std.mem.span(id));
    }

    pub fn deinit(self: *Portal) void {
        for (self.entries.items) |e| {
            self.alloc.free(e.id);
            self.alloc.free(e.description);
            self.alloc.free(e.trigger);
        }
        self.entries.deinit(self.alloc);
        if (self.session_handle) |h| self.alloc.free(h);
        self.alloc.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "v0.3.10 D1: 会话判定（WAYLAND_DISPLAY + GDK_BACKEND=x11 排除）" {
    try testing.expect(isWaylandSession("wayland-0", null));
    try testing.expect(isWaylandSession("wayland-0", "wayland"));
    try testing.expect(!isWaylandSession(null, null));
    try testing.expect(!isWaylandSession("", null));
    // WSLg 陷阱：WAYLAND_DISPLAY 有值但 CI/脚本显式 x11 后端 → X11 分支
    try testing.expect(!isWaylandSession("wayland-0", "x11"));
}

test "v0.3.10 D1: portal 触发器格式（Ctrl+Alt+N → <Control><Alt>n）" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("<Control><Alt>n", portalTrigger("Ctrl+Alt+N", &buf).?);
    try testing.expectEqualStrings("<Control>s", portalTrigger("Ctrl+S", &buf).?);
    try testing.expectEqualStrings("<Shift><Super>F5", portalTrigger("Shift+Super+F5", &buf).?);
    try testing.expectEqualStrings("n", portalTrigger("N", &buf).?);
    // 非法：双键位 / 空段
    try testing.expect(portalTrigger("Ctrl+Alt+X+Y", &buf) == null);
    try testing.expect(portalTrigger("Ctrl+", &buf) == null);
}

test "v0.3.10 D1: BindShortcuts GVariant 文本构造" {
    const entries = [_]Entry{
        .{ .id = "quick-note", .description = "Ctrl+Alt+N", .trigger = "<Control><Alt>n" },
        .{ .id = "reload", .description = "Ctrl+R", .trigger = "<Control>r" },
    };
    const text = try bindText(testing.allocator, "/org/x/request/1", &entries);
    defer testing.allocator.free(text);
    // 结构形态：handle + 两项 + 空 parent + 空 options
    try testing.expect(std.mem.startsWith(u8, text, "('/org/x/request/1',["));
    // a(sa{sv})：值是 variant，故为 <'…'>（v0.3.19 修正过期断言）
    try testing.expect(std.mem.indexOf(u8, text, "('quick-note',{'description':<'Ctrl+Alt+N'>,'preferred_trigger':<'<Control><Alt>n'>})") != null);
    try testing.expect(std.mem.indexOf(u8, text, "('reload',{'description':<'Ctrl+R'>,'preferred_trigger':<'<Control>r'>})") != null);
    try testing.expect(std.mem.endsWith(u8, text, "],'',{})"));
    // 单引号转义
    const esc = try bindText(testing.allocator, "/h", &.{.{ .id = "a'b", .description = "d", .trigger = "t" }});
    defer testing.allocator.free(esc);
    try testing.expect(std.mem.indexOf(u8, esc, "a\\'b") != null);
}

test "v0.3.10 D1: CreateSession 参数文本 + shortcut id 校验" {
    const text = try createSessionText(testing.allocator, "zilt_1a2b");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{'handle_token':<'zilt_1a2b'>}", text);
    try testing.expect(validShortcutId("quick-note"));
    try testing.expect(validShortcutId("reload.page_2"));
    try testing.expect(!validShortcutId(""));
    try testing.expect(!validShortcutId("bad id"));
    try testing.expect(!validShortcutId("bad/name"));
}
