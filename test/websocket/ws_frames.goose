// WebSocket's frames (websocket.goose) through an echo handler, driven as the
// loops drive it: each kind of frame, fragmented and pipelined messages,
// frames split across reads, the size limit, and the protocol errors, each
// printed as the frames the server sent back.
import std;
import http from "../../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http.websocket;
import check from "../";

let UPGRADE = "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

struct St { ws: http::WebSocket = http::WebSocket { limit: 300, .. } }

fn handle(ev: http::Event, st: St&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        http::ws_upgrade(ev.req, st.ws, out);
    } else {
        http::ws_read(ev, st.ws, out) { op, data, o => http::ws_send(o, op, data); };
    }
}

// Appends a client's frame, masked unless plain: fin, opcode, and payload,
// with rsv's bits in the first byte.
fn frame(out: u8[>..]&, fin: bool, op: u8, payload: const u8[:], plain: bool = false, rsv: u8 = 0) {
    out.push((if fin { 0x80 } else { 0 }) | rsv | op);
    let m: u8 = if plain { 0 } else { 0x80 };
    let n = payload.len;
    if n < 126 {
        out.push(m | n as! u8);
    } else if n < 65536 {
        out.push(m | 126);
        out.push((n >> 8) as! u8);
        out.push(n as! u8);
    } else {
        out.push(m | 127);
        for i in 8 { out.push((n >> (56 - 8 * i)) as! u8); }
    }
    let key: u8[4] = [0x12, 0x34, 0x56, 0x78];
    if !plain { out.append(key); }
    for b, i in payload { out.push(if plain { b } else { b ^ key[i & 3] }); }
}

fn text(out: u8[>..]&, fin: bool, payload: const u8[:]) { frame(out, fin, http::WS_TEXT, payload); }

fn close_frame(out: u8[>..]&, code: i32, reason: const u8[:]) {
    var body: u8[>..] = [];
    body.push((code >> 8) as! u8);
    body.push(code as! u8);
    body.append(reason);
    frame(out, true, 8, body);
}

// The server's frames in out, one per line: the opcode's name, the length,
// and a short payload but a binary one, or a Close's code and reason.
fn frames_of(out: const u8[:]) -> u8[>..] {
    var t: u8[>..] = [];
    var at = 0;
    while at + 2 <= out.len {
        let s = out[at..];
        let op = s[0] & 0x0F;
        assert(s[0] & 0xF0 == 0x80 && s[1] & 0x80 == 0);
        var n = (s[1] & 0x7F) as i64;
        var h = 2;
        if n == 126 {
            n = (s[2] as i64) << 8 | s[3];
            h = 4;
        } else if n == 127 {
            n = 0;
            for i in 8 { n = n << 8 | s[2 + i]; }
            h = 10;
        }
        let p = s[h..h + n];
        let name = match op { 1 => "text", 2 => "binary", 8 => "close", 9 => "ping", 10 => "pong", _ => "?" };
        format(t, "  ", name, " ", n);
        if op == 8 && n >= 2 { format(t, " ", (p[0] as i64) << 8 | p[1], " ", p[2..]); }
        else if op != 2 && n <= 40 { format(t, " ", p); }
        else if op == 2 { format(t, " ", p.len > 0 && p[p.len - 1] == 255); }
        else if n > 40 { format(t, " ", p[..10], "...", p[n - 10..]); }
        t.push('\n');
        at += h + n;
    }
    assert(at == out.len);
    return t;
}

// Upgrades a connection, then hands it data as BODY pieces, step bytes each,
// or all at once for 0, and prints what the server sent back and whether the
// connection is still open.
fn talk(name: const u8[:], data: const u8[:], step: i64 = 0) {
    var buf: u8[>..] = [];
    buf.append(UPGRADE);
    let r, s = http::parse(buf);
    assert(s == 200);
    var keep = r.keep_alive;
    var stream = http::Stream { .. };
    var st = St { .. };
    var out: u8[>..] = [];
    let reply = http::Reply { buf: out, common: check::COMMON, keep_alive: keep, minor: r.minor, head: false,
                              stream: stream };
    handle(http::Event { kind: http::REQUEST, req: r, data: "", whole: true, trailers: "" }, st, reply);
    assert(starts_with(out, "HTTP/1.1 101 "));
    let mark = out.len;
    let k = if step > 0 { step } else { max(data.len, 1) };
    var at = 0;
    while at < data.len {
        let to = min(at + k, data.len);
        handle(http::Event { kind: http::BODY, req: r, data: data[at..to], whole: false, trailers: "" }, st, reply);
        // Never more than the message and a frame, which ws.held is promised.
        assert(st.ws.held.cap <= st.ws.held.most);
        at = to;
    }
    let open = stream.open && keep;
    handle(http::Event { kind: http::CLOSED, req: r, data: "", whole: false, trailers: "" }, st, reply);
    assert(http::gather_promised == 0 && st.ws.held.cap == 0);
    print(name, if open { " (open)" } else { " (closed)" });
    print(frames_of(out[mark..]));
}

