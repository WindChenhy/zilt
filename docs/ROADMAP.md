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
      - [x] 构建工具链跨平台化（2026-11-12）：`frontend_codegen` 的 Win32 遍历/读写 →
            `std.Io.Dir`（walk/readFileAlloc/writeFile/createDirPathStatus/deleteTree，路径统一 `/`）；
            `log.zig` 的 Win32 追加写/轮转 → `Io.File.Writer`（positional + 显式定位末尾）+ `Io.Mutex`；
            `tools/tests.zig` 按 OS 裁剪（`init`/`win_env`/`win_res` 暂限 Windows）。
            **Linux（Ubuntu 22.04 / WSL2）`zig build test` 5/5 通过**；Windows 冒烟 49 项 exit 0。
      - [x] `build.zig` 按 OS 裁剪（2026-11-13）：`target.result.os.tag` 判定 + `linkWindowsLibs`
            收敛六库链接 + `windowsOnlyStep`（非 Windows 上 step 保留名字、执行即给出原因）。
            Windows 专用 exe（cli/driver/dev/bundle/keygen/sign/diff/pack/init）不再链接
            shell32/bcrypt，也不参与默认 install；`capabilities` 清单同样不挂默认 install
            （否则会编译同一份 `zilt_mod`、遮蔽真正的后端报错）。`frontend.build_command`
            在非 Windows 上改用 `sh -c`。
            **结果**：Linux `zig build` 只走 `install → zilt-app` 一条链，报错即
            `platform/linux/backend.zig` 的「Linux 后端尚未实现」；`zig build test` 仍全绿；
            `zig build doctor` 打印依赖 Win32 的原因与 v0.2 计划。Windows 侧产物与之前完全一致。
      - [x] `init.zig` 移植到 std.Io（v0.2.8：模板脚手架跨平台；Linux 工具测试同步放开）
      - [x] Linux 后端实现（GTK3 + WebKit2GTK 4.1）：v0.2.1–v0.2.7 全链路
      - [x] `zilt doctor` Linux 依赖检查（v0.2.8：pkg-config gtk+-3.0/webkit2gtk-4.1 +
            xvfb-run/xdg-open/mksquashfs；Windows 检查项平台分派保留）
- [x] **v0.2.1 窗口/WebView 面**（2026-11-13；Linux 侧四切片，平台无关层零改动）：
      - [x] 切片 1 窗口 API（3c330b9）：`window_fn`/`window_query_fn` 全套基础动作；
            未实现项返回 false（错误语义对齐 Windows）；冒烟 9 → 20 项
      - [x] 切片 2 WebView 面（761d165）：`webview_request_fn`（reload/stop/zoom/
            history/devtools/set_user_agent/eval）+ `eval_async_fn`；eval 同步走
            嵌套 GMainLoop（对应 Windows SyncWait）；冒烟 20 → 26 项
      - [x] 切片 3 多窗口 + 子 WebView + 数据分区：窗口注册表（id 从 1 起，全部
            钩子/ACL 按 window_id 路由）；`spawn_window_fn`（GTK 属性映射 +
            transient-for/modal + 父销毁级联）；**所有窗口销毁才 gtk_main_quit**；
            `system_fn` 接通 `.webviews`（create/remove/navigate/setBounds/focus/
            list/eval 异步回传），其余 op NotSupported；子 WebView GtkOverlay 布局 +
            分区（独立 WebKitWebsiteDataManager，同名复用）+ IPC 按 sender 路由；
            冒烟 26 → 33 项（多窗口 E2E + alpha/beta 分区隔离 + 同分区复用 +
            共享 context 互通），逐项检查落 Zig 日志
            （踩坑与验证记录见 `docs/v0.2-LINUX.md` §v0.2.1 实施记录）
      - [x] 切片 4（2026-11-13）WebView 数据面 + 窗口状态持久化：
            **下载**（WebKitWebContext::download-started → save_directory >
            show_dialog 原生保存框 > $HOME/Downloads；重名追加 " (n)"；received-data
            32KB 节流 / finished / failed → `webview.download_*` 事件，payload 与
            Windows 同形；cancel_download 未知 id → UnknownDownload；
            **实测坑**：失败后 WebKit 还会补发 finished，必须在终止事件里
            `g_signal_handler_disconnect` 三个处理，否则二次进回调 UAF）、
            **cookies**（WebKitCookieManager get/set/delete/按域名清理，异步 API
            用嵌套 GMainLoop 同步化，返回 `{"cookies":[…]}`）、
            **clear_storage**（WebKitWebsiteDataManager::clear，本版为全来源超集）、
            **截图**（无 CDP → 仅 `Page.captureScreenshot`，webkit_web_view_get_snapshot
            + cairo PNG + base64 → `webviewCdp` 事件，runtime 的 captureScreenshot
            零改动）、**窗口状态持久化**（`platform/linux/window_state.zig`，目录/格式/
            SHA-256 文件名与 Windows app_data 一致；state_key / persist_window_state
            创建时恢复、销毁时保存，`windowState.get/save` 经 system_fn）；
            冒烟 33 → **40 项 exit 0**
      - [ ] print（P2）：Linux 仍 NotSupported——WebKit 打印 UI 走 GTK PrintOperation，
            规划随 v0.2.5 稳定化补齐（能力清单里本来就列为 P2）
- [x] **v0.2.2 系统集成**（2026-11-13/14 完成；Linux 侧两批全部落地）：
      - [x] **剪贴板**：文本 / HTML / 文件列表 / 图片读写（GTK 剪贴板；HTML 与
            URI 列表走延迟提供）；`clipboard_change_event` → `clipboardChanged`
      - [x] **原生对话框**：消息框 / 打开 / 保存 / 选文件夹 / 多选 / 颜色 / 字体
            （GtkFileChooserNative，有 portal 时走 portal；字体用 Pango 解析）
      - [x] **通知**：GApplication + GNotification（tag 替换）；无 D-Bus 总线时
            降级 `disabled_for_application`，不阻断启动
      - [x] **菜单栏**：config.menu → 每窗口 GtkMenuBar；叶子 activate → `menu` 事件
            {id}；无 id 叶子置灰；accel 挂 GtkAccelGroup（展示+触发）；role →
            WebKit 编辑命令 + menuRole 事件（delete → execCommand）
      - [x] **托盘**：libayatana-appindicator3 **dlopen 可选依赖**（缺失仅日志）；
            菜单构建与 indicator 解耦——运行时菜单模型驱动托盘菜单
      - [x] **单实例 + 深链**（第二批，2026-11-14）：GApplication 唯一 ID
            （HANDLES_COMMAND_LINE，先注册再建窗口）——主实例 g_application_run
            （command-line 信号承载深链/聚焦，显式 hold 防 command-line 处理完即退）；
            第二实例远端命中后转交 argv → **exit 5**（对齐 Windows）；`deepLink`
            {url,files} 事件经 pending_launch 在页面就绪后补发（loaded 守卫防丢）；
            注册 = 应用级 `.desktop`（x-scheme-handler + 文件 MIME）+ `xdg-mime
            default`（缺失仅日志）；无 D-Bus 降级为本地解析启动参数 + gtk_main。
            新模块 `deep_link.zig`（参数分类/转交载荷/XDG 目录，注入式 exists 可测）
            + `desktop_entry.zig`（.desktop 生成/自启动状态解析）
      - [x] **运行时菜单模型**（第二批）：`menu_model`（config.tray.menu 初始化，
            与 Windows 同构）→ `menu.*` op（list/add/remove/set → 整树重建托盘菜单
            + popup at rect，无 libayatana 也可用）；勾选项用 GtkCheckMenuItem
      - [x] **拖放**（第二批）：主 WebView 挂 drag dest——drag-drop 拦截 WebKit
            默认文件导航 + drag-data-received 解析 text/uri-list → `dropFiles`
            {files}；解析 `parseDropUris` 纯函数单测；冒烟经 `__zilt.linuxSmokeDrop`
            模拟投递覆盖事件链路
      - [x] **自启动/系统信息**（第二批）：`~/.config/autostart/<app_id>.desktop`
            （autostart.* op，enable 写条目/disable 删文件/query 解析 Exec 匹配）；
            `system.info` = /etc/os-release + locale 推导 + GTK 主题深色判定 +
            GDK 显示器枚举（JSON 与 Windows 同构；新模块 `sysinfo_linux.zig`）
      - [ ] print（P2）：Linux 仍 NotSupported——WebKit 打印 UI 走 GTK PrintOperation，
            规划随 v0.2.5 稳定化补齐（能力清单里本来就列为 P2）
