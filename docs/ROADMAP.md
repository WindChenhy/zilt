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

> **v0.2 起做 Linux**。详细需求、选型与里程碑见 [`docs/v0.2-LINUX.md`](v0.2-LINUX.md)。
> 技术栈决定：默认 **GTK3 + WebKit2GTK 4.1**（覆盖 Ubuntu 22.04 / Debian 12 / RHEL 9），
> v0.2.5 提供 GTK4 + WebKitGTK 6.0 构建变体（对齐 Wails v3 的现代栈；Tauri 2 目前仍是 GTK3）。
> 绑定用 `@cImport` + pkg-config（GTK/WebKit 是稳定 C ABI），不引入第三方 GObject 绑定。

- [~] **v0.2.0 骨架**
      - [x] 平台接口层（2026-11-12）：`platform/interface.zig`（后端契约 `platform_name` +
            `run(comptime Config) !void` + 能力矩阵 `windows_capabilities` /
            `linux_target_capabilities` + 编译期 `assertBackend`）,`platform/mod.zig` 按
            `builtin.os.tag` 选择后端（Windows/Linux/unsupported），`root.run` 只做转发。
            契约测试：最小 `ipc.Context`（只有必需字段）的降级错误名固定
            （`WebViewNotAvailable` / `ClipboardNotAvailable` / `NotificationNotAvailable` /
            `DialogNotAvailable` / `SystemNotAvailable` / `DragNotAvailable`），
            Linux 后端照此实现即可与 Windows 行为一致；能力矩阵自身无重复且平台独占项不在 Linux 目标集。
            **Windows 回归**：冒烟 49 项 exit 0（接口改动零行为变化）。
      - [ ] Linux 后端实现（GTK3 + WebKit2GTK 4.1）：需 Linux 构建环境；本机 WSL 被安全策略拦截，
            待 CI（ubuntu-22.04 + xvfb）就位后落地——先 `g_application_run` + `WebKitWebView`
            + scheme 资产 + IPC 桥，再补窗口/系统集成
      - [ ] `zilt doctor` Linux 依赖检查（cli.zig 目前深绑 Win32 文件 IO，需随之移植）
      - [ ] `build.zig` 的 Linux 分支（pkg-config 链接 gtk-3 / webkit2gtk-4.1，Windows 资源步骤加 OS 守卫）
- [ ] **v0.2.1 窗口/WebView 面**：多窗口/模态/全屏、eval、devtools、下载、分区、截图、子 WebView
- [ ] **v0.2.2 系统集成**：单实例（GApplication）+ 深链、通知（GNotification）、剪贴板、对话框、菜单、托盘
- [ ] **v0.2.3 安全与数据**：capability/scope 全链路、CSP、`Config.protocols` → 真 scheme、
      fs watch（inotify）/流式、SQL（libsqlite3）、http/ws（libsoup）
- [ ] **v0.2.4 打包与 CI**：deb/rpm/AppImage/Flatpak + Xvfb 冒烟 + WebKitWebDriver
- [ ] **v0.2.5 GTK4 变体与稳定化**：`-Dgtk=gtk4`、Wayland/HiDPI、性能基线
- [ ] macOS：zig-objc 路线（NSApplication/NSWindow/WKWebView + 运行时注册 delegate）——v0.3+
- [x] 平台差异收敛原则：平台无关层（ipc/security/fs_api/protocol/net/sql/store/patch/pack_formats）
      两平台共用，差异只出现在 `platform/<os>/`

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

- [x] **PE 资源**：VERSIONINFO（CompanyName/ProductName/FileVersion/ProductVersion）、
      应用 manifest（PerMonitorV2 / longPathAware / supportedOS / asInvoker）
      —— `src/tools/win_res.zig` 构建期生成 rc + manifest（rc 内嵌 manifest 哈希避免缓存陷阱）
- [x] **安装器增强**：setup.exe 图标、per-machine（admin + Program Files + HKLM）、
      安装目录选择、License 页、升级检测、**安装时注册 URL 协议与文件关联**
      （`ZILT_INSTALLER_*` 环境变量控制；makensis 实测两种变体均编译通过）
- [x] **MSI（WiX 3.14.1 自动 vendor，Tauri 式）**：`wix_vendor.zig` + `tools/wix_tool.zig`
      首次构建时下载 `wix314-binaries.zip` 到 `%LOCALAPPDATA%\zilt\WixTools`，
      SHA256 校验（`6ac824e1…`）+ 缓存复用 + `ZILT_WIX_TOOLPATH` 覆盖 + `ZILT_WIX_NO_DOWNLOAD=1`
      离线模式；`candle -arch x64` + `light` 真实产出 .msi
      **实测**：19 秒完成下载→校验→解压→构建；静默安装/卸载往返 exit 0，
      exe 落 `%LOCALAPPDATA%\Programs\Zilt`、开始菜单项创建、卸载后目录与快捷方式清理干净，
      共用层 `%LOCALAPPDATA%\Programs` 保留（RemoveFolder 只删空目录）
      同时修掉原 `.wxs` 的三处真实缺陷：快捷方式 `Target` 拼错（`[ZiltPrograms]/…`）、
      per-user 的文件 KeyPath（ICE38）、user profile 目录未清理（ICE64）
      —— 现支持 per-user / per-machine 两种 scope（`ZILT_INSTALLER_PER_MACHINE=1`）
