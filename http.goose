// goose-http: an HTTP/1.1 server for Goose programs, with an event loop per
// worker and nothing shared between workers. A program calls one of two
// loops from a thread_fn of its own, with its handler:
//
//   http::serve(cfg) { req, body, out => ... }        io_uring on Linux, IOCP on Windows,
//                                                      emulated over kqueue on macOS
//   http::serve_epoll(cfg) { req, body, out => ... }  epoll on Linux, kqueue on macOS
//
// The handler gets the parsed request (Request, message.goose), its body, and
// a Reply to write one whole response into. Goose compiles a generic function
// only where it's called, so the loop a program doesn't call isn't in it.
//
// For bodies and responses of any size, each loop also takes a handler that
// it calls again for each piece of the exchange (Event), with state of the
// program's own type that starts each request as fresh:
//
//   http::serve(cfg, fresh) { ev, st, out => ... }
//   http::serve_epoll(cfg, fresh) { ev, st, out => ... }
namespace http;

import std;
import os;
import message;
import sys;
import ring;
import epoll;
import uring;
import router;
import file;
import media;
import shared;
import cookie;
import auth;
import form;
import forwarded;
import timers;
import mail;
import lane;
import socket;

// A listener beside Config.port's, at Config.address: its port, and whether
// it serves h2c, HTTP/2 with prior knowledge (h2.goose), or HTTP/1.1 over
// TLS (http.tls), rather than HTTP/1.1; and with h3, HTTP/3 over QUIC on a
// UDP socket on the same port too (http.h3), which needs tls.
struct Listener {
    port: i32 = 0,
    h2c: bool = false,
    tls: bool = false,
    h3: bool = false,
}

// The most listeners a loop takes beside Config.port's.
let MAX_LISTENERS = 3;

// The server's settings. Each worker gets a copy, as thread_spawn copies
// flat values.
struct Config {
    // Where to listen: an IPv4 address, an IPv6 one, bare or in brackets,
    // "::" for every address, IPv6 and, unless ipv6_only, IPv4, or
    // "unix:PATH" for a Unix socket at PATH, on Linux and macOS. Empty is
    // every IPv4 address (127.0.0.1 on Windows).
    address: u8[..112] = "",
    ipv6_only: bool = false,
    port: i32 = 8080,
    // Whether port's listener serves h2c or TLS rather than HTTP/1.1, and
    // the listeners beside it, each with its own port and mode. TLS needs
    // the module http.tls and the loops' forms that take a TlsServer. On
    // Windows, serve takes one listener (ring_listeners), and fails with
    // ENOSYS on more, and on a TLS listener so far.
    h2c: bool = false,
    tls: bool = false,
    // Whether port's listener serves HTTP/3 too, as Listener.h3 says. It
    // needs the module http.h3 and the loops' forms that take an H3Server.
    h3: bool = false,
    listeners: Listener[..MAX_LISTENERS] = [],
    // HTTP/2: the most streams a client may have open on a connection, up to
    // 256 (SETTINGS_MAX_CONCURRENT_STREAMS), and what it may send before a
    // WINDOW_UPDATE on each stream and on the connection.
    h2_max_streams: i64 = 128,
    h2_stream_window: i64 = 65535,
    h2_conn_window: i64 = 1048576,
    // 0 for one per hardware thread, or on macOS one per performance core
    // (worker_count).
    workers: i64 = 0,
    backlog: i32 = 4096,
    // The most connections one worker holds. The default lets one worker take
    // TechEmpower's largest run, 16,384 connections, alone.
    max_conns: i64 = 16384,
    // The longest request head, and the size of a worker's read buffer, which
    // holds one whole. A body that fits in it with its head goes to the
    // handler whole; a longer one in pieces, or dropped as it arrives.
    max_head: i64 = MAX_HEAD,
    // The longest body a request may have; a longer one is refused with 413.
    max_body: i64 = MAX_BODY,
    // The longest request line, past which a request is refused with 414,
    // and the most header fields, past which with 431.
    max_line: i64 = MAX_LINE,
    max_fields: i64 = MAX_FIELDS,
    // The most bytes of a body the handler answered without reading that
    // the connection drops to stay open; past them, it closes.
    max_drain: i64 = MAX_BODY,
    // The most requests one connection may make, the last of which is
    // answered with Connection: close; 0 for no limit.
    max_requests: i64 = 0,
    // A worker's write buffer grows to hold any response whole. Past this
    // many bytes, the worker sends what it holds before it answers more: the
    // default takes the responses to a read's worth of pipelined requests, as
    // 16 TechEmpower responses are about 2 KB.
    write_buffer: i64 = 8192,
    // In milliseconds of the monotonic clock. A request head has request_ms
    // from its first byte to arrive whole. A body that comes in pieces has
    // body_ms between them, and a response write_ms to move on once the
    // client stops taking it. A connection gets 408 or is closed past them.
    // An idle keep-alive connection closes after idle_ms. A refused
    // connection has linger_ms for the client to read the refusal and close.
    request_ms: i64 = 10000,
    body_ms: i64 = 10000,
    write_ms: i64 = 10000,
    idle_ms: i64 = 60000,
    linger_ms: i64 = 2000,
    // The Server field's value, or empty for no Server field.
    server: u8[..64] = "goose",
    // After stop, how long a loop goes on with the requests in progress
    // before it closes their connections and returns.
    grace_ms: i64 = 10000,
    // serve's ring: its submission entries, and its provided buffers, which
    // the kernel fills in turn, a power of two of them. A receive that finds
    // none left ends its multishot request, which the loop queues again. The
    // loop gives each buffer back in the pass that takes it. io_uring takes
    // the buffers in ring order, so a worker commits every one of them
    // whatever its load; 64 served as fast as 256 and 1,024 (tasks 005 and
    // 065).
    ring_entries: i32 = 4096,
    ring_buffers: i32 = 64,
    ring_buffer_size: i32 = 4096,
    // On Linux, serve's ring is the emulation over epoll it falls back to
    // where io_uring_setup fails, as in Docker's default seccomp profile: for
    // testing that fallback.
    emulate_ring: bool = false,
    // serve fails with call "io_uring" where it would emulate the ring:
    // where io_uring_setup fails on Linux, and always on macOS. Windows'
    // completion port is its own. So a run that meant to measure io_uring
    // can't end up on epoll unnoticed.
    require_ring: bool = false,
    // The bytes of responses a serve connection may have queued and not yet
    // sent, its send in flight's too. Past this, the loop stops reading from
    // it until the client takes what it was sent, as serve_epoll does when a
    // send would block.
    max_queued: i64 = 65536,
    // The most bytes serve_epoll reads from one connection in a turn before
    // it goes on to the others, so that a body arriving as fast as the worker
    // reads it doesn't hold up the worker's other connections; 0 for no
    // limit. Beside uploads, 16 KB kept tier C's reads at a p99 of 4 ms, where
    // no limit let them wait seconds (task 021).
    max_read: i64 = 16384,
    // Call the handler given state with DONE after each response, for an
    // access log.
    log: bool = false,
    // Answers that wait (later): each worker's box takes mail_slots replies
    // of up to mail_size bytes at once, and its timer table max_waiting
    // exchanges waiting at once, a cell added as each is first needed. With
    // either at 0, the default, the loop opens
    // no box and later's exchange gets TIMEOUT at once: a program that never
    // waits pays nothing. mail_slots is a power of two of at least 2; other
    // values stop the loop with mail_open's EINVAL. A box needs max_conns of
    // at most 2^20.
    mail_slots: i32 = 0,
    mail_size: i32 = 256,
    max_waiting: i64 = 0,
    // Experimental, epoll loop only: each pass serves its plain HTTP events
    // first, then its upgraded connections' events, then the wakes asked for,
    // so a request doesn't wait behind the pass's WebSocket writes.
    requests_first: bool = false,
}

