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
    /// v0.1.18：预定义角色（undo/redo/cut/copy/paste/delete/select_all）
    role: ?[]const u8 = null,
    /// v0.1.18：菜单项图标（.ico/.bmp 路径）
    icon: ?[]const u8 = null,
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
    /// v0.3.16 G17：暗色模式托盘图标（Wails SetDarkModeIcon 对齐）。null = 恢复
    /// 与亮色同图标。主题切换（themeChanged）时后端自动换发。
    set_dark_icon: ?[]const u8,
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

/// v0.4.0 H11：'gpu'（Win DXGI EnumAdapters / Linux /sys/class/drm 解析）
pub const InfoKind = enum { os, monitors, all, gpu };

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

pub const FsTarget = struct {
    path: []const u8,
    /// v0.1.19：根目录（appData/appConfig/appCache/home/desktop/documents/
    /// downloads/pictures/videos/temp/exe）。null = appData（v0.1.16 行为）。
    scope: ?[]const u8 = null,
};
pub const FsWrite = struct {
    path: []const u8,
    data: []const u8,
    scope: ?[]const u8 = null,
};
pub const FsMove = struct {
    from: []const u8,
    to: []const u8,
    scope: ?[]const u8 = null,
    to_scope: ?[]const u8 = null,
};
pub const FsOp = union(enum) {
    read: FsTarget,
    write: FsWrite,
    append: FsWrite,
    exists: FsTarget,
    remove: FsTarget,
    /// 递归创建目录
    mkdir: FsTarget,
    /// 递归删除目录
    remove_dir: FsTarget,
    read_dir: FsTarget,
    stat: FsTarget,
    rename: FsMove,
    copy: FsMove,
    /// 各 scope 解析出的绝对路径（调试/授权可视化）
    roots,
    // ---- v0.1.22 ----
    /// 目录监视（ReadDirectoryChangesW），变更走 `fsEvent`
    watch: FsWatchReq,
    unwatch: i64,
    /// 流式读取（大文件分块），分块走 `fsChunk`（base64）
    read_stream: FsStreamReq,
};

pub const FsWatchReq = struct {
    /// 目录（相对 scope）；空 = scope 根
    path: []const u8 = "",
    scope: ?[]const u8 = null,
    recursive: bool = true,
};

pub const FsStreamReq = struct {
    path: []const u8,
    scope: ?[]const u8 = null,
    chunk_size: u32 = 64 * 1024,
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
    // ---- v0.1.20（WinHTTP）----
    /// 显式代理（"http://127.0.0.1:7890"）；null = 系统代理
    proxy: ?[]const u8 = null,
    /// 忽略证书错误（自签测试环境用；生产不要开）
    insecure_tls: bool = false,
    follow_redirects: bool = true,
    /// 流式：边读边发 `httpChunk` 事件（base64），httpResponse 的 body 为空
    stream: bool = false,
    /// multipart/form-data 分片（非空时覆盖 body 并自动设置 Content-Type）
    multipart: ?[]const MultiPart = null,
    /// v0.3.8 E6：multipart 上传进度——发送过程中发 `httpUploadProgress`
    /// {id, written, total} 事件（Win ~10Hz 节流；Linux 粗粒度 0/total 两帧，
    /// libsoup3 无字节级上传进度 API，文档化差异）
    upload_progress: bool = false,
};

pub const MultiPart = struct {
    name: []const u8,
    data: []const u8 = "",
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    /// v0.3.8 E6：data 的编码（"text" | "base64"）——二进制分片走 base64
    /// （JS 侧 `http.upload` 的 parts 默认 base64，构建 multipart 前解码）
    encoding: []const u8 = "text",
};

pub const HttpOp = union(enum) {
    request: HttpRequest,
    /// v0.4.1 H14：断点续传分块上传（JSON-tus-lite 协议：PATCH 分块 +
    /// `Upload-Offset` 请求头 + 响应体 `{"offset":N}` 回执；状态落盘 appData
    /// 支持重启续传；fail_after 供冒烟演练「中断→续传」路径）
    upload_resumable: UploadResumableReq,
};

pub const UploadResumableReq = struct {
    id: i64,
    url: []const u8,
    /// 本地文件绝对路径（fs scope 校验由调用方——builtin——保证）
    path: []const u8,
    chunk_size: u32 = 64 * 1024,
    /// 本会话发送 N 个分块后强制失败（0 = 正常）；状态已逐块落盘 →
    /// 下次调用从持久化 offset 续传
    fail_after: u32 = 0,
};

/// WebSocket（v0.1.16）。connect 异步执行：立即返回，握手结果与后续消息
/// 都走 `wsEvent` 事件（kind: open/message/close/error）。
pub const WsOp = union(enum) {
    /// v0.1.20：ws:// 与 wss:// 都支持（wss 走 WinHTTP/Schannel）
    connect: struct {
        id: i64,
        url: []const u8,
        proxy: ?[]const u8 = null,
        insecure_tls: bool = false,
        headers: []const u8 = "",
    },
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
    /// v0.1.17：数据分区名。null/空 = 与主 webview 共享 Environment（Cookie/
    /// localStorage/IndexedDB 共享）；非空 = 独立 Environment + 独立 user data
    /// folder（`<profile>\WebView2-partitions\<name>`），该 webview 的 Web 存储
    /// 与主页面完全隔离。同一 partition 名在多次 create 间复用同一个 Environment。
    partition: ?[]const u8 = null,
    /// v0.3.2：无痕子 webview（Win：InPrivate controller；Linux：ephemeral data
    /// manager）。与 partition 互斥——同时给出时 incognito 优先（分区被忽略）。
    incognito: bool = false,
};
pub const WebviewsOp = union(enum) {
    create: WebviewCreate,
    remove: i64,
    navigate: struct { id: i64, url: []const u8 },
    set_bounds: struct { id: i64, x: i32, y: i32, width: i32, height: i32 },
    focus: i64,
    list,
    /// v0.1.17：在子 webview 内执行脚本。异步：结果走 `webviewEval` 事件
    /// （payload {rid,id,ok,value|error}）。rid 由前端生成，用于匹配 Promise。
    eval: WebviewEval,
};
pub const WebviewEval = struct { id: i64, script: []const u8, rid: i64 = 0 };

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
    /// v0.3.16 G19：全局光标位置（屏幕坐标；Wails/Tauri cursor_position 对齐）
    cursor_position,
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
    /// v0.1.19：更新器（info = 状态；check = 触发检查/下载/替换）
    updater: UpdaterOp,
    /// v0.1.21：运行时授权（持久化到 acl.json）
    acl: AclOp,
};

pub const AclGrant = struct {
    /// fs / shell / http
    kind: []const u8,
    /// 资源模式（"documents/**"、"git"、"https://api.x/*"）
    pattern: []const u8,
};

pub const AclOp = union(enum) {
    list,
    grant: AclGrant,
    revoke: AclGrant,
};

pub const UpdaterOp = union(enum) {
    info,
    check,
    /// v0.3.4：跳过指定版本（skipped.json；重复 skip 覆盖）
    skip: []const u8,
};

/// v0.1.17：SQL 操作。query 返回行集 JSON；execute 返回 {changes,last_id}。
pub const SqlOp = union(enum) {
    query: SqlQuery,
    execute: SqlQuery,
    /// v0.1.22：事务化迁移（成功后设置 PRAGMA user_version）
    migrate: SqlMigrate,
};

pub const SqlMigrate = struct {
    db: []const u8,
    version: i32,
    statements: []const []const u8 = &.{},
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
