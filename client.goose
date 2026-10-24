// An HTTP/1.1 client for a thread that runs no loop, such as a lane's or a
// command-line program's: each call blocks until its response has come, over
// the blocking socket (socket.goose), and over goose-tls's client TLS for an
// https URL. Only a program that imports this module needs goose-tls, which
// its root file declares at the reference this file names:
//
//   import http from "github.com/kaitk/goose-http@<tag>";
//   import tls from "github.com/kaitk/goose-tls@v0.0.6";
//   import http.client;
//
//   var session = http::session();
//   let response, err = http::post(session, "https://api.example.com/v1/login") { req =>
//       http::bearer(req, api_key);
//       http::header(req, "X-Device-Id", device_id);
//       http::json(req, credentials);
//   };
//   http::free(session);
//
// The calls are compositions of parts a program can call on its own:
// parse_url, write_request, and read_response work on bytes, and exchange
// carries one request over a session's connection.
namespace http;

import std;
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import sys;
import message;
import socket;

// A client's settings and its open connection, which the next request to the
// same scheme, host, and port reuses.
struct Session {
    // The limit in milliseconds on each wait: the connect, a send, a read
    // (-1: none). A host name's lookup isn't bounded by it.
    ms: i64 = 30000,
    // The most body a response may have, in bytes as sent.
    max_body: i64 = 16 << 20,
    // An address to connect to in place of the URL's host and port, such as
    // "unix:/run/app.sock"; TLS still checks the URL's host.
    via: u8[..256],
    ctx: tls::Context,
    s: Socket = Socket { fd: -1 },
    c: tls::Conn,
    // The connection's scheme, host, and port, as https://host:port.
    peer: u8[..320],
}

// A session whose TLS trusts OpenSSL's store of certificate authorities. An
// https request fails with call "tls" when OpenSSL couldn't make its context.
fn session(ms: i64 = 30000) -> Session {
    let ctx, ok = tls::client(["http/1.1"]);
    return Session { ms: ms, ctx: if ok { ctx } else { tls::Context { .. } }, .. };
}

// A session whose TLS trusts only the certificates in ca, PEM text, and
// whether its context was made.
fn session_trusting(ca: const u8[:], ms: i64 = 30000) -> Session, bool {
    let ctx, ok = tls::client_trusting(ca, ["http/1.1"]);
    return Session { ms: ms, ctx: if ok { ctx } else { tls::Context { .. } }, .. }, ok;
}

// Closes the session's connection and frees its TLS context.
fn free(s: Session&) {
    hangup(s);
    if tls::ok(s.ctx) { tls::free(s.ctx); }
    s.ctx = tls::Context { .. };
}

// What a request's block adds to it: header field lines, and a body with its
// media type. lines and payload are the request call's own buffers.
struct ClientRequest {
    lines: u8[>..]&,
    payload: u8[>..]&,
    media: const u8[:] = "",
    // What the block did that fails the request: "header" for a field it
    // refused, "body" for a second body.
    refused: const u8[:] = "",
}

// The response: its status, its header field lines, each ending in CRLF,
// and its body. Status 0 for a request that failed.
struct ClientResponse {
    status: i64 = 0,
    fields: u8[..8192],
    body: u8[>..],
}

// The value of r's header field name, compared ignoring ASCII case, and
// whether r has it; the first, if it repeats.
fn header(r: const ClientResponse&, name: const u8[:]) -> const u8[:], bool {
    return field_in(r.fields, name);
}

// Adds the field name: value. A name that isn't a token, a value with a CR,
// an LF, or another control byte, and the fields the session writes itself
// fail the request with call "header".
fn header(req: ClientRequest&, name: const u8[:], value: const u8[:]) {
    let own = same_name(name, "Host") || same_name(name, "Content-Length")
        || same_name(name, "Transfer-Encoding") || same_name(name, "Connection");
    guard !own && is_field(name, trim_ows(value)) else {
        if req.refused.len == 0 { req.refused = "header"; }
        return;
    }
    format(req.lines, name, ": ", trim_ows(value), "\r\n");
}

// Adds Authorization: Bearer token.
fn bearer(req: ClientRequest&, token: const u8[:]) { header(req, "Authorization", str("Bearer ", token)); }

// Makes v the body as JSON, written by v's format overload, with
// Content-Type: application/json. A request has one body: a second fails it
// with call "body".
fn json(req: ClientRequest&, v) {
    guard first_body(req) else { return; }
    format(req.payload, v);
    req.media = "application/json";
}

// Makes bytes the body, with Content-Type: media.
fn body(req: ClientRequest&, media: const u8[:], bytes: const u8[:]) {
    guard first_body(req) else { return; }
    req.payload.append(bytes);
    req.media = media;
}

