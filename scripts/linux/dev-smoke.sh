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

  # 透传额外环境变量（--extra-env K=V 形式，可重复）；--gtk4 = GTK4 变体
  #（v0.4.3 L1：双栈冒烟——24.04+ WebKitGTK 6.0 环境）
  GTK_FLAG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --extra-env) export "$2"; shift 2 ;;
      --gtk4) GTK_FLAG="-Dgtk=gtk4"; shift ;;
      *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  zig build $GTK_FLAG

  rm -f zilt.log
  export ZILT_LINUX_SMOKE=1
  export GDK_BACKEND=x11
  export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
  export LIBGL_ALWAYS_SOFTWARE=1

  # v0.2.3：http/ws 冒烟需要回声服务器（scripts/http_echo.py 8788 +
  # ws_echo.py 8765；冒烟对 8788/echo 做 POST 断言，拒绝路径不依赖服务器）
  python3 scripts/http_echo.py 8788 > /tmp/zilt-http-echo.log 2>&1 &
  echo_pid=$!
  python3 scripts/ws_echo.py 8765 > /tmp/zilt-ws-echo.log 2>&1 &
  ws_pid=$!
  trap 'kill $echo_pid $ws_pid 2>/dev/null || true' EXIT

  set +e
  # v0.3.0：有 openbox 时在同一 Xvfb 会话里起 WM（windowMoved/Resized/Focus 才
  # 会真实触发；没有 WM 时 smoke.js 自动 skip 该检查）；CI 会安装 openbox。
  timeout 240 xvfb-run -a --server-args="-screen 0 1280x800x24" bash -c '
    if command -v openbox >/dev/null 2>&1; then
      openbox >/tmp/zilt-openbox.log 2>&1 &
      sleep 0.5
    fi
    exec ./zig-out/bin/zilt-app
  ' 2>&1 | tail -120
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
