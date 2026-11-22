# Zilt 路线图 —— v0.4.x 系列规划

> 制定日期：2026-11-20。修订：2026-11-21（Linux 专项复核：L1–L8 入图，macOS 顺延）。
> 基线：**v0.3.19**（git 31b3109，测试体系收口）。
> 当前：**v0.4.6**（2026-11-22，macOS 外观与窗口行为收尾：材质/主题/Dock/事件面/状态持久化/拖动接线；
> v0.4.5–v0.4.9 为 macOS 能力面切片，见下）。
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
> （见 §0.4），差距集中在**工具链与分发生态**——GTK4 默认化（L1b 未做）、分数缩放、
> ARM64 实跑。包格式/签名/AppImage 自包含/托盘挂窗已在 v0.4.3 补齐（L3/L5/L6 实测）。
> 这一组不影响 `window.zilt` 的 API，但决定「在 24.04+/Fedora/Arch/ARM 上能否顺利装上
> 并用好」，故单列 L 系列。

| 编号 | 能力 | 对标出处 | 平台 | 工程量 | 实施路径 |
|---|---|---|---|---|---|
| L1 | **GTK4 默认化 + 双栈构建** | Wails v3 默认 GTK4/WebKitGTK 6.0，`-tags gtk3` 于 v3.1 移除 | Linux | 中 | `build.zig` 默认 `gtk=gtk4`，`-Dgtk=gtk3` 保留为 legacy 一个周期；README/打包依赖/CI 安装包同步；**CI 增 gtk3 + gtk4 双 job**（单测 + Xvfb 冒烟；workflow 先落地，remote 建立后生效），本地等价脚本 `scripts/linux/dev-test-matrix.sh`；GTK4 差异（portal 文件对话框、AppIndicator、分数缩放）逐项回归 |
| L2 | 分数缩放 | Wails GTK4 `gdk_monitor_get_scale`（GTK 4.14+） | Linux | 小 | GTK4 走 `gdk_monitor_get_scale`（小数），GTK3 回退 `get_scale_factor` 并文档化；`system.info('monitors')` 增浮点 `scale`；窗口尺寸/截图/坐标换算路径复核（避免 1.25 下取整错位） |
| L3 | **AppImage 自包含 + 沙箱** | Wails AppImage 打包 WebKit 并修补 AppRun（保留 bubblewrap） | Linux | 大 | ✅ 已实施（2026-11-21）：`ZILT_BUNDLE_WEBKIT=1 zig build pack` → ldd 闭包（117 库，剔除 glibc/驱动栈）+ WebKit helper/injected-bundle 复制；**libwebkit 编译期 helper 路径等长改写**（2.52 无 `WEBKIT_EXEC_PATH`，strace 实测）为 `/tmp/.zk-<hash>`，AppRun 建符号链并设 `LD_LIBRARY_PATH`/`WEBKIT_INJECTED_BUNDLE_PATH`/GIO/pixbuf/GSettings 面；`dev-appimage-e2e.sh` 增「无宿主 WebKit」验证（docker 优先；无镜像时 bwrap 掩 14 处宿主 WebKit，等价命名空间），LD_DEBUG 断言加载随包路径；**实测 +88MB**（squashfs 88MB，WebKit 2.52 比预期大，见 R7）；**沙箱实测结论**：Ubuntu/Debian 的 WebKitGTK 构建不安装 `bwrapinfo.json`（未启用 bubblewrap）→ WebKit 静默无沙箱运行，helper 路径改写与沙箱无交互；E2E 增 `SANDBOX_SUPPORT/SANDBOX_ACTIVE` 探测（有 bwrapinfo 的发行版上采样 `WebKitWebProcess` 的 pid-ns/seccomp，`ZILT_SANDBOX_REQUIRE=1` 时强制断言） |
| L4 | **ARM64 构建链** | Wails Docker 交叉 / Tauri Docker+QEMU | Linux | 中 | 脚本就绪（2026-11-21）：`scripts/linux/build-arm64.sh`（默认 docker：`arm64v8/ubuntu:24.04` + QEMU binfmt → 容器内装 GTK3/WebKitGTK + aarch64 Zig → `zig build` + `ZILT_BUNDLE_WEBKIT=1 zig build pack`；`--sysroot DIR` 本地交叉走 `PKG_CONFIG_SYSROOT_DIR`）+ `dev-arm64-e2e.sh`（qemu-aarch64-static -L sysroot / arm64 容器跑冒烟，ELF machine 断言）+ CI `linux-arm64` job（setup-qemu-action）。**本机 WSL 无外网且无 arm64 镜像 → 容器路径如实 SKIP，验收待 CI** |
| L5 | RPM/AUR 实构建 + PGP 签名 | Wails：deb/rpm `wails3 sign`、AUR 任务 | Linux | 中 | **✅ 已实施（2026-11-21）**：`pack-rpm.sh` 真跑 `rpmbuild -bb` → 16.3MB `app.zilt.desktop-0.4.3-1.x86_64.rpm`（载荷 bin + `.desktop` + hicolor PNG，`%post(un)` 刷新 desktop db；rpm 自动依赖闭包）；`pack-aur.sh` 生成 PKGBUILD/.SRCINFO + 源 tar，并用 `source PKGBUILD; package` 模拟 makepkg 安装段（落地文件断言）；`sign-packages.sh` deb 追加 `_gpgorigin`（GNU ar 纯字节追加，`dpkg-deb` 仍可解析）+ rpm `--addsign`，`dev-sign-e2e.sh` 做 Good signature / `rpm -K`（独立 rpmdb 导入公钥）+ **反向对照**（空 rpmdb 与原包必须不通过）；makepkg 实跑仍缺 docker 镜像（离线），已在脚本内如实跳过 |
| L6 | 托盘挂窗（Linux） | Wails `AttachWindow`（定位/去抖/焦点丢失语义） | Linux | 中 | ✅ 已实施（2026-11-21）：XEmbed 宿主（stalonetray/trayer/面板）→ **自建 GtkStatusIcon**（左键 `activate` → toggle；libayatana 回退把左键绑成弹菜单，拿不到该语义）+ `gtk_status_icon_get_geometry` 定位；无 XEmbed 宿主 → libayatana SNI（`secondary_activate_target` 隐藏菜单项为点击入口，左键菜单/中键 toggle 由宿主决定）；点击 200ms 去抖（Wails WindowDebounce）；FFM 桌面（Hyprland/Sway/i3…）禁用挂窗 `hideOnFocusLost`；WM 外框偏移用延时校正（openbox 实测 +20px）；`scripts/linux/dev-tray-e2e.sh` 实测（Xvfb+openbox+stalonetray+XTest） |
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
| 托盘 | dlopen libayatana（可选依赖）、挂窗（XEmbed 自建图标 + 几何定位 / SNI 目标项） | 硬依赖 appindicator + `AttachWindow` | 硬依赖 appindicator、无挂窗 | 持平（依赖更轻） |
| Wayland 全局快捷键 | X11 + portal 双路 | 文档未明确 | **仅 X11** | 领先 Tauri |
| 二进制 IPC | evaluate + base64 | Streams | raw IPC | 落后 → H4 相关 |
| 包格式 | deb / AppImage / Flatpak / rpm（实构建）/ AUR PKGBUILD | deb / AppImage / rpm / AUR | deb / rpm / AppImage | 持平（L5） |
| 包签名 | deb `_gpgorigin` / rpm `--addsign`（实签实校，L5） | deb/rpm PGP | 无 | 持平（L5） |
| AppImage 自包含 | **WebKit 随包 + helper 路径改写**（L3 实测） | **打包 WebKit + 沙箱修补** | 依赖宿主 | 持平（沙箱面见 L3 注） |
| ARM64 构建 | 脚本 + CI job（Docker/QEMU 或 `--sysroot`），待首次实跑 | Docker | Docker/QEMU | 落后 → L4 |
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

