//! MCP（Model Context Protocol）服务端（v0.1.19 起；v0.3.1 深化）。
//!
//! 把应用的 Zig 命令暴露成 MCP tools，让 AI 客户端（Claude Desktop / IDE 等）
//! 直接调用。传输有两种：
//!   - HTTP JSON-RPC 2.0：`POST /mcp`（headless HTTP 服务）
//!   - stdio：`ZILT_MCP_STDIO=1`（一行一条 JSON-RPC；`zilt mcp` 命令直连应用）
//!
//! v0.3.1 增加：
//!   - `resources/list` / `resources/read`：app info / zilt.log 尾部 / tools 清单
//!   - `prompts/list` / `prompts/get`：应用概览与命令调用模板
//!   - 工具级 ACL：`ZILT_MCP_TOOLS=greet,add` 白名单（tools/list 过滤 + call 拒绝）
//!   - 通知（无 id）不回包；HTTP 层返回 202、stdio 层不写 stdout
//!
//! 安全提示：MCP 端点等于把允许的命令开放给本机调用方，只应在
//! ZILT_HEADLESS=1 且仅绑 127.0.0.1 的场景使用；白名单可进一步收紧。
const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ipc.zig");

pub const PROTOCOL_VERSION = "2024-11-05";
pub const version = @import("version.zig").version;

/// 运行时选项（headless 从 env / config 组装）。
pub const Options = struct {
    app_id: []const u8 = "app.zilt",
    /// null = 全部命令；否则只有列出的命令出现在 tools/list，且 tools/call 拒绝其余。
    tools_allowlist: ?[]const []const u8 = null,
};

/// comptime 生成全量 tools/list 的 JSON（单测/无白名单路径）。
pub fn toolsJson(comptime Commands: type) []const u8 {
    return comptime toolsJsonImpl(Commands);
}

fn toolsJsonImpl(comptime Commands: type) []const u8 {
    {
        var out: []const u8 = "[";
        var first = true;
        for (ipc.commandMetas(Commands)) |m| {
            if (m.name.len == 0) continue;
            if (!first) out = out ++ ",";
            first = false;
            out = out ++ "{\"name\":\"" ++ m.name ++ "\",\"description\":\"Zilt 命令 " ++ m.name ++ "\",\"inputSchema\":";
            out = out ++ argsSchema(m.args);
            out = out ++ "}";
        }
        return out ++ "]";
    }
}

