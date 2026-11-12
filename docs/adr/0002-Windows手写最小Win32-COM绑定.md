# ADR-0002：Windows 层手写最小 Win32/COM 绑定（初期不引入 zigwin32）

日期：2026-11-07 · 状态：已接受

## 背景

调研建议 Windows 用 zigwin32（全量 Win32 绑定）+ 自写 WebView2 COM 接口。本机条件：无 MSVC，默认 windows-gnu 目标。

## 决策

Phase 0 **手写最小 Win32 绑定**（约 25 个函数 + 必要常量/结构体）+ **手写所需 WebView2 COM 接口**（约 15 个接口 + 6 个事件处理器），零第三方依赖。

## 理由

1. PoC 所需面积极小：窗口/消息循环/定时器/注册表/COM 内存 handful 函数，手写半天即可，比引入+适配 zigwin32（校验其 0.17.1 兼容性、处理全量命名空间编译）更快更可控。
2. WebView2 接口无论如何都要手写（zigwin32 不含 WebView2——其头文件来自 NuGet 而非 Windows SDK，见 win32metadata#66）；Win32 部分用同一风格手写保持一致。
3. 手写过程本身就是对 COM ABI 的验证（x64 下 `.c` 调用约定、vtable 布局、引用计数），为 macOS（zig-objc）与 Linux（GObject）积累模式。

## 后果

- 扩展系统能力（托盘 Shell_NotifyIcon、Toast 通知、对话框）时手写量上升——**届时重新评估引入 zigwin32**（触发条件：预计新增 >300 行 Win32 声明）。
- 必须以 docs/reference/webview2-binding-notes.md（来自官方 WebView2.h）为准逐字对齐 vtable 顺序与 IID，禁止凭记忆。