- [x] **MSIX**：`msix.zig`（AppxManifest 生成 / ICO → PNG 帧提取 / 四段版本规范化，
      8 条单测）+ `tools/msix_tool.zig`（makeappx 定位 + staging 组织）。
      `ZILT_PACK_TARGET=msix zig build pack` 产出 `dist/*.msix`（1011 KB）
      **实测**：makeappx pack exit 0；松散注册 `Add-AppxPackage -Register` 成功
      （`app.zilt.desktop 0.1.16.0`）→ 卸载干净；签名后 `Type=Authenticode`、时间戳 OK
      **两条硬约束**（都是实测踩出来的）：`Identity/@Publisher` 必须与证书 Subject
      逐字一致；`Identity/@Version` 必须四段式（`0.1.16` → `0.1.16.0`，
      预发布标签 `1.2.3-beta.4` 的 `.4` 不是第四段，必须整段丢弃）
      ⚠ **签名安装未验证**：MSIX 要求证书链终止于 `LocalMachine\Root`，
      而 AppX 部署服务以 SYSTEM 身份校验（CurrentUser 下的根证书它看不到），
      导入本机根证书需要管理员 —— 当前会话非管理员，故止步于「打包 + 签名 + 松散注册」
      仍支持：**Fixed WebView2**（`Config.environment.browser_directory`，
      loader 走 fixed 模式且不回落 Evergreen —— 代码已接线，缺专项 E2E）
- [x] **代码签名接入（已实测）**：`codesign.zig` 构造 signtool 命令（PFX/指纹/base64 PFX
      三选一、RFC3161 时间戳、/fd /td 一致、路径引号、指纹规范化）；
      **凭据来源对齐上游**：`ZILT_SIGN_PFX`（路径）/ `ZILT_SIGN_PFX_BASE64`（CI secret，
      解到临时 pfx 签完即删，容忍折行/缺 padding/PEM 头尾）/ `ZILT_SIGN_THUMBPRINT`（证书存储）
      + `ZILT_SIGN_PASSWORD` / `ZILT_SIGN_TIMESTAMP`
      **工具发现**：PATH → 注册表 `KitsRoot10`（SDK 可装在任意盘，本机在 E 盘）→
      `App Certification Kit` → `ProgramFiles(x86)` 兜底；只接受以数字开头的版本目录
      （`bin\` 下混有 x64/x86/arm64，字典序最大的是 x86，会漏掉真正的最新版）
      **实测**：自签名证书 → `sign` 退出 0 → `Get-AuthenticodeSignature` 报
      `SignatureType=Authenticode`、signer 正确、`sha256RSA`、
      时间戳为 `DigiCert SHA256 RSA4096 Timestamp Responder 2026 1`（RFC3161 生效）；
      `Status=UnknownError` 仅因自签名根不受信（换 CA 证书即 `Valid`）
- [x] **更新器增强**：通道（stable/beta，`Config.update.channel`；beta 客户端同时接受
      stable 清单，未知通道一律拒绝）+ 崩溃回滚（restart helper 观察 3 秒，非 0 退出即用
      `.zilt-old` 回滚并重拉）+ 健康确认（启动 10 秒后才清理备份，`WM_TIMER` id=3）
- [x] **验收**：exe 属性 Zilt / 0.1.16、manifest 含 PerMonitorV2；
      MSI 安装/卸载往返 exit 0 且清理干净；签名产物 Authenticode + RFC3161 时间戳；
      setup.exe 814KB / 824KB；通道矩阵与回滚文件语义有单测；
      健康确认实测 `health timer armed (10s)` → `health confirmed, backup cleaned`；
      `zilt doctor` 报告 signtool（`bin\10.0.26100.0\x64`）与 WiX 3.14 缓存路径

### v0.1.16 — 插件 / 服务架构、官方周边 API 与多 WebView（P2）

- [x] **插件 / 服务模型**：`Config.services` 声明 → 框架按序 `init/start`、逆序 `deinit`，
      并暴露 `window.zilt.services.list/status/start/stop`。
      **实测**：`[services] 1 registered, 1 started`；冒烟断言 list 含 `demo`
      （scope=`demo:read`, started=true）、status('nope') 返回 null。
      设计边界：框架不解释 `state`、不代理方法调用 —— 需要方法级桥接请用 `commands`
      （对齐 Wails service 的「显式绑定」思路，而不是把任意指针暴露给前端）
- [x] **官方周边 API**（已接 JS，可冒烟验证）：
      `store`（KV + 落盘 `%LOCALAPPDATA%\<app_id>\store.json`）、
      `fs`（scope 内读写，拒绝 `..`/绝对路径/盘符/UNC/NUL）、
      `path`（join/dirname/basename/extname/normalize）、
      `log`（前端日志汇入 Zig 日志）、
      `opener`（openUrl/openPath/reveal，复用 shell）、
      `windowState`（get 当前几何 / save 立即持久化）、
      以及既有的 `system`/`shell`/`autostart`/`appearance`
- [x] **`http`**（v0.1.16，**异步**）：`window.zilt.http.request({url, method, headers, body})`
      → `{status, body}`。实现方式：后台线程执行 → `PostMessage` 回 UI 线程 →
      `httpResponse` 事件 → JS 侧 Promise resolve/reject。
      **为什么不做成同步**：IPC 在窗口消息循环里同步处理，同步 HTTP 会让窗口在慢请求下
      冻结数秒，体验等同卡死。
      **实测**：`https://example.com` → `status=200 bytes=577`，body 为字符串
      （`bodyType=string`，内容为真实 HTML）；`http://127.0.0.1:1/` → `err=ConnectionRefused`
      且错误完整穿过线程→消息→事件→Promise reject。
      `on()` 现返回取消函数（一次性请求必须能摘监听，否则会累积）。
      ⚠ `timeout_ms` 目前只是透传，**未强制生效**（std.http.Client.fetch 无超时参数）；
      要真正超时需额外看门狗线程，留待后续
- [x] **websocket**（v0.1.16 补完）：`window.zilt.ws.connect/send/close/on`。
      协议层 `ws.zig`（握手 + 帧编解码纯逻辑 14 单测）；backend 后台线程握手 + 读循环
      （`WM_ZILT_WS` 事件回传，ping 自动 pong，close 回声，EOF→close 1006）。
      wss 明确报 `UnsupportedScheme`（TLS 未接线，不静默降级）。
      **实测**：echo 服务端对照（scripts/ws_echo.py）——错误路径 `ws://127.0.0.1:1/` →
      ConnectionRefused→error 事件；全链路 connect→open→welcome（服务端主动推）→
      echo→close 1000→conn released。**关键坑**：Zig 0.17 `readSliceShort` 填不满
      buffer 会永久阻塞，帧读取必须 `takeByte`。
      sql / upload / process / os 仍未实现