/// 运行期 tools/list（支持白名单过滤）。调用方 free 返回值。
pub fn toolsJsonFiltered(alloc: std.mem.Allocator, comptime Commands: type, allow: ?[]const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');
    var first = true;
    for (comptime toolMetas(Commands)) |m| {
        if (allow) |list| {
            if (!allowed(list, m.name)) continue;
        }
        if (!first) try out.append(alloc, ',');
        first = false;
        const item = try std.fmt.allocPrint(
            alloc,
            "{{\"name\":\"{s}\",\"description\":\"Zilt 命令 {s}\",\"inputSchema\":{s}}}",
            .{ m.name, m.name, m.schema },
        );
        defer alloc.free(item);
        try out.appendSlice(alloc, item);
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}

/// comptime 展开的命令元数据（name + 预生成的 inputSchema）。
const ToolMeta = struct { name: []const u8, schema: []const u8 };

fn toolMetas(comptime Commands: type) []const ToolMeta {
    comptime {
        const metas = ipc.commandMetas(Commands);
        var count: usize = 0;
        for (metas) |m| {
            if (m.name.len != 0) count += 1;
        }
        var arr: [count]ToolMeta = undefined;
        var i: usize = 0;
        for (metas) |m| {
            if (m.name.len == 0) continue;
            arr[i] = .{ .name = m.name, .schema = argsSchema(m.args) };
            i += 1;
        }
        const frozen = arr;
        return &frozen;
    }
}

fn allowed(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn argsSchema(comptime maybe_args: ?type) []const u8 {
    comptime {
        const args = maybe_args orelse return "{\"type\":\"object\",\"properties\":{}}";
        const info = @typeInfo(args);
        if (info != .@"struct") return "{\"type\":\"object\",\"properties\":{}}";
        var props: []const u8 = "";
        var required: []const u8 = "";
        var first_prop = true;
        var first_req = true;
        for (info.@"struct".field_names, info.@"struct".field_types, info.@"struct".field_attrs) |fname, ftype, fattrs| {
            if (!first_prop) props = props ++ ",";
            first_prop = false;
            props = props ++ "\"" ++ fname ++ "\":" ++ fieldSchema(ftype);
            const optional = @typeInfo(ftype) == .optional or fattrs.default_value_ptr != null;
            if (!optional) {
                if (!first_req) required = required ++ ",";
                first_req = false;
                required = required ++ "\"" ++ fname ++ "\"";
            }
        }
        if (required.len == 0) {
            return "{\"type\":\"object\",\"properties\":{" ++ props ++ "}}";
        }
        return "{\"type\":\"object\",\"properties\":{" ++ props ++ "},\"required\":[" ++ required ++ "]}";
    }
}

fn fieldSchema(comptime T: type) []const u8 {
    comptime {
        const inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        return switch (@typeInfo(inner)) {
            .bool => "{\"type\":\"boolean\"}",
            .int => "{\"type\":\"integer\"}",
            .float => "{\"type\":\"number\"}",
            .@"enum" => "{\"type\":\"string\"}",
            .pointer => "{\"type\":\"string\"}",
            .array => "{\"type\":\"array\",\"items\":{}}",
            .@"struct" => "{\"type\":\"object\"}",
            else => "{}",
        };
    }
}

/// 资源清单（固定 3 项；headless 下没有窗口，故不提供截图资源）。
const resources_json =
    "{\"resources\":[" ++
    "{\"uri\":\"zilt://app/info\",\"name\":\"App info\",\"description\":\"应用 ID / 版本 / 平台 / 运行模式\",\"mimeType\":\"application/json\"}," ++
    "{\"uri\":\"zilt://app/log\",\"name\":\"Application log\",\"description\":\"zilt.log 尾部（最多 64KB）\",\"mimeType\":\"text/plain\"}," ++
    "{\"uri\":\"zilt://app/tools\",\"name\":\"MCP tools\",\"description\":\"当前暴露的 tools/list JSON\",\"mimeType\":\"application/json\"}" ++
    "]}";

/// 提示模板清单（固定 2 项）。
const prompts_json =
    "{\"prompts\":[" ++
    "{\"name\":\"app_overview\",\"description\":\"概括这个 Zilt 应用可被 AI 调用的能力\",\"arguments\":[]}," ++
    "{\"name\":\"call_command\",\"description\":\"按名称调用一个应用命令\",\"arguments\":[{\"name\":\"command\",\"description\":\"命令名（tools/list 中的 name）\",\"required\":true}]}" ++
    "]}";

/// 处理一次 JSON-RPC 请求，返回响应 JSON（allocator 分配）。
/// 返回 null 表示这是通知（无 id）——调用方不应写回任何内容。
pub fn handle(
    alloc: std.mem.Allocator,
    body: []const u8,
    ctx: ipc.Context,
    comptime Commands: type,
    opts: Options,
) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return try errorResponse(alloc, null, -32700, "Parse error");
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return try errorResponse(alloc, null, -32600, "Invalid Request");

    const id_value = root.object.get("id");
    // 通知（no id）：按 JSON-RPC 2.0 不回应
    if (id_value == null) return null;

    const id_json: []const u8 = try std.json.Stringify.valueAlloc(alloc, id_value.?, .{});
    defer alloc.free(id_json);

    const method_v = root.object.get("method") orelse return try errorResponse(alloc, id_json, -32600, "Missing method");
    const method = switch (method_v) {
        .string => |s| s,
        else => return try errorResponse(alloc, id_json, -32600, "Method must be string"),
    };

    if (std.mem.eql(u8, method, "initialize")) {
        return try std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}},\"resources\":{{}},\"prompts\":{{}}}},\"serverInfo\":{{\"name\":\"zilt\",\"version\":\"{s}\"}}}}}}",
            .{ id_json, PROTOCOL_VERSION, version },
        );
    }
    if (std.mem.eql(u8, method, "ping")) {
        return try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{id_json});
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        const tools = try toolsJsonFiltered(alloc, Commands, opts.tools_allowlist);
        defer alloc.free(tools);
        return try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tools\":{s}}}}}", .{ id_json, tools });
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const params = root.object.get("params") orelse return try errorResponse(alloc, id_json, -32602, "Missing params");
        if (params != .object) return try errorResponse(alloc, id_json, -32602, "params must be object");
        const name_v = params.object.get("name") orelse return try errorResponse(alloc, id_json, -32602, "Missing tool name");
        const tool_name = switch (name_v) {
            .string => |s| s,
            else => return try errorResponse(alloc, id_json, -32602, "tool name must be string"),
        };
        if (opts.tools_allowlist) |list| {
            if (!allowed(list, tool_name)) {
                const msg = try std.fmt.allocPrint(alloc, "ToolNotAllowed: {s}", .{tool_name});
                defer alloc.free(msg);
                return try toolResult(alloc, id_json, false, msg);
            }
        }
        const args_json: []const u8 = blk: {
            if (params.object.get("arguments")) |a| {
                break :blk try std.json.Stringify.valueAlloc(alloc, a, .{});
            }
            break :blk try alloc.dupe(u8, "{}");
        };
        defer alloc.free(args_json);

        const result = ipc.dispatch(Commands, ctx, tool_name, args_json) catch |err| {
            return try toolResult(alloc, id_json, false, @errorName(err));
        };
        defer alloc.free(result);
        return try toolResult(alloc, id_json, true, result);
    }
    if (std.mem.eql(u8, method, "resources/list")) {
        return try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, resources_json });
    }
    if (std.mem.eql(u8, method, "resources/read")) {
        const params = root.object.get("params") orelse return try errorResponse(alloc, id_json, -32602, "Missing params");
        if (params != .object) return try errorResponse(alloc, id_json, -32602, "params must be object");
        const uri_v = params.object.get("uri") orelse return try errorResponse(alloc, id_json, -32602, "Missing uri");
        const uri = switch (uri_v) {
            .string => |s| s,
            else => return try errorResponse(alloc, id_json, -32602, "uri must be string"),
        };
        const content = readResource(alloc, uri, opts, Commands) catch |err| switch (err) {
            error.UnknownResource => return try errorResponse(alloc, id_json, -32602, "Unknown resource"),
            else => return try errorResponse(alloc, id_json, -32603, "Resource read failed"),
        };
        defer alloc.free(content.text);
        const text_json = try std.json.Stringify.valueAlloc(alloc, content.text, .{});
        defer alloc.free(text_json);
        const uri_json = try std.json.Stringify.valueAlloc(alloc, uri, .{});
        defer alloc.free(uri_json);
        return try std.fmt.allocPrint(
            alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"contents\":[{{\"uri\":{s},\"mimeType\":\"{s}\",\"text\":{s}}}]}}}}",
            .{ id_json, uri_json, content.mime, text_json },
        );
    }
    if (std.mem.eql(u8, method, "prompts/list")) {
        return try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, prompts_json });
    }
    if (std.mem.eql(u8, method, "prompts/get")) {
        const params = root.object.get("params") orelse return try errorResponse(alloc, id_json, -32602, "Missing params");
        if (params != .object) return try errorResponse(alloc, id_json, -32602, "params must be object");
        const name_v = params.object.get("name") orelse return try errorResponse(alloc, id_json, -32602, "Missing prompt name");
        const name = switch (name_v) {
            .string => |s| s,
            else => return try errorResponse(alloc, id_json, -32602, "prompt name must be string"),
        };
        if (std.mem.eql(u8, name, "app_overview")) {
            const text = try std.fmt.allocPrint(
                alloc,
                "这是 Zilt 应用 \"{s}\"（headless 模式）。请先调用 tools/list 查看可用命令，再概括它能做什么、哪些操作有副作用。",
                .{opts.app_id},
            );
            defer alloc.free(text);
            return try promptResult(alloc, id_json, "应用能力概览", text);
        }
        if (std.mem.eql(u8, name, "call_command")) {
            var command: []const u8 = "<command>";
            if (params.object.get("arguments")) |args_v| {
                if (args_v == .object) {
                    if (args_v.object.get("command")) |cv| {
                        if (cv == .string) command = cv.string;
                    }
                }
            }
            const text = try std.fmt.allocPrint(
                alloc,
                "请调用工具 \"{s}\"：参数按 tools/list 的 inputSchema 构造。执行前先确认该命令是否有副作用。",
                .{command},
            );
            defer alloc.free(text);
            return try promptResult(alloc, id_json, "调用应用命令", text);
        }
        return try errorResponse(alloc, id_json, -32602, "Unknown prompt");
    }
    // notifications/* 已在无 id 分支处理；带 id 的未知方法按协议报错
    return try errorResponse(alloc, id_json, -32601, "Method not found");
}

