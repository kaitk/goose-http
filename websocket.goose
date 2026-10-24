// WebSocket (RFC 6455) over upgrade's raw bytes: the handshake, the frames,
// and the close. Only a program that imports this module needs goose-hash,
// for the handshake's SHA-1, which its root file declares at the tag this
// file names:
//
//   import http from "github.com/kaitk/goose-http@<tag>";
//   import hash from "github.com/kaitk/goose-hash@v0.0.4";
//   import http.websocket;
//
// An echo, with a WebSocket in the handler's state:
//
//   if ev.kind == http::REQUEST {
//       http::ws_upgrade(ev.req, st.ws, out);   // 101, or 400, 426, or 503
//   } else {
//       http::ws_read(ev, st.ws, out) { op, data, o => http::ws_send(o, op, data); };
//   }
//
// ws_upgrade is ws_check's verdict and ws_switch's 101, and ws_read is
// ws_take at BODY and ws_release at CLOSED, for a program that answers a
// refusal itself or holds the bytes outside an Event.
//
// No extension is negotiated, so a frame with an RSV bit set fails the
// connection, as permessage-deflate's would.
namespace http;

import std;
import base64;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import message;

// A message's opcode, as ws_take gives it and ws_send takes it.
let WS_TEXT: u8 = 1;
let WS_BINARY: u8 = 2;

let WS_CONTINUATION: u8 = 0;
let WS_CLOSE: u8 = 8;
let WS_PING: u8 = 9;
let WS_PONG: u8 = 10;

// Close codes (RFC 6455 §7.4.1).
let WS_NORMAL: i32 = 1000;
let WS_PROTOCOL_ERROR: i32 = 1002;
let WS_INVALID_DATA: i32 = 1007;
let WS_TOO_BIG: i32 = 1009;
let WS_TRY_AGAIN: i32 = 1013;

// The value a client's key is joined with before it's hashed (§1.3).
let WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// A connection's WebSocket, in the handler's state from the upgrade on: what
// it holds of a message whose fragments are still coming, and of a frame not
// yet whole, in a run of the worker's pool that gather uses.
struct WebSocket {
    // The longest message taken, in bytes, whether in one frame or several;
    // a longer one closes the connection with 1009.
    limit: i64 = 1 << 16,
    // The message so far, its first joined bytes, and then a frame not yet
    // whole, if one is. It's promised limit and WS_SLACK bytes of the pool
    // when it first holds any, and gives them back when it's empty again.
    held: Gather = Gather { .. },
    joined: i64 = 0,
    // The opcode of the message whose fragments are coming, or 0.
    op: u8 = 0,
    // What a text message's UTF-8 so far leaves to check (ws_utf8).
    utf8: u32 = 0,
    // A Close was sent, and the client's is awaited; then done, and nothing
    // more is read.
    closing: bool = false,
    done: bool = false,
}

// Answers a request to open a WebSocket (§4.2) as ws_check judges it: 101
// from ws_switch, after which the connection carries frames into ws, and
// true; or the status ws_check gives, with its fields, and false. With
// protocol, the 101 names it in Sec-WebSocket-Protocol: one of those the
// client offered in its own Sec-WebSocket-Protocol field, which field_of
// gives. A protocol that is_field refuses gets 400.
fn ws_upgrade(req: const Request&, ws: WebSocket&, out: Reply, protocol: const u8[:] = "") -> bool {
    var status, key, fields = ws_check(req, out.minor);
    if status == 101 && protocol.len > 0 && !is_field("Sec-WebSocket-Protocol", protocol) { status = 400; }
    guard status == 101 else {
        start(out, status);
        out.buf.append(fields);
        finish(out, NO_TYPE, "");
        return false;
    }
    ws_switch(out, key, protocol);
    return true;
}

// Whether req may open a WebSocket (§4.2.1), on a connection whose
// Reply.minor is minor, without answering it. Returns 101 and req's
// Sec-WebSocket-Key, for ws_switch; or the status to refuse it with, and the
// fields that refusal carries, whole lines each ending in CRLF: 426 with
// "Connection: Upgrade" and "Upgrade: websocket" for a request that doesn't
// ask for one, as a plain GET; 426 with "Sec-WebSocket-Version: 13" for
// another version; 400 with none for a method other than GET or a key that
// isn't 16 bytes in base64; and 501 with none on an HTTP/2 stream
// (H2_MINOR), which has no upgrade.
fn ws_check(req: const Request&, minor: i32) -> i32, const u8[:], const u8[:] {
    guard minor != H2_MINOR else { return 501, "", ""; }
    var asked = false;
    each_split(upgrade_of(req), ',') { if eq_fold(trim(it), "websocket") { asked = true; } };
    guard asked else { return 426, "", "Connection: Upgrade\r\nUpgrade: websocket\r\n"; }
    let version, _ = field_of(req, "sec-websocket-version");
    guard version == "13" else { return 426, "", "Sec-WebSocket-Version: 13\r\n"; }
    let key, _ = field_of(req, "sec-websocket-key");
    var nonce: u8[>..] = [];
    guard req.method == "GET" && key.len == 24 && base64::decode(nonce, key) && nonce.len == 16 else {
        return 400, "", "";
    }
    return 101, key, "";
}

