//! inotify 目录监视（v0.2.3，Linux 侧；对应 Windows 的 ReadDirectoryChangesW）。
//!
//! inotify 没有递归选项：start 时递归遍历子目录逐个 add_watch；运行中出现的新
//! 子目录（IN_CREATE|IN_ISDIR / IN_MOVED_TO|IN_ISDIR）动态补挂。事件线程用
//! poll({inotify_fd, stop_pipe})——只 close inotify_fd 解不开阻塞的 read，
//! 自管道是标准的停止手段（对齐 Windows 侧 CancelIoEx 的教训）。
//!
//! 事件回调在**监视线程**触发，宿主必须自行封送到 UI 线程（backend 用 g_idle_add）。

const std = @import("std");
const log = @import("../../log.zig");
const sys = @import("../../sys.zig");

/// 本模块的惰性线程同步 Io（目录探测用；同 backend/window_state 的模式）。
var g_io: std.Io.Threaded = undefined;
var g_io_ready = false;
fn moduleIo() std.Io {
    if (!g_io_ready) {
        g_io = .init(std.heap.page_allocator, .{});
        g_io_ready = true;
    }
    return g_io.io();
}

const Allocator = std.mem.Allocator;

// inotify 常量（<sys/inotify.h>；std.c 在 0.17 不保证暴露，这里自持）
const IN_MODIFY: u32 = 0x0000_0002;
const IN_MOVED_FROM: u32 = 0x0000_0040;
const IN_MOVED_TO: u32 = 0x0000_0080;
const IN_CREATE: u32 = 0x0000_0100;
const IN_DELETE: u32 = 0x0000_0200;
const IN_DELETE_SELF: u32 = 0x0000_0400;
const IN_MOVE_SELF: u32 = 0x0000_0800;
const IN_ISDIR: u32 = 0x4000_0000;
const IN_ONLYDIR: u32 = 0x0100_0000;
const WATCH_MASK: u32 = IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE |
    IN_DELETE_SELF | IN_MOVE_SELF;

const event_header_size = 16; // sizeof(struct inotify_event) 头部

extern fn inotify_init1(flags: c_int) c_int;
extern fn inotify_add_watch(fd: c_int, pathname: [*:0]const u8, mask: u32) c_int;
extern fn inotify_rm_watch(fd: c_int, wd: c_int) c_int;

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 };
extern fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;

const IN_NONBLOCK: c_int = 0o4000; // O_NONBLOCK

/// 事件动作名（与 Windows 侧 payload 对齐）。
pub const action_added = "added";
pub const action_removed = "removed";
pub const action_modified = "modified";
pub const action_renamed_old = "renamed_old";
pub const action_renamed_new = "renamed_new";

