#!/usr/bin/env bash
# v0.4.3 L5：AUR 包面 —— PKGBUILD/.SRCINFO + 源 tar + package() 模拟安装 + 可选 makepkg。
#
# 用法：bash scripts/linux/pack-aur.sh [exe 路径]
# 产物：dist/aur/{PKGBUILD,.SRCINFO,<pkg>-<ver>.tar.gz}
# 验收（本机可完成的部分）：
#   1. `bash -n PKGBUILD`（PKGBUILD 是 shell）+ `.SRCINFO` 与 PKGBUILD 字段一致
#   2. 用 fakeroot 语义模拟 `package()`（设 srcdir/pkgdir 后直接调用该函数），
#      断言 /usr/bin/<exe>、.desktop、hicolor PNG 都落地——等价于 makepkg 的 install 段
#   3. docker 可用时再跑 `makepkg -sf`（Arch 容器；无镜像/无外网则跳过并打印原因）
set -eu
cd "$(dirname "$0")/../.."

EXE="${1:-zig-out/bin/zilt-app}"
[ -x "$EXE" ] || { echo "exe missing: $EXE" >&2; exit 2; }
EXE=$(readlink -f "$EXE")

# 1) 产物面（PKGBUILD/.SRCINFO 由 zilt-pack 生成）
# 清陈旧 spec：AppDir 目录名从 spec 推导，残留会让指纹指向旧包
rm -f dist/*.spec
zig build pack -- "$EXE" >/dev/null
AUR=dist/aur
[ -f "$AUR/PKGBUILD" ] || { echo "PKGBUILD missing (zilt-pack)" >&2; exit 2; }
[ -f "$AUR/.SRCINFO" ] || { echo ".SRCINFO missing (zilt-pack)" >&2; exit 2; }
echo "[pack-aur] PKGBUILD/.SRCINFO ready"

PKGVER=$(grep -oP '^pkgver=\K.*' "$AUR/PKGBUILD" | head -1)
PKGBASE=$(grep -oP '^pkgname=\K.*' "$AUR/PKGBUILD" | head -1)
ARCH=$(grep -oP "^arch=\('?\K[^')]+" "$AUR/PKGBUILD" | head -1)
echo "[pack-aur] pkg=$PKGBASE ver=$PKGVER arch=$ARCH"

# 2) 静态校验：shell 语法 + .SRCINFO 一致性
bash -n "$AUR/PKGBUILD"
for field in "pkgname = $PKGBASE" "pkgver = $PKGVER" "arch = $ARCH"; do
  grep -qF "$field" "$AUR/.SRCINFO" || { echo ".SRCINFO mismatch: $field" >&2; exit 3; }
done
echo "[pack-aur] bash -n OK；.SRCINFO 与 PKGBUILD 一致"

# 3) source tar（exe + .desktop + 图标）——PKGBUILD 的 $srcdir 内容
TAR="$AUR/$PKGBASE-$PKGVER.tar.gz"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$EXE" "$STAGE/$(basename "$EXE")"
APPDIR="dist/$(basename "$(ls dist/*.spec | head -1)" .spec)"
SRC_DESKTOP="$APPDIR/usr/share/applications/$PKGBASE.desktop"
[ -f "$SRC_DESKTOP" ] || SRC_DESKTOP=$(ls "$APPDIR/usr/share/applications/"*.desktop 2>/dev/null | head -1 || true)
if [ -n "$SRC_DESKTOP" ] && [ -f "$SRC_DESKTOP" ]; then
  cp "$SRC_DESKTOP" "$STAGE/"
else
  cat > "$STAGE/$PKGBASE.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$PKGBASE
Exec=$PKGBASE
Categories=Network;
EOF
fi
SRC_ICON=$(ls "$APPDIR/usr/share/icons/hicolor/256x256/apps/"*.png 2>/dev/null | head -1 || true)
[ -n "$SRC_ICON" ] && cp "$SRC_ICON" "$STAGE/"
DESK_NAME=$(basename "$SRC_DESKTOP")
tar -czf "$TAR" -C "$STAGE" .
echo "[pack-aur] source tar -> $TAR"
tar -tzf "$TAR" | sed 's/^/  /'

# 4) package() 模拟安装（等价 makepkg install 段；fakeroot 不改变可见性）
PKGDIR="$STAGE/pkgdir"
SRCDIR="$STAGE/src"
mkdir -p "$PKGDIR" "$SRCDIR"
tar -xzf "$TAR" -C "$SRCDIR"
(
  set -eu
  srcdir="$SRCDIR"; pkgdir="$PKGDIR"; pkgname="$PKGBASE"
  # shellcheck disable=SC1090
  source "$AUR/PKGBUILD"
  package
)
echo "[pack-aur] package() 落地文件："
find "$PKGDIR" -type f -printf '  %P (%s bytes)\n' | sort
for f in "usr/bin/$(basename "$EXE")" "usr/share/applications/$DESK_NAME"; do
  [ -f "$PKGDIR/$f" ] || { echo "package() missing $f" >&2; exit 4; }
done
if [ -n "$SRC_ICON" ]; then
  [ -f "$PKGDIR/usr/share/icons/hicolor/256x256/apps/$(basename "$SRC_ICON")" ] || {
    echo "package() missing icon" >&2; exit 4; }
fi

# 5) makepkg 实构建（archlinux 容器；无 docker/镜像 → 跳过）
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker image inspect archlinux:base-devel >/dev/null 2>&1; then
    # v0.6.1：默认 GTK4；ZILT_E2E_GTK=gtk3 覆盖 legacy 变体
    AUR_DEPS="gtk4 webkitgtk-6.0 libsoup3"
    [ "${ZILT_E2E_GTK:-gtk4}" = "gtk3" ] && AUR_DEPS="gtk3 webkit2gtk-4.1 libsoup3"
    docker run --rm -v "$(pwd)":/work -w /work/dist/aur archlinux:base-devel \
      bash -c "pacman -Sy --noconfirm --needed $AUR_DEPS >/dev/null 2>&1; \
        useradd -m builder && chown -R builder: . && runuser -u builder -- makepkg -sf --noconfirm" \
      && { echo "[pack-aur] makepkg OK (archlinux container)"; ls "$AUR"/*.pkg.tar.* 2>/dev/null || true; }
  else
    echo "[pack-aur] makepkg skipped: archlinux:base-devel image absent (offline)"
  fi
else
  echo "[pack-aur] makepkg skipped: docker unavailable"
fi
echo "===PACK-AUR-OK==="
