# Zilt 架构

> 状态：v0.1.16（Windows 全栈 + 前端工程化 + 多窗口/窗口模型 + capability ACL + 托盘/菜单/快捷键/任务栏 + 系统能力统一通道 + 打包链（NSIS/MSI/MSIX/签名/更新器）+ services/http/websocket/多 WebView）。逐版本明细见 `docs/ROADMAP.md`；可行性依据与对标分析见 `docs/research/`。

## 定位

Zilt 是基于**系统 WebView** 的跨平台 GUI 框架（对标 Tauri 2 / Wails v3）：前端用 Web 技术，框架本体尽可能全部用 Zig。

**纯 Zig 边界（项目口径）**：框架核心 ≈95–98% Zig；每平台 0–2k 行胶水（Windows 当前为 0 胶水）；不自研浏览器引擎。

## 分层

```
┌────────────────────────────────────────────┐
│      用户应用（Zig 命令 + Web 前端）          │
│      src/commands.zig  frontend/           │
├────────────────────────────────────────────┤
│  zilt 核心库（平台无关）                     │
│   ipc.zig      JSON 协议 v1 / comptime 分发 │
│                per-message arena / Context │
│   bindings.zig comptime 反射 → TS 绑定      │
│   config.zig   应用配置（编译期实例化后端）   │
│   system_api.zig 系统能力统一请求协议        │
│                （menu/tray/hotkey/taskbar/ │
│                store/fs/services/http/ws…）│
│   services.zig 声明式服务注册表              │
│   ws.zig       WebSocket 协议（RFC6455）    │
│   codesign.zig Authenticode 签名参数模型    │
│   msix.zig     AppxManifest/ICO→PNG/版本   │
│   wix_vendor.zig WiX 下载/校验/缓存定位     │
│   updater.zig  自动更新（ed25519 验签）      │
│   bundler.zig  zip / NSIS 安装器生成        │
├────────────────────────────────────────────┤
│  工程化工具（src/tools + templates/）        │
│   frontend_codegen  资产目录 → zilt-assets  │
│   dev.zig  dev 服务器编排（spawn/探测/清理）  │
│   init.zig 模板脚手架（vendored 框架源码）    │
│   cli.zig  zilt doctor/info/version        │
│   bundle/pack/wix_tool/msix_tool/signtool  │
│   keygen/sign/gen_bindings                 │
├────────────────────────────────────────────┤
│  平台绑定层（自研，Windows 当前 0 胶水）      │
│   win32.zig    窗口/消息循环/注册表/文件     │
│   com.zig      COM 基础设施（GUID/引用计数） │
│   loader.zig   WebView2 运行时发现+加载      │
│   webview2.zig WebView2 COM 接口绑定        │
│   backend.zig  生命周期/资产服务/IPC/emit    │
│                marshal/dev watcher/origin/ │
│                http 线程/ws 线程/子 webview │
│   tray/menu/dialog/hotkey/single_instance  │
│   taskbar/sysinfo/theme/autostart/shell    │
├────────────────────────────────────────────┤
│  系统 WebView 引擎（动态链接，不分发）        │
│   WebView2 / (WKWebView / WebKitGTK 后置)  │
└────────────────────────────────────────────┘
```

**平台边界（v0.2 起）**：`platform/` 是唯一允许出现 OS API 的目录。

- 入口：`root.run` → `platform/mod.zig::run`（按 `builtin.os.tag` 选 `platform/<os>/backend.zig`），
  契约由 `platform/interface.zig::assertBackend` 在**编译期**校验（缺 `platform_name` /
  `run(comptime Config) !void` 直接编译失败）；
- 能力矩阵与降级语义：`interface.zig` 的 `windows_capabilities` / `linux_target_capabilities`
  是文档的代码化版本；未实现的钩子留 `null`，调用方得到固定错误名（有单测锁定）；
- 平台无关层（`ipc` / `security` / `fs_api` / `protocol` / `net` / `sql` / `store` / `updater` /
  `patch` / `pack_formats` / `bindings`）两平台共用；
- 平台层通过 `ipc.Context` 的函数指针（`clipboard_*`、`webview_request_fn`、`spawn_window_fn`…）
  向核心暴露能力，Windows 后端直接实现，Linux 后端（v0.2）同样实现；
