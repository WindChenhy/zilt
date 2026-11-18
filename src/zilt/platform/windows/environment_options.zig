//! ICoreWebView2EnvironmentOptions implementation, not a dependency on the SDK.
//! ABI/IID: WebView2.h 48591–48688, Microsoft.Web.WebView2 1.0.4314.35.
//! Defaults/null semantics: WebView2EnvironmentOptions.h string/bool macros.
//! v0.3.2：QI 支持 `ICoreWebView2EnvironmentOptions4`（真 scheme 注册），见
//! `setCustomSchemes`——懒创建 Options4 分片并持有注册对象引用。
const std = @import("std");
const com = @import("com.zig");
const win32 = @import("win32.zig");
const environment = @import("../../environment.zig");
const custom_scheme = @import("custom_scheme.zig");

pub const IID_ICoreWebView2EnvironmentOptions: com.GUID = .parse("{2FDE08A8-1E9A-4766-8C05-95A9CEB9D1C5}");
/// CORE_WEBVIEW_TARGET_PRODUCT_VERSION in the matching official helper header.
pub const target_compatible_browser_version = "156.0.4314.35";
const E_OUTOFMEMORY: com.HRESULT = @bitCast(@as(u32, 0x8007000E));
extern "ole32" fn CoTaskMemAlloc(bytes: usize) callconv(.winapi) ?*anyopaque;

/// Reject strings that would be truncated by Win32 or contain control characters.
fn validateText(value: []const u8) !void {
    const view = try std.unicode.Utf8View.init(value);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidEnvironmentOption;
    }
}

/// v0.3.2：禁用后台节流的 Chromium 开关（backgroundThrottling=false 时追加）。
/// 环境级选项：作用于该环境创建的全部 webview。
const background_throttling_off_args = "--disable-backgrounding-occluded-windows --disable-background-timer-throttling --disable-render-backgrounding";

/// Returns an owned UTF-8 string, or null when no switches were configured.
/// Proxy syntax is deliberately a strict ASCII subset of Chromium proxy rules:
/// host:port, scheme://host:port, and semicolon-separated per-scheme mappings.
/// Quotes, backslashes, whitespace and shell metacharacters are not proxy data.
/// Therefore quoting the entire value cannot terminate or escape its argument.
pub fn buildBrowserArguments(alloc: std.mem.Allocator, options: environment.Options) !?[]u8 {
    if (options.additional_browser_arguments) |raw| try validateText(raw);
    var has_proxy = false;
    if (options.proxy_server) |proxy| {
        if (proxy.len == 0 or proxy[0] == '-') return error.InvalidProxyServer;
        for (proxy) |c| {
            if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._~:/;=[]%", c) == null)
                return error.InvalidProxyServer;
        }
        has_proxy = true;
    }
    // 组装：[proxy, raw, throttle] 按序以单空格连接（空段跳过）
    const proxy_part: ?[]const u8 = if (has_proxy)
        try std.fmt.allocPrint(alloc, "--proxy-server=\"{s}\"", .{options.proxy_server.?})
    else
        null;
    defer if (proxy_part) |p| alloc.free(p);
    const raw_part: ?[]const u8 = if (options.additional_browser_arguments) |raw| (if (raw.len > 0) raw else null) else null;
    const throttle_part: ?[]const u8 = if (!options.background_throttling) background_throttling_off_args else null;

    var total: usize = 0;
    var count: usize = 0;
    for ([3]?[]const u8{ proxy_part, raw_part, throttle_part }) |part| {
        if (part) |p| {
            total += p.len + 1; // + 空格
            count += 1;
        }
    }
    if (count == 0) return null;
    const out = try alloc.alloc(u8, total - 1);
    var at: usize = 0;
    var written: usize = 0;
    for ([3]?[]const u8{ proxy_part, raw_part, throttle_part }) |part| {
        if (part) |p| {
            if (written > 0) {
                out[at] = ' ';
                at += 1;
            }
            @memcpy(out[at .. at + p.len], p);
            at += p.len;
            written += 1;
        }
    }
    return out;
}

