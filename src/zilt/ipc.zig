//! IPC 协议层（平台无关）：JSON 消息协议、comptime 命令/事件分发、Context。
//!
//! 协议（v1）：
//!   JS→Zig  {"zilt":1,"kind":"invoke","id":N,"method":"greet","args":{...}}
//!           {"zilt":1,"kind":"event","name":"frontendLog","payload":{...}}
//!   Zig→JS  {"zilt":1,"kind":"resolve","id":N,"result":<json>}
//!           {"zilt":1,"kind":"reject","id":N,"error":"ErrorName"}
//!           {"zilt":1,"kind":"event","name":"tick","payload":{...}}
//!
//! 约定：用户在 Config.commands 定义 `pub fn 名字(ctx: Context, args: struct{...}) !结果`，
//! comptime 反射自动生成分发表与 TS 绑定（见 bindings.zig）。`zilt` 标记字段用于
//! 忽略页面上其他 postMessage 流量。

const std = @import("std");
const updater = @import("updater.zig");

// ---------------------------------------------------------------------------
// 原生对话框（平台后端实现；Context 暴露类型安全接口）
// ---------------------------------------------------------------------------

pub const MsgKind = enum { info, warning, err };
pub const MsgButtons = enum { ok, ok_cancel, yes_no };
pub const Button = enum { ok, cancel, yes, no };

pub const MessageBoxOptions = struct {
    text: []const u8,
    caption: []const u8 = "提示",
    kind: MsgKind = .info,
    buttons: MsgButtons = .ok,
};

pub const Filter = struct {
    /// 显示名（如 "文本文件"）
    name: []const u8,
    /// 模式（如 "*.txt"）
    pattern: []const u8,
};

pub const FileDialogOptions = struct {
    title: []const u8 = "",
    filters: []const Filter = &.{},
    default_name: []const u8 = "",
};

pub const FolderDialogOptions = struct {
    title: []const u8 = "选择文件夹",
};

pub const ColorDialogOptions = struct {
    title: []const u8 = "选择颜色",
    /// 初始颜色（0xRRGGBB）
    default_rgb: u32 = 0x3B82F6,
    /// 展开自定义颜色区
    full_open: bool = true,
};

pub const FontDialogOptions = struct {
    title: []const u8 = "选择字体",
    /// 初始颜色（0xRRGGBB；需 effects = true 才可见颜色下拉）
    color_rgb: u32 = 0x000000,
    effects: bool = true,
};

/// 字体选择结果。
pub const FontChoice = struct {
    name: []const u8,
    /// 点大小（1/10 磅为单位的 iPointSize / 10）
    size_points: i32,
    bold: bool,
    italic: bool,
    underline: bool,
    strikeout: bool,
    color_rgb: u32,
};

pub const DialogRequest = union(enum) {
    message_box: MessageBoxOptions,
    open_file: FileDialogOptions,
    save_file: FileDialogOptions,
    /// 文件夹选择（IFileDialog FOS_PICKFOLDERS；v0.1.5）
    pick_folder: FolderDialogOptions,
    /// 多选文件（FOS_ALLOWMULTISELECT；v0.1.5）
    pick_files: FileDialogOptions,
    /// 颜色选择（ChooseColorW；v0.1.5）
    pick_color: ColorDialogOptions,
    /// 字体选择（ChooseFontW；v0.1.5）
    pick_font: FontDialogOptions,
};

