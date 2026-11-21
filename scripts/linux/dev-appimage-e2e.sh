#!/usr/bin/env bash
# 单文件 AppImage E2E（v0.2.9；v0.4.3 L3 扩「无宿主 WebKit」验证）：
#   1. 构建（ZILT_BUNDLE_WEBKIT=1 → AppDir 收入 WebKit + helper，AppRun 改写 helper 路径）
#   2. 取 AppImageKit 官方 runtime-x86_64（ZILT_APPIMAGE_RUNTIME 缓存 / GitHub 下载）
#   3. cat runtime + squashfs → 单文件 AppImage；无 FUSE 走 --appimage-extract
#   4. **无宿主 WebKit 沙箱**：docker（有镜像时）或 bubblewrap 掩掉宿主的
#      libwebkit2gtk / libjavascriptcoregtk / helper 目录 → 冒烟必须仍跑通
#      （证明随包自包含；无镜像/离线时 docker 路径跳过，bwrap 为等价命名空间）
#
# 退出码：0 PASS / 1 FAIL / 3 SKIP（runtime 或沙箱能力缺失）
set -u
cd "$(dirname "$0")/../.."
LOG=".zilt-probe/appimage-last.log"
mkdir -p .zilt-probe

# 已知失败白名单：v0.4.3 L3 起为空（布局装箱与剪贴板写入的既有缺陷已修，
# 冒烟 95/95 exit 0）——这里保留机制，后续出现平台差异时按需登记。
KNOWN_FAILED=""

