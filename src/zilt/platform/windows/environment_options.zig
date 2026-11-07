//! ICoreWebView2EnvironmentOptions implementation, not a dependency on the SDK.
//! ABI/IID: WebView2.h 48591–48688, Microsoft.Web.WebView2 1.0.4314.35.
//! Defaults/null semantics: WebView2EnvironmentOptions.h string/bool macros.
const std = @import("std");
const com = @import("com.zig");
const win32 = @import("win32.zig");
const environment = @import("../../environment.zig");

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

/// Returns an owned UTF-8 string, or null when no switches were configured.
/// Proxy syntax is deliberately a strict ASCII subset of Chromium proxy rules:
/// host:port, scheme://host:port, and semicolon-separated per-scheme mappings.
/// Quotes, backslashes, whitespace and shell metacharacters are not proxy data.
/// Therefore quoting the entire value cannot terminate or escape its argument.
pub fn buildBrowserArguments(alloc: std.mem.Allocator, options: environment.Options) !?[]u8 {
    if (options.additional_browser_arguments) |raw| try validateText(raw);
    if (options.proxy_server) |proxy| {
        if (proxy.len == 0 or proxy[0] == '-') return error.InvalidProxyServer;
        for (proxy) |c| {
            if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._~:/;=[]%", c) == null)
                return error.InvalidProxyServer;
        }
        const raw = options.additional_browser_arguments orelse "";
        return try std.fmt.allocPrint(alloc, "--proxy-server=\"{s}\"{s}{s}", .{ proxy, if (raw.len == 0) "" else " ", raw });
    }
    if (options.additional_browser_arguments) |raw| return try alloc.dupe(u8, raw);
    return null;
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

    fn allocator(self: *EnvironmentOptions) std.mem.Allocator {
        return .{ .ptr = self.allocator_context, .vtable = self.allocator_vtable };
    }
    fn queryInterface(self: *EnvironmentOptions, iid: *const com.GUID, out: ?*?*anyopaque) callconv(.winapi) com.HRESULT {
        const result = out orelse return com.E_POINTER;
        result.* = null;
        if (!iid.eql(com.IID_IUnknown) and !iid.eql(IID_ICoreWebView2EnvironmentOptions)) return com.E_NOINTERFACE;
        result.* = self;
        _ = addRef(self);
        return com.S_OK;
    }
    fn addRef(self: *EnvironmentOptions) callconv(.winapi) u32 {
        return @atomicRmw(u32, &self.refs, .Add, 1, .monotonic) + 1;
    }
    fn release(self: *EnvironmentOptions) callconv(.winapi) u32 {
        const previous = @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel);
        if (previous == 1) {
            const alloc = self.allocator();
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
