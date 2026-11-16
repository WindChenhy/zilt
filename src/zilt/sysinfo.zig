//! 系统信息（v0.1.14）的平台无关部分：类型与 JSON 序列化。
//! Windows 采集见 `platform/windows/sysinfo.zig`。
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Theme = enum { light, dark };

pub const OsInfo = struct {
    /// 产品名（"Windows 11" / "Windows 10" / "Windows 8.1" …）
    name: []const u8 = "Windows",
    /// "10.0.22631" 形式
    version: []const u8 = "0.0.0",
    build: u32 = 0,
    /// "x86_64" / "aarch64"
    arch: []const u8 = "unknown",
    /// BCP-47（"zh-CN"）
    locale: []const u8 = "en-US",
    theme: Theme = .light,
    /// 0xAARRGGBB（Windows 强调色，DWM\AccentColor）
    accent_color: u32 = 0,
};

pub const Monitor = struct {
    index: u32 = 0,
    primary: bool = false,
    /// 显示器物理区域（虚拟屏坐标）
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// 工作区（扣除任务栏）
    work_x: i32 = 0,
    work_y: i32 = 0,
    work_width: u32 = 0,
    work_height: u32 = 0,
    dpi: u32 = 96,
    /// 150% → 1.5
    scale: f64 = 1.0,
    /// v0.3.2：调用窗口所在显示器（system.info('monitors') 时按 windowId 标记）
    current: bool = false,
};

/// 由 major/minor/build 推断产品名（Win11 起始 build 22000）。
pub fn productName(major: u32, minor: u32, build: u32) []const u8 {
    if (major >= 10) {
        return if (build >= 22000) "Windows 11" else "Windows 10";
    }
    if (major == 6 and minor == 3) return "Windows 8.1";
    if (major == 6 and minor == 2) return "Windows 8";
    if (major == 6 and minor == 1) return "Windows 7";
    return "Windows";
}

/// "10.0.22631"
pub fn formatVersion(buf: []u8, major: u32, minor: u32, build: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ major, minor, build });
}

pub fn scaleFromDpi(dpi: u32) f64 {
    if (dpi == 0) return 1.0;
    return @as(f64, @floatFromInt(dpi)) / 96.0;
}

pub fn osToJson(alloc: Allocator, info: OsInfo) ![]u8 {
    const name = try std.json.Stringify.valueAlloc(alloc, info.name, .{});
    defer alloc.free(name);
    const version = try std.json.Stringify.valueAlloc(alloc, info.version, .{});
    defer alloc.free(version);
    const arch = try std.json.Stringify.valueAlloc(alloc, info.arch, .{});
    defer alloc.free(arch);
    const locale = try std.json.Stringify.valueAlloc(alloc, info.locale, .{});
    defer alloc.free(locale);
    return std.fmt.allocPrint(
        alloc,
        "{{\"name\":{s},\"version\":{s},\"build\":{d},\"arch\":{s},\"locale\":{s},\"theme\":\"{s}\",\"accentColor\":\"#{x:0>8}\"}}",
        .{ name, version, info.build, arch, locale, @tagName(info.theme), info.accent_color },
    );
}

pub fn monitorsToJson(alloc: Allocator, monitors: []const Monitor) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "[");
    for (monitors, 0..) |m, i| {
        if (i != 0) try out.appendSlice(alloc, ",");
        const chunk = try std.fmt.allocPrint(
            alloc,
            "{{\"index\":{d},\"primary\":{},\"current\":{},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}," ++
                "\"workX\":{d},\"workY\":{d},\"workWidth\":{d},\"workHeight\":{d},\"dpi\":{d},\"scale\":{d:.2}}}",
            .{ m.index, m.primary, m.current, m.x, m.y, m.width, m.height, m.work_x, m.work_y, m.work_width, m.work_height, m.dpi, m.scale },
        );
        defer alloc.free(chunk);
        try out.appendSlice(alloc, chunk);
    }
    try out.appendSlice(alloc, "]");
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "product name inference" {
    try testing.expectEqualStrings("Windows 11", productName(10, 0, 22631));
    try testing.expectEqualStrings("Windows 10", productName(10, 0, 19045));
    try testing.expectEqualStrings("Windows 8.1", productName(6, 3, 9600));
    try testing.expectEqualStrings("Windows", productName(5, 1, 2600));
}

test "version formatting and dpi scale" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("10.0.22631", try formatVersion(&buf, 10, 0, 22631));
    try testing.expectApproxEqAbs(@as(f64, 1.5), scaleFromDpi(144), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), scaleFromDpi(96), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), scaleFromDpi(0), 0.0001);
}

test "os info json shape" {
    const json = try osToJson(testing.allocator, .{
        .name = "Windows 11",
        .version = "10.0.22631",
        .build = 22631,
        .arch = "x86_64",
        .locale = "zh-CN",
        .theme = .dark,
        .accent_color = 0xFF0078D4,
    });
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("Windows 11", obj.get("name").?.string);
    try testing.expectEqual(@as(i64, 22631), obj.get("build").?.integer);
    try testing.expectEqualStrings("dark", obj.get("theme").?.string);
    try testing.expectEqualStrings("#ff0078d4", obj.get("accentColor").?.string);
}

test "monitor json is an array with scale" {
    const monitors = [_]Monitor{
        .{ .index = 0, .primary = true, .width = 2560, .height = 1440, .dpi = 144, .scale = 1.5 },
        .{ .index = 1, .x = 2560, .width = 1920, .height = 1080 },
    };
    const json = try monitorsToJson(testing.allocator, &monitors);
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try testing.expect(parsed.value.array.items[0].object.get("primary").?.bool);
    try testing.expectApproxEqAbs(@as(f64, 1.5), parsed.value.array.items[0].object.get("scale").?.float, 0.001);
}
