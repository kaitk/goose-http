// The worker's own address and local wakes. /wait waits; /ping mails the
// worker's address from its own thread, and /far from another thread, and
// the WORKER call that follows wakes every exchange that waits, with the
// message's tag, through http::wake. LOOP picks the loop: epoll, uring
// (io_uring, required), emulated, or serve's own choice otherwise.
import std;
import os;
import http from "../../";

struct State { n: i64 = 0 }

// The worker's waiting exchanges, for its WORKER calls to wake: those from
// woken on.
var waiters: http::MailAddress[>..] = [];
var woken: i64 = 0;

thread_fn far(to: http::MailAddress) {
    while http::mail_send(to, 9, "hi") == http::FULL { sleep_ms(1); }
}

fn handle(cfg: const http::Config&, ev: http::Event, state: State&, out: http::Reply) {
    if ev.kind == http::WORKER {
        assert(ev.data == "hi");
        var woke = 0;
        var stale = 0;
        for to in waiters[woken..] {
            let sent = http::wake(to, ev.tag);
            if sent == http::SENT { woke++; } else { assert(sent == http::STALE); stale++; }
        }
        woken = waiters.len;
        print(str("tag ", ev.tag, ": woke ", woke, ", stale ", stale));
    } else if ev.kind == http::REQUEST && ev.req.target == "/wait" {
        waiters.push(http::later(out, 5000));
    } else if ev.kind == http::REQUEST && ev.req.target == "/ping" {
        let sent = http::mail_send(http::worker_address(cfg, out), 7, "hi");
        http::respond(out, 200, "text/plain", if sent == http::SENT { "sent" } else { "refused" });
    } else if ev.kind == http::REQUEST && ev.req.target == "/far" {
        thread_spawn(far, http::worker_address(cfg, out));
        http::respond(out, 200, "text/plain", "sent");
    } else if ev.kind == http::WAKE {
        // A wake carries no bytes.
        assert(ev.data.len == 0);
        http::respond(out, 200, "text/plain", str("woken ", ev.tag));
    } else if ev.kind == http::TIMEOUT {
        http::respond(out, 504, "text/plain", "timeout");
    }
}

thread_fn worker(cfg: http::Config) {
    var name: u8[>..] = [];
    let error = if env("LOOP", name) && name == "epoll" {
        http::serve_epoll(cfg, State { .. }) { ev, state, out => handle(cfg, ev, state, out); }
    } else {
        var ring = cfg;
        ring.require_ring = name == "uring";
        ring.emulate_ring = name == "emulated";
        http::serve(ring, State { .. }) { ev, state, out => handle(cfg, ev, state, out); }
    };
    http::report(error);
}

fn main() {
    var name: u8[>..] = [];
    if env("LOOP", name) && name == "uring" && http::ring_probe() != 0 {
        print("no io_uring here");
        return;
    }
    http::exit_on_error(http::stop_on_signals());
    let port: i32 = if name == "uring" { 27894 } else if name == "emulated" { 27893 } else { 27892 };
    http::run(http::Config { address: "127.0.0.1", port: port, workers: 1, max_conns: 16, mail_slots: 16,
                             max_waiting: 16, .. }, worker);
}
