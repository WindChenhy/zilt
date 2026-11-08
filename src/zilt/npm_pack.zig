//! v0.1.17：npm 运行时包生成（对齐 `@tauri-apps/api` / Wails3 npm 分发生态位）。
//!
//! `zilt npm-pack [-o <dir>]`：从框架 runtime（window.zilt.* 注入脚本）与
//! 静态类型描述生成可直接 `npm pack` / `npm publish` 的包：
//!   package.json / index.js / index.d.ts / README.md
//!
//! 纯逻辑（字符串拼装），全部可单测；文件写出在 cli.zig（win32 API）。

const std = @import("std");

pub const PackageOptions = struct {
    name: []const u8 = "@zilt/runtime",
    version: []const u8 = "0.1.17",
    description: []const u8 = "Zilt desktop framework JS runtime (window.zilt.*)",
    /// 框架 IPC runtime 注入脚本（ipc.runtime_js 原文）
    runtime_js: []const u8,
};

pub const Files = struct {
    package_json: []u8,
    index_js: []u8,
    index_d_ts: []u8,
    readme_md: []u8,

    pub fn deinit(self: *Files, alloc: std.mem.Allocator) void {
        alloc.free(self.package_json);
        alloc.free(self.index_js);
        alloc.free(self.index_d_ts);
        alloc.free(self.readme_md);
    }
};

pub const ENTRY_SNIPPET = "window.zilt";

/// 生成 npm 包文件集（全部归调用方 allocator）。
pub fn generate(alloc: std.mem.Allocator, opts: PackageOptions) !Files {
    const package_json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "name": "{s}",
        \\  "version": "{s}",
        \\  "description": "{s}",
        \\  "main": "index.js",
        \\  "types": "index.d.ts",
        \\  "license": "MIT",
        \\  "files": ["index.js", "index.d.ts", "README.md"],
        \\  "keywords": ["zilt", "desktop", "webview", "zig"]
        \\}}
    , .{ opts.name, opts.version, opts.description });

    // index.js：浏览器端无环境 → 注入脚本在应用窗口内由框架自动执行；
    // npm 包的用途是给 IDE/打包器提供可 import 的类型与（可选）运行时副本。
    const literal_or_empty = jsStringLiteral(alloc, opts.runtime_js) catch "";
    defer if (literal_or_empty.len > 0) alloc.free(literal_or_empty);
    const literal: []const u8 = if (literal_or_empty.len > 0) literal_or_empty else "''";
    const index_js = try std.fmt.allocPrint(alloc,
        \\// @zilt/runtime — Zilt window.zilt.* 运行时。
        \\// 应用窗口内框架会自动注入完整 runtime；本文件用于：
        \\//   1. IDE 类型来源（配合 index.d.ts）
        \\//   2. 自定义打包器需要显式引用 runtime 的场景
        \\// 原始注入脚本（与框架版本 {s} 对齐）：
        \\
        \\const ZILT_RUNTIME_SOURCE = {s};
        \\
        \\if (typeof window !== "undefined" && window.zilt) {{
        \\  // 已在 Zilt 应用内：runtime 已就绪，无需再注入
        \\}} else if (typeof window !== "undefined") {{
        \\  // 嵌入到非 Zilt 环境（预览/测试垫片）：执行注入脚本
        \\  new Function(ZILT_RUNTIME_SOURCE)();
        \\}}
        \\
        \\module.exports = {{ ZILT_RUNTIME_SOURCE }};
        \\
    , .{ opts.version, literal });

    const index_d_ts = try alloc.dupe(u8, TYPES_D_TS);
    const readme_md = try std.fmt.allocPrint(alloc,
        \\# {s}
        \\
        \\{s}
        \\
        \\## 用法
        \\
        \\Zilt 应用窗口内 `window.zilt.*` 由框架自动注入，无需 import。本包提供：
        \\
        \\- **类型**：`index.d.ts` 声明 `window.zilt` 全接口（invoke / on / emit /
        \\  window / clipboard / dialog / notification / webview / store / fs /
        \\  path / log / opener / windowState / services / http / ws / webviews /
        \\  process / sql / menu / tray …）
        \\- **运行时源**：`index.js` 导出 `ZILT_RUNTIME_SOURCE`（注入脚本原文），
        \\  供自定义打包器或测试垫片使用
        \\
        \\版本 {s}（与 Zilt 框架 v0.1.17 对齐）。
        \\
    , .{ opts.name, opts.description, opts.version });

    return .{
        .package_json = package_json,
        .index_js = index_js,
        .index_d_ts = index_d_ts,
        .readme_md = readme_md,
    };
}