// Answers a request that ws_check gave 101, with key: 101 with
// Sec-WebSocket-Accept, computed for this request alone, and switches the
// connection to frames, which ws_take then reads. With protocol, the 101
// names it in Sec-WebSocket-Protocol, unless is_field refuses it, as field
// does.
fn ws_switch(out: Reply, key: const u8[:], protocol: const u8[:] = "") {
    start(out, 101);
    out.buf.append("Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ");
    out.buf.append(ws_accept(key));
    out.buf.append("\r\n");
    if protocol.len > 0 { field(out, "Sec-WebSocket-Protocol", protocol); }
    out.buf.append("\r\n");
    switched(out);
}

// Sec-WebSocket-Accept's value for key: the base64 of the SHA-1 of the key
// and WS_GUID (§4.2.2).
fn ws_accept(key: const u8[:]) -> u8[..28] {
    var joined: u8[..64] = [];
    joined.append(key[..min(key.len, 28)]);
    joined.append(WS_GUID);
    // base64::encode may shrink what it's given, so not the write buffer.
    var text: u8[>..] = [];
    base64::encode(text, hash::sha1(joined));
    var accept: u8[..28] = [];
    accept.append(text);
    return accept;
}

// Takes an upgraded connection's events after REQUEST: ws_take at BODY, and
// ws_release at CLOSED; other events are the handler's.
fn ws_read<F>(ev: Event, ws: WebSocket&, out: Reply) {
    if ev.kind == CLOSED {
        ws_release(ws);
    } else if ev.kind == BODY {
        ws_take(ev.data, ws, out) { op, data, o => F(op, data, o); };
    }
}

// Takes bytes, the next a connection that ws_switch switched has sent:
// reads every frame they complete, those that came together in one pass,
// and calls F(op, data, out) with each whole message, WS_TEXT or WS_BINARY.
// A message in fragments is joined first; data lasts until F returns. A ping
// gets its pong, and a Close its Close, after which the connection closes. A
// frame the protocol forbids closes it with 1002, text that isn't UTF-8 with
// 1007, a message longer than ws.limit with 1009, and one the worker's
// gather budget can't hold with 1013, each sent in a Close first. What ws
// holds between calls ws_release gives back.
fn ws_take<F>(bytes: const u8[:], ws: WebSocket&, out: Reply) {
    guard !ws.done else { return; }
    // The unmasked payload of each frame, on the worker's data stack.
    var payload: u8[>..] = [];
    var rest = bytes;
    // A frame not yet whole waits after the message so far, and takes from
    // bytes only what it lacks, so ws.held never holds more than the message
    // and one frame.
    while ws.held.len > ws.joined {
        let frame = gathered[ws.held.at + ws.joined..ws.held.at + ws.held.len];
        let want, judged = ws_length(frame);
        if judged {
            // ws_frames refuses the frame by its head, reads it, or waits.
            let used = ws_frames(frame, ws, out, payload) { op, data, o => F(op, data, o); };
            guard !ws.done else { return; }
            if used > 0 {
                ws.held.len = ws.joined;
                if ws.joined == 0 { release_gather(ws.held); }
                break;
            }
        }
        guard rest.len > 0 else { return; }
        let take = min(want - frame.len, rest.len);
        guard ws_hold(ws, out, rest[..take]) else { return; }
        rest = rest[take..];
    }
    let used = ws_frames(rest, ws, out, payload) { op, data, o => F(op, data, o); };
    if !ws.done && used < rest.len { ws_hold(ws, out, rest[used..]); }
}

