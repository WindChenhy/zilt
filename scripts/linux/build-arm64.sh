#!/usr/bin/env bash
# v0.4.3 L4：ARM64 构建链（qemu + sysroot）
#
# 两条路径：
#   A) docker（默认，推荐）：arm64v8/ubuntu:24.04 容器 + QEMU binfmt →
#      容器内装 GTK3/WebKitGTK 开发包与 aarch64 Zig → `zig build` +
#      `zig build pack`（ZILT_BUNDLE_WEBKIT=1，随包 WebKit）→ dist-arm64/
#      （deb / AppDir / squashfs / build-appimage.sh；AppImage 需 runtime-aarch64）
#   B) --sysroot DIR（无 docker 的本地交叉；DIR 内需有 aarch64 的
#      usr/include + usr/lib/aarch64-linux-gnu/pkgconfig）：
#      PKG_CONFIG_SYSROOT_DIR 指向 sysroot → `zig build -Dtarget=aarch64-linux-gnu`；
#      打包不随包 WebKit（host 版 zilt-pack 无法 ldd 外来架构，
#      自包含 AppImage 走 A 路径）。
#
# 环境限制：本机（WSL）无外网/无 arm64 镜像时，docker 路径如实 SKIP（exit 3），
# 不伪装成功；CI 用 docker/setup-qemu-action 后可直接跑本脚本。
#
# 用法：
#   bash scripts/linux/build-arm64.sh                # docker 路径
#   bash scripts/linux/build-arm64.sh --check        # 只做预检，打印将执行的命令
#   bash scripts/linux/build-arm64.sh --sysroot /opt/sysroot-arm64
#   ZILT_ARM64_IMAGE=arm64v8/ubuntu:22.04 ...        # 换基础镜像
set -u
cd "$(dirname "$0")/../.."

ZIG_VERSION="${ZIG_VERSION:-0.17.1}"
IMAGE="${ZILT_ARM64_IMAGE:-arm64v8/ubuntu:24.04}"
OUT="${ZILT_ARM64_OUT:-dist-arm64}"
MODE="docker"
SYSROOT=""
CHECK=0
BUNDLE="${ZILT_BUNDLE_WEBKIT:-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --sysroot) MODE=sysroot; SYSROOT="${2:-}"; shift 2 ;;
    --docker) MODE=docker; shift ;;
    --image) IMAGE="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say() { printf '== %s\n' "$*"; }
skip() { printf 'ARM64_BUILD=SKIP reason=%s\n' "$*"; exit 3; }

mkdir -p "$OUT"

# 容器内执行的构建脚本（单引号 here-doc：宿主不展开）
container_script() {
  cat <<'EOS'
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential pkg-config ca-certificates curl xz-utils \
  libgtk-3-dev libwebkit2gtk-4.1-dev libx11-dev libxext-dev \
  libayatana-appindicator3-dev squashfs-tools >/dev/null
if ! command -v zig >/dev/null 2>&1; then
  curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-aarch64-linux-${ZIG_VERSION}.tar.xz"
  tar -xJf /tmp/zig.tar.xz -C /opt
  ln -sf "/opt/zig-aarch64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
fi
echo "ZIG=$(zig version) ARCH=$(uname -m)"
zig build
if [ "${ZILT_ARM64_SKIP_TESTS:-0}" != "1" ]; then zig build test; fi
ZILT_BUNDLE_WEBKIT="${ZILT_BUNDLE_WEBKIT:-1}" zig build pack
ls -lh dist-arm64 2>/dev/null || true
# 挂载卷内的产物归 root——交回宿主用户，避免 CI/本地后续无法清理
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" dist-arm64 2>/dev/null || true
EOS
}

if [ "$MODE" = "sysroot" ]; then
  [ -n "$SYSROOT" ] || { echo "ARM64_BUILD=FAIL reason=sysroot-missing"; exit 1; }
  [ -d "$SYSROOT" ] || { echo "ARM64_BUILD=FAIL reason=sysroot-not-dir"; exit 1; }
  PC_DIR="$SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig"
  [ -d "$PC_DIR" ] || { echo "ARM64_BUILD=FAIL reason=no-pkgconfig:$PC_DIR"; exit 1; }
  say "sysroot 交叉构建（不随包 WebKit——见脚本头 B 路径说明）"
  CMD=(env
    PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
    PKG_CONFIG_LIBDIR="$PC_DIR:$SYSROOT/usr/share/pkgconfig"
    ZILT_PACK_OUT="$OUT"
    zig build -Dtarget=aarch64-linux-gnu
  )
  if [ "$CHECK" = 1 ]; then printf 'CMD: %s\n' "${CMD[*]}"; echo "ARM64_BUILD=CHECK_OK mode=sysroot"; exit 0; fi
  "${CMD[@]}" || { echo "ARM64_BUILD=FAIL reason=cross-build"; exit 1; }
  echo "ARM64_BUILD=PASS mode=sysroot out=$OUT"
  exit 0