- 线程封送：Windows = `PostMessageW(WM_ZILT_*)`，Linux = `g_idle_add`（详见
  [`docs/v0.2-LINUX.md`](v0.2-LINUX.md) §3.3）。

## 用户视角的 API

```zig
// src/main.zig
try zilt.run(.{
    .commands = app.commands,   // JS→Zig：pub fn 名(ctx, args: struct{...}) !结果
    .events   = app.events,     // JS→Zig 事件：pub fn 名(ctx, payload: struct{...}) void
    .assets   = &app.assets,    // embedded 资产表（@embedFile）
    .title    = "...", .url = "https://zilt.app/index.html",
});

// 命令处理器内
ctx.emit("tick", .{ .n = 1 });  // Zig→JS 事件（任意线程安全；发往当前窗口）
ctx.emitTo(2, "tick", .{});      // 指定窗口
ctx.windowSetTitle("新标题");    // 窗口控制（minimize/maximize/restore/fullscreen/size/position/show/hide/focus/close）
ctx.windowSetAlwaysOnTop(true);  // v0.1.7
ctx.windowStartDragging();       // 自定义标题栏拖动
const id = try ctx.newWindow(.{ .title = "子窗口", .url = "https://zilt.app/second.html" });
try ctx.clipboardWriteText("hello");  // 剪贴板
ctx.quit(0);                    // 请求退出
```

前端（自动注入 `window.zilt`，v0.1.16 全量）：

```js
const r = await window.zilt.invoke('greet', { name: 'Zilt' }); // Promise
window.zilt.emit('frontendLog', { msg: 'hi' });                // JS→Zig 事件
window.zilt.on('tick', (p) => console.log(p.n));               // Zig→JS 事件
// 窗口/子窗口：window / webview / clipboard / drag / notification
// 系统能力：menu / tray / hotkey / taskbar / system / shell / autostart / appearance
// 周边 API：store / fs / path / log / opener / windowState / services
// 异步网络：http.request（后台线程） / ws（connect/send/close/on）
// 单窗口多 WebView：webviews.create/remove/navigate/setBounds/focus/list
```

TS 工程：`zig build gen` 生成 `frontend/bindings/zilt.ts`（全类型命令函数 + 事件负载表）。

## 关键机制