// Why a loop stopped: the call that failed, and its error code, one of
// sys.goose's. report writes it to stderr.
struct Error { call: const u8[:], code: i64 }

// Spawns worker_count(cfg) workers, each the thread_fn W, which calls a loop,
// with its own copy of cfg and the values after cfg, up to two. Returns once
// every worker has returned.
//
//   http::run(cfg, worker);             // thread_fn worker(cfg: http::Config)
//   http::run(cfg, app, worker);        // thread_fn worker(cfg: http::Config, app: App)
//
// A program that chooses its loop at run time calls run once per choice:
//
//   if epoll { http::run(cfg, worker_epoll) } else { http::run(cfg, worker) }
fn run<W>(cfg: Config) { spawn_workers(cfg) { c => thread_spawn(W, c) }; }
fn run<W>(cfg: Config, a) { spawn_workers(cfg) { c => thread_spawn(W, c, a) }; }
fn run<W>(cfg: Config, a, b) { spawn_workers(cfg) { c => thread_spawn(W, c, a, b) }; }

// run's loop: SPAWN starts a worker with its Config and returns its id.
fn spawn_workers<SPAWN>(cfg: Config) {
    var ids: i64[>..] = [];
    for i in worker_count(cfg) { ids.push(SPAWN(cfg)); }
    for id in ids { thread_wait(id); }
}

// The number of workers cfg asks for, which run spawns.
fn worker_count(cfg: Config) -> i64 {
    guard cfg.workers <= 0 else { return cfg.workers; }
    let n = net_default_workers();
    return if n > 0 { n } else { max(1, hardware_threads()) };
}

// Opens a worker's listener where cfg.address says, on port, or cfg.port
// without one. Returns its fd, or the error, for an address that isn't one or
// a listen that fails.
fn listen_on(cfg: const Config&, on: i32 = 0) -> i32, Error {
    let port = if on > 0 { on } else { cfg.port };
    let flags = NONBLOCK | REUSEPORT;
    let text = cfg.address;
    if starts_with(text, "unix:") {
        guard text.len > 5 else { return -1, Error { call: "address", code: EINVAL }; }
        let fd = net_listen(text[5..], 0, cfg.backlog, flags | UNIX);
        guard fd >= 0 else { return -1, Error { call: "listen", code: -fd }; }
        return fd, Error { call: "", code: 0 };
    }
    var host = text;
    if text.len >= 2 && text[0] == '[' && text[text.len - 1] == ']' { host = text[1..text.len - 1]; }
    var fd: i32 = 0;
    if host.len == 0 {
        fd = net_listen("", port, cfg.backlog, flags);
    } else {
        let a, ok = address(host);
        guard ok else { return -1, Error { call: "address", code: EINVAL }; }
        fd = net_listen(a.ip, port, cfg.backlog, if cfg.ipv6_only { flags | V6ONLY } else { flags });
    }
    guard fd >= 0 else { return -1, Error { call: "listen", code: -fd }; }
    return fd, Error { call: "", code: 0 };
}

