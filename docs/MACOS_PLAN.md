# macOS 功能实施计划（v0.4.5–v0.4.9）

> 制定：2026-11-22。依据：Wails v3 / Tauri(wry+tao) 源码精读 + v0.4.4 主链实测。
> 参考源码浅克隆在 `.zilt-probe/vendor/`（gitignored；重建命令见文末），**不入库**。
> 版本切片与验收口径见 `ROADMAP.md` §v0.4.5–v0.4.9；本文是其工程展开。

## 0. 参考源码地图（已核对，selector 均来自实测 grep）

| 参考库 | 位置 | 为什么有用 |
|---|---|---|
| **wailsapp/wails** | `v3/pkg/application/*_darwin_purego.go` | purego 路线 = 纯 `objc_msgSend` 字符串调用，**与我们 Zig 路线同构**，可直接当 selector 字典抄语义（免 CGO 版是后来者，最贴近） |
| **tauri-apps/wry** | `src/wkwebview/` | WebView 行为面全集：自定义协议/下载/导航/UI 委托/拖放/私有 inspectable |
| **tauri-apps/tao** | `src/platform_impl/macos/` | 窗口/事件循环/委托事件面（`window_delegate.rs` 2063 行，事件最全）；菜单拆到了 `tauri-apps/muda` |

关键文件清单（实现前先读）：

- 窗口样式：`wails/.../webview_window_style_darwin_purego.go`（139 行，titlebar 三态）
- 窗口全量：`wails/.../webview_window_darwin_purego.go`（1852 行：setStyleMask/toggleFullScreen/setLevel/setFrame/zoom:/setMagnification/evaluateJavaScript/setTitleVisibility…）
- 私有 API：`wails/.../mac_private_api_darwin_purego.go`（NSVisualEffectView 材质等）
- 托盘：`wails/.../systemtray_darwin_purego.go`（581 行：`statusItemWithLength:`、`setTemplate:`、`setMenu:`、mouseDown 本地监听、menuDidClose、贴图标 setFrame）
- 对话框：`wails/.../dialogs_darwin_purego.go`（542 行；**Zig 用 `runModal` 同步版，避开 completion block**）
- 剪贴板：`wails/.../clipboard_darwin_purego.go`（58 行，NSPasteboard 直译）
- 通知：`wails/v3/pkg/services/notifications/notifications_darwin_purego.go`（UNUserNotificationCenter + 授权 + actions）
- 快捷键：`wails/.../global_shortcut_darwin.go`（Carbon `RegisterEventHotKey` 语义）+ `autostart_darwin_smappservice.go`（SMAppService）
- WebView 深度：`wry/src/wkwebview/class/*`（`wry_web_view.rs` 的 `_inspectable`/`pageZoom`/`takeSnapshot`/`createPDF`/`NSPrintOperation`/`WKDownload`×19、`url_scheme_handler.rs`、`wry_download_delegate.rs`、`wry_web_view_ui_delegate.rs`、`drag_drop.rs`）
- 窗口事件：`tao/src/platform_impl/macos/window_delegate.rs`（didMove/didResize/didBecomeKey/resignKey/shouldClose…）

## 1. 基建先行（objc.zig v2，v0.4.5 开工前完成）

1. **最小 Block 支持**：`_NSConcreteStackBlock` + `invoke` + `descriptor` 的 Zig 结构体
   ——`takeSnapshot`/`createPDF`/`evaluateJavaScript` 回调必须传块；WKDownloadDelegate
   等**收进来的块**按内存布局直接调用（block 首 16 字节：isa、flags+reserved，偏移 16
   是 invoke 函数指针）。`_NSConcreteStackBlock` 加进 Foundation 桩 tbd 的符号表。
2. **autorelease pool**：手动事件泵每轮 `objc_autoreleasePoolPush/Pop`——
   `dateWithTimeIntervalSinceNow:` 等返回 autoreleased 对象，现在每 50ms 泄一个，
   长跑应用必须修（libobjc 自带这两个 C 函数，无需新桩符号）。
3. 便捷封装：NSString/NSData/NSDictionary↔JSON、NSError 读取（现有 jsonFromId 泛化）。
4. 测试策略：纯逻辑（加速键解析、路径映射、事件分类）放跨平台单测；ObjC 行为一律
   走 CI 冒烟日志断言（现有六段锚点的模式延续）。

## 2. v0.4.5 窗口与多窗口 / v0.4.6 外观与窗口行为收尾 / v0.4.7 桌面集成 / v0.4.8 WebView 深度