fn first_body(req: ClientRequest&) -> bool {
    guard req.media.len > 0 else { return true; }
    if req.refused.len == 0 { req.refused = "body"; }
    return false;
}

// The request method makes to url, which is http:// or https://, after F has
// added to it, and its response; an Error whose call says which step failed
// and whose code is the socket's, or EINVAL for a URL, a field, a body, TLS,
// or a response that couldn't be used, as call "url", "header", "body",
// "tls", and "response" say. After "tls", tls::error_text() says why.
fn request<F>(s: Session&, method: const u8[:], url: const u8[:]) -> ClientResponse, Error {
    var lines: u8[>..] = [];
    var payload: u8[>..] = [];
    var req = ClientRequest { lines: lines, payload: payload };
    F(&req);
    return exchange(s, method, url, req);
}

fn get<F>(s: Session&, url: const u8[:]) -> ClientResponse, Error { return request(s, "GET", url) { req => F(req); }; }
fn post<F>(s: Session&, url: const u8[:]) -> ClientResponse, Error { return request(s, "POST", url) { req => F(req); }; }
fn put<F>(s: Session&, url: const u8[:]) -> ClientResponse, Error { return request(s, "PUT", url) { req => F(req); }; }
fn patch<F>(s: Session&, url: const u8[:]) -> ClientResponse, Error { return request(s, "PATCH", url) { req => F(req); }; }
fn delete<F>(s: Session&, url: const u8[:]) -> ClientResponse, Error { return request(s, "DELETE", url) { req => F(req); }; }

fn get(s: Session&, url: const u8[:]) -> ClientResponse, Error { return request(s, "GET", url) { req => }; }
fn delete(s: Session&, url: const u8[:]) -> ClientResponse, Error { return request(s, "DELETE", url) { req => }; }

// A URL's parts, as slices of it. authority is host[:port], as the Host
// field takes it; host has no brackets around an IPv6 address; target is the
// path and query, "/" when the URL has neither.
struct Url { secure: bool = false, authority: const u8[:], host: const u8[:], port: i64 = 80, target: const u8[:] }

let AUTHORITY_END = byte_set("/?");
let NOT_IN_HOST = byte_set(" @\r\n\t");
let NOT_IN_TARGET = byte_set(" \r\n\t");

// The parts of url, http:// or https:// with a host, an optional port, and an
// optional path and query, without its fragment; false for anything else.
fn parse_url(url: const u8[:]) -> Url, bool {
    var u = Url { .. };
    var rest = url;
    if starts_with(url, "https://") {
        u.secure = true;
        u.port = 443;
        rest = url[8..];
    } else if starts_with(url, "http://") {
        rest = url[7..];
    } else {
        return u, false;
    }
    let hash = find(rest, "#");
    if hash >= 0 { rest = rest[..hash]; }
    var end = find_any(rest, AUTHORITY_END);
    if end < 0 { end = rest.len; }
    u.authority = rest[..end];
    u.host = u.authority;
    u.target = if end == rest.len { "/" } else { rest[end..] };
    var port_at = -1;
    if u.authority.len > 0 && u.authority[0] == '[' {
        let close = find(u.authority, "]");
        guard close > 1 else { return u, false; }
        u.host = u.authority[1..close];
        if close + 1 < u.authority.len {
            guard u.authority[close + 1] == ':' else { return u, false; }
            port_at = close + 2;
        }
    } else {
        let colon = find(u.authority, ":");
        if colon >= 0 {
            u.host = u.authority[..colon];
            port_at = colon + 1;
        }
    }
    if port_at >= 0 {
        let digits = u.authority[port_at..];
        let port, ok = parse_int(digits);
        guard ok && is_digit(digits[0]) && port > 0 && port < 65536 else { return u, false; }
        u.port = port;
    }
    guard u.host.len > 0 && find_any(u.host, NOT_IN_HOST) < 0 else { return u, false; }
    guard find_any(u.target, NOT_IN_TARGET) < 0 else { return u, false; }
    return u, true;
}

// Appends the request to out: its request line, Host, User-Agent, Accept,
// req's fields, its body's Content-Type and Content-Length, and the body. A
// POST, PUT, or PATCH says Content-Length: 0 for no body.
fn write_request(out: u8[>..]&, method: const u8[:], u: Url, req: const ClientRequest&) {
    format(out, method, " ", u.target, " HTTP/1.1\r\nHost: ", u.authority,
           "\r\nUser-Agent: goose-http\r\nAccept: */*\r\n", req.lines);
    if req.media.len > 0 { format(out, "Content-Type: ", req.media, "\r\n"); }
    if req.payload.len > 0 || method == "POST" || method == "PUT" || method == "PATCH" {
        format(out, "Content-Length: ", req.payload.len, "\r\n");
    }
    out.append("\r\n");
    out.append(req.payload);
}

