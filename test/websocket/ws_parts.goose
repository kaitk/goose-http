// WebSocket's parts (websocket.goose), as a framework composes them: ws_check's
// verdicts without an answer, a refusal in a program's own shape, ws_switch's
// 101 against ws_upgrade's, and ws_take driven with bytes alone against
// ws_read driven with events, with ws_release for what a connection holds,
// and 1013 for a message the gather budget can't hold.
import std;
import http from "../../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http.websocket;
import check from "../";

let KEY = "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";
let ASK = "Upgrade: websocket\r\nConnection: Upgrade\r\n";
let V13 = "Sec-WebSocket-Version: 13\r\n";

// ws_check's verdict on a request with fields, its fields' CRLFs shown as |.
fn verdict(method: const u8[:], fields: const u8[:], minor: i32 = 1) -> u8[>..] {
    var buf: u8[>..] = [];
    let r = check::request(method, fields, buf);
    let status, key, extra = http::ws_check(r, minor);
    var t: u8[>..] = [];
    format(t, status, " key '", key, "' fields '");
    each_split(extra, "\r\n") { if it.len > 0 { format(t, it, "|"); } };
    t.push('\'');
    return t;
}

// What a Reply over a fresh stream answers, as the handler's out.
fn respond_with<F>(minor: i32 = 1) -> u8[>..] {
    var keep = true;
    var stream = http::Stream { .. };
    var out: u8[>..] = [];
    F(http::Reply { buf: out, common: check::COMMON, keep_alive: keep, minor: minor, head: false, stream: stream });
    var t: u8[>..] = [];
    t.append(out);
    return t;
}

// A framework's answer: ws_check's refusal with a JSON body of its own, or
// ws_switch's 101.
fn framework(req: const http::Request&, out: http::Reply) {
    let status, key, fields = http::ws_check(req, out.minor);
    guard status == 101 else {
        http::start(out, status);
        out.buf.append(fields);
        http::finish(out, http::JSON, "{\"error\":\"no_websocket\"}");
        return;
    }
    http::ws_switch(out, key, "chat");
}

// A client's masked frame: fin, opcode, and payload.
fn frame(out: u8[>..]&, fin: bool, op: u8, payload: const u8[:]) {
    out.push((if fin { 0x80 } else { 0 }) | op);
    let n = payload.len;
    if n < 126 {
        out.push(0x80 | n as! u8);
    } else {
        out.push(0x80 | 126);
        out.push((n >> 8) as! u8);
        out.push(n as! u8);
    }
    let key: u8[4] = [0x12, 0x34, 0x56, 0x78];
    out.append(key);
    for b, i in payload { out.push(b ^ key[i & 3]); }
}

// What a framework holds for a handler instead of an Event.
struct Cx { kind: u8, body: const u8[:] }

// What a connection sends back for data, handed over step bytes at a time,
// through ws_read with events or, with bytes, through ws_take from a Cx: a
// line with the count, whether it's still open, and whether its WebSocket
// held a run before the connection closed, then the bytes.
fn echo(data: const u8[:], step: i64, bytes: bool, limit: i64 = 1 << 20) -> u8[>..] {
    var keep = true;
    var stream = http::Stream { .. };
    var out: u8[>..] = [];
    let reply = http::Reply { buf: out, common: "", keep_alive: keep, minor: 1, head: false, stream: stream };
    http::switched(reply);
    var ws = http::WebSocket { limit: limit, .. };
    let none = http::Request { .. };
    var at = 0;
    while at < data.len {
        let to = min(at + step, data.len);
        if bytes {
            let cx = Cx { kind: http::BODY, body: data[at..to] };
            if cx.kind == http::BODY {
                http::ws_take(cx.body, ws, reply) { op, msg, o => http::ws_send(o, op, msg); };
            }
        } else {
            http::ws_read(http::Event { kind: http::BODY, req: none, data: data[at..to], whole: false, trailers: "" },
                          ws, reply) { op, msg, o => http::ws_send(o, op, msg); };
        }
        at = to;
    }
    let held = ws.held.cap;
    let open = stream.open && keep;
    if bytes {
        http::ws_release(ws);
    } else {
        http::ws_read(http::Event { kind: http::CLOSED, req: none, data: "", whole: false, trailers: "" }, ws,
                      reply) { op, msg, o => http::ws_send(o, op, msg); };
    }
    assert(ws.held.cap == 0 && http::gather_promised == 0);
    var t: u8[>..] = [];
    format(t, out.len, " bytes back, ", if open { "open" } else { "closed" }, ", ",
           if held > 0 { "a run held" } else { "nothing held" });
    t.push('\n');
    t.append(out);
    return t;
}

