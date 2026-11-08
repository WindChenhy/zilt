#!/usr/bin/env python3
"""最小 WebSocket echo 服务端 —— 仅用于对照测试 Zilt 的 ws 客户端实现。

不依赖任何第三方库（本机没有 websockets / ws）。实现 RFC 6455 的必需子集：
  - Upgrade 握手（Sec-WebSocket-Key → Accept: base64(sha1(key + GUID))）
  - 帧解码（客户端帧必带掩码、支持 7/16/64 位长度）
  - text 回显、ping→pong、close 回声
  - 握手后主动推一条 welcome，用于验证「服务端主动推」路径

不支持：分片帧（fin=0 的续帧）、二进制帧、扩展协商。测试够用。

用法：python scripts/ws_echo.py [port]
"""

import base64
import hashlib
import socket
import struct
import sys
import threading

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def handshake(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return None
        data += chunk
        if len(data) > 65536:
            return None

    key = None
    for line in data.decode("latin1").split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()
    if not key:
        return None

    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    resp = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
        "\r\n"
    )
    conn.sendall(resp.encode())
    return key


def recv_frame(conn):
    hdr = recv_exact(conn, 2)
    if hdr is None:
        return None
    b1, b2 = hdr[0], hdr[1]
    fin = bool(b1 & 0x80)
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    ln = b2 & 0x7F

    if ln == 126:
        ext = recv_exact(conn, 2)
        if ext is None:
            return None
        ln = struct.unpack(">H", ext)[0]
    elif ln == 127:
        ext = recv_exact(conn, 8)
        if ext is None:
            return None
        ln = struct.unpack(">Q", ext)[0]

    mask = recv_exact(conn, 4) if masked else None
    payload = recv_exact(conn, ln) if ln else b""
    if payload is None:
        return None
    if mask:
        payload = bytes(payload[i] ^ mask[i % 4] for i in range(len(payload)))
    return fin, opcode, payload


def send_frame(conn, opcode, payload):
    b1 = 0x80 | opcode  # FIN=1，服务端帧不加掩码
    ln = len(payload)
    if ln < 126:
        hdr = struct.pack(">BB", b1, ln)
    elif ln < 65536:
        hdr = struct.pack(">BBH", b1, 126, ln)
    else:
        hdr = struct.pack(">BBQ", b1, 127, ln)
    conn.sendall(hdr + payload)


def handle(conn, addr):
    try:
        if handshake(conn) is None:
            return
        print(f"[ws] connected {addr}", flush=True)
        send_frame(conn, 0x1, b'{"type":"welcome","from":"python-echo"}')

        while True:
            frame = recv_frame(conn)
            if frame is None:
                break
            fin, opcode, payload = frame
            if not fin:
                # 分片帧未实现：直接关闭，避免静默错乱
                send_frame(conn, 0x8, struct.pack(">H", 1003))
                break
            if opcode == 0x8:
                send_frame(conn, 0x8, payload)
                break
            if opcode == 0x9:
                send_frame(conn, 0xA, payload)
                continue
            if opcode == 0x1:
                send_frame(conn, 0x1, payload)
            elif opcode == 0x2:
                send_frame(conn, 0x2, payload)
    except OSError:
        pass
    finally:
        conn.close()
        print(f"[ws] closed {addr}", flush=True)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(8)
    print(f"ws echo listening on 127.0.0.1:{port}", flush=True)
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()
