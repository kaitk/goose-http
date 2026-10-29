// serve_epoll, the readiness loop: each worker has its own edge-triggered
// epoll instance (kqueue on macOS), and its own SO_REUSEPORT listener on Linux
// (net_listen), and nothing else is shared between workers. A connection
// belongs to the worker that accepted it, in a slot of that worker's pool.
namespace http;

import std;
import os;
import sys;
import message;
import h2;
import shared;

// The epoll tag of Config.port's listener; Config.listeners[k]'s is
// EPOLL_LISTENER - 2 - k. A connection's is its slot.
let EPOLL_LISTENER: u64 = 0xFFFFFFFFFFFFFFFF;
// The waker's tag (net_waker): mail in the box, or a stop.
let EPOLL_WAKE: u64 = 0xFFFFFFFFFFFFFFFE;

fn epoll_listener_tag(k: i64) -> u64 {
    return if k == 0 { EPOLL_LISTENER } else { EPOLL_WAKE - (k as u64) };
}

// Between events, a connection holds only what its socket left over: the
// start of a request not yet whole, and responses the socket didn't take.
// Both are runs of the worker's spill pool, empty almost always.
struct EpollConn<S> {
    fd: i32,            // -1 while the slot is free
    state: u8,
    watch_out: bool,    // OUT is registered: set while out holds bytes
    ready: bool,        // another turn is owed for reads or an upgraded drain credit
    listed: bool,       // in turns
    empty: bool = false, // a recv found the socket empty, and no edge came since
    h2: i32 = -1,       // an h2 connection's H2Conn, in the worker's pool; -1 for HTTP/1.1,
                        // and -2 for HTTP/1.1 that a TLS handshake's ALPN chose
    tls: i32 = -1,      // a TLS connection's slot in the TlsServer (http.tls); -1 for none
    deadline: i64,      // the time after which the sweep closes it
    x: Exchange<S>,     // the request in progress past its handler's REQUEST call
    held: u8[:],        // received and not yet answered
    out: u8[:],         // still to send
}

// What a turn of answering did, for advance: whether it moved the exchange
// on, and whether it has more to write before it reads.
struct EpollTurn {
    moved: bool,
    full: bool,
}

// Serves HTTP as cfg says, answering each request with H, until a call fails
// or stop ends it, and returns its error, with every socket it opened
// closed. On Windows it fails at once with ENOSYS.
fn serve_epoll<H>(cfg: Config) -> Error {
    return serve_epoll(cfg, false) { ev, st, out => whole(ev, out, H); };
}

// serve_epoll(cfg), with a handler H that's called for each Event of a
// request, with the request's state, which starts as fresh.
fn serve_epoll<S, H>(cfg: Config, fresh: S) -> Error {
    var plain = NoTls {};
    return epoll_loop(cfg, fresh, plain, H);
}

// A program without http.tls: no listener serves TLS, so the loop never
// calls these.
struct NoTls {}
fn tls_serves(t: NoTls&) -> bool { false }
fn tls_open(t: NoTls&) -> i32 { -1 }
fn tls_ready(t: NoTls&, k: i32) -> bool { false }
fn tls_h2(t: NoTls&, k: i32) -> bool { false }
fn tls_recv(t: NoTls&, k: i32, fd: i32, buf: u8[:]) -> i64, bool { return -1, false; }
fn tls_take(t: NoTls&, k: i32, bytes: const u8[:], out: u8[>..]&) -> bool { false }
fn tls_seal(t: NoTls&, k: i32, w: u8[>..]&, from: i64, last: bool) -> bool { false }
fn tls_close(t: NoTls&, k: i32, fd: i32, clean: bool) {}

// Nor HTTP/3 (http.h3), whose hooks the loops call only where h3_serves.
fn h3_serves(t: NoTls&) -> bool { false }
fn h3_listen(t: NoTls&, cfg: const Config&, k: i64, port: i32) -> Error { Error { call: "h3", code: EINVAL } }
fn h3_listener(t: NoTls&, key: u64) -> i64 { -1 }
fn h3_ready<S, H>(t: NoTls&, k: i64, cfg: const Config&, fresh: const S&, common: const u8[:], now: i64) {}
fn h3_wait(t: NoTls&, now: i64, limit: i32) -> i32 { limit }
fn h3_tick<S, H>(t: NoTls&, cfg: const Config&, fresh: const S&, common: const u8[:], now: i64) {}
fn h3_stop(t: NoTls&, now: i64) {}
fn h3_count(t: NoTls&) -> i64 { 0 }
fn h3_end<H>(t: NoTls&) {}