const Resource = struct { text: []u8, mime: []const u8 };

/// 读取一个资源。返回的 text 由调用方 free。
fn readResource(alloc: std.mem.Allocator, uri: []const u8, opts: Options, comptime Commands: type) !Resource {
    if (std.mem.eql(u8, uri, "zilt://app/info")) {
        const text = try std.fmt.allocPrint(
            alloc,
            "{{\"app_id\":\"{s}\",\"version\":\"{s}\",\"platform\":\"{s}\",\"mode\":\"headless\"}}",
            .{ opts.app_id, version, @tagName(builtin.os.tag) },
        );
        return .{ .text = text, .mime = "application/json" };
    }
    if (std.mem.eql(u8, uri, "zilt://app/tools")) {
        const text = try toolsJsonFiltered(alloc, Commands, opts.tools_allowlist);
        return .{ .text = text, .mime = "application/json" };
    }
    if (std.mem.eql(u8, uri, "zilt://app/log")) {
        const text = readLogTail(alloc) catch try alloc.dupe(u8, "(zilt.log unavailable)");
        return .{ .text = text, .mime = "text/plain" };
    }
    return error.UnknownResource;
}

/// 读取 zilt.log 尾部（最多 64KB）。headless 的 cwd 是启动目录。
fn readLogTail(alloc: std.mem.Allocator) ![]u8 {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();
    const f = try dir.openFile(io, "zilt.log", .{});
    defer f.close(io);
    const len = f.length(io) catch 0;
    const take: usize = @intCast(@min(len, 64 * 1024));
    if (take == 0) return alloc.dupe(u8, "");
    const buf = try alloc.alloc(u8, take);
    const n = f.readPositionalAll(io, buf, len - take) catch 0;
    if (n == take) return buf;
    return try alloc.realloc(buf, n);
}

