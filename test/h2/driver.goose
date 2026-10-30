// The h2c driver, h2_answer, fed a client's bytes without a socket: the
// preface and settings, requests whole and with bodies, a response sent in
// pieces, a response's fields translated, flow control at a small window, a stream that waits while another
// is answered, streams that wait at once, upgrade answering 501, malformed requests, Expect, a handler
// that ends keep-alive, and the flood guards. Each frame the server writes is printed, its Date left out.
import std;
import http from "../../";
import http.hpack;
import http.h2frame;
import check from "../";

struct St { n: i64 = 0 }
struct Conn { fd: i32 = -1, state: u8 = 0, x: http::Exchange<St> }

reusable[] var spill: u8[>..] = [];
reusable var conns: http::H2Conn[>..] = [];
reusable var streams: http::H2Stream<St>[>..] = [];
var conn = Conn { x: http::Exchange<St> { state: St { .. }, .. }, .. };
var h = 0;
var rbuf: u8[>..] = [];
var rlen = 0;
var timers = http::timer_table(0);
var overdue: u64[>..] = [];
var cenc = http::hpack_table();
var cdec = http::hpack_table();
var cfg = http::Config { .. };
// What the client hasn't parsed yet of the server's output, and PINGs it
// hasn't printed yet, which come in runs.
var pending: u8[>..] = [];
var pings = 0;

fn handle(ev: http::Event, st: St&, out: http::Reply) {
    if ev.kind == http::CLOSED {
        print("  (handler: CLOSED)");
        return;
    }
    if ev.kind == http::WAKE || ev.kind == http::TIMEOUT {
        print("  (handler: ", if ev.kind == http::WAKE { "WAKE" } else { "TIMEOUT" }, ")");
        http::respond(out, 200, "text/plain", "waited");
        return;
    }
    if ev.kind == http::BODY {
        st.n += ev.data.len;
        return;
    }
    if ev.kind == http::END {
        http::respond(out, 200, "text/plain", str("pieces ", st.n));
        return;
    }
    if ev.kind == http::MORE {
        st.n++;
        if st.n < 3 { http::send(out, "more ") } else { http::end(out); }
        return;
    }
    guard ev.kind == http::REQUEST else { return; }
    let path = ev.req.target;
    let host, has = http::field_of(ev.req, "host");
    if path == "/" {
        http::respond(out, 200, "text/plain", str("hello ", host));
    } else if path == "/big" {
        var body: u8[>..] = [];
        for i in 100 { body.push(('a' + i % 26) as u8); }
        http::respond(out, 200, "text/plain", body);
    } else if path == "/echo" {
        if ev.whole { http::respond(out, 200, "text/plain", str("whole ", ev.data.len)); }
    } else if path == "/stream" {
        http::begin(out, 200, -1);
        http::send(out, "first ");
    } else if path == "/wait" {
        http::later(out, 1000);
    } else if path == "/close" {
        out.keep_alive = false;
        http::respond(out, 200, "text/plain", "bye");
    } else if path == "/upgrade" {
        http::upgrade(out, "websocket");
    } else if path == "/cookie" {
        let c, ok = http::field_of(ev.req, "cookie");
        http::respond(out, 200, "text/plain", c);
    } else if path == "/fields" {
        http::start(out, 200);
        http::field(out, "X-Mixed-Case", "1");
        http::field(out, "Connection", "close");
        http::field(out, "Keep-Alive", "timeout=5");
        http::field(out, "Proxy-Connection", "close");
        http::field(out, "Transfer-Encoding", "chunked");
        http::field(out, "Upgrade", "h2c");
        http::field(out, "Upgrades", "kept");
        http::field(out, "Content-Location", "/kept");
        http::finish(out, http::NO_TYPE, "ok");
    } else if path == "/long" {
        // More lines than h2_head_block keeps the ends of.
        http::start(out, 200);
        for i in 34 { http::field(out, str("X-F", i), "v"); }
        http::field(out, "Connection", "close");
        http::finish(out, http::NO_TYPE, "long");
    } else if path == "/held" {
        // The head stays open until MORE's first send.
        http::begin(out, 200, -1);
        http::field(out, "X-Held", "yes");
    } else {
        http::respond(out, 404, "text/plain", "");
    }
}

