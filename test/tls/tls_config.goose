// What serve_epoll and serve with a TlsServer refuse before they open a
// listener: a TLS listener without a context, and TLS on an h2c listener:
// h2c is h2 by prior knowledge, and over TLS ALPN chooses h2 (alpn.goose).
import std;
import http from "../../";
import tls from "../../../goose-tls-quic";
import http.tls;

fn main() {
    var none = http::TlsServer { .. };
    var cfg = http::Config { port: 1, tls: true, .. };
    var e = http::serve_epoll(cfg, none) { req, body, out => http::respond(out, 200, "text/plain", ""); };
    print("no context: ", e.call, " ", e.code == http::EINVAL);
    e = http::serve(cfg, none) { req, body, out => http::respond(out, 200, "text/plain", ""); };
    print("serve, no context: ", e.call, " ", e.code == http::EINVAL);

    var chain: u8[>..] = [];
    var key: u8[>..] = [];
    let failed = tls::run() {
        let k = tls::key_generate(tls::P256);
        chain = tls::self_signed(k, ["localhost"], 1);
        key = tls::key_pem(k);
        tls::free(k);
    };
    assert(failed.len == 0);
    let ctx, ok = tls::server(chain, key, ["http/1.1"]);
    assert(ok);
    var server = http::tls_server(ctx);
    tls::free(ctx);
    cfg.tls = false;
    cfg.listeners.push(http::Listener { port: 2, h2c: true, tls: true });
    e = http::serve_epoll(cfg, false, server) { ev, st, out => http::respond(out, 200, "text/plain", ""); };
    print("h2c and TLS: ", e.call, " ", e.code == http::EINVAL);
    e = http::serve(cfg, false, server) { ev, st, out => http::respond(out, 200, "text/plain", ""); };
    print("serve, h2c and TLS: ", e.call, " ", e.code == http::EINVAL);
    http::release(server);
}
