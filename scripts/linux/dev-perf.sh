#!/usr/bin/env bash
# 性能基线（v0.2.5）：Release 构建 → 冷启动（进程级）+ 冒烟全程耗时 + 峰值 RSS。
# 输出 .zilt-probe/perf.log（每版重跑对比）。
set -eu
cd "$(dirname "$0")/../.."
LOG=".zilt-probe/perf.log"

export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$HOME/.zcache/zilt-linux}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.zcache/zig-global}"
export ZILT_LINUX_SMOKE=1
export GDK_BACKEND=x11
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export LIBGL_ALWAYS_SOFTWARE=1

# http 冒烟需要回声服务器（同 dev-smoke.sh）
python3 scripts/http_echo.py 8788 > /dev/null 2>&1 &
echo_pid=$!
python3 scripts/ws_echo.py 8765 > /dev/null 2>&1 &
ws_pid=$!
trap 'kill $echo_pid $ws_pid 2>/dev/null' EXIT

{
  echo "== build (ReleaseSafe, cached after first run) =="
  /usr/bin/time -f "build_seconds=%e" zig build -Doptimize=ReleaseSafe 2>&1 | tail -1
  rm -f zilt.log

  echo "== cold start + smoke (3 runs) =="
  for i in 1 2 3; do
    set +e
    /usr/bin/time -f "run_${i}_seconds=%e max_rss_kb=%M" \
      timeout 180 xvfb-run -a --server-args="-screen 0 1280x800x24" ./zig-out/bin/zilt-app > /dev/null 2>> "$LOG"
    set -e
    grep -aq "ALL 57 CHECKS PASSED" zilt.log || echo "run_${i}: SMOKE NOT GREEN"
    rm -f zilt.log
  done
  echo "== baseline recorded $(date +%F) =="
} > "$LOG" 2>&1

grep -a "build_seconds\|run_.*_seconds\|NOT GREEN" "$LOG"
