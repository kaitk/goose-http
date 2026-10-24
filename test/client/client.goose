// http.client against two servers in the program, on Unix sockets in TMPDIR:
// serve, plain, and serve_epoll with TLS and a certificate goose-tls makes
// here. A POST with a bearer token, a field, and a JSON body, over https and
// http; a GET that reuses the connection, and one after the server closed
// it; the requests the session refuses before sending; and a session that
// doesn't trust the certificate.
import std;
import os;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;
import http.client;

struct Credentials { user: const u8[:], password: const u8[:] }

fn format(out: u8[>..]&, c: const Credentials&) {
    out.append("{\"user\":");
    http::json_string(out, c.user);
    out.append(",\"password\":");
    http::json_string(out, c.password);
    out.push('}');
}

fn handle(req: const http::Request&, body: const u8[:], out: http::Reply) {
    let path = http::path_of(req.target);
    if req.method == "POST" && path == "/v1/login" {
        let auth, a = http::field_of(req, "Authorization");
        let device, d = http::field_of(req, "X-Device-Id");
        let media, m = http::field_of(req, "Content-Type");
        http::respond(out, 200, "text/plain", str(auth, "\n", device, "\n", media, "\n", body));
    } else if path == "/hello" {
        http::respond(out, 200, "text/plain", "hello");
    } else {
        http::respond(out, 404, "text/plain", "");
    }
}

thread_fn plain_worker(cfg: http::Config) {
    let e = http::serve(cfg) { req, body, out => handle(req, body, out); };
    if e.code != 0 { http::report(e); }
}

thread_fn tls_worker(cfg: http::Config, ctx: tls::Context) {
    var server = http::tls_server(ctx);
    let e = http::serve_epoll(cfg, server) { req, body, out => handle(req, body, out); };
    http::release(server);
    if e.code != 0 { http::report(e); }
}

fn unix_address(name: const u8[:]) -> u8[>..] {
    var dir: u8[>..] = [];
    var a: u8[>..] = [];
    if env("TMPDIR", dir) && dir.len > 0 { format(a, "unix:", dir, "/", name); }
    else { format(a, "unix:", name); }
    return a;
}

// Waits for the server at address to listen.
fn listening(address: const u8[:]) {
    for i in 500 {
        var s, e = http::connect(address, 0, 1000);
        if e.code == 0 {
            http::hangup(s);
            return;
        }
        sleep_ms(10);
    }
    abort(str("nothing listens at ", address));
}

fn show(response: const http::ClientResponse&, err: http::Error) {
    if err.code != 0 {
        print("failed: ", err.call, " ", err.code);
        return;
    }
    let length, has = http::header(response, "content-length");
    print(response.status, ", Content-Length ", length, ":\n", response.body);
}

fn login(session: http::Session&, url: const u8[:]) {
    let api_key = "k-123";
    let device_id = "dev-9";
    let credentials = Credentials { user: "ann", password: "p\"w" };
    let response, err = http::post(session, url) { req =>
        http::bearer(req, api_key);
        http::header(req, "X-Device-Id", device_id);
        http::json(req, credentials);
    };
    show(response, err);
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
    let ctx, ok = tls::server(chain, key, ["http/1.1"]);
    assert(ok);
    let plain = unix_address("http-client-plain.sock");
    let secure = unix_address("http-client-tls.sock");
    let w = [
        thread_spawn(plain_worker, http::Config { address: plain, workers: 1, .. }),
        thread_spawn(tls_worker, http::Config { address: secure, workers: 1, tls: true, max_requests: 2, .. }, ctx),
    ];
    listening(plain);
    listening(secure);

    var session, trusted = http::session_trusting(chain, 5000);
    assert(trusted);
    print("== https");
    session.via.append(secure);
    login(session, "https://localhost/v1/login");
    // The server closes a connection at its second request, which says so
    // only if the login's connection carried it; the third reconnects.
    for i in 2 {
        let hello, e = http::get(session, "https://localhost/hello");
        show(hello, e);
        let connection, closes = http::header(hello, "Connection");
        print("Connection: ", if closes { connection } else { "(none)" });
    }

    print("== http");
    session.via.clear();
    session.via.append(plain);
    login(session, "http://localhost:8080/v1/login");

    print("== refused");
    let r1, e1 = http::get(session, "ftp://localhost/");
    print(e1.call, " ", e1.code == http::EINVAL);
    let r2, e2 = http::get(session, "http://localhost/") { req => http::header(req, "X-Bad", "a\r\nb"); };
    print(e2.call, " ", e2.code == http::EINVAL);
    let r3, e3 = http::get(session, "http://localhost/") { req => http::header(req, "Content-Length", "9"); };
    print(e3.call, " ", e3.code == http::EINVAL);
    let r4, e4 = http::post(session, "http://localhost/") { req =>
        http::body(req, "text/plain", "one");
        http::body(req, "text/plain", "two");
    };
    print(e4.call, " ", e4.code == http::EINVAL);

    print("== untrusted");
    var stranger = http::session(5000);
    stranger.via.append(secure);
    let r5, e5 = http::get(stranger, "https://localhost/hello");
    print(e5.call, " ", r5.status);

    http::free(stranger);
    http::free(session);
    http::stop();
    for t in w { thread_wait(t); }
    tls::free(ctx);
}