- [x] **多 WebView**（v0.1.16 补完）：`window.zilt.webviews.create/remove/navigate/
      setBounds/focus/list`。WebView2 每 HWND 只能绑一个 controller → 附加 webview
      各建 WS_CHILD 子窗口；IPC 回复按 sender 路由（子 webview 的 invoke 回到子页面）；
      就绪前 navigate 排队；窗口销毁时释放全部子 webview。
      **实测**：created→ready→navigate(hr=0x0)→removed；就绪前销毁触发官方定义的
      E_ABORT 中止路径（父窗口销毁中止创建），无崩溃。
      **数据分区（v0.1.17 完成）**：`create({partition:'name'})` → 独立 Environment +
      `<profile>\WebView2-partitions\<name>` user data folder；同名分区复用；
      `webviews.eval(id, script)`（异步事件回传，见下）
- [x] **验收**：冒烟 32 项含 store/fs/path/log/windowState + http + ws + webviews +
      **partition 隔离**（alpha/beta localStorage 互不可见、共享实例与主页面互通）

### v0.1.24 — 每窗口 UA + 应用自定义协议（2026-11-12）

> 差距表里最后两项「小改动、高价值」的 Windows 能力。

- [x] **每窗口 UA**：`window.create({ userAgent })` → 该窗口独立 UA
  （`ICoreWebView2Settings2::put_UserAgent`，在 `attach` 前写入 `wv_opts.settings`）。
  另有运行时 `webview.setUserAgent(ua)`（空串恢复默认）。
  **语义坑**：`put_UserAgent` 只对**下一次导航**生效——当前文档的子资源请求仍用旧 UA，
  所以冒烟必须开新窗口验证（`ua-probe.html` + `BroadcastChannel` 回传服务端看到的 UA）。
- [x] **应用自定义协议**：`Config.protocols` 注册 `{ name, handle }`，请求
  `https://<origin>/__proto/<name>/<rest>?<query>` 交给处理函数，返回
  `{status, content_type, body, headers, owned}`；框架负责写回
  `CreateWebResourceResponse`（并叠加全局 CSP/`security.headers`）。
  限制（已在 protocol.zig 顶部写明）：WebView2 的 `WebResourceRequested` 拿不到请求体，
  POST body 不可读；**真 scheme**（`media://`）需 `ICoreWebView2EnvironmentOptions4`
  的 17 槽 vtable + `ICoreWebView2CustomSchemeRegistration`，列为后续项。
- [x] **验收**：单测 +3（协议路由/注册表/处理器分配）；冒烟 **49 项** exit 0
  （c-proto：文本 + 自定义头 + JSON/201 + 二进制 4 字节；c-ua：新窗口 UA 出现在请求头）
- [ ] **未做**：真自定义 scheme（Options4）、浏览器扩展加载、InPrivate（见 v0.2 规划）

### v0.1.23 — 全量审查 + 六项收尾（2026-11-12）

> 先做全仓审查（死代码 / 冗余 / 缺陷），再补上 Tauri/Wails 差距表里「能做且值得做」的六项。

**审查修复**

- **WinHTTP 请求头长度单位**（真实越界读）：`dwHeadersLength` 以 **WCHAR 数**计，
  原代码传 UTF-8 字节数——非 ASCII 头值（如 `X-Note: 测试`）会让 WinHTTP 读过缓冲区末尾。
  request/openWebSocket 两处都改为按转换后的 `[:0]u16` 长度传。
- **超时看门狗位置**：原先放在 `SendRequest` **之后**，而 SendRequest 会阻塞到收到响应头，
  于是「TCP 已连上但服务器永不响应」卡死（v0.1.20 记录的已知限制）。改为在 SendRequest
  之前启动看门狗，超时由 `WinHttpCloseHandle` 取消挂起 I/O → 返回 `error.Timeout`。
- **wss 句柄泄漏**：`WebSocketCompleteUpgrade` 成功后若 `alloc.create` 失败，新句柄未释放；
  补 `errdefer CloseHandle`。
- **fs 路径加固**：拒绝路径中任意位置的 `:`（NTFS 备用数据流 `a.txt:hidden` / 设备名）。
- **版本号单一来源**：运行时/MCP/CLI 统一读 `src/zilt/version.zig`，`build.zig` 顶部用
  `comptime` 断言它与 `project.zig`（PE 资源/打包）一致——漏改一处直接编译失败。
- **死代码清理**：`menu_runtime` 的 buildMenuBar/applyDefault/refreshMenuBar/labelFor
  （v0.1.18 换 `menu.zig::buildWin32WithIcons` 后的遗留）+ `Ctx.root`/`default_id`、
  `accel.menuSuffix`、`menu_model.isSubmenu`、`sysinfo.applyWindowDpi`、`winhttp.describe`。
- **重复实现合并**：`pack/diff_patch/sign_update` 三份 `getEnv` → `src/tools/win_env.zig`。

**六项能力**

- [x] **CDP 逃生口**：`window.zilt.webview.cdp(method, params)` → Promise。
  `ICoreWebView2::CallDevToolsProtocolMethod` + 自建
  `ICoreWebView2CallDevToolsProtocolMethodCompletedHandler`
  （IID `{5C4889F0-…}`），结果经 `webviewCdp {rid, ok, result}` 事件回传；
  CDP 是异步的，请求本身立即返回 `{}`，避免嵌套消息循环等待。
- [x] **截图**：`webview.captureScreenshot({format, quality})` → `data:image/png;base64,…`
  （`Page.captureScreenshot`，实测 45 万字符 PNG data URL）。
- [x] **每请求头**：`webview.setExtraHeaders({...})` = `Network.enable` +
  `Network.setExtraHTTPHeaders`（作用于页面所有 HTTP 请求，区别于 `security.headers`
  的资产响应头）。踩坑：JS 侧字段名必须是 `params_json`（std.json 不做 camel→snake）。