pub const DialogResponse = union(enum) {
    button: Button,
    path: ?[]u8,
    /// 多选文件（每个路径与外层切片均用请求的 allocator 分配）
    paths: ?[][]u8,
    /// RGB（0xRRGGBB）
    color: ?u32,
    font: ?FontChoice,
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// 命令/事件处理器拿到的执行环境。
///
/// 两个分配器的契约：
///  - `allocator`：当前调用域（分发时是 per-message arena，响应发出后销毁）。
///  - `msg_allocator`：长生命周期分配器——emit 消息用它分配（可能比本次调用活得久，
///    需要跨线程 marshal），后端收到后用同一分配器释放。
///
/// emit 线程安全：平台后端负责把事件编排（marshal）到 UI 线程后再投递。
pub const Context = struct {
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
    backend: *anyopaque,
    emit_fn: *const fn (backend: *anyopaque, message_json: []const u8) void,
    quit_fn: *const fn (backend: *anyopaque, code: u8) void,
    /// 系统通知（需要托盘已启用；由平台后端 marshal 到 UI 线程）。null = 未启用。
    notify_fn: ?*const fn (backend: *anyopaque, title: []const u8, body: []const u8) void = null,
    /// 原生对话框（UI 线程调用；模态会阻塞至用户关闭）。null = 不可用。
    dialog_fn: ?*const fn (backend: *anyopaque, alloc: std.mem.Allocator, req: DialogRequest) anyerror!DialogResponse = null,
    /// 自动更新器环境（config.update 存在时由后端组装）。null = 未配置。
    updater_env: ?updater.Env = null,
    /// 重启以应用已暂存的更新（v0.1.5：分离接力进程拉起新 exe 后退出）。null = 不可用。
    restart_fn: ?*const fn (backend: *anyopaque) void = null,

    /// 发送系统通知（Windows: 托盘气球 → Toast）。
    pub fn notify(self: Context, title: []const u8, body: []const u8) void {
        if (self.notify_fn) |f| {
            f(self.backend, title, body);
        } else {
            std.log.warn("[zilt] notify ignored (tray not enabled in config)", .{});
        }
    }

    /// 消息框（模态）。返回用户点击的按钮。
    pub fn messageBox(self: Context, opts: MessageBoxOptions) anyerror!Button {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, self.allocator, .{ .message_box = opts });
        return switch (r) {
            .button => |b| b,
            else => error.DialogNotAvailable,
        };
    }

    /// 打开文件对话框。取消返回 null（路径用传入的 allocator 分配）。
    pub fn openFile(self: Context, alloc: std.mem.Allocator, opts: FileDialogOptions) anyerror!?[]u8 {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, alloc, .{ .open_file = opts });
        return switch (r) {
            .path => |p| p,
            else => error.DialogNotAvailable,
        };
    }

    /// 保存文件对话框（覆盖提示）。取消返回 null。
    pub fn saveFile(self: Context, alloc: std.mem.Allocator, opts: FileDialogOptions) anyerror!?[]u8 {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, alloc, .{ .save_file = opts });
        return switch (r) {
            .path => |p| p,
            else => error.DialogNotAvailable,
        };
    }

    /// 选择文件夹（IFileDialog FOS_PICKFOLDERS；模态）。取消返回 null。
    pub fn pickFolder(self: Context, alloc: std.mem.Allocator, opts: FolderDialogOptions) anyerror!?[]u8 {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, alloc, .{ .pick_folder = opts });
        return switch (r) {
            .path => |p| p,
            else => error.DialogNotAvailable,
        };
    }

    /// 多选文件（模态）。取消返回 null；路径按选择顺序排列。
    pub fn pickFiles(self: Context, alloc: std.mem.Allocator, opts: FileDialogOptions) anyerror!?[][]u8 {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, alloc, .{ .pick_files = opts });
        return switch (r) {
            .paths => |ps| ps,
            else => error.DialogNotAvailable,
        };
    }

    /// 颜色选择（模态）。返回 0xRRGGBB；取消返回 null。
    pub fn pickColor(self: Context, opts: ColorDialogOptions) anyerror!?u32 {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, self.allocator, .{ .pick_color = opts });
        return switch (r) {
            .color => |c| c,
            else => error.DialogNotAvailable,
        };
    }

    /// 字体选择（模态）。取消返回 null（字符串用传入的 allocator 分配）。
    pub fn pickFont(self: Context, alloc: std.mem.Allocator, opts: FontDialogOptions) anyerror!?FontChoice {
        const r = try (self.dialog_fn orelse return error.DialogNotAvailable)(self.backend, alloc, .{ .pick_font = opts });
        return switch (r) {
            .font => |f| f,
            else => error.DialogNotAvailable,
        };
    }

    /// 重启以应用已暂存的更新（stageUpdate 后调用；接力进程负责拉起新版本）。
    pub fn restartToApply(self: Context) void {
        if (self.restart_fn) |f| {
            f(self.backend);
        } else {
            std.log.warn("[zilt] restartToApply ignored (restart_fn not wired)", .{});
        }
    }

    /// 向前端发事件（payload 序列化为 JSON）。
    /// 注意：全程使用 msg_allocator——emit 可能发生在本次调用的 arena 销毁之后
    /// （如后台线程继续 emit）。
    pub fn emit(self: Context, name: []const u8, payload: anytype) void {
        const payload_json = std.json.Stringify.valueAlloc(self.msg_allocator, payload, .{}) catch return;
        defer self.msg_allocator.free(payload_json);
        self.emitJson(name, payload_json);
    }

    /// 向前端发事件（无 payload）。
    pub fn emitNull(self: Context, name: []const u8) void {
        self.emitJson(name, "null");
    }

    fn emitJson(self: Context, name: []const u8, payload_json: []const u8) void {
        const msg = encodeEvent(self.msg_allocator, name, payload_json) catch return;
        self.emit_fn(self.backend, msg); // 所有权转移给后端（UI 线程用完用 msg_allocator 释放）
    }

    /// 请求退出应用（在 UI 线程的命令/事件回调内调用）。
    pub fn quit(self: Context, code: u8) void {
        self.quit_fn(self.backend, code);
    }
};

