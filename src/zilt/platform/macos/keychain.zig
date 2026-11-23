//! v0.5.6 macOS 钥匙串加密 store（Security.framework + CoreFoundation，
//! std.DynLib dlopen 可选依赖——与 Linux libsecret.zig 同源；缺失只降级不阻断）。
//!
//! 与 Linux libsecret 的对应关系：
//!   * libsecret：值存 GNOME Keyring，store.json 落 `secret:` 标记；
//!   * Keychain：值存 macOS 钥匙串（kSecClassGenericPassword），store.json 同样落
//!     `secret:` 标记——会话外/无钥匙串读取返回 KeyringUnavailable（文档化）。
//! 属性映射：kSecAttrService=<app_id>，kSecAttrAccount=<key>（libsecret 的
//! zilt-app/zilt-key 属性对同构）。upsert = 先 SecItemDelete 再 SecItemAdd。
//!
//! 宿主可编译：std.DynLib.open 在 Windows 为 @compileError，故 dlopen/符号解析
//! 全部置于 comptime macOS 守卫内（open() 非 macOS 直接 null）；纯逻辑单测可在
//! 任意宿主跑，FFI 往返在 CI macos-15 真跑（钥匙串拒绝则 SKIP）。

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// store.json 标记（与 Linux libsecret 同形态）。
pub const marker = "secret:";

// Security.framework OSStatus 常量（SecBase.h）。
pub const errSecSuccess: i32 = 0;
pub const errSecItemNotFound: i32 = -25300;
pub const errSecDuplicateItem: i32 = -25299;

/// 纯逻辑：OSStatus 是否成功（宿主可单测；守卫魔数）。
pub fn succeeded(status: i32) bool {
    return status == errSecSuccess;
}

// ---------------------------------------------------------------------------
// CoreFoundation / Security FFI（CFTypeRef 系列均为不透明指针）
// ---------------------------------------------------------------------------
const CFRef = *const anyopaque;
const kCFStringEncodingUTF8: u32 = 0x08000100;

const CFStringCreateWithBytesFn = *const fn (?CFRef, ?[*]const u8, c_long, u32, u8) callconv(.c) ?CFRef;
const CFDataCreateFn = *const fn (?CFRef, ?[*]const u8, c_long) callconv(.c) ?CFRef;
const CFDataGetBytePtrFn = *const fn (?CFRef) callconv(.c) ?[*]const u8;
const CFDataGetLengthFn = *const fn (?CFRef) callconv(.c) c_long;
const CFDictionaryCreateFn = *const fn (?CFRef, [*]const CFRef, [*]const CFRef, c_long, ?*const anyopaque, ?*const anyopaque) callconv(.c) ?CFRef;
const CFReleaseFn = *const fn (?CFRef) callconv(.c) void;
const SecItemAddFn = *const fn (?CFRef, ?*?CFRef) callconv(.c) i32;
const SecItemCopyMatchingFn = *const fn (?CFRef, ?*?CFRef) callconv(.c) i32;
const SecItemDeleteFn = *const fn (?CFRef) callconv(.c) i32;

pub const KeychainLib = struct {
    sec: std.DynLib,
    cf: std.DynLib,
    str_create: CFStringCreateWithBytesFn,
    data_create: CFDataCreateFn,
    data_ptr: CFDataGetBytePtrFn,
    data_len: CFDataGetLengthFn,
    dict_create: CFDictionaryCreateFn,
    release: CFReleaseFn,
    item_add: SecItemAddFn,
    item_copy: SecItemCopyMatchingFn,
    item_delete: SecItemDeleteFn,
    key_cb: *const anyopaque,
    val_cb: *const anyopaque,
    k_class: CFRef,
    k_class_generic: CFRef,
    k_service: CFRef,
    k_account: CFRef,
    k_value_data: CFRef,
    k_return_data: CFRef,
    k_match_limit: CFRef,
    k_match_limit_one: CFRef,
    k_true: CFRef,
};

/// dlopen Security + CoreFoundation（缺失 → null，调用方降级明文并记日志）。
/// 非 macOS 宿主直接 null（不触碰 std.DynLib.open——其在 Windows 为 compileError）。
pub fn open() ?KeychainLib {
    if (builtin.os.tag == .macos) return openImpl() catch null;
    return null;
}

