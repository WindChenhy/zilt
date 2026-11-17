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
/// v0.3.9 A12：DWMWA_WINDOW_CORNER_PREFERENCE（33，Win11 22000+）。
pub const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
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
    /// v0.3.9 A12：窗口底色 tint（0xRRGGBB 或 0xAARRGGBB；SetWindowCompositionAttribute
    /// ACCENT_ENABLE_ACRYLICBLURBEHIND——Tauri windowEffects tint 同款）。null = 不修改
    tint: ?u32 = null,
    /// v0.3.9 A12：Win11 窗口圆角偏好（DWMWCP_*）。null = 不修改
    corner_preference: ?CornerPreference = null,
};

/// DWM_WINDOW_CORNER_PREFERENCE（v0.3.9 A12）。
pub const CornerPreference = enum(u32) {
    /// 跟随系统（默认）
    default = 0,
    /// 不圆角
    donotround = 1,
    /// 全圆角
    round = 2,
    /// 小圆角（窗口贴边时）
    smallround = 3,

    pub fn fromName(name: []const u8) !CornerPreference {
        const eql = std.mem.eql;
        if (eql(u8, name, "default")) return .default;
        if (eql(u8, name, "donotround") or eql(u8, name, "do-not-round")) return .donotround;
        if (eql(u8, name, "round")) return .round;
        if (eql(u8, name, "smallround") or eql(u8, name, "small-round")) return .smallround;
        return error.UnknownCornerPreference;
    }
};

// ---- ACCENT_POLICY（SetWindowCompositionAttribute，v0.3.9 A12）----
// 未公开 API，Tauri windowEffects（windows tint/acrylic）同款。user32 动态加载。

/// WCA_ACCENT_POLICY（WINDOWCOMPOSITIONATTRIBDATA.Attrib）
pub const WCA_ACCENT_POLICY: u32 = 26;

/// ACCENT_STATE（取子集）
pub const AccentState = enum(u32) {
    disabled = 0,
    enable_gradient = 1,
    enable_transparent_gradient = 2,
    enable_blur_behind = 3,
    enable_acrylic_blur_behind = 4,
};

/// ACCENT_POLICY（布局与 winuser 私有头一致；GradientColor = 0xAABBGGRR）。
pub const AccentPolicy = extern struct {
    accent_state: u32,
    accent_flags: u32 = 0,
    gradient_color: u32 = 0,
    animation_id: u32 = 0,
};

/// WINDOWCOMPOSITIONATTRIBDATA（同上；pvData 指向 ACCENT_POLICY）。
pub const WindowCompositionAttribData = extern struct {
    attrib: u32,
    data: *anyopaque,
    size: usize,
};

/// 解析 tint 颜色串（"AARRGGBB" / "RRGGBB"，可带 `#` 前缀）→ ACCENT_POLICY 的
/// GradientColor（0xAABBGGRR）。透明度缺省 0xCC（acrylic tint 的可见下限，Tauri 同款）。
pub fn parseTint(text: []const u8) !u32 {
    var hex = text;
    if (hex.len > 0 and hex[0] == '#') hex = hex[1..];
    if (hex.len != 6 and hex.len != 8) return error.InvalidTint;
    for (hex) |ch| {
        if (!std.ascii.isHex(ch)) return error.InvalidTint;
    }
    const value = std.fmt.parseInt(u64, hex, 16) catch return error.InvalidTint;
    var a: u32 = 0xCC;
    var r: u32 = 0;
    var g: u32 = 0;
    var b: u32 = 0;
    if (hex.len == 8) {
        a = @intCast((value >> 24) & 0xFF);
        r = @intCast((value >> 16) & 0xFF);
        g = @intCast((value >> 8) & 0xFF);
        b = @intCast(value & 0xFF);
    } else {
        r = @intCast((value >> 16) & 0xFF);
        g = @intCast((value >> 8) & 0xFF);
        b = @intCast(value & 0xFF);
    }
    return (a << 24) | (b << 16) | (g << 8) | r;
}

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

test "v0.3.9 A12: corner preference names" {
    try testing.expectEqual(CornerPreference.round, try CornerPreference.fromName("round"));
    try testing.expectEqual(CornerPreference.smallround, try CornerPreference.fromName("small-round"));
    try testing.expectEqual(CornerPreference.donotround, try CornerPreference.fromName("donotround"));
    try testing.expectEqual(CornerPreference.default, try CornerPreference.fromName("default"));
    try testing.expectError(error.UnknownCornerPreference, CornerPreference.fromName("hexagon"));
}

test "v0.3.9 A12: tint 解析 → ACCENT GradientColor（0xAABBGGRR）" {
    // RRGGBB（缺省 alpha 0xCC）：#66AACC → A=CC R=66 G=AA B=CC → 0xCCCCAA66
    try testing.expectEqual(@as(u32, 0xCCCCAA66), try parseTint("66AACC"));
    try testing.expectEqual(@as(u32, 0xCCCCAA66), try parseTint("#66AACC"));
    // AARRGGBB：8866AACC → A=88 → 0x88CCAA66
    try testing.expectEqual(@as(u32, 0x88CCAA66), try parseTint("8866AACC"));
    // 非法：长度/字符
    try testing.expectError(error.InvalidTint, parseTint("66AAC"));
    try testing.expectError(error.InvalidTint, parseTint("66AACCZZ"));
    try testing.expectError(error.InvalidTint, parseTint(""));
    try testing.expectError(error.InvalidTint, parseTint("#12345"));
}
