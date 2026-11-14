// Config.ring_buffers far below the connections that send at once: a
// receive that finds no provided buffer free waits for one, and every
// connection is answered, twice, with plain and with direct descriptors.
// Where the ring is emulated, the same holds.
import std;
import http from "../../";

let CONNS = 64;

thread_fn worker(cfg: http::Config) {
    let e = http::serve(cfg) { req, body, out => http::respond(out, 200, "text/plain", "hello"); };
    if e.code != 0 { http::report(e); }
}

// Sends a request on each of socks before reading any answer, and returns
// how many were answered.
fn round(socks: http::Socket[:]) -> i64 {
    for s in socks {
        let e = http::send_all(s, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", 5000);
        assert(e.code == 0);
    }
    var answered = 0;
    var got: u8[>..] = [];
    var buf: u8[>..] = [];
    buf.resize(4096, 0);
    for s in socks {
        got.clear();
        while !ends_with(got, "hello") {
            let n = http::recv(s, buf, 5000);
            if n <= 0 { break; }
            got.append(buf[..n]);
        }
        if starts_with(got, "HTTP/1.1 200") && ends_with(got, "hello") { answered++; }
    }
    return answered;
}

fn main() {
    for direct in 2 {
        // A port of its own, as the runner runs each build of a test at once.
        let port = 20000 + (random_seed() % 20000) as i32;
        let w = thread_spawn(worker, http::Config { address: "127.0.0.1", port: port, workers: 1,
                                                    ring_buffers: 2, ring_direct: direct == 1, .. });
        var socks: http::Socket[>..] = [];
        for i in 500 {
            var s, e = http::connect("127.0.0.1", port, 1000);
            if e.code == 0 {
                socks.push(s);
                break;
            }
            sleep_ms(10);
        }
        assert(socks.len == 1);
        while socks.len < CONNS {
            var s, e = http::connect("127.0.0.1", port, 1000);
            assert(e.code == 0);
            socks.push(s);
        }
        for k in 2 { print("direct ", direct == 1, ", round ", k, ": ", round(socks), " of ", CONNS, " answered"); }
        for k in socks.len { http::hangup(socks[k]); }
        http::stop();
        thread_wait(w);
    }
    print("stopped");
}
