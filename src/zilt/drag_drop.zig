//! Shared drag/drop values. All callback data is borrowed until the callback returns.

pub const Kind = enum { enter, over, leave, drop };

pub const CustomFormat = struct {
    /// Registered clipboard format name, UTF-8.
    name: []const u8,
    /// Raw HGLOBAL bytes, including any allocator padding. Formats needing an exact
    /// logical length must encode that length in their own payload.
    data: []const u8,
};

pub const Event = struct {
    kind: Kind,
    /// Client coordinates; leave uses the last enter/over position.
    x: i32,
    y: i32,
    /// UTF-8 paths. No files are moved or deleted by Zilt.
    files: []const []const u8 = &.{},
    custom: []const CustomFormat = &.{},
};

pub const Callback = *const fn (context: ?*anyopaque, event: Event) void;

// Standalone test root: zig test src/zilt/drag_drop.zig -lole32 -luser32 -lkernel32
// This does not pull in root/config/backend or require application wiring.
test {
    if (@import("builtin").os.tag == .windows) {
        @import("std").testing.refAllDecls(@import("platform/windows/drag_drop.zig"));
    }
}
