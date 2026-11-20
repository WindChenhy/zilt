# Zilt 路线图 —— v0.4.x 系列规划

> 制定日期：2026-11-20。修订：2026-11-21（Linux 专项复核：L1–L8 入图，macOS 顺延）。
> 基线：**v0.3.19**（git 31b3109，测试体系收口）。
> 对标：**Wails v3.1.0 stable（2026-11-01）+ v3.2.0-nightly**、**Tauri 2.12.x**（2026-11 最新，2.12.x 仅 bugfix）。
> 历史说明：原 docs/ 文档（v0.1–v0.3 逐版本记录、调研报告、WebView2 ABI 笔记、ADR）已随文档清理移除，
> 逐版本实施与验收记录见 **git 提交历史**；当前能力索引与平台状态见 [README](../README.md)。
> 规划原则（沿用 v0.3 文化）：一个版本一个主题 + 全链路验收；平台差异显式文档化；
> 切片按工程量递增；实施时允许实测后微调。

## 0. 差距分析结论

### 0.1 已持平/领先维度（不动作）

| 维度 | 说明 |
|---|---|
| printToPdf | Wails/Tauri 均无（wry#707/1317 未实现）——Zilt Windows 已实装 |
| CDP 逃生口 / 截图 / 每请求头 | 两家均无 |
| 差分更新（zilt-patch）+ 健康确认 + 回滚 | Tauri 2 无 delta；Wails 无 delta |
| MCP（HTTP+stdio+resources+prompts+工具级 ACL） | Wails 有 MCP 但无 resources/prompts/ACL |
| capability ACL + scope + isolation 密封 + 原型冻结 | 对齐 Tauri 安全模型，isolation 为 Zilt 独有形态 |
| server 模式（WS 会话 + 浏览器 runtime shim） | 对齐 Wails application_server/BrowserWindow |
| headless / WebDriver E2E / doctor / 热重启 dev | 对齐 |
| 拖入/拖出/坐标/自定义格式、颜色/字体对话框 | 领先两家 |
| 二进制 IPC（SharedBuffer + FNV-1a 校验帧通道） | 对齐 Wails Streams（缺背压 → H4） |
| Wayland 全局快捷键（portal GlobalShortcuts） | Tauri 仅 X11（Wayland 明确不支持）；Zilt X11 + portal 双路（v0.3.10） |
| 可选依赖 dlopen（appindicator / libsqlite3 / WebKitWebDriver） | 运行时无硬依赖、缺失降级；Wails/Tauri 的托盘是编译期硬依赖 |
| 窗口形状 mask / 子 WebView / sticky / preventOverflow | 两家无或不全（详见 §0.4 对照矩阵） |

### 0.2 缺失项总表（H# 跨平台通用 + L# Linux 发行版专项）

> v0.3 的 G1–G27 已于 v0.3.14–v0.3.18 全部落地；G28（server TLS）原默认决策不纳入，
> 本轮经用户确认全部差距入图 → 改编号 H5 纳入 v0.4.1。