/// Classic COM object; the pointer returned by create can be passed directly to
/// loader.createEnvironment. The initial reference belongs to the caller.
/// Getters allocate copies with CoTaskMemAlloc (caller must CoTaskMemFree).
/// Setters copy inputs; null clears a string. Configure before sharing the object.
pub const EnvironmentOptions = extern struct {
    lpVtbl: *const VTable = &vtable,
    refs: u32 = 1,
    allocator_context: *anyopaque,
    allocator_vtable: *const std.mem.Allocator.VTable,
    arguments: ?[*:0]u16 = null,
    language: ?[*:0]u16 = null,
    target_version: ?[*:0]u16 = null,
    allow_sso: win32.BOOL = 0,
    /// v0.3.2：Options4 分片（QI 懒创建；生命周期由 owner 引用计数保证）
    opts4: ?*custom_scheme.Options4Part = null,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*EnvironmentOptions, *const com.GUID, ?*?*anyopaque) callconv(.winapi) com.HRESULT,
        AddRef: *const fn (*EnvironmentOptions) callconv(.winapi) u32,
        Release: *const fn (*EnvironmentOptions) callconv(.winapi) u32,
        get_AdditionalBrowserArguments: StringGetter,
        put_AdditionalBrowserArguments: StringSetter,
        get_Language: StringGetter,
        put_Language: StringSetter,
        get_TargetCompatibleBrowserVersion: StringGetter,
        put_TargetCompatibleBrowserVersion: StringSetter,
        get_AllowSingleSignOnUsingOSPrimaryAccount: *const fn (*EnvironmentOptions, ?*win32.BOOL) callconv(.winapi) com.HRESULT,
        put_AllowSingleSignOnUsingOSPrimaryAccount: *const fn (*EnvironmentOptions, win32.BOOL) callconv(.winapi) com.HRESULT,
    };
    const StringGetter = *const fn (*EnvironmentOptions, ?*?[*:0]u16) callconv(.winapi) com.HRESULT;
    const StringSetter = *const fn (*EnvironmentOptions, ?[*:0]const u16) callconv(.winapi) com.HRESULT;
    const vtable: VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .get_AdditionalBrowserArguments = getArguments,
        .put_AdditionalBrowserArguments = putArguments,
        .get_Language = getLanguage,
        .put_Language = putLanguage,
        .get_TargetCompatibleBrowserVersion = getTarget,
        .put_TargetCompatibleBrowserVersion = putTarget,
        .get_AllowSingleSignOnUsingOSPrimaryAccount = getSso,
        .put_AllowSingleSignOnUsingOSPrimaryAccount = putSso,
    };

    pub fn create(alloc: std.mem.Allocator, options: environment.Options) !*EnvironmentOptions {
        if (options.language) |value| try validateText(value);
        const args = try buildBrowserArguments(alloc, options);
        defer if (args) |value| alloc.free(value);
        const self = try alloc.create(EnvironmentOptions);
        self.* = .{ .allocator_context = alloc.ptr, .allocator_vtable = alloc.vtable };
        errdefer self.dropRef();
        if (args) |value| self.arguments = (try std.unicode.utf8ToUtf16LeAllocZ(alloc, value)).ptr;
        if (options.language) |value| self.language = (try std.unicode.utf8ToUtf16LeAllocZ(alloc, value)).ptr;
        self.target_version = (try std.unicode.utf8ToUtf16LeAllocZ(alloc, target_compatible_browser_version)).ptr;
        return self;
    }

    pub fn dropRef(self: *EnvironmentOptions) void {
        _ = self.lpVtbl.Release(self);
    }

    /// v0.3.2：注册真 scheme（`ICoreWebView2EnvironmentOptions4::
    /// SetCustomSchemeRegistrations`）。懒创建 Options4 分片（聚合语义：分片的
    /// 引用计数/查询都委托本对象），注册对象引用归本对象持有，随最后一个引用
    /// 一起释放。注册名与允许来源在此处校验（非法即报错，避免带病进环境创建）。
    pub fn setCustomSchemes(
        self: *EnvironmentOptions,
        alloc: std.mem.Allocator,
        protocols: []const @import("../../protocol.zig").Protocol,
        app_origin: []const u8,
        extra_names: []const []const u8,
    ) !void {
        _ = app_origin; // v0.3.2 实测：AllowedOrigins 用通配 "*"（精确 origin 匹配
        // 不解决 https 页面 fetch 的 CORS 判定；见 protocol.zig 文档化限制）
        if (protocols.len == 0 and extra_names.len == 0) return;
        const part = try self.ensureOptions4(alloc);
        // v0.3.10 C2：extra_names（isolation 的 "ziltiso"）与应用协议一并注册
        const regs = try alloc.alloc(*custom_scheme.SchemeRegistration, protocols.len + extra_names.len);
        var written: usize = 0;
        errdefer {
            for (regs[0..written]) |reg| reg.dropRef();
            alloc.free(regs);
        }
        for (protocols) |p| {
            regs[written] = try custom_scheme.SchemeRegistration.create(alloc, p.name, &.{"*"});
            written += 1;
        }
        for (extra_names) |name| {
            regs[written] = try custom_scheme.SchemeRegistration.create(alloc, name, &.{"*"});
            written += 1;
        }
        const hr = part.lpVtbl.SetCustomSchemeRegistrations(part, @intCast(regs.len), @ptrCast(regs.ptr));
        // COM 契约：Set 已对每项 AddRef 保留自己的拷贝 → caller 引用即刻归还
        for (regs) |reg| reg.dropRef();
        alloc.free(regs);
        if (com.failed(hr)) return error.SetCustomSchemesFailed;
    }

    fn ensureOptions4(self: *EnvironmentOptions, alloc: std.mem.Allocator) !*custom_scheme.Options4Part {
        if (self.opts4) |part| return part;
        const regs = try alloc.alloc(*custom_scheme.SchemeRegistration, 0);
        const part = custom_scheme.Options4Part.create(
            alloc,
            self,
            queryOwner,
            addRefOwner,
            releaseOwner,
            regs,
        ) catch |err| {
            alloc.free(regs);
            return err;
        };
        self.opts4 = part;
        return part;
    }

    fn queryOwner(self_opaque: *anyopaque, iid: *const com.GUID, out: ?*?*anyopaque) callconv(.winapi) com.HRESULT {
        const self: *EnvironmentOptions = @ptrCast(@alignCast(self_opaque));
        return queryInterface(self, iid, out);
    }
    fn addRefOwner(self_opaque: *anyopaque) callconv(.winapi) u32 {
        const self: *EnvironmentOptions = @ptrCast(@alignCast(self_opaque));
        return addRef(self);
    }
    fn releaseOwner(self_opaque: *anyopaque) callconv(.winapi) u32 {
        const self: *EnvironmentOptions = @ptrCast(@alignCast(self_opaque));
        return release(self);
    }

    fn allocator(self: *EnvironmentOptions) std.mem.Allocator {
        return .{ .ptr = self.allocator_context, .vtable = self.allocator_vtable };
    }
    fn queryInterface(self: *EnvironmentOptions, iid: *const com.GUID, out: ?*?*anyopaque) callconv(.winapi) com.HRESULT {
        const result = out orelse return com.E_POINTER;
        result.* = null;
        if (iid.eql(com.IID_IUnknown) or iid.eql(IID_ICoreWebView2EnvironmentOptions)) {
            result.* = self;
            _ = addRef(self);
            return com.S_OK;
        }
        // v0.3.2：真 scheme 注册接口（分片懒创建；未配置 schemes 时也允许 QI，
        // 运行时拿到的注册列表为空 = 无自定义 scheme）
        if (iid.eql(custom_scheme.IID_ICoreWebView2EnvironmentOptions4)) {
            const part = self.ensureOptions4(self.allocator()) catch return E_OUTOFMEMORY;
            _ = addRef(self); // QI 语义：返回分片指针但计数在共享 owner 上
            result.* = part;
            return com.S_OK;
        }
        return com.E_NOINTERFACE;
    }
    fn addRef(self: *EnvironmentOptions) callconv(.winapi) u32 {
        return @atomicRmw(u32, &self.refs, .Add, 1, .monotonic) + 1;
    }
    fn release(self: *EnvironmentOptions) callconv(.winapi) u32 {
        const previous = @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel);
        if (previous == 1) {
            const alloc = self.allocator();
            // v0.3.2：注册对象引用与分片随 owner 一起释放（聚合语义）
            if (self.opts4) |part| {
                for (part.registrations_ptr[0..part.registrations_len]) |reg| reg.dropRef();
                if (part.registrations_len > 0) alloc.free(part.registrations_ptr[0..part.registrations_len]);
                alloc.destroy(part);
                self.opts4 = null;
            }
            // （len=0 时列表无分配，free 跳过）
            if (self.arguments) |s| alloc.free(std.mem.span(s));
            if (self.language) |s| alloc.free(std.mem.span(s));
            if (self.target_version) |s| alloc.free(std.mem.span(s));
            alloc.destroy(self);
        }
        return previous - 1;
    }
    fn copyString(value: ?[*:0]u16, out: ?*?[*:0]u16) com.HRESULT {
        const result = out orelse return com.E_POINTER;
        result.* = null;
        if (value) |s| {
            const len = std.mem.len(s);
            const bytes = std.math.mul(usize, len + 1, @sizeOf(u16)) catch return E_OUTOFMEMORY;
            const copy: [*:0]u16 = @ptrCast(@alignCast(CoTaskMemAlloc(bytes) orelse return E_OUTOFMEMORY));
            @memcpy(copy[0 .. len + 1], s[0 .. len + 1]);
            result.* = copy;
        }
        return com.S_OK;
    }
    fn setString(self: *EnvironmentOptions, slot: *?[*:0]u16, value: ?[*:0]const u16) com.HRESULT {
        const alloc = self.allocator();
        // Allocate first, preserving the old value on failure (and allowing aliasing).
        const copy = if (value) |s| (alloc.dupeSentinel(u16, std.mem.span(s), 0) catch return E_OUTOFMEMORY).ptr else null;
        if (slot.*) |s| alloc.free(std.mem.span(s));
        slot.* = copy;
        return com.S_OK;
    }
    fn getArguments(self: *EnvironmentOptions, out: ?*?[*:0]u16) callconv(.winapi) com.HRESULT {
        return copyString(self.arguments, out);
    }
    fn putArguments(self: *EnvironmentOptions, value: ?[*:0]const u16) callconv(.winapi) com.HRESULT {
        return self.setString(&self.arguments, value);
    }
    fn getLanguage(self: *EnvironmentOptions, out: ?*?[*:0]u16) callconv(.winapi) com.HRESULT {
        return copyString(self.language, out);
    }
    fn putLanguage(self: *EnvironmentOptions, value: ?[*:0]const u16) callconv(.winapi) com.HRESULT {
        return self.setString(&self.language, value);
    }
    fn getTarget(self: *EnvironmentOptions, out: ?*?[*:0]u16) callconv(.winapi) com.HRESULT {
        return copyString(self.target_version, out);
    }
    fn putTarget(self: *EnvironmentOptions, value: ?[*:0]const u16) callconv(.winapi) com.HRESULT {
        return self.setString(&self.target_version, value);
    }
    fn getSso(self: *EnvironmentOptions, out: ?*win32.BOOL) callconv(.winapi) com.HRESULT {
        (out orelse return com.E_POINTER).* = self.allow_sso;
        return com.S_OK;
    }
    fn putSso(self: *EnvironmentOptions, value: win32.BOOL) callconv(.winapi) com.HRESULT {
        self.allow_sso = value;
        return com.S_OK;
    }
};

