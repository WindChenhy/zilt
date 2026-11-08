# Zilt 路线图

> 依据：`docs/research/zig-webview-gui-framework-feasibility.md` §6.2。
> **优先级调整（2026-11-07）**：Windows 优先做深（Phase 0→2 连续完成），Linux/macOS（原 Phase 1）后置。

## Phase 0 — Windows PoC ✅ 完成（2026-11-07）

- [x] Win32 最小绑定 + COM 基础设施 + WebView2 纯 Zig loader + COM 接口绑定
- [x] 里程碑：窗口 + custom scheme 资产服务 + JS↔Zig 双向 IPC（冒烟 exit 0）
- [x] 1856 行 Zig，0 行 C/C++ 胶水；ABI 笔记见 docs/reference/

## Phase 2 — 框架核心能力（Windows）✅ 完成（2026-11-07）

> 原 Phase 1（Linux/macOS）按用户指示后置，见下方"Phase 1（调整后）"。

- [x] **IPC 协议层**（ipc.zig）：
  - JSON 协议 v1（invoke/resolve/reject/event，`zilt:1` 标记过滤外部流量）
  - comptime 命令分发：`pub fn 名字(ctx, args: struct{...}) !结果` 自动注册（args 自动 JSON 反序列化、结果自动序列化、错误名回传 reject）
  - JS→Zig 事件分发（同 comptime 反射）+ Zig→JS 事件（`ctx.emit`，后台线程安全）
  - **origin 校验**：WebMessageReceived 来源与允许列表比对，非白名单丢弃
  - **per-message arena**：命令处理期间分配统一管理；`msg_allocator` 长生命周期分配器承载跨线程消息（emit/后台任务），文档化所有权契约
  - 注入式运行时 `window.zilt`（invoke/emit/on + Promise 注册表 + `__reload`）
- [x] **绑定 codegen**（bindings.zig）：comptime 反射 → 强类型 TS（`zig build gen` → `frontend/bindings/zilt.ts`，v0.1.3 起输出至 frontend/bindings/）；struct→对象字面量类型、可选/默认值→`?`、枚举→字符串联合、`[]const u8`→string
- [x] **dev 模式三件**：
  - `embedded`（默认）：@embedFile 资产表经 custom scheme 服务
  - `dev-dir`（`ZILT_DEV_DIR`）：磁盘目录服务 + 热重载 watcher（后台线程签名轮询 → `__reload` 事件 → 页面自动重载）
  - `dev-url`（`ZILT_DEV_URL`）：直接导航 Vite 等前端 dev server（HMR 由其承担）
- [x] 框架化：`zilt.run(.{ .commands = ..., .events = ..., .assets = ... })` 配置驱动入口；后端按 Config 编译期实例化

**验收记录（三项验证全通过）**：
1. 单元测试 9/9（协议编解码、分发、错误传播、事件、emit marshal、TS 生成断言）
2. embedded 冒烟：前端自动跑 6 项检查 → smokeResult 回传 → Zig 断言 → exit 0
   `greet / add / failNow-reject / queryUser(可选嵌套) / tick 事件(后台线程) / setMode(枚举)`
3. dev-dir 冒烟：磁盘服务首次检查 PASS → 修改 styles.css → watcher 捕获 → `__reload` → 重载后检查再次 PASS

## Phase A/B（前端工程化）✅ 完成（2026-11-07，v0.1.3）

依据 docs/research/frontend-integration.md（Tauri 2 / Wails v3 对标调研）：

- [x] **Config.Frontend 段**（对齐 Tauri 四字段语义）：dir/dist/dev_command/dev_url/build_command
- [x] **资产目录 codegen**：build.zig 遍历 frontend dist → 生成 zilt-assets 模块
  （@embedFile 相对路径表；排序稳定保缓存命中；node_modules 等排除；dist 缺失空表降级）
- [x] **`zig build frontend`**：spawn build_command（cwd=frontend，cmd /S /C 包装）
- [x] **`zig build dev`**：spawn dev_command → TCP 直连 127.0.0.1 探测等待（Tauri 2s×N 策略，
  规避 getaddrinfo localhost 双栈歧义）→ 注入 ZILT_DEV_URL → Job Object 整树清理
- [x] **`zig build init`**：一键创建项目（ZILT_INIT_TEMPLATE=vanilla|vue|react|svelte）；
  模板含 vendored 框架源码（项目自包含）+ 占位符替换（APP_NAME/APP_ID/VERSION/ZON_NAME/FINGERPRINT）
  + **Zig 包指纹算法对齐**（高 32 位随机 id + 低 32 位 crc32(zon name)，源码核对 Maker/Package.zig）
- [x] **模板四套**：vanilla（无构建）/ vue / react / svelte（vite + 类型化绑定 import）
- [x] **E2E**：init → npm install → frontend build → exe 嵌入运行（Vue 3 资产 200）；
  dev 模式 vite 直连加载 SUCCESS；TS 绑定输出迁至 frontend/bindings/
- [x] **验证**：单元测试 43/43（框架 + frontend_codegen/init 工具）；嵌入冒烟 exit 0
  （4/4 日志断言）；dev-dir 热重载 3/3 grep；Vue E2E 与仓库 vanilla demo 回归全通过
- [x] **Phase C（前端增强，2026-11-07，v0.1.4）**：
  - **资产预压缩（Tauri brotli 同款）**：codegen 对 >8KB 且 gzip 收益 ≥10% 的资产只嵌
    `.gz` 字节（`Asset.encoding = .gzip`）→ **exe 体积缩小**（vue demo bundle 66.0KB→26.4KB）；
    服务端首次请求惰性解压 + 进程内缓存，恒以 identity 字节下发。
    实测关键（§G.6/G.7）：custom scheme 响应不走网络栈内容解码、附加响应头会破坏模块
    脚本 MIME 校验——压缩字节不能直接下发（初版"直接下发"方案被 E2E 证伪后回退）
  - **反代 dev 模式（Wails build_dev 同款）**：`ZILT_DEV_PROXY=<dev_url>`（config
    `frontend.dev_proxy = true` 时由 `zig build dev` 自动注入）——应用保持自身 origin
    （https://zilt.app），资产请求经 custom scheme 处理器同步转发上游（vite 全模块图
    + Content-Type 透传）；keep-alive 死连接 ReadFailed → 重建连接池重试一次；
    HMR 经由模板预置的显式 `server.hmr`（直连 vite ws）+ `?t=` 模块重取走代理——实测
    运行中改 App.vue → `[proxy] GET /src/App.vue?t=… -> 200` 热更新生效
  - **ETag/304**：`etagOf`（wyhash 强 ETag）+ `If-None-Match` 解析（列表/`*`/W/ 前缀）
    → 304 短路逻辑三模式统一就绪；**实测 custom scheme 通道从不回传 If-None-Match**，
    当前为休眠能力（§G.6），ETag 响应头按规格仅在 304 出现