// Appends data to ws.held, promising it limit and WS_SLACK bytes of the
// worker's pool first if it holds none, which bounds it from then on. Fails
// the connection with 1013 where the budget can't promise them, or with 1009
// past them, and returns false.
fn ws_hold(ws: WebSocket&, out: Reply, data: const u8[:]) -> bool {
    if ws.held.most == 0 && !gather_promise(ws.held, ws.limit + WS_SLACK) {
        ws_fail(out, ws, WS_TRY_AGAIN);
        return false;
    }
    guard gather_piece(ws.held, data) else {
        ws_fail(out, ws, WS_TOO_BIG);
        return false;
    }
    return true;
}

// The length of the frame that s starts, and whether its head is whole: the
// head's length until it is, and then the head's, the mask's, and the
// payload's.
fn ws_length(s: const u8[:]) -> i64, bool {
    guard s.len >= 2 else { return 2, false; }
    let short = (s[1] & 0x7F) as i64;
    let h: i64 = if short == 126 { 4 } else if short == 127 { 10 } else { 2 };
    guard s.len >= h else { return h, false; }
    var n = short;
    if short == 126 {
        n = (s[2] as i64) << 8 | s[3];
    } else if short == 127 {
        n = 0;
        for i in 8 { n = n << 8 | s[2 + i]; }
    }
    return h + 4 + n, true;
}

// The bytes a WebSocket may hold past its limit: a control frame not yet
// whole, of 125 bytes with its head and mask, after a message at the limit.
let WS_SLACK = 131;

// Adds a fragment's payload to the message at the start of ws.held. A frame
// after the message there is the one being read, whose payload is unmasked
// already, so payload takes its place. Returns false where ws_hold failed
// the connection.
fn ws_join(ws: WebSocket&, out: Reply, payload: const u8[:]) -> bool {
    if ws.held.len > ws.joined {
        copy_into(gathered[ws.held.at + ws.joined..ws.held.at + ws.joined + payload.len], payload);
    } else if !ws_hold(ws, out, payload) {
        return false;
    }
    ws.joined += payload.len;
    return true;
}

// Reads the whole frames at the start of src, as ws_take describes, and
// returns how many bytes they took.
fn ws_frames<F>(src: const u8[:], ws: WebSocket&, out: Reply, payload: u8[>..]&) -> i64 {
    var at = 0;
    while !ws.done && src.len - at >= 2 {
        let s = src[at..];
        let fin = s[0] & 0x80 != 0;
        let op = s[0] & 0x0F;
        var n = (s[1] & 0x7F) as i64;
        var h = 2;
        if n == 126 {
            guard s.len >= 4 else { break; }
            n = (s[2] as i64) << 8 | s[3];
            h = 4;
        } else if n == 127 {
            guard s.len >= 10 else { break; }
            guard s[2] & 0x80 == 0 else {
                ws_fail(out, ws, WS_PROTOCOL_ERROR);
                break;
            }
            n = 0;
            for i in 8 { n = n << 8 | s[2 + i]; }
            h = 10;
        }
        // Checked from the head alone, so a frame too long is refused before
        // it arrives.
        let control = op >= 8;
        let fault = s[0] & 0x70 != 0 || s[1] & 0x80 == 0 ||
                    (if control { op > WS_PONG || !fin || n > 125 }
                     else { op > WS_BINARY || (op == WS_CONTINUATION) == (ws.op == 0) });
        guard !fault else {
            ws_fail(out, ws, WS_PROTOCOL_ERROR);
            break;
        }
        guard control || n <= ws.limit - ws.joined else {
            ws_fail(out, ws, WS_TOO_BIG);
            break;
        }
        guard s.len - h - 4 >= n else { break; }
        let mask = s[h..h + 4];
        let body = s[h + 4..h + 4 + n];
        at += h + 4 + n;
        // After a Close is sent, only the client's Close matters (§5.5.1).
        if ws.closing && op != WS_CLOSE { continue; }
        payload.resize(n, 0);
        for b, i in body { payload[i] = b ^ mask[i & 3]; }
        if op == WS_PING {
            ws_frame(out, WS_PONG, payload);
        } else if op == WS_CLOSE {
            ws_closed(out, ws, payload);
        } else if op == WS_PONG {
            // Unasked for, or for a ping the program sent: nothing to do.
        } else if fin && op != WS_CONTINUATION {
            var state: u32 = 0;
            guard op != WS_TEXT || ws_utf8(payload, state) && state == 0 else {
                ws_fail(out, ws, WS_INVALID_DATA);
                break;
            }
            F(op, payload, out);
        } else {
            if op != WS_CONTINUATION {
                ws.op = op;
                ws.utf8 = 0;
            }
            // Checked as each fragment comes, so bad text fails at once.
            guard ws.op != WS_TEXT || ws_utf8(payload, ws.utf8) else {
                ws_fail(out, ws, WS_INVALID_DATA);
                break;
            }
            guard ws_join(ws, out, payload) else { break; }
            if fin {
                guard ws.op != WS_TEXT || ws.utf8 == 0 else {
                    ws_fail(out, ws, WS_INVALID_DATA);
                    break;
                }
                F(ws.op, gathered[ws.held.at..ws.held.at + ws.joined], out);
                ws.joined = 0;
                release_gather(ws.held);
                ws.op = 0;
            }
        }
    }
    return at;
}

