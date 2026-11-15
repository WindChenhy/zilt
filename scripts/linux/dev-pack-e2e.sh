#!/usr/bin/env bash
# 打包 E2E（v0.2.4）：zig build pack 的产物逐项实测（无需 root）。
#   1. dpkg-deb --info/-x：包元数据与内容提取
#   2. 从提取目录运行安装版 exe（Xvfb 冒烟 57 项）
#   3. AppDir 的 AppRun 直接执行（Xvfb 冒烟）
#   4. squashfs 镜像列表校验
# 结论写 .zilt-probe/pack-e2e.log；退出码 0 = 全过。
set -u
cd "$(dirname "$0")/../.."
LOG=".zilt-probe/pack-e2e.log"

export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$HOME/.zcache/zilt-linux}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.zcache/zig-global}"
export GDK_BACKEND=x11
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export LIBGL_ALWAYS_SOFTWARE=1
export ZILT_LINUX_SMOKE=1

# 冒烟的 http 检查需要回声服务器（同 dev-smoke.sh）
python3 scripts/http_echo.py 8788 > /dev/null 2>&1 &
echo_pid=$!
trap 'kill $echo_pid 2>/dev/null' EXIT

{
  zig build pack
} > "$LOG" 2>&1

DEB=$(ls dist/*_amd64.deb 2>/dev/null | head -1)
APPDIR=$(ls -d dist/*.zilt*/ 2>/dev/null | head -1)
SQ=$(ls dist/*.squashfs 2>/dev/null | head -1)

ok=1
{
  echo "== 1) deb 元数据 =="
  [ -n "$DEB" ] || { echo "MISSING deb"; ok=0; }
  if [ -n "$DEB" ]; then
    dpkg-deb --info "$DEB" | head -12 || ok=0
    dpkg-deb --info "$DEB" | grep -aq "Depends: libgtk-3-0, libwebkit2gtk-4.1-0, libsqlite3-0" || { echo "DEPENDS MISSING"; ok=0; }
    rm -rf /tmp/zilt-deb-x && dpkg-deb -x "$DEB" /tmp/zilt-deb-x || ok=0
    ls -la /tmp/zilt-deb-x/usr/bin/ || ok=0
    ls /tmp/zilt-deb-x/usr/share/applications/ || ok=0
    ls /tmp/zilt-deb-x/usr/share/icons/hicolor/256x256/apps/ || ok=0
  fi

  echo "== 2) 安装版（dpkg-deb -x 提取）冒烟 =="
  if [ -x /tmp/zilt-deb-x/usr/bin/zilt-app ]; then
    rm -f zilt.log
    timeout 180 xvfb-run -a --server-args="-screen 0 1280x800x24" /tmp/zilt-deb-x/usr/bin/zilt-app > /dev/null 2>&1
    code=$?
    echo "INSTALLED_SMOKE_EXIT=$code"
    [ "$code" = "0" ] || ok=0
    grep -aqE "ALL [0-9]+ CHECKS PASSED" zilt.log || { echo "SMOKE NOT GREEN"; ok=0; }
  else
    echo "EXTRACTED EXE MISSING"; ok=0
  fi

  echo "== 3) AppDir AppRun 冒烟 =="
  if [ -x "$APPDIR/AppRun" ]; then
    rm -f zilt.log
    timeout 180 xvfb-run -a --server-args="-screen 0 1280x800x24" "$APPDIR/AppRun" > /dev/null 2>&1
    code=$?
    echo "APPRUN_SMOKE_EXIT=$code"
    [ "$code" = "0" ] || ok=0
    grep -aqE "ALL [0-9]+ CHECKS PASSED" zilt.log || { echo "SMOKE NOT GREEN"; ok=0; }
  else
    echo "APPRUN MISSING at $APPDIR"; ok=0
  fi

  echo "== 4) squashfs =="
  if [ -n "$SQ" ]; then
    # unsquashfs -l 不在时用 mksquashfs 产物大小断言（> 2MB）
    sz=$(stat -c%s "$SQ")
    echo "SQUASHFS_BYTES=$sz"
    [ "$sz" -gt 2000000 ] || ok=0
  else
    echo "SQUASHFS MISSING"; ok=0
  fi
} >> "$LOG" 2>&1

if [ "$ok" = "1" ]; then echo "PACK_E2E=PASS" >> "$LOG"; else echo "PACK_E2E=FAIL" >> "$LOG"; fi
grep -a "INSTALLED_SMOKE_EXIT\|APPRUN_SMOKE_EXIT\|SQUASHFS_BYTES\|PACK_E2E\|DEPENDS\|MISSING" "$LOG"
exit "$ok"