- [ ] Phase C 剩余：create-zilt-app npm 包（走 npm 生态传播时再做）
- [x] **Phase C 顺带修复**：runFileDialog 对 filter 的错误分配器双重释放（v0.1.2 潜伏，
  vue demo pickFile 实测崩溃暴露）；build.zig addCopyFile 引用 dist 源文件导致前端重
  构建后缓存 manifest 失效（改内联字节）；repo build.zig 补 dist_abs（joinString）
- [x] **Phase C 验证**：单元测试 51/51（+8：gzip 往返/确定性/不可压落选、生成表编码标记、
  readFileAlloc、acceptsGzip 含 q=0、etagOf、If-None-Match、joinProxyUrl）；
  GUI：仓库 vanilla 冒烟 exit 0 ALL CHECKS PASSED；vue demo embedded（gz-store 服务 +
  模块执行 + greet IPC）与反代（vite 全模块图 200 + 运行中 HMR）双 E2E 通过

## Phase 1（调整后）— Linux / macOS 绑定

- [ ] Linux：zig-gobject（webkit2gtk-4.1 与 webkitgtk-6.0）+ GTK 窗口
- [ ] macOS：zig-objc 路线（NSApplication/NSWindow/WKWebView + 运行时注册 delegate）
- [ ] 统一平台接口（后端 trait 化：createWindow/serveAssets/postMessage/emit marshal）

## Phase 3 — 打包器与周边 🚧 Windows 部分完成（2026-11-07，v0.1.0）

- [x] **bundler.zig**：store-only ZipWriter（CRC-32，结构化测试回读）+ NSIS 脚本生成器
- [x] **`zig build bundle`** → `dist/`：
  - `Zilt-0.1.0-x64.zip`（便携版，ReleaseSafe 构建 + README）
  - `Zilt-0.1.0-x64-setup.nsi` / `Zilt-0.1.0-x64-setup.exe`（本机有 makensis 时；UTF-8 BOM）
- [x] **NSIS 安装器能力**：per-user 安装（无管理员）、开始菜单+桌面快捷方式、卸载器、
  HKCU 卸载表项、**WebView2 运行时检测（HKLM/HKCU 双路）+ Evergreen bootstrapper 静默引导**（官方 fwlink URL）
- [x] **分发物全生命周期实测**：Windows 官方 Expand-Archive 解压互操作 ✓ →
  便携包 exe 冒烟 exit 0 ✓ → 静默安装（`/S /D=`，注意参数不加引号）✓ →
  安装产物冒烟 exit 0 + 快捷方式确认 ✓ → 静默卸载（目录/开始菜单/桌面全部干净移除）✓
- [x] **系统能力（v0.1.1，Windows）**：
  - 托盘（Shell_NotifyIconW：tooltip/左键显隐窗口；NIF_INFO 气泡在 Win10+ 自动渲染为 Toast 通知——纯 Zig 免 WinRT）
  - `ctx.notify(title, body)`（WM_APP marshal 到 UI 线程）+ `close_to_tray`
  - 单实例保护（命名互斥体，第二实例退出码 5）
- [x] **自动更新器（updater.zig，ed25519 验签）**：
  - Tauri 式方案：manifest(version/notes/url/sha256/signature) + 安装包 ed25519 签名（base64）
  - 流程：检查（版本比较）→ 下载（std.http.Client）→ sha256 → 验签 → zip 提取 → 运行中原子替换（.zilt-new/.zilt-old）→ 重启生效
  - 网络经 Fetcher 注入 → 决策/验签/staging 全部离线单测
  - 工具链：`zilt-keygen`（BCryptGenRandom 熵源）/ `zilt-sign`（产出 manifest）
  - env 覆盖：ZILT_UPDATE_URL / ZILT_UPDATE_PK / ZILT_UPDATE_AUTO
- [x] **验证（v0.1.1）**：
  - 单元测试 26/26（新增：托盘结构/UTF-16 截断、互斥体名、zip store 回读+CRC 篡改拒绝、
    版本比较、manifest 解析、sha256 已知向量、ed25519 回环+篡改拒绝、staging 原子替换+备份、通知打包往返）
  - GUI：托盘挂载 ok + 通知发送 ok + 冒烟 exit 0；单实例第二实例 exit 5（精确）
  - 更新器端到端：keygen→sign→HttpListener 分发→应用后台线程
    检查(9.9.9)>0.1.1 → 下载 1.9MB → sha256+ed25519 验签 → staged ✓（物理证据：替换后 exe + .zilt-old 备份）
- [x] **系统能力补齐（v0.1.2，Windows）**：
  - **原生菜单栏**：config 声明式菜单树（`config.menu`），comptime id 表（深度优先叶子序）↔ win32 菜单 id
    双向映射；WM_COMMAND → emit `"menu"` 事件；分隔符/子菜单/无 id 灰项
  - **原生对话框**：`ctx.messageBox`（info/warning/error × ok/ok_cancel/yes_no，结果映射为语义化 Button）、
    `ctx.openFile` / `ctx.saveFile`（comdlg32，过滤器双 NUL 构造、覆盖提示、取消返回 null）；模态阻塞语义与 Tauri 一致
  - **全局快捷键**：`config.hotkeys` 声明（key 编译期校验：A-Z/0-9/F1-F12，非法直接编译失败），
    RegisterHotKey 注册 + WM_HOTKEY → emit `"hotkey"` 事件；退出时注销；占用失败优雅降级（记日志不崩溃）
