//! v0.4.2 H15：进程内计划通知（timer 调度器）。
//!
//! OS 级 ScheduledToastNotification（WinRT）列为 stretch（R3 实验顺延）——
//! 本实现为进程内 timer：应用存活期间到点触发 ctx.notify + 发
//! `notificationScheduled {tag, fired:true}` 事件（冒烟断言面）。
//! 进程退出即失效——与 OS 级语义的差异文档化。
//!
//! 线程模型：全局自旋锁清单（server_session 同款——std.Thread.Mutex 在
//! 0.17 缺位）+ 单一调度线程（200ms 轮询，懒启动，daemon——进程退出随
//! 内核终止）。Context.notify 线程安全（Windows WM_APP marshal / Linux
//! g_idle_add 封送），emit 同理——到点直接调用。
//! 时钟：std.time.Timer 单调起点（0.17 的 milliTimestamp/nanoTimestamp
//! 已移除——deadline 为相对 ns）。

const std = @import("std");
const ipc = @import("ipc.zig");
const sys = @import("sys.zig");

const Item = struct {
    tag: []const u8,
    title: []const u8,
    body: []const u8,
    /// 相对单调时钟的到期 ns（g_timer.read() 基准）
    deadline_ns: u64,
    ctx: ipc.Context,
};

var g_lock: std.atomic.Value(bool) = .init(false);
var g_list: std.ArrayListUnmanaged(Item) = .empty;
var g_thread: ?std.Thread = null;
var g_started = false;
var g_timer: ?std.time.Timer = null;

fn spinLock(cell: *std.atomic.Value(bool)) void {
    while (cell.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn spinUnlock(cell: *std.atomic.Value(bool)) void {
    cell.store(false, .release);
}

// 近似单调钟：调度循环 200ms 步进推进（轮询粒度即为通知精度——OS 级
// 精确调度随 WinRT stretch；0.17 的 milliTimestamp/Timer 已移除）。
var g_now_ms: u64 = 0;

/// 纯函数：到点条目提取（测试面；调度线程内联同逻辑）。
pub fn extractDue(list: []Item, now: u64, buf: []Item) usize {
    var n: usize = 0;
    for (list) |*it| {
        if (it.deadline_ns <= now) {
            if (n < buf.len) {
                buf[n] = it.*;
                n += 1;
            }
        }
    }
    return n;
}

fn schedulerLoop() void {
    const a = std.heap.page_allocator;
    var buf: [16]Item = undefined;
    while (true) {
        sys.sleepMs(200);
        g_now_ms += 200;
        const now = g_now_ms;
        spinLock(&g_lock);
        var n: usize = 0;
        var i: usize = 0;
        while (i < g_list.items.len) {
            if (g_list.items[i].deadline_ns <= now and n < buf.len) {
                buf[n] = g_list.items[i];
                n += 1;
                _ = g_list.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        spinUnlock(&g_lock);
        for (buf[0..n]) |it| {
            it.ctx.notify(it.title, it.body);
            it.ctx.emit("notificationScheduled", .{ .tag = it.tag, .fired = true });
            a.free(it.tag);
            a.free(it.title);
            a.free(it.body);
        }
    }
}

/// 计划一条通知（delay_ms 后由调度线程触发 notify + 事件；tag 供事件匹配）。
/// 字符串立即用 page_allocator 复制（跨线程所有权归调度器）。
pub fn schedule(ctx: ipc.Context, tag: []const u8, title: []const u8, body: []const u8, delay_ms: u32) void {
    const a = std.heap.page_allocator;
    const tag_c = a.dupe(u8, tag) catch return;
    const title_c = a.dupe(u8, title) catch {
        a.free(tag_c);
        return;
    };
    const body_c = a.dupe(u8, body) catch {
        a.free(tag_c);
        a.free(title_c);
        return;
    };
    const it = Item{
        .tag = tag_c,
        .title = title_c,
        .body = body_c,
        .deadline_ns = g_now_ms + @as(u64, delay_ms),
        .ctx = ctx,
    };
    spinLock(&g_lock);
    defer spinUnlock(&g_lock);
    g_list.append(a, it) catch {
        a.free(it.tag);
        a.free(it.title);
        a.free(it.body);
        return;
    };
    if (!g_started) startScheduler();
}

/// v0.4.2 H15（实测教训）：调度线程在 backend init 时启动——Webkit
/// script-message 回调内 spawn 会 SIGABRT（实测）；daemon 空转成本可忽略。
pub fn startScheduler() void {
    if (g_started) return;
    g_started = true;
    if (std.Thread.spawn(.{ .stack_size = 512 * 1024 }, schedulerLoop, .{})) |t| {
        t.detach();
        g_thread = t;
    } else |_| {
        g_started = false;
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extractDue: 到点提取与未到点保留" {
    var items = [_]Item{
        .{ .tag = "a", .title = "", .body = "", .deadline_ns = 100, .ctx = undefined },
        .{ .tag = "b", .title = "", .body = "", .deadline_ns = 5000, .ctx = undefined },
        .{ .tag = "c", .title = "", .body = "", .deadline_ns = 200, .ctx = undefined },
    };
    var buf: [16]Item = undefined;
    const n = extractDue(&items, 1000, &buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("a", buf[0].tag);
    try testing.expectEqualStrings("c", buf[1].tag);
}

test "clock: 调度钟步进推进" {
    const t1 = g_now_ms;
    sys.sleepMs(2);
    g_now_ms += 2;
    try testing.expect(g_now_ms > t1);
}