pub const Watch = struct {
    id: i64,
    alloc: Allocator,
    /// 绝对监视根（NUL 结尾副本）
    root_z: [:0]u8,
    recursive: bool,
    inotify_fd: c_int,
    /// 自管道（stop 时写 1 字节解除 poll）
    stop_pipe: [2]c_int,
    /// wd → 相对目录路径（"" = 根）。**无锁**：addTree 在线程 spawn 前完成，
    /// 运行期的动态补挂只发生在监视线程内（start/stop 与线程有 join/happens-before）。
    dir_of_wd: std.AutoHashMapUnmanaged(i32, []u8) = .empty,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    /// 事件回调（监视线程触发；action 是静态串，path 调用后失效）
    on_event: *const fn (ctx: ?*anyopaque, id: i64, action: []const u8, path: []const u8) void,
    ctx: ?*anyopaque,

    /// 挂一个 watch（wd → 相对路径登记；仅监视线程/spawn 前调用）。
    fn addWatch(self: *Watch, abs_dir: []const u8, rel_dir: []const u8) void {
        const abs_z = self.alloc.allocSentinel(u8, abs_dir.len, 0) catch return;
        defer self.alloc.free(abs_z);
        @memcpy(abs_z[0..abs_dir.len], abs_dir);
        const wd = inotify_add_watch(self.inotify_fd, abs_z.ptr, WATCH_MASK);
        if (wd < 0) return;
        const gop = self.dir_of_wd.getOrPut(self.alloc, wd) catch return;
        if (gop.found_existing) {
            self.alloc.free(gop.value_ptr.*);
            gop.value_ptr.* = self.alloc.dupe(u8, rel_dir) catch return;
        } else {
            gop.value_ptr.* = self.alloc.dupe(u8, rel_dir) catch {
                _ = self.dir_of_wd.remove(wd);
                return;
            };
        }
    }

    /// 递归遍历挂 watch（启动时；depth 防符号链接/异常树爆栈）。
    fn addTree(self: *Watch, abs_dir: []const u8, rel_dir: []const u8, depth: u32) void {
        if (depth > 32) return;
        {
            self.addWatch(abs_dir, rel_dir);
        }
        if (!self.recursive) return;
        var dir = std.Io.Dir.cwd().openDir(moduleIo(), abs_dir, .{ .iterate = true }) catch return;
        defer dir.close(moduleIo());
        var it = dir.iterate();
        while (it.next(moduleIo()) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const child_abs = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ abs_dir, entry.name }) catch continue;
            defer self.alloc.free(child_abs);
            const child_rel = if (rel_dir.len == 0)
                self.alloc.dupe(u8, entry.name) catch continue
            else
                std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ rel_dir, entry.name }) catch continue;
            defer self.alloc.free(child_rel);
            self.addTree(child_abs, child_rel, depth + 1);
        }
    }

    fn emit(self: *Watch, action: []const u8, rel: []const u8) void {
        self.on_event(self.ctx, self.id, action, rel);
    }

    fn run(self: *Watch) void {
        var buf: [16 * 1024]u8 align(8) = undefined;
        while (!self.stopping.load(.acquire)) {
            var fds = [_]PollFd{
                .{ .fd = self.inotify_fd, .events = 0x0001, .revents = 0 }, // POLLIN
                .{ .fd = self.stop_pipe[0], .events = 0x0001, .revents = 0 },
            };
            const ready = poll(&fds, 2, 1000);
            if (ready <= 0) continue;
            // stop 管道可读 → 退出
            if (fds[1].revents != 0) break;

            const n = std.c.read(self.inotify_fd, &buf, buf.len);
            if (n <= 0) {
                if (self.stopping.load(.acquire)) break;
                continue;
            }
            var off: usize = 0;
            const total: usize = @intCast(n);
            while (off + event_header_size <= total) {
                const wd: i32 = @bitCast(std.mem.readInt(u32, buf[off..][0..4], .little));
                const mask: u32 = std.mem.readInt(u32, buf[off + 4 ..][0..4], .little);
                const name_len: usize = @intCast(std.mem.readInt(u32, buf[off + 12 ..][0..4], .little));
                off += event_header_size;

                var rel_dir: []const u8 = "";
                if (self.dir_of_wd.get(wd)) |d| rel_dir = d;

                if (mask & IN_DELETE_SELF != 0 or mask & IN_MOVE_SELF != 0) {
                    // 被监视目录自身没了：按 removed 上报相对根并停止
                    self.emit(action_removed, rel_dir);
                    self.stopping.store(true, .release);
                    break;
                }

                const has_name = name_len > 0 and off + name_len <= total and buf[off] != 0;
                const name: []const u8 = if (has_name) blk: {
                    const raw = buf[off..][0..name_len];
                    const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
                    break :blk raw[0..end];
                } else "";

                if (mask & IN_CREATE != 0) {
                    if (mask & IN_ISDIR != 0 and self.recursive and name.len > 0) {
                        // 新子目录 → 补挂 watch（锁外做，避免重入）
                        const abs = std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}", .{ self.root_z, rel_dir, name }) catch continue;
                        defer self.alloc.free(abs);
                        const rel = if (rel_dir.len == 0)
                            self.alloc.dupe(u8, name) catch continue
                        else
                            std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ rel_dir, name }) catch continue;
                        defer self.alloc.free(rel);
                        self.addWatch(abs, rel);
                    }
                    if (name.len > 0) self.joinEmit(action_added, rel_dir, name);
                } else if (mask & IN_MOVED_TO != 0) {
                    if (mask & IN_ISDIR != 0 and self.recursive and name.len > 0) {
                        const abs = std.fmt.allocPrint(self.alloc, "{s}/{s}/{s}", .{ self.root_z, rel_dir, name }) catch continue;
                        defer self.alloc.free(abs);
                        const rel = if (rel_dir.len == 0)
                            self.alloc.dupe(u8, name) catch continue
                        else
                            std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ rel_dir, name }) catch continue;
                        defer self.alloc.free(rel);
                        self.addWatch(abs, rel);
                    }
                    if (name.len > 0) self.joinEmit(action_renamed_new, rel_dir, name);
                } else if (mask & IN_DELETE != 0) {
                    if (name.len > 0) self.joinEmit(action_removed, rel_dir, name);
                } else if (mask & IN_MODIFY != 0) {
                    if (name.len > 0) self.joinEmit(action_modified, rel_dir, name);
                } else if (mask & IN_MOVED_FROM != 0) {
                    if (name.len > 0) self.joinEmit(action_renamed_old, rel_dir, name);
                }
                off += name_len;
            }
        }
    }

    fn joinEmit(self: *Watch, action: []const u8, rel_dir: []const u8, name: []const u8) void {
        if (rel_dir.len == 0) {
            self.emit(action, name);
            return;
        }
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, "{s}/{s}", .{ rel_dir, name }) catch return;
        self.emit(action, joined);
    }
};

