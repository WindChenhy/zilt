#!/usr/bin/env bash
# 单文件 AppImage E2E（v0.2.9）：
#   1. 取 AppImageKit 官方 runtime-x86_64（ZILT_APPIMAGE_RUNTIME 缓存 / GitHub 下载）
#   2. cat runtime + squashfs → 单文件 AppImage
#   3. 冒烟跑通产物（66 项 exit 0）
# runtime 下载失败（离线）时如实 SKIP（退出码 3，CI 可区分）。
set -u
cd "$(dirname "$0")/../.."
LOG=".zilt-probe/appimage-last.log"
mkdir -p .zilt-probe
{
  SQ="dist/app.zilt.desktop.squashfs"
  RT=".zilt-probe/appimage-runtime-x86_64"
  OUT="dist/Zilt.AppImage"

  if [ ! -f "$SQ" ]; then echo "MISSING_SQUASHFS"; echo "APPIMAGE_E2E=SKIP"; exit 3; fi

  if [ ! -f "$RT" ]; then
    if [ -n "${ZILT_APPIMAGE_RUNTIME:-}" ] && [ -f "$ZILT_APPIMAGE_RUNTIME" ]; then
      cp "$ZILT_APPIMAGE_RUNTIME" "$RT"
      echo "RUNTIME=cache"
    else
      URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/runtime-x86_64"
      echo "RUNTIME=download $URL"
      curl -sL -m 120 -o "$RT" "$URL" || { echo "DOWNLOAD_FAILED"; echo "APPIMAGE_E2E=SKIP"; exit 3; }
    fi
  fi
  chmod +x "$RT"
  SIZE=$(stat -c %s "$RT")
  echo "RUNTIME_BYTES=$SIZE"
  # runtime 必须是 ELF（下载到 HTML 错误页时拦下）
  head -c 4 "$RT" | grep -q "ELF" || { echo "NOT_ELF"; echo "APPIMAGE_E2E=SKIP"; exit 3; }

  cat "$RT" "$SQ" > "$OUT"
  chmod +x "$OUT"
  echo "APPIMAGE_BYTES=$(stat -c %s "$OUT")"

  rm -f zilt.log
  export ZILT_LINUX_SMOKE=1 GDK_BACKEND=x11 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 LIBGL_ALWAYS_SOFTWARE=1
  python3 scripts/http_echo.py 8788 > /dev/null 2>&1 &
  ECHO_PID=$!
  python3 scripts/ws_echo.py 8765 > /dev/null 2>&1 &
  WS_PID=$!
  set +e
  # 优先 FUSE 直跑；无 FUSE（WSL/容器常态）降级 --appimage-extract + 提取版
  # AppRun——runtime 对 squashfs 的识别/校验仍然真实发生（magic + 完整性）
  timeout 240 xvfb-run -a --server-args="-screen 0 1280x800x24" "$OUT" > /tmp/appimage-run.log 2>&1
  code=$?
  if [ $code -ne 0 ] && grep -q "FUSE" /tmp/appimage-run.log; then
    echo "FUSE_UNAVAILABLE -> --appimage-extract fallback"
    (cd dist && "./$(basename "$OUT")" --appimage-extract > /dev/null 2>&1)
    EXTRACTED="dist/squashfs-root/AppRun"
    [ -f "$EXTRACTED" ] || { echo "EXTRACT_FAILED"; echo "APPIMAGE_E2E=FAIL"; kill $ECHO_PID $WS_PID 2>/dev/null; exit 1; }
    timeout 240 xvfb-run -a --server-args="-screen 0 1280x800x24" "$EXTRACTED" 2>&1 | tail -5
    code=${PIPESTATUS[0]}
  fi
  set -e
  kill $ECHO_PID $WS_PID 2>/dev/null
  echo "SMOKE_EXIT=$code"
  if [ "$code" = "0" ]; then echo "APPIMAGE_E2E=PASS"; else echo "APPIMAGE_E2E=FAIL"; fi
} > "$LOG" 2>&1

grep -a 'RUNTIME\|APPIMAGE\|SMOKE_EXIT' "$LOG"
grep -aq 'APPIMAGE_E2E=PASS' "$LOG" && exit 0
grep -aq 'APPIMAGE_E2E=SKIP' "$LOG" && exit 3
exit 1
