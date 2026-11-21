#!/usr/bin/env bash
# v0.4.4：无 Mac 硬件的本地检查——交叉编译 macOS 产物（只编译，不执行）。
#
#   bash scripts/macos/check.sh            # app + 测试产物
#   bash scripts/macos/check.sh --build-only
#
# 依赖：仓库内 src/zilt/platform/macos/stubs/*.tbd（非 macOS 宿主用最小链接桩）。
# 运行/截图只能在 macOS 上：CI `.github/workflows/macos.yml`（macos-15）。
set -eu
cd "$(dirname "$0")/../.."

TARGET="${ZILT_MACOS_TARGET:-aarch64-macos}"
BUILD_ONLY=0
[ "${1:-}" = "--build-only" ] && BUILD_ONLY=1

echo "== 交叉编译目标 $TARGET（宿主无法执行 Mach-O；运行/截图交给 CI）"

# 1) 应用与工具（可执行产物）——独立前缀，避免覆盖宿主的 zig-out
OUT="${ZILT_MACOS_OUT:-.zilt-out/macos}"
zig build -Dtarget="$TARGET" -p "$OUT"
echo "APP=$OUT/bin/zilt-app"

# 2) 测试产物只编译（本机无法执行 Mach-O）
if [ "$BUILD_ONLY" = 0 ]; then
  zig build test -Dtarget="$TARGET" -Dtest-compile-only=true --summary all
fi
echo "MACOS_CHECK=PASS target=$TARGET"
