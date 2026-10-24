#!/usr/bin/env python3
"""Checks the HTTP/3 example (examples/h3) with aioquic, a QUIC and TLS stack of
its own, as scripts/test-h3.sh runs it in a container:

    python3 h3_client.py HOST PORT STATIC_DIR

One connection makes every request at once, each on its own stream: the
example's routes, and each file of STATIC_DIR as identity, br, and gzip,
compared byte for byte with the file on disk or its .br or .gz copy. Prints a
line per check and exits 1 if any fails."""
import asyncio
import os
import ssl
import sys

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.h3 = H3Connection(self._quic)
        self.waiting = {}

    def quic_event_received(self, event):
        for ev in self.h3.handle_event(event):
            got = self.waiting.get(getattr(ev, "stream_id", None))
            if got is None:
                continue
            if isinstance(ev, HeadersReceived):
                got["fields"].update({k.decode(): v.decode() for k, v in ev.headers})
            elif isinstance(ev, DataReceived):
                got["body"] += ev.data
            if getattr(ev, "stream_ended", False) and not got["done"].done():
                got["done"].set_result(True)

    async def request(self, host, method, path, fields=(), body=b""):
        sid = self._quic.get_next_available_stream_id()
        headers = [(b":method", method), (b":scheme", b"https"), (b":authority", host.encode()), (b":path", path)]
        headers += list(fields)
        if body:
            headers.append((b"content-length", str(len(body)).encode()))
        self.h3.send_headers(sid, headers, end_stream=not body)
        if body:
            self.h3.send_data(sid, body, end_stream=True)
        got = {"fields": {}, "body": b"", "done": asyncio.get_running_loop().create_future()}
        self.waiting[sid] = got
        self.transmit()
        await asyncio.wait_for(got["done"], 20)
        return self.waiting.pop(sid)


async def main():
    host, port, static = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    config.verify_mode = ssl.CERT_NONE
    checks = []

    def check(label, ok):
        checks.append(ok)
        print(("ok      " if ok else "FAILED  ") + label)

    names = sorted(n for n in os.listdir(static) if not n.endswith((".br", ".gz")))
    async with connect(host, port, configuration=config, create_protocol=Client) as client:
        reqs = [
            ("baseline", b"GET", b"/baseline2?a=13&b=42", (), b""),
            ("root", b"GET", b"/", (), b""),
            ("echo", b"POST", b"/echo", (), b"x" * 5000),
            ("missing", b"GET", b"/missing", (), b""),
        ]
        for coding in ("", "br", "gzip"):
            fields = ((b"accept-encoding", coding.encode()),) if coding else ()
            for n in names:
                reqs.append((f"{n} {coding or 'identity'}", b"GET", b"/static/" + n.encode(), fields, b""))
        results = await asyncio.gather(*(client.request(host, m, p, f, b) for _, m, p, f, b in reqs))
    by = {label: r for (label, *_), r in zip(reqs, results)}
    check("baseline: 200 text/plain 55", by["baseline"]["fields"].get(":status") == "200" and
          by["baseline"]["fields"].get("content-type") == "text/plain" and by["baseline"]["body"] == b"55")
    check("root: Hello, World!", by["root"]["body"] == b"Hello, World!")
    check("echo: a 5,000-byte body back", by["echo"]["body"] == b"x" * 5000)
    check("missing: 404", by["missing"]["fields"].get(":status") == "404")
    for label, r in by.items():
        if " " not in label:
            continue
        n, coding = label.split(" ")
        got = r["fields"].get("content-encoding", "")
        path = os.path.join(static, n + {"br": ".br", "gzip": ".gz"}.get(got, ""))
        want = open(path, "rb").read()
        check(f"{label}: {len(r['body'])} bytes as {got or 'identity'}",
              r["fields"].get(":status") == "200" and r["body"] == want and
              int(r["fields"].get("content-length", "-1")) == len(want) and (coding == "identity" or got in ("", coding)))
    print(f"{checks.count(True)} of {len(checks)} passed")
    sys.exit(0 if all(checks) else 1)


asyncio.run(main())