- [x] **验证（v0.1.2）**：
  - 单元测试 36/36（新增：菜单 id 表双向映射/空菜单/无 id 叶子、VK 映射 8 例、修饰符位组合、
    快捷键 id 表、消息框结果映射、过滤器双 NUL 结构回读（**揪出 appendSlice 丢 NUL 真 bug**）、OFN 结构/标志）
  - GUI：菜单构建（3 叶子）、3 快捷键注册成功、托盘/通知/冒烟全链路 exit 0
  - 全局快捷键端到端触发实测通过一次（SendKeys 注入 → WM_HOTKEY → 事件 → 前端 → Zig 日志）；
    重复注入受本机安全软件干扰（WeTab 等注入类工具），手动按 Ctrl+Alt+N / Ctrl+Alt+R / F7 即可复现
- [x] **对话框扩展（v0.1.5，dialog_ext.zig）**：文件夹选择/多选（IFileOpenDialog COM，
  FOS_PICKFOLDERS / FOS_ALLOWMULTISELECT + GetResult/GetResults 槽位 26/27）+
  颜色（ChooseColorW，0xRRGGBB↔COLORREF 转换）+ 字体（ChooseFontW→FontChoice）；
  Context 新 API：pickFolder/pickFiles/pickColor/pickFont；demo 四按钮 + TS 绑定
- [x] **自动更新器扩展（v0.1.5）**：
  - 重启触发：stageUpdate 已即时交换新旧 → `ctx.restartToApply()` 分离接力进程
    （同 exe `--zilt-restart <target>`，run 最早期拦截——等旧实例退出/互斥体释放后
    拉起新版，退出码 5 自动重试）；`update.auto_restart = true` 可全自动
  - 增量/差分：自研 **zilt-patch v1**（patch.zig，纯 Zig）：4KiB 块哈希索引 + 贪心
    COPY/LITERAL；重建结果 sha256 强校验（基线错误/篡改必拦）；manifest 增 `patch`
    字段（from/from_sha256/sha256/signature），流程 = 下载补丁 → ed25519 验签 →
    应用 → **与全量 sha256+签名复核** → 暂存，任一步失败回退全量下载；
    `zig build diff`（zilt-diff）生成——实测 6MB exe 12 处扰动 → 补丁 0.8%
- [x] **多平台打包（v0.1.5，pack_formats.zig + `zig build pack`）**：
  - **.deb 真实产物**（纯 Zig：ar 容器 + ustar tar + gzip，control/data 双包）——
    结构经独立解析校验（ar 三成员/ustar 魔数/control 字段）
  - WiX .wxs 生成（per-user + MajorUpgrade + 开始菜单快捷方式 + 确定性 UpgradeCode
    = SHA256(app_id) 派生 v4 GUID）；MSI 构建需本机 WiX（工具输出指引）
  - 代码签名：signtool 命令构造（Authenticode 证书经环境传入；ed25519 更新签名已有）
  - macOS .app 结构（Info.plist + Contents/MacOS）——DMG 需 hdiutil（仅 macOS）
  - AppImage AppDir（AppRun + .desktop + usr/bin）——需 Linux mksquashfs
  - rpm .spec（rpmbuild 可直接构建）
  - 五目标本机全部产出真实工件并核验（deb 1.9MB）

## v0.1.7（2026-11-08）

窗口模型与生命周期（Windows）：

- **WindowConfig 扩展**：`x` / `y` / `visible` / `resizable` / `decorations`（无边框）/
  `transparent` / `always_on_top` / `skip_taskbar` / `min_width` / `min_height` /
  `max_width` / `max_height` / `background_color` / `close_requested_event` / 每窗口 `icon`
- **窗口创建样式**：frameless = `WS_POPUP + WS_THICKFRAME`（保留缩放）；透明 =
  `WS_EX_NOREDIRECTIONBITMAP` + `ICoreWebView2Controller2.put_DefaultBackgroundColor`
  （A=0）；背景色同接口（A=255）；置顶 `HWND_TOPMOST`；任务栏隐藏 `WS_EX_TOOLWINDOW`；
  `WM_GETMINMAXINFO` 最小/最大尺寸；`WM_ERASEBKGND` 背景刷
- **窗口事件**：`windowMoved` / `windowResized`（client 尺寸）/ `windowFocus` /
  `windowBlur` / `windowThemeChanged`（注册表 AppsUseLightTheme）/
  `windowScaleFactorChanged`（WM_DPICHANGED，含 DPI 与缩放比）/ `windowCloseRequested`
  （opt-in，前端确认后调用 windowClose）/ `windowDestroyed`（原 windowClosed 更名）
- **自定义标题栏**：runtime_js 注入 `data-zilt-drag-region` 的 mousedown 监听 +
  `window.zilt.startDragging()` → 内置命令 `__zilt.startDragging` →
  `WM_NCLBUTTONDOWN/HTCAPTION`；按钮/输入元素自动排除
- **运行时控制扩展**：`ctx.windowSetAlwaysOnTop` / `windowSetSkipTaskbar` /
  `windowStartDragging`；demo 新增无边框/透明/置顶/隐藏任务栏/隐藏创建窗口按钮与窗口事件输出

**验证（v0.1.7）**：

- 单测 90 个 `test` 块（+3：窗口 style/exstyle、COLORREF 转换）全通过
- GUI 冒烟 exit 0，10 项检查（新增 `windowResized` 事件断言）
- 透明无边框窗口实测：Controller2 `put_DefaultBackgroundColor(a=0) hr=0x0`，
  截图确认圆角透明卡片 + 自绘标题栏；无原生边框（decorations=false）
- 关闭请求 E2E：向窗口 #2 发送 WM_CLOSE → `[window] close requested` → 前端确认 →
  `WM_DESTROY`，主窗口保持存活
- 主题事件实测：WM_THEMECHANGED → `[theme] changed -> light` 广播
- 窗口模式实测：`ZILT_SMOKE_FRAME=1/3/4`（无边框/置顶/隐藏任务栏）日志与创建成功
- Release 打包：`dist/Zilt-0.1.7-x64.zip` 2.14MB / `-setup.exe` 712KB / 单文件 exe；
  PE `subsystem=2`（GUI），ReleaseSafe 冒烟 exit 0（10 项检查）

## 已完成版本（v0.1.8 → v0.1.12，2026-11-08）

