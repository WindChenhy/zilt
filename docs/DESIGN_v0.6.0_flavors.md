# v0.6.0 设计：配置 flavors + 平台 merge-patch

> 制定：2026-11-27（v0.5.11 收口后启动）。基线：tag **v0.5.11**（a20483c）。
> 上游 spec：[DESIGN_v0.5-v0.7_roadmap.md](DESIGN_v0.5-v0.7_roadmap.md) §2.2「配置 flavors + 平台 merge-patch」。
> 对标：Tauri 2 `--config` / 平台配置文件（RFC 7396 JSON merge-patch）；本文只覆盖 v0.6.0 的第一个切片。

## 1. 目标 / 非目标

**目标**

1. `zig build -Dflavor=<name>` 与 `zilt build --flavor <name> --config <file>` 可用；同一份代码产出
   dev / beta / prod 三种**身份分离**的构建（app 名、bundle id、图标、单实例键、更新通道）。
2. 平台 overlay：`zilt.<platform>.json`（`windows` / `macos` / `linux`）在 base 之上合并；
   合并语义严格按 **RFC 7396 JSON Merge Patch**（对象递归、数组整体替换、`null` 删除键）。
3. 合并结果在 **build graph 配置期**求值一次，打包/资源/运行时身份读同一份 `ResolvedFlavor`，
   不允许两处各算一遍。
4. 纯函数合并引擎有单测（含数组替换、null 删除、深合并、非法 JSON）。

**非目标（本切片不做）**

- 不改 `Config` 的全部字段；首版只覆盖**身份与分发**字段（见 §3）。
- 不做运行时热切换 flavor（身份是构建期常量）。
- 不引入服务端 flavor 下发；不碰 ACL/能力清单（放到 0.6.0b）。
- 不改变 `src/project.zig` 作为「默认 base」的地位。

## 2. 现状约束

- `src/project.zig` 是 **comptime 常量**，被 `build.zig` 直接 `@import`（打包、exe 名、bundle id 都用它）；
  应用侧经 `src/app_meta.zig` 再导出。
- `src/zilt/config.zig` 也是 comptime `Config`，但身份字段大多来自 `project.zig`。
- 因此 **不能** 在运行时读 JSON 覆盖身份；必须在 build graph 配置期算出结果，再投影成
  build options（app 侧）与打包参数（build.zig 侧）。

## 3. 首版覆盖字段

| 字段 | 用途 | 备注 |
|---|---|---|
| `app_name` | 窗口标题、安装器显示名 | 平台 overlay 可改（如 macOS 带空格） |
| `app_id` | bundle id / desktop 文件 / 单实例键 | 每个 flavor 必须唯一 |
| `version` | 运行时版本、安装器版本 | 允许 flavor 覆盖（beta 可带后缀？首版仍要求 semver） |
| `exe_name` | 产物名 | 默认 `<app_id 末段>`；Windows 自动补 `.exe` |
| `icon` | 窗口/托盘/安装器图标 | 相对项目根；null = 内置 |
| `publisher` | 安装器/签名元数据 | |
| `update_channel` | 更新器清单通道 | stable / beta / dev |
| `single_instance_key` | 单实例命名空间 | 缺省由 `app_id` 派生 |

**后续切片（0.6.0b）**：`frontend.dev_url` / `capabilities` / `security.csp` / `window` 默认值。

## 4. 解析顺序与文件布局

```
src/project.zig                 # base（comptime 默认值）
zilt.config.json                # 可选：项目级 base overlay
zilt.<platform>.json            # 可选：平台 overlay（windows|macos|linux）
zilt.<flavor>.json              # 可选：flavor overlay（dev|beta|prod 或自定义名）
--config <file>                 # 可选：命令行 overlay（最高优先级）
```

合并顺序（后者覆盖前者，RFC 7396）：

```
project 默认值 → zilt.config.json → zilt.<platform>.json → zilt.<flavor>.json → --config
```

- `-Dflavor=beta` 等价于加载 `zilt.beta.json`；文件缺失时报错（显式声明 `flavors` 表时）。
- `--config` 允许匿名 overlay，不需要预定义 flavor（CI 一次性构建用）。
- 数组一律整体替换（不做元素级合并），与 Tauri/RFC 7396 一致。
- `null` 删除键；删除后回落到下一层默认值（或空）。

