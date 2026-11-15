//! Desktop entry（.desktop）生成与自启动状态（v0.2.2，Linux 纯逻辑）。
//!
//! 三处使用（文件落盘与 xdg-mime 调用在 backend.zig）：
//!   - 深链注册：`~/.local/share/applications/<app_id>.desktop`
//!     （`MimeType=x-scheme-handler/<scheme>[;…]`，随后 `xdg-mime default` 指向它）
//!   - 自启动：`~/.config/autostart/<app_id>.desktop`
//!     （`X-GNOME-Autostart-enabled=true`；disable = 删除文件）
//!   - v0.2.4 打包：deb/rpm 系统级 .desktop 同一生成器
//!
//! Exec 字段按 desktop entry 规范：含空格的路径用双引号包住（`\"` 转义），
//! 参数原样追加；`%` 在字段值里是字段码前缀，必须转义为 `%%`。
const std = @import("std");
const autostart_shared = @import("../../autostart.zig");

const Allocator = std.mem.Allocator;

pub const EntryOptions = struct {
    /// 显示名（Name=）
    name: []const u8,
    /// 绝对路径（可带参数；经 formatExec 转义）
    exec: []const u8,
    /// 图标（主题图标名或绝对路径；null = 省略）
    icon: ?[]const u8 = null,
    /// 描述（Comment=；null = 省略）
    comment: ?[]const u8 = null,
    /// MimeType= 列表（";" 连接；空 = 省略）
    mime_types: []const []const u8 = &.{},
    /// StartupWMClass（默认与应用窗口类匹配；null = 省略）
    wmclass: ?[]const u8 = null,
    /// 自启动条目（autostart 目录）需要 X-GNOME-Autostart-enabled=true
    autostart: bool = false,
};

/// Exec= 值构造：含空格/引号的路径加双引号，内部 `"` 与 `%` 转义。
pub fn formatExec(alloc: Allocator, exe: []const u8, args: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    const needs_quote = std.mem.indexOfAny(u8, exe, " \t") != null;
    if (needs_quote) try out.append(alloc, '"');
    for (exe) |ch| {
        if (ch == '"') try out.append(alloc, '\\');
        try out.append(alloc, ch);
    }
    if (needs_quote) try out.append(alloc, '"');
    if (args) |rest| {
        if (rest.len > 0) {
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, rest);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// 字段值转义：`%` → `%%`（desktop entry 的字段码前缀）、换行非法 → 空格。
pub fn escapeValue(alloc: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (raw) |ch| {
        switch (ch) {
            '%' => try out.appendSlice(alloc, "%%"),
            '\n', '\r' => try out.append(alloc, ' '),
            else => try out.append(alloc, ch),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// 生成 [Desktop Entry] 全文（UTF-8，行尾 \n）。
pub fn content(alloc: Allocator, opts: EntryOptions) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "[Desktop Entry]\n");
    try out.appendSlice(alloc, "Type=Application\n");
    try appendField(alloc, &out, "Name", opts.name);
    if (opts.comment) |cm| try appendField(alloc, &out, "Comment", cm);
    try appendField(alloc, &out, "Exec", opts.exec);
    if (opts.icon) |icon| if (icon.len > 0) try appendField(alloc, &out, "Icon", icon);
    try out.appendSlice(alloc, "Terminal=false\n");
    if (opts.mime_types.len > 0) {
        try out.appendSlice(alloc, "MimeType=");
        for (opts.mime_types, 0..) |mime, i| {
            if (i != 0) try out.append(alloc, ';');
            try out.appendSlice(alloc, mime);
        }
        try out.appendSlice(alloc, ";\n");
    }
    if (opts.wmclass) |wc| if (wc.len > 0) try appendField(alloc, &out, "StartupWMClass", wc);
    if (opts.autostart) try out.appendSlice(alloc, "X-GNOME-Autostart-enabled=true\n");
    return out.toOwnedSlice(alloc);
}

fn appendField(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), key: []const u8, value: []const u8) !void {
    const escaped = try escapeValue(alloc, value);
    defer alloc.free(escaped);
    try out.appendSlice(alloc, key);
    try out.append(alloc, '=');
    try out.appendSlice(alloc, escaped);
    try out.append(alloc, '\n');
}

/// 自启动条目文件名：`<app_id>.desktop`（多应用互不覆盖）。
/// app_id 已以 .desktop 结尾时不重复拼接（v0.2.7 修正：`app.zilt.desktop`
/// 这类反域名 app_id 此前会生成 `app.zilt.desktop.desktop`）。
pub fn entryFileName(alloc: Allocator, app_id: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, app_id, ".desktop")) return alloc.dupe(u8, app_id);
    return std.fmt.allocPrint(alloc, "{s}.desktop", .{app_id});
}

/// 解析自启动状态：文件存在 + Exec 指向当前 exe（忽略参数差异）+ 未被显式禁用。
pub fn autostartState(alloc: Allocator, text: ?[]const u8, exe: []const u8) autostart_shared.State {
    _ = alloc; // 返回的 command 借用 text；调用方需要生命周期时自行 dupe
    const body = text orelse return .{ .enabled = false, .command = null };
    if (body.len == 0) return .{ .enabled = false, .command = null };
    var exec_value: ?[]const u8 = null;
    var disabled = false;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (std.mem.startsWith(u8, line, "Exec=")) exec_value = line["Exec=".len..];
        if (std.ascii.eqlIgnoreCase(line, "X-GNOME-Autostart-enabled=false")) disabled = true;
    }
    const command = exec_value orelse return .{ .enabled = false, .command = null };
    if (disabled or !autostart_shared.matchesExe(command, exe)) {
        return .{ .enabled = false, .command = command };
    }
    return .{ .enabled = true, .command = command };
}