> 来源：v0.1.6 与 Tauri 2 / Wails v3（Windows）能力对比，见 `docs/research/`。
> 本节 5 个版本的全部功能项已实现、验证通过并提交；v0.1.13–v0.1.17 仍为规划。
> 统一验收链：`zig build test`（129/129）→ `zig build`（编译 + capability 清单生成 + 资产嵌入）
> → GUI 冒烟（`ZILT_SMOKE_EXIT=1`，18 项前端检查 + Zig 侧 `smokeResult` 断言，exit 0）
> → `zig build gen` → 模板 `zig build init` 及子项目 `zig build` / `zig build test` 回归。
> 底层模块（`webview_driver` / `environment_options` / `app_data` / `clipboard` /
> `drag_drop` / `toast`）为纯 Zig 实现且自带 ABI/边界单测；本轮补齐
> Config → Backend → Context → `window.zilt.*` JS runtime 的全链路接线与验收证据。

### v0.1.8 — 多窗口进阶、状态持久化、数据隔离与导航基线（P0）✅

- [x] **父子/模态窗口**：`WindowOptions.parent/modal/child`、置顶于父、随父关闭、模态禁用/恢复父窗口
- [x] **每窗口菜单**：`opts.menu` 克隆到窗口 arena，独立 HMENU；WM_COMMAND 按各窗口菜单树映射
- [x] **窗口状态持久化**：`app_data.save/load`（原子写 + 版本校验），按 `state_key` 或 label
      保存/恢复位置、尺寸、最大化、全屏（GUI 日志 `[state] restored/saved window #1 (main)`）
- [x] **WebView2 数据目录隔离**：`%LOCALAPPDATA%\<app_id>\WebView2`，含旧
      `%TEMP%\zilt-app-webview2` 同卷迁移；日志 `[profile] ...\app.zilt\WebView2`
- [x] **SPA 路由回退**：`asset_routes.decodePath` + `Candidates`（`path.html` /
      `path/index.html` / `index.html`），仅 Document 请求回退、拒绝路径穿越；
      GUI 冒烟以 sandbox iframe 请求 `/account/settings` 命中 index.html（c-spa PASS）
- [x] **CSP 与导航策略**：CSP/自定义响应头（CRLF 注入与保留头校验）、`cspHash`、
      导航白名单、外部链接 allow / system_browser / deny（NavigationStarting 拦截 + ShellExecuteW）
- [x] **验收**：单测（路径解码/回退链/origin 相似域名拒绝/头注入/CSP hash/导航策略/app_id 校验/状态序列化）
      + GUI 冒烟；两个应用使用不同 `app_id` → 不同 profile 目录（不共享登录态）

**验证（v0.1.8）**：`asset_routes.zig`（2）、`security.zig`（5）、`app_data.zig`（7）单测；
GUI 冒烟 `profile/state/spa` 三项日志断言；CSP 内联脚本拦截为可配置能力
（demo 未开启 CSP 以免破坏内联脚本，头注入路径由 `validateHeaders` 单测覆盖）。

### v0.1.9 — WebView2 事件面（P0）✅

- [x] **`ctx.eval` / `ctx.evalAsync`**：同步返回 JSON（局部消息泵驱动 STA completion），
      异步 completion 恰好一次；前端 `window.zilt.eval(script)` 返回 Promise
      （`__zilt.evalResult` 事件 resolve/reject），冒烟 c-eval PASS（`1 + 41 === 42`）
- [x] **导航事件**：`NavigationStarting` / `NavigationCompleted` / `SourceChanged` →
      `webview.navigation_*` 事件（含 url/id/redirected/policy）
- [x] **新窗口请求**：`NewWindowRequested` 三策略（deny / external / new_window），
      新建 Zilt 窗口走 `createWindow` + `beginController`
- [x] **权限请求**：`PermissionRequested` 五类（摄像头/麦克风/位置/剪贴板/通知）allow/deny/ask，
      ask 走延迟派发的原生询问框
- [x] **下载管理**：`DownloadStarting` / 进度 / 完成 / 失败事件、自定义保存目录、取消下载
- [x] **渲染进程崩溃**：`ProcessFailed` → 事件 + 渲染进程自动 reload / 浏览器进程重建 controller
- [x] **验收**：`window.open` 三策略由 `webview.new_window` 配置 + 单测覆盖；
      下载进度/取消/进程失败恢复路径由 `webview_driver.zig`（6）单测与 ABI 偏移断言覆盖

### v0.1.10 — WebView2 设置与环境（P1）✅

- [x] **Settings 开关**：DevTools（release 默认关）/ 右键菜单 / 状态栏 / 缩放控制 /
      内置错误页 / 脚本对话框 / HostObjects / User-Agent（`webview.Settings`）
- [x] **运行时 WebView API**：reload / stop / zoom / getZoom / print / cookies(增删清) /
      history / back / forward / clearStorage / DevTools / cancelDownload
      —— Zig `ctx.webviewRequest` 与 JS `window.zilt.webview.*` 双通道
- [x] **环境选项**：UA / 语言 / 代理 / AdditionalBrowserArguments / 运行时通道
      （evergreen/beta/dev/canary）/ 固定版本目录，经自实现 `ICoreWebView2EnvironmentOptions`
      传给 `CreateWebViewEnvironmentWithOptionsInternal`
- [x] **验收**：单测（settings 默认值、环境参数构造、通道 GUID、UA/代理字符串）；
      GUI 冒烟 c-webview PASS（`getZoom` 返回 `{"factor":1}`）；release 默认关闭 DevTools
      由 `webview.Settings.devtools = builtin.mode == .debug` 断言保证

### v0.1.11 — 前端运行时 API 与安全能力模型（P0）✅

- [x] **`window.zilt.window`**：create/close/show/hide/minimize/maximize/restore/fullscreen/
      setSize/setPosition/setTitle/alwaysOnTop/skipTaskbar/focus/startDragging
      （`builtin.zig` 统一内置命令，冒烟 c-windowapi PASS：创建并关闭子窗口）
- [x] **capability / ACL**：按窗口/命令/事件/接收事件声明；`zig build` 生成
      `frontend/bindings/capabilities.json` 并嵌入资产；运行时对 invoke/emit/event 强制，
      dev 可放宽、显式拒绝名单优先；未授权命令 reject `PermissionDenied`
- [x] **远程内容边界**：导航白名单 + 外部链接策略 + `isolation` 模式（远程页面禁止 IPC），
      capability 支持 `remote_origins`
