// HTTP/1.1 and h2 over TLS in serve_epoll and serve, with goose-tls's server
// TLS 1.3, written in Goose over OpenSSL 3's libcrypto (task 014). Only a
// program that imports this module needs that package, which its root file
// declares at the reference this file names:
//
//   import http from "github.com/kaitk/goose-http@<tag>";
//   import tls from "github.com/kaitk/goose-tls@v0.0.6";
//   import http.tls;
//
// The listeners with Listener.tls (or Config.tls for Config.port's) serve
// TLS, from a context the program makes once and hands each worker. Its
// ALPN protocols choose each connection's driver: h2 where the context lists
// "h2" and the client chose it, HTTP/1.1 otherwise.
//
//   let ctx, ok = tls::server_files("server.crt", "server.key", ["h2", "http/1.1"]);
//   http::run(cfg, ctx, worker);
//   tls::free(ctx);
//
//   thread_fn worker(cfg: http::Config, ctx: tls::Context) {
//       var server = http::tls_server(ctx);
//       http::exit_on_error(http::serve_epoll(cfg, fresh, server) { ev, st, out => ... });
//       http::release(server);
//   }
//
// A program that picks each connection's context at its ClientHello, as
// ACME's TLS-ALPN-01 needs, calls tls::choose_context(ctx) once before the
// workers start, gives each worker's server a value of its own type
// (tls_server(ctx, chooser)), and declares tls_hello for that type in this
// namespace, which the handshake calls once a connection:
//
//   fn http::tls_hello(c: Chooser&, conn: tls::Conn) {
//       if tls::offers(conn, "acme-tls/1") && ... { tls::use_context(conn, c.challenge); }
//   }
namespace http;

import std;
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import sys;
import epoll;

// One connection's TLS: ready once its handshake is done, and notified once
// close_notify is queued. A free slot holds the next free one.
struct TlsSlot {
    conn: tls::Conn,
    ready: bool,
    notified: bool,
    next: i32 = -1,
}

// A worker's TLS: the context its connections are accepted from, the
// buffer the socket's bytes are read into before they're fed to OpenSSL,
// the program's value that tls_hello is given for each connection paused at
// its ClientHello, and each connection's state, by the slot EpollConn.tls or
// RingConn.tls names, with the first free one. The chooser comes after the
// fields the loops read most: an empty struct takes a byte, which would move
// them.
struct TlsServerOf<C> {
    ctx: tls::Context,
    free: i32 = -1,
    wire: u8[16384],
    chooser: C,
    slots: TlsSlot[>..],
}

// A server whose connections keep the context they're accepted from.
struct OneContext {}
type TlsServer = TlsServerOf<OneContext>;

// A connection whose context was given to tls::choose_context, paused at its
// ClientHello, keeps that context: the program has no chooser.
fn tls_hello(c: OneContext&, conn: tls::Conn) {}

// A worker's TlsServer, on its own reference to ctx, which release frees.
fn tls_server(ctx: tls::Context) -> TlsServer {
    return TlsServer { ctx: tls::share(ctx), .. };
}

// A worker's server, on its own reference to ctx, that calls
// tls_hello(chooser, conn) for each connection paused at its ClientHello,
// once the program has called tls::choose_context(ctx). The program declares
// that tls_hello in the namespace http; it may move the connection with
// tls::use_context, and the handshake then goes on.
fn tls_server(ctx: tls::Context, chooser) {
    return TlsServerOf { ctx: tls::share(ctx), chooser: chooser, .. };
}

// Frees t's reference to its context, once its loop has returned. Contexts
// the chooser holds are the program's to free.
fn release<C>(t: TlsServerOf<C>&) {
    tls::free(t.ctx);
    t.ctx = tls::Context { .. };
}

// serve_epoll(cfg), whose listeners with tls serve it with t.
fn serve_epoll<H>(cfg: Config, t: TlsServer&) -> Error {
    return epoll_loop(cfg, false, t) { ev, st, out => whole(ev, out, H); };
}