test "browser argument construction and proxy injection rejection" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try buildBrowserArguments(alloc, .{})) == null);
    const args = (try buildBrowserArguments(alloc, .{
        .proxy_server = "http=127.0.0.1:8080;https=socks5://[::1]:1080",
        .additional_browser_arguments = "--disable-features=Example --user-agent=\"developer value\"",
    })).?;
    defer alloc.free(args);
    try std.testing.expectEqualStrings("--proxy-server=\"http=127.0.0.1:8080;https=socks5://[::1]:1080\" --disable-features=Example --user-agent=\"developer value\"", args);
    const proxy_only = (try buildBrowserArguments(alloc, .{ .proxy_server = "localhost:8080" })).?;
    defer alloc.free(proxy_only);
    try std.testing.expectEqualStrings("--proxy-server=\"localhost:8080\"", proxy_only);
    const raw = (try buildBrowserArguments(alloc, .{ .additional_browser_arguments = "--foo=\"bar baz\"" })).?;
    defer alloc.free(raw);
    try std.testing.expectEqualStrings("--foo=\"bar baz\"", raw);
    for ([_][]const u8{ "", "--disable-web-security", "host --disable-web-security", "host\" --foo", "host\\", "host\r", "host\n", "host\x00suffix", "host\t", "host\x7f", "host\x01", "host&command", "host|command" }) |bad| {
        try std.testing.expectError(error.InvalidProxyServer, buildBrowserArguments(alloc, .{ .proxy_server = bad }));
    }
    try std.testing.expectError(error.InvalidEnvironmentOption, buildBrowserArguments(alloc, .{ .additional_browser_arguments = "--foo\x00--bar" }));
}