| 编号 | 能力 | 对标出处 | 平台 | 工程量 | 实施路径 |
|---|---|---|---|---|---|
| H1 | **macOS 全栈** | 两家均为一级平台 | macOS | 大（两切片） | zig-objc / @cImport objc_msgSend：NSApplication/NSWindow/WKWebView + 运行时注册 delegate；IPC 走 WKScriptMessageHandler + evaluateJavaScript 双向（无 SharedBuffer → 复用 Linux 式 evaluate/base64 通道）；资产经 WKURLSchemeHandler。**v0.4.3 骨架**（运行循环/窗口/资产/IPC 主链）+ **v0.4.4 集成分发**（菜单/托盘/对话框/剪贴板/通知/Dock/深链/单实例、title_bar_style/traffic_light/NSVisualEffect、.app+DMG 打包 / codesign+notarization、WebDriver） |
| H2 | iOS / Android 移动端 | Tauri 2 mobile stable；Wails v3 mobile | 移动 | 特大 | v0.4.6+ 仅**立项调研**：Zig 核心静态库化 + Kotlin/JNI、Swift/ObjC 桥；不进入 v0.4.x 实施 |
| H3 | Linux 加密 store（keyring） | Tauri keyring/stronghold | Linux | 中 | libsecret **dlopen 可选依赖**（复用 libayatana/libsqlite3 先例）：secret_password_store/lookup/free；缺失降级明文 + 日志；密文前缀 `secret:`（与 Windows `dpapi:` 同形，混合形态兼容） |
| H4 | channel 背压 | Wails Streams（v3.1.0） | 双 | 中 | v0.3.17 G25 帧协议扩**控制帧**：JS→Zig 信用窗口（每 N 帧向 Zig 发 ACK，超窗 send Promise pending）；Zig→JS 高水位事件；帧 type 位区分 data/ack/credit，向后兼容 |
| H5 | server 模式 TLS | Wails Server.TLS | 双 | 中 | headless HTTP 服务 TLS 化；Zig std 无服务端 TLS → 选型决策（§4 R1）：dlopen OpenSSL/mbedTLS vs 文档化「外层反代承担」；`Config.server_tls {cert,key}`（可选项，默认关） |
| H6 | 数据目录覆盖 | Tauri 2.12 appDirectoriesOverride | 双 | 小 | Config 增 `data_dir/config_dir/cache_dir` 可选覆盖（默认派生逻辑不变）；app_data/fs/store/更新器/窗口状态/WebView2 user data 统一走解析点 |
| H7 | 每窗口拖放开关 | Tauri dragDropEnabled | 双 | 小 | `window.create({dragDrop:false})`：Win 不注册/RevokeDragDrop；Linux 不挂 drag-dest——页面原生 drag 事件可用 |
| H8 | 禁用 JS | Tauri with_javascript_disabled | 双 | 小 | Win `Settings::put_IsScriptEnabled(false)`；Linux WebKitSettings `enable-javascript=false`（复核：两侧引擎均有开关，v0.3 曾以「平台不齐」推后，实为可行）；文档化：禁用后 window.zilt 运行时不可用（kiosk 锁定用途，Tauri 同语义） |
| H9 | 物理像素面 | Wails GetBorderSizes/PhysicalBounds | 双 | 小 | `window.state()` 增 `border_sizes`（Win WM_NCCALCSIZE 非客户区边；GTK gdk_window_get_frame_extents）+ `physical_position/physical_size`（Win GetWindowRect；GTK scale 换算） |
| H10 | 数值徽标 | Tauri set_badge_count | Linux(Unity) | 小 | com.canonical.Unity.LauncherEntry D-Bus `count` 属性（既有 Unity-only 徽标通道扩数值语义；Windows 文本徽标 v0.3.16 已有） |
| H11 | GPU 信息 | Wails GPUInfo | 双 | 小 | `system.info('gpu')`：Win DXGI EnumAdapters（+DXCore 兜底）；Linux /sys/class/drm 或 EGL glGetString |
| H12 | CLI 自更新 | Tauri cli/updater 体验 | 双 | 小 | `zilt self-update`：复用 updater 基建（ed25519 清单 + staging + 原子替换），目标 = zilt.exe 自身；GitHub Releases provider 复用 |
| H13 | 安装脚本钩子 + Flatpak E2E | Tauri NSIS/deb hooks | 双 | 小 | NSIS 预置 !include 钩子（pre/post install 片段注入）；deb preinst/postinst 片段合并；**Flatpak manifest 走 flatpak-builder 实测**（v0.2 起遗留的静态产物） |
| H14 | tus 断点续传 | 通用协议（Tauri upload stretch） | 双 | 中 | `http.upload` 增 resume：Upload-To/Offset 握手 + 分块 PATCH + 断点续传；WinHTTP/libsoup 分块写已具备，差进度/状态持久化 |
| H15 | 计划通知 | Tauri notification schedule | 双 | 小-中 | Windows：WinRT ScheduledToastNotification（动态加载 RoGetActivationFactory，失败降级进程内 timer）；Linux：GNotification 无调度 → 进程内 timer（语义弱，文档化） |
| H16 | reparent | Tauri unstable set_parent/reparent | 双 | 中 | `window.reparent(id)`：Win SetParent + style/owner 调整；GTK 容器重挂（gtk_widget_reparent deprecated 但可用） |
| H17 | 拖出常驻 drag source（opt-in） | —（反转 v0.1.12「不做常驻」决策，默认仍关） | 双 | 小-中 | `window.create({dragSource:true})`：Win 常驻 IDropSource 注册；GTK 常驻 drag source——默认关，保持不抢文本选择 |
| H18 | WML 声明式 HTML 绑定 | Wails WML | 双 | 中（可选） | runtime JS 扩展 wml 属性解释器（纯前端，不依赖后端新面）；**默认不排期**（弹性位） |
| H19 | 浏览器扩展加载 | Tauri/wry WebExtensions（实验） | Win | 大（实验） | WebView2 WebExtensions COM 面（上游实验 API，随 Runtime 演进）；**实验位，默认不排期** |
| H20 | 深链/CLI 参数解析面 | Tauri cli 插件 | 双 | 小 | 第二实例/首启参数统一解析：子命令+flag 语法，`deepLink` 事件载荷增 `parsed` 字段（现只有原始串分类） |
| H21 | WinHTTP 等响应头看门狗 | —（v0.1.20 已知限制自愈） | Win | 小-中 | 「已建连未回响应头」超时：watchdog 线程 + WinHttpCloseHandle 中止（flags 实测无效的自愈路径）；Linux libsoup 已有超时面，对齐语义 |