// A connection's states, in both loops.
let OPEN: u8 = 0;       // answering requests
let CLOSING: u8 = 1;    // sending what's left, then shutting down its side
let DRAINING: u8 = 2;   // shut down, and dropping what arrives until the client closes

// What a handler given to serve(cfg, fresh) or serve_epoll(cfg, fresh) is
// called for: Event.kind.
let REQUEST: u8 = 0;    // a request's head, and its body if it came whole
let BODY: u8 = 1;       // the next piece of a body that didn't come whole
let END: u8 = 2;        // the end of that body
let MORE: u8 = 3;       // room for more of a response begun with begin, once the body has ended
// The connection closed, or the loop stopped, while the handler was owed
// another call: its response begun and not ended, or its body not read to the
// end. The handler releases what its state holds, as a file (close_body);
// what it writes goes nowhere.
let CLOSED: u8 = 4;
// With Config.log, the response is whole in the write buffer: Event.status,
// sent, and ms say how it went, and Reply.fd gives the peer. req is the
// request's head when its response was whole at REQUEST, and empty
// otherwise; the state is still the request's. A response cut short by a
// close gets CLOSED instead, as does an upgraded connection, and a request
// the loop refused before REQUEST gets neither.
let DONE: u8 = 5;
// An exchange that later made wait got a message at its address: its bytes
// in data, valid until the handler returns, and its tag. req is empty: the
// handler keeps in its state what of the request it needs. The handler
// answers, sends more of an open response, or calls later again; a handler
// that does none of these gets 500, as at REQUEST.
let WAKE: u8 = 6;
// later's time limit passed first, or there was no room to wait: no box, or
// Config.max_waiting exchanges waiting already, which its tag NO_ROOM says.
// As WAKE otherwise.
let TIMEOUT: u8 = 7;
// after_drain's output reached the socket. The exchange's mailbox wait, if
// any, remains armed. CLOSED replaces this event if the connection fails.
let DRAINED: u8 = 8;
// Mail to the worker's own address (worker_address): ev.data and ev.tag are
// what was sent, and the call belongs to no exchange.
let WORKER: u8 = 9;
// TIMEOUT's tag when the exchange found no room to wait, and got it at once.
let NO_ROOM: i32 = 1;
// No event, for answer's wake.
let NO_EVENT: u8 = 255;

struct Event {
    kind: u8,
    // REQUEST's parsed head. Its slices point into the read buffer, and last
    // until the handler returns. A reference, so that the request isn't
    // copied for each call: about 20 instructions per request.
    req: const Request&,
    // REQUEST's body, when whole; BODY's piece, decoded if chunked.
    data: const u8[:],
    // REQUEST's data is the whole body, as a body that fits in the read buffer
    // with its head always is, and no BODY or END follows.
    whole: bool,
    // The trailer fields of a chunked body (RFC 9112 §7.1.2), at END, or at
    // REQUEST when whole: field lines, each ending in CRLF, that field_in
    // finds a field in. A handler that reads one lets the sender know it may
    // send them with its TE field.
    trailers: const u8[:],
    // DONE's status, as start, begin, or a refusal of the loop's gave it; the
    // bytes of the response, head included, written to the write buffer; and
    // the milliseconds of the loop's clock from the read that brought the
    // head's first byte.
    status: i32 = 0,
    sent: i64 = 0,
    ms: i64 = 0,
    // WAKE's tag, as the sender gave it, and TIMEOUT's, NO_ROOM or 0.
    tag: i32 = 0,
}

// Makes the exchange wait, after this call to the handler, for a message to
// its address, which this returns, for at most ms milliseconds: then the
// handler is called with WAKE or TIMEOUT. At REQUEST or WAKE it holds back
// the response; at MORE, or after begin, it pauses an open response, for
// Server-Sent Events and long polling. While an exchange waits, the requests
// pipelined behind it wait in the read buffer, and the loop stops reading
// once that's full. After an upgrade, the client's bytes still come as BODY
// while the exchange waits; a later at BODY starts the time limit again, and
// end stops the wait. The address is the same for each call in one exchange,
// and a message to it after the exchange has ended, or once the connection
// has closed, makes a send return STALE; messages already in flight may be
// dropped. A call that writes a whole response doesn't wait,
// so a handler that can't hand the work on answers instead, as below. Only
// the handler given state gets WAKE and TIMEOUT.
//
//   let reply = http::later(out, 5000);
//   guard http::mail_send(worker, JOB, job_with(reply)) == http::SENT
//   else { http::respond(out, 503, "text/plain", ""); return; }
fn later(out: Reply, ms: i64) -> MailAddress {
    let s .= out.stream;
    s.waiting = true;
    s.rearm = true;
    s.wait_ms = max(ms, 0);
    if !s.live && s.later.box.slot >= 0 {
        s.live = true;
        mail_mark(Box { handle: s.later.box }, s.later.key, true);
    }
    return s.later;
}

// Makes s's address stale once its exchange no longer waits. The key stays
// live through WAKE until the handler returns, so a sender of a reply in
// pieces doesn't find it stale between one piece and the handler's next
// later; after an upgrade, through TIMEOUT too.
fn retire(s: Stream&) {
    guard s.live && !s.waiting else { return; }
    s.live = false;
    mail_mark(Box { handle: s.later.box }, s.later.key, false);
}