test "v0.3.2: backgroundThrottling=false 追加节流开关（默认不变）" {
    const alloc = std.testing.allocator;
    // 默认（true）不追加
    try std.testing.expect((try buildBrowserArguments(alloc, .{})) == null);
    // 仅节流关闭
    const off = (try buildBrowserArguments(alloc, .{ .background_throttling = false })).?;
    defer alloc.free(off);
    try std.testing.expectEqualStrings("--disable-backgrounding-occluded-windows --disable-background-timer-throttling --disable-render-backgrounding", off);
    // 节流关闭 + 已有参数
    const mixed = (try buildBrowserArguments(alloc, .{ .background_throttling = false, .additional_browser_arguments = "--foo" })).?;
    defer alloc.free(mixed);
    try std.testing.expectEqualStrings("--foo --disable-backgrounding-occluded-windows --disable-background-timer-throttling --disable-render-backgrounding", mixed);
    // 节流关闭 + 代理
    const proxied = (try buildBrowserArguments(alloc, .{ .background_throttling = false, .proxy_server = "localhost:8080" })).?;
    defer alloc.free(proxied);
    try std.testing.expectEqualStrings("--proxy-server=\"localhost:8080\" --disable-backgrounding-occluded-windows --disable-background-timer-throttling --disable-render-backgrounding", proxied);
}

