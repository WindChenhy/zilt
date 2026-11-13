#!/usr/bin/env bash
# 单实例 E2E 内层脚本（在 dbus-run-session 里执行，两实例共享会话总线）。
# 由 dev-single-instance.sh 调起；假设 cwd 已是项目根。
set -u
export GDK_BACKEND=x11
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export LIBGL_ALWAYS_SOFTWARE=1

xvfb-run -a --server-args="-screen 0 1280x800x24" ./zig-out/bin/zilt-app &
primary_pid=$!

# 等主实例冒烟完成进入 stay 窗口（最多 30s）
for i in $(seq 1 60); do
  grep -aq "staying alive" zilt.log 2>/dev/null && break
  sleep 0.5
done

# 第二实例：带深链参数 → GApplication 转交 → exit 5
xvfb-run -a ./zig-out/bin/zilt-app zilt://second-instance?x=1
echo "SECOND_EXIT=$?" > .zilt-probe/second.exit

wait $primary_pid
echo "PRIMARY_EXIT=$?" > .zilt-probe/primary.exit
