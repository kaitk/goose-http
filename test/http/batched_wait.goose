// Config.ring_batch_us: a wait holds for more completions, but never past
// the loop's next timer, its sweep within a second, so a request is answered
// though the batch is far longer, and a stop still ends the loop. Where the
// ring is emulated the setting does nothing, and the same holds.
import std;
import os;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.client;

thread_fn worker(cfg: http::Config) {
    let e = http::serve(cfg) { req, body, out => http::respond(out, 200, "text/plain", "hello"); };
    if e.code != 0 { http::report(e); }
}

fn main() {
    var dir: u8[>..] = [];
    var address: u8[>..] = [];
    if env("TMPDIR", dir) && dir.len > 0 { format(address, "unix:", dir, "/bw.sock"); }
    else { format(address, "unix:", "bw.sock"); }
    let w = thread_spawn(worker, http::Config { address: address, workers: 1, ring_batch_us: 5000000, .. });
    var up = false;
    for i in 500 {
        var s, e = http::connect(address, 0, 1000);
        if e.code == 0 {
            http::hangup(s);
            up = true;
            break;
        }
        sleep_ms(10);
    }
    assert(up);
    var session = http::session(10000);
    session.via.append(address);
    for i in 2 {
        let t0 = time_ns();
        let r, e = http::get(session, "http://localhost/");
        let ms = (time_ns() - t0) / 1000000;
        print(e.code, " ", r.status, " ", r.body, ", within the sweep: ", ms < 2500);
    }
    http::free(session);
    http::stop();
    thread_wait(w);
    print("stopped");
}
