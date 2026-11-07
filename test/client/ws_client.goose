// The blocking WebSocket client (wsclient.goose), first against a TCP
// listener in this program that records the opening request and the masked
// frames: the accept value, a pong for a ping, a fragmented message, frames
// with a 16-bit length, the answer to a server's Close, the Close for a
// masked frame, and a refused port. Then over wss, against serve_epoll with
// http.websocket echoing, on a Unix socket in TMPDIR, with a certificate
// goose-tls makes here.
import std;
import os;
import http from "../../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;
import http.websocket;
import http.wsclient;

struct Wire { step: i64, ok: i64 }

let STEP_OPENING = 1;
let STEP_TEXT = 2;
let STEP_PONG = 3;
let STEP_BINARY = 4;
let STEP_LONG = 5;
let STEP_CLOSE = 6;
let STEP_ANSWER = 7;
let STEP_FAIL = 8;

fn listener(backlog: i32) -> i32, i32 {
    let a, ok = http::address("127.0.0.1");
    assert(ok);
    let fd = http::net_listen(a.ip, 0, backlog, 0);
    assert(fd >= 0);
    return fd, http::net_port(fd);
}

fn send_fd(fd: i32, bytes: const u8[:]) {
    var at = 0;
    while at < bytes.len {
        let n = http::net_send(fd, bytes[at..]);
        assert(n > 0);
        at += n;
    }
}

fn read_n(fd: i32, n: i64, out: u8[>..]&) -> bool {
    var buf: u8[4096] = [0; 4096];
    let base = out.len;
    while out.len - base < n {
        let want = min(buf.len, n - (out.len - base));
        let got = http::net_recv(fd, buf[..want]);
        if got <= 0 { return false; }
        out.append(buf[..got]);
    }
    return true;
}

fn read_headers(fd: i32, out: u8[>..]&) -> bool {
    var buf: u8[1024] = [0; 1024];
    while find(out, "\r\n\r\n") < 0 {
        let n = http::net_recv(fd, buf);
        if n <= 0 { return false; }
        out.append(buf[..n]);
        if out.len > 8192 { return false; }
    }
    return true;
}

fn opening_ok(req: const u8[:]) -> i64 {
    let at = find(req, "Sec-WebSocket-Key: ");
    let key_at = at + 19;
    let key_ok = at >= 0 && key_at + 26 <= req.len && req[key_at + 24] == '\r' && req[key_at + 25] == '\n';
    let ok = key_ok && starts_with(req, "GET /ws HTTP/1.1\r\n") && find(req, "Upgrade: websocket\r\n") >= 0
        && find(req, "Connection: Upgrade\r\n") >= 0 && find(req, "Sec-WebSocket-Version: 13\r\n") >= 0
        && find(req, "permessage-deflate") < 0 && find(req, "Sec-WebSocket-Extensions") < 0;
    return if ok { 1 } else { 0 };
}

fn key_of(req: const u8[:]) -> u8[>..] {
    let at = find(req, "Sec-WebSocket-Key: ");
    var key: u8[>..] = [];
    if at >= 0 && at + 19 + 24 <= req.len { key.append(req[at + 19..at + 19 + 24]); }
    return key;
}

// Accepts a connection and answers its opening request with a 101: the
// socket, and 1 when the request was as opening_ok wants it.
fn accept_ws(lfd: i32) -> i32, i64 {
    let fd = http::net_accept(lfd, 0);
    assert(fd >= 0);
    var req: u8[>..] = [];
    assert(read_headers(fd, req));
    let end = find(req, "\r\n\r\n");
    assert(end >= 0 && end + 4 == req.len);
    var answer: u8[>..] = [];
    answer.append("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ");
    answer.append(http::ws_accept(key_of(req)));
    answer.append("\r\n\r\n");
    send_fd(fd, answer);
    return fd, opening_ok(req);
}

struct Got { op: u8 = 0, masked: bool = false, data: u8[>..] }

fn read_frame(fd: i32) -> Got, bool {
    var head: u8[>..] = [];
    guard read_n(fd, 2, head) else { return Got { .. }, false; }
    let masked = head[1] & 0x80 != 0;
    var n = (head[1] & 0x7F) as i64;
    if n == 126 {
        guard read_n(fd, 2, head) else { return Got { .. }, false; }
        n = (head[2] as i64) << 8 | head[3];
    } else if n == 127 {
        guard read_n(fd, 8, head) else { return Got { .. }, false; }
        n = 0;
        for i in 8 { n = n << 8 | head[2 + i]; }
    }
    var mask: u8[4] = [0; 4];
    if masked {
        var m: u8[>..] = [];
        guard read_n(fd, 4, m) else { return Got { .. }, false; }
        for i in 4 { mask[i] = m[i]; }
    }
    var data: u8[>..] = [];
    if n > 0 {
        guard read_n(fd, n, data) else { return Got { .. }, false; }
    }
    if masked {
        for i in data.len { data[i] = data[i] ^ mask[i & 3]; }
    }
    return Got { op: head[0] & 0x0F, masked: masked, data: data }, true;
}