// serve_epoll(cfg, fresh), with tls, a NoTls or http.tls's TlsServer, the
// TLS of the listeners that serve it. A TLS connection's bytes pass through
// tls between the socket and the worker's buffers: what it receives is
// decrypted into rbuf, and wbuf holds the bytes sealed for the socket
// before sealed, and the plaintext to seal after.
fn epoll_loop<S, H>(cfg: Config, fresh: S, tls) -> Error {
    net_worker_start();
    guard is_field_value(cfg.server) else { return Error { call: "server", code: EINVAL }; }
    guard cfg.listeners.len == 0 || !starts_with(cfg.address, "unix:") else {
        return Error { call: "listeners", code: EINVAL };
    }
    // The listeners, Config.port's first, and whether each serves h2c or TLS.
    var lfds: i32[..MAX_LISTENERS + 1] = [];
    var h2c_at: bool[..MAX_LISTENERS + 1] = [];
    var tls_at: bool[..MAX_LISTENERS + 1] = [];
    var h3_at: bool[..MAX_LISTENERS + 1] = [];
    for k in cfg.listeners.len + 1 {
        let h2c = if k == 0 { cfg.h2c } else { cfg.listeners[k - 1].h2c };
        let secure = if k == 0 { cfg.tls } else { cfg.listeners[k - 1].tls };
        let h3 = if k == 0 { cfg.h3 } else { cfg.listeners[k - 1].h3 };
        // h2c is h2 by prior knowledge, over TCP; over TLS, ALPN chooses it.
        guard !secure || !h2c && tls_serves(tls) else { return Error { call: "tls", code: EINVAL }; }
        guard !h3 || secure && h3_serves(tls) else { return Error { call: "h3", code: EINVAL }; }
        h2c_at.push(h2c);
        tls_at.push(secure);
        h3_at.push(h3);
    }
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
    let ep = net_epoll_create();
    guard ep >= 0 else {
        close_listeners();
        return Error { call: "epoll_create", code: -ep };
    }
    for fd, k in lfds {
        let added = net_epoll_ctl(ep, EPOLL_CTL_ADD, fd, EPOLLIN | EPOLLET, epoll_listener_tag(k));
        guard added >= 0 else {
            net_close(ep);
            close_listeners();
            return Error { call: "epoll_ctl", code: -added };
        }
    }
    let waker = net_waker(ep, EPOLL_WAKE);
    guard waker >= 0 else {
        net_close(ep);
        close_listeners();
        return Error { call: "waker", code: -waker };
    }
    net_stop_watch(waker);
    let box, opened = open_waiting(cfg, waker);
    guard opened.code == 0 else {
        close_waiting(box, waker);
        net_close(ep);
        close_listeners();
        return opened;
    }
    let waiting = box.handle.slot >= 0;
    // For wait_socket, which watches outbound sockets on ep.
    net_loop_bind(ep);
    if h3_serves(tls) {
        for k in lfds.len {
            if !h3_at[k] { continue; }
            let opened3 = h3_listen(tls, cfg, k, if k == 0 { cfg.port } else { cfg.listeners[k - 1].port });
            guard opened3.code == 0 else {
                h3_end(tls, H);
                net_loop_bind(-1);
                close_waiting(box, waker);
                net_close(ep);
                close_listeners();
                return opened3;
            }
        }
    }
    var timers = timer_table(if waiting { cfg.max_waiting } else { 0 });
    // Exchanges owed TIMEOUT for want of a timer, by their keys.
    var overdue: u64[>..] = [];
    // Connections owed another turn, by slot, for reads or a drain credit.
    var turns: u64[>..] = [];
    var generation: u64 = 0;
    let nothing = Request { .. };
    let none = Event { kind: NO_EVENT, req: nothing, data: "", whole: false, trailers: "" };

    let started = stops();
    var stopping = false;
    var stop_by: i64 = 0;
    reusable[] var spill: u8[>..] = [];
    reusable var conns: EpollConn<S>[>..] = [];
    var open = 0;
    // Set when accepting stopped before the backlog was empty: at cfg.max_conns,
    // or at the fd limit (EMFILE). The listener's edge has passed, so the
    // loop retries until the backlog is empty, and the waiting clients keep
    // their place in it. One for each listener, and whether any is.
    var paused_at: bool[..MAX_LISTENERS + 1] = [];
    for fd in lfds { paused_at.push(false); }
    var paused = false;
    // h2c's connections and streams, empty unless a listener serves h2c;
    // the worker's scratch for them; the streams' generations for later's
    // keys; and the stream a WAKE or TIMEOUT is for, while go hands it on.
    reusable var h2conns: H2Conn[>..] = [];
    reusable var h2streams: H2Stream<S>[>..] = [];
    var h2out: u8[>..] = [];
    var h2fields: u8[>..] = [];
    var h2pseudo: u8[>..] = [];
    var h2cookie: u8[>..] = [];
    var h2huff: u8[>..] = [];
    var h2fb: u8[>..] = [];
    var h2gen: u64 = 0;
    var wake_at: i64 = -1;
    // The slot go drives.
    var driving: i64 = -1;
    // Whether files go out with sendfile: on Linux and macOS, whose shims
    // refuse fd -1 with EBADF.
    let direct = net_sendfile(-1, -1, 0, 0) != -ENOSYS;
    var now = net_clock_ms();
    var next_sweep = now + 1000;
    // On the heap: as a 112-byte array in the loop's frame, it cost the
    // io_uring loop 10-25 user instructions per request.
    var common: u8[>..] = [];
    var date_s: i64 = -1;
    var events: PollEvent[256] = [PollEvent { events: 0, tag: 0 }; 256];
    // The driven connection's bytes: rbuf[..rlen] is received and not yet
    // answered, and wbuf[woff..] is still to send.
    var rbuf: u8[>..] = [];
    rbuf.resize(cfg.max_head, 0);
    var rlen = 0;
    var wbuf: u8[>..] = [];
    var woff = 0;
    // What of the output, wbuf and the shared ranges deferred into it, the socket didn't take.
    var gbuf: u8[>..] = [];
    // On a TLS connection, wbuf[..sealed] is sealed for the socket, and what
    // follows is plaintext still to seal.
    var sealed = 0;

    // Accepts from each listener that paused.
    fn accept_all() {
        paused = false;
        for k in lfds.len {
            if paused_at[k] { accept_from(k); }
            paused = paused || paused_at[k];
        }
    }

    fn accept_from(k: i64) {
        let retry = paused_at[k];
        paused_at[k] = true;
        paused = true;
        while open < cfg.max_conns {
            let fd = net_accept(lfds[k], NONBLOCK);
            if fd == -EAGAIN {
                paused_at[k] = false;
                return;
            }
            if fd == -EINTR || fd == -ECONNABORTED { continue; }
            guard fd >= 0 else {
                // EMFILE, ENFILE, or out of memory: try again later.
                if !retry { report(Error { call: "accept", code: -fd }); }
                return;
            }
            let i = conns.alloc_index(EpollConn<S> { fd: fd, deadline: now + cfg.request_ms, .. });
            conns[i].x.stream.direct = direct;
            let r = net_epoll_ctl(ep, EPOLL_CTL_ADD, fd, EPOLLIN | EPOLLRDHUP | EPOLLET, i as u64);
            if r < 0 {
                report(Error { call: "epoll_ctl", code: -r });
                net_close(fd);
                conns[i].fd = -1;
                conns.free(i);
                continue;
            }
            generation = generation % 0xFFFFFF + 1;
            conns[i].x.stream.later = MailAddress { box: box.handle, key: later_base(i, generation) };
            if h2c_at[k] { conns[i].h2 = h2conns.alloc_index(h2_conn(cfg, now)) as i32; }
            if tls_at[k] {
                let t = tls_open(tls);
                // OpenSSL is out of memory: the client is turned away.
                if t < 0 {
                    net_close(fd);
                    conns[i].fd = -1;
                    conns.free(i);
                    continue;
                }
                conns[i].tls = t;
                // Files go through the record layer, read in pieces.
                conns[i].x.stream.direct = false;
            }
            open++;
        }
    }

    fn close_conn(i: i64) {
        let c .= conns[i];
        abandon(c, H);
        cancel(timers, c.x.timer);
        if c.h2 >= 0 {
            h2_release(h2conns[c.h2], h2streams, spill, timers, c.fd, H);
            h2conns.free(c.h2);
            c.h2 = -1;
        }
        if c.tls >= 0 {
            // close_notify, or a failed handshake's alert, only where nothing
            // sealed is still waiting to go before it.
            tls_close(tls, c.tls, c.fd, c.out.len == 0);
            c.tls = -1;
        }
        net_close(c.fd);
        c.fd = -1;
        if c.x.stream.file >= 0 {
            net_file_close(c.x.stream.file);
            c.x.stream.file = -1;
        }
        if c.held.len > 0 { spill.free_slice(c.held); }
        if c.out.len > 0 { spill.free_slice(c.out); }
        conns.free(i);
        open--;
    }

    // Moves a connection on as far as its socket allows, in the worker's
    // buffers, and keeps what's left over in spill. hup is whether the event
    // reported the client's side closed, and wake goes to answer first
    // (answer). False when the connection is done.
    fn drive(c: EpollConn<S>&, hup: bool, wake: const Event&) -> bool {
        rlen = c.held.len;
        if rlen > 0 {
            copy_into(rbuf[..rlen], c.held);
            spill.free_slice(c.held);
            c.held = c.held[..0];
        }
        wbuf.clear();
        woff = 0;
        // Shared ranges go out from their blobs only on a plain socket.
        shared_gather(c.tls < 0, wbuf);
        if c.out.len > 0 {
            wbuf.append(c.out);
            spill.free_slice(c.out);
            c.out = c.out[..0];
        }
        sealed = wbuf.len;
        // advance takes the answering as a block, so that its HTTP/1.1 copy
        // captures none of the h2 driver's state: one advance for both took
        // that state as 27 more arguments at each call, and stayed a C
        // function of its own, which cost an HTTP/1.1 request about 170
        // instructions (task 056).
        let going = if c.h2 >= 0 {
            advance(c, hup, wake) { c, ev =>
                let before = wbuf.len;
                let rest, full = h2_answer(c, driving, h2conns[c.h2], h2streams, spill, rbuf, rlen, wbuf, cfg.write_buffer,
                                           h2out, h2fields, h2pseudo, h2cookie, h2huff, h2fb, common, cfg, fresh, stopping, now, ev,
                                           wake_at, timers, overdue, h2gen, H);
                let moved = rest != rlen || wbuf.len > before;
                rlen = rest;
                EpollTurn { moved: moved, full: full }
            }
        } else {
            advance(c, hup, wake) { c, ev =>
                let rest, done, full = answer(c, rbuf, rlen, wbuf, common, cfg, fresh, stopping, now, ev, H) { false };
                rlen = rest;
                if c.x.stream.rearm && start_wait(c, timers, now) { overdue.push(c.x.stream.later.key); }
                EpollTurn { moved: done > 0, full: full }
            }
        };
        // Gathering ends with the turn: a CLOSED or HTTP/3 handler, outside
        // it, copies into its own output.
        guard going else {
            shared_gather(false, wbuf);
            return false;
        }
        if rlen > 0 {
            c.held = spill.alloc_slice(rlen);
            copy_into(c.held, rbuf[..rlen]);
        }
        if shared_pending() > 0 {
            gbuf.clear();
            shared_flatten(wbuf, woff, gbuf);
            c.out = spill.alloc_slice(gbuf.len);
            copy_into(c.out, gbuf);
        } else if woff < wbuf.len {
            c.out = spill.alloc_slice(wbuf.len - woff);
            copy_into(c.out, wbuf[woff..]);
        }
        shared_gather(false, wbuf);
        return true;
    }

    // Registers OUT while the connection has bytes the socket didn't take, and
    // drops it once they're sent, as libuv does: kqueue reports EV_CLEAR's
    // write filter as each ACK frees buffer space, a wake-up per response.
    // False if epoll_ctl fails.
    fn watch(i: i64) -> bool {
        let c .= conns[i];
        let want = c.out.len > 0 || c.x.stream.file >= 0;
        if want == c.watch_out { return true; }
        let out: u32 = if want { EPOLLOUT } else { 0 };
        let r = net_epoll_ctl(ep, EPOLL_CTL_MOD, c.fd, EPOLLIN | out | EPOLLRDHUP | EPOLLET, i as u64);
        if r < 0 {
            report(Error { call: "epoll_ctl", code: -r });
            return false;
        }
        c.watch_out = want;
        return true;
    }

    // Answers what it can, sends the responses in one send, and reads more.
    // Edge-triggered epoll reports a socket again only after its state
    // changes, so this returns only once a send would block, the socket is
    // empty, the connection is done, which is false, or its read or drain-credit
    // budget sets ready for another turn (go). A recv that
    // filled less than it was given emptied the socket, and the next byte to
    // arrive raises a new event, so it isn't followed by a recv that would
    // block, unless hup: a close that arrived with the last bytes raises none.
    // While the exchange waits, it stops reading once rbuf is full; an
    // upgraded one's answer takes what arrives (holds_input). A answers,
    // given c and ev, and returns an EpollTurn.
    fn advance<A>(c: EpollConn<S>&, hup: bool, wake: const Event&) -> bool {
        var progress = false;
        var drained = false;
        var credited = false;
        var got = 0;
        c.ready = false;
        var ev = wake;
        loop {
            var full = false;
            if c.state == OPEN && (c.h2 >= 0 || c.x.stream.file < 0 &&
                                   (rlen > 0 || c.x.stream.open && c.x.body == BodyReader.None || ev.kind != NO_EVENT)) {
                let turn = A(c, ev);
                ev.kind = NO_EVENT;
                if turn.moved { progress = true; }
                full = turn.full;
            }
            if c.tls >= 0 {
                guard tls_seal(tls, c.tls, wbuf, sealed, c.state == CLOSING) else { return false; }
                sealed = wbuf.len;
            }
            while woff < wbuf.len + shared_pending() {
                let w = if shared_pending() > 0 { shared_send(c.fd, wbuf, woff) } else { net_send(c.fd, wbuf[woff..]) };
                if w == -EAGAIN { return wait(c, progress); }
                if w == -EINTR { continue; }
                guard w > 0 else { return false; }   // EPIPE, ECONNRESET: the client left
                woff += w;
                progress = true;
            }
            wbuf.clear();
            woff = 0;
            sealed = 0;
            shared_settle();
            if c.x.stream.framing == Framing.RawDrain && c.state == OPEN && c.x.stream.open {
                // One credit per turn keeps a publisher with a fast reader
                // from delaying other sockets, mail, and the timer sweep.
                if credited {
                    c.ready = true;
                    return wait(c, progress);
                }
                credited = true;
                c.x.stream.framing = Framing.Raw;
                ev = Event { kind: DRAINED, req: nothing, data: "", whole: false, trailers: "" };
                continue;
            }
            while c.x.stream.file >= 0 {
                let s .= c.x.stream;
                let w = net_sendfile(c.fd, s.file, s.file_off, s.file_left);
                if w == -EAGAIN { return wait(c, progress); }
                if w == -EINTR { continue; }
                // The client left, or the file ended short of what the head
                // promised.
                guard w > 0 else { return false; }
                s.file_off += w;
                s.file_left -= w;
                progress = true;
                if s.file_left == 0 {
                    net_file_close(s.file);
                    s.file = -1;
                    full = true;    // to answer what arrived meanwhile
                }
            }
            if c.state == CLOSING {
                net_shutdown(c.fd, SHUT_WR);
                c.state = DRAINING;
                c.deadline = now + cfg.linger_ms;
            }
            if full { continue; }
            if drained { return wait(c, progress); }
            if cfg.max_read > 0 && got >= cfg.max_read {
                c.ready = true;
                return wait(c, progress);
            }
            // answer leaves rbuf full only to refuse the request with 431 or
            // 413, so an OPEN connection always has room to read into.
            if rlen == 0 { c.x.since = now; }
            let room = if c.state == DRAINING { rbuf.len } else { rbuf.len - rlen };
            if room == 0 && c.x.stream.waiting { return wait(c, progress); }
            if c.tls >= 0 && c.state == OPEN {
                // 0: the handshake has bytes to send before it reads more.
                let r, empty = tls_recv(tls, c.tls, c.fd, rbuf[rlen..]);
                if r == -EAGAIN { return wait(c, progress); }
                if r == 0 {
                    drained = false;
                    continue;
                }
                guard r > 0 else { return false; }   // closed, reset, or a failed handshake
                got += r;
                rlen += r;
                drained = empty && !hup;
                // The first plaintext: if ALPN chose h2, the preface goes to
                // the h2 driver, never to answer, in the turn go lists the
                // connection for.
                if c.h2 == -1 {
                    if tls_h2(tls, c.tls) {
                        c.ready = true;
                        return wait(c, progress);
                    }
                    c.h2 = -2;
                }
                continue;
            }
            // A WAKE that finds the socket as the last recv left it reads nothing: the
            // next byte or close raises an edge, which clears empty.
            if c.empty { return wait(c, progress); }
            let r = if c.state == DRAINING { net_recv(c.fd, rbuf) }
                    else { net_recv(c.fd, rbuf[rlen..]) };
            if r == -EAGAIN {
                c.empty = true;
                return wait(c, progress);
            }
            if r == -EINTR { continue; }
            guard r > 0 else { return false; }   // the client closed or reset
            got += r;
            if c.state == OPEN { rlen += r; }
            drained = r < room && !hup;
            c.empty = drained;
        }
    }

    // Moves the deadline of a connection that's waiting on its socket.
    // Progress restarts the clock; the first bytes of a request after an
    // idle spell shorten it.
    fn wait(c: EpollConn<S>&, progress: bool) -> bool {
        guard c.state != DRAINING else { return true; }
        // A handshake has request_ms from the accept, however it progresses.
        guard c.tls < 0 || tls_ready(tls, c.tls) else { return true; }
        let writing = woff < wbuf.len + shared_pending() || c.x.stream.file >= 0;
        // An h2c connection's streams have their own limits (later's), so
        // the connection's is idle_ms, or write_ms while the client doesn't
        // take what it was sent.
        if c.h2 >= 0 {
            if progress { c.deadline = now + (if writing { cfg.write_ms } else { cfg.idle_ms }); }
            return true;
        }
        let idle = rlen == 0 && c.x.body == BodyReader.None && !c.x.stream.open && !c.x.stream.waiting && !writing;
        if progress { c.deadline = now + (if idle { cfg.idle_ms } else { busy_ms(c, writing, cfg) }); }
        else if !idle { c.deadline = min(c.deadline, now + busy_ms(c, writing, cfg)); }
        return true;
    }

    // Closes the connections past their deadline. One still waiting for the
    // rest of a request is sent a 408 first, if its socket takes it, and then
    // shut down and drained as any refusal is. An exchange that waits has its
    // own time limit instead.
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
                if c.state == OPEN && h.streams.len == 0 && c.out.len == 0 {
                    wbuf.clear();
                    h2_write_goaway(wbuf, h.last_stream, H2_NO_ERROR);
                    h.goaway = true;
                    if bye(c) { continue; }
                }
                close_conn(i);
                continue;
            }
            // A handshake that didn't finish in time gets no 408.
            if owes_408(c, c.out.len > 0 || c.x.stream.file >= 0) && (c.tls < 0 || tls_ready(tls, c.tls)) {
                wbuf.clear();
                refuse(wbuf, 408, common);
                if bye(c) { continue; }
            }
            close_conn(i);
        }
    }

    // Sends wbuf, a refusal or a GOAWAY, in one send, with close_notify after
    // it over TLS, then shuts the connection down and gives the client
    // cfg.linger_ms to close. False when the socket didn't take it all.
    fn bye(c: EpollConn<S>&) -> bool {
        if c.tls >= 0 && !tls_seal(tls, c.tls, wbuf, 0, true) { wbuf.clear(); }
        let sent = wbuf.len > 0 && net_send(c.fd, wbuf) == wbuf.len;
        wbuf.clear();
        guard sent else { return false; }
        if c.held.len > 0 {
            spill.free_slice(c.held);
            c.held = c.held[..0];
        }
        net_shutdown(c.fd, SHUT_WR);
        c.state = DRAINING;
        c.deadline = now + cfg.linger_ms;
        return true;
    }

    // Whether the last wait returned events. Under load the next ones are
    // usually queued by the time a batch is done, so the next wait only polls,
    // and the worker sleeps only after a poll comes back empty: that skips the
    // wakeup a blocking wait costs each batch.
    // Closes the listener and the connections between requests, and gives
    // the rest cfg.grace_ms to finish.
    fn begin_stop() {
        stopping = true;
        stop_by = now + cfg.grace_ms;
        close_listeners();
        for k in lfds.len {
            lfds[k] = -1;
            paused_at[k] = false;
        }
        paused = false;
        if h3_serves(tls) { h3_stop(tls, now); }
        for i in conns.len {
            let c .= conns[i];
            // An h2c connection sends GOAWAY, and closes once its streams end.
            if c.fd >= 0 && c.h2 >= 0 { go(i, false, none); }
            else if c.fd >= 0 && c.state == OPEN && idle(c) && c.out.len == 0 && c.x.stream.file < 0 { close_conn(i); }
            else if c.fd >= 0 && c.x.stream.waiting { c.x.keep_alive = false; }
        }
    }

    // Goes on with the exchange of connection i, which waited, with ev, its
    // WAKE or TIMEOUT, and then with what it holds.
    fn resume(i: i64, ev: const Event&) { go(i, false, ev); }

    // Drives connection i, and lists it for another turn after cfg.max_read
    // or a drain credit: neither needs another socket edge to resume.
    fn go(i: i64, hup: bool, ev: const Event&) {
        driving = i;
        guard drive(conns[i], hup, ev) && watch(i) else {
            close_conn(i);
            return;
        }
        let c .= conns[i];
        if c.ready && !c.listed {
            c.listed = true;
            turns.push(i as u64);
            // advance stopped at an h2 preface (ALPN): the connection's h2
            // state, here, off the request path, before any event drives it.
            if c.h2 == -1 && c.tls >= 0 && tls_h2(tls, c.tls) {
                c.h2 = h2conns.alloc_index(h2_conn(cfg, now)) as i32;
            }
        }
    }

    // The worker's own state and reply, for WORKER calls (worker_address).
    var worker_state = fresh;
    var worker_buf: u8[>..] = [];
    var worker_stream = Stream { .. };
    var worker_keep = false;

    // A message to key, for the exchange that waits for it, if any, or for
    // the worker.
    fn delivered(key: u64, tag: i32, bytes: const u8[:]) {
        if key == worker_key(cfg) {
            H(Event { kind: WORKER, req: nothing, data: bytes, whole: false, trailers: "", tag: tag }, &worker_state,
              Reply { buf: worker_buf, common: common, keep_alive: worker_keep, minor: 1, head: false, stream: worker_stream });
            worker_buf.clear();
            worker_stream = Stream { .. };
            return;
        }
        let i = later_slot(key);
        guard i < conns.len else { return; }
        if conns[i].h2 >= 0 {
            let k = h2_key_index(key);
            guard conns[i].fd >= 0 && conns[i].state == OPEN && k < h2streams.len && h2_waits_for(h2streams[k], i, key) else { return; }
            cancel(timers, h2streams[k].x.timer);
            h2streams[k].x.stream.waiting = false;
            wake_at = k;
            let ev = Event { kind: WAKE, req: nothing, data: bytes, whole: false, trailers: "", tag: tag };
            resume(i, ev);
            wake_at = -1;
            return;
        }
        guard waits_for(conns[i], key) else { return; }
        cancel(timers, conns[i].x.timer);
        conns[i].x.stream.waiting = false;
        let ev = Event { kind: WAKE, req: nothing, data: bytes, whole: false, trailers: "", tag: tag };
        resume(i, ev);
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
            resume(i, ev);
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
        resume(i, ev);
    }

    // Delivers the wakes asked for so far: those they ask for wait for the next call.
    fn wake_all() {
        guard woken.len > 0 else { return; }
        let asked = woken.len;
        for k in asked / 2 { delivered(woken[2*k], woken[2*k+1] as! u32 as i32, ""); }
        drop_first(woken, asked);
    }

    var hot = false;
    var failed = Error { call: "", code: 0 };
    loop {
        // A wait ends within a second, for the sweep and a paused accept's
        // retry, or at the next timer; the waker ends it for mail and a stop.
        var timeout: i32 = if hot || overdue.len > 0 || turns.len > 0 || woken.len > 0 { 0 } else { wait_for(timers, now) };
        if h3_serves(tls) { timeout = h3_wait(tls, now, timeout); }
        let n = net_epoll_wait(ep, events, timeout);
        if n == -EINTR { continue; }
        guard n >= 0 else {
            failed = Error { call: "epoll_wait", code: -n };
            break;
        }
        hot = n > 0;
        now = net_clock_ms();
        let t = net_time_s();
        if t != date_s {
            common.clear();
            common_fields(common, cfg.server, t);
            date_s = t;
        }
        for ev in events[..n] {
            if ev.tag == EPOLL_LISTENER || (ev.tag < EPOLL_WAKE && ev.tag >= EPOLL_WAKE - MAX_LISTENERS) {
                let k: i64 = if ev.tag == EPOLL_LISTENER { 0 } else { (EPOLL_WAKE - ev.tag) as i64 };
                if k < lfds.len && lfds[k] >= 0 { accept_from(k); }
                continue;
            }
            if ev.tag == EPOLL_WAKE {
                // A worker's mail asks its wakes now, as mail did, not after the pass's other events.
                if waiting { mail_take(box) { key, tag, bytes => delivered(key, tag, bytes); }; wake_all(); }
                continue;
            }
            if h3_serves(tls) {
                let hk = h3_listener(tls, ev.tag);
                if hk >= 0 {
                    h3_ready(tls, hk, cfg, fresh, common, now, H);
                    continue;
                }
            }
            // An outbound socket that wait_socket armed with its exchange's key.
            if waiting && ev.tag >= SOCKET_KEYS {
                delivered(ev.tag, SOCKET_READY, "");
                continue;
            }
            let i = ev.tag as i64;
            // A WAKE earlier in the batch may have closed it.
            if conns[i].fd < 0 { continue; }
            conns[i].empty = false;
            go(i, ev.events & (EPOLLRDHUP | EPOLLHUP | EPOLLERR) != 0, none);
        }
        // One more turn each for the connections listed so far, after this
        // pass's events. A slot that closed and opened again since has ready
        // unset. hup, since a close may have come with the bytes left.
        let listed = turns.len;
        for k in listed {
            let i = turns[k] as i64;
            conns[i].listed = false;
            if conns[i].fd >= 0 && conns[i].ready { go(i, true, none); }
        }
        drop_first(turns, listed);
        wake_all();
        if h3_serves(tls) { h3_tick(tls, cfg, fresh, common, now, H); }
        if waiting { expire(timers, now) { key => timed_out(key, true); }; }
        // With or without a box: without one, every later is owed its TIMEOUT.
        let owed = overdue.len;
        for k in owed { timed_out(overdue[k], false); }
        drop_first(overdue, owed);
        if now >= next_sweep {
            sweep();
            next_sweep = now + 1000;
        }
        if paused { accept_all(); }
        if !stopping && stops() != started { begin_stop(); }
        if stopping && (open == 0 && h3_count(tls) == 0 || now >= stop_by) { break; }
    }
    for i in conns.len {
        if conns[i].fd >= 0 { close_conn(i); }
    }
    if h3_serves(tls) { h3_end(tls, H); }
    net_loop_bind(-1);
    close_waiting(box, waker);
    net_close(ep);
    close_listeners();
    return failed;
}
