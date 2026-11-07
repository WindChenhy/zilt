//! 绑定 codegen：Zig comptime 反射 → TypeScript 绑定。
//!
//! 这是 Zig 做 codegen 的结构性优势（对比 Rust 需要 proc-macro/specta、Go 需要 AST 解析）：
//! 直接 `@typeInfo` 遍历命令命名空间即可，无宏、无外部解析器。
//!
//! 生成内容：
//!  - 每个命令一个强类型函数 `export async function greet(args: {...}): Promise<{...}>`
//!  - 事件名/类型映射表 `ZiltEvents`
//!  - `window.zilt` 全局声明
//!
//! 运行方式：`zig build gen` → 写出 src/frontend/zilt-bindings.ts（由 src/tools/gen_bindings.zig 调用）。

const std = @import("std");
const ipc = @import("ipc.zig");

/// 生成 TS 绑定源码（comptime 字符串）。
pub fn generateTs(comptime Commands: type, comptime Events: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        out = out ++
            \\// 由 Zilt 自动生成（Zig comptime 反射）—— DO NOT EDIT.
            \\// 重新生成：zig build gen
            \\
            \\export interface ZiltGlobal {
            \\  invoke(method: string, args?: unknown): Promise<unknown>;
            \\  emit(name: string, payload?: unknown): void;
            \\  on(name: string, cb: (payload: any) => void): void;
            \\  version: string;
            \\}
            \\
            \\declare global {
            \\  interface Window { zilt: ZiltGlobal }
            \\}
            \\
            \\
        ;

        // ---- 命令函数 ----
        for (ipc.commandMetas(Commands)) |m| {
            const args_t = if (m.args) |A| tsType(A) else "void";
            const ret_t = if (m.result == void) "void" else tsType(m.result);
            out = out ++ "export async function " ++ m.name ++ "(args: " ++ args_t ++ "): Promise<" ++ ret_t ++ "> {\n";
            if (m.result == void) {
                out = out ++ "  await window.zilt.invoke(\"" ++ m.name ++ "\", args ?? {});\n}\n\n";
            } else {
                out = out ++ "  return window.zilt.invoke(\"" ++ m.name ++ "\", args ?? {}) as Promise<" ++ ret_t ++ ">;\n}\n\n";
            }
        }

        // ---- 事件类型表 ----
        out = out ++ "export type ZiltEventPayloads = {\n";
        for (eventMetas(Events)) |e| {
            const p_t = if (e.payload) |P| tsType(P) else "null";
            out = out ++ "  \"" ++ e.name ++ "\": " ++ p_t ++ ",\n";
        }
        // 框架内置事件（v0.1.6）：与用户事件同名时以用户定义为准
        const builtins = [_]struct { name: []const u8, ts: []const u8 }{
            .{ .name = "menu", .ts = "{ id: string }" },
            .{ .name = "hotkey", .ts = "{ id: string }" },
            .{ .name = "trayMenu", .ts = "{ id: string }" },
            .{ .name = "dropFiles", .ts = "{ files: string[] }" },
            .{ .name = "deepLink", .ts = "{ url?: string; files: string[] }" },
            .{ .name = "windowMoved", .ts = "{ id: number; x: number; y: number }" },
            .{ .name = "windowResized", .ts = "{ id: number; width: number; height: number }" },
            .{ .name = "windowFocus", .ts = "{ id: number }" },
            .{ .name = "windowBlur", .ts = "{ id: number }" },
            .{ .name = "windowThemeChanged", .ts = "{ id: number; theme: string }" },
            .{ .name = "windowScaleFactorChanged", .ts = "{ id: number; scale_factor: number; dpi: number }" },
            .{ .name = "windowCloseRequested", .ts = "{ id: number }" },
            .{ .name = "windowDestroyed", .ts = "{ id: number }" },
        };
        for (builtins) |b| {
            if (hasEvent(Events, b.name)) continue;
            out = out ++ "  \"" ++ b.name ++ "\": " ++ b.ts ++ ",\n";
        }
        out = out ++ "  \"__reload\": null,\n";
        out = out ++
            \\};
            \\
            \\export function onEvent<K extends keyof ZiltEventPayloads>(
            \\  name: K,
            \\  cb: (payload: ZiltEventPayloads[K]) => void,
            \\): void {
            \\  window.zilt.on(name, cb as (payload: any) => void);
            \\}
            \\
        ;
        return out;
    }
}

const EventMeta = struct {
    name: []const u8,
    payload: ?type,
};

fn eventMetas(comptime Events: type) []const EventMeta {
    const decl_names = @typeInfo(Events).@"struct".decl_names;
    var metas: [decl_names.len]EventMeta = undefined;
    for (decl_names, 0..) |name, i| {
        const info = @typeInfo(@TypeOf(@field(Events, name))).@"fn";
        const has_payload = info.param_types.len == 2;
        metas[i] = .{
            .name = name,
            .payload = if (has_payload) info.param_types[1].? else null,
        };
    }
    const frozen = metas;
    return &frozen;
}

