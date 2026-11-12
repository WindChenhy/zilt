# 前端工程化调研：Tauri 2 / Wails v3 与 Zilt 的对齐方案

> 调研日期：2026-11-07。调研基线：Tauri 2.12.5（stable）/ tauri-v3.0.0-alpha.6；Wails v3.1.0（stable，2026-11-01 发布）/ v3.2.0-nightly。
> 调研方法：官方文档 + GitHub 源码逐文件核对（Tauri `dev` 分支、Wails `master` 分支即 v3 主线）。
> 来源标注：【一手】= 官方文档原文或直接阅读的源码；【二手】= 社区讨论/搜索结果，未经源码复核。

---

## TL;DR

1. **两者前端工程化的本质是同一件事的三段式编排**：`前端构建命令 → devUrl/资产目录 → webview 加载`。Tauri 把这段编排写死在 Rust CLI 里（配置驱动），Wails 把它摊开在项目 `Taskfile.yml` + `build/config.yml` 里（文件驱动、用户可改）。
2. **dev 模式的关键差异在"webview 导航到哪"**：
   - **Tauri**：webview **直接导航**到 `devUrl`（如 `http://localhost:1420`），HMR 完全由 Vite 等 dev server 承担，Tauri 不代理。【一手】
   - **Wails v3.1.x**：主窗口导航 URL 会被改写为 `http://wails.localhost:{vite端口}/`——同样**直连** dev server（`GetStartURL` 源码确认）；同时应用自己的 AssetServer 还保留一层 **反向代理**（`httputil.NewSingleHostReverseProxy`，带 50 次重试/连接池调优），让打到应用资产 origin 的请求也能转发到 vite。【一手】所以 Wails 是"直连为主 + 反代兜底"的混合形态。
3. **生产嵌入的差异**：Tauri 在 **cargo 编译期** 由 `tauri-codegen` 把 `frontendDist` 变成 brotli 压缩（release q9）的 `include_bytes!` + `phf::Map` 完美哈希表，运行时按路径查找、brotli 解码、CSP hash 注入；Wails 用 **`//go:embed all:frontend/dist`**（无压缩）+ `http.Handler` 文件服务器。Zilt 现有的 `@embedFile` 资产表与 Wails 同构，缺的是"整目录自动枚举 + codegen"。
4. **对 Zilt 的最小可用路径（Phase A）**：不需要新 CLI、不需要 Taskfile——
   - `zilt.Config` 增加 `frontend` 段（对齐 Tauri 四字段语义）；
   - `build.zig` 新增一个 **assets codegen 步骤**：遍历 `frontend/dist` → 生成 `assets.zig`（`@embedFile` 相对路径表）→ 以匿名 module 接入 `app_config`；
   - 新增 `zig build dev` step：spawn 前端 dev 命令（Windows 上 `cmd /S /C` 包装 `.cmd` shim）→ TCP 轮询等 devUrl（Tauri 策略：2s 间隔 × 90 次）→ 启动 exe 并注入 `ZILT_DEV_URL`；
   - `zig build gen` 的 TS 绑定输出迁移到 `frontend/bindings/`（对齐 Wails 惯例）。
   模板（Phase B）与 HMR 反代/资产预压缩（Phase C）后置。

---

## 1. Tauri 2 前端工程化详解

### 1.1 `tauri.conf.json` 的 build 段

