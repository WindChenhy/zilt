#!/usr/bin/env bash
# v0.3.1：Linux 差分更新 E2E。
#   keygen → 构造 new-exe（old + 标记字节）→ zilt-diff 生成补丁 → zilt-sign 签名 →
#   本地 HTTP 分发 manifest → 应用自动检查并走 patch 路径暂存 →
#   校验 exe 已替换为 new、.zilt-old 是 old → 二次启动等 10s 健康确认清理备份。
# 退出码落 .zilt-probe/update-e2e.exit（0 = 全通）。
set -eu
cd "$(dirname "$0")/../.."
mkdir -p .zilt-probe
WORK=/tmp/zilt-update-e2e
LOG=.zilt-probe/update-e2e.log
APP=zig-out/bin/zilt-app
PORT=8789

rm -rf "$WORK"
mkdir -p "$WORK"

{
  test -x "$APP" || { echo "app missing: $APP"; echo "UPDATE_E2E=FAIL"; exit 1; }
  # 在 /tmp 里跑副本：staging 的 61MB 读写不受 /mnt/d 慢盘影响，也不污染 zig-out
  cp "$APP" "$WORK/app"
  chmod +x "$WORK/app"
  RUN="$WORK/app"
  cp "$RUN" "$WORK/old-exe"
  cp "$RUN" "$WORK/new-exe"
  printf '\nzilt-update-e2e-marker-v0.3.1\n' >> "$WORK/new-exe"

  eval "$(./zig-out/bin/zilt-keygen 2>&1)"
  echo "PUBLIC_KEY=$PUBLIC_KEY_HEX"

  ZILT_DIFF_OLD="$WORK/old-exe" ZILT_DIFF_NEW="$WORK/new-exe" ZILT_DIFF_OUT="$WORK/update.patch" \
    ./zig-out/bin/zilt-diff >/dev/null
  PATCH_SIZE=$(stat -c %s "$WORK/update.patch")
  echo "PATCH_SIZE=$PATCH_SIZE"

  sign_file() { ZILT_SIGN_FILE="$1" ZILT_SIGN_KEY="$SECRET_KEY_HEX" ./zig-out/bin/zilt-sign; }
  NEW_SIG=$(sign_file "$WORK/new-exe" 2>&1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["signature"])')
  PATCH_SIG=$(sign_file "$WORK/update.patch" 2>&1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["signature"])')
  OLD_SHA=$(sha256sum "$WORK/old-exe" | cut -d' ' -f1)
  NEW_SHA=$(sha256sum "$WORK/new-exe" | cut -d' ' -f1)
  PATCH_SHA=$(sha256sum "$WORK/update.patch" | cut -d' ' -f1)

  cat > "$WORK/manifest.json" <<EOF
{
  "version": "9.9.9",
  "notes": "v0.3.1 differential update e2e",
  "pub_date": "2026-11-15T00:00:00Z",
  "url": "http://127.0.0.1:$PORT/full.zip",
  "sha256": "$NEW_SHA",
  "signature": "$NEW_SIG",
  "patch": {
    "from": "0.1.1",
    "from_sha256": "$OLD_SHA",
    "url": "http://127.0.0.1:$PORT/update.patch",
    "sha256": "$PATCH_SHA",
    "signature": "$PATCH_SIG"
  }
}
EOF

  python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK" >/dev/null 2>&1 &
  HTTP_PID=$!
  Xvfb :97 -screen 0 1280x800x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  APP_PID=""
  APP2=""
  cleanup() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
    [ -n "$APP2" ] && kill "$APP2" 2>/dev/null || true
    kill "$HTTP_PID" "$XVFB_PID" 2>/dev/null || true
    rm -rf "$WORK"
  }
  trap cleanup EXIT
  export DISPLAY=:97
  sleep 1

  rm -f "$RUN.zilt-old" "$RUN.zilt-new" zilt.log
  ZILT_UPDATE_URL="http://127.0.0.1:$PORT/manifest.json" \
  ZILT_UPDATE_PK="$PUBLIC_KEY_HEX" ZILT_UPDATE_AUTO=1 \
  GDK_BACKEND=x11 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 LIBGL_ALWAYS_SOFTWARE=1 \
    "$RUN" >/tmp/zilt-update-app.log 2>&1 &
  APP_PID=$!

  # 等自动检查 + patch 下载/应用/暂存（轮询日志；Debug 构建的 61MB 哈希较慢，上限 30s）
  STAGED=0
  for _ in $(seq 1 150); do
    if grep -aq 'patched & staged ok' zilt.log 2>/dev/null; then STAGED=1; break; fi
    if grep -aq 'patch path failed\|patch stage failed\|updaterFailed' zilt.log 2>/dev/null; then break; fi
    sleep 0.2
  done
  sleep 0.3
  echo "PATCH_STAGED=$STAGED"

  BACKUP=0
  [ -f "$RUN.zilt-old" ] && BACKUP=1
  echo "OLD_BACKUP=$BACKUP"

  CUR_SHA=$(sha256sum "$RUN" | cut -d' ' -f1)
  EXE_UPDATED=0
  [ "$CUR_SHA" = "$NEW_SHA" ] && EXE_UPDATED=1
  echo "EXE_UPDATED=$EXE_UPDATED"

  BAK_SHA=$(sha256sum "$RUN.zilt-old" 2>/dev/null | cut -d' ' -f1 || true)
  BACKUP_OK=0
  [ "$BAK_SHA" = "$OLD_SHA" ] && BACKUP_OK=1
  echo "BACKUP_MATCH=$BACKUP_OK"

  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""

  # 健康确认：不带 auto 再启动新 exe，10s 定时器后 .zilt-old 应被清理。
  # v0.6.1：CI（24.04 + GTK4）启动更慢/单实例时序更紧——改为轮询最多 25s。
  # 注意：24.04 runner 的 bwrap 存在但非特权 userns 受限——WebKit 若尝试沙箱会
  # 直接 abort（Connection: failed to receive credentials），与首启同样禁用沙箱。
  GDK_BACKEND=x11 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 LIBGL_ALWAYS_SOFTWARE=1 \
    "$RUN" >/tmp/zilt-update-app2.log 2>&1 &
  APP2=$!
  HEALTH=0
  for _ in $(seq 1 50); do
    if [ ! -f "$RUN.zilt-old" ]; then HEALTH=1; break; fi
    sleep 0.5
  done
  echo "HEALTH_CLEANUP=$HEALTH"
  if [ "$HEALTH" != "1" ]; then
    echo "== app2 log tail =="
    tail -40 /tmp/zilt-update-app2.log 2>/dev/null || true
    echo "== zilt.log tail =="
    tail -40 zilt.log 2>/dev/null || true
  fi
  kill "$APP2" 2>/dev/null || true
  wait "$APP2" 2>/dev/null || true
  APP2=""
  grep -a 'health confirmed' zilt.log | tail -1 || true

  PASS=1
  [ "$STAGED" = "1" ] || PASS=0
  [ "$BACKUP" = "1" ] || PASS=0
  [ "$EXE_UPDATED" = "1" ] || PASS=0
  [ "$BACKUP_OK" = "1" ] || PASS=0
  [ "$HEALTH" = "1" ] || PASS=0
  # 差分体积：追加 30 字节的补丁应远小于全量（< 1MB）
  [ "$PATCH_SIZE" -lt 1048576 ] || PASS=0
  if [ "$PASS" = "1" ]; then echo "UPDATE_E2E=PASS"; else echo "UPDATE_E2E=FAIL"; fi
} > "$LOG" 2>&1

grep -a 'PATCH_STAGED=\|EXE_UPDATED=\|BACKUP_MATCH=\|HEALTH_CLEANUP=\|UPDATE_E2E=' "$LOG"
code=$(grep -aq 'UPDATE_E2E=PASS' "$LOG" && echo 0 || echo 1)
echo "$code" > .zilt-probe/update-e2e.exit
exit "$code"
