//! 插件 / 服务模型（v0.1.16）。
//!
//! 对齐 Wails services / Tauri State 的最小可用形态：
//!  - 注册：名称唯一，携带可选 init/deinit 与 capability 作用域
//!  - 生命周期：`startAll` 按注册顺序初始化，失败回滚已启动项；
//!    `stopAll` 逆序销毁（依赖方先退）
//!  - 托管状态：服务自行持有 `state` 指针，框架只负责调用时序
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Service = struct {
    name: []const u8,
    /// 服务自有状态（框架不解释其含义）
    state: ?*anyopaque = null,
    init_fn: ?*const fn (state: *anyopaque) anyerror!void = null,
    deinit_fn: ?*const fn (state: *anyopaque) void = null,
    /// capability 作用域（如 "fs:app_data"、"net:https"）；空串 = 不受限
    scope: []const u8 = "",
};

const Slot = struct {
    service: Service,
    started: bool = false,
};

pub const Registry = struct {
    alloc: Allocator,
    slots: std.ArrayListUnmanaged(Slot) = .empty,

    pub fn init(alloc: Allocator) Registry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Registry) void {
        self.stopAll();
        self.slots.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn register(self: *Registry, service: Service) !void {
        if (service.name.len == 0) return error.InvalidServiceName;
        if (self.get(service.name) != null) return error.ServiceAlreadyRegistered;
        try self.slots.append(self.alloc, .{ .service = service });
    }

    pub fn get(self: *Registry, name: []const u8) ?*Service {
        for (self.slots.items) |*slot| {
            if (std.mem.eql(u8, slot.service.name, name)) return &slot.service;
        }
        return null;
    }

    pub fn count(self: *const Registry) usize {
        return self.slots.items.len;
    }

    pub fn isStarted(self: *Registry, name: []const u8) bool {
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.service.name, name)) return slot.started;
        }
        return false;
    }

    /// 启动单个服务（幂等：已启动直接返回）。
    pub fn start(self: *Registry, name: []const u8) !void {
        for (self.slots.items) |*slot| {
            if (!std.mem.eql(u8, slot.service.name, name)) continue;
            if (slot.started) return;
            if (slot.service.init_fn) |f| {
                const state = slot.service.state orelse return error.MissingServiceState;
                try f(state);
            }
            slot.started = true;
            return;
        }
        return error.ServiceNotFound;
    }

    /// 按注册顺序启动全部服务；任一失败则回滚已启动项并返回该错误。
    pub fn startAll(self: *Registry) !void {
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.started) continue;
            if (slot.service.init_fn) |f| {
                const state = slot.service.state orelse {
                    self.rollback(i);
                    return error.MissingServiceState;
                };
                f(state) catch |err| {
                    self.rollback(i);
                    return err;
                };
            }
            slot.started = true;
        }
    }

    fn rollback(self: *Registry, upto: usize) void {
        var i = upto;
        while (i > 0) {
            i -= 1;
            const slot = &self.slots.items[i];
            if (!slot.started) continue;
            if (slot.service.deinit_fn) |f| {
                if (slot.service.state) |state| f(state);
            }
            slot.started = false;
        }
    }

    /// 停止单个服务（未启动时为 no-op）。
    pub fn stop(self: *Registry, name: []const u8) void {
        for (self.slots.items) |*slot| {
            if (!std.mem.eql(u8, slot.service.name, name)) continue;
            if (!slot.started) return;
            if (slot.service.deinit_fn) |f| {
                if (slot.service.state) |state| f(state);
            }
            slot.started = false;
            return;
        }
    }

    /// 逆序停止全部（依赖方先退）。
    pub fn stopAll(self: *Registry) void {
        var i = self.slots.items.len;
        while (i > 0) {
            i -= 1;
            const slot = &self.slots.items[i];
            if (!slot.started) continue;
            if (slot.service.deinit_fn) |f| {
                if (slot.service.state) |state| f(state);
            }
            slot.started = false;
        }
    }
};