test "COM defaults, string copies and setters, null outputs, and SSO" {
    const obj = try EnvironmentOptions.create(std.testing.allocator, .{});
    defer obj.dropRef();
    const vt = obj.lpVtbl;
    var value: ?[*:0]u16 = null;
    try std.testing.expectEqual(com.S_OK, vt.get_AdditionalBrowserArguments(obj, &value));
    try std.testing.expect(value == null);
    try std.testing.expectEqual(com.S_OK, vt.get_Language(obj, &value));
    try std.testing.expect(value == null);
    try std.testing.expectEqual(com.S_OK, vt.get_TargetCompatibleBrowserVersion(obj, &value));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral(target_compatible_browser_version), std.mem.span(value.?));
    win32.CoTaskMemFree(@ptrCast(value));

    const getters = [_]EnvironmentOptions.StringGetter{ vt.get_AdditionalBrowserArguments, vt.get_Language, vt.get_TargetCompatibleBrowserVersion };
    const setters = [_]EnvironmentOptions.StringSetter{ vt.put_AdditionalBrowserArguments, vt.put_Language, vt.put_TargetCompatibleBrowserVersion };
    for (getters, setters) |get, put| {
        try std.testing.expectEqual(com.E_POINTER, get(obj, null));
        var input = [_:0]u16{ 'z', 'h', '-', 'C', 'N' };
        try std.testing.expectEqual(com.S_OK, put(obj, &input));
        input[0] = 'X'; // setter must not borrow its input
        try std.testing.expectEqual(com.S_OK, get(obj, &value));
        const first = value.?;
        defer win32.CoTaskMemFree(@ptrCast(first));
        try std.testing.expectEqualSlices(u16, &.{ 'z', 'h', '-', 'C', 'N' }, std.mem.span(first));
        first[0] = 'Y'; // getter must not expose internal storage
        try std.testing.expectEqual(com.S_OK, get(obj, &value));
        try std.testing.expectEqual(@as(u16, 'z'), value.?[0]);
        win32.CoTaskMemFree(@ptrCast(value));
        try std.testing.expectEqual(com.S_OK, put(obj, std.unicode.utf8ToUtf16LeStringLiteral("")));
        try std.testing.expectEqual(com.S_OK, get(obj, &value));
        try std.testing.expect(value != null and std.mem.len(value.?) == 0);
        win32.CoTaskMemFree(@ptrCast(value));
        try std.testing.expectEqual(com.S_OK, put(obj, null));
        try std.testing.expectEqual(com.S_OK, get(obj, &value));
        try std.testing.expect(value == null);
    }
    var sso: win32.BOOL = -1;
    try std.testing.expectEqual(com.S_OK, vt.get_AllowSingleSignOnUsingOSPrimaryAccount(obj, &sso));
    try std.testing.expectEqual(@as(win32.BOOL, 0), sso);
    try std.testing.expectEqual(com.E_POINTER, vt.get_AllowSingleSignOnUsingOSPrimaryAccount(obj, null));
    try std.testing.expectEqual(com.S_OK, vt.put_AllowSingleSignOnUsingOSPrimaryAccount(obj, 1));
    try std.testing.expectEqual(com.S_OK, vt.get_AllowSingleSignOnUsingOSPrimaryAccount(obj, &sso));
    try std.testing.expectEqual(@as(win32.BOOL, 1), sso);
}

