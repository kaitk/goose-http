// A WebSocket client for a thread that runs no loop, such as a lane's or a
// command-line program's. It connects with the blocking socket, wraps that
// socket in goose-tls when the URL is wss, writes the HTTP/1.1 opening
// handshake, and then reads and writes masked frames (RFC 6455). It offers
// no extension, so the opening request has no permessage-deflate. Only a
// program that imports this module needs goose-tls and goose-hash, which
// its root file declares at the references this file names:
//
//   import http from "github.com/kaitk/goose-http@<tag>";
//   import tls from "github.com/kaitk/goose-tls@v0.0.6";
//   import hash from "github.com/kaitk/goose-hash@v0.0.4";
//   import http.wsclient;
//
//   var conn, err = http::ws_client_connect("ws://127.0.0.1:8080/ws", 5000);
//   http::ws_client_text(conn, "hello");
//   let msg, err = http::ws_client_recv(conn);
//   http::ws_client_close(conn);
//
// A program can import this module and http.websocket together.
namespace http;

import std;
import os;
import base64;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import sys;
import message;
import socket;
import client;

// Opcodes a caller sees on WsMessage, and the control opcodes this file
// answers itself. Not WS_TEXT and the rest: those belong to http.websocket.
let WSC_CONTINUATION: u8 = 0;
let WSC_TEXT: u8 = 1;
let WSC_BINARY: u8 = 2;
let WSC_CLOSE: u8 = 8;
let WSC_PING: u8 = 9;
let WSC_PONG: u8 = 10;

// Idle, then the handshake has finished, then a Close is sent, then the
// socket is gone. One value, so a send cannot run after the close has started
// and also pretend the handshake is still unfinished.
enum WscLife { Idle, Open, Closing, Done }

// One connection. scratch holds bytes read past the frame just taken, from
// at. frag holds a message whose later fragments are still coming, and
// frag_op is that message's opcode, or 0 when no fragment is open. frag is
// the one growable field, so it stays last.
struct WsClient {
    ms: i64 = 30000,
    // The longest message, in one frame or several.
    limit: i64 = 1 << 16,
    s: Socket = Socket { fd: -1 },
    c: tls::Conn,
    ctx: tls::Context,
    scratch: u8[..8192],
    at: i64 = 0,
    frag_op: u8 = 0,
    utf8: u32 = 0,
    phase: WscLife = WscLife.Idle,
    frag: u8[>..],
}

struct WsMessage {
    op: u8 = 0,
    data: u8[>..],
}

fn wsc_error(call: const u8[:]) -> Error { Error { call: call, code: EINVAL } }

// Opens url, ws:// or wss://, and finishes the opening handshake. ms limits
// each wait, 30,000 by default, and -1 means none. An Error whose call is
// "url", "resolve", "connect", "send", "recv", "tls", or "handshake".
fn ws_client_connect(url: const u8[:], ms: i64 = 30000) -> WsClient, Error {
    var w = WsClient { ms: ms, .. };
    // parse_url's slices point at rewritten, which stays live through the
    // handshake. tls::connect reads the host during that handshake.
    var rewritten: u8[>..] = [];
    if starts_with(url, "wss://") {
        rewritten.append("https://");
        rewritten.append(url[6..]);
    } else if starts_with(url, "ws://") {
        rewritten.append("http://");
        rewritten.append(url[5..]);
    } else {
        return w, wsc_error("url");
    }
    let u, ok = parse_url(rewritten);
    guard ok else { return w, wsc_error("url"); }

    let sock, e = connect(u.host, u.port, ms);
    guard e.code == 0 else { return w, e; }
    w.s = sock;
    if u.secure {
        let ctx, made = tls::client(["http/1.1"]);
        guard made else {
            wsc_hangup(w);
            return w, wsc_error("tls");
        }
        w.ctx = ctx;
        w.c = tls::connect(w.ctx, u.host);
        let h = wsc_tls_handshake(w);
        guard h.code == 0 else {
            wsc_hangup(w);
            return w, h;
        }
    }

    let key = wsc_key();
    var req: u8[>..] = [];
    req.append("GET ");
    req.append(u.target);
    req.append(" HTTP/1.1\r\nHost: ");
    req.append(u.authority);
    req.append("\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ");
    req.append(key);
    req.append("\r\nSec-WebSocket-Version: 13\r\n\r\n");
    let sent = wsc_put(w, req);
    guard sent.code == 0 else {
        wsc_hangup(w);
        return w, sent;
    }
    let hs = wsc_read_101(w, key);
    guard hs.code == 0 else {
        wsc_hangup(w);
        return w, hs;
    }
    w.phase = WscLife.Open;
    return w, no_error();
}

