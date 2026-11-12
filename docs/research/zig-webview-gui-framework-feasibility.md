# 基于 Zig 的系统 WebView 跨平台 GUI 框架可行性调研报告

> 调研日期：2026-11-07
> 对标对象：Tauri 2 / Wails v3
> 核心问题：为 Zig 语言新增一个「系统 WebView + Web 前端 + 本地资产服务 + IPC 桥」的跨平台 GUI 框架（支持桌面与移动端），框架本体尽可能全部用 Zig 实现，是否可行？
>
> 标注约定：**[一手确认]** = 直接核实过官方文档/源码/本机实验；**[二手]** = 来自可信度较高的报道或社区讨论，未回溯到源码；**[推测/待验证]** = 基于证据的推断，动手前需再验证。

---

## 结论速览（TL;DR）

1. **桌面端可行性：高。** Windows（WebView2 COM）、Linux（WebKitGTK C API）可以在 **100% Zig** 内实现；macOS（WKWebView / Objective-C runtime）可以做到 **≈98% Zig**（用 `zig-objc` 走 ObjC runtime 动态调用，或保留几百行 ObjC shim）。Wails v3 的 "purego" macOS 后端已经在 Go 语言里用 `objc_msgSend` + runtime 注册类完整复刻了 cgo/ObjC 后端（菜单、托盘、WKURLSchemeHandler、对话框等全部实现），这是「不需要编译 Objective-C 也能驱动整个 macOS 壳」的最强先例 **[一手确认]**。
2. **移动端可行性：中等偏低（可做，但成本高）。** Zig 官方目标列表包含 `ios/tvos/watchos/visionos/maccatalyst`，且本机实测 `aarch64-linux-android` 可直接完整链接出二进制（Zig 自带 Bionic libc，无需 NDK）**[一手确认，本机实测]**；但 iOS 侧 Zig 编译可过、链接需要 Apple SDK，且 App 生命周期/UIViewController/UIKit 宿主必须由 Swift/ObjC 承担；Android 需要 Kotlin 宿主 Activity + JNI。Tauri 2 与 Wails v3 在移动端同样是「宿主工程 + 胶水」模式，移动端稳定版两家都尚未落地（Tauri 2 已支持但 Wails v3 移动端仍标实验性）。
3. **「尽可能纯 Zig」的现实边界（建议口径）：** 框架核心（窗口管理、事件循环、IPC 协议、JSON 序列化、资产服务、多窗口、dev server、打包器）≈ **95–98% Zig**；每平台保留 **0–2k 行**的薄胶水（Windows：0 行，直接手写 COM vtable；macOS：0 行若走 zig-objc runtime 调用、或 ≤1k 行 ObjC shim 走 Ghostty 路线；Linux：0 行 C，GTK/GObject 绑定可用 zig-gobject 生成；iOS：Swift 宿主工程；Android：Kotlin 宿主工程）。**无需自研浏览器引擎**。
4. **生态现状（避免重复造轮子）：** 目前**不存在**成熟的「Zig 版 Tauri」。最接近的是 Vercel Labs 的 **native SDK（原名 zero-native，2026-05 创建，≈7.8k stars，v0.11.0）**，其做法恰好验证了本报告的架构口径：Zig 核心 + 每平台极薄 C/ObjC 胶水（macOS 用 `appkit_host.m`/`cef_host.mm`，Windows 用 `webview2_host.cpp`），桌面 full 支持、移动端实验性 **[一手确认]**。可复用组件：zigwin32（Win32 全量绑定）、zig-objc、zig-gobject、std.http.Server/std.json/std.crypto；起步可复用 webview/webview（~7k 行 C++，v0.12.0）做 PoC，但中期应脱离（无多窗口、无打包、无自定义协议可控性弱）。
5. **最大风险不是技术，是维护：** Zig 未 1.0，0.14→0.15 的 "Writergate"（`std.io` 全量废弃换 `std.Io.Reader/Writer`）迫使全生态迁移；2026-07 Bun（原 535,496 行 Zig）宣布整体重写为 Rust，虽然官方明确**不是**因为 Zig 不稳定而是 GC/手动内存边界问题，但事件本身说明大型 Zig 项目的维护决策是现实的 **[一手确认]**。建议框架锁定 Zig 稳定版 + 用 zig version 门槛管理，接受每半年一次的迁移成本。
6. **工作量现实性：** webview/webview（参考下限）约 7k 行 C++ 只做到「单窗口 + 导航 + evaluate_script + bind/resolve」；Tauri 从 2019 立项到 2.0（2024-10）用了约 5 年、多核心维护者；Wails v3 从 2023 alpha 到 2026-10 稳定版用了约 3 年。单人/小团队的合理预期：**PoC（单平台）数周；三平台桌面最小可用框架 3–6 个月；达到 Tauri/Wails 用户预期的周边能力（绑定 codegen、打包器、更新器、托盘、通知、多窗口）还需 1–2 人年**。
7. **建议策略：** 先做平台绑定（WebView2/WKWebView/WebKitGTK 三个薄绑定层）→ 再做框架核心 → PoC 阶段**可以**复用 webview/webview C 库验证 IPC/资产服务抽象，但自定义协议能力受限，应在 Phase 1 前脱离；macOS 建议先走 zig-objc runtime 路线验证，若 delegate/内存管理坑过多再退到 ObjC shim（Ghostty 路线）。

---

## 0. 调研方法与时效说明

- 核实日期：2026-11-07。所有版本号/活跃度均为当日数据。
- 一手来源：官方文档（Microsoft Learn、webkitgtk.org、ziglang.org、v2.tauri.app、wails.io）、GitHub 源码（直接读取 raw 文件并核对关键实现）、本机实测（本机装有 Zig 0.17.1，做了交叉编译与 std 库检查）。
- 交叉验证：WebSearch + WebFetch + `gh api`（GitHub REST）多渠道核对，避免只看博客。

---

## 1. 对标对象架构拆解

### 1.1 Tauri 2 的架构

