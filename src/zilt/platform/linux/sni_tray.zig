//! GTK4 托盘（v0.6.1 L1b）：自实现 StatusNotifierItem + DBusMenu（GDBus）。
//!
//! 背景：libayatana-appindicator3 是 GTK3 链接库，GTK4 进程不可载（符号冲突）；
//! GtkStatusIcon 在 GTK4 移除。这里直接走会话总线的标准协议，不依赖 GTK 控件：
//!
//!   * `/StatusNotifierItem`（org.kde.StatusNotifierItem）——宿主（GNOME 扩展 /
//!     KDE 面板）绘制图标，左键 Activate → 回调切换挂窗，右键由宿主按
//!     `Menu` 属性拉取 DBusMenu；
//!   * `/MenuBar`（com.canonical.dbusmenu）——菜单树直接由运行时 `menu_model`
//!     （arena 节点，生命周期稳定）构造；`menu.*` op 重建后 revision++ 并发
//!     `LayoutUpdated`。
//!
//! 降级：无会话总线 / 无 watcher（Xvfb、纯 X11 桌面）只记日志，应用照常运行
//! ——与 GTK3 侧「libayatana 缺失 = 无托盘图标」同一语义。
//!
//! 说明：org.freedesktop.DBus.Properties 由 GDBus 依据接口 XML 的 property 声明
//! 自动实现（get_property 回调）；这里不重复注册 Properties 接口。

const std = @import("std");
const c = @import("gtk");
const menu_model = @import("../../menu_model.zig");
const gtk_compat = @import("gtk_compat.zig");
const log = @import("../../log.zig");

const Allocator = std.mem.Allocator;

/// NUL 结尾副本（Zig 0.17 的 Allocator 已移除 dupeZ；C API 传参需要 sentinel）。
fn dupeZ(alloc: Allocator, s: []const u8) ![:0]u8 {
    const buf = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(buf, s);
    return buf;
}

const item_path = "/StatusNotifierItem";
const menu_path = "/MenuBar";
const item_iface = "org.kde.StatusNotifierItem";
const menu_iface = "com.canonical.dbusmenu";

const item_xml =
    \\<node>
    \\  <interface name="org.kde.StatusNotifierItem">
    \\    <property name="Category" type="s" access="read"/>
    \\    <property name="Id" type="s" access="read"/>
    \\    <property name="Title" type="s" access="read"/>
    \\    <property name="Status" type="s" access="read"/>
    \\    <property name="IconName" type="s" access="read"/>
    \\    <property name="IconThemePath" type="s" access="read"/>
    \\    <property name="Menu" type="o" access="read"/>
    \\    <property name="ItemIsMenu" type="b" access="read"/>
    \\    <method name="Activate">
    \\      <arg name="x" type="i" direction="in"/>
    \\      <arg name="y" type="i" direction="in"/>
    \\    </method>
    \\    <method name="SecondaryActivate">
    \\      <arg name="x" type="i" direction="in"/>
    \\      <arg name="y" type="i" direction="in"/>
    \\    </method>
    \\    <method name="ContextMenu">
    \\      <arg name="x" type="i" direction="in"/>
    \\      <arg name="y" type="i" direction="in"/>
    \\    </method>
    \\    <method name="Scroll">
    \\      <arg name="delta" type="i" direction="in"/>
    \\      <arg name="orientation" type="s" direction="in"/>
    \\    </method>
    \\  </interface>
    \\</node>
;