// A server's frame: unmasked, unless mask, with a 7-bit or 16-bit length.
fn write_frame(fd: i32, fin: bool, op: u8, data: const u8[:], mask: bool = false) {
    var out: u8[>..] = [];
    out.push((if fin { 0x80 } else { 0 }) | op);
    let m: u8 = if mask { 0x80 } else { 0 };
    if data.len < 126 {
        out.push(m | data.len as! u8);
    } else {
        assert(data.len < 65536);
        out.push(m | 126);
        out.push((data.len >> 8) as! u8);
        out.push(data.len as! u8);
    }
    if mask { out.append("\0\0\0\0"); }
    out.append(data);
    send_fd(fd, out);
}

fn report(step: i64, ok: i64) { assert(qput(Wire { step: step, ok: ok })); }

fn same(g: Got&, op: u8, data: const u8[:]) -> i64 {
    return if g.masked && g.op == op && g.data == data { 1 } else { 0 };
}

fn long_text() -> u8[>..] {
    var s: u8[>..] = [];
    for i in 300 { s.push('a' + (i % 26) as! u8); }
    return s;
}

// Reads frames until the socket ends, so the client's close isn't reset.
fn drain(fd: i32) {
    var sink: u8[256] = [0; 256];
    loop {
        let n = http::net_recv(fd, sink);
        if n <= 0 { break; }
    }
    http::net_close(fd);
}

thread_fn server(lfd: i32) {
    let fd, opening = accept_ws(lfd);
    report(STEP_OPENING, opening);

    let text, text_ok = read_frame(fd);
    assert(text_ok);
    report(STEP_TEXT, same(text, 1, "hello"));

    write_frame(fd, true, 9, "z");
    let pong, pong_ok = read_frame(fd);
    assert(pong_ok);
    report(STEP_PONG, same(pong, 10, "z"));
    write_frame(fd, true, 1, "after");

    let bin, bin_ok = read_frame(fd);
    assert(bin_ok);
    var raw: u8[3] = [1, 2, 3];
    report(STEP_BINARY, same(bin, 2, raw));

    write_frame(fd, false, 1, "hel");
    write_frame(fd, true, 0, "lo");

    let long, long_ok = read_frame(fd);
    assert(long_ok);
    report(STEP_LONG, same(long, 1, long_text()));
    write_frame(fd, true, 1, long_text());

    let close, close_ok = read_frame(fd);
    assert(close_ok);
    var normal: u8[2] = [3, 232];
    report(STEP_CLOSE, same(close, 8, normal));
    write_frame(fd, true, 8, normal);
    http::net_close(fd);

    let bad = http::net_accept(lfd, 0);
    assert(bad >= 0);
    var bad_req: u8[>..] = [];
    assert(read_headers(bad, bad_req));
    send_fd(bad, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n\r\n");
    drain(bad);

    // A server's Close, 1001, is answered with 1001.
    let going, going_opening = accept_ws(lfd);
    var away: u8[2] = [3, 233];
    write_frame(going, true, 8, away);
    let answer, answer_ok = read_frame(going);
    report(STEP_ANSWER, if answer_ok { same(answer, 8, away) } else { 0 });
    drain(going);

    // A masked frame from the server fails the connection with 1002.
    let wrong, wrong_opening = accept_ws(lfd);
    write_frame(wrong, true, 1, "x", true);
    let fail, fail_ok = read_frame(wrong);
    var protocol: u8[2] = [3, 234];
    report(STEP_FAIL, if fail_ok { same(fail, 8, protocol) } else { 0 });
    drain(wrong);
    http::net_close(lfd);
}

fn take(step: i64, label: const u8[:]) {
    let w = qget<Wire>();
    let ok = w.step == step && w.ok == 1;
    print(label, ": ", ok);
    assert(ok);
}

struct Echo { ws: http::WebSocket = http::WebSocket { .. } }

fn echo(ev: http::Event, st: Echo&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        http::ws_upgrade(ev.req, st.ws, out);
    } else {
        http::ws_read(ev, st.ws, out) { op, data, o => http::ws_send(o, op, data); };
    }
}

thread_fn tls_worker(cfg: http::Config, ctx: tls::Context) {
    var server = http::tls_server(ctx);
    let e = http::serve_epoll(cfg, Echo { .. }, server) { ev, st, out => echo(ev, st, out); };
    http::release(server);
    if e.code != 0 { http::report(e); }
}

fn unix_address(name: const u8[:]) -> u8[>..] {
    var dir: u8[>..] = [];
    var a: u8[>..] = [];
    if env("TMPDIR", dir) && dir.len > 0 { format(a, "unix:", dir, "/", name); }
    else { format(a, "unix:", name); }
    return a;
}

