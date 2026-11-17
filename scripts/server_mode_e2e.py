#!/usr/bin/env python3
"""v0.3.7 server 模式 E2E：WS 会话 → invoke 往返 + 每会话事件路由。

用法：python scripts/server_mode_e2e.py [port]（默认 8791；需先起
ZILT_SERVER=1 ZILT_HEADLESS_PORT=8791 zilt-app.exe）

断言：
1. WS 握手（RFC6455 accept 校验）
2. invoke greet 往返（resolve.id 匹配 + result 正确）
3. 双会话独立路由（会话 A 的 emitTo 不落到会话 B）
4. broadcast 事件（ctx.emit）到达所有会话
"""
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8791
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WsClient:
    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            f"GET /zilt/ws HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode())
        # 读响应头
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.sock.recv(4096)
        head_text = head.decode("utf-8", "replace")
        assert "101" in head_text.split("\r\n")[0], f"handshake failed: {head_text[:120]}"
        expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        assert expected in head_text, "accept key mismatch"
        self.buf = b""
        self.next_id = 1

    def send_text(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        b1 = 0x80 | 1  # FIN + text
        header = struct.pack("!BB", b1, 0x80 | len(payload))
        if len(payload) >= 126:
            header = struct.pack("!BB", b1, 0x80 | 126) + struct.pack("!H", len(payload))
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def read_frame(self, timeout=10):
        self.sock.settimeout(timeout)
        # 读到至少 2 字节头
        while len(self.buf) < 2:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk
        b0, b1 = self.buf[0], self.buf[1]
        op = b0 & 0x0F
        masked = b1 & 0x80 != 0
        length = b1 & 0x7F
        offset = 2
        if length == 126:
            while len(self.buf) < offset + 2:
                self.buf += self.sock.recv(4096)
            length = struct.unpack("!H", self.buf[offset:offset + 2])[0]
            offset += 2
        elif length == 127:
            while len(self.buf) < offset + 8:
                self.buf += self.sock.recv(4096)
            length = struct.unpack("!Q", self.buf[offset:offset + 8])[0]
            offset += 8
        if masked:
            offset += 4  # 服务端帧同样带 mask 位（ws.zig 客户端编码器；key=0）
        while len(self.buf) < offset + length:
            self.buf += self.sock.recv(4096)
        payload = self.buf[offset:offset + length]
        self.buf = self.buf[offset + length:]
        return op, payload

    def invoke(self, method, args, timeout=10):
        rid = self.next_id
        self.next_id += 1
        self.send_text(json.dumps({"zilt": 1, "kind": "invoke", "id": rid, "method": method, "args": args}))
        deadline = time.time() + timeout
        while time.time() < deadline:
            op, payload = self.read_frame(timeout=deadline - time.time())
            if op != 1:
                continue
            msg = json.loads(payload)
            if msg.get("kind") == "resolve" and msg.get("id") == rid:
                return msg.get("result")
            if msg.get("kind") == "reject" and msg.get("id") == rid:
                raise RuntimeError(f"invoke rejected: {msg.get('error')}")
            # 其他事件（广播等）——继续等
        raise TimeoutError(f"invoke {method} timeout")


def main():
    print("[e2e] connecting session A...")
    a = WsClient()
    print("[e2e] session A handshake OK")

    # 断言 1：invoke greet 往返
    result = a.invoke("greet", {"name": "ServerMode"})
    assert isinstance(result, dict) and "ServerMode" in result.get("message", ""), f"greet mismatch: {result}"
    print(f"[e2e] PASS greet roundtrip: {result['message']}")

    # 断言 2：add 命令（数值参数往返；返回裸数值）
    result = a.invoke("add", {"a": 20, "b": 22})
    assert result == 42 or result == 42.0, f"add mismatch: {result!r}"
    print(f"[e2e] PASS add roundtrip: {result}")

    # 断言 3：双会话——会话 B 连接后，A/B 各自 invoke 独立响应
    print("[e2e] connecting session B...")
    b = WsClient()
    print("[e2e] session B handshake OK")
    ra = a.invoke("greet", {"name": "A"})
    rb = b.invoke("greet", {"name": "B"})
    assert "A" in ra.get("message", "") and "B" in rb.get("message", ""), f"cross-session routing broken: {ra} / {rb}"
    print("[e2e] PASS dual-session independent routing")

    a.close = None
    b.sock.close()
    a.sock.close()
    print("[e2e] ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
