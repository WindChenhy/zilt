# Zilt

基于系统 WebView 的跨平台 GUI 框架（对标 Tauri 2 / Wails v3），框架本体用 **Zig** 实现。

- 前端：任意 Web 技术（HTML/CSS/JS/框架）
- 后端：Zig 核心（窗口、IPC、资产服务、绑定 codegen、dev 工具链）
- WebView：系统自带引擎（Windows: WebView2 / macOS: WKWebView / Linux: WebKitGTK），不自研浏览器引擎

**当前状态：v0.1.5（Windows 全栈 + 前端工程化 + Phase C + 对话框/更新器/多平台打包扩展：绑定 + IPC 协议 + comptime 绑定生成 + 前端资产 codegen + dev/init 工具链 + 打包器 + 托盘/菜单/对话框/快捷键 + 自动更新器）**。路线图见 [docs/ROADMAP.md](docs/ROADMAP.md)。

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
zig build test    # 单元测试（43 项：协议/更新器/打包器/系统能力/前端 codegen/模板）
```

dev 模式：

```sh
zig build dev                                       # dev_command + TCP 探测 + ZILT_DEV_URL 注入（Job Object 整树清理）
ZILT_DEV_DIR=frontend zig-out/bin/zilt-app.exe      # 磁盘服务 + 热重载
ZILT_DEV_URL=http://localhost:5173 zig-out/bin/zilt-app.exe  # Vite HMR
ZILT_DEV_PROXY=http://localhost:1420 zig-out/bin/zilt-app.exe # 反代：应用保持自身 origin（config 里 frontend.dev_proxy = true 则 zig build dev 自动启用）
```

前端资产经 codegen 预压缩嵌入（>8KB 且 gzip 收益 ≥10% 只嵌 .gz 字节，缩小 exe；运行时惰性解压服务）。

GUI 冒烟测试：

```sh
ZILT_SMOKE_TEST_MS=15000 ZILT_SMOKE_EXIT=1 zig-out/bin/zilt-app.exe && echo PASS
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
