# Zilt

基于系统 WebView 的跨平台 GUI 框架（对标 Tauri 2 / Wails v3），框架本体用 **Zig** 实现。

- 前端：任意 Web 技术（HTML/CSS/JS/框架）
- 后端：Zig 核心（窗口、IPC、资产服务、绑定 codegen、dev 工具链）
- WebView：系统自带引擎（Windows: WebView2 / macOS: WKWebView / Linux: WebKitGTK），不自研浏览器引擎

**当前状态：v0.3.19（测试体系收口——41 个从未执行的用例入图 + 4 处真实缺陷修复 + 文档校准）**。
逐版本功能项与验收记录分散在三份文档：[docs/ROADMAP.md](docs/ROADMAP.md)（v0.1.0–v0.1.24）、
[docs/v0.2-LINUX.md](docs/v0.2-LINUX.md)（v0.2.0–v0.3.1）、[docs/v0.3.x-PLAN.md](docs/v0.3.x-PLAN.md)（v0.3.2–v0.3.19）。

| 平台 | 状态 | 技术栈 |
|---|---|---|
| Windows | ✅ 全栈（v0.1.0–v0.3.19） | Win32 + WebView2（纯 Zig 手写 COM 绑定） |
| Linux | ✅ 全栈（v0.2.0–v0.3.19，冒烟 86 项） | GTK3 + WebKit2GTK 4.1；`-Dgtk=gtk4` 构建变体 |
| macOS | ⏳ 未开始（原计划 v0.3+，v0.3 系列未覆盖） | WKWebView（zig-objc 路线） |

Windows 能力面（截至 v0.3.18）：窗口/多窗口/覆盖式标题栏/窗口形状 mask/每按钮状态/失焦与 Escape 隐藏/
窗口级 KeyBindings、WebView2 事件面与 Settings（含 printToPdf、加速键与手势开关）、IPC + 事件 + 流式 channel
（含二进制 FNV-1a32 帧）+ isolation 密封、内嵌资产（gzip/ETag/Range）、capability ACL + scope + 运行时授权、
fs（scope/watch/流式）、SQL、store（可选 DPAPI 加密）、http（WinHTTP：https/wss/代理/multipart/流式/上传进度）、
托盘（含暗色图标）/菜单/快捷键/任务栏（含文本徽标）/通知/剪贴板/拖放/对话框、自启/深链/单实例（HMAC 密封）、
更新器（ed25519 + 差分 + 回滚 + 周期检查）、打包（NSIS/MSI/MSIX/zip/sidecar）、headless + MCP + server 模式
（浏览器 runtime shim）、WebDriver、12 套模板、`zilt` CLI。CompositionController 管线已接通，但受上游 WebView2
运行时限制，默认回退 HWND 渲染（`ZILT_COMP_ENABLE=1` 可启用修复后的真实组合管线验证）。
Linux 复用同一 JS API 面，差异逐版本以「文档化」条目记录（无 SharedBuffer → evaluate 通道、无 PDF 导出 →
`PdfNotSupported` 等）。

## 能力索引（v0.3.18）

| 能力组 | 主要入口 | Windows | Linux |
|---|---|---|---|
| 窗口/多窗口 | `window.create/center/maximize/setResizable/setDecorations/destroy/list/setScreen/startDragging`、`app.quit/restart` | ✅ | ✅ |
| WebView | `eval/reload/zoom/print/cookies/history/find/captureScreenshot/loadHTML/devtools` | ✅ | ✅ |
| WebView 扩展 | `cdp`、`printToPdf` | ✅ | ⚠️ `cdp` 仅 `Page.captureScreenshot`；无 PDF 导出 |
| IPC/事件 | `invoke`/`emit`/`on`、`channel`（二进制帧）、`binary.request` | ✅ | ✅（evaluate 通道） |
| 安全 | capability ACL + scope、运行时授权、isolation HMAC 密封、原型冻结、导航白名单 | ✅ | ✅ |
| 数据 | `store`（DPAPI 可选）、`fs`（scope/watch/流式）、`sql`（sqlite3） | ✅ | ✅ |
| 网络 | `http`（https/代理/multipart/流式/上传进度）、`ws`/`wss` | ✅ | ✅ |
| 系统集成 | 托盘（暗色图标）/菜单/全局与窗口快捷键/任务栏徽标/通知/剪贴板/拖放/对话框 | ✅ | ✅（徽标 Unity-only） |
| 桌面 | 自启/深链/单实例（HMAC）/窗口状态持久化/透明与覆盖式标题栏/窗口效果 | ✅ | ✅ |
| 更新与分发 | ed25519 清单/差分补丁/回滚/skipVersion/GitHub provider；NSIS/MSI/MSIX/zip/deb/AppImage/Flatpak spec | ✅ | ✅（deb/AppImage/Flatpak） |
| 运行模式 | GUI / headless（HTTP + MCP）/ server（浏览器 runtime）/ dev HMR | ✅ | ✅ |
| 工具链 | `zilt` CLI（init/doctor/info/gen/icon/npm-pack/mcp/keygen/sign/diff/pack）、12 套模板、WebDriver | ✅ | ✅ |

> ⚠️ = 平台差异（Linux 侧明确返回 `NotSupported` 或能力受限），逐条记录在各版本「文档化」说明中。
> 组合渲染（CompositionController）为 Windows 专属且默认回退 HWND；Linux 无 SharedBuffer，二进制 IPC 走 evaluate 通道。

## 版本记录

> 版本号唯一来源：`src/zilt/version.zig`（`src/project.zig` 再导出，`build.zig` 编译期断言一致）。
> 发布 tag 仅覆盖 v0.1.0–v0.1.5；其余版本以提交信息中的 `vX.Y.Z` 前缀标识。
> 注：v0.1.x 段落里的「单测 N/N」为当时口径（有的只计框架、有的含工具链），数值不完全可比；
> v0.2 起统一为两平台全量计数，当前口径见「快速开始」。

v0.3.19 新增（2026-11-20，测试体系收口——审计驱动的缺陷修复 + 文档校准）：

- **41 个从未执行的用例入图**：`patch` / `png` / `ico`（跨平台）与 `app_data` / `deep_link` /
  `dialog_ext` / `icon` / `menu_runtime` / `range` / `single_instance` / `tray` / `winhttp`（Windows）
  此前只有 `pub const` 惰性声明，测试从未进入编译图；`tools/driver.zig` 同理。接入后 Windows 侧
  已无「声明但未编译」的用例（剩余 43 个未进二进制的名字均为 Linux-only）
- **修复：差分补丁块对齐（patch）**：COPY 段向后延伸未按 4KiB 块边界收尾，一次块内改动会让
  游标相对块栅格漂移，后续块再也命中不了旧文件索引——200KB 文件改 100 字节生成约 150KB 补丁
  （应约 4KB）。延伸长度改为向下取整到块边界（到 new 末尾除外）
