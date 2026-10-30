// A client's ACK Delay is capped by its max_ack_delay (RFC 9002, section
// 5.3), however large the field: 2^60 at the default exponent, 3, would wrap
// once shifted and push the RTT estimate, the PTO, and the idle timeout out
// by 10^16 ms.
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.quic;
import http.tls;
import http.h3;

// Sends packet pn at sent, and takes an ACK frame for it at now with the
// ACK Delay field delay, a varint's bytes.
fn acked(ci: i64, pn: i64, sent: i64, now: i64, delay: const u8[:]) {
    let c .= http::h3conns[ci];
    c.sp[2].largest_sent = pn;
    c.sp[2].eliciting_in_flight++;
    c.in_flight += 100;
    http::sent_add(ci, 2, http::H3Sent { conn: ci as i32, gen: c.gen, pn: pn, time: sent, size: 100, eliciting: true,
                                         in_flight: true });
    var frame: u8[>..] = [];
    http::qv_put(frame, pn);
    frame.append(delay);
    http::qv_put(frame, 0);
    http::qv_put(frame, 0);
    var ranges: http::QRange[..64] = [];
    var r = http::QRd { at: 0, bad: false };
    let largest, d, ok = http::quic_read_ack(frame, r, false) { lo, hi => ranges.push(http::QRange { lo: lo, hi: hi }); };
    assert(ok);
    assert(http::on_ack(ci, 2, ranges, largest, d, now));
    let c2 .= http::h3conns[ci];
    print("delay ", d, ": srtt ", c2.srtt, ", rttvar ", c2.rttvar, ", PTO ", http::pto_ms(c2, 2));
}

fn main() {
    let ci = http::h3conns.alloc_index(http::H3Conn { live: true, shaken: true, .. });
    acked(ci, 0, 1000, 1040, "\x00");
    acked(ci, 1, 2000, 2040, "\xd0\x00\x00\x00\x00\x00\x00\x00");
    acked(ci, 2, 3000, 3040, "\xff\xff\xff\xff\xff\xff\xff\xff");
}
