//! Per-app Windows data. No backend/config dependencies; callers own returned buffers.
//! App IDs are Windows path segments (case-insensitive on typical filesystems).
//! Window keys are arbitrary bytes, including empty/NUL: SHA-256 names isolate them.
const std = @import("std");
const win32 = @import("win32.zig");
const Allocator = std.mem.Allocator;

pub const State = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    maximized: bool = false,
    fullscreen: bool = false,
};

const max_json_bytes = 4096;
const reparse_point = 0x400;
const share_delete = 0x4;
const create_new = 1;
const move_write_through = 0x8;
extern "kernel32" fn FlushFileBuffers(file: win32.HANDLE) callconv(.c) win32.BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.c) win32.DWORD;
extern "kernel32" fn GetTempPathW(length: win32.DWORD, buffer: [*]u16) callconv(.c) win32.DWORD;
var temp_sequence = std.atomic.Value(u64).init(0);

/// Returns %LOCALAPPDATA%/<app_id>/WebView2, creating a fresh profile by default.
/// Migration consumes the legacy directory with a same-volume, non-replacing rename.
/// Existing targets always win. No profiles are deleted or copied. A busy legacy
/// profile reports MigrationInUse; cross-volume migration reports MigrationCrossVolume.
pub fn profileDirectory(alloc: Allocator, app_id: []const u8, migrate_legacy: bool) ![]u8 {
    try validateAppId(app_id);
    const root = try environmentDirectory(alloc, "LOCALAPPDATA");
    defer alloc.free(root);
    const target = try appPath(alloc, root, app_id, "WebView2");
    errdefer alloc.free(target);
    if (try directoryExists(alloc, target)) return target;
    const parent = std.fs.path.dirnameWindows(target) orelse return error.InvalidDataRoot;
    try ensureDirectory(alloc, parent);
    if (migrate_legacy) {
        const temp = try environmentDirectory(alloc, "TEMP");
        defer alloc.free(temp);
        const legacy = try join(alloc, temp, "zilt-app-webview2");
        defer alloc.free(legacy);
        try migrateDirectory(alloc, legacy, target);
    }
    try ensureDirectory(alloc, target);
    return target;
}

/// Atomically saves version-1 JSON. Dimensions must be positive and fit Win32 i32.
/// Unique CREATE_NEW temp files live beside the target; only our own temp is cleaned
/// up on failure. Existing state remains intact until the flushed file is renamed.
pub fn save(alloc: Allocator, app_id: []const u8, key: []const u8, state: State) !void {
    try validateAppId(app_id);
    const bytes = try serialize(alloc, state);
    defer alloc.free(bytes);
    const root = try environmentDirectory(alloc, "LOCALAPPDATA");
    defer alloc.free(root);
    const path = try statePath(alloc, root, app_id, key);
    defer alloc.free(path);
    try ensureDirectory(alloc, std.fs.path.dirnameWindows(path).?);
    try atomicWrite(alloc, path, bytes);
}

/// Missing state returns null. Corrupt/oversized/version-mismatched state returns
/// InvalidState; filesystem failures remain errors. Does not create directories.
/// Screen clamping and application of maximized/fullscreen belong to the caller.
pub fn load(alloc: Allocator, app_id: []const u8, key: []const u8) !?State {
    try validateAppId(app_id);
    const root = try environmentDirectory(alloc, "LOCALAPPDATA");
    defer alloc.free(root);
    const path = try statePath(alloc, root, app_id, key);
    defer alloc.free(path);
    return loadPath(alloc, path);
}

