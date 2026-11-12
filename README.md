# Zilt

基于系统 WebView 的跨平台 GUI 框架（对标 Tauri 2 / Wails v3），框架本体用 **Zig** 实现。

- 前端：任意 Web 技术（HTML/CSS/JS/框架）
- 后端：Zig 核心（窗口、IPC、资产服务、绑定 codegen、dev 工具链）
- WebView：系统自带引擎（Windows: WebView2 / macOS: WKWebView / Linux: WebKitGTK），不自研浏览器引擎

**当前状态：v0.1.22（Windows 全栈 + 前端工程化 + 多窗口/持久化/隔离 + WebView2 事件面/Settings/环境 + capability ACL + 托盘/菜单/快捷键/任务栏 + 系统信息/主题/Shell/自启 + PE VERSIONINFO/manifest + 安装器增强（per-machine/License/协议与文件关联）+ store/fs/path/log/opener/windowState 周边 API + 更新器通道/崩溃回滚/健康确认 + 代码签名（签名产物已实测 Authenticode + RFC3161）+ MSI（WiX 3.14 自动 vendor，安装/卸载实测）+ MSIX（makeappx，松散注册实测）+ services 生命周期 + http（异步）+ websocket 客户端 + 单窗口多 WebView + 前端对话框/子进程/图标生成 CLI + SQL（SQLite 动态加载）+ headless/server 模式 + 热重启 dev + npm 运行时包/脚手架 + SQL + 多 WebView 数据分区 + 窗口精细控制/菜单角色与加速键/托盘 hover + fs 全量/scope ACL/channel/MCP + WinHTTP（https/wss/代理/流式/multipart）+ scope 全覆盖/运行时授权/原型冻结 + fs.watch/流式读/SQL 迁移 + 8 套模板 + WebDriver 自动化 + CI 流水线 + `zilt` CLI）**。逐版本功能项与验收记录见 [docs/ROADMAP.md](docs/ROADMAP.md)。

v0.1.13–v0.1.16 新增（2026-11-08，均已实现、验证并提交）：

- **v0.1.13**：系统能力统一通道（`system_api.Request` 单次 marshal）——托盘 tooltip/图标/点击行为、运行时菜单增删改查与程序化弹出、全局快捷键、任务栏进度/覆盖图标/闪烁
- **v0.1.14**：`window.zilt.system`（OS/显示器信息）、`shell`（openUrl/openPath/reveal）、`autostart`（注册表自启 + 冲突报告）、`appearance`（暗色标题栏/Mica 背景材质）、管理员重启
- **v0.1.15**：PE VERSIONINFO + manifest（PerMonitorV2/longPathAware）、安装器增强（per-machine/License/URL 协议与文件关联/升级检测）、MSI（WiX 3.14.1 自动 vendor + SHA256 校验 + 安装/卸载往返实测）、MSIX（AppxManifest 生成 + ICO→PNG 帧提取 + makeappx + 松散注册实测）、代码签名（signtool 自动定位 + RFC3161 时间戳，签名产物 Get-AuthenticodeSignature 实测）、更新器通道 + restart helper 崩溃回滚 + 健康确认
- **v0.1.16**：`services`（声明式服务注册表，init/start 逆序 deinit，状态暴露给 JS）、`http`（后台线程异步，错误穿透全链路实测）、`websocket`（协议层手写 RFC6455 必需子集 + 后台线程握手/读循环 + echo 服务端对照实测，wss 明确报错不静默降级）、**单窗口多 WebView**（附加子 webview：WS_CHILD 子窗口 + 独立 controller + IPC 按 sender 路由，created→ready→navigate→remove 全链路实测）、`path`/`log`/`opener`/`windowState`、`zilt` CLI（doctor/info/version）
- **验收**：单元测试 226/226（框架核心 209 + 工具链 17）；GUI 冒烟 **30 项** `ALL CHECKS PASSED`（exit 0，含 http/ws/webviews 全链路检查）；Release 构建冒烟同过；NSIS 升级安装覆盖 + 卸载干净实测；MSI/MSIX 重打成功

v0.1.17 新增（2026-11-08，均已实现、验证并提交）：

