#!/usr/bin/env bash
# GTK4 SNI 托盘 headless 探针（v0.6.2 起）
#
# 验证不依赖桌面宿主的那部分 SNI 契约：
#   1. 会话总线上出现 org.kde.StatusNotifierItem-<pid>-1
#   2. /StatusNotifierItem 暴露非空 IconName、Status、Menu 路径
#   3. /MenuBar 的 com.canonical.dbusmenu.GetLayout 能返回菜单树
#   4. Activate（左键语义）→ 挂窗 toggle：窗口从可见变隐藏，再点回可见
#
# 显式不做：宿主把像素画到面板上的**观感**（需要真实 StatusNotifierHost，
# 如 GNOME AppIndicator 扩展 / KDE 面板）；像素本身由 IconPixmap 随属性发出，
# 已在 Xvfb + snixembed + stalonetray 下实测渲染（见 docs/ROADMAP.md）。
#
# 用法：
#   scripts/linux/dev-sni-e2e.sh [app 可执行文件]
#   默认 ./zig-out/bin/zilt-app；无 DISPLAY 时自起 Xvfb + openbox。
# 退出码：0 通过 / 1 失败 / 3 跳过（缺 gdbus/Xvfb）
set -uo pipefail

APP="${1:-./zig-out/bin/zilt-app}"
DISPLAY_NUM="${ZILT_SNI_DISPLAY:-:99}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "SKIP: 缺少 $1"; exit 3; }; }
need gdbus
need Xvfb
need openbox

[ -x "$APP" ] || { echo "FAIL: 找不到可执行文件 $APP"; exit 1; }

# 没有会话总线就自建一个（CI / WSL 的 bare shell 都没有）
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  command -v dbus-run-session >/dev/null 2>&1 || { echo "SKIP: 缺少 dbus-run-session"; exit 3; }
  exec dbus-run-session -- "$0" "$@"
fi

export DISPLAY="$DISPLAY_NUM"
export GDK_BACKEND=x11
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export LIBGL_ALWAYS_SOFTWARE=1
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/zilt-xdg-$$}"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

XVFB_PID=""; OB_PID=""; APP_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  [ -n "$OB_PID" ] && kill "$OB_PID" 2>/dev/null
  [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  for _ in $(seq 1 50); do xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break; sleep 0.1; done
fi
openbox >/dev/null 2>&1 &
OB_PID=$!
sleep 0.4

echo "== 启动 $APP =="
"$APP" >/tmp/zilt-sni-app.log 2>&1 &
APP_PID=$!

BUS="org.kde.StatusNotifierItem-${APP_PID}-1"
ITEM_PATH="/StatusNotifierItem"
MENU_PATH="/MenuBar"

# 1) 等总线名出现（最多 20s）
ok_bus=0
for _ in $(seq 1 200); do
  names=$(gdbus call --session --dest org.freedesktop.DBus \
    --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames 2>/dev/null)
  if printf '%s' "$names" | grep -q "'${BUS}'"; then ok_bus=1; break; fi
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 0.1
done
if [ "$ok_bus" -ne 1 ]; then
  echo "FAIL: 会话总线未出现 $BUS"
  tail -30 /tmp/zilt-sni-app.log
  exit 1
fi
echo "PASS 总线名 $BUS"

prop() {
  gdbus call --session --dest "$BUS" --object-path "$ITEM_PATH" \
    --method org.freedesktop.DBus.Properties.Get org.kde.StatusNotifierItem "$1" 2>/dev/null
}

# 2) 属性
icon=$(prop IconName)
status=$(prop Status)
menu=$(prop Menu)
echo "  IconName=$icon Status=$status Menu=$menu"
if printf '%s' "$menu" | grep -q "$MENU_PATH"; then
  echo "PASS Menu 属性指向 $MENU_PATH"
else
  echo "FAIL: Menu 属性异常: $menu"; exit 1
fi
if printf '%s' "$icon" | grep -qE "'[^']+'"; then
  echo "PASS IconName 非空"
else
  echo "FAIL: IconName 为空: $icon"; exit 1
fi
# IconPixmap（v0.6.3）：a(iiay) 里必须真的有像素——这是不依赖宿主图标主题的路径
pixmap=$(prop IconPixmap)
if printf '%s' "$pixmap" | grep -q "byte" && printf '%s' "$pixmap" | grep -qE '\(64, 64|\(32, 32'; then
  echo "PASS IconPixmap 携带像素（$(printf '%s' "$pixmap" | head -c 60)…）"
else
  echo "FAIL: IconPixmap 为空或尺寸异常: $(printf '%s' "$pixmap" | head -c 120)"; exit 1
fi

# 3) 菜单树
# `-1` 会被 gdbus 当成选项解析 → 必须用 `--` 结束选项
layout=$(gdbus call --session --dest "$BUS" --object-path "$MENU_PATH" \
  --method com.canonical.dbusmenu.GetLayout -- 0 -1 "[]" 2>&1)
if printf '%s' "$layout" | grep -q "label"; then
  echo "PASS GetLayout 返回菜单树（$(printf '%s' "$layout" | head -c 160)…）"
else
  echo "FAIL: GetLayout 无菜单项: $(printf '%s' "$layout" | head -c 200)"; exit 1
fi

# 4) Activate → 挂窗 toggle
# 不能用「可见窗口数」判断：演示应用启动即跑 96 项冒烟，会不断建/销窗口。
# 改用应用自己的日志（hidden/shown 各一行），与窗口 churn 无关。
LOG=/tmp/zilt-sni-app.log
count_log() { grep -a -c "$1" "$LOG" 2>/dev/null || true; }
hidden0=$(count_log "attach window .* hidden")
shown0=$(count_log "attach window .* shown")

activate() {
  gdbus call --session --dest "$BUS" --object-path "$ITEM_PATH" \
    --method org.kde.StatusNotifierItem.Activate 0 0 >/dev/null 2>&1
}
wait_log() {
  local pat="$1" base="$2" i
  for i in $(seq 1 80); do
    [ "$(count_log "$pat")" -gt "$base" ] && return 0
    sleep 0.1
  done
  return 1
}

activate
if wait_log "attach window .* hidden" "$hidden0"; then
  echo "PASS Activate 隐藏挂窗（hidden $hidden0 → $(count_log "attach window .* hidden")）"
else
  echo "FAIL: Activate 后未出现 hidden 日志"; tail -5 "$LOG"; exit 1
fi
sleep 0.35  # 越过 toggle 的 200ms 去抖
activate
if wait_log "attach window .* shown" "$shown0"; then
  echo "PASS Activate 再次显示挂窗（shown $shown0 → $(count_log "attach window .* shown")）"
else
  echo "FAIL: 第二次 Activate 后未出现 shown 日志"; tail -5 "$LOG"; exit 1
fi

echo "== SNI 探针通过（像素由 IconPixmap 提供；宿主侧渲染见 ROADMAP 视觉验证记录）=="
