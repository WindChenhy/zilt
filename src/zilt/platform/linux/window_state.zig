//! Linux 窗口状态持久化（v0.2.1）。
//!
//! 目录与文件名对齐 Windows 的 `platform/windows/app_data.zig`：
//!   `<XDG_DATA_HOME|~/.local/share>/<app_id>/window-state/<sha256(key)>.json`
//! 键可以是任意字节（含空串 / 含 `/`），SHA-256 文件名避免路径注入与
//! 大小写不敏感文件系统的键冲突。
//!
//! 只做「读写 + 校验」；屏幕钳制、maximized/fullscreen 的应用属于调用方
//! （backend 创建窗口时读取）。
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const State = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    maximized: bool = false,
    fullscreen: bool = false,
};

pub const max_json_bytes: usize = 4096;

/// 状态文件名（64 位十六进制 SHA-256 + ".json"）。
pub fn filename(key: []const u8) [69]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    var name: [69]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        name[i * 2] = hex[byte >> 4];
        name[i * 2 + 1] = hex[byte & 15];
    }
    @memcpy(name[64..], ".json");
    return name;
}

fn validateState(state: State) !void {
    if (state.width == 0 or state.height == 0) return error.InvalidState;
    if (state.width > std.math.maxInt(i32) or state.height > std.math.maxInt(i32)) return error.InvalidState;
}

pub fn serialize(alloc: Allocator, state: State) ![]u8 {
    try validateState(state);
    return std.json.Stringify.valueAlloc(alloc, .{
        .version = @as(u32, 1),
        .x = state.x,
        .y = state.y,
        .width = state.width,
        .height = state.height,
        .maximized = state.maximized,
        .fullscreen = state.fullscreen,
    }, .{});
}

fn integer(object: std.json.ObjectMap, name: []const u8) !i64 {
    return switch (object.get(name) orelse return error.InvalidState) {
        .integer => |n| n,
        else => error.InvalidState,
    };
}

fn boolean(object: std.json.ObjectMap, name: []const u8) !bool {
    return switch (object.get(name) orelse return error.InvalidState) {
        .bool => |b| b,
        else => error.InvalidState,
    };
}

pub fn deserialize(alloc: Allocator, bytes: []const u8) !State {
    if (bytes.len == 0 or bytes.len > max_json_bytes) return error.InvalidState;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .max_value_len = max_json_bytes,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidState;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidState;
    const obj = parsed.value.object;
    if (obj.count() != 7 or try integer(obj, "version") != 1) return error.InvalidState;
    const state: State = .{
        .x = std.math.cast(i32, try integer(obj, "x")) orelse return error.InvalidState,
        .y = std.math.cast(i32, try integer(obj, "y")) orelse return error.InvalidState,
        .width = std.math.cast(u32, try integer(obj, "width")) orelse return error.InvalidState,
        .height = std.math.cast(u32, try integer(obj, "height")) orelse return error.InvalidState,
        .maximized = try boolean(obj, "maximized"),
        .fullscreen = try boolean(obj, "fullscreen"),
    };
    try validateState(state);
    return state;
}

/// 进程级 Io（线程同步目录/文件操作；惰性创建，同 log.zig 的模式）。
var g_threaded: std.Io.Threaded = undefined;
var g_threaded_ready = false;
fn sharedIo() Io {
    if (!g_threaded_ready) {
        g_threaded = .init(std.heap.page_allocator, .{});
        g_threaded_ready = true;
    }
    return g_threaded.io();
}

fn statePath(alloc: Allocator, root: []const u8, key: []const u8) ![]u8 {
    const name = filename(key);
    return std.fmt.allocPrint(alloc, "{s}/window-state/{s}", .{ std.mem.trimEnd(u8, root, "/"), name[0..] });
}

/// 文件是否存在（下载目标去重等调用方共用；不区分错误类型，一律按不存在）。
pub fn fileExists(path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(sharedIo(), path, .{}) catch return false;
    return true;
}

/// 原子性不做强保证（单文件 < 4KB；崩溃最多丢一次状态），但会先创建目录。
pub fn save(alloc: Allocator, root: []const u8, key: []const u8, state: State) !void {
    const bytes = try serialize(alloc, state);
    defer alloc.free(bytes);
    const path = try statePath(alloc, root, key);
    defer alloc.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.InvalidStatePath;
    const i = sharedIo();
    _ = try Io.Dir.cwd().createDirPathStatus(i, dir, .default_dir);
    try Io.Dir.cwd().writeFile(i, .{ .sub_path = path, .data = bytes });
}

