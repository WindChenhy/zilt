#!/usr/bin/env bash
# v0.5.4：macOS 上组装 .app、ad-hoc 签名并产出拖装 DMG（hdiutil）。CI macos-15 调用。
#
#   bash scripts/macos/bundle.sh
#
# 依赖：zig（构建 exe + pack_macos 工具）、codesign + hdiutil（macOS 自带）。
# 产物：$ZILT_PACK_OUT/<name>.app + entitlements.plist + codesign.sh + bundle-dmg.sh + <name>.dmg
set -eu
cd "$(dirname "$0")/../.."

OUT="${ZILT_PACK_OUT:-.zilt-out/macos-dist}"
echo "== 组装 .app + 签名/DMG 脚本（out=${OUT}）"
ZILT_PACK_OUT="$OUT" zig build pack

echo "== codesign .app（ad-hoc，hardened runtime + entitlements）"
bash "$OUT/codesign.sh"

echo "== 执行 hdiutil 产出 DMG"
bash "$OUT/bundle-dmg.sh"

# 回读校验：DMG 存在且非空
DMG="$(find "$OUT" -maxdepth 1 -name '*.dmg' | head -1)"
[ -n "$DMG" ] && [ -s "$DMG" ]
echo "MACOS_DMG=$DMG ($(wc -c < "$DMG") bytes)"