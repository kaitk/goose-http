// Responses compressed by the request's Accept-Encoding: zstd, gzip, or
// deflate, from goose-compress. A program that doesn't import
// http.compression builds without it.
//
//   curl --compressed localhost:8080/report
//   curl -H 'Accept-Encoding: zstd' localhost:8080/count/1000 | zstd -d
import std;
import http from "../../";
import compress from "github.com/kaitk/goose-compress@v0.1.4";
import http.compression;

// An exchange's state: the encoder of a streamed response, and the lines
// still to send.
struct St {
    coded: http::Compressed = http::Compressed { .. },
    next: i64 = 0,
    last: i64 = 0,
}

let MAX_COUNT = 1000000;

thread_fn worker(cfg: http::Config) {
    let e = http::serve(cfg, St { .. }) { ev, st, out => handle(ev, st, out); };
    guard e.code != 0 else { return; }
    http::report(e);
    exit(1);
}

fn handle(ev: http::Event, st: St&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        var r = http::router(ev.req);
        if http::on(r, "GET", "/report") {
            // A whole response: compressed when the client takes a coding and
            // the body is at least Compression.min_size, 256 bytes by default.
            var body: u8[>..] = [];
            body.push('[');
            for i in 200 {
                if i > 0 { body.push(','); }
                format(body, "{\"id\":", i + 1, ",\"status\":\"ok\",\"note\":\"all quiet\"}");
            }
            body.push(']');
            http::respond_compressed(out, ev.req, 200, "application/json", body);
        } else if http::on(r, "GET", "/count/:n") {
            // A streamed response: each piece compressed and flushed, sent
            // as the connection has room.
            let n, ok = parse_int(http::param(r, "n"));
            guard ok && n >= 0 && n <= MAX_COUNT else { http::respond(out, 404, "text/plain", ""); return; }
            http::begin_compressed(out, ev.req, 200, "text/plain", st.coded);
            st.next = 1;
            st.last = n;
            if n == 0 || out.head { http::end_compressed(out, st.coded); }
        } else {
            http::otherwise(r, out);
        }
    } else if ev.kind == http::MORE {
        var piece: u8[>..] = [];
        while st.next <= st.last && piece.len < 16384 {
            format(piece, st.next, "\n");
            st.next++;
        }
        http::send_compressed(out, st.coded, piece);
        if st.next > st.last { http::end_compressed(out, st.coded); }
    } else if ev.kind == http::CLOSED {
        http::release_compressed(st.coded);
    }
}

fn main() {
    http::exit_on_error(http::stop_on_signals());
    let cfg = http::Config { port: 8080, .. };
    print("listening on port ", cfg.port);
    http::run(cfg, worker);
}
