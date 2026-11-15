# CI / 签名流水线

`.github/workflows/ci.yml` 提供三档流水线，覆盖「构建 → 测试 → 冒烟 → 打包 → 签名发布」。

## 任务结构

| job | 触发 | 内容 |
|---|---|---|
| `test` | push / PR / 手动 | Zig 构建（Debug + ReleaseFast）→ `zig build test` → GUI 冒烟 31 项 → WebDriver E2E（可选）|
| `linux-test` | push / PR / 手动 | Ubuntu 22.04：GTK3/WebKitGTK 构建 + 单测 → Xvfb + **openbox** 冒烟 75 项 → headless/MCP → **差分更新 E2E** → WebKitWebDriver → init 模板 → 打包 |
| `package` | 依赖 `test` | 前端构建 → NSIS 打包 → 上传 `zilt-windows-x64`（setup.exe / zip）|
| `release` | tag `v*` | 下载产物 → signtool 签名（RFC3161 时间戳）→ 创建 GitHub Release |

## 关键约定

**冒烟测试**：`ZILT_SMOKE_TEST_MS` 给窗口一个存活上限，`ZILT_SMOKE_EXIT=1` 让应用按检查结果退出（0 全过 / 非 0 失败）。日志里 `[smoke] ALL CHECKS PASSED` 是判据。

**Linux 冒烟（`linux-test`）**：`ZILT_LINUX_SMOKE=1` + `xvfb-run`（`GDK_BACKEND=x11`，
`WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`，`LIBGL_ALWAYS_SOFTWARE=1`）。
v0.3.0 起在 Xvfb 内先启动 **openbox**——windowMoved/Resized/Focus 需要真实 WM
（裸 Xvfb 不会产生 configure/focus），冒烟据此断言事件载荷；WM 探测走
`_NET_SUPPORTING_WM_CHECK`，无 WM 时该检查明确 skip。本地等价命令：
`bash scripts/linux/dev-smoke.sh`（有 openbox 自动启用）。

**WebDriver E2E 是「可选但不静默」**：CI 里按 runner 的 Edge 版本下载匹配的 `msedgedriver`，下载失败或无 Edge 时打印 SKIP 并跳过；真跑起来后失败必须让流水线红。本地同理：

```bash
# 手动指定驱动
set ZILT_EDGEDRIVER_PATH=C:\tools\msedgedriver.exe
zig build e2e

# 或直接跑（加自定义断言脚本）
zig-out\bin\zilt-driver.exe zig-out\bin\zilt-app.exe --script checks.js
```

退出码：`0` 全过 / `1` 有断言失败 / `2` 参数错误 / `3` 未找到驱动（SKIP）。

**签名 secrets**（在仓库 Settings → Secrets 配置）：

| secret | 说明 |
|---|---|
| `WINDOWS_CERTIFICATE_BASE64` | PFX 文件的 base64（`certutil -encode` 去头尾即可）|
| `WINDOWS_CERTIFICATE_PASSWORD` | PFX 密码 |

签名走框架自带的 `zilt-sign`（内部调 signtool + `/fd sha256 /td sha256` + RFC3161 时间戳）。MSI / MSIX 在 CI 里默认不构建：需要 WiX（`zig build pack` 会自动 vendor）与 Windows SDK 的 `makeappx`（runner 已带 SDK，缺 WiX 时 MSI 跳过）。

## 本地等价命令

```bash
zig build                      # Debug 构建
zig build -Doptimize=ReleaseFast
zig build test                 # 单测（框架 + 工具）
ZILT_SMOKE_TEST_MS=30000 ZILT_SMOKE_EXIT=1 zig-out/bin/zilt-app.exe
zig build e2e                  # WebDriver（无驱动 → SKIP 3）
zig build bundle               # NSIS + zip → dist/
ZILT_PACK_TARGET=msi zig build pack
ZILT_PACK_TARGET=msix zig build pack
```

## 为什么不用 `zig build --watch` 做 CI 缓存

`--watch` 是开发体验，CI 里每步都是单次构建。缓存只针对 `.zig-cache` 与全局 zig 缓存，key 绑定 `build.zig` / `build.zig.zon` 哈希——源码变更不会命中旧缓存，但依赖不变时能省掉全局库编译。
