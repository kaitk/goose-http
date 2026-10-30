// A connection whose handshake doesn't finish closes its idle period after
// the accept, however many packets keep coming: anyone can make Initial
// packets, so they mustn't keep a slot of Config.max_conns. Once the
// handshake is done, each packet restarts the period. The test seals the
// client's packets at the Handshake level, with one secret each way, since
// goose-tls sets only that level's and 1-RTT's keys by a secret; the rule is
// the same for every packet before the handshake is done.
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.quic;
import http.tls;
import http.h3;

extern "tlsg_ks_set" fn ks_set(id: i64, slot: i64, value: const u8[:]) -> bool;

var client_pn: i64 = 0;

// Seals a client Handshake packet of a PING to connection ci, and hands it
// over.
fn ping(ci: i64, now: i64) {
    let c .= http::h3conns[ci];
    var p: u8[>..] = [0xe3, 0, 0, 0, 1];
    var cid: u8[..20] = [];
    http::h3_cid_bytes(c.cid, cid);
    p.push(cid.len as! u8);
    p.append(cid);
    p.push(c.client_scid.len as! u8);
    p.append(c.client_scid);
    let payload = "\x01\x00\x00\x00";
    p.append("\x40\x00");
    http::qv_put2_at(p, p.len - 2, 4 + payload.len + 16);
    let hdr = p.len + 4;
    for i in 4 { p.push((client_pn >> (24 - 8 * i)) as! u8); }
    p.append(payload);
    p.resize(p.len + 16, 0);
    assert(tls::quic_seal(c.t, tls::QUIC_HANDSHAKE, p, hdr, 4, client_pn));
    client_pn++;
    let h, ok = http::quic_header(p, 0, http::H3_CID_LEN);
    assert(ok);
    http::h3_packet(ci, h, p[..h.end], h.pn_at, now);
}

fn accept(ctx: tls::Context, now: i64) -> i64 {
    var dcid: u8[>..] = [];
    var scid: u8[>..] = [];
    for i in 8 { dcid.push((0x10 + i) as! u8); scid.push((0x20 + i) as! u8); }
    let h = http::QHeader { long: true, kind: 0, version: 1, dcid: dcid, scid: scid, token: dcid[..0], pn_at: 0, end: 0 };
    let peer = http::UdpPeer { len: 16, addr: [0; 28] };
    let ci = http::h3_accept(ctx, 0, h, peer, now);
    assert(ci >= 0);
    let id = http::h3conns[ci].t.id;
    var secret: u8[>..] = [];
    for i in 32 { secret.push((0x31 + 5 * i) as! u8); }
    assert(tls::g_hs_begin(id, 0x1301));
    assert(ks_set(id, tls::S_SERVER_HS, secret));
    assert(tls::g_quic_keys(id, tls::QL_HANDSHAKE, tls::DIR_WRITE, tls::S_SERVER_HS));
    assert(tls::g_quic_keys(id, tls::QL_HANDSHAKE, tls::DIR_READ, tls::S_SERVER_HS));
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
    http::h3max_conns = 2;
    let ci = accept(ctx, 0);
    for t in [20000, 25000, 29000] { ping(ci, t); }
    let c .= http::h3conns[ci];
    print("after PINGs at 20, 25, and 29 s: up to packet ", http::quic_ranges_largest(c.sp[1].recv), " taken, idle at ",
          c.idle_at, " ms");
    http::h3_expire(ci, 30000);
    print("at 30 s: closed ", http::h3conns[ci].dead);
    http::h3_free(ci);
    // Past its handshake, a connection's packets keep it.
    let done = accept(ctx, 0);
    http::h3conns[done].shaken = true;
    ping(done, 20000);
    print("past its handshake, after a PING at 20 s: idle at ", http::h3conns[done].idle_at, " ms");
}
