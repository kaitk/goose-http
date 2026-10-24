// HTTPS: HTTP/1.1 over TLS 1.3 on port 8443, and plain HTTP on 8080, from one
// loop per worker. The certificate chain and key are PEM files, named on the
// command line:
//
//   tls server.crt server.key
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;

thread_fn worker(cfg: http::Config, ctx: tls::Context) {
    var server = http::tls_server(ctx);
    let e = http::serve_epoll(cfg, server) { req, body, out =>
        if http::path_of(req.target) == "/" {
            http::respond(out, 200, "text/plain", "Hello, World!");
        } else if req.method == "POST" && http::path_of(req.target) == "/echo" {
            http::respond(out, 200, "application/octet-stream", body);
        } else {
            http::respond(out, 404, "text/plain", "");
        }
    };
    http::release(server);
    http::report(e);
}

fn main() {
    let argv = args();
    guard argv.len == 3 else {
        write_stderr("usage: tls CERT KEY\n");
        exit(2);
    }
    let ctx, ok = tls::server_files(argv[1], argv[2], ["http/1.1"]);
    guard ok else {
        write_stderr(str("tls: ", tls::error_text(), "\n"));
        exit(1);
    }
    var cfg = http::Config { port: 8080, .. };
    cfg.listeners.push(http::Listener { port: 8443, tls: true });
    http::run(cfg, ctx, worker);
    tls::free(ctx);
}