### v0.4.3 — Linux 发行版兼容专项 [~] L1a + L3 + L6 完成，L4 脚本+CI 就绪（2026-11-21）

**L1a ✅（2026-11-21）——GTK4 构建级兼容基础 + 双栈环境**：
- 环境：Ubuntu 24.04 第二发行版（WSL，D 盘迁移后新建）+ GTK 4.14.5 / WebKitGTK 6.0
  2.52.6 / Zig 0.17.1；`scripts/linux/dev-smoke.sh --gtk4` 双栈冒烟开关
- capi.h：WebKit 头改构建期宏 `ZILT_GTK4` 选择——实测教训：`__has_include` 会命中
  /usr/include 默认路径下并存的另一变体头（两代 dev 包并存必现），变体选择必须显式
- 符号审计（gtkaudit.sh：nm 对照 libgtk-4 导出）：**70 个 GTK4 移除符号**，覆盖窗口
  主循环/基础几何/对话框/剪贴板/拖放/菜单全套——量级为 4.x UI 面重写（GdkClipboard/
  GdkDrag/GtkPopoverMenu/GtkFileDialog/gdk_toplevel），非补丁级
- 探针实验（已回滚，保留宏基础设施）：51 处 opaque 指针替换 + 12 处销毁语义分派 +
  能力守卫的机制验证成立
- **零回归**：Windows/22.04 单测全绿 + 22.04 GTK3 冒烟 exit 0

**L1b（待实施）——4.x UI 面重写**：按审计表逐子系统移植（GdkClipboard ↔ GtkClipboard、
GdkDrag ↔ gtk_drag_*、GtkPopoverMenu ↔ GtkMenu 族、gdk_toplevel ↔ gtk_window 几何/
状态、GtkFileDialog ↔ GtkFileChooserNative）；完成后切 `-Dgtk=gtk4` 默认化（D7 保留
gtk3 legacy 一个周期）。前置已就绪（本 L1a 环境）。

**L6 ✅（2026-11-21）——托盘挂窗（attach_window 接线 + stalonetray 实测）**：

- **XEmbed 宿主（stalonetray/trayer/xfce4-panel）→ 自建 GtkStatusIcon**：libayatana 在无
  SNI 宿主时的回退实现把左键绑成「弹菜单」，拿不到 AttachWindow 的左键 toggle 语义；
  自建图标接 `activate`（toggle）/`popup-menu`（菜单），并用 `gtk_status_icon_get_geometry`
  取真实图标矩形。检测：`_NET_SYSTEM_TRAY_S<n>` 选择拥有者存在即走该路径（GTK3；GTK4 仍无托盘，文档化）