- **P0 补齐**（对齐 Wails3/Tauri2 差距）：`window.zilt.dialog`（messageBox/openFile/saveFile/pickFolder/pickFiles，UI 线程模态）、`window.zilt.process`（spawn/kill/list，stdout/stderr/exit 走事件流，kill=TerminateProcess，应用退出强杀残留）、`zilt icon`（PNG→多尺寸 .ico，纯 Zig PNG 解码 + ICO 编码，CreateIconFromResourceEx 实测返回真实 HICON）
- **SQL**：`window.zilt.sql.query/execute`——sqlite3.dll 运行时动态加载（ZILT_SQLITE_PATH → exe 目录 → **winsqlite3.dll**，Windows 10/11 自带开箱可用），行集 JSON 序列化，参数直接传原生值（number/string/null 自动映射）；headless 下 `POST /zilt/ipc` 调 `__zilt.sql` 完成真 E2E（建表/四类型插入/自动 id/参数过滤）
- **headless/server 模式**：`ZILT_HEADLESS=1` 跳过窗口/COM 跑 HTTP 服务（127.0.0.1，默认 8790）——`/zilt/health`、`/zilt/info`、POST `/zilt/ipc`（与前端 invoke 同一 dispatch 链路）、`/*` 资产服务；services 生命周期同 GUI；四路端点实测全通
- **热重启 dev**：`ZILT_DEV_WATCH=1 zig build dev`——spawn `zig build --watch` + 自盯 `src/**.zig` mtime，变更→先杀应用解锁 exe→等 install→重新拉起（实测 restart #1 全链路）；修复 FILETIME 4 字节对齐陷阱与 .zig-cache hash 路径漂移
- **npm 运行时包 + 脚手架**：`zilt npm-pack` 生成 `@zilt/runtime`（Node require 实测）；`zilt new <dir> -t <tmpl>` 与 `npm/create-zilt-app`（优先 zilt CLI，回退 `zig build init`），自动定位框架根
- **模板扩充**：4 → 8 个模板——新增 **htmx**（离线内嵌 htmx.min.js + 资产服务真实请求）、**solid**、**preact**、**angular 19**（standalone + application builder）；顺带修复占位符从未替换/从未赋值两处既有缺陷
- **WebDriver 自动化**：`zilt-driver`（新 exe）走 msedgedriver W3C 协议直驱 WebView2（`ZILT_WEBVIEW2_ARGS` 注入调试端口 + `ms:edgeOptions.debuggerAddress`），默认 4 条断言 + `--script` 自定义，无驱动 SKIP(3)；**实测 4/4 passed**；`zig build e2e` 接入
- **CI / 签名流水线**：`.github/workflows/ci.yml`（test 构建+单测+冒烟+可选 WebDriver → package NSIS+zip → tag 签名发布）+ `docs/CI.md`
- **多 WebView 数据分区**（2026-11-09）：`webviews.create({partition:'login'})` → 独立 WebView2 Environment + 独立 user data folder（`<profile>\WebView2-partitions\<name>`），Cookie/localStorage/IndexedDB 与主页面隔离；同名分区复用同一 Environment；新增 `webviews.eval(id, script)`（异步事件回传，包成 Promise）。**实测**：alpha/beta 分区 localStorage 互不可见、共享实例与主页面互通，两个 user data 目录真实落盘（12M/7.7M）
- **日志轮转**：4MB 阈值，zilt.log → .1 → .2 → .3（实测 5MB 日志轮转）
- **验收**：单元测试 **234/234**（框架 216 + 工具 18）；GUI 冒烟 **32 项** ALL PASSED（exit 0，含数据分区隔离）；WebDriver 4/4；headless 四端点 + SQL 真 E2E；日志轮转实测；`zilt version` 报 0.1.17

v0.1.23 新增（2026-11-12，审查 + 六项收尾）：

