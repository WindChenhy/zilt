#!/usr/bin/env bash
# v0.4.3 L6：托盘挂窗 E2E —— attach_window 接线 + stalonetray（XEmbed）实测。
#
# 环境：Xvfb（1280x800）+ openbox（WM，焦点/边框语义）+ stalonetray（XEmbed 托盘，
# 顶部右侧 1x1 槽）。点击用 scripts/linux/xtool.py（XTest，无 xdotool 依赖）。
#
# 验收点：
#   1) 左键图标 → 主窗口隐藏（activate → toggle）
#   2) 再左键 → 显示，且贴图标定位（右缘对齐 + 下方/上方 4px）
#   3) 右键图标 → 托盘菜单弹出
#   4) ZILT_FOCUS_FOLLOWS_MOUSE=1 → FFM 语义生效日志（挂窗 hideOnFocusLost 禁用）
#
# 用法：bash scripts/linux/dev-tray-e2e.sh [--no-build]
# 输出：.zilt-probe/tray-e2e.log（WSL 的 /tmp 随实例重启清空，以文件为准）
set -eu
cd "$(dirname "$0")/../.."
LOG=".zilt-probe/tray-e2e.log"
EXIT_FILE=".zilt-probe/tray-e2e.exit"
mkdir -p .zilt-probe

BUILD=1
if [ "${1:-}" = "--no-build" ]; then BUILD=0; fi

# v0.5.11：测试主体放进子 shell 并关掉 -e ——
# 主体里的 `[ -n "$X" ] && break`、`$XT click` 在 set -e 下一旦返回 1 就直接退出，
# 既不会有 RESULT 行，也跑不到下面的诊断块（CI 上表现为 20 秒空日志红）。
set +e
(
  export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$HOME/.zcache/zilt-linux}"
  export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.zcache/zig-global}"
  mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
  export GDK_BACKEND=x11 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 LIBGL_ALWAYS_SOFTWARE=1
  export DISPLAY=:97

  for bin in Xvfb openbox stalonetray python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "MISSING_DEP=$bin"
      echo "RESULT=FAIL reason=missing-$bin"
      exit 3
    fi
  done

  if [ "$BUILD" = 1 ]; then
    zig build
  fi

  XT="python3 scripts/linux/xtool.py"
  FAIL=0
  pass() { echo "PASS  $*"; }
  fail() { echo "FAIL  $*"; FAIL=1; }

  cleanup() {
    pkill -f 'zig-out/bin/zilt-app' 2>/dev/null || true
    pkill -f stalonetray 2>/dev/null || true
    pkill -f 'Xvfb :97' 2>/dev/null || true
  }
  trap cleanup EXIT

  start_stack() {
    cleanup
    sleep 0.5
    Xvfb :97 -screen 0 1280x800x24 >/tmp/zilt-tray-xvfb.log 2>&1 &
    sleep 1
    openbox >/tmp/zilt-tray-openbox.log 2>&1 &
    sleep 0.6
    stalonetray --geometry 1x1-0+0 --icon-size 24 --slot-size 28 --window-strut none \
      >/tmp/zilt-tray-stalonetray.log 2>&1 &
    sleep 1
    rm -f zilt.log
  }

  # 等日志出现（最长 $2 秒）
  wait_log() {
    local pat="$1" limit="${2:-25}" i=0
    while [ "$i" -lt "$((limit * 4))" ]; do
      if [ -f zilt.log ] && grep -aq "$pat" zilt.log; then return 0; fi
      sleep 0.25
      i=$((i + 1))
    done
    return 1
  }

  # 等窗口消失/出现（visible <id> 的语义：0=可见）
  wait_visible() {
    local id="$1" want="$2" limit="${3:-20}" i=0
    while [ "$i" -lt "$((limit * 4))" ]; do
      if $XT visible "$id" >/dev/null 2>&1; then
        [ "$want" = 1 ] && return 0
      else
        [ "$want" = 0 ] && return 0
      fi
      sleep 0.25
      i=$((i + 1))
    done
    return 1
  }

  echo "=== run 1: attach toggle + geometry + menu ==="
  start_stack
  ./zig-out/bin/zilt-app >/tmp/zilt-tray-app.log 2>&1 &
  APP_PID=$!

  if wait_log "main window ready" 30; then pass "app started"; else fail "app start (no 'main window ready')"; fi
  # 演示页内置自检会创建/销毁窗口并抢焦点——等它跑完再点托盘
  wait_log "\[updater\] health confirmed" 40 || true
  sleep 1

  MAIN=""
  ICON=""
  for _ in $(seq 1 40); do
    MAIN=$($XT findtitle "示例" 2>/dev/null | tail -1 || true)
    ICON=$($XT trayicon 2>/dev/null | head -1 || true)
    if [ -n "$MAIN" ] && [ -n "$ICON" ]; then break; fi
    sleep 0.25
  done
  echo "main=$MAIN icon=$ICON"
  if [ -z "$MAIN" ]; then fail "main window not found"; fi
  if [ -z "$ICON" ]; then fail "tray icon window not found"; fi

  if [ -n "$ICON" ] && [ -n "$MAIN" ]; then
    read -r ix iy iw ih <<EOF
