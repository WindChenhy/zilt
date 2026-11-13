//! X11 全局快捷键（v0.2.6；对齐 Windows 的 RegisterHotKey 语义）。
//!
//! XGrabKey 抓键 + 独立事件线程（XPending 轮询）→ KeyPress 匹配 → 回调
//! （监视线程触发，宿主自行封送 UI）。修饰符锁（Num/Caps/Scroll Lock）按
//! X11 惯例全组合抓取（4 种 lock 组合）。
//!
//! accel 解析复用 backend 的 parseAccelGtk（GDK 修饰符 + keysym）——这里只做
//! GDK→X11 的掩码换算与 keysym→keycode（XKeysymToKeycode）。
//! Wayland 下 XOpenDisplay 仍可能通过 XWayland 工作；无显示连接时
//! 注册返回 error.X11Unavailable（对齐「无全局热键能力即明确失败」）。
const std = @import("std");
const log = @import("../../log.zig");
const zilt_sys = @import("../../sys.zig");

const Allocator = std.mem.Allocator;

// --- Xlib（动态加载，避免硬链接依赖；运行时桌面必有 libX11）---
const XDisplay = opaque {};
const XEvent = extern struct {
    type: c_int,
    pad: [191]u8 align(8), // XEvent 是 192 字节 union；KeyPress 读取前 24 字节
}; // xserial:8 + send_event:1 + display:8 + window:8 … 简化对齐处理

const KeyPressMask: c_long = 1 << 0;
const GrabModeAsync: c_int = 1;
const PropModeReplace: c_int = 0;

const XOpenDisplayFn = *const fn (name: ?[*:0]const u8) callconv(.c) ?*XDisplay;
const XCloseDisplayFn = *const fn (d: *XDisplay) callconv(.c) void;
const XGrabKeyFn = *const fn (d: *XDisplay, keycode: c_int, modifiers: c_uint, grab_window: c_ulong, owner_events: c_int, pointer_mode: c_int, keyboard_mode: c_int) callconv(.c) c_int;
const XUngrabKeyFn = *const fn (d: *XDisplay, keycode: c_int, modifiers: c_uint, grab_window: c_ulong) callconv(.c) c_int;
const XDefaultRootWindowFn = *const fn (d: *XDisplay) callconv(.c) c_ulong;
const XStringToKeysymFn = *const fn (str: [*:0]const u8) callconv(.c) c_ulong;
const XKeysymToKeycodeFn = *const fn (d: *XDisplay, keysym: c_ulong) callconv(.c) c_int;
const XPendingFn = *const fn (d: *XDisplay) callconv(.c) c_int;
const XNextEventFn = *const fn (d: *XDisplay, event: *XEvent) callconv(.c) void;
const XSelectInputFn = *const fn (d: *XDisplay, w: c_ulong, mask: c_long) callconv(.c) c_int;
const XGetModifierMappingFn = *const fn (d: *XDisplay) callconv(.c) ?*anyopaque;
const XFreeFn = *const fn (data: ?*anyopaque) callconv(.c) c_int;
const XSyncFn = *const fn (d: *XDisplay, discard: c_int) callconv(.c) c_int;
const XErrorEvent = extern struct {
    type: c_int,
    pad0: [12]u8, // display 指针 + 对齐
    resourceid: c_ulong,
    serial: c_ulong,
    error_code: u8,
    request_code: u8,
    minor_code: u8,
    rest: [5]u8,
};
const XErrorHandlerFn = *const fn (?*XDisplay, ?*XErrorEvent) callconv(.c) c_int;
const XSetErrorHandlerFn = *const fn (handler: ?XErrorHandlerFn) callconv(.c) ?XErrorHandlerFn;