fn session(c: http::Config) {
    cfg = c;
    if conns.len > 0 { http::h2_release(conns[h], streams, spill, timers, -1, handle); }
    h = conns.alloc_index(http::h2_conn(cfg, 0));
    conn = Conn { fd: 5, state: http::OPEN, x: http::Exchange<St> { state: St { .. }, .. } };
    rbuf.clear();
    rbuf.resize(cfg.max_head, 0);
    rlen = 0;
    cenc = http::hpack_table();
    cdec = http::hpack_table();
    pending.clear();
}

// Feeds bytes to the driver, a read's worth at a time, and prints what it
// writes. ev, unless NO_EVENT, is a WAKE or TIMEOUT for stream pool index at.
fn feed(bytes: const u8[:], ev_kind: u8 = http::NO_EVENT, at: i64 = -1) {
    var wbuf: u8[>..] = [];
    var o: u8[>..] = [];
    var f: u8[>..] = [];
    var p: u8[>..] = [];
    var ck: u8[>..] = [];
    var hf: u8[>..] = [];
    var fbuf: u8[>..] = [];
    let nothing = http::Request { .. };
    var ev = http::Event { kind: ev_kind, req: nothing, data: "", whole: false, trailers: "" };
    let fresh = St { .. };
    var pos = 0;
    loop {
        let n = min(bytes.len - pos, rbuf.len - rlen);
        copy_into(rbuf[rlen..rlen + n], bytes[pos..pos + n]);
        rlen += n;
        pos += n;
        guard conn.state == http::OPEN else { break; }
        let rest, full = http::h2_answer(conn, 0, conns[h], streams, spill, rbuf, rlen, wbuf, cfg.write_buffer, o, f, p, ck, hf, fbuf,
                                         check::COMMON, cfg, fresh, false, 0, ev, at, timers, overdue, handle);
        ev.kind = http::NO_EVENT;
        rlen = rest;
        show(wbuf);
        wbuf.clear();
        if !full && pos == bytes.len { break; }
    }
}

fn show(out: const u8[:]) {
    pending.append(out);
    var used = 0;
    loop {
        let fr, size, err = http::h2_parse(pending[used..], http::H2_MAX_FRAME_SIZE);
        guard size > 0 else { break; }
        used += size;
        if fr.kind == http::H2_PING {
            pings++;
            continue;
        }
        if pings > 0 {
            print("  PING acknowledgments: ", pings);
            pings = 0;
        }
        var line: u8[>..] = [];
        format(line, "  ", kind_name(fr.kind), " ", fr.stream);
        if fr.kind == http::H2_HEADERS {
            var scratch: u8[>..] = [];
            assert(http::hpack_decode(cdec, fr.data, scratch) { n, v =>
                if n != "date" { format(line, " ", n, "=", v); }
            });
        } else if fr.kind == http::H2_DATA {
            format(line, " ", fr.data.len, " '", fr.data[..min(fr.data.len, 24)], "'");
        } else if fr.kind == http::H2_RST_STREAM || fr.kind == http::H2_GOAWAY {
            format(line, " ", code_name(fr.error));
            if fr.kind == http::H2_GOAWAY { format(line, " last ", fr.last_stream); }
        } else if fr.kind == http::H2_WINDOW_UPDATE {
            format(line, " +", fr.increment);
        } else if fr.kind == http::H2_SETTINGS {
            format(line, if fr.flags & http::H2_ACK != 0 { " ACK" } else { "" }, " ", fr.len / 6, " values");
        }
        if fr.flags & http::H2_END_STREAM != 0 && (fr.kind == http::H2_DATA || fr.kind == http::H2_HEADERS) {
            line.append(" END_STREAM");
        }
        print(line);
    }
    let rest = pending.len - used;
    for i in rest { pending[i] = pending[used + i]; }
    pending.resize(rest, 0);
}

