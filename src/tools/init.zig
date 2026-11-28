//! `zig build init` 项目创建工具：
//!   zilt-init [-t vanilla|vue|react|svelte] [-n 项目名] [-d 目标目录]
//! 产出独立可构建的项目：
//!   - vendored 框架源码（src/zilt/**，从本仓库复制——项目完全自包含）
//!   - 共享壳（templates/_common：build.zig/main.zig/commands 等，.tmpl 占位符替换）
//!   - 模板前端（templates/<t>/frontend/**）
//!   - 模板专属 project.zig（frontend 段按模板差异生成）
//!
//! v0.2.8：IO 层从 kernel32 手写 extern 改为 `std.Io.Dir`（frontend_codegen 的
//! v0.2.0 移植同款）——Windows / Linux 同一份实现，路径分隔符统一 '/'。

const std = @import("std");
const Io = std.Io;

const alloc = std.heap.page_allocator;

pub const templates_available = [_][]const u8{ "vanilla", "vue", "react", "svelte", "solid", "preact", "htmx", "angular", "vue-ts", "react-ts", "svelte-ts", "preact-ts" };

/// v0.3.11 F2：TS 变体 = 基础模板（vendored 框架复用）+ TS overlay
/// （templates/<variant>/frontend 覆盖式叠加：src/*.ts、tsconfig.json、package.json
/// 加 typecheck 步骤）。返回 null = 非变体（直接用同名目录）。
pub fn tsVariantBase(template: []const u8) ?[]const u8 {
    const map = [_]struct { variant: []const u8, base: []const u8 }{
        .{ .variant = "vue-ts", .base = "vue" },
        .{ .variant = "react-ts", .base = "react" },
        .{ .variant = "svelte-ts", .base = "svelte" },
        .{ .variant = "preact-ts", .base = "preact" },
    };
    for (map) |e| {
        if (std.mem.eql(u8, template, e.variant)) return e.base;
    }
    return null;
}

/// 工具进程的 Io（Threaded 惰性创建；本工具只做同步目录/文件操作）。
var g_threaded: Io.Threaded = undefined;
var g_threaded_ready = false;
fn toolIo() Io {
    if (!g_threaded_ready) {
        g_threaded = .init(alloc, .{});
        g_threaded_ready = true;
    }
    return g_threaded.io();
}

pub fn main(init: std.process.Init) !void {
    // 参数经环境变量（0.17 build 无 b.args）：ZILT_INIT_TEMPLATE / ZILT_INIT_NAME / ZILT_INIT_DEST
    const template = init.environ_map.get("ZILT_INIT_TEMPLATE") orelse "vanilla";
    const name = init.environ_map.get("ZILT_INIT_NAME") orelse "my-zilt-app";
    const dest: ?[]const u8 = init.environ_map.get("ZILT_INIT_DEST");

    return scaffold(template, name, dest);
}