// A Later's key: the connection's slot, 24 bits of its generation, and 20 of
// the exchange's number, so a message for a closed connection, or an
// exchange that has ended, matches no exchange that waits.
fn later_base(slot: i64, gen: u64) -> u64 { ((slot as u64) << 44) | ((gen & 0xFFFFFF) << 20) }
fn later_slot(key: u64) -> i64 { (key >> 44) as i64 }

// Whether connection c's exchange waits for a message to key.
fn waits_for(c, key: u64) -> bool {
    return c.fd >= 0 && c.state == OPEN && c.x.stream.waiting && c.x.stream.later.key == key;
}

// Whether exchange x waits with the bytes after it held back: any but an
// upgraded one, whose client's bytes go on to the handler as BODY while it
// waits.
fn holds_input(x) -> bool { return x.stream.waiting && x.body != BodyReader.Raw; }

// The box of a loop with cfg, on a waker that ends the loop's wait, which the
// box then owns: none when cfg asks for no waiting, and then the loop closes
// the waker itself. An error for a box that can't open. The loop's timer
// table has cfg.max_waiting cells with a box, and none without.
fn open_waiting(cfg: const Config&, waker: i64) -> Box, Error {
    guard cfg.mail_slots > 0 && cfg.max_waiting > 0 else { return Box { .. }, Error { call: "", code: 0 }; }
    guard cfg.max_conns < 1 << 20 else { return Box { .. }, Error { call: "max_conns", code: EINVAL }; }
    // A key for each connection's slot, and the worker's own past them.
    let b, err = mail_open(cfg.mail_slots, cfg.mail_size, waker, cfg.max_conns as i32 + 1, 44);
    if err.code == 0 {
        mail_mark(b, worker_key(cfg), true);
        wake_box = b.handle;
    }
    return b, err;
}

// The worker's key in its loop's box: the slot past every connection's.
fn worker_key(cfg: const Config&) -> u64 { (cfg.max_conns as u64) << 44 }

// The address of out's worker itself, for as long as its loop runs: mail to it
// calls the handler with WORKER, the message's tag and bytes, a state of the
// worker's own, which starts as fresh, and a reply that sends nothing. A
// publisher can then address a worker without picking one of its exchanges.
// cfg is the worker's Config.
fn worker_address(cfg: const Config&, out: Reply) -> MailAddress {
    return MailAddress { box: out.stream.later.box, key: worker_key(cfg) };
}

// A loop's own box, in its thread, and the wakes its handlers asked for: pairs
// of an exchange's key and a tag, which the loop delivers after its pass.
var wake_box = Handle { .. };
var woken: u64[>..] = [];

// Wakes the exchange that waits at to with tag and no bytes, as
// mail_send(to, tag, "") does. From the worker whose box to is, it takes no
// slot: the loop calls the exchange after the pass it was asked in. Returns
// SENT, or STALE for an exchange that doesn't wait; from another thread, what
// mail_send returns.
fn wake(to: MailAddress, tag: i32) -> i32 {
    guard to.box.slot >= 0 && key_of(to.box) == key_of(wake_box) else { return mail_send(to, tag, ""); }
    guard mail_live(to) else { return STALE; }
    woken.push(to.key);
    woken.push(tag as! u32);
    return SENT;
}

// mail_open_code (mail.goose), with its error as an Error.
fn mail_open(slots: i32, size: i32, waker: i64 = 0, live_keys: i32 = 0, key_shift: i32 = 0) -> Box, Error {
    let b, k = mail_open_code(slots, size, waker, live_keys, key_shift);
    return b, Error { call: "mail_open", code: -k };
}

// Closes a loop's box, or its waker when it has none, after unlisting the
// waker for stop.
fn close_waiting(b: Box, waker: i64) {
    wake_box = Handle { .. };
    woken.clear();
    net_stop_unwatch(waker);
    if b.handle.slot >= 0 { mail_close(b); } else { net_waker_close(waker); }
}

// Takes out of overdue the first n keys, those of the exchanges owed TIMEOUT
// before a pass's calls added more.
fn drop_first(overdue: u64[>..]&, n: i64) {
    let rest = overdue.len - n;
    for k in rest { overdue[k] = overdue[n + k]; }
    overdue.resize(rest, 0);
}

// Starts the timer of c's exchange, which later asked for. With no room for
// it, the exchange stops waiting and true says it's owed TIMEOUT now.
fn start_wait(c, timers: Timers&, now: i64) -> bool {
    let s .= c.x.stream;
    s.rearm = false;
    cancel(timers, c.x.timer);
    c.x.timer = arm(timers, s.later.key, now + s.wait_ms);
    guard c.x.timer.slot < 0 else { return false; }
    s.waiting = false;
    retire(s);
    return true;
}

// The wait for the loop's next pass: up to a second, and no later than the
// next timer.
fn wait_for(timers: const Timers&, now: i64) -> i32 {
    let due, any = next_due(timers);
    guard any else { return 1000; }
    return min(max(due - now, 0), 1000) as i32;
}

// A request whose exchange outlasts the handler's REQUEST call: what of its
// body is still to come, what its response needs, and the handler's state.
// Each connection's slot holds one.
struct Exchange<S> {
    body: BodyReader = BodyReader.None,
    skip: bool,        // drop the rest of the body: the response is done without it
    taken: i64,         // body bytes so far, or dropped since skip, if chunked
    answered: bool,     // the handler's response is whole
    continued: bool,    // 100 Continue went out for the request in the read buffer
    expect: bool,       // the client asked for 100 Continue
    keep_alive: bool,
    head: bool,
    minor: i32,
    served: i64,        // requests on this connection so far
    since: i64,         // when the first byte the read buffer holds arrived; the loops set it
    began: i64,         // since, at the request's head
    sent: i64,          // the response's bytes so far
    stream: Stream,
    timer: Handle = Handle { .. },  // the time limit of the wait later asked for
    state: S,
}

