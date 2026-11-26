# v0.5–v0.7 路线方案：桌面对等 → DX/弹性 → 插件生态

> 制定：2026-11-23。基线：**v0.4.8**（git `bc3cd0f`，运行时版本 `src/zilt/version.zig:9`）。
> 定位：v0.4.x 之后的**连续三个大版本**；**保持 0.x 快速迭代**（本轮不做 API 冻结 / 不冲 1.0）；**本轮不含移动端**。
> 对标：**Wails v3.1.0 stable（2026-11-01）+ v3.2-nightly**（本地 vendored 源码精读，`.zilt-probe/vendor/wails`）；**Tauri 2.12.7（2026-11-18）**（官方 v2 文档 + GitHub releases 调研）。
> 决策依据：用户 2026-11-23 拍板——主轴「桌面对等 → 移动 → 生态」；**移动端本轮移出**；0.6 = DX/弹性、0.7 = 插件生态（生态收尾）。
> 存档：本文是 0.5–0.7 的 **spec of record**；各版本实施前再出各自的 `DESIGN_vX.Y_*.md` 细化，并回填 `ROADMAP.md`。
> 规划原则（沿用 v0.3/v0.4 文化）：一个版本一个主题 + 全链路验收；平台差异显式文档化；切片按工程量递增；实施时允许实测后微调。

---

## 0. 现状与差距结论（探索摘要）

### 0.1 当前进度（v0.4.8）

| 平台 | 状态 | 技术栈 | 证据 |
|---|---|---|---|
| Windows | ✅ 全栈（v0.1.0–v0.4.3） | Win32 + WebView2（纯 Zig 手写 COM） | `src/zilt/platform/windows/backend.zig` |
| Linux | ✅ 全栈（冒烟 95 项）；GTK4 构建变体已通，**默认化未做** | GTK3 + WebKit2GTK 4.1；`-Dgtk=gtk4` | `src/zilt/platform/linux/backend.zig`；`ROADMAP.md:205`（L1b） |
| macOS | 🚧 集成/外观/WebView 深度已齐（v0.4.4–v0.4.8）；**分发/安全/更新/对等打磨未做** | WKWebView（手写 ObjC 消息） | `src/zilt/platform/macos/{backend,objc}.zig`；`ROADMAP.md:500`（v0.4.9）、`:520`（v0.4.10） |

- v0.4.x 已完成：v0.4.0–v0.4.8（双平台小项 / 网络 IPC 分发 / 安全系统集成 / Linux 发行版专项 L1a·L3·L5·L6 / macOS 主链·窗口·外观·桌面集成·WebView 深度）。
- v0.4.x 剩余：**v0.4.9**（macOS 分发/签名/公证/DMG/universal/Keychain/更新器）、**v0.4.10**（macOS 对等打磨）；**L1b**（GTK4 4.x UI 面重写）、**L4**（ARM64 容器实跑，脚本+CI 就绪待首跑）。
- 现 `ROADMAP.md:534` 的「v0.5+」仅是弹性/实验位停车场（WML H18 / 扩展 H19 / 移动 H2），**无实质 0.5–0.7 规划**——本文填补。

### 0.2 框架探索结论（Wails v3 / Tauri 2）

**Zilt 已领先或持平、本轮不动作的维度**（详见 `ROADMAP.md:15` §0.1）：

| 维度 | Zilt | Wails v3 | Tauri 2 |
|---|---|---|---|
| printToPdf / CDP 逃生口 / 截图 / 每请求头 | ✅ 有 | 无 | 无 |
| 差分更新 + 健康确认 + 回滚 | ✅ 有 | 无 delta | 无 delta |
| MCP（HTTP+stdio+resources+prompts+工具级 ACL） | ✅ 领先 | 有 MCP，无 resources/prompts/ACL | 无 |
| capability ACL + scope + isolation 密封 + 原型冻结 | ✅ 对齐/独有 | 部分 | ✅ 对齐 |
| 二进制 IPC + 背压（credit 控制帧） | ✅ 有 | Streams | raw IPC + Channel |
| 类型化 TS 绑定 codegen | ✅ **官方内置**（`src/tools/gen_bindings.zig:12`） | 有 | 社区 tauri-specta（RC） |
| CSP / 编译期资产嵌入 + gzip | ✅ 有（`src/zilt/security.zig:19,204`；`src/tools/frontend_codegen.zig`） | 有 | ✅ 有 |
| Wayland 全局快捷键（portal） | ✅ X11+portal 双路 | 未明确 | 仅 X11 |
| 窗口 mask / 子 WebView / sticky / preventOverflow | ✅ 全有 | 无/不全 | 无/不全 |

