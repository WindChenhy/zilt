//! 示例命令（JS→Zig）：每个 pub fn 就是一个可被前端 invoke 的命令。
//! 函数签名约定：fn(ctx: zilt.Context, args: struct{...}) !结果。
//! TS 绑定由 comptime 反射自动生成（zig build gen）。

const std = @import("std");
const zilt = @import("zilt");
const Context = zilt.Context;

// ---- tick demo：Zig→JS 事件（后台线程 emit，经 WM_APP marshal 到 UI 线程）----

var ticker_stop = std.atomic.Value(bool).init(true);

const TickerState = struct {
    ctx: Context,
    count: u32,
    interval_ms: u16,
};

pub fn startTicker(ctx: Context, args: struct { count: u32, interval_ms: u16 }) !void {
    ticker_stop.store(false, .release);
    // state 必须活得比本次 invoke 调用久 → 用长生命周期的 msg_allocator
    const state = try ctx.msg_allocator.create(TickerState);
    state.* = .{ .ctx = ctx, .count = args.count, .interval_ms = args.interval_ms };
    _ = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, tickerMain, .{state}) catch |err| {
        ticker_stop.store(true, .release);
        ctx.msg_allocator.destroy(state);
        return err;
    };
}

pub fn stopTicker(_: Context, args: struct {}) !void {
    _ = args;
    ticker_stop.store(true, .release);
}

fn tickerMain(state: *TickerState) void {
    const win32 = zilt.platform_windows.win32;
    var n: u32 = 0;
    while (n < state.count and !ticker_stop.load(.acquire)) : (n += 1) {
        win32.Sleep(state.interval_ms);
        state.ctx.emit("tick", .{ .n = n + 1 }); // emit 走 msg_allocator，跨线程安全
    }
    state.ctx.msg_allocator.destroy(state);
}

// ---- 基础命令 ----

pub fn greet(ctx: Context, args: struct { name: []const u8 }) !struct { message: []const u8, length: usize } {
    const msg = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{args.name});
    return .{ .message = msg, .length = msg.len };
}

pub fn add(_: Context, args: struct { a: f64, b: f64 }) !f64 {
    return args.a + args.b;
}

/// 演示 reject：错误名回传前端，JS 侧 Promise reject。
pub fn failNow(_: Context, args: struct {}) !void {
    _ = args;
    return error.DemoFailure;
}

/// 演示可选字段与嵌套对象。
pub fn queryUser(_: Context, args: struct { id: i32 }) !struct { user: ?struct { id: i32, name: []const u8 } } {
    if (args.id == 7) return .{ .user = .{ .id = 7, .name = "Ann" } };
    return .{ .user = null };
}

/// 演示枚举参数映射（TS: "fast" | "slow"）。
pub fn setMode(_: Context, args: struct { mode: enum { fast, slow } }) !struct { applied: []const u8 } {
    return .{ .applied = @tagName(args.mode) };
}

// ---- 系统能力 / 更新器 demo ----

/// 系统通知（Windows Toast；需 config.tray 启用）。
pub fn notifyMe(ctx: Context, args: struct { title: []const u8, body: []const u8 }) !void {
    ctx.notify(args.title, args.body);
}

/// 检查更新（后台线程 → updateInfo / updaterFailed 事件）。
pub fn checkUpdate(ctx: Context, args: struct {}) !void {
    _ = args;
    const env = ctx.updater_env orelse return error.UpdateNotConfigured;
    const Ctx = struct { ctx: Context, env: zilt.updater.Env };
    const S = struct {
        fn main(state: *Ctx) void {
            var arena = std.heap.ArenaAllocator.init(state.ctx.msg_allocator);
            defer arena.deinit();
            const m = zilt.updater.checkForUpdate(
                arena.allocator(),
                state.env.fetcher,
                state.env.manifest_url,
                state.env.current_version,
            ) catch |err| {
                state.ctx.emit("updaterFailed", .{ .stage = "check", .err = @errorName(err) });
                state.ctx.msg_allocator.destroy(state);
                return;
            } orelse {
                state.ctx.emit("updaterInfo", .{ .version = "", .notes = "已是最新版本" });
                state.ctx.msg_allocator.destroy(state);
                return;
            };
            state.ctx.emit("updateInfo", .{ .version = m.version, .notes = m.notes });
            state.ctx.msg_allocator.destroy(state);
        }
    };
    const state = try ctx.msg_allocator.create(Ctx);
    state.* = .{ .ctx = ctx, .env = env };
    _ = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, S.main, .{state}) catch {
        ctx.msg_allocator.destroy(state);
        return error.SpawnFailed;
    };
}

/// 安装更新（检查→下载→验签→staged，后台线程；重启后生效）。
pub fn installUpdate(ctx: Context, args: struct {}) !void {
    _ = args;
    const env = ctx.updater_env orelse return error.UpdateNotConfigured;
    const state = try ctx.msg_allocator.create(InstallCtx);
    state.* = .{ .ctx = ctx, .env = env };
    _ = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, installMain, .{state}) catch {
        ctx.msg_allocator.destroy(state);
        return error.SpawnFailed;
    };
}

fn installMain(state: *InstallCtx) void {
    const ctx = state.ctx;
    const env = state.env;
    defer ctx.msg_allocator.destroy(state);

    var arena = std.heap.ArenaAllocator.init(ctx.msg_allocator);
    defer arena.deinit();

    const m = zilt.updater.checkForUpdate(arena.allocator(), env.fetcher, env.manifest_url, env.current_version) catch |err| {
        ctx.emit("updaterFailed", .{ .stage = "check", .err = @errorName(err) });
        return;
    } orelse {
        ctx.emit("updaterInfo", .{ .version = "", .notes = "已是最新版本" });
        return;
    };

    const artifact = zilt.updater.downloadAndVerify(ctx.msg_allocator, env.fetcher, m, env.public_key) catch |err| {
        ctx.emit("updaterFailed", .{ .stage = "download", .err = @errorName(err) });
        return;
    };
    ctx.msg_allocator.free(artifact);

    zilt.updater.stageUpdate(ctx.msg_allocator, env.exe_path, env.exe_name, artifact) catch |err| {
        ctx.emit("updaterFailed", .{ .stage = "stage", .err = @errorName(err) });
        return;
    };
    ctx.emit("updateStaged", .{ .version = m.version });
}

const InstallCtx = struct { ctx: Context, env: zilt.updater.Env };