**Linux 发行版兼容专项（L 系列，第四轮复核）**

> 2026-11-21 对照 Wails v3.1 / Tauri 2.12 的 **Linux 专项**复核结论：Zilt 的 API 能力面更宽
> （见 §0.4），差距集中在**工具链与分发生态**——GTK4 默认化、分数缩放、AppImage 自包含、
> ARM64 构建链、包签名与 AUR。这一组不影响 `window.zilt` 的 API，但决定「在 24.04+/Fedora/
> Arch/ARM 上能否顺利装上并用好」，故单列 L 系列。

| 编号 | 能力 | 对标出处 | 平台 | 工程量 | 实施路径 |
|---|---|---|---|---|---|
| L1 | **GTK4 默认化 + 双栈构建** | Wails v3 默认 GTK4/WebKitGTK 6.0，`-tags gtk3` 于 v3.1 移除 | Linux | 中 | `build.zig` 默认 `gtk=gtk4`，`-Dgtk=gtk3` 保留为 legacy 一个周期；README/打包依赖/CI 安装包同步；**CI 增 gtk3 + gtk4 双 job**（单测 + Xvfb 冒烟；workflow 先落地，remote 建立后生效），本地等价脚本 `scripts/linux/dev-test-matrix.sh`；GTK4 差异（portal 文件对话框、AppIndicator、分数缩放）逐项回归 |
| L2 | 分数缩放 | Wails GTK4 `gdk_monitor_get_scale`（GTK 4.14+） | Linux | 小 | GTK4 走 `gdk_monitor_get_scale`（小数），GTK3 回退 `get_scale_factor` 并文档化；`system.info('monitors')` 增浮点 `scale`；窗口尺寸/截图/坐标换算路径复核（避免 1.25 下取整错位） |
| L3 | **AppImage 自包含 + 沙箱** | Wails AppImage 打包 WebKit 并修补 AppRun（保留 bubblewrap） | Linux | 大 | AppDir 收入 `libwebkit2gtk` + `WebKitNetworkProcess`/`WebKitWebProcess` helper；AppRun 处理工作目录与库路径（bwrap 内外均可解析）；`scripts/linux/dev-appimage-e2e.sh` 增「无宿主 WebKit」容器验证 + 无 FUSE 降级 extract；产物体积预期 +30–40MB，发布说明标注 |
| L4 | **ARM64 构建链** | Wails Docker 交叉 / Tauri Docker+QEMU | Linux | 中 | `scripts/linux/build-arm64.sh`：`arm64v8/ubuntu:24.04` 容器 + GTK/WebKit 依赖 → `zig build -Dtarget=aarch64-linux-gnu` → deb/AppImage；先落脚本与文档，CI 待 remote 建立后接入 |
| L5 | RPM/AUR 实构建 + PGP 签名 | Wails：deb/rpm `wails3 sign`、AUR 任务 | Linux | 中 | `rpmbuild -bb` 走通 spec（当前仅生成）；新增 `packaging/PKGBUILD` + `.SRCINFO`；`zilt-sign --linux`（gpg detach-sign：deb `_gpgorigin`、rpm `%_gpg_name`），密钥经 `ZILT_GPG_KEY` 注入 |
| L6 | 托盘挂窗（Linux） | Wails `AttachWindow`（定位/去抖/焦点丢失语义） | Linux | 中 | `tray.attach_window` 在 Linux 接线：左键 toggle + 依据 `gtk_status_icon_get_geometry` 定位（X11）；无几何（Wayland）回退光标位；focus-follows-mouse（Hyprland/Sway）下禁用 `hideOnFocusLost`（对齐 Wails 行为） |
| L7 | Linux 更新健康回滚 | —（Windows helper 已有，Linux 缺编排） | Linux | 小 | `--zilt-restart` helper：替换后等新 exe 存活 ≥N 秒且退出码 0，否则 `rollbackToBackup`（POSIX rename 已具备）+ 重新拉起；与 Windows 同语义、同日志 |
| L8 | capability 清单修正 | —（清单与实现不一致） | Linux | 极小 | 补 `window_key_bindings`（v0.3.9 A4L 已实现且有单测）；删除「Linux 未接线」过期注释；契约测试增「清单 ⊆ 后端 @hasDecl」断言，防再漂移 |