- [~] **v0.2.3 安全与数据**（2026-11-14 完成）：capability/scope 在 Linux 侧全链路生效
      （fs/http/shell 执行点统一 `aclAllowed`，运行时授权 `window.zilt.acl` 落盘
      acl.json 重启生效）；store（KV + store.json）；`Config.protocols` → **真
      scheme**（每协议一个 scheme `<name>://…`，CORS 允许 + Expose-Headers）；
      fs watch（inotify，`fs_watch.zig`：递归子目录动态补挂 + 自管道停止）/
      流式读（fsChunk base64）；SQL（libsqlite3 dlopen，`sqlite.zig` 与 Windows
      版同构：行集 JSON/{changes,last_id}/事务迁移）；http/ws/wss（libsoup3：
      SoupSession 每请求建（对齐 WinHTTP），proxy/超时/忽略证书/重定向开关/
      multipart，流式 httpChunk，WebSocket 事件 open/message/close/error）；
      CSP 注入（scheme 响应带 CSP/security.headers，v0.2.1 已就位）。
      **验收**：冒烟 48 → **57 项** exit 0（store/fs 12 ops/fs.acl 拒绝→授权→
      撤销/fs.watch+readStream/sql 迁移+查询/http 拒绝+echo 往返/ws 拒绝路径/
      真 scheme echo·json·bin fetch）；有/无 D-Bus 双环境 + 单实例转交 E2E 全过；
      Windows 冒烟 47/49（clip/clipmulti 因桌面剪贴板被外部进程占用——
      PowerShell Set-Clipboard 同样失败，环境问题非代码回归；Windows 代码零改动）。
- [x] **v0.2.4 打包与 CI**（2026-11-14）：`zig build pack`（Linux 目标）→ **真实
      .deb**（ar 包：Depends libgtk-3-0/libwebkit2gtk-4.1-0/libsqlite3-0 + postinst
      xdg-mime 注册深链 + /usr/share/applications 桌面项 + hicolor 256 PNG 图标）
      + **AppDir**（AppRun 可直接执行 + usr/bin + metainfo）+ **真实 squashfs**
      （mksquashfs；单文件 AppImage 需官方 runtime，附 build-appimage.sh）+
      Flatpak manifest（org.gnome.Platform）+ rpm spec。**打包 E2E 实测**
      （scripts/linux/dev-pack-e2e.sh）：dpkg-deb --info/-x 提取运行 → 冒烟
      57/57 exit 0；AppDir AppRun 冒烟 57/57 exit 0；squashfs 2.4MB。
      GitHub Actions 增 **linux job**（ubuntu-22.04 + Xvfb 冒烟 + 打包产物上传）；
      附带修复：**ReleaseSafe 链接误报 dl* 符号**（libgmodule 依赖 dlopen 系列，
      glibc 2.34+ 并入 libc——`linker_allow_shlib_undefined = true`）；
      pack_formats 单测此前从未被编译执行（root.zig 补引用 + 修正与实现脱节的
      断言）。Flatpak manifest 为静态产物（flatpak-builder 实测留待有环境的 CI）。
- [~] **v0.2.5 GTK4 变体与稳定化**（2026-11-14）：**print 实装**（P2 兑现——
      WebKitPrintOperation 原生打印对话框，browser=对话框/system=NotSupported，
      模态交互冒烟不覆盖）；**`-Dgtk=gtk4` 构建选项**（pkg-config 切换 gtk4 +
      webkitgtk-6.0；22.04 无 6.0 dev 包 → pkg-config 可读报错；完整 GTK4 后端
      需 24.04+ 环境）+ **gtk_compat.zig**（编译期按 `gtk_init` 参数个数判定
      变体 + gtkInit/menuBarAvailable 适配 + 差异清单文档）；**性能基线**
      （scripts/linux/dev-perf.sh，ReleaseSafe：构建缓存 3.4s、冒烟全程
      ~8.4s、峰值 RSS ~215MB，2026-11-14 记录）。Wayland 实测/输入法/无障碍
      仍在清单上（需桌面会话环境）。
- [x] **v0.2.6 Linux 收尾**（2026-11-14）：**窗口事件面**——windowMoved/
      windowResized（configure-event 去重上报）+ windowFocus/windowBlur
      （focus-in/out）+ **windowCloseRequested**（delete-event 拦截；
      per-window `closeRequested` opt-in（`window.create({closeRequested})`，
      两平台同接——Windows 的 WM_CLOSE 判断复用同一字段）+ 冒烟模式主窗口
      自测「拦截 → 存活」闭环）；**X11 全局快捷键**（`hotkey.zig`：XGrabKey
      + 事件线程，BadAccess 经 XSetErrorHandler 计数检测——XGrabKey 返回值
      实测非状态码；lock 组合全抓取；config.hotkeys 启动注册 + hotkey.* op，
      冒烟 register→list→unregister 实测）；CI apt 列表补 libx11-dev。
      未做（如实记录）：headless 服务 / WebKitWebDriver E2E（Linux）——留待
      后续；windowMoved/Resized/Focus/Blur 的冒烟断言需 WM（Xvfb 无 WM 不触发
      configure/focus，实现与桌面同代码路径）。
      **测试补齐（2026-11-15）**：payload JSON 拼装抽为纯函数
      `windowEventPayloadJson`（单测锁定 v0.2.6 修过的「字段名缺引号被
      evaluate 静默丢弃」缺陷 + toOwnedSlice 所有权）；`close_requested_event`
      的「null 跟随 config / 显式值覆盖」两平台合并语义收敛为共享
      `ipc.resolveCloseRequested`（两后端同用 + 单测）。Linux 190/191、
      Windows 278/278 全绿。
- [x] **v0.2.7 平台能力对称**（2026-11-15）：把「Windows 有、Linux 无」的能力面补齐——
      **导航策略/新窗口策略/权限请求/渲染进程终止**（decide-policy（自有 zilt:// 与
      data:/blob:/about: 内联 scheme 放行 + 其余走共享 security.navigation 三态）、
      permission-request（GType 反查 → 共享 PermissionKind；ask 在冒烟模式自动拒绝、
      桌面弹原生询问框（嵌套泵））、create（兜底阻断默认弹窗）、web-process-terminated
      （process_failed 事件 + recover_renderer 自动 reload）——事件 payload 与 Windows
      driver 面同形）；**shell（opener）**（url/path → xdg-open、reveal → 打开所在目录
      （文档化语义差异），spawnDetachedLinux：spawn 不等待 + SIGCHLD=SIG_IGN 防僵尸）；
      **windowThemeChanged**（notify::gtk-theme-name → 广播）；**per-window WebView 代理**
      （独立 WebContext + 数据目录 + 全套 scheme 处理器，同 proxy 串复用）；
      **updater Linux 接线**（stageBytes 的 POSIX 分支：libc 写 .zilt-new(0755) →
      rename×2 原子替换；`--zilt-restart` helper = 等父进程消失 → std.process.replace
      exec 新版；info/check op + 事件与 Windows 逐字对齐）；**services op**（共享
      Registry + appendToJson 上移共享层）。**冒烟 59 → 65 项**（nav.deny / perm.geo /
      shell.open / services.list / updater.info / proxy.window）+ **Zig 侧后置终止闭环**
      （前端检查全过后主动 terminate web process → 断言信号 → 退出；smoke_finished
      守卫防重载页重跑整套冒烟）。修正 `.desktop` 文件名重复拼接（app_id 已带
      .desktop 后缀时）；CI apt 补 libx11-dev（v0.2.6 声称补了实际漏了——X11 头文件
      是 capi.h 硬依赖）。**验收**：Linux 冒烟 65/65 exit 0（+ post terminate PASS）、
      单实例转交 E2E PASS、打包 E2E PASS、Linux 单测 191/192（1 skip）、
      Windows 单测/构建全绿。
