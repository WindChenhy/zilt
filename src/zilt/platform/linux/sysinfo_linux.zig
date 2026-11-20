//! 系统信息采集（Linux 侧纯逻辑，v0.2.2）。
//!
//! Windows 的对应物是 `platform/windows/sysinfo.zig`（RtlGetVersion/EnumDisplayMonitors）；
//! Linux 侧：
//!   - OS：`/etc/os-release`（PRETTY_NAME / VERSION_ID）+ 内核（uname）
//!   - arch / locale：builtin.cpu.arch 与 LC_ALL/LANG 环境变量
//!   - 主题：GtkSettings 的 gtk-theme-name 含 "dark" → .dark（backend 里读）
//!   - 显示器几何：GDK（backend 里采，JSON 走共享 `sysinfo.monitorsToJson`）
const std = @import("std");
const shared = @import("../../sysinfo.zig");

const Allocator = std.mem.Allocator;

/// /etc/os-release 里关心的字段。
pub const OsRelease = struct {
    /// PRETTY_NAME（"Ubuntu 22.04.5 LTS"）；缺失回退 NAME，再缺失 "Linux"
    name: []u8,
    /// VERSION_ID（"22.04"）；缺失 "0.0"
    version: []u8,
};

/// 解析 os-release 文本（KEY=VALUE 行，值可带引号；`#` 注释行跳过）。
pub fn parseOsRelease(alloc: Allocator, text: []const u8) !OsRelease {
    var name: ?[]u8 = null;
    var version: ?[]u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = unquote(line[eq + 1 ..]);
        if (std.mem.eql(u8, key, "PRETTY_NAME")) {
            if (name) |old| alloc.free(old);
            name = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "VERSION_ID")) {
            if (version) |old| alloc.free(old);
            version = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "NAME") and name == null) {
            name = try alloc.dupe(u8, value);
        }
    }
    return .{
        .name = name orelse try alloc.dupe(u8, "Linux"),
        .version = version orelse try alloc.dupe(u8, "0.0"),
    };
}

pub fn freeOsRelease(alloc: Allocator, r: *OsRelease) void {
    alloc.free(r.name);
    alloc.free(r.version);
    r.* = .{ .name = &.{}, .version = &.{} };
}

fn unquote(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len >= 2) {
        const first = trimmed[0];
        const last = trimmed[trimmed.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return trimmed[1 .. trimmed.len - 1];
        }
    }
    return trimmed;
}

/// locale：LC_ALL 优先于 LANG；`zh_CN.UTF-8` → `zh-CN`（去 codeset/@modifier）。
/// 空/POSIX/C → "en-US"（对齐 OsInfo 默认）。
pub fn localeFromEnv(alloc: Allocator, lc_all: ?[]const u8, lang: ?[]const u8) ![]u8 {
    const raw = blk: {
        if (lc_all) |v| {
            if (v.len > 0) break :blk v;
        }
        if (lang) |v| {
            if (v.len > 0) break :blk v;
        }
        break :blk "";
    };
    var base = raw;
    if (std.mem.indexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
    if (std.mem.indexOfScalar(u8, base, '@')) |at| base = base[0..at];
    if (base.len < 2 or std.ascii.eqlIgnoreCase(base, "C") or std.ascii.eqlIgnoreCase(base, "POSIX")) {
        return alloc.dupe(u8, "en-US");
    }
    const out = try alloc.dupe(u8, base);
    for (out) |*ch| {
        if (ch.* == '_') ch.* = '-';
    }
    return out;
}

/// GtkSettings 的 gtk-theme-name 是否表示深色（"Adwaita-dark"、"Yaru-dark"…）。
pub fn isDarkThemeName(name: ?[]const u8) bool {
    const n = name orelse return false;
    return std.mem.indexOf(u8, n, "dark") != null or std.mem.indexOf(u8, n, "Dark") != null;
}

/// 内核版本（uname release，如 "5.15.167.4-microsoft-standard-WSL2"）。
pub fn kernelVersion(buf: []u8) []const u8 {
    // 0.17：uname 直接返回 utsname（不再有返回码）
    const uts = std.posix.uname();
    const release = std.mem.span(@as([*:0]const u8, @ptrCast(&uts.release)));
    const n = @min(release.len, buf.len);
    @memcpy(buf[0..n], release[0..n]);
    return buf[0..n];
}

/// 组装 OsInfo（version 字段 = VERSION_ID + " (" + kernel + ")"，与 Windows 的
/// "10.0.22631" 同为展示用自由文本；build 字段 Linux 无对应物，恒 0）。
pub fn osInfo(alloc: Allocator, release: OsRelease, locale: []const u8, dark: bool) !shared.OsInfo {
    return .{
        .name = try alloc.dupe(u8, release.name),
        .version = try alloc.dupe(u8, release.version),
        .build = 0,
        .arch = @tagName(@import("builtin").cpu.arch),
        .locale = try alloc.dupe(u8, locale),
        .theme = if (dark) .dark else .light,
        .accent_color = 0, // Linux 无全局强调色概念
    };
}

pub fn freeOsInfo(alloc: Allocator, info: *shared.OsInfo) void {
    alloc.free(info.name);
    alloc.free(info.version);
    alloc.free(info.locale);
    info.* = .{};
}

// ---------------------------------------------------------------------------
// v0.4.0 H11：GPU（/sys/class/drm/card*/device 解析——纯函数部分）
// ---------------------------------------------------------------------------

/// uevent 文本的 DRIVER= 值（无则 null）。
pub fn driverFromUevent(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "DRIVER=")) return line["DRIVER=".len..];
    }
    return null;
}

