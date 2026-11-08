//! 系统能力统一请求协议（v0.1.13 / v0.1.14）。
//!
//! `window.zilt.*` 的所有系统调用都归一到 `Request`，由后端在 UI 线程执行一次
//! marshal；`Result` 再序列化为 JSON 回到前端。这样新增一项能力只需扩一个
//! union 分支，而不是给 `ipc.Context` 加一个函数指针。
const std = @import("std");
const taskbar = @import("taskbar.zig");
const sysinfo = @import("sysinfo.zig");
const shell = @import("shell.zig");
const autostart = @import("autostart.zig");
const theme = @import("theme.zig");
const shared_sql = @import("sql.zig");

pub const MenuAdd = struct {
    parent: ?[]const u8 = null,
    /// -1 = 追加
    index: i32 = -1,
    id: ?[]const u8 = null,
    label: []const u8 = "",
    accel: ?[]const u8 = null,
    checked: bool = false,
    enabled: bool = true,
};

pub const MenuSet = struct {
    path: []const u8 = "",
    label: ?[]const u8 = null,
    checked: ?bool = null,
    enabled: ?bool = null,
    accel: ?[]const u8 = null,
};

pub const MenuOp = union(enum) {
    /// 当前菜单树快照（JSON）
    list,
    /// 在菜单栏插入
    add: MenuAdd,
    remove: []const u8,
    set: MenuSet,
    /// 在窗口坐标处程序化弹出（右键上下文菜单）
    popup: struct { x: i32 = 0, y: i32 = 0 },
};

pub const ClickAction = enum {
    none,
    toggle_window,
    show_menu,
    emit_event,
};

pub const TrayOp = union(enum) {
    set_tooltip: []const u8,
    /// null = 恢复默认图标
    set_icon: ?[]const u8,
    set_click: struct {
        left: ClickAction = .toggle_window,
        middle: ClickAction = .none,
        double: ClickAction = .toggle_window,
    },
};

pub const HotkeyOp = union(enum) {
    register: struct { id: []const u8, accel: []const u8 },
    unregister: []const u8,
    /// 已注册项 + 冲突报告（JSON）
    list,
};

pub const InfoKind = enum { os, monitors, all };

pub const AutostartOp = union(enum) {
    query,
    enable: ?[]const u8,
    disable,
    toggle,
};

pub const StoreSet = struct { key: []const u8, value: []const u8 };
pub const StoreOp = union(enum) {
    get: []const u8,
    set: StoreSet,
    remove: []const u8,
    keys,
    all,
};

pub const FsWrite = struct { path: []const u8, data: []const u8 };
pub const FsOp = union(enum) {
    read: []const u8,
    write: FsWrite,
    exists: []const u8,
    remove: []const u8,
};

/// 窗口状态（v0.1.16 window-state）：读当前几何 / 立即持久化
pub const WindowStateOp = enum { get, save };

/// 应用服务（v0.1.16）
pub const ServicesOp = union(enum) {
    /// 全部服务：[{name, scope, started}]
    list,
    /// 单个服务状态
    status: []const u8,
    start: []const u8,
    stop: []const u8,
};

/// HTTP 请求（v0.1.16）。异步执行：立即返回，完成后以 `httpResponse` 事件回传。
/// headers 用 "A: 1\r\nB: 2" 单串传递，避免嵌套数组的 IPC 编解码开销。
pub const HttpRequest = struct {
    /// 调用方生成，用于在事件里匹配（避免并发请求串号）
    id: i64,
    url: []const u8,
    method: []const u8 = "GET",
    headers: []const u8 = "",
    body: []const u8 = "",
    timeout_ms: u32 = 30_000,
};

pub const HttpOp = union(enum) {
    request: HttpRequest,
};

/// WebSocket（v0.1.16）。connect 异步执行：立即返回，握手结果与后续消息
/// 都走 `wsEvent` 事件（kind: open/message/close/error）。
pub const WsOp = union(enum) {
    /// url 仅支持 ws://（wss 需 TLS，明确报错）
    connect: struct { id: i64, url: []const u8 },
    send: struct { id: i64, data: []const u8 },
    close: struct { id: i64, code: u16 = 1000, reason: []const u8 = "" },
};

/// 单窗口多 WebView（v0.1.16）。create 同步返回 id（HWND 即刻创建，
/// controller 异步就绪；早于就绪的 navigate 会排队）。
pub const WebviewCreate = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 400,
    height: i32 = 300,
    /// 就绪后导航的目标；空 = about:blank
    url: []const u8 = "",
};
pub const WebviewsOp = union(enum) {
    create: WebviewCreate,
    remove: i64,
    navigate: struct { id: i64, url: []const u8 },
    set_bounds: struct { id: i64, x: i32, y: i32, width: i32, height: i32 },
    focus: i64,
    list,
};

/// 子进程执行（v0.1.16）。spawn 立即返回；stdout/stderr/exit 经 `processEvent`
/// 事件回传。安全性：spawn 受 .command ACL 管控（capabilities.json 授权后可用），
/// 应用侧应自行限制 argv 来源。
pub const ProcessOp = union(enum) {
    /// argv[0] = 可执行文件，其余为参数；cwd 可空
    spawn: struct { id: i64, argv: []const []const u8, cwd: ?[]const u8 = null },
    kill: struct { id: i64, exit_code: u32 = 1 },
    list,
};