- **无 XEmbed 宿主 → libayatana SNI**：`app_indicator_set_secondary_activate_target` 的隐藏
  菜单项为点击入口（GNOME/KDE 的 SecondaryActivate → 激活该目标）；字符串审计确认
  libayatana 0.5/0.6 无 `secondary-activate` GObject 信号（D-Bus 方法由库内部转为激活目标项），
  故不连信号；左键菜单/中键 toggle 由宿主策略决定（文档化）
- **定位**：XEmbed 几何（`gtk_status_icon_get_geometry` → X 树扫描 `_XEMBED_INFO` 兜底）→
  右缘贴图标右缘、下/上方 4px、工作区夹取；SNI 无图标窗口 → 指针锚点；Wayland 无全局坐标 → 原位
- **WM 外框校正**：openbox 把 ConfigureRequest 当外框位置（实测客户区 +20px），同步读几何又是旧值
  → show 后 80ms 延时校正一次（`surfaceOrigin` 实测原点补偿；只校一次，不覆盖后续拖动）
- **去抖 / FFM**：点击 200ms 去抖（Wails WindowDebounce；目标项与信号面可能对同一次点击各触发一遍）；
  focus-follows-mouse 桌面（Hyprland/Sway/i3/xmonad/qtile 令牌匹配 + `HYPRLAND_INSTANCE_SIGNATURE`/
  `SWAYSOCK`；`ZILT_FOCUS_FOLLOWS_MOUSE` 覆盖）下挂窗 `hideOnFocusLost` 整段禁用（Wails 语义）
- **检测时机**：托盘路径在启动时定（有 XEmbed 宿主 → 自建图标；否则 SNI）。托盘宿主晚于
  应用启动时，libayatana 回退仍会挂上图标但左键语义回到「弹菜单」——需要挂窗语义时先启托盘
  宿主（真实桌面总是先有面板；E2E 亦如此）
- **实测**：`scripts/linux/dev-tray-e2e.sh`（Xvfb 1280x800 + openbox + stalonetray 顶部右侧 +
  `scripts/linux/xtool.py` XTest 合成点击，无 xdotool 依赖）：左键隐藏/再左键显示（318,30 =
  图标右缘 1278 / 下缘 26+4）、右键菜单、FFM 检测全 PASS；单测 GTK3/GTK4 各 301（283+18，1 skip）
  全绿，冒烟 95 项含 `tray.attach` PASS（当时的 screenshot/clipboard 两项既有失败已在 L3 阶段定位修复，
  见下）

**L3 ✅（2026-11-21）——AppImage 自包含（WebKit 随包 + 无宿主实测）**：

- **随包面**（`src/pack_linux.zig`，`ZILT_BUNDLE_WEBKIT=1`）：`ldd` 闭包（exe + 三个
  helper）按 soname 摊平到 `usr/lib/`（剔除 glibc 家族 / libstdc++ / GL·EGL·drm·gbm /
  nvidia），共 117 库；helper 目录（WebKit{Web,Network,GPU}Process + injected-bundle）
  复制到 `usr/lib/<triplet>/webkit2gtk-4.1/`；GIO 模块、gdk-pixbuf loaders、
  `gschemas.compiled` 一并带上
- **路径改写（关键实测）**：WebKitGTK 2.52 **没有** `WEBKIT_EXEC_PATH`——strace 三段对照
  （默认 / 设为副本 / 设为不存在）均 exec `/usr/lib/<triplet>/webkit2gtk-4.1/WebKit*`。
  AppImage 挂载点长度可变，只能把 libwebkit 里的**编译期常量前缀等长改写**为固定短路径
  `/tmp/.zk-<12hex>`（+ NUL 填充；`/injected-bundle/` 长串先单独改），AppRun 再把随包
  helper 符号链到该路径 → bwrap 内外路径一致（helper 在进沙箱前 exec）
- **AppRun（bundled 版）**：`LD_LIBRARY_PATH` 只指随包目录、`WEBKIT_INJECTED_BUNDLE_PATH`、
  `GIO_EXTRA_MODULES`、`GDK_PIXBUF_MODULEDIR`、`GSETTINGS_SCHEMA_DIR`、`XDG_DATA_DIRS`
- **无宿主验证**（`scripts/linux/dev-appimage-e2e.sh`）：runtime 拼接 → 无 FUSE
  `--appimage-extract` → ①宿主基线 ②**掩掉宿主 WebKit** 再跑（docker 有镜像时用
  `--network none` 的 `ubuntu:22.04`；本机无镜像/无外网 → bwrap 掩 14 处宿主
  libwebkit/libjavascriptcore/helper，等价命名空间）→ 冒烟 95 项，LD_DEBUG 断言 252 次
  加载都命中 `squashfs-root`（随包）
- **体积实测**：AppDir 222MB → squashfs **88MB**（+78MB；WebKit 89MB + JSC 33MB + ICU，
  strip 无收益——发行版包本就已 strip）。**R7 的 +30–40MB 估计偏乐观**，发布说明按实测标注