// Calls H with CLOSED for c's exchange, if it was owed another call.
fn abandon<H, C>(c: C&) {
    let x .= c.x;
    let owed = x.stream.open || x.stream.waiting || (!x.skip && x.body != BodyReader.None);
    x.stream.waiting = false;
    retire(x.stream);
    guard owed else { return; }
    var sink: u8[>..] = [];
    let none = Request { .. };
    H(Event { kind: CLOSED, req: none, data: "", whole: false, trailers: "" }, &x.state,
      Reply { buf: sink, common: "", keep_alive: x.keep_alive, minor: x.minor, head: x.head, stream: x.stream,
            fd: c.fd });
    x.stream.open = false;
    x.body = BodyReader.None;
}

// The interim response a client that sent Expect: 100-continue waits for.
let INTERIM = "HTTP/1.1 100 Continue\r\n\r\n";

// Answers the requests in rbuf[..rlen] for connection c with the handler H,
// into wbuf, and moves the rest of rbuf to its front. rbuf's length is the
// longest head it takes. A request's state starts as fresh, and while
// stopping, its response closes the connection. Before a
// request, a piece of a body, or a MORE call, if wbuf holds
// cfg.write_buffer bytes or more, with the shared ranges deferred into it
// before a piece or a MORE, it calls ROOM(), which empties wbuf and
// returns true, or returns false to stop there. Returns the bytes left in
// rbuf, the number of calls to H, and whether ROOM, or a file for the loop
// to send (Stream.direct), stopped it. A refused
// request, or a response that doesn't keep the connection open, leaves c
// CLOSING and rbuf empty. wake, unless its kind is NO_EVENT, is a WAKE or
// TIMEOUT for c's exchange, which stopped waiting, for H before the rest. It
// does nothing while c's exchange waits, and stops when it starts to, unless
// the exchange is upgraded (holds_input).
fn answer<S, H, ROOM, C>(c: C&, rbuf: u8[:], rlen: i64, wbuf: u8[>..]&, common: const u8[:],
                         cfg: const Config&, fresh: const S&, stopping: bool, now: i64,
                         wake: const Event&) -> i64, i64, bool {
    var off = 0;
    var done = 0;
    var full = false;
    let x .= c.x;
    // The req of the events after REQUEST.
    let gone = Request { .. };
    // Read once per call: gcc can't tell an append to wbuf from a write to
    // cfg, so a field of cfg read per request is a load per request. Read
    // there, these cost 10-15 instructions per request.
    let max_body = cfg.max_body;
    let max_line = cfg.max_line;
    let max_fields = cfg.max_fields;
    let write_buffer = cfg.write_buffer;
    let max_requests = cfg.max_requests;
    let log = cfg.log;

    // Sends what wbuf holds, and closes.
    fn close() {
        c.state = CLOSING;
        off = rlen;
    }

    // Calls H with DONE for the request in x, whose response of sent bytes
    // ended with status. Its writes go nowhere.
    fn log_done(head: const Request&, status: i32, sent: i64, began: i64) {
        var sink: u8[>..] = [];
        var keep = x.keep_alive;
        var st = x.stream;
        H(Event { kind: DONE, req: head, data: "", whole: false, trailers: "", status: status, sent: sent,
                  ms: now - began }, &x.state,
          Reply { buf: sink, common: "", keep_alive: keep, minor: x.minor, head: x.head, stream: st, fd: c.fd });
    }

    // Refuses the request with status, unless its response has begun, and
    // closes.
    fn fail(status: i32) {
        if !x.answered && !x.stream.open {
            let before = wbuf.len;
            refuse(wbuf, status, common);
            x.answered = true;
            if log { log_done(gone, status, x.sent + wbuf.len - before, x.began); }
        }
        close();
    }

    // A call that both waited and wrote a whole response, or ended one,
    // doesn't wait. io_uring's poll of a socket wait_socket armed would hold
    // the socket open after the handler hangs it up.
    fn unwait() {
        x.stream.waiting = false;
        x.stream.rearm = false;
        net_disarm(x.stream.later.key);
    }

    // Calls H for ev on the request in x. Returns whether it wrote anything.
    fn call(ev: Event) -> bool {
        let before = wbuf.len;
        let was_open = x.stream.open;
        // &x.state: a block given x.state gets a copy, and loses what it
        // writes there (docs/goose-findings.md).
        H(ev, &x.state, Reply { buf: wbuf, common: common, keep_alive: x.keep_alive, minor: x.minor,
                               head: x.head, stream: x.stream, fd: c.fd });
        done++;
        let wrote = wbuf.len > before;
        // An end after an upgrade, or of a response that ends with the
        // connection, writes nothing.
        if (wrote || was_open) && x.stream.waiting && !x.stream.open { unwait(); }
        retire(x.stream);
        x.sent += wbuf.len - before;
        if x.stream.file >= 0 { x.sent += x.stream.file_left; }
        if !x.answered && !x.stream.open && (wrote || was_open) {
            x.answered = true;
            if log { log_done(gone, x.stream.status, x.sent, x.began); }
        }
        return wrote;
    }

    // Moves the request in x on after a call to H. False when the connection
    // closes, or the exchange waits with its input held back.
    fn settle() -> bool {
        if holds_input(x) { return false; }
        if x.body == BodyReader.None {
            if x.stream.open { return true; }
            if !x.answered {
                fail(500);
                return false;
            }
            x.continued = false;
            if !x.keep_alive || stopping {
                close();
                return false;
            }
            return true;
        }
        if x.answered && !x.skip {
            // Answered before the body ended: the rest is dropped, unless the
            // client still waits for 100 Continue, or the rest is longer than
            // cfg.max_drain. Then the connection closes.
            x.skip = true;
            x.taken = 0;
            let long = match x.body { Length l => l.left > cfg.max_drain, _ => false };
            if (x.expect && !x.continued) || !x.keep_alive || long {
                close();
                return false;
            }
        }
        return true;
    }

    var go = !holds_input(x);
    if wake.kind != NO_EVENT {
        call(wake);
        go = settle();
    }
    while go {
        // A file the loop sends itself goes out before anything after it.
        if x.stream.file >= 0 {
            full = true;
            break;
        }
        if x.body != BodyReader.None {
            guard off < rlen else { break; }
            // Ranges send_shared deferred count as written: only an upgraded exchange,
            // which takes BODY and MORE but no new request, defers them.
            if wbuf.len + shared_pending() >= write_buffer && !ROOM() {
                full = true;
                break;
            }
            let chunked = match x.body { ChunkSize, ChunkData, ChunkEnd, ChunkTrailer => true, _ => false };
            let d0, d1, s = read_body(rbuf[off..rlen], x.body);
            if s == INCOMPLETE {
                // A size or trailer line longer than rbuf can't fit.
                if off == 0 && rlen == rbuf.len { fail(400); }
                break;
            }
            if s != 200 {
                fail(400);
                break;
            }
            // A chunked body ends with its trailers, not data.
            let ended = chunked && x.body == BodyReader.None;
            let piece = rbuf[off + d0..if ended { off + d0 } else { off + d1 }];
            let trailers = rbuf[off + d0..if ended { off + d1 - 2 } else { off + d0 }];
            off += d1;
            x.taken += piece.len;
            // A chunk's size tells, before its data, whether it's too long.
            let coming = match x.body { ChunkData d => d.left, _ => 0 };
            if x.skip {
                done++;
                if x.taken > cfg.max_drain {
                    close();
                    break;
                }
                if x.body == BodyReader.None { guard settle() else { break; } }
                continue;
            }
            // A Content-Length beyond cfg.max_body is refused by parse, and an
            // upgraded connection has no body to limit.
            if x.taken + coming > cfg.max_body && x.body != BodyReader.Raw {
                fail(413);
                break;
            }
            if piece.len > 0 { call(Event { kind: BODY, req: gone, data: piece, whole: false, trailers: "" }); }
            if x.body == BodyReader.None && !x.answered { call(Event { kind: END, req: gone, data: "", whole: false, trailers: trailers }); }
            guard settle() else { break; }
            continue;
        }
        if x.stream.open {
            if wbuf.len + shared_pending() >= write_buffer && !ROOM() {
                full = true;
                break;
            }
            // A MORE that neither sends, ends, nor waits would be called
            // forever.
            x.stream.moved = false;
            if !call(Event { kind: MORE, req: gone, data: "", whole: false, trailers: "" }) && !x.stream.moved &&
               x.stream.open && !x.stream.waiting {
                close();
                break;
            }
            guard settle() else { break; }
            continue;
        }
        guard off < rlen else { break; }
        if wbuf.len >= write_buffer && !ROOM() {
            full = true;
            break;
        }
        let req, status = parse(rbuf[off..rlen], rbuf.len, max_body, max_line, max_fields);
        if status == INCOMPLETE { break; }
        if status != 200 {
            refuse(wbuf, status, common);
            close();
            break;
        }
        // A body that fits in rbuf with its head is answered once it's whole,
        // and so is a chunked one that turns out to fit. A longer one goes to
        // the handler in pieces.
        let b0 = off + req.len;
        let room = rbuf.len - req.len;
        var whole = !req.chunked && req.body <= room;
        var wire = 0;
        if req.chunked || (req.body > 0 && whole) {
            let n, s = frame_body(rbuf[b0..rlen], req, room);
            if s == INCOMPLETE {
                // The client may wait for this before it sends the body.
                if req.expect && !x.continued {
                    wbuf.append(INTERIM);
                    x.continued = true;
                }
                break;
            }
            if s == 413 && req.chunked {
                whole = false;
            } else if s != 200 {
                refuse(wbuf, s, common);
                close();
                break;
            } else {
                whole = true;
                wire = n;
            }
        }
        // The data and trailers of a chunked body. The trailers are sliced
        // only from a chunked body: sliced for every request, as rbuf[b0 +
        // t0..b0 + t1], they cost 6-11 instructions per request.
        var data: const u8[:] = rbuf[b0..b0 + wire];
        var trailers = data[..0];
        if req.chunked && whole {
            let n, t = dechunk(rbuf[b0..b0 + wire]);
            trailers = data[t..wire - 2];
            data = data[..n];
        }
        off = b0 + wire;
        // The request's state goes straight into c's slot, whose stream no
        // response holds open between requests.
        x.served++;
        x.keep_alive = req.keep_alive && !stopping && (max_requests <= 0 || x.served < max_requests);
        x.state = fresh;
        // The exchange's address for later. Without a box the key still
        // finds the exchange for its TIMEOUT.
        x.stream.later.key = (x.stream.later.key & ~0xFFFFF) | ((x.served & 0xFFFFF) as u64);
        let before = wbuf.len;
        H(Event { kind: REQUEST, req: req, data: data, whole: whole, trailers: trailers }, &x.state,
          Reply { buf: wbuf, common: common, keep_alive: x.keep_alive, minor: req.minor,
                  head: req.method == "HEAD", stream: x.stream, fd: c.fd });
        done++;
        if x.stream.waiting && !x.stream.open && wbuf.len > before { unwait(); }
        retire(x.stream);
        if whole && !x.stream.open && !x.stream.waiting {
            if wbuf.len == before {
                // The handler didn't answer.
                refuse(wbuf, 500, common);
                if log { log_done(req, 500, wbuf.len - before, x.since); }
                close();
                break;
            }
            if log { log_done(req, x.stream.status, wbuf.len - before, x.since); }
            if req.expect { x.continued = false; }
            if !x.keep_alive {
                close();
                break;
            }
            continue;
        }
        // The exchange goes on past this call, in c's slot.
        x.body = if raw(x.stream) { BodyReader.Raw }
                 else if whole { BodyReader.None }
                 else if req.chunked { BodyReader.ChunkSize }
                 else { BodyReader.Length { left: req.body } };
        x.skip = false;
        x.taken = 0;
        x.answered = !x.stream.open && !x.stream.waiting && wbuf.len > before;
        x.sent = wbuf.len - before;
        x.began = x.since;
        if x.answered && log { log_done(req, x.stream.status, x.sent, x.began); }
        x.expect = req.expect;
        x.head = req.method == "HEAD";
        x.minor = req.minor;
        if x.expect && !x.answered && !x.stream.open && !x.continued {
            wbuf.append(INTERIM);
            x.continued = true;
        }
        guard settle() else { break; }
    }
    let rest = rlen - off;
    if rest > 0 && off > 0 { copy_into(rbuf[..rest], rbuf[off..rlen]); }
    return rest, done, full;
}

