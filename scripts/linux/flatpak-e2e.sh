#!/usr/bin/env bash
# v0.4.1 H13：Flatpak 构建端到端（flatpak-builder 存在时真构建 + 提取运行冒烟；
# 不存在 → SKIP 退出 0——CI/本地无 flatpak 环境的文档化路径）。
#
# 用法：bash scripts/linux/flatpak-e2e.sh
# 产物：.zilt-probe/flatpak-build/repo + flatpak smoke 退出码文件
#   .zilt-probe/flatpak-smoke.exit（0 = PASS；SKIP 也为 0）
set -eu
cd "$(dirname "$0")/../.."
mkdir -p .zilt-probe

if ! command -v flatpak-builder >/dev/null 2>&1; then
  echo "flatpak-builder not found -> SKIP（文档化：真构建随 v0.4.3 L5 在有 flatpak 的 CI 接入）"
  echo "SKIP" > .zilt-probe/flatpak-smoke.exit
  exit 0
fi

APP_ID="app.zilt"
BUILD_DIR=".zilt-probe/flatpak-build"
mkdir -p "$BUILD_DIR"

# 1) manifest 生成（pack 工具的 flatpak 子目标 = 静态 manifest 产物）
zig build pack ZILT_PACK_TARGET=flatpak || true
[ -f dist/*.flatpak.json ] || [ -f dist/app.zilt.flatpak.json ] || {
  echo "flatpak manifest 未生成（pack flatpak 目标）-> FAIL"
  echo "FAIL" > .zilt-probe/flatpak-smoke.exit
  exit 1
}

# 2) flatpak-builder 构建（需要 flatpak SDK runtime；缺失由 builder 报错）
flatpak-builder --force-clean --repo="$BUILD_DIR/repo" "$BUILD_DIR/app" dist/*.flatpak.json

# 3) 提取运行冒烟（沙箱内跑既有冒烟检查）
flatpak-builder --run="$PWD/scripts/linux/dev-smoke.sh" --force-clean "$BUILD_DIR/app" dist/*.flatpak.json
echo "$?" > .zilt-probe/flatpak-smoke.exit
cat .zilt-probe/flatpak-smoke.exit