// Sends data in one masked text frame. call "send" when the connection is
// not open, "text" when data is not UTF-8, "frame" past limit.
fn ws_client_text(w: WsClient&, data: const u8[:]) -> Error {
    guard w.phase == WscLife.Open else { return wsc_error("send"); }
    var state: u32 = 0;
    guard wsc_utf8(data, state) && state == 0 else { return wsc_error("text"); }
    return wsc_send_frame(w, WSC_TEXT, data);
}

// Sends data in one masked binary frame. call "send" or "frame".
fn ws_client_binary(w: WsClient&, data: const u8[:]) -> Error {
    guard w.phase == WscLife.Open else { return wsc_error("send"); }
    return wsc_send_frame(w, WSC_BINARY, data);
}

// The next whole text or binary message. A ping is answered with a masked
// pong and is not returned. Fragments are joined. call "recv", "frame",
// "text", or "close" when the peer sends a Close, and then code is the
// close code, or 1006 when the socket ends with no Close.
fn ws_client_recv(w: WsClient&) -> WsMessage, Error {
    guard w.phase == WscLife.Open else { return WsMessage { .. }, wsc_error("recv"); }
    loop {
        var payload: u8[>..] = [];
        let fin, op, e = wsc_one_frame(w, payload);
        guard e.code == 0 else { return wsc_peer_end(w, e); }
        if op == WSC_PING {
            let p = wsc_send_frame(w, WSC_PONG, payload);
            guard p.code == 0 else { return wsc_dead(w, p); }
            continue;
        }
        if op == WSC_PONG { continue; }
        if op == WSC_CLOSE {
            let code = wsc_close_code(payload);
            wsc_hangup(w);
            return WsMessage { .. }, Error { call: "close", code: code };
        }
        if op == WSC_CONTINUATION {
            guard w.frag_op != 0 else { return wsc_dead(w, wsc_error("frame")); }
        } else {
            guard w.frag_op == 0 else { return wsc_dead(w, wsc_error("frame")); }
            w.frag_op = op;
            w.utf8 = 0;
        }
        if w.frag_op == WSC_TEXT {
            guard wsc_utf8(payload, w.utf8) else { return wsc_dead(w, wsc_error("text")); }
        }
        guard w.frag.len + payload.len <= w.limit else { return wsc_dead(w, wsc_error("frame")); }
        var msg = WsMessage { .. };
        if fin && w.frag.len == 0 {
            guard w.frag_op != WSC_TEXT || w.utf8 == 0 else { return wsc_dead(w, wsc_error("text")); }
            msg.op = w.frag_op;
            msg.data.append(payload);
            w.frag_op = 0;
            w.utf8 = 0;
            return msg, no_error();
        }
        w.frag.append(payload);
        if fin {
            guard w.frag_op != WSC_TEXT || w.utf8 == 0 else { return wsc_dead(w, wsc_error("text")); }
            msg.op = w.frag_op;
            msg.data.append(w.frag);
            w.frag.clear();
            w.frag_op = 0;
            w.utf8 = 0;
            return msg, no_error();
        }
    }
}

// Sends a Close with code 1000, reads until the peer ends the connection,
// and closes the socket. A second call does nothing. call "send" or "recv"
// when that wait fails. A peer that has already gone is code 0.
fn ws_client_close(w: WsClient&) -> Error {
    guard w.phase == WscLife.Open else {
        if w.phase != WscLife.Done { wsc_hangup(w); }
        return no_error();
    }
    // 1000 is normal closure, two big-endian bytes.
    var body: u8[2] = [3, 232];
    let sent = wsc_send_frame(w, WSC_CLOSE, body);
    guard sent.code == 0 else { return wsc_drop(w, sent); }
    w.phase = WscLife.Closing;
    for i in 64 {
        var payload: u8[>..] = [];
        let fin, op, e = wsc_one_frame(w, payload);
        if e.code != 0 {
            if e.call == "recv" && e.code == ECONNRESET {
                wsc_hangup(w);
                return no_error();
            }
            return wsc_drop(w, e);
        }
        if op == WSC_CLOSE {
            wsc_hangup(w);
            return no_error();
        }
        if op == WSC_PING {
            let p = wsc_send_frame(w, WSC_PONG, payload);
            guard p.code == 0 else { return wsc_drop(w, p); }
        }
        // After Close is sent, a data frame is discarded (RFC 6455 §5.5.1).
        guard fin || op == WSC_PONG || op == WSC_PING else { return wsc_drop(w, wsc_error("frame")); }
    }
    return wsc_drop(w, wsc_error("close"));
}

