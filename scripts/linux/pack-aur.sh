#!/usr/bin/env bash
# v0.4.3 L5：AUR 包面准备 + makepkg 实构建验证（archlinux docker 容器）。
# 用法：bash scripts/linux/pack-aur.sh [exe 路径]
# 产物：dist/aur/{PKGBUILD,.SRCINFO,<pkg>-<ver>.tar.gz}
# 验收：archlinux 容器内 makepkg -sf 走通（docker 可用时；否则仅准备 + 文档化）。
set -eu
cd "$(dirname "$0")/../.."

EXE="${1:-zig-out/bin/zilt-app}"
[ -x "$EXE" ] || { echo "exe missing: $EXE" >&2; exit 2; }
EXE=$(readlink -f "$EXE")

# 1) 产物面（PKGBUILD/.SRCINFO 由 zilt-pack 生成）
zig build pack -- "$EXE" >/dev/null
AUR=dist/aur
[ -f "$AUR/PKGBUILD" ] || { echo "PKGBUILD missing (zilt-pack)" >&2; exit 2; }
echo "[pack-aur] PKGBUILD/.SRCINFO ready"

# 2) source tar（exe + .desktop）——PKGBUILD 的 $srcdir 内容
PKGVER=$(grep -oP '^pkgver=\K.*' "$AUR/PKGBUILD" | head -1)
PKGBASE=$(grep -oP '^pkgname=\K.*' "$AUR/PKGBUILD" | head -1)
TAR="$AUR/$PKGBASE-$PKGVER.tar.gz"
STAGE=$(mktemp -d)
cp "$EXE" "$STAGE/$(basename "$EXE")"
# .desktop 由 zilt-pack 一并产出（deb 面）；缺失则最小生成
find dist -maxdepth 1 -type f -name "*.desktop" -exec cp {} "$STAGE/" \;
ls "$STAGE"/*.desktop >/dev/null 2>&1 || {
  cat > "$STAGE/$PKGBASE.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$PKGBASE
Exec=$PKGBASE
Categories=Network;
EOF
}
tar -czf "$TAR" -C "$STAGE" .
rm -rf "$STAGE"
echo "[pack-aur] source tar -> $TAR"

# 3) makepkg 实构建验证（docker archlinux；无 docker → 跳过并文档化）
#    依赖以 root 预装（builder 免 sudo）；makepkg -sf 解包 source + package()
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker run --rm -v "$(pwd)":/work -w /work/dist/aur archlinux:base-devel \
    bash -c "sed -i '1i Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch' /etc/pacman.d/mirrorlist; \
      pacman -Syu --noconfirm gtk3 webkit2gtk-4.1 libsoup3 >/dev/null 2>&1; \
      useradd -m builder && chown -R builder: . && runuser -u builder -- makepkg -sf" \
    && echo "[pack-aur] makepkg OK (archlinux container)"
  ls "$AUR"/*.pkg.tar.zst 2>/dev/null || ls "$AUR"/*.pkg.tar.xz 2>/dev/null || true
else
  echo "[pack-aur] docker unavailable — makepkg verification skipped (documented)"
fi
echo "===PACK-AUR-OK==="