| 能力 | 参考 | 关键 selector / 方案 | 验收（CI 日志锚点） |
|---|---|---|---|
| 多窗口 | tao `window.rs` 多实例 | `Backend.inst` → `windows: HashMap(u32, *WinState)`；`spawn_window_fn`/`windowById` | `newWindowDemo` 往返 + 两窗口标题断言 |
| 窗口控制全量 | tao `window.rs` | `setFrame:`/`setStyleMask:`/`toggleFullScreen:`/`miniaturize:`/`orderFront:`/`setIsVisible:`/`center` | windowControlDemo 各 action 探针 |
| 标题栏三态 | wails `webview_window_style_*`（139 行） | standard / transparent（`setTitlebarAppearsTransparent:`+`setTitleVisibility:`）/ overlay（styleMask 摘 titled + 红绿灯 `setFrameOrigin:`） | 三种样式截图 artifact |
| 拖动区域 | tao `window.rs`（`mouseDownCanMoveWindow`） | `data-zilt-drag-region` → 命中测试 + `performWindowDragWithEvent:` | 冒烟拖动（XTest 不可用 → 合成 mouseDown + 位移断言 didMove） |
| 材质/透明 | wails `mac_private_api_*` | NSVisualEffectView（blendingMode/material）+ `setOpaque:NO`；透明默认关（App Store 约束） | 截图对比 |
| 明暗主题 | tao `window_delegate.rs`（effectiveAppearance） | `NSApp appearance` 读写 + KVO 观察事件 `themeChanged` | 主题切换事件探针 |
| Dock | tao `dock.rs`/`badge.rs` | `setBadgeLabel:`/dock 隐藏（activation policy） | 徽标往返 |
| 窗口事件面 | tao `window_delegate.rs`（2063 行） | 自建 ZiltWindowDelegate 扩方法：didMove/didResize/didBecomeKey/didResignKey/windowShouldClose（可否决 → close_requested 事件） | 事件计数（对齐 events 命名空间） |
| 窗口状态持久化 | Zilt 已有 `window_state.zig`（Linux 同源） | macOS 侧 frame 读写接线 | 重启恢复 frame |

## 3. v0.4.7 桌面集成

| 能力 | 参考 | 方案 |
|---|---|---|
| 应用菜单 | muda（tauri 菜单库）+ wails `menuitem_selectors_darwin_purego.go` | NSMenu/NSMenuItem；标准角色（About/Hide/Quit 用系统 selector `orderFrontStandardAboutPanel:` 等零代码）；`keyEquivalent` Cmd 组合 |
| 上下文菜单 | wails `menu_darwin_purego.go` | WKWebView `menuForEvents:` 不可控 → 右键事件 + `NSMenu popUpMenuPositioningItem:` |
| 托盘 | wails `systemtray_darwin_purego.go`（581 行，同构直译） | NSStatusBar `statusItemWithLength:`、Template 图标、菜单、点击；`AttachWindow`：mouseDown 监听 + 图标 frame 换算贴窗（Linux L6 同语义） |
| 对话框 | wails `dialogs_darwin_purego.go` | **`runModal`**（同步、主线程自带嵌套 runloop）——不走 completion block；NSOpenPanel/NSSavePanel/NSAlert |
| 剪贴板 | wails `clipboard_darwin_purego.go`（58 行） | NSPasteboard general；文本先行，多格式随后 |
| 通知 | wails `services/notifications/notifications_darwin_purego.go` | UNUserNotificationCenter（授权请求、actions、进度替换）；bundle 缺失时降级明文日志 |
| 全局快捷键 | wails `global_shortcut_darwin.go`（Carbon） | extern Carbon `RegisterEventHotKey`/`InstallEventHandler`（stub tbd 增 Carbon 符号）；无 Accessibility 权限需求 |
| 深链 | wails `single-instance-url-scheme` 示例 | Info.plist `CFBundleURLTypes`（pack 面已有 plist 生成）+ `application:openURLs:` 委托（runtime class 加方法） |
| 单实例 | Zilt 已有跨平台实现 | macOS 激活已跑实例（NSWorkspace/本地 socket 转发 argv） |
| 自启 | wails `autostart_darwin_smappservice.go` | SMAppService（macOS 13+）为主，LSSharedFileList 回退 |

## 4. v0.4.8 WebView 深度（wry 对标）

