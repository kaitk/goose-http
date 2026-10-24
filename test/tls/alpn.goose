// The driver a TLS connection gets, by ALPN, once its handshake is done:
// h2 where the server's context lists "h2" and the client offers it, and
// HTTP/1.1 otherwise; a client that offers ALPN with nothing in common is
// refused (RFC 7301 §3.2). Each handshake runs in memory, a TlsServer slot
// against goose-tls's client, with a certificate made here.
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;

// The driver slot k of server chose for a client of cctx, after their
// handshake, or "refused" when the server's side failed it.
fn driver(server: http::TlsServer&, cctx: tls::Context) -> const u8[:] {
    let k = http::tls_open(server);
    assert(k >= 0);
    let c = tls::connect(cctx, "localhost");
    assert(tls::ok(c));
    var buf: u8[16384] = [0; 16384];
    var plain: u8[>..] = [];
    var w: u8[>..] = [];
    var going = true;
    for round in 8 {
        tls::handshake(c);
        while going && tls::pending(c) > 0 {
            let n = tls::drain(c, buf);
            guard n > 0 else { break; }
            going = http::tls_take(server, k, buf[..n], plain);
        }
        w.clear();
        assert(http::tls_seal(server, k, w, 0, false));
        if w.len > 0 { tls::feed(c, w); }
        if !going || http::tls_ready(server, k) && tls::handshake(c) == 0 { break; }
    }
    let ready = going && http::tls_ready(server, k);
    let h2 = http::tls_h2(server, k);
    http::tls_close(server, k, -1, false);
    tls::free(c);
    return if !ready { "refused" } else if h2 { "h2" } else { "http/1.1" };
}

// Prints the driver a client offering offers gets from server.
fn offer(server: http::TlsServer&, chain: const u8[:], label: const u8[:], offers: const u8[:][:]) {
    let cctx, ok = tls::client_trusting(chain, offers);
    assert(ok);
    print("  offers ", label, ": ", driver(server, cctx));
    tls::free(cctx);
}

// Prints the driver each client gets from a server whose context lists
// protocols.
fn serve(chain: const u8[:], key: const u8[:], label: const u8[:], protocols: const u8[:][:]) {
    let ctx, ok = tls::server(chain, key, protocols);
    assert(ok);
    var server = http::tls_server(ctx);
    tls::free(ctx);
    print("server lists ", label, ":");
    offer(server, chain, "h2", ["h2"]);
    offer(server, chain, "http/1.1", ["http/1.1"]);
    offer(server, chain, "http/1.1 then h2", ["http/1.1", "h2"]);
    offer(server, chain, "nothing", []);
    offer(server, chain, "spdy/3", ["spdy/3"]);
    http::release(server);
}

fn main() {
    var chain: u8[>..] = [];
    var key: u8[>..] = [];
    let failed = tls::run() {
        let k = tls::key_generate(tls::P256);
        chain = tls::self_signed(k, ["localhost"], 1);
        key = tls::key_pem(k);
        tls::free(k);
    };
    assert(failed.len == 0);
    serve(chain, key, "h2, http/1.1", ["h2", "http/1.1"]);
    serve(chain, key, "http/1.1", ["http/1.1"]);
}