### 0.3 平台/引擎固有限制（维持文档化，不立项）

- **Linux**：printToPdf、每按钮状态、accent tint、background 节流、autofill/passwordAutosave、
  monitor rotation、字节级上传进度（libsoup3）——引擎无 API，两家同侧同样受限
- **Windows**：真 scheme 的页面 fetch/XHR（Chromium fetch scheme 白名单）、devtools 无关闭 API
- **aarch64 GUI 交叉**：sysroot 是工程封装问题（非引擎限制）→ 已立项 **L4**，不再列为固有限制
- **SnapAssist**：依赖 CompositionController 渲染修复（§2 持续跟踪后重评）

### 0.4 Linux 专项对照矩阵（2026-11-21 复核）

> 口径：Zilt 取 `src/zilt/platform/linux/` 与 `linux_target_capabilities`（代码为准）；
> Wails 取官方 Linux Packaging / SystemTray / Notifications 文档；Tauri 取 v2 文档与
> `tauri::window` 源码注释（Platform-specific 段）。

| 维度 | Zilt v0.3.19 | Wails v3.1 | Tauri 2.12 | 判定 |
|---|---|---|---|---|
| 默认工具栈 | GTK3 + WebKit2GTK 4.1（GTK4 可选，**CI 未覆盖**） | GTK4 + WebKitGTK 6.0（GTK3 legacy 至 v3.1） | GTK3 + WebKit2GTK 4.1 | 落后 → L1 |
| 分数缩放 | 仅整数 scale factor | `gdk_monitor_get_scale`（4.14+） | 仅整数（GTK3） | 落后 Wails → L2 |
| GNOME 主菜单 | 无 | `LinuxMenuStylePrimaryMenu` | 无 | 落后 |
| 托盘 | dlopen libayatana（可选依赖）、无挂窗 | 硬依赖 appindicator + `AttachWindow` | 硬依赖 appindicator、无挂窗 | 依赖更轻 / 挂窗落后 → L6 |
| Wayland 全局快捷键 | X11 + portal 双路 | 文档未明确 | **仅 X11** | 领先 Tauri |
| 二进制 IPC | evaluate + base64 | Streams | raw IPC | 落后 → H4 相关 |
| 包格式 | deb / AppImage / Flatpak manifest / rpm spec | deb / AppImage / rpm / AUR | deb / rpm / AppImage | 落后 → L5 |
| 包签名 | 无（`zilt-sign` 仅 Windows） | deb/rpm PGP | 无 | 落后 → L5 |
| AppImage 自包含 | 依赖宿主 WebKit | **打包 WebKit + 沙箱修补** | 依赖宿主 | 落后 Wails → L3 |
| ARM64 构建 | 无流程（Zig 可交叉） | Docker | Docker/QEMU | 落后 → L4 |
| store 加密 | Linux 明文 | 无 | keyring/stronghold | 落后 Tauri → H3 |
| 窗口 mask / 子 WebView / sticky / preventOverflow | 全有 | 无/不全 | 无/不全 | 领先 |

