//! 任务栏集成（v0.1.13）的平台无关部分：进度状态、缩略图按钮、闪烁请求。
//! Windows 实现见 `platform/windows/taskbar.zig`（ITaskbarList3）。
const std = @import("std");

/// TBPFLAG（ShellApi.h）：0/1/2/4/8。
pub const ProgressState = enum(u32) {
    none = 0,
    indeterminate = 1,
    normal = 2,
    err = 4,
    paused = 8,

    pub fn fromName(name: []const u8) !ProgressState {
        const eql = std.mem.eql;
        if (eql(u8, name, "none") or eql(u8, name, "no-progress")) return .none;
        if (eql(u8, name, "indeterminate")) return .indeterminate;
        if (eql(u8, name, "normal")) return .normal;
        if (eql(u8, name, "error")) return .err;
        if (eql(u8, name, "paused")) return .paused;
        return error.UnknownProgressState;
    }
};

pub const Progress = struct {
    /// 0.0–1.0；null = 不确定进度（配合 state = indeterminate）
    value: ?f64 = null,
    state: ProgressState = .normal,

    /// TBPFLAG 的 SetProgressValue 需要整数比例，统一放大到 0..10000。
    pub fn scaled(self: Progress) struct { done: u64, total: u64 } {
        const v = self.value orelse 0;
        const clamped = if (v < 0) 0.0 else if (v > 1) 1.0 else v;
        const total: u64 = 10000;
        const done: u64 = @intFromFloat(@round(clamped * @as(f64, @floatFromInt(total))));
        return .{ .done = done, .total = total };
    }
};

pub const Button = struct {
    id: u32,
    /// 按钮提示文本（≤ 259 字符，Win32 结构限制）
    tooltip: []const u8 = "",
    enabled: bool = true,
    /// 点击后不显示按下态（一次性动作）
    dismiss_on_click: bool = false,
};

pub const Flash = struct {
    /// 闪烁次数；0 = 持续到窗口被激活
    count: u32 = 3,
    /// 闪烁间隔毫秒（0 = 系统默认 500ms）
    timeout_ms: u32 = 0,
    /// 只在任务栏按钮闪烁，不闪标题栏
    tray_only: bool = true,
};

pub const Request = union(enum) {
    progress: Progress,
    overlay: ?Overlay,
    tooltip: []const u8,
    flash: Flash,
    thumb_buttons: []const Button,
    /// v0.3.16 G18：任务栏文本徽标（Wails Dock SetBadge 对齐——文本渲染成
    /// overlay 图标）。null = 清除徽标。
    badge: ?Badge,

    pub const Overlay = struct {
        /// 资产路径（.ico）或 null 清除叠加图标
        icon: ?[]const u8 = null,
        /// 无障碍描述（屏幕阅读器朗读）
        description: []const u8 = "",
    };
};

/// v0.3.16 G18：文本徽标（32×32 圆形底 + 居中文本；Windows 红/白默认）。
pub const Badge = struct {
    text: []const u8,
    /// 0xRRGGBB
    bg_color: u32 = 0xE81123,
    text_color: u32 = 0xFFFFFF,
};

const testing = std.testing;

test "progress state names map to TBPFLAG values" {
    try testing.expectEqual(@as(u32, 0), @intFromEnum(try ProgressState.fromName("none")));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(try ProgressState.fromName("indeterminate")));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(try ProgressState.fromName("normal")));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(try ProgressState.fromName("error")));
    try testing.expectEqual(@as(u32, 8), @intFromEnum(try ProgressState.fromName("paused")));
    try testing.expectError(error.UnknownProgressState, ProgressState.fromName("bogus"));
}

test "progress scaling clamps and rounds" {
    const half = (Progress{ .value = 0.5 }).scaled();
    try testing.expectEqual(@as(u64, 5000), half.done);
    try testing.expectEqual(@as(u64, 10000), half.total);

    const over = (Progress{ .value = 2.5 }).scaled();
    try testing.expectEqual(@as(u64, 10000), over.done);

    const under = (Progress{ .value = -1 }).scaled();
    try testing.expectEqual(@as(u64, 0), under.done);

    const indeterminate = (Progress{ .value = null }).scaled();
    try testing.expectEqual(@as(u64, 0), indeterminate.done);
}

test "button and flash defaults are usable" {
    const b = Button{ .id = 1, .tooltip = "Sync" };
    try testing.expect(b.enabled);
    try testing.expect(!b.dismiss_on_click);
    const f = Flash{};
    try testing.expectEqual(@as(u32, 3), f.count);
    try testing.expect(f.tray_only);
}