$($XT geom "$ICON")
EOF
    echo "icon_geom=$ix,$iy ${iw}x${ih}"
    read -r mx0 my0 mw0 mh0 <<EOF
$($XT geom "$MAIN")
EOF
    echo "main_geom_initial=$mx0,$my0 ${mw0}x${mh0}"
    if $XT visible "$MAIN" >/dev/null 2>&1; then pass "main visible before click"; else fail "main not visible before click"; fi

    # 1) 左键 → 隐藏
    $XT click $((ix + iw / 2)) $((iy + ih / 2)) 1
    if wait_visible "$MAIN" 0 12; then pass "left click hides attach window"; else fail "left click did not hide window"; fi
    if grep -aq 'attach window #1 hidden' zilt.log; then pass "log: attach window hidden"; else fail "log: hidden line missing"; fi
    # 去抖窗（200ms）内连点会被合并——这里模拟人的第二次点击间隔
    sleep 0.45

    # 2) 左键 → 显示 + 贴图标定位
    $XT click $((ix + iw / 2)) $((iy + ih / 2)) 1
    if wait_visible "$MAIN" 1 12; then pass "second left click shows window"; else fail "second left click did not show window"; fi
    # v0.6.0：先等后端 positioned 日志，再轮询 X 几何（CI 负载下 2.4s 会采到移动前坐标）
    wait_log "attach window #1 positioned" 40 || true
    icon_right=$((ix + iw))
    icon_bottom=$((iy + ih))
    icon_top=$iy
    # v0.5.11：定位请求现在等 mapped 后才下（最多 600ms）+ 80ms 外框校正，
    # 固定 sleep 0.4 会采到中间态 → 轮询到锚定或 9s 超时再断言。
    for _ in $(seq 1 60); do
      read -r mx my mw mh <<EOF