/// xdg-mime default <desktop> <mime> 的 argv（注册 scheme handler / 文件关联）。
pub fn xdgMimeDefaultArgs(alloc: Allocator, desktop_name: []const u8, mime: []const u8) ![]const []const u8 {
    const argv = try alloc.alloc([]const u8, 4);
    errdefer alloc.free(argv);
    argv[0] = "xdg-mime";
    argv[1] = "default";
    argv[2] = try alloc.dupe(u8, desktop_name);
    argv[3] = try alloc.dupe(u8, mime);
    return argv;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "formatExec: 空格路径加引号、参数追加" {
    const a = testing.allocator;
    const plain = try formatExec(a, "/opt/app/bin", null);
    defer a.free(plain);
    try testing.expectEqualStrings("/opt/app/bin", plain);

    const quoted = try formatExec(a, "/opt/My App/bin", "--hidden");
    defer a.free(quoted);
    try testing.expectEqualStrings("\"/opt/My App/bin\" --hidden", quoted);

    const esc = try formatExec(a, "/we\"ird/app", null);
    defer a.free(esc);
    try testing.expectEqualStrings("\"/we\\\"ird/app\"", esc);
}

test "escapeValue: 百分号转义与换行清洗" {
    const a = testing.allocator;
    const v = try escapeValue(a, "100% \nDone");
    defer a.free(v);
    try testing.expectEqualStrings("100%%  Done", v);
}

test "content: 深链注册条目（scheme + 文件 MIME）" {
    const a = testing.allocator;
    const exec = try formatExec(a, "/opt/My App/zilt-app", "%u");
    defer a.free(exec);
    const text = try content(a, .{
        .name = "Zilt Demo",
        .exec = exec,
        .icon = "zilt-demo",
        .comment = "Demo app",
        .mime_types = &.{ "x-scheme-handler/zilt", "application/x-demo" },
        .wmclass = "app.zilt.demo",
    });
    defer a.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "[Desktop Entry]\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Type=Application\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Name=Zilt Demo\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Exec=\"/opt/My App/zilt-app\" %u\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "MimeType=x-scheme-handler/zilt;application/x-demo;\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "StartupWMClass=app.zilt.demo\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "X-GNOME-Autostart-enabled") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Terminal=false\n") != null);
}

test "content: 自启动条目带 enabled 标记" {
    const a = testing.allocator;
    const text = try content(a, .{ .name = "Z", .exec = "/bin/app", .autostart = true });
    defer a.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "X-GNOME-Autostart-enabled=true\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "MimeType=") == null);
}

test "autostartState: enabled / disabled / exe 不匹配" {
    const a = testing.allocator;
    const exe = "/opt/My App/zilt-app";

    const enabled_text = try content(a, .{ .name = "Z", .exec = try formatExec(a, exe, null), .autostart = true });
    defer a.free(enabled_text);
    const on = autostartState(a, enabled_text, exe);
    try testing.expect(on.enabled);
    try testing.expect(on.command != null);

    const off_text = try content(a, .{ .name = "Z", .exec = try formatExec(a, exe, null), .autostart = false });
    defer a.free(off_text);
    // 无 X-GNOME-Autostart-enabled 行不算禁用（enabled=true 语义由文件存在性承载）
    try testing.expect(autostartState(a, off_text, exe).enabled);

    const explicit_off = try std.fmt.allocPrint(a, "{s}X-GNOME-Autostart-enabled=false\n", .{off_text});
    defer a.free(explicit_off);
    try testing.expect(!autostartState(a, explicit_off, exe).enabled);

    try testing.expect(!autostartState(a, enabled_text, "/opt/other/app").enabled);
    try testing.expect(!autostartState(a, null, exe).enabled);
    try testing.expect(!autostartState(a, "", exe).enabled);
}

test "xdgMimeDefaultArgs: argv 形状" {
    const a = testing.allocator;
    const argv = try xdgMimeDefaultArgs(a, "app.zilt.desktop", "x-scheme-handler/zilt");
    defer {
        for (argv) |part| a.free(part);
        a.free(argv);
    }
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("xdg-mime", argv[0]);
    try testing.expectEqualStrings("default", argv[1]);
    try testing.expectEqualStrings("app.zilt.desktop", argv[2]);
    try testing.expectEqualStrings("x-scheme-handler/zilt", argv[3]);
}

test "entryFileName: 已带 .desktop 后缀不重复拼接" {
    const a = testing.allocator;
    {
        const n = try entryFileName(a, "com.example.app");
        defer a.free(n);
        try testing.expectEqualStrings("com.example.app.desktop", n);
    }
    {
        const n = try entryFileName(a, "app.zilt.desktop");
        defer a.free(n);
        try testing.expectEqualStrings("app.zilt.desktop", n);
    }
}

test "entryFileName" {
    const a = testing.allocator;
    const n = try entryFileName(a, "app.zilt.desktop");
    defer a.free(n);
    try testing.expectEqualStrings("app.zilt.desktop.desktop", n);
}
