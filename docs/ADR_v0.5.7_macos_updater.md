# ADR — macOS 更新器选型（路线 §6 Q5）

- 状态：Accepted（用户 2026-11-23 拍板「扩展现有 ed25519 核心」）
- 关联：`DESIGN_v0.5-v0.7_roadmap.md` §6 Q5 / §7「不重排已领先的更新核心」；v0.5.7

## 背景

`src/zilt/updater.zig` 已是平台无关的 ed25519 清单验签核心：
`parseManifest` / `versionNewer` / `sha256Hex` / `verifyArtifact` /
`checkForUpdateEnv`（含 GitHub Releases provider + skip）/ `downloadAndVerify`。
staging 已有 Windows（Win32 `MoveFileExW` 舞步）与 POSIX（`std.c.rename`）两分支；
POSIX 分支天然适用于 macOS 单文件替换。`rollbackToBackup` / `cleanupOld` 同样有 POSIX 分支。

macOS 缺口：
1. `.app` 是**目录束**（`X.app/Contents/MacOS/<exe>` + Info.plist + Resources），
   签名（v0.5.4 codesign）覆盖整束；只换内部 exe 会破坏签名封印 → 需**整束原子替换**。
2. macOS 后端 `systemEntry` 此前只接 `.store`（v0.5.6），无 `.updater`。

## 决策

**扩展现有 ed25519 核心（零新依赖）**，不引入 Sparkle：

- 复用 `checkForUpdateEnv` / `downloadAndVerify`（验签逻辑零改动）。
- 新增 `appBundleRoot(exe_path)`：纯逻辑，识别 exe 是否在 `.app` 束内并返回束根。
- 新增 `extractZipTree(io, alloc, zip, dest)`：把更新包（zip 含 `.app` 树）解压到临时目录。
- 新增 `stageAppBundle(io, alloc, app_path, new_app_dir)`：目录级原子替换舞步
  （`X.app` → `X.app.zilt-old` → 新束接管 `X.app`；失败回滚）。
- 三者均走跨平台 `std.Io.Dir`（`createDirPath` / `rename` / `writeFile`），可在 Windows 宿主单测。
- macOS 后端接线：`buildUpdaterEnv` + `updaterFetchMacos`（`std.http.Client`）+
  `runUpdaterOp`(info/check/skip) + `updaterFlow` + `systemEntry .updater`。
- flow 分支：束内 → `extractZipTree` + `stageAppBundle`；裸二进制（dev/CI 冒烟）→ 现有 `stageUpdate`。

## 理由

- §7 明确「不重排已领先的更新核心」；Sparkle 会**替换**或**并行**于 ed25519 核心，二者皆冲突。
- 零依赖文化：Sparkle 是第三方 Objective-C 框架，引入运行时依赖 + 第二套更新机制。
- POSIX rename 对目录原子，`.app` 整束替换无需 Windows 式「运行中不能覆盖」helper——
  staging 已把新束换到原名，**重启即生效**。

## 后果 / 诚实 gap（本切片不做）

- 差分/增量更新（Linux `tryPatchUpdateLinux` 有）：macOS 本期**仅全量下载**，patch 留后续。
- `auto_restart` / 重启 helper：macOS 本期发 `updateStaged` 事件由前端提示用户重启；
  自动重启留后续（POSIX staging 已就位，重启即新版）。
- 更新产物契约：macOS 更新包 = 含 `.app` 树的 zip（store 条目）；发布侧打该 zip 属打包流程，另接。
- `.app` 束路径仅单测覆盖（CI 冒烟跑裸二进制，走单文件分支）；束内真机端到端留后续。

## 被否方案

- **Sparkle appcast provider**：macOS 行业标准，但新增第三方依赖 + 与 ed25519 核心并行，
  违反零依赖文化与 §7。除非后续显式接受依赖，否则不采用。