fn validateAppId(id: []const u8) !void {
    // Conservative byte limit also guarantees <= 255 UTF-16 code units. Reject ~
    // to prevent DOS short-name aliases from selecting another app's directory.
    if (id.len == 0 or id.len > 255 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidAppId;
    if (id[0] == '.' or id[0] == ' ' or id[id.len - 1] == '.' or id[id.len - 1] == ' ') return error.InvalidAppId;
    for (id) |c| {
        if (c < 32 or c == 127 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*~", c) != null) return error.InvalidAppId;
    }
    const dot = std.mem.indexOfScalar(u8, id, '.') orelse id.len;
    const base = std.mem.trimEnd(u8, id[0..dot], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(base, reserved)) return error.InvalidAppId;
    }
    if (base.len >= 4 and (std.ascii.eqlIgnoreCase(base[0..3], "COM") or std.ascii.eqlIgnoreCase(base[0..3], "LPT"))) {
        const suffix = base[3..];
        if ((suffix.len == 1 and suffix[0] >= '1' and suffix[0] <= '9') or
            std.mem.eql(u8, suffix, "¹") or std.mem.eql(u8, suffix, "²") or std.mem.eql(u8, suffix, "³")) return error.InvalidAppId;
    }
}

fn join(alloc: Allocator, parent: []const u8, child: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ std.mem.trimEnd(u8, parent, "/\\"), child });
}

fn appPath(alloc: Allocator, root: []const u8, id: []const u8, child: []const u8) ![]u8 {
    try validateAppId(id);
    const parent = try join(alloc, root, id);
    defer alloc.free(parent);
    return join(alloc, parent, child);
}

fn keyFilename(key: []const u8) [69]u8 {
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

fn statePath(alloc: Allocator, root: []const u8, id: []const u8, key: []const u8) ![]u8 {
    const dir = try appPath(alloc, root, id, "window-state");
    defer alloc.free(dir);
    const name = keyFilename(key);
    return join(alloc, dir, &name);
}

fn environmentDirectory(alloc: Allocator, name: []const u8) ![]u8 {
    const wide_name = try std.unicode.utf8ToUtf16LeAllocZ(alloc, name);
    defer alloc.free(wide_name);
    const needed = win32.GetEnvironmentVariableW(wide_name.ptr, null, 0);
    if (needed == 0 or needed > 32768) return error.InvalidDataRoot;
    const wide = try alloc.alloc(u16, needed);
    defer alloc.free(wide);
    const got = win32.GetEnvironmentVariableW(wide_name.ptr, wide.ptr, needed);
    if (got == 0 or got >= needed) return error.InvalidDataRoot;
    const root = try std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..got]);
    errdefer alloc.free(root);
    // No relative, drive-relative, or Win32 device namespace roots.
    const drive = root.len >= 3 and std.ascii.isAlphabetic(root[0]) and root[1] == ':' and (root[2] == '\\' or root[2] == '/');
    const unc = root.len > 4 and std.mem.startsWith(u8, root, "\\\\") and root[2] != '?' and root[2] != '.';
    if (!drive and !unc) return error.InvalidDataRoot;
    return root;
}

fn missing(code: u32) bool {
    return code == 2 or code == 3;
}

fn directoryExists(alloc: Allocator, path: []const u8) !bool {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide);
    var info: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win32.GetFileAttributesExW(wide.ptr, 0, &info) == 0) {
        if (missing(win32.GetLastError())) return false;
        return error.DirectoryAccessFailed;
    }
    if (info.dwFileAttributes & reparse_point != 0) return error.ReparsePointNotAllowed;
    if (info.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0) return error.NotDirectory;
    return true;
}

fn ensureDirectory(alloc: Allocator, path: []const u8) anyerror!void {
    if (try directoryExists(alloc, path)) return;
    const parent = std.fs.path.dirnameWindows(path) orelse return error.InvalidDataRoot;
    if (std.mem.eql(u8, parent, path)) return error.InvalidDataRoot;
    try ensureDirectory(alloc, parent);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide);
    if (win32.CreateDirectoryW(wide.ptr, null) == 0) {
        if (win32.GetLastError() != win32.ERROR_ALREADY_EXISTS) return error.CreateDirectoryFailed;
        if (!try directoryExists(alloc, path)) return error.CreateDirectoryFailed;
    }
}