- [x] **页内查找**：`webview.find(text, {matchCase, backwards, wrap})` → bool。
  Chromium 无公开的匹配计数 API，用 `window.find` 做定位（与 Ctrl+F 语义一致，不产生高亮）。
- [x] **每窗口代理**：`window.create({proxy})`。WebView2 代理是 Environment 级 →
  该窗口用独立 Environment + 独立 profile（`<profile>\WebView2-windows\<id>`，
  cookie/缓存不与主窗口共享）；崩溃恢复复用同一 Environment。
  实测日志：`[proxy] window #3 environment ready`。
- [x] **覆盖式标题栏**：`Config.titlebar_overlay` / `window.create({titlebarOverlay})`。
  `WS_POPUP|WS_THICKFRAME`（无 `WS_CAPTION`）+ `WM_NCCALCSIZE` 返回 0（客户区=整窗）
  + 自绘 `WM_NCHITTEST` 8px 缩放边；拖动复用运行时已有的
  `data-zilt-drag-region` → `startDragging`。实测 `innerW/H == outerW/H`。
- [x] **capability JSON DSL**：`ZILT_CAP_FROM=<capabilities.json> ZILT_CAP_OUT=<out.zig>
  zig build capabilities` 把 JSON 反向生成 `security.Options` Zig 字面量
  （`src/tools/capability_codegen.zig`，转义/缺省/非法枚举都有单测）；
  生成物用 `zig build-obj -fno-emit-bin` 做过类型校验。

**验收**

- 单测全通过（+6：ipc 版本行拼接、version semver、win_env、capability_codegen ×3）
- GUI 冒烟 **47 项** ALL PASSED，exit 0（新增 c-cdp / c-shot / c-hdrs / c-find / c-proxy / c-overlay）
- `ZILT_SMOKE_OVERLAY=1` 二次冒烟：c-overlay 真实断言通过（客户区=整窗），exit 0
- 版本 0.1.23（`window.zilt.version` / MCP serverInfo / `zilt version` 同源）

### v0.1.22 — 数据与监视收尾（P1，2026-11-11）

- [x] **fs.watch**：`fs.watch(path, {scope, recursive})` → id，变更经 `fsEvent`
      （action = added/removed/modified/renamed_old/renamed_new + 相对路径）；
      `fs.unwatch(id)` 停止。实现：`CreateFileW(FILE_LIST_DIRECTORY)` +
      `ReadDirectoryChangesW` 阻塞循环（16KB 缓冲，解析 FILE_NOTIFY_INFORMATION 链）
      · 实测坑：同步 ReadDirectoryChangesW 只 `CloseHandle` 不会解除阻塞（unwatch 卡死）
        → 必须 `CancelIoEx` 再关句柄，线程才能退出
- [x] **fs 流式读**：`fs.readStream(path, {scope, chunkSize})` → id，分块经 `fsChunk`
      （base64，seq 递增，最后 done=true）；默认 64KB，夹在 4KB–1MB
- [x] **SQL 迁移**：`sql.migrate(db, version, statements)` —— BEGIN → 逐条执行 →
      `PRAGMA user_version = version` → COMMIT；任一步失败整体 ROLLBACK
      （headless E2E：v1 迁移成功、版本/数据可查；故意坏 SQL 回滚后版本与建表都不生效）
- [x] **冒烟**：41 项 exit 0（c-fs2：watch 捕获 added + readStream 11007 字节 / 3 分块还原一致）
- [ ] **未做（明确记录，非“已完成”）**：
      · DPAPI 加密库（需要 CryptProtectData 接线；当前 SQL 库是明文文件）
      · 每窗口 UA / 代理 / InPrivate / 浏览器扩展（需 ICoreWebView2Settings2 与
        ControllerOptions，未接线）
      · 用户自定义协议注册（asset_routes 尚未开放给应用回调）
      · `with_webview` 原生句柄暴露（安全面大，需独立设计）

### v0.1.21 — 安全模型补齐（P0，2026-11-11）

> 目标：把 scope 从「只有 fs 用」扩到 shell/http，并支持运行时授权持久化。

- [x] **scope 全覆盖**：`fs`（原有）+ **`http`**（含 ws/wss URL）+ **`shell`**（argv[0]
      basename，去 .exe）三处执行点统一走 `aclAllowed`；越权返回 PermissionDenied
- [x] **运行时授权 `window.zilt.acl`**：`grant(kind, pattern)` / `revoke` / `list`；
      授权落盘到 `<appData>cl.json`，**重启后仍生效**（启动加载，跨进程 E2E 验证）
- [x] **合并判定**：`security.scopeAllowedWith(options, extra_grants, kind, resource)`——
      编译期 capability scopes 与运行时授权取并集；opt-in 语义保持（两者都没有 → 放行）
- [x] **原型冻结**：`security.freeze_prototype` → 运行前注入标记，runtime 建好
      `window.zilt` 后冻结自身 + Object/Array/Function/String/Number 原型
- [x] **示例配置**：demo capability 声明 fs/http/shell scopes（进入强制模式），
      http/ws 仅放行 127.0.0.1，shell 仅 cmd
- [x] **实测修复两个 bug**：`initStorage` 会随窗口创建多次调用 → `loadAclGrants` 加
      `acl_loaded` 守卫（此前授权被重复加载）；`revoke` 只删第一个匹配 → 改为删除全部
- [x] **单测**：231（+1：运行时授权与编译期 scope 的并集/opt-in 交互）
- [x] **冒烟**：40 项 exit 0（c-acl2：documents 拒绝 → 授权 → 读写 → 撤销 → 再拒绝；
      跨进程预置 downloads 授权被加载并撤销；https 未授权拒绝；原型冻结断言）
- [ ] **未做（明确记录）**：Tauri 的 **isolation pattern**（独立 iframe 沙箱页 + 消息
      校验脚本）未实现——现有的 `security.isolation` 只是「远程页面不得访问 IPC」。
      iframe 代理会改变所有 invoke/event 的链路，风险与工作量都大，留作独立版本。