来源：[v2.tauri.app/reference/config](https://v2.tauri.app/reference/config/)【一手，官方文档】

| 字段 | 类型 | 默认 | 语义 |
|---|---|---|---|
| `build.beforeDevCommand` | `string \| { script, cwd?, wait? }` | `null` | "A shell command to run before tauri dev kicks in"。对象形式多一个 `wait`：**是否阻塞等待命令退出**（dev server 场景为 `false`，即后台 spawn）。自动注入 `TAURI_ENV_*` 环境变量。 |
| `build.devUrl` | `string`（URI） | `null` | "The URL to load in development"。指向前端 dev server（Vite 等）。**不设**则 CLI 用内置 dev server 服务 `frontendDist`。 |
| `build.beforeBuildCommand` | `string \| { script, cwd? }` | `null` | "A shell command to run before tauri build kicks in"。注意对象形式**没有 `wait` 字段**（build 场景必然阻塞等待）。 |
| `build.frontendDist` | `FrontendDist`：`URL 字符串 \| 目录路径 \| 路径数组` | `null` | 三种形态：① **URL**："An external URL that should be used as the default application URL. **No assets are embedded in the app in this case.**"；② **目录**：相对路径递归读入并**嵌入二进制**，以 `index.html` 为入口；③ **文件数组**：逐文件嵌入，落在根路径。 |

另有关联字段：`build.beforeBundleCommand`（打包前钩子）、`build.runner`（替换 cargo）、`build.additionalWatchFolders`、`build.features`。

模板示例（create-tauri-app `_base_/src-tauri/tauri.conf.json`）：【一手】

```json
{
  "build": {
    "beforeDevCommand": "npm run dev",
    "devUrl": "http://localhost:1420",
    "beforeBuildCommand": "npm run build",
    "frontendDist": "../dist"
  }
}
```

### 1.2 CLI 分发形态

- `@tauri-apps/cli`（npm 包，含各平台二进制 `@tauri-apps/cli-win32-x64-msvc` 等）与 `cargo tauri`（crates.io `tauri-cli`）是**同一个 Rust CLI** 的两种分发渠道；npm 包的 `"tauri"` script 让用户以 `npm run tauri dev` 调用。【一手：v2.tauri.app/develop 中 `npm run tauri dev` 用法 + create-tauri-app 模板 package.json 中 `"tauri": "tauri"`】
- CLI 是"编排者"而非构建系统：它自己不认识 npm/vite 的任何细节，只认识配置里的 shell 命令与 URL。

### 1.3 `tauri dev` 完整流程（源码核对）

来源：[crates/tauri-cli/src/dev.rs](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-cli/src/dev.rs)【一手】

1. **spawn beforeDevCommand**：Windows 上经 `cmd /S /C <script>`，其他平台 `sh -c`；`wait: true` 则同步执行且非零退出即失败，否则作为后台 `SharedChild` spawn，stdio 管道直通 CLI；看护线程在子进程非零退出时结束 CLI，Ctrl+C 时杀掉子进程（exit 130）。
2. **等 devUrl 可达**（除非 `--no-dev-server-wait`）：把 devUrl 的 host/port 解析为 socket 地址，**TCP connect 轮询**：
   ```rust
   let sleep_interval = std::time::Duration::from_secs(2);   // 每 2s 一次
   let timeout_duration = std::time::Duration::from_secs(1); // 单次 connect 超时 1s
   let max_attempts = 90;                                    // 最多 90 次 ≈ 180s
   // if std::net::TcpStream::connect_timeout(addr, timeout_duration).is_ok() { break }
   ```
   期间每几轮打印 "Waiting for your frontend dev server to start on {url}..."；90 次失败后报错退出（exit 1）。
3. **devUrl 缺省时的内置 dev server**：若未配置 `devUrl` 且 `frontendDist` 是存在的目录，CLI 启动 `builtin_dev_server::start(path, ip, options.port)`（默认端口 **1430**）静态服务该目录，并把生成的 URL 写回 config（`"devUrl": server_url`）。【一手】
4. **启动 app**：编译 Rust（增量）并运行，webview 加载 `devUrl`。
5. **文件监听**：默认监听 `src-tauri` 及其依赖 crate，变更则重编译重启；`--no-watch` 关闭；`.taurignore`（gitignore 语法）排除路径。【一手 + 官方文档】

**内置 dev server 的"热重载"**（`frontendDist` 直服务场景）：[crates/tauri-cli/src/dev/builtin_dev_server.rs](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-cli/src/dev/builtin_dev_server.rs)【一手】——axum 静态文件服务 + 路径 scope 校验（防穿越）+ `path.html` / `path/index.html` 回退 + HTML 响应**注入 auto-reload 脚本**（`include_str!("./auto-reload.js")`），脚本连 `ws://{address}/__tauri_cli`；notify 监听（1s 去抖）文件变化后广播 `{"reload": true}` 让页面整页 reload。注意这是**整页刷新式 reload**，不是 HMR；真正的 HMR 只存在于 devUrl 直连 Vite 的场景。

### 1.4 `tauri build` 完整流程（源码核对）

来源：[crates/tauri-cli/src/build.rs](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-cli/src/build.rs)【一手】

1. `setup()`：加载/合并配置 → **执行 `beforeBuildCommand`**（`helpers::run_hook`，cwd 为 frontend 目录，注入 `TAURI_ENV_*`）→ **校验 `frontendDist`**：
   - 目录不存在 → 报错 "Unable to find your web assets, did you forget to build your web app?"；
   - `frontendDist` 含 `node_modules`、`src-tauri`、cargo target 子目录 → 拒绝构建（防误嵌）。
2. `interface.build(...)`：调 cargo build。**资产嵌入发生在 cargo 编译期**：`tauri-build`/`tauri-codegen` 在处理 `generate_context!()` 时执行（见 1.5）。
3. 打包（bundle）：`--no-bundle` 可跳过；否则按 `bundle.active`/`--bundles` 走 NSIS/MSI 等（Zilt 的对标物）。

### 1.5 资产嵌入机制：tauri-codegen（编译期）

来源：[crates/tauri-codegen/src/embedded_assets.rs](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-codegen/src/embedded_assets.rs)、[crates/tauri-utils/src/assets.rs](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-utils/src/assets.rs)、[crates/tauri/src/manager/mod.rs](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri/src/manager/mod.rs)、[crates/tauri/src/protocol/tauri.rs](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri/src/protocol/tauri.rs)、[crates/tauri/Cargo.toml](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri/Cargo.toml)（`compression` 为默认 feature）【一手】

- **遍历**：`WalkDir` 遍历 `frontendDist`，只收文件；key 为去掉前缀的相对路径（`AssetKey`，统一 Unix 分隔符）。
- **压缩**：`compression` feature（默认开启）下每个资产先 **brotli 压缩**写入 `OUT_DIR/tauri-codegen-assets/{sha256}.{ext}`；质量：debug 构建 `quality = 2`，release `quality = 9`。**输出文件名用内容 SHA-256 哈希**，已存在则跳过压缩（缓存）并 `backdate`（回拨 mtime 保增量）。不压缩原始文件也要 `const _: &[u8] = include_bytes!(#input);` 一下——借 dead-code elimination 建立构建依赖跟踪（文件变了会重编）。
- **代码生成**：不是 `include_dir`，而是自定义 `ToTokens` 生成 `phf_map!`（**编译期完美哈希表**），每个条目 `include_bytes!(压缩产物)`：
  ```rust
  pub struct EmbeddedAssets {
      assets: phf::Map<&'static str, &'static [u8]>,          // key → brotli bytes
      global_hashes: &'static [CspHash<'static>],             // 全局 CSP hash
      html_hashes: phf::Map<&'static str, &'static [CspHash<'static>]>, // 按 HTML 文件的 CSP hash
  }
  ```
- **CSP 处理**：对 `js`/`mjs` 外链脚本与 inline `<script>`（按 HTML 文件分桶）、CSS 做 SHA-256，生成 `'sha256-…'` hash 列表；运行时把 hash 注入 `script-src`/`style-src`，inline nonce 运行时随机生成。可用 `dangerous_disable_asset_csp_modification` 关闭。hash 排序以保证生成代码跨机器稳定（不依赖文件系统遍历顺序）。
- **运行时查找**（custom protocol `tauri://localhost` / `https://tauri.localhost`）：`manager.get_asset(path)` 按精确路径 → `path.html` → `path/index.html` → `index.html` 回退链查 phf map；命中后 **brotli 解码**（`brotli::BrotliDecompress`）返回字节 + mime + csp header。**没有 ETag/304 机制**（dev 移动端代理路径上有 dev-only 的 response cache，生产无）。
- **体积影响**：brotli q9 显著小于原始体积，但解码后驻留内存；**增量构建**靠 OUT_DIR 内容哈希缓存 + backdate，资产未变时 codegen 快速通过。

### 1.6 create-tauri-app 模板体系

来源：[github.com/tauri-apps/create-tauri-app](https://github.com/tauri-apps/create-tauri-app)（`dev` 分支 `templates/` 目录）【一手】

- **模板清单**（`templates/` 实际目录）：
  `template-vanilla`、`template-vanilla-ts`、`template-vue`、`template-vue-ts`、`template-svelte`、`template-svelte-ts`、`template-react`、`template-react-ts`、`template-preact`、`template-preact-ts`、`template-solid`、`template-solid-ts`、`template-angular`、`template-yew`、`template-leptos`、`template-sycamore`、`template-dioxus`、`template-blazor`
- **语言/框架分组**：Rust → Vanilla/Yew/Leptos/Sycamore；TS/JS → Vanilla/Vue/Svelte/React/Solid/Angular/Preact；.NET → Blazor。
- **包管理器**：安装途径 `npm / yarn / pnpm / bun / deno / cargo` 均可跑 `create-tauri-app`（如 `bunx create-tauri-app`）；模板本身与包管理器无关（package.json 通用），CLI 参数选择管理器决定提示词与 lockfile。
- **目录组织**（关键结构，`template-vue-ts` 实测）：
  ```
  templates/
    _assets_/            # 各框架共用静态资源（vite.svg 等）
    _base_/src-tauri/    # 跨模板共享的 Rust 壳（tauri.conf.json.lte、Cargo.toml.lte、capabilities、icons、build.rs、src/）
    template-vue-ts/     # 前端部分：package.json.lte、vite.config.ts.lte、index.html、src/、tsconfig*
  ```
  模板文件用 `.lte` 后缀（`{% %}` 条件/占位符），如 `{% before_dev_command %}`、`{% dev_url %}`、`{% frontend_dist %}`——**同一份 `_base_` 按框架注入不同的 build 四件套**。
- **Vite 配置约定**（每个模板内嵌）：
  ```ts
  server: {
    port: 1420,
    strictPort: true,            // 端口被占直接失败，防止 devUrl 指向别的服务
    watch: { ignored: ["**/src-tauri/**"] },  // 防止 Rust 侧变更触发前端重建
  }
  ```
  移动端场景用 `TAURI_DEV_HOST` 环境变量配置 `host`/`hmr`。【一手】

### 1.7 HMR 机制确认

来源：[v2.tauri.app/develop](https://v2.tauri.app/develop/) + dev.rs【一手】

- **HMR 完全由前端 dev server 承担**：webview 加载 `devUrl` 后" behaves like a browser"，Vite 的 HMR websocket 直接连 `http://localhost:1420`，**Tauri 不代理、不参与**。文档原话："You can make changes to your web app, and if your tooling supports it, the webview should update automatically."
- 唯一的跨域要求：前端页面从 `http://localhost:1420` 发 IPC → custom protocol origin 的 IPC handler，Tauri 在 IPC 层处理（`WithGlobalTauri` 或 `@tauri-apps/api`），不经过 HTTP。
- **localhost plugin**：[v2.tauri.app/plugin/localhost](https://v2.tauri.app/plugin/localhost/)【一手】——生产构建默认用 custom protocol origin（`tauri://localhost`），部分库（cookie/auth/service worker）要求真 HTTP origin，该插件改为在 Rust 侧起一个 localhost HTTP server 服务内嵌资产（`WebviewUrl::External(Url::parse("http://localhost:9527")...)`）。文档明确警告 "considerable security risks"，仅在确需 HTTP origin 时使用。**它解决的是生产 origin 问题，与 devUrl 无关**。

### 1.8 monorepo / 多前端

- 官方无专门 monorepo 页；实践路径：【二手：GitHub Discussion #13941 + 社区方案，未逐一源码复核】
  1. **每个前端配一个 src-tauri**（每个 `tauri.conf.json` 指向各自的 `frontendDist`/`devUrl`）；
  2. **同一 app 多配置**：`tauri dev --config tauri.web.conf.json` 切换（`-c/--config` 官方支持 JSON/JSON5/TOML 合并，"Configurations are merged in the order they are provided"【一手：v2.tauri.app/reference/cli】）。
- `frontendDist` 指向远程 URL：官方语义支持（"No assets are embedded"），用于应用壳指向已部署站点。【一手：config 参考】

---

## 2. Wails v3 前端工程化详解

> 版本基线：`master` 分支 = v3.1.0（2026-11-01 发布 v3.1.0，另有 v3.2.0-nightly.20261103）。【一手：GitHub Releases API】

### 2.1 总体架构：CLI = Task 执行器，Taskfile = 构建系统

**这是与 Tauri 最关键的差异。** 源码确认：

- [v3/cmd/wails3/main.go](https://github.com/wailsapp/wails/blob/master/v3/cmd/wails3/main.go)【一手】：`wails3` 子命令 = `init / dev / task / generate bindings / generate build-assets / update build-assets / doctor / package / ...`。
- [v3/internal/commands/task.go](https://github.com/wailsapp/wails/blob/master/v3/internal/commands/task.go)【一手】：`wails3 task` **内嵌了 go-task 的 Wails fork**（`import "github.com/wailsapp/task/v3"`），用 `task.Executor` 在项目目录跑 Taskfile 任务。**CLI 本身不调用 npm/pnpm/bun**——所有包管理器调用都写在项目 `Taskfile.yml` 的任务定义里。
- [v3/internal/commands/init.go](https://github.com/wailsapp/wails/blob/master/v3/internal/commands/init.go)【一手】：`wails3 init` = 模板抽取（`_common` + 框架模板）→ `go mod tidy` → **`GenerateBuildAssets`**（生成项目 `build/` 目录：`config.yml`、`build/Taskfile.yml`（公共任务）、`build/<platform>/Taskfile.yml`（平台任务）、图标、NSIS 工程等）。
- 项目根 `Taskfile.yml`（来自 [`_legacy/Taskfile.tmpl.yml`](https://github.com/wailsapp/wails/blob/master/v3/internal/templates/_legacy/Taskfile.tmpl.yml)）【一手】：
  ```yaml
  includes:
    common:  ./build/Taskfile.yml        # 公共任务（frontend/go/bindings）
    windows: ./build/windows/Taskfile.yml # 平台任务（build/package/nsis/msix/sign）
    # darwin/linux/ios/android 同理
  tasks:
    build:   { cmds: [ { task: "{{.GOOS}}:build" } ] }   # → windows:build
    package: { cmds: [ { task: "{{.GOOS}}:package" } ] }
    run:     { cmds: [ { task: "{{.GOOS}}:run" } ] }
    dev:     { cmds: [ "wails3 dev -config ./build/config.yml -port {{.VITE_PORT}}" ] }
  ```
  所以 `wails3 dev` 与 `wails3 task dev` 殊途同归：前者直接跑 Dev 命令，后者跑 Taskfile 的 `dev` 任务再调 `wails3 dev`。【一手】
- 公共任务（[`v3/internal/commands/build_assets/Taskfile.tmpl.yml`](https://github.com/wailsapp/wails/blob/master/v3/internal/commands/build_assets/Taskfile.tmpl.yml)）【一手】核心条目：
  - `install:frontend:deps:{npm,bun,pnpm,yarn}`：按 `PACKAGE_MANAGER` 变量分派，带 `sources/generates` 缓存（`package.json + lockfile → node_modules`）与 preconditions（工具不存在给中文友好报错）。
  - `build:frontend`：`deps: install:frontend:deps + generate:bindings` → `frontend:run` 执行 package.json 的 `build`（DEV=true 时执行 `build:dev`）；带 `run: once` 防并发竞争（#4637）。
  - `generate:bindings`：`wails3 generate bindings -clean=true -ts ...`，`generates: frontend/bindings/**/*`，`sources` 含 `**/*.go`——Go 代码变更即重生成。
  - `dev:frontend` → `frontend:dev:{npm,yarn,pnpm,bun}`：`npm run dev -- --port {{.VITE_PORT}} --strictPort`。
- 平台任务（[`build_assets/windows/Taskfile.yml`](https://github.com/wailsapp/wails/blob/master/v3/internal/commands/build_assets/windows/Taskfile.yml)）【一手】：`build` → `go build -tags production -trimpath -ldflags="-w -s -H windowsgui"`；`package` → NSIS（默认）或 MSIX；`generate:syso` 等。**CLI 只提供原子命令（generate syso/icons/webview2bootstrapper、tool msix/sign），编排全在 Taskfile。**

**结论【一手】**：Wails v3 的 CLI 不直接调 npm/pnpm/bun/yarn；包管理器集成 100% 位于生成到用户项目里的 Taskfile 模板（npm/yarn/pnpm/bun 四种 runner 全覆盖，无 deno 任务）。用户改构建 = 改自己项目里的 Taskfile（Tauri 用户改配置字段，自由度与责任都在用户侧）。

### 2.2 `wails3 init` 模板体系

来源：[v3/internal/templates/](https://github.com/wailsapp/wails/tree/master/v3/internal/templates)（master）【一手】

- **内置模板**（`templates.go::init()` 按 `_` 前缀排除法枚举目录）：
  `base`、`vanilla`、`vanilla-js`、`vue`、`vue-js`、`react`、`react-js`、`svelte`、`svelte-js`（`-js` 后缀为 JavaScript 变体；TS 拥有裸名——`template.yaml` 中 `typescript: true`）。**官方内置无 htmx 模板**；htmx 场景由 `vanilla` 模板或社区模板覆盖（`wails3 init -l` 列出，支持本地路径与远程 git URI 模板，`splitTemplateURI`/`getRemoteTemplate` 源码支持）。【一手】
- **目录结构**（vue 模板实测）：
  ```
  v3/internal/templates/
    _common/            # 所有模板共享：main.go.tmpl、go.mod.tmpl、go.sum.tmpl、gitignore.tmpl、greetservice.go、README、frontend/ 公共资源
    vue/                # template.yaml + frontend/（package.json.tmpl、vite.config.ts、src/App.vue...）+ .vscode
    _legacy/            # 生成根 Taskfile.yml（Taskfile.tmpl.yml）
    base/               # NEXTSTEPS.md
  ```
- **生成后的项目结构**：
  ```
  myapp/
    main.go             # //go:embed all:frontend/dist + application.New(...) + Window URL "/"
    greetservice.go
    Taskfile.yml        # 根任务（build/package/run/dev）
    build/              # wails3 init 生成：config.yml、Taskfile.yml、windows/...、appicon.png
    frontend/           # 前端工程（package.json、vite.config.ts、src/...）
  ```
- **`main.go.tmpl` 的资产接线**【一手】：
  ```go
  //go:embed all:frontend/dist
  var assets embed.FS

  app := application.New(application.Options{
      Assets: application.AssetOptions{ Handler: application.AssetFileServerFS(assets) },
  })
  app.Window.NewWithOptions(application.WebviewWindowOptions{ URL: "/" })
  ```

### 2.3 AssetServer 实现：dev 反代 / 生产 embed

来源：[v3/internal/assetserver/](https://github.com/wailsapp/wails/tree/master/v3/internal/assetserver)（master）【一手】

**生产**（`//go:build production`）：
- `build_production.go::NewAssetFileServer(vfs)` → `newAssetFileServerFS(vfs)`：在 `embed.FS` 中定位含 `index.html` 的根目录，`io/fs.Sub` 截取后按 URL path 查文件，`index.html` 回退，mime sniff。**无压缩、无 hash/ETag**——go:embed 原样字节。
- webview 侧：资产 origin 为 `http://wails.localhost`（`assetserver_windows.go::baseURL`）；Windows 上经 WebView2 **`AddWebResourceRequested`** 拦截（[v3/internal/webview2/pkg/edge/chromium.go](https://github.com/wailsapp/wails/blob/master/v3/internal/webview2/pkg/edge/chromium.go) 有 `AddWebResourceRequestedFilter`）把请求转给进程内 AssetServer。与 Zilt 的 `https://zilt.app/*` custom scheme 是同一机制类别。

**dev**（`//go:build !production`）【一手，本节是重要发现】：
1. `wails3 dev`（[dev.go](https://github.com/wailsapp/wails/blob/master/v3/internal/commands/dev.go)）：
   - 解析 vite 端口：`--port` > 环境变量 `WAILS_VITE_PORT` > 默认 **9245**；先 `net.Listen` 探测端口空闲再关闭；
   - 设置 `WAILS_VITE_PORT`（给 Taskfile 的 `frontend:dev:*` 用）与 **`FRONTEND_DEVSERVER_URL`**（`http://localhost:9245`，给 Go 应用与 watcher 用）；
   - 启动 **Watcher**：读项目 `build/config.yml` 的 `dev_mode` 段（引擎为 `atterpac/refresh`）。
2. `build/config.yml` 的 `dev_mode`【一手】：
   ```yaml
   dev_mode:
     ignore: { dir: [.git, node_modules, frontend, bin], watched_extension: ["*.go", "*.js", "*.ts"] }
     debounce: 1000
     executes:
       - cmd: wails3 build DEV=true          # blocking：先构建 Go
       - cmd: wails3 task common:dev:frontend # background：起 vite dev server
       - cmd: wails3 task run                 # primary：运行应用（退出即关停全部）
   ```
3. **就绪等待（双层）**：
   - watcher 层（[watcher.go](https://github.com/wailsapp/wails/blob/master/v3/internal/commands/watcher.go)）：对 `common:dev:frontend` 后台进程自动注入 **TCP readiness 探测**（`process.Readiness{TCP: host:port, Timeout: "60s"}`）。注释解释为何用 TCP 不用 HTTP："servers such as Vite answer with 404 (see #6209)"。
   - 应用层（[pkg/application/application_dev.go](https://github.com/wailsapp/wails/blob/master/v3/pkg/application/application_dev.go)，`!production` 构建）：App 启动时读 `FRONTEND_DEVSERVER_URL`，**HTTP GET 轮询 10 次 × 500ms**，仍失败则 fatal："unable to connect to frontend server. Please check it is running"。
4. **导航 URL 改写**（[assetserver.go::GetStartURL](https://github.com/wailsapp/wails/blob/master/v3/internal/assetserver/assetserver.go)）【一手，关键】：
   ```go
   var baseURL = url.URL{ Scheme: "http", Host: "wails.localhost" }
   func GetStartURL(userURL string) (string, error) {
       // dev 模式：baseURL.Host = wails.localhost:{vite端口}
       // startURL = http://wails.localhost:9245/
   }
   ```
   主窗口 `URL: "/"` 在 dev 下解析为 **`http://wails.localhost:9245/`**——直连 vite（`*.localhost` 在 Chromium/WebView2 中解析到 loopback）。**HMR websocket 同源直连，不经代理。**
5. **AssetServer 反代兜底**（[build_dev.go](https://github.com/wailsapp/wails/blob/master/v3/internal/assetserver/build_dev.go)）：dev 下 `NewAssetFileServer` 返回的不是静态文件服务器，而是 **`httputil.NewSingleHostReverseProxy(FRONTEND_DEVSERVER_URL)`**，带：`retryTransport`（连接错误重试 50 次、间隔 50ms——应对 vite 高并发动态 import 时暂时拒连）、`MaxIdleConnsPerHost=512`（防 dev 页面数百个未打包 ES module 打光临时端口）、localhost 强制 IPv4（Windows IPv6 问题）、502 错误处理。**作用**：任何打到应用自身资产 origin 的请求（非主窗口导航路径）也会被转发到 vite。

**归纳**：Wails v3.1.x dev = "直连为主（主窗口导航改写到 dev server）+ 反代兜底（assetserver origin 的请求转发）"，与早期 alpha"CLI 起 devServer 中转"的设计已经不同。这与 Tauri 纯直连相比，多出的反代层是为了 origin 一致性兜底，不是 HMR 的必要条件。

### 2.4 bindings 生成与前端集成

【一手：Taskfile.tmpl.yml + vue 模板实测 + v3.wails.io/reference/cli】

- 命令：`wails3 generate bindings -clean=true -ts [-i] [-d 输出目录] [-obfuscated] ...`；由 Taskfile 的 `generate:bindings` 任务在 `build:frontend` 前自动执行（`sources: **/*.go`，`generates: frontend/bindings/**/*`）。
- 输出位置：**`frontend/bindings/<module path>/`**（按 Go 模块路径分目录）。
- 前端导入（vue 模板 `HelloWorld.vue.tmpl` 原文）：
  ```ts
  import { Events, WML } from "@wailsio/runtime";
  import { GreetService } from "../../bindings/{{js .ModulePath}}";
  ```
- 运行时以 npm 包 `@wailsio/runtime` 分发（模板 package.json 依赖，版本与 CLI lockstep：`RuntimeVersionFor()`）。绑定产物**进入 vite 打包管线**（构建时被 bundle，而非运行时注入）。

### 2.5 与 Tauri 的职责对照

| 维度 | Tauri 2 | Wails v3 |
|---|---|---|
| 编排载体 | CLI 内部逻辑 + `tauri.conf.json` 字段 | 项目内 `Taskfile.yml` + `build/config.yml`（文件即配置） |
| CLI 调包管理器 | 是（beforeDevCommand 即用户命令） | 否——CLI 只跑 Task；npm/bun 等由 Taskfile 任务调用【一手】 |
| dev 等待策略 | CLI 层 TCP 轮询 2s×90 次 | watcher 层 TCP readiness 60s + 应用层 HTTP GET 10×500ms |
| dev 导航 | 直连 devUrl | 直连（URL 改写到 `wails.localhost:{vite port}`）+ assetserver 反代兜底 |
| 生产嵌入 | cargo 编译期 codegen（brotli+phf） | `go:embed all:frontend/dist`（原始字节） |
| 绑定 | 运行时 IPC（@tauri-apps/api，无生成物） | 编译期生成到 `frontend/bindings/`，随前端打包 |

---

## 3. exe 资产嵌入机制对比

| | Tauri 2（tauri-codegen） | Wails v3（go:embed） | Zilt 现状（@embedFile 手工表） |
|---|---|---|---|
| 嵌入时机 | cargo 编译期（proc-macro/build script） | Go 编译期（`//go:embed all:frontend/dist`） | Zig 编译期（手工列出文件） |
| 目录枚举 | 自动 WalkDir | 自动（`all:` 前缀含 dotfiles） | 无——手工逐文件 |
| 压缩 | brotli（debug q2 / release q9），feature 可关 | 无 | 无 |
| 索引结构 | 编译期 `phf::Map` 完美哈希 | 遍历 `fs.FS`（embed 自动索引） | Zig 数组线性查找 |
| 路径回退 | 精确→`.html`→`/index.html`→`index.html` | `index.html` 目录回退 | 自行实现 |
| CSP/hash | 构建期算 SHA-256 注入 CSP；nonce 运行时 | 无 | 无 |
| ETag/304 | 无（生产） | 无 | 无 |
| 增量构建 | OUT_DIR 内容哈希缓存 + backdate | go build 自动跟踪 embed 输入 | zig build 自动跟踪 @embedFile 输入 |
| 体积影响 | 压缩后最小；解码驻留内存 | 原始字节 | 原始字节 |

来源汇总：Tauri 侧见 1.5；Wails 侧 [build_production.go](https://github.com/wailsapp/wails/blob/master/v3/internal/assetserver/build_production.go)、[_common/main.go.tmpl](https://github.com/wailsapp/wails/blob/master/v3/internal/templates/_common/main.go.tmpl)；均为【一手】。

---

## 4. Zilt 实施方案

> 现状基线（已核对仓库）：Zig 0.17.1；`src/zilt/config.zig` 的 `Config.assets: []const Asset`（path+content）+ `Config.Dev{dir,url}`；`src/app_config.zig` 手工 `@embedFile("frontend/index.html")` 三文件；custom scheme `https://zilt.app/*`；`build.zig` 已有 `gen`（TS 绑定 → `src/frontend/zilt-bindings.ts`）、`bundle`（zip+NSIS）step；IPC 注入 `window.zilt`。

### 4.1 Config 设计（对齐语义）

```zig
// src/zilt/config.zig 新增
pub const Frontend = struct {
    /// 前端工程目录（含 package.json），等价 beforeDevCommand/beforeBuildCommand 的 cwd
    dir: ?[]const u8 = null,                 // 默认 "frontend"
    /// 构建产物目录，等价 frontendDist（相对工程根）
    dist: ?[]const u8 = null,                // 默认 "frontend/dist"
    /// 等价 beforeDevCommand（如 "bun run dev"）
    dev_command: ?[]const u8 = null,
    /// 等价 devUrl；设置则 dev 模式直连（HMR 由 dev server 承担）
    dev_url: ?[]const u8 = null,
    /// 等价 beforeBuildCommand（如 "bun run build"）
    build_command: ?[]const u8 = null,
    /// 等待 dev_url 就绪的超时（秒）；Tauri 为 90×2s≈180s，建议默认 90
    wait_timeout_secs: u32 = 90,
    /// dev_url 缺省时：轮询间隔
    wait_interval_ms: u32 = 2000,
    /// 包管理器：未指定时按 bun → pnpm → yarn → npm 探测（Wails Taskfile 同款四件套）
    package_manager: ?enum { bun, pnpm, yarn, npm } = null,
};

pub const Config = struct {
    ...
    frontend: ?Frontend = null,   // null = 维持现状（@embedFile 资产表 / Dev{dir,url}）
    pub const Dev = struct {
        dir: ?[]const u8 = null,
        url: ?[]const u8 = null,
        /// 新增：dev 模式启动前执行的命令（等价 beforeDevCommand）
        command: ?[]const u8 = null,
        /// 等待 url 就绪超时（秒）
        wait_timeout_secs: u32 = 90,
    };
};
```

字段语义与 Tauri 一一映射（`dev.command→beforeDevCommand`、`dev.url→devUrl`、`build.command→beforeBuildCommand`、`dist→frontendDist`），保证从 Tauri/Wails 迁移的用户零学习成本。`Dev{dir,url}` 保留为低配形态（无 node 工具链时），`frontend` 有值时优先。

### 4.2 资产目录嵌入：build.zig codegen（推荐路径）

**方案 A（推荐）：build.zig 执行期遍历 → 生成 assets.zig → `@embedFile` 相对路径**

实现路径（Zig 0.17）：

```zig
// build.zig 内
const assets_step = b.step("assets", "Generate embedded assets table from frontend dist");
const wf = b.addWriteFiles();               // std.Build.Step.WriteFile
const dist_path = frontend.dist orelse "frontend/dist";

// build.zig 执行期遍历目录（b.build_root 下）：
//   std.fs.cwd().walk / Dir.iterate，收集相对路径，
//   排序（保证生成文件内容稳定 → zig 缓存命中），
//   逐文件 wf.addCopyFile(b.path(join(.{dist_path, rel})), join(.{"zilt-assets/payload", rel}))，
//   并生成文本 assets.zig：
//     pub const assets = [_]zilt.Asset{
//         .{ .path = "/index.html", .content = @embedFile("payload/index.html") },
//         ...
//     };
//   wf.add( .{ .relative_path = "zilt-assets/assets.zig", .data = generated } );
const assets_mod = b.createModule(.{ .root_source_file = wf.getFileSource("zilt-assets/assets.zig").? });
// 主模块：main_mod.addImport("zilt_assets", assets_mod)
// app_config.zig 改为：
//   const zilt_assets = @import("zilt_assets");
//   .assets = &zilt_assets.assets,
```

要点与取舍：
- **`@embedFile` 的路径必须位于该源文件所属 module root 之下**，所以生成文件与 `payload/` 副本必须同目录（`WriteFile` step 的虚拟目录天然满足）。直接 `@embedFile("../../frontend/dist/…")` 不行（module root 之外）。
- **生成文件必须内容确定**：遍历结果按路径排序；这样资产未变时 `assets.zig` 与 payload 均哈希不变，zig 构建缓存命中，不触发重编（对标 Tauri 的 OUT_DIR 内容哈希缓存）。
- `WriteFile` 的 copy 会让 payload 进入 zig 的输入哈希图，**单文件变更 → 重编含 assets 的编译单元 → 重链接 exe**。这与 Tauri/Wails 一致（Rust/Go 也是重链），是 @embedFile 语义的固有代价。
- 排除规则内建：`node_modules`、`.git`、`zig-cache`、`src-tauri`（Tauri build.rs 同款防御【一手】）。
- 嵌入前校验 `index.html` 存在，缺失时报 Tauri 式错误信息（"did you forget to build your web app?"）。

**方案 B（备选）：comptime 枚举**——`@embedFile` 无法 comptime 枚举目录（Zig 不支持 comptime fs 遍历），只能用 `@embedFile` 逐个 + 手工表（现状）。若 0.17 提供了 build 期目录 API 也仅限 build.zig 执行期（即方案 A），comptime 内不可行。**结论：方案 A 是唯一自动化的正统路径，且与 zig build 缓存体系契合。**

**体积与压缩（Phase C）**：Zig std 无 brotli；`std.compress.flate`（deflate/zlib）可用。可在 codegen 时预压缩，资产表附带 `encoding: .gzip` 标记，custom scheme 响应头带 `Content-Encoding: gzip`（WebView2/Chromium 会解码，Tauri brotli 同理经 custom protocol 下发）。按文件大小阈值（如 >8KB）才压缩。此为增强项，Phase A 用原始字节（exe 变大可接受，与 Wails 同水平）。

### 4.3 CLI 设计：`zig build dev` / `zig build frontend`

**新增工具 `src/tools/dev.zig`（zilt-dev exe，bundle 同款模式）**，`zig build dev` step 依赖 `install` step + `gen` step，运行时执行：

```
zig build dev
  1. 读 frontend 段配置（见下"单一配置源"）
  2. spawn dev_command:
     - Windows: CreateProcess 经 `cmd /S /C <script>`（Tauri dev.rs 同款【一手】），
       因为 npm/pnpm/yarn 是 .cmd shim，CreateProcess 不直接执行 .cmd；
       bun/node 为真实 .exe，PATH 探测后可直接 spawn。
     - PATH 探测：std.process.getEnvVarOwned("PATH") 分割 + PATHEXT 依次匹配。
     - stdio 直通（inherit），子进程非零退出即退出 dev。
  3. 若 frontend.dev_url 存在：TCP 轮询等待
     std.net.tcpConnectToHost(alloc, host, port)  // 1s 超时（单线程 deadline 控制）
     每 2s 一次，最多 wait_timeout_secs/2 次；期间打印 "Waiting for frontend dev server on {url}..."
     （TCP 探测而非 HTTP GET：Wails #6209 教训——vite 对无 Accept 头的探活请求回 404【一手】）
  4. spawn 主程序 exe（zig-out/bin/<app>.exe），注入环境变量 ZILT_DEV_URL=<dev_url>
     （主程序启动时若该变量存在 → 强制 dev-url 导航，等价现有 Dev.url）
  5. Windows 下用 Job Object（CREATE_BREAKAWAY_FROM_JOB 可选）挂子进程树，
     Ctrl+C/退出时一并Terminate——避免 dev server 孤儿进程
  6. 主程序退出 → 杀 dev server → dev 退出
```

- **`zig build frontend`** step：运行 `build_command`（`cmd /C bun run build` 等）→ 依赖 `assets` codegen step（构建产物变化自动重生成资产表）。同时把默认 `zig build install` 也依赖 `assets`，保证 release 构建总是嵌最新 dist。
- **单一配置源**：dev.zig 不引入运行时 JSON 配置，而是 build.zig 里直接 `@import("src/app_config.zig").frontend`（comptime 读取纯数据；`app_config.zig` 拆出 `frontend` 常量不依赖 zilt 运行时即可）。保持 Zilt "comptime 配置" 理念；将来若需要 CLI 覆盖（`-Ddev-url=...`）用 `b.option()` 合并。
- 与现有 `Dev.dir` 的关系：`frontend.dev_url` 优先级最高；无 dev_url 但有 `Dev.dir` → 维持现有目录服务+轮询热重载；都无 → embedded 资产表。三级降级与 Tauri（devUrl > frontendDist 内置 server）语义对齐。

### 4.4 HMR 策略建议

**Phase A：沿用 Tauri 式纯直连（现有 `dev.url` 模式），不做代理。**
理由：
1. Zilt 的 custom scheme origin（`https://zilt.app`）与 IPC 注入已经解决跨 origin 调用；dev 下直连 vite 时 IPC 走 `window.zilt` 注入（dev 模式 runtime 注入逻辑保留），无需同源。
2. Tauri 数年生产验证 + Wails v3.1.x 主路径也回归直连（GetStartURL 改写导航）。
3. 反代层（Wails build_dev.go 的 retryTransport/连接池调优）是为了兜底 origin 一致性场景，实现成本高（HTTP server + websocket 升级转发），收益场景少。

**Phase C（可选）**：`frontend.dev_proxy = true` 提供 Wails 式反代，用于 cookie/同源 fetch/service worker 类库在 dev 下报跨域的场景。届时在 Zilt dev runtime 里加本地 HTTP listener（Windows 可复用 WebView2 拦截机制：对 `https://zilt.app/*` 请求转发 vite）。**不做**内嵌 dev server 服务 dist 目录 + 注入 reload 脚本的 Tauri builtin 路径——Zilt 已有更简单的 `Dev.dir` 轮询热重载，等价物已存在。

对 vite 项目的模板约定（照抄 create-tauri-app，Phase B 进模板）：`server.port: 1420, strictPort: true, watch.ignored: ["**/src-zilt/**"]`。

### 4.5 模板策略

对比两者：
- Tauri：`create-tauri-app` 独立 npm 包 + `_base_/src-tauri` 共享壳 + `.lte` 条件模板，模板数量 18 个；
- Wails：CLI 内嵌模板（gosod 抽取）+ `_common` 共享 + `template.yaml` 元数据 + init 时生成 build/ 脚手架。

**建议（分两步）**：
1. **Phase B（手工模板目录）**：仓库内 `templates/` 目录，结构仿 Wails：
   ```
   templates/
     _common/        # app_config.zig.tmpl、main.zig.tmpl、build.zig 片段、.gitignore
     vanilla/        # 纯 html/js（现状三文件工程化）
     vue/、vue-js/、react/、svelte/、htmx/   # frontend/ + package.json + vite.config.ts
   ```
   `htmx` 作为正式模板提供（无构建步骤，`dist` 即目录本身，`dev_command: null` + `Dev.dir` 服务——覆盖无 node 工具链用户）。
   实施入口：`zig build init -- -t vue -n myapp`（zilt-dev 工具加 init 子命令，纯 Zig 文件复制 + 占位符替换，无需独立 npm 包）。
2. **Phase C（可选）**：若走 npm 生态传播再做 `create-zilt-app` 包；在此之前模板随仓库分发（`zig build` 用户天然不依赖 node 装 CLI）。

### 4.6 `zig build gen`（TS 绑定）输出衔接

对齐 Wails 惯例（`frontend/bindings/**/*` + 相对导入 + 进 vite 打包）【一手】：
- `zig build gen` 输出从 `src/frontend/zilt-bindings.ts` 迁移到 **`frontend/bindings/zilt.ts`**（`frontend` 为 frontend.dir 配置值；无 frontend 段时保持旧路径兼容）。
- 前端导入：`import { commands } from "../bindings/zilt"`（或 tsconfig paths：`"@zilt/*": ["frontend/bindings/*"]`）。
- Taskfile 对应物：`zig build frontend` step 的依赖链中加入 `gen`（Wails `build:frontend deps: generate:bindings` 同构【一手】），Go/Go 变更重生成 → Zilt 侧即 commands.zig/events.zig 变更触发重生成（zig build 对 gen step 的输入跟踪：`gen_run.addFileSourceDependencies` 列入 src/zilt/commands.zig 等）。
- 绑定产物进 vite 打包管线（与 `@wailsio/runtime` 同理，Zilt 无需 npm 运行时包——`window.zilt` 注入已是运行时，绑定文件仅是类型+薄封装）。

### 4.7 分阶段实施清单

**Phase A —— 最小可用（目标：`zig build dev` + Vite 项目直连跑通）**
1. `Config.Frontend` 段 + `Dev{command,wait_timeout_secs}` 扩展（config.zig）。
2. build.zig `assets` codegen step（WriteFile + 目录遍历 + 排序稳定生成）。
3. `app_config.zig` 改为 `@import("zilt_assets")`。
4. `src/tools/dev.zig`：spawn（Windows `cmd /S /C`）→ TCP 轮询 → 注入 `ZILT_DEV_URL` → Job Object 清理。
5. `zig build frontend` step（build_command + 依赖 gen）。
6. 文档：`frontend/` 目录约定 + vite.config.ts 推荐配置。

**Phase B —— 模板与工具链**
1. `templates/_common` + vanilla/vue/react/svelte/htmx 模板。
2. `zig build init`（模板抽取 + 占位符）。
3. `frontend.dev_url` 缺省时 fallback 到 dist 目录内置服务（对齐 Tauri builtin dev server；可先不做，`Dev.dir` 已覆盖）。
4. bundle step 消费 `frontend.dist`（替代固定 src/frontend 三文件）。

**Phase C —— 增强**
1. 资产预压缩（flate + `Content-Encoding`）+ 大小阈值。
2. `dev_proxy` 反代模式（Wails 式，同源场景）。
3. ETag/304（资产表带内容哈希，custom scheme 支持 If-None-Match）。
4. `create-zilt-app`（可选）。
5. CSP hash 注入（若实现 inline script CSP 支持）。

---

## 5. 参考资料清单

### Tauri（一手来源）
- 配置参考（BuildConfig/FrontendDist 语义）：https://v2.tauri.app/reference/config/
- dev 工作流/HMR：https://v2.tauri.app/develop/
- CLI 参考（--config 合并语义）：https://v2.tauri.app/reference/cli/
- localhost plugin：https://v2.tauri.app/plugin/localhost/
- dev.rs（spawn/等待轮询 90×2s/内置 dev server 1430）：https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-cli/src/dev.rs
- builtin_dev_server.rs（auto-reload 注入）：https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-cli/src/dev/builtin_dev_server.rs
- build.rs（beforeBuildCommand/frontendDist 校验）：https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-cli/src/build.rs
- embedded_assets.rs（brotli/SHA-256/phf 生成）：https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-codegen/src/embedded_assets.rs
- assets.rs（运行时 brotli 解码/phf 结构）：https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-utils/src/assets.rs
- manager/mod.rs（get_asset 回退/CSP nonce）：https://github.com/tauri-apps/tauri/blob/dev/crates/tauri/src/manager/mod.rs
- protocol/tauri.rs（custom protocol 服务）：https://github.com/tauri-apps/tauri/blob/dev/crates/tauri/src/protocol/tauri.rs
- tauri crate features（compression 默认开启）：https://github.com/tauri-apps/tauri/blob/dev/crates/tauri/Cargo.toml
- create-tauri-app（模板清单/_base_/lte 模板）：https://github.com/tauri-apps/create-tauri-app
- 版本核证：GitHub API——tauri-v2.12.5（stable）、tauri-v3.0.0-alpha.6（2026-11-06）

### Wails（一手来源）
- 版本核证：GitHub API——v3.1.0（2026-11-01 发布）、v3.2.0-nightly.20261103
- CLI 命令注册：https://github.com/wailsapp/wails/blob/master/v3/cmd/wails3/main.go
- task 执行器（内嵌 go-task fork）：https://github.com/wailsapp/wails/blob/master/v3/internal/commands/task.go
- init（模板 + GenerateBuildAssets）：https://github.com/wailsapp/wails/blob/master/v3/internal/commands/init.go
- 模板清单与解析：https://github.com/wailsapp/wails/blob/master/v3/internal/templates/templates.go
- _common/main.go.tmpl（go:embed all:frontend/dist）：https://github.com/wailsapp/wails/blob/master/v3/internal/templates/_common/main.go.tmpl
- 根 Taskfile 模板（dev/package/build 任务）：https://github.com/wailsapp/wails/blob/master/v3/internal/templates/_legacy/Taskfile.tmpl.yml
- 公共任务（frontend:dev/npm/bun/pnpm/yarn、generate:bindings）：https://github.com/wailsapp/wails/blob/master/v3/internal/commands/build_assets/Taskfile.tmpl.yml
- Windows 平台任务（go build -tags production / NSIS）：https://github.com/wailsapp/wails/blob/master/v3/internal/commands/build_assets/windows/Taskfile.yml
- build/config.yml（dev_mode 编排）：https://github.com/wailsapp/wails/blob/master/v3/internal/commands/build_assets/config.yml
- dev.go（端口 9245/FRONTEND_DEVSERVER_URL）：https://github.com/wailsapp/wails/blob/master/v3/internal/commands/dev.go
- watcher.go（TCP readiness 60s）：https://github.com/wailsapp/wails/blob/master/v3/internal/commands/watcher.go
- application_dev.go（应用层 HTTP GET 10×500ms 等待）：https://github.com/wailsapp/wails/blob/master/v3/pkg/application/application_dev.go
- build_dev.go（反代 + retryTransport + 连接池调优）：https://github.com/wailsapp/wails/blob/master/v3/internal/assetserver/build_dev.go
- build_production.go（生产静态 FS）：https://github.com/wailsapp/wails/blob/master/v3/internal/assetserver/build_production.go
- asset_fileserver.go（index.html 定位/回退）：https://github.com/wailsapp/wails/blob/master/v3/internal/assetserver/asset_fileserver.go
- assetserver.go（GetStartURL dev URL 改写）：https://github.com/wailsapp/wails/blob/master/v3/internal/assetserver/assetserver.go
- chromium.go（WebView2 WebResourceRequested 拦截）：https://github.com/wailsapp/wails/blob/master/v3/internal/webview2/pkg/edge/chromium.go
- CLI 参考（generate bindings flags）：https://v3.wails.io/reference/cli/
- vue 模板 bindings 导入示例：https://github.com/wailsapp/wails/blob/master/v3/internal/templates/vue/frontend/src/components/HelloWorld.vue.tmpl

### 二手来源
- Tauri monorepo 多应用实践讨论：https://github.com/orgs/tauri-apps/discussions/13941
- Wails vite 404 探活问题（#6209，watcher.go 注释引用）：https://github.com/wailsapp/wails/issues/6209
