#!/usr/bin/env python3
"""send_shared through each loop: every byte in order, from a prompt and a stalled reader,
and a client that leaves with the rest unsent; through a handler's own buffer, which copies; and a
piece for each of the client's frames, which the loop sends once a write buffer's worth is
deferred. Each loop gathers: it holds the ranges'
references until it sends them (GATHERS=1, which the fixture asserts). LOOP=uring needs
io_uring, and is skipped where the fixture finds none, as on macOS or under Docker's
default seccomp profile."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


def expected(n, path=""):
    blob = bytes(i * 7 % 251 for i in range(n))
    if path == "/echo":
        return b"<" + blob * 64 + b">!"
    return b"<" + blob[:1000] + b"|" + blob[1000:] + b">!"


PORTS = {"uring": 27897, "emulated": 27896, "epoll": 27895}


def fetch(port, path, stall, n):
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
    sock.settimeout(10)
    sock.connect(("127.0.0.1", port))
    sock.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                 "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                 "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".encode())
    head = b""
    while not head.endswith(b"\r\n\r\n"):
        part = sock.recv(1)
        assert part, head
        head += part
    assert head.startswith(b"HTTP/1.1 101"), head
    if path == "/echo":
        # 64 masked text frames of 1000 bytes, in one write: more than one read's worth.
        frame = b"\x81\xfe\x03\xe8" + b"\x00" * 4 + b"x" * 1000
        sock.sendall(frame * 64)
    # A stalled reader leaves the loop the rest of the output to keep.
    time.sleep(stall)
    data = bytearray()
    while len(data) < n:
        part = sock.recv(n - len(data))
        assert part, "closed early"
        data.extend(part)
    sock.close()
    return bytes(data)


fixture = str(Path(sys.argv[1]).resolve())
for loop in ("uring", "emulated", "epoll"):
    env = {**os.environ, "LOOP": loop, "GATHERS": "1"}
    with tempfile.TemporaryFile(mode="w+") as log:
        proc = subprocess.Popen([fixture], env=env, stdout=log, stderr=log)
        try:
            for _ in range(100):
                try:
                    socket.create_connection(("127.0.0.1", PORTS[loop]), timeout=.1).close()
                    break
                except OSError:
                    if proc.poll() is not None:
                        break
                    time.sleep(.05)
            if proc.poll() is not None:
                log.seek(0)
                assert loop == "uring" and proc.returncode == 0 and "no io_uring here" in log.read(), loop
                print(json.dumps({"loop": loop, "shared_send": "skipped: no io_uring here"}), flush=True)
                continue
            # The third client leaves after one byte, with most of its 4 MiB unsent.
            for path, stall, n in (("/small", 0, 4096), ("/large", .5, 4 << 20), ("/large", -1, 0),
                                   ("/small", 0, 4096), ("/large", 0, 4 << 20), ("/copy", 0, 4096),
                                   ("/echo", 0, 4096), ("/echo", .5, 4096)):
                want = expected(n, path)
                got = fetch(PORTS[loop], path, max(stall, 0), 1 if stall < 0 else len(want))
                assert got == want[:len(got)], (loop, path)
            time.sleep(.2)
            assert proc.poll() is None, loop
            print(json.dumps({"loop": loop, "shared_send": "ok"}), flush=True)
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(10)
                except subprocess.TimeoutExpired:
                    proc.kill()
            proc.wait()
            log.seek(0)
            out = log.read()
            if out.strip() and "no io_uring here" not in out:
                print(out, file=sys.stderr)
