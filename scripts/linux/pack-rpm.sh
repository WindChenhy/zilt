#!/usr/bin/env bash
# v0.4.3 L5：RPM 实构建（rpmbuild -bb）——zilt-pack 产 spec 后走真实 rpm 工具链。
# 用法：bash scripts/linux/pack-rpm.sh [exe 路径]（默认 zig-out/bin/<exe>）
# 依赖：rpm/rpmbuild（apt install rpm）；产物 → dist/*.rpm
# 载荷：/usr/bin/<exe> + /usr/share/applications/<pkg>.desktop（+ 有图标时 hicolor PNG）
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

# 1) spec + AppDir（zilt-pack 需要产物 exe 作为参数）
# 注意：不要对 GUI exe 做任何探测调用（--version 会进主循环挂死）
# 陈旧 spec 会让下面的 Source0 解析错位（历史坑）——先清掉
mkdir -p dist
rm -f dist/*.spec
zig build pack -- "$EXE" >/dev/null

SPEC=$(ls dist/*.spec | head -1)
[ -n "$SPEC" ] || { echo "spec missing (zilt-pack)" >&2; exit 3; }
PKG=$(basename "$SPEC" .spec)
APPDIR="dist/$PKG"
DESKTOP=$(ls "$APPDIR/usr/share/applications/"*.desktop 2>/dev/null | head -1 || true)
ICON=$(ls "$APPDIR/usr/share/icons/hicolor/256x256/apps/"*.png 2>/dev/null | head -1 || true)
echo "[pack-rpm] spec=$SPEC pkg=$PKG desktop=${DESKTOP:-none} icon=${ICON:-none}"

# 2) rpmbuild 目录结构 + Source 就位
SRC0=$(grep -oP '^Source0:\s+\K.*' "$SPEC" | head -1)
[ -n "$SRC0" ] || { echo "spec missing Source0" >&2; exit 3; }
TOP="$HOME/rpmbuild"
rm -rf "$TOP"
mkdir -p "$TOP/SOURCES" "$TOP/SPECS" "$TOP/RPMS" "$TOP/SRPMS" "$TOP/BUILD" "$TOP/BUILDROOT"
cp "$EXE" "$TOP/SOURCES/$SRC0"
cp "$SPEC" "$TOP/SPECS/"
SRC1=$(grep -oP '^Source1:\s+\K.*' "$SPEC" | head -1)
if [ -n "$SRC1" ]; then
  [ -n "$DESKTOP" ] || { echo "spec declares Source1 but AppDir desktop missing" >&2; exit 3; }
  cp "$DESKTOP" "$TOP/SOURCES/$SRC1"
fi
SRC2=$(grep -oP '^Source2:\s+\K.*' "$SPEC" | head -1)
if [ -n "$SRC2" ]; then
  [ -n "$ICON" ] || { echo "spec declares Source2 but AppDir icon missing" >&2; exit 3; }
  cp "$ICON" "$TOP/SOURCES/$SRC2"
fi

# 3) 实构建（无 %prep/%build 的 -bin spec：Source 直接进 %install）
rpmbuild -bb --define "_topdir $TOP" --define "_sourcedir $TOP/SOURCES" \
  --define "_rpmdir $TOP/RPMS" --define "_builddir $TOP/BUILD" \
  --define "_buildrootdir $TOP/BUILDROOT" --define "_srcrpmdir $TOP/SRPMS" \
  "$TOP/SPECS/$(basename "$SPEC")" >/tmp/zilt-rpmbuild.log 2>&1 || {
    echo "rpmbuild failed:" >&2; tail -25 /tmp/zilt-rpmbuild.log >&2; exit 3; }

# 4) 产物收集 → dist/ + 载荷断言
RPM=$(find "$TOP/RPMS" -name '*.rpm' | head -1)
[ -n "$RPM" ] || { echo "rpmbuild produced nothing" >&2; exit 3; }
cp "$RPM" "dist/"
OUT="dist/$(basename "$RPM")"
echo "[pack-rpm] rpm -> $OUT"
rpm -q --qf 'name=%{NAME} version=%{VERSION} release=%{RELEASE} arch=%{ARCH} size=%{SIZE}\n' -p "$OUT"
echo "[pack-rpm] payload:"
rpm -qlp "$OUT" | sed 's/^/  /'
rpm -qlp "$OUT" | grep -qx "/usr/bin/zilt-app" || { echo "payload missing /usr/bin/zilt-app" >&2; exit 4; }
rpm -qlp "$OUT" | grep -q '/usr/share/applications/.*\.desktop' || { echo "payload missing .desktop" >&2; exit 4; }

# 5) 可选 PGP 签名（ZILT_GPG_KEY_ID 存在时）：rpmsign --addsign
if [ -n "${ZILT_GPG_KEY_ID:-}" ]; then
  command -v rpmsign >/dev/null 2>&1 || { echo "rpmsign missing (apt install rpm-sign)" >&2; exit 5; }
  SIGN_ARGS=(--addsign --define "_gpg_name $ZILT_GPG_KEY_ID")
  [ -n "${GNUPGHOME:-}" ] && SIGN_ARGS+=(--define "_gpg_path $GNUPGHOME" --define "__gpg /usr/bin/gpg")
  rpmsign "${SIGN_ARGS[@]}" "$OUT"
  echo "[pack-rpm] signed (key=$ZILT_GPG_KEY_ID)"
fi
echo "===PACK-RPM-OK==="