fn wsc_dead(w: WsClient&, e: Error) -> WsMessage, Error {
    wsc_hangup(w);
    return WsMessage { .. }, e;
}

fn wsc_peer_end(w: WsClient&, e: Error) -> WsMessage, Error {
    if e.call == "recv" && e.code == ECONNRESET {
        wsc_hangup(w);
        return WsMessage { .. }, Error { call: "close", code: 1006 };
    }
    return wsc_dead(w, e);
}

fn wsc_drop(w: WsClient&, e: Error) -> Error {
    wsc_hangup(w);
    return e;
}

fn wsc_close_code(payload: const u8[:]) -> i64 {
    if payload.len >= 2 { return (payload[0] as i64) << 8 | payload[1]; }
    if payload.len == 0 { return 1005; }
    return 1002;
}

// 16 random bytes, base64, the opening key (RFC 6455 §4.1).
fn wsc_key() -> u8[..24] {
    var r = rng { random_seed() };
    var raw: u8[16] = [0; 16];
    let a = rand_u64(r);
    let b = rand_u64(r);
    for i in 8 {
        raw[i] = (a >> (8 * i)) as! u8;
        raw[8 + i] = (b >> (8 * i)) as! u8;
    }
    var text: u8[>..] = [];
    base64::encode(text, raw);
    var key: u8[..24] = [];
    key.append(text[..min(text.len, 24)]);
    return key;
}

