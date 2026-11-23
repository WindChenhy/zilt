#!/usr/bin/env bash
# v0.5.3：macOS 上组装 .app 并产出拖装 DMG（hdiutil）。CI macos-15 调用。
#
#   bash scripts/macos/bundle.sh
#
# 依赖：zig（构建 exe + pack_macos 工具）、hdiutil（macOS 自带）。
# 产物：$ZILT_PACK_OUT/<name>.app + bundle-dmg.sh + <name>.dmg
set -eu
cd "$(dirname "$0")/../.."

OUT="${ZILT_PACK_OUT:-.zilt-out/macos-dist}"
echo "== 组装 .app + DMG 脚本（out=$OUT）"
ZILT_PACK_OUT="$OUT" zig build pack

echo "== 执行 hdiutil 产出 DMG"
bash "$OUT/bundle-dmg.sh"

# 回读校验：DMG 存在且非空
DMG="$(find "$OUT" -maxdepth 1 -name '*.dmg' | head -1)"
[ -n "$DMG" ] && [ -s "$DMG" ]
echo "MACOS_DMG=$DMG ($(wc -c < "$DMG") bytes)"