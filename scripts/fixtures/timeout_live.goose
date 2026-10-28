import std;
import os;
import http from "../../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http.websocket;

struct State { ws: http::WebSocket = http::WebSocket { .. }, upgraded: bool = false, ticks: i64 = 0 }

// An upgraded exchange's TIMEOUT is a tick: its key stays live through the
// handler, as a publisher's mail_live sees it. A plain exchange's TIMEOUT
// ends it: its key is retired first, so a late reply finds it STALE.
fn handle(ev: http::Event, state: State&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        if ev.req.target == "/plain" {
            http::later(out, 20);
            return;
        }
        guard http::ws_upgrade(ev.req, state.ws, out) else { return; }
        state.upgraded = true;
        http::later(out, 20);
    } else if ev.kind == http::TIMEOUT && !state.upgraded {
        let live = http::mail_live(out.stream.later);
        http::respond(out, 200, "text/plain", if live { "live" } else { "retired" });
    } else if ev.kind == http::TIMEOUT {
        guard http::mail_live(out.stream.later) else {
            write_stderr(str("upgraded key stale at TIMEOUT ", state.ticks, "\n"));
            exit(1);
        }
        state.ticks++;
        if state.ticks == 20 {
            print("upgraded key live through 20 TIMEOUTs");
            http::ws_send(out, http::WS_TEXT, "done");
        }
        http::later(out, 20);
    } else {
        http::ws_read(ev, state.ws, out) { op, data, reply => };
        if ev.kind != http::CLOSED { http::later(out, 20); }
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
    http::exit_on_error(http::stop_on_signals());
    http::run(http::Config { address: "127.0.0.1", port: 27895, workers: 1, max_conns: 8, mail_slots: 8, max_waiting: 8, .. }, worker);
}