// serve_epoll(cfg, fresh), whose listeners with tls serve it with t. The
// form without fresh takes no chooser: serve_epoll(cfg, t) would be as
// generic as serve_epoll(cfg, fresh).
fn serve_epoll<S, C, H>(cfg: Config, fresh: S, t: TlsServerOf<C>&) -> Error {
    return epoll_loop(cfg, fresh, t, H);
}

// serve(cfg), whose listeners with tls serve it with t. On Windows it fails
// with ENOSYS on a TLS listener.
fn serve<H>(cfg: Config, t: TlsServer&) -> Error {
    return ring_loop(cfg, false, t) { ev, st, out => whole(ev, out, H); };
}

// serve(cfg, fresh), whose listeners with tls serve it with t.
fn serve<S, C, H>(cfg: Config, fresh: S, t: TlsServerOf<C>&) -> Error {
    return ring_loop(cfg, fresh, t, H);
}

fn tls_serves<C>(t: TlsServerOf<C>&) -> bool { tls::ok(t.ctx) }

// A connection for a socket just accepted: its slot, or -1 when OpenSSL
// can't make one.
fn tls_open<C>(t: TlsServerOf<C>&) -> i32 {
    let c = tls::accept(t.ctx);
    guard tls::ok(c) else { return -1; }
    let s = TlsSlot { conn: c, ready: false, notified: false };
    if t.free >= 0 {
        let k = t.free;
        t.free = t.slots[k].next;
        t.slots[k] = s;
        return k;
    }
    t.slots.push(s);
    return (t.slots.len - 1) as i32;
}

fn tls_ready<C>(t: TlsServerOf<C>&, k: i32) -> bool { t.slots[k].ready }

// Whether slot k's client chose h2 by ALPN, once its handshake is done: the
// context lists "h2" (tls::server's protocols), and the client offered it.
// The loops ask once a connection, and keep the answer.
fn tls_h2<C>(t: TlsServerOf<C>&, k: i32) -> bool { tls::alpn(t.slots[k].conn) == "h2" }

// Reads plaintext into buf from what slot k holds, through its handshake
// first, until buf is full or OpenSSL wants more input. Returns the count,
// and whether the connection is done after it: the client sent
// close_notify, or the handshake or a record failed.
fn tls_plain(s: TlsSlot&, buf: u8[:], chooser) -> i64, bool {
    if !s.ready {
        var h = tls::handshake(s.conn);
        if h == tls::HELLO {
            tls_hello(chooser, s.conn);
            h = tls::handshake(s.conn);
        }
        if h == 0 { s.ready = true; }
        else if h != tls::WANT_INPUT { return 0, true; }
    }
    var got = 0;
    if s.ready {
        while got < buf.len {
            let r = tls::read(s.conn, buf[got..]);
            if r > 0 {
                got += r;
                continue;
            }
            if r == tls::WANT_INPUT { break; }
            return got, true;   // CLOSED or FAILED
        }
    }
    return got, false;
}

// Reads plaintext into buf from slot k's socket fd, through its handshake
// first. Returns the count, with whether the socket was emptied and every
// whole record read; 0 when the handshake has bytes to send before it can
// go on; -EAGAIN once the socket is empty; or another value below 0 when
// the connection is done: the client closed it, sent close_notify, or failed
// the handshake. What came before a close_notify is returned first, and the
// next call returns the close.
fn tls_recv<C>(t: TlsServerOf<C>&, k: i32, fd: i32, buf: u8[:]) -> i64, bool {
    let s .= t.slots[k];
    guard buf.len > 0 else { return -1, false; }
    var empty = false;
    loop {
        let got, done = tls_plain(s, buf, t.chooser);
        if got > 0 { return got, !done && empty && got < buf.len; }
        guard !done else { return -1, false; }
        if tls::pending(s.conn) > 0 { return 0, false; }
        if empty { return -EAGAIN, true; }
        let n = net_recv(fd, t.wire);
        if n == -EINTR { continue; }
        if n == -EAGAIN { return -EAGAIN, true; }
        guard n > 0 else { return -1, false; }
        guard tls::feed(s.conn, t.wire[..n]) == n else { return -1, false; }
        empty = n < t.wire.len;
    }
}

