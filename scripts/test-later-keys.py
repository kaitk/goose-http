#!/usr/bin/env python3
"""A lane's reply to an HTTP/1.1 exchange whose client has gone is STALE, and reaches no h2c
stream of a later connection in the same slot, whatever generations and pool indexes the streams
get. With a generation counter of their own, stream 5's key was the gone exchange's. LOOP=uring
needs io_uring, and is skipped where the fixture finds none."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

PORTS = {"uring": 27884, "emulated": 27882, "epoll": 27880}


def frame(kind, flags, sid, payload):
    return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", sid) + payload


def headers(path):
    p = path.encode()
    return b"\x82\x86\x01\x01x\x04" + bytes([len(p)]) + p


def read_for(sock, secs):
    sock.settimeout(.1)
    data, end = b"", time.time() + secs
    while time.time() < end:
        try:
            part = sock.recv(65536)
        except socket.timeout:
            continue
        if not part:
            break
        data += part
    return data


def data_frames(data):
    out = []
    while len(data) >= 9:
        n = int.from_bytes(data[:3], "big")
        if len(data) < 9 + n:
            break
        if data[3] == 0 and n > 0:
            out.append((int.from_bytes(data[5:9], "big") & 0x7FFFFFFF, data[9:9 + n]))
        data = data[9 + n:]
    return out


def attack(port):
    # The readiness probe was the worker's first connection, in slot 0. The victim takes the
    # slot next, with generation 2, and leaves before the lane replies to its first exchange.
    v = socket.create_connection(("127.0.0.1", port))
    v.sendall(b"GET /slow HTTP/1.1\r\nHost: x\r\n\r\n")
    time.sleep(.05)
    v.close()
    time.sleep(.05)
    # Another client's h2c streams in the slot, waiting when the lane replies. With their own
    # counter, stream 3 had generation 2 and pool index 1: the victim's key. It waits last, so
    # the slot's live entry is its key when the lane sends.
    a = socket.create_connection(("127.0.0.1", port + 1))
    a.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + frame(4, 0, 0, b""))
    for sid in (1, 3):
        a.sendall(frame(1, 5, sid, headers("/wait")))
    got = data_frames(read_for(a, 1.5))
    a.close()
    return got


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
                print(json.dumps({"loop": loop, "later_keys": "skipped: no io_uring here"}), flush=True)
                continue
            got = attack(port)
            log.seek(0)
            lines = [l for l in log.read().splitlines() if l.startswith("lane: ")]
            assert lines == ["lane: stale"], (loop, lines)
            assert sorted(got) == [(1, b"timeout"), (3, b"timeout")], (loop, got)
            print(json.dumps({"loop": loop, "later_keys": "ok"}), flush=True)
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(10)
                except subprocess.TimeoutExpired:
                    proc.kill()
            proc.wait()