- **顺带修复（实测暴露的三处既有缺陷，均在 GTK4 兼容层 WIP 范围内）**：
  ① **主 WebView 只分到 1px 高**——布局重构把 GtkOverlay 用 `gtk_box_pack_start(expand=0)`
  装进 GtkBox，窗口其余区域空白（截图快照 `800x1` 暴露）→ 新增 `boxPackStartFill`
  （expand+fill），reparent 路径同步从 overlay main-child 摘除后按 fill 装箱；
  ② **剪贴板写入未拷贝**——`allocSentinel` 后直接传 `z.ptr`，把未初始化内存写进剪贴板
  （读回乱码，`Error converting selection from UTF8_STRING`）→ `@memcpy(z, text)`；
  ③ **fs.readStream use-after-free**——`thread.detach()` 后仍读 `job.chunk_size`，
  小文件在 worker 释放后段错误（30KB 必现）；读失败路径双重释放 → spawn 前取局部副本、
  错误路径所有权交给 idle 回调。修复后 **Linux 冒烟 95/95 exit 0**（两条 L3 E2E 均严格断言）

**L4 [~]（2026-11-21）——ARM64 构建链（脚本 + CI 就绪，容器验收待 CI）**：

- `scripts/linux/build-arm64.sh`：
  - 默认 docker：`arm64v8/ubuntu:24.04` + QEMU binfmt → 容器内装
    `libgtk-3-dev libwebkit2gtk-4.1-dev libx11/xext-dev squashfs-tools` + aarch64 Zig
    0.17.1 → `zig build` + `zig build test` + `ZILT_BUNDLE_WEBKIT=1 zig build pack`
    （容器内 ldd 可用，随包与 x86_64 同路径）→ `dist-arm64/`；产物 chown 回宿主用户
  - `--sysroot DIR`：`PKG_CONFIG_SYSROOT_DIR`/`PKG_CONFIG_LIBDIR` + `-Dtarget=aarch64-linux-gnu`
    （host 版 pack 无法 ldd 外来架构 → 该路径不随包，自包含走 docker）
  - 预检 `--check`（打印将执行命令）；无 docker / 无镜像且 pull 失败 / 无 binfmt →
    `ARM64_BUILD=SKIP`（exit 3，不伪装成功）
- `scripts/linux/dev-arm64-e2e.sh`：`readelf` 断言 ELF machine=AArch64；优先
  `qemu-aarch64-static [-L sysroot]`，否则 arm64 容器；冒烟口径同 L3（失败白名单默认为空，
  任何失败都 FAIL；机制保留以备平台差异）
- CI：新增 `linux-arm64` job（`docker/setup-qemu-action@v3` + build + qemu 冒烟 + 产物上传）
- **本机限制**：WSL 无外网（registry/镜像站不可达），24.04 的 docker 29.1.3 与
  qemu-aarch64-static 8.2 均在位但无 arm64 镜像 → 容器路径如实 SKIP；已用
  `zig build-exe -target aarch64-linux-musl` + qemu 跑通 aarch64 二进制，验证执行器可用

目标：把 Linux 从「API 齐全」推进到「发行版可直接采用」——GTK4 默认、自包含 AppImage、
ARM64、包签名/AUR、托盘挂窗。这是 L 系列的主体，也是与 Wails v3.1 差距最集中的一段。

- **L1** GTK4 默认化 + 双栈构建（`-Dgtk=gtk3` 保留为 legacy 一个周期，CI 双 job）
- **L3 ✅** AppImage 自包含（WebKit 随包 + helper 路径改写；无宿主 WebKit 实测见上）
- **L4 [~]** ARM64 构建链（Docker+QEMU 脚本 / `--sysroot` 交叉 / CI job；本机无镜像 SKIP）
- **L5 ✅** RPM/AUR 实构建 + PGP 签名（deb `_gpgorigin` / rpm `--addsign`；`dev-sign-e2e.sh` 正反向校验）
- **L6 ✅** 托盘挂窗（见上：XEmbed 自建图标 / SNI 目标项、贴图标定位、去抖、FFM 规避）

**验收**：gtk3/gtk4 双栈单测 + Xvfb/openbox 冒烟全绿；AppImage 在「未安装 WebKit 的容器」
内启动并跑通冒烟（无 FUSE 走 extract 路径）；ARM64 deb/AppImage 在 qemu-user 下冒烟通过；
`gpg --verify` 校验 deb/rpm 签名；AUR `makepkg` 构建通过；托盘挂窗 X11 实测 +
Wayland 回退路径文档化；既有冒烟/单测全量回归（Windows 侧零回归）。

**v0.4.3 验收记录（2026-11-21，Windows 11 + WSL Ubuntu 22.04 / 24.04）**：

