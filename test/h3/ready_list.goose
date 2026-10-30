// A connection's list of readable streams holds each open stream once. A
// client whose response fills the connection's queue (it gives no stream
// credit) opens request streams and resets and stops each in the same packet:
// each waits in the list while the queue is full, and closes there. Its
// slot's next stream must not be listed beside it, or the list's 512 entries
// overflow and the process aborts.
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;
import http.h3;

// What h3_packet_out does with the frames owed once it sends them.
fn sent_owed(ci: i64) {
    let c .= http::h3conns[ci];
    if c.owe_max_streams {
        c.bidi_max = c.bidi_closed + http::H3_STREAMS;
        c.owe_max_streams = false;
    }
    for k in c.streams { http::h3strms[k].owe_reset = false; }
}

fn main() {
    let ci = http::h3conns.alloc_index(http::H3Conn { live: true, .. });
    var q = http::H3ServerOf<bool> { ctx: tls::Context { .. }, .. };
    let cfg = http::Config { .. };
    let fresh = false;
    var big: u8[>..] = [];
    push_n(big, 'x', 100000);
    // GET / on stream 0: HEADERS of :method GET, :scheme https, :path /,
    // and :authority a, with FIN.
    let section: u8[8] = [0x00, 0x00, 0xd1, 0xd7, 0xc1, 0x50, 0x01, 'a'];
    var b: u8[>..] = [];
    http::qv_put(b, 0x0b);
    http::qv_put(b, 0);
    http::qv_put(b, 2 + section.len);
    http::qv_put(b, 0x01);
    http::qv_put(b, section.len);
    b.append(section);
    http::h3_frames(ci, 2, b, 1000);
    var calls = 0;
    http::h3_serve_conn(q, ci, cfg, fresh, "", 1000) { ev, st, out =>
        calls++;
        if ev.kind == http::REQUEST { http::respond(out, 200, "text/plain", big); }
    };
    sent_owed(ci);
    print("queued past H3_QUEUED: ", http::h3conns[ci].queued > http::H3_QUEUED);
    var most = 0;
    for n in 1..601 {
        b.clear();
        for frame in [0x0a, 0x04, 0x05] {
            http::qv_put(b, frame);
            http::qv_put(b, n * 4);
            if frame == 0x0a { http::qv_put(b, 0); }
            else { http::qv_put(b, http::H3_REQUEST_CANCELLED); }
            if frame == 0x04 { http::qv_put(b, 0); }
        }
        http::h3_frames(ci, 2, b, 1000 + n);
        assert(http::h3conns[ci].state == http::H3_OPEN);
        http::h3_serve_conn(q, ci, cfg, fresh, "", 1000 + n) { ev, st, out => calls++; };
        sent_owed(ci);
        let c .= http::h3conns[ci];
        for k, i in c.ready {
            assert(http::h3strms[k].conn == ci);
            for j in i { assert(c.ready[j] != k); }
        }
        most = max(most, c.ready.len);
    }
    print("600 streams opened, reset, and stopped: the most listed ", most, ", handler calls ", calls);
}