/// 脚手架核心（`zig build init` 与 `zilt new` 共用）。cwd 必须是框架仓库根
/// （需要 src/zilt、src/tools、templates/ 作为源）。返回错误由调用方决定退出码。
pub fn scaffold(template: []const u8, name: []const u8, dest: ?[]const u8) !void {
    var ok = false;
    for (templates_available) |t| {
        if (std.mem.eql(u8, t, template)) ok = true;
    }
    if (!ok) {
        std.debug.print("error: 未知模板 '{s}'（可选：", .{template});
        for (templates_available, 0..) |t, j| {
            std.debug.print("{s}{s}", .{ t, if (j + 1 < templates_available.len) "/" else "" });
        }
        std.debug.print("）\n", .{});
        return error.UnknownTemplate;
    }
    if (!validName(name)) {
        std.debug.print("error: 项目名只能包含字母/数字/-/_\n", .{});
        return error.BadName;
    }

    // 占位符值由项目名派生（此前全局变量从未赋值，所有模板都产出
    // "My Zilt App"/"app.myziltapp"——v0.1.17 修复）
    app_name_value = try displayNameAlloc(alloc, name);
    app_id_value = try appIdAlloc(alloc, name);
    // v0.6.0b：版本占位符改从 `src/project.zig` 提取——运行时 `src/zilt/version.zig`
    // 已改为读 build options（无字面量），project.zig 是构建期 base 的唯一字面量。
    if (readFile("src/project.zig")) |pz| {
        defer alloc.free(pz);
        if (std.mem.indexOf(u8, pz, "pub const version = \"")) |i| {
            const start = i + "pub const version = \"".len;
            if (std.mem.indexOfScalarPos(u8, pz, start, '"')) |j| {
                if (j > start) version_value = try alloc.dupe(u8, pz[start..j]);
            }
        }
    } else |_| {}
    zon_name_value = try zonNameAlloc(alloc, name);

    const dest_dir = dest orelse try alloc.dupe(u8, name);
    mkDir(dest_dir); // 已存在不算错误

    // 1) vendored 框架源码与工具（项目完全自包含）
    try copyTree("src/zilt", try join3(dest_dir, "src", "zilt"), false);
    try copyTree("src/tools", try join3(dest_dir, "src", "tools"), false);
    // v0.2.8：src/pack_linux.zig（vendored build.zig 的 Linux pack 步骤引用它；
    // 它只依赖 src/zilt/pack_formats.zig 等已 vendor 的路径，单文件拷贝即可）
    {
        const pl = try readFile("src/pack_linux.zig");
        defer alloc.free(pl);
        try writeFile(try join3(dest_dir, "src", "pack_linux.zig"), pl);
    }

    // 2) 共享壳（.tmpl 占位符替换）
    try copyTree("templates/_common", dest_dir, true);

    // 3) 模板前端 + 模板专属 project.zig（frontend 段按模板差异）
    // v0.3.11 F2：TS 变体 = 基础前端（vendored 框架复用）+ overlay 覆盖
    // （templates/<variant>/ 只放 TS 专属文件：src/*.ts、tsconfig、package.json）
    var tmpl_root = try join2("templates", template);
    if (tsVariantBase(template)) |base| {
        tmpl_root = try join2("templates", base);
        try copyTree(try join2(tmpl_root, "frontend"), try join2(dest_dir, "frontend"), true);
        try copyTree(try join2("templates", template), try join2(dest_dir, "frontend"), true);
    } else {
        try copyTree(try join2(tmpl_root, "frontend"), try join2(dest_dir, "frontend"), true);
    }
    {
        const pz_data = try readFile(try join2(tmpl_root, "project.zig.tmpl"));
        defer alloc.free(pz_data);
        const replaced = try replacePlaceholders(alloc, pz_data);
        defer alloc.free(replaced);
        try writeFile(try join3(dest_dir, "src", "project.zig"), replaced);
    }

    std.debug.print(
        \\✓ 项目已创建: {s}（模板 {s}）
        \\
        \\下一步:
        \\  cd {s}
        \\  npm install            （或 pnpm/bun install；vanilla 模板无需）
        \\  zig build frontend     （构建前端到 frontend/dist）
        \\  zig build run          （运行：资产已嵌入 exe）
        \\  zig build dev          （开发：spawn dev server → 直连 HMR）
        \\
    , .{ dest_dir, template, dest_dir });
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// build.zig.zon 的 name 字段（合法标识符）：小写、非字母数字转 _、数字开头加前缀。
pub fn zonNameAlloc(alloc2: std.mem.Allocator, name: []const u8) ![]u8 {
    const fixed = zonName(name);
    const len = std.mem.indexOfScalar(u8, &fixed, 0) orelse fixed.len;
    return alloc2.dupe(u8, fixed[0..len]);
}

/// 显示名：按 -/_ 分词，每词首字母大写，空格连接（my-app → My App）。
pub fn displayNameAlloc(alloc2: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc2);
    var at_word_start = true;
    for (name) |c| {
        if (c == '-' or c == '_') {
            try out.append(alloc2, ' ');
            at_word_start = true;
            continue;
        }
        if (at_word_start and c >= 'a' and c <= 'z') {
            try out.append(alloc2, std.ascii.toUpper(c));
        } else {
            try out.append(alloc2, c);
        }
        at_word_start = false;
    }
    return out.toOwnedSlice(alloc2);
}

