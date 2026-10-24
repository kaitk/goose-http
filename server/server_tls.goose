// The benchmark server with the TLS listener (https.goose), served with
// http::serve_epoll unless LOOP says otherwise: epoll on Linux, kqueue on
// macOS; with LOOP=uring, http::serve. This root declares goose-tls, and
// builds with OpenSSL; server_epoll.goose is the same server without TLS,
// which doesn't map it.
import http from "../";
import compress from "github.com/kaitk/goose-compress@v0.1.4";
import tls from "../../goose-tls-quic";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import app;
import https;

fn main() { run("epoll", tls_listener, tls_workers); }