fn kind_name(k: u8) -> const u8[:] {
    match k {
        0 => "DATA", 1 => "HEADERS", 3 => "RST_STREAM", 4 => "SETTINGS", 6 => "PING",
        7 => "GOAWAY", 8 => "WINDOW_UPDATE", _ => "other",
    }
}

fn code_name(c: u32) -> const u8[:] {
    match c {
        0 => "NO_ERROR", 1 => "PROTOCOL_ERROR", 3 => "FLOW_CONTROL_ERROR", 5 => "STREAM_CLOSED",
        6 => "FRAME_SIZE_ERROR", 7 => "REFUSED_STREAM", 9 => "COMPRESSION_ERROR",
        11 => "ENHANCE_YOUR_CALM", _ => "other",
    }
}

// A client's HEADERS for path, with fields given as "name: value" lines.
fn request(out: u8[>..]&, id: i64, method: const u8[:], path: const u8[:], extra: const u8[:], end: bool) {
    var fb: u8[>..] = [];
    http::hpack_encode(cenc, fb, ":method", method);
    http::hpack_encode(cenc, fb, ":scheme", "http");
    http::hpack_encode(cenc, fb, ":path", path);
    http::hpack_encode(cenc, fb, ":authority", "example.test");
    each_split(extra, '\n') {
        let colon = find(it, ": ");
        if colon > 0 { http::hpack_encode(cenc, fb, it[..colon], it[colon + 2..]); }
    };
    http::h2_write_headers(out, id, fb, end);
}

fn opening(out: u8[>..]&, s: http::H2Settings) {
    out.append(http::H2_PREFACE);
    http::h2_write_settings(out, s);
}

fn basics() {
    print("a GET, a HEAD, a POST gathered whole, a POST in pieces, a 404:");
    session(http::Config { .. });
    var input: u8[>..] = [];
    opening(input, http::H2Settings { .. });
    request(input, 1, "GET", "/", "", true);
    request(input, 3, "HEAD", "/", "", true);
    request(input, 5, "POST", "/echo", "content-length: 11", false);
    http::h2_write_data(input, 5, "hello", false);
    http::h2_write_data(input, 5, " world", true);
    feed(input);
    input.clear();
    request(input, 7, "POST", "/echo", "", false);
    var big: u8[>..] = [];
    for i in 9000 { big.push('x'); }
    http::h2_write_data(input, 7, big[..4500], false);
    http::h2_write_data(input, 7, big[4500..], true);
    request(input, 9, "GET", "/nothing", "cookie: a=1\ncookie: b=2", true);
    request(input, 11, "GET", "/cookie", "cookie: a=1\ncookie: b=2", true);
    feed(input);
}

fn streamed() {
    print("a response in pieces, through MORE:");
    session(http::Config { .. });
    var input: u8[>..] = [];
    opening(input, http::H2Settings { .. });
    request(input, 1, "GET", "/stream", "", true);
    feed(input);
}

fn translation() {
    print("a response's fields lowercased, HTTP/1.1's connection fields dropped, and a head held open:");
    session(http::Config { .. });
    var input: u8[>..] = [];
    opening(input, http::H2Settings { .. });
    request(input, 1, "GET", "/fields", "", true);
    request(input, 3, "GET", "/held", "", true);
    request(input, 5, "GET", "/long", "", true);
    feed(input);
}