/// 不存在返回 null；损坏/超长/版本不符返回 InvalidState。
pub fn load(alloc: Allocator, root: []const u8, key: []const u8) !?State {
    const path = try statePath(alloc, root, key);
    defer alloc.free(path);
    const bytes = Io.Dir.cwd().readFileAlloc(sharedIo(), path, alloc, .limited(max_json_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(bytes);
    return try deserialize(alloc, bytes);
}

const testing = std.testing;

test "state JSON round trip and defaults" {
    const alloc = testing.allocator;
    const states = [_]State{
        .{ .x = -1920, .y = -30, .width = 1200, .height = 800 },
        .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32), .width = std.math.maxInt(i32), .height = 1, .maximized = true, .fullscreen = true },
    };
    for (states) |state| {
        const bytes = try serialize(alloc, state);
        defer alloc.free(bytes);
        try testing.expect(bytes.len <= max_json_bytes);
        try testing.expectEqualDeep(state, try deserialize(alloc, bytes));
    }
    try testing.expectError(error.InvalidState, serialize(alloc, .{ .x = 0, .y = 0, .width = 0, .height = 1 }));
}

test "reject corrupt, ambiguous, oversized and invalid states" {
    const alloc = testing.allocator;
    const template = "{{\"version\":{s},\"x\":{s},\"y\":0,\"width\":{s},\"height\":{s},\"maximized\":{s},\"fullscreen\":false}}";
    const cases = [_][5][]const u8{
        .{ "2", "0", "1", "1", "false" },
        .{ "1", "2147483648", "1", "1", "false" },
        .{ "1", "-2147483649", "1", "1", "false" },
        .{ "1", "0", "0", "1", "false" },
        .{ "1", "0", "1", "0", "false" },
        .{ "1", "0", "1.5", "1", "false" },
        .{ "1", "\"0\"", "1", "1", "false" },
        .{ "1", "0", "1", "1", "0" },
    };
    for (cases) |args| {
        const bytes = try std.fmt.allocPrint(alloc, template, .{ args[0], args[1], args[2], args[3], args[4] });
        defer alloc.free(bytes);
        try testing.expectError(error.InvalidState, deserialize(alloc, bytes));
    }
    for ([_][]const u8{ "", "{", "{}", "[]", "null", "{\"version\":1,\"version\":1}", "{} trailing" }) |bytes| {
        try testing.expectError(error.InvalidState, deserialize(alloc, bytes));
    }
    try testing.expectError(error.InvalidState, deserialize(alloc, &(@as([max_json_bytes + 1]u8, @splat(' ')))));
}

test "hashed key filenames isolate arbitrary keys" {
    const base = filename("main");
    try testing.expectEqual(@as(usize, 69), base.len);
    for (base[0..64]) |ch| try testing.expect(std.ascii.isHex(ch));
    try testing.expectEqualStrings(".json", base[64..]);
    for ([_][]const u8{ "../escape", "/abs", "a\x00b", "窗口", "MAIN", "" }) |key| {
        const other = filename(key);
        try testing.expect(!std.mem.eql(u8, &base, &other));
    }
    // 稳定：同 key 两次一致
    try testing.expectEqualStrings(&base, &filename("main"));
}

test "save/load round trip under a private temp directory" {
    const alloc = testing.allocator;
    var buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, ".zig-cache/zilt-window-state-test-{d}", .{std.time.nanoTimestamp()});
    const i = sharedIo();
    defer Io.Dir.cwd().deleteTree(i, root) catch {};

    try testing.expectEqual(@as(?State, null), try load(alloc, root, "main"));
    const first: State = .{ .x = -80, .y = 20, .width = 600, .height = 400 };
    const second: State = .{ .x = 42, .y = -10, .width = 800, .height = 500, .maximized = true, .fullscreen = true };
    try save(alloc, root, "main", first);
    try testing.expectEqualDeep(first, (try load(alloc, root, "main")).?);
    try save(alloc, root, "main", second);
    try testing.expectEqualDeep(second, (try load(alloc, root, "main")).?);
    // 键互不影响
    try testing.expectEqual(@as(?State, null), try load(alloc, root, "other"));
}