fn migrateDirectory(alloc: Allocator, legacy: []const u8, target: []const u8) !void {
    if (try directoryExists(alloc, target)) return;
    if (!try directoryExists(alloc, legacy)) return;
    const from = try std.unicode.utf8ToUtf16LeAllocZ(alloc, legacy);
    defer alloc.free(from);
    const to = try std.unicode.utf8ToUtf16LeAllocZ(alloc, target);
    defer alloc.free(to);
    // Neither REPLACE_EXISTING nor COPY_ALLOWED: exactly one app can consume it.
    if (win32.MoveFileExW(from.ptr, to.ptr, move_write_through) != 0) return;
    const code = win32.GetLastError();
    if (try directoryExists(alloc, target)) return; // Another creator won.
    if (missing(code) and !try directoryExists(alloc, legacy)) return; // Another app consumed it.
    return switch (code) {
        5, 32, 33 => error.MigrationInUse,
        17 => error.MigrationCrossVolume,
        else => error.MigrationFailed,
    };
}

fn validateState(state: State) !void {
    if (state.width == 0 or state.height == 0 or state.width > std.math.maxInt(i32) or state.height > std.math.maxInt(i32)) return error.InvalidState;
}

fn serialize(alloc: Allocator, state: State) ![]u8 {
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
    const value = object.get(name) orelse return error.InvalidState;
    return switch (value) {
        .integer => |n| n,
        else => error.InvalidState,
    };
}

fn boolean(object: std.json.ObjectMap, name: []const u8) !bool {
    const value = object.get(name) orelse return error.InvalidState;
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidState,
    };
}

fn deserialize(alloc: Allocator, bytes: []const u8) !State {
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

fn loadPath(alloc: Allocator, path: []const u8) !?State {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide);
    // Share deletion so readers never prevent an atomic replacement; no shared writes.
    const file = win32.CreateFileW(wide.ptr, win32.GENERIC_READ, win32.FILE_SHARE_READ | share_delete, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win32.INVALID_HANDLE_VALUE) {
        if (missing(win32.GetLastError())) return null;
        return error.StateOpenFailed;
    }
    defer _ = win32.CloseHandle(file);
    var size: win32.LARGE_INTEGER = undefined;
    if (win32.GetFileSizeEx(file, &size) == 0) return error.StateReadFailed;
    if (size.QuadPart <= 0 or size.QuadPart > max_json_bytes) return error.InvalidState;
    var buffer: [max_json_bytes + 1]u8 = undefined;
    var total: usize = 0;
    while (total < buffer.len) {
        var got: u32 = 0;
        if (win32.ReadFile(file, buffer[total..].ptr, @intCast(buffer.len - total), &got, null) == 0) return error.StateReadFailed;
        if (got == 0) break;
        total += got;
    }
    return try deserialize(alloc, buffer[0..total]);
}

fn atomicWrite(alloc: Allocator, path: []const u8, bytes: []const u8) !void {
    const target = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(target);
    // PID + atomic sequence + CREATE_NEW avoids concurrent/stale temp collisions.
    for (0..128) |_| {
        const sequence = temp_sequence.fetchAdd(1, .monotonic);
        const temp = try std.fmt.allocPrint(alloc, "{s}.{d}.{d}.tmp", .{ path, GetCurrentProcessId(), sequence });
        defer alloc.free(temp);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, temp);
        defer alloc.free(wide);
        const file = win32.CreateFileW(wide.ptr, win32.GENERIC_WRITE, 0, null, create_new, win32.FILE_ATTRIBUTE_NORMAL, null);
        if (file == win32.INVALID_HANDLE_VALUE) {
            const code = win32.GetLastError();
            if (code == 80 or code == 183) continue;
            return error.StateWriteFailed;
        }
        var open = true;
        defer if (open) {
            _ = win32.CloseHandle(file);
        };
        errdefer {
            _ = win32.DeleteFileW(wide.ptr);
        }
        // Close before cleanup on all write failures (Windows disallows deleting
        // this exclusive handle), as well as before publishing the file.
        var written: u32 = 0;
        const ok = win32.WriteFile(file, bytes.ptr, @intCast(bytes.len), &written, null) != 0 and written == bytes.len and FlushFileBuffers(file) != 0;
        const closed = win32.CloseHandle(file) != 0;
        open = false;
        if (!ok or !closed) return error.StateWriteFailed;
        if (win32.MoveFileExW(wide.ptr, target.ptr, win32.MOVEFILE_REPLACE_EXISTING | move_write_through) == 0) return error.StateReplaceFailed;
        return;
    }
    return error.StateTempCollision;
}

