// Outbound connections: TCP sockets, or Unix sockets, that the program opens
// to another server, such as a database. Two ways to drive one:
//
// - On a thread that runs no loop, such as a lane's, the calls block, each
//   with a time limit: connect, recv with a limit, send_all.
//
//     let s, e = http::connect("127.0.0.1", 5432, 5000);
//     guard e.code == 0 else { ... }
//     http::send_all(s, request, 5000);
//     let n = http::recv(s, buf, 5000);    // 0: the server closed
//     http::hangup(s);
//
// - In a handler on serve_epoll's loop, or serve's on io_uring, the worker
//   that asked owns the socket, and the calls never block: connect_start
//   starts the connect, wait_socket makes the exchange wait until the
//   socket is ready, as later does, and recv and send without a limit take
//   and give what the socket has room for now. The handler gets WAKE with
//   tag SOCKET_READY, or TIMEOUT.
//
// A host is localhost, an IPv4 or IPv6 address, or unix:PATH for a Unix
// socket on Linux and macOS. The blocking connect also takes a name, which it
// resolves; connect_start doesn't, since resolving one blocks.
namespace http;

import std;
import sys;
import message;
import forwarded;

// An outbound connection's socket; fd -1 for none.
struct Socket { fd: i32 = -1 }

// What wait_socket waits for: bytes to read, or the connection closed or
// failed; room to send, or the connect done.
let READABLE: u32 = EPOLLIN;
let WRITABLE: u32 = EPOLLOUT;

// WAKE's tag for an exchange that wait_socket made wait: its socket is ready
// for what it asked, or was, as a socket may stop being ready before the
// handler looks, so recv or send may still give -EAGAIN. A program's own
// tags avoid it.
let SOCKET_READY: i32 = -2147483647 - 1;

// The keys wait_socket gives the loop as event tags are at least this, and
// below the listeners' and the waker's tags (epoll.goose), as later_n
// leaves them, and a connection's own tag, its slot, is below
// Config.max_conns, at most 1 << 20 where exchanges can wait.
let SOCKET_KEYS: u64 = 1 << 20;

fn no_error() -> Error { Error { call: "", code: 0 } }

// Starts a connect to host and port, and returns the socket, which doesn't
// block. Its connect may still be going on: once it's writable, connected
// says how it went. An error for a host it can't take, or a connect that
// failed at once, such as one refused on some platforms.
fn connect_start(host: const u8[:], port: i64) -> Socket, Error {
    if starts_with(host, "unix:") {
        guard host.len > 5 else { return Socket { .. }, Error { call: "connect_start", code: EINVAL }; }
        let fd = net_connect(host[5..], 0, UNIX);
        guard fd >= 0 else { return Socket { .. }, Error { call: "connect", code: -fd }; }
        return Socket { fd: fd }, no_error();
    }
    guard port > 0 && port < 65536 else { return Socket { .. }, Error { call: "connect_start", code: EINVAL }; }
    let a, ok = literal(host);
    // A name needs a resolver, which would block the loop.
    guard ok else { return Socket { .. }, Error { call: "resolve", code: ENOSYS }; }
    let fd = net_connect(a.ip, port as i32, 0);
    guard fd >= 0 else { return Socket { .. }, Error { call: "connect", code: -fd }; }
    return Socket { fd: fd }, no_error();
}

// The address host is written as: localhost, or an IPv4 or IPv6 address,
// bracketed or not; false for a name to resolve.
fn literal(host: const u8[:]) -> Address, bool {
    var name = host;
    if host.len >= 2 && host[0] == '[' && host[host.len - 1] == ']' { name = host[1..host.len - 1]; }
    return address(if name == "localhost" { "127.0.0.1" } else { name });
}

// How connect_start's connect went, once the socket is writable: code 0 when it's
// connected, EINPROGRESS while it goes on, or why it failed, such as
// ECONNREFUSED. A failure is reported once.
fn connected(s: Socket) -> Error {
    let r = net_connected(s.fd);
    return Error { call: "connect", code: -r };
}

// Up to buf.len bytes the socket holds, without waiting: how many, 0 when
// the server has closed, -EAGAIN for none yet, or -code.
fn recv(s: Socket, buf: u8[:]) -> i64 { net_recv(s.fd, buf) }

// Sends what of data the socket has room for, without waiting: how many
// bytes, -EAGAIN for none, or -code, such as -EPIPE once the server has
// closed.
fn send(s: Socket, data: const u8[:]) -> i64 { net_send(s.fd, data) }

// Closes the socket, if it's open, and leaves s with none.
fn hangup(s: Socket&) {
    guard s.fd >= 0 else { return; }
    net_close(s.fd);
    s.fd = -1;
}

