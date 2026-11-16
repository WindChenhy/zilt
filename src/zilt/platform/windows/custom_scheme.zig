//! 真 scheme 自定义协议（v0.3.2）：WebView2 侧的 COM 注册对象。
//!
//! ABI/IID 取自官方 NuGet 包 `Microsoft.Web.WebView2` 的 WebView2.h（1.0.x）：
//! - `ICoreWebView2CustomSchemeRegistration`
//!   IID `{d60ac92c-37a6-4b26-a39e-95cfe59047bb}`，vtable：
//!   QI/AddRef/Release + get_SchemeName + get/put_TreatAsSecure +
//!   GetAllowedOrigins/SetAllowedOrigins + get/put_HasAuthorityComponent（10 槽）。
//! - `ICoreWebView2EnvironmentOptions4`
//!   IID `{ac52d13f-0d38-475a-9dca-876580d6793e}`，vtable：
//!   QI/AddRef/Release + GetCustomSchemeRegistrations + SetCustomSchemeRegistrations（5 槽；
//!   注意 C 头文件里它直接派生自 IUnknown，**没有**继承 Options/2/3 的槽位）。
//!
//! 生命周期契约：`SetCustomSchemeRegistrations` 之后注册对象必须活过环境创建
//! （规范：「registrations are valid throughout the lifetime of the
//! CoreWebView2Environment and browser process」）。实现上 `Options4Part` 持有
//! 注册对象的引用，而 `Options4Part` 由 `EnvironmentOptions` 持有——运行时在环境
//! 创建完成前持有 options 对象的引用（与 proxy/language 选项同一保证），
//! 环境创建完成后运行时释放，part/registration 随之释放。
const std = @import("std");
const com = @import("com.zig");
const win32 = @import("win32.zig");
const protocol = @import("../../protocol.zig");

const E_OUTOFMEMORY: com.HRESULT = @bitCast(@as(u32, 0x8007000E));

extern "ole32" fn CoTaskMemAlloc(bytes: usize) callconv(.winapi) ?*anyopaque;

pub const IID_ICoreWebView2CustomSchemeRegistration: com.GUID =
    .parse("{d60ac92c-37a6-4b26-a39e-95cfe59047bb}");
pub const IID_ICoreWebView2EnvironmentOptions4: com.GUID =
    .parse("{ac52d13f-0d38-475a-9dca-876580d6793e}");

// ---------------------------------------------------------------------------
// ICoreWebView2CustomSchemeRegistration（应用侧实现）
// ---------------------------------------------------------------------------