| 项 | 命令 | 结果 |
|---|---|---|
| Windows 单测 | `zig build test` | 386/387（1 skip） |
| GTK3 单测 | `zig build test`（22.04） | 303/304（285+18，1 skip） |
| GTK4 单测 | `zig build test -Dgtk=gtk4`（24.04） | 303/304（1 skip） |
| Linux 冒烟 | `scripts/linux/dev-smoke.sh` | **95/95 exit 0** |
| 托盘挂窗 | `scripts/linux/dev-tray-e2e.sh` | PASS（toggle / 贴图标定位 / 右键菜单 / FFM 共 12 断言） |
| AppImage 自包含 | `scripts/linux/dev-appimage-e2e.sh` | PASS：宿主 + 掩掉宿主 WebKit 各 **95/95**；LD_DEBUG 252 次命中随包 `libwebkit2gtk`；`SANDBOX_SUPPORT=no`（Ubuntu 构建无 bwrapinfo） |
| RPM 实构建 | `scripts/linux/pack-rpm.sh` | PASS：`app.zilt.desktop-0.4.3-1.x86_64.rpm`，载荷 3 项 + `%post` desktop db |
| AUR 包面 | `scripts/linux/pack-aur.sh` | PASS：`bash -n` + `.SRCINFO` 一致 + `package()` 模拟落地 3 文件；makepkg 跳过（无 Arch 镜像） |
| 包签名 | `scripts/linux/dev-sign-e2e.sh` | PASS：deb `_gpgorigin` Good signature 且 dpkg 可解析；rpm `--addsign` → `rpm -K` signatures OK；两项反向对照通过 |
| ARM64 构建链 | `build-arm64.sh --check` / `dev-arm64-e2e.sh` | 预检 PASS；容器路径 SKIP（本机无外网、无 arm64 镜像）；qemu-aarch64-static 已用交叉编译的 aarch64 二进制验证 |
| Windows GUI 冒烟 | `ZILT_SMOKE_EXIT=1` | 仅 echo-server 依赖项（ws/http2/wss/tus）失败，其余全 true（零回归） |

- **体积**：自包含 AppDir 222MB → squashfs **88MB（+78MB）**；R7 的 +30–40MB 估计已按实测修正
- **顺带修复**（L3 实测暴露的既有缺陷）：主 WebView 只分 1px（`boxPackStartFill`）、剪贴板写入缺
  memcpy、`fs.readStream` use-after-free —— 修复后 Linux 冒烟从 93/95 升到 **95/95 exit 0**
- **顺带修复**（L5 实构建暴露的打包缺陷，5 处）：
  ① **deb tar 条目名 use-after-free**——sidecar/resources/图标的名字在 `if`/`for` 块内
  `defer alloc.free`，块结束即回收，Zig 安全构建把内存填 0xAA → `dpkg-deb -c` 出现 58 字节
  乱码文件名（release 构建则可能静默截断）；改为 arena 托管，函数尾释放；
  ② **rpm spec 参数错位**——`Source0` 实际写的是 description、`%description` 写的是 exe 名；
  ③ **deb 与 postinst 桌面项名不一致**——装的是 `app.zilt.desktop.desktop`，`xdg-mime default`
  注册的是 `app.zilt.desktop`（深链默认程序实际未生效）；统一为 `app.zilt.desktop`；
  ④ **AppDir 从不清理**——11-15 的旧 `app.zilt.desktop.desktop` 仍被打进 squashfs/AppImage；
  打包前 `deleteTree`；
  ⑤ **架构硬编码**——`BuildArch: x86_64` / deb `_amd64` / PKGBUILD `arch=('x86_64')` 改为跟随
  `builtin.cpu.arch`（ARM64 产物名/元数据正确）
- **未完成项**：ARM64 容器内构建与 qemu 冒烟（CI `linux-arm64` job 待 remote 首次执行）、
  AUR `makepkg` 实跑（本机无 Arch 镜像/外网；`package()` 已按 makepkg 语义模拟验证）、
  WebKit 沙箱行为（Ubuntu 构建无 bwrapinfo，见 L3 行）、L1b（4.x UI 面移植）
- **已知 flake**：`platform.linux.hotkey` 的「真实抓键」用例在并发 Xvfb/残留显示下偶发
  X11 抓键失败（复跑即过，与版本无关）
- **坑位记录**：22.04 与 24.04 共用仓库 `zig-out/`，GTK4 构建会覆盖 GTK3 产物（表现为
  `libgtk-4.so.1: cannot open`）——验收前先确认最后构建的栈

### v0.4.4 — macOS 全栈 I（主链）✅ 完成（2026-11-22）

目标：窗口 + 资产 + IPC 主链跑通，且**无 Mac 硬件也能开发**（交叉编译 + CI 真跑）。

- `objc.zig`：msgSend 按签名转型、NSString/NSData/NSJSONSerialization、运行时创建
  ObjC 子类（`objc_allocateClassPair` + `class_addMethod/Protocol`）
- NSApplication（ActivationPolicy=Regular + `finishLaunching`）+ NSWindow（900×640、
  标题/置前、close→terminate）
- WKWebView + `WKURLSchemeHandler`（`zilt://app/...` 资产，复用 `asset_routes` 与
  `inflate`）+ `WKUserScript` 注入 `ipc.runtime_js`
- IPC：`WKScriptMessageHandler("zilt")`（JS→Zig，NSJSONSerialization 转 JSON）→
  `ipc.decode` → builtin/commands → `evaluateJavaScript("window.__ziltDeliver(...)")`
  （Zig→JS，Promise 语义）
- 冒烟：`ZILT_SMOKE_TEST_MS` 有界事件泵（NSDate deadline，不依赖 std 时间 API）+
  页面加载后注入 `greet` 探针（真实 command 往返）+ 日志锚点
