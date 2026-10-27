// QUIC version 1's wire format (RFC 9000) as h3.goose reads and writes it:
// variable-length integers, packet headers, the frames a server writes, the
// packet numbers received, and transport parameters. Bytes alone, as
// h2frame.goose is: no state, no system calls.
namespace http;

import std;

let QUIC_V1: i64 = 1;
// The largest variable-length integer, 2^62 - 1.
let QUIC_VARINT_MAX: i64 = 0x3fffffffffffffff;

// Long header packet types (§17.2).
let QP_INITIAL = 0;
let QP_ZERO_RTT = 1;
let QP_HANDSHAKE = 2;
let QP_RETRY = 3;

// Frame types (§19).
let QF_PADDING = 0x00;
let QF_PING = 0x01;
let QF_ACK = 0x02;
let QF_ACK_ECN = 0x03;
let QF_RESET_STREAM = 0x04;
let QF_STOP_SENDING = 0x05;
let QF_CRYPTO = 0x06;
let QF_NEW_TOKEN = 0x07;
let QF_STREAM = 0x08;
let QF_MAX_DATA = 0x10;
let QF_MAX_STREAM_DATA = 0x11;
let QF_MAX_STREAMS_BIDI = 0x12;
let QF_MAX_STREAMS_UNI = 0x13;
let QF_DATA_BLOCKED = 0x14;
let QF_STREAM_DATA_BLOCKED = 0x15;
let QF_STREAMS_BLOCKED_BIDI = 0x16;
let QF_STREAMS_BLOCKED_UNI = 0x17;
let QF_NEW_CONNECTION_ID = 0x18;
let QF_RETIRE_CONNECTION_ID = 0x19;
let QF_PATH_CHALLENGE = 0x1a;
let QF_PATH_RESPONSE = 0x1b;
let QF_CONNECTION_CLOSE = 0x1c;
let QF_CONNECTION_CLOSE_APP = 0x1d;
let QF_HANDSHAKE_DONE = 0x1e;

// Transport error codes (§20.1); a TLS alert is QE_CRYPTO plus it.
let QE_NO_ERROR = 0x00;
let QE_INTERNAL_ERROR = 0x01;
let QE_CONNECTION_REFUSED = 0x02;
let QE_FLOW_CONTROL_ERROR = 0x03;
let QE_STREAM_LIMIT_ERROR = 0x04;
let QE_STREAM_STATE_ERROR = 0x05;
let QE_FINAL_SIZE_ERROR = 0x06;
let QE_FRAME_ENCODING_ERROR = 0x07;
let QE_TRANSPORT_PARAMETER_ERROR = 0x08;
let QE_CONNECTION_ID_LIMIT_ERROR = 0x09;
let QE_PROTOCOL_VIOLATION = 0x0a;
let QE_INVALID_TOKEN = 0x0b;
let QE_CRYPTO_BUFFER_EXCEEDED = 0x0d;
let QE_KEY_UPDATE_ERROR = 0x0e;
let QE_AEAD_LIMIT_REACHED = 0x0f;
let QE_CRYPTO = 0x100;

// A cursor over bytes: where it is, and whether a read ran past the end.
struct QRd { at: i64, bad: bool }

// The variable-length integer at r (§16), or 0 with r.bad.
fn qv(b: const u8[:], r: QRd&) -> i64 {
    guard !r.bad && r.at < b.len else {
        r.bad = true;
        return 0;
    }
    let first = b[r.at];
    let n: i64 = 1 << (first >> 6);
    guard r.at + n <= b.len else {
        r.bad = true;
        return 0;
    }
    var v: i64 = first & 0x3f;
    for i in 1..n { v = (v << 8) | b[r.at + i]; }
    r.at += n;
    return v;
}

// The next n bytes at r, or none with r.bad.
fn qtake(b: const u8[:], r: QRd&, n: i64) -> const u8[:] {
    guard !r.bad && n >= 0 && n <= b.len - r.at else {
        r.bad = true;
        return b[..0];
    }
    let s = b[r.at..r.at + n];
    r.at += n;
    return s;
}

fn qbyte(b: const u8[:], r: QRd&) -> i64 {
    guard !r.bad && r.at < b.len else {
        r.bad = true;
        return 0;
    }
    r.at += 1;
    return b[r.at - 1];
}

// The bytes v takes as a variable-length integer.
fn qv_len(v: i64) -> i64 {
    return if v < 64 { 1 } else if v < 16384 { 2 } else if v < 1 << 30 { 4 } else { 8 };
}

