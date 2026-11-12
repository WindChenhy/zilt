//! MCP（Model Context Protocol）服务端最小实现（v0.1.19）。
//!
//! 仅用于 headless 模式：把应用的 Zig 命令暴露成 MCP tools，让 AI 客户端
//! （Claude Desktop / IDE 等）直接调用。传输是 HTTP JSON-RPC 2.0（POST /mcp），
//! 对齐 Wails v3 内置 MCP 的定位，但只做 tools（无 resources/prompts）。
//!
//! 安全提示：MCP 端点等于把 commands 全量开放给本机调用方，只应在
//! ZILT_HEADLESS=1 且仅绑 127.0.0.1 的场景使用。
const std = @import("std");
const ipc = @import("ipc.zig");

pub const PROTOCOL_VERSION = "2024-11-05";
pub const version = @import("version.zig").version;

/// comptime 生成 tools/list 的 JSON（避免运行期反射）。
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

/// 处理一次 JSON-RPC 请求，返回响应 JSON（allocator 分配）。
/// `ctx` 由 headless 构造（builtin 分发也走同一条链路）。
pub fn handle(alloc: std.mem.Allocator, body: []const u8, ctx: ipc.Context, comptime Commands: type) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return errorResponse(alloc, null, -32700, "Parse error");
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return errorResponse(alloc, null, -32600, "Invalid Request");

    const id_json: []const u8 = blk: {
        if (root.object.get("id")) |idv| {
            break :blk try std.json.Stringify.valueAlloc(alloc, idv, .{});
        }
        break :blk try alloc.dupe(u8, "null");
    };
    defer alloc.free(id_json);

    const method_v = root.object.get("method") orelse return errorResponse(alloc, id_json, -32600, "Missing method");
    const method = switch (method_v) {
        .string => |s| s,
        else => return errorResponse(alloc, id_json, -32600, "Method must be string"),
    };

    if (std.mem.eql(u8, method, "initialize")) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"zilt\",\"version\":\"{s}\"}}}}}}",
            .{ id_json, PROTOCOL_VERSION, version },
        );
    }
    if (std.mem.eql(u8, method, "ping")) {
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{id_json});
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tools\":{s}}}}}", .{ id_json, toolsJson(Commands) });
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const params = root.object.get("params") orelse return errorResponse(alloc, id_json, -32602, "Missing params");
        if (params != .object) return errorResponse(alloc, id_json, -32602, "params must be object");
        const name_v = params.object.get("name") orelse return errorResponse(alloc, id_json, -32602, "Missing tool name");
        const tool_name = switch (name_v) {
            .string => |s| s,
            else => return errorResponse(alloc, id_json, -32602, "tool name must be string"),
        };
        const args_json: []const u8 = blk: {
            if (params.object.get("arguments")) |a| {
                break :blk try std.json.Stringify.valueAlloc(alloc, a, .{});
            }
            break :blk try alloc.dupe(u8, "{}");
        };
        defer alloc.free(args_json);

        const result = ipc.dispatch(Commands, ctx, tool_name, args_json) catch |err| {
            return toolResult(alloc, id_json, false, @errorName(err));
        };
        defer alloc.free(result);
        return toolResult(alloc, id_json, true, result);
    }
    return errorResponse(alloc, id_json, -32601, "Method not found");
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