**真实缺口（本轮要补的）**：

| 缺口 | 对标 | Zilt 现状 | 落点 |
|---|---|---|---|
| **平台完整度**（macOS 分发/对等、GTK4 默认、ARM64 实跑） | 两家三平台一级公民 | macOS 差分发/打磨；Linux 差 GTK4 默认+ARM64 实跑 | **v0.5** |
| **配置 flavors + 平台 merge-patch** | Tauri `--config` / 平台特定配置（RFC 7396 合并） | 无（grep 无 flavor/merge-patch） | **v0.6** |
| **WML 声明式 HTML 绑定** | Wails WML | 无（H18，原默认不排期 `ROADMAP.md:56`） | **v0.6** |
| **第三方插件生态** | Tauri ~30 官方插件 + `tauri add` + `plugin new` + per-platform 元数据 | **无外部插件体系**：`services.Registry`（`src/zilt/services.zig:27`）是应用自定义服务；`config.zig:199` 的 `manifest_url` 是**更新器**清单，非插件 | **v0.7** |
| 外部安全审计（发布门禁） | Tauri 经 Radically Open Security 审计 | 无（有单测/冒烟，无威胁模型/审计） | v0.6 加固（自查 vs 外审见 §6） |
| 移动端 iOS/Android | Tauri 2 mobile stable；Wails iOS **仅 PoC**（CGO/模拟器/单窗口，`IOS_ARCHITECTURE.md`） | 空白 | **本轮不做**，留 1.x |

**关键架构红利（记录在案，本轮不用）**：Zilt 的 macOS `WKWebView + objc.zig`（手写 `objc_msgSend` + 运行时注册 delegate + block 布局自调）几乎可直接复用到 **iOS**（WKWebView 为 macOS/iOS 共享）。未来移动端 iOS-first 的起步成本远低于从零；Android 需 JNI + Kotlin + 系统 WebView。Wails 在移动端并不领先（iOS 仍 PoC），Tauri 是唯一成熟对标。

### 0.3 本轮战略决策（用户 2026-11-23 拍板）

1. **主轴排序**：桌面对等 →（移动）→ 生态。
2. **移动端**：本轮**移出** 0.5–0.7，留 1.x；仅保留 §0.2 的复用红利记录。
3. **稳定性姿态**：保持 0.x 快速迭代，**不做 API 冻结 / 不冲 1.0**。
4. **0.6/0.7 切分**：0.6 = DX/配置/弹性能力；0.7 = 完整第三方插件生态（生态收尾，单版本主题干净）。
5. **0.4.9/0.4.10 处置**：建议**并入 v0.5**（使三大版本自包含）——**待用户确认**（§6 Q1）。

---

## 1. v0.5 — 桌面三平台对等收口

> 分支（建议）：`feature/update/v0.5`。定位：把桌面三平台从「API 齐全」推进到「**装得上、一个样、可分发**」。不做 API 冻结。

### 1.1 目标 / 非目标

- **目标**：macOS 可签名/公证/DMG/universal 分发 + 安全存储 + 更新器；Linux GTK4 默认化 + ARM64 实跑；三平台能力矩阵文档化，差异项显式 skip。
- **非目标**：不动 Windows 已稳定的核心结构；不引入移动端；不冻结 API；不重排已领先的 IPC/安全面。

### 1.2 范围