fi

# ---- docker 路径预检 ----
if ! command -v docker >/dev/null 2>&1; then
  skip "docker-unavailable"
fi
if ! docker info >/dev/null 2>&1; then
  skip "docker-daemon-unavailable"
fi

say "基础镜像 $IMAGE"
NEED_PULL=0
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  NEED_PULL=1
  echo "镜像未缓存——需要 docker pull（离线环境会失败并 SKIP）"
fi

# `-i` + `bash -ls`：container_script 从 stdin 管道喂给容器内 bash。
#   `bash -lc -` 会把末尾 `-` 当「选项结束」标记 → `-c` 缺参数（CI 45025651776 实测
#   "bash: -c: option requires an argument"）；读 stdin 脚本的开关是 `-s`。
DOCKER_RUN=(docker run --rm -i --platform linux/arm64
  -v "$PWD":/work -w /work
  -e ZIG_VERSION="$ZIG_VERSION"
  -e ZILT_BUNDLE_WEBKIT="$BUNDLE"
  -e ZILT_PACK_OUT="$OUT"
  -e ZILT_ARM64_SKIP_TESTS="${ZILT_ARM64_SKIP_TESTS:-0}"
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)"
  # 构建缓存放容器 /tmp（不污染宿主仓库；zig-cache 跨架构不可复用）
  -e ZIG_LOCAL_CACHE_DIR=/tmp/zc -e ZIG_GLOBAL_CACHE_DIR=/tmp/zg
  "$IMAGE" bash -ls)

if [ "$CHECK" = 1 ]; then
  echo "NEED_PULL=$NEED_PULL"
  echo "CMD: ${DOCKER_RUN[*]} <container-script>"
  echo "ARM64_BUILD=CHECK_OK mode=docker image=$IMAGE"
  exit 0
fi

if [ "$NEED_PULL" = 1 ]; then
  if ! timeout 180 docker pull --platform linux/arm64 "$IMAGE" >/dev/null 2>&1; then
    skip "image-pull-failed(offline?)"
  fi
fi

# QEMU binfmt：--platform 依赖宿主已注册 aarch64 binfmt
if ! timeout 60 docker run --rm --platform linux/arm64 "$IMAGE" uname -m 2>/dev/null | grep -q aarch64; then
  skip "qemu-binfmt-unavailable(docker run --platform 失败；安装 qemu-user-static/binfmt 或 CI 用 docker/setup-qemu-action)"
fi

say "容器内构建（arm64）"
if ! container_script | "${DOCKER_RUN[@]}"; then
  echo "ARM64_BUILD=FAIL reason=container-build"
  exit 1
fi

# 产物清单（deb / AppDir / squashfs）
say "产物"
ls -lh "$OUT" 2>/dev/null || true
FAIL=0
for d in "$OUT"/*.deb; do
  [ -e "$d" ] || continue
  a=$(dpkg-deb -f "$d" Architecture 2>/dev/null || echo '?')
  echo "DEB=$(basename "$d") ARCH=$a"
  [ "$a" = "arm64" ] || { echo "ARCH_MISMATCH deb=$a（应为 arm64）"; FAIL=1; }
done
for r in "$OUT"/*.rpm; do
  [ -e "$r" ] || continue
  a=$(rpm -qp --qf '%{ARCH}' "$r" 2>/dev/null || echo '?')
  echo "RPM=$(basename "$r") ARCH=$a"
  [ "$a" = "aarch64" ] || { echo "ARCH_MISMATCH rpm=$a（应为 aarch64）"; FAIL=1; }
done
[ "$FAIL" = 0 ] || { echo "ARM64_BUILD=FAIL reason=arch-mismatch"; exit 1; }
echo "ARM64_BUILD=PASS mode=docker image=$IMAGE out=$OUT"