- **CDP 逃生口 / 截图 / 每请求头**：`webview.cdp(method, params)`、`captureScreenshot()`（PNG data URL）、`setExtraHeaders({...})`（`Network.setExtraHTTPHeaders`，作用于页面全部请求）
- **页内查找**：`webview.find(text, {matchCase, backwards, wrap})`（`window.find` 语义）
- **每窗口代理**：`window.create({proxy})` → 独立 Environment + 独立 profile（WebView2 代理是环境级选项）
- **覆盖式标题栏**：`Config.titlebar_overlay`，客户区覆盖整窗 + 自绘 8px 缩放边，拖动复用 `data-zilt-drag-region`
- **capability JSON DSL**：`ZILT_CAP_FROM=capabilities.json ZILT_CAP_OUT=src/capabilities.zig zig build capabilities`
- **审查修复**：WinHTTP 头长度单位（越界读）、超时看门狗前置（修掉 v0.1.20 的已知限制）、wss 句柄泄漏、fs 路径拒绝 NTFS ADS、版本号单一来源 + 编译期一致性断言、死代码/重复实现清理
- **验收**：单测 **236**；冒烟 **47 项** exit 0；`ZILT_SMOKE_OVERLAY=1` 二次冒烟通过

v0.1.22 新增（2026-11-11，数据与监视收尾）：

- **fs.watch**：目录监视（`ReadDirectoryChangesW`）→ `fsEvent`（added/removed/modified/renamed_* + 相对路径）；`fs.unwatch` 停止（`CancelIoEx` 解阻塞，实测坑）
- **fs 流式读**：`fs.readStream(path, {chunkSize})` → `fsChunk`（base64 分块 + done），大文件不整块进内存
- **SQL 迁移**：`sql.migrate(db, version, statements)` 事务化 + `PRAGMA user_version`，失败整体回滚（headless E2E 验证）
- **验收**：冒烟 **41 项** exit 0（c-fs2 覆盖 watch + 11KB 流式还原）
- **未做**：DPAPI 加密库、每窗口 UA/代理/InPrivate、自定义协议注册、`with_webview`

v0.1.21 新增（2026-11-11，安全模型补齐）：

- **scope 全覆盖**：fs / **http（含 ws/wss）** / **shell（argv[0]）** 三处执行点统一校验，越权返回 `PermissionDenied`
- **运行时授权 + 持久化**：`acl.grant(kind, pattern)` / `revoke` / `list`，落盘 `<appData>\acl.json`，**重启后仍生效**（跨进程实测）
- **原型冻结**：`security.freezePrototype` 冻结 `window.zilt` 与内建原型（防原型链篡改）
- **验收**：单测 **231**；冒烟 **40 项** exit 0（c-acl2 覆盖拒绝→授权→读写→撤销→再拒绝 + 跨进程持久化 + 冻结）
- **未做**：Tauri isolation pattern（iframe 沙箱代理）——现有 `isolation` 仅表示远程页面禁 IPC

v0.1.20 新增（2026-11-11，网络层换 WinHTTP）：

- **HTTP(S) 全能力**：`http.request` 支持 https、显式/系统代理（loopback 自动绕过）、重定向策略、忽略证书、**multipart 上传**；新增 `http.stream(opts, onChunk)` 流式下载（`httpChunk` 事件，base64 分块 → Uint8Array）
- **wss / TLS**：`ws.connect('wss://…', {insecureTls, proxy})` 走 WinHTTP/Schannel；`ws://` 保留自研帧层；消息新增 `binary` 标记
- **Zig 侧订阅内置事件**：`pub fn windowMoved(ctx, payload) void` 即可在 Zig 收到框架事件（与 `window.zilt.on` 对齐）
- **测试基建**：`scripts/http_echo.py`（echo/流式/302/multipart/慢响应）、`scripts/ws_echo.py --tls`（自签证书）
- **已知限制**：WinHTTP 对「只建连不发响应头」的等待超时未生效（三条路径实测），connect 超时正常
- **验收**：单测 **230**；冒烟 **39 项** exit 0（http2 / wss / zigev 新增）

v0.1.19 新增（2026-11-10，结构性能力补齐）：