// Appends v, at most QUIC_VARINT_MAX, as a variable-length integer.
fn qv_put(w: u8[>..]&, v: i64) {
    if v < 64 {
        w.push(v as! u8);
    } else if v < 16384 {
        w.push((0x40 | (v >> 8)) as! u8);
        w.push(v as! u8);
    } else if v < 1 << 30 {
        w.push((0x80 | (v >> 24)) as! u8);
        w.push((v >> 16) as! u8);
        w.push((v >> 8) as! u8);
        w.push(v as! u8);
    } else {
        w.push((0xc0 | (v >> 56)) as! u8);
        for i in 1..8 { w.push((v >> (56 - 8 * i)) as! u8); }
    }
}

// Writes v as a 2-byte variable-length integer at w[at..at + 2], for a
// length filled in after what it counts: at most 16383.
fn qv_put2_at(w: u8[>..]&, at: i64, v: i64) {
    w[at] = (0x40 | (v >> 8)) as! u8;
    w[at + 1] = v as! u8;
}

// A packet's header, as far as it's readable before header protection comes
// off: for a long header (§17.2), its type, version, connection IDs, an
// Initial's token, where its packet number starts, and where the packet
// ends, by its Length; a short header (§17.3) runs to the datagram's end.
struct QHeader {
    long: bool,
    kind: i64,
    version: i64,
    dcid: const u8[:],
    scid: const u8[:],
    token: const u8[:],
    pn_at: i64,
    end: i64,
}

// The header of the packet at d[at..], whose short header's Destination
// Connection ID is cid_len bytes, and whether it parses. A long header of
// another version parses as far as its version and connection IDs.
fn quic_header(d: const u8[:], at: i64, cid_len: i64) -> QHeader, bool {
    var h = QHeader { long: false, kind: 0, version: 0, dcid: d[..0], scid: d[..0], token: d[..0], pn_at: 0, end: d.len };
    var r = QRd { at: at, bad: false };
    let first = qbyte(d, r);
    guard !r.bad else { return h, false; }
    if first & 0x80 == 0 {
        h.dcid = qtake(d, r, cid_len);
        h.pn_at = r.at;
        return h, !r.bad && first & 0x40 != 0;
    }
    h.long = true;
    h.kind = (first >> 4) & 3;
    let v = qtake(d, r, 4);
    guard !r.bad else { return h, false; }
    h.version = (v[0] as i64) << 24 | (v[1] as i64) << 16 | (v[2] as i64) << 8 | v[3];
    let dl = qbyte(d, r);
    guard dl <= 20 else { return h, false; }
    h.dcid = qtake(d, r, dl);
    let sl = qbyte(d, r);
    guard sl <= 20 else { return h, false; }
    h.scid = qtake(d, r, sl);
    guard !r.bad else { return h, false; }
    guard h.version == QUIC_V1 else { return h, true; }
    guard first & 0x40 != 0 && h.kind != QP_RETRY else { return h, false; }
    if h.kind == QP_INITIAL { h.token = qtake(d, r, qv(d, r)); }
    let len = qv(d, r);
    guard !r.bad && len <= d.len - r.at else { return h, false; }
    h.pn_at = r.at;
    h.end = r.at + len;
    return h, true;
}

// The full packet number that a truncated one of n bytes encodes, given the
// largest received in its space so far, -1 for none (RFC 9000, A.3).
fn quic_decode_pn(largest: i64, truncated: i64, n: i64) -> i64 {
    let expected = largest + 1;
    let win: i64 = 1 << (n * 8);
    let half = win / 2;
    let candidate = (expected & ~(win - 1)) | truncated;
    if candidate <= expected - half && candidate < (1 << 62) - win { return candidate + win; }
    if candidate > expected + half && candidate >= win { return candidate - win; }
    return candidate;
}

// The bytes to encode packet number pn in, given the largest the peer has
// acknowledged, -1 for none (A.2): twice the packets in flight, as a 1- to
// 4-byte number holds them.
fn quic_pn_len(pn: i64, acked: i64) -> i64 {
    let range = 2 * (pn - (if acked < 0 { -1 } else { acked }));
    return if range < 1 << 8 { 1 } else if range < 1 << 16 { 2 } else if range < 1 << 24 { 3 } else { 4 };
}

// The packet numbers received in one space, as ranges, highest first, which
// an ACK frame reports (§19.3). The oldest go once the list is full: their
// packets are long acknowledged, or never will be. floor is the highest
// packet number dropped with them, and nothing at or below it is accepted
// again (§13.2.3).
struct QRange { lo: i64, hi: i64 }
let QUIC_RANGES = 32;
struct QRanges { r: QRange[..QUIC_RANGES] = [], floor: i64 = -1 }