fn flow_control() {
    print("a stream window of 10, then WINDOW_UPDATEs:");
    session(http::Config { .. });
    var input: u8[>..] = [];
    opening(input, http::H2Settings { initial_window_size: 10, .. });
    request(input, 1, "GET", "/big", "", true);
    feed(input);
    input.clear();
    http::h2_write_window_update(input, 1, 30);
    feed(input);
    input.clear();
    // The window grows by the difference when the setting changes.
    http::h2_write_settings(input, http::H2Settings { initial_window_size: 50, .. });
    feed(input);
    input.clear();
    http::h2_write_window_update(input, 1, 100);
    feed(input);
    print("padded bodies at a server stream window of 100:");
    session(http::Config { h2_stream_window: 100, .. });
    input.clear();
    opening(input, http::H2Settings { .. });
    // 30 bytes fit in half the window and are gathered. 60 don't, so they
    // come in pieces, and with the pad length and the padding the stream's
    // WINDOW_UPDATE gives back all 80 bytes of the frame.
    request(input, 1, "POST", "/echo", "", false);
    padded(input, 1, 30);
    request(input, 3, "POST", "/echo", "", false);
    padded(input, 3, 60);
    feed(input);
    input.clear();
    http::h2_write_data(input, 1, "", true);
    http::h2_write_data(input, 3, "", true);
    feed(input);
}

// A DATA frame for stream id of n bytes and 19 of padding.
fn padded(out: u8[>..]&, id: i64, n: i64) {
    http::h2_head(out, n + 20, http::H2_DATA, http::H2_PADDED, id);
    out.push(19);
    for i in n { out.push('x'); }
    for i in 19 { out.push(0); }
}

fn waiting() {
    print("a stream that waits holds back no other:");
    session(http::Config { .. });
    var input: u8[>..] = [];
    opening(input, http::H2Settings { .. });
    request(input, 1, "GET", "/wait", "", true);
    request(input, 3, "GET", "/", "", true);
    feed(input);
    // No box, so later's exchange is owed TIMEOUT at once (overdue).
    assert(overdue.len == 1);
    let key = overdue[0];
    overdue.clear();
    let at = http::h2_key_index(cfg.max_conns, key);
    assert(streams[at].id == 1 && !streams[at].x.stream.waiting);
    feed("", http::TIMEOUT, at);
}

fn sent(r: i32) -> const u8[:] { if r == http::SENT { "SENT" } else if r == http::STALE { "STALE" } else { "other" } }

// Streams of one connection that wait at once, with a box: each one's key is
// live until it ends, whichever waited last, and STALE after.
fn waiting_streams() {
    print("streams that wait at once, each live until it ends:");
    session(http::Config { h2c: true, max_conns: 4, mail_slots: 8, max_waiting: 8, .. });
    let box, err = http::open_waiting(cfg, 0);
    assert(err.code == 0);
    conn.x.stream.later = http::MailAddress { box: box.handle, key: http::later_base(0) | http::later_draw() };
    timers = http::timer_table(cfg.max_waiting);
    var input: u8[>..] = [];
    opening(input, http::H2Settings { .. });
    request(input, 1, "GET", "/wait", "", true);
    request(input, 3, "GET", "/wait", "", true);
    feed(input);
    let first = conns[h].streams[0] as i64;
    let second = conns[h].streams[1] as i64;
    let a = streams[first].x.stream.later;
    let b = streams[second].x.stream.later;
    print("  live: ", http::mail_live(a), " and ", http::mail_live(b));
    // As the loop's delivered does.
    for k in [first, second] {
        http::cancel(timers, streams[k].x.timer);
        streams[k].x.stream.waiting = false;
        feed("", http::WAKE, k);
        print("  then sends to streams 1 and 3: ", sent(http::mail_send(a, 0, "")), ", ", sent(http::mail_send(b, 0, "")));
    }
    http::mail_close(box);
    timers = http::timer_table(0);
}