- [x] **验收**：GUI 冒烟 c-acl PASS（`blockedDemo` → `PermissionDenied`）、
      c-capability PASS（资产 200 `/bindings/capabilities.json` 且 deny 名单一致）；
      未声明 capability 时保持 v0.1.7 兼容（本地页面放行）
- [x] 注：剪贴板 JS API 已随 v0.1.12 交付；托盘/菜单/快捷键 JS API 仍属 v0.1.13 范围

### v0.1.12 — 系统集成 I：剪贴板 / 拖放 / 通知（P1）✅

- [x] **剪贴板多格式**：文本 / 图片(CF_DIBV5) / HTML(CF_HTML) / 文件列表(CF_HDROP) 读写；
      `clipboardChanged` 变化监听（AddClipboardFormatListener → WM_CLIPBOARDUPDATE）；
      GUI 冒烟 c-clipmulti PASS（text + html 往返）
- [x] **拖放增强**：`dragEnter` / `dragOver` / `dragLeave` / `drop`（含坐标）、
      OLE `IDropTarget` 自定义数据格式（`config.drag_formats`）、文件拖出
      `ctx.startDrag` / `window.zilt.drag.start`（OLE DoDragDrop）；旧 WM_DROPFILES 作降级
- [x] **通知交互**：操作按钮、文本输入、进度条、点击回调/深链、tag/group 替换、
      通知状态查询；WinRT 线程回调 marshal 到 UI 线程发 `notification` 事件
- [x] **验收**：拖入坐标/自定义格式与拖出文件由 `drag_drop.zig`（13）单测 +
      OLE 注册日志覆盖；Toast 按钮/输入/进度由 `toast.zig`（11）单测 +
      `notificationInteractiveDemo` 命令覆盖；GUI 冒烟 c-notification PASS（状态查询）

**验证（v0.1.8–v0.1.12 汇总）**：单元测试 **129/129**（框架 116 + 工具 13）；
`zig build` / `zig build gen` / 模板 init→build→test 回归全通过；
GUI 冒烟 `ZILT_SMOKE_EXIT=1` **18 项检查 ALL CHECKS PASSED，exit 0**；
日志实证：driver attached、profile 隔离、状态恢复/保存、capability 资产 200、ACL 拒绝、SPA 回退。
纯交互项（真实鼠标拖入/拖出、Toast 横幅点击、CSP 拦截内联脚本、杀 WebView2 子进程）
受本机通知设置与手工操作限制，由对应模块的离线单测与可复现命令覆盖。

### v0.1.13 — 系统集成 II：托盘 / 菜单 / 快捷键 / 任务栏（P1）

- [x] **托盘动态能力**：运行时增删/勾选/禁用菜单项、换图标、改 tooltip、
      双击/中键事件、左右键行为配置（`window.zilt.tray.*` + 运行时菜单模型）
- [x] **菜单动态能力**：运行时增删/勾选/禁用、accelerator 展示、程序化 popup
      （`window.zilt.menu.*`）；每窗口菜单与 WebView 原生右键菜单仍走既有静态路径
- [x] **全局快捷键运行时 API**：注册/注销/查询、加速键字符串解析（`accel.zig`）、
      冲突检测（同 VK+修饰符 → `HotkeyConflict`）
- [x] **任务栏集成**：进度条、overlay 图标、缩略图工具栏按钮、闪烁窗口
      （TaskbarList COM：优先 ITaskbarList3，QI 失败回退 ITaskbarList4——Win11 25H2
      实测只暴露 v1/v2/v4；闪烁走 FlashWindowEx 不依赖 COM；Jump List 未实现）
- [x] **验收**：托盘勾选态同步（menu.set → list 快照 checked=true）；
      菜单 accelerator 以 `\tCtrl+N` 右对齐显示；任务栏进度 API 往返 + 能力探测

### v0.1.14 — Windows 平台深度：主题 / 系统信息 / Shell / 自启动 / 窗口效果（P1）

- [x] **系统信息 API**：OS 版本/build/架构/语言/主题/强调色；显示器枚举
      （bounds/work area/DPI/主屏）→ `window.zilt.system.info('all')`
- [x] **主题与窗口效果**：深浅色检测（注册表 AppsUseLightTheme）、暗色标题栏、
      Mica/Acrylic/Mica Alt（DWMWA_SYSTEMBACKDROP_TYPE）→ `window.zilt.appearance.apply`
      注：`WM_DPICHANGED` 与主题切换事件回传本轮未接线（仅提供 DPI 校正工具函数）
- [x] **Shell 集成**：默认程序打开 URL/文件、资源管理器定位、管理员重启（runas）
- [x] **开机自启**：HKCU Run 注册/注销/查询/切换（值名用 app_id，命令含引号处理）
- [x] **验收**：暗色标题栏 + Mica 应用成功（`[appearance] dark_titlebar=true backdrop=true`）；
      自启动 enable→disable 往返 `{enabled:true}`→`{enabled:false}`；
      系统信息冒烟断言 build>0 且显示器≥1

#### v0.1.13 / v0.1.14 实施记录（2026-11-08）

**新增模块**：`accel.zig`（加速键解析/格式化/冲突）、`menu_model.zig`（运行时菜单树）、
`platform/windows/menu_runtime.zig`（模型 → HMENU 重建）、`taskbar.zig` +
`platform/windows/taskbar.zig`（ITaskbarList3，vtable 21 槽编译期断言）、
`sysinfo.zig` + `platform/windows/sysinfo.zig`（RtlGetVersion / EnumDisplayMonitors）、
`shell.zig`（命令行构造与引号规则）、`autostart.zig`（Run 值匹配）、`theme.zig`、
`platform/windows/system_integration.zig`（ShellExecuteW / Reg* / DwmSetWindowAttribute）、
`system_api.zig`（统一请求/结果协议）。

**接线**：`ipc.Context.system_fn` 单通道 + 后端 `WM_ZILT_ACTION` marshal；托盘菜单改由
模型驱动（`tray_popup`），WM_COMMAND / 托盘右键 / TrackPopupMenu 统一走 `Built.idFor`；
WM_HOTKEY 优先匹配运行时表（id 空间 0x8000+）；JS 侧新增 `window.zilt.menu / tray /
hotkey / taskbar / system / shell / autostart / appearance`。