test "state JSON round trip and defaults" {
    const alloc = std.testing.allocator;
    const states = [_]State{
        .{ .x = -1920, .y = -30, .width = 1200, .height = 800 },
        .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32), .width = std.math.maxInt(i32), .height = 1, .maximized = true, .fullscreen = true },
    };
    for (states) |state| {
        const bytes = try serialize(alloc, state);
        defer alloc.free(bytes);
        try std.testing.expect(bytes.len <= max_json_bytes);
        try std.testing.expectEqualDeep(state, try deserialize(alloc, bytes));
    }
}

test "reject corrupt, ambiguous, oversized and invalid states" {
    const alloc = std.testing.allocator;
    const template = "{{\"version\":{s},\"x\":{s},\"y\":0,\"width\":{s},\"height\":{s},\"maximized\":{s},\"fullscreen\":false}}";
    const cases = [_][5][]const u8{
        .{ "2", "0", "1", "1", "false" },
        .{ "1", "2147483648", "1", "1", "false" },
        .{ "1", "-2147483649", "1", "1", "false" },
        .{ "1", "0", "0", "1", "false" },
        .{ "1", "0", "1", "0", "false" },
        .{ "1", "0", "-1", "1", "false" },
        .{ "1", "0", "2147483648", "1", "false" },
        .{ "1", "0", "1.5", "1", "false" },
        .{ "1", "\"0\"", "1", "1", "false" },
        .{ "1", "0", "1", "1", "0" },
        .{ "1", "0", "1", "1", "null" },
        .{ "1", "0", "1e999", "1", "false" },
    };
    for (cases) |args| {
        const bytes = try std.fmt.allocPrint(alloc, template, .{ args[0], args[1], args[2], args[3], args[4] });
        defer alloc.free(bytes);
        try std.testing.expectError(error.InvalidState, deserialize(alloc, bytes));
    }
    for ([_][]const u8{ "", "{", "{}", "[]", "null", "{\"version\":1,\"version\":1}", "{} trailing" }) |bytes| {
        try std.testing.expectError(error.InvalidState, deserialize(alloc, bytes));
    }
    try std.testing.expectError(error.InvalidState, deserialize(alloc, &(@as([max_json_bytes + 1]u8, @splat(' ')))));
    try std.testing.expectError(error.InvalidState, serialize(alloc, .{ .x = 0, .y = 0, .width = 0, .height = 1 }));
}

test "app IDs reject traversal, Windows devices and aliases" {
    for ([_][]const u8{ "", ".", "..", "../app", "a/b", "a\\b", "C:app", "app:stream", "a\x00b", "a\n", "app.", "app ", " app", "a?b", "a*b", "a|b", "a<b", "a>b", "a\"b", "CON", "con.txt", "NUL", "aux.json", "PRN", "COM1", "lpt9.log", "COM¹", "LPT².txt", "COM³", "CON .txt", "CLOCK$", "CONIN$", "CONOUT$", "APP~1", "\xff" }) |id| {
        try std.testing.expectError(error.InvalidAppId, validateAppId(id));
    }
    try std.testing.expectError(error.InvalidAppId, validateAppId(&(@as([256]u8, @splat('a')))));
    for ([_][]const u8{ "com.example.app", "my-app_2", "COM10", "console", "应用", "My App" }) |id| try validateAppId(id);
}