fn hasEvent(comptime Events: type, comptime name: []const u8) bool {
    comptime {
        for (@typeInfo(Events).@"struct".decl_names) |decl| {
            if (std.mem.eql(u8, decl, name)) return true;
        }
        return false;
    }
}

// ---------------------------------------------------------------------------
// 类型映射
// ---------------------------------------------------------------------------

pub fn tsType(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "boolean",
        .int, .comptime_int => "number",
        .float, .comptime_float => "number",
        .void => "void",
        .null => "null",
        .optional => |o| tsType(o.child) ++ " | null",
        .error_union => |eu| tsType(eu.payload),
        .array => |a| tsType(a.child) ++ "[]",
        .pointer => |p| blk: {
            // []const u8 → string；其他切片 → T[]；单元素指针解引用
            if (p.size == .slice and p.child == u8) break :blk "string";
            if (p.size == .slice) break :blk tsType(p.child) ++ "[]";
            if (p.size == .one) break :blk tsType(p.child);
            break :blk "unknown";
        },
        .@"struct" => |st| blk: {
            comptime var out: []const u8 = "{ ";
            inline for (st.field_names, st.field_types, st.field_attrs, 0..) |fname, ftype, fattr, i| {
                if (i > 0) out = out ++ "; ";
                // 有默认值或可选类型的字段 → TS 可选属性
                const is_optional = @typeInfo(ftype) == .optional;
                const has_default = fattr.defaultValue(ftype) != null;
                if (is_optional or has_default) {
                    const base = if (is_optional) @typeInfo(ftype).optional.child else ftype;
                    out = out ++ fname ++ "?: " ++ tsType(base);
                } else {
                    out = out ++ fname ++ ": " ++ tsType(ftype);
                }
            }
            out = out ++ (if (st.field_names.len == 0) "" else " ") ++ "}";
            break :blk out;
        },
        .@"enum" => |e| blk: {
            comptime var out: []const u8 = "";
            inline for (e.field_names, 0..) |name, i| {
                if (i > 0) out = out ++ " | ";
                out = out ++ "\"" ++ name ++ "\"";
            }
            break :blk out;
        },
        .@"union" => "unknown", // tagged union 序列化需自定义，Phase 2 后扩展
        else => "unknown",
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

const SampleCommands = struct {
    pub fn greet(_: ipc.Context, args: struct { name: []const u8 }) !struct { message: []const u8, length: usize } {
        _ = args;
        return .{ .message = "", .length = 0 };
    }
    pub fn ping(_: ipc.Context) !void {}
    pub fn query(_: ipc.Context, args: struct { id: i32, tag: ?[]const u8 = null, flags: []const bool }) !f64 {
        _ = args;
        return 0;
    }
};

const SampleEvents = struct {
    pub fn tick(_: ipc.Context, payload: struct { n: u32 }) void {
        _ = payload;
    }
    pub fn log(_: ipc.Context, payload: struct { msg: []const u8, level: ?u8 = null }) void {
        _ = payload;
    }
};

test "tsType mappings" {
    try testing.expectEqualStrings("boolean", comptime tsType(bool));
    try testing.expectEqualStrings("number", comptime tsType(i32));
    try testing.expectEqualStrings("number", comptime tsType(f64));
    try testing.expectEqualStrings("string", comptime tsType([]const u8));
    try testing.expectEqualStrings("number[]", comptime tsType([]const u32));
    try testing.expectEqualStrings("string | null", comptime tsType(?[]const u8));
    try testing.expectEqualStrings("{ a: number; b?: string }", comptime tsType(struct { a: f64, b: ?[]const u8 = null }));
    try testing.expectEqualStrings("\"on\" | \"off\"", comptime tsType(enum { on, off }));
}

test "generateTs contains typed commands and events" {
    const ts = comptime generateTs(SampleCommands, SampleEvents);

    // 命令签名
    try testing.expect(std.mem.indexOf(u8, ts, "export async function greet(args: { name: string }): Promise<{ message: string; length: number }> {") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "window.zilt.invoke(\"greet\", args ?? {}) as Promise<{ message: string; length: number }>;") != null);
    // 无参数命令
    try testing.expect(std.mem.indexOf(u8, ts, "export async function ping(args: void): Promise<void> {") != null);
    // 默认值 → 可选属性
    try testing.expect(std.mem.indexOf(u8, ts, "export async function query(args: { id: number; tag?: string; flags: boolean[] })") != null);
    // 事件表
    try testing.expect(std.mem.indexOf(u8, ts, "\"tick\": { n: number },") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "\"log\": { msg: string; level?: number },") != null);
    // 内置事件（v0.1.6）
    try testing.expect(std.mem.indexOf(u8, ts, "\"menu\": { id: string },") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "\"dropFiles\": { files: string[] },") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "\"deepLink\": { url?: string; files: string[] },") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "\"__reload\": null,") != null);
}