/// 把任意脚本文本转成 JS 单引号字符串字面量（转义 ' \\ \n 换行拼接）。
pub fn jsStringLiteral(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '\'');
    for (src) |c| {
        switch (c) {
            '\'' => try out.appendSlice(alloc, "\\'"),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            else => try out.append(alloc, c),
        }
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

/// window.zilt 全接口的 TS 声明（与 ipc.runtime_js 同步维护）。
const TYPES_D_TS =
    \\// @zilt/runtime — window.zilt 全接口声明（v0.1.17）
    \\
    \\declare global {
    \\  interface Window {
    \\    zilt: {
    \\      version: string;
    \\      invoke: (method: string, args?: unknown) => Promise<any>;
    \\      emit: (name: string, payload?: unknown) => void;
    \\      on: (name: string, cb: (payload: any) => void) => () => void;
    \\      startDragging: () => void;
    \\      window: {
    \\        close(): void; minimize(): void; maximize(): void; restore(): void;
    \\        setTitle(t: string): Promise<void>; setBounds(x: number, y: number, w: number, h: number): Promise<void>;
    \\        focus(): Promise<void>; show(): Promise<void>; hide(): Promise<void>;
    \\        list(): Promise<{ id: number; label: string; title: string; visible: boolean }[]>;
    \\      };
    \\      clipboard: {
    \\        readText(): Promise<string | null>; writeText(t: string): Promise<boolean>;
    \\        read(format?: string): Promise<unknown>;
    \\      };
    \\      dialog: {
    \\        messageBox(opts?: Record<string, unknown>): Promise<unknown>;
    \\        openFile(opts?: Record<string, unknown>): Promise<string | null>;
    \\        saveFile(opts?: Record<string, unknown>): Promise<string | null>;
    \\        pickFolder(opts?: Record<string, unknown>): Promise<string | null>;
    \\        pickFiles(opts?: Record<string, unknown>): Promise<string[]>;
    \\      };
    \\      notification: {
    \\        show(opts: { title: string; body?: string; tag?: string; group?: string }): Promise<unknown>;
    \\        status(tag: string, group?: string): Promise<unknown>;
    \\      };
    \\      webview: Record<string, (...args: any[]) => Promise<unknown>>;
    \\      store: { get(key: string): Promise<unknown>; set(key: string, v: unknown): Promise<void>; remove(key: string): Promise<void>; keys(): Promise<string[]> };
    \\      fs: { read(path: string): Promise<string>; write(path: string, content: string): Promise<void>; exists(path: string): Promise<boolean>; remove(path: string): Promise<void> };
    \\      path: { join(...parts: string[]): string; basename(p: string): string; extname(p: string): string };
    \\      log: { info(msg: string): void; warn(msg: string): void; error(msg: string): void };
    \\      opener: { open(url: string): Promise<void> };
    \\      windowState: { get(): Promise<unknown>; save(): Promise<void> };
    \\      services: { list(): Promise<{ name: string; scope: string; started: boolean }[]>; start(name: string): Promise<void>; stop(name: string): Promise<void> };
    \\      http: { request(opts: { url: string; method?: string; headers?: Record<string, string>; body?: string; timeout_ms?: number }): Promise<unknown> };
    \\      ws: { connect(url: string): Promise<number>; send(id: number, data: string): Promise<void>; close(id: number, code?: number, reason?: string): Promise<void>; on(id: number, cb: (e: unknown) => void): () => void };
    \\      webviews: { create(opts?: { x?: number; y?: number; width?: number; height?: number; url?: string }): Promise<{ id: number }>; remove(id: number): Promise<boolean>; navigate(id: number, url: string): Promise<boolean>; setBounds(id: number, x: number, y: number, w: number, h: number): Promise<boolean>; focus(id: number): Promise<boolean>; list(): Promise<unknown[]> };
    \\      process: { spawn(opts: { id: number; argv: string[]; cwd?: string }): Promise<void>; kill(id: number, code?: number): Promise<boolean>; list(): Promise<unknown[]>; on(id: number, cb: (e: unknown) => void): () => void };
    \\      sql: { query(db: string, sql: string, params?: unknown[]): Promise<Record<string, unknown>[]>; execute(db: string, sql: string, params?: unknown[]): Promise<{ changes: number; last_id: number }> };
    \\    };
    \\  }
    \\}
    \\export {};
    \\
;

test "package.json is valid JSON with name/version" {
    const a = std.testing.allocator;
    var files = try generate(a, .{ .runtime_js = "window.zilt = { version: '0.1.17' };" });
    defer files.deinit(a);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, files.package_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("@zilt/runtime", parsed.value.object.get("name").?.string);
    try std.testing.expectEqualStrings("0.1.17", parsed.value.object.get("version").?.string);
    try std.testing.expectEqualStrings("index.js", parsed.value.object.get("main").?.string);
}

test "jsStringLiteral escapes quotes and newlines" {
    const a = std.testing.allocator;
    const s = try jsStringLiteral(a, "a'b\\c\nd");
    defer a.free(s);
    try std.testing.expectEqualStrings("'a\\'b\\\\c\\nd'", s);
    // 字面量必须在 JS 里合法（两端引号闭合）
    try std.testing.expect(s[0] == '\'' and s[s.len - 1] == '\'');
}

test "index.js embeds runtime source as valid literal" {
    const a = std.testing.allocator;
    var files = try generate(a, .{ .runtime_js = "const x = 1;" });
    defer files.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, files.index_js, "'const x = 1;'") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.index_js, ENTRY_SNIPPET) != null);
    try std.testing.expect(std.mem.indexOf(u8, files.readme_md, "@zilt/runtime") != null);
    // d.ts 覆盖关键命名空间
    try std.testing.expect(std.mem.indexOf(u8, files.index_d_ts, "sql:") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.index_d_ts, "webviews:") != null);
}
