// WebSocket's opening handshake (websocket.goose): the accept value of RFC
// 6455's example, the 101, and the answers to requests that can't upgrade.
import std;
import http from "../../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http.websocket;
import check from "../";

let KEY = "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";
let ASK = "Upgrade: websocket\r\nConnection: Upgrade\r\n";
let V13 = "Sec-WebSocket-Version: 13\r\n";

// What ws_upgrade answers a request with fields, with protocol, and whether
// it switched the connection to frames.
fn answer(method: const u8[:], fields: const u8[:], protocol: const u8[:] = "", minor: i32 = 1) -> u8[>..] {
    var buf: u8[>..] = [];
    let r = check::request(method, fields, buf);
    var keep = r.keep_alive;
    var stream = http::Stream { .. };
    var out: u8[>..] = [];
    let reply = http::Reply { buf: out, common: check::COMMON, keep_alive: keep, minor: minor, head: false,
                              stream: stream };
    var ws = http::WebSocket { .. };
    let before = http::gather_promised;
    let ok = http::ws_upgrade(r, ws, reply, protocol);
    assert(ok == (stream.framing == http::Framing.Raw && stream.open));
    // An upgrade promises nothing: a WebSocket is promised its bytes only
    // while it holds a message.
    assert(http::gather_promised == before && ws.held.most == 0);
    http::ws_release(ws);
    var t: u8[>..] = [];
    t.append(out);
    format(t, "(switched: ", ok, ")\n");
    return t;
}

fn main() {
    // RFC 6455 §1.3's example.
    check::same(http::ws_accept("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    print("accept: RFC 6455's example");

    print(answer("GET", str(ASK, KEY, V13)));
    print(answer("GET", str("upgrade: WebSocket\r\nconnection: keep-alive, Upgrade\r\n", KEY, V13)));
    print(answer("GET", str(ASK, KEY, V13, "Sec-WebSocket-Protocol: chat, superchat\r\n"), "chat"));
    // A plain GET, another protocol, another version, no version.
    print(answer("GET", ""));
    print(answer("GET", str("Upgrade: echo\r\nConnection: Upgrade\r\n", KEY, V13)));
    print(answer("GET", str(ASK, KEY, "Sec-WebSocket-Version: 8\r\n")));
    print(answer("GET", str(ASK, KEY)));
    // A key that isn't 16 bytes, none, another method, a protocol that
    // can't be a field's value.
    print(answer("GET", str(ASK, "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\n", V13)));
    print(answer("GET", str(ASK, "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=!\r\n", V13)));
    print(answer("GET", str(ASK, V13)));
    print(answer("POST", str(ASK, KEY, V13)));
    print(answer("GET", str(ASK, KEY, V13), "chat\r\nX: y"));
    // An HTTP/2 stream has no upgrade.
    print(answer("GET", str(ASK, KEY, V13), "", http::H2_MINOR));
    // A worker whose budget is spent still upgrades.
    http::gather_budget(0);
    assert(starts_with(answer("GET", str(ASK, KEY, V13)), "HTTP/1.1 101 "));
    http::gather_budget(http::GATHER_BUDGET);
}
