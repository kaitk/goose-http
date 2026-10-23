// The benchmark server, serving with http::serve_epoll unless LOOP says
// otherwise: epoll on Linux, kqueue on macOS. It serves no TLS, so it doesn't
// map OpenSSL; server_tls.goose adds the TLS listener.
import http from "../";
import compress from "github.com/kaitk/goose-compress@v0.1.4";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import app;

fn main() { run("epoll", no_tls, workers); }