fn main() {
    var b: u8[>..] = [];
    text(b, true, "hello");
    talk("text", b);
    b.clear();
    frame(b, true, http::WS_BINARY, [0, 1, 2, 255]);
    talk("binary", b);
    b.clear();
    frame(b, true, 9, "are you there");
    talk("ping", b);
    b.clear();
    frame(b, true, 10, "unasked");
    talk("pong, unasked", b);
    b.clear();
    close_frame(b, 1000, "bye");
    talk("close", b);
    b.clear();
    frame(b, true, 8, "");
    talk("close, empty", b);
    b.clear();
    close_frame(b, 1001, "");
    text(b, true, "late");
    talk("close, then text", b);

    // Text in three fragments, with a ping between two of them, in one read
    // and then each frame in a read of its own.
    b.clear();
    text(b, false, "hel");
    frame(b, false, 0, "lo, ");
    frame(b, true, 9, "");
    frame(b, true, 0, "world");
    talk("fragmented", b);
    talk("fragmented, a byte per read", b, 1);
    talk("fragmented, 7 bytes per read", b, 7);

    // 16 frames in one read, as HttpArena's echo-ws-pipeline sends them.
    b.clear();
    for i in 16 { text(b, true, "hello"); }
    talk("pipelined", b);
    talk("pipelined, 13 bytes per read", b, 13);

    // 200 bytes takes the 16-bit length; the limit is 300.
    var long: u8[>..] = [];
    for i in 300 { long.push('a' + (i % 26) as! u8); }
    b.clear();
    text(b, true, long[..200]);
    talk("200 bytes", b);
    b.clear();
    text(b, true, long);
    talk("300 bytes, the limit", b, 50);

    // Past the limit, in one frame, refused from its head, and in fragments.
    b.clear();
    text(b, true, long);
    b.push('x');
    b[1] = 0x80 | 126;
    b[3] = 45;          // 256 + 45 = 301
    talk("over the limit", b[..10]);
    b.clear();
    text(b, false, long[..150]);
    frame(b, true, 0, long[..151]);
    talk("over the limit, fragmented", b);

    // Protocol errors: 1002.
    b.clear();
    frame(b, true, http::WS_TEXT, "hi", true);
    talk("unmasked", b);
    b.clear();
    frame(b, true, http::WS_TEXT, "hi", false, 0x40);
    talk("RSV1, no extension", b);
    b.clear();
    frame(b, true, 3, "");
    talk("opcode 3", b);
    b.clear();
    frame(b, true, 11, "");
    talk("opcode 11", b);
    b.clear();
    frame(b, false, 9, "");
    talk("ping in fragments", b);
    b.clear();
    frame(b, true, 9, long[..126]);
    talk("ping of 126 bytes", b);
    b.clear();
    frame(b, true, 0, "lo");
    talk("continuation first", b);
    b.clear();
    text(b, false, "a");
    text(b, true, "b");
    talk("text while fragmented", b);
    b.clear();
    frame(b, true, 8, "x");
    talk("close of one byte", b);
    b.clear();
    close_frame(b, 1005, "");
    talk("close code 1005", b);
    b.clear();
    close_frame(b, 2000, "");
    talk("close code 2000", b);
    b.clear();
    close_frame(b, 4000, "app");
    talk("close code 4000", b);

    // Invalid UTF-8: 1007.
    b.clear();
    text(b, true, [0x68, 0xC0, 0xAF]);
    talk("text, overlong", b);
    b.clear();
    text(b, true, [0xED, 0xA0, 0x80]);
    talk("text, a surrogate", b);
    b.clear();
    text(b, true, [0xF4, 0x90, 0x80, 0x80]);
    talk("text, past U+10FFFF", b);
    b.clear();
    text(b, true, "κόσμε");
    talk("text, UTF-8", b);
    // Bad in the first fragment: fails before the rest comes.
    b.clear();
    text(b, false, [0xFF]);
    talk("fragment, not UTF-8", b);
    // A character split between fragments is whole; one left open isn't.
    b.clear();
    text(b, false, [0xCE, 0xBA, 0xE1, 0xBD]);
    frame(b, true, 0, [0x83]);
    talk("character across fragments", b);
    b.clear();
    text(b, false, [0xCE]);
    frame(b, true, 0, "");
    talk("character left open", b);
    b.clear();
    close_frame(b, 1000, [0xFF]);
    talk("close reason, not UTF-8", b);
}
