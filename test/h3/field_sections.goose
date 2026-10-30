// A request's field sections on HTTP/3: trailers are bound by max_head as
// the head is, which gets 431 past it, and its :method and :path follow
// HTTP/1.1's request line, a token and visible ASCII from '/'. A malformed
// request's stream is reset with H3_MESSAGE_ERROR (0x10e).
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.qpack;
import http.tls;
import http.h3;

// A HEADERS frame of the fields, names and values in turn.
fn headers(out: u8[>..]&, fields: const u8[:][:]) {
    var fb: u8[>..] = [];
    http::qpack_begin(fb);
    for i in fields.len / 2 { http::qpack_encode(fb, fields[2 * i], fields[2 * i + 1]); }
    http::qv_put(out, 0x01);
    http::qv_put(out, fb.len);
    out.append(fb);
}

var next_id: i64 = 0;

// A request of the frames, with FIN, on the next stream: what the handler
// got, and how the stream was answered.
fn request(label: const u8[:], frames: const u8[:]) {
    let ci = http::h3conns.alloc_index(http::H3Conn { live: true, .. });
    var q = http::H3ServerOf<bool> { ctx: tls::Context { .. }, .. };
    let cfg = http::Config { .. };
    let fresh = false;
    var b: u8[>..] = [];
    http::qv_put(b, 0x0b);
    http::qv_put(b, 0);
    http::qv_put(b, frames.len);
    b.append(frames);
    http::h3_frames(ci, 2, b, 0);
    var got: u8[>..] = [];
    http::h3_serve_conn(q, ci, cfg, fresh, "", 0) { ev, st, out =>
        if ev.kind == http::REQUEST {
            format(got, "REQUEST ", ev.req.method, " ", ev.req.target, ", trailers ", ev.trailers.len, " bytes");
            http::respond(out, 204, "text/plain", "");
        }
    };
    let st .= http::h3strms[http::strm_find(http::h3conns[ci], 0)];
    if st.owe_reset {
        print(label, ": reset 0x", hex(st.reset_code));
        return;
    }
    // The response's HEADERS: a type, a length, and the field section.
    let sent = http::tx_bytes(st.tx, 0, st.tx.end);
    var r = http::QRd { at: 0, bad: false };
    http::qv(sent, r);
    let n = http::qv(sent, r);
    var huff: u8[>..] = [];
    http::qpack_decode(sent[r.at..r.at + n], huff) { name, value =>
        if name == ":status" { format(got, if got.len > 0 { ", " } else { "" }, "status ", value); }
    };
    print(label, ": ", got);
}

fn hex(v: i64) -> u8[>..] {
    var out: u8[>..] = [];
    format_int(out, v, 16, 0, '0');
    return out;
}

fn main() {
    var big: u8[>..] = [];
    push_n(big, 'v', 9000);
    var f: u8[>..] = [];
    let get = [":method", "GET", ":scheme", "https", ":path", "/a", ":authority", "x"];
    headers(f, get);
    headers(f, ["x-t", "small"]);
    request("small trailers", f);
    f.clear();
    headers(f, get);
    headers(f, ["x-t", big]);
    request("trailers past max_head", f);
    f.clear();
    headers(f, [":method", "GET", ":scheme", "https", ":path", "/a", ":authority", "x", "x-h", big]);
    request("a head past max_head", f);
    let paths = ["/a\x1b[31mb", "an escape character", "/a b", "a space", "/a\xffb", "a byte past ASCII", "a",
                 "no '/' first", "/a%zz", "a broken escape", "*", "* for GET"];
    for i in paths.len / 2 {
        var g: u8[>..] = [];
        headers(g, [":method", "GET", ":scheme", "https", ":path", paths[2 * i], ":authority", "x"]);
        request(str(":path with ", paths[2 * i + 1]), g);
    }
    let methods = ["G\x1b[2JET", "an escape character", "GE T", "a space", "", "nothing"];
    for i in methods.len / 2 {
        var g: u8[>..] = [];
        headers(g, [":method", methods[2 * i], ":scheme", "https", ":path", "/a", ":authority", "x"]);
        request(str(":method with ", methods[2 * i + 1]), g);
    }
    f.clear();
    headers(f, [":method", "OPTIONS", ":scheme", "https", ":path", "*", ":authority", "x"]);
    request("OPTIONS *", f);
}