## 5. 实现路径

### 5.1 纯函数合并引擎（本切片先落地）

新增 `src/zilt/flavor_merge.zig`（无平台依赖，可单测）：

```zig
pub const Patch = std.json.Value; // 对象
pub fn merge(alloc, base: Value, patch: Value) !Value; // RFC 7396
pub fn mergeAll(alloc, base: Value, patches: []const Value) !Value;
pub fn projectIdentity(alloc, value: Value) !Identity; // 只取 §3 字段，缺省用 base
pub const Identity = struct { app_name: []u8, app_id: []u8, ... };
```

单测覆盖：对象递归、数组替换、`null` 删除、类型冲突（标量覆盖对象）、空 patch、非法输入。

### 5.2 build graph 投影

`build.zig` 在 `b.option([]const u8, "flavor", ...)` 之后：

1. 读 `project.zig` 的默认 `Identity`；
2. 依次读存在的 overlay JSON（`b.build_root.handle.readFileAlloc`）；
3. `mergeAll` → `ResolvedFlavor`；
4. 打包/安装器用 `ResolvedFlavor`（替换现在直接读 `project.app_name` 的位置）；
5. `const opts = b.addOptions(); opts.addOption([]const u8, "app_name", ...)` 等，挂到 app 模块
   `build_options`；`src/zilt/identity.zig` 从 `build_options` 取值，缺省时回落到 `project.zig`。

> **为什么用 build options 而不是生成源码**：不污染 `src/`、天然参与缓存指纹、无需 `@import` 匿名文件；
> 代价是 `project.zig` 仍被 build.zig 直接引用（作为 base），应用侧改读 `identity.zig`。

### 5.3 CLI

`zilt build --flavor beta --config ci.json` 只做参数转译：
`zig build -Dflavor=beta -Dconfig=ci.json`（`-Dconfig` 由 build.zig 读取，不经过 CLI 解析 JSON）。
`zilt info` 增 `flavor` / `app_id` 字段，便于验收断言。

## 6. 验收链

1. `zig build test`：合并引擎单测全绿（0 失败 0 泄漏）。
2. 三份产物身份分离：`dev` / `beta` / `prod` 各构建一次，断言
   `zilt info --json` 的 `app_name` / `app_id` / `channel` 互不相同；安装器/plist 同名同值。
3. 平台 overlay：仅 `zilt.macos.json` 改 `app_name`，Linux/Windows 产物不变。
4. RFC 7396 语义：`--config` 把数组整体替换、`null` 删除键，产物断言 + 单测双证。
5. 缓存确定性：同一输入连续构建不重编身份模块（`zig build --summary` 观察 cached）。
6. 三平台既有单测/冒烟全量回归（v0.5.11 基线）。

## 7. 风险

| 编号 | 风险 | 缓解 |
|---|---|---|
| R-0.6.0a | `project.zig` 被 build.zig 直接引用，身份改由 options 后出现两套来源 | 明确「build.zig 用 ResolvedFlavor；app 用 identity.zig」；加一条编译期断言两者默认值一致 |
| R-0.6.0b | macOS Info.plist / Windows 资源 / Linux desktop 文件各自读身份 | 打包脚本统一从 `ResolvedFlavor` 取；模板 E2E 覆盖 |
| R-0.6.0c | `app_id` 冲突导致单实例互踢 | flavor 表启动时校验唯一性；文档要求 dev/beta/prod 三套 id |
| R-0.6.0d | 数组替换与用户预期不符 | 文档显式说明（RFC 7396）；单测锁定 |

## 8. 切片

- **0.6.0a（本切片）**：合并引擎 + build graph 解析 + 身份投影（app_name/app_id/version/exe_name/icon/publisher/channel）+ CLI 转译 + 单测。
- **0.6.0b**：frontend/capabilities/CSP/window 默认值纳入 overlay；`zilt info` 完整回显。
- **0.6.0c**：模板加 `zilt.<flavor>.json` 示例；文档（快速开始「一份代码三种产物」）。

> 待拍板：`app_id` 是否允许 flavor 覆盖（推荐允许，且强制唯一）；`version` 是否允许带预发布后缀
> （`0.6.0-beta.1` 需放宽现有 semver 单测）。实施前确认。