**分层组成** [一手确认，来源：[Tauri Architecture](https://v2.tauri.app/concept/architecture/)、[wry](https://github.com/tauri-apps/wry)、[tao](https://github.com/tauri-apps/tao)]：

| 组件 | 职责 | 说明 |
|---|---|---|
| `tauri`（core crate） | 把 runtimes/macros/utilities/API 组装成最终产品；编译期读 `tauri.conf.json`，运行时注入脚本 | 官方原话："the major crate that holds everything together" |
| `tauri-runtime` / `tauri-runtime-wry` | Tauri 与底层 webview 库之间的 glue layer | |
| `tao` | 跨平台窗口创建库，**是 winit 的 fork**，扩展了菜单/托盘 | 官方原话："a fork of winit that we have extended"；Linux 用 GTK3，Android 用 ndk-rs |
| `wry` | 跨平台 WebView 渲染抽象层，决定用哪个引擎、如何交互 | v0.57.1（2026-10-23） |
| `tauri-bundler` | 把 Rust 可执行文件包装成 OS 专属 app bundle；是 cargo-bundle 的 fork | deb / dmg / .app / rpm / AppImage；Windows 走 NSIS/MSI（CLI 层面） |
| `tauri-codegen` | 编译期嵌入、hash、压缩资产 | 资产打进二进制 |

**各平台 WebView 引擎** [一手确认，来源：[wry README](https://github.com/tauri-apps/wry)]：
- Windows：WebView2（Microsoft Edge Chromium 内核）
- macOS / iOS：WKWebView（系统 WebKit，"WebKit is native on macOS"）
- Linux：WebKitGTK（依赖 GTK，`webkit2gtk-4.1`；`linux-body` 特性要求 WebKit2GTK ≥ v2.40 才支持自定义协议请求体）
- Android：android.webkit.WebView + 生成的 Kotlin 文件 + `WryActivity`（继承 AppCompatActivity）+ `wry::android_binding!` JNI 宏 [一手确认，wry README + 源码]

**IPC 机制**（wry 源码逐平台核对）[一手确认，来源：wry `src/webview2/mod.rs`、`src/wkwebview/mod.rs`、`src/webkitgtk/mod.rs`、`src/android/kotlin/Ipc.kt`，dev 分支]：

wry 在每个平台向页面注入一段统一 shim：`Object.defineProperty(window, 'ipc', { value: Object.freeze({ postMessage: ... }) })`，底层各自落到平台原语：

| 平台 | JS → Native | Native → JS | 自定义协议（资产服务） |
|---|---|---|---|
| Windows | `window.chrome.webview.postMessage` → WebView2 `add_WebMessageReceived`（COM 事件） | `ExecuteScript` / `ExecuteScriptWithResult` | `AddWebResourceRequestedFilter` + `add_WebResourceRequested`（`ICoreWebView2_22/23`）；另有 `custom_protocol_workaround.rs` 处理 URI 规避 |
| macOS/iOS | `window.webkit.messageHandlers.ipc.postMessage` → `WKScriptMessageHandler` | `evaluateJavaScript:completionHandler:` | `WKURLSchemeHandler`（`config.setURLSchemeHandler:forURLScheme:`， objc2 crate 的 `msg_send!` 调用） |
| Linux | `window.webkit.messageHandlers['ipc'].postMessage` → `webkit_web_view_register_script_message_handler` | `webkit_web_view_evaluate_javascript` | `webkit_web_context_register_uri_scheme`（请求体需 2.40+） |
| Android | `WebViewCompat.addWebMessageListener(webView, "ipc", ...)`（回退 `addJavascriptInterface` + `@JavascriptInterface postMessage`）→ JNI 调 `Rust.ipc()` | `evaluateJavascript` | 无（dev 走 HTTP，prod 走 WebViewAssetLoader 类机制或内嵌） |

**Tauri 2 应用层 IPC**：`invoke` 命令系统是 "JSON-RPC like protocol"，参数与返回值必须可 JSON 序列化；Events 是 fire-and-forget 单向消息 [一手确认，[IPC 概念页](https://v2.tauri.app/concept/inter-process-communication/)]。v2 的 JS 侧实现（`crates/tauri/scripts/ipc-protocol.js`）优先用 **fetch() 打自定义协议**（`ipc://`，请求头带 `Tauri-Callback`/`Tauri-Error`/`Tauri-Invoke-Key`），失败则回退 postMessage 通道；Promise 回调通过 `__TAURI_INTERNALS__.runCallback(callbackId, data)` 解析 **[一手确认，源码]**。

**资产服务与 origin**：v2 在 macOS/Linux 用 `tauri://localhost`，Windows 用 `https://tauri.localhost`（v1 是 `http://tauri.localhost`，v2 破坏性变更）[一手确认，[v1→v2 迁移指南](https://v2.tauri.app/start/migrate/from-tauri-1)]。官方还提供 localhost plugin 作为「真 HTTP server」替代 [一手确认，[plugin/localhost](https://v2.tauri.app/plugin/localhost)]。

**移动端实现**：Android 侧是 Kotlin 宿主（`crates/tauri/mobile/android/src/main/java/app/tauri/*.kt`、`TauriActivity.kt`）；iOS 侧是 Swift Package（`crates/tauri-cli/templates/mobile/...`、plugin 模板的 `Package.swift`/`ExamplePlugin.swift`）[一手确认，源码树]。

**打包器**：tauri-bundler 是 cargo-bundle 的 fork，"Wrap Rust executables in OS-specific app bundles"——deb、dmg、.app、rpm、AppImage 在 README/配置中明确；Windows NSIS/MSI 由 tauri-cli 集成 [一手确认，[tauri-bundler](https://github.com/tauri-apps/tauri/tree/dev/crates/tauri-bundler)]。

**当前状态** [一手确认，[docs.rs](https://docs.rs/crate/tauri/latest)、[v2.tauri.app/release](https://v2.tauri.app/release)]：Tauri 2.x 最新 2.12.5（2.12 于 2026-09-26 发布，放弃了 Win7 官方支持）；**Tauri 3.0.0-alpha.6 已于 2026-11-06 发布**，alpha 序列自 2026-09 开始。

### 1.2 Wails v3 的架构与现状

**成熟度** [一手确认，[Wails v3.0.0 Released](https://wails.io/blog/wails-v3-released)]：
- **2026-08-02 进入 beta**（[wails-v3-beta](https://wails.io/blog/wails-v3-beta)），**2026-10-26 发布 v3.0.0 稳定版**；截至目前 tag 有 v3.0.0、v3.1.0，nightly 已到 v3.2.0-nightly.20261103。仓库 36,977 stars，2026-11-07 当天仍有 push，非常活跃。
- 桌面三平台（Windows amd64/arm64、macOS Intel/Apple Silicon、Linux amd64/arm64）为稳定范围；**移动端仍标 experimental**。
- Linux 默认已切到 **GTK4 + WebKitGTK 6.0**。
- v3 能力清单（官方博客）：多窗口运行时创建/管理、系统托盘（明暗图标、macOS template icons）、原生菜单与对话框、**静态源码分析生成 bindings**（`wails3 generate bindings`，注释与参数名透传到前端）、Taskfile 构建体系、`wails3 dev` 热重载、各平台签名/安装器/MSIX 指南、**应用内更新器**（密码学校验 + 原子替换）、server build 模式（无窗口跑 HTTP 服务）。

**窗口与平台层源码结构** [一手确认，`v3/pkg/application`，tag v3.1.0]：
- Windows：`application_windows.go`，纯 Go + syscall 调 Win32；WebView2 用自维护的 Go COM 绑定（`v3/internal/webview2/pkg/edge/ICoreWebView2_3.go` 等，含 `SetVirtualHostNameToFolderMapping`）——**Go 生态都要手写 WebView2 COM 绑定**，Zig 的 COM 手写条件更好（见 §2.1）。
- macOS：`application_darwin.go` + `application_darwin_delegate.m` 等 **cgo Objective-C** 文件（`#cgo CFLAGS: -x objective-c`）；同时提供 **purego 后端**（`application_darwin_purego.go` + `PUREGO_MACOS.md`），见下。
- Linux：`application_linux_gtk3.go` / `application_linux_gtk4_shared.go`，另有 purego 生成绑定（`application_linux_purego_gtk3_generated.go`，由 GIR 生成，等价于 zig-gobject 思路）。
- iOS：`application_ios.go` + `application_ios.m`；Android：`application_android.go`（+ nocgo 变体）。
- `pkg/mac/mac.go`：直接内嵌 ObjC 源码获取 bundle ID——**Go 都绕不开 ObjC 胶水**。

**Purego（CGO-free macOS 后端）——对本调研最关键的先例** [一手确认，[PUREGO_MACOS.md](https://github.com/wailsapp/wails/blob/v3.1.0/v3/pkg/application/PUREGO_MACOS.md)]：

> "This is a port of the Wails v3 macOS backend that runs with `CGO_ENABLED=0` by driving the Objective-C runtime through purego… Frameworks (AppKit, WebKit, Foundation, CoreGraphics, ...) are `dlopen`ed at runtime rather than linked at build time."

要点：
- 用 `objc.RegisterClass` 在**运行时注册** Objective-C delegate 类（NSApplicationDelegate、NSWindowDelegate、WKScriptMessageHandler、WKURLSchemeHandler、WKNavigationDelegate...），方法实现是宿主语言的闭包（IMP）。
- 主线程调度用 libdispatch（`dispatch_async` 到 `_dispatch_main_q`）。
- **验证完整的 parity 清单**包括：应用生命周期、窗口全套（尺寸/最小化/全屏/frameless/标题栏预设）、WKWebView（setURL/execJS/reload/zoom/devtools）、**资产服务（WKURLSchemeHandler）**、**JS↔宿主桥**、菜单/托盘、对话框、全局快捷键（Carbon）、通知、剪贴板、拖放、单实例、autostart（SMAppService）等全部 implemented。
- 结论性含义：**编译器不支持 Objective-C 也不是障碍**——动态调 ObjC runtime 就能复刻完整 macOS 桌面壳。Go 能做到，Zig（有 `std.DynLib` dlopen/dlsym + zig-objc 封装 + 更细的 calling convention 控制）没有原理性障碍。

**资产服务** [一手确认，`v3/internal/assetserver/assetserver_{darwin,windows,linux}.go`]：
- macOS/Linux：自定义 scheme `wails://localhost`
- Windows：`http://wails.localhost`（WebView2 `SetVirtualHostNameToFolderMapping` 虚拟主机名映射）
- 生产模式资产嵌入二进制（`bundled_assetserver.go`），dev 模式带 middleware/devServerURL 反代到前端工具链（Vite 等），HMR 由前端 dev server 承担。
- 前端运行时桥脚本 `runtime.js` 由框架注入（`internal/assetserver/bundledassets/runtime.js`）。

### 1.3 两者的共同模式（确认）

**[一手确认]** Tauri 与 Wails 均为：**「系统 WebView（不自研引擎）+ 本地资产服务（custom scheme / virtual hostname / 内嵌二进制）+ IPC 桥（postMessage / script message handler / custom protocol fetch）+ 每平台薄窗口层」**。证据：
- Tauri 架构页明言 "It directly uses WRY and TAO to do the heavy lifting in making system calls to the OS"，且 WebView 库 "not included in your final executable but dynamically linked at runtime"（[process-model](https://v2.tauri.app/concept/process-model/)）。
- Wails v3 各平台资产 baseURL 就是 `wails://` / `http://wails.localhost` 两种 custom scheme，无自研引擎。
- 打包产物体积小、不捆绑 Chromium（对比 Electron 的核心卖点）。

---

## 2. 各平台 WebView 引擎与 Zig 的可达性（核心章节）

### 2.0 总览

| 平台 | 引擎 | 原生 API 形态 | Zig 可达路径 | 纯 Zig 程度（现实可达） |
|---|---|---|---|---|
| Windows | WebView2 (Edge/Chromium) | Win32 + COM（C 接口，IDL 头文件） | zigwin32（Win32）+ 自写 COM vtable 绑定 | **100% Zig** |
| macOS | WKWebView (WebKit) | Objective-C（AppKit/WebKit framework） | zig-objc 调 ObjC runtime（dlopen + msgSend + 运行时注册类）；或少量 ObjC shim | ≈98% Zig（或 ≤1k 行 ObjC） |
| Linux | WebKitGTK | C API + GObject Introspection | zig-gobject（GIR 生成绑定，Ghostty 同路线） | **100% Zig** |
| iOS | WKWebView | UIKit + ObjC/Swift | Zig 编译静态库/动态库 + Swift/ObjC 宿主工程 | 核心逻辑 Zig，壳必须 Swift/ObjC |
| Android | android.webkit.WebView | Java/Kotlin + JNI | Zig 交叉编译 `.so`（自带 Bionic libc）+ JNI + Kotlin 宿主 | 核心逻辑 Zig，壳必须 Kotlin/Java |

### 2.1 Windows：WebView2（可行性最高）

**引擎与运行时分发** [一手确认，[Microsoft Learn: Distribute your app and the WebView2 Runtime](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)]：
- Evergreen 模式：运行时自更新、全机共享；**Windows 11 内置**；Windows 10 绝大多数设备已由微软 2022-12 起推送安装。
- 检测方式：注册表 `pv` 键（`HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`）或 `GetAvailableCoreWebView2BrowserVersionString` 返回 `nullptr` 即未安装。
- 引导安装：Bootstrapper（约 2MB，在线）`MicrosoftEdgeWebview2Setup.exe /silent /install`；离线场景用 Evergreen Standalone Installer；生产应用**不允许**依赖 Microsoft Edge 浏览器本体。
- Fixed Version 模式：>250MB，随包分发、不自动更新（特殊环境才用；v120+ 在 Win10 未打包应用上还需 `icacls` 授权 AppContainer 权限）。
- **加载器**：`WebView2Loader`（静态链 `WebView2Loader.lib` 或随包发 `WebView2Loader.dll`，架构相关）——webview/webview 甚至内置了最小 loader（运行时 dlopen），不硬性依赖 SDK 的 loader [一手确认，[webview README](https://github.com/webview/webview)]。

**Zig 调 COM 的可行性**：
- COM 对 Zig 而言就是「vtable 结构体 + GUID」，语言层面无障碍。**现有先例**：zigwin32 已生成全部 Win32 COM 接口（`win32/graphics/direct3d`、`dxgi` 等 44 个命名空间）[一手确认，[zigwin32](https://github.com/marlersoft/zigwin32) 目录树]。
- **但 WebView2 接口不在其中**：WebView2 的 COM 头（WebView2.h）来自 **Microsoft.Web.WebView2 NuGet 包**而非 Windows SDK——微软 win32metadata 官方 issue #66 明确把 WebView2 列为 "Win32 APIs not included with Windows SDK" 的例子 [一手确认，[microsoft/win32metadata#66](https://github.com/microsoft/win32metadata/issues/66)]；zigwin32 的 `win32/web/` 下只有 `ms_html.zig`（旧 MSHTML）**[一手确认]**，仓库 issue 中也无 WebView2 绑定请求。
- **也没有现成的 Zig WebView2 绑定项目**（搜索 `ICoreWebView2 zig` 只命中 webview/webview 的包装项目）[一手确认，GitHub 搜索]。
- **可行路径（推荐）**：手写所需的 ~20–40 个接口/事件处理器（`ICoreWebView2`、`ICoreWebView2Environment`、`ICoreWebView2Controller`、`ICoreWebView2_3`（SetVirtualHostNameToFolderMapping）、`ICoreWebView2_22/23`、`ICoreWebView2EnvironmentOptions`、各 `IEventHandler` vtable）——参照 wry 的 `webview2/mod.rs`（~2,000 行 Rust，其中 COM 事件样板占大头）与 wails 的 Go COM 绑定。或者写个小工具从 WebView2.h/IDL 生成 Zig。`@cImport` + translate-c 对 WebView2.h **理论上可行但不推荐**：该头文件面向 MSVC（SAL 注解、`__RPC` 等宏），translate-c 对这类头的兼容性是已知的坑 [推测/待验证——未在本机实测该头文件的 translate-c 结果]。
- 事件回调（`WebMessageReceivedEventHandler` 等）在 Zig 里是「实现 Invoke 方法的 vtable 结构体实例」，比 Go 更自然（无 GC 偏移问题）。

**结论**：Windows 是三个桌面平台中**唯一可以做到 0 胶水、100% Zig** 的平台，也是建议的 PoC 起点。对照：Vercel 的 native SDK 在 Windows 上用了 `webview2_host.cpp`（C++ 胶水），说明他们选择了复用 C++ 快速落地，但这不是 Zig 能力边界 **[一手确认，[vercel-labs/native](https://github.com/vercel-labs/native) `src/platform/windows/`]**。

### 2.2 macOS：WKWebView（需 ObjC runtime 调用或薄 shim）

**Zig 无法直接编译 Objective-C** [一手确认，[ziglang/zig#7944 "Objective-C runtime support in zig?"](https://github.com/ziglang/zig/issues/7944)]：zig cc 内含 clang 但 ObjC 支持不完整（compiler-rt 移植缺 `@available` 等）；本机实测 `zig build-exe -target aarch64-ios` **语义检查通过**，但完整链接报 `undefined symbol: __NSGetExecutablePath`/`___error`——需要 Apple SDK 的 libSystem **[一手确认，本机实测]**。结论：**编译 ObjC 源码这条路不要指望**。

**可行路径 A：直接调 ObjC runtime（推荐先试）**：
- `objc_msgSend` 只是 C 函数，Zig 完全可调；社区库 **mitchellh/zig-objc**（360 stars，2026-10-20 仍有 push，"Objective-C runtime bindings for Zig"）提供 msgSend/类查找/blocks 封装 **[一手确认，[zig-objc](https://github.com/mitchellh/zig-objc)]**。Ghostty 的 `build.zig.zon` 明确依赖 `zig_objc`（lazy）**[一手确认，源码]**。
- delegate 类在运行时注册（`objc_allocateClassPair`/`objc_registerClassPair` + 方法 IMP），WKURLSchemeHandler 等 protocol 实现同理——**Wails v3 purego 后端已在 Go 里全部跑通**（见 §1.2），证明该路线可完整覆盖 macOS 壳 [一手确认]。
- Zig 侧优势：可精确控制调用约定与内存；`std.DynLib` 可 dlopen AppKit/WebKit。
- **风险点 [推测/待验证]**：(1) `objc_msgSend` 的 struct-by-value 返回（NSRect 等）在 arm64 上统一走 `objc_msgSend`，但 Intel 上历史上有 `objc_msgSend_stret` 分叉，需按架构处理；(2) `zig-objc` 的 blocks 支持完整度；(3) ObjC 异常（`@try/@catch`）不可直接写，需用 API 层规避（Wails purego 就用「stopped-task 注册表」替代了 `@try/@catch` [一手确认]）。

**可行路径 B：少量 ObjC/Swift shim（Ghostty 路线）**：
- Ghostty（63,754 stars）官方 README："There is a large, shared core written in Zig but we do a lot of platform-native things… The macOS app is a true SwiftUI-based application" [一手确认，[ghostty README](https://github.com/ghostty-org/ghostty)]。
- 结构 [一手确认，仓库树]：`src/` 全 Zig（含 `apprt/embedded.zig`——给 macOS/iOS 用的嵌入式应用层），通过 `include/ghostty.h`（40KB C API）+ `module.modulemap` 暴露给 Swift；`macos/` 目录是 Xcode 工程（Swift 源码）；Linux 侧 `apprt/gtk.zig` + `apprt/gtk/` **直接用 Zig 写 GTK 应用**。
- 启示：macOS 上「Zig 核心 + Swift 壳 + C API 边界」是被验证过的最稳路线，代价是壳层语言分裂。

**建议**：框架的 macOS 层按 A 起步（框架作者写一次 runtime 绑定，用户全程 Zig）；若 App Store 分发/系统能力（SwiftUI 设置界面、通知 deep link 等）要求高，再补 B 的可选 Swift 模板。**[推测，基于 Ghostty/Wails 双先例]**

### 2.3 Linux：WebKitGTK（绑定最直接）

- **API 版本碎片化** [一手确认，[WebKitGTK 官方文档](https://webkitgtk.org/reference/webkit2gtk/stable/) + GNOME Discourse "WebKitGTK API Versions Demystified"（https://discourse.gnome.org/t/webkitgtk-api-versions-demystified/）+ [迁移指南](https://webkitgtk.org/reference/webkit2gtk/2.39.7/migrating-to-webkitgtk-6.0.html)]：
  - `webkit2gtk-4.0`：GTK3 + libsoup2，**已废弃，WebKitGTK 2.52 起移除**
  - `webkit2gtk-4.1`：GTK3 + libsoup3（API 与 4.0 相同）；Ubuntu 24.04+ 只带 4.1
  - `webkitgtk-6.0`：GTK4 + libsoup3，面向未来；**Wails v3 稳定版已把 GTK4/6.0 设为 Linux 默认**；wry 当前默认 4.1；webview/webview 用 `WEBVIEW_WEBKITGTK_API` 支持三档
  - 建议：框架同时面向 4.1 与 6.0（GObject 绑定从 GIR 生成时本来就是参数化的）。
- **Zig 绑定**：C API + GObject Introspection（GIR）→ 社区 **ianprime0509/zig-gobject**（151 stars，活跃，2026-10-13 有 push）从 GIR 生成 Zig 绑定；Ghostty 维护自己的 fork（ghostty-org/zig-gobject，依赖项里 `gobject-0.3.2`）**[一手确认]**。Ghostty 的 Linux 应用证明「纯 Zig 写 GTK 应用」生产可用。
- **许可**：WebKitGTK 为 **LGPL-2.1-or-later**（部分 BSD-2-Clause），动态链接闭源应用合规（需附许可声明、允许用户替换库）[一手确认，Debian copyright 记录，https://packages.debian.org/src:webkit2gtk]。因此**不可静态链接**进专有二进制（除非遵守 LGPL 义务），发布用动态依赖即可——这与 Tauri/Wails 一致。
- 依赖链条：GTK3/GTK4 + libsoup3 + GLib——AppImage/deb/rpm 打包时按发行版动态依赖即可，无需分发。

**结论**：Linux 可 100% Zig（绑定生成器 + 手写少量 C 互操作粘合），无编译器障碍。

### 2.4 iOS：WKWebView + Swift/ObjC 宿主

- Zig 目标列表官方包含 `ios`、`maccatalyst`、`tvos`、`visionos`、`watchos`（os 维度）与 `simulator`（abi 维度）[一手确认，本机 `zig targets` 输出，Zig 0.17.1]。
- 本机实测：`zig build-exe hello.zig -target aarch64-ios -fno-emit-bin` 编译通过；完整链接需 iOS SDK（Xcode）[一手确认]。
- 但**应用形态决定了宿主必须是 Swift/ObjC**：UIApplication 生命周期、WKWebView 需要挂在 UIViewController 视图树上、App Store 上架流程都在 Xcode 工程内。Zig 的角色是**被 Swift 调用的库**（静态库/framework + C API），即 Ghostty 的 libghostty 模式（`apprt/embedded.zig` 就是为 macOS/iOS 宿主准备的应用层）[一手确认]。
- Tauri 2 iOS 侧同样是 Swift 宿主 + Rust 库 [一手确认，tauri 源码树 Package.swift]。
- 社区实践存在但零散 [二手]，无 iOS 上的 Zig WebView 框架先例。**结论：iOS 可行但属于「Zig 库 + Swift 壳」，无法纯 Zig；工作量主要在宿主工程模板与桥接代码生成。**

### 2.5 Android：WebView + JNI + Kotlin 宿主

- **Zig 官方支持 Android 目标**：`android`/`androideabi` 在 abi 列表，os 是 `linux` [一手确认，`zig targets`]。本机实测：`zig build-exe -target aarch64-linux-android` **完整链接成功**（Zig 自带 Bionic libc，不需要 NDK sysroot）[一手确认，本机实测，产出 4.2MB 可执行文件]。
- 社区实践：`shreyassanthu77/zig-android`（构建系统包，自动发现 SDK/NDK 并交叉编译）等 [二手，GitHub 搜索结果]；Ziggit 有 "Targeting Android" 讨论串 [二手]。
- WebView 侧必须由 Java/Kotlin 承担：Activity 生命周期、`WebViewClient`、权限、asset loader。wry 的做法（可直接借鉴）[一手确认，`src/android/kotlin/*.kt`]：生成 Kotlin 文件（`RustWebView`/`RustWebViewClient`/`Ipc`/`WryActivity`），`Ipc` 类用 `WebViewCompat.addWebMessageListener(webView, "ipc", ...)` 并回调 JNI `Rust.ipc()`，回退 `addJavascriptInterface`；Rust→JS 用 `evaluateJavascript`。Zig 侧做 JNI 双向调用（`JNIEnv` 通过 `JNI_OnLoad`/线程 attach 获得）没有原理障碍，但 JNI 签名/引用管理是细致活。
- Gradle/AGP 打包 APK/AAB 仍需 Android SDK 工具链——这部分交给宿主工程模板 + 框架 CLI 调 gradle 即可。

**结论**：Android 与 iOS 同级——**核心逻辑（IPC、协议、序列化、native 代码）可 100% Zig，壳必须 Kotlin**。风险集中在 JNI 绑定的样板量。

### 2.6 分层结论：哪些 100% Zig，哪些必须留胶水

**可以 100% Zig** [一手确认或强先例]：
- 主逻辑、事件循环调度、IPC 协议（消息格式、回调注册、Promise 解析）、JSON/序列化（std.json）
- HTTP 资产服务（dev 模式 std.http.Server，含 std.http.Server.respondWebSocket；生产模式走各平台 custom scheme 拦截）
- 窗口管理大部分：Windows（Win32 via zigwin32）、Linux（GTK via zig-gobject）、macOS（NSWindow/NSApplication via zig-objc——Wails purego 已验证同等能力）
- 打包器（NSIS 脚本生成、.app bundle 目录结构、AppImage/deb 组装、DMG hdiutil 调用）、更新器（std.crypto 有 ed25519 等，签名校验无需外部依赖）
- 绑定 codegen（Zig comptime 反射 + TS 文本生成）

**必须留薄胶水或 runtime 调用** [一手确认]：
- macOS：ObjC runtime 调用（zig-objc，≈0 行外部代码）或 ≤1k 行 ObjC shim
- iOS：Swift 宿主工程（UIApplication、WKWebView 视图管理、Info.plist/签名）
- Android：Kotlin 宿主工程（Activity、WebView 配置、IPC 桥类）+ Zig/JNI
- Windows：0 胶水（COM 手写绑定即 Zig 代码本身）

---

## 3. 现有 Zig 生态盘点（避免重复造轮子）

### 3.1 webui-dev/webui 与 zig-webui

- webui：4,648 stars，2026-10-28 有 push；核心 `src/webui.c` 16,255 行 [一手确认]。
- 架构 [一手确认，[webui README](https://github.com/webui-dev/webui)]：**不是内嵌 WebView**——"Think of WebUI like a WebView controller, but instead of embedding the WebView controller in your program... you use a tiny static/dynamic library to run any installed web browser"。即：起本地服务 + WebSocket 桥（"Fast binary WebSocket communication protocol"）+ 拉起已安装浏览器（Firefox/Chrome/Edge/...）；WebView2/GTK WebView/WKWebView 只是可选项。**局限**：GUI 窗口不在应用进程内（是外部浏览器进程的标签页/窗口），无法控制窗口样式/托盘/系统集成深度；与 Tauri/Wails 不是同类框架。
- zig-webui（845 stars）：绑定 WebUI v2.5.1，CI 明确测试 Zig **0.16.0 与 0.17.0**，维护活跃 [一手确认，[zig-webui README](https://github.com/webui-dev/zig-webui)]。**对本项目可参考其 Zig 绑定工程化方式，但架构不可复用**。

### 3.2 webview/webview 及其 Zig 绑定

- webview/webview：14,338 stars，v0.12.0，C++11（Windows 需 C++14）；三后端 `win32_edge.hh`（29KB）/`cocoa_webkit.hh`（22KB）/`gtk_webkitgtk.hh`（12KB）+ C API + 引擎基类等，**核心合计约 286KB（≈7–8k 行）** [一手确认，GitHub 树 + 文件尺寸]。
- 功能：单窗口、navigate、evaluate_script、bind/resolve 双向绑定（resolve 内部走 dispatch 主线程）；**无多窗口、无自定义协议拦截、无打包、无托盘**；明确不支持 alert/confirm/prompt 等 [一手确认，README]。
- Windows 上「不硬性要求 WebView2 SDK loader」——内置最小 loader 运行时 dlopen，但不支持环境变量配置与预览通道 [一手确认，README]。
- Zig 绑定现状：
  - `happystraw/zig-webview`：11 stars，2026-10-08 push，`minimum_zig_version = 0.15.2` [一手确认，build.zig.zon]
  - `thechampagne/webview-zig`：199 stars，但 2025-12-27 后无 push，锁 Zig 0.13 [一手确认]
  - 质量：均为薄绑定，star/活跃度低，不可作为框架底座 [推测，基于元数据]。
- **结论**：PoC 可直接 `@cImport`/链接 webview 库验证 IPC 与资产抽象（其 C API 友好），但其功能面（无多窗口/自定义协议）撑不起框架本体，Phase 1 前应脱离、改为自研三平台薄绑定。

### 3.3 marlersoft/zigwin32

- 「complete autogenerated set of Zig bindings for the Win32 API」，MIT，由 zigwin32gen 从微软元数据生成；457 stars，持续维护 [一手确认，README]。
- 覆盖 44 个顶层命名空间（ui、shell、graphics/direct3d、networking、security 等），**COM 接口以 vtable 形式生成，证明 Zig 表达 COM 成熟**；**不含 WebView2**（原因见 §2.1）[一手确认]。
- 对本项目的价值：窗口创建/消息循环/托盘（Shell_NotifyIcon）/对话框/注册表检测（WebView2 `pv` 键）等全部开箱可用，只剩 WebView2 接口要自写。

### 3.4 Ghostty（最成功的 Zig 原生 GUI 先例）

[一手确认，README + 仓库树]
- 架构：大共享 Zig 核心 + 平台原生壳——macOS 是 **SwiftUI 应用**（macos/ Xcode 工程），通过 libghostty C API（`include/ghostty.h`，40KB）+ `module.modulemap` 消费 Zig 核心；Linux 是 **纯 Zig GTK 应用**（`apprt/gtk.zig`），GTK 绑定来自自维护 zig-gobject fork；渲染器 Metal（macOS）/OpenGL（Linux）。
- 依赖：`zig_objc`（mitchellh/zig-objc）、`gobject`（ghostty-org/zig-gobject）均在 build.zig.zon 中。
- 对本方案的启示：(1) 「每平台原生体验优先于单一技术栈」是值得抄的设计哲学；(2) Linux 纯 Zig GUI 生产可行；(3) macOS 选择 Swift 壳说明当时（2023-2024）纯 runtime 调用路线的工程风险被认为偏高——但 Wails purego（2026）与 Vercel native SDK 的新实践正在降低这一风险。

### 3.5 Bun（Zig FFI 能力上限的先例）

- Bun 曾长期是「Zig + C++/JavaScriptCore（WebKit）」的生产级大型项目：官方博客披露 Rust 重写对象是 **535,496 行 Zig** [一手确认，[Rewriting Bun in Rust, 2026-07-08](https://bun.com/blog/bun-in-rust)]。
- 2025-12 被 Anthropic 收购；2026-05 开始 AI 辅助 Rust 重写实验（约 $165K API 成本、11 天、64 并行实例），2026-07-08 官宣合并，README 已改为 "written in Rust" [一手确认]。
- **重写动机不是 Zig 不稳定**：原话 "I don't blame Zig for that - other users of Zig don't have the bugs we had"；根因是 GC（JSC）与手动内存管理边界上的 use-after-free/泄漏，"Compiler errors are a better feedback loop than a style guide"；同时明确 "Zig made Bun possible" [一手确认，博客原文]。
- 对本项目含义：(1) Zig 链接大型 C/C++ 库（WebKit/JSC 级别）的上限已被证明——但我们根本不需要链接 C++，只调 C/COM/ObjC，难度低一个量级；(2) 本项目无 GC，Bun 的问题类别不适用；(3) 「大型 Zig 项目被整体迁移走」在 2026 年是真实发生过的，写进风险章。

### 3.6 Vercel native SDK（原名 zero-native）——最接近的「Zig 版 Tauri」

[一手确认，[vercel-labs/native](https://github.com/vercel-labs/native)、docs/webviews.mdx、docs/platform-support.mdx]
- 2026-05-08 创建，7,834 stars，v0.11.0（2026-10-13），Apache-2.0，push 活跃（2026-11-06）。InfoQ 2026-06 报道其为 Vercel Labs 开源的 Zig 跨平台桌面框架 [二手，InfoQ]。
- 定位与 Tauri 不完全同：主打「TypeScript + Native markup」自有渲染（macOS Metal、Win/Linux 软件 renderer），**同时内嵌可选 WebView**（多 WebView 栈模型、`window.zero.webviews.create`、`zero://app` 受信 origin、`bridge: true` 注入 `window.zero` JS API）。
- 平台实现（`src/platform/`）**每平台都有薄 C/ObjC/C++ 胶水**：macOS `appkit_host.m`、`cef_host.mm`；Windows `webview2_host.cpp`、`cef_host.cpp`；另有大块纯 Zig（global_shortcuts.zig、keyboard_input.zig、bridge/、updater/ 等）。
- 支持矩阵：桌面三平台 full；**iOS/Android experimental（toolkit-owned 宿主，单窗口全屏）**——与 Tauri/Wails 的移动端现状一致。
- 对本项目的意义：**直接证明了「Zig 核心 + 每平台极薄胶水 + 实验性移动端」是 2026 年工业界可接受甚至流行的路线**；也说明该细分市场刚起步，仍有空间做「专注系统 WebView 的 Zig 版 Tauri」。

### 3.7 awesome-zig GUI 一节与其他

[一手确认，[zigcc/awesome-zig](https://github.com/zigcc/awesome-zig)（2,549 stars）GUI 节]
- 原生控件类：Capy（W32/GTK/Web 多后端）、dvui（immediate mode）、zfltk、libqt6zig、qml_zig、IUPforZig、ZWL——均非 WebView 模型。
- WebView 相关：zig-webui、happystraw/zig-webview、ziglibs/positron（124 stars，2024-07 后停更）"A web renderer frontend for zig applications"。
- 其他相关：star-tek-mb/zig-tray（托盘）、kotsutsumi/zylix（Virtual DOM，早期）。
- **没有已存在的成熟 "Zig 版 Tauri/Wails"** [一手确认，GitHub 搜索 "zig tauri alternative"、"zig webview framework" 结果为空/不成规模]。

### 3.8 Zig 标准库可用性

[一手确认，本机 Zig 0.17.1 std 源码检查]
- `std.http.Server`：存在，API 为 `receiveHead()` → `Request.respond/respondStreaming`，**且有 `respondWebSocket`**（Websocket 服务器端支持）——dev server 与 WebSocket IPC 均可用。
- `std.json`：完整（Scanner/Stringify/dynamic/static）。
- `std.Thread`、`std.crypto`（含 ed25519）、`std.DynLib`（dlopen/dlsym，macOS/ObjC runtime 调用需要）均可用。
- `std.Io`：0.15 起的新 I/O 接口体系（见 §5 风险）。
- build system：本机实测三连——`-target aarch64-ios` 编译通过、`-target aarch64-linux-android` 完整链接成功（自带 Bionic）、Windows→`x86_64-linux-musl` 交叉编译出 13MB 静态二进制；交叉编译是 Zig 一等公民 **[一手确认，本机实测]**。macOS 交叉编译需要 Apple SDK（社区有明确流程，zig-webui 文档验证过 SDK 26.5 的 Linux→macOS 交叉编译 [一手确认，zig-webui README]）。

---

## 4. 关键设计决策调研

### 4.1 IPC 方案对比（含 Promise 回调与大文件）

各平台原语（wry 源码逐平台核对，见 §1.1 表）[一手确认]：

| 能力 | WebView2 (Win) | WKWebView (macOS/iOS) | WebKitGTK (Linux) | Android WebView |
|---|---|---|---|---|
| JS→Native | `chrome.webview.postMessage` → `WebMessageReceived` | `window.webkit.messageHandlers.<n>.postMessage` → `WKScriptMessageHandler` | `register_script_message_handler` | `addWebMessageListener`/`addJavascriptInterface` → JNI |
| Native→JS | `ExecuteScript(WithResult)` | `evaluateJavaScript:completionHandler:` | `webkit_web_view_evaluate_javascript` | `evaluateJavascript` |
| 资产/大文件通道 | `AddWebResourceRequestedFilter` + `WebResourceRequested`（自定义协议；wry 有 URI workaround） | `WKURLSchemeHandler`（完整 request/response 控制，**大文件最稳**） | `register_uri_scheme`（请求体需 2.40+，`linux-body`） | WebViewAssetLoader / dev HTTP |
| 宿主对象注入 | `AddHostObjectToScript`（wry 未用它做 IPC，Tauri 也未用） | 无等价物 | 无等价物 | `addJavascriptInterface` |

**框架层设计建议**（对齐 wry/tauri 做法）[一手确认实现 + 推测建议]：
- 统一 shim：注入 `window.__IPC__.postMessage`，底层接各平台原语（wry 的 `window.ipc` 模式已验证）。
- 双向调用：invoke(requestId, method, payload) → Native 异步执行 → `evaluate_script` 回调 `__IPC__.resolve(requestId, result)`；Tauri 的 callback 注册表（`runCallback(callbackId)`）+ fetch-based custom protocol 是更高效的变体（大批量数据走 HTTP 语义）。
- 大文件：不要走 postMessage（结构化克隆有开销与大小限制风险 [推测]）；走 custom scheme fetch（可分块、Range）或宿主 API（Save/Open dialog 由 native 层直接处理路径）。
- Origin/安全：仿 Tauri v2 的 capability/permission + origin 校验（`ipc://` 的 Invoke-Key 思路）[一手确认机制存在]。

### 4.2 资产服务：custom scheme vs 本地 HTTP

| 方案 | 采用者 | 优点 | 缺点 |
|---|---|---|---|
| custom scheme / virtual host | Tauri（`tauri://localhost`、`https://tauri.localhost`）、Wails v3（`wails://localhost`、`http://wails.localhost`） | 无端口、安全 origin、生产零网络栈 | 各平台拦截 API 不一（见 §4.1 表）；Linux 请求体要 2.40+；Windows 有 workaround 细节 |
| 真 HTTP server | Wails（dev）、Tauri localhost plugin（可选）、webui（本质） | 调试工具链友好、大文件简单、CORS 语义标准 | 端口占用/防火墙、origin 是 `http://127.0.0.1:port`（安全边界变化）、生产多一个服务面 |

[一手确认，各来源见上] **建议**：生产用 custom scheme（三平台能力都已验证），dev server 用 HTTP + HMR 反代；把「资产解析器」抽象成 `fn handler(request) response` 单一接口，两条通道共用。

### 4.3 前端绑定代码生成

- Wails v3：静态源码分析 Go 服务结构体生成 TS（`wails3 generate bindings`，注释/参数名透传）[一手确认，博客]。
- Tauri：tauri-specta（817 stars，2026-11-04 活跃）"Completely typesafe Tauri commands"，基于 specta 类型系统 + 过程宏 [一手确认，仓库]。
- **Zig 里怎么做**：Zig 的 `comptime` 反射（`@typeInfo`）+ `std.json` + `@typeName`/字段遍历，可以在 build 阶段（或 CLI）扫描 `pub fn` 导出表生成 TS/JS：无需宏、无需外部解析器——**比 Rust（需要 proc-macro/specta）和 Go（需要 AST 解析）都简单**，这是 Zig 做 codegen 的结构性优势 [推测，基于语言能力；需 PoC 验证导出模型设计]。
- 需要设计：命令注册表（comptime 生成 dispatch 表）、类型映射（Zig tagged union → TS discriminated union）、可选生成 JSON Schema。

### 4.4 打包与分发

| 平台 | 目标 | Zig 生态现状 | 建议路径 |
|---|---|---|---|
| Windows | NSIS / MSI / MSIX + WebView2 引导 | 无现成工具 [一手确认，搜索] | 自写 bundler：生成 NSIS 脚本调 makensis（或 WiX）；内嵌 Bootstrapper 逻辑（检测 `pv` 键→静默装 Evergreen）[一手确认，微软文档流程明确] |
| macOS | .app bundle / DMG + 签名公证 | 无现成工具 | .app 就是目录结构 + Info.plist + codesign；DMG 用 `hdiutil`；公证 `notarytool`——CLI 全部可由 Zig 调（均系统自带）[一手确认，苹果工具为系统组件；具体脚本模板需自建] |
| Linux | AppImage / deb / rpm | 无现成工具（Wails 有内部 AppImage runtime 资产 [一手确认，wails 源码树]） | deb/rpm 是「目录 + control 文件」组装；AppImage 用 linuxdeploy/appimagetool 外部工具调用 |

对照：tauri-bundler 也是 fork 自 cargo-bundle 的库，功能面就是以上这些 [一手确认]。**打包器是纯逻辑工作，无语言障碍，但覆盖三平台需要大量小细节（图标、plist、desktop 文件、权限）。**

### 4.5 热重载 dev server

- Tauri：`tauri.conf.json` 的 `build.devUrl` 指向 Vite 等 dev server，`tauri dev` 起前端工具链 + 注入（HMR 完全由 Vite 承担）[一手确认机制，config 参考文档]。
- Wails v3：`wails3 dev`（Taskfile 体系）+ assetserver dev middleware（devServerURL 反代），退出时清理后台进程 [一手确认，博客 + assetserver_dev.go]。
- **Zig 实现成本**：dev 模式 = `std.http.Server`（已有 WebSocket 能力）+ 文件监听（Windows ReadDirectoryChangesW / inotify / kqueue——zigwin32 覆盖 Windows，Linux 原生 syscall）+ 向页面注入 reload JS 或桥 WebSocket；前端 HMR 复用 Vite。工作量小，无原理障碍 [推测，基于 std 能力]。

---

## 5. 风险与成本评估

### 5.1 Zig 未 1.0：版本破坏性变更

[一手确认]
- 现状：0.17.1（2026-11-02）为稳定版，master 为 0.18.0-dev [一手确认，ziglang.org/download]。
- 节奏：约每 6 个月一个大版本；**0.15 的 "Writergate"** 把旧 `std.io` 全量废弃，"All existing std.io readers and writers are deprecated in favor of the newly provided std.Io.Reader and std.Io.Writer"（[0.15.1 release notes](https://ziglang.org/download/0.15.1/release-notes.html)）——下游库被迫同步迁移。
- 生态证据：zig-webui 用 CI 同时测 0.16/0.17、 discourages nightly [一手确认]；happystraw/zig-webview `minimum_zig_version = 0.15.2` [一手确认]；thechampagne/webview-zig 锁 0.13 已实质停更 [一手确认]。**绑定类项目「锁版本→停更」是常态**，自研绑定是正确决策。
- 缓解：框架自身锁定 Zig 稳定版（`.minimum_zig_version` + CI 矩阵）；绑定为自研内嵌（不依赖第三方），每半年一次迁移预算约 1–2 周 [推测]。
- Bun 事件（§3.5）：大型项目整体迁离 Zig 在 2026 年发生过一次，但动机是 GC 边界内存安全，对本项目无直接影响；作为对冲，框架核心与绑定层保持小而清晰（wry 级别 ≈8k 行），迁移面可控。

### 5.2 引擎行为差异（Chromium vs WebKit）

[一手确认差异存在 + 推测影响]
- 渲染/JS 差异属于 Web 开发常规问题（Tauri/Wails 用户同样面对），框架层能做的是：统一注入的 `user-agent`/特性检测、dev tools 开关（wry 的 devtools 特性在 macOS 用私有 API，App Store 版要关 [一手确认，wry README]）、CSS/JS polyfill 文档。
- 已知的框架级坑（从 wry 源码可见）：Windows 自定义协议需要 workaround（wry `custom_protocol_workaround.rs`）；Linux 请求体要 WebKitGTK 2.40+；macOS `evaluateJavaScript` 的 completionHandler 空指针处理等 [一手确认]。
- 服务 Worker / SharedArrayBuffer 等在 custom scheme origin 下的行为差异需实测 [推测/待验证]。

### 5.3 工作量现实性

[一手确认数据点]
- **webview/webview（参照下限）**：核心 ~7–8k 行 C++ = 单窗口 + 导航 + evaluate + bind/resolve。没有：多窗口、自定义协议资产服务、打包、绑定生成、托盘、通知、更新器 [一手确认，README]。
- **wry（参照中限）**：~8k+ 行 Rust 专门做「各平台 WebView 统一抽象 + IPC + 自定义协议 + 下载/拖放/代理」，尚不含窗口层（tao 另算）与打包 [一手确认，源码]。
- **Tauri（参照上限）**：2019 立项 → 2.0（2024-10）约 5 年，核心团队多人 + 插件生态；2026-09 才发 2.12 并放弃 Win7；3.0 alpha 于 2026-09 开始 [一手确认]。
- **Wails**：单人主导（leaanthony）+ 社区，v3 alpha（2023）→ stable（2026-10）约 3 年 [一手确认，时间线]。
- **单人/小团队路线的现实拆分**（推算，非承诺）：
  - PoC Windows（窗口 + WebView2 + IPC + custom scheme + 静态资产）：2–4 周
  - 三平台桌面最小框架（统一 API、多窗口、dev server）：3–6 个月
  - 绑定 codegen + 打包器 + 文档/模板：再 3–6 个月
  - 托盘/通知/更新器/自动升级/移动端：进入 1–2 人年量级

### 5.4 用户预期的周边能力清单（Tauri/Wails 既有，按工作量分级）

| 能力 | Tauri/Wails 现状 | Zig 实现路径 | 工作量级 |
|---|---|---|---|
| 多窗口 | 两者均有 | 平台窗口层自然支持 | 小 |
| 系统托盘 | tao 扩展/Wails 内置 | Win `Shell_NotifyIcon`（zigwin32）、macOS `NSStatusItem`（zig-objc）、Linux SNI/DBus（手写 DBus，Wails 有 `application_linux_dbus.go` 先例 [一手确认]） | 中 |
| 原生菜单/对话框 | 均有 | Win zigwin32、macOS NSMenu/NSOpenPanel（zig-objc）、Linux GTK（zig-gobject） | 中 |
| 通知 | 均有 | Win Toast（COM）/macOS UNUserNotification/Linux libnotify/DBus | 中 |
| 自动更新 | tauri-updater 插件；Wails v3 内置（密码学校验+原子替换 [一手确认，博客]） | 下载 + `std.crypto` ed25519 验签 + 原子替换/重启动 | 中 |
| 全局快捷键 | 均有 | Win RegisterHotKey、macOS Carbon RegisterEventHotKey（Wails purego 已做 [一手确认]）、Linux X11/Wayland | 中（Wayland 部分偏大） |
| 深链接/单实例/文件关联 | 均有 | 各平台注册表/Info.plist/DBus + 单实例 socket/互斥体 | 中 |
| 剪贴板/拖放 | 均有 | 平台 API | 小–中 |
| 打包器 | 均有 | 见 §4.4 | 大（覆盖细节多） |
| 绑定 codegen | 均有 | 见 §4.3 | 中 |

---

## 6. 可行性结论 + 分阶段路线图

### 6.1 明确结论

| 评估项 | 结论 | 依据 |
|---|---|---|
| **桌面端可行性** | **高（推荐做）** | 三平台无原理障碍；四个先例（wry/wails/ghostty/vercel-native）各自验证了一部分 |
| **移动端可行性** | **中（后期做，预期管理）** | Zig 目标支持 + 本机实测 android 链接成功；但宿主工程与 JNI/Swift 桥是持续成本；Tauri/Wails 移动端同样未完全稳定 |
| **「尽可能纯 Zig」现实边界** | **核心 ≈95–98% Zig；胶水 ≤2k 行/平台，Windows 可 0 胶水** | §2 各平台证据 |
| **最大风险** | Zig 版本演进（每半年迁移）；胶水层的 ObjC/JNI 细节坑；单人维护带宽 | §5 |
| **差异化机会** | 2026 年该赛道在 Zig 生态只有 Vercel native SDK 一个非专注型玩家；Zig 的 comptime codegen 与交叉编译是结构性优势；"无运行时、无 Node" 叙事与 Zig 社区契合 | §3.6/§3.7 |

**建议口径（写进项目 README 的定位）**：框架本体（含平台绑定）≈95%+ Zig；Windows 0 胶水、Linux 0 C 胶水（GIR 生成绑定）、macOS 优先 0 外部文件（zig-objc runtime 调用，备选 ≤1k 行 ObjC shim）；iOS/Android 提供「宿主工程模板（Swift/Kotlin）+ Zig 核心库」。

### 6.2 分阶段路线图

**Phase 0 — Windows PoC（2–4 周）**
- zigwin32 起窗口/消息循环；手写 WebView2 COM 绑定（Environment/Controller/CoreWebView2 + 3 个事件 vtable）
- 里程碑：加载本地 HTML、`window.ipc.postMessage` → Zig、`ExecuteScript` 回调 JS、`WebResourceRequested` 服务内嵌资产（即 wry Windows 后端的最小子集）
- 关键技术点：COM vtable/GUID、`CreateCoreWebView2EnvironmentWithOptions`、`WebView2Loader` 动态加载、`pv` 注册表检测

**Phase 1 — 三平台桌面统一抽象（3–6 个月）**
- Linux：zig-gobject（webkit2gtk-4.1 与 webkitgtk-6.0 双 API）+ GTK 窗口
- macOS：zig-objc 路线 PoC（NSApplication/NSWindow/WKWebView + WKScriptMessageHandler 运行时注册类 + WKURLSchemeHandler）；风险过高则切 ObjC shim
- 统一：`Webview` trait 式接口、事件循环模型（主线程 dispatch：Windows 消息泵 / GTK main loop / dispatch_async 主队列 [一手确认，Wails purego 用同一机制]）
- 里程碑：同一用户代码三平台出窗口 + IPC + custom scheme 资产
- 关键技术点：每平台 IPC 三原语对齐（§4.1 表）、主线程调度、多窗口

**Phase 2 — 框架核心能力（3–6 个月）**
- IPC 协议层：invoke/Promise 回调注册表、JSON-RPC 风格消息、origin 校验、事件系统
- 绑定 codegen：comptime 扫描导出命令 → TS/JS 绑定 + 运行时注入（对齐 Wails `wails3 generate bindings` 体验）
- dev server：std.http.Server + 文件监听 + HMR 反代（复用 Vite）
- 里程碑：`myfw dev` / `myfw build` 开发闭环

**Phase 3 — 打包器与周边（3–6 个月）**
- bundler：NSIS/MSI + WebView2 引导（Bootstrapper 检测安装）、.app/DMG + codesign/notarytool 脚手架、AppImage/deb/rpm
- 系统能力：托盘、菜单、对话框、通知、剪贴板、全局快捷键、单实例、深链接
- 自动更新器（ed25519 验签 + 原子替换）
- 里程碑：从单一二进制到可分发安装包的完整链路（对齐 Tauri bundler + updater 主体）

**Phase 4 — 移动端（实验性，1+ 人年）**
- iOS：Zig 编译 `aarch64-ios` 静态库（本机已验证编译可行 [一手确认]）+ Xcode 宿主模板（SwiftUIApplication + WKWebView + libghostty 式 C API 桥）
- Android：Zig `.so`（`aarch64-linux-android`，本机已验证完整链接 [一手确认]）+ Kotlin 宿主模板（仿 wry 的 Kotlin 文件生成 + JNI `Rust.ipc` 模式）
- CLI：`myfw package --target ios|android`（调 xcodebuild/gradle）
- 里程碑：单窗口 WebView 应用双端可跑（对齐 vercel native SDK 的实验性水平）

### 6.3 策略建议：先绑定还是先框架？是否复用 webview/webview？

1. **先绑定，后框架。** 三个平台绑定层（WebView2 COM / WebKitGTK / WKWebView）是全部风险的所在，先行验证可把不可控部分前置；绑定层稳定后框架 API 只是编排。Tauri 的 wry、Wails 的 per-platform 应用层都印证这一顺序。
2. **PoC 阶段可复用 webview/webview，Phase 1 前脱离。** 复用收益：几天内拿到三平台「窗口 + IPC」可点原型，验证统一 API 设计与 IPC 抽象；脱离原因：无多窗口、自定义协议不可控（Windows 走内置 loader 简化、Linux 无请求体控制）、C++ 工具链要求（Windows 需 C++14）违背「纯 Zig」目标 [一手确认，README]。
3. **绑定自研、不依赖第三方 Zig 绑定库**：现有 zig 绑定（zig-webview 等）活跃度/版本锁不满足框架基建要求 [一手确认，§3.2]；zigwin32/zig-objc/zig-gobject 三个底层库可作为依赖（它们本身活跃且有 Ghostty 背书）。
4. **macOS 策略**：zig-objc runtime 路线先行（Wails purego 是完整可行性证明）；把「ObjC shim 可选层」设计成 build 选项而非架构依赖，避免 Ghostty 式双栈分叉过早固话。

---

## 7. 参考资料清单

**Zig 官方 / 语言**
1. Zig Download（0.17.1, 2026-11-02）: https://ziglang.org/download
2. Zig 0.15.1 Release Notes（Writergate / std.Io）: https://ziglang.org/download/0.15.1/release-notes.html
3. zig targets（本机 Zig 0.17.1 实测输出：ios/maccatalyst/tvos/visionos/watchos；abi 含 android/androideabi/simulator）
4. ziglang/zig#7944 "Objective-C runtime support in zig?": https://github.com/ziglang/zig/issues/7944

**Tauri 2**
5. Tauri Architecture: https://v2.tauri.app/concept/architecture/
6. Tauri Process Model: https://v2.tauri.app/concept/process-model/
7. Tauri IPC 概念: https://v2.tauri.app/concept/inter-process-communication/
8. v1→v2 迁移（https://tauri.localhost 等）: https://v2.tauri.app/start/migrate/from-tauri-1
9. localhost plugin: https://v2.tauri.app/plugin/localhost
10. wry（README + src/）: https://github.com/tauri-apps/wry （v0.57.1, 2026-10-23）
11. tao: https://github.com/tauri-apps/tao （v0.37.2）
12. tauri-bundler: https://github.com/tauri-apps/tauri/tree/dev/crates/tauri-bundler
13. tauri 源码 IPC 脚本: crates/tauri/scripts/ipc.js、ipc-protocol.js（dev 分支）
14. tauri 移动端 Kotlin/Swift 源码: crates/tauri/mobile/…、crates/tauri-cli/templates/mobile/…
15. Tauri release/docs.rs（2.12.5；3.0.0-alpha.6）: https://docs.rs/crate/tauri/latest 、https://v2.tauri.app/release
16. tauri-specta: https://github.com/oscartbeaumont/tauri-specta

**Wails v3**
17. Wails v3.0.0 Released（2026-10-26）: https://wails.io/blog/wails-v3-released
18. Wails v3 Beta（2026-08-02）: https://wails.io/blog/wails-v3-beta
19. wails 仓库（v3.1.0 tag；pkg/application 源码）: https://github.com/wailsapp/wails
20. PUREGO_MACOS.md（CGO-free macOS 后端）: https://github.com/wailsapp/wails/blob/v3.1.0/v3/pkg/application/PUREGO_MACOS.md
21. wails pkg/mac/mac.go（cgo ObjC）: https://github.com/wailsapp/wails/blob/v3.1.0/v3/pkg/mac/mac.go
22. wails assetserver 平台 baseURL: v3/internal/assetserver/assetserver_{darwin,windows,linux}.go（v3.1.0）

**平台 WebView 引擎（厂商文档）**
23. WebView2 运行时分发（Evergreen/Fixed Version/Bootstrapper/Loader）: https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution
24. microsoft/win32metadata#66（WebView2 不随 Windows SDK 分发）: https://github.com/microsoft/win32metadata/issues/66
25. WebKitGTK 4.1 API 文档: https://webkitgtk.org/reference/webkit2gtk/stable/
26. WebKitGTK API 版本详解（GNOME Discourse）: https://discourse.gnome.org/t/webkitgtk-api-versions-demystified/
27. 迁移到 webkitgtk-6.0: https://webkitgtk.org/reference/webkit2gtk/2.39.7/migrating-to-webkitgtk-6.0.html
28. Debian webkit2gtk 包（LGPL-2.1 记录）: https://packages.debian.org/src:webkit2gtk

**Zig 生态项目**
29. marlersoft/zigwin32: https://github.com/marlersoft/zigwin32
30. mitchellh/zig-objc: https://github.com/mitchellh/zig-objc
31. ianprime0509/zig-gobject / ghostty-org/zig-gobject: https://github.com/ianprime0509/zig-gobject
32. Ghostty（README + build.zig.zon + src/apprt/）: https://github.com/ghostty-org/ghostty
33. webview/webview（v0.12.0）: https://github.com/webview/webview
34. happystraw/zig-webview: https://github.com/happystraw/zig-webview
35. thechampagne/webview-zig: https://github.com/thechampagne/webview-zig
36. webui-dev/webui: https://github.com/webui-dev/webui ；webui-dev/zig-webui: https://github.com/webui-dev/zig-webui
37. vercel-labs/native（原 zero-native，docs/webviews.mdx、docs/platform-support.mdx）: https://github.com/vercel-labs/native
38. InfoQ zero-native 报道: https://www.infoq.com/news/2026/06/zero-native-zig-xplatform-vercel
39. Bun "Rewriting Bun in Rust"（2026-07-08）: https://bun.com/blog/bun-in-rust
40. zigcc/awesome-zig（GUI 节）: https://github.com/zigcc/awesome-zig
41. shreyassanthu77/zig-android: https://github.com/shreyassanthu77/zig-android

**本机实测记录（2026-11-07，Zig 0.17.1, Windows x64）**
42. `zig build-exe -target aarch64-ios -fno-emit-bin`：编译通过；完整链接缺 Apple SDK 符号（`__NSGetExecutablePath`）→ iOS 链接需 SDK
43. `zig build-exe -target aarch64-linux-android`：完整链接成功（4.2MB，自带 Bionic libc）
44. `zig build-exe -target x86_64-linux-musl`（Windows 宿主交叉编译）：成功（13MB 静态二进制）
45. `zig targets` / std 源码检查：`std.http.Server`（含 respondWebSocket）、`std.json`、`std.Io` 存在

---

*报告完。标注「[推测/待验证]」的条目请在 PoC 阶段优先验证：translate-c 对 WebView2.h 的兼容性、zig-objc 的 delegate/blocks 完整度、WebKitGTK custom scheme 请求体行为、custom scheme origin 下 Service Worker 支持。*