/// 应用 id：app. + 小写去分隔符（my-app → app.myapp）。
pub fn appIdAlloc(alloc2: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc2);
    try out.appendSlice(alloc2, "app.");
    for (name) |c| {
        if (c == '-' or c == '_') continue;
        try out.append(alloc2, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(alloc2);
}

/// build.zig.zon 的 name 字段（合法标识符）：小写、非字母数字转 _、数字开头加前缀。
pub fn zonName(name: []const u8) [64]u8 {    var out: [64]u8 = undefined;
    var n: usize = 0;
    for (name) |c| {
        if (n >= out.len) break;
        const lower = std.ascii.toLower(c);
        out[n] = if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) lower else '_';
        n += 1;
    }
    if (n == 0 or (out[0] >= '0' and out[0] <= '9')) {
        // 前移插入 "app" 前缀
        const prefix = "app";
        if (n + prefix.len < out.len) {
            std.mem.copyBackwards(u8, out[prefix.len..][0..n], out[0..n]);
            @memcpy(out[0..prefix.len], prefix);
            n += prefix.len;
        }
    }
    for (out[n..]) |*c| c.* = 0;
    return out;
}

/// 递归复制。replace=true 时：.tmpl 文件做占位符替换并去掉后缀。
fn copyTree(src: []const u8, dst: []const u8, replace: bool) !void {
    mkDir(dst);
    const io = toolIo();
    var dir = Io.Dir.cwd().openDir(io, src, .{ .iterate = true }) catch return error.SourceMissing;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const name = try alloc.dupe(u8, entry.name);
        defer alloc.free(name);
        const src_path = try join2(src, name);
        const dst_path = try join2(dst, name);
        switch (entry.kind) {
            .directory => try copyTree(src_path, dst_path, replace),
            .file => {
                if (replace and isTextPlaceholderFile(name)) {
                    // 文本文件同样做占位符替换（此前只处理 .tmpl，frontend/index.html
                    // 里的 {{APP_NAME}} 会原样留在产出页面——实测缺陷，v0.1.17 修复）
                    const out_name = if (std.mem.endsWith(u8, name, ".tmpl")) name[0 .. name.len - 5] else name;
                    const out_path = try join2(dst, out_name);
                    const data = try readFile(src_path);
                    defer alloc.free(data);
                    const replaced = try replacePlaceholders(alloc, data);
                    defer alloc.free(replaced);
                    try writeFile(out_path, replaced);
                } else {
                    const data = try readFile(src_path);
                    defer alloc.free(data);
                    try writeFile(dst_path, data);
                }
            },
            else => {}, // symlink 等跳过（模板仓库不含）
        }
    }
}

/// 占位符替换（Zig shell 文件）。
/// 仅对文本类扩展名启用（含 .tmpl），二进制资产原样复制。
fn isTextPlaceholderFile(name: []const u8) bool {
    const exts = [_][]const u8{ ".tmpl", ".html", ".htm", ".js", ".jsx", ".ts", ".tsx", ".json", ".css", ".vue", ".svelte", ".md", ".txt", ".xml", ".yml", ".yaml" };
    for (exts) |e| {
        if (std.mem.endsWith(u8, name, e)) return true;
    }
    return false;
}

