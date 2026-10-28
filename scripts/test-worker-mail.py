#!/usr/bin/env python3
"""Mail to the worker's own address, from its thread and another, reaches the handler as
WORKER, which wakes the waiting exchanges with http::wake: every live one gets WAKE with the
message's tag, and one whose client left is STALE. LOOP=uring needs io_uring, and is skipped
where the fixture finds none."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

PORTS = {"uring": 27894, "emulated": 27893, "epoll": 27892}


def request(port, path):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    sock.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
    return sock


def body(sock):
    data = b""
    while True:
        part = sock.recv(4096)
        assert part, data
        data += part
        head, _, rest = data.partition(b"\r\n\r\n")
        length = [int(l.split(b":")[1]) for l in head.split(b"\r\n") if l.lower().startswith(b"content-length:")]
        if length and len(rest) >= length[0]:
            sock.close()
            return rest[:length[0]].decode()


fixture = str(Path(sys.argv[1]).resolve())
for loop in ("uring", "emulated", "epoll"):
    with tempfile.TemporaryFile(mode="w+") as log:
        proc = subprocess.Popen([fixture], env={**os.environ, "LOOP": loop}, stdout=log, stderr=log)
        port = PORTS[loop]
        try:
            for _ in range(100):
                try:
                    socket.create_connection(("127.0.0.1", port), timeout=.1).close()
                    break
                except OSError:
                    if proc.poll() is not None:
                        break
                    time.sleep(.05)
            if proc.poll() is not None:
                log.seek(0)
                assert loop == "uring" and proc.returncode == 0 and "no io_uring here" in log.read(), loop
                print(json.dumps({"loop": loop, "worker_mail": "skipped: no io_uring here"}), flush=True)
                continue
            for path, tag in (("/ping", 7), ("/far", 9)):
                waiting = [request(port, "/wait") for _ in range(3)]
                gone = request(port, "/wait")
                time.sleep(.2)
                gone.close()
                time.sleep(.2)
                assert body(request(port, path)) == "sent", (loop, path)
                for sock in waiting:
                    assert body(sock) == f"woken {tag}", (loop, path)
            time.sleep(.2)
            log.seek(0)
            lines = [l for l in log.read().splitlines() if l.startswith("tag ")]
            assert lines == ["tag 7: woke 3, stale 1", "tag 9: woke 3, stale 1"], (loop, lines)
            print(json.dumps({"loop": loop, "worker_mail": "ok"}), flush=True)
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(10)
                except subprocess.TimeoutExpired:
                    proc.kill()
            proc.wait()