/// 一个自定义 scheme 的注册对象。`create` 返回的对象引用计数为 1，归调用者；
/// 交给 `Options4Part` 时它会额外 AddRef 并负责最终释放。
pub const SchemeRegistration = extern struct {
    lpVtbl: *const VTable = &vtable,
    refs: u32 = 1,
    allocator_context: *anyopaque,
    allocator_vtable: *const std.mem.Allocator.VTable,
    /// UTF-16 scheme 名（create 时从 UTF-8 转换，生命周期 = 对象本身）
    scheme_name: [*:0]u16,
    treat_as_secure: win32.BOOL = 1,
    // v0.3.2：true = tuple origin（`echo://a/b` 的 origin 是 `echo://a`）。
    // 实测矩阵：false 会导致 iframe 导航 `echo://a/b` 直接崩溃浏览器进程
    // （URL 形态与 no-authority scheme 不兼容）；true 时 iframe 导航正常。
    has_authority_component: win32.BOOL = 1,
    /// UTF-16 允许来源列表（如 "https://zilt.app"；extern struct → ptr+len）
    allowed_origins_ptr: [*]?[*:0]u16 = undefined,
    allowed_origins_len: usize = 0,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*SchemeRegistration, *const com.GUID, ?*?*anyopaque) callconv(.winapi) com.HRESULT,
        AddRef: *const fn (*SchemeRegistration) callconv(.winapi) u32,
        Release: *const fn (*SchemeRegistration) callconv(.winapi) u32,
        get_SchemeName: *const fn (*SchemeRegistration, ?*?[*:0]u16) callconv(.winapi) com.HRESULT,
        get_TreatAsSecure: *const fn (*SchemeRegistration, ?*win32.BOOL) callconv(.winapi) com.HRESULT,
        put_TreatAsSecure: *const fn (*SchemeRegistration, win32.BOOL) callconv(.winapi) com.HRESULT,
        GetAllowedOrigins: *const fn (*SchemeRegistration, ?*win32.UINT, ?*?[*]?[*:0]u16) callconv(.winapi) com.HRESULT,
        SetAllowedOrigins: *const fn (*SchemeRegistration, win32.UINT, ?[*]const ?[*:0]const u16) callconv(.winapi) com.HRESULT,
        get_HasAuthorityComponent: *const fn (*SchemeRegistration, ?*win32.BOOL) callconv(.winapi) com.HRESULT,
        put_HasAuthorityComponent: *const fn (*SchemeRegistration, win32.BOOL) callconv(.winapi) com.HRESULT,
    };

    const vtable: VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .get_SchemeName = getSchemeName,
        .get_TreatAsSecure = getSecure,
        .put_TreatAsSecure = putSecure,
        .GetAllowedOrigins = getAllowedOrigins,
        .SetAllowedOrigins = setAllowedOrigins,
        .get_HasAuthorityComponent = getAuthority,
        .put_HasAuthorityComponent = putAuthority,
    };

    pub fn create(alloc: std.mem.Allocator, scheme_name: []const u8, allowed_origins: []const []const u8) !*SchemeRegistration {
        if (!protocol.validName(scheme_name)) return error.InvalidSchemeName;
        for (allowed_origins) |o| {
            if (o.len == 0) return error.InvalidAllowedOrigin;
        }
        const self = try alloc.create(SchemeRegistration);
        errdefer alloc.destroy(self);
        self.* = .{
            .allocator_context = alloc.ptr,
            .allocator_vtable = alloc.vtable,
            .scheme_name = (try std.unicode.utf8ToUtf16LeAllocZ(alloc, scheme_name)).ptr,
        };
        if (allowed_origins.len > 0) {
            const list = try alloc.alloc(?[*:0]u16, allowed_origins.len);
            var count: usize = 0;
            errdefer {
                for (list[0..count]) |item| if (item) |p| alloc.free(std.mem.span(p));
                alloc.free(list);
            }
            for (allowed_origins, 0..) |o, i| {
                list[i] = (try std.unicode.utf8ToUtf16LeAllocZ(alloc, o)).ptr;
                count = i + 1;
            }
            self.allowed_origins_ptr = list.ptr;
            self.allowed_origins_len = list.len;
        }
        return self;
    }

    pub fn dropRef(self: *SchemeRegistration) void {
        _ = self.lpVtbl.Release(self);
    }

    fn allocator(self: *SchemeRegistration) std.mem.Allocator {
        return .{ .ptr = self.allocator_context, .vtable = self.allocator_vtable };
    }

    fn queryInterface(self: *SchemeRegistration, iid: *const com.GUID, out: ?*?*anyopaque) callconv(.winapi) com.HRESULT {
        const result = out orelse return com.E_POINTER;
        result.* = null;
        if (!iid.eql(com.IID_IUnknown) and !iid.eql(IID_ICoreWebView2CustomSchemeRegistration)) return com.E_NOINTERFACE;
        result.* = self;
        _ = addRef(self);
        return com.S_OK;
    }
    fn addRef(self: *SchemeRegistration) callconv(.winapi) u32 {
        return @atomicRmw(u32, &self.refs, .Add, 1, .monotonic) + 1;
    }
    fn release(self: *SchemeRegistration) callconv(.winapi) u32 {
        const previous = @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel);
        if (previous == 1) {
            const alloc = self.allocator();
            for (self.allowed_origins_ptr[0..self.allowed_origins_len]) |item| if (item) |p| alloc.free(std.mem.span(p));
            if (self.allowed_origins_len > 0) alloc.free(self.allowed_origins_ptr[0..self.allowed_origins_len]);
            alloc.free(std.mem.span(self.scheme_name));
            alloc.destroy(self);
        }
        return previous - 1;
    }
    fn getSchemeName(self: *SchemeRegistration, out: ?*?[*:0]u16) callconv(.winapi) com.HRESULT {
        const result = out orelse return com.E_POINTER;
        result.* = copyUtf16(self.scheme_name) orelse return E_OUTOFMEMORY;
        return com.S_OK;
    }
    fn getSecure(self: *SchemeRegistration, out: ?*win32.BOOL) callconv(.winapi) com.HRESULT {
        (out orelse return com.E_POINTER).* = self.treat_as_secure;
        return com.S_OK;
    }
    fn putSecure(self: *SchemeRegistration, value: win32.BOOL) callconv(.winapi) com.HRESULT {
        self.treat_as_secure = value;
        return com.S_OK;
    }
    fn getAuthority(self: *SchemeRegistration, out: ?*win32.BOOL) callconv(.winapi) com.HRESULT {
        (out orelse return com.E_POINTER).* = self.has_authority_component;
        return com.S_OK;
    }
    fn putAuthority(self: *SchemeRegistration, value: win32.BOOL) callconv(.winapi) com.HRESULT {
        self.has_authority_component = value;
        return com.S_OK;
    }
    fn getAllowedOrigins(self: *SchemeRegistration, count_out: ?*win32.UINT, origins_out: ?*?[*]?[*:0]u16) callconv(.winapi) com.HRESULT {
        const count_ptr = count_out orelse return com.E_POINTER;
        const origins_ptr = origins_out orelse return com.E_POINTER;
        count_ptr.* = 0;
        origins_ptr.* = null;
        if (self.allowed_origins_len == 0) return com.S_OK;
        const bytes = std.math.mul(usize, self.allowed_origins_len, @sizeOf(?[*:0]u16)) catch return E_OUTOFMEMORY;
        const block: [*]?[*:0]u16 = @ptrCast(@alignCast(CoTaskMemAlloc(bytes) orelse return E_OUTOFMEMORY));
        var written: usize = 0;
        errdefer {
            for (block[0..written]) |item| if (item) |p| win32.CoTaskMemFree(@ptrCast(p));
            win32.CoTaskMemFree(@ptrCast(block));
        }
        for (self.allowed_origins_ptr[0..self.allowed_origins_len]) |item| {
            const copy = copyUtf16(item.?) orelse return E_OUTOFMEMORY;
            block[written] = copy;
            written += 1;
        }
        count_ptr.* = @intCast(written);
        origins_ptr.* = block;
        return com.S_OK;
    }
    fn setAllowedOrigins(self: *SchemeRegistration, count: win32.UINT, origins: ?[*]const ?[*:0]const u16) callconv(.winapi) com.HRESULT {
        const alloc = self.allocator();
        // 先构造新列表（失败保留旧值），再替换并释放旧的
        const new_list = alloc.alloc(?[*:0]u16, count) catch return E_OUTOFMEMORY;
        var written: usize = 0;
        errdefer {
            for (new_list[0..written]) |item| if (item) |p| alloc.free(std.mem.span(p));
            alloc.free(new_list);
        }
        if (count > 0) {
            const src = origins orelse return com.E_POINTER;
            for (0..count) |i| {
                const item = src[i] orelse return com.E_POINTER;
                new_list[i] = (alloc.dupeSentinel(u16, std.mem.span(item), 0) catch return E_OUTOFMEMORY).ptr;
                written = i + 1;
            }
        }
        for (self.allowed_origins_ptr[0..self.allowed_origins_len]) |item| if (item) |p| alloc.free(std.mem.span(p));
        if (self.allowed_origins_len > 0) alloc.free(self.allowed_origins_ptr[0..self.allowed_origins_len]);
        self.allowed_origins_ptr = new_list.ptr;
        self.allowed_origins_len = new_list.len;
        return com.S_OK;
    }
};