fn client_error(call: const u8[:]) -> Error { Error { call: call, code: EINVAL } }

// Sends the request, and reads its response, on the session's connection to
// url's peer: the open one, or a new one.
fn exchange(s: Session&, method: const u8[:], url: const u8[:], req: const ClientRequest&) -> ClientResponse, Error {
    var r = ClientResponse { .. };
    let u, ok = parse_url(url);
    guard ok else { return r, client_error("url"); }
    guard req.refused.len == 0 else { return r, client_error(if req.refused == "body" { "body" } else { "header" }); }
    var wire: u8[>..] = [];
    write_request(wire, method, u, req);

    var e = open(s, u);
    guard e.code == 0 else { return r, e; }
    e = put(s, wire);
    guard e.code == 0 else {
        hangup(s);
        return r, e;
    }
    let head = method == "HEAD";
    var raw: u8[>..] = [];
    var buf: u8[16384] = [0; 16384];
    loop {
        let n, got = take(s, buf);
        guard got.code == 0 else {
            hangup(s);
            r.status = 0;
            return r, got;
        }
        if n > 0 { raw.append(buf[..n]); }
        let read = read_response(raw, n == 0, head, s.max_body, r);
        if read == READ_COMPLETE || read == READ_AT_CLOSE {
            let connection, has = header(r, "Connection");
            if read == READ_AT_CLOSE || (has && same_name(connection, "close")) { hangup(s); }
            return r, no_error();
        }
        guard read == INCOMPLETE && n > 0 else {
            hangup(s);
            r.status = 0;
            return r, client_error("response");
        }
    }
}

// Makes the session's connection one to u's peer: the open one, while the
// server hasn't closed it, or a new one, with its TLS handshake done.
fn open(s: Session&, u: Url) -> Error {
    var peer: u8[..320] = [];
    guard u.authority.len < 300 else { return client_error("url"); }
    format(peer, if u.secure { "https://" } else { "http://" }, u.host, ":", u.port);
    if s.s.fd >= 0 && s.peer == peer {
        // A connection the server has closed, or that holds bytes nothing
        // asked for, such as TLS's close_notify, isn't reused.
        var probe: u8[1] = [0];
        if recv(s.s, probe, 0) == -ETIMEDOUT { return no_error(); }
    }
    hangup(s);
    let to = if s.via.len > 0 { s.via[..] } else { u.host };
    let sock, e = connect(to, u.port, s.ms);
    guard e.code == 0 else { return e; }
    s.s = sock;
    if u.secure {
        guard tls::ok(s.ctx) else {
            hangup(s);
            return client_error("tls");
        }
        s.c = tls::connect(s.ctx, u.host);
        let h = handshake(s);
        guard h.code == 0 else {
            hangup(s);
            return h;
        }
    }
    s.peer = peer;
    return no_error();
}

fn handshake(s: Session&) -> Error {
    guard tls::ok(s.c) else { return client_error("tls"); }
    var wire: u8[16384] = [0; 16384];
    loop {
        let r = tls::handshake(s.c);
        let e = flush(s);
        guard e.code == 0 else { return e; }
        if r == 0 { return no_error(); }
        guard r == tls::WANT_INPUT else { return client_error("tls"); }
        let n = recv(s.s, wire, s.ms);
        guard n > 0 else { return Error { call: "recv", code: if n == 0 { ECONNRESET } else { -n } }; }
        guard tls::feed(s.c, wire[..n]) == n else { return client_error("tls"); }
    }
}

// Sends what TLS has to send.
fn flush(s: Session&) -> Error {
    var buf: u8[16384] = [0; 16384];
    loop {
        let n = tls::drain(s.c, buf);
        guard n > 0 else { return no_error(); }
        let e = send_all(s.s, buf[..n], s.ms);
        guard e.code == 0 else { return e; }
    }
}

// Sends bytes on the session's connection.
fn put(s: Session&, bytes: const u8[:]) -> Error {
    guard tls::ok(s.c) else { return send_all(s.s, bytes, s.ms); }
    guard tls::write(s.c, bytes) == bytes.len else { return client_error("tls"); }
    return flush(s);
}

