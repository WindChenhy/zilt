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
        @setEvalBranchQuota(100000);
        var out: []const u8 = "";
        out = out ++
            \\// 由 Zilt 自动生成（Zig comptime 反射）—— DO NOT EDIT.
            \\// 重新生成：zig build gen
            \\
            \\export type ZiltErrorCode = string;
            \\
            \\export class ZiltCommandError<Code extends ZiltErrorCode = ZiltErrorCode> extends Error {
            \\  readonly command: string;
            \\  readonly code: Code;
            \\  constructor(command: string, code: Code) {
            \\    super(`${command}: ${code}`);
            \\    this.name = "ZiltCommandError";
            \\    this.command = command;
            \\    this.code = code;
            \\  }
            \\}
            \\
            \\function __ziltErrorCode(e: unknown): ZiltErrorCode {
            \\  if (e instanceof Error) return e.message || "UnknownError";
            \\  if (typeof e === "string") return e;
            \\  return "UnknownError";
            \\}
            \\
            \\export interface ZiltGlobal {
            \\  invoke<K extends keyof ZiltCommandMap>(method: K, args?: ZiltCommandMap[K]["args"]): Promise<ZiltCommandMap[K]["result"]>;
            \\  invoke(method: string, args?: unknown): Promise<unknown>;
            \\  emit<K extends keyof ZiltEventPayloads>(name: K, payload: ZiltEventPayloads[K]): void;
            \\  emit(name: string, payload?: unknown): void;
            \\  on<K extends keyof ZiltEventPayloads>(name: K, cb: (payload: ZiltEventPayloads[K]) => void): void;
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

        // ---- 错误类型联合 + 命令映射（v0.6.0 d 打磨）----
        // 命令错误集可由 Zig error set 反射（anyerror → string）；映射表同时是
        // 0.7 插件绑定的扩展点（declare module 合并）。
        const cmds = sortedCommandMetas(Commands);
        out = out ++ "export type ZiltCommandErrors = {\n";
        for (cmds) |m| {
            out = out ++ "  \"" ++ m.name ++ "\": " ++ errorTs(m.error_type) ++ ",\n";
        }
        out = out ++ "};\n\n";

        out = out ++ "export interface ZiltCommandMap {\n";
        for (cmds) |m| {
            const args_t = if (m.args) |A| tsType(A) else "void";
            const ret_t = if (m.result == void) "void" else tsType(m.result);
            out = out ++ "  \"" ++ m.name ++ "\": { args: " ++ args_t ++ "; result: " ++ ret_t ++
                "; error: ZiltCommandErrors[\"" ++ m.name ++ "\"] };\n";
        }
        out = out ++ "}\n\n";

        // ---- 命令函数 ----
        // v0.3.8 C3：参数名保留——args 结构体的字段升级为 TS 形参
        // （`greet(name: string)` 而非 `greet(args: { name: string })`），
        // 调用侧 `invoke("greet", { name })`。无参数命令直接 `ping()`。
        // 不满足命名形态（非 struct / 可选字段出现在必填字段之前 / TS 属性名
        // 非法标识符）的命令保留 v0.1.3 的 args 对象形态。
        // v0.6.0：统一 try/catch，把 Zig 错误名包成 ZiltCommandError。
        for (cmds) |m| {
            const ret_t = if (m.result == void) "void" else tsType(m.result);
            const params = if (m.args) |A| blk: {
                if (paramSig(A)) |ps| break :blk ps.params;
                break :blk "args: " ++ tsType(A);
            } else "";
            const call = if (m.args) |A| blk: {
                if (paramSig(A)) |ps| {
                    break :blk if (ps.call_args.len == 0) "{}" else "{ " ++ ps.call_args ++ " }";
                }
                break :blk "args ?? {}";
            } else "{}";

            out = out ++ "export async function " ++ m.name ++ "(" ++ params ++ "): Promise<" ++ ret_t ++ "> {\n";
            out = out ++ "  try {\n";
            if (m.result == void) {
                out = out ++ "    await window.zilt.invoke(\"" ++ m.name ++ "\", " ++ call ++ ");\n";
            } else {
                out = out ++ "    return await window.zilt.invoke(\"" ++ m.name ++ "\", " ++ call ++ ") as Promise<" ++ ret_t ++ ">;\n";
            }
            out = out ++ "  } catch (e) {\n";
            out = out ++ "    throw new ZiltCommandError<ZiltCommandErrors[\"" ++ m.name ++ "\"]>(\"" ++ m.name ++
                "\", __ziltErrorCode(e) as ZiltCommandErrors[\"" ++ m.name ++ "\"]);\n";
            out = out ++ "  }\n}\n\n";
        }

        // ---- 事件类型表（扩展点：declare module 合并 ZiltEventMap）----
        out = out ++ "export interface ZiltEventMap {\n";
        for (sortedEventMetas(Events)) |e| {
            const p_t = if (e.payload) |P| tsType(P) else "null";
            out = out ++ "  \"" ++ e.name ++ "\": " ++ p_t ++ ",\n";
        }
        out = out ++ "}\n\n";
        out = out ++ "export interface ZiltBuiltinEventMap {\n";
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
        out = out ++ "}\n\n";
        out = out ++ "export type ZiltEventPayloads = ZiltEventMap & Omit<ZiltBuiltinEventMap, keyof ZiltEventMap>;\n\n";
        out = out ++
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
    @setEvalBranchQuota(10000);
    const decl_names = @typeInfo(Events).@"struct".decl_names;
    // 先数 fn 型 decl（events.zig 里允许 pub var 计数器等非命令 decl——实测
    // `pub var builtin_hits` 混进 decl_names 会把 @typeInfo 打到 struct 分支）
    comptime var n: usize = 0;
    inline for (decl_names) |name| {
        if (@typeInfo(@TypeOf(@field(Events, name))) == .@"fn") n += 1;
    }
    var metas: [n]EventMeta = undefined;
    comptime var i: usize = 0;
    inline for (decl_names) |name| {
        const Fn = @TypeOf(@field(Events, name));
        if (@typeInfo(Fn) == .@"fn") {
            const info = @typeInfo(Fn).@"fn";
            const has_payload = info.param_types.len == 2;
            metas[i] = .{
                .name = name,
                .payload = if (has_payload) info.param_types[1].? else null,
            };
            i += 1;
        }
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

/// v0.6.0：命令按名字排序——生成物与 decl 顺序解耦，输出确定。
fn sortedCommandMetas(comptime Commands: type) []const ipc.Meta {
    comptime {
        const raw = ipc.commandMetas(Commands);
        var out: [raw.len]ipc.Meta = undefined;
        for (raw, 0..) |m, i| out[i] = m;
        var i: usize = 1;
        while (i < out.len) : (i += 1) {
            const key = out[i];
            var j = i;
            while (j > 0 and std.mem.lessThan(u8, key.name, out[j - 1].name)) : (j -= 1) {
                out[j] = out[j - 1];
            }
            out[j] = key;
        }
        const frozen = out;
        return &frozen;
    }
}

/// v0.6.0：事件按名字排序（同一理由）。
fn sortedEventMetas(comptime Events: type) []const EventMeta {
    comptime {
        const raw = eventMetas(Events);
        var out: [raw.len]EventMeta = undefined;
        for (raw, 0..) |m, i| out[i] = m;
        var i: usize = 1;
        while (i < out.len) : (i += 1) {
            const key = out[i];
            var j = i;
            while (j > 0 and std.mem.lessThan(u8, key.name, out[j - 1].name)) : (j -= 1) {
                out[j] = out[j - 1];
            }
            out[j] = key;
        }
        const frozen = out;
        return &frozen;
    }
}

/// 命令错误集 → TS 联合：显式 error set 逐项；anyerror → string；无错误 → never。
fn errorTs(comptime error_type: ?type) []const u8 {
    comptime {
        const E = error_type orelse return "never";
        const einfo = @typeInfo(E).error_set;
        const names = einfo.error_names orelse return "string";
        if (names.len == 0) return "never";
        var sorted: [names.len][]const u8 = undefined;
        for (names, 0..) |n, i| sorted[i] = n;
        var si: usize = 1;
        while (si < sorted.len) : (si += 1) {
            const key = sorted[si];
            var sj = si;
            while (sj > 0 and std.mem.lessThan(u8, key, sorted[sj - 1])) : (sj -= 1) {
                sorted[sj] = sorted[sj - 1];
            }
            sorted[sj] = key;
        }
        var out: []const u8 = "";
        for (sorted, 0..) |n, i| {
            if (i > 0) out = out ++ " | ";
            out = out ++ "\"" ++ n ++ "\"";
        }
        return out;
    }
}

// ---------------------------------------------------------------------------
// 命名参数形态（v0.3.8 C3）
// ---------------------------------------------------------------------------

const ParamSig = struct {
    /// TS 形参串：`name: string, tag?: string`
    params: []const u8,
    /// 调用侧对象字面量：`name, tag`（`invoke(m, { name, tag })`）
    call_args: []const u8,
};

/// args 结构体可升级为命名形参的条件：
/// 1. 是普通 struct（tuple / 非结构类型走对象形态）
/// 2. TS 属性名（经 jsonName 映射）都是合法 JS 标识符——形参名与对象键共用
/// 3. 可选/默认值字段不出现在必填字段之前（TS「必填参数不能跟在可选参数后」约束）
fn paramSig(comptime args_t: ?type) ?ParamSig {
    comptime {
        @setEvalBranchQuota(100000);
        const T = args_t orelse return null;
        const ti = @typeInfo(T);
        if (ti != .@"struct") return null;
        const st = ti.@"struct";
        if (st.is_tuple) return null;
        const has_json_name = @hasDecl(T, "jsonName");
        var params: []const u8 = "";
        var call_args: []const u8 = "";
        var seen_optional = false;
        for (st.field_names, st.field_types, st.field_attrs, 0..) |fname, ftype, fattr, i| {
            const is_optional = @typeInfo(ftype) == .optional;
            const has_default = fattr.defaultValue(ftype) != null;
            const ts_name = if (has_json_name) T.jsonName(fname) else fname;
            if (!isValidJsIdent(ts_name)) return null;
            if (seen_optional and !is_optional and !has_default) return null;
            if (is_optional or has_default) seen_optional = true;
            const base = if (is_optional) @typeInfo(ftype).optional.child else ftype;
            if (i > 0) {
                params = params ++ ", ";
                call_args = call_args ++ ", ";
            }
            params = params ++ ts_name ++ (if (is_optional or has_default) "?:" else ":") ++ " " ++ tsType(base);
            call_args = call_args ++ ts_name;
        }
        return .{ .params = params, .call_args = call_args };
    }
}

fn isValidJsIdent(comptime s: []const u8) bool {
    comptime {
        if (s.len == 0) return false;
        for (s, 0..) |c, i| {
            const head = std.ascii.isAlphabetic(c) or c == '_' or c == '$';
            if (i == 0) {
                if (!head) return false;
            } else if (!head and !std.ascii.isDigit(c)) return false;
        }
        const reserved = [_][]const u8{ "class", "const", "default", "export", "function", "import", "let", "new", "return", "var" };
        for (reserved) |r| {
            if (std.mem.eql(u8, s, r)) return false;
        }
        return true;
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
            // v0.1.21：类型声明了 `pub fn jsonName(field) []const u8` 时，
            // TS 属性名采用该映射（应用侧 JSON 契约与 Zig 字段名解耦，
            // 对齐 Tauri 的 serde rename）
            const has_json_name = @hasDecl(T, "jsonName");
            inline for (st.field_names, st.field_types, st.field_attrs, 0..) |fname, ftype, fattr, i| {
                if (i > 0) out = out ++ "; ";
                // 有默认值或可选类型的字段 → TS 可选属性
                const is_optional = @typeInfo(ftype) == .optional;
                const has_default = fattr.defaultValue(ftype) != null;
                const ts_name = if (has_json_name) T.jsonName(fname) else fname;
                if (is_optional or has_default) {
                    const base = if (is_optional) @typeInfo(ftype).optional.child else ftype;
                    out = out ++ ts_name ++ "?: " ++ tsType(base);
                } else {
                    out = out ++ ts_name ++ ": " ++ tsType(ftype);
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
    // v0.2.8：非 fn 的 pub decl（计数器等）必须被 eventMetas 跳过——
    // 实测 events.zig 的 `pub var builtin_hits` 曾把 @typeInfo 打到 struct 分支
    pub var hits: u32 = 0;

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

test "v0.1.21: jsonName 映射 TS 属性名" {
    // 应用侧若声明 `pub fn jsonName(field) []const u8`，TS 属性名走该映射
    // （对齐 Tauri 的 serde rename：Zig 字段 snake_case，JSON/TS 用 camelCase）。
    const Renamed = struct {
        user_name: []const u8,
        retry_count: u32 = 3,
        pub fn jsonName(comptime field: []const u8) []const u8 {
            comptime {
                if (std.mem.eql(u8, field, "user_name")) return "userName";
                if (std.mem.eql(u8, field, "retry_count")) return "retryCount";
                return field;
            }
        }
    };
    try testing.expectEqualStrings("{ userName: string; retryCount?: number }", comptime tsType(Renamed));
    // 没有 jsonName 的类型保持原字段名
    try testing.expectEqualStrings("{ user_name: string }", comptime tsType(struct { user_name: []const u8 }));
}

test "v0.3.8 C3: generateTs 命名参数形态 + 事件表" {
    const ts = comptime generateTs(SampleCommands, SampleEvents);

    // 单必填参数 → 命名形参（v0.3.8 C3：参数名保留）
    try testing.expect(std.mem.indexOf(u8, ts, "export async function greet(name: string): Promise<{ message: string; length: number }> {") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "window.zilt.invoke(\"greet\", { name }) as Promise<{ message: string; length: number }>;") != null);
    // 无参数命令 → 零形参
    try testing.expect(std.mem.indexOf(u8, ts, "export async function ping(): Promise<void> {") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "window.zilt.invoke(\"ping\", {});") != null);
    // 可选字段在必填字段之前 → 保留 args 对象形态（TS 形参顺序约束）
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

test "v0.3.8 C3: 命名形态边界（可选全在尾部 / jsonName 映射 / 空参数结构）" {
    // 可选字段全在必填之后 → 命名形态带 `?:`
    const Trailing = struct {
        pub fn upload(_: ipc.Context, args: struct { url: []const u8, note: ?[]const u8 = null }) !void {
            _ = args;
        }
    };
    const ts1 = comptime generateTs(Trailing, struct {});
    try testing.expect(std.mem.indexOf(u8, ts1, "upload(url: string, note?: string): Promise<void>") != null);
    try testing.expect(std.mem.indexOf(u8, ts1, "invoke(\"upload\", { url, note });") != null);

    // jsonName 映射（声明在 args 结构体上，v0.1.21 契约）→ 形参名与对象键都用映射名
    const Renamed = struct {
        pub fn find(_: ipc.Context, args: struct {
            user_name: []const u8,

            pub fn jsonName(comptime field: []const u8) []const u8 {
                comptime {
                    if (std.mem.eql(u8, field, "user_name")) return "userName";
                    return field;
                }
            }
        }) !void {
            _ = args;
        }
    };
    const ts2 = comptime generateTs(Renamed, struct {});
    try testing.expect(std.mem.indexOf(u8, ts2, "find(userName: string): Promise<void>") != null);
    try testing.expect(std.mem.indexOf(u8, ts2, "invoke(\"find\", { userName });") != null);

    // 空 args 结构体 → 零形参 + `invoke(m, {})`
    const Empty = struct {
        pub fn pingEmpty(_: ipc.Context, args: struct {}) !u32 {
            _ = args;
            return 0;
        }
    };
    const ts3 = comptime generateTs(Empty, struct {});
    try testing.expect(std.mem.indexOf(u8, ts3, "pingEmpty(): Promise<number>") != null);
    try testing.expect(std.mem.indexOf(u8, ts3, "invoke(\"pingEmpty\", {}) as Promise<number>;") != null);
}

test "v0.3.8 C3: 非法标识符/必填跟在可选后 → 回退对象形态" {
    const Bad = struct {
        pub fn f(_: ipc.Context, args: struct { @"class": []const u8 }) !void {
            _ = args;
        }
    };
    const ts1 = comptime generateTs(Bad, struct {});
    try testing.expect(std.mem.indexOf(u8, ts1, "f(args: { class: string })") != null);

    const Order = struct {
        pub fn g(_: ipc.Context, args: struct { a: ?[]const u8 = null, b: u32 }) !void {
            _ = args;
        }
    };
    const ts2 = comptime generateTs(Order, struct {});
    try testing.expect(std.mem.indexOf(u8, ts2, "g(args: { a?: string; b: number })") != null);
}

test "v0.6.0 codegen: 错误联合 / 命令映射 / 事件扩展点 / 输出排序" {
    const Cmds = struct {
        pub fn zeta(_: ipc.Context) void {}
        pub fn alpha(_: ipc.Context) void {}
        pub fn fail(_: ipc.Context) error{ Denied, Timeout }!void {
            return error.Denied;
        }
    };
    const Events = struct {
        pub fn zz(_: ipc.Context, payload: struct { z: u8 }) void {
            _ = payload;
        }
        pub fn aa(_: ipc.Context, payload: struct { a: u8 }) void {
            _ = payload;
        }
    };
    const ts = comptime generateTs(Cmds, Events);

    // 显式 error set → 联合
    try testing.expect(std.mem.indexOf(u8, ts, "\"fail\": \"Denied\" | \"Timeout\"") != null);
    // 无 error union → never
    try testing.expect(std.mem.indexOf(u8, ts, "\"alpha\": never") != null);
    // 命令映射（0.7 插件扩展点）与错误包装
    try testing.expect(std.mem.indexOf(u8, ts, "export interface ZiltCommandMap {") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "throw new ZiltCommandError<ZiltCommandErrors[\"fail\"]>") != null);
    // 事件扩展点
    try testing.expect(std.mem.indexOf(u8, ts, "export interface ZiltEventMap {") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "export type ZiltEventPayloads = ZiltEventMap & Omit<ZiltBuiltinEventMap, keyof ZiltEventMap>;") != null);
    // 输出按名字排序（decl 顺序 zeta/alpha 反转）
    const ai = std.mem.indexOf(u8, ts, "export async function alpha").?;
    const zi = std.mem.indexOf(u8, ts, "export async function zeta").?;
    try testing.expect(ai < zi);
    const aa = std.mem.indexOf(u8, ts, "\"aa\": { a: number }").?;
    const zz = std.mem.indexOf(u8, ts, "\"zz\": { z: number }").?;
    try testing.expect(aa < zz);
}
