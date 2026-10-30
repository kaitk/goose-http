// serve, the completion loop: each worker has its own ring (io_uring on Linux,
// a completion port on Windows, an emulation over epoll or kqueue elsewhere), and its own SO_REUSEPORT listeners on Linux
// (net_listen), and nothing else is shared between workers. A multishot
// accept takes each listener's connections, and a multishot receive per
// connection fills the ring's provided buffers. The sends a pass over the
// completions queues go to the kernel together, in the next wait.
namespace http;

import std;
import os;
import sys;
import message;
import ring;
import h2;
import shared;

// A request's tag: the connection's slot in the low 32 bits and a
// generation above, so a completion that arrives after its connection
// closed isn't taken for one of the slot's next connection. The listeners'
// slots are ones no connection gets: Config.port's is RING_LISTENER, and
// Config.listeners[k]'s RING_WAKE - 1 - k.
let RING_LISTENER: u64 = 0xFFFFFFFF;
// The tag of the waker's completions (ring_waker): mail in the box, or a stop.
let RING_WAKE: u64 = 0xFFFFFFFE;
// The tag of an outbound socket's readiness, which wait_socket armed on the
// ring (ring_bind): RING_WAKE - MAX_LISTENERS - 1, below the listeners', so
// it's no connection's.
let RING_SOCKET: u64 = 0xFFFFFFFA;
// The bits of a later's key that hold its connection's slot (later_base).
let SLOT_BITS: u64 = 0xFFFFF00000000000;

fn ring_listener_tag(k: i64) -> u64 {
    return if k == 0 { RING_LISTENER } else { RING_WAKE - (k as u64) };
}

// Between completions, a connection holds what it couldn't answer yet as a
// run of the worker's spill pool. Its responses wait in the ring, which
// sends them in order.
struct RingConn<S> {
    fd: i32,            // -1 while the slot is free
    tag: u64,
    state: u8,
    tls: i32 = -1,      // a TLS connection's slot in the TlsServer (http.tls); -1 for none
    queued: i64,        // bytes given to ring_send and not yet sent
    reading: bool,      // its multishot receive is queued
    stalled: bool,      // stopped reading at cfg.max_queued, with held to answer
    h2: i32 = -1,       // an h2 connection's H2Conn, in the worker's pool; -1 for HTTP/1.1,
                        // and -2 for HTTP/1.1 that a TLS handshake's ALPN chose
    deadline: i64,      // the time after which the sweep closes it
    x: Exchange<S>,     // the request in progress past its handler's REQUEST call
    held: u8[:],        // received and not yet answered
}

// Serves HTTP as cfg says, answering each request with H, until a call fails
// or stop ends it, and returns its error, with every socket it opened
// closed.
fn serve<H>(cfg: Config) -> Error {
    return serve(cfg, false) { ev, st, out => whole(ev, out, H); };
}

// serve(cfg), with a handler H that's called for each Event of a request,
// with the request's state, which starts as fresh.
fn serve<S, H>(cfg: Config, fresh: S) -> Error {
    var plain = NoTls {};
    return ring_loop(cfg, fresh, plain, H);
}

