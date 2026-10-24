# Architecture

How goose-http works, and why. The [API](api.md) describes each call,
[server patterns](patterns.md) which approach fits bodies, long responses, and slow
work, the [examples](../examples/README.md) show each in a program, and the
[benchmarks](benchmarks.md) give the measured costs. The decisions behind this design,
with their dates and the alternatives rejected, are in [decisions](decisions.md).

## What isn't Goose

Measuring Goose is the point, so all HTTP functionality is written in Goose: parsing,
routing, response building, the loops' state machines, messages between threads, the
timer table, and JSON. The package uses the pinned Goose release without modifying it.

### C in the package

`http.build`, the package sidecar, compiles each platform's C files from `shim/` into
every program that imports the package, so Goose code needs no conditional
compilation:

| File | Platform | What it does |
|---|---|---|
| `shim/net.c` | Linux | Sockets, outbound ones included, epoll, clocks, file reads, the stop counter, and the loops' waker, an `eventfd` |
| `shim/kqueue.c` | macOS | `shim/net.c`'s functions over kqueue, with the same Linux error codes; the waker is `EVFILT_USER` |
| `shim/net_win.c` | Windows | `shim/net.c`'s functions over Winsock |
| `shim/uring.c` | Linux | The io_uring ring, over liburing |
| `shim/iocp.c` | Windows | The same ring over a completion port, and the waker, a completion packet |
| `shim/ring_epoll.c` | Linux, macOS | The ring emulated over epoll or kqueue, where io_uring is blocked, and always on macOS |
| `shim/mail.c` | all | The boxes' bounded queue, and the list of loop wakers that `http::stop` wakes |
| `shim/store.c` | all | The store's blobs, written once at startup and read by every thread |

Each is C for one of five reasons:

- **Syscalls and kernel structures.** Goose calls C functions, not the kernel, and its
  structs are packed, so they don't match the kernel's own (`struct epoll_event` is 16
  bytes on ARM, 12 in Goose). So `shim/net.c`, `shim/kqueue.c`, and `shim/net_win.c`
  call the kernel and copy its structures into the package's.
- **Memory the kernel uses after a call returns.** A C function may not keep a
  pointer into Goose memory past the call (spec §7.10), but io_uring and IOCP read and
  write buffers while a request is in flight. So each ring owns its buffers in C.
- **Atomics, and a wait another thread can end.** Goose threads share no memory and
  have no atomics, and a Goose thread can't end another's wait in the kernel. So
  `shim/mail.c` holds each box's slots and the counts its senders change atomically,
  and each platform's waker ends a loop's wait.
- **Memory every thread reads.** Goose shares only static data between threads, and
  copies every other global a worker uses when it's spawned. `shim/store.c` holds
  byte blobs a program writes once, before its workers read them.
