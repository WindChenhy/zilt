//! 加速键（accelerator）字符串解析、格式化与冲突检测（v0.1.13）。
//!
//! 纯逻辑、无平台依赖：`"Ctrl+Shift+K"` → `{ mods, vk }`，`vk` 为 Win32 虚拟键码，
//! 因此同一份解析结果既可用于 `RegisterHotKey`（全局快捷键）也可用于菜单项展示
//! （`\tCtrl+K` 后缀）与键盘处理（`WM_KEYDOWN`）。
//!
//! 支持的写法（大小写不敏感）：
//!  - 修饰符：`Ctrl`/`Control`、`Alt`、`Shift`、`Win`/`Super`/`Meta`/`Cmd`
//!  - 主键：`A`–`Z`、`0`–`9`、`F1`–`F24`、命名键（`Space`/`Enter`/`Escape`/`PageDown`…）
//!  - 分隔符：`+`（也接受 `-` 与空格，便于读取人类书写的快捷键）
const std = @import("std");

pub const MOD_ALT: u32 = 0x0001;
pub const MOD_CONTROL: u32 = 0x0002;
pub const MOD_SHIFT: u32 = 0x0004;
pub const MOD_WIN: u32 = 0x0008;
/// 仅用于展示：不参与修饰符位运算。
pub const MOD_NOREPEAT: u32 = 0x4000;

pub const Modifiers = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    win: bool = false,

    pub fn flags(self: Modifiers) u32 {
        var bits: u32 = 0;
        if (self.ctrl) bits |= MOD_CONTROL;
        if (self.alt) bits |= MOD_ALT;
        if (self.shift) bits |= MOD_SHIFT;
        if (self.win) bits |= MOD_WIN;
        return bits;
    }

    pub fn fromFlags(bits: u32) Modifiers {
        return .{
            .ctrl = bits & MOD_CONTROL != 0,
            .alt = bits & MOD_ALT != 0,
            .shift = bits & MOD_SHIFT != 0,
            .win = bits & MOD_WIN != 0,
        };
    }

    pub fn count(self: Modifiers) u8 {
        return @as(u8, @intFromBool(self.ctrl)) + @intFromBool(self.alt) +
            @intFromBool(self.shift) + @intFromBool(self.win);
    }
};

pub const Accel = struct {
    mods: Modifiers = .{},
    vk: u8 = 0,

    pub fn equal(a: Accel, b: Accel) bool {
        return a.vk == b.vk and a.mods.flags() == b.mods.flags();
    }
};

pub const ParseError = error{
    EmptyAccelerator,
    MissingKey,
    UnknownKey,
    DuplicateModifier,
};

const KeyName = struct { name: []const u8, vk: u8 };

