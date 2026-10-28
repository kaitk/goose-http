#!/usr/bin/env python3
"""An upgraded exchange's key stays live through TIMEOUT; a plain one's is retired first."""
import http.client
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


for loop in ("uring", "epoll"):
    with tempfile.TemporaryFile(mode="w+") as log:
        proc = subprocess.Popen([str(Path(sys.argv[1]).resolve())],
                                env={**os.environ, "LOOP": loop}, stdout=log, stderr=log)
        sock = None
        try:
            for _ in range(100):
                try:
                    sock = socket.create_connection(("127.0.0.1", 27895), timeout=.1)
                    break
                except OSError:
                    assert proc.poll() is None
                    time.sleep(.05)
            assert sock is not None
            conn = http.client.HTTPConnection("127.0.0.1", 27895, timeout=2)
            conn.request("GET", "/plain")
            response = conn.getresponse()
            assert response.status == 200 and response.read() == b"retired", "plain TIMEOUT kept its key live"
            conn.close()
            sock.settimeout(5)
            sock.sendall(b"GET /stream HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                         b"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                         b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
            data = b""
            while b"done" not in data:
                part = sock.recv(4096)
                assert part, "upgraded connection closed"
                data += part
            assert data.startswith(b"HTTP/1.1 101"), data
            assert proc.poll() is None
        finally:
            if sock is not None:
                sock.close()
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            log.seek(0)
            output = log.read()
        assert "upgraded key live through 20 TIMEOUTs" in output and "stale" not in output, output
        print(f"{loop}: plain TIMEOUT retired its key; upgraded key live through 20 TIMEOUTs", flush=True)
