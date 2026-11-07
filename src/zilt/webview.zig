//! Shared WebView engine contract. Strings in requests are borrowed for action()
//! only; the driver copies anything needed asynchronously. All APIs run on the
//! owning UI/COM STA thread. Environment/loader options deliberately live elsewhere.
const std = @import("std");
const builtin = @import("builtin");

pub const NavigationPolicy = enum { allow, external, deny };
pub const NewWindowPolicy = enum { deny, external, new_window };
pub const PermissionPolicy = enum { allow, deny, ask };
pub const PermissionKind = enum { camera, microphone, location, clipboard, notifications, unknown };

pub const Permissions = struct {
    camera: PermissionPolicy = .ask,
    microphone: PermissionPolicy = .ask,
    location: PermissionPolicy = .ask,
    clipboard: PermissionPolicy = .ask,
    notifications: PermissionPolicy = .ask,
    unknown: PermissionPolicy = .deny,

    pub fn policy(self: Permissions, kind: PermissionKind) PermissionPolicy {
        return switch (kind) {
            inline else => |k| @field(self, @tagName(k)),
        };
    }
};

pub const Settings = struct {
    devtools: bool = builtin.mode == .debug,
    context_menus: bool = true,
    status_bar: bool = false,
    zoom_controls: bool = true,
    built_in_error_page: bool = true,
    script_dialogs: bool = true,
    host_objects: bool = false,
    user_agent: ?[]const u8 = null,
};

pub const Downloads = struct {
    enabled: bool = true,
    /// Existing absolute directory. null preserves WebView2's chosen destination.
    /// Explicit destinations never silently overwrite an existing file.
    save_directory: ?[]const u8 = null,
    show_dialog: bool = true,
};

pub const Options = struct {
    settings: Settings = .{},
    permissions: Permissions = .{},
    downloads: Downloads = .{},
    new_window: NewWindowPolicy = .deny,
    /// Origin used by storage clearing and default cookie URLs (no path/query).
    origin: []const u8 = "https://zilt.local",
    recover_renderer: bool = true,
};

pub const Completion = struct {
    context: *anyopaque,
    /// Exactly once, including synchronous failures and DriverDestroyed during
    /// destroy(). JSON is borrowed for this call. With a completion, action()
    /// reports errors here, NOT through its error return. Keep context alive until
    /// invocation; destroy the driver BEFORE releasing any outstanding contexts.
    callback: *const fn (context: *anyopaque, result: anyerror![]const u8) void,
};

pub const ClearStorage = struct {
    origin: ?[]const u8 = null,
    local_storage: bool = true,
    indexed_db: bool = true,
    /// Cache Storage + service workers for origin, AND profile-wide HTTP cache.
    cache: bool = true,
    cookies: bool = true,
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    url: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    path: []const u8 = "/",
    secure: bool = false,
    http_only: bool = false,
    same_site: ?enum { Strict, Lax, None } = null,
    /// Unix seconds; null creates a session cookie.
    expires: ?f64 = null,
};

pub const Cookies = union(enum) {
    /// URL-scoped (includes HttpOnly); JSON result is {"cookies":[...]}.
    get: struct { url: ?[]const u8 = null },
    set: Cookie,
    delete: struct { name: []const u8, url: ?[]const u8 = null, domain: ?[]const u8 = null, path: ?[]const u8 = null },
    /// Origin-scoped, not a profile-wide cookie purge.
    clear: struct { origin: ?[]const u8 = null },
};

pub const Request = union(enum) {
    reload,
    stop,
    /// Factor, not percentage; must be finite and > 0.
    zoom: f64,
    get_zoom,
    history,
    back,
    forward,
    /// Opens native print UI; completion acknowledges opening, not print outcome.
    print: enum { browser, system },
    devtools,
    clear_storage: ClearStorage,
    cookies: Cookies,
    /// Result is the evaluated JSON value, undefined => null. Non-JSON values
    /// produce NonJsonResult; thrown/rejected JS produces JavaScriptException.
    eval: struct { script: []const u8, timeout_ms: u32 = 30_000 },
    cancel_download: u64,
};

pub const Event = struct {
    pub const navigation_starting = "webview.navigation_starting";
    pub const source_changed = "webview.source_changed";
    pub const navigation_completed = "webview.navigation_completed";
    pub const new_window = "webview.new_window";
    pub const permission = "webview.permission";
    pub const download_started = "webview.download_started";
    pub const download_progress = "webview.download_progress";
    pub const download_completed = "webview.download_completed";
    pub const download_failed = "webview.download_failed";
    pub const process_failed = "webview.process_failed";
    pub const action_failed = "webview.action_failed";
};

test "settings and permission defaults" {
    const o: Options = .{};
    try std.testing.expectEqual(builtin.mode == .debug, o.settings.devtools);
    try std.testing.expect(!o.settings.host_objects);
    try std.testing.expectEqual(PermissionPolicy.deny, o.permissions.policy(.unknown));
    inline for (.{ PermissionKind.camera, .microphone, .location, .clipboard, .notifications }) |kind| {
        try std.testing.expectEqual(PermissionPolicy.ask, o.permissions.policy(kind));
    }
}

test {
    if (builtin.os.tag == .windows) _ = @import("platform/windows/webview_driver.zig");
}
