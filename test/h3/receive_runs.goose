// What a stream or a level's CRYPTO holds for bytes received out of order
// stays within the limit this side gave: two bytes just under it make a run
// no larger. A connection's first Initial, which any address can send, can
// have it hold at most 16 KB of CRYPTO.
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;
import http.h3;

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
    let ctx, made = tls::server(chain, key, ["h3"]);
    assert(made);
    http::h3max_conns = 1;
    var dcid: u8[>..] = [];
    for i in 8 { dcid.push(i as u8); }
    let h = http::QHeader { long: true, kind: 0, version: 1, dcid: dcid, scid: dcid, token: dcid[..0], pn_at: 0, end: 0 };
    let peer = http::UdpPeer { len: 16, addr: [0; 28] };
    let ci = http::h3_accept(ctx, 0, h, peer, 0);
    assert(ci >= 0);
    let r .= http::h3conns[ci].sp[0].crypto_rx;
    let limit = r.max;
    assert(http::rx_put(r, limit - 2, "x") && http::rx_put(r, limit - 1, "y"));
    print("Initial CRYPTO bytes at the limit - 2 and - 1: run ", r.data.cap, " bytes, limit ", limit);
    print("an Initial CRYPTO byte at the limit: taken ", http::rx_put(r, limit, "z"));
    let mib: i64 = 1 << 20;
    assert(http::h3_stream_in(ci, 0, mib - 2, "x", false) == 0 && http::h3_stream_in(ci, 0, mib - 1, "y", false) == 0);
    let st .= http::h3strms[http::strm_find(http::h3conns[ci], 0)];
    print("stream bytes at 1 MiB - 2 and - 1: run ", st.rx.data.cap, " bytes, limit ", st.rx.max);
}