test "COM QueryInterface identity and reference lifetime" {
    const obj = try EnvironmentOptions.create(std.testing.allocator, .{ .language = "zh-CN", .proxy_server = "localhost:8080" });
    const vt = obj.lpVtbl;
    var out: ?*anyopaque = obj;
    const unsupported: com.GUID = .{ .data1 = 0, .data2 = 0, .data3 = 0, .data4 = @splat(0) };
    try std.testing.expectEqual(com.E_NOINTERFACE, vt.QueryInterface(obj, &unsupported, &out));
    try std.testing.expect(out == null);
    try std.testing.expectEqual(com.E_POINTER, vt.QueryInterface(obj, &com.IID_IUnknown, null));
    try std.testing.expectEqual(com.S_OK, vt.QueryInterface(obj, &com.IID_IUnknown, &out));
    try std.testing.expectEqual(@intFromPtr(obj), @intFromPtr(out.?));
    try std.testing.expectEqual(@as(u32, 1), vt.Release(obj));
    try std.testing.expectEqual(com.S_OK, vt.QueryInterface(obj, &IID_ICoreWebView2EnvironmentOptions, &out));
    try std.testing.expectEqual(@intFromPtr(obj), @intFromPtr(out.?));
    obj.dropRef(); // QI reference keeps it alive
    var value: ?[*:0]u16 = null;
    try std.testing.expectEqual(com.S_OK, vt.get_Language(obj, &value));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("zh-CN"), std.mem.span(value.?));
    win32.CoTaskMemFree(@ptrCast(value));
    try std.testing.expectEqual(@as(u32, 2), vt.AddRef(obj));
    try std.testing.expectEqual(@as(u32, 1), vt.Release(obj));
    try std.testing.expectEqual(@as(u32, 0), vt.Release(obj));
}

fn createWithFailures(alloc: std.mem.Allocator) !void {
    const obj = try EnvironmentOptions.create(alloc, .{ .language = "zh-CN", .proxy_server = "localhost:8080", .additional_browser_arguments = "--foo" });
    defer obj.dropRef();
}

test "creation is leak-free on allocation failure and invalid options" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createWithFailures, .{});
    try std.testing.expectError(error.InvalidEnvironmentOption, EnvironmentOptions.create(std.testing.allocator, .{ .language = "en\x00-US" }));
    try std.testing.expectError(error.InvalidProxyServer, EnvironmentOptions.create(std.testing.allocator, .{ .proxy_server = "x\" --foo" }));
}

