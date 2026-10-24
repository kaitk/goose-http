# Changelog

What each tag adds. Each release names the Goose compiler it was built and tested with.

## Unreleased

Changed:

- The loops' timers fall due by the precise monotonic clock on Linux and macOS, not
  the coarse one, which is up to a scheduler tick old: `/delay/10` at 64 connections
  answered in 12.2 ms, and now in 10.2 ms
  ([decisions](docs/decisions.md#timers-fall-due-by-the-precise-monotonic-clock)).
- A timer table adds its cells as timers need them, up to its capacity, rather than
  writing every cell at open, and a box's table of live keys is left as `calloc`
  zeroed it. A worker with `max_waiting` at `max_conns`, 16,384, held about 0.8 MiB
  before its first wait; now it holds what its waits use.
- `Config.ring_buffers` is 64, down from 256: io_uring writes every provided buffer
  in turn, so each worker held 1 MiB of them at any load, and 64 serve as fast on
  Linux ([decisions](docs/decisions.md#64-provided-buffers-a-ring)). On Windows, IOCP
  serves 1 to 7% fewer requests a second with 64; a program there that wants them
  back sets `ring_buffers: 256`.
- A WebSocket is promised bytes of the gather budget only while it holds part of a
  message, a message in fragments or a frame split across reads, not from its upgrade
  on. Idle connections and messages that arrive whole cost no budget, so a worker holds
  as many WebSockets as `max_conns` allows, where the defaults stopped it at 1,021.
  `ws_upgrade` no longer answers 503; a message the budget can't hold closes its
  connection with 1013 (Try Again Later)
  ([decisions](docs/decisions.md#a-websocket-is-promised-its-bytes-while-it-holds-a-message)).

Removed:

- `http::ws_admit`. A program that called it before `ws_switch` drops the call; its
  WebSockets are then promised their bytes as `ws_upgrade`'s are.

## v0.5.8 (2026-10-23)

Compression from 256 bytes, and goose-compress `v0.1.4`. Goose `v2026.3`, goose-hash
`v0.0.4`, goose-tls `v0.0.5`, and goose-compress `v0.1.4`.

Changed:

- `http::Compression`'s `min_size` is 256 bytes, down from 1,024: gzip saves bytes on
  JSON from about 192 bytes on, and an 888-byte answer went out raw
  ([decisions](docs/decisions.md#bodies-from-256-bytes-are-compressed)). A program
  that wants the old threshold passes `http::Compression { min_size: 1024, .. }`.
- goose-compress `v0.1.4`, whose DEFLATE level 1 matcher and symbol coder are C, with
  the same bytes: gzip at level 1 takes 12 to 15 percent less time on 4 to 8 KB JSON
  bodies.
- The drain example stops on SIGTERM, so its io_uring listener closes.

## v0.5.7 (2026-10-23)

An io_uring send fix, and goose-compress `v0.1.3`. Goose `v2026.3`, goose-hash
`v0.0.4`, goose-tls `v0.0.5`, and goose-compress `v0.1.3`.

Changed:

- goose-compress `v0.1.3`, whose CRC-32 uses the CPU's carryless multiply (PCLMULQDQ
  on x86-64, PMULL on arm64) in a C shim, and whose `load32` is inlined. Gzip and
  deflate responses are faster, with the same bytes; in Plod's HttpArena entry,
  json-comp serves 20% more requests a second.

Fixed:

- On io_uring, a send made at once, without the ring, reserves its completion before
  any byte goes out. Out of memory, it once returned an error after sending every byte;
  now it sends nothing.

## v0.5.6 (2026-10-23)

Fuzz targets for the parsers, and io_uring closes cancel by tag. Goose `v2026.3`,
goose-hash `v0.0.4`, goose-tls `v0.0.5`, and goose-compress `v0.1.2`.

Added:

- `content_type_of` knows `.map` (`application/json`), `.webmanifest`
  (`application/manifest+json`), and `.otf` (`font/otf`).
- `fuzz/`: libFuzzer targets for the request head and chunked body, HPACK, h2 frames,
  and multipart ([development](docs/development.md#fuzz-the-parsers)).

Changed:

- On io_uring, closing a connection cancels its receive and its send in flight by
  their tags, and only when they're queued, rather than everything on its fd, which
  the kernel finds by walking its whole poll table
  ([decisions](docs/decisions.md#io_uring-cancels-a-closing-connections-requests-by-their-tags)).
- goose-compress `v0.1.2`, whose DEFLATE, gzip, and CRC-32 are faster.

Fixed:

- On io_uring, a file's send closed while it filled its pipe no longer leaves the
  pipe, with that piece in it, for the next file's send.

## v0.5.5 (2026-10-23)

Drain credits for publishers on upgraded connections. Goose `v2026.3`, goose-hash
`v0.0.4`, goose-tls `v0.0.5`, and goose-compress `v0.1.1`.

Added:

- `after_drain(out)` requests a `DRAINED` event when an upgraded connection's output
  reaches its socket, so a publisher can keep one bounded batch in flight. Pending
  mailbox waits stay armed; closing cancels the credit. The application still bounds
  its producer queue and batches ([API](docs/api.md#websocket)).

Fixed:

- On Windows, a `Config.backlog` below 200 stays as asked, rather than being raised
  to 200.

## v0.5.4 (2026-10-22)

A blocking HTTP/1.1 and HTTPS client. Goose `v2026.3`, goose-hash `v0.0.4`, goose-tls
`v0.0.5`, and goose-compress `v0.1.1`.

Added:

- The module `http.client`: HTTP/1.1 requests, plain or over TLS, on the blocking
  socket, for a lane's thread or a program without a loop. A session keeps its
  connection for the next request to the same host; `http::get`, `post`, `put`,
  `patch`, `delete`, and `request` take a block that adds header fields, a bearer
  token, or a body, `http::json` for a JSON one. It decodes chunked bodies, and
  doesn't follow redirects, keep cookies, or decode compressed bodies. A program that
  imports it declares goose-tls (`docs/api.md`, "An HTTP client").

## v0.5.3 (2026-10-22)

A TLS connection's context chosen per connection, for ACME's TLS-ALPN-01. Goose
`v2026.3`, goose-hash `v0.0.4`, goose-tls `v0.0.5`, and goose-compress `v0.1.1`.

Added:

- A TLS connection's context chosen at its ClientHello, as ACME's TLS-ALPN-01 needs:
  `http::tls_server(ctx, chooser)` gives a worker an `http::TlsServerOf<C>`, and on a
  context given to `tls::choose_context`, the handshake calls the program's
  `http::tls_hello(chooser, conn)`, which may move the connection with
  `tls::use_context`. `http::TlsServer` and `http::tls_server(ctx)` are unchanged,
  and add a check only where the handshake is advanced (`docs/api.md`, "HTTPS").

## v0.5.2 (2026-10-22)

Host names in the blocking `connect`, and goose-tls's faster server. Goose `v2026.3`,
goose-hash `v0.0.4`, goose-tls `v0.0.5`, and goose-compress `v0.1.1`.

Added:

- `http::connect(host, port, ms)`, the blocking connect for a thread without a loop,
  resolves a host name with the system's resolver, then tries its addresses in the
  resolver's order, up to 8, all within `ms`. The lookup itself isn't bounded by `ms`,
  and fails with `resolve`'s `ENOENT` for a name with no address or `EAGAIN` for one
  that failed for now. The loop's `http::connect_start` still fails a name with
  `ENOSYS`, since resolving blocks the loop.

Changed:

- goose-tls `v0.0.5`: the server's overhead cut, with one HKDF and one HMAC context
  reused through a handshake and records decrypted in place. In goose-tls's own
  measurements, 8.3% less CPU a json-like request, 2.7% a full handshake, and 11.8% a
  resumed one. No API change.

## v0.5.1 (2026-10-22)

h2 over TLS, goose-tls's own TLS 1.3 server, and outbound sockets released when an h2
stream ends. Goose `v2026.3`, goose-hash `v0.0.4`, goose-tls `v0.0.4`, and
goose-compress `v0.1.1`.

Added:

- h2 over TLS on both loops, chosen by ALPN: a TLS listener whose context lists `h2`,
  as `tls::server_files(chain, key, ["h2", "http/1.1"])`, serves h2 to a client that
  offers it and HTTP/1.1 to one that doesn't, on one port. No new name; a context
  that lists only `http/1.1` serves as before. h2spec passes over TLS on both loops.
  The benchmark server serves it from one context on both its TLS ports, the port + 1
  and the port + 363 (8081 and 8443 beside 8080, `TLS_PORT` and `H2_PORT`), and
  serves `/static/` as `/files/`, for HttpArena's static profiles.
- An idle h2 connection, h2c or over TLS, is sent GOAWAY before it closes, and over
  TLS close_notify after it.
- `http::file_tag(f)`, the `ETag` that `serve_file` sends, which `serve_file` now
  calls, so a program that answers a 304 or 416 itself can match it.
- `http::take_compressed(z, coding, c)`, which takes and resets an encoder from the
  worker's pool, and which `begin_compressed` now calls once it has written the head,
  so a program that writes its own head can stream compressed.
- `http::close_file(f)`, which closes a `File` that `open_file` opened and the
  program won't serve, the last of `open_precompressed`'s parts to be public.

Changed:

- goose-tls `v0.0.4`: the TLS server is goose-tls's own TLS 1.3 server in Goose over
  libcrypto, 2.9 KB per idle connection where libssl held 28.5 KB, with session
  tickets; a client offering ALPN without `http/1.1` now fails with
  `no_application_protocol`. The kTLS handoff is gone, with the benchmark server's
  `KTLS=1`.

Fixed:

- On io_uring, an h2 stream reset while it waits on `http::wait_socket`, or answered in
  the call that waited, cancels the socket's poll, which held a socket the handler hung
  up open until its next event or the connection's close. `test/outbound/` tests both
  over h2c on every loop where `wait_socket` works.
- On io_uring, an HTTP/1.1 handler that answers in the call that waited on
  `http::wait_socket` cancels the socket's poll too.
- An h2 stream refused with 413, for a body past `Config.max_body`, calls its handler
  with `CLOSED` when it was owed a call, as a reset does, so a socket it holds is hung
  up. `test/outbound/` tests both on every loop where `wait_socket` works.

## v0.5.0 (2026-10-22)

Conveniences split into public parts, a budget for the gather pool, and TLS and
outbound connections on the io_uring loop. Goose `v2026.3`, goose-hash `v0.0.4`, goose-tls `v0.0.3`, and
goose-compress `v0.1.1`.

Breaking:

- `http::ws_upgrade(req, ws, out)` and `ws_upgrade(req, ws, out, protocol)` take the
  connection's `WebSocket`, which they admit to the gather pool. Where the worker's
  budget can't hold it, the upgrade gets 503 with `Retry-After: 1`, and the connection
  stays open.
- `WebSocket.limit` defaults to 64 KiB, from 1 MiB.
- `WebSocket`'s `pending` and `message` are one run, `held`, whose first `joined`
  bytes are the message so far.
- `http::gather` answers a body its worker's budget can't hold with 503 and
  `Retry-After: 1` at its head, and closes the connection. A chunked body is promised
  its `limit`. `gather_head` takes the `limit` and returns whether it was promised, and
  `gather_piece` returns false past the promise.

Added:

- The gather pool has a budget in each worker, the most bytes it promises its runs at
  once: `http::GATHER_BUDGET`, 64 MiB, unless `http::gather_budget(bytes)` sets
  another. A body is promised its bytes at its head, a Content-Length's exact size or a
  chunked body's `limit`, and a WebSocket at its upgrade; a run admitted is never
  refused later. The pool's parts are public, for a framework's own runs under the same
  budget: an `http::Gather`'s bytes are `http::gathered[g.at..g.at + g.len]`, and
  `gather_promise`, `gather_piece`, `gather_clear`, `gather_head`, and
  `release_gather` promise, fill, empty, and give back a run. `http::ws_admit(ws)`
  promises a WebSocket its `limit` and `http::WS_SLACK`, 131 bytes, for a control frame
  not yet whole after a message nearly at the limit
  ([decision](docs/decisions.md#the-gather-budget-counts-bytes-promised-and-refuses-at-admission)).
- WebSocket's parts: `http::ws_check(req, minor)` returns the upgrade's status, the
  key, and the fields a refusal must carry, and writes nothing; `http::ws_switch(out,
  key, protocol)` writes the 101 and switches the connection; and `http::ws_take(bytes,
  ws, out)` reads frames from bytes the program holds, with `ws_release` at `CLOSED`.
  `ws_upgrade` and `ws_read` compose them, and answer byte for byte as before
  ([api](docs/api.md#websocket)).
- A `TIMEOUT` given because no room was left to wait (`Config.max_waiting`) has the tag
  `http::NO_ROOM`, so a handler can answer 503 there and 504 for a time limit.
- `http::unrouted(r)` returns the status `otherwise` answers a request no route took,
  501, 400, 204, 405, or 404, and `otherwise` composes it.
  `http::unrouted(method, path, routable, allow)` gives the same status to a router of
  the program's own.
- `docs/api.md`'s "Parts" lists the checks and writers the helpers are made of, for a
  framework that answers in its own shape: `has_type`, `negotiate`, `known_method`,
  `is_routable`, `same_segment`, `field_in`, `parse`, `forwarded_client`, `H2_MINOR`
  and `switched`, `unrouted`, `field_at`, `same_name`, compression's `coding_for`,
  `coding_q`, `compressible`, `coding_field`, and `compress_whole`, `status_line`,
  `write_body`, `refuse`, `Stream` and `Framing`, and the gather pool's parts. A change
  to one is an API change
  ([decision](docs/decisions.md#every-convenience-is-a-composition-of-public-parts)).
- HTTPS on the io_uring loop: `http::serve(cfg, server)` and `serve(cfg, fresh,
  server)` serve the listeners that ask for TLS, as `serve_epoll` does. An idle TLS
  connection that times out, or one a stop closes, sends close_notify. On Windows,
  `serve` still fails with `ENOSYS` on a TLS listener.
- Outbound connections on the io_uring loop: `http::wait_socket` waits on `serve` with
  io_uring as on `serve_epoll`, and the socket's poll is cancelled once the wait ends,
  so no stale `SOCKET_READY` reaches a later wait. The emulated ring and IOCP still
  fail it with `ENOSYS`
  ([decision](docs/decisions.md#io_uring-cancels-a-sockets-poll-when-its-wait-ends)).
- kTLS on the epoll loop on Linux: a context that asks with goose-tls's
  `tls::use_kernel(ctx)` hands each connection's record layer to the kernel after its
  handshake. Handlers don't change, and io_uring's connections stay in user space.
  Parked since: 9% fewer cycles on small responses doesn't justify it yet
  ([decision](docs/decisions.md#ktls-is-the-contexts-choice-made-by-the-program)).
- `docs/patterns.md` shows several processes on one port, each under the service
  manager, so a crash resets only its own connections.
- The benchmark server's TLS build serves on either loop, and HttpArena's entry runs it
  on io_uring with the Rust entries' key exchange (`TLS_GROUPS`). The README records
  HttpArena's json-tls and 8gbit against its Rust entries.

Not yet: h2 over TLS, kTLS on io_uring, and TLS on Windows.

## v0.4.3 (2026-10-20)

h2c's cost to HTTP/1.1 on the epoll loop removed, and `Config.require_ring`. Goose
master `f114b5a`, goose-hash `v0.0.4`, goose-tls `v0.0.1`, and goose-compress `v0.1.1`.

- The epoll loop's turn of reading, answering, and sending takes its answering as a
  block, one for HTTP/1.1 and one for h2c, so an HTTP/1.1 connection's copy no longer
  carries the h2 driver's state through every call. An HTTP/1.1 request costs about
  170 fewer user instructions on this repository's REST server and 210 fewer on
  goose-rest, unpipelined; tier A runs 2-4% faster on epoll. The io_uring loop and
  plaintext's count are unchanged.
- `Config.require_ring` makes `http::serve` fail with call `io_uring` where it would
  emulate the ring on epoll, before it opens a listener, so a server meant to run on
  io_uring doesn't run on epoll unnoticed. On macOS it always fails (`ENOSYS`).

## v0.4.2 (2026-10-20)

Bearer tokens and header lines scanned 16 bytes at a time. Goose master `f114b5a`,
goose-hash `v0.0.4`, goose-tls `v0.0.1`, and goose-compress `v0.1.1`.

- `http::bearer` checks a token's token68 bytes, and `http::field_at` finds a line's
  colon and its end, with std's `find_any`, where each scanned a byte at a time. What
  they accept is unchanged: the tests try a bad byte and an `=` at every position of
  tokens up to 48 bytes. On tier C, whose tokens are 560 bytes, a request costs about
  7,600 fewer user instructions on goose-rest, which calls both, and 3,100 fewer on
  this repository's REST server, which calls `field_at`; plaintext's count is
  unchanged.
- The REST benchmark server checks tier C's JWT shape with `find_any` too, as
  goose-rest's does, so both servers do the same work outside the framework: 6,100
  fewer user instructions per tier C request. Tier C templated runs 5-8% faster on
  both.
- Each test program gets a `TMPDIR` of its own, where a test that listens on a Unix
  socket puts it, so the suite passes from a checkout on WSL's `/mnt/c`.

## v0.4.1 (2026-10-20)

`v0.4.0`'s benchmark server back to `v0.3.7`'s cost. The package itself is unchanged.
Goose master `f114b5a`, goose-hash `v0.0.4`, goose-tls `v0.0.1`, and goose-compress
`v0.1.1`.

- The benchmark server echoes a WebSocket from a function outside its inlined handler,
  and keeps each WebSocket in a pool, with only an index in the request state. Inside
  the handler, the WebSocket's frame loop changed how Goose inlined the event loop's
  call to it, and cost about 140 user instructions per plaintext request that never
  upgrades. Plaintext counts 1,609-1,610 on epoll and 1,648-1,661 on io_uring, as
  `v0.3.7` does.
- The benchmark server's TLS listener is a build of its own, `server/server_tls.goose`
  (`TLS=1` in `scripts/build.sh`), so the plaintext epoll server doesn't map OpenSSL:
  3.8 MB of peak RSS where `v0.4.0`'s held 6.0 MB. HttpArena's image starts the TLS
  build when a certificate is mounted.

## v0.4.0 (2026-10-19)

HTTP/2 over TCP (h2c), HTTPS, WebSocket, outbound connections, `http::run`, and lanes
in the package. Goose master `f114b5a`, since no release has
[aardappel/goose#37](https://github.com/aardappel/goose/pull/37) yet, which `http::run`
and `http::lane_open` need; goose-hash `v0.0.4` for WebSocket, goose-tls `v0.0.1` for
TLS, and goose-compress `v0.1.1`.

- h2c, HTTP/2 with prior knowledge, in the epoll, kqueue, and io_uring loops and the
  ring's emulation: HPACK and HTTP/2's frames written in Goose, `Config.h2c` for the
  main port, and `Config.h2_max_streams`, `h2_stream_window`, and `h2_conn_window`.
  Handlers don't change: each stream is an exchange. Expect is answered on a stream, a
  handler that ends keep-alive ends the connection with a GOAWAY, and flood budgets are
  set from what h2load, nghttp, and curl spend. It passes h2spec, 146 of 146 cases, and
  147 of 147 with `-S`. Translating a response's head into HPACK takes one pass over
  it, and lowercases names in place
  ([api](docs/api.md#several-ports-and-h2c)).
- Several listeners per loop: `Config.listeners` adds up to `http::MAX_LISTENERS` (3)
  ports on the same address, each an `http::Listener { port, h2c, tls }`, served by the
  same workers. `http::ring_listeners()` says how many a ring takes; IOCP takes one.
- HTTP/1.1 over TLS 1.3 in `serve_epoll` on Linux and macOS, from the module
  `http.tls` with goose-tls over OpenSSL 3: `Config.tls` or a `Listener`'s `tls`,
  `http::tls_server(ctx)` per worker, and `http::release` after the loop
  ([api](docs/api.md#https)).
- WebSocket (RFC 6455) in the module `http.websocket`, over HTTP/1.1 and TLS:
  `http::ws_upgrade`, `ws_read`, `ws_send`, and `ws_close`, with pings, Close, and the
  protocol's errors handled by the package. It passes Autobahn's test suite, but for
  the extension sections ([api](docs/api.md#websocket)).
- Outbound connections, TCP or a Unix socket: `http::connect`, `send_all`, and `recv`
  with time limits block a lane's thread; `http::connect_start`, `wait_socket`,
  `connected`, `send`, and `recv` drive a socket from a handler on `serve_epoll`, where
  the exchange waits for it as for mail, with `WAKE` and `http::SOCKET_READY`
  ([api](docs/api.md#outbound-connections)).
- `http::run(cfg, worker)` spawns the workers, up to two values passed to each beside
  its `Config`, and returns once all have returned.
- Lanes are in the package: `http::lane_open` spawns a lane's threads, each with a box,
  `http::lane(box)` is a thread's loop, `lane_send` and `lane_send_value` send to the
  least busy, `lane_stop` stops and waits for them, `lane_of(box)` is a lane of one box
  for a test, and `lane_spawn` lets a package start lane threads of its own
  ([api](docs/api.md#lanes)).
- A `later` while waiting isn't configured (`Config.mail_slots` and `max_waiting` 0)
  gets `TIMEOUT` on the loop's next pass, and its address takes no message.
- The benchmark server serves h2c on its port + 2 (`H2C_PORT`), TLS on its port + 1
  with `LOOP=epoll` (`TLS_CERT`, `TLS_KEY`, `TLS_PORT`), `/ws`, and HttpArena's
  `/baseline2`. `bench/h2c.sh` runs HttpArena's h2c profiles.
- Removed: placement (`http::place_load`, seats, and `docs/tuning.md`), which hadn't
  been measured to help, and 32-bit ARM. aarch64 builds with Goose's default stack
  reserve.

Not yet: TLS and `wait_socket` on `http::serve`'s loops (io_uring, its emulation, and
IOCP) fail with `ENOSYS`, so Windows has no TLS; h2 over TLS and the kernel's TLS are
still to come; h2c is untested on Windows; host names other than `localhost` aren't
resolved.

## v0.3.7 (2026-10-19)

A lane stops with a flag a full box can't refuse, and threads can be placed on cores
from a file per machine, as an experiment. Goose `v2026.2` (`3ee3871`).

- `http::mail_stop(b)` stops a box from any thread, and `http::mail_stopped(b)` tells
  its owner that it is stopped and empty, with every message sent before the stop
  taken. A send to a stopped box returns `STALE`, `mail_live` is false, and
  `mail_slot_size` is -1. After a stop, `mail_wait` returns at once: true while
  messages are pending, false once the box is empty
  ([api](docs/api.md#answers-that-wait)). `examples/later` stops its lane.
- `http::mail_queued(to)` gives how many messages a box holds, from any thread, for
  picking the least busy of several.
- Placement, experimental until measured on real cores: a placement file, read by
  `http::place_load()` from `--place`, `--place=`, or `GOOSE_PLACE`, or from a path the
  program gives, maps roles to cores, `each` core of a set, `within` a set, or one
  `core`, with `exclusive` sets, `low` priority, and `incoming` (`SO_INCOMING_CPU`).
  Workers take their seats from `Config.place`, `http::place_ref(place)`, by
  `Config.role`, `"workers"` by default, and any other thread with
  `http::place_seat` and `http::take_seat`. A file's count for the workers' role
  replaces `Config.workers`. Nothing about the hardware stops the start: each
  shortfall prints a warning and the program runs without it; a file that doesn't
  parse ends it with exit code 2. Without a file, nothing changes
  ([tuning](https://github.com/kaitk/goose-http/blob/placement/docs/tuning.md), on the
  branch `placement` since it left `main`).
- `docs/tuning.md` covers worker counts, placement files, what each platform does, and
  what has been measured: on an M1 Pro, no layout beat the default.
- `bench/pinning.sh` measures a short route's latency beside a busy CPU lane in each
  layout of workers and lane.

## v0.3.6 (2026-10-16)

The store reads numbers and records by value, and the release builds with Goose
`v2026.2` (`3ee3871`) and goose-compress `v0.1.1`.

- `http::store_i64`, `store_u32`, `store_u8`, and `store_f64` read a little-endian
  value at a byte offset of a blob, and `http::store_record<T>(b, i, read)` reads record
  `i` of a flat fixed-size `T` through a C function the program declares for `T`. Each
  returns the value and whether the read was in range, with no buffer. A record read
  costs 2.6 ns on an M1 Pro, against 10.3 ns for `store_append` and `from_bytes`
  ([api](docs/api.md#the-store)).
- `docs/api.md` documents the store, `store_append` included.
- The REST benchmark server's application, its records, loaders, writers, templates,
  and tier D's body work, is `bench/rest/goose/app.goose`, which goose-rest's benchmark
  server imports.
- goose-compress `v0.1.1`, the same encoders built with `v2026.2`.

## v0.3.5 (2026-10-16)

A part of a multipart body read whole comes as slices of it. Goose `v2026.1` (`ac759c3`).

- `http::find_part(req, body, name)` gives the first part named `name` of a whole
  `multipart/form-data` body: its content and its head fields, both slices of the body,
  and a status, `PART_FOUND`, `PART_ABSENT`, `PART_TYPE`, or `PART_BAD`. It follows
  `each_part`'s rules, and doesn't read the parts after the one it finds.

## v0.3.4 (2026-10-16)

The emulated ring serves every connection under load. Goose `v2026.1` (`ac759c3`).

- The ring's emulation, over epoll where io_uring isn't available and over kqueue on
  macOS, collects the kernel's events on every wait. It returned the completions of its
  busy connections without them, so under load a connection waiting to send or to read
  could wait for seconds.

## v0.3.3 (2026-10-15)

JSON strings are written faster, an upgraded connection is read while it waits, and the
tests follow Goose's own convention. Goose `v2026.1` (`ac759c3`).

- `http::json_string` looks for a byte to escape 16 bytes at a time and appends the
  bytes between escapes whole. Its output equals `json::format_string`'s, and the
  examples and the benchmark servers write their JSON strings with it.
- `http::json_string` writes a newline, tab, carriage return, backspace, and form feed
  in their short forms (`\n`, not `\u000a`), as `json::format_string` does.
- An upgraded connection's bytes keep coming as `BODY` while its exchange waits with
  `later`, where they waited for the wait to end.
- The architecture is two pages: how goose-http works, for users, and the decisions
  behind it, for contributors.
- The tests are small programs by area under `test/`, each checked against a golden
  file, and `test/run_tests.py` runs them.

## v0.3.2 (2026-10-15)

A mailbox of one slot is refused, goose-compress is imported by its tag, and the
documentation is split by topic. Goose `v2026.1` (`ac759c3`).

- `http::mail_open` refuses fewer than two slots with `EINVAL`, and a `Config.mail_slots`
  of 1 stops the loop with that error. A box of one slot reported `SENT` for every send,
  overwriting the message not yet taken.
- `http.compression` imports goose-compress at `v0.1.0`, the same code as the commit
  v0.3.1 named. A program that compresses declares it at that tag.
- The API reference, server patterns (request bodies, long responses, mail, slow work,
  limits, and shared state), development setup, and known issues are pages of their
  own.
- Builds with the official Goose release that `scripts/goose.sh` pins.

## v0.3.1 (2026-10-14)

A send to an exchange that no longer waits says so at once, so a service can stop
working for a client that has gone. Goose `46356c2`.
[Release notes](https://github.com/kaitk/goose-http/releases/tag/v0.3.1).

- `http::mail_send` returns `STALE` for a reply to an exchange whose client closed or
  whose wait timed out, where it returned `SENT` and the loop dropped the message.
- `http::mail_live(address)` checks, from any thread and without sending, whether an
  exchange still waits.
- A reply sent in pieces is never refused between pieces.
- Boxes of a program's own can track keys: `http::mail_open(slots, size, waker,
  live_keys, key_shift)` and `http::mail_mark`. The new parameters are optional.
- REST strings' JSON escapes are found 16 bytes at a time.

## v0.3.0 (2026-10-14)

A revised API, compression, files sent without copying on every loop, and a shared
store for immutable data. Goose `46356c2`.
[Release notes](https://github.com/kaitk/goose-http/releases/tag/v0.3.0), with the
migration from `v0.2.0`.

- Precompressed Brotli, Zstandard, and gzip files, and gzip, deflate, and Zstandard on
  the fly through `http.compression`.
- Large files sent without copying on io_uring, its epoll emulation, and IOCP.
- `http.store`: immutable byte blobs shared by every worker.
- `insert_field`, `file_path`, `fail_multipart`, typed mail helpers, and
  `exit_on_error`.
- API changes: request helpers take `const Request&`; `BodyReader`, multipart `Part`,
  and `Stream` framing are enums; `query_int` returns `(value, found)`;
  `stop_on_signals` returns `http::Error` and `mail_open` returns `(Box, Error)`.

## v0.2.0 (2026-10-12)

The HTTP/1.1 essentials: a strict parser, the router, bodies and responses of any size,
conditional and range requests, static files, cookies and `Basic` authorization, forms
and multipart, limits and timeouts, answers that wait, the client's address, IPv6, and
Unix sockets, on io_uring, epoll, kqueue, and IOCP.

## v0.1.0 (2026-10-11)

The first tag: an event loop per worker, `http::serve` (io_uring, IOCP, or a ring over
kqueue) and `http::serve_epoll`, with keep-alive. Requests and responses
are fixed in size: no header lookup, bodies read in pieces, or streamed responses.