/// CoTaskMem 分配的 UTF-16 拷贝（getter 语义：调用方 CoTaskMemFree）。
fn copyUtf16(src: [*:0]u16) ?[*:0]u16 {
    const len = std.mem.len(src);
    const bytes = std.math.mul(usize, len + 1, @sizeOf(u16)) catch return null;
    const copy: [*:0]u16 = @ptrCast(@alignCast(CoTaskMemAlloc(bytes) orelse return null));
    @memcpy(copy[0 .. len + 1], src[0 .. len + 1]);
    return copy;
}

// ---------------------------------------------------------------------------
// ICoreWebView2EnvironmentOptions4（EnvironmentOptions 的接口分片）
// ---------------------------------------------------------------------------

/// `EnvironmentOptions` 的 Options4 分片（WRL 式聚合语义）：part 不持有独立
/// 引用计数——QI/AddRef/Release 全部委托 owner（同一 COM 对象的调整指针），
/// 注册对象列表归 owner 所有（owner 释放时统一 dropRef）。这样 QI(Options4)
/// 返回 part、Release(part) 递减共享计数，与 WRL RuntimeClass 行为一致。
pub const Options4Part = extern struct {
    lpVtbl: *const VTable = &vtable,
    owner: *anyopaque, // *EnvironmentOptions（避免循环 import，经回调操作）
    owner_alloc_context: *anyopaque,
    owner_alloc_vtable: *const std.mem.Allocator.VTable,
    query_owner: *const fn (*anyopaque, *const com.GUID, ?*?*anyopaque) callconv(.winapi) com.HRESULT,
    add_ref_owner: *const fn (*anyopaque) callconv(.winapi) u32,
    release_owner: *const fn (*anyopaque) callconv(.winapi) u32,
    registrations_ptr: [*]*SchemeRegistration,
    registrations_len: usize,

    fn ownerAlloc(self: *Options4Part) std.mem.Allocator {
        return .{ .ptr = self.owner_alloc_context, .vtable = self.owner_alloc_vtable };
    }

    pub const VTable = extern struct {
        QueryInterface: *const fn (*Options4Part, *const com.GUID, ?*?*anyopaque) callconv(.winapi) com.HRESULT,
        AddRef: *const fn (*Options4Part) callconv(.winapi) u32,
        Release: *const fn (*Options4Part) callconv(.winapi) u32,
        GetCustomSchemeRegistrations: *const fn (*Options4Part, ?*win32.UINT, ?*?[*]?*SchemeRegistration) callconv(.winapi) com.HRESULT,
        SetCustomSchemeRegistrations: *const fn (*Options4Part, win32.UINT, ?[*]const ?*SchemeRegistration) callconv(.winapi) com.HRESULT,
    };

    const vtable: VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .GetCustomSchemeRegistrations = getRegistrations,
        .SetCustomSchemeRegistrations = setRegistrations,
    };

    /// `registrations` 的引用转给 owner 列表（不额外 AddRef）；为空列表时合法。
    /// 分片自身由 owner 分配/释放（owner 用同一 allocator）。
    pub fn create(
        alloc: std.mem.Allocator,
        owner: *anyopaque,
        query_owner: *const fn (*anyopaque, *const com.GUID, ?*?*anyopaque) callconv(.winapi) com.HRESULT,
        add_ref_owner: *const fn (*anyopaque) callconv(.winapi) u32,
        release_owner: *const fn (*anyopaque) callconv(.winapi) u32,
        registrations: []*SchemeRegistration,
    ) !*Options4Part {
        const self = try alloc.create(Options4Part);
        self.* = .{
            .owner = owner,
            .owner_alloc_context = alloc.ptr,
            .owner_alloc_vtable = alloc.vtable,
            .query_owner = query_owner,
            .add_ref_owner = add_ref_owner,
            .release_owner = release_owner,
            .registrations_ptr = registrations.ptr,
            .registrations_len = registrations.len,
        };
        return self;
    }

    fn queryInterface(self: *Options4Part, iid: *const com.GUID, out: ?*?*anyopaque) callconv(.winapi) com.HRESULT {
        return self.query_owner(self.owner, iid, out);
    }
    fn addRef(self: *Options4Part) callconv(.winapi) u32 {
        return self.add_ref_owner(self.owner);
    }
    fn release(self: *Options4Part) callconv(.winapi) u32 {
        return self.release_owner(self.owner);
    }
    fn getRegistrations(self: *Options4Part, count_out: ?*win32.UINT, regs_out: ?*?[*]?*SchemeRegistration) callconv(.winapi) com.HRESULT {
        const count_ptr = count_out orelse return com.E_POINTER;
        const regs_ptr = regs_out orelse return com.E_POINTER;
        count_ptr.* = 0;
        regs_ptr.* = null;
        if (self.registrations_len == 0) return com.S_OK;
        const bytes = std.math.mul(usize, self.registrations_len, @sizeOf(?*SchemeRegistration)) catch return E_OUTOFMEMORY;
        const block: [*]?*SchemeRegistration = @ptrCast(@alignCast(CoTaskMemAlloc(bytes) orelse return E_OUTOFMEMORY));
        var written: usize = 0;
        errdefer {
            for (block[0..written]) |item| if (item) |reg| reg.dropRef();
            win32.CoTaskMemFree(@ptrCast(block));
        }
        for (self.registrations_ptr[0..self.registrations_len]) |reg| {
            block[written] = reg;
            _ = reg.lpVtbl.AddRef(reg);
            written += 1;
        }
        count_ptr.* = @intCast(written);
        regs_ptr.* = block;
        return com.S_OK;
    }
    fn setRegistrations(self: *Options4Part, count: win32.UINT, regs: ?[*]const ?*SchemeRegistration) callconv(.winapi) com.HRESULT {
        const alloc = self.ownerAlloc();
        if (count == 0) {
            // 置空：释放旧列表与引用，不再分配（len=0 → 无块可还）
            for (self.registrations_ptr[0..self.registrations_len]) |reg| reg.dropRef();
            if (self.registrations_len > 0) alloc.free(self.registrations_ptr[0..self.registrations_len]);
            self.registrations_ptr = undefined;
            self.registrations_len = 0;
            return com.S_OK;
        }
        if (count > 0 and regs == null) return com.E_POINTER; // 先校验再分配（普通返回不走 errdefer）
        const new_list = alloc.alloc(*SchemeRegistration, count) catch return E_OUTOFMEMORY;
        var written: usize = 0;
        errdefer {
            for (new_list[0..written]) |reg| reg.dropRef();
            alloc.free(new_list);
        }
        if (count > 0) {
            const src = regs.?;
            for (0..count) |i| {
                const reg = src[i] orelse return com.E_POINTER;
                new_list[i] = reg;
                _ = reg.lpVtbl.AddRef(reg);
                written = i + 1;
            }
        }
        for (self.registrations_ptr[0..self.registrations_len]) |reg| reg.dropRef();
        if (self.registrations_len > 0) alloc.free(self.registrations_ptr[0..self.registrations_len]);
        self.registrations_ptr = new_list.ptr;
        self.registrations_len = new_list.len;
        return com.S_OK;
    }
};

