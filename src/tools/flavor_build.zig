//! v0.6.0c：build graph 的 flavor 解析共享实现（仓库 build.zig 与模板 build.zig 共用）。
//!
//! 解析顺序（RFC 7396，后者覆盖前者）：
//!   project base → zilt.config.json → zilt.<platform>.json
//!   → flavors 表中的 effective patch（v0.6.0c，支持 extends）
//!   → zilt.<flavor>.json（存在则再覆盖）→ -Dconfig
//!
//! 表模式与文件模式可组合：表提供身份默认值/继承，文件补充该 flavor 的额外 overlay。
//! 无 `flavors` 表时，`-Dflavor=<name>` 仍要求 `zilt.<name>.json`（0.6.0a 行为）。

const std = @import("std");
const flavor_merge = @import("../zilt/flavor_merge.zig");
const flavor_codegen = @import("../zilt/flavor_codegen.zig");
const codegen = @import("frontend_codegen.zig");

pub const Identity = flavor_merge.Identity;
pub const Frontend = flavor_merge.Frontend;

pub const Resolved = struct {
    identity: Identity,
    frontend: Frontend,
    merged: std.json.Value,
};

fn flavorPlatform(tag: std.Target.Os.Tag) []const u8 {
    return switch (tag) {
        .windows => "windows",
        .macos => "macos",
        .linux => "linux",
        else => "other",
    };
}

fn readJsonPatch(b: *std.Build, path: []const u8) ?std.json.Value {
    const bytes = codegen.readFileAlloc(b.allocator, b.graph.io, path) orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, b.allocator, bytes, .{}) catch {
        std.debug.print("flavor: {s} 不是合法 JSON\n", .{path});
        std.process.exit(1);
    };
    return parsed.value;
}

fn putString(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) void {
    obj.put(alloc, key, .{ .string = value }) catch @panic("OOM");
}

fn baseConfigValue(
    alloc: std.mem.Allocator,
    identity: Identity,
    frontend: Frontend,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    putString(alloc, &obj, "app_name", identity.app_name);
    putString(alloc, &obj, "app_id", identity.app_id);
    putString(alloc, &obj, "version", identity.version);
    putString(alloc, &obj, "publisher", identity.publisher);
    putString(alloc, &obj, "channel", identity.channel);
    putString(alloc, &obj, "exe_name", identity.exe_name);
    try obj.put(alloc, "icon", if (identity.icon) |p| .{ .string = p } else .null);
    try obj.put(alloc, "single_instance_key", .null);

    var fe = std.json.ObjectMap.empty;
    putString(alloc, &fe, "dir", frontend.dir);
    putString(alloc, &fe, "dist", frontend.dist);
    if (frontend.dev_command) |v| putString(alloc, &fe, "dev_command", v) else try fe.put(alloc, "dev_command", .null);
    if (frontend.dev_url) |v| putString(alloc, &fe, "dev_url", v) else try fe.put(alloc, "dev_url", .null);
    if (frontend.build_command) |v| putString(alloc, &fe, "build_command", v) else try fe.put(alloc, "build_command", .null);
    try fe.put(alloc, "dev_proxy", .{ .bool = frontend.dev_proxy });
    try fe.put(alloc, "wait_timeout_secs", .{ .integer = frontend.wait_timeout_secs });
    try obj.put(alloc, "frontend", .{ .object = fe });

    try obj.put(alloc, "security", .{ .object = std.json.ObjectMap.empty });
    try obj.put(alloc, "window", .{ .object = std.json.ObjectMap.empty });
    return .{ .object = obj };
}

fn jsonStr(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "?";
    const x = v.object.get(key) orelse return "?";
    return if (x == .string) x.string else "<non-string>";
}

fn hasFlavorTable(config: std.json.Value) bool {
    if (config != .object) return false;
    return config.object.get("flavors") != null;
}