test "v0.3.2: setCustomSchemes 注册 + QI 分片往返 + 释放无泄漏" {
    const alloc = std.testing.allocator;
    const proto_mod = @import("../../protocol.zig");
    const obj = try EnvironmentOptions.create(alloc, .{ .proxy_server = "localhost:8080" });

    // 未注册时 QI 也能拿到分片（空列表）
    var out: ?*anyopaque = null;
    try std.testing.expectEqual(com.S_OK, obj.lpVtbl.QueryInterface(obj, &custom_scheme.IID_ICoreWebView2EnvironmentOptions4, &out));
    const part0: *custom_scheme.Options4Part = @ptrCast(@alignCast(out.?));
    var count0: win32.UINT = 0;
    var regs0: ?[*]?*custom_scheme.SchemeRegistration = null;
    try std.testing.expectEqual(com.S_OK, part0.lpVtbl.GetCustomSchemeRegistrations(part0, &count0, &regs0));
    try std.testing.expectEqual(@as(win32.UINT, 0), count0);
    try std.testing.expect(regs0 == null);
    try std.testing.expectEqual(@as(u32, 1), part0.lpVtbl.Release(part0)); // 归还 QI 引用（计数在 obj 上；剩 caller 的 1）

    // 注册两个 scheme → QI 读回
    const protocols = [_]proto_mod.Protocol{
        .{ .name = "media", .handle = undefined },
        .{ .name = "app-data", .handle = undefined },
    };
    try obj.setCustomSchemes(alloc, &protocols, "https://zilt.app", &.{});

    try std.testing.expectEqual(com.S_OK, obj.lpVtbl.QueryInterface(obj, &custom_scheme.IID_ICoreWebView2EnvironmentOptions4, &out));
    const part: *custom_scheme.Options4Part = @ptrCast(@alignCast(out.?));
    var count: win32.UINT = 0;
    var regs: ?[*]?*custom_scheme.SchemeRegistration = null;
    try std.testing.expectEqual(com.S_OK, part.lpVtbl.GetCustomSchemeRegistrations(part, &count, &regs));
    try std.testing.expectEqual(@as(win32.UINT, 2), count);
    try std.testing.expect(regs != null);
    for (regs.?[0..count], 0..) |item, i| {
        const reg = item.?;
        var name: ?[*:0]u16 = null;
        try std.testing.expectEqual(com.S_OK, reg.lpVtbl.get_SchemeName(reg, &name));
        defer win32.CoTaskMemFree(@ptrCast(name.?));
        const expected_media = std.unicode.utf8ToUtf16LeStringLiteral("media");
        const expected_app = std.unicode.utf8ToUtf16LeStringLiteral("app-data");
        const expected = if (i == 0) expected_media else expected_app;
        try std.testing.expectEqualSlices(u16, expected, std.mem.span(name.?));
        _ = reg.lpVtbl.Release(reg); // 归还 getter 拷贝引用
    }
    win32.CoTaskMemFree(@ptrCast(regs.?));
    try std.testing.expectEqual(@as(u32, 1), part.lpVtbl.Release(part)); // 归还 QI 引用（剩 caller 的 1）

    // 非法 scheme 名在注册前即报错（不产生半注册状态）
    const bad = [_]proto_mod.Protocol{.{ .name = "Bad_Name", .handle = undefined }};
    try std.testing.expectError(error.InvalidSchemeName, obj.setCustomSchemes(alloc, &bad, "https://zilt.app", &.{}));

    try std.testing.expectEqual(@as(u32, 1), obj.refs); // 只剩 caller 引用
    try std.testing.expect(obj.opts4 != null); // 分片仍在（随 owner 释放）
    try std.testing.expectEqual(@as(win32.UINT, 2), obj.opts4.?.registrations_len);
    obj.dropRef(); // 最后引用 → 分片 + 注册对象全部释放（testing.allocator 校验泄漏）
}
