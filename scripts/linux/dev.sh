#!/usr/bin/env bash
# zig build dev 的 Linux 实现（v0.2.8）——与 src/tools/dev.zig（Windows）同一编排语义：
#   1. spawn frontend dev_command（cwd = frontend dir）
#   2. TCP 直连 127.0.0.1 探测等待 dev_url（规避 getaddrinfo localhost 双栈歧义）
#   3. 注入 ZILT_DEV_URL（或 ZILT_DEV_PROXY=反代模式）后拉起应用
#   4. ZILT_DEV_WATCH=1：盯 src/**.zig 与 build.zig* 的 mtime → 先杀应用（解锁
#      exe——Linux 上 install 覆盖运行中文件不需要解锁，但应用要跑新代码必须重启）
#      → 等 zig build --watch 写出新 exe → 拉起；`zig build --watch` 的重建/错误
#      输出直接在控制台
# 参数（由 build.zig 的 dev step 注入，与 dev.zig 相同顺序）：
#   dev.sh <exe-path> <dev-command|-> <dev-url|-> <wait-timeout-secs> <frontend-dir> [proxy-flag]
set -u
EXE="$1"; DEV_CMD="$2"; DEV_URL="$3"; WAIT_SECS="${4:-90}"; FRONTEND_DIR="$5"; PROXY_FLAG="${6:--}"

log() { echo "[dev] $*"; }
DEV_PID=""; WATCH_PID=""; APP_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
  [ -n "$DEV_PID" ] && kill "$DEV_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT INT TERM

tcp_probe() {
  # bash 内建 /dev/tcp 直连探测（无 curl/nc 依赖）
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null || return 1
  exec 3>&- 3<&- 2>/dev/null
  return 0
}

# ---- 1) spawn dev 命令 ----
if [ -n "$DEV_CMD" ] && [ "$DEV_CMD" != "-" ]; then
  log "frontend dev command: $DEV_CMD"
  (cd "$FRONTEND_DIR" && sh -c "$DEV_CMD") &
  DEV_PID=$!
  log "pid=$DEV_PID"
fi

# ---- 2) TCP 等待 dev_url ----
hostport()
{
  # http://127.0.0.1:5173 → 5173（探测只对 127.0.0.1：与 dev.zig 同语义）
  printf '%s' "$1" | sed -E 's#^[a-z]+://[^/]*:([0-9]+).*#\1#'
}
if [ -n "$DEV_URL" ] && [ "$DEV_URL" != "-" ]; then
  PORT="$(hostport "$DEV_URL")"
  if [ -z "$PORT" ]; then log "cannot parse dev url: $DEV_URL"; exit 2; fi
  MAX=$(( WAIT_SECS / 2 ))
  log "waiting for frontend dev server on $DEV_URL (port $PORT) ..."
  OK=0
  for _ in $(seq 1 "$MAX"); do
    if tcp_probe "$PORT"; then OK=1; break; fi
    sleep 2
  done
  if [ "$OK" != "1" ]; then log "dev server not reachable after ${WAIT_SECS}s"; exit 3; fi
  log "dev server ready"
fi

# ---- 3) 注入环境并拉起应用 ----
if [ -n "$DEV_URL" ] && [ "$DEV_URL" != "-" ]; then
  if [ "$PROXY_FLAG" = "1" ]; then
    export ZILT_DEV_PROXY="$DEV_URL"
    log "ZILT_DEV_PROXY=$DEV_URL（反代模式：应用保持自身 origin）"
  else
    export ZILT_DEV_URL="$DEV_URL"
    log "ZILT_DEV_URL=$DEV_URL"
  fi
fi
log "launching app: $EXE"
"$EXE" &
APP_PID=$!

# ---- 4) 热重启（ZILT_DEV_WATCH=1）----
WATCH="${ZILT_DEV_WATCH:-0}"
RESTARTS=0
if [ "$WATCH" = "1" ]; then
  log "hot-restart enabled (ZILT_DEV_WATCH=1): watching src/**.zig + build.zig*"
  zig build --watch &
  WATCH_PID=$!
  sleep 1
  while kill -0 "$WATCH_PID" 2>/dev/null && kill -0 "$APP_PID" 2>/dev/null; do
    BEFORE="$(find src build.zig -name '*.zig' -newer /tmp/.zilt-dev-marker 2>/dev/null | head -1)"
    if [ -z "$BEFORE" ]; then sleep 1; continue; fi
    touch /tmp/.zilt-dev-marker
    RESTARTS=$((RESTARTS + 1))
    log "source changed -> restarting app (restart #$RESTARTS)"
    kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
    # 等构建器写入新 exe（最长 120s）
    PRE="$(stat -c %Y "$EXE" 2>/dev/null || echo 0)"
    WAITED=0
    while [ "$WAITED" -lt 120 ]; do
      CUR="$(stat -c %Y "$EXE" 2>/dev/null || echo 0)"
      if [ "$CUR" -gt "$PRE" ]; then log "rebuild finished -> relaunching"; break; fi
      sleep 1; WAITED=$((WAITED + 1))
    done
    "$EXE" &
    APP_PID=$!
  done
fi

# 非 watch：等应用退出
if [ "$WATCH" != "1" ]; then
  wait "$APP_PID"
fi
log "app exited (restarts=$RESTARTS)"