// Adds pn; false when it was there already, a duplicate, or can't be told
// from one: at or below floor, or below every range of a full list.
fn quic_ranges_add(s: QRanges&, pn: i64) -> bool {
    if pn <= s.floor { return false; }
    // The ranges before i start above pn + 1, so none of them touches pn.
    var i = 0;
    while i < s.r.len && s.r[i].lo > pn + 1 { i++; }
    if i < s.r.len {
        let g .= s.r[i];
        if g.lo == pn + 1 {
            g.lo = pn;
            if i + 1 < s.r.len && s.r[i + 1].hi + 1 == pn {
                g.lo = s.r[i + 1].lo;
                s.r.remove_at(i + 1);
            }
            return true;
        }
        if pn <= g.hi { return false; }
        if g.hi + 1 == pn {
            g.hi = pn;
            return true;
        }
    }
    if s.r.len == QUIC_RANGES {
        guard i < QUIC_RANGES else { return false; }
        s.floor = s.r.pop().hi;
    }
    s.r.insert_at(i, QRange { lo: pn, hi: pn });
    return true;
}

fn quic_ranges_largest(s: const QRanges&) -> i64 { if s.r.len > 0 { s.r[0].hi } else { -1 } }

// Appends an ACK frame for s, its delay in microseconds scaled by the
// ack_delay_exponent of 3 this side sends.
fn quic_write_ack(w: u8[>..]&, s: const QRanges&, delay_us: i64) {
    w.push(QF_ACK);
    qv_put(w, s.r[0].hi);
    qv_put(w, max(delay_us, 0) >> 3);
    qv_put(w, s.r.len - 1);
    qv_put(w, s.r[0].hi - s.r[0].lo);
    for i in 1..s.r.len {
        qv_put(w, s.r[i - 1].lo - s.r[i].hi - 2);
        qv_put(w, s.r[i].hi - s.r[i].lo);
    }
}

// The ACK frame at r, after its type: F(lo, hi) for each range it
// acknowledges, highest first, and its largest and its delay; false for one
// that doesn't parse or reaches below 0 (§19.3.1).
fn quic_read_ack<F>(b: const u8[:], r: QRd&, ecn: bool) -> i64, i64, bool {
    let largest = qv(b, r);
    let delay = qv(b, r);
    let count = qv(b, r);
    var hi = largest;
    var lo = largest - qv(b, r);
    guard !r.bad && lo >= 0 else { return 0, 0, false; }
    F(lo, hi);
    for i in count {
        let gap = qv(b, r);
        let len = qv(b, r);
        hi = lo - gap - 2;
        lo = hi - len;
        guard !r.bad && lo >= 0 else { return 0, 0, false; }
        F(lo, hi);
    }
    if ecn {
        qv(b, r);
        qv(b, r);
        qv(b, r);
    }
    return largest, delay, !r.bad;
}

fn quic_write_crypto_head(w: u8[>..]&, off: i64, len: i64) {
    w.push(QF_CRYPTO);
    qv_put(w, off);
    qv_put(w, len);
}

// A STREAM frame's head, with its offset where it isn't 0, and its length.
fn quic_write_stream_head(w: u8[>..]&, id: i64, off: i64, len: i64, fin: bool) {
    w.push((QF_STREAM | 0x02 | (if off > 0 { 0x04 } else { 0 }) | (if fin { 0x01 } else { 0 })) as! u8);
    qv_put(w, id);
    if off > 0 { qv_put(w, off); }
    qv_put(w, len);
}

// The bytes quic_write_stream_head takes.
fn quic_stream_head_len(id: i64, off: i64, len: i64) -> i64 {
    return 1 + qv_len(id) + (if off > 0 { qv_len(off) } else { 0 }) + qv_len(len);
}

fn quic_write_frame1(w: u8[>..]&, kind: i64, v: i64) {
    w.push(kind as! u8);
    qv_put(w, v);
}

fn quic_write_frame2(w: u8[>..]&, kind: i64, a: i64, b: i64) {
    w.push(kind as! u8);
    qv_put(w, a);
    qv_put(w, b);
}

// A transport CONNECTION_CLOSE (0x1c), or an application's (0x1d), with no
// reason phrase.
fn quic_write_close(w: u8[>..]&, app: bool, code: i64, frame: i64) {
    w.push(if app { QF_CONNECTION_CLOSE_APP } else { QF_CONNECTION_CLOSE });
    qv_put(w, code);
    if !app { qv_put(w, frame); }
    qv_put(w, 0);
}

