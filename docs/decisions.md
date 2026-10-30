# Decisions

The record for contributors and agents: each design decision, dated, with its reason,
what was rejected, and the task that measured it. How the package works now is in
[architecture](architecture.md); this page keeps why it came to work that way. Entries
run oldest first, and a later entry that replaces an earlier one says so.

## Goose unmodified

Decided 2026-10-10.

The package uses the pinned Goose checkout without modifying it. Compiler and stdlib
gaps that meet the reporting bar go to [Goose findings](goose-findings.md).

## Workers own their connections

Decided 2026-10-10, task 003.

The program spawns workers and passes each a flat `Config`. A `thread_fn` is compiled
as its own program and copies the non-static globals it uses (§11.2). Spawning stays
in the program because `thread_spawn` cannot take a `thread_fn` passed through a
package function. Each worker runs one loop and owns its connections for their
lifetime. Where workers are spawned was replaced on 2026-10-18 by
[the package spawns the workers](#the-package-spawns-the-workers).

## Connection slots and a spill pool

Decided 2026-10-10, task 009.

Connections live in a worker's `reusable` pool. A slot as the event tag avoids an
fd-indexed table growing to the highest fd across all workers. Read and write buffers
belong to the worker; incomplete requests and output that could not be sent go to a
spill pool. Full buffers in every slot were rejected for their memory cost.

## HTTP in Goose, syscalls in a C shim

Decided 2026-10-11, tasks 010 and 011.

HTTP parsing, routing, response building, loop state machines, messages between threads,
timers, and JSON are Goose. C in `shim/` wraps syscalls and kernel structures that
Goose cannot reach. The package sidecar, `http.build`, selects and compiles each
platform's C files; Goose code needs no conditional compilation.

## io_uring is the default loop on Linux

Decided 2026-10-11, task 005.

`http::serve` is the default on Linux. `http::serve_epoll` remains buildable and tested
as a lower-memory alternative. Linux is the benchmark platform; the
[current comparisons](benchmarks.md) record both wins and losses.

## The ring falls back to an emulation

Decided 2026-10-11, task 011.

Where `io_uring_setup` fails, the ring falls back to `shim/ring_epoll.c`: Docker's
default seccomp profile, disabled io_uring, or an older kernel. The same emulation
runs over kqueue on macOS. `Config.emulate_ring` selects it for tests;
`http::ring_probe()` reports why native io_uring is unavailable. The package does not
log the fallback; the benchmark server does.

## macOS over kqueue

Decided 2026-10-11, task 012.

On macOS, kqueue filters become poll flags. Events for one fd are merged within a
batch so a second event cannot drive a slot freed by the first. Workers share a
listener because separate `SO_REUSEPORT` listeners did not distribute connections.
An accept counter limits an already-ahead worker; a level-triggered listener keeps
declined connections available to others. Near the fd limit, a locked free-fd check
avoids macOS dropping a connection on `EMFILE`. Writability is watched only while
output waits for room.

## Linux error codes on every platform

Decided 2026-10-11, task 006.

Goose sees Linux errno values on every platform. Linux passes them through, macOS and
Windows translate, and `net_strerror` supplies platform text. An unmapped code becomes
1000 plus the platform code. The C shims own this mapping.

## A handler with state is called again

Decided 2026-10-12, task 013.

A handler with state is called again for each part of an exchange, with a flat value
of the program's type kept in the connection slot. Goose cannot suspend or store a
handler (§7.6), so this is how bodies, streamed responses, upgrades, and waiting
answers resume. The [event table](api.md#streaming) defines each call and its lifetime.

## The epoll loop bounds reads per turn

Decided 2026-10-12, task 021.

The epoll loop reads at most `Config.max_read` bytes from one connection per turn,
16 KB by default. A connection left readable goes on a deferred list because an
edge-triggered socket may raise no new event while its sender waits. This prevents
a sustained upload taking a worker for the entire body. Completion-loop latency
beside uploads remains open in task 026.

## Large io_uring sends go inline

Decided 2026-10-12, task 021.

The ring owns memory the kernel touches after a call returns. The shim copies sends
into its own buffers, and the loop copies receives out of provided buffers, because
an `extern fn` cannot retain a Goose argument (§7.10). A send of at least 64 KB with
nothing queued on its socket first tries synchronous `send(2)`; only unsent bytes
need a retained copy. Smaller sends stay asynchronous because a syscall per response
cost small REST responses throughput.

## Files of 64 KB or more go to the loop

Decided 2026-10-12, task 020.

`http::send_file` hands a file to the loop when the remaining `Content-Length`
response is at least 64 KB: `sendfile` on epoll and the emulated ring, splice through
a pipe on io_uring, and `TransmitFile` on IOCP. Smaller files and chunked responses
use `pread` in pieces. The threshold avoids direct-send overhead for small files; its
[measurement](results.md#static-files) and the remaining 64 KB gap to nginx are
recorded in task 024.

## Waiting through bounded boxes in C

Decided 2026-10-12, task 015.

Waiting uses bounded boxes, a fixed-capacity timer table, and generation-checked
handles, each independent of HTTP. Boxes are C because Goose has neither atomics
nor a wait another thread can end. Goose's typed queues have no bound, allow any
thread to receive, and cannot wake an event loop.

## The log measures the write buffer

Decided 2026-10-12, task 015.

With `Config.log`, `DONE` reports status, bytes, and elapsed loop time. It measures
completion in the write buffer, not delivery to the client, which the loop does not
track per response.

## The API isn't frozen

Decided 2026-10-13, task 027.

The API may change when an idiom improves clarity without costing speed or memory
beyond the benchmark runs' spread.

## Sends to an exchange that no longer waits are stale

Decided 2026-10-14, tasks 027 and 028.

Send checks the key atomically before claiming a queue slot and returns `STALE` for
an exchange that no longer waits. `mail_live` gives any thread the same snapshot
without sending. A send that read a live key before it was cleared can still be
queued; the loop checks each delivered key and drops messages that no longer match
a waiting exchange. Repeating `later` on the same exchange marks its key live again.
Send returns `SENT`, `FULL`, `TOO_LONG`, or `STALE` without blocking; senders can query
the slot size, or -1 for a stale address.

As first decided, both Goose loops cleared the key before `WAKE`, `TIMEOUT`, or
`CLOSED`, when a timer could not be armed, or when a handler answered instead of
waiting. The next entry replaces that for `WAKE`.

## A waiting key stays live through WAKE

Decided 2026-10-14. Replaces clearing the key before `WAKE`, in the entry above.

`later` marks the key before returning, so a reply from another thread can arrive
before the handler returns. The key stays live through a `WAKE` and is cleared after
the handler returns without waiting again, so a reply sent in pieces never finds it
stale between one piece and the handler's next `later`. It is cleared before
`TIMEOUT` and `CLOSED`, when a timer cannot be armed, and when a handler answers or
stops waiting instead of waiting. `Stream.live` records whether the key is marked, so
only an exchange that waited pays for an atomic write. This covers io_uring, epoll,
kqueue, and IOCP through their shared Goose paths.

## A store for read-only blobs

Decided 2026-10-14, task 025.

The store (`store.goose` over `shim/store.c`) holds byte blobs populated by one thread
and frozen before others read. Queues, `thread_spawn`, or `thread_wait` order writes
before reads. Reads copy ranges into Goose arrays because an `extern fn` cannot return
a view of C memory (§7.10). The data's meaning and response construction remain Goose.
The store imports nothing of HTTP and is reached through `import http.store`.

This avoids a copy per worker for JSON built at startup. Loading it from disk per
request was rejected: it would move memory out of RSS into the page cache and add a
syscall per response. Other REST records still cost a copy per worker.

## An upgraded connection is read while it waits

Decided 2026-10-15, task 038.

A waiting exchange holds back the bytes after it, since the next request must wait
its turn, except an upgraded one: its connection is a stream both ways, so the loops
go on reading it and `answer` hands what arrives to the handler as `BODY` while the
wait stands (`holds_input`). The wait still ends only with `WAKE`, `TIMEOUT`, `end`,
or `CLOSED`, so this adds no state, and the handler sees bytes and the reply in the
order they reached the worker.

## Tests follow Goose's convention

Decided 2026-10-15, task 041, for goose-http, goose-rest, and goose-compress alike.
Tests follow Goose's own convention, as the Goose repository's `test/` and
`docs/testing.md` lay it out:

- A top-level `test/` holds the tests, in a folder per area.
- Each test is a small program: a `main` with `assert`s, which prints what it checks.
  Its expected output is a golden file, `test/expected/<name>.out`, with
  `<name>.stderr` for lines its standard error must hold, and `<name>.aborts` for a
  test that must abort.
- A test that must not compile carries `// error: <substring>` comments.
- The repository's own runner, `test/run_tests.py` in Python as Goose's is, finds the
  tests, compiles them in batches with `goose --multi-test`, runs each as a process of
  its own and in parallel, and reports every failure without stopping at the first.
  No runner is shared between repositories, as none is with Goose's. In goose-http the
  batch is the typecheck, and `goose build` builds each test, since most tests link C
  that a sidecar names, the package's shim or the box's, which `goose build`
  compiles.
- Helpers the tests share are one imported module, not a copy in each test.

This replaces the test programs `scripts/test.sh` runs by name, where the first failed
`assert` ends a program and hides the rest. A test framework inside Goose was rejected:
Goose has no reflection to find tests, and checking by printing against a golden file
needs none. So were tests beside the code: Goose's compiler already leaves out of a
build what its root doesn't import, so a separate `test/` costs nothing, and it matches
the convention any reader of Goose's own repository knows.

## One name for each place data lives

Decided 2026-10-16, with goose-rest. A thread's queue of messages is a *box*
(`http::Box`), and a message reaches it *by mail*; the shared blobs are the *store*
(`http.store`); a global with a literal value, compiled into the program, is a
*constant*; and the thread that does one kind of slow work, which workers send jobs to
by mail, is a *lane*. These replace "mailbox", "shared store", "a global with a literal
initializer", and, in the slow-work pattern, "service thread" and "backend thread".
The request's state in `http::serve` keeps its name, and no API name changed.

Decided 2026-10-16, with goose-rest: work of minutes that the handler answers with
`202 Accepted`, and that the client then polls, is a *background task*, not a job. A
*job* is the work a handler mails a lane and waits for, as in goose-rest, where a
background task is made of jobs: one that starts it, and one for each poll.

## A crash ends the process, and a service manager restarts it

Decided 2026-10-16.

A crash in any thread, worker or lane, ends the whole process. The service manager
restarts it, with a delay and a limit on restarts in a row
([a crash ends the process](patterns.md#a-crash-ends-the-process)). The package has no
supervisor of its own.

Tina restarts one Isolate after a crash and keeps the rest of its shard running ("let it
crash"). Goose can't do this inside a process: an abort, such as an index out of bounds
or a failed `assert`, ends the program and can't be caught (spec §9.3). A thread can't
be restarted after it fails. Running each lane as a child process would give that
boundary, but it needs boxes and wakes that work across processes on Linux, macOS, and
Windows, and a second way to start the program on Windows, which has no `fork`. That
cost is rejected.

Kept 2026-10-19, task 050. With `thread_spawn_contained`
([aardappel/goose#38](https://github.com/aardappel/goose/pull/38)) in the pin, an abort
can end only its thread, and `http::run` restarting an aborted worker was built and
tested on Linux and macOS. It is kept on the branch `restart-workers`, an experiment not
pursued now: it added a
watcher thread per worker, two queues, C to close what the dead worker opened, and a
second mechanism for lanes, while the dead worker's connections still got no answer.
One finding stays for whoever picks it up: on Linux, a dead ring's io_uring multishot
accept keeps a closed listener in its `SO_REUSEPORT` group, and new connections hang
there, so shut the listener down before closing it.

Kept 2026-10-21, after a second look. Of the branch's costs, the watcher threads, both
queues, and closing the listener from another thread came from its design. The rest are
inherent in an abort that leaves C resources open. A dead worker's connections exist
only in its own Goose memory, so closing them needs each connection's owner recorded in
C at accept and close, which is code on the request path. Without that, their fds stay
open for good, since their idle timers died with the thread. Its ring's memory, its TLS
sessions, a lane's database handles, which keep a transaction's locks, and a box's
count, which `mail_adopt` had to settle, are left the same way. Erlang and Tina restart
inside the process because their runtimes own every resource a unit holds; Goose owns
only its memory. Several processes on one port give the smaller blast radius with no
code ([patterns](patterns.md#a-crash-ends-the-process)): on arm64 Docker, native
io_uring and epoll, two servers on port 29080 lost none of 400 new connections after
one was killed. Two findings stay for whoever picks restarts up:

- A pthread key's destructor runs on a contained worker's thread as it ends, whether it
  returned or aborted, on macOS and glibc. It can close what that thread opened and
  tell `main` which worker ended, with no watcher thread or queue. It must keep its
  state in the key's record: `_Thread_local` values read -1 there on macOS. Windows'
  `FlsAlloc` callback is the likely counterpart, untested.
- Lanes would still need a thread that can name their `thread_fn`: the Goose change on
  the fork's `thread-fn-values`, or a wrapper each program writes.

## A stop is a flag in the box, not a message

Decided 2026-10-17, task 044; `mail_stopped`'s wait, 2026-10-18.

`http::mail_stop(box)` sets a flag in the box and wakes its owner, and
`http::mail_stopped(box)` is true once the box is stopped and empty. A `STOP` message
needs a free slot: to a full box at shutdown, its send returns `FULL`, the stop is
lost, and the lane waits forever, which goose-rest's lanes did. Tina reserves part of
its message pool for shutdown, timers, and restarts for that reason; a flag needs no
reserve, since traffic can't crowd it out. A send to a stopped box returns `STALE`, so
a lane that finds its box stopped and empty can close it without dropping a job sent
after. `mail_stopped` waits, yielding in the shim, for the sends in
flight across the stop, since returning `false` to a lane whose box workers were
polling made it spin at 100% CPU. The cost is one more load of the flag on every send,
a locked instruction under MSVC (task 047).

## No .env loader

Decided 2026-10-18, task 046.

`http::env_load`, which put a development `.env` file into the environment through the
placement file's line reader, since removed, was built and dropped. No program called it, and in
production systemd's `EnvironmentFile` and Compose's `env_file` already load one into
the environment that `env` reads.

## The package spawns the workers

Decided 2026-10-18, task 048; the worker's index went with placement on 2026-10-19.
Replaces the spawning in [workers own their connections](#workers-own-their-connections).

`http::run(cfg, worker)` spawns the workers, with up to two values of the program's
between `cfg` and the worker, and returns once every one has returned. Goose
`fb5698125` lets a generic function spawn the `thread_fn` its caller binds, which made
this possible; before it, every program wrote the same spawn loop. Goose has no
variadic parameters, so `run` has an overload for each count of values; two cover
every program in goose-http and goose-rest. The worker comes last, as Goose passes a
function value after a call's other arguments. `http::lane_open` spawns a lane's
threads the same way.

A program that picks the loop for its workers at run time, such as `server/app.goose`,
calls `run` once per choice (2026-10-18). Only a program that must interleave spawning
with other work, such as the REST benchmark servers with their startup handshake, keeps
its own spawn loop.

## Placement is removed until it is measured to help

Decided 2026-10-19, after an independent review; replaces the placement entries of
2026-10-17 and 2026-10-18, which the branch keeps.

Placement, a file per kind of machine that mapped the workers' and each lane's role to
cores, a priority, and `SO_INCOMING_CPU`, with `Config.place`, `Config.role`,
`Config.worker`, seats, `place.goose`, and `shim/place.c`, is off `main`, parked on the
branch `placement` in goose-http and goose-rest. It was never measured to help: on an M1 Pro no layout beat
the OS's own (task 045), and a `low` lane lost about 40% of its rate. It returns only
when bare-metal Linux measures a gain beyond the runs' spread, and then invisible to
programs: the library reads the file, or `GOOSE_PLACE`, and applies it inside `run`
and `lane_open`, with no seat or role in a program's code. A porter from Hono, Elysia,
or Axum shouldn't learn a concept that buys nothing measured.

## Placement stays off main after bare-metal Linux

Decided 2026-10-21, task 045; settles the condition the entry above set.

On a Ryzen 5 9600X under Bazzite 43, no layout beat the floating default on /fast's p99
beyond the runs' spread, at either rate (task 045, "On bare-metal Linux"): pinned
workers, a pinned lane, a lane on a worker's SMT sibling, a lane kept within a set,
`SO_INCOMING_CPU`, and a low-priority lane all went. Leaving a hardware thread free
(`fewer`) was worse at the higher rate. Placement stays on the branch `placement` and
off `main`. The runs measured lightly loaded workers, since oha couldn't load the
server further; a case for placement would need a client that can, and a gain there.

## Lanes are goose-http's, and the one way to a pool

Decided 2026-10-19, after an independent review, with goose-rest.

`http::Lane`, `lane_open`, `lane`, `lane_send`, and `lane_stop` moved here from
goose-rest's `rest::lane`, so that goose-http's own programs and goose-rest's open,
run, and stop a lane the same way, whether it has one thread or several. A lane is the
one mechanism for threads that do slow work: the typed-queue pool of task 051 and
goose-rest's `ask_by`, which sent one key's jobs to one thread, went, so each thing is
done one way. `LaneConfig` keeps only `threads`, `slots`, and `size`. A thread that does
its own timed work between jobs, as `server/backend.goose` and goose-rest's reports
tutorial do, writes the four-line loop that `lane` is; a timed `lane` would add a
concept for two programs. `mail_queued` stays for `lane_send`, outside the user docs.

## Without waiting configured, later gets TIMEOUT at once

Decided 2026-10-19, task 043.

With `Config.mail_slots` or `Config.max_waiting` at 0, `later` finds no timer cell, and
its exchange gets `TIMEOUT` on the loop's next pass, as one past `max_waiting` does. The
loops drain their owed timeouts whether or not they have a box, and every connection's
address has a key of its own, so the `TIMEOUT` reaches the exchange that asked. This
matches what the docs said of a full timer table, and lets a handler that waits run,
degraded, on a server that turns waiting off. Refusing `later` without the configuration
was rejected: a handler would need a second path for the same outcome, which a
`TIMEOUT` already gives it.

## HTTP/2 is modules of http, written in Goose

Decided 2026-10-19, task 014.

HTTP/2 lives in this repository as modules of the `http` package: HPACK in
`hpack.goose` (`http.hpack`) and the frames in `h2frame.goose` (`http.h2frame`), on
bytes alone, and later the connection state, flow control, and stream scheduler beside
the loops. Framing, HPACK, flow control, and scheduling are HTTP: they share the
parser's field rules, the response builders, and the `Date`, and they change the event
loop itself. Goose has no runtime function pointers (spec §7.6), so a separate package
would reach the loop through function values anyway. Like the HTTP/1.1 parser, it is
Goose, since measuring Goose is the point: HPACK and the framing are bounded,
table-driven byte work, 1,500 to 3,000 lines in other implementations.

Rejected: h2 as its own package, which couples to the loop through function values and
duplicates its types; and binding nghttp2, as Aegon does, which leads HttpArena's h2c
profiles (goose-rest's task 048). nghttp2 calls back into the program for each frame
and field, and a C library that calls back into Goose doesn't fit the loop: an `export
fn` must be called on the thread that called `goose_init` (spec §7.11), not a worker.
It would also put protocol work in C, where the shim holds only what Goose can't reach.
The cost is writing and testing what nghttp2 already has, against h2spec. Where TLS
lives is [its own entry](#tls-is-goose-tls-reached-from-the-module-httptls).

## A loop takes several listeners, each with its own mode

Decided 2026-10-19, task 014.01.

A loop listens on `Config.port` and on each of `Config.listeners`, and each listener
has a mode: HTTP/1.1, or h2c with prior knowledge, whose connections must open with
the preface. There is no detection of the preface on an HTTP/1.1 listener. HttpArena
serves 8080 and 8082 from one container, and calling `http::run` once per port would
run twice the worker threads on the same CPUs, which distorts the comparison; TLS on
8081 and 8443 will need several listeners too. The cost is an accept path that goes
over several listeners in each loop.

The names were agreed on 2026-10-19: `Config.h2c` for `Config.port`'s mode,
`Config.listeners`, a list of `Listener { port, h2c }`, and the HTTP/2 settings
`Config.h2_max_streams`, `Config.h2_stream_window`, and `Config.h2_conn_window`.

## h2 serves the handlers' HTTP/1.1 responses, translated

Decided 2026-10-19, task 014.01.

A handler on an h2 stream writes its response with the writers it uses for HTTP/1.1,
and the h2 driver turns the head into a HEADERS frame and the body into DATA. The API
and the writers stay as they are, for a parse of a head the package just wrote. Writers
that emit HPACK themselves for an h2 `Reply` are to be built only if a measurement
shows the translation matters.

The measurement did (2026-10-19): on HttpArena's baseline-h2c, the translation took
16-17% of the server's samples beyond HPACK's own encoding, so it was made cheaper
instead, and a cache of the last head's block per connection comes next. The writers
stay an option, looked at only if a large share remains after the cache: each writer
would gain an h2 branch, and a head that `begin` holds open can't be encoded as it's
written (task 014.01, answers 10 and 11).

## An h2 connection's state is outside its slot

Decided 2026-10-19, task 014.01.

An h2c connection's HPACK tables, settings, windows, and streams are in pools of their
own, and each connection slot holds an `i32` index into the first, -1 for HTTP/1.1. An
HTTP/1.1 connection grows by those 4 bytes and nothing more; a dictionary from slot to
index would have saved them for a lookup per event on h2 connections.

## An h2 stream is an exchange

Decided 2026-10-19, task 014.01.

Each stream is one exchange with its own state, called with the events an HTTP/1.1
exchange gets. A stream's body comes as HTTP/1.1's does: whole at REQUEST when it
fits in the read buffer, else in pieces, so the route chooses between gathering it and
reading it in pieces as before. `later`'s key gives its low 20 bits, an HTTP/1.1
exchange's number, to the stream's index in the stream pool, and the 24 bits of
generation to the stream, so a reply finds its stream and no other. A stream that
waits holds back no other stream.

## TLS is goose-tls, reached from the module http.tls

Decided 2026-10-19, task 014.

TLS is [goose-tls](https://github.com/kaitk/goose-tls), a package of its own: a Goose
API over OpenSSL 3 with opaque handles, whose connections take the bytes the program
read and give back the bytes to send. `http`
imports it only from its module `http.tls` (`tls.goose`), so only a program that
imports `http.tls` declares goose-tls in its root file and builds with OpenSSL and
CMake; `test/http/no_tls.goose` builds without it, and `test/tls/undeclared.goose`
checks that one importing `http.tls` must declare it. This package adds no C for TLS:
the C over OpenSSL, the exception to "C is for what Goose can't reach", stays in
goose-tls, and the crypto, the record layer, and X.509 are OpenSSL's, not Goose.

The loops reach TLS without importing it. `epoll_loop` and `ring_loop` take the TLS of
their listeners as an untyped parameter, and call `tls_open`, `tls_recv` (`tls_take` on
the ring), `tls_seal`, and the rest on it; Goose checks a generic body per
instantiation and resolves the calls in the namespace `http`, so `serve_epoll` or
`serve` without TLS passes a `NoTls`, whose stubs are never
called, and `http.tls` adds a `TlsServer` and its own overloads. No function pointer is
needed, and a program without TLS compiles none of it.

Rejected: TLS in this repository, which would make every program link OpenSSL; TLS
written in Goose, which constant-time crypto and X.509 put out of scope; and, among C libraries,
BoringSSL (no stable API or releases), rustls-ffi (a Rust toolchain in the build), and
BearSSL (TLS 1.2 at most, where HttpArena checks for 1.3). goose-tls's own
[decisions](https://github.com/kaitk/goose-tls/blob/main/docs/decisions.md) record
those in full. The cost: a program serving HTTPS needs CMake and OpenSSL's headers to
build, and its libraries to run.

## TLS is a listener's mode

Decided 2026-10-19, task 014.02.

A listener serves HTTP/1.1, h2c, or HTTP/1.1 over TLS, as `Config.tls` or a
`Listener`'s `tls` says, beside the others in one loop, as
[several listeners](#a-loop-takes-several-listeners-each-with-its-own-mode) decided:
HttpArena serves 8080, 8081 (TLS), and 8082 (h2c) from one container. The context
comes to the loop apart from `Config`, which can't name goose-tls's types: the program
makes one `tls::Context` and gives each worker an `http::TlsServer`
(`http::tls_server(ctx)`), passed to `serve_epoll(cfg, server)` or
`serve_epoll(cfg, fresh, server)`, and since 2026-10-20 to `serve` the same way. ALPN
chooses nothing yet: a TLS listener serves
HTTP/1.1, and TLS on an h2c listener is refused with `EINVAL` until h2 over TLS
(task 014's phase 5).

The names were agreed on 2026-10-19: `Config.tls` and `Listener.tls`,
`http::TlsServer`, `http::tls_server(ctx)`, `http::release(server)`, and
`serve_epoll(cfg, server)` and `serve_epoll(cfg, fresh, server)`, the server last. A
`serve_tls` of its own was the other shape, which would need another name again for
io_uring. The benchmark server serves TLS on its port + 1 (`TLS_PORT`), only when
`TLS_CERT` and `TLS_KEY` are set.

## No kTLS

Decided 2026-10-22, with goose-tls's task 007.

The loops keep every TLS connection's record layer in user space. goose-tls retires
kTLS, its `tls::use_kernel` and the calls after it, and goose-http drops what used
them: the switch in `tls_recv`, the receive of the kernel's non-data records, the
close_notify sent as an alert record, the shim's `recvmsg` and `sendmsg` for them, and
the benchmark server's `KTLS=1`. On the Ryzen 5 9600X, kTLS served small `/json`
responses about 10% faster but 16 KB ones 44% slower (task 014.02), and it needed a
second path through the epoll loop that the io_uring loop never took. It replaces
"kTLS is the context's choice, made by the program" (2026-10-20). goose-tls's
decisions record the reasons in full.

## HttpArena's entry uses the Rust entries' key exchange

Decided 2026-10-20, task 058.

The benchmark server takes `TLS_GROUPS` for goose-tls's `tls::use_groups`, and
HttpArena's entry sets it to `X25519:P-256:P-384`, what the Rust entries' rustls with
the `ring` provider offers. Without it, OpenSSL 3.5's default puts X25519MLKEM768
first, which the Rust entries don't negotiate, and which costs each connection about
6 KB more and each handshake more bytes. The server's default, and any program's,
stays OpenSSL's: post-quantum is right for a real server. Rejected: changing the
default for everyone to match a benchmark.

## The benchmark server's TLS is a build of its own

Decided 2026-10-20, task 055, replacing the epoll benchmark server as the one build
that serves TLS. `server/server_epoll.goose` serves no TLS, as `server/server.goose`
doesn't, and `server/server_tls.goose`, built with `scripts/build.sh`'s `TLS=1`, is the
epoll server with the TLS listener; since the io_uring loop serves TLS (2026-10-20,
task 014.02), it serves the listener on that loop too with `LOOP=uring` at run time.
Linking goose-tls maps libcrypto, libssl, and their libz and libzstd at startup, 2.3 MB of resident pages that the epoll server's peak RSS
carried on every benchmark, with no TLS listener (1012e705: 3.6 → 6.0 MB). HttpArena's
image holds both builds and starts the TLS one only when HttpArena mounts a certificate,
so the one container still serves 8080, 8081, and 8082 together, as the entry above
decided. `scripts/test.sh` tests the epoll and io_uring loops with the TLS build, so
the listener stays tested. Rejected: loading OpenSSL only once `Config.tls` is set,
which is goose-tls's to do, with `dlopen` behind its calls; and keeping one build, whose plaintext cells
carried OpenSSL's pages.

## WebSocket is an optional module over upgrade

Decided 2026-10-19, task 054. Replaces the README's status of WebSocket as out of scope,
which no entry here recorded.

WebSocket (RFC 6455) is in scope, as the optional module `http.websocket`
(`websocket.goose`), on the upgrade that already hands a connection's bytes to the
handler as `BODY`. HttpArena scores three echo profiles on a board of their own, and
framing is bounded byte work of the parser's kind, so it is Goose, as HTTP/2's is. It
needs no change to the loops: the frames are read in the handler's `BODY` calls, a
frame not yet whole and a fragmented message wait in runs of the worker's `gather`
pool, and a WebSocket's state is a flat `http::WebSocket` in the request's state. The
handshake's SHA-1 comes from goose-hash `v0.0.2`, whose C runs it on the CPU's SHA
instructions with a Goose fallback. The module declares goose-hash as `http.compression`
declares goose-compress, so only a program that imports the module declares it in its
root file and links its C; a program without WebSocket builds as before.

The handshake is computed for each connection, as HttpArena's rules require; nothing
is cached. Pings, pongs, and the close handshake are handled inside `ws_read`; the
program sees whole text and binary messages, sends with `ws_send`, and starts a close
with `ws_close`. Text is checked as UTF-8, as RFC 6455 requires of an endpoint. The API
was agreed on 2026-10-19: the `ws_` names, `ws_upgrade(req, out)` taking no state, and
its optional subprotocol parameter.

Rejected: a package of its own, which would reach `Reply`'s stream and the gather pool
from outside, as h2 would have; a C library such as wslay, which would put protocol
work in C; and computing SHA-1 in this package, which goose-hash already tests against
RFC 6455's example. Left out for now: extensions, permessage-deflate among them, which
Autobahn's sections 12 and 13 test; WebSocket over HTTP/2 (RFC 8441); and a strict
UTF-8 check of a single frame before it is whole, which Autobahn scores NON-STRICT in
cases 6.4.3 and 6.4.4.

## Outbound connections: blocking on a lane, readiness on the worker's loop

Decided 2026-10-19, task 053; the names and `ENOSYS` on `serve` were agreed on
2026-10-19.

A program opens TCP or Unix-socket connections to other servers through
`socket.goose`, in two ways, for the two places goose-postgres's decisions run database
work:

- **Blocking, on a thread that runs no loop.** A lane job that runs several queries
  calls `http::connect(host, port, ms)`, `http::send_all(s, bytes, ms)`, and
  `http::recv(s, buf, ms)`, each of which waits up to its time limit, and
  `http::hangup(s)`. This is the transport goose-postgres's blocking facade takes.
- **Non-blocking, on `serve_epoll`'s loop.** A handler starts a connect with
  `http::connect_start`, and `http::wait_socket(out, s, events, ms)` makes its exchange wait
  until the socket is readable or writable, as `later` waits for mail: the handler is
  called with `WAKE`, tag `http::SOCKET_READY`, or `TIMEOUT`. It then reads and writes
  with `http::recv(s, buf)` and `http::send(s, bytes)`, which never block, and learns how
  a connect ended with `http::connected(s)`. This is what goose-postgres's pool for
  HttpArena's `/async-db` builds on, one connection's bytes at a time.

One socket type serves both: a non-blocking fd, which the blocking calls wait on with
`poll`. The C is four thin functions per platform (`net_connect`, `net_connected`,
`net_poll`, and `net_arm`), beside the listener's; Goose's stdlib has no sockets.

**The worker that asked owns the socket.** `wait_socket` adds it to that worker's own
epoll instance or kqueue, with the waiting exchange's key as its tag, once
(`EPOLLONESHOT`, `EV_ONESHOT`), and the loop hands the event to the exchange through the
path mail takes, which finds an h2 stream as it finds an HTTP/1.1 exchange. A query
then never crosses threads, which is the point of the worker's loop for single queries;
a lane that held one pool for every worker would add two queue hops to each query, which
goose-postgres's decisions reject for `/async-db`. The cost: each worker holds its own
share of a pool, `DATABASE_MAX_CONN` divided by the workers, and an idle connection on
one worker can't serve another's request.

**Readiness, not bytes.** The loop tells the handler that the socket is ready, and the
program reads into its own buffers, such as `pg::Conn`'s input, rather than the loop
reading into the worker's buffers and handing bytes over as events, as it does for
accepted connections. The protocol packages own their buffers already; the loop copies
nothing and holds nothing for a connection, so an idle pooled connection costs one fd,
and bytes that arrive while no exchange waits wait in the kernel, not in a buffer of the
loop's that someone must drain. The cost is the readiness pattern's: a `WAKE` may find
nothing to read, so a handler treats `SOCKET_READY` as "try again".

**Where it doesn't run yet.** The emulated ring and IOCP (`ConnectEx`) fail
`wait_socket` with `ENOSYS`, and the exchange doesn't wait; io_uring runs it with a
one-shot poll (2026-10-22, [io_uring cancels a socket's poll when its wait
ends](#io_uring-cancels-a-sockets-poll-when-its-wait-ends)). The failure comes at the
call, not at startup as for an h2c or TLS listener, since `serve` can't know whether a
handler will call `wait_socket`. The blocking calls work on every platform, Windows included, where a Unix socket
is `EAFNOSUPPORT`.

**Names, in the blocking `connect` only (2026-10-22).** `http::connect` resolves a
name with `getaddrinfo` in the shim, and tries its addresses in the resolver's order
within the call's time limit: a lane may block, and goose-acme's requests to Let's
Encrypt's directory need a name. `connect_start` still fails a name with `ENOSYS` from
`resolve`, since `getaddrinfo` would block the loop. This replaces "a host is
`localhost`, a literal, or `unix:PATH`" for the blocking call. The time limit doesn't
cover the lookup, which `getaddrinfo` can't bound; the system resolver's own timeouts
apply. Rejected for now: a resolver for the loop, on a lane or with a DNS client of its
own, which waits until a handler needs a name; and Happy Eyeballs, racing IPv6 against
IPv4, for a call a lane makes once per connection.

Rejected: a lane that holds every worker's pool (above); the loop reading outbound
sockets as it reads accepted ones (above); a blocking socket with `SO_RCVTIMEO` and
`SO_SNDTIMEO`, which has no time limit for the connect; and a socket module separate
from the loops, which the worker's half needs anyway.

## An HTTP client is an optional module over the blocking socket

Decided 2026-10-22.

`http.client` makes HTTP/1.1 requests, plain or over goose-tls's client TLS, over
the blocking `connect`, `send_all`, and `recv`. It's here because goose-http already
holds what a client needs: the socket and its resolver, and the HTTP/1.1 parts a
response reuses (`line_end`, `trailer_end`, and `field_at` for its fields,
`chunked_len` and `dechunk` for a chunked body). As `http.tls` does, it costs a
program that doesn't import it nothing, and only one that does needs goose-tls.
goose-rest's client and goose-acme's `https.goose` each wrote half of it; both use this
one instead.

- It blocks, with a limit on each wait, so it runs on a lane or in a program without a
  loop. A client for a handler on the loop would drive `connect_start` and
  `wait_socket` across `WAKE`s, which needs a state machine Goose can't hide behind
  one call; it waits until a handler needs it, as the loop's resolver does.
- A session keeps one connection and reuses it for the same scheme, host, and port. It
  checks with a recv that doesn't wait whether the server has closed the connection,
  rather than send a request again after a failure, which could repeat a POST.
- A request's block adds to it through calls that take `req`, so the request's buffers
  stay the call's own. Its failures are `http::Error`s, `call` naming the step.

Rejected: a client in goose-rest, which uses nothing of goose-rest's and would leave
goose-acme with its own; and a package of its own, which adds a repository to every
pin move of goose-tls and goose-http, for code that needs goose-http's parts.

## Every convenience is a composition of public parts

Decided 2026-10-22, task 059.

A function that decides and acts in one call, such as a check that writes its own
refusal, is a convenience over public parts that a program can call on their own: a
check returns its verdict, and a separate function writes the response; a protocol
function takes the bytes and fields it reads, not a whole `http::Event`; and a resource
a worker keeps, such as the pool that `http::gather` fills, is one a program can reach.
The convenience stays, as a short composition of its parts, so a direct user writes
what it wrote before.

Programs and frameworks built on goose-http compose these parts. A framework answers
in its own error shape, keeps its handler's inputs in a context of its own rather than
an `Event`, and holds its buffers where its other buffers are. Where only the composite
is public, it has to wrap the composite, fake the composite's inputs, or rebuild it. A
rebuilt part drifts from the original, and its buffers sit in a second arena beside the
package's.

A part leaves the request path's cost as it is: a split that adds instructions to a
request doesn't land, as for every idiom ([the API isn't
frozen](#the-api-isnt-frozen), task 027). Breaking changes cost least before v0.5.0
is tagged.

Rejected: keeping only composites and adding a parameter to each for the cases a
caller needs, such as a flag that suppresses a refusal or a callback that writes it,
which grows every composite and still hides its parts; and hooks a framework registers
with the package, which Goose's function values, which can't be stored (spec §7.6),
don't allow.

## The gather budget counts bytes promised, and refuses at admission

Decided 2026-10-22, task 059. Replaces, of [WebSocket is an optional module over
upgrade](#websocket-is-an-optional-module-over-upgrade), `ws_upgrade(req, out)` taking
no state, and runs that nothing bounded.

What a handler holds past its call, a gathered body and a WebSocket's frames not yet
read, is in runs of each worker's pool, `http::gathered`, under a budget: the most
bytes the pool may promise its runs at once, 64 MiB per worker unless
`http::gather_budget` sets another. There is always a budget, and every run is under
it. A budget is a promise: a run is promised the most bytes it may ever take when it
is admitted, and refused there, where a refusal has an answer. It never grows past
that promise, so nothing admitted fails for lack of room later.

- **A body is admitted at its head.** `http::gather_head` promises the rebuilt head and
  the body: a Content-Length's exact size, in a run placed whole then, which never grows
  or moves; or a chunked body's limit, in a run that doubles from 16 KB as it fills, up
  to that. A body the budget can't hold gets 503 with `Retry-After: 1` from `gather`,
  and the connection closes rather than drain the body under memory pressure.
- **A WebSocket is admitted at its upgrade.** `http::ws_admit` promises its limit and
  131 bytes: a message nearly at the limit and a control frame not yet whole after it,
  in one run, since a frame not yet whole takes only the bytes it lacks. A connection
  that doesn't fit gets 503 with `Retry-After: 1` from `ws_upgrade`, and the connection
  stays open, as no body follows. `WebSocket.limit`'s default went from 1 MiB to
  64 KiB, so the default budget admits about a thousand connections per worker rather
  than 63. Replaced on 2026-10-24 by
  [a WebSocket is promised its bytes while it holds a message](#a-websocket-is-promised-its-bytes-while-it-holds-a-message).
- **The parts are public**: `gather_budget`, `gather_promise`, `gather_piece`,
  `gather_clear`, `release_gather`, `gather_head`, and `ws_admit`. A framework answers a
  refusal in its own shape and keeps its own runs in the same pool, under the same
  budget.
- **The budget is per worker, set by a function**, `gather_budget(bytes)`, in `main`
  before `run`, which each worker copies at spawn, or in a worker before its loop. A
  `Config` field would be read by code the loop doesn't call, and a budget passed to
  each call, as goose-rest's `Budget&` is now, is the program's to thread through.
- **A program that never gathers has no pool.** Its workers' globals don't copy it,
  and nothing on the request path reads it. Main's globals still hold the pool's empty
  header and the budget's three numbers, as Goose initializes every module's globals
  there.
- **The loops' own spill stays apart.** A connection's held bytes and queued output are
  the loop's, which a handler can't reach without a field in `Reply`.

The trade-off: the budget bounds the bytes the runs are promised, not the pool's
length, which the worker keeps for its life. A freed run leaves a gap that a larger
run can't use, so the length can pass the budget by what fragmentation leaves free.

Rejected: a budget on the pool's length, as goose-rest's `Budget` is. A length can be
checked only when a run is placed, so it can't hold a promise of growth not yet
placed: a chunked body or a WebSocket's message would be refused partway, after the
client had sent part of it. And it needs a mirror of the runs in use that predicts
where `alloc_slice` puts the next one (spec §5.4), a scan of every run for each run
placed, which repeats the pool's own hidden search. Counting both the length and the
promises needs the mirror still. Also rejected: a count of the bytes in use, which
grants a growth when it comes and so refuses it then; and a budget of 0 for none, which
leaves a program's runs bounded only by `Config.max_conns` times its limits. A Goose
slice pool that reported its free spans, or allocated within a bound and failed
otherwise, would let the length be bounded too.

## io_uring cancels a socket's poll when its wait ends

Decided 2026-10-22, task 053.

On io_uring, `wait_socket` queues a one-shot `IORING_OP_POLL_ADD` for the waiting
exchange's key, and the loop hands its completion to the exchange as epoll's event,
`WAKE` with `SOCKET_READY`. The connect stays `connect_start`'s non-blocking one, which
the poll then waits on for writable, as epoll does. `IORING_OP_CONNECT` would need a
second `connect_start` for the ring and a second kind of completion to route, where
the poll needs neither.

When the wait ends another way, by `TIMEOUT`, by mail, by another socket's readiness,
or with its connection's close, the loop cancels the poll (`ring_disarm`), and the
shim marks its record stale, so a completion already in the queue is dropped. The
cancel, not a stale mark alone, is what's needed: an io_uring poll holds a reference to
the socket, so a socket the handler hangs up at `TIMEOUT` would stay open, and its
peer, such as a database waiting for a query, would never see the close. The stale
mark covers the completion that arrived before the cancel. Epoll needs neither: closing
the socket removes it from the poller. epoll and kqueue keep the trap that task 053
records, a `WAKE` in the exchange's next wait.

A wait can also end in the code that every loop shares: an answer in the call that
waited, over HTTP/1.1 or h2, or an h2 stream's reset or 413 (2026-10-22). That code
calls `net_disarm(key)`, which only a thread that `ring_bind` bound points at its
ring's cancel; elsewhere it does nothing. An exchange's key has its own number, and a
stream's its own generation, so on epoll and kqueue the event after the wait ends
matches no later wait. The shim's thread-local, which `net_arm` already uses, spares
that code a parameter for one loop's need. Only an exchange that waits makes the call.

The key takes all 64 bits, more than a ring tag's 62, so the shim keeps it in a record
and the completion carries the record's index, under the tag `RING_SOCKET`, which no
connection has. That completion is read only on the path for completions that match no
connection, and the shim tells it from receives and sends by the bit it already tests
for cancels, so the request path costs nothing more. Each wait that ends, and each
connection's close, makes one call, which returns at once when nothing is armed.

Rejected: a stale mark alone, which keeps a hung-up socket open; and a generation per
wait in the tag, for which the key has no bits left.

## ALPN chooses h2 over TLS

Decided 2026-10-22, task 061. Replaces [TLS is a listener's
mode](#tls-is-a-listeners-mode)'s "ALPN chooses nothing yet".

A TLS listener serves h2 or HTTP/1.1, as the handshake's ALPN chose: h2 where the
context's protocols list `h2` and the client offered it, HTTP/1.1 otherwise. The
program decides by the list it gives goose-tls (`["h2", "http/1.1"]`), and goose-http
adds no name. The loops choose the driver when the first plaintext arrives after the
handshake, before the HTTP/1.1 parser sees it: the h2 driver's connection state is
allocated then, as accept allocates it for h2c, and the h2 frames run over the record
layer unchanged. An HTTP/1.1 connection over TLS pays one `tls::alpn` call, at its
first plaintext, and a compare per receive after it, since the loop keeps the answer
in the connection's `h2` (-2) rather than ask per receive: asking goose-tls each time
cost 31 instructions a request. A plaintext program, whose loops take `NoTls`, pays
nothing (task 061 has the counts). TLS on an h2c listener is still refused with
`EINVAL`: h2c is h2 by prior knowledge, over TCP.

An idle h2 connection, over TLS or not, is sent GOAWAY before it closes (RFC 9113
§9.1), and over TLS close_notify after it, on both loops, as a stop already did. It
then lingers as a refusal does.

Rejected: a `Listener.h2` flag. ALPN is the context's, and a loop has one context for
all its TLS listeners, so a flag could disagree with what the handshake advertised. A
program that wants h2 on one port and only `http/1.1` on another runs a second set of
workers with a second context. A context per listener would need a new name in the
API.

## The benchmark server offers h2 on both TLS ports

Decided 2026-10-22, task 061. Replaces that task's decision 2, which kept h2 over TLS
to 8443 and ALPN `http/1.1` alone on 8081.

The benchmark server's TLS listeners, HttpArena's 8081 and 8443, share one context
that offers `["h2", "http/1.1"]`, served by one set of workers. Keeping 8081 at
`http/1.1` alone took a second context, and with it a second set of workers, idle in
every TLS profile: about 2.7 MB of resident memory per worker, 170 MB on a server with
64. HttpArena's pages ask for `http/1.1` alone on 8081, but its validation allows
`h2` there, and the load tool of its 8081 profiles (json-tls, static-tls, 8gbit), wrk,
offers no ALPN, so those profiles still measure HTTP/1.1.

Rejected: a context per listener, which would need a new name in goose-http's API for
one benchmark's ports.

## The program chooses a connection's context at its ClientHello

Decided 2026-10-22, for goose-acme's task 001. Narrows [ALPN chooses h2 over
TLS](#alpn-chooses-h2-over-tls)'s "a loop has one context for all its TLS listeners":
a connection still starts from that context, and the program may move it.

ACME's TLS-ALPN-01 (RFC 8737) answers a client that sends the challenged name in SNI
and offers ALPN `acme-tls/1` with a challenge certificate, and every other client
with the server's, on the same port; a renewed certificate reaches new connections
while open ones keep theirs. goose-tls has the parts: `tls::choose_context(ctx)` pauses
each handshake after the ClientHello with `tls::HELLO`, and `tls::server_name`,
`tls::offers`, and `tls::use_context` read the hello and move the connection. So
goose-http adds only the place where the program's code runs at that pause:

- `http::TlsServerOf<C>`, a worker's TLS server that holds a program value, the
  chooser, made by `http::tls_server(ctx, chooser)`. `http::TlsServer` is
  `TlsServerOf<OneContext>`, so `http::tls_server(ctx)` and code that names
  `TlsServer` are unchanged.
- At `tls::HELLO`, the handshake calls `http::tls_hello(chooser, conn)`, which the
  program declares in the namespace `http` for its chooser's type, as goose-acme's
  programs declare `acme::challenge_start`, then goes on. The program calls
  `tls::choose_context(ctx)` once, before the workers start, since a context must be
  set to choose before it accepts.
- The chooser is the worker's, and changes only through `tls_hello`: a challenge or a
  renewal reaches it as the program arranges, such as mail the chooser takes at the
  next hello.

A one-context program pays nothing per request: the check for `tls::HELLO` sits where
the handshake is advanced, which a connection leaves once its handshake is done, and
`OneContext`'s `tls_hello` is empty. The chooser sits after the buffer, since an empty
struct takes a byte, and ahead of the other fields it moved them, which changed
clang's loads of them. On macOS (clang, the TLS benchmark server), what this adds is
the handshake's check and its second call, and nothing else; gcc's count on Linux,
with valgrind as task 061 counted, is still to take. `serve(cfg, server)` and
`serve_epoll(cfg, server)`, the forms without `fresh`, take only a `TlsServer`: with a
generic server, Goose finds them as generic as `serve(cfg, fresh)`, and a call is
ambiguous. A program with a chooser passes `fresh`.

Rejected: a chooser passed to `serve` as a function value, which Goose can't store,
and which each loop would pass down to the handshake; a hello event for the handler,
a new `Event` kind on the request path; a context per listener, which can't tell an
ACME client from a browser on port 443; and making `TlsServer` itself generic, which
would make every program that names it, such as goose-rest's `rest.tls`, write a type
parameter.

## Upgraded streams can request output drain notifications

Accepted 2026-10-23; task 063. `after_drain` and `DRAINED` let a publisher keep one
bounded batch in flight per upgraded connection. The pending bit is a `Framing`
variant, so ordinary HTTP connections gain no fields or queue storage. Both loops
deliver the event after their queued output reaches the socket; connection failure
cancels it through the existing `CLOSED` event. Plain HTTP costs +0.1 user
instructions per request on the emulated ring and +0.3 on epoll (task 063).

A general `try_send` admission API would need output accounting exposed to every
handler, and retry storage in the application. A drain credit lets the publisher
retain the next message instead. This is opt-in producer flow control, not a
hard limit on handlers that continue sending without waiting for a credit.

Rejected: `MORE` for upgraded connections, which every WebSocket handler would get
after each message, a call each, and which closes a connection whose handler sends
nothing there; and holding a slow subscriber's mail in the worker's box, with `FULL`
for the publisher, which lets one subscriber fill the box for every other connection.
Server-Sent Events already have their credit in `MORE`.

## io_uring cancels a closing connection's requests by their tags

Decided 2026-10-23. Replaces `ring_close`'s cancel of every request on the fd, which
the io_uring loop has queued since it was added, unrecorded.

A connection's socket can have two requests in the kernel when it closes: its
multishot receive, while the loop's `reading` says one is queued, and the one send in
flight, whose record the shim keeps as its fd's first. Its other requests, a TLS
connection's and an upgraded one's included, are sends queued behind that one, which
the shim drops. Sockets that `wait_socket` armed are other fds, which
`ring_disarm` cancels ([io_uring cancels a socket's poll when its wait
ends](#io_uring-cancels-a-sockets-poll-when-its-wait-ends)). `ring_close` now takes the
receive's tag, or 0 for none, and cancels the receive by it and the send by its
record's address, then closes the socket.

The cancels are still needed: a queued request holds the socket, so a connection the
server closes, with its receive armed or a send that its client doesn't take, would
otherwise stay open, and its client would never see the close (`http_client.py`'s
`slow`). Stale completions don't need them: the tag's generation and the fd's
generation in the shim already drop those.

The kernel serves a cancel by fd by walking every bucket of the ring's poll table,
where a cancel by user_data looks in one. On a Linux laptop under HttpArena's
limited-conn profile, 10 requests per connection over 4,096 connections, that walk was
9.9% of a server's samples. There the client closes first, so its receive has usually
ended and the server queues no cancel at all.

The close is no longer hard-linked behind the cancel: a cancel by fd needed the fd
open, and one by user_data doesn't. A file's send cancelled in its splice into its pipe
closes the pipe rather than keep it, since the pipe may hold the piece.

Rejected: a cancel by tag of the receive alone, which leaves a send to a client that
doesn't read holding the socket open; and the shim tracking whether each fd's receive
is queued, which needs the fd on the completion path, where the loop already knows.

### Bodies from 256 bytes are compressed

Decided 2026-10-23, task 022.

`http::Compression`'s `min_size` is 256 bytes, down from 1,024. gzip at level 1 saves
bytes on the wire from about 160 to 192 bytes of JSON on: below that, its 18 bytes of
header and trailer and the 24-byte `Content-Encoding: gzip` line outweigh what it
saves. Measured on prefixes of HttpArena's `/json/50` body and its `dataset.json`, with
goose-compress `v0.1.4`: at 256 bytes, compressing saves 36 and 56 bytes; at 512, 216
and 245; at 128, it costs 23 and 11. At 1,024, an 888-byte JSON answer such as
`/json/5?m=7` went out raw where Aegon's gzip sends 385 bytes. HttpArena's json-comp
no longer asks for it: its harness at `3717e25` sends `/json/25`, `/json/40`, and
`/json/50` only, so the change leaves that benchmark's bytes as they were. nginx's default
`gzip_min_length` is 20 bytes, and Aegon's json-comp entry compresses from 64.

The trade-off: a body of 256 to 1,023 bytes now costs a compression call, a few µs at
level 1.

## Timers fall due by the precise monotonic clock

Decided 2026-10-24, task 065. Replaces the coarse clocks that `net_clock_ms` read
since the shim was written (task 002), on Linux and macOS.

`net_clock_ms` is the loops' clock: each pass reads it once, and their timers, request
deadlines, and idle sweep count by it. It read `CLOCK_MONOTONIC_COARSE` on Linux, the
time of the last scheduler tick, and `CLOCK_MONOTONIC_RAW_APPROX` on macOS, the value
at the last context switch. Up to 4 ms stale at `HZ=250`, it made a waiting answer
late twice: the wait counted from a start that had already passed, and on waking the
stale clock could say the timer wasn't due yet. On a Ryzen 7 5800X3D under WSL2
(kernel 6.18.54.1, `HZ=250`), goose-http's server with 8 workers and `/delay/10` under
wrk at 64 connections answered at a median of 12.2 ms on both loops; with
`CLOCK_MONOTONIC`, at 10.2 ms, p99 10.5 ms. HttpArena's async profile is closed-loop
on `/delay/10` at 32,000 connections, so its rate is the connections over that time.

`CLOCK_MONOTONIC` and macOS's `CLOCK_MONOTONIC_RAW` are read without a syscall: on that
machine 20.9 ns a read against the coarse clock's 4.3 ns, 17 ns more per pass. The wall clock that the `Date` field reads
once a pass, in whole seconds, stays coarse. Windows' `GetTickCount64` is unchanged:
its completion port's waits are in milliseconds at the system timer's resolution
anyway.

Rejected: a second, precise clock for the timers alone, beside the coarse one for
deadlines, which would read two clocks a pass to save 17 ns; and nanosecond waits
(`epoll_pwait2`, as viltrum v1.5.1 uses), which help only deadlines finer than a
millisecond, and `later` takes milliseconds.

## 64 provided buffers a ring

Decided 2026-10-24, task 065. Replaces task 005's 256.

io_uring takes a ring's provided buffers in ring order, and the loop gives each back at
the tail, so every buffer is written within a few hundred receives: a worker commits
`ring_buffers` × `ring_buffer_size` whatever its connections, 1 MiB at 256. At
HttpArena's 64 workers that was 64 MiB of a server's memory at any load.

Measured on the machine of the entry above, goose-http's server at 256, 128, and 64
buffers, otherwise the same build:

- `bench/count.sh`, one worker, 10 million plaintext requests, two rounds: 1,924.6
  user instructions a request for each, and 472 to 484 cycles, within the rounds'
  spread.
- `bench/run.sh`, plaintext pipelined 16 deep at 256, 1,024, and 4,096 connections and
  JSON at 1,024, 1 and 4 workers, one 5 s run each: every cell at 64 within 0.99 to 1.04
  times 256's rate, but JSON at 1 worker, 1.11. Peak RSS fell by 0.4 MiB a worker at 4
  workers and by 1.3 to 1.4 MiB at 1.

The cost is on Windows. IOCP and the emulated ring keep their free buffers on a stack,
so they commit only the buffers in use, and IOCP keeps a receive posted into a buffer
only while more than half are free (task 017). With 64, more receives take its
zero-byte path: oha, 1,000,000 plaintext requests at 256 connections, three
alternating rounds, served 74,446 to 75,459 a second at 1 worker against 256's 79,100
to 81,059, and 217,723 to 221,202 at 4 workers against 222,543 to 226,265.

Rejected: a default for each platform, 64 on io_uring and 256 elsewhere, which adds a
platform rule to `Config` for a loop that serves development, not production; a
program on Windows that wants the rate sets `ring_buffers` itself.

## A WebSocket is promised its bytes while it holds a message

Decided 2026-10-24, task 066. Replaces, of [the gather budget counts bytes promised,
and refuses at admission](#the-gather-budget-counts-bytes-promised-and-refuses-at-admission),
a WebSocket admitted at its upgrade.

A WebSocket's run holds bytes only for a message in fragments or a frame split across
reads; a frame that arrives whole is read from the read buffer. Promising its limit at
the upgrade, for the connection's life, bounded a worker's WebSockets by a worst case
that nearly never happens at once: at the defaults, 1,021 a worker. A laptop's or
desktop's few workers refused HttpArena's echo-ws at 16,384 connections: on 4 workers,
1,824 messages a second, the rest of the connections refused with 503 and reconnecting
(Plod's task 061).

Now `ws_take` promises the run `limit` and 131 bytes when it first holds a byte, and
gives the promise back when the run is empty: when the message is whole, or the split
frame is. A message the budget can't promise closes the connection with 1013 (Try
Again Later) in a Close, RFC 6455's code for a server that is overloaded, since after
the upgrade there is no status to answer with. `ws_upgrade` no longer answers 503, and
`ws_admit` is gone.

Nothing admitted still fails partway through a message: the promise is the whole limit,
taken before the message's first byte is held. What changes is where a refusal comes:
at a message rather than at the upgrade, so a client that sends a long message in
fragments while the worker's budget is spent is closed then, where before it would have
been refused at its upgrade. That is the trade the earlier decision rejected for a
body, whose refusal partway has no answer; a WebSocket's has 1013.

Rejected: keeping `ws_admit` beside the new default, for a program that would rather
refuse at the upgrade, which needs a field in `WebSocket` to keep an admitted
connection's promise when its run empties, and which no program here uses; and raising
the default budget, which only moves the cap.

## HTTP/3 is an optional module, over QUIC in Goose

Decided 2026-10-24, task 067.

HTTP/3 costs more CPU per request than h2, so a program has it only where it asks:
the module `http.h3`, and `Listener.h3` (`Config.h3` for `Config.port`'s) on a TLS
listener, which serves h3 on a UDP socket on the same port. goose-http adds no
`Alt-Svc`; a program that wants browsers to find h3 sends it. A program without the
module builds as it did, and its loops' hooks for h3 are empty.

- **QUIC is written in Goose, here**: packets, frames, streams, flow control, and
  RFC 9002's loss recovery and NewReno, with HTTP/3 and QPACK with the static table
  only. goose-tls's TLS 1.3 server in Goose runs QUIC's handshake in a mode of its
  own, and does the packet protection in its C over libcrypto, where its secrets stay
  (goose-tls's decisions).
- **`Listener.h3` is a flag, beside `h2c` and `tls`.** [ALPN chooses h2 over
  TLS](#alpn-chooses-h2-over-tls) rejected a `Listener.h2` flag because ALPN picks
  between h1 and h2 on a socket the client has reached; h3 is another socket, which
  the client reaches before any ALPN, and the flag gives one listener h3 and another
  none from one context, as HttpArena's entries need 8443 to have it and 8081 not. The
  context's ALPN list must still offer `h3`.
- **The loops take the TLS and HTTP/3 servers as one value**, `H3Pair`, through the
  generic parameter that takes a `TlsServer`, so the loops' code for h3 is behind a
  constant `h3_serves` and costs a program without it nothing.
- **The transport's state is the worker's globals**, its byte runs by place: a
  `Goose` worker copies globals, which may hold no references (spec §11.2), and
  scratch the layers clear is each call's locals, since a global that shrank could
  leave a reference the layers were handed dangling (§5.1).

Rejected: ngtcp2 and nghttp3 through C, as Aegon uses them. They would bring a QUIC
in C for what Goose can do, and a second TLS handshake beside goose-tls's, and
HttpArena's board (`d9438f6`, 2026-10-23) shows them no faster: Aegon's 2.98 M
requests per second on baseline-h3 behind zix's 9.09 M and agensio's 8.63 M, each with a
QUIC of its own. And ALPN alone turning h3 on, which opens UDP on every TLS listener of
a context.

## C where Goose blocks a measured cost, until Goose has a way

Decided 2026-10-24, task 067. Amends [HTTP in Goose, syscalls in a C
shim](#http-in-goose-syscalls-in-a-c-shim).

Where Goose has no way to do something at the speed a profile shows it needs, and no
clear Goose workaround exists, a thin C function in `shim/` does it, the gap goes in
[findings](goose-findings.md) and to Goose's maintainer, and the C goes once a Goose
release has the way. The first is `net_move`, `memmove` for HTTP/3's byte copies: at
Goose's default `-O2`, static-h3 spent 44% of its user instructions in `copy_into`'s
byte loops, and answered 31% more requests a second without them. At `-O3`, where gcc
vectorizes the loop, `memmove` is still 1.3% ahead. HTTP itself stays Goose.

Rejected: reworking HTTP/3's buffers so its copies are `append`s, which goes against
the globals that only grow (above) and changes the stream buffers throughout; and
waiting for Goose, with static-h3 bound by copies meanwhile.

## A program can keep small files in a worker's cache that follows the disk

Decided 2026-10-24, Plod's task 062.

`http::serve_cached` serves files as `open_precompressed` and `serve_file` do, from a
cache that each worker keeps:

- The program chooses it at the call that serves a route, with a byte budget. A
  program that never calls it has no cache: the cache is the worker's globals in
  `file.goose`, which only the workers that use them copy.
- It holds files of at most `FILE_PIECE` (64 KB), and sends a cached file whole in the
  request's turn. A response then holds nothing of the cache after its turn, so a file
  replaced meanwhile needs no count of readers, and a response holds no more than
  `send_file`'s one piece. Larger files are read from the disk as before.
- It follows the disk. Each request stats the file, and each copy it tries, in place of
  opening them, and compares the chosen file's size, modification time to the
  nanosecond, and inode with what the cache read. A change reads the file again. The
  inode catches a file replaced by `rename` at the same length and second, and one put
  back with its old time, as HttpArena's staleness probe does both.
- `.br`, `.zst`, and `.gz` copies are files of their own in the cache, chosen as
  `open_precompressed` chooses them.
- A file that doesn't fit what is left of the budget is served from the disk. Nothing
  is evicted, and the cache isn't freed: a file's entry keeps its path, and is read
  into again when the file changes.

Why: on static-h2, the opens, `fstat`s, `pread`s, and closes of each request cost more
kernel time than the response's sends (Plod's task 062). The cache cuts the kernel's
cycles a request from 57 K to 29 K, and answers 60% more requests a second. On
HTTP/1.1 over TLS and on HTTP/3 it gains 18% and 13%, where the sends cost more.

Costs: each worker holds its own copy, since workers share nothing. HttpArena's
requests reach 19 files, 258 KB, so 16.5 MB at 64 workers, and its entry's budget of
1 MiB bounds that at 64 MiB. A stat per file tried still costs a path walk: about 2.25
a request on HttpArena's files, 6 K to 17 K kernel cycles a request more than serving
from memory with no check. An in-place rewrite at the same size, within one tick of
the file system's clock, isn't seen; a replacement by `rename` is.

Rejected: a cache filled once and never checked, which HttpArena's rules and its
staleness probe refuse; checking only the chosen copy, which would keep serving a
stale `.br` after its original is replaced; caching larger files, which needs a count
of the responses still reading a file, since Goose frees memory only at scope exit;
and `inotify`, which is Linux only and adds a descriptor and events to each worker's
loop.

## Shared blobs carry one message to many workers

Decided 2026-10-28, for Campfire's cable fan-out.

A program that sends one message to many connections on several workers can put it in a
shared blob (`shared.goose`, `shim/shared.c`) and mail each worker its handle instead of
the bytes. A blob is a refcounted, immutable byte string in one process-wide table;
`send_shared` copies a range of it into the connection's output.

- The bytes cross threads once, not once per worker, and a box's slots hold handles, so
  they stay small whatever the message's size.
- A handle is a slot and a generation, as `handle.goose`'s: the last release advances
  the generation, so a stale or forged handle is refused rather than read. Each slot
  packs its generation and count in one atomic word, so a retain or release is one
  compare-and-swap, and a lookup takes no lock; the table grows in chunks that never
  move.
- A program that never calls `shared_put` pays nothing: the table is empty and nothing
  on the request path looks at it.

Why: Campfire's broker copied each publication into every reader's delivery mail. With
the body put once and described by handle, its 64-reader fan-out rose from 1,905 to
2,871 messages a second, and CPU per message fell 40%, together with two changes of its
own that coalesce frames (once-campfire-goose `9542706`, M1, Docker's arm64 VM, 3 rotated
rounds).

Rejected: copying into each worker's box, which sizes every slot for the largest message;
and a pointer with no generation, which a use after the last release reads.

## Shared blobs' free list behind a mutex, not a spinlock

Shared blobs (`shim/shared.c`) are found through a slot table whose lookups take no lock;
only the free list does, for a few instructions at a put and at a last release. That lock
is the platform's mutex, as `mail.c`'s. Uncontended, a mutex and a spinlock each cost one
atomic. Contended, a program often runs more threads than cores (Campfire runs four
workers, its broker and a checkpointer on four CPUs), and a spinning waiter whose holder
was preempted burns its whole time slice; a new chunk's `calloc` and page faults, once
per 4096 slots, also run under the lock. A mutex sleeps instead.

Rejected: a bare spinlock (the first version); and a spinlock with `pause`, a bounded
spin then a yield, and chunks allocated outside the lock, which keeps a fast path no
profile asked for, at a couple of lock operations per published message.

## Shared ranges go out from their blobs

Decided 2026-10-28, for Campfire's cable fan-out.

`send_shared` on a plain socket doesn't copy the range into the output. The loop records
it, retained, at its offset in the write buffer, and sends the buffer and the ranges
together: one `sendmsg` of up to 64 runs on epoll, and a ring send that holds the
ranges' references until its completion, or the connection's close, on io_uring and
the emulated ring. Only what the socket doesn't take is copied, into the connection's
pending output, as before.

- The loop names its write buffer when it gathers, and `shared_defer` defers only into
  that buffer: a handler that builds a `Reply` around a buffer of its own, as Campfire
  does for a deferred POST, gets the range copied there. h2 and TLS output, which go
  through other buffers or need contiguous plaintext, copy.
- Deferred bytes count toward `Config.write_buffer` before each body piece and `MORE`,
  so a handler that defers at each `MORE` is flushed as one that copies is.
- Gathering is on only while a loop drives a connection, and every range is settled or
  handed to a ring send before the turn ends, so none outlives its connection.
- Traffic that never calls `send_shared` pays a thread-local load before each body piece
  and `MORE`, and the epoll loop's `shared_pending` checks around a send.

Why: each of Campfire's readers copied every message body into its output. Sent from the
blob, its 64-reader fan-out rose 19% with 11% less CPU per message (M1, Docker's arm64 VM,
3 rotated rounds), and with its per-worker delivery 4,177 against 3,796 messages a second.

Rejected: deferring into any `Reply`'s buffer by offset, the first version, which put the
ranges in the loop's output at another buffer's offsets when a handler's buffer wasn't
the loop's. `MSG_ZEROCOPY` wasn't tried.

## A worker has an address of its own, and wakes its exchanges locally

Decided 2026-10-28, for Campfire's cable fan-out; local wakes go right after the
worker's mail since 2026-10-29.

A worker's box has one key past its connections' slots, `worker_address()`, whose mail
calls the handler with `WORKER`. `wake(to, tag)` from the worker that owns `to` queues
the wake in the loop instead of the box, and the loop delivers it once the call that
asked returns, right after the worker's mail or at the end of the pass.

- A publisher mails each worker once, not one exchange per worker chosen to stand for
  it, so nothing has to hand that role on when the exchange ends.
- A wake to one's own exchange needs no slot, so the box is sized for the publisher's
  mail alone. It is checked as a send is, against the live key, and the loop checks
  the whole key again when it delivers.
- Programs that never call `wake` pay a length check per pass.

Why: Campfire's broker had mailed one representative connection per worker, which
then kicked the others through the box. With worker addresses and local wakes, and
the empty-socket recv skip, its 2,000-reader saturated fan-out rose 11% with 7% less
CPU per message, and the box shrank from 2,048 slots to 512. Delivering the wakes
right after the mail cut its 64-reader delivery p99 from 8.26 to 4.14 ms (5800X3D,
once-campfire-goose `a62f2f8` and `d1e12a1`).

Rejected: waking through `mail_send` to one's own box, which needs a slot per wake;
and delivering wakes only at the end of a pass, which left them behind every other
event in it.

## Not yet decided

### Compression in an optional module

Implemented, with no recorded approval; task 022.

Precompressed files need no codec. Dynamic compression is implemented in the optional
`http.compression` module using goose-compress's gzip, deflate, and zstd encoders. Negotiation and response framing stay in `http`; codecs import nothing of
HTTP. Programs without the module need no codec dependency. Compression remains part
of measuring Goose; TLS crypto is outside this project's scope. Task 022 retains the
split's unrecorded approval and remaining validation.