- **A copy into an existing slice at memmove's speed.** Goose's `copy_into` is a byte
  loop under gcc, and only `append` copies whole runs. `net_move`, in each platform's
  shim, is `memmove`, which `sys.goose`'s `net_copy` calls after checking the lengths;
  HTTP/3 copies its bodies and datagrams with it
  ([findings](goose-findings.md#copy_into-copies-a-byte-at-a-time)).

A program that imports `http.websocket` also links goose-hash's C, which runs the
handshake's SHA-1 on the CPU's SHA instructions where it has them, and goose-hash's
Goose rounds elsewhere ([WebSocket](#websocket)).

Each C file is a separate translation unit and declares the layouts it shares with
Goose; the [C interop guide](c-interop.md) describes them. Goose has no runtime
function pointers (§7.5), and `export fn` calls must stay on the thread that called
`goose_init` (§7.11), so libraries that call back into Goose don't fit the loop. A
list of slices can't cross `extern fn` (§7.10), so responses are batched in one buffer
rather than passed as an `iovec` list to `writev`.

### Outside the package

None of this is in a program that imports the package alone:

- **TLS, in goose-tls**, a package of its own: its C over OpenSSL comes only with
  the module `http.tls` ([TLS](#tls)).

- **Competing servers, in `bench/`**, each in its own language, built in release mode
  by `bench/build.sh`: hyper, tokio, may-minihttp, and xitca-web (Rust); vanilla-epoll
  and vanilla-io_uring (V); dusty, zeemo, and zix (Zig); odin-http (Odin); and
  libreactorng (C). `bench/httparena/goose/` is the Dockerfile that builds this
  server for HttpArena.
- **Benchmark tools, in C**: `bench/latency.c` reads h2load's per-request log into
  percentiles, and `bench/wrk-monotonic.c`, preloaded into wrk, gives it the
  monotonic clock where WSL2 steps the wall clock.
- **Scripts.** Shell runs the builds, tests, and benchmarks (`scripts/*.sh`,
  `bench/*.sh`). Python drives the HTTP and echo checks (`scripts/http_client.py`,
  `scripts/echo_client.py`), summarizes benchmark runs (`bench/summarize.py`), and logs
  clock steps (`bench/clockstep.py`). Lua makes wrk pipeline its requests
  (`scripts/pipeline.lua`).

## Event loops

### Workers and connections

`http::run` spawns the program's worker, a `thread_fn` it takes as a generic parameter,
once per worker, and passes each a flat `Config` of its own. Each worker runs one loop and owns its connections for their
lifetime. No worker takes another's connections, as a work-stealing scheduler would, so
a connection's state stays in one thread's caches and idle workers don't contend for a
shared run queue. Tina's author explains the trade in
[the work-stealing myth](https://pmbanugo.me/blog/why-async-await-complect-concurrency):
fairness costs throughput.

`http::worker_count(cfg)` uses `Config.workers`, or the hardware thread count by
default. On macOS it defaults to the performance-core count, and the loop sets
user-interactive QoS. Linux workers bind separate listeners with `SO_REUSEPORT`;
macOS and Windows workers share a listener.

A connection is a slot in its worker's pool, and the slot is the event tag. Read and
write buffers belong to the worker; an incomplete request or output not yet sent goes
to a spill pool, so an idle connection holds no buffer. At `Config.max_conns`, or
after `EMFILE` or `ENFILE`, a worker pauses accepting and retries after a close or at
the next sweep; waiting clients stay in the backlog.

The epoll loop reads at most `Config.max_read` bytes, 16 KB by default, from one
connection per turn, and puts a connection left readable on a deferred list, so a
sustained upload can't take a worker for its whole body. On the completion loop, a
sustained upload can still delay other connections' reads.

### Completion loop

`http::serve` runs a completion loop, a proactor that submits I/O and learns when it is
done: io_uring on Linux, IOCP on Windows, and an emulation over epoll or kqueue
elsewhere. `http::serve_epoll` is a readiness loop, a reactor that learns a socket is
ready and then reads or writes; it uses less memory and works on Linux and macOS. The program chooses a loop by calling it, and a loop it
doesn't call isn't compiled in.

| Platform | `http::serve` | `http::serve_epoll` | Networking shim |
|---|---|---|---|
| Linux | io_uring, or emulated over epoll | epoll | `shim/net.c`, `shim/uring.c`, `shim/ring_epoll.c` |
| macOS | emulated over kqueue | kqueue | `shim/kqueue.c`, `shim/ring_epoll.c` |
| Windows | IOCP | fails with `ENOSYS` | `shim/net_win.c`, `shim/iocp.c` |

On Linux, each worker owns an io_uring ring on kernel 6.1 or later, set up so
completion work stays on the worker when it waits. Multishot accept takes connections,
and multishot receive fills provided buffers. The ring owns the memory the kernel
touches after a call returns: the shim copies sends into its own reused buffers, and
the loop copies receives out of provided buffers. A send of at least 64 KB with
nothing queued on its socket first tries a synchronous `send(2)`, so only unsent bytes
need a copy.

A connection has one send in flight, and later sends queue behind it, which keeps
order and batches pipelined responses. Past `Config.max_queued` bytes queued, the loop
stops receiving until the client reads. A completion carries the connection's slot
and generation, and the shim tracks each fd's generation, so a send left from a closed
connection never goes to a new one that reuses the fd. A close cancels the
connection's receive, while one is queued, and its send in flight, each by its tag,
which the kernel finds by hash
([decisions](decisions.md#io_uring-cancels-a-closing-connections-requests-by-their-tags)).

Where io_uring isn't available, such as under Docker's default seccomp profile, with
io_uring disabled, or on an older kernel, the ring falls back to the emulation in
`shim/ring_epoll.c`. `http::ring_probe()` reports why, `Config.emulate_ring`
selects the emulation for tests, and `Config.require_ring` makes `serve` fail instead
of falling back: `ring_create`'s `RING_REQUIRE` returns io_uring's error.

### Platforms

On macOS, workers share one listener per port, because separate `SO_REUSEPORT`
listeners didn't spread connections, and an accept counter for each port keeps one
worker from taking them all. Apple Silicon has no CPU affinity.

On Windows, repeated `AcceptEx` and `WSARecv` operations stand in for multishot
requests, and zero-byte receives keep idle connections from using up the provided
buffers. Accepts are posted last-in first-out, which can leave workers unevenly
loaded. The server listens on loopback by default, to avoid a firewall prompt;
explicit IPv4 and IPv6 addresses work. On teardown the port and its buffers stay
allocated, because cancelled operations can still complete into them.

Goose sees Linux `errno` values on every platform: macOS and Windows translate theirs,
and `net_strerror` gives the platform's text. A code with no Linux equivalent becomes
1000 plus the platform's code.

## The handler and its events

The parser enforces CRLF, HTTP/1.1's single `Host`, the framing rules, and
configurable head, body, and field limits. HTTP/1.1 keeps connections alive by
default; HTTP/1.0 does so only when the client asks. Pipelined requests are answered
in order, and their responses batched. `Server` and `Date` are rendered once a second
per worker.

Goose can't suspend or store a handler (§7.6), so a handler with state is called again
for each part of an exchange, with a flat value of the program's type kept in the
connection's slot. Bodies, streamed responses, upgrades, and answers that wait all
resume this way. The [event table](api.md#streaming) defines each call and what it
may do.

A whole-request handler gets a body that fits with its head in the read buffer. A
longer body needs a handler with state, which can copy it whole up to a limit with
`http::gather`, into a run of the worker's gather pool, `http::gathered`. The pool is
a slice pool that only a program that gathers has, and each worker's has a budget, the
bytes it may promise its runs at once. A body's run is promised its most at its head,
and refused there with 503, so a body admitted never fails later
([decision](decisions.md#the-gather-budget-counts-bytes-promised-and-refuses-at-admission)).
A WebSocket's run is promised only while it holds part of a message, and a message
the budget can't hold closes the connection with 1013
([decision](decisions.md#a-websocket-is-promised-its-bytes-while-it-holds-a-message)).
A Content-Length body's run is its exact size, placed at the head, and a chunked one
doubles up to its limit. The budget bounds the bytes promised, not the pool's length,
which fragmentation can take past it. A streamed response is asked for `MORE` only while its queued output
is below the write buffer's size on epoll, or `Config.max_queued` on the completion
loop. A whole response still occupies the worker's write buffer, which keeps the
pages its largest response touched.

A response sent before its request body ends drains the rest, up to
`Config.max_drain`, then closes. Under `Expect: 100-continue`, a body that fits gets
the interim response at once, and the handler may refuse a longer one first. Refusals
and timeouts send their response before shutting down and draining, so a reset
doesn't discard it. Head, body, write, and idle timeouts are separate, and a sweep
enforces them.

## Files and compression

`http::send_file` hands a file to the loop when the remaining response, with its
`Content-Length`, is at least 64 KB: `sendfile` on epoll and the emulated ring, splice
through a pipe on io_uring, and `TransmitFile` on IOCP. Smaller files, and chunked
responses, are read with `pread` in pieces, which costs less than a direct send for
small files ([measurements](results.md#static-files)). The loop closes a file handed
to it, including when the connection closes first. A handler that keeps a file
releases it at `CLOSED`.

`http::serve_cached` keeps files of up to 64 KB in the worker's memory, within a budget
the program gives, and checks each against the disk with a stat per request
([decision](decisions.md#a-program-can-keep-small-files-in-a-workers-cache-that-follows-the-disk)).

Precompressed files need no codec. Dynamic gzip, deflate, and zstd come from the
optional `http.compression` module, over goose-compress's encoders, which are Goose
and import nothing of HTTP. Negotiation and response framing stay in `http`, so a
program that doesn't import the module needs no codec. [TLS](#tls) is goose-tls's, in
the same way.

## WebSocket

The optional `http.websocket` module speaks RFC 6455 over `http::upgrade`'s raw bytes,
so the loops know nothing of it ([decisions](decisions.md#websocket-is-an-optional-module-over-upgrade)).
`ws_upgrade` checks the request with `ws_check` and writes the 101 with `ws_switch`, whose `Sec-WebSocket-Accept` is
the base64 of the key's SHA-1 from goose-hash, computed for each connection. A program
that doesn't import the module needs neither goose-hash nor its C.

`ws_read` hands each `BODY`'s bytes to `ws_take`, which reads the frames they complete
in one pass, unmasking each payload
onto the worker's data stack, so 16 frames that arrive together are 16 calls of the
program's block and one write. The fragments of a message, and after them a frame
split across reads, wait in one run of the worker's gather pool, held in the
`WebSocket` in the connection's state and freed when the message is whole or the
connection closes; an idle connection holds no buffer. A frame split across reads takes
from the next bytes only what it lacks, so the run never holds more than the message
and one frame: `WebSocket.limit` and 131 bytes, which the run is promised when it
first holds a byte and gives back when it's empty, or `ws_release` at the close.
A frame's head is checked
before its payload arrives, so a frame past `WebSocket.limit` closes the connection
with 1009 without being buffered. Text is checked as UTF-8 a fragment at a time, so bad
text in an early fragment fails the connection before the rest arrives; within one
frame, the check runs once the frame is whole. Pings get their pong, and a Close its
Close, inside `ws_take`, without the program. No extension is negotiated, and an
HTTP/2 stream has no WebSocket (RFC 8441). A TLS listener carries it as it carries any
upgraded bytes, so `wss://` needs nothing of its own.

## HTTP/2

HTTP/2 is being built in Goose, as modules of `http`
([decisions](decisions.md#http2-is-modules-of-http-written-in-goose)). Both loops
serve h2c, HTTP/2 with prior knowledge, on a listener with `Config.h2c` or a
`Listener`'s `h2c`, and h2 over TLS where ALPN chooses it ([TLS](#tls)): `h2.goose`'s
`h2_answer` takes such a connection's bytes in place of `answer`, with its state in
pools outside the connection's slot, and a stream per exchange. An idle h2 connection
is sent GOAWAY before it closes. It writes frames until its output reaches a limit the loop gives:
`Config.write_buffer` on epoll, and what `Config.max_queued` leaves on the completion
loop, which then stops receiving until a send completes. A completion port keeps one
accept, so on Windows `serve` takes one listener (`ring_listeners`). Two modules
beneath it work on bytes alone:

- `http.hpack` (`hpack.goose`) is HPACK (RFC 7541): integers, strings, the static
  table, a dynamic table with its size updates, and Huffman coding. A table is a flat
  value of 9 KB: entries' bytes in a buffer twice the 4,096-byte table size, so the
  live ones move to the front at most once per 4,096 bytes added, and a ring of up to
  128 entries. Huffman decoding goes four bits at a time through a table of 4,096
  steps that each worker builds from the code at startup. The decoder hands each field
  to a block, pointing into the field block, the table, or a scratch buffer, rather
  than build a list. The encoder takes a field whole from either table by index, and
  Huffman-codes a literal unless that would lengthen it.
- `http.h2frame` (`h2frame.goose`) parses and writes each frame type of RFC 9113 §6,
  with the connection preface and the settings. A parse returns the frame, its size,
  and what it breaks: nothing, a stream, or the connection. It keeps no state, so
  sequencing rules, such as CONTINUATION following its HEADERS, belong to the
  connection.

## TLS

Both loops serve HTTP/1.1 and h2 over TLS 1.3 on a listener with `Config.tls` or a
`Listener`'s `tls`, through [goose-tls](https://github.com/kaitk/goose-tls) and OpenSSL,
from the optional module `http.tls` (`tls.goose`)
([decisions](decisions.md#tls-is-goose-tls-reached-from-the-module-httptls)). On
Windows, `serve` fails with `ENOSYS` on a TLS listener.

The loops' code is `epoll_loop` and `ring_loop`, which take the listeners' TLS as an
untyped parameter: a `NoTls` from `serve_epoll(cfg, fresh)` or `serve(cfg, fresh)`, or
an `http::TlsServer` from `http.tls`'s `serve_epoll(cfg, fresh, server)` or
`serve(cfg, fresh, server)`. A `TlsServer` is a worker's: its reference to the context,
a 16 KB buffer the socket's bytes are read into, and a slot per TLS connection, which
`EpollConn.tls` or `RingConn.tls` names, -1 on a plain connection. A slot holds the
`tls::Conn`, whether its handshake is done, and whether close_notify is queued.
`TlsServer` is `TlsServerOf<OneContext>`; a `TlsServerOf<C>` also holds the
program's chooser, which `tls_plain` hands to the program's `tls_hello` when the
handshake pauses at the ClientHello (`tls::HELLO`), before it goes on
([decisions](decisions.md#the-program-chooses-a-connections-context-at-its-clienthello)).

Which driver answers a TLS connection, `answer` or `h2_answer`, is the ALPN's choice
([decisions](decisions.md#alpn-chooses-h2-over-tls)), which the loop asks for
(`tls_h2`) when the first plaintext arrives and keeps in the connection's `h2`: -2 for
HTTP/1.1, so later receives only compare. When the handshake chose h2, the loop
allocates the connection's h2 state, as accept does for h2c, before any of the
plaintext reaches `answer`: the epoll loop keeps the
preface, stops the connection's turn, and lists it for another (`go`), now through
`h2_answer`; the io_uring loop does it in `received`, so `feed` picks `pump_h2`. The h2
frames pass through the record layer as HTTP/1.1's bytes do. An idle h2 connection
is sent GOAWAY and close_notify after it; at a stop, close_notify follows the GOAWAY
once the connection's streams are done.

On the epoll loop, a TLS connection's bytes pass through its `tls::Conn` between the
socket and the worker's buffers, and everything above them is unchanged:

- **Reading.** `tls_recv` advances the handshake, then decrypts into the read buffer
  what OpenSSL holds before it reads the socket again, so an edge-triggered event is
  never lost to records already received. When the handshake has bytes to send, it
  returns 0, and the loop sends them before reading again.
- **Writing.** The handler's responses are plaintext in the write buffer; before each
  send, `tls_seal` encrypts what follows the bytes already sealed and puts the records
  in its place, with the handshake's flights, session tickets, and alerts. What the
  socket doesn't take waits in the connection's spill run, sealed, as a plain
  connection's does, so the write buffer's limits apply to the records.
- **Files** go through the record layer, read with `pread` in pieces: `sendfile` would
  bypass it.
- **Closing.** A connection that closes after its response (`Connection: close`, a
  refusal, a 408) queues close_notify behind it before shutting its side down, and
  `close_conn` sends one, or a failed handshake's alert, to a connection with nothing
  sealed still waiting. A client's close_notify ends the connection as a close does.
- **Timeouts.** A handshake has `Config.request_ms` from the accept, however it
  progresses; past it the sweep closes the connection, without a 408. After the
  handshake, the connection's timeouts are a plain connection's.

The io_uring loop does the same with the bytes its completions carry, and sends every
byte TLS makes through the ring, in order with the connection's other sends:

- **Reading.** A receive's ciphertext is copied out of its provided buffer and given
  to `tls_take`, which feeds it to OpenSSL and decrypts until OpenSSL wants more
  input, through the handshake first. The plaintext is answered as a plain
  connection's received bytes are, and then what OpenSSL has to send is queued.
- **Writing.** `flush` seals the write buffer in its place before it queues it, so
  the ring's copy and `Config.max_queued` count the records.
- **Files** are read with `pread` in pieces, rather than spliced.
- **Closing.** The ring's sockets block, so the loop never sends to one directly, and
  `ring_close` drops what is still queued. A connection that ends cleanly goes the way
  a refusal does instead: close_notify, or a failed handshake's alert, is queued, its
  side is shut down once it's sent, and the client has `Config.linger_ms` to close.
  That is how a client's close_notify, a failed handshake, an idle connection's
  timeout, and a stop end a TLS connection; one whose client closes the socket or
  resets it, or whose send fails, is closed at once.
- **Timeouts** are the epoll loop's.

The handshake and the record layer run in user space on every platform: kTLS is
retired ([decisions](decisions.md#no-ktls)).

## HTTP/3

A listener with `h3` serves HTTP/3 over QUIC on a UDP socket on its port, from the
optional module `http.h3` (`h3.goose`), over goose-tls's QUIC mode
([decisions](decisions.md#http3-is-an-optional-module-over-quic-in-goose)). Two
modules beneath it work on bytes alone, as h2's do: `http.quic` (`quic.goose`)
reads and writes QUIC's variable-length integers, packet headers, ACK frames, frames
the server writes, and transport parameters; `http.qpack` (`qpack.goose`) is QPACK
with the static table only, HPACK's integers and Huffman code under it.

The loops take the TLS and the HTTP/3 servers as one value, an `H3Pair`, in place of
the `TlsServer`, so a loop without h3 is the loop it was: its hooks for h3 are a
`NoTls`'s or a `TlsServer`'s, which do nothing, behind a constant `h3_serves`. With
h3, each listener's UDP socket is armed for readiness with `net_arm`, as an outbound
socket's is: on epoll an `EPOLLONESHOT` watch, on io_uring a one-shot poll. When it
fires, `h3_ready` takes up to 32 datagrams a call with `recvmmsg`, up to eight calls,
then arms it again; the loop's wait ends at the next QUIC timer (`h3_wait`), and
`h3_tick` runs the timers due.

Two layers:

- **The QUIC transport** keeps each worker's connections, streams, sent packets, and
  the bytes they send and receive in pools that are the worker's globals: a worker
  copies a program's globals, which may then hold no references, so a stream's bytes
  are a run of the worker's byte pool by its place, not a slice. A connection is found
  by the 8-byte Connection ID this side gave it, or by the client's first one until
  the client uses it. Its packets go through goose-tls, which removes and applies
  header protection and opens and seals each packet in place. ACKs, loss detection,
  the PTO, and NewReno are RFC 9002's, each connection's timer in a heap. Datagrams
  are at most 1,200 bytes until the connection's path MTU probe (RFC 8899), a PING
  padded to 1,452 bytes or the client's `max_udp_payload_size`, is acknowledged; the
  socket sets DF, so a path that can't carry it drops or refuses it, and a lost probe
  is no congestion. A flush lays packets out in those datagrams, ACK first, then
  frames this side owes, then CRYPTO, then the streams' data in turn, within the
  congestion window
  and, before the client's address is validated, three times what it sent; it seals
  them, records each packet's frames to send again if it's lost, and queues the
  datagrams, which go out together with `sendmmsg`.
- **HTTP/3** reads what each stream received: a request's HEADERS through QPACK into a
  `Request`, its DATA as the body, and the client's control and QPACK streams. It
  calls the handler as h2 does, a stream per exchange, and turns its HTTP/1.1
  response into HEADERS, through QPACK, and DATA frames on the stream. A response
  begun with `begin` gets `MORE` while its stream has less than 128 KB unsent. This
  side's control stream carries its SETTINGS, and GOAWAY when the worker stops or a
  handler ends its connection.

A request stream closes once its request is read, or stopped, and its response's end
is acknowledged, or reset; the client gets back its credit for streams as half of it
is spent. A connection idle for 30 seconds, or done closing, goes at its next timer,
after `CLOSED` to each exchange owed one.

## Mail between threads

A handler that waits for another thread calls `http::later`, which needs a time limit
and returns the exchange's address. The other thread sends its reply to that address
through the worker's bounded box, and the loop calls the handler with `WAKE`, or
with `TIMEOUT` when the limit expires.
[Mail between threads](patterns.md#mail-between-threads) shows the pattern, and the
API's [answers that wait](api.md#answers-that-wait) lists the calls.

Boxes are C because Goose has neither atomics nor a wait that another thread
can end. Goose's typed queues have no bound, let any thread receive, and can't wake
an event loop. A loop opens a box and a timer table only when `Config.mail_slots` and
`Config.max_waiting` are positive.

Each worker's box tracks the keys of exchanges that wait, in an atomic table of
`Config.max_conns` entries: 8 bytes each, 128 KiB at the default, of which a worker
commits only the pages its connections' keys reach. Its timer table adds a cell as a
wait needs one, up to `Config.max_waiting`, and keeps it, so a worker's waits cost what
its busiest moment held. `later` marks the
exchange's key live before it returns, so a reply can arrive before the handler
returns. The key stays live through `WAKE`, so a reply sent in pieces finds it live
between one piece and the handler's next `later`, and is cleared once the handler
answers or stops waiting, and before `TIMEOUT` and `CLOSED`.

A send never blocks: it returns `SENT`, `FULL`, `TOO_LONG`, or `STALE`, the last for
an exchange that no longer waits. `mail_live` checks whether the address is still live
without sending. A send that saw a key live just before it was cleared can still be
queued, so the loop checks each delivered key and drops a message no exchange waits for.

A lane (`lane.goose`) is Goose over boxes. `lane_open` opens a box per thread and
spawns the program's `thread_fn` with it, as `run` spawns workers, and keeps the boxes
and thread ids in a flat `Lane` of at most 64 of each. `lane_send` reads each box's
count with `mail_queued`, sends to the box that holds the fewest, and tries the others
in turn while each is full. Each send starts its scan one box further on, from a
counter per thread, so ties don't all go to one box.

A lane stops on a flag in its box, which `mail_stop` sets and then wakes the owner. A
stop sent as a message would need a free slot: to a full box at shutdown, the send
returns `FULL`, the stop is lost, and the lane waits forever. A send reads the flag after it raises
the table entry's senders count, and returns `STALE` once it's set, so a lane that
finds its box stopped and empty can close it without dropping a job sent after it
looked. `mail_stopped` closes the remaining gap, a send that read the flag before the
stop and hasn't yet queued its message: once the box is stopped and nothing is
pending, it waits, yielding, inside the shim until the senders count is 0, then reads
pending again. The count also covers `mail_live`, `mail_slot_size`, `mail_queued`, and
`STALE` sends, which finish at once, so the wait is short; returning `false` to the
lane instead made it spin at 100% CPU while workers polled the box. `mail_wait`
returns at once on a stopped box, so the lane's loop reaches `mail_stopped` again.

A waiting exchange holds back the requests after it, which must wait their turn. An
upgraded connection is a stream both ways, so the loops go on reading it, and the
bytes that arrive reach the handler as `BODY` while the wait stands, in the order they
reached the worker.

## Outbound connections

A program opens connections to other servers, such as a database, through
`socket.goose` ([decisions](decisions.md#outbound-connections-blocking-on-a-lane-readiness-on-the-workers-loop)).
Every such socket is non-blocking, made by `net_connect`, which starts the connect and
returns; `net_connected` reads how it ended from `SO_ERROR`.

On a thread that runs no loop, such as a lane's, `connect`, `recv` with a time limit,
and `send_all` wait on the socket with `poll` up to their limits, so the thread blocks
and the program's code reads top to bottom.

On `serve_epoll`'s loop, the worker that asked owns the socket. `wait_socket` adds it
to the worker's epoll instance or kqueue once, with the waiting exchange's key as the
event's tag, and calls `later`. The loop knows its sockets' tags from its connections'
by their range: a key is at least 2<sup>20</sup>, and a connection's slot below
`Config.max_conns`, which can't pass 2<sup>20</sup> where exchanges can wait. An event
with a key goes to the exchange through the path a message takes, as `WAKE` with the tag
`SOCKET_READY`, and the exchange's timer gives it `TIMEOUT` instead. The loop never
reads or writes the socket, and keeps no state for it: the handler does both, into
buffers of the program's, and a socket that's armed again after its event is modified,
not added. Closing the socket takes it off the poller. Each loop lists its poller in a
thread-local of the shim while it runs, which `net_arm` finds.

On `serve`'s io_uring ring, `ring_bind` lists the ring instead, and `net_arm` queues a
one-shot `IORING_OP_POLL_ADD`. The key stays in a record of the shim's, and the
completion comes with the tag `RING_SOCKET` and the record's index, on the path for
completions that match no connection. A wait that ends another way, an answer in the
call that waited, an h2 stream's reset or refusal while it waits, and a connection's
close cancel the poll, which would otherwise hold the socket open after the handler
hangs it up
([decisions](decisions.md#io_uring-cancels-a-sockets-poll-when-its-wait-ends)). The
exchange and h2 stream code, which every loop shares, cancels through `net_disarm`,
which does nothing on a thread that `ring_bind` didn't bind.
A thread with neither, such as one running the emulated ring or IOCP, gets `ENOSYS`.

## The store

`import http.store` gives a program byte blobs that one thread writes at startup and
every worker then reads, so data built once, such as a JSON catalog, isn't copied into
each worker. Writes must be ordered before reads by a queue, `thread_spawn`, or
`thread_wait`. A read copies a range into a Goose array, or returns a scalar or a
fixed-size record by value, because an `extern fn` can't return a view of C memory
(§7.10). What the bytes mean, and the responses built from
them, are Goose. [State that workers share](patterns.md#state-that-workers-share)
says when to use it.

## Logging and shutdown

`http::peer` asks for a connection's address when it's needed. A forwarded address is
used only when the peer is in the program's trusted networks. With `Config.log`,
`DONE` reports the status, bytes, and loop time of each exchange, measured to its
completion in the write buffer, not its delivery to the client.

`http::stop`, or a signal installed by `http::stop_on_signals`, advances a counter and
wakes every loop; a loop started after a stop runs normally. The loops close their
listeners and idle connections, add `Connection: close` to the next response on the
others, and return when drained or after `Config.grace_ms`.

## Background

Each part of the design has a precedent in the research literature, though none of
these papers describes the combination:

- **Thread-per-core, shared-nothing.** Enberg, Rao, and Tarkoma,
  [The Impact of Thread-Per-Core Architecture on Application Tail Latency](https://penberg.org/papers/tpc-ancs19.pdf)
  (ANCS 2019), build a key-value store with one epoll loop per core, `SO_REUSEPORT`,
  and bounded queues between threads. It lowers tail latency only while the threads
  neither synchronize nor block. It partitions data by key and forwards requests
  between workers; goose-http partitions by connection.
- **Blocking work off the loop.** Flash
  ([Pai, Druschel, Zwaenepoel](https://www.usenix.org/legacy/events/usenix99/full_papers/pai/pai.pdf),
  USENIX 1999) hands disk operations that could block to helper processes, and their
  completion reaches the loop as an event.
  [Half-Sync/Half-Async](https://www.dre.vanderbilt.edu/~schmidt/PDF/PLoP-95.pdf)
  (Schmidt and Cranor, PLoP 1995) names the split: an asynchronous layer for I/O,
  threads that run blocking code such as database queries, and a queue between them
  that discards messages rather than block the asynchronous side. Here that queue is a
  box addressed to one thread, not a layer any thread drains.
- **Bounded boxes.** [SEDA](https://doi.org/10.1145/502034.502057) (Welsh, Culler,
  Brewer, SOSP 2001) bounds the queue in front of each stage and answers with an error
  when it's full, which bounds response time under overload, as `FULL` and a 503 do here.
- **CPU-bound work in the handler.**
  [Shinjuku](https://www.usenix.org/conference/nsdi19/presentation/kaffes) (Kaffes et
  al., NSDI 2019) shows that run-to-completion on per-core queues, which is what a
  worker does, gives poor tail latency when service times vary widely: short requests
  wait behind long ones. Its fix, preemption every few microseconds through hardware
  virtualization, is beyond a portable server, so long work moves to a thread instead
  ([slow work](patterns.md#slow-work)).