/// sysfs 的 hex id 文本（"0x8086\n"）→ u32。
pub fn parseHexId(text: []const u8) ?u32 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "0x") or t.len <= 2) return null;
    return std.fmt.parseInt(u32, t[2..], 16) catch null;
}

/// GPU 名："card0 [8086:9b41]"（vendor/device 原始 id 并入——语义名由
/// shared_sysinfo.vendorFromPciId 给出）。
pub fn gpuName(alloc: Allocator, card: []const u8, vendor_id: u32, device_id: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s} [{x:0>4}:{x:0>4}]", .{ card, vendor_id, device_id });
}

/// 释放 backend collectGpus 的产物（name/vendor/driver 全为堆分配）。
pub fn freeGpus(alloc: Allocator, gpus: []shared.GpuInfo) void {
    for (gpus) |*g| {
        alloc.free(g.name);
        alloc.free(g.vendor);
        if (g.driver.len > 0) alloc.free(g.driver);
    }
    alloc.free(gpus);
}

test "driverFromUevent / parseHexId / gpuName" {
    const uevent = "DRIVER=pci\nMODALIAS=pci:v00008086d00009B41\n";
    try testing.expectEqualStrings("pci", driverFromUevent(uevent).?);
    try testing.expect(driverFromUevent("MODALIAS=x\n") == null);
    try testing.expectEqual(@as(u32, 0x8086), parseHexId("0x8086\n").?);
    try testing.expect(parseHexId("8086") == null);
    try testing.expect(parseHexId("0x") == null);
    const name = try gpuName(testing.allocator, "card0", 0x8086, 0x9b41);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("card0 [8086:9b41]", name);
}

test "freeGpus roundtrip" {
    const gpus = try testing.allocator.alloc(shared.GpuInfo, 2);
    gpus[0] = .{ .name = try testing.allocator.dupe(u8, "card0 [8086:9b41]"), .vendor = try testing.allocator.dupe(u8, "Intel"), .driver = try testing.allocator.dupe(u8, "pci") };
    gpus[1] = .{ .name = try testing.allocator.dupe(u8, "card1"), .vendor = try testing.allocator.dupe(u8, "unknown") };
    freeGpus(testing.allocator, gpus);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

const sample_release =
    "# comment line\n" ++
    "NAME=\"Ubuntu\"\n" ++
    "VERSION_ID=\"22.04\"\n" ++
    "PRETTY_NAME=\"Ubuntu 22.04.5 LTS\"\n" ++
    "HOME_URL=\"https://www.ubuntu.com/\"\n";

test "parseOsRelease: 引号值 / 注释 / 回退链" {
    const a = testing.allocator;
    var r = try parseOsRelease(a, sample_release);
    defer freeOsRelease(a, &r);
    try testing.expectEqualStrings("Ubuntu 22.04.5 LTS", r.name);
    try testing.expectEqualStrings("22.04", r.version);

    var r2 = try parseOsRelease(a, "NAME=Fedora Linux\n");
    defer freeOsRelease(a, &r2);
    try testing.expectEqualStrings("Fedora Linux", r2.name);
    try testing.expectEqualStrings("0.0", r2.version);

    var r3 = try parseOsRelease(a, "");
    defer freeOsRelease(a, &r3);
    try testing.expectEqualStrings("Linux", r3.name);
}

test "localeFromEnv: codeset/modifier 剥离与 POSIX 回退" {
    const a = testing.allocator;
    const cases = [_]struct { lc: ?[]const u8, lang: ?[]const u8, want: []const u8 }{
        .{ .lc = "zh_CN.UTF-8", .lang = "en_US.UTF-8", .want = "zh-CN" },
        .{ .lc = null, .lang = "de_DE@euro", .want = "de-DE" },
        .{ .lc = "C", .lang = "zh_CN", .want = "en-US" },
        .{ .lc = null, .lang = null, .want = "en-US" },
        .{ .lc = "", .lang = "POSIX", .want = "en-US" },
    };
    for (cases) |tc| {
        const got = try localeFromEnv(a, tc.lc, tc.lang);
        defer a.free(got);
        try testing.expectEqualStrings(tc.want, got);
    }
}

test "isDarkThemeName" {
    try testing.expect(isDarkThemeName("Adwaita-dark"));
    try testing.expect(isDarkThemeName("Yaru-dark"));
    try testing.expect(!isDarkThemeName("Adwaita"));
    try testing.expect(!isDarkThemeName(null));
}

test "osInfo: 字段组装" {
    const a = testing.allocator;
    var r = try parseOsRelease(a, sample_release);
    defer freeOsRelease(a, &r);
    var info = try osInfo(a, r, "zh-CN", true);
    defer freeOsInfo(a, &info);
    try testing.expectEqualStrings("Ubuntu 22.04.5 LTS", info.name);
    try testing.expectEqualStrings("zh-CN", info.locale);
    try testing.expectEqual(shared.Theme.dark, info.theme);
    try testing.expect(info.build == 0);
}

test "kernelVersion: 缓冲区形状" {
    var buf: [64]u8 = undefined;
    const v = kernelVersion(&buf);
    // uname 在 Linux 测试进程可用；非 Linux 环境返回空切片
    try testing.expect(v.len <= buf.len);
}
