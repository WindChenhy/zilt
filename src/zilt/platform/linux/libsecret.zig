//! v0.4.2 H3：Linux 密钥环加密 store（libsecret-1 dlopen 可选依赖——
//! libayatana/libsqlite3 的 dlopen 模式同源；缺失只降级不阻断）。
//!
//! 与 Windows DPAPI 的对应关系：
//!   * DPAPI：值加密后落盘（`dpapi:` 前缀）——离线可解密（同用户）；
//!   * libsecret：值存 GNOME Keyring，store.json 只落 `secret:` 标记——
//!     桌面会话外/无 keyring 读取返回 KeyringUnavailable（更强，文档化）。
//! 属性对（zilt-key=<key>, zilt-app=<app_id>），schema 传 NULL（ad-hoc）。
//! store 为 C varargs：经 11 参函数指针调用（属性对 1 组 + NULL 终结——
//! x86-64 C ABI 下对 varargs 被调方等价）。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SecretLib = struct {
    lib: std.DynLib,
    store_fn: StoreFn,
    lookup_fn: LookupFn,
    free_fn: FreeFn,

    /// secret_password_store_sync(schema, collection, label, password,
    ///   cancellable, &err, attr_type, attr_value, app_type, app_value, NULL)
    pub const StoreFn = *const fn (
        schema: ?*const anyopaque,
        collection: ?[*:0]const u8,
        label: ?[*:0]const u8,
        password: ?[*:0]const u8,
        cancellable: ?*anyopaque,
        err: ?*?*anyopaque,
        attr_type: [*:0]const u8,
        attr_value: [*:0]const u8,
        app_type: [*:0]const u8,
        app_value: [*:0]const u8,
        terminator: ?*const anyopaque,
    ) callconv(.c) c_int;

    /// secret_password_lookup_sync(schema, collection, cancellable, &err,
    ///   attr_type, attr_value)
    pub const LookupFn = *const fn (
        schema: ?*const anyopaque,
        collection: ?[*:0]const u8,
        cancellable: ?*anyopaque,
        err: ?*?*anyopaque,
        attr_type: [*:0]const u8,
        attr_value: [*:0]const u8,
    ) callconv(.c) ?[*:0]const u8;

    pub const FreeFn = *const fn (?[*:0]const u8) callconv(.c) void;
};

/// dlopen libsecret-1.so.0 + 符号查找（缺失 → null，调用方降级明文并记日志）。
pub fn open() ?SecretLib {
    var lib = std.DynLib.open("libsecret-1.so.0") catch return null;
    const store = lib.lookup(SecretLib.StoreFn, "secret_password_store_sync") orelse {
        lib.close();
        return null;
    };
    const lookup = lib.lookup(SecretLib.LookupFn, "secret_password_lookup_sync") orelse {
        lib.close();
        return null;
    };
    const free = lib.lookup(SecretLib.FreeFn, "secret_password_free") orelse {
        lib.close();
        return null;
    };
    return .{ .lib = lib, .store_fn = store, .lookup_fn = lookup, .free_fn = free };
}

/// 值写入密钥环（覆盖同 attr 对旧值；alloc 仅作调用期哨兵串）。
pub fn storeValue(
    lib: *const SecretLib,
    alloc: Allocator,
    app_id: []const u8,
    key: []const u8,
    secret: []const u8,
) !void {
    const app_z = try alloc.allocSentinel(u8, app_id.len, 0);
    defer alloc.free(app_z);
    @memcpy(app_z[0..app_id.len], app_id);
    const key_z = try alloc.allocSentinel(u8, key.len, 0);
    defer alloc.free(key_z);
    @memcpy(key_z[0..key.len], key);
    const label = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ app_id, key }, 0);
    defer alloc.free(label);
    const secret_z = try alloc.allocSentinel(u8, secret.len, 0);
    defer alloc.free(secret_z);
    @memcpy(secret_z[0..secret.len], secret);
    var gerr: ?*anyopaque = null;
    const rc = lib.store_fn(
        null,
        null,
        label.ptr,
        secret_z.ptr,
        null,
        @ptrCast(&gerr),
        "zilt-key",
        key_z.ptr,
        "zilt-app",
        app_z.ptr,
        null,
    );
    if (rc == 0) return error.StoreFailed;
}

/// 读密钥环（缺 → null）。返回值为 alloc 拷贝（libsecret 原串经
/// secret_password_free 释放）。
pub fn lookupValue(lib: *const SecretLib, alloc: Allocator, key: []const u8) ?[]u8 {
    const key_z = alloc.allocSentinel(u8, key.len, 0) catch return null;
    defer alloc.free(key_z);
    @memcpy(key_z[0..key.len], key);
    var gerr: ?*anyopaque = null;
    const raw = lib.lookup_fn(null, null, null, @ptrCast(&gerr), "zilt-key", key_z.ptr) orelse return null;
    defer lib.free_fn(raw);
    return alloc.dupe(u8, std.mem.span(raw)) catch null;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "open: dlopen 缺失 → null（不崩）；存在 → 符号齐备" {
    // 真实环境：libsecret 存在 → SecretLib；不存在 → null。两者都合法。
    if (open()) |lib| {
        try testing.expect(@intFromPtr(lib.store_fn) != 0);
        try testing.expect(@intFromPtr(lib.lookup_fn) != 0);
        try testing.expect(@intFromPtr(lib.free_fn) != 0);
    }
}

test "store/lookup 往返（libsecret + 会话总线存在时；CI 无 keyring → SKIP）" {
    var lib_opt = open();
    if (lib_opt == null) return error.SkipZigTest;
    const lib = &lib_opt.?;
    const pre = lookupValue(lib, testing.allocator, "zilt-selftest-pre");
    if (pre) |v| testing.allocator.free(v);
    try storeValue(lib, testing.allocator, "app.zilt.selftest", "zilt-selftest-pre", "hello-keyring");
    const got = lookupValue(lib, testing.allocator, "zilt-selftest-pre");
    try testing.expect(got != null);
    try testing.expectEqualStrings("hello-keyring", got.?);
    testing.allocator.free(got.?);
}