### v0.1.20 — 网络层换 WinHTTP（P0，2026-11-11）

> 目标：一次补掉网络维度 4 个差异点（wss / 代理 / 流式 / 上传）。
> 实现方式：动态加载 winhttp.dll（同 sqlite/WebView2 模式），不改 build.zig 链接。

- [x] **WinHTTP 客户端**（`platform/windows/winhttp.zig`）：会话→连接→请求→读数据全链路；
      15 个导出函数动态解析；错误码映射为稳定名（Timeout/CannotConnect/SecureFailure…）
- [x] **https + 代理**：显式 `proxy` 走 NAMED_PROXY；默认跟随系统代理；
      **loopback 自动 NO_PROXY**（系统代理会把 127.0.0.1 代理掉，实测无法连接）
- [x] **重定向策略**：`followRedirects:false` → `WINHTTP_OPTION_DISABLE_FEATURE`
      （`WINHTTP_OPTION_REDIRECT_POLICY` 设了不生效，实测后改用前者）
- [x] **忽略证书**：`insecureTls`（IGNORE_UNKNOWN_CA/CN/DATE），仅用于自签测试环境
- [x] **multipart 上传**：`http.request({multipart:[{name,data,filename,contentType}]})`
      → 自动 boundary + Content-Type + 编码（`net.buildMultipart`，含引号转义）
- [x] **流式下载**：`http.stream(opts, onChunk)` → 后台 `WinHttpReadData` 分块 →
      `httpChunk` 事件（base64）→ JS 端 Uint8Array 累积 + 逐块回调
- [x] **wss（TLS）**：`ws.connect(url, {insecureTls, proxy})` —— wss 走
      `WinHttpWebSocketCompleteUpgrade`（Schannel/代理全免费），ws:// 保留自研帧层；
      `wsEvent.message` 新增 `binary` 标记（binary 时 data 为 base64）
- [x] **Zig 侧订阅内置事件**：`emitEventPayload` 同时 `ipc.dispatchEvent(config.events)`，
      应用可用 `pub fn windowMoved(ctx, payload) void` 直接收到框架事件
- [x] **测试基建**：`scripts/http_echo.py`（echo/chunked 流/302/multipart/慢响应）、
      `scripts/ws_echo.py` 支持 `ZILT_WS_TLS=1` + 自签证书（openssl 生成）
- [x] **单测**：230（+5：URL 解析 3 组、multipart、base64）
- [x] **冒烟**：39 项 exit 0（c-http2 multipart/302/流式 32B；c-wss TLS echo；c-zigev）
- [ ] **已知限制（实测记录）**：WinHTTP 的「等响应头」超时未生效——
      `WinHttpSetTimeouts` + `WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT` + 看门狗关句柄
      三条路径都试过，服务端只建连不发头时仍等到响应（3s+）；connect 超时正常。
      wss 的 close 帧可能晚 3s+ 到达（对端 close 握手时序），已放宽断言并在文档标注。

### v0.1.19 — 结构性能力补齐（P1，2026-11-10）

> 目标：补「权限 scope / 流式 IPC / fs 标准库 / 更新器 API / 初始化脚本」，
> 并加 MCP 服务端。**9 项完成，2 项明确未做**（见末尾）。

- [x] **fs 全量 + 多根目录**：`window.zilt.fs` 从 4 个操作扩到 12 个——
      read/write/append/exists/remove/mkdir/removeDir/readDir/stat/rename/copy/roots；
      scope 11 个：appData/appConfig/appCache/home/desktop/documents/downloads/
      pictures/videos/temp/exe（对齐 Tauri BaseDirectory 的 Windows 子集）；
      读写上限 32MB，写/复制自动建父目录，removeDir 递归删树
- [x] **capability scope 层**：`Capability.scopes = ["fs:documents/**", "shell:git",
      "http:https://api.example.com/*"]`；`security.scopesDeclared` / `scopeAllowed`
      + glob（`*` 不跨段、`**` 跨段、`?` 单字符）与尾部 `*` 前缀语义。
      **opt-in**：未声明 scopes 时保持 v0.1.16 行为（仅应用私有目录）
- [x] **流式通道 `window.zilt.channel`**：`create({onmessage,onclose})` → `{id,close}`；
      Zig 侧 `ctx.channelSend(id, seq, data)` / `channelSendText` / `channelClose(id, err)`；
      分片按 seq 有序、close 可带错误。**已知限制：仍走事件管道，没有背压**
- [x] **更新器 JS API**：`updater.info()`（configured / manifest_url / current_version /
      channel / restart_required，后者由 `<exe>.zilt-old` 是否存在判定）与
      `updater.check()`（复用后台 updaterFlow，结果走 updateInfo/updaterStaged 事件）
- [x] **自定义初始化脚本**：`Config.init_scripts`（document-start 注入，runtime 之后，
      可直接用 `window.zilt`），对齐 Tauri `initialization_script`
- [x] **MCP 服务端（headless）**：`POST /mcp` JSON-RPC 2.0——initialize / ping /
      tools/list / tools/call；tools 由 `ipc.commandMetas` **comptime 生成**（含
      inputSchema：properties/required/类型映射）；GET /mcp 返回工具数。
      实测：32 tools、greet 调用返回真实结果、未知工具 isError
- [x] **单测**：225 全过（+5：scope opt-in/匹配、glob 边界、fs 资源串、MCP schema）
- [x] **冒烟**：36 项 exit 0（新增 c-fs 12 操作 + 越权拒绝、c-channel 5 分片有序、
      c-init 初始化脚本 + updater.info）
- [x] **版本** 0.1.18 → 0.1.19；README/ARCHITECTURE 同步
- [ ] **未做（明确记录）**：`wss`（需 WinHTTP WebSocket 或 Schannel，当前仅 ws://）、
      HTTP 流式/上传/代理、Tauri isolation pattern、InPrivate/浏览器扩展、
      每窗口 UA/代理（需 Settings2 绑定）