pub fn replacePlaceholders(alloc2: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc2);
    var i: usize = 0;
    while (i < data.len) {
        if (std.mem.startsWith(u8, data[i..], "{{")) {
            const end = std.mem.indexOfPos(u8, data, i, "}}") orelse {
                try out.append(alloc2, data[i]);
                i += 1;
                continue;
            };
            const key = data[i + 2 .. end];
            if (std.mem.eql(u8, key, "APP_NAME")) {
                try out.appendSlice(alloc2, app_name_value);
            } else if (std.mem.eql(u8, key, "APP_ID")) {
                try out.appendSlice(alloc2, app_id_value);
            } else if (std.mem.eql(u8, key, "VERSION")) {
                try out.appendSlice(alloc2, version_value);
            } else if (std.mem.eql(u8, key, "ZON_NAME")) {
                const zn = zonName(app_name_value);
                try out.appendSlice(alloc2, zn[0..std.mem.indexOfScalar(u8, &zn, 0) orelse zn.len]);
            } else if (std.mem.eql(u8, key, "FINGERPRINT")) {
                // Zig 包指纹：高 32 位随机 id（1..0xfffffffe），低 32 位 = crc32(zon name)
                var fp: [4]u8 = undefined;
                Io.random(toolIo(), &fp); // 跨平台熵源（BCryptGenRandom 的替代）
                var id = std.mem.readInt(u32, &fp, .little);
                if (id == 0 or id == 0xffffffff) id = 0x12345678;
                const checksum = std.hash.Crc32.hash(zon_name_value);
                const fingerprint = (@as(u64, checksum) << 32) | id;
                try out.print(alloc2, "0x{x:0>16}", .{fingerprint});
            } else {
                try out.appendSlice(alloc2, data[i .. end + 2]); // 未知占位符原样保留
            }
            i = end + 2;
        } else {
            try out.append(alloc2, data[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc2);
}

// 由 main 解析后填充（模块级可变状态；工具进程生命周期内有效）
var app_name_value: []const u8 = "My Zilt App";
var app_id_value: []const u8 = "app.myziltapp";
var version_value: []const u8 = "0.1.0";
var zon_name_value: []const u8 = "my_zilt_app";

// ---------------------------------------------------------------------------
// 测试（zig build test-tools）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "validName" {
    try testing.expect(validName("my-app"));
    try testing.expect(validName("App_1"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("a b"));
    try testing.expect(!validName("中文"));
}

test "zonName: 清洗 + 数字开头补前缀" {
    const a = zonName("my-app");
    try testing.expect(std.mem.startsWith(u8, &a, "my_app"));
    const b = zonName("1abc");
    try testing.expect(std.mem.startsWith(u8, &b, "app1abc"));
    const c = zonName("Vue TS!"); // 空格/! → _
    try testing.expect(std.mem.startsWith(u8, &c, "vue_ts_"));
}

test "replacePlaceholders" {
    const out = try replacePlaceholders(testing.allocator, "name={{APP_NAME}} id={{APP_ID}} v={{VERSION}} keep={{X}}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "name=My Zilt App") != null);
    try testing.expect(std.mem.indexOf(u8, out, "id=app.myziltapp") != null);
    try testing.expect(std.mem.indexOf(u8, out, "v=0.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "keep={{X}}") != null);
}

// ---- 文件助手 ----

fn join2(base: []const u8, a: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, a });
}

fn join3(base: []const u8, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ base, a, b });
}

/// 递归创建目录（逐段创建，CreateDirectoryW 不建父目录）。
fn mkDir(path: []const u8) void {
    _ = Io.Dir.cwd().createDirPathStatus(toolIo(), path, .default_dir) catch {};
}

fn readFile(path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(toolIo(), path, alloc, .limited(64 * 1024 * 1024));
}

fn writeFile(path: []const u8, data: []const u8) !void {
    Io.Dir.cwd().writeFile(toolIo(), .{ .sub_path = path, .data = data }) catch {
        std.debug.print("[init] writeFile failed: {s}\n", .{path});
        return error.WriteFailed;
    };
}

test "displayNameAlloc / appIdAlloc 派生" {
    const a = std.testing.allocator;
    const d1 = try displayNameAlloc(a, "my-app");
    defer a.free(d1);
    try testing.expectEqualStrings("My App", d1);
    const d2 = try displayNameAlloc(a, "zilt_demo");
    defer a.free(d2);
    try testing.expectEqualStrings("Zilt Demo", d2);
    const id1 = try appIdAlloc(a, "my-app");
    defer a.free(id1);
    try testing.expectEqualStrings("app.myapp", id1);
    const id2 = try appIdAlloc(a, "Zilt_Demo");
    defer a.free(id2);
    try testing.expectEqualStrings("app.ziltdemo", id2);
}