/// 启动监视（线程随 start 创建）。失败时返回错误，调用方无需清理。
pub fn start(
    alloc: Allocator,
    id: i64,
    root: []const u8,
    recursive: bool,
    on_event: *const fn (ctx: ?*anyopaque, id: i64, action: []const u8, path: []const u8) void,
    ctx: ?*anyopaque,
) !*Watch {
    const fd = inotify_init1(IN_NONBLOCK);
    if (fd < 0) return error.InotifyUnavailable;
    errdefer {
        _ = std.c.close(fd);
    }

    const w = try alloc.create(Watch);
    errdefer alloc.destroy(w);
    const root_z = try alloc.allocSentinel(u8, root.len, 0);
    @memcpy(root_z[0..root.len], root);
    w.* = .{
        .id = id,
        .alloc = alloc,
        .root_z = root_z,
        .recursive = recursive,
        .inotify_fd = fd,
        .stop_pipe = .{ -1, -1 },
        .on_event = on_event,
        .ctx = ctx,
    };
    errdefer alloc.free(root_z);

    const pipe_rc = std.c.pipe(&w.stop_pipe);
    if (pipe_rc != 0) return error.InotifyUnavailable;
    errdefer {
        _ = std.c.close(w.stop_pipe[0]);
        _ = std.c.close(w.stop_pipe[1]);
    }

    // 根目录必须存在
    _ = std.Io.Dir.cwd().statFile(moduleIo(), root, .{}) catch return error.FileNotFound;

    w.addTree(root, "", 0);
    w.thread = std.Thread.spawn(.{ .stack_size = sys.threadStackSize(256 * 1024) }, Watch.run, .{w}) catch |e| {
        // 清理已挂的 wd 映射
        var it = w.dir_of_wd.iterator();
        while (it.next()) |entry| alloc.free(entry.value_ptr.*);
        w.dir_of_wd.deinit(alloc);
        return e;
    };
    return w;
}