- [x] **v0.2.8 工具链与 headless**（2026-11-15）：对齐 Wails `wails3 dev`/doctor 的
      开发体验 + 补齐 headless/MCP 的 Linux 半边——
      **init 跨平台**（kernel32 手写 extern → std.Io.Dir + Args.Iterator + Io.random；
      `zig build init` Linux 可用，脚手架项目在 Linux `zig build` + 冒烟 exit 0 实测）；
      **模板漂移修复**（v0.2.x 期间 templates/_common 的 build.zig.tmpl /
      app_meta.zig.tmpl 与仓库脱节——两平台都产不出可构建项目，本轮实测踩到后
      全量同步；VERSION 占位符改为读 src/zilt/version.zig（此前硬编码 0.1.0 →
      版本一致性编译断言必炸）；src/pack_linux.zig 纳入 vendored 集合）；
      **cli 跨平台**（doctor/info Linux 化：文件检查走 std.Io、PATH 扫描两平台分派、
      doctor 增 Linux 检查组 pkg-config gtk+-3.0/webkit2gtk-4.1 + xvfb-run/
      xdg-open/mksquashfs；icon/npm-pack/new 的 IO 同步跨平台）；
      **`zig build dev`（Linux）**（scripts/linux/dev.sh，与 dev.zig 同编排语义：
      spawn dev 命令 → TCP 直连等待 → 注入 ZILT_DEV_URL/反代 → 拉起；
      ZILT_DEV_WATCH=1 热重启——杀应用 → 等 `zig build --watch` 写新 exe → 重拉）；
      **headless + MCP**（Windows v0.1.17 的 headless.zig 跨平台化——全 std.Io 实现，
      仅 env/SQL 两处平台点 comptime 分派；Linux sqlite.zig 的 run/migrate 与
      Windows 逐字同构；`ZILT_HEADLESS=1` 在 Linux 跳过 GTK 直起 HTTP 服务）。
      **验收**：Linux 单测 195/196（1 skip）/Windows 279/279；冒烟 65/65 +
      post terminate PASS；headless E2E 四端点 PASS（health / ipc greet /
      mcp 33 tools / tools/call 42 / 资产 200）；dev 编排实测（TCP 等待 +
      ZILT_DEV_URL 注入 + 应用拉起）；CI Linux job 增 headless E2E 与模板
      init→build E2E。gen_bindings 顺带跨平台化（dev/gen 依赖它）。
- [x] **v0.2.9 分发与测试收尾**（2026-11-15）：v0.2 画句号——
      **WebKitWebDriver E2E**（driver.zig 跨平台化：argv 走 Args.Iterator、文件/env/
      进程/睡眠助手两平台分派、W3C HTTP 层本就 std.Io；Linux 流程 = 注入
      `ZILT_AUTOMATION=1`（app 侧 `webkit_web_context_set_automation_allowed`）→
      spawn WebKitWebDriver → POST /session（`webkitgtk:browserOptions.binary` =
      应用 exe，WebKitWebDriver 自己拉起应用）→ 同一套 execute/sync 断言 →
      DELETE /session；缺驱动 SKIP(3) 与 Windows 同语义）；**find_in_page 打勾**
      （runtime 纯 JS `window.find` 两平台同实现——冒烟补 find 检查项锁定）；
      **per_window_proxy/webdriver 能力清单打勾**；**单文件 AppImage E2E 实测**
      （dev-appimage-e2e.sh：AppImageKit runtime-x86_64（gh-proxy mirror——
      GitHub release-assets 在本地网络 TLS 被干扰，直连 302 后解码失败）+
      squashfs 拼接 → 无 FUSE 环境降级 `--appimage-extract` + 提取版 AppRun
      冒烟 **66/66 exit 0**；CI runner 可装 libfuse2 直跑）。
      **验收**：冒烟 65 → **66 项**；Linux 单测 195/196（1 skip）/Windows 279/279；
      单实例转交/打包/headless/AppImage E2E 全 PASS；CI apt 补 webkit2gtk-driver
      + e2e 步骤。
- [~] **v0.3.0 桌面体验包**（2026-11-15 进行中，逐项同步）：
      - [x] **process 子进程 op**（Linux 接线，对齐 Windows v0.1.16）：runProcOp
            （spawn/kill/list）+ procWorker（spawn → 两路管道读线程 → wait →
            processEvent 事件：stdout/stderr 分块 + exit code）+ `shell:` scope
            ACL（argv[0] basename 去 .exe，与 Windows 同规则）；事件经 g_idle_add
            封送。**实测坑**：v0.2.7 的 SIGCHLD=SIG_IGN 让内核自动回收 → 子进程
            wait 拿到 ECHILD → Threaded io 视为 errno bug panic——改为每个分离
            子进程挂收割线程（waitpid 该 pid），全局信号方案废弃。
            demo shell scope 补 `echo`/`sh`（Linux 侧检查用）。冒烟 66 → **68 项**
            （proc stdout/exit 闭环 + proc.acl 拒绝）。
      - [x] **通知交互**（Linux 接线，对齐 Windows v0.1.12 的可用子集）：按钮/正文
            点击走 **GAction 索引机制**（`app.zilt-notify::<i>`——SimpleAction
            参数 int32，激活回调查表 → `notification` 事件
            `{tag,kind:activated,arguments}`，与 Windows toastEventJson 同形；
            索引方案规避 GVariant 字符串转义）；launch → set_default_action。
            input/progress 是 WinRT 独有 → 稳定 NotSupported
            （`NotificationInputNotSupported`/`ProgressNotSupported`）；GNotification
            无 dismissed 回调（文档化差异）。**坑**：`G_VARIANT_TYPE_INT32` 宏
            translate-c 失败 → `g_variant_type_new("i")`；GSimpleAction 是
            opaque → `?*c.T` 单指针（0.17 老规矩）。冒烟 68 → **69 项**
            （notify.actions：按钮发送 + input 拒绝）。
      - [x] **透明窗口 + background_color**（对齐 Windows v0.1.7）：RGBA visual +
            app_paintable + `draw` 信号 cairo SOURCE 清屏（GTK3 无透明开关）+
            `webkit_web_view_set_background_color`（alpha=0 / 0xRRGGBB 不透明）。
            必须在 realize 前设置。`window.state()` 增 `transparent` /
            `background_color` 字段（Windows 的 style/ex_style 之外的两平台通用查询项）。
      - [x] **titlebar overlay / CSD**（对齐 Windows v0.1.23）：`titlebar_overlay`
            → 无原生边框（`gtk_window_set_decorated(FALSE)`，客户区覆盖整窗），
            `data-zilt-drag-region` 复用既有 `startDragging`（`gtk_window_begin_move_drag`）。
            `window.create({titlebarOverlay, backgroundColor})` 两平台同接
            （builtin Arg 补齐 + runtime camelCase 映射）。
      - [x] **WebView 右键菜单 / 脚本对话框接管**：`context-menu` 信号 →
            `settings.context_menus=false` 时阻止 WebKit 默认菜单（应用可经
            `menu.popup` 自绘）；`script-dialog` 信号 → `settings.script_dialogs=false`
            时阻止原生模态框（confirm/prompt 返回默认值），冒烟模式一律阻止（否则
            模态框卡死主循环）。
      - [x] **窗口精细控制包**（对齐 Windows v0.1.18）：14 种光标（GDK CSS 名 +
            default 兜底）/ 光标隐藏（1×1 透明 pixbuf cursor）/ `gdk_seat_grab` 抓取 /
            `gdk_device_warp` 定位 / 鼠标穿透（GdkWindow 空 input shape）/
            运行时图标（`gtk_window_set_icon_from_file`，null 清空）/
            阴影（GTK3 无窗口阴影 API → WM/compositor 负责，接受请求并记录）/
            防截屏（Linux 无标准 API → 稳定 false，文档化）。
      - [x] **拖出**（对齐 Windows v0.1.12）：`start_drag_fn` →
            `gtk_drag_begin_with_coordinates`（text/uri-list, COPY），
            `drag-data-get` 信号把待拖文件写成 CRLF 分隔 URI 列表
            （`buildUriList` 纯函数 + 单测）。不做常驻 drag source（避免抢走页面
            文本选择手势）。拖入既有 `dropFiles` 不变。
      - [x] **CI openbox + 窗口事件断言**：CI apt 增 openbox；冒烟在 Xvfb 内先起
            openbox（本地 dev-smoke.sh 同款，有则起、无则跳过）。后端启动用
            `_NET_SUPPORTING_WM_CHECK` 探 WM（`__zilt.linuxSmokeWired` 探针），
            有 WM 时断言 windowMoved/Resized 载荷与 state 一致 +
            新窗口 blur → 回焦 focus 闭环；无 WM 明确 skip。
            **焦点关键修复**：WebKit 的 X 焦点落在子 GdkWindow 时 GtkWindow 的
            focus-in/out 与 has-toplevel-focus 都不更新（openbox 实测事件全灭）——
            改为 200ms 轮询 `XGetInputFocus` + `XQueryTree` 父链匹配 toplevel XID
            （`FocusProbe`，capi.h 对 GTK3 引入 gdkx.h，GTK4 回退属性）。
            **窗口状态恢复修复**：WM 忽略 map 前的 move（openbox 恢复成 0,0）→
            `map-event` 补一次 move。
            **验收**：Linux 冒烟 69 → **75 项 exit 0**（新增 win.polish /
            win.guards / win.overlay / win.background / win.dialog / drag.out /
            wm.events；无 WM 路径 skip 也 exit 0）；本地无 root 安装 openbox 实测
            wm.events 全绿（blur/focus/probeActive/mainActive=true）。
            Linux 单测 **197/198**（1 skip；+gdkCursorName/buildUriList）；
            Windows 单测 **279/279**、冒烟除桌面剪贴板占用（clip/clipmulti，
            环境问题）外全 PASS。