- **修复：PNG 编码路径（png/ico）**：`Compress.init` 需要可写缓冲（`ensureTotalCapacity`，
  断言 `buffer.len > 8`）且 `finish()` 已无参——旧代码在 Zig 0.17 下无法编译，即 `zilt icon`
  的 PNG→ICO 路径实际不可用。测试侧同步修正 PNG 行数据（每行漏一个像素）与 ICO 目录项读数
  偏移（14..16 是 dwBytesInRes，wBitCount 在 12..14）
- **修复：单实例密封（single_instance）**：`SealError` 缺 `OutOfMemory`——配置
  `single_instance_key` 时该分支一旦被分析即编译失败；`openPayload` 用 `split('|')` 解析，
  载荷自身含 `|`（深链 URL 常见）时被截断 → HMAC 永不匹配、跨实例参数一律丢弃。改为定长解析
  （32 hex nonce + 64 hex MAC + 余下即载荷），hex 编码改用 `std.fmt.bytesToHex`
- **新增回归用例**：IDCompositionVisual vtable 槽位（SetContent=15 / AddVisual=16，锁定
  v0.3.18 根因）、SharedBuffer 确定性载荷与字节和（Zig/JS 跨语言契约）、server 帧不置掩码位
  （v0.3.13 真实浏览器 bug）
- **文档校准**：`build.zig.zon` 版本号（0.1.0 → 0.3.19）、README 平台状态/能力面更新到 0.3.19、
  新增「能力索引」与 v0.2.0–v0.2.9 章节、变更日志按版本降序重排、单测与冒烟计数修正、
  快速开始补 Linux 依赖；ROADMAP 标注记录分界；CI 文档冒烟项数（31/75 → 66/86）
- **验收**：Windows `zig build test` **364 项（363 通过 + 1 skip：POSIX 专用）**、`zig build`
  21/21；Linux 平台层本次无改动，沿用 v0.3.18 的冒烟 86/86 记录

v0.3.18 新增（2026-11-20，CompositionController 渲染专项收口——三轮差距刷新第五批）：

- **三项真实缺陷修复（v0.3.12 装配错误，实测驱动）**：
  1. **IDCompositionVisual vtable 槽位修正**——dcomp.h 的 C++ 接口有重载，
     SetOffsetX/Y/Transform/Clip 各占 2 槽，真实槽位 SetContent=15 / AddVisual=16
     （v0.3.12 误记 11/12——AddVisual 调用落到 SetBorderMode 报 E_INVALIDARG，
     实测暴露）；SDK 10.0.26100.0 dcomp.h C++ 声明序逐项重数
  2. **官方双视觉层级**——WebView2APISample BuildDCompTreeUsingVisual 序列落地：
     target.SetRoot(root) + root.AddVisual(webview, TRUE, null) +
     put_RootVisualTarget(webview 子视觉)（v0.3.12 单视觉 + put 根视觉错误）
  3. **put_Bounds + DComp 设备先建**——QI'd Controller put_Bounds（客户端区，
     官方 m_controller->put_Bounds 同形；v0.3.12 从未调用 = 0×0 呈现面）+
     DComp 设备先于 controller 创建（官方 InitializeWebView 序；设备改用
     DCompositionCreateDevice2 动态加载）+ 有序拆除（视觉树先行 → Close）
- **最小复现实验收口**：`ZILT_COMP_BARE=1`（零 driver 交互裸 Navigate）——
  装配全链成功（composition ready + Settings9 hr=0x0）后 Navigate 仍段错误于
  EmbeddedBrowserWebView.dll → **上游运行时缺陷定案**（Runtime 157.0.4341.60 +
  本机 DComp 栈；与 Wails composition hosting 保持 experimental 一致）
- **默认回退 + 验证入口**：默认 HWND 渲染（c-comp 断言回退路径 + state.composition=
  false）；`ZILT_COMP_ENABLE=1` 启用修复后的真实组合管线（未来运行时修复后的
  验证开关——装配正确性修复不依赖该开关）
- **验收**：Windows 冒烟 **66 项**（comp 回退路径 + 其余全过）+ 单测全绿；
  Linux 冒烟 **86/86**（组合为 Windows 面）；装配链在 ZILT_COMP_ENABLE=1 下
  实测 composition ready（新增 cc4 探测/dcomp 序列日志）

v0.3.17 新增（2026-11-20，更新器/分发收尾 + 二进制通道——三轮差距刷新第四批）：

- **更新器字节级下载进度（G23）**：`updateDownloadProgress {written, total}` 事件
  （~10Hz 节流 + 终值补发）——Fetcher 增 `streamFn`（流式下载，64KB 分块 +
  Content-Length 总量）+ `progress` 回调；Windows `httpFetchStreaming`（手动
  request/receiveHead/readSliceShort 短读循环——v0.3.8 的 upload 进度同款节流）；
  Linux updater 保持整体拉取（soup 无进度面，文档化）
- **更新器周期检查（G23）**：`Config.update.check_interval_min`（分钟）——
  Windows SetTimer(id 6) → WM_TIMER 重跑 updaterFlow 后台线程（check → download →
  stage 全链 + 事件）
- **deb/AppDir resources 分发收尾（G24）**：pack Linux 递归收集 exe 旁
  `resources/**`（libc readdir——Io walker 递归句柄 BADF 实测回退；arena 段内
  回收破坏 tar 条目名实测——dir_rel 切片直指 rf.rel 零分配规避）→ deb
  `usr/bin/resources/**`（dir+file tar 条目）+ AppDir/AppImage 同布局；
  **PACK_E2E PASS + deb tar 条目实测**（demo/manifest.json + demo/readme.txt）
- **二进制通道（G25）**：`channel.create({binary: true})`——帧带 **FNV-1a32
  校验和**（JS `Math.imul` 实现——普通乘法 2^53 精度丢失实测修正 + 公开测试向量
  单测）；Zig→JS `ctx.channelSendBinary`（base64 帧 → JS 解回 Uint8Array，验和
  不符 onclose('checksum')）；JS→Zig `ch.send(Uint8Array)` → 事件 channelUp
  （events 命名空间 `channelUp(ctx, {id, seq, data_b64, sum})` 接收，事件通道
  天然经 ACL + isolation 密封）；demo 回显链路 16KB 逐字节比对（c-bchan）
- **验收**：Windows 冒烟 **66 项**（c-bchan 全链过）+ 单测全绿（+FNV 向量/
  往返/非法输入、seal 结构）；Linux 冒烟 **86/86** + PACK_E2E PASS + post
  terminate PASS；clip 既有环境问题

v0.3.16 新增（2026-11-20，托盘/任务栏/屏幕细化 + 单实例加固——三轮差距刷新第三批）：

- **托盘暗色模式图标（G17）**：`tray.setDarkIcon(path)`（null = 恢复亮色同图标，
  Wails SetDarkModeIcon 对齐）——当前为暗色主题立即换发；`windowThemeChanged`
  （WM_SETTINGCHANGE ImmersiveColorSet）时后端自动随主题换发