### v0.1.18 — Windows 窗口层对齐 Tauri（P0，2026-11-10）

> 目标：把「窗口层差 ~15 个 Win32 小 API」补齐到与 Tauri 2 同级。
> 全部实现并实测；GUI 冒烟 32 → **33 项**。

- [x] **光标**：`window.setCursor(kind)`（14 种：arrow/ibeam/hand/wait/crosshair/
      not-allowed/size-ns|ew|nwse|nesw/move/up-arrow）、`setCursorVisible`、
      `setCursorGrab`（SetCapture）、`setCursorPosition`；`WM_SETCURSOR` 按窗口生效
- [x] **鼠标穿透**：`setIgnoreCursorEvents`（WS_EX_LAYERED|WS_EX_TRANSPARENT +
      alpha=255 防全透明，实测坑）
- [x] **截屏保护**：`setContentProtected`（SetWindowDisplayAffinity WDA_EXCLUDEFROMCAPTURE）
- [x] **阴影**：`setShadow`（DwmExtendFrameIntoClientArea 负 margin）
- [x] **层序/焦点**：`setAlwaysOnBottom`（WM_WINDOWPOSCHANGING 强制 HWND_BOTTOM）、
      `setFocusable`（WS_EX_NOACTIVATE）、`setEnabled`（EnableWindow）
- [x] **标题栏配色**：`setTheme({dark, captionColor, textColor, borderColor})`
      （DWMWA_CAPTION_COLOR/TEXT_COLOR/BORDER_COLOR，Win11 生效）
- [x] **运行时图标**：`setIcon(path)` / `setIcon(null)` 恢复默认（WM_SETICON + 旧图标释放）
- [x] **菜单加速键真正生效**：由菜单 `accel` 生成 ACCEL 表（CreateAcceleratorTableW），
      消息循环 TranslateAcceleratorW 分发 → WM_COMMAND（此前只显示 `\tCtrl+K` 文本）
- [x] **菜单角色 + 图标**：`role` = undo/redo/cut/copy/paste/delete/select_all
      （原生编辑控件走 WM_*，页面走 execCommand；paste 走「原生读剪贴板 + insertText」）；
      `icon` = .ico/.bmp 经 GetIconInfo → SetMenuItemBitmaps，随窗口/菜单销毁释放
- [x] **托盘 hover**：`trayHover {phase: enter|move|leave, x, y}`（TrackMouseEvent + WM_MOUSELEAVE）
- [x] **尺寸约束/多屏**：`setMinMax({minWidth…})` 运行时生效（0 = 清除）；
      `fullscreenOnMonitor(index)` 按 EnumDisplayMonitors 顺序；普通全屏改为当前显示器
- [x] **窗口状态查询**：`window.state()` → {x,y,width,height,style,ex_style,enabled,
      visible,focused,zoomed,iconic,fullscreen,always_on_top/bottom,ignore_cursor,
      focusable,content_protected,min/max,child_webviews}（供调试与自动化断言）
- [x] **单测**：+4（光标名解析 / RGB→COLORREF / 角色反查 / ACCEL 表过滤）；框架 **220**
- [x] **验收**：冒烟 33 项 exit 0（新增 c-wincontrol 实测 12 个操作与 state 回读一致性）；
      示例应用菜单加「编辑」角色子菜单

### v0.1.17 — 工具链、测试与生态（P2）

> 状态（2026-11-09 收尾）：CLI / 图标 CLI / headless / 热重启 / npm 运行时包 /
> create-zilt-app / SQL / 模板扩充 / WebDriver / CI / **多 WebView 数据分区**
> **全部完成并实测**。

- [x] **CLI `zilt`**：`version` / `doctor`（Zig、WebView2（含 WOW6432Node）、makensis、
      frontend dist、图标）/ `info`（project 配置摘要）；`zig build doctor|info` 快捷 step
      （dev/build/config 子命令包装未做，仍直接用 zig build）
- [x] **后端热重启 dev**（2026-11-08）：`ZILT_DEV_WATCH=1 zig build dev`——dev 工具
      spawn `zig build --watch`（重建/错误输出在控制台），自盯 `src/**.zig` mtime
      （递归 FindFirstFileW 扫描），变更→**先杀应用解锁 exe**→等 install 覆盖→重新拉起。
      实测：改 src/main.zig → `restart #1` → `rebuild finished -> relaunching`。
      两个实测踩坑：① FILETIME 在 C 是 4 字节对齐两连 DWORD，Zig u64 字段插 padding 读错位；
      ② dev 原跑 .zig-cache 内 hash 目录副本，重建后路径漂移——改跑 zig-out/bin 稳定产物
      （build.zig addArtifactArg → addArg）。**日志轮转**：`log.initFileLog` 启动时按
      4MB 阈值轮转（zilt.log → .1 → .2 → .3，MoveFileExW REPLACE_EXISTING），
      实测 5MB 日志 → zilt.log.1(5MB) + 新 zilt.log；单测覆盖 rotatedName
- [x] **npm 运行时包 + 独立脚手架**（2026-11-08）：`zilt npm-pack [-o npm] [--name --version]` →
      生成 `@zilt/runtime` 包（package.json / index.js（内嵌 runtime 源）/
      index.d.ts（window.zilt 全接口 TS 声明）/ README.md）；纯逻辑 `npm_pack.zig` 3 单测；
      实测 Node require 加载 index.js 成功（runtime 源 14414 字节）。
      **create-zilt-app**：`zilt new <dir> -t <tmpl>`（Native 脚手架，与 `zig build init`
      共用 `init.zig::scaffold`；自动定位框架根：ZILT_ROOT → exe 的 ../../）+ 
      `npm/create-zilt-app`（npm 包：优先调 zilt CLI，回退 `zig build init`）。
      实测：空格路径外任意 cwd 下 `node index.js /tmp/x -t preact` 成功产出可编译项目
