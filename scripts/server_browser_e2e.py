#!/usr/bin/env python3
"""v0.3.13 F1b 浏览器端 runtime shim E2E：Edge headless + CDP Runtime.evaluate。

前置：ZILT_HEADLESS=1 ZILT_SERVER=1 的 zilt-app（端口 argv[1]，默认 8792）。
断言：
1. / 响应 HTML 含 runtime 注入（__ZILT_SERVER__ + /zilt/runtime.js）
2. /zilt/runtime.js 200 且含 srvMode WS shim
3. Edge headless 加载页面 → CDP Runtime.evaluate 经 **浏览器端 shim** invoke
   greet/add → resolve 结果正确（真实浏览器 WS 往返）
"""
import base64
import hashlib
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8792
BASE = f"http://127.0.0.1:{PORT}"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
EDGE = None
for p in (
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
):
    if os.path.exists(p):
        EDGE = p
        break


def http_get(path, timeout=5):
    return urllib.request.urlopen(BASE + path, timeout=timeout)


def check_injection():
    html = http_get("/").read().decode()
    assert "__ZILT_SERVER__" in html and "/zilt/runtime.js" in html, "runtime injection missing"
    print("[browser-e2e] PASS: HTML runtime injection")


def check_runtime_js():
    rt = http_get("/zilt/runtime.js").read().decode()
    assert "srvMode" in rt and "/zilt/ws" in rt, "runtime shim missing"
    print("[browser-e2e] PASS: /zilt/runtime.js shim served")


class RawWs:
    """最小 WS 客户端（掩码客户端帧；服务端帧不带掩码——ws.zig 语义）"""

    def __init__(self, url):
        m = re.match(r"ws://([^:/]+):(\d+)(/.*)", url)
        host, port, path = m.group(1), int(m.group(2)), m.group(3)
        self.sock = socket.create_connection((host, port), timeout=15)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            (
                f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.sock.recv(4096)
        assert b"101" in head.split(b"\r\n")[0], "ws handshake failed"
        expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        assert expected.encode() in head, "accept mismatch"
        self.buf = head[head.index(b"\r\n\r\n") + 4 :]
        self.next_id = 1

    def send_text(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        b1 = 0x80 | 1
        header = struct.pack("!BB", b1, 0x80 | len(payload))
        if len(payload) >= 126:
            header = struct.pack("!BB", b1, 0x80 | 126) + struct.pack("!H", len(payload))
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def read_frame(self, timeout=15):
        self.sock.settimeout(timeout)
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
            length = struct.unpack("!H", self.buf[offset : offset + 2])[0]
            offset += 2
        elif length == 127:
            while len(self.buf) < offset + 8:
                self.buf += self.sock.recv(4096)
            length = struct.unpack("!Q", self.buf[offset : offset + 8])[0]
            offset += 8
        if masked:
            while len(self.buf) < offset + 4:
                self.buf += self.sock.recv(4096)
            offset += 4
        while len(self.buf) < offset + length:
            self.buf += self.sock.recv(4096)
        payload = self.buf[offset : offset + length]
        self.buf = self.buf[offset + length :]
        return op, payload

    def invoke(self, method, args, timeout=15):
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
                raise RuntimeError("invoke rejected: " + str(msg.get("error")))
        raise TimeoutError(f"invoke {method} timeout")


class CdpClient(RawWs):
    """CDP：page target 的 Runtime.evaluate"""

    def __init__(self, url):
        super().__init__(url)
        self.msg_id = 0

    def evaluate(self, expression, await_promise=True, timeout=15):
        self.msg_id += 1
        mid = self.msg_id
        self.send_text(
            json.dumps(
                {
                    "id": mid,
                    "method": "Runtime.evaluate",
                    "params": {
                        "expression": expression,
                        "awaitPromise": await_promise,
                        "returnByValue": True,
                    },
                }
            )
        )
        deadline = time.time() + timeout
        while time.time() < deadline:
            op, payload = self.read_frame(timeout=deadline - time.time())
            print("[cdp-debug] frame op=", op, "len=", len(payload), payload[:120])
            if op == 8:
                raise ConnectionError("cdp closed by peer")
            if op != 1:
                continue
            msg = json.loads(payload)
            if msg.get("id") == mid:
                return msg
        raise TimeoutError("cdp evaluate timeout")


def check_browser_invoke():
    assert EDGE, "Edge not found"
    profile = os.path.join(os.environ.get("TEMP", "."), "zilt-edge-e2e")
    proc = subprocess.Popen(
        [
            EDGE,
            "--headless=new",
            "--disable-gpu",
            "--remote-debugging-port=9333",
            f"--user-data-dir={profile}",
            BASE + "/",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        # 等调试端口
        targets = None
        for _ in range(40):
            time.sleep(0.5)
            try:
                data = json.loads(urllib.request.urlopen("http://127.0.0.1:9333/json/list", timeout=2).read())
                pages = [t for t in data if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
                if pages:
                    targets = pages
                    break
            except Exception:
                continue
        assert targets, "CDP targets not found"
        ws_url = targets[0]["webSocketDebuggerUrl"]
        cdp = CdpClient(ws_url)

        # CDP 连通性先验证（Runtime 域不涉及业务）
        r0 = cdp.evaluate("1 + 1", await_promise=False)
        v0 = r0.get("result", {}).get("result", {}).get("value")
        assert v0 == 2, "CDP evaluate broken: " + json.dumps(r0)[:200]
        print("[browser-e2e] PASS: CDP evaluate basic")
        # 页面就绪（runtime.js 已注入 → window.zilt 存在）
        rz = cdp.evaluate("typeof window.zilt", await_promise=False)
        vz = rz.get("result", {}).get("result", {}).get("value", "?")
        print("[browser-e2e] window.zilt type:", vz)
        # shim 状态诊断：__ZILT_SERVER__/ws readyState/最近错误
        rd = cdp.evaluate(
            "JSON.stringify({srv: window.__ZILT_SERVER__, ready: window.zilt ? (window.__ziltWsReady ?? 'n/a') : '?', loc: location.href})",
            await_promise=False,
        )
        print("[browser-e2e] shim state:", rd.get("result", {}).get("result", {}).get("value", "?"))
        # 直接诊断 invoke 的同步返回（Promise 状态）
        rp = cdp.evaluate(
            "(function(){ const p = window.zilt.invoke('greet', {name:'X'}); return {then: typeof p.then}; })()",
            await_promise=False,
        )
        print("[browser-e2e] invoke returns promise:", rp.get("result", {}).get("result", {}).get("value", "?"))
        # 浏览器端 shim invoke：window.zilt.invoke → WS → dispatch → resolve
        r1 = cdp.evaluate("window.zilt.invoke('greet', {name: 'BrowserE2E'}).then(r => r.message)")
        val = r1.get("result", {}).get("result", {}).get("value", "")
        assert "BrowserE2E" in val, "greet via shim failed: " + val
        print("[browser-e2e] PASS: greet via browser shim:", val)

        r2 = cdp.evaluate("window.zilt.invoke('add', {a: 20, b: 22}).then(r => String(r))")
        val2 = r2.get("result", {}).get("result", {}).get("value", "")
        assert "42" in val2, "add via shim failed: " + val2
        print("[browser-e2e] PASS: add via browser shim:", val2)
    finally:
        proc.terminate()


def main():
    check_injection()
    check_runtime_js()
    check_browser_invoke()
    print("[browser-e2e] ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