**结论**：Zilt 在 Linux 的 **API 面**（窗口/系统集成/安全/运行形态）领先或持平，差距集中在
**工具链与分发生态**（L1–L5）与两处交互细节（L6/L7）；L8 属清单与实现漂移的修正。


## 1. 版本切片（工程量递增）

### v0.4.0 — 双平台小项集中收尾 ✅ 完成（2026-11-21，git df73cd4 后 amend）

**验收**：Windows 单测 374 项全绿（353 通过 + 1 skip + 20 工具）+ 冒烟 **69/69 exit 0**；
Linux 单测 293 项全绿（274 通过 + 1 skip + 18 工具，WSL Ubuntu 22.04）+ 冒烟 **exit 0**
（含 bcount D-Bus 真发）。新增冒烟检查 c-v04 / c-gpu / c-bcount（双平台）+ curs 扩
scale 断言（L2）。**实测教训**：① DXGI EnumAdapters 在本机（RDP/VM 会话）返回
DXGI_ERROR_INVALID_CALL（C# ComImport 互操作复现）→ H11 Windows 侧改
EnumDisplayDevicesW（vendor/vram 数据受限，文档化）；② **严禁在 WebKit script-message
回调内调 g_bus_get_sync**（同步 I/O 重入主循环 → gio→glib→JSC→WebKit→
g_application_run abort 实测）→ 会话总线 init 一次性缓存 + emit 非阻塞发射。

目标：收掉全部「小工程量」差距，两平台行为对称；不动大结构。

- **H6** 数据目录覆盖（data/config/cache 三字段 + 统一解析点）
- **H7** 每窗口拖放开关（dragDrop opt-out）
- **H8** 禁用 JS（IsScriptEnabled / enable-javascript + kiosk 文档化）
- **H9** 物理像素面（border_sizes / physical_position / physical_size）
- **H10** 数值徽标（Unity LauncherEntry count）
- **H11** GPU 信息（system.info('gpu')）
- **H20** 深链/CLI 参数解析面（deepLink.parsed）
- **L2** 分数缩放面（GTK4 `gdk_monitor_get_scale` + `monitors.scale` 浮点；GTK3 回退并文档化）
- **L7** Linux 更新健康回滚（restart helper 等待存活 + 失败回滚）
- **L8** capability 清单修正（补 `window_key_bindings`，去过期注释，加漂移断言）

**验收**：Windows 冒烟 66+N 项 / Linux 86+N 项（每项能力带冒烟检查）+ 单测全绿 +
双平台 0 失败 0 泄漏；headless/server E2E 回归（H6 触碰目录解析点）；
L2 的 `monitors.scale` 在 1.0/1.25 两种缩放下断言；L7 用「人为让新 exe 退出」演练回滚；
L8 的清单断言在 gtk3 与 gtk4 两种本地构建下均通过（CI 双栈随 L1 在 v0.4.3 接入）。

### v0.4.1 — 网络/IPC/分发深化 ✅ 完成（2026-11-21，见 git 提交记录）

**验收**：双平台单测全绿（Windows/Linux `zig build test` 0 失败 0 泄漏，新增
upload_resume 状态机 4 测试 + winhttp 看门狗语义 2 测试）+ 冒烟新增 c-bp / c-tus
（双平台）。Windows 冒烟 71 项中 69 通过（clip/clipmulti 为既有环境问题——外部
剪贴板占用，cmd/PowerShell 同样失败；c-bp/c-tus 全过）；**Linux 冒烟 exit 0 全过**
（含 tus 中断→续传 E2E：failAfter=2 演练中断@32768 → 状态续传 → 65536 完成）。
**实测教训**：① worker 线程持有的 job/字符串必须 page_allocator 分配（dispatch
per-message arena 回收后 worker free = free(): invalid pointer abort）；② libsoup
3.0.7（22.04）同步读取即 `soup_session_send_and_read`（无 _sync 变体）；③
`std.c.getenv` 在 Windows 构建触发 libc 链接要求 → 平台分派。

