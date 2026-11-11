#!/usr/bin/env python3
"""HTTP echo / 流式 / multipart 测试服务端（v0.1.20 E2E 用，仅标准库）。

端点：
  GET  /hello                  → 文本 "hello"
  GET  /stream?chunks=5&size=8 → chunked 分块推送（可验证流式与 httpChunk 顺序）
  GET  /redirect               → 302 → /hello（验证 follow_redirects）
  GET  /slow?ms=300            → 延迟响应（验证 timeout 生效）
  POST /echo                   → 回显 {len,sha256,ctype,preview}
  POST /multipart              → 解析 multipart/form-data，返回各字段名/长度/文件名

用法：python scripts/http_echo.py [port]
"""
import hashlib
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("[http] " + (fmt % args), flush=True)

    def _send(self, code, body: bytes, ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/hello":
            self._send(200, b"hello")
            return
        if u.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/hello")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if u.path == "/slow":
            ms = int(q.get("ms", ["300"])[0])
            time.sleep(ms / 1000.0)
            self._send(200, b"slow-ok")
            return
        if u.path == "/stream":
            chunks = int(q.get("chunks", ["5"])[0])
            size = int(q.get("size", ["8"])[0])
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(chunks):
                payload = (f"{i:02d}".encode() + b"x" * max(0, size - 2))
                self.wfile.write(b"%x\r\n" % len(payload) + payload + b"\r\n")
                self.wfile.flush()
                time.sleep(0.05)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        self._send(404, b"not found")

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n) if n else b""
        ctype = self.headers.get("Content-Type", "")
        if u.path == "/echo":
            self._json(200, {
                "len": len(body),
                "sha256": hashlib.sha256(body).hexdigest(),
                "ctype": ctype,
                "preview": body[:32].decode("latin1"),
            })
            return
        if u.path == "/multipart":
            parts = []
            boundary = ""
            for seg in ctype.split(";"):
                seg = seg.strip()
                if seg.startswith("boundary="):
                    boundary = seg[len("boundary="):].strip('"')
            if boundary:
                delim = b"--" + boundary.encode()
                for raw in body.split(delim):
                    raw = raw.strip(b"\r\n")
                    if not raw or raw == b"--":
                        continue
                    head, _, data = raw.partition(b"\r\n\r\n")
                    name = ""
                    filename = None
                    for line in head.decode("latin1").split("\r\n"):
                        if "name=" in line:
                            name = line.split("name=", 1)[1].split(";")[0].strip('"')
                        if "filename=" in line:
                            filename = line.split("filename=", 1)[1].split(";")[0].strip('"')
                    parts.append({
                        "name": name,
                        "filename": filename,
                        "len": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "text": data[:24].decode("utf-8", "replace"),
                    })
            self._json(200, {"boundary": boundary, "parts": parts})
            return
        self._send(404, b"not found")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8788
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"http echo listening on 127.0.0.1:{port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