- [x] **图标生成 CLI**（2026-11-08，P0 阶段完成）：`zilt icon <in.png> [-o out.ico]
      [--sizes …]`——纯 Zig PNG 解码（zlib inflate + 5 行滤波 + RGB/RGBA/palette）
      + nearest 缩放 + ICO 编码（BMP 条目双高度 + AND mask）；png.zig/ico.zig 单测；
      实测 CreateIconFromResourceEx 返回真实 HICON。icns/PNG 面未做（Windows 够用）
- [x] **Server / headless 模式**（2026-11-08）：`ZILT_HEADLESS=1`（端口
      `ZILT_HEADLESS_PORT`，默认 8790，仅绑 127.0.0.1）——跳过窗口/COM，
      HTTP 服务：GET `/zilt/health`·`/zilt/info`、POST `/zilt/ipc`（与前端 invoke
      同一 dispatch 链路）、GET `/*` 资产（asset_routes 候选 + gzip 惰性解压）；
      services 生命周期同 GUI。实测四路端点全通（greet 命令返回真结果）
- [x] **SQL（P1 增补，超出原规划）**（2026-11-08）：`window.zilt.sql.query/execute`——
      sqlite3.dll 动态加载（对齐 WebView2 loader 模式：ZILT_SQLITE_PATH → exe 目录 →
      默认搜索 → **winsqlite3.dll**（Windows 10/11 自带，实测 19/19 符号齐全，开箱可用）），
      prepare/step/bind v2 API 表，行集 JSON 序列化；`sql.zig` 纯逻辑 2 单测。
      **真 E2E 已跑通**（headless + `POST /zilt/ipc` 调 `__zilt.sql`）：建表 → 四类型参数插入
      → 自动 id → 全表查询 → 带参数过滤，全部返回预期 JSON。
      实现中修掉两个真 bug：① `allocSentinel` 只分配不拷贝（SQL 字符串是未初始化内存，
      prepare 报 near "ªªª…"）；② std.json 无法还原 void 载荷的 tagged union
      （`"nul"`/`{"nul":null}` 都失败）→ SqlValue 改为 `{kind, text, int, real}` 结构，
      JS 侧直接传原生值（number/string/null 自动映射）
- [x] **模板扩充**（2026-11-08）：新增 **htmx**（无构建；htmx.min.js 离线内嵌 +
      `/data/items.json` 经资产服务真实请求）/ **solid**（Vite + vite-plugin-solid）/
      **preact**（Vite + @preact/preset-vite）/ **angular**（19 standalone +
      @angular/build application builder，dist=frontend/dist/browser）。
      模板面 4 → 8。顺带修复两处既有缺陷：① `copyTree(frontend, …, false)` 不做占位符
      替换（`{{APP_NAME}}` 原样留在页面）；② 占位符全局变量从未赋值（所有模板都产出
      "My Zilt App"/"app.myziltapp"）——现按项目名派生显示名/应用 id/zon name，2 单测。
      实测：htmx 与 preact 模板 `zilt new` 产出后 `zig build` 成功并运行
- [x] **UI 自动化测试（WebDriver）**（2026-11-08）：`zilt-driver`（新 exe）——msedgedriver
      W3C 协议直驱 WebView2：spawn 应用（注入 `ZILT_WEBVIEW2_ARGS=--remote-debugging-port`，
      backend 新增该 env 覆盖）→ spawn msedgedriver → POST /session（
      `ms:edgeOptions.debuggerAddress`）→ `/execute/sync` 逐条断言 → DELETE /session。
      自研极简 HTTP 客户端（按 Content-Length 读体；**读到 EOF 会挂住**——msedgedriver
      忽略 Connection: close，实测踩到）。默认 4 条断言（runtime/invoke/dom/title）+
      `--script` 自定义。无驱动时 SKIP 退出码 3（区别于真失败 1）。
      **实测**：下载 Edge 157 对应 msedgedriver → 4/4 passed，exit 0；`zig build e2e` 已接入
- [x] **CI / 签名流水线**（2026-11-08）：`.github/workflows/ci.yml` 三段式——
      test（构建/单测/冒烟 31 项/WebDriver 可选）→ package（NSIS+zip 上传 artifact）
      → release（tag 触发：signtool 签名 + GitHub Release）；Edge 版本自动匹配驱动下载、
      失败降级 SKIP 不静默。文档 `docs/CI.md`（secrets、退出码、本地等价命令）
- [~] **验收**：改 Zig 自动重启 ✅；`zilt doctor/info/icon/npm-pack/new` ✅；
      headless 服务可访问 ✅；WebDriver 跑通示例 ✅（4/4）；CI 模板 ✅（本地无法执行 Actions，
      结构与命令按本地等价命令逐条验证）

#### v0.1.15 / v0.1.16 / v0.1.17 实施记录（2026-11-08）

**v0.1.15（打包链路）**：新增 `src/tools/win_res.zig`（VERSIONINFO + manifest 生成，
7 条单测）；`build.zig` 改为构建期生成 rc + manifest，并把 manifest 哈希写进 rc 注释——
否则 resinator 不把 include 的 manifest 当依赖，改 manifest 后仍命中旧缓存（实测踩到，
exe 内嵌的仍是旧 XML）。NSIS 生成器参数化：`per_machine` / `license_path` / `setup_icon` /
`schemes` / `file_exts`，新增协议与文件关联的安装/卸载片段与升级检测（4 条新单测）。
`bundle.zig` 支持 `ZILT_INSTALLER_PER_MACHINE|LICENSE|ICON|SCHEME|EXT` 环境变量。

**实测**：`zig build bundle` → setup.exe 814KB；带 per-machine + license + scheme + ext →
824KB，两次 makensis 均 exit 0。exe 属性 `CompanyName=Zilt / ProductVersion=0.1.16`，
manifest 含 `PerMonitorV2` 与 `longPathAware`。
**踩坑（重要）**：manifest 的 `<assemblyIdentity>` 必须带 `version`，否则运行时报
`side-by-side configuration is incorrect`，exe 完全无法启动（bash 表现为 Permission denied）；
单测发现不了，只有真实启动才暴露。

