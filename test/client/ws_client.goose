// The blocking WebSocket client (wsclient.goose) against a TCP listener in
// this program. The listener records the opening request and the masked
// frames. The client checks the accept value, answers a ping with a pong,
// joins a fragmented text message, and returns from a refused port.
import std;
import http from "../../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.websocket;
import http.wsclient;

struct Wire { step: i64, ok: i64 }

let STEP_OPENING = 1;
let STEP_TEXT = 2;
let STEP_PONG = 3;
let STEP_BINARY = 4;
let STEP_CLOSE = 5;

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

fn write_frame(fd: i32, fin: bool, op: u8, data: const u8[:]) {
    var out: u8[>..] = [];
    out.push((if fin { 0x80 } else { 0 }) | op);
    assert(data.len < 126);
    out.push(data.len as! u8);
    out.append(data);
    send_fd(fd, out);
}

fn report(step: i64, ok: i64) { assert(qput(Wire { step: step, ok: ok })); }

fn same(g: Got&, op: u8, data: const u8[:]) -> i64 {
    return if g.masked && g.op == op && g.data == data { 1 } else { 0 };
}

thread_fn server(lfd: i32) {
    let fd = http::net_accept(lfd, 0);
    assert(fd >= 0);
    var req: u8[>..] = [];
    assert(read_headers(fd, req));
    let end = find(req, "\r\n\r\n");
    assert(end >= 0 && end + 4 == req.len);
    report(STEP_OPENING, opening_ok(req));
    var answer: u8[>..] = [];
    answer.append("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ");
    answer.append(http::ws_accept(key_of(req)));
    answer.append("\r\n\r\n");
    send_fd(fd, answer);

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
    let close, close_ok = read_frame(fd);
    assert(close_ok);
    var code: u8[2] = [3, 232];
    report(STEP_CLOSE, same(close, 8, code));
    http::net_close(fd);

    let bad = http::net_accept(lfd, 0);
    assert(bad >= 0);
    var bad_req: u8[>..] = [];
    assert(read_headers(bad, bad_req));
    send_fd(bad, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n\r\n");
    var sink: u8[256] = [0; 256];
    loop {
        let n = http::net_recv(bad, sink);
        if n <= 0 { break; }
    }
    http::net_close(bad);
    http::net_close(lfd);
}

fn take(step: i64, label: const u8[:]) {
    let w = qget<Wire>();
    let ok = w.step == step && w.ok == 1;
    print(label, ": ", ok);
    assert(ok);
}

fn main() {
    let lfd, port = listener(16);
    let t = thread_spawn(server, lfd);
    var url: u8[>..] = [];
    format(url, "ws://127.0.0.1:", port, "/ws");

    var conn, err = http::ws_client_connect(url, 2000);
    assert(err.code == 0);
    take(STEP_OPENING, "opening request has no permessage-deflate");

    assert(http::ws_client_text(conn, "hello").code == 0);
    take(STEP_TEXT, "masked text");

    let reply, reply_err = http::ws_client_recv(conn);
    print("reply: ", reply.data);
    assert(reply_err.code == 0 && reply.op == http::WSC_TEXT && reply.data == "after");
    take(STEP_PONG, "pong");

    var raw: u8[3] = [1, 2, 3];
    assert(http::ws_client_binary(conn, raw).code == 0);
    take(STEP_BINARY, "masked binary");

    let joined, joined_err = http::ws_client_recv(conn);
    print("joined message: ", joined_err.code == 0 && joined.op == http::WSC_TEXT && joined.data == "hello");
    assert(joined_err.code == 0 && joined.data == "hello");

    assert(http::ws_client_close(conn).code == 0);
    assert(conn.s.fd < 0);
    take(STEP_CLOSE, "close");

    var bad, bad_err = http::ws_client_connect(url, 2000);
    print("bad accept: ", bad_err.call);
    assert(bad_err.call == "handshake" && bad_err.code != 0 && bad.s.fd < 0);
    http::ws_client_close(bad);

    thread_wait(t);

    let gone, gone_port = listener(1);
    http::net_close(gone);
    var refused_url: u8[>..] = [];
    format(refused_url, "ws://127.0.0.1:", gone_port, "/ws");
    var refused, refused_err = http::ws_client_connect(refused_url, 2000);
    print("refused: ", refused_err.call, " ", refused_err.code == http::ECONNREFUSED, ", socket ", refused.s.fd);
    assert(refused_err.call == "connect" && refused_err.code == http::ECONNREFUSED && refused.s.fd < 0);

    print("wsclient ok");
}
