#!/usr/bin/env bash
# 开发辅助：构建 + Xvfb 冒烟（ZILT_LINUX_SMOKE=1），输出逐项检查日志与退出码。
# 用法：wsl -d Ubuntu-22.04 -- bash /mnt/d/Projects/ZigProjects/Zilt/scripts/linux/dev-smoke.sh [--extra-env VAR=1 ...]
#
# 输出与退出码落在仓库内 <root>/.zilt-probe/smoke-last.log（WSL 的 /tmp 随实例
# 重启清空；wsl.exe 对 Git Bash 的退出码转发也不可靠，因此以文件为准）。
set -eu
cd "$(dirname "$0")/../.."
LOG=".zilt-probe/smoke-last.log"
mkdir -p .zilt-probe

{
  export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$HOME/.zcache/zilt-linux}"
  export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.zcache/zig-global}"
  mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

  # 透传额外环境变量（--extra-env K=V 形式，可重复）
  while [ $# -gt 0 ]; do
    case "$1" in
      --extra-env) export "$2"; shift 2 ;;
      *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  zig build

  rm -f zilt.log
  export ZILT_LINUX_SMOKE=1
  export GDK_BACKEND=x11
  export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
  export LIBGL_ALWAYS_SOFTWARE=1

  set +e
  timeout 240 xvfb-run -a --server-args="-screen 0 1280x800x24" ./zig-out/bin/zilt-app 2>&1 | tail -120
  code=${PIPESTATUS[0]}
  set -e
  echo "SMOKE_EXIT=$code"
  echo "--- frontend/smoke lines ---"
  grep -a -E '\[linux-smoke\]|\[frontend\]' zilt.log | tail -100 || true
  echo "===DONE==="
} > "$LOG" 2>&1
# 同步退出码到文件尾（供宿主侧读取）
code=$(grep -a '^SMOKE_EXIT=' "$LOG" | tail -1 | cut -d= -f2)
echo "$code" > .zilt-probe/smoke-last.exit
exit "$code"