- 构建闭环：`-Dtest-compile-only=true`（测试产物只编译）、`scripts/macos/check.sh`、
  `stubs/*.tbd`（libobjc + AppKit/Foundation 空桩）；`-Dtarget=aarch64-macos` 在
  Windows 上产出 arm64 Mach-O
- CI：`.github/workflows/macos.yml`（`macos-15` arm64）——build + test + 6s 冒烟 +
  `screencapture` 截图 artifact，六段日志断言
- 能力表：`.window` / `.ipc_events` / `.asset_server`

**验收记录（2026-11-22，Windows 11 + WSL Ubuntu 22.04；macOS 运行待 CI）**

| 项 | 命令 | 结果 |
|---|---|---|
| Windows 单测 | `zig build test` | 389/390（1 skip） |
| Linux 单测（GTK3） | `zig build test`（22.04） | 306/307（1 skip） |
| macOS 交叉编译（app） | `bash scripts/macos/check.sh` | PASS，arm64 Mach-O（0xfeedfacf） |
| macOS 测试产物编译 | `zig build test -Dtarget=aarch64-macos -Dtest-compile-only=true` | PASS |
| macOS 运行时冒烟 | CI `macos.yml` | 待首次 push（本机无 Mac） |

**macOS 能力对标与版本切片（Wails v3 / Tauri 2，2026-11 复核）**

| 能力面 | Wails v3 | Tauri 2 | Zilt 落点 |
|---|---|---|---|
| 应用生命周期 | `MacOptions.ActivationPolicy`、`ApplicationShouldTerminateAfterLastWindowClosed` | `RunEvent`、AppHandle exit/restart | v0.4.4 ✅（Regular）/ v0.4.5（Accessory·Prohibited、关窗策略） |
| 多窗口 | `app.Window.New()`（原生多窗口） | `WebviewWindow` | v0.4.5 |
| 窗口参数 | Width/Height/Min/Max/AlwaysOnTop/Frameless/HideOnFocusLost | width/height/min/max/alwaysOnTop/visible/decorations | v0.4.5 |
| 标题栏定制 | Window options（frameless 等） | `titleBarStyle`（Visible/Transparent/Overlay）、`hiddenTitle`、`trafficLightPosition` | v0.4.5 |
| 材质/透明 | BackgroundColour/translucency | `window-vibrancy`、`macOSPrivateApi`（透明） | v0.4.5（NSVisualEffectView；私有 API 只做 opt-in） |
| 窗口状态持久化 | —（应用自管） | `window-state` 插件 | v0.4.5 |
| Dock / 激活 | — | `set_badge_count`、dock 可见性 | v0.4.5 |
| 菜单 | `app.NewMenu()`（含标准 App/Edit/Window 菜单） | `Menu` + `PredefinedMenuItem` | v0.4.6 |
| 托盘 | `SystemTray`（Template 图标、`AttachWindow`） | `tray-icon` + menu | v0.4.6 |
| 对话框 | `Dialog.OpenFile/Save/Message` | `dialog` 插件 | v0.4.6 |
| 剪贴板 | `Clipboard` API | `clipboard-manager` | v0.4.6 |
| 通知 | `Notification`（含 actions） | `notification` 插件 | v0.4.6 |
| 全局快捷键 | `GlobalShortcut` | `global-shortcut` | v0.4.6 |
| 深链/单实例/自启 | 部分（v3 有 single instance 语义） | `deep-link` / `single-instance` / `autostart` | v0.4.6 |
| WebView 深度 | DevTools/Zoom/Evaluate/Print | devtools/eval/print/download/zoom | v0.4.7 |
| 拖放 | Drag&Drop（文件拖入/拖出） | `drag-drop` 事件 + 拖出 | v0.4.7 |
| 媒体/权限 | — | WebView 权限回调 | v0.4.7（摄像头/麦克风/屏幕录制） |
| 分发 | `.app`/DMG/universal/codesign/notarize | `dmg`/`universal-apple-darwin`/签名/公证 | v0.4.8 |
| 安全存储 | —（应用自管） | `stronghold`（非 Keychain） | v0.4.8（Security.framework Keychain，对齐 Linux `secret:`） |
| 更新器 | 内置 Updater（GitHub/keygen/Sparkle AppCast） | `updater`（appcast） | v0.4.8 |
| 自动化测试 | — | `tauri-driver` 仅 Win/Linux | v0.4.8（WebKit automation / safaridriver 选型） |
| 系统信息/Shell/电源/主题 | Environment / Shell / 主题跟随 | `os` / `opener` / `process` | v0.4.9 |
| 弹性项 | — | — | H18（WML）/ H19（扩展）/ H2（移动端）不进 v0.4.x |

### v0.4.5 — macOS 窗口与多窗口 ✅ 完成（2026-11-22）

目标：窗口能力对齐 Wails/Tauri 的 macOS 常用面。本版交付（均已在 macos-15-arm64 上以
冒烟硬断言取证）：

- 多窗口：`spawn_window_fn`；`wins` 表（主窗口 id 0，副窗 id ≥ 1）；每窗口独立
  WKWebView configuration / scheme handler / runtime 注入；IPC 按 `message.webView`
  解 window_id 路由，投递队列带目标窗；关窗只在最后一个窗口关闭时退出