const menu_xml =
    \\<node>
    \\  <interface name="com.canonical.dbusmenu">
    \\    <property name="Version" type="u" access="read"/>
    \\    <property name="TextDirection" type="s" access="read"/>
    \\    <property name="Status" type="s" access="read"/>
    \\    <property name="IconThemePath" type="as" access="read"/>
    \\    <method name="GetLayout">
    \\      <arg name="parentId" type="i" direction="in"/>
    \\      <arg name="recursionDepth" type="i" direction="in"/>
    \\      <arg name="propertyNames" type="as" direction="in"/>
    \\      <arg name="revision" type="u" direction="out"/>
    \\      <arg name="layout" type="(ia{sv}av)" direction="out"/>
    \\    </method>
    \\    <method name="GetGroupProperties">
    \\      <arg name="ids" type="ai" direction="in"/>
    \\      <arg name="propertyNames" type="as" direction="in"/>
    \\      <arg name="properties" type="a(ia{sv})" direction="out"/>
    \\    </method>
    \\    <method name="GetProperty">
    \\      <arg name="id" type="i" direction="in"/>
    \\      <arg name="name" type="s" direction="in"/>
    \\      <arg name="value" type="v" direction="out"/>
    \\    </method>
    \\    <method name="Event">
    \\      <arg name="id" type="i" direction="in"/>
    \\      <arg name="eventId" type="s" direction="in"/>
    \\      <arg name="data" type="v" direction="in"/>
    \\      <arg name="timestamp" type="u" direction="in"/>
    \\    </method>
    \\    <method name="EventGroup">
    \\      <arg name="events" type="a(isvu)" direction="in"/>
    \\      <arg name="idErrors" type="ai" direction="out"/>
    \\    </method>
    \\    <method name="AboutToShow">
    \\      <arg name="id" type="i" direction="in"/>
    \\      <arg name="needUpdate" type="b" direction="out"/>
    \\    </method>
    \\    <method name="AboutToShowGroup">
    \\      <arg name="ids" type="ai" direction="in"/>
    \\      <arg name="updatesNeeded" type="ai" direction="out"/>
    \\      <arg name="idErrors" type="ai" direction="out"/>
    \\    </method>
    \\    <signal name="LayoutUpdated">
    \\      <arg name="revision" type="u"/>
    \\      <arg name="parentId" type="i"/>
    \\    </signal>
    \\    <signal name="ItemsPropertiesUpdated">
    \\      <arg name="updatedProps" type="a(ia{sv})"/>
    \\      <arg name="removedProps" type="a(ias)"/>
    \\    </signal>
    \\  </interface>
    \\</node>
;

/// 注册上下文：一个路径 + 一个接口的 vtable user_data。
const Ctx = struct {
    tray: *Tray,
    kind: enum { item, menu },
    registration: c.guint = 0,
};