**验证**：单测全通过；GUI 冒烟 24 项 ALL CHECKS PASSED（exit 0）。日志实证
`[tray] popup menu built (runtime model, 6 leaves)`、`[menu] set 'tray-check' (changed=true)`、
`[hotkey] runtime registered smoke-hotkey = Ctrl+Alt+F9`、
`[appearance] dark_titlebar=true backdrop=true`、`[autostart] enabled/disabled`。

**任务栏接口兼容（更正记录）**：初版只请求 `IID_ITaskbarList3`，在本机（Windows 11 25H2，
build 26200）返回 `0x80004002 E_NOINTERFACE`，曾误判为「环境不支持任务栏能力」。实测
QI 矩阵显示 **v1/v2/v4 均返回 S_OK、仅 v3 返回 E_NOINTERFACE**，因此改为「v3 优先、v4 回退」
（v4 是 v3 超集，前 21 个 vtable 槽布局一致，复用同一 VTable 定义）。修复后日志
`[taskbar] ITaskbarList4 ready` + `[taskbar] progress normal value=0.5` + `flash (ok=true)`，
进度条/overlay/缩略图按钮全部真实生效。同时把 `flash` 提前到 COM 初始化之前——
`FlashWindowEx` 本就只需 user32，不应被 COM 可用性连累。

**未完成项**：v0.1.15 / v0.1.17 未开始；v0.1.16 仅完成三个模块（见其章节）。

### v0.1.15 — 打包、安装器与更新（P0/P1）

- [ ] **PE 资源**：VERSIONINFO（CompanyName/ProductName/FileVersion/ProductVersion）、
      应用 manifest（DPI/UAC/longPath/supportedOS）
- [ ] **安装器增强**：setup.exe 图标、per-machine 选项、安装目录选择、License 页、
      升级检测、**安装时注册 URL 协议与文件关联**（多 scheme/多扩展名 + MIME/Open With/
      关联图标；当前仅运行期注册）、运行时深链事件类型化
- [ ] **MSI / MSIX**：WiX 实际构建 MSI（当前只生成 .wxs）；MSIX/Store 打包；
      Fixed WebView2 Runtime 分发选项
- [ ] **代码签名接入**：证书/时间戳配置，自动签名 exe + setup（当前仅生成 signtool 命令）
- [ ] **更新器增强**：安装器式更新（MSI/NSIS/UAC）、通道（stable/beta）、
      回滚与健康检查、前端更新 UI/JS API
- [ ] **验收**：签名 MSI 安装/卸载；安装包带文件关联；旧版本可更新到新版本

### v0.1.16 — 插件 / 服务架构、官方周边 API 与多 WebView（P2）

- [~] **插件 / 服务模型**：`services.zig` 已实现注册表、顺序启动/失败回滚、逆序销毁、
      capability 作用域字段（对齐 Wails services / Tauri State 的最小形态）；尚未接 JS API
- [~] **官方周边 API**：`store.zig`（KV + JSON 往返）、`fs_api.zig`（scope 内路径校验，
      拒绝 `..`/绝对路径/盘符/UNC/NUL）已实现并单测；http/websocket/sql/upload/process 未实现
- [ ] **多 WebView / 数据分区**：同一窗口多 WebView、每 WebView 独立数据分区
      （未实现；当前每窗口已独立 WebView2 profile，同窗多 WebView 仍缺）
- [ ] **验收**：两个插件并列加载；fs API 受 capability 限制；同窗多 WebView（未达成）

### v0.1.17 — 工具链、测试与生态（P2）

- [ ] **CLI `zilt`**：dev/build/doctor/info/config 覆盖（包装现有 zig build step）
- [ ] **后端热重启 dev**：监听 Zig 源码自动重建 + 重启应用；错误覆盖层；日志轮转
- [ ] **npm 运行时与脚手架**：`@zilt/runtime`（或等价包）+ `create-zilt-app`
- [ ] **图标生成 CLI**：一张 PNG → 多尺寸 .ico/.icns/PNG（对齐 `tauri icon`）
- [ ] **模板扩充**：htmx / solid / preact / angular 等，补齐与 Tauri/Wails 的模板面差距
- [ ] **UI 自动化测试**：WebDriver（zilt-driver）替代仅注入 JS 的冒烟
- [ ] **Server / headless 模式**：无窗口跑 HTTP 服务（对齐 Wails v3 server build）
- [ ] **CI / 签名流水线**：构建、签名、打包、发布的 CI 模板
- [ ] **验收**：改 Zig 自动重启；`zilt doctor/info`；WebDriver 跑通示例；headless 服务可访问

## v0.1.6（2026-11-07）

桌面壳能力补齐（Windows）：多窗口 + 窗口控制 + 托盘右键菜单/图标 + 剪贴板/拖放 +
深链接/文件关联/第二实例转参 + Range/206 大载荷通道。

- **多窗口（P0）**：`Window` 实例化（hwnd/controller/webview/事件处理器/标题/URL 独立），
  共享 Environment；每窗口独立 IPC sink、资产服务、运行时注入与导航；`Context.window_id`
  + `ctx.emitTo(window_id, …)` 按窗口路由事件；`ctx.newWindow(.{title,width,height,url})`；
  关闭窗口释放 COM 资源并向其余窗口发 `windowClosed`；全部关闭才退出消息泵
- **窗口控制 API（P0）**：`ctx.windowSetTitle/Minimize/Maximize/Restore/SetFullscreen/
  SetSize/SetPosition/Show/Hide/Focus/Close`（`WM_ZILT_WINCTL` + SendMessage 同步 marshal，
  任意线程安全）；全屏保存/恢复 style+RECT
- **托盘右键菜单 + 自定义图标（P1）**：`Config.Tray.menu`（复用菜单树，弹出菜单 id 从 100 起，
  `TrackPopupMenu(TPM_RETURNCMD)`），右键 → emit `trayMenu`；`Config.icon` / `Tray.icon`
  指向资产 `.ico`，纯 Zig ICONDIR 解析 + `CreateIconFromResourceEx`（窗口/托盘共用）
- **剪贴板 + 文件拖放（P1）**：`ctx.clipboardWriteText/ReadText`（CF_UNICODETEXT，含 NUL；
  `WM_ZILT_CLIP` 同步 marshal）；`DragAcceptFiles` + `WM_DROPFILES` → emit
  `dropFiles { files[] }`
