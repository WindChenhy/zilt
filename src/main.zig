//! Zilt Phase 2 示例应用：配置驱动的窗口 + IPC + comptime 绑定 + dev 模式。

const std = @import("std");
const zilt = @import("zilt");
const app = @import("app_config");

pub fn main() !void {
    try zilt.run(.{
        .commands = app.commands,
        .events = app.events,
        .assets = &app.assets,
        .security = app.security,
        .title = "Zilt — v0.1.14 示例",
        .width = 960,
        .height = 700,
        .url = "https://zilt.app/index.html",
        // v0.1.8：按窗口 label 持久化位置/尺寸/最大化/全屏；独立 WebView2 数据目录
        .persist_window_state = true,
        // v0.1.9/v0.1.10：WebView2 事件面 + Settings + 下载/权限 + 运行时 API
        .webview = .{
            .new_window = .new_window,
            .permissions = .{ .clipboard = .allow, .notifications = .allow },
            .downloads = .{ .enabled = true, .show_dialog = false },
            .recover_renderer = true,
        },
        // v0.1.10：环境选项（UA/语言/代理/浏览器参数/通道）默认关闭，可按需开启
        .environment = .{},
        // v0.1.12：剪贴板变化事件 + OLE 自定义拖放格式
        .clipboard_change_event = true,
        .drag_formats = &.{"ZiltDemoFormat"},
        // 系统能力（Windows）
        // 图标：项目未指定 → 使用内置 Zig 官方图标（窗口/托盘/exe 资源）
        .tray = .{
            .tooltip = "Zilt — 点击显示/隐藏窗口",
            .menu = &.{
                .{ .label = "显示窗口", .id = "show-window" },
                .{ .label = "隐藏窗口", .id = "hide-window" },
                .{ .label = "-" },
                // v0.1.13：运行时勾选态由 window.zilt.menu 驱动
                .{ .label = "勾选示例", .id = "tray-check" },
                .{ .label = "新建窗口", .id = "new-window" },
                .{ .label = "关于 Zilt", .id = "about" },
                .{ .label = "-" },
                .{ .label = "退出", .id = "exit" },
            },
        },
        .close_to_tray = true,
        .single_instance = true,
        // 深链接 / 文件关联（HKCU per-user 注册；第二实例参数转发）
        .deep_link = .{
            .scheme = "zilt",
            .register = true,
            .file_ext = ".zilt",
        },
        .menu = &.{
            .{ .label = "文件", .items = &.{
                .{ .label = "新建窗口", .id = "new-window", .accel = "Ctrl+N" },
                .{ .label = "打开文件...", .id = "open", .accel = "Ctrl+O" },
                .{ .label = "-" },
                .{ .label = "退出", .id = "exit", .accel = "Alt+F4" },
            } },
            .{ .label = "帮助", .items = &.{
                .{ .label = "关于 Zilt", .id = "about", .accel = "F1" },
            } },
        },
        .hotkeys = &.{
            .{ .id = "quick-note", .ctrl = true, .alt = true, .key = "N" },
            .{ .id = "reload-page", .ctrl = true, .alt = true, .key = "R" },
            .{ .id = "help", .key = "F7" },
        },
        // 自动更新器（E2E 用 ZILT_UPDATE_URL / ZILT_UPDATE_PK 环境变量覆盖）
        .update = .{
            .manifest_url = "https://updates.invalid/manifest.json",
            .public_key_hex = "0000000000000000000000000000000000000000000000000000000000000000",
            .current_version = "0.1.1",
        },
    });
}
