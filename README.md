# Zilt

基于系统 WebView 的跨平台 GUI 框架（对标 Tauri 2 / Wails v3），框架本体用 **Zig** 实现。

- 前端：任意 Web 技术（HTML/CSS/JS/框架）
- 后端：Zig 核心（窗口、IPC、资产服务、绑定 codegen、dev 工具链）
- WebView：系统自带引擎（Windows: WebView2 / macOS: WKWebView / Linux: WebKitGTK），不自研浏览器引擎

**当前状态：v0.1.6（Windows 全栈 + 前端工程化 + 多窗口/窗口控制/托盘菜单/剪贴板/拖放/深链接/Range：绑定 + IPC 协议 + comptime 绑定生成 + 前端资产 codegen + dev/init 工具链 + 打包器 + 托盘/菜单/对话框/快捷键 + 自动更新器）**。路线图见 [docs/ROADMAP.md](docs/ROADMAP.md)。

v0.1.6 新增：

- **默认 Zig 官方图标**：内置多尺寸 `zilt.ico`（窗口/托盘/exe 资源共用，无需配置）；
  `project.icon` 可自定义 exe 图标，`Config.icon` / `Tray.icon` 可自定义运行时图标
- **多窗口**：`ctx.newWindow(...)`、每窗口独立 IPC/事件路由、`ctx.emitTo(window_id, ...)`、`windowClosed` 事件
- **窗口控制**：标题/最小化/最大化/还原/全屏/尺寸/位置/显隐/聚焦/关闭（任意线程安全）
- **托盘右键菜单**：`Config.Tray.menu` → `trayMenu` 事件
- **剪贴板 + 文件拖放**：`ctx.clipboardWriteText/ReadText`、`dropFiles` 事件
- **深链接/文件关联**：`Config.DeepLink`（HKCU 注册 + 参数分类 + `deepLink` 事件）；第二实例参数经
  `WM_COPYDATA` 转发给首个实例后 exit 5
- **Range/206**：内嵌资产支持 `Range: bytes=…` 分块下载（200 附 `Accept-Ranges`，206 带 `Content-Range`）

## 创建新项目（vue/react/svelte）

```sh
ZILT_INIT_TEMPLATE=vue ZILT_INIT_NAME=my-app zig build init
# → my-app/（vendored 框架源码，项目自包含；npm install → zig build dev 即可开发）
```

## 快速开始（本仓库示例）

要求：Zig 0.17.x + Windows 10/11（系统自带 WebView2 运行时，无需安装任何 SDK）。

```sh
zig build gen      # 生成前端 TS 绑定（frontend/bindings/zilt.ts）
zig build run      # 启动示例应用（embedded 模式）
zig build test    # 单元测试（87 个 test 块：协议/更新器/打包器/系统能力/前端 codegen/模板/图标/深链接/Range）
```

dev 模式：

```sh
zig build dev                                       # dev_command + TCP 探测 + ZILT_DEV_URL 注入（Job Object 整树清理）
ZILT_DEV_DIR=frontend zig-out/bin/zilt-app.exe      # 磁盘服务 + 热重载
ZILT_DEV_URL=http://localhost:5173 zig-out/bin/zilt-app.exe  # Vite HMR
ZILT_DEV_PROXY=http://localhost:1420 zig-out/bin/zilt-app.exe # 反代：应用保持自身 origin（config 里 frontend.dev_proxy = true 则 zig build dev 自动启用）
```

前端资产经 codegen 预压缩嵌入（>8KB 且 gzip 收益 ≥10% 只嵌 .gz 字节，缩小 exe；运行时惰性解压服务）。

## Release 打包（无控制台窗口）

```sh
zig build --release=safe          # zig-out/bin/zilt-app.exe（ReleaseSafe，GUI 子系统）
zig build bundle --release=safe   # dist/Zilt-<ver>-x64.zip + -setup.exe（便携/安装器）
```

Windows 构建已设 `subsystem = .windows`：双击/安装后不会弹出 cmd 窗口；运行日志写入
`zilt.log`。exe 图标默认内置 Zig logo，自定义见 `project.zig` 的 `icon` 字段。

GUI 冒烟测试：

```sh
ZILT_SMOKE_TEST_MS=15000 ZILT_SMOKE_EXIT=1 zig-out/bin/zilt-app.exe && echo PASS
ZILT_SMOKE_MULTI=12 ZILT_SMOKE_TEST_MS=12000 zig-out/bin/zilt-app.exe   # 多窗口 E2E（3s 后自动关第二窗）
```

## 写一个命令

```zig
// src/commands.zig —— 每个 pub fn 自动成为前端可 invoke 的命令
pub fn greet(ctx: zilt.Context, args: struct { name: []const u8 }) !struct { message: []const u8 } {
    return .{ .message = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{args.name}) };
}
```

前端：`const g = await window.zilt.invoke('greet', { name: 'Zilt' });`
TS 工程用生成的绑定：`const g = await greet({ name: 'Zilt' });`（全类型）

## 文档

| 文档 | 内容 |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 分层架构、IPC/内存契约、运行模式 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 路线图与验收记录 |
| [docs/research/](docs/research/) | 可行性调研报告（全部一手来源） |
| [docs/reference/](docs/reference/) | WebView2 ABI 笔记（IID/vtable/loader 协议/实测陷阱） |
| [docs/adr/](docs/adr/) | 架构决策记录 |