- 窗口控制：`window_fn` 全量接线——set_title / minimize / maximize(zoom:) / restore /
  fullscreen(toggleFullScreen:) / size(setContentSize:) / position（左上原点 ↔ Cocoa
  左下原点换算） / show / hide / focus / close / always_on_top(setLevel:) / limits / state
- `window_query_fn`：与 Windows/Linux 同名字段的状态 JSON（含 min/max 尺寸）
- 标题栏与透明：`titlebar_overlay` → 摘 titled + FullSizeContentView +
  setTitlebarAppearsTransparent + hidden title + movableByWindowBackground；
  `transparent` → 关 opaque + 透明背景色

**验收**：`[macos] window ops ok=true`、`[macos] window spawn ok=true`、
`[macos] appearance ok=true` 三条 grep -qF 硬断言（macos.yml），任一不成立即红。

**顺延（决策 D10）**：`NSVisualEffectView` 材质、`NSAppearance` 明暗主题与主题变更事件、
Dock 徽标/激活策略、拖动区域命中、窗口事件面（moved/resized/focus/blur/close_requested）、
`window_state` 持久化 归入 v0.4.6，与桌面集成合并交付；编号不变。

### v0.4.6 — macOS 外观与窗口行为收尾 ✅ 完成（2026-11-22）

本版交付（macos-15-arm64 硬断言取证：vibrancy / theme / dock / state / drag 均 grep
-qF 强制）：

- 材质：`config.vibrancy`（sidebar/hud/window → AppKit 7/13/12），NSVisualEffectView
  垫在 webview 下、关 opaque
- 明暗主题：`effectiveAppearance` 读写 + 循环比对发 `themeChanged{appearance}`
- Dock：`dockTile` 徽标读写
- 窗口事件面：windowMoved / windowResized / windowFocus / windowBlur（didMove/
  didResize/didBecomeKey/didResignKey，注意入参是 NSNotification）
- window_state：`$HOME/.zilt-window-<app_id>.json` 存 frame，创建时 setFrame:display: 恢复
- 拖动区域：`data-zilt-drag-region` → runtime startDragging → `.start_dragging`
  → performWindowDragWithEvent:（只认真实 leftMouseDown；CI 仅验接线，实际拖动需人工）

### v0.4.7 — macOS 桌面集成

> 含自 v0.4.5 顺延的外观与窗口行为收尾（材质/明暗主题/Dock/拖动区域/事件面/状态持久化）。

目标：系统集成能力面对齐 Windows/Linux 已有面。

- 菜单：`NSMenu` 应用菜单（About/Services/Hide/Quit + Edit/Window 标准角色）、
  上下文菜单、Cmd 快捷键（key equivalent）、菜单事件回传
- 托盘：`NSStatusItem`（Template 图标、菜单、点击）、`AttachWindow`（菜单栏弹窗）
- 对话框：`NSOpenPanel`/`NSSavePanel`/`NSAlert`（文件/文件夹/多选/消息）
- 剪贴板：`NSPasteboard`（文本/图片/HTML/文件列表，读写与变化事件）
- 通知：`UNUserNotificationCenter`（授权、actions、进度/替换、点击深链）
- 深链：`CFBundleURLTypes` + `application:openURLs:`；单实例：LaunchServices reopen
  + 本地 socket 转发；自启：`SMAppService`（macOS 13+）/ LaunchAgent 回退
- 全局快捷键：Carbon `RegisterEventHotKey`（含 Accessibility 权限状态与引导）

**验收**：菜单/托盘/对话框/剪贴板/通知/快捷键逐项冒烟（需交互的用脚本化 UI 或
单元测试替代）+ 深链/单实例/自启在 CI 上脚本化验证。

### v0.4.8 — macOS WebView 深度

目标：补齐 WebView 行为面（下载/打印/截图/缩放/拖放/权限）。

- DevTools：`WKWebView.inspectable`（DEBUG 构建）+ 独立窗口
- 缩放：`pageZoom` 读写；`window.zilt.webview.zoom/getZoom`
- 打印：`NSPrintOperation`（WebKit 打印视图）；PDF 导出（`createPDF`）
- 下载：`WKDownloadDelegate`（目标路径、进度、完成/失败事件）
- 截图：`takeSnapshotWithConfiguration:completionHandler:` → PNG 回传
- Cookie/数据分区：`WKHTTPCookieStore`、`WKWebsiteDataStore`（非持久分区对齐
  `data_partition`）
- 自定义协议：`config.protocols` → 动态注册 scheme handler（对齐 Linux v0.2.3）
- JS 对话框：`WKUIDelegate`（alert/confirm/prompt）→ 前端事件或原生面板
- 拖放：`NSDraggingDestination`（文件拖入 → drag-drop 事件）、`NSDraggingSource`
  （拖出，对齐 `startDrag`）
- 媒体权限：`WKUIDelegate requestMediaCapturePermission` + TCC 说明（Info.plist
  用途字符串 + entitlements）
- 查找：`findString:withConfiguration:completionHandler:`（对齐 find_in_page）

**验收**：下载/打印/截图/缩放/拖放/权限各自冒烟；截图与 PDF 产物上传 artifact。

