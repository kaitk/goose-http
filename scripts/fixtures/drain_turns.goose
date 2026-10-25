import std;
import os;
import http from "../../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http.websocket;

struct State { ws: http::WebSocket = http::WebSocket { .. } }

fn handle(ev: http::Event, state: State&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        if ev.req.target == "/health" {
            http::respond(out, 200, "text/plain", "ok");
            return;
        }
        guard http::ws_upgrade(ev.req, state.ws, out) else { return; }
    } else if ev.kind != http::DRAINED {
        http::ws_read(ev, state.ws, out) { op, data, reply => };
        return;
    }
    // A fast reader can keep this socket writable indefinitely. No later wait
    // exempts it from the timeout sweep, and no incoming frames refresh it.
    sleep_ms(2);
    let data: u8[8192] = ['x'; 8192];
    http::ws_send(out, http::WS_BINARY, data);
    assert(http::after_drain(out));
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
    http::exit_on_error(http::stop_on_signals());
    http::run(http::Config { address: "127.0.0.1", port: 27894, workers: 1,
        max_conns: 8, write_ms: 1000, body_ms: 1000, idle_ms: 1000, .. }, worker);
}