// Waits for the server at address to listen.
fn listening(address: const u8[:]) {
    for i in 500 {
        var s, e = http::connect(address, 0, 1000);
        if e.code == 0 {
            http::hangup(s);
            return;
        }
        sleep_ms(10);
    }
    abort(str("nothing listens at ", address));
}

fn plain() {
    let lfd, port = listener(16);
    let t = thread_spawn(server, lfd);
    var url: u8[>..] = [];
    format(url, "ws://127.0.0.1:", port, "/ws");
    var session = http::session(2000);

    var conn, err = http::ws_client_connect(session, url);
    assert(err.code == 0);
    take(STEP_OPENING, "opening request has no permessage-deflate");

    assert(http::ws_client_text(conn, "hello").code == 0);
    take(STEP_TEXT, "masked text");

    let reply, reply_err = http::ws_client_recv(conn);
    print("reply: ", reply.data);
    assert(reply_err.code == 0 && reply.op == http::WS_TEXT && reply.data == "after");
    take(STEP_PONG, "pong");

    var raw: u8[3] = [1, 2, 3];
    assert(http::ws_client_binary(conn, raw).code == 0);
    take(STEP_BINARY, "masked binary");

    let joined, joined_err = http::ws_client_recv(conn);
    print("joined message: ", joined_err.code == 0 && joined.op == http::WS_TEXT && joined.data == "hello");
    assert(joined_err.code == 0 && joined.data == "hello");

    assert(http::ws_client_text(conn, long_text()).code == 0);
    take(STEP_LONG, "16-bit length sent");
    let long, long_err = http::ws_client_recv(conn);
    print("16-bit length received: ", long_err.code == 0 && long.data == long_text());

    assert(http::ws_client_close(conn).code == 0);
    assert(conn.session.s.fd < 0);
    take(STEP_CLOSE, "close");

    var bad, bad_err = http::ws_client_connect(session, url);
    print("bad accept: ", bad_err.call);
    assert(bad_err.call == "handshake" && bad_err.code != 0 && bad.session.s.fd < 0);
    http::ws_client_close(bad);

    var going, going_err = http::ws_client_connect(session, url);
    assert(going_err.code == 0);
    let gone, gone_err = http::ws_client_recv(going);
    print("server's close: ", gone_err.call, " ", gone_err.code);
    take(STEP_ANSWER, "close answered");

    var wrong, wrong_err = http::ws_client_connect(session, url);
    assert(wrong_err.code == 0);
    let masked, masked_err = http::ws_client_recv(wrong);
    print("masked frame: ", masked_err.call);
    take(STEP_FAIL, "fails with 1002");

    thread_wait(t);

    let closed, closed_port = listener(1);
    http::net_close(closed);
    var refused_url: u8[>..] = [];
    format(refused_url, "ws://127.0.0.1:", closed_port, "/ws");
    var refused, refused_err = http::ws_client_connect(session, refused_url);
    print("refused: ", refused_err.call, " ", refused_err.code == http::ECONNREFUSED, ", socket ", refused.session.s.fd);
    assert(refused_err.call == "connect" && refused_err.code == http::ECONNREFUSED && refused.session.s.fd < 0);
    http::free(session);
}

fn secure() {
    var chain: u8[>..] = [];
    var key: u8[>..] = [];
    let failed = tls::run() {
        let k = tls::key_generate(tls::P256);
        chain = tls::self_signed(k, ["localhost"], 1);
        key = tls::key_pem(k);
        tls::free(k);
    };
    assert(failed.len == 0);
    let ctx, ok = tls::server(chain, key, ["http/1.1"]);
    assert(ok);
    let address = unix_address("ws-client-tls.sock");
    let w = thread_spawn(tls_worker, http::Config { address: address, workers: 1, tls: true, .. }, ctx);
    listening(address);

    var session, trusted = http::session_trusting(chain, 5000);
    assert(trusted);
    session.via.append(address);
    var conn, err = http::ws_client_connect(session, "wss://localhost/ws");
    print("wss connect: ", err.call, err.code);
    assert(err.code == 0);
    assert(http::ws_client_text(conn, "over tls").code == 0);
    let back, back_err = http::ws_client_recv(conn);
    print("wss echo: ", back.data);
    assert(http::ws_client_binary(conn, long_text()).code == 0);
    let long, long_err = http::ws_client_recv(conn);
    print("wss 16-bit echo: ", long_err.code == 0 && long.op == http::WS_BINARY && long.data == long_text());
    print("wss close: ", http::ws_client_close(conn).code);

    http::free(session);
    http::stop();
    thread_wait(w);
    tls::free(ctx);
}

fn main() {
    plain();
    secure();
    print("wsclient ok");
}