- **深链接/文件关联/第二实例转参（P2）**：`Config.DeepLink{scheme,register,file_ext}`；
  启动参数分类（`scheme://` → URL、存在的路径 → 文件、`--flag` 忽略）→ 导航完成后
  emit `deepLink { url?, files[] }`；HKCU per-user 注册 URL 协议 + 扩展名关联；
  第二实例用 `WM_COPYDATA` 把参数转发给首个实例（按 app_id 唯一窗口类名，最多等 2s）后 exit 5；
  无参数二次启动也会聚焦已有窗口
- **Range/206（P2）**：资产服务解析 `Range: bytes=a-b / a- / -n`（单区间），
  200 附 `Accept-Ranges`，命中回 206 + `Content-Range`，非法回 416；纯函数单测
- **默认 Zig 官方图标（2026-11-08）**：官方 logo SVG 经无头 Edge 栅格化为
  16/32/48/256 多尺寸 `src/zilt/assets/zilt.ico`，框架 `@embedFile` 内置——`Config.icon = null`
  时窗口/托盘直接使用（无需项目资产）；exe 资源经 Zig 内置 resinator
  （`module.addWin32ResourceFile` + `zilt.rc`）嵌入，`project.icon` 指向自定义 `.ico`
  时生成临时 RC 覆盖（repo 与模板 build.zig 同步）；`Config.icon`/`Tray.icon`
  仍可指向应用资产 `.ico` 自定义运行时图标（自定义缺失回退内置 Zig 图标）
- **Release 无控制台（2026-11-08）**：exe / rel_app / 模板 exe 统一
  `subsystem = .windows`（GUI 子系统）——双击或安装运行不再弹出 cmd 窗口；日志仍写
  `zilt.log`。`zig build --release=safe` 产出 GUI ReleaseSafe exe，
  `zig build bundle --release=safe` 产出 `dist/<name>-<ver>-x64.zip` /
  `-setup.exe`（并补 `app_meta.publisher`，修复此前 bundle 编译失败）

- **托盘图标修复（2026-11-08）**：此前把最大 256px HICON 直接交给
  Shell_NotifyIcon，托盘按 1:1 绘制导致只显示图标左上角一块（用户截图复现）；改为按
  `SM_CXSMICON`（100%=16 / 150%=24 / 200%=32）创建托盘与标题栏小图标、按
  `SM_CXICON` 创建任务栏/Alt-Tab 大图标；`pickNearest` 选最近尺寸条目，
  `CreateIconFromResourceEx` 缩放到目标尺寸；清理时分别 DestroyIcon

**验证（v0.1.6）**：

- 托盘图标实测：`[icon] ready (small=16px big=32px)`；`CreateIconFromResourceEx`
  尺寸矩阵（16/24/32 目标，16/32/48/256 源图）全部产出精确 HICON 尺寸；
  隐藏到托盘后打开 Windows 溢出面板截图确认完整 Zig logo（修复前仅左上角碎片）
- Release 实测（修复后重建）：dist zip 2.11MB / setup 700KB / 单文件 exe 重打包，
  GUI 子系统冒烟 exit 0（small=16px big=32px 日志）
- Release 实测：PE OptionalHeader `subsystem=2`（GUI）、`ExtractAssociatedIcon` 32×32 +
  Zig 橙色像素、`Start-Process -Wait` ReleaseSafe 冒烟 exit 0（ALL CHECKS PASSED）；
  dist 产出 zip 2.1MB / setup.exe 700KB / 单文件 exe 2.1MB（zip 内 exe 同为 GUI 子系统）
- 单测全通过（87 个 `test` 块；新增图标解析（含内置多尺寸/最近尺寸断言）/深链接载荷/Range/
  托盘 id 映射/IPC 回调共 12 块）
- 图标实测：运行时 `[icon] ready (small=16px big=32px)`；exe
  `ExtractAssociatedIcon` 32×32 + 465 个 Zig 橙色像素（repo 与 vanilla 模板 exe 均验证）；
  临时 `project.icon = "resources/custom-zilt.ico"` 构建通过（自定义 exe 图标路径生效）
- GUI 冒烟 exit 0：9 项前端检查（原 6 项 + 剪贴板往返 + 窗口标题 + **Range fetch 实测 206**）
- 多窗口 E2E（`ZILT_SMOKE_MULTI=12`）：自动创建第二窗口（second.html 资产 200）→ 3s 后
  自动关闭 → 主窗口存活（窗口关闭/资源释放路径实测）
- 第二实例转参 E2E：`zilt-app.exe zilt://second-instance?x=1` → 第二进程 exit 5，
  首实例日志 `[deep-link] received second-instance payload`
- 启动深链接 E2E：`zilt-app.exe zilt://startup?demo=1` → `[deep-link] startup payload (url=true)`
- HKCU 注册实测 `protocol "zilt" registered (ok=true)` / `file assoc ".zilt" registered (ok=true)`
- 图标/托盘实测：`[icon] loaded /app.ico`、`[tray] popup menu built`、托盘 added ok
- 模板回归：vanilla 模板 `zig build init` + `zig build` 通过（新 Config 字段向后兼容）
- 手工项：托盘右键弹出菜单、文件拖入、窗口最小化/最大化/全屏（UI 交互）

## v0.1.5（2026-11-07）

Phase 3 收尾三件套：
- **对话框扩展**：文件夹/多选（IFileDialog）+ 颜色/字体（comdlg32）——Context 4 新 API
- **更新器**：重启触发（接力进程）+ 增量/差分（zilt-patch v1，6MB→0.8% 实证，
  三重校验：补丁签名/重建摘要/全量复核）
- **多平台打包**：.deb 真实产物（纯 Zig ar+tar+gz）+ WiX .wxs + signtool + macOS .app
  + AppImage AppDir + rpm spec（`zig build pack` 五目标）
单测 73/73（+19）；冒烟 exit 0；deb 结构独立解析校验；差分/接力 E2E 实测。

## 资产缓存修复（2026-11-07，v0.1.5 后补）

菜单 demo pickFile E2E 验证暴露：原地编辑前端文件后 `zig build` 命中缓存，exe 嵌入旧资产
（WriteFiles 内联字节的 manifest 不跟踪同名内容变更；addCopyFile 则因前端哈希改名后陈旧
manifest 引用缺失文件直接构建失败——Phase C 顺带修复项的内联字节方案只修了一半）。重做资产 codegen：