$($XT geom "$MAIN")
EOF
      if [ $((mx + mw)) -ge $((icon_right - 2)) ] && [ $((mx + mw)) -le $((icon_right + 2)) ] \
        && { { [ "$my" -ge $((icon_bottom + 2)) ] && [ "$my" -le $((icon_bottom + 6)) ]; } \
          || { [ $((my + mh)) -le $((icon_top - 2)) ] && [ $((my + mh)) -ge $((icon_top - 6)) ]; }; }; then
        break
      fi
      sleep 0.15
    done
    echo "main_geom_after=$mx,$my ${mw}x${mh}"
    if [ $((mx + mw)) -ge $((icon_right - 2)) ] && [ $((mx + mw)) -le $((icon_right + 2)) ]; then
      pass "window right edge aligns icon right edge ($((mx + mw)) vs $icon_right)"
    else
      fail "window right edge misaligned ($((mx + mw)) vs $icon_right)"
    fi
    if [ "$my" -ge $((icon_bottom + 2)) ] && [ "$my" -le $((icon_bottom + 6)) ]; then
      pass "window below icon (y=$my, icon_bottom=$icon_bottom)"
    elif [ $((my + mh)) -le $((icon_top - 2)) ] && [ $((my + mh)) -ge $((icon_top - 6)) ]; then
      pass "window above icon (flip; bottom=$((my + mh)), icon_top=$icon_top)"
    else
      fail "window not anchored to icon (y=$my h=$mh icon_top=$icon_top bottom=$icon_bottom)"
    fi
    if grep -aq 'icon geometry' zilt.log; then pass "log: gtk_status_icon_get_geometry anchor"; else fail "log: geometry line missing"; fi

    # 3) 右键 → 菜单
    $XT click $((ix + iw / 2)) $((iy + ih / 2)) 3
    sleep 0.8
    MENU=""
    for _ in $(seq 1 12); do
      MENU=$($XT findclass "zilt" 2>/dev/null | while read -r w; do
        read -r _wx _wy _ww _wh <<EOF
$($XT geom "$w")
EOF
        if [ "$_ww" -lt 400 ] && [ "$_wh" -lt 700 ] && [ "$_ww" -gt 40 ] && [ "$_wh" -gt 40 ]; then echo "$w"; fi
      done | head -1)
      if [ -n "$MENU" ]; then break; fi
      sleep 0.25
    done
    if [ -n "$MENU" ]; then pass "right click opens tray menu (win $MENU)"; else fail "right click menu not detected"; fi
    if grep -aq 'xembed popup menu' zilt.log; then pass "log: popup menu"; else fail "log: popup menu line missing"; fi
    $XT key Escape || true
    sleep 0.3
  fi

  kill "$APP_PID" 2>/dev/null || true
  sleep 1
  cp -f zilt.log .zilt-probe/tray-run1.log 2>/dev/null || true
  echo "=== tray log run1 (grep) ==="
  grep -a '\[tray\]' .zilt-probe/tray-run1.log | tail -20 || true

  echo "=== run 2: focus-follows-mouse 检测（挂窗 hideOnFocusLost 禁用）==="
  start_stack
  ZILT_FOCUS_FOLLOWS_MOUSE=1 ./zig-out/bin/zilt-app >/tmp/zilt-tray-app-ffm.log 2>&1 &
  APP_PID2=$!
  if wait_log "focus-follows-mouse desktop" 25; then
    pass "FFM env override detected"
  else
    fail "FFM env override not detected"
  fi
  if grep -aq 'attach window hideOnFocusLost disabled' zilt.log; then
    pass "log: hideOnFocusLost disabled under FFM"
  else
    fail "log: FFM disable line missing"
  fi
  kill "$APP_PID2" 2>/dev/null || true
  sleep 1

  echo "=== tray log (grep) ==="
  grep -a '\[tray\]' zilt.log | tail -20 || true

  if [ "$FAIL" = 0 ]; then echo "RESULT=PASS"; else echo "RESULT=FAIL"; fi
  exit "$FAIL"
) > "$LOG" 2>&1
body_rc=$?
set -e

code=$(grep -a '^RESULT=' "$LOG" | tail -1 | sed 's/RESULT=//' || true)
case "$code" in
  PASS) echo 0 > "$EXIT_FILE"; exit 0 ;;
  *)
    # 诊断：run_body 在 set -eu 下提前退出时不会有 RESULT 行，CI 只剩一句 exit 1。
    # 这里把尾部日志回显到 step 输出，否则失败不可见（2026-11-26 定位抖动时踩过）。
    echo "TRAY_E2E=FAIL reason=${code:-no-RESULT-line} rc=$body_rc"
    tail -120 "$LOG" 2>/dev/null || true
    echo 1 > "$EXIT_FILE"
    exit 1
    ;;

esac
