//! Zilt Phase 2 示例应用：配置驱动的窗口 + IPC + comptime 绑定 + dev 模式。

const std = @import("std");
const zilt = @import("zilt");
const app = @import("app_config");

// v0.1.16：示例服务 —— 验证「Config 声明 → 框架驱动生命周期 → JS 可查状态」这条链路。
// 框架不解释 state 的含义，只负责 init/start 与逆序 stop/deinit 的时序。
var demo_service_state: u32 = 0;

fn demoServiceInit(state: *anyopaque) anyerror!void {
    const p: *u32 = @ptrCast(@alignCast(state));
    p.* += 1;
}

fn demoServiceDeinit(state: *anyopaque) void {
    _ = state;
}

pub fn main() !void {
    try zilt.run(.{
        .commands = app.commands,
        .events = app.events,
        .assets = &app.assets,
        .security = app.security,
        .title = "Zilt — v0.1.22 示例",
        .width = 960,
        .height = 700,
        .url = "https://zilt.app/index.html",
        // v0.1.16：服务注册表（框架 init/start，逆序 deinit；状态暴露给 window.zilt.services）
        .services = &.{
            .{
                .name = "demo",
                .state = @ptrCast(&demo_service_state),
                .init_fn = demoServiceInit,
                .deinit_fn = demoServiceDeinit,
                .scope = "demo:read",
            },
        },
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
        // v0.1.19：document-start 用户脚本（对齐 Tauri initialization_script）
        .init_scripts = &.{
            "window.__ziltInit = { version: window.zilt.version, at: Date.now() };",
        },
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
            // v0.1.18：预定义角色菜单（copy/paste 等由框架直接执行；不带加速键，
            // 避免劫持 WebView 原生的 Ctrl+C/V 行为）
            .{ .label = "编辑", .items = &.{
                .{ .label = "撤销", .id = "edit.undo", .role = "undo" },
                .{ .label = "重做", .id = "edit.redo", .role = "redo" },
                .{ .label = "-" },
                .{ .label = "剪切", .id = "edit.cut", .role = "cut" },
                .{ .label = "复制", .id = "edit.copy", .role = "copy" },
                .{ .label = "粘贴", .id = "edit.paste", .role = "paste" },
                .{ .label = "删除", .id = "edit.delete", .role = "delete" },
                .{ .label = "全选", .id = "edit.selectAll", .role = "select_all" },
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