// echo through both paths, which must send the same bytes.
fn both(name: const u8[:], data: const u8[:], step: i64, limit: i64 = 1 << 20) {
    let a = echo(data, step, false, limit);
    let b = echo(data, step, true, limit);
    check::same(b, a);
    print(name, ": ", b[..position(b, '\n')]);
}

fn main() {
    print("ws_check:");
    print(verdict("GET", str(ASK, KEY, V13)));
    print(verdict("GET", ""));
    print(verdict("GET", str(ASK, KEY, "Sec-WebSocket-Version: 8\r\n")));
    print(verdict("GET", str(ASK, "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\n", V13)));
    print(verdict("POST", str(ASK, KEY, V13)));
    print(verdict("GET", str(ASK, KEY, V13), http::H2_MINOR));

    // ws_switch writes ws_upgrade's 101, byte for byte.
    var buf: u8[>..] = [];
    let ok = check::request("GET", str(ASK, KEY, V13, "Sec-WebSocket-Protocol: chat\r\n"), buf);
    var ws = http::WebSocket { .. };
    let upgraded = respond_with() { out => http::ws_upgrade(ok, ws, out, "chat"); };
    http::ws_release(ws);
    let switched = respond_with() { out =>
        let status, key, fields = http::ws_check(ok, out.minor);
        assert(status == 101 && fields.len == 0);
        http::ws_switch(out, key, "chat");
    };
    check::same(switched, upgraded);
    print("ws_switch: ws_upgrade's 101");

    // A refusal in the program's own shape, and the 101 from the same code.
    var buf2: u8[>..] = [];
    let plain = check::request("GET", "", buf2);
    print(respond_with() { out => framework(plain, out); });
    print(respond_with() { out => framework(ok, out); });
    assert(http::gather_promised == 0);

    // ws_take from bytes alone sends what ws_read sends from events.
    var b: u8[>..] = [];
    for i in 16 { frame(b, true, http::WS_TEXT, "hello"); }
    both("16 pipelined", b, b.len);
    both("16 pipelined, 13 bytes per call", b, 13);
    b.clear();
    frame(b, false, http::WS_TEXT, "hel");
    frame(b, true, 9, "");
    frame(b, true, 0, "lo");
    both("fragmented, a byte per call", b, 1);
    b.clear();
    frame(b, true, http::WS_TEXT, "hello");
    both("a frame cut short", b[..4], 4);
    var long: u8[>..] = [];
    for i in 200 { long.push('a'); }
    b.clear();
    frame(b, true, http::WS_TEXT, long);
    both("over the limit", b, b.len, 100);

    // With the budget spent, whole frames still echo, as they hold nothing;
    // a message in fragments, which must be held, closes with 1013.
    http::gather_budget(0);
    b.clear();
    for i in 4 { frame(b, true, http::WS_TEXT, "hello"); }
    both("whole frames, no budget", b, b.len);
    b.clear();
    frame(b, false, http::WS_TEXT, "hel");
    frame(b, true, 0, "lo");
    both("fragmented, no budget", b, b.len);
    http::gather_budget(http::GATHER_BUDGET);
}