fn openImpl() !KeychainLib {
    var sec = std.DynLib.open("/System/Library/Frameworks/Security.framework/Security") catch return error.SecurityUnavailable;
    errdefer sec.close();
    var cf = std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation") catch return error.CoreFoundationUnavailable;
    errdefer cf.close();

    const str_create = cf.lookup(CFStringCreateWithBytesFn, "CFStringCreateWithBytes") orelse return error.SymbolMissing;
    const data_create = cf.lookup(CFDataCreateFn, "CFDataCreate") orelse return error.SymbolMissing;
    const data_ptr = cf.lookup(CFDataGetBytePtrFn, "CFDataGetBytePtr") orelse return error.SymbolMissing;
    const data_len = cf.lookup(CFDataGetLengthFn, "CFDataGetLength") orelse return error.SymbolMissing;
    const dict_create = cf.lookup(CFDictionaryCreateFn, "CFDictionaryCreate") orelse return error.SymbolMissing;
    const release = cf.lookup(CFReleaseFn, "CFRelease") orelse return error.SymbolMissing;
    const item_add = sec.lookup(SecItemAddFn, "SecItemAdd") orelse return error.SymbolMissing;
    const item_copy = sec.lookup(SecItemCopyMatchingFn, "SecItemCopyMatching") orelse return error.SymbolMissing;
    const item_delete = sec.lookup(SecItemDeleteFn, "SecItemDelete") orelse return error.SymbolMissing;
    const key_cb = cf.lookup(*const anyopaque, "kCFTypeDictionaryKeyCallBacks") orelse return error.SymbolMissing;
    const val_cb = cf.lookup(*const anyopaque, "kCFTypeDictionaryValueCallBacks") orelse return error.SymbolMissing;

    // kSec* / kCFBooleanTrue 是 CFStringRef/CFBooleanRef 全局变量——dlsym 取地址后解引用。
    const k_class = (sec.lookup(*const CFRef, "kSecClass") orelse return error.SymbolMissing).*;
    const k_class_generic = (sec.lookup(*const CFRef, "kSecClassGenericPassword") orelse return error.SymbolMissing).*;
    const k_service = (sec.lookup(*const CFRef, "kSecAttrService") orelse return error.SymbolMissing).*;
    const k_account = (sec.lookup(*const CFRef, "kSecAttrAccount") orelse return error.SymbolMissing).*;
    const k_value_data = (sec.lookup(*const CFRef, "kSecValueData") orelse return error.SymbolMissing).*;
    const k_return_data = (sec.lookup(*const CFRef, "kSecReturnData") orelse return error.SymbolMissing).*;
    const k_match_limit = (sec.lookup(*const CFRef, "kSecMatchLimit") orelse return error.SymbolMissing).*;
    const k_match_limit_one = (sec.lookup(*const CFRef, "kSecMatchLimitOne") orelse return error.SymbolMissing).*;
    const k_true = (cf.lookup(*const CFRef, "kCFBooleanTrue") orelse return error.SymbolMissing).*;

    return .{
        .sec = sec,
        .cf = cf,
        .str_create = str_create,
        .data_create = data_create,
        .data_ptr = data_ptr,
        .data_len = data_len,
        .dict_create = dict_create,
        .release = release,
        .item_add = item_add,
        .item_copy = item_copy,
        .item_delete = item_delete,
        .key_cb = key_cb,
        .val_cb = val_cb,
        .k_class = k_class,
        .k_class_generic = k_class_generic,
        .k_service = k_service,
        .k_account = k_account,
        .k_value_data = k_value_data,
        .k_return_data = k_return_data,
        .k_match_limit = k_match_limit,
        .k_match_limit_one = k_match_limit_one,
        .k_true = k_true,
    };
}

/// 释放 dlopen 句柄（进程生命周期持有；测试用）。
pub fn close(lib: *KeychainLib) void {
    if (builtin.os.tag == .macos) {
        lib.sec.close();
        lib.cf.close();
    }
}

/// 值写入钥匙串（upsert：先删后加，覆盖同 service/account 旧值）。
pub fn storeValue(lib: *const KeychainLib, app_id: []const u8, key: []const u8, secret: []const u8) !void {
    const service = lib.str_create(null, app_id.ptr, @intCast(app_id.len), kCFStringEncodingUTF8, 0) orelse return error.KeychainStringFailed;
    defer lib.release(service);
    const account = lib.str_create(null, key.ptr, @intCast(key.len), kCFStringEncodingUTF8, 0) orelse return error.KeychainStringFailed;
    defer lib.release(account);
    const data = lib.data_create(null, secret.ptr, @intCast(secret.len)) orelse return error.KeychainDataFailed;
    defer lib.release(data);

    const del_keys = [_]CFRef{ lib.k_class, lib.k_service, lib.k_account };
    const del_vals = [_]CFRef{ lib.k_class_generic, service, account };
    const del_q = lib.dict_create(null, &del_keys, &del_vals, 3, lib.key_cb, lib.val_cb) orelse return error.KeychainDictFailed;
    defer lib.release(del_q);
    _ = lib.item_delete(del_q); // 不存在亦合法（upsert）

    const add_keys = [_]CFRef{ lib.k_class, lib.k_service, lib.k_account, lib.k_value_data };
    const add_vals = [_]CFRef{ lib.k_class_generic, service, account, data };
    const add_attrs = lib.dict_create(null, &add_keys, &add_vals, 4, lib.key_cb, lib.val_cb) orelse return error.KeychainDictFailed;
    defer lib.release(add_attrs);
    if (!succeeded(lib.item_add(add_attrs, null))) return error.KeychainStoreFailed;
}

