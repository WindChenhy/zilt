# Zilt

基于系统 WebView 的跨平台 GUI 框架（对标 Tauri 2 / Wails v3），框架本体用 **Zig** 实现。

- 前端：任意 Web 技术（HTML/CSS/JS/框架）
- 后端：Zig 核心（窗口、IPC、资产服务、绑定 codegen、dev 工具链）
- WebView：系统自带引擎（Windows: WebView2 / macOS: WKWebView / Linux: WebKitGTK），不自研浏览器引擎

**当前状态：v0.1.16（Windows 全栈 + 前端工程化 + 多窗口/持久化/隔离 + WebView2 事件面/Settings/环境 + capability ACL + 托盘/菜单/快捷键/任务栏 + 系统信息/主题/Shell/自启 + PE VERSIONINFO/manifest + 安装器增强（per-machine/License/协议与文件关联）+ store/fs/path/log/opener/windowState 周边 API + 更新器通道/崩溃回滚/健康确认 + 代码签名（签名产物已实测 Authenticode + RFC3161）+ MSI（WiX 3.14 自动 vendor，安装/卸载实测）+ MSIX（makeappx，松散注册实测）+ services 生命周期 + http（异步）+ websocket 客户端 + 单窗口多 WebView + `zilt` CLI）**。逐版本功能项与验收记录见 [docs/ROADMAP.md](docs/ROADMAP.md)。

v0.1.13–v0.1.16 新增（2026-11-08，均已实现、验证并提交）：

- **v0.1.13**：系统能力统一通道（`system_api.Request` 单次 marshal）——托盘 tooltip/图标/点击行为、运行时菜单增删改查与程序化弹出、全局快捷键、任务栏进度/覆盖图标/闪烁
- **v0.1.14**：`window.zilt.system`（OS/显示器信息）、`shell`（openUrl/openPath/reveal）、`autostart`（注册表自启 + 冲突报告）、`appearance`（暗色标题栏/Mica 背景材质）、管理员重启
- **v0.1.15**：PE VERSIONINFO + manifest（PerMonitorV2/longPathAware）、安装器增强（per-machine/License/URL 协议与文件关联/升级检测）、MSI（WiX 3.14.1 自动 vendor + SHA256 校验 + 安装/卸载往返实测）、MSIX（AppxManifest 生成 + ICO→PNG 帧提取 + makeappx + 松散注册实测）、代码签名（signtool 自动定位 + RFC3161 时间戳，签名产物 Get-AuthenticodeSignature 实测）、更新器通道 + restart helper 崩溃回滚 + 健康确认
- **v0.1.16**：`services`（声明式服务注册表，init/start 逆序 deinit，状态暴露给 JS）、`http`（后台线程异步，错误穿透全链路实测）、`websocket`（协议层手写 RFC6455 必需子集 + 后台线程握手/读循环 + echo 服务端对照实测，wss 明确报错不静默降级）、**单窗口多 WebView**（附加子 webview：WS_CHILD 子窗口 + 独立 controller + IPC 按 sender 路由，created→ready→navigate→remove 全链路实测）、`path`/`log`/`opener`/`windowState`、`zilt` CLI（doctor/info/version）
- **验收**：单元测试 226/226（框架核心 209 + 工具链 17）；GUI 冒烟 **30 项** `ALL CHECKS PASSED`（exit 0，含 http/ws/webviews 全链路检查）；Release 构建冒烟同过；NSIS 升级安装覆盖 + 卸载干净实测；MSI/MSIX 重打成功

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

GUI 冒烟测试（30 项前端检查 + Zig 侧 `smokeResult` 断言，日志 `ALL CHECKS PASSED` 且 exit 0）：

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