// Bytes from the session's connection into buf: how many, or 0 once the
// server has closed it. Under TLS, only close_notify is a close: a socket
// that ends without it could cut a body that ends with the connection.
fn take(s: Session&, buf: u8[:]) -> i64, Error {
    guard tls::ok(s.c) else {
        let n = recv(s.s, buf, s.ms);
        return if n >= 0 { n } else { 0 }, if n >= 0 { no_error() } else { Error { call: "recv", code: -n } };
    }
    var wire: u8[16384] = [0; 16384];
    loop {
        let n = tls::read(s.c, buf);
        if n > 0 { return n, no_error(); }
        if n == tls::CLOSED { return 0, no_error(); }
        guard n == tls::WANT_INPUT else { return 0, client_error("tls"); }
        let m = recv(s.s, wire, s.ms);
        guard m > 0 else { return 0, Error { call: "recv", code: if m == 0 { ECONNRESET } else { -m } }; }
        guard tls::feed(s.c, wire[..m]) == m else { return 0, client_error("tls"); }
    }
}

// Closes the session's connection, if one is open.
fn hangup(s: Session&) {
    if tls::ok(s.c) {
        tls::free(s.c);
        s.c = tls::Conn { .. };
    }
    hangup(s.s);
    s.peer.clear();
}

// What read_response finds in the bytes so far, beside INCOMPLETE.
let READ_COMPLETE = 1;
let READ_AT_CLOSE = 2;
let READ_MALFORMED = -1;

// The most a response's status line and fields may take.
let MAX_RESPONSE_HEAD = 8192;

// Reads an HTTP/1.1 response from raw into r: READ_COMPLETE, INCOMPLETE when
// more bytes are needed, or READ_MALFORMED, also for a body past max_body as
// sent. closed says the connection has ended, so a body with neither a
// length nor chunks ends with raw: READ_AT_CLOSE. The body is copied into r
// once it has all come. A response to a HEAD, a 204, and a 304 have no body,
// whatever their fields say, and a 1xx before the final response is skipped.
fn read_response(raw: const u8[:], closed: bool, head: bool, max_body: i64, r: ClientResponse&) -> i64 {
    var at = 0;
    loop {
        r.status = 0;
        r.fields.clear();
        let rest = raw[at..];
        let short = if closed || rest.len > MAX_RESPONSE_HEAD { READ_MALFORMED } else { INCOMPLETE };
        let eol = line_end(rest, 0);
        guard eol != 0 else { return short; }
        guard eol > 0 else { return READ_MALFORMED; }
        let status = rest[..eol - 2];
        guard starts_with(status, "HTTP/1.") && status.len >= 12 && is_digit(status[7]) && status[8] == ' '
        else { return READ_MALFORMED; }
        let code, ok = parse_int(status[9..12]);
        guard ok && is_digit(status[9]) && code >= 100 && code < 600 && (status.len == 12 || status[12] == ' ')
        else { return READ_MALFORMED; }
        let end = trailer_end(rest, eol);
        guard end != 0 else { return short; }
        guard end > 0 && end <= MAX_RESPONSE_HEAD else { return READ_MALFORMED; }
        let fields = rest[eol..end - 2];

        var length = -1;
        var chunked = false;
        var pos = 0;
        while pos < fields.len {
            let name, value, next = field_at(fields, pos);
            pos = next;
            if same_name(name, "Content-Length") {
                let n, valid = parse_int(value);
                guard valid && value.len > 0 && is_digit(value[0]) && (length < 0 || length == n) else { return READ_MALFORMED; }
                length = n;
            } else if same_name(name, "Transfer-Encoding") {
                guard same_name(value, "chunked") else { return READ_MALFORMED; }
                chunked = true;
            }
        }
        r.status = code;
        r.fields.append(fields);

        let body = rest[end..];
        if code < 200 {
            at += end;
            continue;
        }
        if head || code == 204 || code == 304 { return READ_COMPLETE; }
        if chunked {
            let n, verdict = chunked_len(body, max_body);
            if verdict == INCOMPLETE { return if closed { READ_MALFORMED } else { INCOMPLETE }; }
            guard verdict == 200 else { return READ_MALFORMED; }
            r.body.append(body[..n]);
            let len, trailers = dechunk(r.body);
            r.body.resize(len);
            return READ_COMPLETE;
        }
        if length >= 0 {
            guard length <= max_body else { return READ_MALFORMED; }
            guard body.len >= length else { return if closed { READ_MALFORMED } else { INCOMPLETE }; }
            r.body.append(body[..length]);
            return READ_COMPLETE;
        }
        guard body.len <= max_body else { return READ_MALFORMED; }
        guard closed else { return INCOMPLETE; }
        r.body.append(body);
        return READ_AT_CLOSE;
    }
}
