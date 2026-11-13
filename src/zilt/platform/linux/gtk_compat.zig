//! GTK 变体差异收敛点（v0.2.5）。
//!
//! 构建变体由 `zig build -Dgtk=gtk4` 选择（build.zig 切换 pkg-config 包名：
//! gtk3 → `gtk+-3.0` + `webkit2gtk-4.1`；gtk4 → `gtk4` + `webkitgtk-6.0`），
//! 本文件收敛**代码侧**的 API 差异，后端只在需要处引用：
//!
//! | 差异点 | GTK3 + WebKit2GTK 4.1 | GTK4 + WebKitGTK 6.0 |
//! |---|---|---|
//! | 初始化 | `gtk_init(&argc, &argv)` | `gtk_init()` |
//! | 菜单栏 | GtkMenuBar（`gtk_menu_bar_new`） | **已移除**——需 GtkPopoverMenuBar |
//! | 拖放 | GtkWidget drag 信号 | GdkDrag/Drop（4.x 全新模型） |
//! | 剪贴板 | GtkClipboard | GdkClipboard |
//! | 对话框 | GtkFileChooserNative（两版皆可） | 同左 |
//! | WebView 构造 | `webkit_web_view_new_with_user_content_manager` | 同名（6.0 沿用） |
//! | 打印 | WebKitPrintOperation（两版皆可） | 同左 |
//!
//! 完整 GTK4 后端（菜单/拖放/剪贴板的 4.x 实装）需要 WebKitGTK 6.0 开发包
//!（Ubuntu 24.04+/Debian 13+）；22.04 上 `-Dgtk=gtk4` 在 pkg-config 处给出
//! 可读报错。这里的适配函数用**编译期参数探测**（@typeInfo 参数个数 /
//! @hasDecl），同一份源码在两种变体下都能编译。
const std = @import("std");
const c = @import("gtk");

pub const Variant = enum { gtk3, gtk4 };

/// 当前变体：按 `gtk_init` 的参数个数在编译期判定
///（GTK3 = 2 参；GTK4 = 0 参）。
pub const variant: Variant = blk: {
    const F = @TypeOf(c.gtk_init);
    const n = @typeInfo(F).@"fn".param_types.len;
    break :blk if (n == 0) Variant.gtk4 else Variant.gtk3;
};

pub fn isGtk4() bool {
    return variant == .gtk4;
}

/// gtk_init：GTK3 带 (argc, argv)，GTK4 无参。
pub fn gtkInit() void {
    const F = @TypeOf(c.gtk_init);
    const n = @typeInfo(F).@"fn".param_types.len;
    if (n == 0) {
        c.gtk_init();
    } else {
        c.gtk_init(null, null);
    }
}

/// 菜单栏构造在 GTK4 下不可用（GtkMenuBar 已移除）——
/// 调用方据此降级为「无菜单栏」（完整 GtkPopoverMenuBar 适配随 6.0 环境补齐）。
pub fn menuBarAvailable() bool {
    return !isGtk4();
}

test "variant 探测：本构建按 gtk_init 签名判定" {
    // 默认（gtk3）构建下应为 gtk3；gtk4 构建下为 gtk4——两个方向都合法，
    // 这里只断言探测逻辑不崩且与头文件一致。
    const F = @TypeOf(c.gtk_init);
    const n = @typeInfo(F).@"fn".param_types.len;
    if (n == 0) {
        try std.testing.expectEqual(Variant.gtk4, variant);
    } else {
        try std.testing.expectEqual(Variant.gtk3, variant);
    }
}