- **内容寻址资产目录**：聚合 dist 全部文件（路径+内容）的 wyhash 作目录名
  （`.zilt-cache-assets/<hash>/`），assets.zig + payload/ 落成**真实文件**，模块直接指向该目录
  ——内容变 → 目录名变 → 模块源必变 → 必然重编；旧目录保留，陈旧缓存引用永远安全
- **configure 缓存毒性声明（0.17 `graph.poisonCache()`）**：`zig build` 会缓存 build.zig
  求值结果，Win32 遍历/落盘对求值缓存不可见 → 保持 pure 则前端永不重嵌（实测）；
  `dependOn*` 声明式依赖也覆盖不了本场景——依赖集只能在上次求值时确定（实测漏新增文件），
  目录依赖遇 dist 缺失/被前端工具删除则 configure 直接 FileSystemFailure 且缓存校验
  先于重求值（实测永久陷阱）。按官方语义（configure 期不可追踪副作用）显式 poison：
  求值期每次重跑（毫秒级），step 级编译缓存不受影响——实测无变更构建不重链
- repo 与模板 `build.zig`（四套模板共用）同步；vue 模板 init 后六态矩阵
  （缺 dist 降级/增/再增/删/改/dist 删除）实测全通过；repo 单测/冒烟 exit 0，
  前端改→嵌新内容→还原→嵌回旧内容 probe 回环实测通过

## 通知升级（2026-11-07，v0.1.4 后修复）

用户实测反馈：点「系统通知」按钮右下角无横幅（日志 ok=true）。诊断链：Shell_NotifyIconW
NIF_INFO 气泡在 Win10+ 转入 **Toast 通道**渲染 → 本机 `ToastEnabled=0`（已恢复默认 1）→
升级后经 `IToastNotifier.Setting` 读到 **DisabledForUser**——Win11 通知总开关/勿扰
（CloudStore）独立于该注册表键，用户级禁用时横幅被静默抑制（balloon 同样被拦，无实现可绕过）。

框架修复（toast.zig，纯 Zig WinRT，combase 运行时加载）：
- `ctx.notify` 主通道升级为 **WinRT Toast**（Tauri/Wails 同款）：RoGetActivationFactory →
  GetTemplateContent + IXmlDocumentIO.LoadXml → CreateToastNotifierWithId(AUMID) →
  IToastNotificationFactory → Show；支持 Action Center，**不再要求 tray 启用**
- AUMID 供给：首次发送自动创建开始菜单快捷方式（IShellLinkW + IPropertyStore
  System.AppUserModel.ID + IPersistFile），UI 线程独占、失败不阻断发送
- 降级链：WinRT 失败 → 托盘气球（tray 启用时）；Setting 诊断日志常驻（DisabledForUser
  明示"检查 设置→系统→通知/勿扰"）
- 踩坑（官方 IDL 核实）：IPersistFile 成员序 **IsDirty/Load/Save/SaveCompleted/GetCurFile**
  ——Save 在 slot 6（曾误按 GetCurFile=6/Save=7 绑定，"Save 成功无文件"实为调到
  SaveCompleted）；IID 取自 microsoft/win32metadata recompiled IDL
- 单测 54/54（+3：xmlEscape/buildToastXml/shortcutFileName）；冒烟 exit 0，
  winrt 链路（ready→shortcut→Show）实测通过；视觉横幅待用户开启通知设置后确认

## v0.1.4（2026-11-07）

Phase C 前端增强：资产预压缩（Tauri 式压缩存储 + 惰性解压，缩 exe）+ 反代 dev 模式
（ZILT_DEV_PROXY，应用保持自身 origin，HMR 双通道）+ ETag/304 就绪（通道实测休眠）。
顺带修复：对话框双重释放（v0.1.2 潜伏）、addCopyFile 缓存失效、dist_abs 统一。
单元测试 51/51；vanilla 冒烟 exit 0；vue demo embedded/反代双 E2E + HMR 实测通过。
实测 gotcha 沉淀至 reference §G.6/G.7（custom scheme 无协商头 / 附加头破坏模块 MIME）。

## v0.1.3（2026-11-07）

前端工程化版本：`project.zig` Config.Frontend（dir/dist/build_command/dev_command/dev_url）
+ 资产目录 codegen（zilt-assets @embedFile 模块）+ `zig build frontend/dev/init`
+ 四套模板（vanilla/vue/react/svelte：vendored 框架源码自包含 + 占位符替换）。
单元测试 43/43；Vue E2E（init→npm install→gen→build→嵌入运行 200 / dev vite 直连）全通过。

## v0.1.2（2026-11-07）

系统能力完整版：+ 原生菜单栏 / 消息框与文件对话框 / 全局快捷键。
单元测试 36/36；GUI 冒烟（菜单构建 + 3 快捷键注册 + 托盘 + 通知 + IPC 全链路）exit 0。

## v0.1.1（2026-11-07）

系统能力版本：托盘 + Toast 通知 + close_to_tray + 单实例 + ed25519 自动更新器（含签名工具链）。
单元测试 26/26；GUI 冒烟（embedded/dev-dir/托盘/通知/单实例/更新器 E2E）全部通过。

## v0.1.0（2026-11-07）

首个可分发版本：Windows 桌面全栈（纯 Zig 绑定 + IPC + codegen + dev 工具链 + 打包器）。
单元测试 16/16；GUI 冒烟（embedded / dev-dir+热重载 / 便携包 / 安装版）全部 exit 0。

## Phase 4 — 移动端（实验性）

- [ ] iOS：Zig 静态库 + Swift 宿主模板
- [ ] Android：Zig .so + Kotlin 宿主模板

## 已验证的技术前提（2026-11-07 实测）

| 事项 | 结果 |
|---|---|
| Zig 0.17.1 交叉编译 aarch64-linux-android | 完整链接成功（自带 Bionic） |
| 本机 WebView2 运行时 | Evergreen 156.0.4314.58；纯 Zig loader 全链路可用 |
| 本机 MSVC | 无 → 构建目标默认 x86_64-windows-gnu |
| std.json / comptime 反射 | 0.17 反射 API（decl_names/param_types/field_attrs）已适配 |