const testing = std.testing;

test "v0.3.2: SchemeRegistration 属性往返 + getter 拷贝语义" {
    const alloc = testing.allocator;
    const reg = try SchemeRegistration.create(alloc, "media", &.{ "https://zilt.app", "https://other.example" });
    defer reg.dropRef();

    var name: ?[*:0]u16 = null;
    try testing.expectEqual(com.S_OK, reg.lpVtbl.get_SchemeName(reg, &name));
    try testing.expect(name != null);
    defer win32.CoTaskMemFree(@ptrCast(name.?));
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("media"), std.mem.span(name.?));

    var secure: win32.BOOL = 0;
    try testing.expectEqual(com.S_OK, reg.lpVtbl.get_TreatAsSecure(reg, &secure));
    try testing.expectEqual(@as(win32.BOOL, 1), secure);
    try testing.expectEqual(com.S_OK, reg.lpVtbl.put_TreatAsSecure(reg, 0));
    try testing.expectEqual(com.S_OK, reg.lpVtbl.get_TreatAsSecure(reg, &secure));
    try testing.expectEqual(@as(win32.BOOL, 0), secure);

    var authority: win32.BOOL = 0;
    try testing.expectEqual(com.S_OK, reg.lpVtbl.get_HasAuthorityComponent(reg, &authority));
    try testing.expectEqual(@as(win32.BOOL, 1), authority);

    var count: win32.UINT = 0;
    var origins: ?[*]?[*:0]u16 = null;
    try testing.expectEqual(com.S_OK, reg.lpVtbl.GetAllowedOrigins(reg, &count, &origins));
    try testing.expectEqual(@as(win32.UINT, 2), count);
    try testing.expect(origins != null);
    for (origins.?[0..count]) |item| if (item) |p| win32.CoTaskMemFree(@ptrCast(p));
    win32.CoTaskMemFree(@ptrCast(origins.?));

    // setter 换列表（数量变化），getter 再读
    const two = [_]?[*:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("https://a.test"),
        std.unicode.utf8ToUtf16LeStringLiteral("https://b.test"),
    };
    try testing.expectEqual(com.S_OK, reg.lpVtbl.SetAllowedOrigins(reg, 2, &two));
    try testing.expectEqual(com.S_OK, reg.lpVtbl.GetAllowedOrigins(reg, &count, &origins));
    try testing.expectEqual(@as(win32.UINT, 2), count);
    for (origins.?[0..count]) |item| if (item) |p| win32.CoTaskMemFree(@ptrCast(p));
    win32.CoTaskMemFree(@ptrCast(origins.?));
    // 置空
    try testing.expectEqual(com.S_OK, reg.lpVtbl.SetAllowedOrigins(reg, 0, null));
    try testing.expectEqual(com.S_OK, reg.lpVtbl.GetAllowedOrigins(reg, &count, &origins));
    try testing.expectEqual(@as(win32.UINT, 0), count);
    try testing.expect(origins == null);

    try testing.expectEqual(com.E_POINTER, reg.lpVtbl.get_SchemeName(reg, null));
    try testing.expectEqual(com.E_POINTER, reg.lpVtbl.GetAllowedOrigins(reg, null, &origins));
}