// Whether c's request has stopped short, for the sweep: the start of one in
// held, or a body not all arrived, that the handler hasn't answered yet,
// with nothing still to send.
fn owes_408(c, sending: bool) -> bool {
    return c.state == OPEN && !c.x.stream.open && !c.x.stream.waiting && !sending &&
        (c.held.len > 0 && c.x.body == BodyReader.None || c.x.body != BodyReader.None && !c.x.answered);
}

// How long connection c may wait without progress, in milliseconds, when it
// isn't idle: for the client to take a response, which writing says it
// hasn't yet, for a body's next piece, or for the rest of a request head.
fn busy_ms(c, writing: bool, cfg: const Config&) -> i64 {
    return if writing { cfg.write_ms }
           else if c.x.body == BodyReader.Raw { cfg.idle_ms }
           else if c.x.body != BodyReader.None { cfg.body_ms }
           else { cfg.request_ms };
}

// Whether c is between requests, with nothing of one received or to send.
fn idle(c) -> bool {
    return c.held.len == 0 && c.x.body == BodyReader.None && !c.x.stream.open && !c.x.stream.waiting;
}

// The handler of serve(cfg) and serve_epoll(cfg) on an Event: calls H(req,
// body, out) at REQUEST, with the body when it came whole and an empty one
// otherwise, which is dropped as it arrives. H can't tell an empty chunked
// body from one dropped, so a chunked body that doesn't come whole is
// refused with 413. Inline: as a call, gcc kept it, and H with it, out of
// line, which cost 60-120 instructions per request.
//
//   http::serve(cfg, fresh) { ev, st, out => http::whole(ev, out) { req, body, o => ... }; }
inline fn whole<H>(ev: Event, out: Reply) {
    if ev.kind != REQUEST { return; }
    if ev.req.chunked && !ev.whole {
        out.keep_alive = false;
        start(out, 413);
        finish(out, NO_TYPE, "");
        return;
    }
    H(ev.req, ev.data, out);
}