| 机制 | 实现 |
|---|---|
| 运行时发现 | 纯 Zig：注册表 `ClientState/Clients` 三路 + 目录扫描（无官方 loader DLL） |
| COM 调用 | 手写 vtable（对齐官方 SDK 1.0.4314.35），事件处理器 = 运行时 COM 对象（原子引用计数） |
| IPC 传输 | JS→Zig `chrome.webview.postMessage`；Zig→JS `PostWebMessageAsJson` |
| 分发 | comptime 反射生成 if-chain：args 自动 JSON 解析、结果自动序列化、错误名 → reject |
| 内存契约 | per-message arena（命令域）+ `msg_allocator`（跨线程消息域）；`Context.emit` 全程用后者 |
| 线程编排 | 后台线程 `emit` → `PostMessageW(WM_APP+1)` → UI 线程投递 → 释放 |
| origin 校验 | `get_Source` → origin 白名单（app origin + config.origin + dev.url origin） |
| dev-dir | 文件签名轮询 watcher（后台线程）→ `__reload` 事件 → 运行时 JS 自动 `location.reload()` |
| dev-url | 直接导航 Vite（HMR 由前端工具链承担），自动加入 origin 白名单 |
| 托盘/通知 | 托盘 Shell_NotifyIconW（tooltip/左键显隐）；notify 主通道 **WinRT Toast**（toast.zig 纯 Zig：combase 运行时加载 + AUMID 开始菜单快捷方式自动供给 + balloon 降级，无需托盘启用），经 WM_APP marshal |
| 单实例 | 命名互斥体 `Local\zilt-single-<app_id>`；第二实例 exit 5 |
| 菜单 | `config.menu` 声明式树 → comptime id 表（DFS 叶子序）↔ win32 菜单 id；WM_COMMAND → emit `"menu"` |
| 对话框 | `ctx.messageBox/openFile/saveFile/pickFolder/pickFiles/pickColor/pickFont`（comdlg32 + MessageBoxW + IFileOpenDialog COM）；UI 线程模态调用 |
| 更新器扩展 | 重启触发（接力进程 `--zilt-restart`，单实例互斥体释放后拉新版）+ 增量/差分（zilt-patch v1：4KiB 块差分，补丁签名/重建摘要/全量复核三重校验，失败回退全量） |
| 多平台打包 | `zig build pack`：.deb（纯 Zig ar+ustar+gzip）/ WiX .wxs / signtool 命令 / macOS .app+plist / AppImage AppDir / rpm spec（pack_formats.zig 纯函数）；Windows exe/rel_app 与模板均 `subsystem = .windows`（GUI 运行无控制台窗口），PE 资源内置 Zig 图标 |
| 全局快捷键 | `config.hotkeys`（key 编译期校验）→ RegisterHotKey；WM_HOTKEY → emit `"hotkey"` |
| 多窗口 | `Window` 实例（hwnd/controller/webview/处理器/标题/URL）共享 Environment；每窗口独立 IPC/资产/注入/导航；`Context.window_id` + `emitTo` 按窗口路由；`ctx.newWindow`；关闭窗口释放 COM 并广播 `windowDestroyed`，全部关闭才退出 |
| 窗口配置/事件 | `WindowConfig`：`x/y/visible/resizable/decorations/transparent/always_on_top/skip_taskbar/min/max/background_color/close_requested_event/icon`；frameless=`WS_POPUP+THICKFRAME`、透明=`WS_EX_NOREDIRECTIONBITMAP`+Controller2 `DefaultBackgroundColor(A=0)`、置顶=`HWND_TOPMOST`、任务栏隐藏=`WS_EX_TOOLWINDOW`；事件 `windowMoved/Resized/Focus/Blur/ThemeChanged/ScaleFactorChanged/CloseRequested/Destroyed`（WM_MOVE/SIZE/SETFOCUS/KILLFOCUS/THEMECHANGED/DPICHANGED/CLOSE/DESTROY）；自定义标题栏 `data-zilt-drag-region` → `startDragging`（WM_NCLBUTTONDOWN/HTCAPTION） |
| 窗口控制 | `WM_ZILT_WINCTL` + SendMessage 同步 marshal（任意线程）：标题/最小化/最大化/还原/全屏/尺寸/位置/显隐/聚焦/关闭；全屏保存恢复 style+RECT |
| 托盘菜单/图标 | `Config.Tray.menu` 弹出菜单（id 从 100 起，`TrackPopupMenu`）→ emit `trayMenu`；默认图标为内置 Zig logo（`src/zilt/assets/zilt.ico`，多尺寸，框架 `@embedFile`）；**按目标尺寸创建 HICON**（托盘/标题栏 `SM_CXSMICON`，任务栏/Alt-Tab `SM_CXICON`；`pickNearest` + `CreateIconFromResourceEx` 缩放，避免 256px 图标被托盘 1:1 裁切）；exe 资源经 `module.addWin32ResourceFile` + `zilt.rc` 嵌入（`project.icon` 自定义），窗口/托盘可用 `Config.icon`/`Tray.icon` 指向资产 `.ico` 覆盖 |
| 图标解析 | 纯 Zig ICONDIR 解析（多尺寸挑最大）+ `CreateIconFromResourceEx`（支持 BMP/PNG 条目）；自定义缺失回退内置 Zig 图标 |
| 剪贴板/拖放 | `ctx.clipboardWriteText/ReadText`（CF_UNICODETEXT，WM_ZILT_CLIP marshal）；`DragAcceptFiles` + WM_DROPFILES → emit `dropFiles {files[]}` |
| 深链接/文件关联 | `Config.DeepLink`：启动参数分类（scheme URL/现存文件）→ 导航完成 emit `deepLink`；HKCU per-user 注册协议/扩展名；第二实例 `WM_COPYDATA` 转参与聚焦后 exit 5 |
| Range 资产 | `Range: bytes=a-b / a- / -n` 单区间解析；200 附 `Accept-Ranges`，命中 206 + `Content-Range`，非法 416（纯函数单测 + 前端 fetch 实测 206） |
| 自动更新 | manifest(url/sha256/ed25519 签名) → 版本比较 → 下载 → 双重校验 → zip 提取 → .zilt-new/.zilt-old 原子替换 → 重启生效；公钥内置于配置（env 可覆盖） |
| 资产 codegen | build.zig 遍历 `frontend.dist`（win32 FindFirstFile，排序稳定保缓存）→ 生成 zilt-assets @embedFile 模块；>8KB 且 gzip 收益 ≥10% 的资产只嵌 .gz 字节（`Asset.encoding=.gzip`，缩 exe）；node_modules 等排除；dist 缺失空表降级。**内容寻址落盘** `.zilt-cache-assets/<wyhash(路径+内容)>/`：内容变→目录名变→必重编，旧目录保留（WriteFiles manifest 不跟踪同名内容变更 / addCopyFile 陈旧引用构建失败，两坑均实测）；configure 期副作用经 `graph.poisonCache()` 声明（0.17 求值缓存对 Win32 IO 不可见，dependOn* 有依赖集覆盖洞）——求值每次重跑，step 编译缓存不受影响 |
| 资产服务 | custom scheme 拦截（`AddWebResourceRequestedFilter`）+ 内存 IStream 响应；压缩资产首次请求惰性解压 + 进程内缓存，恒以 identity 下发（custom scheme 不走网络栈内容解码，实测见 reference §G.6/G.7）；If-None-Match→304 逻辑就绪（当前通道不回传验证器，休眠） |
| 反代 dev 模式 | `ZILT_DEV_PROXY=<dev_url>`（config `frontend.dev_proxy`）：应用保持自身 origin，资产请求经 custom scheme 处理器同步转发上游（Content-Type 透传）；keep-alive 死连接重建连接池重试一次；HMR 由模板预置的显式 `server.hmr` 直连 vite ws，热更新模块经代理 `?t=` 重取 |
| 前端工程化 | `project.zig` Config.Frontend（dir/dist/build_command/dev_command/dev_url/dev_proxy，单一配置源）；`zig build frontend` spawn build_command（cwd=frontend）；`zig build dev` spawn dev_command → TCP 直连 127.0.0.1 探测 → 注入 ZILT_DEV_URL（或 ZILT_DEV_PROXY）→ Job Object 整树清理 |
| fs.watch / 流式读（v0.1.22） | `ReadDirectoryChangesW` 阻塞线程 + `CancelIoEx` 停止；`fs.readStream` 分块 base64 → `fsChunk`；SQL `migrate` 事务化 + `PRAGMA user_version` |
| 安全（v0.1.21） | `aclAllowed(kind, resource)` 合并编译期 `Capability.scopes` 与运行时授权（`<appData>\acl.json`，启动加载）；fs/http(s)/shell 三处执行点统一拦截；`freeze_prototype` 冻结 window.zilt + 内建原型 |
| 网络（v0.1.20） | WinHTTP 动态加载：`WinHttpOpen/Connect/OpenRequest/SendRequest/ReceiveResponse/ReadData`；https/代理/重定向/证书策略；wss 用 `WinHttpWebSocketCompleteUpgrade`（ws:// 仍走自研帧层）；流式下载分块经 `WM_ZILT_HTTP_CHUNK` → `httpChunk` 事件 |
| fs 全量 / scope | 12 个操作 × 11 个根目录（userSubdir 环境变量解析 + exe 目录）；写入/复制自动 mkdir -p，removeDir 用 FindFirstFileW 递归；每次访问先查 capability `scopes`（appData 私有目录豁免） |
| 流式通道 | `__zilt.channel` 事件 + JS 侧 `Map` 分发；Zig `ctx.channelSend/close` 按 seq 推送（无背压） |
| MCP 服务端 | headless `POST /mcp`：JSON-RPC 2.0，tools 由 `commandMetas` comptime 生成（name/description/inputSchema），tools/call 复用 `ipc.dispatch` |
| 窗口精细控制 | v0.1.18：光标（WM_SETCURSOR + LoadCursorW）、鼠标穿透（LAYERED\|TRANSPARENT + alpha 255）、防截屏（WDA_EXCLUDEFROMCAPTURE）、阴影（DwmExtendFrame）、置底（WM_WINDOWPOSCHANGING）、不可聚焦（WS_EX_NOACTIVATE）、标题栏配色（DWMWA_CAPTION/TEXT/BORDER_COLOR）、运行时图标、运行时 min/max、指定屏全屏、`window.state()` 快照 |
| 菜单加速键 / 角色 / 图标 | 菜单 `accel` → ACCEL 表 → `TranslateAcceleratorW` → WM_COMMAND；`role` 走原生 WM_* 或 `execCommand`（paste = 原生读剪贴板 + insertText）；`icon` 经 GetIconInfo → `SetMenuItemBitmaps` |
| 多 WebView 数据分区 | `webviews.create({partition})` → 独立 `ICoreWebView2Environment` + `<profile>\WebView2-partitions\<name>` UDF；同名复用；子页面脚本经 `eval`（WM_ZILT_EVAL 延后 + 事件回传，禁止在 IPC 回调里重入 ExecuteScript） |
| WebDriver 自动化 | `zilt-driver`：msedgedriver（W3C 协议）+ 应用 `--remote-debugging-port`（`ZILT_WEBVIEW2_ARGS`）→ `/session` + `/execute/sync` 断言；无驱动 SKIP(3) |
| CI 流水线 | `.github/workflows/ci.yml`：test（构建/单测/冒烟/WebDriver）→ package（NSIS+zip）→ tag 签名发布；Edge 版本自动匹配驱动 |
| 日志轮转 | `log.initFileLog` 启动时 4MB 阈值轮转（`.1/.2/.3`，MoveFileExW） |
| 项目脚手架 | `zig build init`（ZILT_INIT_TEMPLATE=vanilla\|vue\|react\|svelte ZILT_INIT_NAME=…）：复制模板 + vendored src/zilt、src/tools（项目自包含）+ 占位符替换（APP_NAME/APP_ID/VERSION/ZON_NAME/FINGERPRINT）；指纹算法对齐 Zig 包管理器（高 32 位随机 id + 低 32 位 crc32(zon name)） |
| 系统能力通道 | `window.zilt.*` 全部归一到 `system_api.Request` union → UI 线程单次 marshal（`WM_ZILT_ACTION`）→ 类型化 `Result` → JSON；新能力只扩一个分支，不给 ipc.Context 加函数指针；capability ACL 在通道入口统一强制 |
| http（异步） | 后台线程 `std.http.Client.fetch` → `PostMessageW(WM_ZILT_HTTP)` → `httpResponse` 事件 → JS Promise。同步实现会冻结 UI 数秒（IPC 在消息循环里处理）；错误穿透线程→消息→事件→reject 全链路实测 |
| websocket | 协议层 `ws.zig` 纯逻辑（握手 SHA1+base64 / 帧掩码 / CRLF，14 单测）；backend 后台线程握手 + 读循环（`WM_ZILT_WS`），写端 `std.Io.Mutex` 串行化（UI send 与读循环 pong 共享）；ping 自动 pong、close 回声、EOF→close 1006；`readSliceShort` 填不满会永久阻塞，帧读取必须 `takeByte`（实测坑） |
| 多 WebView | WebView2 每 HWND 只能绑一个 controller → 附加 webview 各建 `WS_CHILD` 子窗口（自注册类）；`onChildControllerReady` 挂 IPC sink/资产拦截/runtime 注入/pending_url 排队；IPC 回复按 sender 路由（`sendJsonTo`：子 webview 的 invoke 回子页面）；就绪前销毁子 HWND → 官方定义 E_ABORT 中止路径（实测安全）；子 webview 不挂 driver（devtools/下载属主内容区） |
| services | `Config.services` 声明（name/init_fn/deinit_fn/scope）→ 框架 init/start、逆序 deinit；`window.zilt.services.list/status/start/stop`；框架不解释 state、不代理方法（方法级桥接走 commands） |
| 打包链 | NSIS（per-user/per-machine/License/协议关联/升级检测）+ MSI（WiX 3.14.1 自动 vendor+SHA256 缓存）+ MSIX（AppxManifest 生成、ICO→PNG 帧提取、预发布版本号丢弃、makeappx）+ Authenticode 签名（signtool 自动定位：PATH→KitsRoot10→AppCertKit；PFX 路径/base64/指纹三源）+ 更新器通道（restart helper 崩溃回滚 + 10s 健康确认） |
| 打包产物 | `zig build bundle` → dist/Zilt-<ver>-x64.zip + -setup.exe；`ZILT_PACK_TARGET=msi\|msix\|sign zig build pack` |