- **任务栏文本徽标（G18）**：`taskbar.badge(text, {bg, fg})`（1–4 字符；空串清除，
  Wails Dock SetBadge/SetCustomBadge 对齐）——32×32 32bpp DIB 圆形底（Windows 红
  默认）+ GDI 文本（DEFAULT_GUI_FONT + DrawTextW 居中）→ CreateIconIndirect →
  SetOverlayIcon；上一枚 HICON 即时销毁防泄漏。Linux Unity-only → 文档化
- **屏幕细化（G19）**：`system.cursorPosition()`（全局光标屏幕坐标，Win GetCursorPos /
  GTK gdk_device_get_position）+ monitors 增 `rotation`（Win DEVMODE
  dmDisplayOrientation 经 EnumDisplaySettingsW，DEVMODEW 220 字节布局单测锁定；
  GDK3 无旋转 API → 恒 0 文档化）
- **Linux GPU policy（G20）**：`environment.gpu_policy`（always/on_demand/never，
  Wails WebviewGpuPolicy 对齐）——never → WebKit 初始化前 `WEBKIT_DISABLE_COMPOSITING_
  MODE=1`（软件合成）；**auto + NVIDIA 探测**（/proc/driver/nvidia）→ 自动
  `WEBKIT_DISABLE_DMABUF_RENDERER=1`（Wails 同款空白窗修复）；Windows 忽略
- **Linux 全工作区可见（G21）**：`window.setAllWorkspaces(bool)` → gtk_window_stick/
  unstick（Tauri visibleOnAllWorkspaces 对齐）；Windows 无原生对等 → no-op true
- **单实例数据密封（G22）**：`Config.single_instance_key`（64 字符 hex；Wails
  SingleInstanceOptions.EncryptionKey 对齐，复用 isolation 的 HMAC-SHA256 基建）——
  WM_COPYDATA 载荷升级 `zilt1|<nonce>|<hmac>|<payload>` 密封形态，明文/篡改一律拒绝
  （本机任意进程可 SendMessage 伪造启动参数的攻击面收口）；seal/open/篡改/明文/
  非法密钥五组单测
- **验收**：Windows 冒烟 **65 项**（c-sys2：cursorPosition 往返 + rotation 字段 +
  badge/night-tray/all-workspaces op 链）+ 单测全绿（+DEVMODEW 布局、seal/open 五组）；
  Linux 冒烟 **86/86**（curs：cursorPosition + rotation + stick 往返）+ GPU policy
  单测 + post terminate PASS；clip 既有环境问题

v0.3.15 新增（2026-11-20，打印与 WebView 开关面——三轮差距刷新第二批）：

- **printToPdf（G12，Windows 实装）**：`webview.printToPdf(absPath)` → Promise——
  `ICoreWebView2_7::PrintToPdf`（**槽 80 / IID 79c24d83…，官方 SDK 1.0.3124.44
  WebView2.h 逐一核对**；NuGet 提取沿用 v0.3.2 方法；vtable 全表 81 槽 python 解析
  实证）+ `printSettings=null` 引擎默认（A4 纵向）+ PrintToPdfCompletedHandler
  （Invoke(hr, is_successful)）→ `webviewPdf {rid, ok}` 事件回传。**Wails/Tauri 均无
  此 API**（wry#707/1317 未实现）——Zilt 领先项。Linux 无 PDF 导出 API →
  PdfNotSupported 文档化（Linux 冒烟 pdfskip 断言）
- **Settings3/6 开关面（G13/G14）**：`webview.settings.browser_accelerators`（默认开，
  Ctrl+F 等交还页面用 false——Tauri disabled_webview_shortcuts 反向）/ `swipe_gestures`
  （默认关，Wails EnableSwipeGestures 同 opt-in）——Win Settings3/6（槽位与 IID 同上
  核对）+ **settingsProbe 探针**（读→反转→验证→恢复→验证的 ABI 往返，冒烟 c-acc）；
  Linux 手势走 WebKitSettings enable-back-forward-navigation-gestures（创建期），
  加速键/探针 null 文档化
- **OtherSensors 权限类（G27）**：`PermissionKind.other_sensors`（native 5）+
  `permissions.other_sensors` 策略（默认 deny）；Linux ask 询问框文案补齐
- **范围修正**：G15 tabbed backdrop 复核发现 **v0.1.14 已有**（Backdrop.tabbed =
  DWMWA_SYSTEMBACKDROP_TYPE=4，fromName 接受 tabbed/mica-alt）；G16 fluentOverlay
  滚动条在官方 SDK（1.0.3124.44）**无 COM 接口**（grep 无 FluentOverlay）→ 文档化
  移除，不做
- **验收**：Windows 冒烟 **64 项**（c-pdf 真实导出 + fs 存在性/清理；c-acc
  accelerators true→false→true + swipe false→true→false 往返）+ 单测全绿（+printToPdf/
  settingsProbe 映射、settings 默认值）；Linux 冒烟 **85/85**（pdfskip）+ post
  terminate PASS；clip 两项为既有环境问题

v0.3.14 新增（2026-11-20，窗口 API 收尾——三轮差距刷新第一批）：

> 三轮差距刷新基线 git 98214f0；对标 Wails v3.1.0 + Tauri 2.12.5（WindowConfig 62 字段 +
> Window 方法 86 个逐项比对）。三轮总表与 v0.3.14–v0.3.18 切片见 v0.3.x-PLAN §0.5。

- **窗口 API 收尾（G1–G8/G11，双平台同接）**：`window.center()`（工作区居中）、
  `window.create({maximized})`（创建即最大化）、运行时 `setResizable`/`setDecorations`
  （Win style 位 / GTK 原生属性；state() 增 resizable/decorated 直读）、`destroy`（强制
  销毁——Win DestroyWindow / GTK widget_destroy，绕过关闭请求链）、`toggleMaximize`、
  `setScreen(index)`（移窗到指定显示器工作区）、`window.list()`（全部存活窗口状态数组，
  Wails GetAll 对齐）、`window.create({zoom})`（初始缩放，controller 就绪后应用）
- **应用级 quit/restart（G5）**：`window.zilt.app.quit(code)` / `app.restart()`——
  Wails application.Quit / Tauri App::exit 对齐；restart 复用 executablePathAlloc 解析
  （与 sidecar/resource 同模式）spawn 自身后正常 quit
- **Zig 侧可取消事件钩子（G6，C4）**：事件命名空间把 `windowCloseRequested` 声明为返回
  `bool` 即启用——true = 取消关闭（对齐 Wails `e.Cancel()` / Tauri `prevent_close()`）；
  comptime 门控（未启用零开销），启用时关闭链路先决、emitEventPayload 跳过重复派发
- **webview 面收尾（G9/G10）**：`webview.loadHTML(html)`（Win NavigateToString /
  GTK load_html，base_uri=应用 origin）+ devtools open/close/state 三态（Win 打开状态
  内部跟踪、无关闭 API 文档化；GTK inspector 全支持）