test "profile and stable hashed key paths" {
    const alloc = std.testing.allocator;
    const profile = try appPath(alloc, "C:\\private\\", "org.test", "WebView2");
    defer alloc.free(profile);
    try std.testing.expectEqualStrings("C:\\private\\org.test\\WebView2", profile);
    const name = keyFilename("abc");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.json", &name);
    const empty = keyFilename("");
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.json", &empty);
    const path = try statePath(alloc, "C:\\private", "app", "abc");
    defer alloc.free(path);
    try std.testing.expectEqualStrings("C:\\private\\app\\window-state\\ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.json", path);
    for ([_][]const u8{ "../escape", "C:\\other", "a\x00b", "窗口", "ABC" }) |key| {
        const filename = keyFilename(key);
        try std.testing.expect(!std.mem.eql(u8, &name, &filename));
        for (filename[0..64]) |c| try std.testing.expect(std.ascii.isHex(c));
    }
    const other = try statePath(alloc, "C:\\private", "other", "abc");
    defer alloc.free(other);
    try std.testing.expect(!std.mem.eql(u8, path, other));
}

// Fixtures never modify environment variables or call APIs with real app IDs.
// CREATE_NEW/CreateDirectory ownership and exact-name (nonrecursive) cleanup keep
// tests away from real profiles, even if a stale fixture already exists.
fn privateTestDirectory(alloc: Allocator) ![]u8 {
    var buffer: [32768]u16 = undefined;
    const length = GetTempPathW(buffer.len, &buffer);
    if (length == 0 or length >= buffer.len) return error.TestTempPathFailed;
    const temp = try std.unicode.utf16LeToUtf8Alloc(alloc, buffer[0..length]);
    defer alloc.free(temp);
    for (0..128) |_| {
        const path = try std.fmt.allocPrint(alloc, "{s}zilt-app-data-test-{d}-{d}", .{ temp, GetCurrentProcessId(), temp_sequence.fetchAdd(1, .monotonic) });
        errdefer alloc.free(path);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
        defer alloc.free(wide);
        if (win32.CreateDirectoryW(wide.ptr, null) != 0) return path;
        const code = win32.GetLastError();
        if (code != win32.ERROR_ALREADY_EXISTS) return error.TestDirectoryFailed;
        alloc.free(path);
    }
    return error.TestDirectoryCollision;
}

fn cleanupTestPath(alloc: Allocator, path: []const u8, directory: bool) void {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch @panic("fixture cleanup allocation failed");
    defer alloc.free(wide);
    const ok = if (directory) win32.RemoveDirectoryW(wide.ptr) else win32.DeleteFileW(wide.ptr);
    if (ok == 0 and !missing(win32.GetLastError())) @panic("private fixture cleanup failed");
}

test "isolated state IO: absent, replace, locked target and corruption" {
    const alloc = std.testing.allocator;
    const root = try privateTestDirectory(alloc);
    defer alloc.free(root);
    defer cleanupTestPath(alloc, root, true);
    const path = try join(alloc, root, "state.json");
    defer alloc.free(path);
    defer cleanupTestPath(alloc, path, false);
    try std.testing.expectEqual(@as(?State, null), try loadPath(alloc, path));
    const first: State = .{ .x = -80, .y = 20, .width = 600, .height = 400 };
    const second: State = .{ .x = 42, .y = -10, .width = 800, .height = 500, .maximized = true };
    const a = try serialize(alloc, first);
    defer alloc.free(a);
    const b = try serialize(alloc, second);
    defer alloc.free(b);
    try atomicWrite(alloc, path, a);
    try std.testing.expectEqualDeep(first, (try loadPath(alloc, path)).?);
    try atomicWrite(alloc, path, b);
    try std.testing.expectEqualDeep(second, (try loadPath(alloc, path)).?);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide);
    {
        const lock = win32.CreateFileW(wide.ptr, win32.GENERIC_READ, win32.FILE_SHARE_READ, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
        try std.testing.expect(lock != win32.INVALID_HANDLE_VALUE);
        defer _ = win32.CloseHandle(lock);
        try std.testing.expectError(error.StateReplaceFailed, atomicWrite(alloc, path, a));
        try std.testing.expectEqualDeep(second, (try loadPath(alloc, path)).?);
    }
    try atomicWrite(alloc, path, "{broken");
    try std.testing.expectError(error.InvalidState, loadPath(alloc, path));
    try atomicWrite(alloc, path, &(@as([max_json_bytes + 1]u8, @splat(' '))));
    try std.testing.expectError(error.InvalidState, loadPath(alloc, path));
    try atomicWrite(alloc, path, "");
    try std.testing.expectError(error.InvalidState, loadPath(alloc, path));
}