- **fs 全量 + 多根目录**：read/write/append/exists/remove/mkdir/removeDir/readDir/stat/rename/copy/roots；scope 11 个（appData/appConfig/appCache/home/desktop/documents/downloads/pictures/videos/temp/exe），非私有目录需 capability `scopes`（如 `"fs:documents/**"`）授权
- **capability scope 层**：`scopes` 声明 + glob 匹配（`*`/`**`/`?`）+ opt-in 语义；fs 走真实授权（越权返回 PermissionDenied，冒烟覆盖）
- **流式通道**：`window.zilt.channel.create({onmessage,onclose})` + Zig `ctx.channelSend/channelClose`（分片有序、可带错误；无背压）
- **更新器 JS API**：`updater.info()`（含 `restart_required`）/ `updater.check()`
- **初始化脚本**：`Config.init_scripts`（document-start，runtime 之后）
- **MCP 服务端**（headless）：`POST /mcp` JSON-RPC——initialize/ping/tools/list/tools/call，tools 与 inputSchema 由 comptime 反射生成（实测 32 tools + greet 调用）
- **验收**：单测 **225/225**；冒烟 **36 项** exit 0（fs/channel/init 新增）

v0.1.18 新增（2026-11-10，Windows 窗口层对齐 Tauri 2）：

- **窗口精细控制**：`window.setCursor/setCursorVisible/setCursorGrab/setCursorPosition`、`setIgnoreCursorEvents`（鼠标穿透）、`setContentProtected`（防截屏）、`setShadow`、`setAlwaysOnBottom`、`setFocusable`、`setEnabled`、`setTheme({dark,captionColor,textColor,borderColor})`、`setIcon(path)`、`setMinMax({minWidth…})`、`fullscreenOnMonitor(index)`、`state()`（状态快照，供调试/断言）
- **菜单**：加速键由「仅显示」升级为真实 ACCEL 表（CreateAcceleratorTableW + TranslateAcceleratorW）；新增预定义角色项（undo/redo/cut/copy/paste/delete/select_all）与菜单图标（.ico/.bmp）
- **托盘**：`trayHover` 事件（enter/move/leave）

v0.1.8–v0.1.12 新增（2026-11-08，均已实现、验证并提交）：

- **v0.1.8**：父子/模态窗口、每窗口独立菜单、窗口状态持久化、`%LOCALAPPDATA%\<app_id>\WebView2` 数据隔离（含旧目录迁移）、SPA 路由回退、CSP/自定义响应头、导航白名单与外部链接策略
- **v0.1.9**：`ctx.eval` / `ctx.evalAsync`（Promise 语义）、导航事件、`NewWindowRequested` 三策略、权限请求、下载管理、渲染进程崩溃自动恢复
- **v0.1.10**：Settings 开关（DevTools release 默认关）、运行时 WebView API（reload/zoom/print/cookies/history/clearStorage…）、环境选项（UA/语言/代理/浏览器参数/运行时通道）
- **v0.1.11**：`window.zilt.window` 全量窗口 API、capability ACL（构建期生成 `capabilities.json`、运行时强制、未授权返回 `PermissionDenied`）、远程内容边界与隔离模式
- **v0.1.12**：剪贴板多格式（文本/图片/HTML/文件）+ 变化监听、OLE `IDropTarget` 拖放（含坐标与自定义格式）+ 文件拖出、Toast 交互（按钮/输入/进度/点击深链/分组/状态查询）
- 前端运行时新增 `window.zilt.eval` / `webview` / `clipboard` / `drag` / `notification`；Zig 侧对应 `zilt.Context` 方法

v0.1.7 新增：

- **窗口模型**：透明 / 无边框 / 置顶 / 隐藏任务栏 / 初始位置与尺寸 / 最小最大尺寸 / 创建时隐藏 / 背景色 / 每窗口图标
- **窗口事件**：moved / resized / focus / blur / themeChanged / scaleFactorChanged / closeRequested / destroyed
- **自定义标题栏**：`data-zilt-drag-region` + `window.zilt.startDragging()`（无边框窗口可拖动）
- **关闭请求**：`close_requested_event` 开启后由前端确认 `windowClose`

v0.1.6 新增：

