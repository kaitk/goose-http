// An HTTP/1.1 exchange's lane reply after its client has gone, and h2c
// streams of a later connection in the same slot: the reply must find
// none of them. And h2c streams that wait at once: a reply finds each
// until it ends. /slow hands its address to a lane that replies 300 ms
// later and again 300 ms after that, and prints what each send returned;
// /wait waits 1 s and answers its WAKE with the bytes, or TIMEOUT. LOOP
// picks the loop: epoll, uring (io_uring, required), emulated, or serve's
// own choice otherwise.
import std;
import os;
import http from "../../";

struct Job { reply: http::MailAddress }

thread_fn slow_lane(box: http::Box) {
    http::lane(box) { tag, bytes =>
        var j = Job { .. };
        if http::mail_value(bytes, j) {
            for i in 2 {
                sleep_ms(300);
                let r = http::mail_send(j.reply, 9, "from the lane");
                print(if r == http::SENT { "lane: sent" } else if r == http::STALE { "lane: stale" } else { "lane: other" });
            }
        }
    };
}

fn handle(ev: http::Event, out: http::Reply, lane: const http::Lane&) {
    if ev.kind == http::REQUEST && ev.req.target == "/slow" {
        guard http::lane_send_value(lane, 1, Job { reply: http::later(out, 5000) }) == http::SENT else {
            http::respond(out, 503, "text/plain", "busy");
            return;
        }
    } else if ev.kind == http::REQUEST && ev.req.target == "/wait" {
        http::later(out, 1000);
    } else if ev.kind == http::REQUEST {
        http::respond(out, 200, "text/plain", "hello");
    } else if ev.kind == http::WAKE {
        http::respond(out, 200, "text/plain", ev.data);
    } else if ev.kind == http::TIMEOUT {
        http::respond(out, 200, "text/plain", "timeout");
    }
}

fn main() {
    var name: u8[>..] = [];
    if env("LOOP", name) && name == "uring" && http::ring_probe() != 0 {
        print("no io_uring here");
        return;
    }
    http::exit_on_error(http::stop_on_signals());
    let lane = http::lane_open(http::LaneConfig { slots: 8, size: 64, .. }, slow_lane);
    let port: i32 = if name == "uring" { 27884 } else if name == "emulated" { 27882 } else { 27880 };
    var cfg = http::Config { address: "127.0.0.1", port: port, workers: 1, mail_slots: 8, max_waiting: 8, .. };
    cfg.listeners.push(http::Listener { port: port + 1, h2c: true });
    let error = if name == "epoll" {
        http::serve_epoll(cfg, false) { ev, state, out => handle(ev, out, lane); }
    } else {
        cfg.require_ring = name == "uring";
        cfg.emulate_ring = name == "emulated";
        http::serve(cfg, false) { ev, state, out => handle(ev, out, lane); }
    };
    http::report(error);
}
