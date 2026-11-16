//! Browser environment configuration. All strings are borrowed UTF-8.

pub const Channel = enum { evergreen, beta, dev, canary };

pub const Options = struct {
    language: ?[]const u8 = null,
    proxy_server: ?[]const u8 = null,
    /// Trusted developer configuration, passed verbatim as browser switches.
    /// Never populate this from untrusted frontend input.
    additional_browser_arguments: ?[]const u8 = null,
    /// Select exactly this installed channel; never fall back to another one.
    channel: Channel = .evergreen,
    /// Fixed-version browser directory. Takes precedence over channel discovery.
    browser_directory: ?[]const u8 = null,
    /// v0.3.2：后台节流（页面不可见时暂停定时器/降渲染优先级）。
    /// false = 追加 Chromium 开关禁用节流（环境级选项，作用于该环境全部 webview）。
    /// **平台差异**：仅 Windows/WebView2 生效；Linux/WebKitGTK 无对应 API（忽略）。
    background_throttling: bool = true,
};

test "environment defaults and Windows implementation" {
    const std = @import("std");
    const defaults: Options = .{};
    try std.testing.expectEqual(Channel.evergreen, defaults.channel);
    try std.testing.expect(defaults.language == null and defaults.proxy_server == null);
    try std.testing.expect(defaults.additional_browser_arguments == null and defaults.browser_directory == null);
    try std.testing.expect(defaults.background_throttling);
    if (@import("builtin").os.tag == .windows) {
        _ = @import("platform/windows/environment_options.zig");
        _ = @import("platform/windows/loader.zig");
    }
}