## 运行模式

| 模式 | 触发 | 资产来源 | 热重载 |
|---|---|---|---|
| embedded | 默认 | @embedFile 资产表 | — |
| dev-dir | `ZILT_DEV_DIR=<dir>` | 磁盘目录（带路径穿越防护） | watcher → `__reload` |
| dev-url | `ZILT_DEV_URL=<url>` | Vite 等外部 dev server | 前端工具链 HMR |
| dev-proxy | `ZILT_DEV_PROXY=<url>`（config `frontend.dev_proxy`） | 反代转发上游 dev server（应用保持自身 origin） | HMR 直连 ws + 模块经代理 `?t=` 重取 |

## 测试

- `zig build test`：**226/226**（框架核心 root.zig 209 + 工具链 17；含协议编解码/分发/TS 生成、
  更新器验签+staging、zip/NSIS、Range 解析、.ico 解析、深链接、窗口 style/ACL、
  剪贴板/拖放/Toast、系统能力请求/存储/受限 fs/服务注册表、WiX vendor/MSIX manifest/
  NSIS 增强/签名凭据/base64 解码、http、**WebSocket 协议**（握手/帧往返/NeedMore/URL 解析））
- GUI 冒烟：`ZILT_SMOKE_TEST_MS=<ms> ZILT_SMOKE_EXIT=1 zig-out/bin/zilt-app.exe`
  **30 项**前端检查（greet/算术/错误路径/事件/模式/剪贴板/窗口/Range/窗口事件/窗口 API/eval/
  webview API/capability ACL/多窗口剪贴板/通知/ACL 拒绝/SPA/托盘/任务栏/快捷键/系统信息/
  外观/自启/存储/外围/服务/http/ws/webviews）→ `smokeResult` → Zig 断言 → exit 0/1