run_body() {
  SQ="dist/app.zilt.desktop.squashfs"
  RT=".zilt-probe/appimage-runtime-x86_64"
  OUT="dist/Zilt.AppImage"
  APPDIR="dist/app.zilt.desktop"
  TRIPLET="x86_64-linux-gnu"

  # ---- 1) 构建（随包 WebKit）----
  if [ "${ZILT_APPIMAGE_NO_BUILD:-0}" != "1" ]; then
    export ZILT_BUNDLE_WEBKIT="${ZILT_BUNDLE_WEBKIT:-1}"
    echo "BUILD=bundle_webkit=${ZILT_BUNDLE_WEBKIT}"
    zig build pack || { echo "APPIMAGE_E2E=FAIL reason=pack-failed"; return 1; }
  fi
  if [ ! -f "$APPDIR/usr/lib/libwebkit2gtk-4.1.so.0" ]; then
    echo "MISSING_BUNDLED_WEBKIT（用 ZILT_BUNDLE_WEBKIT=1 zig build pack 重建）"
    echo "APPIMAGE_E2E=FAIL reason=not-bundled"
    return 1
  fi
  if [ ! -x "$APPDIR/usr/lib/$TRIPLET/webkit2gtk-4.1/WebKitWebProcess" ]; then
    echo "MISSING_HELPERS"
    echo "APPIMAGE_E2E=FAIL reason=no-helpers"
    return 1
  fi
  echo "APPDIR_BYTES=$(du -sb "$APPDIR" | cut -f1)"

  if [ ! -f "$SQ" ]; then echo "MISSING_SQUASHFS"; echo "APPIMAGE_E2E=SKIP"; return 3; fi

  # ---- 2) runtime ----
  if [ ! -f "$RT" ]; then
    if [ -n "${ZILT_APPIMAGE_RUNTIME:-}" ] && [ -f "$ZILT_APPIMAGE_RUNTIME" ]; then
      cp "$ZILT_APPIMAGE_RUNTIME" "$RT"
      echo "RUNTIME=cache"
    else
      URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/runtime-x86_64"
      echo "RUNTIME=download $URL"
      curl -sL -m 120 -o "$RT" "$URL" || { echo "DOWNLOAD_FAILED"; echo "APPIMAGE_E2E=SKIP"; return 3; }
    fi
  fi
  chmod +x "$RT"
  echo "RUNTIME_BYTES=$(stat -c %s "$RT")"
  head -c 4 "$RT" | grep -q "ELF" || { echo "NOT_ELF"; echo "APPIMAGE_E2E=SKIP"; return 3; }

  cat "$RT" "$SQ" > "$OUT"
  chmod +x "$OUT"
  echo "APPIMAGE_BYTES=$(stat -c %s "$OUT")"

  # ---- 3) 解包（WSL/容器无 FUSE 的常态；runtime 的 magic/完整性校验仍真实发生）----
  rm -rf dist/squashfs-root
  ( cd dist && "./$(basename "$OUT")" --appimage-extract >/dev/null 2>&1 )
  EXTRACTED="dist/squashfs-root/AppRun"
  [ -f "$EXTRACTED" ] || { echo "EXTRACT_FAILED"; echo "APPIMAGE_E2E=FAIL reason=extract"; return 1; }
  echo "EXTRACTED=ok"

  python3 scripts/http_echo.py 8788 >/dev/null 2>&1 &
  ECHO_PID=$!
  python3 scripts/ws_echo.py 8765 >/dev/null 2>&1 &
  WS_PID=$!
  trap 'kill $ECHO_PID $WS_PID 2>/dev/null' EXIT

  run_smoke() { # $@ = 命令（可直接 AppRun，也可沙箱包装）
    rm -f zilt.log
    timeout 240 xvfb-run -a --server-args="-screen 0 1280x800x24" \
      env ZILT_LINUX_SMOKE=1 GDK_BACKEND=x11 \
          WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 LIBGL_ALWAYS_SOFTWARE=1 \
      "$@" > /tmp/appimage-run.log 2>&1
    echo $?
  }

  check_result() { # $1=exit code  $2=label
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

  # ---- 4a) 基线：宿主 WebKit 在场 ----
  code=$(run_smoke "$EXTRACTED")
  check_result "$code" "host" || FAIL=1

  # ---- 4b) 无宿主 WebKit ----
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
     && docker image inspect "${ZILT_APPIMAGE_DOCKER_IMAGE:-ubuntu:22.04}" >/dev/null 2>&1; then
    IMG="${ZILT_APPIMAGE_DOCKER_IMAGE:-ubuntu:22.04}"
    echo "SANDBOX=docker image=$IMG"
    code=$(run_smoke docker run --rm --network none \
      -u "$(id -u):$(id -g)" \
      -v "$PWD/dist/squashfs-root:/app:ro" \
      -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
      -e DISPLAY="$DISPLAY" \
      "$IMG" /app/AppRun)
    check_result "$code" "docker" || FAIL=1
  elif command -v bwrap >/dev/null 2>&1 && bwrap --dev-bind / / true 2>/dev/null; then
    echo "SANDBOX=bwrap（掩掉宿主 libwebkit/libjavascriptcore/helper——与 docker 无 WebKit 等价）"
    MASKS=()
    for f in /usr/lib/$TRIPLET/libwebkit2gtk-4.1.so.0 /usr/lib/$TRIPLET/libwebkit2gtk-4.1.so.0.*; do
      [ -e "$f" ] && MASKS+=(--ro-bind /dev/null "$f")
    done
    for f in /usr/lib/$TRIPLET/libjavascriptcoregtk-4.1.so.0 /usr/lib/$TRIPLET/libjavascriptcoregtk-4.1.so.0.*; do
      [ -e "$f" ] && MASKS+=(--ro-bind /dev/null "$f")
    done
    [ -d /usr/lib/$TRIPLET/webkit2gtk-4.1 ] && MASKS+=(--tmpfs /usr/lib/$TRIPLET/webkit2gtk-4.1)
    echo "MASK_COUNT=${#MASKS[@]}"
    code=$(run_smoke bwrap --dev-bind / / "${MASKS[@]}" "$EXTRACTED")
    check_result "$code" "no-host-webkit" || FAIL=1

    # 证据：加载的是随包路径（LD_DEBUG 记录必须命中 squashfs-root/dist）
    rm -f /tmp/lddebug.*
    ( timeout 60 xvfb-run -a bwrap --dev-bind / / "${MASKS[@]}" \
        env LD_DEBUG=libs LD_DEBUG_OUTPUT=/tmp/lddebug GDK_BACKEND=x11 \
            WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 LIBGL_ALWAYS_SOFTWARE=1 \
        "$EXTRACTED" >/dev/null 2>&1 ) || true
    BUNDLED_HIT=$(grep -h 'libwebkit2gtk' /tmp/lddebug.* 2>/dev/null | grep -c "squashfs-root\|dist")
    echo "BUNDLED_LIBWEBKIT_HITS=$BUNDLED_HIT"
    [ "$BUNDLED_HIT" -gt 0 ] || { echo "BUNDLE_NOT_USED"; FAIL=1; }
  else
    echo "SANDBOX=unavailable（无 docker 镜像且 bwrap 不可用）"
    echo "APPIMAGE_E2E=SKIP reason=sandbox"
    return 3
  fi

  if [ "$FAIL" = 0 ]; then echo "APPIMAGE_E2E=PASS"; else echo "APPIMAGE_E2E=FAIL"; fi
}

set +e
run_body > "$LOG" 2>&1
rc=$?
set -e

grep -a 'BUILD=\|APPDIR_BYTES\|RUNTIME=\|APPIMAGE_BYTES\|EXTRACTED=\|SANDBOX=\|MASK_COUNT\|SMOKE\[\|ONLY_KNOWN\|KNOWN_FAIL\|NEW_FAIL\|BUNDLED_\|BUNDLE_NOT_USED\|APPIMAGE_E2E=\|MISSING' "$LOG" || true
if [ "$rc" = 3 ]; then exit 3; fi
grep -aq 'APPIMAGE_E2E=PASS' "$LOG" && exit 0
exit 1