| 子项 | 平台 | 工程量 | 实施路径 | 对标/出处 |
|---|---|---|---|---|
| macOS 分发与安全（吸收 v0.4.9） | macOS | 中-大 | `.app` Info.plist 全字段 + `.icns`；DMG `hdiutil`；codesign（Developer ID + hardened runtime + entitlements）+ `notarytool submit --wait` + `stapler`；Universal `lipo`；Keychain（Security.framework，对齐 Linux `secret:`）；更新器 ed25519 清单 + DMG 替换 vs Sparkle appcast **选型 ADR** | `ROADMAP.md:500`；`MACOS_PLAN.md:86` §5 |
| macOS 对等打磨（吸收 v0.4.10） | macOS | 中 | 系统信息（sysctl/IOKit）/Shell（NSWorkspace）/电源/主题/单实例边缘；Accessibility 标签 + VoiceOver 基本可用；能力矩阵平台列 + 差异文档 | `ROADMAP.md:520` |
| **GTK4 默认化（L1b）** | Linux | 大 | 按符号审计表（70 个 GTK4 移除符号）逐子系统移植：GdkClipboard↔GtkClipboard、GdkDrag↔gtk_drag_*、GtkPopoverMenu↔GtkMenu、gdk_toplevel↔gtk_window 几何、GtkFileDialog↔GtkFileChooserNative；完成后 `-Dgtk=gtk4` 默认，`-Dgtk=gtk3` legacy 保留一周期（D7）；CI 双栈 job | `ROADMAP.md:205`、`:198`（审计）、`:611`（D7） |
| **ARM64 实跑（L4）** | Linux | 中 | CI `linux-arm64` job 首次真跑（Docker+QEMU）；`dev-arm64-e2e.sh` qemu 冒烟 + ELF machine 断言回填；deb/AppImage 架构名核对 | `ROADMAP.md:267`、`:281` |
| 三平台能力矩阵 | 全 | 小-中 | README 能力索引增 macOS 列；差异项（透明/私有 API/沙箱/App Store/无 PDF 等）逐条文档化；契约测试「清单 ⊆ 后端 @hasDecl」防漂移（延续 L8） | `README.md:42`；`ROADMAP.md:78`（L8） |

### 1.3 验收链

1. 三平台 `zig build test` 全绿（0 失败 0 泄漏）+ `zig build`（capability 清单 + 资产嵌入）。
2. macOS：`codesign --verify --deep --strict` + `spctl -a -vv` + `stapler validate`；DMG 挂载安装；更新器旧→新端到端；Keychain 单测；冒烟硬断言（沿用 `macos.yml` grep -qF 模式）。
3. Linux：gtk3/gtk4 **双栈**单测 + Xvfb/openbox 冒烟全绿；GTK4 默认构建产物依赖面回归（portal 文件对话框/AppIndicator/分数缩放）。
4. ARM64：CI 容器内 build + qemu 冒烟通过（本机 WSL 无外网 → 以 CI 为准，不伪装本地成功）。
5. 能力矩阵：三平台列齐全，差异项 skip 且文档化；Windows 侧**零回归**。

### 1.4 风险与依赖

- **R-0.5a（GTK4 UI 重写）**：量级为 4.x UI 面重写（非补丁级，70 符号）；WebKitGTK 6.0 在 22.04/Debian 12 不可用 → gtk3 legacy 必须保留（D7/R6）。分子系统移植 + 双栈 CI 兜底。
- **R-0.5b（macOS 签名/公证）**：无证书时 CI 只做 ad-hoc + 产物上传（secrets 缺省跳过，沿用 `env.*` 判断）；Universal 需 macOS 宿主。
- **R-0.5c（更新器选型）**：ed25519+DMG 替换 vs Sparkle appcast → 实施前出 ADR（§6 Q5）。
- **R-0.5d（ARM64）**：依赖 CI remote 首跑；本机无 arm64 镜像/外网（`ROADMAP.md:283`）。

### 1.5 不做清单（v0.5）

- 不做移动端；不冻结 API；不重排 Windows 核心；不引入服务端 TLS 内置（D8 外层反代）；不默认开私有 API/常驻 drag source。

---

## 2. v0.6 — DX·配置·弹性能力

> 分支（建议）：`feature/update/v0.6`。定位：填补移动端腾出的中槽——**好用、可配置、拉新**，为 0.7 插件生态铺 DX 地基。

### 2.1 目标 / 非目标

