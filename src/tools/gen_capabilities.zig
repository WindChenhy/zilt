//! Capability manifest generation (v0.1.11).
//!
//! `zig build` / `zig build gen` writes frontend/bindings/capabilities.json from
//! the compile-time `app_config.security` declaration, so the ACL enforced at
//! runtime is exactly the one shipped with the build.
const std = @import("std");
const zilt = @import("zilt");
const app = @import("app_config");

pub const OUTPUT_PATH = "frontend/bindings/capabilities.json";

pub const Manifest = struct {
    schema_version: u32 = 1,
    framework_version: []const u8 = "0.1.12",
    csp: ?[]const u8,
    headers: []const zilt.security.Header,
    navigation_origins: []const []const u8,
    external_links: zilt.security.ExternalLinks,
    dev_relaxed: bool,
    isolation: bool,
    capabilities: []const zilt.security.Capability,
    deny_commands: []const []const u8,
    deny_events: []const []const u8,
};

pub fn manifestOf(options: zilt.security.Options) Manifest {
    return .{
        .csp = options.csp,
        .headers = options.headers,
        .navigation_origins = options.navigation_origins,
        .external_links = options.external_links,
        .dev_relaxed = options.dev_relaxed,
        .isolation = options.isolation,
        .capabilities = options.capabilities,
        .deny_commands = options.deny_commands,
        .deny_events = options.deny_events,
    };
}

pub fn render(alloc: std.mem.Allocator, options: zilt.security.Options) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, manifestOf(options), .{});
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    if (try generateFromJson(alloc)) return;
    const path = OUTPUT_PATH;

    const json = try render(alloc, app.security);
    defer alloc.free(json);

    const win32 = zilt.platform_windows.win32;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const dir_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path[0..slash]);
        defer alloc.free(dir_w);
        _ = win32.CreateDirectoryW(dir_w.ptr, null);
    }
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);
    const f = win32.CreateFileW(path_w.ptr, win32.GENERIC_WRITE, 0, null, win32.CREATE_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (f == win32.INVALID_HANDLE_VALUE) return error.WriteFailed;
    defer _ = win32.CloseHandle(f);
    var written: win32.DWORD = 0;
    if (win32.WriteFile(f, json.ptr, @intCast(json.len), &written, null) == 0) return error.WriteFailed;
    std.debug.print("generated {s} ({d} bytes, {d} capabilities)\n", .{ path, json.len, app.security.capabilities.len });
}

/// v0.1.23：JSON → Zig 策略源码。
/// `ZILT_CAP_FROM=<capabilities.json> ZILT_CAP_OUT=<out.zig> zig build capabilities`
/// 不设置 FROM 时保持原行为（导出 JSON）。
fn generateFromJson(alloc: std.mem.Allocator) !bool {
    const win32 = zilt.platform_windows.win32;
    const from = win32.getEnvUtf8(alloc, "ZILT_CAP_FROM") orelse return false;
    defer alloc.free(from);
    const out = win32.getEnvUtf8(alloc, "ZILT_CAP_OUT") orelse try alloc.dupe(u8, "src/capabilities.zig");
    defer alloc.free(out);

    const codegen = @import("frontend_codegen.zig");
    const json = codegen.readFileAlloc(alloc, from) orelse {
        std.debug.print("capabilities: 读取 {s} 失败\n", .{from});
        return error.ReadFailed;
    };
    defer alloc.free(json);
    const src = try @import("capability_codegen.zig").renderZig(alloc, json);
    defer alloc.free(src);

    codegen.ensureDirDeep(alloc, std.fs.path.dirname(out) orelse ".") catch {};
    if (!codegen.writeFilePayload(alloc, out, src)) return error.WriteFailed;
    std.debug.print("generated {s} from {s} ({d} bytes)\n", .{ out, from, src.len });
    return true;
}

test "manifest renders the enforced ACL and navigation policy" {
    const t = std.testing;
    const options = zilt.security.Options{
        .csp = "default-src 'self'",
        .navigation_origins = &.{"https://trusted.example"},
        .external_links = .system_browser,
        .capabilities = &.{.{ .name = "main", .commands = &.{"greet"} }},
        .deny_commands = &.{"blockedDemo"},
    };
    const json = try render(t.allocator, options);
    defer t.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try t.expectEqual(@as(i64, 1), obj.get("schema_version").?.integer);
    try t.expectEqualStrings("default-src 'self'", obj.get("csp").?.string);
    try t.expectEqualStrings("system_browser", obj.get("external_links").?.string);
    const caps = obj.get("capabilities").?.array;
    try t.expectEqual(@as(usize, 1), caps.items.len);
    try t.expectEqualStrings("greet", caps.items[0].object.get("commands").?.array.items[0].string);
    try t.expectEqualStrings("https://trusted.example", obj.get("navigation_origins").?.array.items[0].string);
    try t.expectEqualStrings("blockedDemo", obj.get("deny_commands").?.array.items[0].string);
}

test "empty manifest stays deny-by-default" {
    const t = std.testing;
    const json = try render(t.allocator, .{});
    defer t.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try t.expectEqualStrings("deny", obj.get("external_links").?.string);
    try t.expectEqual(@as(usize, 0), obj.get("capabilities").?.array.items.len);
}
