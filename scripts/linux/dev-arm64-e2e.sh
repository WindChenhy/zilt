#!/usr/bin/env bash
# v0.4.3 L4：ARM64 产物冒烟（qemu-user / arm64 容器）
#
# 输入：dist-arm64/（build-arm64.sh 的产物）。优先用 AppDir（无需 FUSE），
# 有 AppImage 时先 --appimage-extract。
#
# 两种执行器：
#   A) qemu-aarch64-static + --sysroot：本机直跑（需要 sysroot 提供 arm64 运行库；
#      自包含 AppDir 已带全部库，qemu 只需 -L / 提供 ELF 解释器与 libc）
#   B) docker run --platform linux/arm64：容器内跑（CI 用 setup-qemu-action）
#
# 退出码：0 PASS / 1 FAIL / 3 SKIP（无产物 / 无 qemu / 无 binfmt）
set -u
cd "$(dirname "$0")/../.."
LOG=".zilt-probe/arm64-e2e.log"
mkdir -p .zilt-probe

# 与 x86_64 侧同口径：失败白名单默认为空（任何失败都算 FAIL）
KNOWN_FAILED=""

OUT="${ZILT_ARM64_OUT:-dist-arm64}"
SYSROOT="${ZILT_ARM64_SYSROOT:-}"
IMAGE="${ZILT_ARM64_IMAGE:-arm64v8/ubuntu:24.04}"

run_body() {
  APP="$OUT/app.zilt.desktop"
  APPIMAGE=$(ls "$OUT"/*.AppImage 2>/dev/null | head -1)

  [ -d "$APP" ] || { echo "MISSING_APPDIR=$APP（先跑 scripts/linux/build-arm64.sh）"; echo "ARM64_E2E=SKIP reason=no-appdir"; return 3; }
  if [ -n "$APPIMAGE" ]; then
    rm -rf "$OUT/squashfs-root"
    ( cd "$OUT" && "./$(basename "$APPIMAGE")" --appimage-extract >/dev/null 2>&1 ) || true
    [ -d "$OUT/squashfs-root" ] && APP="$OUT/squashfs-root"
  fi
  echo "APP=$APP"
  # 架构证据（aarch64 的 ELF machine=183）
  EXE="$APP/usr/bin/zilt-app"
  [ -f "$EXE" ] || { echo "MISSING_EXE"; echo "ARM64_E2E=FAIL reason=no-exe"; return 1; }
  MACHINE=$(readelf -h "$EXE" 2>/dev/null | awk '/Machine:/{print $2}')
  echo "ELF_MACHINE=$MACHINE"
  [ "$MACHINE" = "AArch64" ] || { echo "NOT_ARM64"; echo "ARM64_E2E=FAIL reason=not-arm64"; return 1; }

  python3 scripts/http_echo.py 8788 >/dev/null 2>&1 & EP=$!
  python3 scripts/ws_echo.py 8765 >/dev/null 2>&1 & WP=$!
  trap 'kill $EP $WP 2>/dev/null || true' EXIT

  check_result() { # $1=exit code $2=label
    local code="$1" label="$2" line failed f
    # 总结行（ALL … PASSED / FAILED n/m）之后还有 post terminate-check 行 → 精确匹配
    line=$(grep -a '\[linux-smoke\]' zilt.log | grep -a -E 'ALL .* CHECKS PASSED|FAILED ' | tail -1)
    if [ -z "$line" ] && [ "$code" = 0 ]; then echo "NO_SUMMARY_BUT_EXIT0"; return 0; fi
    echo "SMOKE[$label]_EXIT=$code"
    echo "SMOKE[$label]_RESULT=$line"
    if echo "$line" | grep -q 'ALL .* CHECKS PASSED'; then return 0; fi
    if echo "$line" | grep -q 'FAILED'; then
      failed=$(echo "$line" | sed -n 's/.*failed: \(.*\))/\1/p' | tr ',' ' ')
      for f in $failed; do
        case " $KNOWN_FAILED " in
          *" $f "*) echo "KNOWN_FAIL=$f" ;;
          *) echo "NEW_FAIL=$f"; return 1 ;;
        esac
      done
      echo "ONLY_KNOWN_FAILURES"
      return 0
    fi
    return 1
  }

  FAIL=0
  if command -v qemu-aarch64-static >/dev/null 2>&1; then
    echo "RUNNER=qemu-aarch64-static sysroot=${SYSROOT:-none}"
    QEMU=(qemu-aarch64-static)
    [ -n "$SYSROOT" ] && QEMU+=(-L "$SYSROOT")
    # 自包含 AppDir：LD_LIBRARY_PATH 指向随包库；qemu 负责 ELF 解释器
    rm -f zilt.log
    timeout 300 xvfb-run -a --server-args="-screen 0 1280x800x24" \
      env ZILT_LINUX_SMOKE=1 GDK_BACKEND=x11 \
          WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 LIBGL_ALWAYS_SOFTWARE=1 \
          LD_LIBRARY_PATH="$APP/usr/lib" \
      "${QEMU[@]}" "$EXE" > /tmp/arm64-run.log 2>&1
    code=$?
    check_result "$code" "qemu" || FAIL=1
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
       && docker run --rm --platform linux/arm64 "$IMAGE" uname -m 2>/dev/null | grep -q aarch64; then
    echo "RUNNER=docker image=$IMAGE"
    rm -f zilt.log
    timeout 300 xvfb-run -a --server-args="-screen 0 1280x800x24" \
      docker run --rm --network none \
        -v "$PWD/$APP:/app:ro" \
        -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
        -e DISPLAY="$DISPLAY" -e ZILT_LINUX_SMOKE=1 -e GDK_BACKEND=x11 \
        -e WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 -e LIBGL_ALWAYS_SOFTWARE=1 \
        "$IMAGE" /app/AppRun > /tmp/arm64-run.log 2>&1
    code=$?
    check_result "$code" "docker" || FAIL=1
  else
    echo "RUNNER=unavailable（无 qemu-aarch64-static，且 docker 无 arm64 binfmt）"
    echo "ARM64_E2E=SKIP reason=runner"
    return 3
  fi

  tail -5 /tmp/arm64-run.log 2>/dev/null || true
  if [ "$FAIL" = 0 ]; then echo "ARM64_E2E=PASS"; else echo "ARM64_E2E=FAIL"; fi
}

set +e
run_body > "$LOG" 2>&1
rc=$?
set -e

grep -a 'APP=\|ELF_MACHINE\|NOT_ARM64\|RUNNER=\|SMOKE\[\|ONLY_KNOWN\|KNOWN_FAIL\|NEW_FAIL\|ARM64_E2E=\|MISSING' "$LOG" || true
if [ "$rc" = 3 ]; then exit 3; fi
grep -aq 'ARM64_E2E=PASS' "$LOG" && exit 0
exit 1