- **目标**：配置 flavors + 平台 merge-patch；绑定 codegen 打磨；WML 声明式绑定；性能/安全加固基准；模板/doctor/docs 拉新面。
- **非目标**：不做外部插件加载（留 0.7）；不动已领先的 IPC/安全核心语义；不引入移动端。

### 2.2 范围

| 子项 | 工程量 | 实施路径 | 对标/出处 |
|---|---|---|---|
| **配置 flavors + 平台 merge-patch** | 中 | `zilt build --config <file>` JSON merge-patch（RFC 7396，数组替换不合并）；dev/beta/prod 身份分离（bundle id/名称/图标）；平台特定配置合并（`config.windows/macos/linux`）；与现有 comptime `Config` 衔接（`src/zilt/config.zig`） | Tauri configuration-files / `--config`；Zilt 无（grep 确认） |
| 绑定 codegen 打磨 | 小-中 | 事件载荷类型化（现 `generateTs(commands, events)`，`gen_bindings.zig:25`）；错误类型联合；为 0.7 插件绑定预留扩展点；输出确定性回归 | Zilt 已领先，打磨；Tauri 社区 tauri-specta |
| **WML 声明式 HTML 绑定（H18）** | 中 | runtime JS 扩 `wml` 属性解释器（纯前端，不依赖后端新面）；`data-zilt-*` 语义对齐；默认 opt-in | Wails WML；`ROADMAP.md:56`（原默认不排期 → 本轮排期，§6 Q4） |
| 性能/安全加固基准 | 中 | 启动时间/内存/IPC 吞吐基准脚本 + 回归门禁；威胁模型文档 + 安全自查清单（对标 Tauri 外部审计项：iframe 加固/fs·http scope/CSP nonce）；可选外部审计（§6 Q6） | Tauri security/审计；Zilt 有 CSP（`security.zig:204`） |
| 模板/doctor/docs | 小-中 | `create-zilt-app` 深化（`npm/create-zilt-app`）；12 模板维护 + 框架升级路径；`zilt doctor` 增强（环境/依赖/平台诊断）；能力矩阵/快速开始文档刷新 | Tauri create-tauri-app / CLI；`src/tools/cli.zig:61` |
| 浏览器扩展（H19，**实验弹性位**） | 大（实验） | WebView2 WebExtensions COM（上游实验 API）；默认不排期，跟随上游稳定度，可弹性插队/移出 | `ROADMAP.md:57`；Tauri/wry 实验 |

### 2.3 验收链

1. flavors：`--config` 构建产物身份分离实测（bundle id/名称/图标断言）；平台 merge-patch 单测（数组替换语义）。
2. 绑定：类型化事件/错误编译期测试；输出确定性（资产未变不重编）。
3. WML：声明式绑定往返冒烟（前端探针）。
4. 性能/安全：基准脚本产出数值 + 回归门禁；威胁模型文档 + 自查清单逐条核验。
5. 既有三平台单测/冒烟全量回归（0 失败 0 泄漏）。

### 2.4 风险与依赖

- **R-0.6a（flavors 与 comptime Config 衔接）**：Zilt Config 是 comptime 值（`config.zig`），运行时 `--config` merge 需在 build 期求值 → 选型 ADR（§6 Q7）。
- **R-0.6b（WML 范围）**：纯前端解释器，避免后端新面；默认 opt-in，不抢现有 runtime。
- **R-0.6c（外部审计）**：需资金/协调（Tauri 由 NLNet/NGI 资助）；本轮默认内部自查 + 威胁模型，外审为弹性（§6 Q6）。

### 2.5 不做清单（v0.6）

- 不做外部插件加载/`zilt add`（留 0.7）；不引入移动端；不重排 IPC/安全核心；H19 扩展默认不排期（实验位）。

---

## 3. v0.7 — 第三方插件生态

> 分支（建议）：`feature/update/v0.7`。定位：补 Zilt 相对 Tauri 的**最大结构缺口**——从「内置模块」到「**第三方可扩展**」。生态收尾。

### 3.1 目标 / 非目标

- **目标**：插件 manifest + 加载 + 生命周期；与 capability ACL 集成；`zilt add` / `zilt plugin new` 脚手架；内置模块插件化试点；插件分发/发现 + 文档。
- **非目标**：不一次性迁移全部内置模块（试点验证扩展点即可）；不引入移动端；不破坏零依赖文化（加载机制选型见 §6 Q2）。