### v0.4.9 — macOS 分发、安全与更新

目标：可分发（签名/公证/DMG/universal）+ 安全存储 + 更新器。

- `.app`：Info.plist 全字段（bundle id/版本/URL types/LSMinimumSystemVersion/
  NSHighResolutionCapable/用途字符串）+ `.icns`
- DMG：`hdiutil`（含 Applications 链接；背景/布局后置）
- 签名：codesign（Developer ID Application、hardened runtime、entitlements、
  `--deep` 校验）；公证：`notarytool submit --wait` + `stapler staple`
- Universal：x86_64 + arm64 双构建 + `lipo`（需 macOS 宿主）
- 安全存储：Security.framework Keychain（`kSecClassGenericPassword`，与 Linux
  libsecret 的 `secret:` 标记同语义）
- 更新器：Zilt 现有 ed25519 清单 + DMG 替换/Sparkle appcast 选型（对齐 Wails
  Updater 的 Sparkle AppCast provider）
- WebDriver：safaridriver / WebKit automation 可行性验证（Tauri 的 tauri-driver
  不支持 macOS，需自建桥）

**验收**：`codesign --verify --deep --strict` + `spctl -a -vv` + `stapler validate`；
DMG 挂载安装；更新器端到端（旧版→新版）；Keychain 单测。

### v0.4.10 — macOS 对等与打磨

目标：平台能力与 Win/Linux 对齐收口 + 文档/CI 矩阵。

- 系统信息（sysctl/IOKit）、Shell（`NSWorkspace open`）、电源事件（sleep/wake）、
  主题（系统明暗）、单实例边缘情况（多用户/快速重启）
- Accessibility 标签、菜单快捷键冲突检查、VoiceOver 基本可用性
- 文档：能力矩阵平台列、差异项（透明/私有 API、沙箱、App Store 限制）
- CI：`macos-15`（arm64）为主；`macos-15-intel` 仅到 2027 前做 x86_64 回归
  （GitHub 已宣告 Intel 镜像退役路径）

**验收**：macOS 冒烟与 Linux 95 项按平台差异对齐（差异项 skip 且文档化）；
全部单测 + 冒烟 + 打包链在 CI 绿。

### v0.5+ — 弹性/实验位（不排期）

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

1. `zig build test`（基线：Windows 386 / Linux 303，随功能递增；0 失败 0 泄漏）
2. `zig build`（构建 + capability 清单 + 资产嵌入）
3. GUI 冒烟（基线：Windows 74 / Linux 95 项；新增能力必须带检查项，exit 0）
4. 触碰面专项：headless/MCP E2E、server E2E、PACK_E2E、e2e_fixed_runtime
5. **Linux 双栈（v0.4.3 起）**：`-Dgtk=gtk3` 与 `-Dgtk=gtk4` 各跑单测 + Xvfb/openbox 冒烟；
   签名与 AUR 见第 8 条；Windows 侧零回归
6. **托盘挂窗（L6 起）**：`scripts/linux/dev-tray-e2e.sh`（Xvfb+openbox+stalonetray，
   XTest 合成点击；`scripts/linux/xtool.py` 无 xdotool 依赖）——toggle/定位/右键菜单/FFM 四组断言
7. **AppImage 自包含（L3 起）**：`dev-appimage-e2e.sh`（`ZILT_BUNDLE_WEBKIT=1` + runtime 拼接 +
   无 FUSE extract + docker/bwrap 掩宿主 WebKit）——冒烟 + LD_DEBUG 随包命中
8. **包面与签名（L5 起）**：`pack-rpm.sh`（rpmbuild -bb + 载荷断言）、`pack-aur.sh`（PKGBUILD/.SRCINFO
   一致性 + `package()` 模拟）、`dev-sign-e2e.sh`（deb/rpm 签名 + Good signature + 反向对照）
9. **ARM64（L4 起）**：`build-arm64.sh`（docker+QEMU 或 `--sysroot`）+ `dev-arm64-e2e.sh`
   （qemu-aarch64-static / arm64 容器 + ELF machine 断言 + deb/rpm 架构名核对）；CI `linux-arm64` job
10. macOS 切片自建验收链（v0.4.4 起）：zig build test macOS + 冒烟骨架 + codesign 产物验证

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
- **R7（L3 AppImage 自包含）**：✅ 实测结论（2026-11-21）——①体积 **+78MB**（squashfs 88MB），
  R7 原估 +30–40MB 偏乐观（WebKitGTK 2.52 的 libwebkit 89MB + JSC 33MB + ICU，已 strip 无收益）；
  ②WebKit 2.52 **无 `WEBKIT_EXEC_PATH`**，helper 路径是编译期常量，必须等长改写为固定短路径
  （`/tmp/.zk-<hash>`）再由 AppRun 建链——这是自包含的唯一可行路径，改写点已收敛在
  `pack_formats.patchCStringInPlace`（有单测）；③bwrap 沙箱与随包 helper：helper 在进沙箱前
  exec，injected-bundle 走 `WEBKIT_INJECTED_BUNDLE_PATH`，实测通过（E2E 关闭 WebKit 沙箱跑冒烟，
  真机沙箱路径另测）
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