- **默认 Zig 官方图标**：内置多尺寸 `zilt.ico`（窗口/托盘/exe 资源共用，无需配置）；
  `project.icon` 可自定义 exe 图标，`Config.icon` / `Tray.icon` 可自定义运行时图标
- **多窗口**：`ctx.newWindow(...)`、每窗口独立 IPC/事件路由、`ctx.emitTo(window_id, ...)`、`windowDestroyed` 事件（v0.1.7 由 windowClosed 更名）
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
zig build test    # 单元测试（226/226：协议/更新器/打包器/系统能力/codegen/模板/图标/深链接/Range/窗口模型/安全 ACL/SPA 回退/WebView2 驱动 ABI/剪贴板编解码/OLE 拖放/Toast/能力清单/内置命令/加速键/运行时菜单/任务栏 ABI/系统信息/自启/存储/受限 fs/服务注册表/VERSIONINFO/manifest/NSIS 增强/WiX vendor/MSIX manifest/http 异步/签名凭据/base64 解码/WebSocket 协议）
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

CLI 自检：

```sh
zig build                       # 产出 zig-out/bin/zilt.exe
./zig-out/bin/zilt.exe doctor   # Zig / WebView2 / makensis / dist / 图标 全链路检查
./zig-out/bin/zilt.exe info     # 项目配置摘要
zig build doctor                # 等价快捷 step
```

安装器（per-machine / License / 协议与文件关联 由环境变量控制）：

```sh
zig build bundle
ZILT_INSTALLER_PER_MACHINE=1 ZILT_INSTALLER_LICENSE=LICENSE.txt \
ZILT_INSTALLER_SCHEME=zilt ZILT_INSTALLER_EXT=.zilt zig build bundle
```

MSI（首次构建自动下载并缓存 WiX 3.14.1 到 `%LOCALAPPDATA%\zilt\WixTools`，
带 SHA256 校验；离线环境可预置或用 `ZILT_WIX_TOOLPATH` 指定）：

```sh
ZILT_PACK_TARGET=msi zig build pack                  # per-user → %LOCALAPPDATA%\Programs
ZILT_PACK_TARGET=msi ZILT_INSTALLER_PER_MACHINE=1 zig build pack   # per-machine → Program Files
```

MSIX（用 Windows SDK 自带的 makeappx，无需额外安装；
`Identity/@Publisher` 必须与签名证书 Subject 一致）：

```sh
ZILT_PACK_TARGET=msix zig build pack
ZILT_PACK_TARGET=sign ZILT_PACK_SIGN=dist/Zilt-0.1.16-x64.msix \\
ZILT_SIGN_THUMBPRINT=<指纹> zig build pack
```

代码签名（三种凭据来源，按优先级：路径 > base64 > 指纹）：

```sh
ZILT_SIGN_THUMBPRINT=<指纹> zig build bundle          # 证书已在证书存储
ZILT_SIGN_PFX=cert.pfx ZILT_SIGN_PASSWORD=*** zig build bundle
ZILT_SIGN_PFX_BASE64=<base64> ZILT_SIGN_PASSWORD=*** zig build bundle   # CI secret
```

GUI 冒烟测试（32 项前端检查 + Zig 侧 `smokeResult` 断言，日志 `ALL CHECKS PASSED` 且 exit 0）：

```sh
zig build                            # 生成 frontend/bindings/capabilities.json 并嵌入资产
zig build                            # 内容寻址资产表重算，确保 capability 清单进入 exe
ZILT_SMOKE_TEST_MS=30000 ZILT_SMOKE_EXIT=1 zig-out/bin/zilt-app.exe && echo PASS
ZILT_SMOKE_MULTI=12 ZILT_SMOKE_TEST_MS=12000 zig-out/bin/zilt-app.exe   # 多窗口 E2E（3s 后自动关第二窗）
```

`zig build capabilities` 可单独生成权限清单；`zig build gen` 同时刷新 TS 绑定与清单。
纯交互能力（真实拖入/拖出、Toast 按钮点击、CSP 拦截内联脚本、杀渲染进程）由
`zig build test` 的离线单测与 `notificationInteractiveDemo` / `dragStartDemo` 等命令复现。

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
