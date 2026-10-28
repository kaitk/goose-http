#!/usr/bin/env python3
"""send_shared through each loop: every byte in order, from a prompt and a stalled reader."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


def expected(n):
    blob = bytes(i * 7 % 251 for i in range(n))
    return b"<" + blob[:1000] + b"|" + blob[1000:] + b">!"


def fetch(path, stall, n):
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
    sock.settimeout(10)
    sock.connect(("127.0.0.1", 27895))
    sock.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                 "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                 "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".encode())
    head = b""
    while not head.endswith(b"\r\n\r\n"):
        part = sock.recv(1)
        assert part, head
        head += part
    assert head.startswith(b"HTTP/1.1 101"), head
    # A stalled reader leaves the loop the rest of the output to keep.
    time.sleep(stall)
    data = bytearray()
    while len(data) < n:
        part = sock.recv(n - len(data))
        assert part, "closed early"
        data.extend(part)
    sock.close()
    return bytes(data)


for loop in ("uring", "epoll"):
    with tempfile.TemporaryFile(mode="w+") as log:
        proc = subprocess.Popen([str(Path(sys.argv[1]).resolve())],
                                env={**os.environ, "LOOP": loop}, stdout=log, stderr=log)
        try:
            for _ in range(100):
                try:
                    socket.create_connection(("127.0.0.1", 27895), timeout=.1).close()
                    break
                except OSError:
                    assert proc.poll() is None
                    time.sleep(.05)
            for path, stall, n in (("/small", 0, 4096), ("/large", .5, 4 << 20), ("/small", 0, 4096)):
                want = expected(n)
                assert fetch(path, stall, len(want)) == want, (loop, path)
            assert proc.poll() is None
            print(json.dumps({"loop": loop, "shared_send": "ok"}), flush=True)
        finally:
            proc.kill()
            proc.wait()
            log.seek(0)
            out = log.read()
            if out.strip():
                print(out, file=sys.stderr)