/// X11 修饰符掩码（<X11/X.h>）
const ShiftMask: c_uint = 1 << 0;
const ControlMask: c_uint = 1 << 2;
const Mod1Mask: c_uint = 1 << 3; // Alt
const Mod2Mask: c_uint = 1 << 4; // Num Lock
const Mod4Mask: c_uint = 1 << 6; // Super
const Mod5Mask: c_uint = 1 << 7; // Scroll Lock? (ISO_Level3)
const LockMask: c_uint = 1 << 1; // Caps Lock

const Xlib = struct {
    lib: std.DynLib,
    open_display: XOpenDisplayFn,
    close_display: XCloseDisplayFn,
    grab_key: XGrabKeyFn,
    ungrab_key: XUngrabKeyFn,
    default_root_window: XDefaultRootWindowFn,
    string_to_keysym: XStringToKeysymFn,
    keysym_to_keycode: XKeysymToKeycodeFn,
    x_pending: XPendingFn,
    x_next_event: XNextEventFn,
    x_sync: XSyncFn,
    set_error_handler: XSetErrorHandlerFn,

    fn load() ?Xlib {
        const names = [_][]const u8{ "libX11.so.6", "libX11.so" };
        for (names) |name| {
            var lib = std.DynLib.open(name) catch continue;
            const x = Xlib{
                .lib = lib,
                .open_display = lib.lookup(XOpenDisplayFn, "XOpenDisplay") orelse {
                    lib.close();
                    continue;
                },
                .close_display = lib.lookup(XCloseDisplayFn, "XCloseDisplay") orelse {
                    lib.close();
                    continue;
                },
                .grab_key = lib.lookup(XGrabKeyFn, "XGrabKey") orelse {
                    lib.close();
                    continue;
                },
                .ungrab_key = lib.lookup(XUngrabKeyFn, "XUngrabKey") orelse {
                    lib.close();
                    continue;
                },
                .default_root_window = lib.lookup(XDefaultRootWindowFn, "XDefaultRootWindow") orelse {
                    lib.close();
                    continue;
                },
                .string_to_keysym = lib.lookup(XStringToKeysymFn, "XStringToKeysym") orelse {
                    lib.close();
                    continue;
                },
                .keysym_to_keycode = lib.lookup(XKeysymToKeycodeFn, "XKeysymToKeycode") orelse {
                    lib.close();
                    continue;
                },
                .x_pending = lib.lookup(XPendingFn, "XPending") orelse {
                    lib.close();
                    continue;
                },
                .x_next_event = lib.lookup(XNextEventFn, "XNextEvent") orelse {
                    lib.close();
                    continue;
                },
                .x_sync = lib.lookup(XSyncFn, "XSync") orelse {
                    lib.close();
                    continue;
                },
                .set_error_handler = lib.lookup(XSetErrorHandlerFn, "XSetErrorHandler") orelse {
                    lib.close();
                    continue;
                },
            };
            return x;
        }
        return null;
    }
};

/// BadAccess 计数（grabs 只发生在 UI/事件线程；handler 由 Xlib 在同线程回调）。
var grab_errors: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var last_xerror_code: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var last_xerror_req: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn grabErrorHandler(_: ?*XDisplay, e: ?*XErrorEvent) callconv(.c) c_int {
    // 仅统计（BadAccess/BadValue 等）——默认处理器会 abort，必须吞掉
    _ = grab_errors.fetchAdd(1, .monotonic);
    if (e) |ev| {
        last_xerror_code.store(ev.error_code, .monotonic);
        last_xerror_req.store(ev.request_code, .monotonic);
    }
    return 0;
}

pub const Hotkey = struct {
    id: []u8,
    accel: []u8,
    keycode: c_int,
    mods: c_uint, // X11 修饰符（不含 lock 组合）
};

pub const Entry = struct { id: []const u8, accel: []const u8 };

pub const Error = error{ X11Unavailable, XGrabFailed, InvalidAccel, OutOfMemory };

