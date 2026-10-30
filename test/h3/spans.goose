// The byte ranges a stream keeps, H3Spans, hold at most H3_SPANS each, and
// never record bytes that didn't arrive or weren't acknowledged. A stream
// that receives a range apart from 8 others past a gap closes the
// connection, where merging two would hand the gap's zeros to the request.
// A sent range acknowledged apart from 8 others is sent again, where merging
// would mark unacknowledged bytes acknowledged; and what's lost never stays
// below the bytes the stream holds, which a resend would read past.
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;
import http.h3;

fn spans(label: const u8[:], sp: const http::H3Spans&) -> u8[>..] {
    var out: u8[>..] = [];
    format(out, label);
    for g in sp.s { format(out, " [", g.lo, ",", g.hi, ")"); }
    return out;
}

// Request stream 0 of chunks of 1000 bytes, each its number's letter: the
// odd chunks below last arrive, then the even ones. The bytes delivered, or
// the first error.
fn receive(last: i64) {
    let ci = http::h3conns.alloc_index(http::H3Conn { live: true, .. });
    var sent: u8[>..] = [];
    for c in last + 1 { push_n(sent, ('A' + c) as u8, 1000); }
    var got: u8[>..] = [];
    for c in [1, 3, 5, 7, 9, 11, 13, 15, 17, 0, 2, 4, 6, 8, 10, 12, 14, 16] {
        guard c <= last else { continue; }
        let e = http::h3_stream_in(ci, 0, c * 1000, sent[c * 1000..(c + 1) * 1000], c == last);
        if e != 0 {
            print("chunks to ", last, ": chunk ", c, " refused, error ", e, ", ", got.len, " bytes delivered");
            return;
        }
        let k = http::strm_find(http::h3conns[ci], 0);
        let b = http::rx_ready(http::h3strms[k].rx);
        got.append(b);
        http::rx_take(http::h3strms[k].rx, b.len);
    }
    print("chunks to ", last, ": delivered as sent ", got == sent);
}

fn main() {
    // 8 gaps, then 9.
    receive(16);
    receive(17);
    // Another run, before the stream's in the pool, which a read before the
    // stream's would find.
    var other = http::H3Run { .. };
    http::run_grow(other, 1024);
    for i in other.cap { http::h3bytes[other.at + i] = '#'; }
    var t = http::H3Tx { max: 1 << 40, .. };
    var bytes: u8[>..] = [];
    push_n(bytes, 's', 4000);
    http::tx_put(t, bytes);
    t.next = t.end;
    http::tx_lost(t, 100, 200);
    for r in [[50, 100], [200, 250], [1000, 1010], [1500, 1510], [2000, 2010], [2500, 2510], [3000, 3010],
              [3500, 3510]] {
        assert(http::tx_ack(t, r[0], r[1]));
    }
    print("8 acknowledged: ", spans("acked", t.acked));
    print("a 9th, sent again: ", !http::tx_ack(t, 3800, 3810), ", ", spans("lost", t.lost));
    http::tx_ack(t, 0, 50);
    print("[0,50) acknowledged: base ", t.base, ", ", spans("lost", t.lost));
    // MORE's bytes move what's held to the front of the run.
    push_n(bytes, 'm', 100);
    http::tx_put(t, bytes[..100]);
    var out: u8[>..] = [];
    var refs: http::H3Ref[>..] = [];
    http::h3_data_frames(out, refs, t, 0, 0, 0, 1200, 1 << 30);
    print("the lost bytes sent: ", count(out, 's'), " of the stream's, ", count(out, '#'), " of another run's");
}

fn count(b: const u8[:], x: u8) -> i64 {
    var n = 0;
    for c in b { if c == x { n++; } }
    return n;
}