fn refusals() {
    print("upgrade, malformed requests, and too many streams:");
    session(http::Config { h2_max_streams: 2, .. });
    var input: u8[>..] = [];
    opening(input, http::H2Settings { .. });
    request(input, 1, "GET", "/upgrade", "", true);
    request(input, 3, "GET", "/", "connection: keep-alive", true);
    request(input, 5, "GET", "/", "te: gzip", true);
    request(input, 7, "GET", "/", "Upper: case", true);
    request(input, 9, "GET", "/echo", "content-length: 3", false);
    http::h2_write_data(input, 9, "four", true);
    feed(input);
    input.clear();
    request(input, 11, "POST", "/echo", "", false);
    request(input, 13, "POST", "/echo", "", false);
    request(input, 15, "POST", "/echo", "", false);
    feed(input);
    input.clear();
    // DATA on a stream this side reset is ignored; on one never opened, it
    // ends the connection.
    http::h2_write_data(input, 15, "late", true);
    http::h2_write_data(input, 99, "never", true);
    feed(input);
}

fn field_limits() {
    print("trailers past max_head, and a :path and a :method HTTP/1.1 refuses:");
    session(http::Config { .. });
    var input: u8[>..] = [];
    opening(input, http::H2Settings { .. });
    request(input, 1, "POST", "/echo", "", false);
    var big: u8[>..] = [];
    push_n(big, 'v', 9000);
    var fb: u8[>..] = [];
    http::hpack_encode(cenc, fb, "x-t", big);
    http::h2_write_headers(input, 1, fb, true);
    request(input, 3, "GET", "/a\x1b[31mb", "", true);
    request(input, 5, "GET", "a", "", true);
    request(input, 7, "G\x1b[2JET", "/", "", true);
    request(input, 9, "OPTIONS", "*", "", true);
    feed(input);
}

fn expectations() {
    print("100-continue, another expectation, and a handler that ends keep-alive:");
    session(http::Config { .. });
    var input: u8[>..] = [];
    opening(input, http::H2Settings { .. });
    request(input, 1, "POST", "/echo", "expect: 100-continue", false);
    request(input, 3, "POST", "/echo", "expect: something", false);
    feed(input);
    input.clear();
    http::h2_write_data(input, 1, "body", true);
    request(input, 5, "GET", "/close", "", true);
    feed(input);
    // After the GOAWAY, a new stream is ignored.
    input.clear();
    request(input, 7, "GET", "/", "", true);
    feed(input);
}

fn floods() {
    print("1001 PINGs:");
    session(http::Config { .. });
    var input: u8[>..] = [];
    opening(input, http::H2Settings { .. });
    for i in 1001 { http::h2_write_ping(input, "12345678", false); }
    feed(input);

    print("600 streams opened and reset before an answer:");
    session(http::Config { .. });
    input.clear();
    opening(input, http::H2Settings { .. });
    for i in 600 {
        request(input, 1 + 2 * i, "POST", "/echo", "", false);
        http::h2_write_rst_stream(input, 1 + 2 * i, http::H2_CANCEL);
    }
    feed(input);

    print("a field block grown past its limit through CONTINUATIONs:");
    session(http::Config { .. });
    input.clear();
    opening(input, http::H2Settings { .. });
    http::h2_head(input, 1, http::H2_HEADERS, 0, 1);
    input.push(0x82);
    var junk: u8[>..] = [];
    for i in 16384 { junk.push(0x82); }
    for i in 3 {
        http::h2_head(input, junk.len, http::H2_CONTINUATION, 0, 1);
        input.append(junk);
    }
    feed(input);

    print("empty CONTINUATIONs:");
    session(http::Config { .. });
    input.clear();
    opening(input, http::H2Settings { .. });
    http::h2_head(input, 1, http::H2_HEADERS, 0, 1);
    input.push(0x82);
    for i in 1001 { http::h2_head(input, 0, http::H2_CONTINUATION, 0, 1); }
    feed(input);
}

fn main() {
    basics();
    streamed();
    translation();
    flow_control();
    waiting();
    waiting_streams();
    refusals();
    field_limits();
    expectations();
    floods();
}