目标：IPC 与网络面补齐 Wails v3.1 对齐的最后两块（背压、TLS），分发链收尾。

- **H4** channel 背压（信用窗口控制帧，向后兼容 G25）
- **H5** server 模式 TLS（选型决策后实施或文档化，见 §4 R1）
- **H14** tus 断点续传（http.upload resume）
- **H21** WinHTTP 等响应头看门狗
- **H12** CLI 自更新（zilt self-update）
- **H13** NSIS/deb 安装脚本钩子 + Flatpak builder E2E

**验收**：背压（高水位断言 + 吞吐不回退）+ tus（中断→续传 E2E）+ TLS（决策项：
实装则 openssl s_server/wireshark 实测，文档化则部署指引）+ 打包 E2E 全格式 +
既有冒烟/单测全量回归。

### v0.4.2 — 安全与系统集成 ✅ 完成（2026-11-21，见 git 提交记录）

**验收**：双平台单测全绿（+libsecret dlopen/往返、notify_sched 提取/时钟 3 测试）+
冒烟新增 c-v042（reparent 记账）/ c-sched（notificationScheduled 事件）/ c-secret
（加密 store 往返+标记检查）。Windows 74 项中 72 通过（clip×2 既有环境问题）；
**Linux 冒烟 exit 0 全过（94/94）**——libsecret 真密钥环往返（WSLg 会话总线 +
GNOME Keyring，marker=secret 降级容错）、reparent 记账、sched 事件全过。
**实测教训**：① script 回调内 std.Thread.spawn 会 SIGABRT → 调度线程 init 预启；
② GNotification 非线程安全 → notifyEntry 经 g_idle_add 封送（调度线程可达）；
③ GBytes opaque 不能 [*c] 索引 → raw 指针 + 用点 @ptrCast；④ worker 所有权
page_allocator（延续 v0.4.1 教训）。

目标：安全面收尾（Linux 密钥环对齐 Tauri）+ 系统集成弹性项。

- **H3** Linux libsecret 加密 store（dlopen 可选，`secret:` 前缀）
- **H15** 计划通知（WinRT 动态加载 + timer 降级）
- **H16** reparent（unstable 语义对齐）
- **H17** 拖出常驻 drag source（opt-in）

**验收**：libsecret 物理 E2E（seahorse/secret-tool 互操作可见）+ 降级路径 +
通知定时触发实测 + reparent 往返（父子/销毁级联）+ 全量回归。

### v0.4.3 — Linux 发行版兼容专项

目标：把 Linux 从「API 齐全」推进到「发行版可直接采用」——GTK4 默认、自包含 AppImage、
ARM64、包签名/AUR、托盘挂窗。这是 L 系列的主体，也是与 Wails v3.1 差距最集中的一段。

- **L1** GTK4 默认化 + 双栈构建（`-Dgtk=gtk3` 保留为 legacy 一个周期，CI 双 job）
- **L3** AppImage 内嵌 WebKit（helper 进程）+ AppRun 沙箱修补
- **L4** ARM64 构建链（Docker + GTK/WebKit sysroot → deb/AppImage）
- **L5** RPM/AUR 实构建 + PGP 签名（deb `_gpgorigin` / rpm detach-sign）
- **L6** 托盘挂窗（AttachWindow 语义：左键 toggle、贴图标定位、focus-follows-mouse 规避）

**验收**：gtk3/gtk4 双栈单测 + Xvfb/openbox 冒烟全绿；AppImage 在「未安装 WebKit 的容器」
内启动并跑通冒烟（无 FUSE 走 extract 路径）；ARM64 deb/AppImage 在 qemu-user 下冒烟通过；
`gpg --verify` 校验 deb/rpm 签名；AUR `makepkg` 构建通过；托盘挂窗 X11 实测 +
Wayland 回退路径文档化；既有冒烟/单测全量回归（Windows 侧零回归）。

