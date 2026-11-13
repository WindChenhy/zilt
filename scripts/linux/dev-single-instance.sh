#!/usr/bin/env bash
# 单实例 + 深链转交 E2E（v0.2.2）：
#   1. 主实例冒烟后保持存活（ZILT_LINUX_SMOKE_STAY）
#   2. 第二实例带 zilt:// 参数启动（**同一 D-Bus 会话**）→ 转交后 exit 5
#   3. 主实例日志应出现 launch 分类 + 前端 deeplink-event
# 输出/结论落 .zilt-probe/single-instance.log，退出码 0 = 通过。
# 注意：两实例必须共享会话总线（GApplication 的唯一性走 D-Bus）——
# 用 dbus-run-session 包住两实例的启动脚本。
set -eu
cd "$(dirname "$0")/../.."
LOG=".zilt-probe/single-instance.log"

export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$HOME/.zcache/zilt-linux}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.zcache/zig-global}"
export ZILT_LINUX_SMOKE=1
export ZILT_LINUX_SMOKE_STAY=10
export GDK_BACKEND=x11
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export LIBGL_ALWAYS_SOFTWARE=1

{
  zig build
  rm -f zilt.log
} > "$LOG" 2>&1

set +e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
dbus-run-session -- bash "$SCRIPT_DIR/single-instance-inner.sh" >> "$LOG" 2>&1
set -e

second_code=$(cut -d= -f2 .zilt-probe/second.exit 2>/dev/null || echo missing)
primary_code=$(cut -d= -f2 .zilt-probe/primary.exit 2>/dev/null || echo missing)

# 判定：第二实例 exit 5；主实例收到转交 + 分类 + 前端事件回声；主实例冒烟全过
ok=1
[ "$second_code" = "5" ] || ok=0
grep -aq "\[single-instance\] args forwarded to primary -> exit 5" zilt.log || ok=0
grep -aq "\[deep-link\] launch (url=zilt://second-instance" zilt.log || ok=0
grep -aq "deeplink-event.*second-instance" zilt.log || ok=0
grep -aq "ALL 48 CHECKS PASSED" zilt.log || ok=0

{
  echo "SECOND_EXIT=$second_code"
  echo "PRIMARY_EXIT=$primary_code"
  if [ "$ok" = "1" ]; then echo "SINGLE_INSTANCE_E2E=PASS"; else echo "SINGLE_INSTANCE_E2E=FAIL"; fi
} >> "$LOG"
grep -a "SECOND_EXIT\|PRIMARY_EXIT\|SINGLE_INSTANCE_E2E" "$LOG"
exit "$ok"