// Sec-WebSocket-Accept for key: base64 of SHA-1 of the key and the GUID.
fn wsc_accept(key: const u8[:]) -> u8[..28] {
    var joined: u8[..64] = [];
    joined.append(key[..min(key.len, 28)]);
    joined.append("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var text: u8[>..] = [];
    base64::encode(text, hash::sha1(joined));
    var accept: u8[..28] = [];
    accept.append(text);
    return accept;
}

fn wsc_token(value: const u8[:], want: const u8[:]) -> bool {
    var found = false;
    each_split(value, ',') { if eq_fold(trim(it), want) { found = true; } };
    return found;
}

// Reads the status and fields, leaves any bytes after them for the frames,
// and fails the handshake when the accept value does not match. An extension
// field fails too: this client offered none.
fn wsc_read_101(w: WsClient&, key: const u8[:]) -> Error {
    var raw: u8[>..] = [];
    var tmp: u8[1024] = [0; 1024];
    loop {
        let end = find(raw, "\r\n\r\n");
        if end >= 0 {
            let err = wsc_check_101(raw[..end + 4], key);
            let rest = raw[end + 4..];
            guard rest.len <= 8192 else { return wsc_error("handshake"); }
            w.scratch.clear();
            w.scratch.append(rest);
            w.at = 0;
            return err;
        }
        guard raw.len <= 8192 else { return wsc_error("handshake"); }
        let n, e = wsc_take(w, tmp);
        guard e.code == 0 else { return e; }
        guard n > 0 else { return Error { call: "recv", code: ECONNRESET }; }
        raw.append(tmp[..n]);
    }
}

fn wsc_check_101(raw: const u8[:], key: const u8[:]) -> Error {
    let eol = line_end(raw, 0);
    guard eol > 0 else { return wsc_error("handshake"); }
    let status = raw[..eol - 2];
    guard starts_with(status, "HTTP/1.") && status.len >= 12 && status[8] == ' ' else {
        return wsc_error("handshake");
    }
    let code, ok = parse_int(status[9..12]);
    guard ok && is_digit(status[9]) && code == 101 else { return wsc_error("handshake"); }
    let end = trailer_end(raw, eol);
    guard end >= eol + 2 else { return wsc_error("handshake"); }
    let fields = raw[eol..end - 2];
    let upgrade, has_up = field_in(fields, "Upgrade");
    let connection, has_conn = field_in(fields, "Connection");
    let accept, has_accept = field_in(fields, "Sec-WebSocket-Accept");
    let ext, has_ext = field_in(fields, "Sec-WebSocket-Extensions");
    guard has_up && wsc_token(upgrade, "websocket") else { return wsc_error("handshake"); }
    guard has_conn && wsc_token(connection, "upgrade") else { return wsc_error("handshake"); }
    guard !has_ext else { return wsc_error("handshake"); }
    let want = wsc_accept(key);
    guard has_accept && accept == want[..] else { return wsc_error("handshake"); }
    return no_error();
}

fn wsc_send_frame(w: WsClient&, op: u8, data: const u8[:]) -> Error {
    guard w.phase == WscLife.Open || w.phase == WscLife.Closing else { return wsc_error("send"); }
    guard op >= WSC_CLOSE || data.len <= w.limit else { return wsc_error("frame"); }
    var mask: u8[4] = [0; 4];
    var r = rng { random_seed() };
    let bits = rand_u64(r);
    for i in 4 { mask[i] = (bits >> (8 * i)) as! u8; }
    var frame: u8[>..] = [];
    frame.push(0x80 | op);
    let n = data.len;
    if n < 126 {
        frame.push(0x80 | n as! u8);
    } else if n < 65536 {
        frame.push(0x80 | 126);
        frame.push((n >> 8) as! u8);
        frame.push(n as! u8);
    } else {
        frame.push(0x80 | 127);
        for i in 8 { frame.push((n >> (56 - 8 * i)) as! u8); }
    }
    frame.append(mask);
    for i in n { frame.push(data[i] ^ mask[i & 3]); }
    return wsc_put(w, frame);
}

// One frame from the server. A masked frame fails the connection. An RSV
// bit fails it too, because no extension was negotiated.
fn wsc_one_frame(w: WsClient&, payload: u8[>..]&) -> bool, u8, Error {
    payload.clear();
    let e = wsc_need(w, 2);
    guard e.code == 0 else { return false, 0, e; }
    let b0 = w.scratch[w.at];
    let b1 = w.scratch[w.at + 1];
    if b0 & 0x70 != 0 || b1 & 0x80 != 0 { return false, 0, wsc_error("frame"); }
    let fin = b0 & 0x80 != 0;
    let op = b0 & 0x0F;
    var n = (b1 & 0x7F) as i64;
    var h: i64 = 2;
    if n == 126 { h = 4; }
    else if n == 127 { h = 10; }
    let e2 = wsc_need(w, h);
    guard e2.code == 0 else { return false, 0, e2; }
    if h == 4 {
        n = (w.scratch[w.at + 2] as i64) << 8 | w.scratch[w.at + 3];
    } else if h == 10 {
        if w.scratch[w.at + 2] & 0x80 != 0 { return false, 0, wsc_error("frame"); }
        n = 0;
        for i in 8 { n = n << 8 | w.scratch[w.at + 2 + i]; }
    }
    let control = op >= WSC_CLOSE;
    if control {
        if op > WSC_PONG || !fin || n > 125 { return false, 0, wsc_error("frame"); }
    } else if op > WSC_BINARY {
        return false, 0, wsc_error("frame");
    }
    if !control && n > w.limit { return false, 0, wsc_error("frame"); }
    w.at += h;
    let e3 = wsc_copy_out(w, n, payload);
    guard e3.code == 0 else { return false, 0, e3; }
    return fin, op, no_error();
}

fn wsc_compact(w: WsClient&) {
    guard w.at > 0 else { return; }
    var keep: u8[..8192] = [];
    keep.append(w.scratch[w.at..]);
    w.scratch.clear();
    w.scratch.append(keep);
    w.at = 0;
}

fn wsc_need(w: WsClient&, n: i64) -> Error {
    while w.scratch.len - w.at < n {
        wsc_compact(w);
        guard w.scratch.len < 8192 else { return wsc_error("frame"); }
        var tmp: u8[1024] = [0; 1024];
        let room = min(1024, 8192 - w.scratch.len);
        let got, e = wsc_take(w, tmp[..room]);
        guard e.code == 0 else { return e; }
        guard got > 0 else { return Error { call: "recv", code: ECONNRESET }; }
        w.scratch.append(tmp[..got]);
    }
    return no_error();
}

fn wsc_copy_out(w: WsClient&, n: i64, dest: u8[>..]&) -> Error {
    var left = n;
    while left > 0 {
        let e = wsc_need(w, min(left, 1024));
        guard e.code == 0 else { return e; }
        let take = min(left, w.scratch.len - w.at);
        dest.append(w.scratch[w.at..w.at + take]);
        w.at += take;
        left -= take;
    }
    if w.at == w.scratch.len {
        w.scratch.clear();
        w.at = 0;
    }
    return no_error();
}

fn wsc_tls_handshake(w: WsClient&) -> Error {
    guard tls::ok(w.c) else { return wsc_error("tls"); }
    var wire: u8[16384] = [0; 16384];
    loop {
        let r = tls::handshake(w.c);
        let e = wsc_flush(w);
        guard e.code == 0 else { return e; }
        if r == 0 { return no_error(); }
        guard r == tls::WANT_INPUT else { return wsc_error("tls"); }
        let n = recv(w.s, wire, w.ms);
        guard n > 0 else { return Error { call: "recv", code: if n == 0 { ECONNRESET } else { -n } }; }
        guard tls::feed(w.c, wire[..n]) == n else { return wsc_error("tls"); }
    }
}

fn wsc_flush(w: WsClient&) -> Error {
    var buf: u8[16384] = [0; 16384];
    loop {
        let n = tls::drain(w.c, buf);
        guard n > 0 else { return no_error(); }
        let e = send_all(w.s, buf[..n], w.ms);
        guard e.code == 0 else { return e; }
    }
}

fn wsc_put(w: WsClient&, bytes: const u8[:]) -> Error {
    guard tls::ok(w.c) else { return send_all(w.s, bytes, w.ms); }
    guard tls::write(w.c, bytes) == bytes.len else { return wsc_error("tls"); }
    return wsc_flush(w);
}

fn wsc_take(w: WsClient&, buf: u8[:]) -> i64, Error {
    guard tls::ok(w.c) else {
        let n = recv(w.s, buf, w.ms);
        if n > 0 { return n, no_error(); }
        if n == 0 { return 0, no_error(); }
        return 0, Error { call: "recv", code: -n };
    }
    var wire: u8[16384] = [0; 16384];
    loop {
        let n = tls::read(w.c, buf);
        if n > 0 { return n, no_error(); }
        if n == tls::CLOSED { return 0, no_error(); }
        guard n == tls::WANT_INPUT else { return 0, wsc_error("tls"); }
        let m = recv(w.s, wire, w.ms);
        guard m > 0 else { return 0, Error { call: "recv", code: if m == 0 { ECONNRESET } else { -m } }; }
        guard tls::feed(w.c, wire[..m]) == m else { return 0, wsc_error("tls"); }
    }
}

fn wsc_hangup(w: WsClient&) {
    if tls::ok(w.c) {
        tls::free(w.c);
        w.c = tls::Conn { .. };
    }
    if tls::ok(w.ctx) {
        tls::free(w.ctx);
        w.ctx = tls::Context { .. };
    }
    hangup(w.s);
    w.scratch.clear();
    w.at = 0;
    w.frag.clear();
    w.frag_op = 0;
    w.utf8 = 0;
    w.phase = WscLife.Done;
}

// Whether s goes on as UTF-8 that state leaves to check. state packs the
// continuation bytes still due and the range the next byte must fall in,
// the same rules RFC 3629 §4 gives the server module.
fn wsc_utf8(s: const u8[:], state: u32&) -> bool {
    var need = state >> 16;
    var lo = (state >> 8) & 0xFF;
    var hi = state & 0xFF;
    for b in s {
        if need == 0 {
            if b < 0x80 { continue; }
            lo = 0x80;
            hi = 0xBF;
            if b >= 0xC2 && b <= 0xDF { need = 1; }
            else if b >= 0xE0 && b <= 0xEF {
                need = 2;
                if b == 0xE0 { lo = 0xA0; }
                if b == 0xED { hi = 0x9F; }
            } else if b >= 0xF0 && b <= 0xF4 {
                need = 3;
                if b == 0xF0 { lo = 0x90; }
                if b == 0xF4 { hi = 0x8F; }
            } else {
                return false;
            }
        } else {
            guard b >= lo && b <= hi else { return false; }
            need--;
            lo = 0x80;
            hi = 0xBF;
        }
    }
    state = if need == 0 { 0 } else { need << 16 | lo << 8 | hi };
    return true;
}
