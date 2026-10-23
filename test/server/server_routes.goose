// The benchmark server's routes (server/routes.goose), which this declares as
// a package, since a program's own imports resolve below its root file's
// directory.
import std;
import http from "../../";
import compress from "github.com/kaitk/goose-compress@v0.1.4";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import routes from "../../server";
import check from "../";

let GET = "GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n";

// Answers a request, whose body follows its head, into out, as the loops do.
// Returns whether the connection stays open.
fn response(text: const u8[:], out: u8[>..]&) -> bool {
    let r, s = http::parse(text);
    assert(s == 200);
    var keep = r.keep_alive;
    var stream = http::Stream { .. };
    var st = Transfer { .. };
    let reply = http::Reply { buf: out, common: check::COMMON, keep_alive: keep, minor: r.minor, head: r.method == "HEAD",
                              stream: stream };
    handle(http::Event { kind: http::REQUEST, req: r, data: text[r.len..], whole: true, trailers: "" }, st, reply);
    while stream.open { handle(http::Event { kind: http::MORE, req: r, data: "", whole: false, trailers: "" }, st, reply); }
    return keep;
}

fn main() {
    var out: u8[>..] = [];
    assert(response(GET, out));
    check::same(out, "HTTP/1.1 200 OK\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!");

    out.clear();
    assert(response("GET /json?x=1 HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out, "HTTP/1.1 200 OK\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{\"message\":\"Hello, World!\"}");

    out.clear();
    assert(response("HEAD /plaintext HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out, "HTTP/1.1 200 OK\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\n");

    out.clear();
    assert(!response("GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", out));
    check::same(out, "HTTP/1.1 404 Not Found\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");

    out.clear();
    assert(response("POST /json HTTP/1.0\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\n", out));
    check::same(out, "HTTP/1.1 405 Method Not Allowed\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nConnection: keep-alive\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\n\r\n");
    print("plaintext, json, HEAD, 404 with close, 405 kept alive");

    // OPTIONS *, and a method the server doesn't recognize on any path.
    out.clear();
    assert(response("OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out, "HTTP/1.1 200 OK\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nAllow: GET, HEAD, POST, OPTIONS\r\nContent-Length: 0\r\n\r\n");
    out.clear();
    assert(response("BREW /plaintext HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out, "HTTP/1.1 501 Not Implemented\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nContent-Length: 0\r\n\r\n");
    out.clear();
    assert(response("BREW /nope HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out[..31], "HTTP/1.1 501 Not Implemented\r\nS");
    out.clear();
    assert(response("DELETE /plaintext HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out[..33], "HTTP/1.1 405 Method Not Allowed\r\n");
    out.clear();
    assert(response("OPTIONS /nope HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out[..24], "HTTP/1.1 404 Not Found\r\n");
    print("OPTIONS, 501, 405, 404");

    // HttpArena's endpoints.
    out.clear();
    assert(response("GET /baseline11?a=13&b=42 HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out, "HTTP/1.1 200 OK\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n55");
    out.clear();
    assert(response("POST /baseline11?b=-50&x&a=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n 20\n", out));
    check::same(out[^3..], "-29");
    out.clear();
    assert(response("POST /baseline11 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nzz", out));
    check::same(out[^1..], "0");
    out.clear();
    assert(response("PUT /baseline11 HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out, "HTTP/1.1 405 Method Not Allowed\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nAllow: GET, HEAD, POST\r\nContent-Length: 0\r\n\r\n");
    out.clear();
    assert(response("GET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out[^2..], "ok");
    print("HttpArena: baseline11 GET and POST, 405, pipeline");
    out.clear();
    assert(response("GET /bytes?n=12 HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out, "HTTP/1.1 200 OK\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nContent-Length: 12\r\nContent-Type: application/octet-stream\r\n\r\n012345678901");
    // Longer than a MORE's piece.
    out.clear();
    assert(response("GET /bytes?n=50000 HTTP/1.1\r\nHost: x\r\n\r\n", out));
    assert(find(out, "\r\nContent-Length: 50000\r\n") > 0);
    check::same(out[^50004..^49997], "\r\n\r\n012");
    check::same(out[^10..], "0123456789");
    // Chunked, in pieces of 16 KB.
    out.clear();
    assert(response("GET /stream?n=20000 HTTP/1.1\r\nHost: x\r\n\r\n", out));
    assert(find(out, "\r\nTransfer-Encoding: chunked\r\n") > 0);
    check::same(out[find(out, "\r\n\r\n") + 4..find(out, "\r\n\r\n") + 16], "4000\r\n012345");
    check::same(out[^17..], "0123456789\r\n0\r\n\r\n");
    // HEAD gets the head alone.
    out.clear();
    assert(response("HEAD /bytes?n=50000 HTTP/1.1\r\nHost: x\r\n\r\n", out));
    check::same(out[^39..], "50000\r\nContent-Type: application/octet-stream\r\n\r\n"[^39..]);
    print("bytes of 12 and 50000, stream of 20000 in 16 KB chunks, HEAD");
    // /upload and /echo, with whole bodies.
    out.clear();
    assert(response("POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc", out));
    check::same(out[^7..], "\r\n3 294");
    out.clear();
    assert(response("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc", out));
    check::same(out[^64..], "Content-Length: 3\r\nContent-Type: application/octet-stream\r\n\r\nabc");
    print("upload and echo, with whole bodies");
}
