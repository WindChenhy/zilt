#!/usr/bin/env bash
# v0.4.3 L5：RPM 实构建（rpmbuild -bb）——zilt-pack 产 spec 后走真实 rpm 工具链。
# 用法：bash scripts/linux/pack-rpm.sh [exe 路径]（默认 zig-out/bin/<exe>）
# 依赖：rpm/rpmbuild（apt install rpm）；产物 → dist/*.rpm
set -eu
cd "$(dirname "$0")/../.."

EXE="${1:-}"
if [ -z "$EXE" ]; then
  zig build install --summary none   # 确保产物在 zig-out（pack 步骤只构建缓存）
  EXE=$(ls zig-out/bin/zilt-app 2>/dev/null || true)
  [ -n "$EXE" ] || { echo "usage: pack-rpm.sh <exe>" >&2; exit 2; }
fi
[ -x "$EXE" ] || { echo "exe not executable: $EXE" >&2; exit 2; }
EXE=$(readlink -f "$EXE")

# 1) spec + AUR 产物（zilt-pack 需要产物 exe 作为参数）
# 注意：不要对 GUI exe 做任何探测调用（--version 会进主循环挂死）
ZILT_PACK_OUT=dist
mkdir -p "$ZILT_PACK_OUT"
zig build pack -- "$EXE"

SPEC=$(ls "$ZILT_PACK_OUT"/*.spec | head -1)
PKG=$(basename "$SPEC" .spec)
echo "[pack-rpm] spec=$SPEC pkg=$PKG"

# 2) rpmbuild 目录结构 + Source0 就位（按 spec 声明的名字拷贝）
SRC0=$(grep -oP '^Source0:\s+\K.*' "$SPEC" | head -1)
[ -n "$SRC0" ] || { echo "spec missing Source0" >&2; exit 3; }
TOP="$HOME/rpmbuild"
mkdir -p "$TOP/SOURCES" "$TOP/SPECS" "$TOP/RPMS/x86_64" "$TOP/SRPMS" "$TOP/BUILD" "$TOP/BUILDROOT"
cp "$EXE" "$TOP/SOURCES/$SRC0"
cp "$SPEC" "$TOP/SPECS/"

# 3) 实构建（无 %prep/%build 的 -bin spec：Source0 直接进 %install）
rpmbuild -bb --define "_topdir $TOP" --define "_sourcedir $TOP/SOURCES" \
  --define "_rpmdir $TOP/RPMS" --define "_builddir $TOP/BUILD" \
  --define "_buildrootdir $TOP/BUILDROOT" --define "_srcrpmdir $TOP/SRPMS" \
  "$TOP/SPECS/$(basename "$SPEC")"

# 4) 产物收集 → dist/
RPM=$(find "$TOP/RPMS" -name '*.rpm' -newer "$SPEC" | head -1)
if [ -z "$RPM" ]; then RPM=$(find "$TOP/RPMS" -name '*.rpm' | head -1); fi
[ -n "$RPM" ] || { echo "rpmbuild produced nothing" >&2; exit 3; }
cp "$RPM" "$ZILT_PACK_OUT/"
echo "[pack-rpm] rpm -> $ZILT_PACK_OUT/$(basename "$RPM")"
rpm -q --qf 'name=%{NAME} version=%{VERSION} release=%{RELEASE} arch=%{ARCH}\n' -p "$RPM"

# 5) 可选 PGP 签名（ZILT_GPG_KEY_ID 存在时）：rpmsign --addsign
if [ -n "${ZILT_GPG_KEY_ID:-}" ]; then
  command -v rpmsign >/dev/null 2>&1 || { echo "rpmsign missing (apt install rpm-sign)" >&2; exit 4; }
  rpmsign --addsign --define "_gpg_name $ZILT_GPG_KEY_ID" "$ZILT_PACK_OUT/$(basename "$RPM")"
  echo "[pack-rpm] signed (key=$ZILT_GPG_KEY_ID)"
  rpm -K "$ZILT_PACK_OUT/$(basename "$RPM")"
fi
echo "===PACK-RPM-OK==="