test "isolated migration: consume once, preserve existing target, report in-use" {
    const alloc = std.testing.allocator;
    const root = try privateTestDirectory(alloc);
    defer alloc.free(root);
    defer cleanupTestPath(alloc, root, true);
    const legacy = try join(alloc, root, "legacy");
    defer alloc.free(legacy);
    defer cleanupTestPath(alloc, legacy, true);
    const target = try join(alloc, root, "first-app");
    defer alloc.free(target);
    defer cleanupTestPath(alloc, target, true);
    const other = try join(alloc, root, "second-app");
    defer alloc.free(other);
    defer cleanupTestPath(alloc, other, true);
    const marker = try join(alloc, legacy, "marker.json");
    defer alloc.free(marker);
    defer cleanupTestPath(alloc, marker, false);
    const moved_marker = try join(alloc, target, "marker.json");
    defer alloc.free(moved_marker);
    defer cleanupTestPath(alloc, moved_marker, false);
    const state: State = .{ .x = 1, .y = 2, .width = 3, .height = 4 };
    const bytes = try serialize(alloc, state);
    defer alloc.free(bytes);
    try ensureDirectory(alloc, legacy);
    try atomicWrite(alloc, marker, bytes);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, legacy);
    defer alloc.free(wide);
    {
        const lock = win32.CreateFileW(wide.ptr, win32.GENERIC_READ, win32.FILE_SHARE_READ, null, win32.OPEN_EXISTING, 0x02000000, null); // FILE_FLAG_BACKUP_SEMANTICS
        try std.testing.expect(lock != win32.INVALID_HANDLE_VALUE);
        defer _ = win32.CloseHandle(lock);
        try std.testing.expectError(error.MigrationInUse, migrateDirectory(alloc, legacy, target));
        try std.testing.expect(!try directoryExists(alloc, target));
    }
    try migrateDirectory(alloc, legacy, target);
    try std.testing.expect(!try directoryExists(alloc, legacy));
    try std.testing.expectEqualDeep(state, (try loadPath(alloc, moved_marker)).?);
    try migrateDirectory(alloc, legacy, other);
    try std.testing.expect(!try directoryExists(alloc, other)); // Never copied to a second app.
    try ensureDirectory(alloc, legacy);
    try atomicWrite(alloc, marker, "legacy must remain untouched");
    try migrateDirectory(alloc, legacy, target);
    try std.testing.expect(try directoryExists(alloc, legacy));
    try std.testing.expectEqualDeep(state, (try loadPath(alloc, moved_marker)).?);
    // A file at the destination must not be mistaken for an absent profile.
    try atomicWrite(alloc, other, "not a directory");
    defer cleanupTestPath(alloc, other, false);
    try std.testing.expectError(error.NotDirectory, migrateDirectory(alloc, legacy, other));
}

test "public APIs reject invalid app IDs before filesystem access" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidAppId, profileDirectory(alloc, "../bad", true));
    try std.testing.expectError(error.InvalidAppId, save(alloc, "NUL", "main", .{ .x = 0, .y = 0, .width = 1, .height = 1 }));
    try std.testing.expectError(error.InvalidAppId, load(alloc, "..", "main"));
}