// serve(cfg, fresh), with tls, a NoTls or http.tls's TlsServer, the TLS of
// the listeners that serve it. A TLS connection's received bytes are
// decrypted before they're answered, and wbuf is sealed in its place before
// it's queued (flush), so that every byte TLS makes goes out through the
// ring, in order with the connection's other sends.
fn ring_loop<S, H>(cfg: Config, fresh: S, tls) -> Error {
    net_worker_start();
    guard is_field_value(cfg.server) else { return Error { call: "server", code: EINVAL }; }
    guard cfg.listeners.len == 0 || !starts_with(cfg.address, "unix:") else {
        return Error { call: "listeners", code: EINVAL };
    }
    // A completion port keeps one listener's accept.
    guard cfg.listeners.len < ring_listeners() else { return Error { call: "listeners", code: ENOSYS }; }
    guard !(cfg.require_ring && cfg.emulate_ring) else { return Error { call: "io_uring", code: EINVAL }; }
    // The listeners' modes, Config.port's first.
    var h2c_at: bool[..MAX_LISTENERS + 1] = [];
    var tls_at: bool[..MAX_LISTENERS + 1] = [];
    var h3_at: bool[..MAX_LISTENERS + 1] = [];
    for k in cfg.listeners.len + 1 {
        let h2c = if k == 0 { cfg.h2c } else { cfg.listeners[k - 1].h2c };
        let secure = if k == 0 { cfg.tls } else { cfg.listeners[k - 1].tls };
        let h3 = if k == 0 { cfg.h3 } else { cfg.listeners[k - 1].h3 };
        // Windows, which has no sendfile, serves no TLS so far.
        guard !secure || net_sendfile(-1, -1, 0, 0) != -ENOSYS else { return Error { call: "tls", code: ENOSYS }; }
        // h2c is h2 by prior knowledge, over TCP; over TLS, ALPN chooses it.
        guard !secure || !h2c && tls_serves(tls) else { return Error { call: "tls", code: EINVAL }; }
        guard !h3 || secure && h3_serves(tls) else { return Error { call: "h3", code: EINVAL }; }
        h3_at.push(h3);
        h2c_at.push(h2c);
        tls_at.push(secure);
    }
    if cfg.require_ring {
        let probe = ring_probe();
        guard probe == 0 else { return Error { call: "io_uring", code: -probe }; }
    }
    var lfds: i32[..MAX_LISTENERS + 1] = [];
    fn close_listeners() {
        for fd in lfds { if fd >= 0 { net_close(fd); } }
    }
    for k in cfg.listeners.len + 1 {
        let fd, listening = listen_on(cfg, if k == 0 { cfg.port } else { cfg.listeners[k - 1].port });
        guard fd >= 0 else {
            close_listeners();
            return listening;
        }
        lfds.push(fd);
    }
    let r = ring_create(cfg.ring_entries, cfg.ring_buffers, cfg.ring_buffer_size,
                        if cfg.emulate_ring { RING_EMULATE } else if cfg.require_ring { RING_REQUIRE } else { 0 });
    guard r >= 0 else {
        close_listeners();
        return Error { call: "io_uring", code: -r };
    }
    // Whether shared ranges go out from their blobs (ring_send_shared).
    let gathers = ring_gathers(r);
    let waker = ring_waker(r, RING_WAKE);
    guard waker >= 0 else {
        close_listeners();
        ring_destroy(r);
        return Error { call: "waker", code: -waker };
    }
    net_stop_watch(waker);
    let box, opened = open_waiting(cfg, waker);
    guard opened.code == 0 else {
        close_waiting(box, waker);
        close_listeners();
        ring_destroy(r);
        return opened;
    }
    let waiting = box.handle.slot >= 0;
    if waiting || h3_serves(tls) { ring_bind(r, RING_SOCKET); }
    // HTTP/3's UDP sockets are armed on the ring (net_arm), which the
    // emulated ring can't do: ENOSYS there.
    if h3_serves(tls) {
        for k in lfds.len {
            if !h3_at[k] { continue; }
            let opened3 = h3_listen(tls, cfg, k, if k == 0 { cfg.port } else { cfg.listeners[k - 1].port });
            guard opened3.code == 0 else {
                h3_end(tls, H);
                close_listeners();
                ring_destroy(r);
                close_waiting(box, waker);
                return opened3;
            }
        }
    }
    var timers = timer_table(if waiting { cfg.max_waiting } else { 0 });
    // Exchanges owed TIMEOUT for want of a timer, by their keys.
    var overdue: u64[>..] = [];
    let nothing = Request { .. };
    let none = Event { kind: NO_EVENT, req: nothing, data: "", whole: false, trailers: "" };
    // Whether each listener's multishot accept is queued. One ends when the
    // worker reaches cfg.max_conns, and on an error such as EMFILE. Then it's
    // queued again once a connection closes, or at the next sweep.
    var accepting: bool[..MAX_LISTENERS + 1] = [];
    var accept_failed: bool[..MAX_LISTENERS + 1] = [];
    for fd, k in lfds {
        ring_accept(r, fd, ring_listener_tag(k));
        accepting.push(true);
        accept_failed.push(false);
    }

    let started = stops();
    var stopping = false;
    var stop_by: i64 = 0;
    reusable[] var spill: u8[>..] = [];
    reusable var conns: RingConn<S>[>..] = [];
    var open = 0;
    // The generation of each connection and h2 stream: one counter, so no
    // stream's key repeats an earlier connection's in its slot (later_base).
    var generation: u64 = 0;
    var closed = false;
    // h2c's connections and streams, empty unless a listener serves h2c;
    // the worker's scratch for them; and the stream a WAKE or TIMEOUT is
    // for, while resume hands it on.
    reusable var h2conns: H2Conn[>..] = [];
    reusable var h2streams: H2Stream<S>[>..] = [];
    var h2out: u8[>..] = [];
    var h2fields: u8[>..] = [];
    var h2pseudo: u8[>..] = [];
    var h2cookie: u8[>..] = [];
    var h2huff: u8[>..] = [];
    var h2fb: u8[>..] = [];
    var wake_at: i64 = -1;
    var now = net_clock_ms();
    var next_sweep = now + 1000;
    // On the heap: as a 112-byte array in the loop's frame, it cost the
    // io_uring loop 10-25 user instructions per request.
    var common: u8[>..] = [];
    var date_s: i64 = -1;
    var done: Completion[256] =
        [Completion { tag: 0, res: 0, buf: -1, more: false, send: false }; 256];
    // The driven connection's bytes: rbuf[..rlen] is received and not yet
    // answered, and wbuf is answered and not yet queued to send.
    var rbuf: u8[>..] = [];
    rbuf.resize(cfg.max_head, 0);
    var rlen = 0;
    var wbuf: u8[>..] = [];
    shared_name(wbuf);
    // A TLS connection's received records, and the plaintext they gave.
    var wire: u8[>..] = [];
    var plain: u8[>..] = [];
    // Whether the driven connection answered a request or sent a response.
    var progress = false;

    // Cancels the accepts queued, at cfg.max_conns.
    fn stop_accepting() {
        for k in lfds.len { if accepting[k] { ring_cancel(r, ring_listener_tag(k)); } }
    }

    // A completion of listener k's accept.
    fn accepted(k: i64, cq: Completion) {
        if !cq.more { accepting[k] = false; }
        let fd = cq.res;
        if fd < 0 {
            // EMFILE, ENFILE, or out of memory: try again later.
            if fd != -ECANCELED && !accept_failed[k] { report(Error { call: "accept", code: -fd }); }
            accept_failed[k] = fd != -ECANCELED;
            return;
        }
        accept_failed[k] = false;
        guard open < cfg.max_conns && !stopping else {
            net_close(fd);
            return;
        }
        // A tag fits in 56 bits, and a free slot's is 0. 24 bits, as a
        // key's: a wider counter would reach keys whose generation bits are 0.
        generation = generation % 0xFFFFFF + 1;
        let i = conns.alloc_index(RingConn<S> { fd: fd, reading: true, deadline: now + cfg.request_ms, .. });
        let c .= conns[i];
        c.tag = (generation << 32) | (i as u64);
        c.x.stream.direct = true;
        c.x.stream.later = MailAddress { box: box.handle, key: later_base(i, generation) };
        if tls_at[k] {
            let t = tls_open(tls);
            // OpenSSL is out of memory: the client is turned away.
            guard t >= 0 else {
                net_close(fd);
                c.fd = -1;
                c.tag = 0;
                conns.free(i);
                return;
            }
            c.tls = t;
            // Files go through the record layer, read in pieces.
            c.x.stream.direct = false;
        }
        if h2c_at[k] { c.h2 = h2conns.alloc_index(h2_conn(cfg, now)) as i32; }
        ring_recv(r, fd, c.tag);
        open++;
        if open == cfg.max_conns { stop_accepting(); }
    }

    fn close_conn(i: i64) {
        let c .= conns[i];
        // Before CLOSED, whose handler may hang up a socket that a poll
        // would hold open. Only an exchange that waits has one armed, and
        // any of an h2c connection's streams may.
        if c.x.stream.waiting || c.h2 >= 0 { ring_disarm(r, c.x.stream.later.key, SLOT_BITS); }
        abandon(c, H);
        cancel(timers, c.x.timer);
        if c.h2 >= 0 {
            h2_release(h2conns[c.h2], h2streams, spill, timers, c.fd, H);
            h2conns.free(c.h2);
            c.h2 = -1;
        }
        // ring_close would drop a close_notify queued now: a connection
        // that ends cleanly queued one before (notify).
        if c.tls >= 0 {
            tls_close(tls, c.tls, c.fd, false);
            c.tls = -1;
        }
        ring_close(r, c.fd, if c.reading { c.tag } else { 0 });
        c.fd = -1;
        if c.x.stream.file >= 0 {
            net_file_close(c.x.stream.file);
            c.x.stream.file = -1;
        }
        c.tag = 0;
        if c.held.len > 0 { spill.free_slice(c.held); }
        conns.free(i);
        open--;
        closed = true;
    }

    fn blocked(c: RingConn<S>&) -> bool { c.queued >= cfg.max_queued }

    // Queues wbuf to send, behind the connection's sends before it. On a TLS
    // connection, wbuf is sealed first, with what OpenSSL has waiting to send
    // after it, and close_notify once the connection is CLOSING. If OpenSSL
    // fails, the connection sends nothing more, and the sweep closes it.
    fn flush(c: RingConn<S>&) {
        if c.tls >= 0 && !tls_seal(tls, c.tls, wbuf, 0, c.state == CLOSING) {
            wbuf.clear();
            c.state = DRAINING;
            c.deadline = now;
            return;
        }
        let deferred = shared_pending();
        guard wbuf.len + deferred > 0 else { return; }
        let e = if deferred > 0 { ring_send_shared(r, c.fd, c.tag, wbuf) } else { ring_send(r, c.fd, c.tag, wbuf) };
        if deferred > 0 { shared_taken(); }
        guard e >= 0 else { return Error { call: "send", code: -e } from spin; }
        c.queued += wbuf.len + deferred;
        wbuf.clear();
    }

    // Shuts down c's side once what it queued has gone, after a refusal or
    // an h2c GOAWAY, and gives the client cfg.linger_ms to close.
    fn drain(c: RingConn<S>&) {
        guard c.queued == 0 && c.state == CLOSING else { return; }
        net_shutdown(c.fd, SHUT_WR);
        c.state = DRAINING;
        c.deadline = now + cfg.linger_ms;
    }

    // Closes an OPEN connection as a refusal does, after what wbuf holds:
    // over TLS, close_notify follows once its handshake is done, or a failed
    // handshake's alert.
    fn notify(c: RingConn<S>&) {
        c.state = CLOSING;
        c.deadline = now + cfg.linger_ms;
        flush(c);
        drain(c);
    }

    // Queues wbuf and then the file send_file gave the exchange
    // (Stream.direct), which the ring then owns.
    fn send_file(c: RingConn<S>&) {
        flush(c);
        let s .= c.x.stream;
        let e = ring_send_file(r, c.fd, c.tag, s.file, s.file_off, s.file_left);
        s.file = -1;
        guard e >= 0 else { return Error { call: "send", code: -e } from spin; }
        c.queued += s.file_left;
        s.file_left = 0;
    }

    // Holds n received bytes from off on, those of provided buffer buf or of
    // src, after rbuf[..rlen].
    fn hold(c: RingConn<S>&, buf: i32, src: const u8[:], off: i64, n: i64) {
        guard rlen + n - off > 0 else { return; }
        c.held = spill.alloc_slice(rlen + n - off);
        copy_into(c.held[..rlen], rbuf[..rlen]);
        if buf >= 0 { ring_take(r, buf, off, c.held[rlen..]); }
        else { copy_into(c.held[rlen..], src[off..n]); }
        rlen = 0;
    }

    // Answers n received bytes after rbuf[..rlen]: those of provided buffer
    // buf, or of src when buf is -1. rbuf takes them as it has room. If the
    // connection reaches cfg.max_queued, it stops reading and holds the rest;
    // while its exchange waits, unless upgraded (holds_input), it holds the
    // rest, and stops reading once it holds rbuf's worth. wake goes to answer
    // first (answer).
    fn pump(c: RingConn<S>&, buf: i32, src: const u8[:], n: i64, wake: const Event&) {
        // At least once, with no bytes, to go on with a response.
        var off: i64 = 0;
        var ev = wake;
        loop {
            let k = min(n - off, rbuf.len - rlen);
            if buf >= 0 { ring_take(r, buf, off, rbuf[rlen..rlen + k]); }
            else { copy_into(rbuf[rlen..rlen + k], src[off..off + k]); }
            rlen += k;
            off += k;
            let rest, done, full = answer(c, rbuf, rlen, wbuf, common, cfg, fresh, stopping, now, ev, H) {
                flush(c);
                !blocked(c)
            };
            ev.kind = NO_EVENT;
            rlen = rest;
            if done > 0 { progress = true; }
            // The ring sends the file in order, so answering goes on.
            if c.x.stream.file >= 0 {
                send_file(c);
                if c.state == OPEN && !blocked(c) && !holds_input(&c.x) { continue; }
            }
            if c.state != OPEN {
                rlen = 0;
                break;
            }
            if blocked(c) || holds_input(&c.x) {
                hold(c, buf, src, off, n);
                if blocked(c) || c.held.len >= rbuf.len {
                    c.stalled = true;
                    if c.reading { ring_cancel(r, c.tag); }
                }
                break;
            }
            if off >= n { break; }
        }
        if rlen > 0 {
            c.held = spill.alloc_slice(rlen);
            copy_into(c.held, rbuf[..rlen]);
        }
        flush(c);
        if c.x.stream.rearm && start_wait(c, timers, now) { overdue.push(c.x.stream.later.key); }
    }

    // pump for an h2c connection: the h2 driver takes every byte but a
    // frame's incomplete start, which c holds, and its frames are queued as
    // far as cfg.max_queued allows. Once the connection reaches it, or the
    // driver has more to write, it stops reading and holds the rest until a
    // send completes. wake is for stream wake_at (h2_answer).
    fn pump_h2(c: RingConn<S>&, buf: i32, src: const u8[:], n: i64, wake: const Event&) {
        let slot = (c.tag & 0xFFFFFFFF) as i64;
        var off: i64 = 0;
        var ev = wake;
        loop {
            let k = min(n - off, rbuf.len - rlen);
            if buf >= 0 { ring_take(r, buf, off, rbuf[rlen..rlen + k]); }
            else { copy_into(rbuf[rlen..rlen + k], src[off..off + k]); }
            rlen += k;
            off += k;
            if c.state != OPEN {
                rlen = 0;
                break;
            }
            let rest, full = h2_answer(c, slot, h2conns[c.h2], h2streams, spill, rbuf, rlen, wbuf,
                                       max(cfg.max_queued - c.queued, 0), h2out, h2fields, h2pseudo, h2cookie,
                                       h2huff, h2fb, common, cfg, fresh, stopping, now, ev, wake_at, timers, overdue,
                                       generation, H);
            ev.kind = NO_EVENT;
            if rest != rlen || wbuf.len > 0 { progress = true; }
            rlen = rest;
            flush(c);
            if c.state != OPEN {
                rlen = 0;
                break;
            }
            if full || blocked(c) {
                hold(c, buf, src, off, n);
                c.stalled = true;
                if c.reading { ring_cancel(r, c.tag); }
                break;
            }
            if off >= n { break; }
        }
        if rlen > 0 {
            c.held = spill.alloc_slice(rlen);
            copy_into(c.held, rbuf[..rlen]);
        }
        drain(c);
    }

    // Shared ranges go out from their blobs only on a plain socket, and only
    // while handlers answer here: pump flushes them all before it returns.
    fn feed(c: RingConn<S>&, buf: i32, src: const u8[:], n: i64, wake: const Event&) {
        if c.h2 >= 0 { pump_h2(c, buf, src, n, wake); return; }
        shared_gather(gathers && c.tls < 0);
        pump(c, buf, src, n, wake);
        shared_gather(false);
    }

    // Goes on with c's exchange, which waited, with ev, its WAKE or TIMEOUT,
    // and then with what c holds.
    fn resume(c: RingConn<S>&, ev: const Event&) {
        // The wait is over: a socket still armed for it would wake the
        // exchange's next one with SOCKET_READY. Once, here: a call in each
        // of delivered's and timed_out's paths cost the request path 2 user
        // instructions (bench/count.sh), though none of them runs there.
        if ev.kind != NO_EVENT && ev.kind != DRAINED {
            ring_disarm(r, if wake_at >= 0 { h2streams[wake_at].x.stream.later.key } else { c.x.stream.later.key }, ~0);
        }
        progress = false;
        c.stalled = false;
        let src = c.held;
        c.held = c.held[..0];
        rlen = 0;
        feed(c, -1, src, src.len, ev);
        if src.len > 0 { spill.free_slice(src); }
        if c.state != DRAINING && !c.reading && !c.stalled {
            ring_recv(r, c.fd, c.tag);
            c.reading = true;
        }
        touch(c);
    }

    // A message to key, for the exchange that waits for it, if any, or for
    // the worker.
    fn delivered(key: u64, tag: i32, bytes: const u8[:]) {
        if key == worker_key(cfg) {
            call_worker(fresh, tag, bytes, H);
            return;
        }
        let i = later_slot(key);
        guard i < conns.len else { return; }
        let c .= conns[i];
        if c.h2 >= 0 {
            let k = h2_key_index(key);
            guard c.fd >= 0 && c.state == OPEN && k < h2streams.len && h2_waits_for(h2streams[k], i, key) else { return; }
            cancel(timers, h2streams[k].x.timer);
            h2streams[k].x.stream.waiting = false;
            wake_at = k;
            let ev = Event { kind: WAKE, req: nothing, data: bytes, whole: false, trailers: "", tag: tag };
            resume(c, ev);
            wake_at = -1;
            return;
        }
        guard waits_for(c, key) else { return; }
        cancel(timers, c.x.timer);
        c.x.stream.waiting = false;
        let ev = Event { kind: WAKE, req: nothing, data: bytes, whole: false, trailers: "", tag: tag };
        resume(c, ev);
    }

    // The exchange of key, which waited, or wanted to and found no timer,
    // is owed TIMEOUT.
    fn timed_out(key: u64, waited: bool) {
        let i = later_slot(key);
        guard i < conns.len else { return; }
        let c .= conns[i];
        if c.h2 >= 0 {
            let k = h2_key_index(key);
            guard c.fd >= 0 && c.state == OPEN && k < h2streams.len else { return; }
            let st .= h2streams[k];
            guard st.slot == i && st.id > 0 && st.x.stream.later.key == key && st.x.stream.waiting == waited else { return; }
            st.x.stream.waiting = false;
            retire(st.x.stream);
            wake_at = k;
            let ev = Event { kind: TIMEOUT, req: nothing, data: "", whole: false, trailers: "",
                             tag: if waited { 0 } else { NO_ROOM } };
            resume(c, ev);
            wake_at = -1;
            return;
        }
        guard c.fd >= 0 && c.state == OPEN && c.x.stream.later.key == key && c.x.stream.waiting == waited else { return; }
        c.x.stream.waiting = false;
        // An upgraded exchange's TIMEOUT is a tick that ends nothing: its key stays live through the
        // handler, as through WAKE, so a publisher's mail_live finds it; answer retires it after.
        if !raw(c.x.stream) { retire(c.x.stream); }
        let ev = Event { kind: TIMEOUT, req: nothing, data: "", whole: false, trailers: "",
                         tag: if waited { 0 } else { NO_ROOM } };
        resume(c, ev);
    }

    // Takes n received bytes, those of provided buffer buf or of src when
    // buf is -1: answers them, or holds them while the connection can't.
    fn take(c: RingConn<S>&, buf: i32, src: const u8[:], n: i64) {
        // A connection that isn't OPEN drops what arrives.
        if c.state != OPEN {
        } else if c.stalled || holds_input(&c.x) {
            let m = c.held.len;
            if m == 0 { c.x.since = now; }
            c.held = if m == 0 { spill.alloc_slice(n) } else { spill.realloc_slice(c.held, m + n) };
            if buf >= 0 { ring_take(r, buf, 0, c.held[m..]); }
            else { copy_into(c.held[m..], src[..n]); }
            if !c.stalled && c.held.len >= rbuf.len {
                c.stalled = true;
                if c.reading { ring_cancel(r, c.tag); }
            }
        } else {
            rlen = c.held.len;
            if rlen == 0 { c.x.since = now; }
            if rlen > 0 {
                copy_into(rbuf[..rlen], c.held);
                spill.free_slice(c.held);
                c.held = c.held[..0];
            }
            feed(c, buf, src, n, none);
        }
    }

    // A receive's completion. False when the connection is done.
    fn received(c: RingConn<S>&, cq: Completion) -> bool {
        if !cq.more { c.reading = false; }
        if cq.res > 0 && c.tls >= 0 && c.state == OPEN {
            // The records' plaintext is answered, and then what OpenSSL has
            // to send goes out: the handshake's flights, or an alert. A
            // client's close_notify, or a failed handshake, closes the
            // connection after them.
            wire.resize(cq.res as i64, 0);
            ring_take(r, cq.buf, 0, wire);
            ring_give(r, cq.buf);
            plain.clear();
            let going = tls_take(tls, c.tls, wire, plain);
            if plain.len > 0 {
                // The first plaintext: if ALPN chose h2, feed gives its
                // preface to pump_h2.
                if c.h2 == -1 {
                    c.h2 = if tls_h2(tls, c.tls) { h2conns.alloc_index(h2_conn(cfg, now)) as i32 } else { -2 };
                }
                take(c, -1, plain, plain.len);
            }
            if !going && c.state == OPEN { notify(c); } else { flush(c); }
        } else if cq.res > 0 {
            take(c, cq.buf, "", cq.res as i64);
            ring_give(r, cq.buf);
        } else if cq.res == 0 || (cq.res != -ENOBUFS && cq.res != -ECANCELED) {
            return false;   // the client closed or reset
        }
        if !c.reading && !c.stalled {
            ring_recv(r, c.fd, c.tag);
            c.reading = true;
        }
        return true;
    }

    // A send's completion. False when the connection is done.
    fn sent(c: RingConn<S>&, res: i32) -> bool {
        guard res >= 0 else { return false; }   // EPIPE, ECONNRESET: the client left
        c.queued -= res as i64;
        progress = true;
        drain(c);
        if c.x.stream.framing == Framing.RawDrain && c.queued == 0 && c.state == OPEN && c.x.stream.open {
            c.x.stream.framing = Framing.Raw;
            let ev = Event { kind: DRAINED, req: nothing, data: "", whole: false, trailers: "" };
            resume(c, ev);
        }
        if c.stalled && !blocked(c) {
            c.stalled = false;
            let src = c.held;
            c.held = c.held[..0];
            rlen = 0;
            feed(c, -1, src, src.len, none);
            if src.len > 0 { spill.free_slice(src); }
        }
        if !c.reading && !c.stalled {
            ring_recv(r, c.fd, c.tag);
            c.reading = true;
        }
        return true;
    }

    // Moves the deadline of a connection after a completion. Progress
    // restarts the clock; the first bytes of a request after an idle spell
    // shorten it.
    fn touch(c: RingConn<S>&) {
        guard c.state != DRAINING else { return; }
        // A handshake has request_ms from the accept, however it progresses.
        guard c.tls < 0 || tls_ready(tls, c.tls) else { return; }
        let sending = c.queued > 0;
        // An h2c connection's streams have their own limits (later's), so
        // the connection's is idle_ms, or write_ms while the client doesn't
        // take what it was sent.
        if c.h2 >= 0 {
            if progress { c.deadline = now + (if sending { cfg.write_ms } else { cfg.idle_ms }); }
            return;
        }
        let idle = idle(c) && !sending;
        if progress { c.deadline = now + (if idle { cfg.idle_ms } else { busy_ms(c, sending, cfg) }); }
        else if !idle { c.deadline = min(c.deadline, now + busy_ms(c, sending, cfg)); }
    }

    // Closes the connections past their deadline. One still waiting for the
    // rest of a request is refused with a 408 instead, which closes it as
    // any refusal does; cfg.linger_ms bounds the send. A close aborts a send in
    // flight on Windows, and io_uring's cancels one that hasn't gone out.
    // An exchange that waits has its own time limit instead.
    fn sweep() {
        for i in conns.len {
            let c .= conns[i];
            if c.fd < 0 || c.deadline > now || c.x.stream.waiting { continue; }
            if c.h2 >= 0 {
                let h .= h2conns[c.h2];
                var waits = false;
                for k in h.streams { waits = waits || h2streams[k].x.stream.waiting; }
                if waits { continue; }
                // An idle one is sent GOAWAY (RFC 9113 §9.1).
                if c.state == OPEN && h.streams.len == 0 && c.queued == 0 {
                    wbuf.clear();
                    h2_write_goaway(wbuf, h.last_stream, H2_NO_ERROR);
                    h.goaway = true;
                    notify(c);
                    continue;
                }
                close_conn(i);
                continue;
            }
            // A handshake that didn't finish in time gets no 408.
            let shaken = c.tls < 0 || tls_ready(tls, c.tls);
            if owes_408(c, c.queued > 0) && shaken {
                wbuf.clear();
                refuse(wbuf, 408, common);
                // CLOSING first, for TLS's close_notify after the 408.
                c.state = CLOSING;
                c.deadline = now + cfg.linger_ms;
                flush(c);
                continue;
            }
            // An idle TLS connection is sent close_notify, as at a stop.
            if c.tls >= 0 && shaken && c.state == OPEN && idle(c) && c.queued == 0 {
                notify(c);
                continue;
            }
            close_conn(i);
        }
    }

    // Closes the listeners and the connections between requests, and gives
    // the rest cfg.grace_ms to finish. A listener's accept holds it open
    // until the accept is cancelled: in a process a signal kills, until the
    // kernel tears the ring down, after the exit (docs/known-issues.md).
    fn begin_stop() {
        stopping = true;
        stop_by = now + cfg.grace_ms;
        stop_accepting();
        close_listeners();
        for k in lfds.len { lfds[k] = -1; }
        if h3_serves(tls) { h3_stop(tls, now); }
        for i in conns.len {
            let c .= conns[i];
            // An h2c connection sends GOAWAY, and closes once its streams end.
            if c.fd >= 0 && c.h2 >= 0 { if c.state == OPEN { resume(c, none); } }
            else if c.fd >= 0 && c.state == OPEN && idle(c) && c.queued == 0 {
                // A TLS connection is sent close_notify, and closes once the
                // client does, or at the sweep.
                if c.tls >= 0 && tls_ready(tls, c.tls) { notify(c); } else { close_conn(i); }
            }
            else if c.fd >= 0 && c.x.stream.waiting { c.x.keep_alive = false; }
        }
    }


    // The loop, until a call fails or a stop ends it: then the error, or one
    // with code 0, is returned from here.
    fn spin() -> Error {
        loop {
            // A wait ends within a second, for the sweep and a stopped
            // accept's retry, or at the next timer; the waker ends it for
            // mail and a stop.
            var timeout: i32 = if overdue.len > 0 || woken_n > 0 { 0 } else { wait_for(timers, now) };
            if h3_serves(tls) { timeout = h3_wait(tls, now, timeout); }
            let n = ring_wait(r, done, timeout);
            if n == -EINTR { continue; }
            guard n >= 0 else { return Error { call: "wait", code: -n }; }
            now = net_clock_ms();
            let t = net_time_s();
            if t != date_s {
                common.clear();
                common_fields(common, cfg.server, t);
                date_s = t;
            }
            closed = false;
            for cq in done[..n] {
                if cq.tag == RING_LISTENER || (cq.tag < RING_WAKE && cq.tag >= RING_WAKE - MAX_LISTENERS) {
                    let k: i64 = if cq.tag == RING_LISTENER { 0 } else { (RING_WAKE - cq.tag) as i64 };
                    if k < lfds.len { accepted(k, cq); }
                    continue;
                }
                if cq.tag == RING_WAKE {
                    // A worker's mail asks its wakes now, as mail did, not after the pass's other events.
                    if waiting { mail_take(box) { key, tag, bytes => delivered(key, tag, bytes); }; wake_all() { key, tag => delivered(key, tag, ""); }; }
                    continue;
                }
                let i = (cq.tag & 0xFFFFFFFF) as i64;
                if i >= conns.len || conns[i].tag != cq.tag {
                    // An outbound socket that wait_socket armed, here off
                    // the connections' path.
                    if cq.tag == RING_SOCKET {
                        let key = ring_socket(r, cq.buf);
                        if h3_serves(tls) {
                            let hk = h3_listener(tls, key);
                            if hk >= 0 {
                                h3_ready(tls, hk, cfg, fresh, common, now, H);
                                continue;
                            }
                        }
                        if key != 0 { delivered(key, SOCKET_READY, ""); }
                        continue;
                    }
                    // The connection closed after the request was queued.
                    if cq.buf >= 0 { ring_give(r, cq.buf); }
                    continue;
                }
                let c .= conns[i];
                progress = false;
                let ok = if cq.send { sent(c, cq.res) } else { received(c, cq) };
                if ok { touch(c); } else { close_conn(i); }
            }
            if h3_serves(tls) { h3_tick(tls, cfg, fresh, common, now, H); }
            if waiting { expire(timers, now) { key => timed_out(key, true); }; }
            // With or without a box: without one, every later is owed its TIMEOUT.
            let owed = overdue.len;
            for k in owed { timed_out(overdue[k], false); }
            drop_first(overdue, owed);
            wake_all() { key, tag => delivered(key, tag, ""); };
            let tick = now >= next_sweep;
            if tick {
                sweep();
                next_sweep = now + 1000;
            }
            for k in lfds.len {
                if !accepting[k] && !stopping && open < cfg.max_conns && (!accept_failed[k] || closed || tick) {
                    ring_accept(r, lfds[k], ring_listener_tag(k));
                    accepting[k] = true;
                }
            }
            if !stopping && stops() != started { begin_stop(); }
            if stopping && (open == 0 && h3_count(tls) == 0 || now >= stop_by) { return Error { call: "", code: 0 }; }
        }
    }

    let failed = spin();
    for i in conns.len {
        let c .= conns[i];
        if c.fd >= 0 {
            abandon(c, H);
            if c.h2 >= 0 {
                h2_release(h2conns[c.h2], h2streams, spill, timers, c.fd, H);
                h2conns.free(c.h2);
                c.h2 = -1;
            }
            if c.tls >= 0 {
                tls_close(tls, c.tls, c.fd, false);
                c.tls = -1;
            }
            net_close(c.fd);
        }
    }
    if h3_serves(tls) { h3_end(tls, H); }
    close_listeners();
    // Submits the closes still queued, then frees the ring, and after it the
    // waker, which io_uring's poll of it holds until then.
    ring_wait(r, done, 0);
    ring_destroy(r);
    close_waiting(box, waker);
    return failed;
}