- 多窗口 E2E：`ZILT_SMOKE_MULTI=12`（1=建第二窗口，第二位 2=3s 后自动关闭）
- 深链接 E2E：首实例运行中再执行 `zilt-app.exe zilt://x` → 第二进程 exit 5，首实例收到
  `deepLink`；带参数首次启动同样在导航完成后发事件
- 热重载冒烟：`ZILT_SMOKE_TEST_MS=12000 ZILT_DEV_DIR=frontend` + 运行中改文件 → 日志断言

## 边界与已知事项

- 多窗口共享同一 Environment；窗口对象在应用生命周期内保留（关闭只释放 COM 资源）
- 多 WebView 的子 webview 与主 webview 共享 user data folder（数据分区需独立
  Environment，未实现）；子 webview 不挂 driver（devtools/下载/事件面属主内容区）；
  Zig→JS 事件只广播主 webview
- websocket 仅 ws:// 明文（wss 明确报 `UnsupportedScheme`，TLS 未接线）；不支持
  分片帧（FIN=0 续帧视为协议错误）与扩展协商；http `timeout_ms` 透传未强制
  （std.http.Client.fetch 无超时参数，真正超时需看门狗线程）
- 透明窗口依赖 `ICoreWebView2Controller2` + `WS_EX_NOREDIRECTIONBITMAP`；旧版 WebView2 不支持时降级为不透明
- `close_requested_event` 为 opt-in：启用后 WM_CLOSE 只发 `windowCloseRequested`，需前端调用 windowClose
- Range 仅单区间（多区间返回 416）
- `ExecuteScript` 结果串不可 CoTaskMemFree（实测崩溃，见 docs/reference §G.2）
- dev-dir 读盘内容生命周期到响应发出（微小泄漏面，正式实现挂响应完成回调）
