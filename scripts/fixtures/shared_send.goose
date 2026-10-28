// send_shared in a loop: inline bytes and a blob's ranges, interleaved, the
// handler's reference dropped at once, and the blob's last reference the
// handler's own again by DRAINED, whether the socket took it all (/small)
// or the loop had to keep the rest (/large, behind a stalled reader). LOOP
// picks the loop: epoll, uring (io_uring, required), emulated (the ring's
// emulation), or serve's own choice otherwise. With GATHERS=1 the loop must
// hold a reference for each range until it sends it, not copy it.
import std;
import os;
import http from "../../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http.websocket;
import http.shared;

struct State { ws: http::WebSocket = http::WebSocket { .. }, blob: http::Shared = http::Shared { .. }, done: bool = false,
               gathers: bool = false }

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
        assert(left == (if state.gathers { 3 } else { 1 }));
        assert(http::after_drain(out));
    } else if ev.kind == http::DRAINED && !state.done {
        state.done = true;
        assert(http::shared_release(state.blob) == 0);
        http::send(out, "!");
        assert(http::after_drain(out));
    } else if ev.kind == http::CLOSED && !state.done && state.blob.h != 0 {
        // A client that left early: the loop may still hold its ranges.
        state.done = true;
        assert(http::shared_release(state.blob) >= 0);
    } else if ev.kind != http::DRAINED {
        http::ws_read(ev, state.ws, out) { op, data, reply => };
    }
}

thread_fn worker(cfg: http::Config) {
    var name: u8[>..] = [];
    var gathers: u8[>..] = [];
    let fresh = State { gathers: env("GATHERS", gathers) && gathers == "1", .. };
    let error = if env("LOOP", name) && name == "epoll" {
        http::serve_epoll(cfg, fresh) { ev, state, out => handle(ev, state, out); }
    } else {
        var ring = cfg;
        ring.require_ring = name == "uring";
        ring.emulate_ring = name == "emulated";
        http::serve(ring, fresh) { ev, state, out => handle(ev, state, out); }
    };
    http::report(error);
}

fn main() {
    var name: u8[>..] = [];
    if env("LOOP", name) && name == "uring" && http::ring_probe() != 0 {
        print("no io_uring here");
        return;
    }
    // A port per loop: a stopped io_uring server's listener can outlive it
    // briefly, and reset the next server's connections.
    let port: i32 = if name == "uring" { 27897 } else if name == "emulated" { 27896 } else { 27895 };
    http::run(http::Config { address: "127.0.0.1", port: port, workers: 1,
        max_conns: 8, write_ms: 10000, idle_ms: 10000, .. }, worker);
}