/// 命名键表（展示名与解析名一致，均为首字母大写形式）。
const named_keys = [_]KeyName{
    .{ .name = "Space", .vk = 0x20 },
    .{ .name = "Enter", .vk = 0x0D },
    .{ .name = "Return", .vk = 0x0D },
    .{ .name = "Tab", .vk = 0x09 },
    .{ .name = "Escape", .vk = 0x1B },
    .{ .name = "Esc", .vk = 0x1B },
    .{ .name = "Backspace", .vk = 0x08 },
    .{ .name = "Delete", .vk = 0x2E },
    .{ .name = "Insert", .vk = 0x2D },
    .{ .name = "Home", .vk = 0x24 },
    .{ .name = "End", .vk = 0x23 },
    .{ .name = "PageUp", .vk = 0x21 },
    .{ .name = "PageDown", .vk = 0x22 },
    .{ .name = "Left", .vk = 0x25 },
    .{ .name = "Up", .vk = 0x26 },
    .{ .name = "Right", .vk = 0x27 },
    .{ .name = "Down", .vk = 0x28 },
    .{ .name = "PrintScreen", .vk = 0x2C },
    .{ .name = "Pause", .vk = 0x13 },
    .{ .name = "CapsLock", .vk = 0x14 },
    .{ .name = "NumLock", .vk = 0x90 },
    .{ .name = "ScrollLock", .vk = 0x91 },
    .{ .name = "Plus", .vk = 0xBB },
    .{ .name = "Minus", .vk = 0xBD },
    .{ .name = "Comma", .vk = 0xBC },
    .{ .name = "Period", .vk = 0xBE },
    .{ .name = "Slash", .vk = 0xBF },
    .{ .name = "Semicolon", .vk = 0xBA },
    .{ .name = "Quote", .vk = 0xDE },
    .{ .name = "BracketLeft", .vk = 0xDB },
    .{ .name = "BracketRight", .vk = 0xDD },
    .{ .name = "Backslash", .vk = 0xDC },
    .{ .name = "Backquote", .vk = 0xC0 },
    .{ .name = "Numpad0", .vk = 0x60 },
    .{ .name = "Numpad1", .vk = 0x61 },
    .{ .name = "Numpad2", .vk = 0x62 },
    .{ .name = "Numpad3", .vk = 0x63 },
    .{ .name = "Numpad4", .vk = 0x64 },
    .{ .name = "Numpad5", .vk = 0x65 },
    .{ .name = "Numpad6", .vk = 0x66 },
    .{ .name = "Numpad7", .vk = 0x67 },
    .{ .name = "Numpad8", .vk = 0x68 },
    .{ .name = "Numpad9", .vk = 0x69 },
    .{ .name = "Multiply", .vk = 0x6A },
    .{ .name = "Add", .vk = 0x6B },
    .{ .name = "Subtract", .vk = 0x6D },
    .{ .name = "Decimal", .vk = 0x6E },
    .{ .name = "Divide", .vk = 0x6F },
};

fn isSeparator(c: u8) bool {
    return c == '+' or c == '-' or c == ' ';
}

fn trimSeparators(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isSeparator(s[start])) start += 1;
    while (end > start and isSeparator(s[end - 1])) end -= 1;
    return s[start..end];
}

fn modifierFromToken(tok: []const u8) ?Modifiers {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(tok, "ctrl") or eql(tok, "control") or eql(tok, "cmdorctrl")) return .{ .ctrl = true };
    if (eql(tok, "alt") or eql(tok, "option")) return .{ .alt = true };
    if (eql(tok, "shift")) return .{ .shift = true };
    if (eql(tok, "win") or eql(tok, "super") or eql(tok, "meta") or eql(tok, "cmd") or eql(tok, "command")) return .{ .win = true };
    return null;
}

/// 主键名 → VK。接受单字符（A-Z/0-9 及若干标点）、F1-F24、命名键。
pub fn vkFromName(name: []const u8) ?u8 {
    const raw = trimSeparators(name);
    if (raw.len == 0) return null;
    if (raw.len == 1) {
        const c = raw[0];
        if (c >= 'a' and c <= 'z') return c - 32;
        if (c >= 'A' and c <= 'Z') return c;
        if (c >= '0' and c <= '9') return c;
        return switch (c) {
            '+' => 0xBB,
            '-' => 0xBD,
            ',' => 0xBC,
            '.' => 0xBE,
            '/' => 0xBF,
            ';' => 0xBA,
            '\'' => 0xDE,
            '[' => 0xDB,
            ']' => 0xDD,
            '\\' => 0xDC,
            '`' => 0xC0,
            else => null,
        };
    }
    // F1-F24
    if ((raw[0] == 'f' or raw[0] == 'F') and raw.len <= 3) {
        const n = std.fmt.parseInt(u8, raw[1..], 10) catch return null;
        if (n >= 1 and n <= 24) return 0x70 + (n - 1);
        return null;
    }
    for (named_keys) |k| {
        if (std.ascii.eqlIgnoreCase(raw, k.name)) return k.vk;
    }
    return null;
}

