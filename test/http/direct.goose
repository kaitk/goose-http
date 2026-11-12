// Config.ring_direct: connections that are io_uring direct descriptors are
// served, kept alive, and closed, and http::peer gives the client's address
// from the accept. Where the ring is emulated the setting does nothing, and
// the same holds.
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.client;

thread_fn worker(cfg: http::Config) {
    let e = http::serve(cfg) { req, body, out =>
        let a, ok = http::peer(out);
        http::respond(out, 200, "text/plain",
                      str(ok, " ", a.ip[12] as i64, ".", a.ip[13] as i64, ".", a.ip[14] as i64, ".",
                          a.ip[15] as i64, ", a port: ", a.port > 0));
    };
    if e.code != 0 { http::report(e); }
}

fn main() {
    // A port of its own, as the runner runs each build of a test at once.
    let port = 20000 + (random_seed() % 20000) as i32;
    let url = str("http://127.0.0.1:", port, "/");
    let w = thread_spawn(worker, http::Config { address: "127.0.0.1", port: port, workers: 1, ring_direct: true, .. });
    var up = false;
    for i in 500 {
        var s, e = http::connect("127.0.0.1", port, 1000);
        if e.code == 0 {
            http::hangup(s);
            up = true;
            break;
        }
        sleep_ms(10);
    }
    assert(up);
    // Two on one connection, then one on another.
    var session = http::session(5000);
    for i in 2 {
        let r, e = http::get(session, url);
        print(e.code, " ", r.status, " ", r.body);
    }
    http::free(session);
    var other = http::session(5000);
    let r, e = http::get(other, url);
    print(e.code, " ", r.status, " ", r.body);
    http::free(other);
    http::stop();
    thread_wait(w);
    print("stopped");
}