fn promptResult(alloc: std.mem.Allocator, id_json: []const u8, description: []const u8, text: []const u8) ![]u8 {
    const desc_json = try std.json.Stringify.valueAlloc(alloc, description, .{});
    defer alloc.free(desc_json);
    const text_json = try std.json.Stringify.valueAlloc(alloc, text, .{});
    defer alloc.free(text_json);
    return std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"description\":{s},\"messages\":[{{\"role\":\"user\",\"content\":{{\"type\":\"text\",\"text\":{s}}}}}]}}}}",
        .{ id_json, desc_json, text_json },
    );
}

fn toolResult(alloc: std.mem.Allocator, id_json: []const u8, ok: bool, text: []const u8) ![]u8 {
    const text_json = try std.json.Stringify.valueAlloc(alloc, text, .{});
    defer alloc.free(text_json);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":{s}}}}}",
        .{ id_json, text_json, if (ok) "false" else "true" },
    );
}

fn errorResponse(alloc: std.mem.Allocator, id_json: ?[]const u8, code: i32, message: []const u8) ![]u8 {
    const msg_json = try std.json.Stringify.valueAlloc(alloc, message, .{});
    defer alloc.free(msg_json);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}",
        .{ id_json orelse "null", code, msg_json },
    );
}

const testing = std.testing;