// Makes the exchange wait, after this call to the handler, until s is ready
// for events, READABLE or WRITABLE or both, for at most ms milliseconds:
// then the handler is called with WAKE, whose tag is SOCKET_READY, or with
// TIMEOUT. It is later (http.goose) with the socket as another way to end the
// wait, so a message to the exchange's address ends it too, and its
// limits, Config.mail_slots and Config.max_waiting, apply. On serve_epoll's
// loop on Linux and macOS, and serve's on io_uring; on serve's emulated ring
// and on Windows, it fails with ENOSYS, and the exchange doesn't wait.
// Once the wait ends, s stays armed on epoll, and its event may still come
// as a WAKE with SOCKET_READY in a later wait; io_uring cancels it.
fn wait_socket(out: Reply, s: Socket, events: u32, ms: i64) -> Error {
    guard s.fd >= 0 else { return Error { call: "wait_socket", code: EINVAL }; }
    let key = out.stream.later.key;
    // Without a box, later's TIMEOUT comes at once, and nothing need watch s.
    if out.stream.later.box.slot >= 0 {
        guard key >= SOCKET_KEYS && key < EPOLL_WAKE - MAX_LISTENERS else {
            return Error { call: "wait_socket", code: EINVAL };
        }
        let r = net_arm(s.fd, events, key);
        guard r == 0 else { return Error { call: "wait_socket", code: -r }; }
    }
    later(out, ms);
    return no_error();
}

// The most of a name's addresses connect tries.
let RESOLVED_MAX = 8;

// Connects to host and port, waiting up to ms milliseconds (-1: no limit),
// for a thread that runs no loop. The socket doesn't block: recv and
// send_all wait for it. An error as connect_start's, or ETIMEDOUT.
//
// A host that is a name is resolved first, with the system's resolver,
// which the time limit doesn't bound: resolve's ENOENT for a name with no
// address, or EAGAIN for a lookup that failed for now. Its addresses are
// tried in the resolver's order, up to RESOLVED_MAX, all within ms; the
// error is the last one's.
fn connect(host: const u8[:], port: i64, ms: i64) -> Socket, Error {
    let until = deadline(ms);
    let a, numeric = literal(host);
    guard !numeric && !starts_with(host, "unix:") else {
        var s, e = connect_start(host, port);
        guard e.code == 0 else { return s, e; }
        return finish_connect(s, until);
    }
    guard port > 0 && port < 65536 else { return Socket { .. }, Error { call: "connect", code: EINVAL }; }
    var addrs: u8[16 * RESOLVED_MAX] = [0; 16 * RESOLVED_MAX];
    let n = net_resolve(host, addrs);
    guard n > 0 else { return Socket { .. }, Error { call: "resolve", code: -n }; }
    var e = no_error();
    for i in n {
        let fd = net_connect(addrs[i * 16..i * 16 + 16], port as i32, 0);
        if fd < 0 {
            e = Error { call: "connect", code: -fd };
            continue;
        }
        let s, err = finish_connect(Socket { fd: fd }, until);
        guard err.code != 0 else { return s, err; }
        e = err;
        if err.code == ETIMEDOUT { break; }
    }
    return Socket { .. }, e;
}

// Waits until until for s's connect to end, and hangs s up when it failed.
fn finish_connect(s: Socket, until: i64) -> Socket, Error {
    var t = s;
    let r = ready_by(t, WRITABLE, until);
    let c = if r > 0 { net_connected(t.fd) } else if r == 0 { -ETIMEDOUT } else { r };
    guard c == 0 else {
        hangup(t);
        return t, Error { call: "connect", code: -c };
    }
    return t, no_error();
}

// Waits up to ms milliseconds (-1: no limit) for bytes, and returns as recv
// without a limit does, or -ETIMEDOUT.
fn recv(s: Socket, buf: u8[:], ms: i64) -> i64 {
    let until = deadline(ms);
    loop {
        let n = net_recv(s.fd, buf);
        if n == -EINTR { continue; }
        guard n == -EAGAIN else { return n; }
        let r = ready_by(s, READABLE, until);
        if r == 0 { return -ETIMEDOUT; }
        if r < 0 { return r; }
    }
}

// Sends all of data, waiting for room up to ms milliseconds in all (-1: no
// limit). Code 0, ETIMEDOUT, or the send's error, such as EPIPE.
fn send_all(s: Socket, data: const u8[:], ms: i64) -> Error {
    let until = deadline(ms);
    var at = 0;
    while at < data.len {
        let n = net_send(s.fd, data[at..]);
        if n > 0 {
            at += n;
            continue;
        }
        if n == -EINTR { continue; }
        guard n == -EAGAIN else { return Error { call: "send", code: -n }; }
        let r = ready_by(s, WRITABLE, until);
        if r == 0 { return Error { call: "send", code: ETIMEDOUT }; }
        if r < 0 { return Error { call: "poll", code: -r }; }
    }
    return no_error();
}

// The clock's time ms milliseconds from now, or -1 for no limit.
fn deadline(ms: i64) -> i64 { if ms < 0 { -1 } else { net_clock_ms() + ms } }

// Waits for s to be ready for events until the clock reaches until (-1: no
// limit): the bits it's ready for, 0 once until has passed, or -code.
fn ready_by(s: Socket, events: u32, until: i64) -> i32 {
    loop {
        let left = if until < 0 { -1 } else { min(max(until - net_clock_ms(), 0), 1 << 30) };
        let r = net_poll(s.fd, events, left as i32);
        if r != 0 || left == 0 { return r; }
    }
}
