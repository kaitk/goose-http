// A WebSocket client for a thread that runs no loop, such as a lane's or a
// command-line program's. It opens its connection as http.client does, with
// a Session's wait limit, deadline, via, and TLS context, then writes the
// HTTP/1.1 opening handshake and reads and writes frames (RFC 6455) with
// http.websocket's opcodes, accept value, and UTF-8 check. It offers no
// extension, so the opening request has no permessage-deflate. Only a
// program that imports this module needs goose-tls and goose-hash, which
// its root file declares at the references this file names:
//
//   import http from "github.com/kaitk/goose-http@<tag>";
//   import tls from "github.com/kaitk/goose-tls@v0.0.6";
//   import hash from "github.com/kaitk/goose-hash@v0.0.4";
//   import http.wsclient;
//
//   var session = http::session();
//   var conn, err = http::ws_client_connect(session, "wss://example.com/ws");
//   http::ws_client_text(conn, "hello");
//   let msg, err = http::ws_client_recv(conn);
//   http::ws_client_close(conn);
//   http::free(session);
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
import websocket;

// Idle, then the handshake has finished, then a Close is sent, then the
// socket is gone. One value, so a send cannot run after the close has started
// and also pretend the handshake is still unfinished.
enum WscLife { Idle, Open, Closing, Done }

// One connection. session holds its socket and TLS, and its own copy of the
// settings of the Session it was opened with. scratch holds bytes read past
// the frame just taken, from at. frag holds a message whose later fragments
// are still coming, and frag_op is that message's opcode, or 0 when no
// fragment is open. frag is the one growable field, so it stays last.
struct WsClient {
    session: Session = Session { .. },
    // The longest message, in one frame or several.
    limit: i64 = 1 << 16,
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

// Opens url, ws:// or wss://, and finishes the opening handshake, with s's
// ms, deadline, via, and TLS context, which stays s's to free. An Error
// whose call is "url", "resolve", "connect", "send", "recv", "tls", or
// "handshake".
fn ws_client_connect(s: const Session&, url: const u8[:]) -> WsClient, Error {
    var w = WsClient { session: Session { ms: s.ms, deadline: s.deadline, via: s.via, ctx: s.ctx, .. }, .. };
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
    let opened = open(w.session, u);
    guard opened.code == 0 else {
        wsc_hangup(w);
        return w, opened;
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
    let sent = put(w.session, req);
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
    guard ws_utf8(data, state) && state == 0 else { return wsc_error("text"); }
    return wsc_send_frame(w, WS_TEXT, data);
}

// Sends data in one masked binary frame. call "send" or "frame".
fn ws_client_binary(w: WsClient&, data: const u8[:]) -> Error {
    guard w.phase == WscLife.Open else { return wsc_error("send"); }
    return wsc_send_frame(w, WS_BINARY, data);
}

// The next whole text or binary message. A ping is answered with a masked
// pong and is not returned. Fragments are joined. call "recv", "frame", or
// "text", after a Close with 1002, 1009, or 1007 (§7.1.7); or "close" when
// the peer sends a Close, which is answered with its code, and then code is
// that close code, or 1006 when the socket ends with no Close.
fn ws_client_recv(w: WsClient&) -> WsMessage, Error {
    guard w.phase == WscLife.Open else { return WsMessage { .. }, wsc_error("recv"); }
    loop {
        var payload: u8[>..] = [];
        let fin, op, e = wsc_one_frame(w, payload);
        guard e.code == 0 else { return WsMessage { .. }, wsc_lost(w, e); }
        if op == WS_PING {
            let p = wsc_send_frame(w, WS_PONG, payload);
            guard p.code == 0 else { return WsMessage { .. }, wsc_drop(w, p); }
            continue;
        }
        if op == WS_PONG { continue; }
        if op == WS_CLOSE {
            guard payload.len != 1 else { return WsMessage { .. }, wsc_fail(w, "frame", WS_PROTOCOL_ERROR); }
            let code = if payload.len == 0 { 1005 } else { (payload[0] as i64) << 8 | payload[1] };
            // The peer may have gone already, so a failed answer isn't reported.
            wsc_send_frame(w, WS_CLOSE, payload[..min(payload.len, 2)]);
            wsc_hangup(w);
            return WsMessage { .. }, Error { call: "close", code: code };
        }
        if op == WS_CONTINUATION {
            guard w.frag_op != 0 else { return WsMessage { .. }, wsc_fail(w, "frame", WS_PROTOCOL_ERROR); }
        } else {
            guard w.frag_op == 0 else { return WsMessage { .. }, wsc_fail(w, "frame", WS_PROTOCOL_ERROR); }
            w.frag_op = op;
            w.utf8 = 0;
        }
        if w.frag_op == WS_TEXT {
            guard ws_utf8(payload, w.utf8) else { return WsMessage { .. }, wsc_fail(w, "text", WS_INVALID_DATA); }
        }
        guard w.frag.len + payload.len <= w.limit else { return WsMessage { .. }, wsc_fail(w, "frame", WS_TOO_BIG); }
        guard fin else {
            w.frag.append(payload);
            continue;
        }
        guard w.frag_op != WS_TEXT || w.utf8 == 0 else { return WsMessage { .. }, wsc_fail(w, "text", WS_INVALID_DATA); }
        var msg = WsMessage { op: w.frag_op, .. };
        msg.data.append(w.frag);
        msg.data.append(payload);
        w.frag.clear();
        w.frag_op = 0;
        w.utf8 = 0;
        return msg, no_error();
    }
}

// Sends a Close with code 1000, reads until the peer answers it or ends the
// connection, and closes the socket. A second call does nothing. call
// "send" or "recv" when that wait fails. A peer that has already gone is
// code 0.
fn ws_client_close(w: WsClient&) -> Error {
    guard w.phase == WscLife.Open else {
        if w.phase != WscLife.Done { wsc_hangup(w); }
        return no_error();
    }
    var body: u8[2] = [(WS_NORMAL >> 8) as! u8, WS_NORMAL as! u8];
    let sent = wsc_send_frame(w, WS_CLOSE, body);
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
        if op == WS_CLOSE {
            wsc_hangup(w);
            return no_error();
        }
        // Data frames after the Close are discarded (RFC 6455 §5.5.1).
        if op == WS_PING {
            let p = wsc_send_frame(w, WS_PONG, payload);
            guard p.code == 0 else { return wsc_drop(w, p); }
        }
    }
    return wsc_drop(w, wsc_error("close"));
}

// Fails the connection (RFC 6455 §7.1.7): a Close with code, unless one was
// sent already, and then the socket closes.
fn wsc_fail(w: WsClient&, call: const u8[:], code: i32) -> Error {
    if w.phase == WscLife.Open {
        var body: u8[2] = [(code >> 8) as! u8, code as! u8];
        wsc_send_frame(w, WS_CLOSE, body);
    }
    wsc_hangup(w);
    return wsc_error(call);
}

// A socket that ended is the peer's close with no Close frame, 1006.
fn wsc_lost(w: WsClient&, e: Error) -> Error {
    wsc_hangup(w);
    if e.call == "recv" && e.code == ECONNRESET { return Error { call: "close", code: 1006 }; }
    return e;
}

fn wsc_drop(w: WsClient&, e: Error) -> Error {
    wsc_hangup(w);
    return e;
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
        let n, e = take(w.session, tmp);
        guard e.code == 0 else { return e; }
        guard n > 0 else { return Error { call: "recv", code: ECONNRESET }; }
        raw.append(tmp[..n]);
    }
}