test "v0.3.2: SchemeRegistration QI / 引用计数 / 非法名拒绝" {
    const alloc = testing.allocator;
    const reg = try SchemeRegistration.create(alloc, "app", &.{}); // refs=1（caller 持有）
    var out: ?*anyopaque = reg;
    const bad: com.GUID = .{ .data1 = 0, .data2 = 0, .data3 = 0, .data4 = @splat(0) };
    try testing.expectEqual(com.E_NOINTERFACE, reg.lpVtbl.QueryInterface(reg, &bad, &out));
    try testing.expectEqual(com.S_OK, reg.lpVtbl.QueryInterface(reg, &IID_ICoreWebView2CustomSchemeRegistration, &out)); // refs=2
    try testing.expectEqual(@intFromPtr(reg), @intFromPtr(out.?));
    try testing.expectEqual(@as(u32, 1), reg.lpVtbl.Release(reg)); // 归还 QI 引用（refs=1）
    try testing.expectEqual(@as(u32, 2), reg.lpVtbl.AddRef(reg)); // refs=2
    try testing.expectEqual(@as(u32, 1), reg.lpVtbl.Release(reg)); // refs=1
    try testing.expectEqual(@as(u32, 0), reg.lpVtbl.Release(reg)); // refs=0 → destroy
    try testing.expectError(error.InvalidSchemeName, SchemeRegistration.create(alloc, "Bad_Name", &.{}));
    try testing.expectError(error.InvalidSchemeName, SchemeRegistration.create(alloc, "", &.{}));
}