/// 解析加速键字符串。空串 → EmptyAccelerator；无主键 → MissingKey。
pub fn parse(text: []const u8) ParseError!Accel {
    const src = trimSeparators(text);
    if (src.len == 0) return error.EmptyAccelerator;

    var mods = Modifiers{};
    var accel = Accel{};
    var has_key = false;

    var it = std.mem.splitAny(u8, src, "+- ");
    while (it.next()) |raw_tok| {
        const tok = trimSeparators(raw_tok);
        if (tok.len == 0) continue;
        if (modifierFromToken(tok)) |m| {
            if (m.ctrl) {
                if (mods.ctrl) return error.DuplicateModifier;
                mods.ctrl = true;
            }
            if (m.alt) {
                if (mods.alt) return error.DuplicateModifier;
                mods.alt = true;
            }
            if (m.shift) {
                if (mods.shift) return error.DuplicateModifier;
                mods.shift = true;
            }
            if (m.win) {
                if (mods.win) return error.DuplicateModifier;
                mods.win = true;
            }
            continue;
        }
        if (has_key) return error.UnknownKey; // 第二个非修饰符 token
        accel.vk = vkFromName(tok) orelse return error.UnknownKey;
        has_key = true;
    }
    if (!has_key) return error.MissingKey;
    accel.mods = mods;
    return accel;
}

/// VK → 展示名（A-Z / 0-9 直接返回字符，其余查命名键表）。
pub fn keyName(vk: u8, buf: []u8) ?[]const u8 {
    if (buf.len == 0) return null;
    if ((vk >= 'A' and vk <= 'Z') or (vk >= '0' and vk <= '9')) {
        buf[0] = vk;
        return buf[0..1];
    }
    if (vk >= 0x70 and vk <= 0x87) {
        return std.fmt.bufPrint(buf, "F{d}", .{vk - 0x70 + 1}) catch null;
    }
    for (named_keys) |k| {
        // 优先返回首个（规范名），跳过别名（Return/Esc）
        if (k.vk != vk) continue;
        if (std.mem.eql(u8, k.name, "Return") or std.mem.eql(u8, k.name, "Esc")) continue;
        if (k.name.len > buf.len) return null;
        @memcpy(buf[0..k.name.len], k.name);
        return buf[0..k.name.len];
    }
    return null;
}

/// 格式化展示文本（Windows 习惯顺序：Ctrl+Alt+Shift+Win+Key）。
pub fn formatBuf(buf: []u8, accel: Accel) ?[]const u8 {
    var n: usize = 0;
    const parts = [_]struct { on: bool, name: []const u8 }{
        .{ .on = accel.mods.ctrl, .name = "Ctrl" },
        .{ .on = accel.mods.alt, .name = "Alt" },
        .{ .on = accel.mods.shift, .name = "Shift" },
        .{ .on = accel.mods.win, .name = "Win" },
    };
    for (parts) |p| {
        if (!p.on) continue;
        if (n != 0) {
            if (n >= buf.len) return null;
            buf[n] = '+';
            n += 1;
        }
        if (n + p.name.len > buf.len) return null;
        @memcpy(buf[n .. n + p.name.len], p.name);
        n += p.name.len;
    }
    var key_buf: [32]u8 = undefined;
    const key = keyName(accel.vk, &key_buf) orelse return null;
    if (n != 0) {
        if (n >= buf.len) return null;
        buf[n] = '+';
        n += 1;
    }
    if (n + key.len > buf.len) return null;
    @memcpy(buf[n .. n + key.len], key);
    n += key.len;
    return buf[0..n];
}

/// 菜单项展示用后缀（`\tCtrl+K`）；无修饰符也返回，调用方自行决定是否使用。
pub fn menuSuffix(buf: []u8, accel: Accel) ?[]const u8 {
    const text = formatBuf(buf, accel) orelse return null;
    return text;
}

/// 冲突检测：返回首个与 `candidate` 重复的注册 id（同 VK + 同修饰符）。
pub fn findConflict(
    ids: []const []const u8,
    accels: []const Accel,
    candidate: Accel,
    skip_index: ?usize,
) ?[]const u8 {
    for (accels, 0..) |a, i| {
        if (skip_index) |s| {
            if (s == i) continue;
        }
        if (a.equal(candidate)) return ids[i];
    }
    return null;
}

