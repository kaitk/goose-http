// send_shared in a loop: inline bytes and a blob's ranges, interleaved, the
// handler's reference dropped at once, and the blob's last reference the
// handler's own again by DRAINED, whether the socket took it all (/small)
// or the loop had to keep the rest (/large, behind a stalled reader).
import std;
import os;
import http from "../../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http.websocket;
import http.shared;

struct State { ws: http::WebSocket = http::WebSocket { .. }, blob: http::Shared = http::Shared { .. }, done: bool = false }

fn handle(ev: http::Event, state: State&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        guard http::ws_upgrade(ev.req, state.ws, out) else { return; }
        let n = if ev.req.target == "/large" { 4 << 20 } else { 4096 };
        var bytes: u8[>..] = [];
        for i in n { bytes.push((i * 7 % 251) as! u8); }
        let b, err = http::shared_put(bytes, 1);
        assert(err == 0);
        // One reference for the handler at DRAINED, one it drops at once.
        assert(http::shared_retain(b, 1));
        state.blob = b;
        http::send(out, "<");
        assert(http::send_shared(out, b, 0, 1000));
        http::send(out, "|");
        assert(http::send_shared(out, b, 1000, n));
        assert(!http::send_shared(out, b, 0, n + 1));
        http::send(out, ">");
        // The handler's other reference, and the loop's for each range if it gathers.
        let left = http::shared_release(b);
        assert(left == 1 || left == 3);
        assert(http::after_drain(out));
    } else if ev.kind == http::DRAINED && !state.done {
        state.done = true;
        assert(http::shared_release(state.blob) == 0);
        http::send(out, "!");
        assert(http::after_drain(out));
    } else if ev.kind != http::DRAINED {
        http::ws_read(ev, state.ws, out) { op, data, reply => };
    }
}

thread_fn worker(cfg: http::Config) {
    var loop_name: u8[>..] = [];
    let error = if env("LOOP", loop_name) && loop_name == "epoll" {
        http::serve_epoll(cfg, State { .. }) { ev, state, out => handle(ev, state, out); }
    } else {
        http::serve(cfg, State { .. }) { ev, state, out => handle(ev, state, out); }
    };
    http::report(error);
}

fn main() {
    http::run(http::Config { address: "127.0.0.1", port: 27895, workers: 1,
        max_conns: 8, write_ms: 10000, idle_ms: 10000, .. }, worker);
}