/// 停止并释放（写 stop 管道 → join → 清理）。幂等。
pub fn stop(w: *Watch) void {
    w.stopping.store(true, .release);
    if (w.stop_pipe[1] >= 0) {
        const one = [1]u8{1};
        _ = std.c.write(w.stop_pipe[1], &one, 1);
    }
    if (w.thread) |t| {
        t.join();
        w.thread = null;
    }
    _ = std.c.close(w.inotify_fd);
    if (w.stop_pipe[0] >= 0) _ = std.c.close(w.stop_pipe[0]);
    if (w.stop_pipe[1] >= 0) _ = std.c.close(w.stop_pipe[1]);
    var it = w.dir_of_wd.iterator();
    while (it.next()) |entry| w.alloc.free(entry.value_ptr.*);
    w.dir_of_wd.deinit(w.alloc);
    w.alloc.free(w.root_z);
    w.alloc.destroy(w);
    log.print("[fs] watch stopped", .{});
}

// ---------------------------------------------------------------------------
// 测试（真实 inotify 往返）
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 0.17 无 realpath：用 cwd 下 .zig-cache 的唯一目录做监视线（进程内自增）。
var fswatch_test_seq: u32 = 0;

test "inotify watch: added/modified 事件往返" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const io = moduleIo();
    const n = fswatch_test_seq;
    fswatch_test_seq += 1;
    // 落在 /tmp（tmpfs）：inotify 在 WSL 的 9p/drvfs（/mnt/*）上不投递事件，
    // 而 0.17 又去掉了 realpath——用绝对路径同时绕开这两个限制。
    const root = try std.fmt.allocPrint(testing.allocator, "/tmp/zilt-fswatch-{d}-{d}", .{ std.c.getpid(), n });
    defer testing.allocator.free(root);
    try std.Io.Dir.createDirAbsolute(io, root, .default_dir);
    defer {
        const tmp = std.Io.Dir.openDirAbsolute(io, "/tmp", .{}) catch null;
        if (tmp) |d| {
            var dd = d;
            var it = std.mem.splitScalar(u8, root["/tmp/".len..], '/');
            dd.deleteTree(io, it.first()) catch {};
            dd.close(io);
        }
    }

    const Ctx = struct {
        events: std.ArrayListUnmanaged(struct { action: []const u8, path: []u8 }) = .empty,
        alloc: Allocator,
        fn onEvent(ctx: ?*anyopaque, id: i64, action: []const u8, path: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = id;
            const p = self.alloc.dupe(u8, path) catch return;
            self.events.append(self.alloc, .{ .action = action, .path = p }) catch {
                self.alloc.free(p);
            };
        }
        fn deinit(self: *@This()) void {
            for (self.events.items) |e| self.alloc.free(e.path);
            self.events.deinit(self.alloc);
        }
    };
    var ctx = Ctx{ .alloc = testing.allocator };
    defer ctx.deinit();

    const w = try start(testing.allocator, 1, root, false, Ctx.onEvent, &ctx);
    defer stop(w);

    // 触发：写文件（added + modified）+ 删除（removed）
    const f1 = try std.fmt.allocPrint(testing.allocator, "{s}/a.txt", .{root});
    defer testing.allocator.free(f1);
    {
        const file = try std.Io.Dir.createFileAbsolute(io, f1, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "hello", 0);
    }
    std.Io.Dir.deleteFileAbsolute(io, f1) catch {};

    // 等事件（inotify 异步；最长 3s）
    var deadline: usize = 0;
    while (deadline < 300) : (deadline += 1) {
        var has_removed = false;
        for (ctx.events.items) |e| {
            if (std.mem.eql(u8, e.action, action_removed)) has_removed = true;
        }
        if (has_removed and ctx.events.items.len >= 3) break;
        std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    }
    try testing.expect(ctx.events.items.len >= 3);
    try testing.expectEqualStrings(action_added, ctx.events.items[0].action);
    try testing.expectEqualStrings("a.txt", ctx.events.items[0].path);
    var saw_removed = false;
    for (ctx.events.items) |e| {
        if (std.mem.eql(u8, e.action, action_removed)) saw_removed = true;
    }
    try testing.expect(saw_removed);
}