/// 解析并合并所有 overlay。失败时打印可执行错误并退出（build 配置期）。
pub fn resolve(
    b: *std.Build,
    target_os: std.Target.Os.Tag,
    flavor: ?[]const u8,
    config_path: ?[]const u8,
    fallback_identity: Identity,
    fallback_frontend: Frontend,
) Resolved {
    var patches: [5]std.json.Value = undefined;
    var n: usize = 0;
    var base_config: ?std.json.Value = null;

    if (readJsonPatch(b, "zilt.config.json")) |v| {
        base_config = v;
        flavor_merge.validateFlavorTable(b.allocator, v, flavor) catch |e| {
            std.debug.print("flavor: zilt.config.json 的 flavors 表非法（{s}）\n", .{@errorName(e)});
            std.process.exit(1);
        };
        patches[n] = v;
        n += 1;
    }

    const platform_path = b.fmt("zilt.{s}.json", .{flavorPlatform(target_os)});
    if (readJsonPatch(b, platform_path)) |v| {
        patches[n] = v;
        n += 1;
    }

    if (flavor) |f| {
        const table_mode = if (base_config) |cfg| hasFlavorTable(cfg) else false;
        if (table_mode) {
            const table_patch = flavor_merge.flavorTablePatch(b.allocator, base_config.?, f) catch |e| {
                std.debug.print("flavor: flavors 表解析失败（{s}）\n", .{@errorName(e)});
                std.process.exit(1);
            };
            if (table_patch) |v| {
                patches[n] = v;
                n += 1;
            }
        }
        const path = b.fmt("zilt.{s}.json", .{f});
        if (readJsonPatch(b, path)) |v| {
            patches[n] = v;
            n += 1;
        } else if (!table_mode) {
            std.debug.print("flavor: -Dflavor={s} 需要 {s}（文件不存在）\n", .{ f, path });
            std.process.exit(1);
        }
    }
    if (config_path) |p| {
        const v = readJsonPatch(b, p) orelse {
            std.debug.print("flavor: -Dconfig={s} 文件不存在\n", .{p});
            std.process.exit(1);
        };
        patches[n] = v;
        n += 1;
    }

    const base = baseConfigValue(b.allocator, fallback_identity, fallback_frontend) catch @panic("OOM");
    const merged = flavor_merge.mergeAll(b.allocator, base, patches[0..n]) catch @panic("OOM");
    const id = flavor_merge.identityFrom(b.allocator, merged, fallback_identity) catch |e| {
        std.debug.print("flavor: 身份非法（{s}）——app_id={s} version={s} channel={s}\n", .{
            @errorName(e),
            jsonStr(merged, "app_id"),
            jsonStr(merged, "version"),
            jsonStr(merged, "channel"),
        });
        std.process.exit(1);
    };
    const fe_value = if (merged == .object) (merged.object.get("frontend") orelse .null) else .null;
    const fe = flavor_merge.frontendFrom(b.allocator, fe_value, fallback_frontend) catch |e| {
        std.debug.print("flavor: frontend 配置非法（{s}）\n", .{@errorName(e)});
        std.process.exit(1);
    };
    return .{ .identity = id, .frontend = fe, .merged = merged };
}

/// 产物名去掉 Windows 扩展名（addExecutable 的 name 不带 .exe）。
pub fn exeStem(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".exe")) return name[0 .. name.len - 4];
    return name;
}

/// 把 window/security overlay 生成为内容寻址的 flavor 模块（带上游 zilt 依赖）。
pub fn addFlavorModule(
    b: *std.Build,
    zilt_mod: *std.Build.Module,
    merged: std.json.Value,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const source = flavor_codegen.generate(b.allocator, merged) catch |e| {
        std.debug.print("flavor: window/security overlay 非法（{s}）\n", .{@errorName(e)});
        std.process.exit(1);
    };
    var hash = std.hash.Wyhash.init(0);
    hash.update(source);
    const rel = b.fmt(".zilt-cache-flavor/{x:0>8}/flavor.zig", .{hash.final()});
    const abs = b.root.joinString(b.allocator, rel) catch rel;
    codegen.ensureDirDeep(b.allocator, b.graph.io, std.fs.path.dirname(abs) orelse ".") catch @panic("flavor dir create failed");
    if (!codegen.writeFilePayload(b.allocator, b.graph.io, abs, source)) @panic("flavor write failed");
    return b.createModule(.{
        .root_source_file = b.path(rel),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zilt", .module = zilt_mod },
        },
    });
}
