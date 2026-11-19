//! Shared WebView engine contract. Strings in requests are borrowed for action()
//! only; the driver copies anything needed asynchronously. All APIs run on the
//! owning UI/COM STA thread. Environment/loader options deliberately live elsewhere.
const std = @import("std");
const builtin = @import("builtin");

pub const NavigationPolicy = enum { allow, external, deny };
pub const NewWindowPolicy = enum { deny, external, new_window };
pub const PermissionPolicy = enum { allow, deny, ask };
pub const PermissionKind = enum { camera, microphone, location, clipboard, notifications, other_sensors, unknown };

pub const Permissions = struct {
    camera: PermissionPolicy = .ask,
    microphone: PermissionPolicy = .ask,
    location: PermissionPolicy = .ask,
    clipboard: PermissionPolicy = .ask,
    notifications: PermissionPolicy = .ask,
    /// v0.3.15 G27：OtherSensors（COREWEBVIEW2_PERMISSION_KIND_OTHER_SENSORS=5）。
    other_sensors: PermissionPolicy = .deny,
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
    /// v0.3.2：表单自动填充（Win：Profile6 IsGeneralAutofillEnabled；
    /// Linux：WebKitSettings enable-auto-fill）。默认开（浏览器语义）。
    autofill: bool = true,
    /// v0.3.2：密码保存（Win：Profile6 IsPasswordAutosaveEnabled；Linux 无 API）。
    /// 默认关（保守安全面：桌面壳应用通常不需要）。
    password_autosave: bool = false,
    /// v0.3.15 G13：浏览器加速键（Win：Settings3 AreBrowserAcceleratorKeysEnabled
    /// ——Ctrl+F 等交还页面用 false；Linux 无 API 文档化）。默认开（浏览器语义）。
    browser_accelerators: bool = true,
    /// v0.3.15 G14：前进/后退滑动手势（Win：Settings6 IsSwipeNavigationEnabled；
    /// Linux：WebKitSettings enable-back-forward-navigation-gestures）。默认关
    /// （WebView2 引擎默认语义；桌面壳应用通常不需要——Wails EnableSwipeGestures 同 opt-in）。
    swipe_gestures: bool = false,
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

/// v0.3.14：DevTools 操作（对齐 Tauri open/close_devtools + Wails OpenDevTools）。
pub const DevToolsOp = enum { open, close, state };

pub const Request = union(enum) {
    reload,
    stop,
    /// Factor, not percentage; must be finite and > 0.
    zoom: f64,
    get_zoom,
    history,
    back,
    forward,
    /// v0.3.14：devtools 显隐与状态。close 仅 Linux 可用（WebKitGTK inspector）；
    /// Windows 的 DevTools 窗口无关闭 API（返回 DevToolsCloseUnsupported，文档化）。
    devtools: DevToolsOp,
    /// v0.3.14：加载 HTML 字符串（Wails SetHTML 语义 / NavigateToString）。
    /// 立即导航替换当前文档；历史策略随引擎默认。
    load_html: []const u8,
    /// Opens native print UI; completion acknowledges opening, not print outcome.
    print: enum { browser, system },
    clear_storage: ClearStorage,
    cookies: Cookies,
    /// Result is the evaluated JSON value, undefined => null. Non-JSON values
    /// produce NonJsonResult; thrown/rejected JS produces JavaScriptException.
    eval: struct { script: []const u8, timeout_ms: u32 = 30_000 },
    /// v0.1.23：任意 CDP 调用（Page.captureScreenshot / Network.setExtraHTTPHeaders …）。
    /// **异步**：本请求立即返回 `{}`，结果经 `webviewCdp` 事件带回（rid 匹配）。
    /// params 是原始 JSON 文本（默认 `{}`）。
    cdp: struct { method: []const u8, params: []const u8 = "{}", rid: i64 },
    /// v0.1.24：运行时改本窗口 UA（下次导航生效；空串 = 恢复引擎默认）
    set_user_agent: []const u8,
    cancel_download: u64,
    /// v0.3.15 G12：静默导出 PDF（Wails/Tauri 均无此 API——Zilt 领先项）。
    /// Win：ICoreWebView2_7::PrintToPdf（槽 80，SDK 1.0.3124.44 核对）+ 引擎默认
    /// 打印设置（A4 纵向）；完成经 handler 回报 is_successful。**异步**：本请求
    /// 立即返回 `{}`，结果经 `webviewPdf` 事件带回（rid 匹配）。
    /// Linux 无 PDF 导出 API（WebKitGTK 仅打印对话框）→ PdfNotSupported 文档化。
    print_to_pdf: struct { path: []const u8, rid: i64 = 0 },
    /// v0.3.15：Settings3/6 开关 ABI 往返探针（读 → 反转 → 验证 → 恢复 → 验证）。
    /// 返回 {"accelerators":{before,after,restored},"swipe":{...}}；Linux 无对应
    /// API → {"accelerators":null,"swipe":null}。冒烟 c-acc 用。
    settings_probe,
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
    // v0.3.15：新开关默认值（浏览器语义：加速键开、手势关）
    try std.testing.expect(o.settings.browser_accelerators);
    try std.testing.expect(!o.settings.swipe_gestures);
    try std.testing.expectEqual(PermissionPolicy.deny, o.permissions.policy(.unknown));
    try std.testing.expectEqual(PermissionPolicy.deny, o.permissions.policy(.other_sensors));
    inline for (.{ PermissionKind.camera, .microphone, .location, .clipboard, .notifications }) |kind| {
        try std.testing.expectEqual(PermissionPolicy.ask, o.permissions.policy(kind));
    }
}

test {
    if (builtin.os.tag == .windows) _ = @import("platform/windows/webview_driver.zig");
}