### v0.4.4 — macOS 全栈 I（骨架）

目标：macOS 端到端最小可用——窗口 + 资产 + IPC 主链跑通。

- zig-objc 基建：NSApplication/NSWindow/WKWebView/NSWindowDelegate +
  WKScriptMessageHandler（ObjC block 注册）+ WKURLSchemeHandler（资产服务）
- IPC：WKScriptMessageHandler（JS→Zig）+ evaluateJavaScript（Zig→JS，Promise 语义）；
  无 SharedBuffer → 复用 Linux 式 evaluate/base64 通道
- 窗口模型首切片：创建/标题/尺寸/居中/全屏/多窗口 + 窗口事件面（moved/resized/focus/close）
- runtime JS 三态传输扩第四态（mac.webkit messageHandlers）

**验收**：macOS `zig build test` 链 + 冒烟骨架（greet/add 往返 + 资产 200）；
无 macOS 环境则 GitHub Actions macOS runner 兜底（§4 R2）。

### v0.4.5 — macOS 全栈 II（系统集成与分发）

目标：macOS 能力面对齐 Windows/Linux 已有面 + 分发链。

- 系统集成：菜单/托盘（NSStatusItem）/对话框（NSOpenPanel 等）/剪贴板/通知（UNUserNotificationCenter）/
  Dock 徽标/深链/单实例/自启（LaunchAgent/Launcher）
- 平台效果：title_bar_style（visible/overlay/transparent）+ traffic_light 位置 +
  NSVisualEffectView 材质 + 全工作区可见
- 分发：.app 结构 + DMG（hdiutil）+ codesign + notarization（stapler）+ 更新器 macOS 接线
- WebDriver（safari/webkit driver 或 CDP 桥选型）

**验收**：macOS 冒烟对齐双平台检查面（平台差异项文档化 skip）+ 打包产物
codesign 验证 + Gatekeeper 实测。

### v0.4.6+ — 弹性/实验位

- **H18** WML（可选，默认不排期）
- **H19** 浏览器扩展（实验，跟随上游 WebView2 API 稳定度）
- **H2** 移动端立项调研（Phase 5 开题，不实施）

## 2. 持续跟踪（非版本项）

- **CompositionController 渲染**：已定案上游 WebView2 运行时缺陷
  （EmbeddedBrowserWebView.dll 段错误，ZILT_COMP_BARE 最小复现）。每个 v0.4 版本
  带一次 `ZILT_COMP_ENABLE=1` 探测（Runtime 版本矩阵记录），上游修复后解锁
  SnapAssist 重评（§0.3）。
- **上游追踪**：Wails v3.2.x / Tauri 2.13+ 发布时做下一轮（第五轮）差距刷新；
  第四轮已完成——2026-11-21 的 Linux 专项复核（§0.4）。

## 3. 验收链（沿用 v0.3.19 口径）

1. `zig build test`（基线：Windows 364 / Linux 280，随功能递增；0 失败 0 泄漏）
2. `zig build`（构建 + capability 清单 + 资产嵌入）
3. GUI 冒烟（基线：Windows 66 / Linux 86 项；新增能力必须带检查项，exit 0）
4. 触碰面专项：headless/MCP E2E、server E2E、PACK_E2E、e2e_fixed_runtime
5. **Linux 双栈（v0.4.3 起）**：`-Dgtk=gtk3` 与 `-Dgtk=gtk4` 各跑单测 + Xvfb/openbox 冒烟；
   AppImage「无宿主 WebKit」容器冒烟 + ARM64 qemu-user 冒烟 + `gpg --verify` 签名校验
6. macOS 切片自建验收链（v0.4.4 起）：zig build test macOS + 冒烟骨架 + codesign 产物验证

## 4. 风险与依赖

- **R1（H5 TLS）**：Zig std 无服务端 TLS。选型：dlopen OpenSSL/mbedTLS（新增可选依赖）
  vs 文档化「外层反代承担」。实施前先做可行性实验定案。
