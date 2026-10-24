// HTTP/3 beside HTTP/1.1 and h2 over TLS on port 8443, from one loop per
// worker: h3 on UDP 8443, and the TCP listener for clients that haven't
// found h3. The files of a directory are under /static/, with their .br and
// .gz copies. The certificate chain and key are PEM files, named on the
// command line, with the directory after them; LOOP=uring serves with
// http::serve, over io_uring, and otherwise http::serve_epoll; PORT and
// TLS_PORT move the ports from 8080 and 8443:
//
//   h3 server.crt server.key [dir]
import std;
import os;
import http from "../../";
import tls from "../../../goose-tls-quic";
import http.tls;
import http.h3;

// What a file's response still has to send, between the handler's calls.
struct Download { file: http::FileBody = http::FileBody { .. } }

struct Setup { ctx: tls::Context, dir: u8[..256], uring: bool }

thread_fn worker(cfg: http::Config, s: Setup) {
    var server = http::tls_server(s.ctx);
    var h3 = http::h3_server(s.ctx, Download { .. });
    let e = if s.uring { http::serve(cfg, Download { .. }, server, h3) { ev, st, out => handle(ev, st, out, s.dir); } }
            else { http::serve_epoll(cfg, Download { .. }, server, h3) { ev, st, out => handle(ev, st, out, s.dir); } };
    http::release(h3);
    http::release(server);
    http::report(e);
}

fn handle(ev: http::Event, st: Download&, out: http::Reply, dir: const u8[:]) {
    if ev.kind == http::MORE {
        if !http::send_file(out, st.file) { http::end(out); }
        return;
    }
    if ev.kind == http::CLOSED {
        http::close_body(st.file);
        return;
    }
    guard ev.kind == http::REQUEST else { return; }
    var r = http::router(ev.req);
    if http::on(r, "GET", "/") {
        http::respond(out, 200, "text/plain", "Hello, World!");
    } else if http::on(r, "GET", "/baseline2") {
        var sum = 0;
        http::each_query(ev.req.target) { name, value =>
            let n, ok = parse_int(value);
            if ok { sum += n; }
        };
        http::respond(out, 200, "text/plain", str(sum));
    } else if http::on(r, "POST", "/echo") && ev.whole {
        http::respond(out, 200, "application/octet-stream", ev.data);
    } else if http::on(r, "GET", "/static/*path") {
        var path: u8[>..] = [];
        guard http::file_path(dir, http::param(r, "path"), path) else {
            http::respond(out, 404, "text/plain", "");
            return;
        }
        let f, status = http::open_precompressed(ev.req, path);
        guard status == 200 else {
            http::respond(out, status, "text/plain", "");
            return;
        }
        http::serve_file(ev.req, out, f, http::content_type_of(path), st.file);
    } else {
        http::otherwise(r, out);
    }
}

// The port the environment variable name gives, or otherwise.
fn port_of(name: const u8[:], otherwise: i32) -> i32 {
    var text: u8[>..] = [];
    guard env(name, text) else { return otherwise; }
    let n, ok = parse_int(trim(text));
    guard ok && n > 0 && n < 65536 else { abort(str(name, ": not a port")); }
    return n as i32;
}

fn main() {
    let argv = args();
    guard argv.len == 3 || argv.len == 4 else {
        write_stderr("usage: h3 CERT KEY [DIR]\n");
        exit(2);
    }
    let ctx, ok = tls::server_files(argv[1], argv[2], ["h3", "h2", "http/1.1"]);
    guard ok else {
        write_stderr(str("h3: ", tls::error_text(), "\n"));
        exit(1);
    }
    var s = Setup { ctx: ctx, dir: ".", uring: false };
    if argv.len == 4 {
        guard argv[3].len <= 256 else { write_stderr("the directory's path is longer than 256 bytes\n"); exit(2); }
        s.dir.clear();
        s.dir.append(argv[3]);
    }
    var loop_name: u8[>..] = [];
    s.uring = env("LOOP", loop_name) && loop_name == "uring";
    http::exit_on_error(http::stop_on_signals());
    var cfg = http::Config { port: port_of("PORT", 8080), .. };
    let tls_port = port_of("TLS_PORT", 8443);
    cfg.listeners.push(http::Listener { port: tls_port, tls: true, h3: true });
    print("h3 on port ", tls_port);
    http::run(cfg, s, worker);
    tls::free(ctx);
}
