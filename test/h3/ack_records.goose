// A client that sends ack-eliciting packets and never acknowledges this
// side's: every second one is answered with an ACK-only packet, which this
// side keeps no record of, so its records stay what's in flight. The
// connection's 1-RTT keys are one secret each way, set as goose-tls's RFC
// 9001 test sets them, so the test seals the client's packets itself.
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;
import http.h3;

extern "tlsg_ks_set" fn ks_set(id: i64, slot: i64, value: const u8[:]) -> bool;

var client_pn: i64 = 0;

fn records(ci: i64) -> i64 {
    var n = 0;
    var k = http::h3conns[ci].sp[2].head;
    while k >= 0 {
        n++;
        k = http::h3sent[k].next;
    }
    return n;
}

// Seals a client 1-RTT packet of payload, with a 4-byte packet number, and
// hands it to connection ci.
fn deliver(ci: i64, payload: const u8[:], now: i64) {
    let c .= http::h3conns[ci];
    var p: u8[>..] = [];
    p.push((0x40 | ((c.phase as i64) << 2) | 3) as! u8);
    var cid: u8[..20] = [];
    http::h3_cid_bytes(c.cid, cid);
    p.append(cid);
    for i in 4 { p.push((client_pn >> (24 - 8 * i)) as! u8); }
    p.append(payload);
    p.resize(p.len + 16, 0);
    assert(tls::quic_seal(c.t, tls::QUIC_APP, p, 13, 4, client_pn));
    client_pn++;
    let h, ok = http::quic_header(p, 0, http::H3_CID_LEN);
    assert(ok);
    http::h3_packet(ci, h, p[..h.end], h.pn_at, now);
}

// Sends what connection ci has, to no socket: the datagrams queued.
fn flush(ci: i64, now: i64) -> i64 {
    http::h3tx_count = 0;
    http::h3q_len = 0;
    http::h3_flush(ci, now);
    return http::h3tx_count;
}

// A connection whose handshake is done, with 1-RTT keys.
fn shaken(ctx: tls::Context, now: i64) -> i64 {
    var dcid: u8[>..] = [];
    var scid: u8[>..] = [];
    for i in 8 { dcid.push((0x10 + i) as! u8); scid.push((0x20 + i) as! u8); }
    let h = http::QHeader { long: true, kind: 0, version: 1, dcid: dcid, scid: scid, token: dcid[..0], pn_at: 0, end: 0 };
    let peer = http::UdpPeer { len: 16, addr: [0; 28] };
    let ci = http::h3_accept(ctx, 0, h, peer, now);
    assert(ci >= 0);
    let c .= http::h3conns[ci];
    let id = c.t.id;
    var secret: u8[>..] = [];
    for i in 32 { secret.push((0x9a + 7 * i) as! u8); }
    assert(tls::g_hs_begin(id, 0x1303));
    assert(ks_set(id, tls::S_SERVER_AP, secret));
    assert(tls::g_quic_keys(id, tls::QL_APP, tls::DIR_WRITE, tls::S_SERVER_AP));
    assert(tls::g_quic_keys(id, tls::QL_APP, tls::DIR_READ, tls::S_SERVER_AP));
    tls::quic_drop(c.t, tls::QUIC_INITIAL);
    c.validated = true;
    c.params_read = true;
    c.peer_params.initial_max_data = 1 << 20;
    c.peer_params.initial_max_stream_data_uni = 1 << 20;
    c.peer_params.initial_max_streams_uni = 3;
    c.tx_max = c.peer_params.initial_max_data;
    http::h3_shaken(ci, now);
    return ci;
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
    let ctx, made = tls::server(chain, key, ["h3"]);
    assert(made);
    http::h3max_conns = 1;
    http::h3fds.push(-1);
    var now: i64 = 1000000;
    let ci = shaken(ctx, now);
    // The first flight, HANDSHAKE_DONE and SETTINGS, acknowledged once; then
    // nothing of this side's is.
    print("first flight: datagrams ", flush(ci, now), ", records ", records(ci));
    now++;
    deliver(ci, "\x01\x02\x00\x00\x00\x00", now);
    print("acknowledged: records ", records(ci));
    var answers = 0;
    for i in 2000 {
        now++;
        deliver(ci, "\x01", now);
        answers += flush(ci, now);
    }
    let c .= http::h3conns[ci];
    print("2000 PINGs: ", answers, " ACK-only answers, records ", records(ci), ", open ", c.state == http::H3_OPEN,
          ", largest sent ", c.sp[2].largest_sent);
    // An ACK of the newest answer, which has no record, still moves
    // largest_acked.
    var ack: u8[>..] = [1, 2];
    http::qv_put(ack, c.sp[2].largest_sent);
    ack.append("\x00\x00\x00");
    now++;
    deliver(ci, ack, now);
    print("the newest acknowledged: largest acked ", http::h3conns[ci].sp[2].largest_acked, ", records ", records(ci));
}