- [x] **v0.3.1 MCP 深化 + Linux 差分更新**（2026-11-15）：
      - **MCP 深化**：`POST /mcp` 之外新增 **stdio transport**
            （`ZILT_HEADLESS=1 ZILT_MCP_STDIO=1`，一行一条 JSON-RPC，stdout 只出响应）；
            `resources/list|read`（app info / zilt.log 尾部 / tools）、
            `prompts/list|get`（app_overview / call_command）、通知（无 id）不回包
            （HTTP 202 / stdio 静默）、工具级 ACL `ZILT_MCP_TOOLS=greet,add`
            （tools/list 过滤 + call 返回 `ToolNotAllowed`）。
      - **`zilt mcp [app]`**：CLI 注入 `ZILT_HEADLESS`/`ZILT_MCP_STDIO` 后 spawn 应用
            （stdin/stdout 继承，无桥接进程/端口）；默认取同目录 zilt-app，
            `ZILT_MCP_APP` 可覆盖。Claude Desktop 可直接以命令方式接入。
      - **Linux 差分更新**：`updaterFlow` 优先 `manifest.patch`——
            基线 sha256 校验 → 补丁下载/sha256/ed25519 → `applyPatch` →
            结果全量 sha256+签名复核 → `stageBytes`；任一步失败回退全量。
      - **Linux 崩溃回滚 + 健康确认**：restart helper 由 exec 改为
            「拉起新版 → 观察 3s，提前退出则 `.zilt-old` 回滚并重拉」；
            启动 10s 后 `cleanupOld` 删除备份（g_timeout，对齐 Windows WM_TIMER）。
      - **工具链跨平台**：`zilt-keygen` / `zilt-sign` / `zilt-diff` 全部改
            `std.process.Init`（env/environ_map + std.Io 文件 + Io.random），
            Linux `zig build` 直接产出三件套（补丁/清单可在 Linux 发布流水线生成）。
      - **验收**：Linux 单测 **200/201**（1 skip；+MCP resources/prompts/ACL、
            POSIX rollback/cleanup）；headless/MCP E2E **PASS**
            （HTTP resources/read + 202 + stdio 3 行 + `zilt mcp` 42 + ACL 拒绝）；
            **差分更新 E2E PASS**（61MB exe + 30 字节扰动 → 补丁 107 字节，
            exe 替换/备份 sha 匹配/10s 健康清理全绿）；
            Linux GUI 冒烟 **75/75 exit 0**（openbox）；Windows 单测 **281/282**
            （1 skip = POSIX 用例）、构建通过、冒烟 **49/49 ALL PASSED**。
- [x] **v0.3.2 WebView 数据与协议面**（2026-11-17；规划见 v0.3.x-PLAN）：
      - **真 scheme（Windows）**：纯 Zig COM 实现 `ICoreWebView2CustomSchemeRegistration`
        （IID d60ac92c…，10 槽）+ `ICoreWebView2EnvironmentOptions4`（IID ac52d13f…，
        WRL 式聚合分片：QI/AddRef/Release 委托 owner）→ `SetCustomSchemeRegistrations`。
        注册名沿用 validName 门控（`schemeNameOf` + `find` 防 https 误拦）。
        **实测坑**：`HasAuthorityComponent=false` 会让 iframe 导航直接崩溃浏览器进程
        （保持 true）；authority 段并入 path（`echo://a/b` → path=`a/b`，与 Linux
        serveProtocol 逐字同约定）；https 页面 fetch/XHR 的 CORS 判定拒绝（ACAO 精确/
        `*`、AllowedOrigins 精确/通配均无效；iframe 导航与 no-cors 正常）——冒烟断言
        用 iframe 导航全链，fetch 场景文档化引导用路径式。
      - **无痕窗口（两平台）**：Windows `ICoreWebView2Environment10::
        CreateCoreWebView2ControllerOptions` + `ControllerWithOptions`
        （IsInPrivateModeEnabled；老运行时 QI 失败回退并记日志）——主窗口与子
        webview（webviews.create({incognito})，与 partition 互斥 incognito 优先）
        双路接入；Linux `webkit_website_data_manager_new_ephemeral()`（每窗口独立
        context，scheme 处理器齐全）。`window.state().incognito` 断言。
      - **Profile 设置 / 节流**：`ICoreWebView2Profile6`（IID bd82fa6a…，槽 18–21）
        autofill/password_autosave（driver.applySettings 接入，QI 失败跳过）；
        `environment.background_throttling=false` → buildBrowserArguments 追加三个
        Chromium 开关（join 语义重写，proxy/raw/throttle 三段拼接）。
      - **显示器细化**：`Monitor.current` 标记（Win：MonitorFromWindow+枚举序匹配；
        Linux：gdk_display_get_monitor_at_window）+ `window.state()` 增 incognito/
        monitor（Linux 用内联 blk 计算 monitorAtWindow 枚举序）。
      - **电源/会话事件**：共享 `power.zig`（事件码→事件名纯函数 + 单测）——
        Windows WM_POWERBROADCAST + WM_WTSSESSION_CHANGE（wtsapi32 **动态加载**
        改直接 extern + 链接 wtsapi32；emitAll 广播所有存活窗口）；Linux GDBus
        订阅 org.freedesktop.login1（**translate-c 的 GDBusConnection 是 opaque，
        [*c] 不可用 → 自声明 extern + *anyopaque 句柄**；PrepareForSleep 参数经
        g_variant_get "(b)"，GetSessionByPID "(so)" 取会话路径订阅 Lock/Unlock；
        信号在 worker 线程 → g_idle_add 封送；无系统总线降级仅日志）。
      - **冒烟**：Windows 52 项（c-scheme=iframe 导航断言 / c-privacy / c-monitor）；
        Linux 77 项（privacy/monitor）。**验收**：Windows 单测全绿 + 冒烟 52/52
        （clip/clipmulti 为桌面剪贴板占用环境问题，PowerShell Set-Clipboard 同样失败）；
        Linux 单测全绿 + 冒烟 77/77 + post terminate PASS（Xvfb+openbox）。
- [x] **v0.3.3 窗口体验包 II**（2026-11-17；规划见 v0.3.x-PLAN）：
      - **mask**：共享 png.zig 解码 alpha → 行扫描 rect 合并；Win SetWindowRgn（所有权归系统）/
        Linux cairo region + shape/input shape 双通道（须 realize 后）
      - **每按钮状态**：Win 系统菜单 EnableMenuItem（SC_CLOSE/MIN/MAXIMIZE）创建期 + 运行时
        setButtonState；GTK3 无 API 文档化
      - **托盘附着窗**：Config.tray.attach_window → 托盘左键切换定位（Shell_NotifyIconGetRect +
        workarea 边界修正；底部放不下 → 图标上方）
      - **hideOnFocusLost/Escape**：Win WM_ACTIVATE(WA_INACTIVE) / ACCEL 表专用 id 0xF000
        （CopyAcceleratorTableW 复制重建合并菜单项）；Linux focus-out-event / key-press-event
        （GdkEventKey opaque → gdk_event_get_keyval）
      - **KeyBindings**：窗口 ACCEL id 0xE000+（与菜单 id 空间隔离）→ windowKeyBinding 事件；
        Linux 未接线（GtkAccelGroup 闭包创建留待后续，文档化）
      - **resize 拖拽 / overflow / 双击 / 去抖**：Win SC_SIZE+HT 边 / WM_WINDOWPOSCHANGING 夹取
        （MONITORINFOEXW workarea，经 win_sysinfo pub 化复用）/ WM_NCLBUTTONDBLCLK → SC_MAXIMIZE /
        WM_MOVE 合并 + WM_TIMER(id=5) 补发 + WM_EXITSIZEMOVE 终值；Linux gtk_window_begin_resize_drag /
        configure-event 夹取
      - **验收**：Windows 单测全绿冒烟 **53 项**（+c-exp2）；Linux 单测全绿冒烟 **78/78**；
        实测坑：HACCEL/HMENU 本身是 optional（?win32.HACCEL = 双 optional 不可作 extern 返回）