test "v0.1.19: tools json contains command names and schemas" {
    const Demo = struct {
        pub fn greet(_: ipc.Context, args: struct { name: []const u8, times: u32 = 1 }) ![]const u8 {
            _ = args;
            return "ok";
        }
        pub fn noArgs(_: ipc.Context, _: struct {}) !void {}
    };
    const json = toolsJson(Demo);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"greet\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":{\"type\":\"string\"}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"name\"]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"times\":{\"type\":\"integer\"}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"noArgs\"") != null);
}

test "v0.3.1: tools allowlist filters tools/list" {
    const Demo = struct {
        pub fn greet(_: ipc.Context, _: struct {}) !void {}
        pub fn add(_: ipc.Context, _: struct {}) !void {}
    };
    const filtered = try toolsJsonFiltered(testing.allocator, Demo, &.{"add"});
    defer testing.allocator.free(filtered);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"name\":\"add\"") != null);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"name\":\"greet\"") == null);
}

test "v0.3.1: resources/prompts/notification 语义" {
    const Demo = struct {
        pub fn greet(_: ipc.Context, _: struct {}) ![]const u8 {
            return "\"hi\"";
        }
    };
    var dummy: u8 = 0;
    const ctx = ipc.Context{
        .allocator = testing.allocator,
        .msg_allocator = testing.allocator,
        .backend = @ptrCast(&dummy),
        .emit_fn = noEmit,
        .quit_fn = noQuit,
    };
    const opts = Options{ .app_id = "app.test" };

    // 通知（无 id）→ 不回应
    try testing.expect((try handle(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", ctx, Demo, opts)) == null);

    // resources/list
    const res = (try handle(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/list\"}", ctx, Demo, opts)).?;
    defer testing.allocator.free(res);
    try testing.expect(std.mem.indexOf(u8, res, "zilt://app/info") != null);
    try testing.expect(std.mem.indexOf(u8, res, "zilt://app/log") != null);

    // resources/read info
    const info = (try handle(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{\"uri\":\"zilt://app/info\"}}", ctx, Demo, opts)).?;
    defer testing.allocator.free(info);
    try testing.expect(std.mem.indexOf(u8, info, "app.test") != null);

    // prompts/list + prompts/get
    const plist = (try handle(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"prompts/list\"}", ctx, Demo, opts)).?;
    defer testing.allocator.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "app_overview") != null);
    const pget = (try handle(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"prompts/get\",\"params\":{\"name\":\"call_command\",\"arguments\":{\"command\":\"greet\"}}}", ctx, Demo, opts)).?;
    defer testing.allocator.free(pget);
    try testing.expect(std.mem.indexOf(u8, pget, "greet") != null);

    // 白名单拒绝
    const blocked_opts = Options{ .tools_allowlist = &.{"add"} };
    const blocked = (try handle(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"greet\"}}", ctx, Demo, blocked_opts)).?;
    defer testing.allocator.free(blocked);
    try testing.expect(std.mem.indexOf(u8, blocked, "ToolNotAllowed") != null);
}

fn noEmit(_: *anyopaque, _: u32, _: []const u8) void {}
fn noQuit(_: *anyopaque, _: u8) void {}
