//! v0.3.7：server 模式 WS 会话——浏览器客户端作为「窗口」。
//!
//! 对齐 Wails 的 application_server + BrowserWindow 模型：每个 WS 连接一个会话，
//! 会话持有独立的 server 窗口 id（SERVER_WINDOW_BASE 起的空间，不与原生窗口冲突）；
//! invoke 经 headless 的同一 dispatch 链路（makeContextWith session）；事件按
//! window_id 路由回该会话（broadcast 事件投递到所有会话）。
//!
//! 协议：与注入 runtime 同一 JSON 消息形态（{zilt:1,kind:invoke,id,method,args} ←→
//! resolve/reject/event），帧编解码复用 ws.zig（客户端帧带 mask，服务端帧不带）。
const std = @import("std");
const ws = @import("ws.zig");

/// server 窗口 id 基址（原生窗口 id 从 1 递增；server 会话空间隔离在高位）
pub const SERVER_WINDOW_BASE: u32 = 0x100000;

// 同步原语：0.17 的 Io.Mutex 需要 io 实例（注册表从任意线程调用拿不到）→
// 原子自旋锁（临界区极小：指针表操作/队列 swap）。
fn spinLock(cell: *std.atomic.Value(bool)) void {
    while (cell.swap(true, .acq_rel)) {
        std.atomic.spinLoopHint();
    }
}

fn spinUnlock(cell: *std.atomic.Value(bool)) void {
    cell.store(false, .release);
}

/// `Sec-WebSocket-Key` → 101 响应体（acceptKey 复用 ws.zig）。
pub fn upgradeResponse(alloc: std.mem.Allocator, client_key: []const u8) ![]u8 {
    const accept = ws.acceptKey(client_key);
    return std.fmt.allocPrint(alloc,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept[0..]});
}

/// 请求头是否为 WS upgrade（/zilt/ws 路径 + Upgrade: websocket）。
pub fn isWsUpgrade(head_text: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, head_text, "Upgrade: websocket") == null and
        std.mem.indexOf(u8, head_text, "upgrade: websocket") == null) return null;
    // 提取 Sec-WebSocket-Key
    var lines = std.mem.splitSequence(u8, head_text, "\r\n");
    while (lines.next()) |ln| {
        const colon = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        const name = std.mem.trim(u8, ln[0..colon], " ");
        if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Key")) {
            return std.mem.trim(u8, ln[colon + 1 ..], " ");
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// 会话注册表（全局；headlessEmit 按 window_id 路由）
// ---------------------------------------------------------------------------

/// 活跃会话句柄（写字端由连接线程独占；事件入队经 mutex 保护的双缓冲）。
pub const Session = struct {
    window_id: u32,
    /// 事件队列（emit 线程写入、连接线程读走）；pending 事件为已分配 JSON。
    pending: std.ArrayListUnmanaged([]u8) = .empty,
    lock: std.atomic.Value(bool) = .init(false),
    alive: bool = true,
    alloc: std.mem.Allocator,

    pub fn enqueue(self: *Session, event_json: []const u8) void {
        spinLock(&self.lock);
        defer spinUnlock(&self.lock);
        if (!self.alive) return;
        const copy = self.alloc.dupe(u8, event_json) catch return;
        self.pending.append(self.alloc, copy) catch {
            self.alloc.free(copy);
        };
    }

    /// 取走全部待发事件（连接线程；返回所有权给调用方）。
    pub fn drain(self: *Session, alloc: std.mem.Allocator) [][]u8 {
        spinLock(&self.lock);
        defer spinUnlock(&self.lock);
        const items = alloc.dupe([]u8, self.pending.items) catch return &.{};
        self.pending.clearRetainingCapacity();
        return items;
    }
};

var sessions_lock: std.atomic.Value(bool) = .init(false);
var sessions: std.ArrayListUnmanaged(*Session) = .empty;
var next_server_window: std.atomic.Value(u32) = .init(SERVER_WINDOW_BASE);

pub fn register(session: *Session) void {
    spinLock(&sessions_lock);
    defer spinUnlock(&sessions_lock);
    sessions.append(std.heap.page_allocator, session) catch {};
}

pub fn unregister(session: *Session) void {
    spinLock(&sessions_lock);
    defer spinUnlock(&sessions_lock);
    session.alive = false;
    // 释放残留 pending（含列表 backing；正常路径 drain 已取走）
    for (session.pending.items) |item| session.alloc.free(item);
    session.pending.deinit(session.alloc);
    for (sessions.items, 0..) |s, i| {
        if (s == session) {
            _ = sessions.swapRemove(i);
            break;
        }
    }
}

/// 分配 server 窗口 id（原子递增）。
pub fn nextWindowId() u32 {
    return next_server_window.fetchAdd(1, .monotonic);
}

/// 事件路由：window_id 命中会话 → 入队；未命中（broadcast/原生窗口）→ 投递所有会话。
/// 对齐 Wails server 模式的「事件广播到浏览器客户端」语义。
pub fn routeEvent(window_id: u32, event_json: []const u8) void {
    spinLock(&sessions_lock);
    defer spinUnlock(&sessions_lock);
    var matched = false;
    for (sessions.items) |s| {
        if (s.window_id == window_id) {
            s.enqueue(event_json);
            matched = true;
        }
    }
    if (!matched) {
        for (sessions.items) |s| {
            s.enqueue(event_json);
        }
    }
}

pub fn sessionCount() usize {
    spinLock(&sessions_lock);
    defer spinUnlock(&sessions_lock);
    return sessions.items.len;
}

// ---------------------------------------------------------------------------
// 测试（纯逻辑：upgrade 响应/upgrade 判定/窗口 id 空间）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "v0.3.7: upgrade 响应含 101 + Accept（RFC6455 已知向量）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // RFC 6455 §1.3 示例 key → 已知 accept
    const resp = try upgradeResponse(arena.allocator(), "dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expect(std.mem.indexOf(u8, resp, "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
}

test "v0.3.7: isWsUpgrade 判定 + key 提取" {
    const head = "GET /zilt/ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    const key = isWsUpgrade(head).?;
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", key);
    try testing.expect(isWsUpgrade("GET /index.html HTTP/1.1\r\n\r\n") == null);
}

test "v0.3.7: server 窗口 id 空间与注册表路由" {
    const id0 = nextWindowId();
    try testing.expect(id0 >= SERVER_WINDOW_BASE);
    const session = try testing.allocator.create(Session);
    session.* = .{ .window_id = id0, .alloc = testing.allocator };
    defer testing.allocator.destroy(session);
    register(session);
    try testing.expect(sessionCount() >= 1);
    routeEvent(id0, "{\"routed\":true}");
    // 原生窗口 id 不投递到任何会话时 → 广播（这里也命中该会话）
    routeEvent(1, "{\"broadcast\":true}");
    const drained = session.drain(testing.allocator);
    defer {
        for (drained) |item| testing.allocator.free(item);
        testing.allocator.free(drained);
    }
    try testing.expectEqual(@as(usize, 2), drained.len);
    unregister(session);
    try testing.expectEqual(@as(usize, 0), sessionCount());
}
