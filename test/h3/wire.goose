// QUIC's and QPACK's bytes: variable-length integers and packet numbers
// against RFC 9000's Appendix A, the packet numbers received as an ACK
// frame's ranges and back, a client's transport parameters checked, and
// QPACK's field sections against RFC 9204's example with the static table
// (B.1), with one that needs the dynamic table refused, and a response head
// encoded and decoded back.
import std;
import http from "../../";
import http.quic;
import http.qpack;
import check from "../";

fn hex(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for i in 0..s.len / 2 {
        let v, ok = parse_int(s[2 * i..2 * i + 2], 16);
        assert(ok);
        out.push(v as u8);
    }
    return out;
}

fn to_hex(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for c in s { format_int(out, c, 16, 2, '0'); }
    return out;
}

// Prints label and got, and fails where got isn't want.
fn eq_bool(label: const u8[:], got: bool, want: bool) {
    print(label, ": ", got);
    assert(got == want);
}

// RFC 9000, A.1: each encoding, read, and the shortest written back.
fn varints() {
    for t in ["c2197c5eff14e88c", "9d7f3e7d", "7bbd", "25", "4025"] {
        let b = hex(t);
        var r = http::QRd { at: 0, bad: false };
        let v = http::qv(b, r);
        var w: u8[>..] = [];
        http::qv_put(w, v);
        print(t, " = ", v, ", written ", to_hex(w));
    }
    var r = http::QRd { at: 0, bad: false };
    http::qv(hex("40"), r);
    eq_bool("a truncated one", r.bad, true);
}

// RFC 9000, A.2 and A.3.
fn packet_numbers() {
    print("decoded: ", to_hex_i(http::quic_decode_pn(0xa82f30ea, 0x9b32, 2)));
    print("bytes for 0xac5c02 after 0xabe8b3: ", http::quic_pn_len(0xac5c02, 0xabe8b3));
    print("bytes for 0xace8fe after 0xabe8b3: ", http::quic_pn_len(0xace8fe, 0xabe8b3));
    print("bytes for the first: ", http::quic_pn_len(0, -1));
}

fn to_hex_i(v: i64) -> u8[>..] {
    var out: u8[>..] = [];
    format_int(out, v, 16, 0, '0');
    return out;
}

fn ranges_text(s: const http::QRanges&) -> u8[>..] {
    var out: u8[>..] = [];
    for g in s.r { format(out, "[", g.lo, "-", g.hi, "]"); }
    return out;
}

// Packet numbers received out of order merge into ranges, highest first,
// which an ACK frame carries and a reader gives back.
fn ranges() {
    var s = http::QRanges { .. };
    for pn in [0, 1, 2, 5, 4, 9, 7, 8, 12] { http::quic_ranges_add(s, pn); }
    print("ranges: ", ranges_text(s));
    eq_bool("a duplicate", http::quic_ranges_add(s, 4), false);
    http::quic_ranges_add(s, 3);
    http::quic_ranges_add(s, 6);
    print("filled: ", ranges_text(s));
    var w: u8[>..] = [];
    http::quic_write_ack(w, s, 2000);
    print("ACK: ", to_hex(w));
    var r = http::QRd { at: 1, bad: false };
    var back: u8[>..] = [];
    let largest, delay, ok = http::quic_read_ack(w, r, false) { lo, hi => format(back, "[", lo, "-", hi, "]"); };
    print("read back: ", back, ", largest ", largest, ", delay ", delay, ", ", ok);
}

// A full list drops its oldest range, and a packet in it, or below every kept
// range, counts as a duplicate rather than a new one (RFC 9000, 13.2.3).
fn ranges_full() {
    var s = http::QRanges { .. };
    for k in 34 { http::quic_ranges_add(s, k * 3); }
    print("kept: ", s.r.len, ", lowest ", s.r[s.r.len - 1].lo, ", floor ", s.floor);
    eq_bool("a dropped one again", http::quic_ranges_add(s, 3), false);
    eq_bool("one below the floor", http::quic_ranges_add(s, 1), false);
    eq_bool("one below every kept range", http::quic_ranges_add(s, 4), false);
    eq_bool("one beside a kept range", http::quic_ranges_add(s, 7), true);
}

// A client's transport parameters: its initial_source_connection_id must be
// the Source Connection ID of its Initial, and it may not send one only a
// server sends.
fn params() {
    var w: u8[>..] = [];
    http::quic_param_bytes(w, http::QT_INITIAL_SCID, "\x01\x02");
    http::quic_param_int(w, http::QT_INITIAL_MAX_DATA, 1048576);
    http::quic_param_int(w, http::QT_INITIAL_MAX_STREAMS_BIDI, 100);
    http::quic_param_int(w, 0x2a2a, 7);
    var p = http::QParams { .. };
    eq_bool("a client's", http::quic_read_params(w, p, "\x01\x02"), true);
    print("  initial_max_data ", p.initial_max_data, ", initial_max_streams_bidi ", p.initial_max_streams_bidi,
          ", max_ack_delay ", p.max_ack_delay);
    var q = http::QParams { .. };
    eq_bool("another Source Connection ID", http::quic_read_params(w, q, "\x01\x03"), false);
    http::quic_param_bytes(w, http::QT_ORIGINAL_DCID, "\x09");
    eq_bool("one that names an original_destination_connection_id", http::quic_read_params(w, q, "\x01\x02"), false);
}

fn decoded(fb: const u8[:]) -> u8[>..] {
    var scratch: u8[>..] = [];
    var lines: u8[>..] = [];
    let ok = http::qpack_decode(fb, scratch) { n, v => format(lines, n, ": ", v, "; "); };
    if !ok { lines.append("refused"); }
    return lines;
}

fn qpack() {
    // B.1: a literal with a name reference to the static table.
    print("B.1: ", decoded(hex("0000510b2f696e6465782e68746d6c")));
    // B.2's field section refers to the dynamic table, which this side
    // gives no capacity.
    print("B.2: ", decoded(hex("03811011")));
    var fb: u8[>..] = [];
    http::qpack_begin(fb);
    http::qpack_status(fb, 200);
    http::qpack_encode(fb, "content-type", "text/plain");
    http::qpack_encode(fb, "content-length", "13");
    http::qpack_encode(fb, "server", "goose");
    http::qpack_encode(fb, "x-request-id", "abc123");
    print("encoded: ", to_hex(fb));
    print("decoded: ", decoded(fb));
    var other: u8[>..] = [];
    http::qpack_begin(other);
    http::qpack_status(other, 418);
    print("418: ", decoded(other));
}

fn main() {
    varints();
    packet_numbers();
    ranges();
    ranges_full();
    params();
    qpack();
}