- **Linux 补齐**：windowDestroyed 事件（此前 GTK 销毁不发事件——对齐 Windows 契约，
  发给其余存活窗口）+ 缩放快捷键 polyfill（G26——WebKitGTK 无 IsZoomControlEnabled
  对等；Ctrl/Cmd ±/0 → zoom，Tauri 同手法，runtime 后注入）
- **验收**：Windows 冒烟 **62 项**（新增 c-win3——探针窗口全量往返：maximized/center/
  resizable/decorations/toggleMaximize×2/setScreen/list/destroy；**appquit 流**——全部
  通过后经 window.zilt.app.quit(0) 正常退出，app.quit 由此获得 E2E 覆盖，quit 失败 →
  冒烟安全网 exit 124）+ 单测全绿（+closeRequestHooked/cancelled 语义、窗口收尾动作
  映射、devtools/loadHTML 映射）；Linux 冒烟 **84/84**（新增 win3 GTK 路径全量往返 +
  windowDestroyed 事件）+ post terminate PASS；clip 两项为既有桌面剪贴板占用环境问题

v0.3.13 新增（2026-11-19，server 模式二阶段——二轮差距刷新收口）：

- **浏览器端 runtime shim（F1b）**：headless 服务新增 `/zilt/runtime.js`（runtime JS
  原样服务）+ **HTML 响应注入**（`<head>` 后注入 `__ZILT_SERVER__` 标记 +
  runtime.js 引用——先于应用脚本执行）；runtime 传输层三态：无 chrome/webkit
  transport 且页面为 http(s) → **WebSocket transport**（`/zilt/ws`；post 就绪前
  排队，onopen flush；入站帧 → deliver）。app 页面**零改动**在真实浏览器经
  server 模式获得完整 window.zilt 面（invoke/emit/on + 全部内建）
- **服务端帧编码修正（RFC 6455）**：ws.zig 增 `encodeFrameServer`（**无掩码**）——
  v0.3.7 的服务端帧复用客户端掩码编码，python E2E 兼容处理掩盖了问题，真实浏览器
  对掩码服务端帧按协议错误关闭连接（Edge 实测驱动修正）；headless 会话全部改用
- **会话生命周期修正**：demo 页 ticker 等后台线程持有 ctx.backend（会话指针）跨
  会话生命周期 emit——页面 WS 关闭 → unregister 释放会话 → 迟到的 emit 解引用
  已 unmap 内存段错误（实测）。修复：unregister 的 pending 清理持 s.lock（与
  enqueue/drain 并发）+ **会话墓地**（上限 16 槽，不销毁——迟到 emit 安全广播/丢弃）
- **浏览器 E2E（scripts/server_browser_e2e.py）**：Edge headless + CDP
  Runtime.evaluate——HTML 注入断言 + runtime.js shim 断言 + **经浏览器 shim 的
  greet/add WS 往返**（window.zilt.invoke → WS → dispatch → resolve）
- **验收**：Windows 冒烟 **61 项 exit 0**（全套回归）；browser E2E ALL PASSED +
  python WS E2E（两次）ALL PASSED + health OK；Linux 单测全绿 + 冒烟 83/83 +
  dev-headless（HEALTH/MCP_STDIO/HEADLESS_E2E=PASS）

v0.3.12 新增（2026-11-19，CompositionController 专项——二轮差距刷新第五批）：

- **CompositionController 管线（A11，Windows）**：官方 WebView2.h 逐一核对的 ABI 绑定——
  `Environment10::CreateCoreWebView2CompositionControllerWithOptions`（slot 22；**修正
  v0.3.2 误记的 4 参签名为官方 3 参**——E_POINTER 实测驱动）+
  `ICoreWebView2CompositionController`（RootVisualTarget/SendMouseInput/SendPointerInput/
  Cursor，11 槽）+ CC2 AutomationProvider + CC3 Drag* + **CC4 NonClientRegion**
  （GetNonClientRegionAtPoint/QueryNonClientRegion/Changed 订阅，16–19 槽）+
  **Settings9::IsNonClientRegionSupportEnabled**（flat 38）+ **DComp 绑定**
  （dcomp.dll：Device Commit(3)/CreateTargetForHwnd(6)/CreateVisual(7)、Target SetRoot(3)、
  Visual SetContent(11)/AddVisual(12)，IIDs 取自 DECLARE_INTERFACE_IID_ 段）
- **组合窗口链路**：`window.create({composition: true})` → Environment10 探测 →
  CC 创建（CompositionControllerCompletedHandler）→ DComp 视觉树装配 → Settings9
  非客户区支持 → **QI 实测**：组合对象实现 ICoreWebView2Controller（非 ICoreWebView2
  直取——QI 探针实证）→ webview 经 controller.getCoreWebView2()；鼠标输入转发
  （WM_* → SendMouseInput，kind/虚拟键映射）+ WM_NCHITTEST → CC4 原生 hit-test
  （app-region: drag → HTCAPTION/按钮位）+ state().composition + 窗口销毁的有序拆除
- **已知问题（渲染管线）**：CC 创建/DComp 装配/Settings9 全部成功后，页面导航阶段
  WebView2 渲染管线段错误（EmbeddedBrowserWebView.dll 内部；about:blank 复现；
  putIsVisible 前置、有序拆除 SetRoot(null)+Commit+Close 均不缓解——诊断笔记
  ROADMAP v0.3.12）。**本版组合选项按降级文化走 HWND 渲染**（窗口存活/IPC 全正常），
  渲染修复列为后续专项；c-comp 检查断言回退路径
- **验收**：Windows 单测全绿 + 冒烟 **61 项**（新增 c-comp 断言组合请求 → 探测 →
  回退全链 + state.composition=false）；Linux 不涉及（组合为 Windows 面）

v0.3.11 新增（2026-11-18，分发收尾——二轮差距刷新第四批）：

- **external_bin sidecar（E1b）**：`project.external_bin`（约定
  `bin/<name>-<triple>[.exe]`，triple 由构建 target 推导）——build install 落 exe 旁
  （缺失静默跳过）、NSIS `{SIDECAR_INSTALL}`（File /oname= 同名安装）、deb
  `extra_files`（usr/bin 同目录）、AppDir usr/bin；运行时
  `__zilt.path {action:'sidecar'}`（防穿越 + Windows .exe 后缀）——c-sidecar 检查
- **fixed 运行时 E2E（E2）**：`ZILT_WEBVIEW2_BROWSER_DIR` 覆盖钩子（E2E/debug 用）+
  `scripts/e2e_fixed_runtime.ps1`——缺失 fixed 目录 → 启动失败 **不回退 Evergreen**
  （stderr 含 WebView2RuntimeNotFound）；正向路径支持 `ZILT_E2E_FIXED_RT` 真运行时冒烟
- **交叉编译 pack（E4）**：pack 工具保持 HOST 目标（交叉时打包 TARGET 的 exe——
  工具跟随 query 会产出跑不起来的交叉工具，实测修正）；矩阵：deb/AppDir/AppImage
  打包随 target 交叉，NSIS/MSI/MSIX 声明仅 Windows 目标；**已知限制**：aarch64 交叉
  止于 GTK 链接（需目标 sysroot 库——GUI 交叉的通用前提，Tauri/Wails 同要求）