test "v0.3.2: Options4Part 聚合语义（QI/AddRef/Release 委托 owner）+ Get/Set 所有权" {
    const alloc = testing.allocator;
    // 所有权语义与 setCustomSchemes 一致：create 的初始引用随列表转移给 part
    const reg1 = try SchemeRegistration.create(alloc, "media", &.{"https://zilt.app"});
    const reg2 = try SchemeRegistration.create(alloc, "app", &.{});

    const MockOwner = struct {
        refs: u32 = 1,
        fn query(ptr: *anyopaque, iid: *const com.GUID, out: ?*?*anyopaque) callconv(.winapi) com.HRESULT {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const result = out orelse return com.E_POINTER;
            result.* = null;
            if (iid.eql(com.IID_IUnknown)) {
                result.* = self;
                self.refs += 1;
                return com.S_OK;
            }
            return com.E_NOINTERFACE; // mock 不应答 Options4（真实 owner 才把分片指出去）
        }
        fn addRefOwnerFn(ptr: *anyopaque) callconv(.winapi) u32 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.refs += 1;
            return self.refs;
        }
        fn releaseOwnerFn(ptr: *anyopaque) callconv(.winapi) u32 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.refs -= 1;
            return self.refs;
        }
    };
    var owner = MockOwner{};
    const list = try alloc.alloc(*SchemeRegistration, 2);
    list[0] = reg1;
    list[1] = reg2;
    const part = try Options4Part.create(alloc, @ptrCast(&owner), MockOwner.query, MockOwner.addRefOwnerFn, MockOwner.releaseOwnerFn, list);

    // AddRef/Release 直接落在 owner 计数上
    try testing.expectEqual(@as(u32, 2), part.lpVtbl.AddRef(part));
    try testing.expectEqual(@as(u32, 1), part.lpVtbl.Release(part));
    // QI 委托 owner：IUnknown → owner 指针（COM 身份一致性）
    var out: ?*anyopaque = null;
    try testing.expectEqual(com.S_OK, part.lpVtbl.QueryInterface(part, &com.IID_IUnknown, &out));
    try testing.expectEqual(@intFromPtr(&owner), @intFromPtr(out.?));
    try testing.expectEqual(@as(u32, 1), part.lpVtbl.Release(part)); // 归还 QI 产生的 owner 引用
    try testing.expectEqual(com.E_NOINTERFACE, part.lpVtbl.QueryInterface(part, &IID_ICoreWebView2EnvironmentOptions4, &out));

    var count: win32.UINT = 0;
    var regs: ?[*]?*SchemeRegistration = null;
    try testing.expectEqual(com.S_OK, part.lpVtbl.GetCustomSchemeRegistrations(part, &count, &regs));
    try testing.expectEqual(@as(win32.UINT, 2), count);
    try testing.expect(regs != null);
    // getter 返回 AddRef 后的拷贝 → 逐个释放
    for (regs.?[0..count]) |item| if (item) |reg| {
        _ = reg.lpVtbl.Release(reg);
    };
    win32.CoTaskMemFree(@ptrCast(regs.?));

    // Set 换入 reg3（Set 对每项 AddRef，caller 引用保持）；换出的 reg1/reg2
    // 因所有权已转移给旧列表而被 dropRef 销毁
    const reg3 = try SchemeRegistration.create(alloc, "blob", &.{});
    const single = [_]?*SchemeRegistration{reg3};
    try testing.expectEqual(com.S_OK, part.lpVtbl.SetCustomSchemeRegistrations(part, 1, &single));
    try testing.expectEqual(@as(u32, 3), reg3.lpVtbl.AddRef(reg3)); // 1 caller + 1 part + 1 探针
    _ = reg3.lpVtbl.Release(reg3);
    try testing.expectEqual(com.S_OK, part.lpVtbl.GetCustomSchemeRegistrations(part, &count, &regs));
    try testing.expectEqual(@as(win32.UINT, 1), count);
    for (regs.?[0..count]) |item| if (item) |reg| {
        _ = reg.lpVtbl.Release(reg);
    };
    win32.CoTaskMemFree(@ptrCast(regs.?));
    try testing.expectEqual(com.S_OK, part.lpVtbl.SetCustomSchemeRegistrations(part, 0, null));
    // 置空后 part 不再持有 reg3 → 归还 caller 引用即销毁
    try testing.expectEqual(@as(u32, 0), reg3.lpVtbl.Release(reg3));

    try testing.expectEqual(com.E_POINTER, part.lpVtbl.GetCustomSchemeRegistrations(part, null, &regs));
    try testing.expectEqual(com.E_POINTER, part.lpVtbl.SetCustomSchemeRegistrations(part, 1, null));

    // 模拟 owner 销毁路径：释放列表（已空）与分片本体；owner 初始引用归还
    alloc.destroy(part);
    try testing.expectEqual(@as(u32, 1), owner.refs);
    owner.refs -= 1;
}