**v0.1.16（周边 API）**：`store` / `fs` 经 `system_api` 统一通道接到后端；
存储根 `%LOCALAPPDATA%\<app_id>`，落盘 `store.json`（Win32 `readFileAlloc`/`writeFileAlloc`）；
fs 走 `fs_api.joinChecked` 做 scope 内路径校验。JS 新增 `window.zilt.store.*` / `fs.*`。

**v0.1.17（CLI）**：`src/tools/cli.zig` → `zig-out/bin/zilt.exe`，含 `doctor` / `info` / `version`；
`zig build doctor` / `zig build info` 两个 step。doctor 实测输出：
`Zig 0.17.1` / `WebView2 runtime 157.0.4341.42` / `makensis: D://Scoop//shims//makensis.exe` /
`frontend dist: frontend` / `app icon: builtin Zig logo` → exit 0。
**踩坑**：WebView2 版本在 32 位安装器写入 `WOW6432Node`，64 位进程读
`HKLM\SOFTWARE` 不会自动重定向，必须显式尝试两条路径。

**（2026-11-08 补完）v0.1.15 剩余项**：`codesign.zig`（7 条单测）+ bundle 自动签名；
更新器通道 + restart helper 崩溃回滚 + 10 秒健康确认（实测日志两阶段）；
`zilt doctor` 增加 signtool/WiX 检测。MSI 仍无法构建（本机无 WiX），已如实标注。

**（2026-11-08 补完）v0.1.16 周边 API**：新增 `path` / `log` / `opener` / `windowState`
（`store`/`fs` 上轮已接）；冒烟增至 26 项并通过。

**（2026-11-08 晚）MSI 与真实代码签名落地**：

- **WiX vendor**：新建 `wix_vendor.zig`（纯逻辑，11 条单测：候选目录优先级 / SHA256
  大小写不敏感比对 / 体积合理性窗口 / stamp 内容）+ `tools/wix_tool.zig`（下载、校验、
  解压、candle+light、退出码）。缓存 `%LOCALAPPDATA%\zilt\WixTools`，
  标记文件 `.zilt-wix-ok` 避免每次重校验 40 MB。
- **下载源核实**：`wix3142rtm` 是 404（网络上大量文档写错），正确 tag 是 `wix3141rtm`；
  实测 41,297,555 字节，SHA256 `6ac824e1…`，与 Scoop manifest 一致。
- **解压用系统 tar.exe** 而非自研 unzip：Windows 10 1803+ 自带 libarchive 支持 zip，
  少一处易错的二进制解析；失败时打印 tar 退出码。
- **修掉 `.wxs` 的三处真实缺陷**（都是 light 的 ICE 校验发现的，之前从未真正构建过 MSI）：
  `ICE38` per-user 时文件不能当 KeyPath → 改 HKCU 注册表值；
  `ICE64` user profile 目录未在卸载表 → 加 `RemoveFolder`；
  快捷方式 `Target` 拼成 `[ZiltPrograms]/ZiltPrograms/Zilt`（目录 ID 重复 + 用应用名
  当文件名）→ 改 `[#ExeFile]`。
  另修 `Guid="*"` 在「文件 + 注册表 keypath」组件上非法（`CNDL0230`）→ 改稳定派生 GUID。
- **占位符顺序陷阱（第二次踩）**：`@ROOT_BLOCK@` 插入的片段自身含 `@EXE_SRC@` 等占位符，
  若排在后面展开就会逃过替换，candle 把字面量 `@EXE_SRC@` 当文件路径去打开。
  与 bundler 里 `${UNINST_ROOT}` 那次同一类问题，现已把分支块放第一位展开。
- **签名工具发现**：本机 SDK 装在 **E 盘**，`ProgramFiles(x86)\Windows Kits\10\bin\*\x64`
  直接返回 null，曾误报「signtool not found」。改为读注册表
  `KitsRoot10` → `bin\<最高版本>\x64` → `App Certification Kit` → 默认盘兜底，
  并只接受以数字开头的版本目录（`bin\` 下 x64/x86/arm64 的字典序会误导）。
- **签名时机 bug**：`signArtifacts` 原在 makensis 之前调用，那时 setup.exe 还没生成，
  必然 exit 1。已移到 makensis 成功之后，并对每个文件做存在性检查。
- **凭据**：新增 `ZILT_SIGN_PFX_BASE64`（对齐 Tauri 的 `WINDOWS_CERTIFICATE`），
  解码容忍折行 / 缺 padding / PEM 头尾，写临时 pfx 签完即删；
  `pickSource` 优先级 pfx 路径 > base64 > 指纹，5 条单测。
- **实测证据**：`[sign] … -> exit 0` ×2；`Get-AuthenticodeSignature` 报
  `Type=Authenticode`、`Signer=CN=Zilt CI Signing`、`sha256RSA`、时间戳 OK；
  MSI `install exit=0 → exe 落地 → uninstall exit=0 → 目录与快捷方式清理`；
  `zig build test` 205/205；GUI 冒烟 26 项 ALL CHECKS PASSED。
- **一处如实说明**：base64 凭据的**完整**签名往返没能跑完 —— 命令行里出现明文密码
  被环境安全策略拦截（不重试、不绕过）。已用两条独立证据替代：
  (a) `decodePfxBase64` 单测覆盖折行/缺 padding/PEM 头尾；
  (b) 传无效 base64 时日志出现 `[sign] decoded base64 PFX to temp file`，
  随后 signtool 确实收到该文件并因内容无效返回 1 —— 链路（解码→写临时文件→传参）打通。

**仍未完成**：多 WebView（需重构 backend 单 webview 假设：多 controller 布局、消息来源区分、
销毁时序——属重构级改动，建议单独一轮并配 WebDriver 回归）、MSIX、http/websocket/sql/
upload/process、npm 脚手架、图标生成 CLI、模板扩充、WebDriver、headless、CI 模板。

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