### 3.2 范围

| 子项 | 工程量 | 实施路径 | 对标/出处 |
|---|---|---|---|
| **插件 manifest + 加载 + 生命周期** | 大 | manifest（name/version/platforms/permissions/入口）；加载机制**选型 ADR**（静态编译期注册 / 动态 `.so`·`.dll` dlopen / 进程外 MCP·server 复用）；生命周期钩子 setup/on_event/on_drop；per-platform 支持元数据 | Tauri plugin（Cargo crate + guest-js + permissions）；Zilt 无（`services.zig:27` 仅应用服务） |
| **与 capability ACL 集成** | 中 | 插件命令纳入 permissions/scope/capabilities（`src/zilt/security.zig`）；插件自带权限声明（Tauri `permissions/*.toml` 等价物）；deny 优先；运行时授权沿用 | Tauri permissions/scopes/capabilities；Zilt ACL 已对齐 |
| `zilt add` / `zilt plugin new` | 中 | CLI 增 `add <plugin>`（拉取+接线+权限注入）/ `plugin new`（脚手架：manifest+入口+绑定+权限）；复用 `src/tools/cli.zig` 分派 | Tauri `tauri add` / `tauri plugin new` |
| 内置模块插件化试点 | 中 | 选 1–2 个内置能力（如 store/sql/http）抽成插件形态验证扩展点；**保留内置默认**，插件化为可选路径 | 验证扩展点，非全量迁移 |
| 插件分发/发现 + 文档 | 小-中 | 分发形态选型（git-based / 静态 registry JSON / npm-like，§6 Q3）；插件开发指南 + 权限模型文档 + 示例插件 | Tauri plugins-workspace / awesome-tauri |

### 3.3 验收链

1. 外部插件加载 + 命令往返冒烟；ACL **允许/拒绝**双向断言（deny 优先）。
2. `zilt plugin new` 脚手架生成可构建插件；`zilt add` 接线 + 权限注入实测。
3. 至少 1–2 个内置能力插件化试点往返；内置默认路径零回归。
4. per-platform 元数据驱动的能力守卫（缺失平台降级 + 文档）。
5. 三平台单测/冒烟全量回归（0 失败 0 泄漏）。

### 3.4 风险与依赖

- **R-0.7a（加载机制 vs 零依赖文化）**：动态 `.so/.dll` 引入运行时加载面（已有 dlopen 可选依赖先例：libsecret/sqlite/appindicator）；静态注册最贴合零依赖但牺牲第三方独立性；进程外复用 MCP/server 最安全但 IPC 开销。**最大架构决策，实施前 ADR**（§6 Q2）。
- **R-0.7b（插件安全边界）**：第三方代码信任边界 → ACL + scope 强制 + 进程隔离选项；威胁模型延续 0.6。
- **R-0.7c（生态冷启动）**：solo 维护，先试点 + 示例插件 + 文档，不追求插件数量。

### 3.5 不做清单（v0.7）

- 不全量迁移内置模块；不引入移动端；不破坏零依赖文化（除非 ADR 显式接受）；不做插件市场托管服务（先 git/静态 registry）。

---

## 4. 跨版本持续跟踪（非版本项）

- **CompositionController 渲染**：上游 WebView2 运行时缺陷（`ROADMAP.md:542`），每版本带 `ZILT_COMP_ENABLE=1` 探测，修复后重评 SnapAssist。
- **上游追踪**：Wails v3.2.x / Tauri 2.13+（及 v3-alpha / CEF runtime / Verso）发布时做下一轮差距刷新（第五轮）。
- **移动端立项（1.x）**：本轮移出；iOS-first 复用 macOS WKWebView/objc 红利记录在 §0.2；开题时另出 `DESIGN_mobile_*.md` + ADR。
- **gtk3 legacy 移除时间点**：由发行版 EOL 与使用数据决定（D7），不在本轮硬性移除。

---

## 5. 风险与依赖（汇总）

