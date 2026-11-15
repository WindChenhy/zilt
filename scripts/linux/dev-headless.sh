#!/usr/bin/env bash
# headless/server 模式 E2E（v0.2.8）：ZILT_HEADLESS=1 → 四端点全通。
#   GET /zilt/health → ok
#   POST /zilt/ipc   → 与前端 invoke 同链路（greet 返回真实结果）
#   GET /mcp         → MCP serverInfo + 工具数
#   POST /mcp        → tools/call（add 2+40=42）
#   GET /index.html  → 资产服务 200
# 退出码落 .zilt-probe/headless-last.exit（0 = 全通）。
set -u
cd "$(dirname "$0")/../.."
mkdir -p .zilt-probe
LOG=".zilt-probe/headless-last.log"
PORT="${ZILT_HEADLESS_PORT_OVERRIDE:-8793}"

{
  ZILT_HEADLESS=1 ZILT_HEADLESS_PORT="$PORT" ./zig-out/bin/zilt-app > /dev/null 2>&1 &
  APP=$!
  # 等服务就绪（最多 5s）
  OK=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -m 1 "http://127.0.0.1:$PORT/zilt/health" 2>/dev/null | grep -q '^ok$'; then OK=1; break; fi
    sleep 0.5
  done
  echo "HEALTH=$OK"

  IPC=$(curl -s -m 2 -X POST "http://127.0.0.1:$PORT/zilt/ipc" -d '{"method":"greet","args":{"name":"Headless"}}')
  echo "IPC_GREET=$IPC"

  MCP_INFO=$(curl -s -m 2 "http://127.0.0.1:$PORT/mcp")
  echo "MCP_INFO=$MCP_INFO"

  MCP_CALL=$(curl -s -m 2 -X POST "http://127.0.0.1:$PORT/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add","arguments":{"a":2,"b":40}}}')
  echo "MCP_CALL=$MCP_CALL"

  ASSET=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/index.html")
  echo "ASSET_CODE=$ASSET"

  kill $APP 2>/dev/null
  wait $APP 2>/dev/null

  PASS=1
  [ "$OK" = "1" ] || PASS=0
  echo "$IPC" | grep -q 'Hello, Headless!' || PASS=0
  echo "$MCP_INFO" | grep -q '"tools":[0-9]' || PASS=0
  echo "$MCP_CALL" | grep -q '"text":"42"' || PASS=0
  [ "$ASSET" = "200" ] || PASS=0
  if [ "$PASS" = "1" ]; then echo "HEADLESS_E2E=PASS"; else echo "HEADLESS_E2E=FAIL"; fi
} > "$LOG" 2>&1

grep -a 'HEALTH=\|HEADLESS_E2E' "$LOG"
code=$(grep -aq 'HEADLESS_E2E=PASS' "$LOG" && echo 0 || echo 1)
echo "$code" > .zilt-probe/headless-last.exit
exit "$code"
