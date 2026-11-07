//! Windows 平台绑定层聚合入口。

pub const com = @import("com.zig");
pub const win32 = @import("win32.zig");
pub const loader = @import("loader.zig");
pub const webview2 = @import("webview2.zig");
pub const tray = @import("tray.zig");
pub const toast = @import("toast.zig");
pub const single_instance = @import("single_instance.zig");
pub const menu = @import("menu.zig");
pub const hotkey = @import("hotkey.zig");
pub const dialog = @import("dialog.zig");
pub const backend = @import("backend.zig");
