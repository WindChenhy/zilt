#!/usr/bin/env bash
# Zilt Linux 构建环境自举（WSL / Ubuntu 22.04+）。
#
# 用法（在 Ubuntu 里，root 或 sudo）：
#   sudo bash scripts/linux/bootstrap.sh
#   # 或 WSL 从 Windows 侧：
#   wsl -d Ubuntu-22.04 -u root -- bash /mnt/d/Projects/ZigProjects/Zilt/scripts/linux/bootstrap.sh
#
# 做的事：装 GTK3/WebKit2GTK 4.1 开发包 + Zig（默认 0.17.1），最后打印自检表。
# 幂等：重复执行只会补齐缺失项。
set -uo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.17.1}"
ZIG_PREFIX="${ZIG_PREFIX:-/opt/zig}"
APT_PACKAGES=(
  build-essential pkg-config curl xz-utils
  libgtk-3-dev libwebkit2gtk-4.1-dev
  xvfb
  # v0.2.6 全局快捷键（X11 头文件，capi.h 硬依赖）+ v0.2.7 shell（xdg-open）
  # v0.2.9 WebDriver E2E（WebKitWebDriver）
  libx11-dev xdg-utils webkit2gtk-driver
  # v0.4.3 L6 托盘挂窗 E2E：openbox（WM 语义）+ stalonetray（XEmbed 托盘宿主）
  openbox stalonetray
)

say() { printf '\n== %s ==\n' "$*"; }
ok()  { printf '[ok]   %s\n' "$*"; }
warn(){ printf '[warn] %s\n' "$*"; }
die() { printf '[fail] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root / sudo 运行"

say "系统信息"
. /etc/os-release
ok "${PRETTY_NAME:-unknown}  kernel=$(uname -r)  arch=$(uname -m)"
case "${VERSION_ID:-}" in
  22.04|24.04|24.10|25.04|25.10) ;;
  *) warn "未验证的发行版 ${VERSION_ID:-?}：需要提供 webkit2gtk-4.1 的 dev 包" ;;
esac

say "安装依赖（apt）"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || die "apt-get update 失败（检查网络/镜像）"
missing=()
for p in "${APT_PACKAGES[@]}"; do
  if dpkg -s "$p" >/dev/null 2>&1; then ok "$p 已安装"; else missing+=("$p"); fi
done
if [ ${#missing[@]} -gt 0 ]; then
  printf '[..]   安装: %s\n' "${missing[*]}"
  apt-get install -y -qq "${missing[@]}" || die "apt-get install 失败: ${missing[*]}"
  ok "已安装 ${#missing[@]} 个包"
fi

say "Zig ${ZIG_VERSION}"
if command -v zig >/dev/null 2>&1 && [ "$(zig version 2>/dev/null)" = "$ZIG_VERSION" ]; then
  ok "zig $(zig version) 已在 PATH（$(command -v zig)）"
else
  mkdir -p "$ZIG_PREFIX"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  # 0.14 起官方包名为 zig-<arch>-<os>-<ver>，更早是 zig-<os>-<arch>-<ver>；两种都试。
  url=""
  for name in "zig-x86_64-linux-${ZIG_VERSION}" "zig-linux-x86_64-${ZIG_VERSION}"; do
    cand="https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz"
    if curl -fsSL --retry 2 -o "$tmp/zig.tar.xz" "$cand"; then url="$cand"; break; fi
  done
  [ -n "$url" ] || die "下载 Zig ${ZIG_VERSION} 失败（网络或版本号）"
  ok "下载 $(basename "$url")"
  tar -xJf "$tmp/zig.tar.xz" -C "$tmp" || die "解压失败"
  src="$(find "$tmp" -maxdepth 1 -type d -name 'zig*' | head -1)"
  [ -n "$src" ] || die "解压后找不到 zig 目录"
  rm -rf "${ZIG_PREFIX:?}"/*
  cp -a "$src"/. "$ZIG_PREFIX"/
  ln -sf "$ZIG_PREFIX/zig" /usr/local/bin/zig
  ok "zig $(/usr/local/bin/zig version) -> /usr/local/bin/zig"
fi

say "自检"
fail=0
check_pkg() {
  local mod="$1" label="$2" v
  if v="$(pkg-config --modversion "$mod" 2>/dev/null)"; then ok "$label $v"; else warn "$label 缺失（pkg-config $mod）"; fail=1; fi
}
check_pkg gtk+-3.0 "GTK3"
check_pkg webkit2gtk-4.1 "WebKit2GTK 4.1"
command -v xvfb-run >/dev/null 2>&1 && ok "xvfb-run $(xvfb-run --help 2>&1 | head -1 >/dev/null; echo ready)" || { warn "xvfb-run 缺失"; fail=1; }
command -v zig >/dev/null 2>&1 && ok "zig $(zig version)" || { warn "zig 不在 PATH"; fail=1; }

printf '\n'
if [ "$fail" -eq 0 ]; then
  ok "环境就绪：可以运行 zig build / zig build test / xvfb-run 冒烟"
  printf '下一步（仓库建议放在 WSL 原生盘，跨 /mnt 构建很慢）：\n'
  printf '  git clone /mnt/d/Projects/ZigProjects/Zilt ~/zilt && cd ~/zilt\n'
  printf '  zig build test\n'
else
  warn "有缺失项，见上面的 [warn]"
fi
exit "$fail"