- [x] **v0.3.4 分发与更新**（2026-11-17；规划见 v0.3.x-PLAN）：
      - **侧车资源**：project.resources → addInstallDirectory（exe 旁 resources/**，显式
        dependOn install step）→ NSIS {RESOURCES_INSTALL}（SetOutPath+File /r，与 install
        同布局）→ path.resource 运行时解析（防穿越 + exists）。实测坑：build.zig 的
        std.Io.Dir/statFile 三参形态 + addInstallDirectory 需手动挂 install step
      - **更新器**：skipped.json（parseSkipped 单测）+ skip op（两平台 runUpdaterOp，
        Win Io.Dir.writeFile options 形态）+ checkForUpdateEnv（github_repo → releases/
        latest → zilt-manifest.json asset；fetchFn anyerror → UpdateError 映射）+
        updateDownloading 事件（updaterFlow 双平台）
      - **验收**：Windows 单测全绿冒烟 54 项（+c-res）；Linux 单测全绿冒烟 78/78
      - **范围**：E2/E4/F2 延后（见 v0.3.x-PLAN 范围说明）
- [x] **v0.3.5 安全深化（DPAPI store）**（2026-11-17）：
      - dpapi.zig：crypt32 动态加载（对齐 sqlite/winhttp 模式）+ encrypt/decrypt
        （`dpapi:` 前缀 + base64；非前缀值原样返回=混合形态兼容）+ 真实 crypt32 往返单测
      - runStoreOp 接线：set 经 config.store_encrypted 加密、get 前缀自动解密
        （demo 开启后 c-storage 既有断言天然兼容）
      - **物理证据**：store.json `dpapi:` 值存在且明文 secret 不在磁盘
      - **延后**：isolation pattern（runtime JS 重设计）与 Wayland portal（需真会话）
        → 专项版本；GDBus 基建（v0.3.2 logind）可复用
      - **验收**：Windows 单测全绿冒烟 55 项（+c-dpapi）；Linux 全绿 78/78
- [x] **v0.3.6 二进制 IPC（SharedBuffer）**（2026-11-17）：
      - COM 绑定：Environment12（IID f503db9b…，flat 槽 24=CreateSharedBuffer）/
        ICoreWebView2SharedBuffer（get_Size/get_Buffer/OpenStream/Close）/
        ICoreWebView2_17（IID 702e75d4…，flat 槽 116=PostSharedBufferToScript）
      - Context.post_binary hook + WM_APP+20 marshal（WebMessageReceived 重入规避，
        实测：回调内同步调用挂死整个页面——v0.1.17 ExecuteScript 同款陷阱）
      - 写路径：get_Buffer 直写后 JS 读到全零（ArrayBuffer 无 .buffer 属性的 JS 包装
        bug + IStream 路径双保险），定案 OpenStream+IStream::Write（官方样例路径）
      - JS：runtime tail `sharedbufferreceived` 桥（getBuffer()=ArrayBuffer 本体 →
        `new Uint8Array(ab)`；checksum 处理器内重算）+ binary.request Promise（5s 超时）
      - **验收**：Windows 冒烟 56 项（+c-binipc 16KB checksum match）；Linux 79/79
        （binipc 平台差异 skip）；A11 CompositionController 延后（ABI 已核对，
        方案在 v0.3.x-PLAN）
- [x] **v0.3.7 server 模式**（2026-11-17）：
      - server_session.zig：WS upgrade（RFC6455 已知向量单测）+ 会话注册表
        （server 窗口 id 0x100000+；自旋锁——Io.Mutex 需 io 实例而注册表从任意
        线程调用）+ routeEvent（命中回会话 / 未命中广播）
      - headless：/zilt/ws upgrade 分流 → runServerSession（帧读循环 invoke →
        dispatch 响应回帧 + drain 事件队列传帧；ping→pong）→ handleIpcJson
        （builtin 优先 + ipc.dispatch，backend=Session）；**accept 线程化**
        （每连接一线程；comptime config 经 spawn 参数剥离传入）
      - **E2E**：scripts/server_mode_e2e.py（原生 WS 客户端：握手 accept 校验 +
        greet/add 往返 + 双会话独立路由）——Windows ALL PASSED + Linux
        SERVER_E2E=PASS（dev-headless.sh 接入 CI）；headless 四端点回归 PASS
      - **实测坑**：Io.Mutex 需 io 实例（自旋锁替代）；Io.Mutex= .init 哨兵；
        Stream.read 是矢量读（[][]u8）；ws.zig encodeFrame 是客户端形态（服务端
        帧也带 mask 位——python E2E 兼容处理）；ConnJob 不能持 comptime-only
        Config（spawn 参数剥离）
      - **范围说明**：浏览器端 runtime 传输 shim（二阶段）——协议层已被 python
        E2E 完整覆盖
      - **验收**：Windows/Linux 单测全绿；Linux 冒烟 79/79 + headless/server E2E
- [x] **v0.3.13 server 模式二阶段**（2026-11-19；二轮差距刷新收口）：
      - **F1b 浏览器端 runtime shim**：headless `/zilt/runtime.js`（runtime JS 原样）+
        serveAsset 的 HTML 注入（`__ZILT_SERVER__` 标记 + runtime.js 引用，`<head>` 后）；
        runtime 传输三态（chrome.webview / webkit.messageHandlers / **WS transport**——
        无 GUI transport 且页面 http(s) 时启用；post 就绪前排队 + onopen flush；
        入站帧 deliver）。app 页面零改动获得完整 window.zilt 面；isolation 密封为
        GUI 专属（浏览器端 ziltiso:// 不可导航——server 模式明文 invoke 文档化）
      - **服务端帧编码修正（RFC 6455）**：ws.zig encodeFrameServer（无掩码）——
        v0.3.7 服务端帧复用客户端掩码编码，python E2E 兼容处理掩盖问题，**真实浏览器
        对掩码服务端帧按协议错误关闭**（Edge 实测：session 连接即关闭、invoke 悬挂）；
        headless 会话 3 处全部改用
      - **会话生命周期修正**：demo 页 ticker 后台线程持有 ctx.backend 跨会话 emit——
        页面关闭 → unregister 释放会话 → 迟到 emit 解引用已 unmap 内存段错误（实测）；
        修复：unregister 的 pending 清理持 s.lock（与 enqueue/drain 并发）+ **会话墓地**
        （16 槽 @splat null，cursor 环形，超出释放最旧——迟到 emit 读旧 window_id →
        routeEvent 无匹配 → 广播/丢弃安全）
      - **浏览器 E2E（server_browser_e2e.py）**：Edge headless + **裸 WS CDP 客户端**
        （Runtime.evaluate awaitPromise）——HTML 注入断言 + shim 断言 + CDP 连通性
        （1+1=2）+ **经浏览器 shim 的 greet/add 往返**；server_mode_e2e.py 回归
        （两次）+ health OK
      - **验收**：Windows 冒烟 **61 项 exit 0** + browser E2E ALL PASSED + python WS
        E2E 两次 ALL PASSED；Linux 单测全绿 + 冒烟 83/83 + dev-headless
        （HEALTH/MCP_STDIO/HEADLESS_E2E=PASS）
- [x] **v0.3.14 窗口 API 收尾**（2026-11-20；三轮差距刷新第一批，对标 Wails v3.1.0 +
      Tauri 2.12.5，总表见 v0.3.x-PLAN §0.5）：
      - **窗口收尾（G1–G8/G11）**：center（工作区居中）/ create({maximized})（状态恢复
        之后应用——显式选项优先）/ setResizable + setDecorations（Win style 位 +
        SWP_FRAMECHANGED / GTK 原生属性；state() 增 resizable/decorated 直读）/ destroy
        （Win DestroyWindow、GTK gtk_widget_destroy——GTK3 无 gtk_window_destroy）/
        toggleMaximize / setScreen（collectMonitors 枚举序与 fullscreenOnMonitor 一致，
        工作区居中放置）/ window.list（window_query_fn 的 WINDOW_LIST_ALL 哨兵 →
        全窗状态数组）/ create({zoom})（Win controller 就绪 put_ZoomFactor；GTK
        webkit_web_view_set_zoom_level）
      - **应用面（G5）**：`__zilt.app` builtin——quit(code)（ctx.quit 既有基建）+
        restart（std.process.spawn 0.17 Io API，stdio 全 ignore，spawn 自身后 quit(0)）
      - **G6 Zig 侧取消钩子**：ipc.closeRequestHooked/closeRequestCancelled（comptime
        探测 events 命名空间 windowCloseRequested 的 bool 返回）；Win WM_CLOSE 与
        GTK delete-event 两路接线（true=取消，日志 + return 拦截）；emitEventPayload
        对已决事件跳过 dispatchEvent（避免双触发）；启用/不启用/返回值三态单测
      - **webview 面（G9/G10）**：Request.devtools 拆 DevToolsOp{open,close,state} +
        load_html；Win devtools_opened 跟踪（无关闭/查询 API → close 返回
        DevToolsCloseUnsupported 文档化）、load_html 走 NavigateToString（槽 6 既有
        绑定）；GTK inspector show/close/is_attached 全支持 + load_html（base_uri=
        app_url）
      - **Linux 补齐**：**windowDestroyed 事件**（此前 GTK 销毁不 emit——实测 win3
        冒烟暴露；onDestroy 发给其余存活窗口，emitWindowEvent idle 封送）+ 缩放
        polyfill（G26：Ctrl/Cmd ±/0 → zilt.webview.zoom，user script 注入，单测锁内容）
      - **验收**：Windows 冒烟 **62 项**（c-win3 探针窗口全量往返 + appquit 流——
        全过后 app.quit(0) 收尾；quit 链路经临时禁用失败自退的对照实验验证 exit 0）
        + 单测全绿；Linux 冒烟 **84/84**（win3 GTK 全量往返）+ post terminate PASS；
        双平台单测全绿。**实测记录**：clip/clipmulti 失败为本机既有桌面剪贴板占用
        环境问题（zilt-keep.log 同样存在，非本版回归）
- [x] **v0.3.15 打印与 WebView 开关面**（2026-11-20；三轮差距刷新第二批）：
      - **G12 printToPdf（Windows 实装，Wails/Tauri 均无 → Zilt 领先项）**：
        ICoreWebView2_7::PrintToPdf（槽 80 / IID 79c24d83，官方 SDK 1.0.3124.44
        WebView2.h 核对——NuGet 提取 + python vtable 全表解析）+ 引擎默认打印设置 +
        PdfHandler（Invoke(hr, is_successful)）→ webviewPdf 事件；requestFromArgs
        printToPdf/settingsProbe 映射单测。Linux PdfNotSupported 文档化（pdfskip）
      - **G13/G14 Settings3/6 开关**：browser_accelerators（默认开——Tauri
        disabled_webview_shortcuts 反向）/ swipe_gestures（默认关——Wails
        EnableSwipeGestures opt-in 同语义）；settingsProbe 探针（读→反转→验证→恢复
        →验证）冒烟 c-acc；Linux 手势走 WebKitSettings enable-back-forward-navigation-
        gestures（创建期），探针 null 文档化
      - **G27 OtherSensors**：PermissionKind.other_sensors（native 5）+ 默认 deny +
        Linux 询问框文案
      - **范围修正**：G15 tabbed backdrop 已有（v0.1.14 Backdrop.tabbed）；G16
        fluentOverlay 官方 SDK 无 COM 接口 → 文档化移除
      - **验收**：Windows 冒烟 **64 项**（c-pdf/c-acc 全过）+ 单测全绿；Linux 冒烟
        **85/85**（pdfskip）+ post terminate PASS；clip 既有环境问题
- [x] **v0.3.16 托盘/任务栏/屏幕细化 + 单实例加固**（2026-11-20；三轮差距刷新第三批）：
      - **G17 托盘暗色图标**：tray.setDarkIcon（运行时 op）+ themeChanged 自动换发
        （emitThemeAll 内 setIcon 按主题分派；暗色未设置回退亮色图标）
      - **G18 任务栏文本徽标**：taskbar.badge（taskbar.Badge{text,bg,fg}）——
        win32.zig 增 GDI 面（CreateCompatibleDC/CreateDIBSection/CreateBitmap/
        SelectObject/DrawTextW/SetTextColor/SetBkMode/GetStockObject/
        CreateIconIndirect）+ makeBadgeIcon 渲染（32×32 top-down DIB 圆底 +
        DEFAULT_GUI_FONT 文本）+ Taskbar.last_badge_icon 即时销毁防泄漏
      - **G19 屏幕细化**：system.cursorPosition（Win GetCursorPos / GTK
        gdk_device_get_position）+ Monitor.rotation（DEVMODEW 自声明 220 字节
        布局单测 + EnumDisplaySettingsW；GDK3 无 API → 0 文档化）
      - **G20 Linux GPU policy**：environment.gpu_policy（never → 禁加速合成；
        auto + /proc/driver/nvidia → WEBKIT_DISABLE_DMABUF_RENDERER=1）——
        setenv extern + Io 读 proc，单测锁往返/安全探测
      - **G21 Linux sticky**：window.setAllWorkspaces → gtk_window_stick/unstick；
        Windows no-op true 文档化
      - **G22 单实例密封**：single_instance.sealPayload/openPayload（HMAC-SHA256 +
        16B nonce；"zilt1|n|s|p" 线格式）+ Config.single_instance_key + 启动转发/
        onCopyData 两路接线（明文/篡改/非法密钥拒绝）
      - **验收**：Windows 冒烟 **65 项**（c-sys2）+ 单测全绿；Linux 冒烟 **86/86**
        （curs）+ post terminate PASS；clip 既有环境问题
- [x] **v0.3.17 更新器/分发收尾 + 二进制通道**（2026-11-20；三轮差距刷新第四批）：
      - **G23 更新器进度 + 周期检查**：Fetcher.streamFn/progress（updater.zig）+
        Windows httpFetchStreaming（短读循环 + GetTickCount64 节流）+
        updateDownloadProgress 事件；Config.update.check_interval_min → SetTimer(6)
        → WM_TIMER 重跑 updaterFlow
      - **G24 deb/AppDir resources**：pack_linux collectResources（libc readdir——
        Io walker 递归 BADF 实测回退）+ buildDebOpt resources 选项（dir+file tar
        条目）；**arena 段内回收破坏 tar 条目名实测** → dir_rel 切片直指 rf.rel
        零分配；deb tar 条目 + PACK_E2E PASS 实测
      - **G25 二进制通道**：channelChecksum（FNV-1a32，公开向量单测）+
        channelDecodeBase64 + Context.channelSendBinary + runtime JS binary 模式
        （Math.imul——浮点乘 2^53 精度丢失实测修正）+ JS→Zig 经事件 channelUp；
        demo 回显 16KB 全链（c-bchan）
      - **验收**：Windows 冒烟 **66 项**（c-bchan）+ 单测全绿；Linux 冒烟
        **86/86** + PACK_E2E PASS + post terminate PASS
- [x] **v0.3.18 CompositionController 渲染专项收口**（2026-11-20；三轮差距刷新第五批）：
      - **三项真实缺陷修复（v0.3.12 装配错误，实测驱动）**：
        1. **IDCompositionVisual vtable 槽位**——dcomp.h C++ 接口重载
           （SetOffsetX/Y/Transform/Clip 各 2 槽）漏算；SetContent=15/AddVisual=16
           （误记 11/12 → AddVisual 落 SetBorderMode 报 E_INVALIDARG 实测暴露）
        2. **官方双视觉层级**——APISample BuildDCompTreeUsingVisual 序列
           （target.SetRoot(root) + root.AddVisual(webview, TRUE, null) +
           put_RootVisualTarget(webview 子视觉)；v0.3.12 单视觉错误）
        3. **put_Bounds + 设备先建**——QI'd Controller put_Bounds（客户端区；
           v0.3.12 从未调用 = 0×0 呈现面）+ DComp 设备先于 controller 创建 +
           DCompositionCreateDevice2 + 有序拆除（视觉树 → Close）
      - **最小复现实验**：ZILT_COMP_BARE=1（零 driver 交互裸 Navigate）——装配
        全链成功后 Navigate 仍段错误于 EmbeddedBrowserWebView.dll → 上游运行时
        缺陷定案（Runtime 157.0.4341.60 + 本机 DComp 栈；Wails 同保持 experimental）
      - **收口形态**：默认 HWND 回退（c-comp 断言）+ ZILT_COMP_ENABLE=1 启用修复
        后管线（未来运行时验证入口）；有序拆除更新（视觉树先行 + 状态字段重排）
      - **验收**：Windows 冒烟 **66 项** + 单测全绿；Linux 冒烟 **86/86**；
        ZILT_COMP_ENABLE=1 实测 composition ready 全链
      - 后续规划（v0.3.8–v0.3.13，二轮差距刷新 2026-11-17——对标 Wails v3.1.0 /（2026-11-19；二轮差距刷新第五批——
      ABI/装配/回退全链落地，渲染管线为已知问题）：
      - **ABI 绑定（官方 WebView2.h 逐一核对）**：webview2.zig 增
        ICoreWebView2CompositionController（11 槽 + CC2/CC3/CC4 尾随槽并入 16–19）+
        ICoreWebView2Settings9（IsNonClientRegionSupportEnabled flat 37/38——
        Settings1–8 自有方法数逐一枚举推算）+ IIDs（CC {3DF9B733-…}/CC4
        {7C367B9B-…}/Settings9 {0528A73B-…}/Handler {02FAB84B-…}）+ 鼠标/非客户区枚举；
        **修正 v0.3.2 误记**：CreateCoreWebView2CompositionControllerWithOptions 为
        官方 3 参（E_POINTER 实测修正——4 参签名把 handler 传进了错误槽位）
      - **DComp 绑定（dcomp.zig）**：SDK dcomp.h DECLARE_INTERFACE_IID_ 段核对——
        Device {C37EA93A-…} Commit(3)/CreateTargetForHwnd(6)/CreateVisual(7)、
        Target {EACDD04C-…} SetRoot(3)、Visual {4D93059D-…} SetContent(11)/AddVisual(12)；
        DCompositionCreateDevice（dcomp.dll 动态加载，dxgi_device=null 引擎自建）
      - **组合窗口链路（backend）**：window.create({composition}) → dispatch →
        beginCompositionController → CompositionControllerCompletedHandler（Invoke 收 CC）
        → onCompositionControllerReady（DComp 装配 + Settings9 + QI 实测 + driver
        attach controller=null）→ **QI 实测记录**：组合对象实现
        ICoreWebView2Controller（0x0 ✓）与 CC4（0x0 ✓）、**不**实现 ICoreWebView2 直取
        （0x80004002）——webview 经 controller.getCoreWebView2() 取；鼠标转发
        （WM_LBUTTONDOWN 等 10 消息 → SendMouseInput；**WM_MOUSELEAVE 与既有托盘
        处理重复**，从组合 case 移除）+ WM_NCHITTEST CC4 原生 hit-test（HTCAPTION/
        HTMINBUTTON/HTMAXBUTTON/HTCLOSE——win32 常量补齐）+ state().composition +
        releaseWindowCom 有序拆除；driver attach 的 controller 参数改可选
        （retain/destroy/zoom/parentWindow 全守卫）
      - **已知问题（渲染管线段错误）**：装配/Settings9/导航全部成功后 WebView2 渲染
        管线段错误（EmbeddedBrowserWebView.dll 内部；about:blank 复现；putIsVisible
        前置、有序拆除 SetRoot(null)+Commit+controller.Close 均不缓解）——本版组合
        选项按降级文化走 HWND 渲染（c-comp 断言回退链）；渲染修复为后续专项
        （排查方向：DComp 设备与浏览器合成器共享、visual 树的 sizing、官方样例
        WebView2APISample ViewComponent.cpp 逐行 diff）
      - **验收**：Windows 单测全绿 + 冒烟 61 项（c-comp 断言组合请求→探测→回退全链；
        clip 两项为外部剪贴板占用环境问题）+ Linux 单测全绿 + 冒烟 83/83
      - 后续规划（v0.3.8–v0.3.13，二轮差距刷新 2026-11-17——对标 Wails v3.1.0 /
      - **E1b external_bin sidecar**：project.external_bin（bin/<name>-<triple>[.exe]
        约定，triple 由构建 target 推导）→ build install 落 exe 旁（缺失跳过）→
        NSIS {SIDECAR_INSTALL}（bundler 增 sidecars 字段 + bundle 工具 {SIDECAR_DIR}
        = exe 目录替换）→ deb DebOptions.extra_files（pack_formats.ExtraFile，
        data.tar usr/bin 条目）→ AppDir usr/bin 复制；运行时 __zilt.path sidecar
        动作（防穿越 + .exe 后缀）——c-sidecar 冒烟检查（解析 + exists=false +
        非法名拒绝）
      - **E2 fixed 运行时 E2E**：ZILT_WEBVIEW2_BROWSER_DIR env 覆盖钩子（loader_opts）+
        scripts/e2e_fixed_runtime.ps1——缺失 fixed 目录 → 启动失败不回退 Evergreen
        （stderr error trace 含 WebView2RuntimeNotFound；**注意**：该错误走 stderr
        而非 zilt.log——E2E 断言源实测修正）；正向路径 ZILT_E2E_FIXED_RT 真运行时冒烟
      - **E4 交叉编译 pack**：pack_linux 工具改 HOST 目标（b.graph.host——交叉时打包
        TARGET exe；工具跟随 query 会产出跑不起来的 aarch64 工具——**实测修正**；
        0.17 的 Compile step 要求 root module 有已知 target，裸省略不行）+ aarch64
        交叉的 sqlite transient 哨兵 **align(1) 指针**修正（@ptrFromInt 对齐检查）；
        **已知限制**：aarch64 交叉止于 GTK 链接（host pkg-config 的 x86_64 .so 与
        目标架构不符——需 aarch64 sysroot，GUI 交叉通用前提）；矩阵文档化
        （deb/AppDir/AppImage 随 target 交叉；NSIS/MSI/MSIX 仅 Windows 目标）
      - **F2 TS 模板变体**：init.zig tsVariantBase 映射（vue-ts→vue 等四对）——
        overlay 机制（基础 vendored 复用 + templates/<variant>/ 只放 TS 专属文件，
        避免 vendored 框架重复）；**实测坑**：overlay 目录层级（模板根直接放文件）
        与覆盖时序（base copy → overlay copy → 不得再跑 base copy——初版三连复制
        把 overlay 覆盖回退）；vue-ts E2E：init → gen（绑定先行，否则 vue-tsc 报
        TS2307）→ 类型检查构建 ✓ → exe 运行资产 200
      - **验收**：Windows 单测全绿 + 冒烟 **60 项**（+c-sidecar）+ e2e_fixed_runtime
        PASS；Linux 单测全绿 + 冒烟 **83/83** + post terminate PASS
      - 后续规划（v0.3.8–v0.3.13，二轮差距刷新 2026-11-17——对标 Wails v3.1.0 /
      - **C2 isolation pattern**：isolation.zig（keyFromHex/HMAC-SHA256 签名/
        verifyJson + ReplayCache 512 槽防重放/canonicalize 规范化/iframeHtml 纯 JS 页面）
        + config.Isolation + 双平台接线（随机 origin ziltiso:// scheme 注册与服务 +
        decide-policy 放行（Linux）/真 scheme 分支拦截（Windows）+ runtime 双形态
        invoke + 明文 invoke 门禁（IsolationRequired/IsoTampered + __zilt.isoRejected））
        —— **选型实测记录**：AES-256-GCM（WebCrypto）方案因 `crypto.subtle` 依赖
        secure context（自定义 scheme iframe 不保证）改定纯 JS HMAC-SHA256（伪造防护
        等价，机密性不在威胁模型内）；**jsc_value_to_json 不保留键序**（页签 {"a":2,"b":3}
        → 桥送 {"b":3,"a":2}，node 对照实证）→ 签名改用规范化 JSON（两侧同构）；
        页侧 canon 丢 undefined 属性（对齐结构化克隆语义——{"exe_args":undefined}
        页侧/桥侧不一致的实证修复）；**node 跨实现 E2E**（.zilt-probe/iso_page_e2e.mjs：
        真实 iframe 页脚本 mock 执行 + node crypto HMAC 对照 + 篡改敏感）；
        demo 常开 isolation → **全套冒烟即密封链路 E2E**（Windows 59 项含 c-iso
        明文伪造必拒 / Linux 83 项含 iso 检查）+ server E2E 回归
      - **D1 Wayland portal 快捷键**：portal_hotkey.zig——isWaylandSession
        （WAYLAND_DISPLAY + **GDK_BACKEND=x11 显式排除**——WSLg 同时设两者的实测陷阱，
        Xvfb/CI 保持 XGrabKey）+ portalTrigger（Ctrl+Alt+N → <Control><Alt>n）+
        bindText（BindShortcuts 的 GVariant 文本构造，g_variant_parse 消费）+
        Portal GDBus 编排（CreateSession/BindShortcuts 整表重绑/Activated → hotkey 事件，
        logind extern 模式）；backend runHotkeyOp 双管理器分派 + runHotkeyOpPortal
        （list/register/unregister 同事件面）；真 Wayland 会话端到端待手动验证
        （v0.2.5 模式）；单测锁定会话判定/触发器/文本构造/shortcut id 校验
      - **验收**：Windows 单测全绿 + 冒烟 **59 项 exit 0**（密封链路 + c-iso）；
        Linux 单测全绿 + 冒烟 **83/83** + post terminate PASS；server E2E 不受影响
      - 后续规划（v0.3.8–v0.3.13，二轮差距刷新 2026-11-17——对标 Wails v3.1.0 /
      - **A12 效果参数（Windows）**：theme.zig 增 CornerPreference（DWMWCP_*，
        DWMWA_WINDOW_CORNER_PREFERENCE 33）+ AccentPolicy/WindowCompositionAttribData
        （extern struct 对齐 winuser 私有头）+ parseTint（"RRGGBB"/"AARRGGBB" →
        GradientColor 0xAABBGGRR，缺省 alpha 0xCC）+ 单测；system_integration 增
        applyTint（SetWindowCompositionAttribute user32 GetProcAddress 动态加载，
        ACCENT_ENABLE_ACRYLICBLURBEHIND——Tauri windowEffects 同款）+ applyCornerPreference；
        builtin 解析 tint/corner_preference；runtime appearance.apply 做 camelCase 映射；
        Linux 无 accent API → NotSupported 文档化（radius macOS-only 不变）
      - **A4L Linux KeyBindings**：KeyBindEntry（创建时 accelTextOf→parseAccelGtk 解析
        keyval/mods，id 归 WinState 所有权）→ key-press-event 匹配（与 v0.3.3 Escape
        同一 handler）→ windowKeyBinding {id, windowId}（与 Windows 逐字一致）；
        matchKeyBinding 文件级纯函数（keyval ASCII 归一小写——**实测坑**：keyvalForGtk
        统一大写键位 0x41-0x5A 而事件 keyval 是实际 level（'x'=0x78），且测试构建不链
        GTK 不能调 gdk_keyval_to_lower → keyvalLower 手写）；mods 只比较四个语义位
        （numlock/MOD2 忽略）；菜单 accel 由 GTK accel group 先行消费（优先级对齐）
      - **实测坑（X 层注入）**：XSendEvent 核心 KeyPress 被 GDK3 的 XI2 后端丢弃
        （事件不到达）；XTestFakeKeyEvent（dlopen libXtst，XSetInputFocus 后注入）
        四步全部执行成功但 WebKit 事件路径稳定段错（无 Zig 栈帧、PC=坏地址）——
        Xvfb+WebKitGTK 环境限制，与 v0.3.3 Escape 同测试深度。冒烟改为探针走
        **同一条匹配→事件派发路径**（合成 keyval/mods → matchKeyBinding → emit；
        确认结果经 linuxSmokeKeyBind 事件回传主页面——secondWindowProbe 先例）+
        matchKeyBinding 单测锁定大小写/掩码语义
      - **验收**：Windows 冒烟 58 项（c-appearance 扩展：tint=true 应用日志 + corner；
        c-exp2 增 keyBindings 创建）+ 单测全绿；Linux 单测全绿（+matchKeyBinding），
        冒烟 **82/82** + post terminate PASS
- [x] **v0.3.8 IPC 与协议收尾**（2026-11-18；二轮差距刷新第一批，规划见 v0.3.x-PLAN §0.4/§1）：
      - **B8 协议 POST body**：protocol.Request 增 `body`——Windows
        `WebResourceRequest::get_Content`（IStream 局部 vtable Read 循环，10MB 上限；
        WebView2 对带 body 请求不回传 Content-Length 但 body 可得，Wails PR#6326 同款）；
        Linux `webkit_uri_scheme_request_get_http_body`（dupe 进 handler arena）。
        **实测坑（两条平台限制文档化）**：① WebKitGTK 不转发自定义 scheme 请求 body
        （上游已知限制 littledivy/laufey#98，2.50.4 实测仅 1 字节垃圾 0xf0——Zig 侧
        读取已接线，上游修复自动生效，Linux 检查 skip 文档化）；② Chromium 的
        fetch/XHR 对自定义 scheme 根本不发出请求（v0.3.2 的「no-cors fetch 正常」
        系 Linux 侧观察，Windows 修正），真 scheme POST 探针改走**表单导航**
        （文档级导航可达 + 响应 HTML 自报 body）
      - **C1L Linux 二进制 IPC**：post_binary hook 接线——载荷 base64 后 evaluate
        `window.__ziltSharedBufferArrived`（runtime tail 全局，契约与 Windows
        sharedbufferreceived 桥一致）；g_idle_add 封送（对齐 Windows WM marshal 策略）+
        evaluate 完成回调回显 JS 错误（null 回调静默吞 ReferenceError 的排查教训）。
        **实测坑**：Zig 嵌入的 JSON 在脚本里是 JS 对象实参而非字符串——
        `JSON.parse(adJson)` 报 "Unexpected identifier object"（adJson typeof 分支兼容
        两种形态）。Linux 冒烟 binipc 从 skip 转**真实断言**（16KB checksum match）
      - **C3 绑定参数名**：bindings.zig paramSig（comptime 反射，@setEvalBranchQuota
        100000）——args 字段升级 TS 形参 `greet(name: string)` + `invoke("greet", { name })`；
        无参数命令 `ping()`；可选/默认值在尾部时带 `?:`；jsonName 映射同步；
        非法标识符/必填跟在可选后 → 回退对象形态（三组单测锁定）。模板四套调用点
        同步更新（greet('Vue')/notifyMe(t,b)/pickFile()）
      - **E6 http 上传进度**：`http.upload({url, parts, onProgress})`（强制 POST multipart）
        → `httpUploadProgress {id, written, total}`——Win `WinHttpWriteData` 分块
        （SendRequest 传 NULL body + dwTotalLength，64KB 块，GetTickCount64 节流 ~10Hz，
        首末块必发）；Linux 粗粒度两帧（libsoup3 无字节级上传进度，文档化）；
        MultiPart 增 `encoding`（base64 分片构建前解码）。**实测坑**：winhttp 响应读取
        循环把任何非 null sink 都当流式丢弃数据（上传 sink 只有 on_upload → 响应体为空）
        ——streaming 判定改为 on_chunk != null；分段 btoa 把 padding 嵌进串中部导致
        base64 解码失败（JS 侧整段编码）；Sink 双回调改 optional 修复 errdefer 双重释放
      - **验收**：Windows 单测全绿（+bindings 命名参数边界/net base64/protocol body
        契约），冒烟 **58 项**（+c-postbody/c-upload；clip/clipmulti 环境问题照旧）；
        Linux 单测全绿，冒烟 **81/81**（+binipc 真 check/postbody skip/upload）+
        post terminate PASS；server E2E ALL PASSED；`zig build gen` 命名参数签名
      - 后续规划（v0.3.8–v0.3.13，二轮差距刷新 2026-11-17——对标 Wails v3.1.0 /
        Tauri 2.12.6；差距总表与实现路径见 v0.3.x-PLAN §0.4/§1）：
        **v0.3.8** IPC/协议收尾（B8 协议 POST body 读取 + C1L Linux 二进制 IPC +
        C3 绑定参数名 + E6 上传进度）✅ → **v0.3.9** 窗口对称（A12 tint/cornerPreference +
        A4L Linux KeyBindings）✅ → **v0.3.10** 安全（C2 isolation pattern +
        D1 Wayland portal 快捷键）✅ → **v0.3.11** 分发（E1b external_bin sidecar +
        E2 fixed 运行时 E2E + E4 交叉编译 pack + F2 模板 TS 变体）✅ →
        **v0.3.12** CompositionController 专项（A11）[~] 渲染已知问题 →
        **v0.3.13** server 模式二阶段（F1b 浏览器端 shim）✅ →
        **v0.3.13** server 模式二阶段（F1b 浏览器端 runtime shim）
      - 明确推后（v0.4+/Phase 4）：macOS 全栈、iOS/Android、浏览器扩展、WML、GPU 信息、
        CLI 自更新、Tauri cli 插件（参数解析）、upload 断点续传（E6 stretch）
- [ ] macOS：zig-objc 路线（NSApplication/NSWindow/WKWebView + 运行时注册 delegate）——v0.4+
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