// Transport parameter IDs (§18.2).
let QT_ORIGINAL_DCID = 0x00;
let QT_MAX_IDLE_TIMEOUT = 0x01;
let QT_STATELESS_RESET_TOKEN = 0x02;
let QT_MAX_UDP_PAYLOAD_SIZE = 0x03;
let QT_INITIAL_MAX_DATA = 0x04;
let QT_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL = 0x05;
let QT_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE = 0x06;
let QT_INITIAL_MAX_STREAM_DATA_UNI = 0x07;
let QT_INITIAL_MAX_STREAMS_BIDI = 0x08;
let QT_INITIAL_MAX_STREAMS_UNI = 0x09;
let QT_ACK_DELAY_EXPONENT = 0x0a;
let QT_MAX_ACK_DELAY = 0x0b;
let QT_DISABLE_ACTIVE_MIGRATION = 0x0c;
let QT_PREFERRED_ADDRESS = 0x0d;
let QT_ACTIVE_CONNECTION_ID_LIMIT = 0x0e;
let QT_INITIAL_SCID = 0x0f;
let QT_RETRY_SCID = 0x10;

// The transport parameters this side reads from a peer, with the defaults
// for those it leaves out (§18.2).
struct QParams {
    max_idle_timeout: i64 = 0,
    max_udp_payload_size: i64 = 65527,
    initial_max_data: i64 = 0,
    initial_max_stream_data_bidi_local: i64 = 0,
    initial_max_stream_data_bidi_remote: i64 = 0,
    initial_max_stream_data_uni: i64 = 0,
    initial_max_streams_bidi: i64 = 0,
    initial_max_streams_uni: i64 = 0,
    ack_delay_exponent: i64 = 3,
    max_ack_delay: i64 = 25,
    active_connection_id_limit: i64 = 2,
}

// Reads a client's transport parameters into p, checking them against the
// rules for a client's (§7.4, §18.2): its initial_source_connection_id must
// be scid, from its Initial's header, and it may not send those only a
// server sends. False for a TRANSPORT_PARAMETER_ERROR.
fn quic_read_params(b: const u8[:], p: QParams&, scid: const u8[:]) -> bool {
    var r = QRd { at: 0, bad: false };
    var seen: u64 = 0;
    var iscid = false;
    while r.at < b.len {
        let id = qv(b, r);
        let body = qtake(b, r, qv(b, r));
        guard !r.bad else { return false; }
        if id < 64 {
            guard seen & ((1 as u64) << id) == 0 else { return false; }
            seen |= (1 as u64) << id;
        }
        var v = QRd { at: 0, bad: false };
        match id {
            QT_ORIGINAL_DCID, QT_STATELESS_RESET_TOKEN, QT_PREFERRED_ADDRESS, QT_RETRY_SCID => { return false; },
            QT_INITIAL_SCID => {
                guard body == scid else { return false; }
                iscid = true;
                continue;
            },
            QT_DISABLE_ACTIVE_MIGRATION => {
                guard body.len == 0 else { return false; }
                continue;
            },
            _ => {},
        }
        let x = qv(body, v);
        let known = id <= QT_ACTIVE_CONNECTION_ID_LIMIT;
        if !known { continue; }
        guard !v.bad && v.at == body.len else { return false; }
        match id {
            QT_MAX_IDLE_TIMEOUT => { p.max_idle_timeout = x; },
            QT_MAX_UDP_PAYLOAD_SIZE => {
                guard x >= 1200 else { return false; }
                p.max_udp_payload_size = x;
            },
            QT_INITIAL_MAX_DATA => { p.initial_max_data = x; },
            QT_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL => { p.initial_max_stream_data_bidi_local = x; },
            QT_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE => { p.initial_max_stream_data_bidi_remote = x; },
            QT_INITIAL_MAX_STREAM_DATA_UNI => { p.initial_max_stream_data_uni = x; },
            QT_INITIAL_MAX_STREAMS_BIDI => {
                guard x <= 1 << 60 else { return false; }
                p.initial_max_streams_bidi = x;
            },
            QT_INITIAL_MAX_STREAMS_UNI => {
                guard x <= 1 << 60 else { return false; }
                p.initial_max_streams_uni = x;
            },
            QT_ACK_DELAY_EXPONENT => {
                guard x <= 20 else { return false; }
                p.ack_delay_exponent = x;
            },
            QT_MAX_ACK_DELAY => {
                guard x < 1 << 14 else { return false; }
                p.max_ack_delay = x;
            },
            QT_ACTIVE_CONNECTION_ID_LIMIT => {
                guard x >= 2 else { return false; }
                p.active_connection_id_limit = x;
            },
            _ => {},
        }
    }
    return iscid;
}

fn quic_param_int(w: u8[>..]&, id: i64, v: i64) {
    qv_put(w, id);
    qv_put(w, qv_len(v));
    qv_put(w, v);
}

fn quic_param_bytes(w: u8[>..]&, id: i64, v: const u8[:]) {
    qv_put(w, id);
    qv_put(w, v.len);
    w.append(v);
}