fn wsc_check_101(raw: const u8[:], key: const u8[:]) -> Error {
    let eol = line_end(raw, 0);
    guard eol > 0 else { return wsc_error("handshake"); }
    let status = raw[..eol - 2];
    guard starts_with(status, "HTTP/1.") && status.len >= 12 && status[8] == ' '
        && (status.len == 12 || status[12] == ' ') else {
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
    let want = ws_accept(key);
    guard has_accept && accept == want[..] else { return wsc_error("handshake"); }
    return no_error();
}

fn wsc_send_frame(w: WsClient&, op: u8, data: const u8[:]) -> Error {
    guard w.phase == WscLife.Open || w.phase == WscLife.Closing else { return wsc_error("send"); }
    guard op >= WS_CLOSE || data.len <= w.limit else { return wsc_error("frame"); }
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
    return put(w.session, frame);
}

// One frame from the server. A masked frame fails the connection. An RSV
// bit fails it too, because no extension was negotiated.
fn wsc_one_frame(w: WsClient&, payload: u8[>..]&) -> bool, u8, Error {
    payload.clear();
    let e = wsc_need(w, 2);
    guard e.code == 0 else { return false, 0, e; }
    let b0 = w.scratch[w.at];
    let b1 = w.scratch[w.at + 1];
    if b0 & 0x70 != 0 || b1 & 0x80 != 0 { return false, 0, wsc_fail(w, "frame", WS_PROTOCOL_ERROR); }
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
        if w.scratch[w.at + 2] & 0x80 != 0 { return false, 0, wsc_fail(w, "frame", WS_PROTOCOL_ERROR); }
        n = 0;
        for i in 8 { n = n << 8 | w.scratch[w.at + 2 + i]; }
    }
    let control = op >= WS_CLOSE;
    if control {
        if op > WS_PONG || !fin || n > 125 { return false, 0, wsc_fail(w, "frame", WS_PROTOCOL_ERROR); }
    } else if op > WS_BINARY {
        return false, 0, wsc_fail(w, "frame", WS_PROTOCOL_ERROR);
    }
    if !control && n > w.limit { return false, 0, wsc_fail(w, "frame", WS_TOO_BIG); }
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
        let got, e = take(w.session, tmp[..room]);
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
        let part = min(left, w.scratch.len - w.at);
        dest.append(w.scratch[w.at..w.at + part]);
        w.at += part;
        left -= part;
    }
    if w.at == w.scratch.len {
        w.scratch.clear();
        w.at = 0;
    }
    return no_error();
}

// Closes the socket and its TLS connection. The TLS context stays the
// Session's.
fn wsc_hangup(w: WsClient&) {
    hangup(w.session);
    w.scratch.clear();
    w.at = 0;
    w.frag.clear();
    w.frag_op = 0;
    w.utf8 = 0;
    w.phase = WscLife.Done;
}