pub const Manager = struct {
    alloc: Allocator,
    xlib: Xlib,
    display: *XDisplay,
    root: c_ulong,
    keys: std.ArrayListUnmanaged(Hotkey) = .empty,
    /// 事件回调（监视线程触发）
    on_press: *const fn (ctx: ?*anyopaque, id: []const u8) void,
    ctx: ?*anyopaque,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// 打开 X11 连接（惰性；失败 = 无全局热键能力）。
    pub fn init(alloc: Allocator, on_press: *const fn (ctx: ?*anyopaque, id: []const u8) void, ctx: ?*anyopaque) Error!*Manager {
        const xlib = Xlib.load() orelse return error.X11Unavailable;
        const display = xlib.open_display(null) orelse return error.X11Unavailable;
        const m = alloc.create(Manager) catch return error.OutOfMemory;
        m.* = .{
            .alloc = alloc,
            .xlib = xlib,
            .display = display,
            .root = xlib.default_root_window(display),
            .on_press = on_press,
            .ctx = ctx,
        };
        return m;
    }

    /// 注册（id/accel 的副本归 Manager）。重复注册同一 (keycode, mods) →
    /// error.XGrabFailed（对齐 Windows 的 HotkeyConflict）。
    pub fn register(self: *Manager, id: []const u8, accel: []const u8, keysym_str: []const u8, gdk_mods: c_uint) Error!void {
        for (self.keys.items) |k| {
            if (std.mem.eql(u8, k.id, id)) return error.XGrabFailed; // 同 id 重复
        }
        const keysym_str_z = self.alloc.allocSentinel(u8, keysym_str.len, 0) catch return error.OutOfMemory;
        defer self.alloc.free(keysym_str_z);
        @memcpy(keysym_str_z[0..keysym_str.len], keysym_str);
        const keysym = self.xlib.string_to_keysym(keysym_str_z.ptr);
        const keycode = self.xlib.keysym_to_keycode(self.display, keysym);
        if (keycode == 0) return error.InvalidAccel;

        const mods = gdkToXMods(gdk_mods);
        // XGrabKey 的返回值不是抓取状态（本机 Xlib 实测恒 1）——BadAccess 由
        // 错误处理器异步上报：装 handler → 全部 lock 组合抓取 → XSync → 数错误。
        const lock_combos = [_]c_uint{ 0, LockMask, Mod2Mask, LockMask | Mod2Mask, Mod5Mask, LockMask | Mod5Mask, Mod2Mask | Mod5Mask, LockMask | Mod2Mask | Mod5Mask };
        const prev = grab_errors.load(.monotonic);
        const old_handler = self.xlib.set_error_handler(grabErrorHandler);
        defer _ = self.xlib.set_error_handler(old_handler);
        for (lock_combos) |lock| {
            _ = self.xlib.grab_key(self.display, keycode, mods | lock, self.root, 0, GrabModeAsync, GrabModeAsync);
        }
        _ = self.xlib.x_sync(self.display, 0);
        if (grab_errors.load(.monotonic) != prev) {
            log.print("[hotkey-x11] grab error code={d} request={d} (keycode={d})", .{ last_xerror_code.load(.monotonic), last_xerror_req.load(.monotonic), keycode });
            return error.XGrabFailed; // 已被其他客户端抓取（对齐 Windows 的 HotkeyConflict）
        }

        const id_copy = self.alloc.dupe(u8, id) catch return error.OutOfMemory;
        errdefer self.alloc.free(id_copy);
        const accel_copy = self.alloc.dupe(u8, accel) catch return error.OutOfMemory;
        errdefer self.alloc.free(accel_copy);
        self.keys.append(self.alloc, .{ .id = id_copy, .accel = accel_copy, .keycode = keycode, .mods = mods }) catch return error.OutOfMemory;
        self.ensureThread();
    }

    fn ensureThread(self: *Manager) void {
        if (self.thread != null) return;
        self.thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, eventLoop, .{self}) catch null;
    }

    /// 注销（返回是否找到）。
    pub fn unregister(self: *Manager, id: []const u8) bool {
        for (self.keys.items, 0..) |k, i| {
            if (!std.mem.eql(u8, k.id, id)) continue;
            const lock_combos = [_]c_uint{ 0, LockMask, Mod2Mask, LockMask | Mod2Mask, Mod5Mask, LockMask | Mod5Mask, Mod2Mask | Mod5Mask, LockMask | Mod2Mask | Mod5Mask };
            for (lock_combos) |lock| {
                _ = self.xlib.ungrab_key(self.display, k.keycode, k.mods | lock, self.root);
            }
            _ = self.xlib.x_sync(self.display, 0);
            self.alloc.free(k.id);
            self.alloc.free(k.accel);
            _ = self.keys.swapRemove(i);
            return true;
        }
        return false;
    }

    /// 已注册项（调用方释放容器；字符串借用 Manager 内部存储）。
    pub fn list(self: *Manager, alloc: Allocator) ![]Entry {
        var out = try alloc.alloc(Entry, self.keys.items.len);
        for (self.keys.items, 0..) |k, i| {
            out[i] = .{ .id = k.id, .accel = k.accel };
        }
        return out;
    }

    pub fn count(self: *Manager) usize {
        return self.keys.items.len;
    }

    fn eventLoop(self: *Manager) void {
        while (!self.stopping.load(.acquire)) {
            const pending = self.xlib.x_pending(self.display);
            if (pending == 0) {
                zilt_sys.sleepMs(50);
                continue;
            }
            var ev: XEvent = undefined;
            self.xlib.x_next_event(self.display, &ev);
            if (ev.type != 2) continue; // KeyPress
            // XKeyEvent 头部：type(4) serial(8) send_event(1+pad) display(8) window(8)
            // → keycode 在 offset 32？不——XEvent.type 后的 XAnyEvent 布局：
            //   serial(8B) + send_event(1B+3pad) + display(8B) = 20B → window(8B)=28B
            //   → XKeyEvent: subtype/root/subwindow/time/x/y/state/keycode…
            // 直接按 XKeyEvent 的稳定偏移取 keycode（offset 40）与 state（offset 36）。
            const key_state: c_uint = std.mem.readInt(u32, ev.pad[12..16], .little);
            const key_code: c_uint = std.mem.readInt(u32, ev.pad[16..20], .little);
            const mods_only = key_state & ~(LockMask | Mod2Mask | Mod5Mask);
            for (self.keys.items) |k| {
                if (k.keycode == key_code and (mods_only & ~(ShiftMask | ControlMask | Mod1Mask | Mod4Mask | LockMask)) == 0 and
                    (mods_only & k.mods) == k.mods)
                {
                    self.on_press(self.ctx, k.id);
                }
            }
        }
    }

    pub fn deinit(self: *Manager) void {
        self.stopping.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        for (self.keys.items) |k| {
            const lock_combos = [_]c_uint{ 0, LockMask, Mod2Mask, LockMask | Mod2Mask, Mod5Mask, LockMask | Mod5Mask, Mod2Mask | Mod5Mask, LockMask | Mod2Mask | Mod5Mask };
            for (lock_combos) |lock| {
                _ = self.xlib.ungrab_key(self.display, k.keycode, k.mods | lock, self.root);
            }
            self.alloc.free(k.id);
            self.alloc.free(k.accel);
        }
        self.keys.deinit(self.alloc);
        self.xlib.close_display(self.display);
        self.xlib.lib.close();
        self.alloc.destroy(self);
    }
};

