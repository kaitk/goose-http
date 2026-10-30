// A connection's flow control credits each byte a client sent once. A
// request this side stops, whose client then sends more and resets it, must
// not credit the bytes after the stop twice, or the client may hold more
// than the connection's window unread.
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;
import http.h3;

fn main() {
    let ci = http::h3conns.alloc_index(http::H3Conn { live: true, .. });
    let mib: i64 = 1 << 20;
    for j in 20 {
        let id = j * 4;
        assert(http::h3_stream_in(ci, id, 0, "12345678", false) == 0);
        let k = http::strm_find(http::h3conns[ci], id);
        http::rx_take(http::h3strms[k].rx, 8);
        http::h3_consumed(ci, k, 8);
        http::h3_stop_request(k);
        assert(http::h3_stream_in(ci, id, mib / 2, "x", false) == 0);
        assert(http::h3_stream_in(ci, id, mib - 1, "x", false) == 0);
        assert(http::h3_reset_in(ci, id, 0, mib) == 0);
        http::strm_close(ci, k);
    }
    let c .= http::h3conns[ci];
    print("20 requests stopped, sent to, and reset: received ", c.rx_total, ", credited ", c.rx_read);
}