// tls_recv for bytes already received, as the ring delivers them: feeds
// them to slot k, and appends to out the plaintext they complete. False once
// the connection is done, after what came before; its alert, if any, waits
// for tls_seal.
fn tls_take<C>(t: TlsServerOf<C>&, k: i32, bytes: const u8[:], out: u8[>..]&) -> bool {
    let s .= t.slots[k];
    guard tls::feed(s.conn, bytes) == bytes.len else { return false; }
    loop {
        let end = out.len;
        out.resize(end + t.wire.len, 0);
        let got, done = tls_plain(s, out[end..], t.chooser);
        out.resize(end + got, 0);
        guard !done else { return false; }
        if got < t.wire.len { return true; }
    }
}

// Seals w[from..] for slot k, in its place, followed by close_notify if
// last: w ends with the bytes OpenSSL has waiting to send, the handshake's
// too. False when OpenSSL fails.
fn tls_seal<C>(t: TlsServerOf<C>&, k: i32, w: u8[>..]&, from: i64, last: bool) -> bool {
    let c = t.slots[k].conn;
    if from < w.len {
        guard tls::write(c, w[from..]) == w.len - from else { return false; }
    }
    if last { tls_notify(t, k); }
    var end = from;
    w.resize(end, 0);
    loop {
        let p = tls::pending(c);
        guard p > 0 else { break; }
        w.resize(end + p, 0);
        let n = tls::drain(c, w[end..]);
        guard n > 0 else { break; }
        end += n;
        w.resize(end, 0);
    }
    return true;
}

// Queues close_notify for slot k, once, after its handshake.
fn tls_notify<C>(t: TlsServerOf<C>&, k: i32) {
    guard t.slots[k].ready && !t.slots[k].notified else { return; }
    t.slots[k].notified = true;
    tls::shutdown(t.slots[k].conn);
}

// Frees slot k, after sending, when clean, close_notify, or the alert of a
// handshake that failed, in one send that may not take it all.
fn tls_close<C>(t: TlsServerOf<C>&, k: i32, fd: i32, clean: bool) {
    let c = t.slots[k].conn;
    if clean {
        tls_notify(t, k);
        var bye: u8[256] = [0; 256];
        let n = tls::drain(c, bye);
        if n > 0 { net_send(fd, bye[..n]); }
    }
    tls::free(c);
    t.slots[k] = TlsSlot { conn: tls::Conn { .. }, ready: false, notified: false, next: t.free };
    t.free = k;
}

// A loop with a TlsServer alone serves no HTTP/3, which needs http.h3's
// H3Server beside it; the loops call these only where h3_serves.
fn h3_serves<C>(t: TlsServerOf<C>&) -> bool { false }
fn h3_listen<C>(t: TlsServerOf<C>&, cfg: const Config&, k: i64, port: i32) -> Error { Error { call: "h3", code: EINVAL } }
fn h3_listener<C>(t: TlsServerOf<C>&, key: u64) -> i64 { -1 }
fn h3_ready<C, S, H>(t: TlsServerOf<C>&, k: i64, cfg: const Config&, fresh: const S&, common: const u8[:], now: i64) {}
fn h3_wait<C>(t: TlsServerOf<C>&, now: i64, limit: i32) -> i32 { limit }
fn h3_tick<C, S, H>(t: TlsServerOf<C>&, cfg: const Config&, fresh: const S&, common: const u8[:], now: i64) {}
fn h3_stop<C>(t: TlsServerOf<C>&, now: i64) {}
fn h3_count<C>(t: TlsServerOf<C>&) -> i64 { 0 }
fn h3_end<C, H>(t: TlsServerOf<C>&) {}
