//! 窗口主题与背景效果（v0.1.14）的平台无关部分。
//!
//! Windows 通过 DwmSetWindowAttribute 实现（暗色标题栏 + Win11 Mica/Acrylic），
//! 见 `platform/windows/system_integration.zig`。
const std = @import("std");

/// DWMWA_USE_IMMERSIVE_DARK_MODE（20）；Win10 1809 前为 19，实现里会回退。
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;
pub const DWMWA_USE_IMMERSIVE_DARK_MODE_OLD: u32 = 19;
/// DWMWA_SYSTEMBACKDROP_TYPE（38，Win11 22H2+）。
pub const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38;
/// v0.1.18：Win11 标题栏配色（COLORREF，0x00BBGGRR）。
pub const DWMWA_BORDER_COLOR: u32 = 34;
pub const DWMWA_CAPTION_COLOR: u32 = 35;
pub const DWMWA_TEXT_COLOR: u32 = 36;

/// 0xRRGGBB → COLORREF(0x00BBGGRR)。DWM 的 COLORREF 属性不接受 alpha。
pub fn colorRef(rgb: u32) u32 {
    const r = (rgb >> 16) & 0xFF;
    const g = (rgb >> 8) & 0xFF;
    const b = rgb & 0xFF;
    return (b << 16) | (g << 8) | r;
}

/// DWM_SYSTEMBACKDROP_TYPE
pub const Backdrop = enum(u32) {
    /// 跟随系统（默认）
    auto = 0,
    /// 无背景效果
    none = 1,
    /// Mica：桌面壁纸采样，适合主窗口
    mica = 2,
    /// Acrylic：模糊透明，适合浮层
    acrylic = 3,
    /// Mica Alt：标题栏与内容不同采样，适合带标签页的窗口
    tabbed = 4,

    pub fn fromName(name: []const u8) !Backdrop {
        const eql = std.mem.eql;
        if (eql(u8, name, "auto")) return .auto;
        if (eql(u8, name, "none")) return .none;
        if (eql(u8, name, "mica")) return .mica;
        if (eql(u8, name, "acrylic")) return .acrylic;
        if (eql(u8, name, "tabbed") or eql(u8, name, "mica-alt") or eql(u8, name, "micaAlt")) return .tabbed;
        return error.UnknownBackdrop;
    }
};

pub const Appearance = struct {
    /// 暗色标题栏
    dark_titlebar: ?bool = null,
    /// 背景效果（null = 不修改）
    backdrop: ?Backdrop = null,
    /// v0.1.18：标题栏/文字/边框颜色（0xRRGGBB，Win11 生效）
    caption_color: ?u32 = null,
    text_color: ?u32 = null,
    border_color: ?u32 = null,
};

/// 应用顺序：先背景效果再标题栏（Win11 上 swapchain 背景与标题栏相互独立）。
pub fn attributeValue(appearance: Appearance) struct { dark: ?u32, backdrop: ?u32 } {
    return .{
        .dark = if (appearance.dark_titlebar) |d| @as(u32, @intFromBool(d)) else null,
        .backdrop = if (appearance.backdrop) |b| @intFromEnum(b) else null,
    };
}

const testing = std.testing;

test "backdrop names parse" {
    try testing.expectEqual(Backdrop.mica, try Backdrop.fromName("mica"));
    try testing.expectEqual(Backdrop.acrylic, try Backdrop.fromName("acrylic"));
    try testing.expectEqual(Backdrop.tabbed, try Backdrop.fromName("mica-alt"));
    try testing.expectEqual(Backdrop.none, try Backdrop.fromName("none"));
    try testing.expectError(error.UnknownBackdrop, Backdrop.fromName("blur"));
}

test "attribute values are optional" {
    const none = attributeValue(.{});
    try testing.expectEqual(@as(?u32, null), none.dark);
    try testing.expectEqual(@as(?u32, null), none.backdrop);

    const dark = attributeValue(.{ .dark_titlebar = true, .backdrop = .mica });
    try testing.expectEqual(@as(?u32, 1), dark.dark);
    try testing.expectEqual(@as(?u32, 2), dark.backdrop);
}

test "v0.1.18: rgb to COLORREF" {
    // 0x112233 → COLORREF 0x00332211
    try testing.expectEqual(@as(u32, 0x00332211), colorRef(0x112233));
    try testing.expectEqual(@as(u32, 0x00000000), colorRef(0x000000));
    try testing.expectEqual(@as(u32, 0x00FFFFFF), colorRef(0xFFFFFF));
}
