//! macOS ObjC 运行时最小封装（v0.4.4）。
//!
//! 不用 `@cImport`：Zig 不带 ObjC 头，且 Zilt 的平台层统一走「extern + 动态消息」。
//! 类名/selector 是运行时字符串 → 非 macOS 宿主交叉编译只需 libobjc 的几个 C 符号
//! （见 `stubs/libobjc.tbd`），框架本身不需要符号。
const std = @import("std");

pub const Id = *anyopaque;
pub const Sel = *anyopaque;
pub const Class = *anyopaque;
pub const Protocol = *anyopaque;

pub extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
pub extern "c" fn sel_registerName(name: [*:0]const u8) ?Sel;
pub extern "c" fn objc_msgSend() void;
pub extern "c" fn objc_msgSend_stret() void;
pub extern "c" fn objc_allocateClassPair(super: ?Class, name: [*:0]const u8, extra: usize) ?Class;
pub extern "c" fn objc_registerClassPair(cls: Class) void;
pub extern "c" fn class_addMethod(cls: Class, name: Sel, imp: ?*const anyopaque, types: [*:0]const u8) bool;
pub extern "c" fn class_addProtocol(cls: Class, proto: ?Protocol) bool;
pub extern "c" fn objc_getProtocol(name: [*:0]const u8) ?Protocol;
/// v0.4.5 基建：手动 autorelease pool（libobjc 导出的 C 函数）
pub extern "c" fn objc_autoreleasePoolPush() Id;
pub extern "c" fn objc_autoreleasePoolPop(pool: Id) void;

pub fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name) orelse @panic("sel_registerName returned null");
}

/// 按调用签名转型 objc_msgSend。签名必须与真实 ABI 一致（arm64）。
pub inline fn msgSend(comptime Sig: type) Sig {
    return @ptrCast(&objc_msgSend);
}

/// 返回大于 16 字节 struct 的消息在 x86_64 上走 stret（arm64 仍用 msgSend）。
/// 签名形如 `*const fn (*T, Id, Sel) callconv(.c) void`，首个参数是返回值存储。
pub inline fn msgSendStret(comptime Sig: type) Sig {
    return @ptrCast(&objc_msgSend_stret);
}

pub fn cls(name: [*:0]const u8) Class {
    return objc_getClass(name) orelse @panic("ObjC class missing");
}

/// `[[NSString alloc] initWithBytes:len encoding:NSUTF8StringEncoding]`
pub fn nsString(ptr: [*]const u8, len: usize) Id {
    const raw = msgSend(*const fn (Class, Sel) callconv(.c) Id)(cls("NSString"), sel("alloc"));
    return msgSend(*const fn (Id, Sel, [*]const u8, c_ulong, c_ulong) callconv(.c) Id)(
        raw,
        sel("initWithBytes:length:encoding:"),
        ptr,
        @intCast(len),
        4, // NSUTF8StringEncoding
    );
}

pub fn nsStringZ(z: [*:0]const u8) Id {
    const s = std.mem.span(z);
    return nsString(s.ptr, s.len);
}

pub fn nsData(ptr: [*]const u8, len: usize) Id {
    return msgSend(*const fn (Class, Sel, [*]const u8, c_ulong) callconv(.c) Id)(
        cls("NSData"),
        sel("dataWithBytes:length:"),
        ptr,
        @intCast(len),
    );
}

/// NSObject → JSON（NSJSONSerialization）。失败（NaN/非 JSON 类型）返回 null。
pub fn jsonFromId(alloc: std.mem.Allocator, obj: Id) ?[]u8 {
    var err: ?Id = null;
    const data = msgSend(*const fn (Class, Sel, Id, c_ulong, *?Id) callconv(.c) ?Id)(
        cls("NSJSONSerialization"),
        sel("dataWithJSONObject:options:error:"),
        obj,
        0,
        &err,
    ) orelse return null;
    const bytes = msgSend(*const fn (Id, Sel) callconv(.c) [*]const u8)(data, sel("bytes"));
    const len: c_ulong = msgSend(*const fn (Id, Sel) callconv(.c) c_ulong)(data, sel("length"));
    return alloc.dupe(u8, bytes[0..@intCast(len)]) catch null;
}

pub const Method = struct {
    name: [*:0]const u8,
    imp: *const anyopaque,
    /// ObjC type encoding，如 "v@:@@"（void, self, _cmd, id, id）
    types: [*:0]const u8,
};

/// 运行时创建 NSObject 子类（+ 可选协议），供 WKURLSchemeHandler /
/// WKScriptMessageHandler 等「必须有 ObjC 对象」的 API 使用。
pub fn defineClass(
    name: [*:0]const u8,
    proto_name: ?[*:0]const u8,
    methods: []const Method,
) ?Class {
    const super = objc_getClass("NSObject") orelse return null;
    const c = objc_allocateClassPair(super, name, 0) orelse return null;
    if (proto_name) |pn| {
        if (objc_getProtocol(pn)) |p| {
            _ = class_addProtocol(c, p);
        }
    }
    for (methods) |m| {
        if (!class_addMethod(c, sel_registerName(m.name) orelse return null, m.imp, m.types)) {
            return null;
        }
    }
    objc_registerClassPair(c);
    return c;
}

pub fn defineSubclass(
    name: [*:0]const u8,
    super_name: [*:0]const u8,
    proto_names: []const [*:0]const u8,
    methods: []const Method,
) ?Class {
    const super = objc_getClass(super_name) orelse return null;
    const c = objc_allocateClassPair(super, name, 0) orelse return null;
    for (proto_names) |pn| {
        if (objc_getProtocol(pn)) |p| {
            _ = class_addProtocol(c, p);
        }
    }
    for (methods) |m| {
        if (!class_addMethod(c, sel_registerName(m.name) orelse return null, m.imp, m.types)) {
            return null;
        }
    }
    objc_registerClassPair(c);
    return c;
}

pub fn allocInit(c: Class) Id {
    const raw = msgSend(*const fn (Class, Sel) callconv(.c) Id)(c, sel("alloc"));
    return msgSend(*const fn (Id, Sel) callconv(.c) Id)(raw, sel("init"));
}
