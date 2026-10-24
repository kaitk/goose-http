// The client's parts on bytes alone: URLs parsed, requests written, and
// responses read whole and at every shorter prefix, which must stay
// INCOMPLETE: lengths, chunks, a body that ends with the connection, a 1xx
// before the final response, bodies that HEAD, 204, and 304 don't have, a
// limit on the body, and responses it refuses.
import std;
import http from "../../";
import tls from "../../../goose-tls-quic";
import http.client;

fn url(u: const u8[:]) {
    let p, ok = http::parse_url(u);
    if ok { print(u, " -> ", p.secure, " | ", p.authority, " | ", p.host, " | ", p.port, " | ", p.target); }
    else { print(u, " -> refused"); }
}

fn outcome(n: i64) -> const u8[:] {
    return if n == http::READ_COMPLETE { "complete" } else if n == http::READ_AT_CLOSE { "complete at close" }
        else if n == http::INCOMPLETE { "incomplete" } else { "malformed" };
}

fn response(label: const u8[:], raw: const u8[:], closed: bool, head: bool = false, max_body: i64 = 1 << 20) {
    var r = http::ClientResponse { .. };
    var early = 0;
    for n in raw.len {
        let got = http::read_response(raw[..n], false, head, max_body, r);
        if got != http::INCOMPLETE && got != http::READ_MALFORMED { early++; }
    }
    let got = http::read_response(raw, closed, head, max_body, r);
    if got == http::READ_COMPLETE || got == http::READ_AT_CLOSE {
        let location, l = http::header(r, "location");
        let nonce, n = http::header(r, "Replay-Nonce");
        var line: u8[>..] = [];
        format(line, label, ": ", outcome(got), ", ", r.status, ", [", r.body, "]");
        if l { format(line, ", location ", location); }
        if n { format(line, ", nonce [", nonce, "]"); }
        if early > 0 { line.append(" (complete early): FAILED"); }
        print(line);
    } else {
        print(label, ": ", outcome(got), if early > 0 { " (complete early): FAILED" } else { "" });
    }
    assert(early == 0);
}

fn written(label: const u8[:], method: const u8[:], target: const u8[:], lines: const u8[:], media: const u8[:],
           body: const u8[:], want: const u8[:]) {
    let u, ok = http::parse_url(target);
    assert(ok);
    var l: u8[>..] = [];
    var p: u8[>..] = [];
    l.append(lines);
    p.append(body);
    let req = http::ClientRequest { lines: l, payload: p, media: media };
    var out: u8[>..] = [];
    http::write_request(out, method, u, req);
    let shown: u8[>..] = if out == want { "as expected" } else { str("got [", out, "]") };
    print(label, ": ", shown);
}

fn main() {
    url("https://example.com");
    url("http://example.com:8080/a?b=1#frag");
    url("https://acme-v02.api.letsencrypt.org/directory");
    url("https://[::1]:14000/dir?x=1");
    url("https://127.0.0.1");
    url("https://:443/dir");
    url("https://example.test:0/");
    url("https://example.test:+443/");
    url("https://example.test:65536/");
    url("https://[::1/");
    url("https://user@example.test/");
    url("https://");
    url("ftp://x/");

    written("POST", "POST", "https://localhost:14000/order", "X-A: 1\r\n", "application/jose+json", "{}",
            "POST /order HTTP/1.1\r\nHost: localhost:14000\r\nUser-Agent: goose-http\r\nAccept: */*\r\nX-A: 1\r\nContent-Type: application/jose+json\r\nContent-Length: 2\r\n\r\n{}");
    written("POST, no body", "POST", "http://h/x?y", "", "", "",
            "POST /x?y HTTP/1.1\r\nHost: h\r\nUser-Agent: goose-http\r\nAccept: */*\r\nContent-Length: 0\r\n\r\n");
    written("HEAD", "HEAD", "https://localhost:14000/order", "", "", "",
            "HEAD /order HTTP/1.1\r\nHost: localhost:14000\r\nUser-Agent: goose-http\r\nAccept: */*\r\n\r\n");

    response("length", "HTTP/1.1 201 Created\r\nLocation: https://ca.test/acct/1\r\nreplay-NONCE:  abc \r\nContent-Length: 5\r\n\r\nhello", false);
    response("length, cut at the close", "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nhello", true);
    response("length, past the limit", "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", false, false, 4);
    response("chunked", "HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\n\r\n3;x=y\r\nhel\r\n2\r\nlo\r\n0\r\n\r\n", false);
    response("chunked, with a trailer", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nX-T: 1\r\n\r\n", false);
    response("chunked, cut at the close", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel", true);
    response("chunked, past the limit", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n", false, false, 4);
    response("chunked, a short chunk", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhello\r\n0\r\n\r\n", false);
    response("chunked, a signed size", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n+5\r\nhello\r\n0\r\n\r\n", false);
    response("to the close", "HTTP/1.1 200 OK\r\n\r\nuntil the end", true);
    response("a 100 first", "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok", false);
    response("a HEAD", "HTTP/1.1 200 OK\r\nReplay-Nonce: n1\r\nContent-Length: 99\r\n\r\n", false, true);
    response("204", "HTTP/1.0 204 No Content\r\nReplay-Nonce: n2\r\n\r\n", false);
    response("304", "HTTP/1.1 304 Not Modified\r\nContent-Length: 10\r\n\r\n", false);
    response("no reason", "HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n", false);
    response("the head, cut at the close", "HTTP/1.1 200 OK\r\nContent-Le", true);
    response("no status", "HTTP/1.1 OK\r\n\r\n", false);
    response("HTTP/2", "HTTP/2 200 OK\r\n\r\n", false);
    response("two lengths", "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab", false);
    response("a signed length", "HTTP/1.1 200 OK\r\nContent-Length: +2\r\n\r\nab", false);
    response("a negative length", "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n", false);
    response("another coding", "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n", false);
    response("a field without a colon", "HTTP/1.1 200 OK\r\nLocation\r\n\r\n", false);
    response("a space in a name", "HTTP/1.1 200 OK\r\nBad Name: x\r\n\r\n", false);
    response("a bare LF", "HTTP/1.1 200 OK\nContent-Length: 0\n\n", true);

    var r = http::ClientResponse { .. };
    http::read_response("HTTP/1.1 200 OK\r\nX-Id:  7 \r\nset-cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 0\r\n\r\n",
                        false, false, 1 << 20, r);
    let id, has_id = http::header(r, "x-id");
    let cookie, has_cookie = http::header(r, "SET-COOKIE");
    let missing, has_missing = http::header(r, "X-None");
    print("fields: [", id, "] [", cookie, "] ", has_missing);
}