| 能力 | 参考（wry） | 方案与风险 |
|---|---|---|
| DevTools | `wry_web_view.rs` 用 `_inspectable:`（私有） | 双路：macOS 13.3+ 公开 `setInspectable:`；回退私有 setter（默认 DEBUG 构建才开，App Store 风险文档化） |
| 缩放 | `pageZoom` | get/set + `window.zilt.webview.zoom` 接线（Linux 同名 API） |
| 打印/PDF | `NSPrintOperation` / `createPDF` | createPDF 需 Block（基建 §1.1）；产物回传事件 |
| 下载 | `wry_download_delegate.rs`（WKDownload×19） | WKDownloadDelegate 协议类；`decideDestination...completionHandler:` **调用传入块**（不必自建块）；进度/完成/失败事件 |
| 截图 | `takeSnapshotWithConfiguration:` | 需 Block → NSBitmapImageRep → PNG → artifact |
| Cookie/数据分区 | wry cookies 面 | WKHTTPCookieStore 读写；`WKWebsiteDataStore` nonPersistent 对齐 `data_partition` |
| 自定义协议 | `url_scheme_handler.rs` | 现有 ZiltSchemeHandler 泛化：`config.protocols` 逐协议注册（Linux v0.2.3 同语义） |
| JS 对话框 | `wry_web_view_ui_delegate.rs` | WKUIDelegate 三件套（alert/confirm/prompt）→ 原生 NSAlert |
| 拖放 | `drag_drop.rs` | `registerForDraggedTypes:` + NSDraggingDestination → drag-drop 事件；拖出 NSDraggingSource（对齐 `startDrag`） |
| 媒体权限 | wry permission 回调 | `requestMediaCapturePermission` + Info.plist 用途串（NSCameraUsageDescription…） |
| 页内查找 | — | `findString:withConfiguration:completionHandler:`（macOS 11+，Block） |

## 5. v0.4.9 分发与安全（要点）

- `.app`/DMG：`zilt-pack` 已有 Info.plist 生成（`generateInfoPlist`）→ 补 `.icns`、
  `CFBundleURLTypes`、用途串；DMG 走 `hdiutil`（CI macos-15 可跑）
- 签名/公证：codesign（Developer ID + hardened runtime + entitlements）→
  `notarytool submit --wait` + `stapler`；Wails v3.1 Signing 指南为流程参考；
  **无证书时 CI 只做 ad-hoc + 产物上传**（secrets 缺省跳过——已有 `env.*` 判断模式）
- Universal：x86_64 + arm64 双构建 + `lipo`（CI 两个 job 或 macos-15 单机双 target）
- Keychain：Security.framework（`kSecClassGenericPassword`），对齐 Linux `secret:` 标记
- 更新器：Zilt 现有 ed25519 清单 + DMG 替换 vs Sparkle appcast——**决策点**，实施前出 ADR
- WebDriver：safaridriver 可行性验证（Tauri 的 tauri-driver 不支持 macOS）

## 6. CI 扩展（随切片推进）

- `macos.yml` 每切片新增日志锚点断言（现有六段锚点模式延续）；失败自动 tmate
  会话已备（`action-tmate`，failure 触发）
- 冒烟探针 `probe_js` 逐切片扩展：先窗口 API 往返（v0.4.5）→ 托盘/菜单存在性（v0.4.6）→
  截图/下载产物上传（v0.4.7）
- Linux ARM64：`ci.yml` `linux-arm64` job 已在跑（QEMU 容器路径），结果回填 ROADMAP L4

## 7. 风险与既定决策

1. **手搓 Block** 是最大技术风险：先在 CI 用 `takeSnapshot` 最小用例验证 Block ABI，
   再铺开到 PDF/下载。
2. **私有 API**（`_inspectable`、透明/材质的 macOSPrivateApi 等价面）：默认关、
   opt-in 显式开启；App Store 分发前复核（对齐 Tauri 的立场）。
3. **runModal 嵌套**：NSApp runModal 自带嵌套 runloop，与我们的手动泵兼容
   （冒烟模式下弹对话框会阻塞探针——冒烟脚本避免触发对话框命令）。
4. **Carbon 已 deprecated 但可用**：RegisterEventHotKey 是唯一无权限的全局快捷键路径
   （Wails 同款）；AddGlobalMonitor 需辅助功能权限，不做默认。
5. Wails 的 purego 后端本身是实验特性——抄语义时以 tao/wry 的成熟实现交叉验证。

---

参考源码重建（vendor 目录 gitignored）：

```bash
mkdir -p .zilt-probe/vendor && cd .zilt-probe/vendor
git -c http.proxy=http://127.0.0.1:7897 clone --depth 1 https://github.com/wailsapp/wails
git -c http.proxy=http://127.0.0.1:7897 clone --depth 1 https://github.com/tauri-apps/wry
git -c http.proxy=http://127.0.0.1:7897 clone --depth 1 https://github.com/tauri-apps/tao
```