// Sends a message, op WS_TEXT or WS_BINARY, in one frame. Text must be UTF-8.
// Nothing is sent on a connection that ws_switch didn't switch, or after the
// connection has closed.
fn ws_send(out: Reply, op: u8, data: const u8[:]) { ws_frame(out, op, data); }

// Starts the close (§7.1.2): sends a Close with code and reason, at most 123
// bytes of UTF-8, and takes no more messages. The connection closes when the
// client's Close comes, or after Config.idle_ms.
fn ws_close(out: Reply, ws: WebSocket&, code: i32 = WS_NORMAL, reason: const u8[:] = "") {
    guard !ws.closing && !ws.done else { return; }
    var body: u8[..125] = [];
    body.push((code >> 8) as! u8);
    body.push(code as! u8);
    body.append(reason[..min(reason.len, 123)]);
    ws_frame(out, WS_CLOSE, body);
    ws.closing = true;
}

// Gives back what ws holds in the worker's pool, and its promise: call it at
// CLOSED, as ws_read does. ws_take does when it closes the connection
// itself.
fn ws_release(ws: WebSocket&) {
    release_gather(ws.held);
    ws.joined = 0;
}

// One unmasked frame, whole, as a server sends it (§5.2).
fn ws_frame(out: Reply, op: u8, data: const u8[:]) {
    guard out.stream.open && raw(out.stream) else { return; }
    var head: u8[..10] = [];
    head.push(0x80 | op);
    let n = data.len;
    if n < 126 {
        head.push(n as! u8);
    } else if n < 65536 {
        head.push(126);
        head.push((n >> 8) as! u8);
        head.push(n as! u8);
    } else {
        head.push(127);
        for i in 8 { head.push((n >> (56 - 8 * i)) as! u8); }
    }
    send(out, head);
    send(out, data);
}

// The client's Close: answered with a Close of the same code, unless one was
// sent already, and the connection then closes. A Close of one byte, or with
// a code that no endpoint may send, is a protocol error, and a reason that
// isn't UTF-8 invalid data.
fn ws_closed(out: Reply, ws: WebSocket&, payload: const u8[:]) {
    var state: u32 = 0;
    if payload.len >= 2 {
        let code = (payload[0] as i32) << 8 | payload[1];
        guard ws_code_ok(code) else {
            ws_fail(out, ws, WS_PROTOCOL_ERROR);
            return;
        }
        guard ws_utf8(payload[2..], state) && state == 0 else {
            ws_fail(out, ws, WS_INVALID_DATA);
            return;
        }
    } else if payload.len == 1 {
        ws_fail(out, ws, WS_PROTOCOL_ERROR);
        return;
    }
    if !ws.closing { ws_frame(out, WS_CLOSE, payload[..min(payload.len, 2)]); }
    ws_end(out, ws);
}

// Whether a Close may carry code (§7.4): those RFC 6455 defines for sending,
// those IANA has registered since, and 3000-4999, for libraries and programs.
fn ws_code_ok(code: i32) -> bool {
    return code >= 1000 && code <= 1003 || code >= 1007 && code <= 1014 || code >= 3000 && code <= 4999;
}

// Fails the connection (§7.1.7): a Close with code, unless one was sent
// already, then the connection closes.
fn ws_fail(out: Reply, ws: WebSocket&, code: i32) {
    if !ws.closing {
        var body: u8[2] = [(code >> 8) as! u8, code as! u8];
        ws_frame(out, WS_CLOSE, body);
    }
    ws_end(out, ws);
}

fn ws_end(out: Reply, ws: WebSocket&) {
    ws.done = true;
    ws.closing = true;
    ws_release(ws);
    end(out);
}

// Whether s goes on UTF-8 that state leaves to check, and so far is valid,
// with state updated to what s leaves: 0 at the end of a character, or the
// count of continuation bytes still due, with the range the next must fall
// in, which excludes overlong forms, surrogates, and code points past
// U+10FFFF (RFC 3629 §4).
fn ws_utf8(s: const u8[:], state: u32&) -> bool {
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