/// 服务条目的 JSON 序列化（v0.2.7：Windows/Linux 的 services.list/status 共用；
/// name/scope 是开发者声明串，仍做转义防意外字符破坏 JSON）。
pub fn appendToJson(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    scope: []const u8,
    started: bool,
) !void {
    try out.appendSlice(alloc, "{\"name\":\"");
    try appendJsonEscaped(alloc, out, name);
    try out.appendSlice(alloc, "\",\"scope\":\"");
    try appendJsonEscaped(alloc, out, scope);
    try out.appendSlice(alloc, "\",\"started\":");
    try out.appendSlice(alloc, if (started) "true" else "false");
    try out.append(alloc, '}');
}

fn appendJsonEscaped(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (ch < 0x20) {
                    try out.appendSlice(alloc, "\\u");
                    var buf: [4]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "{x:0>4}", .{ch}) catch unreachable;
                    try out.appendSlice(alloc, &buf);
                } else {
                    try out.append(alloc, ch);
                }
            },
        }
    }
}

const testing = std.testing;

const Counter = struct {
    inits: usize = 0,
    deinits: usize = 0,
    fail_at: usize = 0,
};

fn initOk(state: *anyopaque) anyerror!void {
    const c: *Counter = @ptrCast(@alignCast(state));
    c.inits += 1;
}

fn deinitCount(state: *anyopaque) void {
    const c: *Counter = @ptrCast(@alignCast(state));
    c.deinits += 1;
}

fn initFail(state: *anyopaque) anyerror!void {
    const c: *Counter = @ptrCast(@alignCast(state));
    _ = c;
    return error.InitFailed;
}

test "register rejects empty and duplicate names" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try testing.expectError(error.InvalidServiceName, reg.register(.{ .name = "" }));
    try reg.register(.{ .name = "store" });
    try testing.expectError(error.ServiceAlreadyRegistered, reg.register(.{ .name = "store" }));
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expect(reg.get("store") != null);
    try testing.expect(reg.get("nope") == null);
}

test "start all then stop all in reverse order" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var a = Counter{};
    var b = Counter{};
    try reg.register(.{ .name = "a", .state = &a, .init_fn = initOk, .deinit_fn = deinitCount });
    try reg.register(.{ .name = "b", .state = &b, .init_fn = initOk, .deinit_fn = deinitCount });

    try reg.startAll();
    try testing.expectEqual(@as(usize, 1), a.inits);
    try testing.expectEqual(@as(usize, 1), b.inits);
    try testing.expect(reg.isStarted("a") and reg.isStarted("b"));

    // 幂等
    try reg.startAll();
    try testing.expectEqual(@as(usize, 1), a.inits);

    reg.stopAll();
    try testing.expectEqual(@as(usize, 1), a.deinits);
    try testing.expectEqual(@as(usize, 1), b.deinits);
    try testing.expect(!reg.isStarted("a"));
}

test "failure rolls back already started services" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var a = Counter{};
    var bad = Counter{};
    try reg.register(.{ .name = "a", .state = &a, .init_fn = initOk, .deinit_fn = deinitCount });
    try reg.register(.{ .name = "bad", .state = &bad, .init_fn = initFail });

    try testing.expectError(error.InitFailed, reg.startAll());
    try testing.expectEqual(@as(usize, 1), a.inits);
    try testing.expectEqual(@as(usize, 1), a.deinits); // 回滚
    try testing.expect(!reg.isStarted("a"));
    try testing.expect(!reg.isStarted("bad"));
}

test "start and stop single service" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var a = Counter{};
    try reg.register(.{ .name = "a", .state = &a, .init_fn = initOk, .deinit_fn = deinitCount });
    try testing.expectError(error.ServiceNotFound, reg.start("nope"));
    try reg.start("a");
    try testing.expect(reg.isStarted("a"));
    reg.stop("a");
    try testing.expect(!reg.isStarted("a"));
    try testing.expectEqual(@as(usize, 1), a.deinits);
    try testing.expectError(error.MissingServiceState, blk: {
        try reg.register(.{ .name = "nostate", .init_fn = initOk });
        break :blk reg.start("nostate");
    });
}

test "appendToJson: 转义与 started 布尔" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendToJson(testing.allocator, &out, "de\"mo", "scope\nA", true);
    try testing.expectEqualStrings(
        "{\"name\":\"de\\\"mo\",\"scope\":\"scope\\nA\",\"started\":true}",
        out.items,
    );
}
