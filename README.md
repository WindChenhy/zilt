# Zilt

基于系统 WebView 的跨平台 GUI 框架（对标 Tauri 2 / Wails v3），框架本体用 **Zig** 实现。

- 前端：任意 Web 技术（HTML/CSS/JS/框架）
- 后端：Zig 核心（窗口、IPC、资产服务、绑定 codegen、dev 工具链）
- WebView：系统自带引擎（Windows: WebView2 / macOS: WKWebView / Linux: WebKitGTK），不自研浏览器引擎

**当前状态：Phase 2 完成（Windows 全栈：绑定 + IPC 协议 + comptime 绑定生成 + dev 模式）**。路线图见 [docs/ROADMAP.md](docs/ROADMAP.md)。

## 快速开始

要求：Zig 0.17.x + Windows 10/11（系统自带 WebView2 运行时，无需安装任何 SDK）。

```sh
zig build gen      # 生成前端 TS 绑定（src/frontend/zilt-bindings.ts）
zig build run      # 启动示例应用（embedded 模式）
zig build test    # 单元测试（IPC 协议/分发/绑定生成）
```

dev 模式：

```sh
ZILT_DEV_DIR=src/frontend zig-out/bin/zilt-app.exe   # 磁盘服务 + 热重载
ZILT_DEV_URL=http://localhost:5173 zig-out/bin/zilt-app.exe  # Vite HMR
```

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