// ---------------------------------------------------------------------------
// 编码（Zig → JS）
// ---------------------------------------------------------------------------

/// JSON 字符串字面量转义（覆盖 " \ 与控制字符；输入按 UTF-8 原样透传）。
fn jsonEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.print(alloc, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(alloc, c);
                }
            },
        }
    }
    try buf.append(alloc, '"');
    return buf.toOwnedSlice(alloc);
}

pub fn encodeResolve(alloc: std.mem.Allocator, id: u64, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"zilt\":1,\"kind\":\"resolve\",\"id\":{d},\"result\":{s}}}", .{ id, result_json });
}

pub fn encodeReject(alloc: std.mem.Allocator, id: u64, error_name: []const u8) ![]u8 {
    const name_json = try jsonEscape(alloc, error_name);
    defer alloc.free(name_json);
    return std.fmt.allocPrint(alloc, "{{\"zilt\":1,\"kind\":\"reject\",\"id\":{d},\"error\":{s}}}", .{ id, name_json });
}

pub fn encodeEvent(alloc: std.mem.Allocator, name: []const u8, payload_json: []const u8) ![]u8 {
    const name_json = try jsonEscape(alloc, name);
    defer alloc.free(name_json);
    return std.fmt.allocPrint(alloc, "{{\"zilt\":1,\"kind\":\"event\",\"name\":{s},\"payload\":{s}}}", .{ name_json, payload_json });
}

// ---------------------------------------------------------------------------
// 解码（JS → Zig）
// ---------------------------------------------------------------------------

pub const Message = union(enum) {
    invoke: struct { id: u64, method: []const u8, args_json: []const u8 },
    event: struct { name: []const u8, payload_json: []const u8 },
    ignore,
};

/// 解码结果。字段字符串指向内部 arena，须在 deinit 前用完。
pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    msg: Message,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
    }
};

pub fn decode(gpa: std.mem.Allocator, raw: []const u8) !Decoded {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return .{ .arena = arena, .msg = .ignore };
    if (v != .object) return .{ .arena = arena, .msg = .ignore };
    const obj = v.object;

    const tag = obj.get("zilt") orelse return .{ .arena = arena, .msg = .ignore };
    if (tag != .integer or tag.integer != 1) return .{ .arena = arena, .msg = .ignore };

    const kind = obj.get("kind") orelse return .{ .arena = arena, .msg = .ignore };
    if (kind != .string) return .{ .arena = arena, .msg = .ignore };

    if (std.mem.eql(u8, kind.string, "invoke")) {
        const id_v = obj.get("id") orelse return .{ .arena = arena, .msg = .ignore };
        if (id_v != .integer) return .{ .arena = arena, .msg = .ignore };
        const method_v = obj.get("method") orelse return .{ .arena = arena, .msg = .ignore };
        if (method_v != .string) return .{ .arena = arena, .msg = .ignore };
        const args_v = obj.get("args") orelse std.json.Value{ .null = {} };
        const args_json = std.json.Stringify.valueAlloc(a, args_v, .{}) catch return .{ .arena = arena, .msg = .ignore };
        return .{ .arena = arena, .msg = .{ .invoke = .{
            .id = @intCast(id_v.integer),
            .method = method_v.string,
            .args_json = args_json,
        } } };
    }

    if (std.mem.eql(u8, kind.string, "event")) {
        const name_v = obj.get("name") orelse return .{ .arena = arena, .msg = .ignore };
        if (name_v != .string) return .{ .arena = arena, .msg = .ignore };
        const payload_v = obj.get("payload") orelse std.json.Value{ .null = {} };
        const payload_json = std.json.Stringify.valueAlloc(a, payload_v, .{}) catch return .{ .arena = arena, .msg = .ignore };
        return .{ .arena = arena, .msg = .{ .event = .{ .name = name_v.string, .payload_json = payload_json } } };
    }

    return .{ .arena = arena, .msg = .ignore };
}