- **R2（H1 macOS）**：验收依赖 macOS 环境（本机或 CI runner）；WKScriptMessageHandler
  的 ObjC block 注册是主链最大技术风险（v0.4.4 第一优先验证点）；
  WKWebView 无 CDP/SharedBuffer/PrintToPdf 对等 → 能力差异逐项文档化。
- **R3（H15）**：Zilt 全线免 WinRT，ScheduledToastNotification 经 RoGetActivationFactory
  动态加载需实验，失败即降级 timer 方案。
- **R4（H19）**：WebView2 WebExtensions API 上游未稳定，只做实验位。
- **R5（文档）**：v0.3 期间的调研报告与 ABI 笔记已删除——macOS/扩展实施前需重做针对性
  调研，或从 git 历史找回 docs/research、docs/reference。
- **R6（L1 GTK4 默认化）**：WebKitGTK 6.0 在 Ubuntu 22.04 / Debian 12 不可用——必须保留
  `-Dgtk=gtk3` legacy 至少一个周期，且发布说明按发行版分列依赖；GTK4 的文件对话框走
  xdg-desktop-portal，默认目录/过滤器行为与 GTK3 不同（需回归对话框用例）；AppIndicator
  在 GTK4 下仍需 libayatana（保持 dlopen 可选）。
- **R7（L3 AppImage 自包含）**：内嵌 WebKit 体积 +30–40MB，且 WebKit 的 bwrap 沙箱在
  AppImage 挂载路径下对 helper 解析敏感——先做可行性脚本（无宿主 WebKit 容器 + extract
  路径），验证 AppRun 工作目录方案后再改打包器。
- **上游**：CompositionController 渲染修复取决于 WebView2 Runtime；WebKitGTK 自定义
  scheme POST body 上游修复自动生效（v0.3.8 已接线）。

## 5. 决策记录

- **D1（2026-11-20，已被 D6 修订）**：v0.4.0–v0.4.2 聚焦双平台收尾；macOS 原放 v0.4.3+（环境依赖最大，
  但为 v0.4 主轴——三家平台面对齐的最后一块结构性缺口）。D6 将 macOS 顺延至 v0.4.4+。
- **D2（2026-11-20）**：H18 WML / H19 浏览器扩展默认不排期（弹性位），需要时提前插队。
- **D3（2026-11-20）**：G28 server TLS 从 v0.3 的「默认不纳入」改为 v0.4.1 纳入——
  用户指示全部差距入图（用户确认，2026-11-20）。
- **D4（2026-11-20）**：移动端维持 Phase 5，仅立项调研，不进入 v0.4.x 实施。
- **D5（2026-11-20）**：§0.3 平台固有限制维持文档化不立项（与 v0.3 三轮复核结论一致）。
- **D6（2026-11-21）**：Linux 发行版兼容（L1–L8）入图。L2/L7/L8（小项）并入 v0.4.0；
  L1/L3/L4/L5/L6 独立为 **v0.4.3 Linux 专项**——理由：GTK4 默认化与 AppImage 自包含会改变
  发布产物与依赖面，不宜与其他小项混在一个版本（一个版本一个主题）；macOS 顺延为
  v0.4.4/v0.4.5，弹性位顺延 v0.4.6+。
- **D8（2026-11-21）**：H5 server TLS 选型定为**文档化「外层反代承担」**（实施于
  v0.4.1 发布说明）：Zig std 无服务端 TLS；引入 OpenSSL/mbedTLS dlopen 违反零依赖
  文化；headless/server 模式定位为内网/本机桥，TLS 由部署层（nginx/caddy）承担。
  tus 协议同步调整为 JSON-tus-lite（offset 回执走响应体——http.request 面无响应头
  读取；tus 标准响应头形态列为 stretch）。
- **D7（2026-11-21）**：GTK3 **不立即移除**，以 `-Dgtk=gtk3` legacy 形式保留至少一个周期
  （与 Wails v3.1 直接移除不同）——理由：Ubuntu 22.04 / Debian 12 / RHEL 9 仍在支持期，
  且 Zilt 的 dlopen 依赖策略本就偏向“宽兼容”。移除时间点由发行版 EOL 与实际使用数据决定。