- **TS 模板变体（F2）**：vue-ts / react-ts / svelte-ts / preact-ts——overlay 机制
  （基础模板 vendored 框架复用 + `templates/<variant>/` 仅 TS 专属文件：src/*.ts(x)、
  tsconfig、package.json 加 typecheck 步骤）；**E2E 实测**：vue-ts init → gen →
  `vue-tsc --noEmit && vite build` 类型检查构建 ✓ → exe 运行资产 200
- **验收**：Windows 单测全绿 + 冒烟 **60 项**（新增 c-sidecar；仅 clip 桌面剪贴板
  占用环境问题）+ e2e_fixed_runtime PASS；Linux 单测全绿 + 冒烟 **83/83** +
  post terminate PASS

v0.3.10 新增（2026-11-18，安全专项——二轮差距刷新第三批）：

- **isolation pattern（C2，对齐 Tauri isolation 防伪造语义）**：`Config.isolation = .{ .key_hex }`
  （32 字节 hex）——invoke 经**随机 origin 隔离 iframe**（`ziltiso://<session-random>/`，
  独立 scheme + decide-policy 放行）的签名服务：主页面 postMessage → 持钥 iframe →
  **纯 JS HMAC-SHA256**（无 WebCrypto——`crypto.subtle` 在自定义 scheme iframe 不保证
  secure context，实测驱动选型）→ `{n, s}` sealed 形态 → Zig 侧验签 + **nonce 防重放**
  （512 槽环形缓存）→ 分发；**明文 invoke 一律拒绝**（`IsolationRequired` +
  `__zilt.isoRejected` 事件；伪造/篡改 `IsoTampered`）。**签名用规范化 JSON**
  （对象键排序递归——`jsc_value_to_json` 不保留键序的实测发现，跨引擎签名唯一可靠基础；
  页侧 canon 与 Zig canonicalize 同构，undefined 属性丢弃对齐结构化克隆语义）。
  **node 跨实现 E2E**：真实生成的 iframe 页脚本在 node mock 环境执行（ready ping →
  seal → 签名与 node crypto HMAC 逐字一致 + 篡改敏感）。**密封链路即全套冒烟链路**
  ——Windows 59 项 / Linux 83 项全部检查经密封 IPC 完成 = 最强 E2E
- **Wayland portal 全局快捷键（D1，对齐 Wails portal 后端）**：Wayland 会话
  （WAYLAND_DISPLAY 有值且 GDK_BACKEND≠x11——WSLg 同时设两者，显式 x11 排除）的
  hotkey op 改走 `org.freedesktop.portal.GlobalShortcuts`（CreateSession →
  BindShortcuts 整表重绑 → Activated → hotkey 事件，GVariant 文本构造经
  g_variant_parse）；X11/CI 保持 XGrabKey 分支逐字不变。会话判定 / portal 触发器
  格式（`Ctrl+Alt+N`→`<Control><Alt>n`）/ BindShortcuts 文本构造 全部单测；
  真 Wayland 会话端到端待桌面环境手动验证（对齐 v0.2.5 模式）
- **验收**：Windows 单测全绿（+isolation seal/verify/重放/规范化/canonicalize 键序）
  + 冒烟 **59 项 exit 0**（新增 c-iso 明文伪造必拒断言）；Linux 单测全绿
  （+portal 会话判定/触发器/BindShortcuts 文本/matchKeyBinding）+ 冒烟 **83/83**
  + post terminate PASS

v0.3.9 新增（2026-11-18，窗口效果与键盘对称——二轮差距刷新第二批）：

- **效果参数（A12，Windows）**：`appearance.apply({ tint, cornerPreference })`——tint 走
  `SetWindowCompositionAttribute`（user32 动态加载，ACCENT_ENABLE_ACRYLICBLURBEHIND +
  GradientColor 0xAABBGGRR，Tauri windowEffects 同款；`"RRGGBB"`/`"AARRGGBB"` 解析，缺省
  alpha 0xCC）+ Win11 圆角偏好 `DWMWA_WINDOW_CORNER_PREFERENCE`（default/donotround/
  round/smallround）；radius 文档化 macOS-only；Linux 无 accent API → NotSupported 文档化
- **Linux 窗口级 KeyBindings（A4L）**：`window.create({keyBindings})` → 创建时解析
  keyval/mods（keyvalForGtk 大写键位）→ key-press-event 匹配（matchKeyBinding：
  keyval 大小写归一 + 只比较四个语义修饰符位，忽略 numlock 等 lock 位）→
  `windowKeyBinding {id, windowId}` 事件（与 Windows 逐字一致）；菜单 accel 由 GTK
  accel group 先行消费（优先级与 Windows 一致）
- **验收**：Windows 冒烟 58 项（c-appearance 扩展 tint/corner 实测应用 + c-exp2 增
  keyBindings 创建）+ 单测全绿（+theme tint/corner 解析）；Linux 冒烟 **82/82**
  （新增 keybind——探针走创建解析→匹配→事件派发全链，匹配函数单测锁定大小写/
  掩码语义）+ post terminate PASS；**实测记录**：X 层按键注入（XSendEvent 与
  XTestFakeKeyEvent）在 Xvfb+WebKitGTK 下稳定段错（环境限制），与 v0.3.3 Escape
  同测试深度——真实按键路径由单测保证

v0.3.8 新增（2026-11-18，IPC 与协议收尾——二轮差距刷新第一批）：

- **协议 POST body（B8）**：`Request.body` 携带请求体——Windows 经
  `ICoreWebView2WebResourceRequest::get_Content`（IStream 同步读，10MB 上限；WebView2
  对带 body 的请求不回传 Content-Length 头但 body 可读，Wails PR#6326 同款核实），
  Linux 经 `webkit_uri_scheme_request_get_http_body`；解除 v0.1.24 的「body 不可读」限制。
  **实测文档化**：WebKitGTK 不转发自定义 scheme 请求 body（上游已知限制
  littledivy/laufey#98，2.50.4 实测仅 1 字节垃圾）——Zig 侧读取已接线，上游修复自动生效；
  Windows 的自定义 scheme fetch/XHR 同样不发出请求（Chromium 的 fetch scheme 白名单），
  导航类请求（iframe/表单 POST）全链可达
- **Linux 二进制 IPC（C1L）**：`binary.request` 在 Linux 走 evaluate base64 通道
  （WebKitGTK 无 SharedBuffer 对等）——载荷经 evaluateJavaScript 注入
  `window.__ziltSharedBufferArrived`，事件契约与 Windows SharedBuffer 逐字一致；
  Linux 冒烟 binipc 从平台 skip 转为真实断言（16KB checksum match）
- **绑定参数名保留（C3）**：TS 绑定升级为命名形参——`greet(name: string)` 而非
  `greet(args: {...})`（无参数命令 `ping()`；可选/默认值字段合法时带 `?:`）；
  jsonName 映射同步生效；非法标识符/必填跟在可选后回退对象形态（单测锁定边界）
- **http 上传进度（E6）**：`http.upload({url, parts, onProgress})`（强制 POST multipart）→
  `httpUploadProgress {id, written, total}` 事件——Windows `WinHttpWriteData` 分块
  （~10Hz 节流，真字节进度）；Linux 粗粒度两帧（libsoup3 无字节级上传进度 API，文档化）；
  分片 `encoding: 'base64'` 承载二进制
- **验收**：Windows 单测全绿（+bindings 命名参数/net base64/protocol body 契约），
  冒烟 **58 项**（新增 c-postbody/c-upload；仅 clip/clipmulti 桌面剪贴板占用环境问题）；
  Linux 单测全绿，冒烟 **81/81**（新增 binipc 真 check/postbody skip/upload）+ post terminate；
  server E2E ALL PASSED；`zig build gen` 产出命名参数签名

v0.3.7 新增（2026-11-17，server 模式——对齐 Wails application_server/BrowserWindow）：

- **server 模式 WS 会话**：headless HTTP 服务扩容 `/zilt/ws` 升级端点——每个浏览器
  连接一个会话（server 窗口 id 空间 0x100000+，与原生窗口隔离），invoke 走与
  POST /zilt/ipc 同一 dispatch 链路（builtin 优先 + 应用命令），响应/事件按会话
  独立回帧；broadcast 事件投递所有会话（Wails BrowserWindow 语义）
- **accept 循环线程化**：每连接一线程（WS 会话的阻塞帧读不再阻塞 accept 与其他
  连接；HTTP 短连接与长会话并存）——comptime config 经 spawn 参数剥离传入线程；
  常规 headless 四端点回归 PASS
- **E2E**：`scripts/server_mode_e2e.py`（python 原生 WS 客户端：握手 accept 校验 +
  greet/add 往返 + **双会话独立路由**）——Windows 手动 ALL PASSED + Linux CI
  （dev-headless.sh 接入 SERVER_E2E=PASS）
- **验收**：Windows/Linux 单测全绿；Linux 冒烟 79/79 + headless/server E2E 全 PASS
- **范围说明**：浏览器端 runtime 传输 shim（页面经 WS 桥接 window.zilt）列为
  server 模式二阶段——协议层已被 python E2E 完整覆盖（该脚本即协议实现）

v0.3.6 新增（2026-11-17，二进制 IPC）：

- **SharedBuffer 二进制通道（Zig→JS，Windows）**：`window.zilt.binary.request(size)` →
  Promise<{size,sum,match}>——Environment12.CreateSharedBuffer → OpenStream+IStream::Write
  写载荷 → ICoreWebView2_17.PostSharedBufferToScript（READ_ONLY）→ JS
  `sharedbufferreceived` 事件（getBuffer() 返回 **ArrayBuffer 本体**；处理器内同步取用 +
  `chrome.webview.releaseBuffer` 语义）→ checksum 处理器内重算比对（字节零拷贝不进 JSON 管道）。
  **实测坑**：① PostSharedBufferToScript 在 WebMessageReceived 回调内调用会重入挂死
  （v0.1.17 ExecuteScript 同款陷阱）→ WM_APP+20 marshal 出回调；② get_Buffer 直写 +
  JS 经 `view.buffer` 包装得空数组（ArrayBuffer 无 .buffer 属性）→ sum=0 假象，改
  `new Uint8Array(ab)` 后通过；③ WM_APP 槽位 9/10/12 已占（TOAST/HTTP/PROC）→ 20
- **平台差异**：WebKitGTK 无 SharedBuffer 对等 API（文档化；Linux 大数据走既有 base64
  分块通道）——Linux 冒烟 skip 形态
- **验收**：Windows 单测全绿冒烟 **56 项**（+c-binipc：16KB SharedBuffer 往返 checksum
  match）；Linux 单测全绿冒烟 **79/79**（binipc skip）
- **范围说明**：A11 CompositionController（DirectComposition visual tree + 输入转发 +
  非客户区 API——v0.3.x 最大单项 COM 工程）移至专项版本：ABI 面已核对
  （Environment10::CreateCoreWebView2CompositionControllerWithOptions 槽 22 + NonClientRegion
  接口族），技术方案记录在 v0.3.x-PLAN §v0.3.6

v0.3.5 新增（2026-11-17，安全深化）：

- **DPAPI 加密 store（Windows）**：`Config.store_encrypted = true` → `store.set` 经
  CryptProtectData（当前用户作用域，crypt32 动态加载）加密落盘（`dpapi:` 前缀 + base64）、
  `store.get` 自动解密（往返语义不变；混合形态兼容——非前缀值原样读）。
  **实测物理证据**：store.json 含 `dpapi:` 值且明文 secret 不在磁盘。
  Linux 无 DPAPI → 开关忽略（明文落盘，libsecret 列 v0.4+ 文档化）
- **范围说明**：isolation pattern（iframe 沙箱持钥 + postMessage 代理，需 runtime JS
  重设计）与 Wayland portal 快捷键（需真 Wayland 会话验证；X11 路径已工作）移至
  专项版本——GDBus 订阅基建（logind）已就位可复用
- **验收**：Windows 单测全绿（+DPAPI 前缀/往返，真实 crypt32 往返实测）冒烟 **55 项**
  （+c-dpapi：加密 store 往返）；Linux 单测全绿冒烟 78/78（平台差异文档化）

v0.3.4 新增（2026-11-17，分发与更新）：

- **侧车资源（resources）**：`project.zig` 声明 `resources`（相对项目根的目录/文件）→
  `zig build` 安装到 exe 旁 `resources/**`（`addInstallDirectory`）→ NSIS 安装器
  `File /r` 同布局分发（`{RESOURCES_INSTALL}` 占位符）→ 运行时
  `window.zilt.path.resource(rel)` 解析（防穿越：拒绝绝对路径与 `..`）+ 存在性检查。
  demo 资源 `resources/demo/` 冒烟断言（c-res）。deb/AppImage 的 resources 分发列后续
- **更新器 skipVersion**：`window.zilt.updater.skipVersion(v)` → `<appData>/skipped.json`
  （单版本覆盖式）→ check 命中即视为无更新（进程内立即生效 + 启动加载持久化）
- **GitHub Releases provider**：`Config.update.github_repo = "owner/repo"` → check 先请求
  `releases/latest` 解析 `zilt-manifest.json` asset 作为清单 URL（manifest_url 兜底）；
  Fetcher 注入离线单测（release assets 匹配/大小写/缺失）
- **更新器事件补全**：`updateDownloading`（下载开始）入列（updateInfo/updateStaged/
  updaterFailed 既有）；细粒度字节进度需 fetcher 回调，列后续
- **验收**：Windows 单测全绿（+parseSkipped/manifestUrlFromGithubRelease）冒烟 **54 项**
  （+c-res）；Linux 单测全绿冒烟 **78/78**；clip 两项为已知桌面剪贴板占用环境问题
- **范围说明**：E2（离线 WebView2 fixed 打包 E2E）与 E4（交叉编译 pack 流水线）留待
  专项迭代（fixed loader 代码路径已有单测；deb/AppImage 交叉产出待 CI 验证）；模板
  TS 变体（F2）同批延后

v0.3.3 新增（2026-11-17，窗口体验包 II——对齐 Wails WindowMask/ButtonState/KeyBindings + Tauri resize drag/preventOverflow）：

- **窗口形状 mask**：`window.create({mask: <png 资产>})`——PNG alpha>8 逐行扫描 → 区域合并 →
  Windows `SetWindowRgn` / Linux `gdk_window_shape_combine_region`+input shape（区域外不渲染/不点击）
- **每按钮状态**：`window.create({closable,minimizable,maximizable})` + 运行时
  `window.setButtonState({closable,...}, id)`——Windows 系统菜单项灰化/恢复（GTK3 无 API 文档化）
- **托盘附着窗口**：`Config.tray.attach_window = <label>`——点击托盘切换该窗口显示/隐藏，
  定位到托盘图标附近（Shell_NotifyIconGetRect，屏幕边缘自适应；配合 `hideOnFocusLost` 即托盘弹窗）
- **失焦/Escape 隐藏**：`window.create({hideOnFocusLost, hideOnEscape})`——Windows 失焦
  WM_ACTIVATE+WA_INACTIVE / Escape 经窗口 ACCEL 表（专用 id 0xF000）；Linux focus-out-event /
  key-press-event（gdk_event_get_keyval，GdkEventKey opaque 规避）
- **窗口级 KeyBindings**：`window.create({keyBindings:[{id,key,ctrl,...}]})`（语法同 config.hotkeys）
  → `windowKeyBinding` 事件——Windows 窗口 ACCEL 表合并（id 空间 0xE000+；与菜单 accel 共存）
- **内容区拉伸**：`window.startResizeDragging(edge)`（n/s/e/w/ne/nw/se/sw）——Windows
  SC_SIZE+WM_NCLBUTTONDOWN；Linux `gtk_window_begin_resize_drag`
- **preventOverflow**：`window.create({preventOverflow})`——窗口位置夹取最近显示器工作区
  （Win：WM_WINDOWPOSCHANGING；Linux：configure-event 后 gdk workarea 夹取）
- **标题栏双击**：`window.create({titlebarDoubleClick:false})` 可禁用 overlay 拖动区双击最大化
  （Windows WM_NCLBUTTONDBLCLK；Linux 沿 WM 语义）
- **move 去抖**：`window.create({moveDebounceMs})` + 运行时 `window.setMoveDebounce(ms)`——
  拖动中合并 windowMoved、定时器补发终值（WM_EXITSIZEMOVE 立即补发）
- **setSimpleFullscreen 别名**：语义同全屏（Win/Linux 全屏即 borderless；命名对齐 Tauri）
- **验收**：Windows 单测全绿（+体验包动作映射）冒烟 **53 项**（+c-exp2：全量创建选项 +
  setButtonState/setMoveDebounce/setSimpleFullscreen 往返）；Linux 单测全绿冒烟 **78/78**
  （+exp2）；clip 两项为已知桌面剪贴板占用环境问题

v0.3.2 新增（2026-11-17，WebView 数据与协议面）：

- **真 scheme 自定义协议（Windows）**：`Config.protocols` 注册的协议在 Windows 上也以
  真 `scheme://` 可达（`ICoreWebView2EnvironmentOptions4` + `ICoreWebView2CustomSchemeRegistration`
  纯 Zig COM 实现；老运行时 QI 失败自动回退路径式）。两平台同约定 `<scheme>://<path>?<query>`。
  实测文档化限制（v0.3.8 修正）：自定义 scheme 的 fetch/XHR 请求根本不会发出（Chromium
  的 fetch scheme 白名单，跨 origin 与同 scheme 文档内均如此）——可读响应体用同源路径式
  `/__proto/<name>/…`；导航类请求（iframe/表单 POST）全链可达，POST body 经 get_Content 读取
  （v0.3.8 B8）
- **无痕窗口**：`window.create({incognito})` / `webviews.create({incognito})`——Windows 走
  `ControllerOptions.IsInPrivateModeEnabled`（Environment10，老运行时回退普通 controller 并记日志），
  Linux 走 `webkit_website_data_manager_new_ephemeral()`；`window.state().incognito` 可断言
- **Profile 设置面**：`webview.settings.autofill / password_autosave`（Windows：Profile6
  IsGeneralAutofillEnabled/IsPasswordAutosaveEnabled，QI 失败跳过；Linux 无对应 API 文档化）
- **backgroundThrottling**：`Config.environment.background_throttling=false` → 追加 Chromium
  节流禁用开关（环境级；Linux 无标准 API 文档化）
- **显示器细化**：`system.info('monitors')` 每条增 `current`（调用窗口所在屏）；
  `window.state()` 增 `incognito` 与 `monitor`（枚举序 index）；Linux 同接（gdk_monitor_at_window）
- **电源/会话事件**：`powerSuspend / powerResume / powerStatusChanged / sessionLock / sessionUnlock`
  ——Windows `WM_POWERBROADCAST` + `WTSRegisterSessionNotification`（wtsapi32）；Linux GDBus 订阅
  `org.freedesktop.login1`（PrepareForSleep + GetSessionByPID→Session Lock/Unlock；无系统总线降级）
- **验收**：Windows 单测全绿（+custom_scheme/SchemeRegistration/Options4 聚合语义/
  真 scheme 路由/节流开关/电源事件映射），冒烟 **52 项**（新增 c-scheme/c-privacy/c-monitor；
  clip 两项为已知桌面剪贴板占用环境问题）；Linux 单测全绿，冒烟 **77/77**（新增 privacy/monitor）
  + post terminate PASS；headless/MCP 全链路不受影响

v0.2.9 新增（2026-11-15，Linux 分发与测试收尾）：
- **WebKitWebDriver E2E**：`zilt-driver` 跨平台化（`webkitgtk:browserOptions` 方言 + 应用侧
  `set_automation_allowed`，env 门 `ZILT_AUTOMATION=1`），`zig build e2e` 在 Linux 放开
- **单文件 AppImage**：AppImageKit runtime + squashfs 拼接（3.9MB）；无 FUSE 环境降级
  `--appimage-extract`（runtime 仍完整解析镜像）
- **能力清单收尾**：`per_window_proxy` / `find_in_page` / `webdriver` 三项补齐（文档滞后修正）
- **验收**：Linux 单测 195/196（1 skip）/ Windows 279/279；Linux 冒烟 **66/66** exit 0；
  单实例转交 / 打包 / headless / AppImage E2E 全 PASS

v0.2.8 新增（2026-11-15，工具链与 headless）：
- **`init.zig` 跨平台**：kernel32 手写 extern 全换 `std.Io.Dir` + `Args.Iterator`，Linux 可生成项目
- **`zilt doctor` Linux 依赖检查**（gtk+-3.0 / webkit2gtk-4.1 / pkg-config）+ Linux headless/MCP 半边
- **模板漂移修复**；**验收**：两平台单测全绿，`zig build init` Linux E2E，headless/MCP 全链路 PASS

v0.2.7 新增（2026-11-15，Linux 平台能力对称）：
- 导航策略 / 权限请求 / 渲染进程崩溃恢复 / shell / 代理 / 更新器 / services 与 Windows 对齐
- **验收**：Linux 单测 191/192；冒烟 **65/65**；单实例转交与打包 E2E PASS；Windows 279/279 无回归

v0.2.6 新增（2026-11-14，Linux 收尾）：
- 窗口事件面（moved/resized/focus/blur/close/destroyed）+ X11 全局快捷键（XGrabKey）
- `windowEventPayloadJson` 抽为纯函数补单测；`close_requested` 合并语义收敛
- **验收**：冒烟 **59/59** exit 0（+ win.closereq 拦截闭环）

v0.2.5 新增（2026-11-14，GTK4 变体与稳定化）：
- Linux `print` 实装（`PrintOperation`）；`-Dgtk=gtk4` 构建变体（WebKitGTK 6.0）；性能基线脚本
- **验收**：GTK4 构建冒烟通过；冒烟 **57/57**（print system 路径断言）

v0.2.4 新增（2026-11-14，打包与 CI）：
- Linux 打包：deb / AppDir / squashfs / Flatpak manifest / rpm spec；CI 增 Linux job
- **附带修复**：`pack_formats` 单测此前从未被编译执行（root.zig 测试引用缺失）
- **验收**：deb 安装布局 → 提取版冒烟 **57/57**；AppDir AppRun 冒烟 **57/57**

v0.2.3 新增（2026-11-14，Linux 安全与数据）：
- ACL 全链路 / `store` / `fs`（含 inotify watch）/ SQL（sqlite3 动态加载）/ libsoup 网络 / 真 `scheme://`
- **验收**：Linux 冒烟 **57/57** exit 0（有/无 D-Bus 双环境）

v0.2.2 新增（2026-11-13/14，系统集成）：
- 剪贴板 / 原生对话框 / 通知（D-Bus）/ 菜单栏 / 托盘 / 单实例 / 深链 / 拖放 / 自启动 / 系统信息 /
  运行时菜单模型 / 窗口状态持久化
- **验收**：冒烟 42 → **48 项**（`desktop_entry`/`deep_link`/`sysinfo_linux`/`backend` 纯逻辑单测同步补齐）

v0.2.1 新增（2026-11-13，窗口与 WebView 面）：
- 多窗口 / 子 WebView / 数据分区接通；下载 / cookies / 清存储 / 截图 / 窗口状态持久化
- **验收**：Linux 冒烟 **40/40**；Windows 单测 267/267 零回归

v0.2.0 新增（2026-11-12/13，平台抽象 + Linux 骨架）：
- 平台后端契约 + 选择层（Windows 零回归）、构建工具链与日志跨平台化
- Linux GTK3 + WebKit2GTK 4.1 后端骨架（窗口/资产/greet IPC 全链）
- **验收**：Linux `zig build test` 5/5；Windows 冒烟 49 项不回归

v0.1.24 新增（2026-11-12，平台细节收尾）：

- **每窗口 UA**：`window.create({ userAgent })` → 独立 UA（另有运行时 `webview.setUserAgent`）。注意 WebView2 语义：只对下一次导航生效
- **应用自定义协议**：`Config.protocols = &.{ .{ .name="media", .handle=fn } }` → `https://<origin>/__proto/media/<path>` 由 Zig 处理，可自定义状态码/内容类型/响应头/二进制体
- **验收**：单测 +3；冒烟 **49 项** exit 0（c-proto / c-ua）
- **未做**：真 `scheme://` 注册（需 WebView2 Options4）、浏览器扩展、InPrivate

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

要求：Zig 0.17.1+。

- **Windows 10/11**：系统自带 WebView2 运行时，无需安装任何 SDK。
- **Linux**：GTK3 + WebKit2GTK 4.1 开发包与 `pkg-config`（Debian/Ubuntu：
  `libgtk-3-dev libwebkit2gtk-4.1-dev libx11-dev`；GTK4 变体改用
  `libgtk-4-dev libwebkitgtk-6.0-dev` 并加 `-Dgtk=gtk4`）；无显示环境用 `xvfb-run`
  （详见 [docs/v0.2-LINUX.md](docs/v0.2-LINUX.md)）。
- **macOS**：尚未实现（见平台表）。

```sh
zig build gen      # 生成前端 TS 绑定（frontend/bindings/zilt.ts）
zig build run      # 启动示例应用（embedded 模式）
zig build test    # 单元测试 364 项（363 通过 + 1 skip：POSIX 专用；框架 341 + 工具链 23）
                  # 覆盖：IPC/绑定 codegen/更新器与差分补丁/打包（NSIS/WiX/MSIX/deb/AppImage）/
                  # ACL 与 isolation/fs/store/SQL/http/ws/托盘与任务栏/对话框/深链/单实例密封/
                  # 图标与 PNG 编解码/窗口模型/WebView2 ABI/加速键/系统信息/自启/...
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
./zig-out/bin/zilt.exe mcp      # MCP stdio 直连同目录 zilt-app（AI 客户端可接入）
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
ZILT_PACK_TARGET=sign ZILT_PACK_SIGN=dist/Zilt-0.3.18-x64.msix \\
ZILT_SIGN_THUMBPRINT=<指纹> zig build pack
```

代码签名（三种凭据来源，按优先级：路径 > base64 > 指纹）：

```sh
ZILT_SIGN_THUMBPRINT=<指纹> zig build bundle          # 证书已在证书存储
ZILT_SIGN_PFX=cert.pfx ZILT_SIGN_PASSWORD=*** zig build bundle
ZILT_SIGN_PFX_BASE64=<base64> ZILT_SIGN_PASSWORD=*** zig build bundle   # CI secret
```

GUI 冒烟测试（前端检查表 + Zig 侧 `smokeResult` 断言，日志 `ALL CHECKS PASSED` 且 exit 0；
当前 Windows **66 项**、Linux **86 项**）：

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
| [docs/v0.3.x-PLAN.md](docs/v0.3.x-PLAN.md) | **v0.3.x 系列规划**（对齐 Wails v3 / Tauri 2 差距：v0.3.2–v0.3.19 切片 + 三轮差距刷新） |
| [docs/v0.2-LINUX.md](docs/v0.2-LINUX.md) | **v0.2 Linux 开发需求文档**（选型/架构/功能矩阵/v0.2.0–v0.3.1 里程碑与实施记录） |
| [docs/research/](docs/research/) | 可行性调研报告（全部一手来源） |
| [docs/reference/](docs/reference/) | WebView2 ABI 笔记（IID/vtable/loader 协议/实测陷阱） |
| [docs/adr/](docs/adr/) | 架构决策记录 |