| 编号 | 风险 | 缓解 |
|---|---|---|
| R-0.5a | GTK4 4.x UI 面重写（70 符号） | 分子系统移植 + 双栈 CI + gtk3 legacy 保留 |
| R-0.5b | macOS 签名/公证证书/宿主依赖 | 无证书 ad-hoc + 产物上传；CI macos-15 |
| R-0.5c | macOS 更新器选型 | 实施前 ADR（ed25519+DMG vs Sparkle） |
| R-0.5d | ARM64 本机无外网/镜像 | 以 CI 首跑为准，不伪装本地成功 |
| R-0.6a | flavors 与 comptime Config 衔接 | build 期求值选型 ADR |
| R-0.6c | 外部审计资金/协调 | 默认内部自查 + 威胁模型；外审弹性 |
| R-0.7a | 插件加载 vs 零依赖文化 | **最大决策**，实施前 ADR（静态/动态/进程外） |
| R-0.7b | 第三方插件安全边界 | ACL+scope 强制 + 进程隔离选项 + 威胁模型 |

---

## 6. 待决策（实施前需用户拍板，不假设默认）

- **Q1（0.5 边界）**：现 ROADMAP 的 v0.4.9/v0.4.10 **并入 v0.5**（推荐，三大版本自包含）vs 先按原编号发布再开 v0.5？
- **Q2（0.7 插件加载机制，最大架构决策）**：静态编译期注册（最贴零依赖）/ 动态 `.so`·`.dll` dlopen（已有可选依赖先例）/ 进程外（MCP·server 复用，最安全）？需 ADR。
- **Q3（0.7 插件分发形态）**：git-based / 静态 registry JSON / npm-like？
- **Q4（0.6 WML）**：H18 原 D2「默认不排期」→ 本轮排期确认？还是仍留弹性位？
- **Q5（0.5 macOS 更新器）**：ed25519 清单 + DMG 替换 vs Sparkle appcast provider？需 ADR。
- **Q6（0.6 安全加固）**：内部自查清单 + 威胁模型（推荐，solo 可行）vs 外部审计（Tauri 模式，需资金/协调）？
- **Q7（0.6 flavors 语法）**：`--config` JSON merge-patch（Tauri 同语义）vs Zig comptime 变体？与现有 `Config` 衔接方式。
- **Q8（流程）**：分支命名 `feature/update/vX.Y` + PR 合并（沿用文化）？每版本实施前是否各出 `DESIGN_vX.Y_*.md`？
- **Q9（0.5 ARM64/CI）**：本轮是否建立 remote / 触发 CI `linux-arm64` 首跑（本机 WSL 无外网）？
- **Q10（0.5 收口 vs L1b，2026-11-26 回填时新增）**：L1b（GTK4 默认化）剩余五项（托盘 SNI / 菜单栏 / 拖出 /
  按域清 cookie / 截图真机验证），是否仍作为 v0.5 的收口前置？
  **A**：先做 L1b 再开 v0.6；**B**：L1b 移出 v0.5（GTK4 继续作为 CI 覆盖的 opt-in 变体），v0.5 以 CI 全绿收口，
  L1b 作为 **v0.6.1** 独立切片。影响：A 推迟 DX 工作；B 默认栈仍是 GTK3（能力最全），GTK4 默认化顺延一个 minor。

---

## 7. 全局不做清单（本轮 0.5–0.7）

- **移动端 iOS/Android**（移出本轮，留 1.x；复用红利已记录）。
- **API 冻结 / 1.0 发布**（保持 0.x 快速迭代）。
- **自研浏览器引擎**（沿用系统 WebView：WebView2 / WKWebView / WebKitGTK）。
- **服务端 TLS 内置**（D8：外层反代承担）。
- **常驻 drag source 默认开**（H17 默认关）/ **私有 API 默认开**（macOS 透明/材质 opt-in）。
- **无关重构**（不重排已领先的 IPC/安全/更新核心）。
- **插件市场托管服务**（0.7 先 git/静态 registry，不做托管）。

---

> 下一步：本文经用户复核批准后，**按版本逐个**出 `DESIGN_vX.Y_*.md` 细化 + 实施计划，再动代码/依赖/配置。本文不触发任何实施。