pub const Request = union(enum) {
    menu: MenuOp,
    tray: TrayOp,
    hotkey: HotkeyOp,
    taskbar: taskbar.Request,
    info: InfoKind,
    shell: shell.Target,
    /// 管理员重启（提权拉起当前 exe）；payload = 额外参数
    admin_restart: ?[]const u8,
    autostart: AutostartOp,
    appearance: theme.Appearance,
    /// v0.1.16：KV 存储（app_data 下 store.json）
    store: StoreOp,
    /// v0.1.16：受限文件访问（scope = app_data，路径禁止逃逸）
    fs: FsOp,
    /// v0.1.16：窗口状态读写
    window_state: WindowStateOp,
    /// v0.1.16：服务注册表
    services: ServicesOp,
    /// v0.1.16：HTTP 请求（异步，结果走 httpResponse 事件）
    http: HttpOp,
    /// v0.1.16：WebSocket 客户端（事件走 wsEvent）
    ws: WsOp,
    /// v0.1.16：单窗口多 WebView
    webviews: WebviewsOp,
    /// v0.1.16：子进程执行（事件走 processEvent）
    process: ProcessOp,
    /// v0.1.17：SQL（SQLite，动态加载 sqlite3.dll）
    sql: SqlOp,
};

/// v0.1.17：SQL 操作。query 返回行集 JSON；execute 返回 {changes,last_id}。
pub const SqlOp = union(enum) {
    query: SqlQuery,
    execute: SqlQuery,
};
pub const SqlQuery = struct {
    /// 数据库文件路径（不存在时按 SQLite 惯例创建）
    db: []const u8,
    sql: []const u8,
    params: []const shared_sql.SqlValue = &.{},
};

pub const Result = union(enum) {
    /// 由调用方 allocator 分配的 JSON（所有权转移给结果）
    json: []u8,
    ok: bool,
    state: autostart.State,
    none: void,
};

/// 把 Result 编码成前端拿到的 JSON（json 分支的所有权转移给返回值）。
pub fn encodeResult(alloc: std.mem.Allocator, result: Result) ![]u8 {
    return switch (result) {
        .json => |j| j,
        .ok => |b| alloc.dupe(u8, if (b) "true" else "false"),
        .none => alloc.dupe(u8, "null"),
        .state => |s| blk: {
            const cmd = if (s.command) |c| try std.json.Stringify.valueAlloc(alloc, c, .{}) else try alloc.dupe(u8, "null");
            defer alloc.free(cmd);
            break :blk std.fmt.allocPrint(alloc, "{{\"enabled\":{},\"command\":{s}}}", .{ s.enabled, cmd });
        },
    };
}

/// `window.zilt.hotkey` 的注册表条目（平台无关，仅用于查询/冲突报告）。
pub const HotkeyEntry = struct {
    id: []const u8,
    accel: []const u8,
};

pub fn hotkeysToJson(alloc: std.mem.Allocator, entries: []const HotkeyEntry) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    for (entries, 0..) |e, i| {
        if (i != 0) try out.appendSlice(alloc, ",");
        const id = try std.json.Stringify.valueAlloc(alloc, e.id, .{});
        defer alloc.free(id);
        const accel = try std.json.Stringify.valueAlloc(alloc, e.accel, .{});
        defer alloc.free(accel);
        const chunk = try std.fmt.allocPrint(alloc, "{{\"id\":{s},\"accel\":{s}}}", .{ id, accel });
        defer alloc.free(chunk);
        try out.appendSlice(alloc, chunk);
    }
    try out.appendSlice(alloc, "]");
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "result encoding covers every branch" {
    const ok_json = try encodeResult(testing.allocator, .{ .ok = true });
    defer testing.allocator.free(ok_json);
    try testing.expectEqualStrings("true", ok_json);

    const none_json = try encodeResult(testing.allocator, .none);
    defer testing.allocator.free(none_json);
    try testing.expectEqualStrings("null", none_json);

    const owned = try testing.allocator.dupe(u8, "{\"a\":1}");
    const json = try encodeResult(testing.allocator, .{ .json = owned });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"a\":1}", json);

    const state = try encodeResult(testing.allocator, .{ .state = .{ .enabled = true, .command = "C:\\a b\\x.exe" } });
    defer testing.allocator.free(state);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, state, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("enabled").?.bool);
    try testing.expectEqualStrings("C:\\a b\\x.exe", parsed.value.object.get("command").?.string);
}

test "hotkey list json" {
    const entries = [_]HotkeyEntry{
        .{ .id = "save", .accel = "Ctrl+S" },
        .{ .id = "palette", .accel = "Ctrl+Shift+P" },
    };
    const json = try hotkeysToJson(testing.allocator, &entries);
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try testing.expectEqualStrings("palette", parsed.value.array.items[1].object.get("id").?.string);
}

test "request unions carry typed payloads" {
    const req = Request{ .info = .all };
    try testing.expectEqual(InfoKind.all, req.info);
    const accel_req = Request{ .hotkey = .{ .register = .{ .id = "x", .accel = "Ctrl+K" } } };
    try testing.expectEqualStrings("Ctrl+K", accel_req.hotkey.register.accel);
}
