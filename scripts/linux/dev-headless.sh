#!/usr/bin/env bash
# headless/server 模式 E2E（v0.2.8；v0.3.1 扩 MCP）。
#   GET /zilt/health → ok
#   POST /zilt/ipc   → 与前端 invoke 同链路（greet 返回真实结果）
#   GET /mcp         → MCP serverInfo + 工具数
#   POST /mcp        → tools/call（add 2+40=42）、resources/list、resources/read、
#                      prompts/list、通知 202、工具白名单拒绝
#   MCP stdio        → ZILT_MCP_STDIO=1 直连（通知不回包，stdout 只有响应）
#   `zilt mcp` CLI   → 同一条 stdio 链路
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

  MCP_RES=$(curl -s -m 2 -X POST "http://127.0.0.1:$PORT/mcp" \
    -d '{"jsonrpc":"2.0","id":2,"method":"resources/list"}')
  echo "MCP_RES=$MCP_RES"

  MCP_READ=$(curl -s -m 2 -X POST "http://127.0.0.1:$PORT/mcp" \
    -d '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"zilt://app/info"}}')
  echo "MCP_READ=$MCP_READ"

  MCP_PROMPTS=$(curl -s -m 2 -X POST "http://127.0.0.1:$PORT/mcp" \
    -d '{"jsonrpc":"2.0","id":4,"method":"prompts/list"}')
  echo "MCP_PROMPTS=$MCP_PROMPTS"

  MCP_NOTIFY_CODE=$(curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/mcp" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}')
  echo "MCP_NOTIFY_CODE=$MCP_NOTIFY_CODE"

  ASSET=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/index.html")
  echo "ASSET_CODE=$ASSET"

  kill $APP 2>/dev/null
  wait $APP 2>/dev/null

  # ---- v0.3.1：MCP stdio 直连（通知不回包）----
  STDIO_OUT=$(
    printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
      '{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"zilt://app/info"}}' \
      '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"greet","arguments":{"name":"Stdio"}}}' \
      | ZILT_HEADLESS=1 ZILT_MCP_STDIO=1 ./zig-out/bin/zilt-app 2>/dev/null
  )
  STDIO_LINES=$(printf '%s\n' "$STDIO_OUT" | wc -l)
  echo "MCP_STDIO_LINES=$STDIO_LINES"
  echo "MCP_STDIO=$STDIO_OUT"

  # ---- v0.3.1：`zilt mcp` CLI ----
  CLI_OUT=$(
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add","arguments":{"a":20,"b":22}}}' \
      | ./zig-out/bin/zilt mcp ./zig-out/bin/zilt-app 2>/dev/null
  )
  echo "MCP_CLI=$CLI_OUT"

  # ---- v0.3.1：工具白名单（ZILT_MCP_TOOLS=greet）----
  ACL_OUT=$(
    printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
      '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":1,"b":2}}}' \
      | ZILT_HEADLESS=1 ZILT_MCP_STDIO=1 ZILT_MCP_TOOLS=greet ./zig-out/bin/zilt-app 2>/dev/null
  )
  echo "MCP_ACL=$ACL_OUT"

  PASS=1
  [ "$OK" = "1" ] || PASS=0
  echo "$IPC" | grep -q 'Hello, Headless!' || PASS=0
  echo "$MCP_INFO" | grep -q '"tools":[0-9]' || PASS=0
  echo "$MCP_INFO" | grep -q '"resources":3' || PASS=0
  echo "$MCP_CALL" | grep -q '"text":"42"' || PASS=0
  echo "$MCP_RES" | grep -q 'zilt://app/info' || PASS=0
  echo "$MCP_READ" | grep -q 'app.zilt' || PASS=0
  echo "$MCP_PROMPTS" | grep -q 'app_overview' || PASS=0
  [ "$MCP_NOTIFY_CODE" = "202" ] || PASS=0
  [ "$ASSET" = "200" ] || PASS=0
  [ "$STDIO_LINES" = "3" ] || PASS=0
  echo "$STDIO_OUT" | grep -q '"resources":{}' || PASS=0
  echo "$STDIO_OUT" | grep -q 'Hello, Stdio!' || PASS=0
  echo "$CLI_OUT" | grep -q '"text":"42"' || PASS=0
  echo "$ACL_OUT" | grep -q '"name":"greet"' || PASS=0
  echo "$ACL_OUT" | grep -q 'ToolNotAllowed: add' || PASS=0
  if [ "$PASS" = "1" ]; then echo "HEADLESS_E2E=PASS"; else echo "HEADLESS_E2E=FAIL"; fi
} > "$LOG" 2>&1

grep -a 'HEALTH=\|MCP_STDIO_LINES=\|HEADLESS_E2E' "$LOG"
code=$(grep -aq 'HEADLESS_E2E=PASS' "$LOG" && echo 0 || echo 1)
echo "$code" > .zilt-probe/headless-last.exit
exit "$code"