// A body limit for one route, below Config.max_body, for a handler that
// takes the body in pieces: call it at REQUEST and at each BODY, with taken
// in the request's state. Returns whether the body is within limit bytes so
// far; past it, answers 413 and closes the connection, rather than drop the
// rest. A Content-Length is checked at REQUEST, and a chunked body as it
// comes. The handler mustn't have answered yet.
fn body_within(taken: i64&, ev: Event, out: Reply, limit: i64) -> bool {
    var over = false;
    if ev.kind == REQUEST {
        taken = ev.data.len;
        over = !ev.whole && !ev.req.chunked && ev.req.body > limit;
    } else if ev.kind == BODY {
        taken += ev.data.len;
    }
    guard over || taken > limit else { return true; }
    out.keep_alive = false;
    start(out, 413);
    finish(out, NO_TYPE, "");
    return false;
}

// A run of the worker's pool, gathered, and the bytes promised it: its
// bytes are gathered[at..at + len], in a run of cap bytes, which never grows
// past most. For gather, its first head bytes are the request's head,
// rebuilt, and then come the body's so far. len is 0 while nothing is
// gathered, and most 0 until gather_promise.
struct Gather { at: i64 = 0, cap: i64 = 0, len: i64 = 0, head: i64 = 0, most: i64 = 0 }

// Each worker's pool, a run for each Gather. A worker's globals are its own
// (spec §11.2), and the workers of a program that never gathers have none.
reusable[] var gathered: u8[>..] = [];

