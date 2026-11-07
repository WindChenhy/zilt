//! 单实例保护：命名互斥体。第二实例立即退出（退出码 5）。

const std = @import("std");
const win32 = @import("win32.zig");
const tray = @import("tray.zig");

pub const SECOND_INSTANCE_EXIT_CODE: u8 = 5;

pub const Guard = struct {
    handle: win32.HANDLE,
    name: []u8,
    allocator: std.mem.Allocator,

    /// 尝试持有单实例锁。返回 null = 已有实例在运行（调用方应退出）。
    pub fn acquire(allocator: std.mem.Allocator, app_id: []const u8) ?Guard {
        const name = tray.singleInstanceMutexName(allocator, app_id) catch return null;
        const name_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, name) catch {
            allocator.free(name);
            return null;
        };
        defer allocator.free(name_w);

        const h = win32.CreateMutexW(null, 0, name_w.ptr);
        if (h == win32.INVALID_HANDLE_VALUE) {
            allocator.free(name);
            return null;
        }
        if (win32.GetLastError() == win32.ERROR_ALREADY_EXISTS) {
            _ = win32.CloseHandle(h);
            allocator.free(name);
            return null;
        }
        return .{ .handle = h, .name = name, .allocator = allocator };
    }

    pub fn release(self: *Guard) void {
        _ = win32.CloseHandle(self.handle);
        self.allocator.free(self.name);
    }
};