pub const Options = struct {
    app_id: []const u8,
    title: []const u8,
    icon_name: []const u8,
    /// 图标所在目录（可选；SNI IconThemePath，宿主据此找文件图标）
    icon_dir: ?[]const u8 = null,
    /// 左键 Activate / SecondaryActivate（挂窗 toggle）
    on_activate: *const fn (ctx: ?*anyopaque) callconv(.c) void,
    /// DBusMenu 菜单项 clicked
    on_menu: *const fn (ctx: ?*anyopaque, node: ?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque = null,
};

/// SNI 托盘实例（堆分配；GDBus vtable 以指针为 user_data，不可移动）。
pub const Tray = struct {
    allocator: Allocator,
    conn: ?*anyopaque = null,
    bus_name: ?[]u8 = null,
    item_ctx: ?*Ctx = null,
    menu_ctx: ?*Ctx = null,
    app_id: []u8 = &.{},
    title: []u8 = &.{},
    icon_name: []u8 = &.{},
    icon_dir: []u8 = &.{},
    /// 字符串是否由 dupe 分配（空串也可能来自 dupe；close 只释放一次）
    strings_owned: bool = false,
    on_activate: *const fn (ctx: ?*anyopaque) callconv(.c) void,
    on_menu: *const fn (ctx: ?*anyopaque, node: ?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque = null,
    /// 当前菜单树（menu_model arena 节点，重建前有效）
    roots: []*menu_model.Node = &.{},
    ids: std.AutoHashMapUnmanaged(i32, *menu_model.Node) = .empty,
    revision: u32 = 1,
    ready: bool = false,

    /// 创建并注册 D-Bus 对象。失败（无总线）→ 返回仍可 close 的实例（降级）。
    pub fn init(allocator: Allocator, opts: Options) !Tray {
        if (!gtk_compat.isGtk4()) return error.Unsupported;
        const app_id = try allocator.dupe(u8, opts.app_id);
        errdefer allocator.free(app_id);
        const title = try allocator.dupe(u8, opts.title);
        errdefer allocator.free(title);
        const icon_name = try allocator.dupe(u8, opts.icon_name);
        errdefer allocator.free(icon_name);
        const icon_dir = try allocator.dupe(u8, opts.icon_dir orelse "");
        errdefer allocator.free(icon_dir);

        var tray = Tray{
            .allocator = allocator,
            .app_id = app_id,
            .title = title,
            .icon_name = icon_name,
            .icon_dir = icon_dir,
            .strings_owned = true,
            .on_activate = opts.on_activate,
            .on_menu = opts.on_menu,
            .ctx = opts.ctx,
        };
        tray.connect();
        return tray;
    }

    fn freeStrings(self: *Tray) void {
        if (!self.strings_owned) return;
        self.strings_owned = false;
        self.allocator.free(self.app_id);
        self.allocator.free(self.title);
        self.allocator.free(self.icon_name);
        self.allocator.free(self.icon_dir);
        self.app_id = &.{};
        self.title = &.{};
        self.icon_name = &.{};
        self.icon_dir = &.{};
    }

    pub fn close(self: *Tray) void {
        if (self.conn) |conn| {
            if (self.item_ctx) |ctx| {
                if (ctx.registration != 0) {
                    _ = c.g_dbus_connection_unregister_object(@ptrCast(@alignCast(conn)), ctx.registration);
                }
                self.allocator.destroy(ctx);
                self.item_ctx = null;
            }
            if (self.menu_ctx) |ctx| {
                if (ctx.registration != 0) {
                    _ = c.g_dbus_connection_unregister_object(@ptrCast(@alignCast(conn)), ctx.registration);
                }
                self.allocator.destroy(ctx);
                self.menu_ctx = null;
            }
            if (self.bus_name) |name| {
                if (dupeZ(self.allocator, name)) |name_z| {
                    defer self.allocator.free(name_z);
                    if (c.g_variant_new("(s)", name_z.ptr)) |params| {
                        if (c.g_dbus_connection_call_sync(
                            @ptrCast(@alignCast(conn)),
                            "org.freedesktop.DBus",
                            "/org/freedesktop/DBus",
                            "org.freedesktop.DBus",
                            "ReleaseName",
                            @ptrCast(params),
                            null,
                            0,
                            -1,
                            null,
                            null,
                        )) |reply| c.g_variant_unref(@ptrCast(@alignCast(reply)));
                    }
                } else |_| {}
                self.allocator.free(name);
                self.bus_name = null;
            }
            // 会话总线连接由 GIO 全局缓存持有；这里只放弃引用
            c.g_object_unref(@ptrCast(@alignCast(conn)));
            self.conn = null;
        }
        self.ids.deinit(self.allocator);
        self.ids = .empty;
        self.freeStrings();
        self.roots = &.{};
        self.ready = false;
    }

    /// 更新菜单树（DFS 重编号 + 发 LayoutUpdated）。空树也合法。
    pub fn setMenu(self: *Tray, roots: []*menu_model.Node) void {
        self.roots = roots;
        self.ids.clearRetainingCapacity();
        var next: i32 = 1;
        for (roots) |node| self.indexNode(node, &next);
        self.revision +%= 1;
        self.emitLayoutUpdated();
    }

    fn indexNode(self: *Tray, node: *menu_model.Node, next: *i32) void {
        const id = next.*;
        next.* += 1;
        self.ids.put(self.allocator, id, node) catch {};
        for (node.children.items) |child| self.indexNode(child, next);
    }

    fn emitLayoutUpdated(self: *Tray) void {
        const conn = self.conn orelse return;
        _ = c.g_dbus_connection_emit_signal(
            @ptrCast(@alignCast(conn)),
            null,
            menu_path,
            menu_iface,
            "LayoutUpdated",
            c.g_variant_new("(ui)", self.revision, @as(c_int, 0)),
            null,
        );
    }

    // ------------------------------------------------------------------
    // 总线连接 / 对象注册 / watcher
    // ------------------------------------------------------------------

    fn connect(self: *Tray) void {
        // G_BUS_TYPE_SESSION = 1
        const conn = c.g_bus_get_sync(1, null, null) orelse {
            log.print("[tray] no session bus — SNI tray disabled", .{});
            return;
        };
        self.conn = conn;

        const pid = std.os.linux.getpid();
        const name = std.fmt.allocPrint(self.allocator, "org.kde.StatusNotifierItem-{d}-1", .{pid}) catch return;
        self.bus_name = name;

        // 同步占用总线名（避免异步竞态：紧接着的 watcher 注册需要它已生效）
        const name_z = dupeZ(self.allocator, name) catch return;
        defer self.allocator.free(name_z);
        if (c.g_variant_new("(su)", name_z.ptr, @as(c_uint, 4))) |params| {
            const reply = c.g_dbus_connection_call_sync(
                @ptrCast(@alignCast(conn)),
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "RequestName",
                @ptrCast(params),
                null,
                0,
                -1,
                null,
                null,
            );
            if (reply) |r| c.g_variant_unref(@ptrCast(@alignCast(r)));
        }

        const item_ctx = self.allocator.create(Ctx) catch return;
        item_ctx.* = .{ .tray = self, .kind = .item };
        if (!self.registerObject(conn, item_path, item_xml, item_iface, item_ctx)) {
            self.allocator.destroy(item_ctx);
            return;
        }
        self.item_ctx = item_ctx;

        const menu_ctx = self.allocator.create(Ctx) catch return;
        menu_ctx.* = .{ .tray = self, .kind = .menu };
        if (!self.registerObject(conn, menu_path, menu_xml, menu_iface, menu_ctx)) {
            self.allocator.destroy(menu_ctx);
            return;
        }
        self.menu_ctx = menu_ctx;

        self.registerWatcher(name_z);
        self.ready = true;
        log.print("[tray] SNI registered as '{s}'", .{name});
    }

    fn registerObject(self: *Tray, conn: ?*anyopaque, path: []const u8, xml: []const u8, iface: []const u8, ctx: *Ctx) bool {
        const xml_z = dupeZ(self.allocator, xml) catch return false;
        defer self.allocator.free(xml_z);
        const path_z = dupeZ(self.allocator, path) catch return false;
        defer self.allocator.free(path_z);
        const iface_z = dupeZ(self.allocator, iface) catch return false;
        defer self.allocator.free(iface_z);

        var err: ?*c.GError = null;
        const info = c.g_dbus_node_info_new_for_xml(xml_z.ptr, &err) orelse {
            if (err) |e| {
                log.print("[tray] D-Bus XML invalid: {s}", .{std.mem.span(e.*.message)});
                c.g_error_free(e);
            }
            return false;
        };
        defer c.g_dbus_node_info_unref(info);
        const iface_info = c.g_dbus_node_info_lookup_interface(info, iface_z.ptr) orelse {
            log.print("[tray] interface '{s}' missing in XML", .{iface});
            return false;
        };

        var vtable: c.GDBusInterfaceVTable = std.mem.zeroes(c.GDBusInterfaceVTable);
        vtable.method_call = @ptrCast(&onMethodCall);
        vtable.get_property = @ptrCast(&onGetProperty);
        vtable.set_property = null;

        const reg = c.g_dbus_connection_register_object(
            @ptrCast(@alignCast(conn)),
            path_z.ptr,
            iface_info,
            &vtable,
            ctx,
            null,
            &err,
        );
        if (reg == 0) {
            if (err) |e| {
                log.print("[tray] register '{s}' failed: {s}", .{ path, std.mem.span(e.*.message) });
                c.g_error_free(e);
            }
            return false;
        }
        ctx.registration = reg;
        return true;
    }

    fn registerWatcher(self: *Tray, name_z: [*:0]const u8) void {
        const conn = self.conn orelse return;
        if (c.g_variant_new("(s)", name_z)) |params| {
            const reply = c.g_dbus_connection_call_sync(
                @ptrCast(@alignCast(conn)),
                "org.kde.StatusNotifierWatcher",
                "/StatusNotifierWatcher",
                "org.kde.StatusNotifierWatcher",
                "RegisterStatusNotifierItem",
                @ptrCast(params),
                null,
                0,
                2000,
                null,
                null,
            );
            if (reply) |r| {
                c.g_variant_unref(@ptrCast(@alignCast(r)));
            } else {
                log.print("[tray] no StatusNotifierWatcher — icon not shown by a host", .{});
            }
        }
    }

    // ------------------------------------------------------------------
    // D-Bus 方法回调
    // ------------------------------------------------------------------

    fn onMethodCall(
        _: ?*anyopaque,
        _: [*c]const u8,
        _: [*c]const u8,
        interface_name: [*c]const u8,
        method_name: [*c]const u8,
        parameters: ?*c.GVariant,
        invocation: ?*anyopaque,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const ctx: *Ctx = @ptrCast(@alignCast(user_data orelse return));
        const inv: ?*anyopaque = invocation;
        const iface = if (interface_name != null) std.mem.span(interface_name) else "";
        const method = if (method_name != null) std.mem.span(method_name) else "";
        if (std.mem.eql(u8, iface, item_iface)) {
            if (std.mem.eql(u8, method, "Activate") or std.mem.eql(u8, method, "SecondaryActivate")) {
                ctx.tray.on_activate(ctx.tray.ctx);
            }
            c.g_dbus_method_invocation_return_value(@ptrCast(@alignCast(inv)), null);
            return;
        }
        if (std.mem.eql(u8, iface, menu_iface)) {
            ctx.tray.handleMenuMethod(method, parameters, inv);
            return;
        }
        c.g_dbus_method_invocation_return_dbus_error(
            @ptrCast(@alignCast(inv)),
            "org.freedesktop.DBus.Error.UnknownInterface",
            "unknown interface",
        );
    }

    fn handleMenuMethod(self: *Tray, method: []const u8, parameters: ?*c.GVariant, inv: ?*anyopaque) void {
        const invocation: ?*anyopaque = inv;
        if (std.mem.eql(u8, method, "GetLayout")) {
            // 全树递归（含所有子菜单）：宿主拿到根布局即完整菜单，无需再按
            // 子菜单 id 二次查询；parentId/recursionDepth 因此不参与。
            var counter: i32 = 1;
            if (self.buildRoot(&counter)) |layout| {
                c.g_dbus_method_invocation_return_value(
                    @ptrCast(@alignCast(invocation)),
                    c.g_variant_new("(u@(ia{sv}av))", self.revision, layout),
                );
            } else {
                c.g_dbus_method_invocation_return_dbus_error(
                    @ptrCast(@alignCast(invocation)),
                    "org.freedesktop.DBus.Error.Failed",
                    "layout build failed",
                );
            }
            return;
        }
        if (std.mem.eql(u8, method, "GetGroupProperties")) {
            const t = c.g_variant_type_new("a(ia{sv})") orelse return;
            var b: c.GVariantBuilder = undefined;
            c.g_variant_builder_init(&b, t);
            if (buildPropsDict("", true, true, false, false, 0)) |root_props| {
                c.g_variant_builder_add(&b, "(i@a{sv})", @as(c_int, 0), root_props);
            }
            var it = self.ids.iterator();
            while (it.next()) |entry| {
                const node = entry.value_ptr.*;
                if (buildPropsDict(
                    node.label,
                    node.enabled,
                    true,
                    node.isSeparator(),
                    node.children.items.len > 0,
                    if (node.checked) 1 else 0,
                )) |props| {
                    c.g_variant_builder_add(&b, "(i@a{sv})", entry.key_ptr.*, props);
                }
            }
            const arr = c.g_variant_builder_end(&b);
            c.g_variant_type_free(t);
            c.g_dbus_method_invocation_return_value(
                @ptrCast(@alignCast(invocation)),
                c.g_variant_new("(@a(ia{sv}))", arr),
            );
            return;
        }
        if (std.mem.eql(u8, method, "GetProperty")) {
            var id: c_int = 0;
            var key: []const u8 = "";
            if (parameters) |p| {
                if (c.g_variant_get_child_value(p, 0)) |cv| {
                    id = c.g_variant_get_int32(cv);
                    c.g_variant_unref(@ptrCast(@alignCast(cv)));
                }
                if (c.g_variant_get_child_value(p, 1)) |cv| {
                    const s = c.g_variant_get_string(cv, null);
                    if (s != null) key = std.mem.span(s);
                    c.g_variant_unref(@ptrCast(@alignCast(cv)));
                }
            }
            const value = self.propertyVariant(id, key) orelse c.g_variant_new_string("");
            c.g_dbus_method_invocation_return_value(
                @ptrCast(@alignCast(invocation)),
                c.g_variant_new("(v)", value),
            );
            return;
        }
        if (std.mem.eql(u8, method, "Event")) {
            var id: c_int = 0;
            var event: []const u8 = "";
            if (parameters) |p| {
                if (c.g_variant_get_child_value(p, 0)) |cv| {
                    id = c.g_variant_get_int32(cv);
                    c.g_variant_unref(@ptrCast(@alignCast(cv)));
                }
                if (c.g_variant_get_child_value(p, 1)) |cv| {
                    const s = c.g_variant_get_string(cv, null);
                    if (s != null) event = std.mem.span(s);
                    c.g_variant_unref(@ptrCast(@alignCast(cv)));
                }
            }
            if (std.mem.eql(u8, event, "clicked")) {
                if (self.ids.get(id)) |node| {
                    if (node.id.len > 0) self.on_menu(self.ctx, node);
                }
            }
            c.g_dbus_method_invocation_return_value(@ptrCast(@alignCast(invocation)), null);
            return;
        }
        if (std.mem.eql(u8, method, "AboutToShow")) {
            c.g_dbus_method_invocation_return_value(
                @ptrCast(@alignCast(invocation)),
                c.g_variant_new("(b)", @as(c_int, 0)),
            );
            return;
        }
        if (std.mem.eql(u8, method, "AboutToShowGroup")) {
            const empty1 = emptyIntArray() orelse return;
            const empty2 = emptyIntArray() orelse return;
            c.g_dbus_method_invocation_return_value(
                @ptrCast(@alignCast(invocation)),
                c.g_variant_new("(@ai@ai)", empty1, empty2),
            );
            return;
        }
        if (std.mem.eql(u8, method, "EventGroup")) {
            const empty = emptyIntArray() orelse return;
            c.g_dbus_method_invocation_return_value(
                @ptrCast(@alignCast(invocation)),
                c.g_variant_new("(@ai)", empty),
            );
            return;
        }
        c.g_dbus_method_invocation_return_dbus_error(
            @ptrCast(@alignCast(invocation)),
            "org.freedesktop.DBus.Error.UnknownMethod",
            "unknown method",
        );
    }

    fn emptyIntArray() ?*c.GVariant {
        const t = c.g_variant_type_new("i") orelse return null;
        defer c.g_variant_type_free(t);
        return c.g_variant_new_array(t, null, 0);
    }

    fn onGetProperty(
        _: ?*anyopaque,
        _: [*c]const u8,
        _: [*c]const u8,
        interface_name: [*c]const u8,
        property_name: [*c]const u8,
        _: ?*?*c.GError,
        user_data: ?*anyopaque,
    ) callconv(.c) ?*c.GVariant {
        const ctx: *Ctx = @ptrCast(@alignCast(user_data orelse return null));
        const iface = if (interface_name != null) std.mem.span(interface_name) else "";
        const prop = if (property_name != null) std.mem.span(property_name) else "";
        if (std.mem.eql(u8, iface, item_iface)) return ctx.tray.itemProperty(prop);
        if (std.mem.eql(u8, iface, menu_iface)) return ctx.tray.menuProperty(prop);
        return null;
    }

    fn newString(s: []const u8) ?*c.GVariant {
        const z = dupeZ(std.heap.c_allocator, s) catch return null;
        defer std.heap.c_allocator.free(z);
        return c.g_variant_new_string(z.ptr);
    }

    fn itemProperty(self: *Tray, prop: []const u8) ?*c.GVariant {
        if (std.mem.eql(u8, prop, "Id")) return newString(self.app_id);
        if (std.mem.eql(u8, prop, "Category")) return c.g_variant_new_string("ApplicationStatus");
        if (std.mem.eql(u8, prop, "Title")) return newString(self.title);
        if (std.mem.eql(u8, prop, "Status")) return c.g_variant_new_string("Active");
        if (std.mem.eql(u8, prop, "IconName")) return newString(self.icon_name);
        if (std.mem.eql(u8, prop, "IconThemePath")) return newString(self.icon_dir);
        if (std.mem.eql(u8, prop, "Menu")) return c.g_variant_new_object_path(menu_path);
        if (std.mem.eql(u8, prop, "ItemIsMenu")) return c.g_variant_new_boolean(0);
        return null;
    }

    fn menuProperty(self: *Tray, prop: []const u8) ?*c.GVariant {
        _ = self;
        if (std.mem.eql(u8, prop, "Version")) return c.g_variant_new_uint32(3);
        if (std.mem.eql(u8, prop, "TextDirection")) return c.g_variant_new_string("ltr");
        if (std.mem.eql(u8, prop, "Status")) return c.g_variant_new_string("normal");
        if (std.mem.eql(u8, prop, "IconThemePath")) {
            const t = c.g_variant_type_new("as") orelse return null;
            defer c.g_variant_type_free(t);
            return c.g_variant_new_array(t, null, 0);
        }
        return null;
    }

    // ------------------------------------------------------------------
    // DBusMenu 布局构造
    // ------------------------------------------------------------------

    fn buildRoot(self: *Tray, counter: *i32) ?*c.GVariant {
        const props = buildPropsDict("", true, true, false, self.roots.len > 0, 0) orelse return null;
        const child_array = buildChildren(self.roots, counter) orelse {
            c.g_variant_unref(@ptrCast(@alignCast(props)));
            return null;
        };
        return c.g_variant_new("(i@a{sv}@av)", @as(c_int, 0), props, child_array);
    }

    fn buildChildren(children: []*menu_model.Node, counter: *i32) ?*c.GVariant {
        const ctype = c.g_variant_type_new("av") orelse return null;
        var cb: c.GVariantBuilder = undefined;
        c.g_variant_builder_init(&cb, ctype);
        for (children) |child| {
            if (buildChildVariant(child, counter)) |v| c.g_variant_builder_add(&cb, "v", v);
        }
        const out = c.g_variant_builder_end(&cb);
        c.g_variant_type_free(ctype);
        return out;
    }

    fn buildChildVariant(node: *menu_model.Node, counter: *i32) ?*c.GVariant {
        const id = counter.*;
        counter.* += 1;
        const props = buildPropsDict(
            node.label,
            node.enabled,
            true,
            node.isSeparator(),
            node.children.items.len > 0,
            if (node.checked) 1 else 0,
        ) orelse return null;
        const child_array = buildChildren(node.children.items, counter) orelse {
            c.g_variant_unref(@ptrCast(@alignCast(props)));
            return null;
        };
        return c.g_variant_new("(i@a{sv}@av)", id, props, child_array);
    }

    fn buildPropsDict(
        label: []const u8,
        enabled: bool,
        visible: bool,
        separator: bool,
        has_children: bool,
        checked: u8,
    ) ?*c.GVariant {
        const t = c.g_variant_type_new("a{sv}") orelse return null;
        var b: c.GVariantBuilder = undefined;
        c.g_variant_builder_init(&b, t);
        const label_z = dupeZ(std.heap.c_allocator, if (separator) "" else label) catch {
            c.g_variant_type_free(t);
            return null;
        };
        defer std.heap.c_allocator.free(label_z);
        const kind: [*:0]const u8 = if (separator)
            "separator"
        else if (has_children)
            "submenu"
        else
            "standard";
        c.g_variant_builder_add(&b, "{sv}", "label", c.g_variant_new_string(label_z.ptr));
        c.g_variant_builder_add(&b, "{sv}", "enabled", c.g_variant_new_boolean(@intFromBool(enabled)));
        c.g_variant_builder_add(&b, "{sv}", "visible", c.g_variant_new_boolean(@intFromBool(visible)));
        c.g_variant_builder_add(&b, "{sv}", "type", c.g_variant_new_string(kind));
        if (has_children) {
            c.g_variant_builder_add(&b, "{sv}", "children-display", c.g_variant_new_string("submenu"));
        }
        if (checked != 0) {
            c.g_variant_builder_add(&b, "{sv}", "toggle-type", c.g_variant_new_string("checkmark"));
            c.g_variant_builder_add(&b, "{sv}", "toggle-state", c.g_variant_new_int32(@intCast(checked)));
        }
        const out = c.g_variant_builder_end(&b);
        c.g_variant_type_free(t);
        return out;
    }

    fn propertyVariant(self: *Tray, id: c_int, name: []const u8) ?*c.GVariant {
        const node: ?*menu_model.Node = if (id == 0) null else self.ids.get(id);
        if (std.mem.eql(u8, name, "label")) return newString(if (node) |n| n.label else "") orelse c.g_variant_new_string("");
        if (std.mem.eql(u8, name, "enabled")) return c.g_variant_new_boolean(if (node) |n| @intFromBool(n.enabled) else 1);
        if (std.mem.eql(u8, name, "visible")) return c.g_variant_new_boolean(1);
        if (std.mem.eql(u8, name, "type")) return c.g_variant_new_string("standard");
        return c.g_variant_new_string("");
    }
};

/// 由 backend 在 GTK4 分支调用；GTK3 返回 null（不创建）。
pub fn create(allocator: Allocator, opts: Options) ?*Tray {
    if (!gtk_compat.isGtk4()) return null;
    const t = allocator.create(Tray) catch return null;
    t.* = Tray.init(allocator, opts) catch |err| {
        log.print("[tray] SNI init failed: {s}", .{@errorName(err)});
        allocator.destroy(t);
        return null;
    };
    return t;
}

test "props dict: 构造与释放" {
    // 不依赖 D-Bus：验证 GVariant 构造路径（Linux CI 有 GTK 时执行）。
    if (!gtk_compat.isGtk4()) return error.SkipZigTest;
    const v = Tray.buildPropsDict("Open", true, true, false, false, 0);
    if (v) |value| c.g_variant_unref(@ptrCast(@alignCast(value)));
}