// The most bytes a worker's pool may promise its runs at once, unless
// gather_budget says otherwise.
let GATHER_BUDGET: i64 = 64 << 20;

// The worker's budget, and the bytes of it promised.
var gather_most: i64 = GATHER_BUDGET;
var gather_promised: i64 = 0;

// Sets the most bytes this worker's pool may promise its runs at once. A
// worker copies main's globals at spawn, so main sets it for every worker
// before run, or a worker for itself before its loop.
fn gather_budget(bytes: i64) { gather_most = bytes; }

// Promises g up to most bytes of the worker's pool and returns true, or
// returns false, promising nothing, when the budget can't hold them beside
// what it has promised. g holds no promise yet.
fn gather_promise(g: Gather&, most: i64) -> bool {
    guard gather_promised + most <= gather_most else { return false; }
    gather_promised += most;
    g.most = most;
    return true;
}

// Appends data to g's run, which starts at 16 KB and doubles as it fills,
// up to g.most. Returns false, appending nothing, where data would take g
// past g.most.
fn gather_piece(g: Gather&, data: const u8[:]) -> bool {
    let n = g.len + data.len;
    guard n <= g.most else { return false; }
    if n > g.cap {
        let cap = min(max(max(n, g.cap * 2), 16384), g.most);
        let run = gathered.realloc_slice(gathered[g.at..g.at + g.cap], cap);
        g.at = gathered.index_of(run[0]);
        g.cap = cap;
    }
    copy_into(gathered[g.at + g.len..g.at + n], data);
    g.len = n;
    return true;
}

// Frees g's run and keeps its promise, for a run that fills again.
fn gather_clear(g: Gather&) {
    if g.cap > 0 { gathered.free_slice(gathered[g.at..g.at + g.cap]); }
    g = Gather { most: g.most, .. };
}

// Frees g's run and gives back its promise.
fn release_gather(g: Gather&) {
    gather_promised -= g.most;
    if g.cap > 0 { gathered.free_slice(gathered[g.at..g.at + g.cap]); }
    g = Gather { .. };
}

// Promises g req's head, rebuilt, and its body, and copies the head in,
// whose bytes the read buffer holds only until the handler returns. A body
// with a Content-Length, which the caller has checked against its limit,
// gets a run of the head and the body's exact size, placed now, which never
// grows or moves; a chunked one is promised limit bytes, and its run grows
// as gather_piece grows it. Returns false, promising nothing, when the
// worker's budget can't hold them.
fn gather_head(g: Gather&, req: const Request&, limit: i64) -> bool {
    var version: u8[..16] = [];
    format(version, " HTTP/1.", req.minor, "\r\n");
    let head = req.method.len + 1 + req.target.len + version.len + req.fields.len + 2;
    guard gather_promise(g, head + (if req.chunked { limit } else { req.body })) else { return false; }
    if !req.chunked {
        let run = gathered.alloc_slice(g.most);
        g.at = gathered.index_of(run[0]);
        g.cap = g.most;
    }
    gather_piece(g, req.method);
    gather_piece(g, " ");
    gather_piece(g, req.target);
    gather_piece(g, version);
    gather_piece(g, req.fields);
    gather_piece(g, "\r\n");
    g.head = g.len;
    return true;
}

// The handler of serve(cfg, fresh) or serve_epoll(cfg, fresh) on an Event,
// ahead of H, for bodies of any size up to limit: calls H(req, body, out)
// once per request, with the whole body. A body that came with its head
// goes to H at REQUEST. A longer one is gathered as it arrives, and goes to
// H at END, with the head parsed again from a copy, as the read buffer is
// reused. g, in the request's state, holds the gathered bytes, which END and
// CLOSED give back. Past limit, at most Config.max_body, answers 413 and
// closes, as body_within does. A body the worker's budget can't promise its
// bytes gets 503 with Retry-After at its head (gather_head), and the
// connection closes. H can't keep req or body past its call.
//
//   http::serve(cfg, St { .. }) { ev, st, out =>
//       http::gather(ev, st.body, out, 1 << 24) { req, body, o => ... };
//   }
inline fn gather<H>(ev: Event, g: Gather&, out: Reply, limit: i64) {
    if ev.kind == REQUEST {
        let over = if ev.whole { ev.data.len > limit } else { !ev.req.chunked && ev.req.body > limit };
        if over {
            too_large(out);
        } else if ev.whole {
            H(ev.req, ev.data, out);
        } else if !gather_head(g, ev.req, limit) {
            out.keep_alive = false;
            start(out, 503);
            finish(out, "Retry-After: 1\r\nContent-Length: ", "");
        }
    } else if g.len == 0 {
        // Nothing gathered: answered at REQUEST, or past the limit.
    } else if ev.kind == BODY {
        if !gather_piece(g, ev.data) {
            release_gather(g);
            too_large(out);
        }
    } else if ev.kind == END {
        // Limits of the head's own size take back what parse took at REQUEST.
        let req, status = parse(gathered[g.at..g.at + g.head], g.head, limit, g.head, g.head);
        if status == 200 {
            H(req, gathered[g.at + g.head..g.at + g.len], out);
        } else {
            start(out, 500);
            finish(out, NO_TYPE, "");
        }
        release_gather(g);
    } else if ev.kind == CLOSED {
        release_gather(g);
    }
}

fn too_large(out: Reply) {
    out.keep_alive = false;
    start(out, 413);
    finish(out, NO_TYPE, "");
}
