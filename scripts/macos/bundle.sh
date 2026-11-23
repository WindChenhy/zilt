#!/usr/bin/env bash
# v0.5.5：macOS 上组装 .app、lipo Universal、ad-hoc 签名、产出拖装 DMG、公证（缺省跳过）。CI macos-15 调用。
#
#   bash scripts/macos/bundle.sh
#
# 依赖：zig（构建 exe + pack_macos 工具）、lipo + codesign + hdiutil（macOS 自带）。
# 产物：$ZILT_PACK_OUT/<name>.app（Universal）+ entitlements.plist + codesign.sh + universal.sh + notarize.sh + bundle-dmg.sh + <name>.dmg
set -eu
cd "$(dirname "$0")/../.."

OUT="${ZILT_PACK_OUT:-.zilt-out/macos-dist}"
echo "== 组装 .app + 签名/DMG 脚本（out=${OUT}）"
ZILT_PACK_OUT="$OUT" zig build pack

echo "== 构建 x86_64 slice + lipo 成 Universal"
X64_PREFIX=.zilt-out/macos-x64
zig build -Dtarget=x86_64-macos -p "$X64_PREFIX"
bash "$OUT/universal.sh" "$(pwd)/$X64_PREFIX/bin/zilt-app"

echo "== codesign .app（ad-hoc，hardened runtime + entitlements）"
bash "$OUT/codesign.sh"

echo "== 执行 hdiutil 产出 DMG"
bash "$OUT/bundle-dmg.sh"

# 回读校验：DMG 存在且非空
DMG="$(find "$OUT" -maxdepth 1 -name '*.dmg' | head -1)"
[ -n "$DMG" ] && [ -s "$DMG" ]
echo "MACOS_DMG=$DMG ($(wc -c < "$DMG") bytes)"

echo "== 公证（Apple secrets 缺省则跳过）"
bash "$OUT/notarize.sh"