/// 读钥匙串（缺 → null）。返回值为 alloc 拷贝（CFData 经 CFRelease 释放）。
pub fn lookupValue(lib: *const KeychainLib, alloc: Allocator, app_id: []const u8, key: []const u8) ?[]u8 {
    const service = lib.str_create(null, app_id.ptr, @intCast(app_id.len), kCFStringEncodingUTF8, 0) orelse return null;
    defer lib.release(service);
    const account = lib.str_create(null, key.ptr, @intCast(key.len), kCFStringEncodingUTF8, 0) orelse return null;
    defer lib.release(account);

    const keys = [_]CFRef{ lib.k_class, lib.k_service, lib.k_account, lib.k_return_data, lib.k_match_limit };
    const vals = [_]CFRef{ lib.k_class_generic, service, account, lib.k_true, lib.k_match_limit_one };
    const query = lib.dict_create(null, &keys, &vals, 5, lib.key_cb, lib.val_cb) orelse return null;
    defer lib.release(query);

    var result: ?CFRef = null;
    if (!succeeded(lib.item_copy(query, &result))) return null;
    const data = result orelse return null;
    defer lib.release(data);
    const ptr = lib.data_ptr(data) orelse return null;
    const len = lib.data_len(data);
    if (len < 0) return null;
    return alloc.dupe(u8, ptr[0..@intCast(len)]) catch null;
}

/// 删除钥匙串项（成功 → true）。
pub fn deleteValue(lib: *const KeychainLib, app_id: []const u8, key: []const u8) bool {
    const service = lib.str_create(null, app_id.ptr, @intCast(app_id.len), kCFStringEncodingUTF8, 0) orelse return false;
    defer lib.release(service);
    const account = lib.str_create(null, key.ptr, @intCast(key.len), kCFStringEncodingUTF8, 0) orelse return false;
    defer lib.release(account);
    const keys = [_]CFRef{ lib.k_class, lib.k_service, lib.k_account };
    const vals = [_]CFRef{ lib.k_class_generic, service, account };
    const query = lib.dict_create(null, &keys, &vals, 3, lib.key_cb, lib.val_cb) orelse return false;
    defer lib.release(query);
    return succeeded(lib.item_delete(query));
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
const testing = std.testing;

test "v0.5.6: Keychain OSStatus 判定（纯逻辑，守卫魔数）" {
    try testing.expectEqual(@as(i32, 0), errSecSuccess);
    try testing.expectEqual(@as(i32, -25300), errSecItemNotFound);
    try testing.expectEqual(@as(i32, -25299), errSecDuplicateItem);
    try testing.expect(succeeded(errSecSuccess));
    try testing.expect(!succeeded(errSecItemNotFound));
    try testing.expect(!succeeded(errSecDuplicateItem));
    try testing.expect(!succeeded(-1));
}

test "v0.5.6: marker 与 Linux secret: 同形态" {
    try testing.expectEqualStrings("secret:", marker);
}

test "v0.5.6: open 缺失→null（不崩）；存在→符号齐备" {
    if (open()) |lib| {
        var l = lib;
        defer close(&l);
        try testing.expect(@intFromPtr(lib.str_create) != 0);
        try testing.expect(@intFromPtr(lib.item_add) != 0);
        try testing.expect(@intFromPtr(lib.item_copy) != 0);
        try testing.expect(@intFromPtr(lib.k_class) != 0);
    }
}

test "v0.5.6: store/lookup/delete 往返（CI macos-15 真钥匙串；拒绝则 SKIP）" {
    var lib = open() orelse return error.SkipZigTest;
    defer close(&lib);
    const app = "app.zilt.selftest";
    const key = "zilt-selftest-keychain";
    _ = deleteValue(&lib, app, key);
    storeValue(&lib, app, key, "hello-keychain") catch |err| {
        std.debug.print("[keychain] store unavailable ({s}) — SKIP\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    const got = lookupValue(&lib, testing.allocator, app, key) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello-keychain", got);
    // upsert 覆盖
    try storeValue(&lib, app, key, "second-value");
    const got2 = lookupValue(&lib, testing.allocator, app, key) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(got2);
    try testing.expectEqualStrings("second-value", got2);
    // 删除后读不到
    try testing.expect(deleteValue(&lib, app, key));
    try testing.expect(lookupValue(&lib, testing.allocator, app, key) == null);
}