// ---------------------------------------------------------------------------
// comptime 命令表
// ---------------------------------------------------------------------------

pub const ContextType = Context;

/// 命令元数据（codegen 与运行时分发共用）。
pub const Meta = struct {
    name: []const u8,
    args: ?type, // null = 无参数
    result: type, // void 表示无返回
};

fn fnMeta(comptime f: anytype) Meta {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const has_args = info.param_types.len == 2;
    return .{
        .name = "", // 由调用方填
        .args = if (has_args) info.param_types[1].? else null,
        .result = info.return_type.?,
    };
}

/// 提取命令命名空间的全部元数据（跳过非函数 decl）。
pub fn commandMetas(comptime Commands: type) []const Meta {
    const decl_names = @typeInfo(Commands).@"struct".decl_names;
    var count: usize = 0;
    for (decl_names) |name| {
        if (@typeInfo(@TypeOf(@field(Commands, name))) == .@"fn") count += 1;
    }
    var metas: [count]Meta = undefined;
    var i: usize = 0;
    for (decl_names) |name| {
        const f = @field(Commands, name);
        if (@typeInfo(@TypeOf(f)) != .@"fn") continue;
        var m = fnMeta(f);
        m.name = name;
        // 剥掉 error union：result 存 payload 类型
        const r = m.result;
        m.result = switch (@typeInfo(r)) {
            .error_union => |eu| eu.payload,
            else => r,
        };
        metas[i] = m;
        i += 1;
    }
    const frozen = metas;
    return &frozen;
}