const testing = std.testing;

test "parse modifiers and simple keys" {
    const a = try parse("Ctrl+Shift+K");
    try testing.expect(a.mods.ctrl and a.mods.shift and !a.mods.alt and !a.mods.win);
    try testing.expectEqual(@as(u8, 'K'), a.vk);

    const b = try parse("ctrl+k");
    try testing.expectEqual(@as(u8, 'K'), b.vk);
    try testing.expect(b.mods.ctrl);

    const c = try parse("F12");
    try testing.expectEqual(@as(u8, 0x7B), c.vk);
    try testing.expectEqual(@as(u8, 0), c.mods.count());
}

test "parse rejects malformed input" {
    try testing.expectError(error.EmptyAccelerator, parse("   "));
    try testing.expectError(error.MissingKey, parse("Ctrl+Shift"));
    try testing.expectError(error.UnknownKey, parse("Ctrl+Bogus"));
    try testing.expectError(error.DuplicateModifier, parse("Ctrl+Ctrl+K"));
    try testing.expectError(error.UnknownKey, parse("Ctrl+K+L"));
    try testing.expectError(error.UnknownKey, parse("F25"));
}

test "parse separators and named keys" {
    const a = try parse("Ctrl-PageDown");
    try testing.expectEqual(@as(u8, 0x22), a.vk);
    const b = try parse("Alt + Space");
    try testing.expectEqual(@as(u8, 0x20), b.vk);
    try testing.expect(b.mods.alt);
    const c = try parse("Win+D");
    try testing.expectEqual(@as(u8, 'D'), c.vk);
    try testing.expect(c.mods.win);
}

test "format roundtrips through parse" {
    var buf: [64]u8 = undefined;
    const cases = [_]struct { text: []const u8, normalized: []const u8 }{
        .{ .text = "ctrl+shift+k", .normalized = "Ctrl+Shift+K" },
        .{ .text = "Alt+F4", .normalized = "Alt+F4" },
        .{ .text = "Super+Space", .normalized = "Win+Space" },
        .{ .text = "PageUp", .normalized = "PageUp" },
    };
    for (cases) |c| {
        const accel = try parse(c.text);
        const out = formatBuf(&buf, accel) orelse return error.FormatFailed;
        try testing.expectEqualStrings(c.normalized, out);
        // 归一化文本必须能被再次解析成同一加速键
        const again = try parse(out);
        try testing.expect(accel.equal(again));
    }
}

test "flags and fromFlags are inverse" {
    const m = Modifiers{ .ctrl = true, .alt = true, .win = true };
    try testing.expectEqual(MOD_CONTROL | MOD_ALT | MOD_WIN, m.flags());
    const back = Modifiers.fromFlags(m.flags());
    try testing.expect(back.ctrl and back.alt and back.win and !back.shift);
    try testing.expectEqual(@as(u8, 3), back.count());
}

test "conflict detection skips the edited entry" {
    var list: [3]Accel = undefined;
    list[0] = try parse("Ctrl+K");
    list[1] = try parse("Ctrl+Shift+K");
    list[2] = try parse("Ctrl+K");
    const ids = [_][]const u8{ "save", "saveAs", "command-k" };
    const candidate = try parse("Ctrl+K");
    try testing.expectEqualStrings("save", findConflict(&ids, &list, candidate, 2).?);
    try testing.expectEqualStrings("command-k", findConflict(&ids, &list, candidate, 0).?);
    try testing.expectEqual(@as(?[]const u8, null), findConflict(&ids, &list, try parse("Ctrl+J"), null));
}

test "keyName covers function keys and aliases" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("F1", keyName(0x70, &buf).?);
    try testing.expectEqualStrings("F24", keyName(0x87, &buf).?);
    try testing.expectEqualStrings("Enter", keyName(0x0D, &buf).?);
    try testing.expectEqualStrings("Escape", keyName(0x1B, &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), keyName(0x01, &buf));
}