/// GDK 修饰符掩码 → X11（Shift/Ctrl/Alt/Super 位一致：GDK_SHIFT=1, CTRL=1<<2,
/// MOD1=1<<3, SUPER=1<<26 → X11 Mod4=1<<6）。
pub fn gdkToXMods(gdk: c_uint) c_uint {
    var mods: c_uint = 0;
    if (gdk & 1 != 0) mods |= ShiftMask; // GDK_SHIFT_MASK
    if (gdk & 4 != 0) mods |= ControlMask; // GDK_CONTROL_MASK
    if (gdk & 8 != 0) mods |= Mod1Mask; // GDK_MOD1_MASK (Alt)
    if (gdk & (1 << 26) != 0) mods |= Mod4Mask; // GDK_SUPER_MASK
    return mods;
}

/// keysym 字符串（"s"/"F7"…）——backend 的 parseAccelGtk 给出 keyval 数值，
/// 这里直接由调用方传入键名（与 accel 文本的键位段一致）。
pub fn keysymNameFor(alloc: Allocator, keyval: c_uint) !?[:0]u8 {
    // 字母 0x41..0x5a、数字 0x30..0x39、F1=0xffbe
    if (keyval >= 0x41 and keyval <= 0x5a) {
        return try std.fmt.allocPrintSentinel(alloc, "{c}", .{@as(u8, @intCast(keyval))}, 0);
    }
    if (keyval >= 0x30 and keyval <= 0x39) {
        return try std.fmt.allocPrintSentinel(alloc, "{c}", .{@as(u8, @intCast(keyval))}, 0);
    }
    if (keyval >= 0xffbe and keyval <= 0xffc9) {
        return try std.fmt.allocPrintSentinel(alloc, "F{d}", .{keyval - 0xffbe + 1}, 0);
    }
    return null;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "gdkToXMods: 位映射" {
    try testing.expectEqual(@as(c_uint, 0), gdkToXMods(0));
    try testing.expectEqual(@as(c_uint, 1), gdkToXMods(1)); // Shift
    try testing.expectEqual(@as(c_uint, 4), gdkToXMods(4)); // Ctrl
    try testing.expectEqual(@as(c_uint, 8), gdkToXMods(8)); // Alt
    try testing.expectEqual(@as(c_uint, 1 | 4 | 8), gdkToXMods(1 | 4 | 8));
    try testing.expectEqual(@as(c_uint, 1 << 6), gdkToXMods(1 << 26)); // Super
}

test "keysymNameFor: 字母/数字/功能键/未知" {
    const a = testing.allocator;
    const s1 = (try keysymNameFor(a, 'S')).?;
    defer a.free(s1);
    try testing.expectEqualStrings("S", s1);
    const s2 = (try keysymNameFor(a, '5')).?;
    defer a.free(s2);
    try testing.expectEqualStrings("5", s2);
    const s3 = (try keysymNameFor(a, 0xffbe + 6)).?;
    defer a.free(s3);
    try testing.expectEqualStrings("F7", s3);
    try testing.expect((try keysymNameFor(a, 0x1234)) == null);
}

test "X11 Manager：真实抓键（Xvfb/WSLg 有显示）" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const Ctx = struct {
        var hits: usize = 0;
        fn onPress(_: ?*anyopaque, _: []const u8) void {
            hits += 1;
        }
    };
    const m = Manager.init(testing.allocator, Ctx.onPress, null) catch return error.SkipZigTest; // 无显示环境 skip
    defer m.deinit();

    // Ctrl+Alt+F9（keyval 'F' + 9 → "F9"，gdk mods Ctrl|Alt = 4|8）
    try m.register("smoke-hotkey", "Ctrl+Alt+F9", "F9", 4 | 8);
    try testing.expectEqual(@as(usize, 1), m.count());
    // 同 id 重复 → 冲突
    try testing.expectError(error.XGrabFailed, m.register("smoke-hotkey", "Ctrl+Alt+F9", "F9", 4 | 8));
    const list = try m.list(testing.allocator);
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("Ctrl+Alt+F9", list[0].accel);
    try testing.expect(m.unregister("smoke-hotkey"));
    try testing.expect(!m.unregister("smoke-hotkey"));
    try testing.expectEqual(@as(usize, 0), m.count());
}