fn makeHandler(comptime f: anytype) *const fn (Context, []const u8) anyerror![]u8 {
    const Impl = struct {
        fn run(ctx: Context, args_json: []const u8) anyerror![]u8 {
            const info = @typeInfo(@TypeOf(f)).@"fn";
            const has_args = info.param_types.len == 2;
            const R = info.return_type.?;
            const result_t = switch (@typeInfo(R)) {
                .error_union => |eu| eu.payload,
                else => R,
            };
            const is_err_union = @typeInfo(R) == .error_union;

            if (comptime !has_args) {
                if (comptime is_err_union) {
                    const r = try f(ctx);
                    return serializeResult(ctx, result_t, r);
                } else {
                    const r = f(ctx);
                    return serializeResult(ctx, result_t, r);
                }
            }
            const ArgsT = info.param_types[1].?;
            if (comptime ArgsT == void) {
                if (comptime is_err_union) {
                    const r = try f(ctx, {});
                    return serializeResult(ctx, result_t, r);
                } else {
                    const r = f(ctx, {});
                    return serializeResult(ctx, result_t, r);
                }
            }
            var parsed = try std.json.parseFromSlice(ArgsT, ctx.allocator, args_json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (comptime is_err_union) {
                const r = try f(ctx, parsed.value);
                return serializeResult(ctx, result_t, r);
            } else {
                const r = f(ctx, parsed.value);
                return serializeResult(ctx, result_t, r);
            }
        }

        fn serializeResult(ctx: Context, comptime RT: type, result: RT) ![]u8 {
            if (RT == void) return ctx.allocator.dupe(u8, "null");
            return std.json.Stringify.valueAlloc(ctx.allocator, result, .{});
        }
    };
    return &Impl.run;
}

/// 按方法名分发命令。未知命令返回 error.UnknownCommand。
pub fn dispatch(comptime Commands: type, ctx: Context, method: []const u8, args_json: []const u8) anyerror![]u8 {
    inline for (@typeInfo(Commands).@"struct".decl_names) |name| {
        const f = @field(Commands, name);
        if (@typeInfo(@TypeOf(f)) == .@"fn" and std.mem.eql(u8, name, method)) {
            return makeHandler(f)(ctx, args_json);
        }
    }
    return error.UnknownCommand;
}

fn makeEventHandler(comptime f: anytype) *const fn (Context, []const u8) anyerror!void {
    const Impl = struct {
        fn run(ctx: Context, payload_json: []const u8) anyerror!void {
            const info = @typeInfo(@TypeOf(f)).@"fn";
            const has_payload = info.param_types.len == 2;
            const R = info.return_type.?;
            const is_err_union = @typeInfo(R) == .error_union;

            if (comptime !has_payload) {
                if (comptime is_err_union) try f(ctx) else f(ctx);
                return;
            }
            const PT = info.param_types[1].?;
            if (comptime PT == void) {
                if (comptime is_err_union) try f(ctx, {}) else f(ctx, {});
                return;
            }
            var parsed = try std.json.parseFromSlice(PT, ctx.allocator, payload_json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (comptime is_err_union) try f(ctx, parsed.value) else f(ctx, parsed.value);
        }
    };
    return &Impl.run;
}

/// 按事件名分发 JS→Zig 事件；返回是否命中了处理器。
pub fn dispatchEvent(comptime Events: type, ctx: Context, name: []const u8, payload_json: []const u8) bool {
    inline for (@typeInfo(Events).@"struct".decl_names) |ename| {
        const f = @field(Events, ename);
        if (@typeInfo(@TypeOf(f)) == .@"fn" and std.mem.eql(u8, ename, name)) {
            makeEventHandler(f)(ctx, payload_json) catch |err| {
                std.log.warn("[zilt] event '{s}' handler failed: {s}", .{ name, @errorName(err) });
            };
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// 注入到页面的运行时（window.zilt）——命令无关，纯静态
// ---------------------------------------------------------------------------

pub const runtime_js =
    \\(() => {
    \\  const resolvers = new Map();
    \\  const listeners = new Map();
    \\  let nextId = 1;
    \\  const post = (m) => window.chrome.webview.postMessage(m);
    \\  window.chrome.webview.addEventListener('message', (e) => {
    \\    const m = e.data;
    \\    if (!m || m.zilt !== 1) return;
    \\    if (m.kind === 'resolve') {
    \\      const r = resolvers.get(m.id);
    \\      if (r) { resolvers.delete(m.id); r.resolve(m.result); }
    \\    } else if (m.kind === 'reject') {
    \\      const r = resolvers.get(m.id);
    \\      if (r) { resolvers.delete(m.id); r.reject(new Error(m.error)); }
    \\    } else if (m.kind === 'event') {
    \\      const ls = listeners.get(m.name);
    \\      if (ls) for (const cb of ls) { try { cb(m.payload); } catch (err) { console.error('[zilt] listener error', err); } }
    \\    }
    \\  });
    \\  window.zilt = {
    \\    invoke: (method, args) => new Promise((resolve, reject) => {
    \\      const id = nextId++;
    \\      resolvers.set(id, { resolve, reject });
    \\      post({ zilt: 1, kind: 'invoke', id, method, args: args ?? {} });
    \\    }),
    \\    emit: (name, payload) => post({ zilt: 1, kind: 'event', name, payload: payload ?? null }),
    \\    on: (name, cb) => {
    \\      const ls = listeners.get(name) ?? [];
    \\      ls.push(cb);
    \\      listeners.set(name, ls);
    \\    },
    \\    version: '0.2.0-phase2',
    \\  };
    \\  window.zilt.on('__reload', () => window.location.reload());
    \\})();
    \\
;

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestCommands = struct {
    pub fn add(_: Context, args: struct { a: f64, b: f64 }) !f64 {
        return args.a + args.b;
    }
    pub fn greet(ctx: Context, args: struct { name: []const u8 }) !struct { message: []const u8, length: usize } {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{args.name});
        return .{ .message = msg, .length = msg.len };
    }
    pub fn failNow(_: Context, args: struct {}) !void {
        _ = args;
        return error.DemoFailure;
    }
    pub fn noArgs(ctx: Context) !struct { ok: bool } {
        _ = ctx;
        ctx_ok = true;
        return .{ .ok = true };
    }
    var ctx_ok: bool = false;
};

const TestEvents = struct {
    pub var last_name: []const u8 = "";
    pub var last_msg: []const u8 = "";
    pub fn frontendLog(_: Context, payload: struct { msg: []const u8 }) void {
        last_name = "frontendLog";
        last_msg = payload.msg;
    }
};

fn testEmit(backend: *anyopaque, message_json: []const u8) void {
    const list: *std.ArrayList(u8) = @ptrCast(@alignCast(backend));
    list.appendSlice(testing.allocator, message_json) catch {};
    testing.allocator.free(message_json); // 模拟后端用 msg_allocator 释放的契约
}
fn testQuit(backend: *anyopaque, code: u8) void {
    _ = backend;
    _ = code;
}

fn testContext(allocator: std.mem.Allocator, backend: *anyopaque) Context {
    return .{
        .allocator = allocator,
        .msg_allocator = testing.allocator,
        .backend = backend,
        .emit_fn = testEmit,
        .quit_fn = testQuit,
    };
}

test "decode: invoke / event / ignore" {
    var d = try decode(testing.allocator, "{\"zilt\":1,\"kind\":\"invoke\",\"id\":7,\"method\":\"add\",\"args\":{\"a\":2,\"b\":3}}");
    defer d.deinit();
    try testing.expect(d.msg == .invoke);
    try testing.expectEqual(@as(u64, 7), d.msg.invoke.id);
    try testing.expectEqualStrings("add", d.msg.invoke.method);
    try testing.expectEqualStrings("{\"a\":2,\"b\":3}", d.msg.invoke.args_json);

    var d2 = try decode(testing.allocator, "{\"zilt\":1,\"kind\":\"event\",\"name\":\"x\",\"payload\":[1,2]}");
    defer d2.deinit();
    try testing.expect(d2.msg == .event);
    try testing.expectEqualStrings("[1,2]", d2.msg.event.payload_json);

    var d3 = try decode(testing.allocator, "not json at all");
    defer d3.deinit();
    try testing.expect(d3.msg == .ignore);

    var d4 = try decode(testing.allocator, "{\"hello\":\"world\"}");
    defer d4.deinit();
    try testing.expect(d4.msg == .ignore);
}

test "dispatch: invoke with args, error, no-args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = testContext(arena.allocator(), undefined);

    const r1 = try dispatch(TestCommands, ctx, "add", "{\"a\":2,\"b\":3}");
    try testing.expectEqualStrings("5", r1);

    const r2 = try dispatch(TestCommands, ctx, "greet", "{\"name\":\"Zilt\"}");
    try testing.expectEqualStrings("{\"message\":\"Hello, Zilt!\",\"length\":12}", r2);

    try testing.expectError(error.DemoFailure, dispatch(TestCommands, ctx, "failNow", "{}"));
    try testing.expectError(error.UnknownCommand, dispatch(TestCommands, ctx, "nope", "{}"));

    const r3 = try dispatch(TestCommands, ctx, "noArgs", "null");
    try testing.expectEqualStrings("{\"ok\":true}", r3);
}

test "events: dispatch handled / unhandled" {
    const ctx = testContext(testing.allocator, undefined);
    try testing.expect(dispatchEvent(TestEvents, ctx, "frontendLog", "{\"msg\":\"hi\"}"));
    try testing.expectEqualStrings("hi", TestEvents.last_msg);
    try testing.expect(!dispatchEvent(TestEvents, ctx, "unknownEvent", "null"));
}

test "encode: resolve / reject / event" {
    const r = try encodeResolve(testing.allocator, 3, "{\"x\":1}");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"zilt\":1,\"kind\":\"resolve\",\"id\":3,\"result\":{\"x\":1}}", r);

    const j = try encodeReject(testing.allocator, 4, "Oops");
    defer testing.allocator.free(j);
    try testing.expectEqualStrings("{\"zilt\":1,\"kind\":\"reject\",\"id\":4,\"error\":\"Oops\"}", j);

    const e = try encodeEvent(testing.allocator, "tick", "{\"n\":1}");
    defer testing.allocator.free(e);
    try testing.expectEqualStrings("{\"zilt\":1,\"kind\":\"event\",\"name\":\"tick\",\"payload\":{\"n\":1}}", e);
}

test "context.emit marshals encoded event" {
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const ctx = testContext(testing.allocator, @ptrCast(&captured));
    ctx.emit("tick", .{ .n = 5 });
    try testing.expectEqualStrings("{\"zilt\":1,\"kind\":\"event\",\"name\":\"tick\",\"payload\":{\"n\":5}}", captured.items);
}

test "metas reflect command signatures" {
    const metas = comptime commandMetas(TestCommands);
    try testing.expectEqual(@as(usize, 4), metas.len);
    try testing.expectEqualStrings("add", metas[0].name);
    try testing.expect(metas[0].result == f64);
    try testing.expect(metas[2].result == void); // failNow
    try testing.expect(metas[3].args == null); // noArgs
}
