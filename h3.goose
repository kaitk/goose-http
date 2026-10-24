// HTTP/3 (RFC 9114) over QUIC version 1 (RFC 9000, 9001, and 9002), on the
// listeners with Listener.h3, or Config.h3 for Config.port's: a UDP socket
// on the same port as the listener's TCP one, per worker, whose datagrams
// the loop hands here. Off unless a program asks: only a program that
// imports this module has it, and it adds no Alt-Svc field, which a program
// that wants browsers to find h3 sends itself. QUIC's handshake and packet
// protection are goose-tls's (tls::quic_accept), and so h3 needs TLS:
//
//   import http from "github.com/kaitk/goose-http@<tag>";
//   import tls from "github.com/kaitk/goose-tls@<tag>";
//   import http.tls;
//   import http.h3;
//
//   let ctx, ok = tls::server_files("server.crt", "server.key", ["h3", "h2", "http/1.1"]);
//
//   thread_fn worker(cfg: http::Config, ctx: tls::Context) {
//       var server = http::tls_server(ctx);
//       var h3 = http::h3_server(ctx, fresh);
//       http::exit_on_error(http::serve_epoll(cfg, fresh, server, h3) { ev, st, out => ... });
//       http::release(h3);
//       http::release(server);
//   }
//
// The handler is HTTP/1.1's and h2's: each request stream is an exchange,
// and its HTTP/1.1 response is turned into HEADERS and DATA frames, as h2
// does. An exchange can't wait yet: later gets TIMEOUT with NO_ROOM at once.
//
// Two layers. The QUIC transport keeps its connections, streams, and sent
// packets in each worker's own pools (globals, which each worker has a copy
// of), and knows nothing of the handler. The HTTP/3 layer reads the bytes
// the transport received on each stream, calls the handler, and queues what
// it answers on the stream for the transport to send.
namespace http;

import std;
import os;
import dictionary;
import tls from "../goose-tls-quic";
import sys;
import message;
import quic;
import qpack;
import epoll;
import uring;
import mail;

// The Connection IDs this side issues, and the largest datagram it sends:
// QUIC's smallest, which every path carries (RFC 9000, section 14).
let H3_CID_LEN = 8;
let H3_DATAGRAM = 1200;
// A datagram's room in the receive buffer, the datagrams taken per receive,
// and the datagrams a worker queues before it sends them.
let H3_SLOT = 2048;
let H3_BATCH = 32;
let H3_TX_MAX = 64;
// The transport parameters this side sends: the request streams a client
// may have open at once, its unidirectional streams, and what it may send on
// each stream and on the connection before more credit comes.
let H3_STREAMS = 128;
let H3_UNI_STREAMS = 8;
let H3_STREAM_WINDOW: i64 = 1 << 20;
let H3_CONN_WINDOW: i64 = 16 << 20;
let H3_IDLE_MS = 30000;
let H3_MAX_ACK_DELAY = 25;
// The most of a response a stream queues before the handler is asked for
// more (MORE).
let H3_SEND_AHEAD = 131072;
// RFC 9002's constants: the RTT before a sample, the timer granularity, the
// packet reordering threshold, and NewReno's windows.
let H3_INITIAL_RTT = 333;
let H3_GRANULARITY = 1;
let H3_PACKET_THRESHOLD = 3;
let H3_INITIAL_WINDOW: i64 = 10 * 1200;
let H3_MIN_WINDOW: i64 = 2 * 1200;
// AES-GCM's confidentiality limit, packets under one key (RFC 9001, section
// 6.6): past it a connection closes rather than update its keys.
let H3_AEAD_PACKETS: i64 = 1 << 23;
// Packets that failed to authenticate on a connection, past which it closes:
// the integrity limit of AEAD_CHACHA20_POLY1305, the lowest of the three.
let H3_FORGERIES: i64 = 1 << 36;

// HTTP/3 frame types (RFC 9114, section 7.2), and stream types (6.2).
let H3F_DATA = 0x00;
let H3F_HEADERS = 0x01;
let H3F_CANCEL_PUSH = 0x03;
let H3F_SETTINGS = 0x04;
let H3F_PUSH_PROMISE = 0x05;
let H3F_GOAWAY = 0x07;
let H3F_MAX_PUSH_ID = 0x0d;
let H3S_CONTROL = 0x00;
let H3S_PUSH = 0x01;
let H3S_ENCODER = 0x02;
let H3S_DECODER = 0x03;
// HTTP/3's error codes (8.1) and QPACK's (RFC 9204, 6).
let H3_NO_ERROR = 0x100;
let H3_GENERAL_PROTOCOL_ERROR = 0x101;
let H3_INTERNAL_ERROR = 0x102;
let H3_STREAM_CREATION_ERROR = 0x103;
let H3_CLOSED_CRITICAL_STREAM = 0x104;
let H3_FRAME_UNEXPECTED = 0x105;
let H3_FRAME_ERROR = 0x106;
let H3_EXCESSIVE_LOAD = 0x107;
let H3_ID_ERROR = 0x108;
let H3_SETTINGS_ERROR = 0x109;
let H3_MISSING_SETTINGS = 0x10a;
let H3_REQUEST_REJECTED = 0x10b;
let H3_REQUEST_CANCELLED = 0x10c;
let H3_REQUEST_INCOMPLETE = 0x10d;
let H3_MESSAGE_ERROR = 0x10e;
let QPACK_DECOMPRESSION_FAILED = 0x200;
let QPACK_ENCODER_STREAM_ERROR = 0x201;
// SETTINGS (7.2.4.1; RFC 9204, 5).
let H3_SETTING_QPACK_CAPACITY = 0x01;
let H3_SETTING_MAX_FIELD_SECTION = 0x06;
let H3_SETTING_QPACK_BLOCKED = 0x07;

// ---- Byte ranges, and the bytes of a stream ----

// [lo, hi) of a stream's or a level's bytes.
struct H3Span { lo: i64, hi: i64 }
// Ranges, apart and in order. Full, the two closest merge, which for the
// ranges acknowledged only means sending some bytes again.
let H3_SPANS = 8;
struct H3Spans { s: H3Span[..H3_SPANS] = [] }

fn spans_add(sp: H3Spans&, lo: i64, hi: i64) {
    guard lo < hi else { return; }
    var a = lo;
    var b = hi;
    var i = 0;
    while i < sp.s.len {
        let g = sp.s[i];
        if g.hi < a || g.lo > b {
            i++;
            continue;
        }
        a = min(a, g.lo);
        b = max(b, g.hi);
        sp.s.remove_at(i);
    }
    var at = 0;
    while at < sp.s.len && sp.s[at].lo < a { at++; }
    if sp.s.len == H3_SPANS {
        // Merge the two closest neighbours to make room.
        var best = 0;
        for j in 1..sp.s.len - 1 {
            if sp.s[j + 1].lo - sp.s[j].hi < sp.s[best + 1].lo - sp.s[best].hi { best = j; }
        }
        sp.s[best].hi = sp.s[best + 1].hi;
        sp.s.remove_at(best + 1);
        if at > best + 1 { at--; }
    }
    sp.s.insert_at(at, H3Span { lo: a, hi: b });
}

// Takes [lo, hi) out of sp.
fn spans_remove(sp: H3Spans&, lo: i64, hi: i64) {
    var i = 0;
    while i < sp.s.len {
        let g = sp.s[i];
        if g.hi <= lo || g.lo >= hi {
            i++;
            continue;
        }
        sp.s.remove_at(i);
        if g.hi > hi { spans_add(sp, hi, g.hi); }
        if g.lo < lo { spans_add(sp, g.lo, lo); }
        i = 0;
    }
}

// A run of the worker's byte pool, h3bytes[at..at + cap], by its place
// rather than a slice: the transport's pools are globals, which a worker
// copies, so they hold no references (spec §11.2).
struct H3Run { at: i64 = 0, cap: i64 = 0 }

// The bytes this side sends on a stream, or as CRYPTO at a level, kept until
// they're acknowledged: offsets start..start + data.cap are in data; those
// below base are acknowledged, and queued ones run to end. next is the first
// offset never sent, and lost holds what was sent and lost. fin follows end,
// and max is the peer's limit.
struct H3Tx {
    data: H3Run = H3Run { .. },
    start: i64 = 0,
    base: i64 = 0,
    end: i64 = 0,
    next: i64 = 0,
    fin: bool = false,
    fin_sent: bool = false,
    fin_acked: bool = false,
    max: i64 = 0,
    acked: H3Spans = H3Spans { .. },
    lost: H3Spans = H3Spans { .. },
}

// What a stream, or a level's CRYPTO, received: offsets start..start +
// data.cap in data; read is how far it's been taken, got what arrived past
// it, high the largest offset seen, fin the final size, or -1, and max the
// limit this side gave.
struct H3Rx {
    data: H3Run = H3Run { .. },
    start: i64 = 0,
    read: i64 = 0,
    got: H3Spans = H3Spans { .. },
    high: i64 = 0,
    fin: i64 = -1,
    max: i64 = 0,
}

// The worker's byte pool: every stream's and level's bytes, as runs.
reusable[] var h3bytes: u8[>..] = [];

fn run_free(r: u8[:]) { if r.len > 0 { h3bytes.free_slice(r); } }

fn run_bytes(r: H3Run) -> u8[:] { h3bytes[r.at..r.at + r.cap] }

// Moves r to a run of cap bytes, keeping its bytes.
fn run_grow(r: H3Run&, cap: i64) {
    let s = if r.cap == 0 { h3bytes.alloc_slice(cap) } else { h3bytes.realloc_slice(h3bytes[r.at..r.at + r.cap], cap) };
    r.at = h3bytes.index_of(s[0]);
    r.cap = cap;
}

fn run_drop(r: H3Run&) {
    if r.cap > 0 { h3bytes.free_slice(h3bytes[r.at..r.at + r.cap]); }
    r = H3Run { .. };
}

// Moves bytes [from, from + n) of r to its front.
fn run_shift(r: H3Run, from: i64, n: i64) {
    for i in max(n, 0) { h3bytes[r.at + i] = h3bytes[r.at + from + i]; }
}

// Room in t for its offsets up to need: what's acknowledged goes from the
// front, and the run grows.
fn tx_room(t: H3Tx&, need: i64) {
    if need - t.start <= t.data.cap { return; }
    let keep = t.end - t.base;
    if t.base > t.start && keep <= t.data.cap {
        run_shift(t.data, t.base - t.start, keep);
        t.start = t.base;
        if need - t.start <= t.data.cap { return; }
    }
    run_grow(t.data, max(max(need - t.start, 2 * t.data.cap), 1024));
}

// Queues bytes on t.
fn tx_put(t: H3Tx&, bytes: const u8[:]) {
    guard bytes.len > 0 else { return; }
    tx_room(t, t.end + bytes.len);
    let at = t.data.at + t.end - t.start;
    copy_into(h3bytes[at..at + bytes.len], bytes);
    t.end += bytes.len;
}

// t's bytes [lo, hi), which it holds.
fn tx_bytes(t: const H3Tx&, lo: i64, hi: i64) -> u8[:] {
    return h3bytes[t.data.at + lo - t.start..t.data.at + hi - t.start];
}

// Bytes [lo, hi) acknowledged.
fn tx_ack(t: H3Tx&, lo: i64, hi: i64) {
    spans_remove(t.lost, lo, hi);
    if lo <= t.base && hi > t.base {
        t.base = hi;
    } else if lo > t.base {
        spans_add(t.acked, lo, hi);
    }
    loop {
        guard t.acked.s.len > 0 && t.acked.s[0].lo <= t.base else { break; }
        t.base = max(t.base, t.acked.s[0].hi);
        t.acked.s.remove_at(0);
    }
}

// Bytes [lo, hi), sent, are lost: what of them isn't acknowledged is sent
// again.
fn tx_lost(t: H3Tx&, lo: i64, hi: i64) {
    let a = max(lo, t.base);
    guard a < hi else { return; }
    spans_add(t.lost, a, hi);
    for g in t.acked.s { spans_remove(t.lost, g.lo, g.hi); }
}

// Whether t has bytes or its end to send.
fn tx_pending(t: const H3Tx&) -> bool {
    return t.lost.s.len > 0 || t.next < t.end || (t.fin && !t.fin_sent);
}

fn tx_done(t: const H3Tx&) -> bool { t.fin && t.fin_acked && t.base >= t.end }

fn tx_free(t: H3Tx&) {
    run_drop(t.data);
    t = H3Tx { .. };
}

// Stores bytes at offset off in r; false where they reach past r.max, a
// FLOW_CONTROL_ERROR. Bytes before read, or there already, are dropped.
fn rx_put(r: H3Rx&, off: i64, bytes: const u8[:]) -> bool {
    let end = off + bytes.len;
    guard end <= r.max else { return false; }
    r.high = max(r.high, end);
    let lo = max(off, r.read);
    guard lo < end else { return true; }
    if end - r.start > r.data.cap {
        // Drop what's been read from the front, then grow.
        if r.read > r.start {
            let from = r.read - r.start;
            run_shift(r.data, from, min(r.high - r.read, r.data.cap - from));
            r.start = r.read;
        }
        if end - r.start > r.data.cap { run_grow(r.data, max(max(end - r.start, 2 * r.data.cap), 512)); }
    }
    let at = r.data.at + lo - r.start;
    copy_into(h3bytes[at..at + end - lo], bytes[lo - off..]);
    spans_add(r.got, lo, end);
    return true;
}

// The bytes in r from read on that arrived without a gap.
fn rx_ready(r: const H3Rx&) -> const u8[:] {
    guard r.got.s.len > 0 && r.got.s[0].lo <= r.read else { return h3bytes[..0]; }
    return h3bytes[r.data.at + r.read - r.start..r.data.at + r.got.s[0].hi - r.start];
}

// Marks n of rx_ready's bytes taken.
fn rx_take(r: H3Rx&, n: i64) {
    r.read += n;
    if r.got.s.len > 0 && r.got.s[0].hi <= r.read { r.got.s.remove_at(0); }
}

fn rx_free(r: H3Rx&) {
    run_drop(r.data);
    r = H3Rx { .. };
}

// ---- The transport's state ----

// What a sent packet carried that matters once it's acknowledged or lost
// (RFC 9002, section 2): a stream's bytes and end, a level's CRYPTO bytes,
// or a frame this side sends again with its current value if it's lost.
let R_STREAM: u8 = 0;
let R_CRYPTO: u8 = 1;
let R_HANDSHAKE_DONE: u8 = 2;
let R_MAX_DATA: u8 = 3;
let R_MAX_STREAMS: u8 = 4;
let R_MAX_STREAM_DATA: u8 = 5;
let R_RESET: u8 = 6;
let R_STOP: u8 = 7;
struct H3Ref { kind: u8, fin: bool, stream: i32, gen: u32, off: i64, len: i64 }

// A sent packet, until it's acknowledged or lost: one of its connection's
// list for its space, in packet number order.
struct H3Sent {
    conn: i32,
    gen: u32,
    pn: i64,
    time: i64,
    size: i64,
    eliciting: bool,
    in_flight: bool,
    // Its frames, h3refs[refs_at..refs_at + refs_n].
    refs_at: i64 = 0,
    refs_n: i64 = 0,
    next: i32 = -1,
}

fn sent_refs(p: const H3Sent&) -> H3Ref[:] { h3refs[p.refs_at..p.refs_at + p.refs_n] }

reusable var h3sent: H3Sent[>..] = [];
reusable[] var h3refs: H3Ref[>..] = [];

// A stream's kinds: a request (a client's bidirectional stream); a client's
// unidirectional stream, before its type is read, and as its type says; and
// this side's control stream.
let K_REQUEST: u8 = 0;
let K_UNI: u8 = 1;
let K_CONTROL_IN: u8 = 2;
let K_ENCODER_IN: u8 = 3;
let K_DECODER_IN: u8 = 4;
let K_IGNORED_IN: u8 = 5;
let K_CONTROL_OUT: u8 = 6;

// A stream's transport: its bytes each way, and the frames owed for it.
struct H3Strm {
    conn: i32 = -1,
    gen: u32 = 0,
    id: i64 = 0,
    kind: u8 = 0,
    rx: H3Rx,
    tx: H3Tx,
    // The handler's layer has bytes or the end to read here.
    readable: bool = false,
    // This side sent STOP_SENDING, or the client RESET_STREAM: the rest of
    // the request is dropped; and the client STOP_SENDING: the response is.
    rx_stopped: bool = false,
    tx_stopped: bool = false,
    // Frames owed: MAX_STREAM_DATA, RESET_STREAM, and STOP_SENDING, with
    // their codes.
    owe_max: bool = false,
    owe_reset: bool = false,
    owe_stop: bool = false,
    reset_code: i64 = 0,
    stop_code: i64 = 0,
    next_free: i32 = -1,
}

reusable var h3strms: H3Strm[>..] = [];

// A packet number space (RFC 9000, section 12.3): Initial, Handshake, and
// application data, each with its own numbers, acknowledgments, and CRYPTO.
struct H3Space {
    next_pn: i64 = 0,
    recv: QRanges = QRanges { .. },
    // When the largest packet number received arrived, for an ACK's delay.
    largest_at: i64 = 0,
    // Ack-eliciting packets received since this side last sent an ACK, and
    // when one is due.
    unacked: i64 = 0,
    ack_at: i64 = 0,
    largest_acked: i64 = -1,
    largest_sent: i64 = -1,
    loss_time: i64 = 0,
    last_eliciting: i64 = 0,
    eliciting_in_flight: i64 = 0,
    head: i32 = -1,
    tail: i32 = -1,
    crypto_tx: H3Tx,
    crypto_rx: H3Rx,
    // Probe packets owed by a PTO (RFC 9002, section 6.2.4).
    probes: i64 = 0,
}

let H3_OPEN: u8 = 0;
let H3_CLOSING: u8 = 1;
let H3_DRAINING: u8 = 2;

// A connection.
struct H3Conn {
    live: bool = false,
    gen: u32 = 0,
    listener: i32 = 0,
    peer: UdpPeer = UdpPeer { len: 0, addr: [0; 28] },
    t: tls::Conn = tls::Conn { .. },
    cid: u64 = 0,
    // The client's first Destination Connection ID, its Source Connection
    // ID, and the one this side sends to.
    odcid: u8[..20] = [],
    odcid_key: u64 = 0,
    client_scid: u8[..20] = [],
    dcid: u8[..20] = [],
    // The sequence number of dcid among the client's Connection IDs, and a
    // retired one whose RETIRE_CONNECTION_ID is owed, or -1.
    dcid_seq: i64 = 0,
    owe_retire: i64 = -1,
    state: u8 = 0,
    shaken: bool = false,
    params_read: bool = false,
    validated: bool = false,
    rx_bytes: i64 = 0,
    tx_bytes: i64 = 0,
    sp: H3Space[3],
    // 1-RTT's key phase (RFC 9001, section 6), the first packet received in
    // it, when the previous phase's keys go, and packets sealed and failed.
    phase: u8 = 0,
    phase_first: i64 = 0,
    prev_until: i64 = 0,
    sealed: i64 = 0,
    forged: i64 = 0,
    // RFC 9002's RTT estimate and NewReno.
    latest_rtt: i64 = 0,
    srtt: i64 = H3_INITIAL_RTT,
    rttvar: i64 = H3_INITIAL_RTT / 2,
    min_rtt: i64 = 0,
    has_rtt: bool = false,
    first_rtt_at: i64 = 0,
    pto_count: i64 = 0,
    cwnd: i64 = H3_INITIAL_WINDOW,
    ssthresh: i64 = 0x7fffffffffffffff,
    in_flight: i64 = 0,
    recovery_start: i64 = -1,
    // The client's transport parameters, and flow control each way: what
    // this side may send on the connection, and has sent; what the client
    // may, has, and has had taken.
    peer_params: QParams = QParams { .. },
    tx_max: i64 = 0,
    tx_total: i64 = 0,
    rx_max: i64 = H3_CONN_WINDOW,
    rx_total: i64 = 0,
    rx_read: i64 = 0,
    // Streams: the client's bidirectional ones opened, its limit, and those
    // closed, and the same for its unidirectional ones; this side's control
    // stream, and the client's control and QPACK streams; and the streams
    // open, by their index in h3strms.
    bidi_next: i64 = 0,
    bidi_max: i64 = H3_STREAMS,
    bidi_closed: i64 = 0,
    uni_next: i64 = 0,
    uni_max: i64 = H3_UNI_STREAMS,
    uni_closed: i64 = 0,
    control_out: i32 = -1,
    control_in: i32 = -1,
    encoder_in: i32 = -1,
    decoder_in: i32 = -1,
    settings_seen: bool = false,
    goaway_sent: bool = false,
    goaway_owed: bool = false,
    streams: i32[..512] = [],
    turn: i64 = 0,
    // Frames owed: HANDSHAKE_DONE, MAX_DATA, MAX_STREAMS, PATH_RESPONSE, and
    // a CONNECTION_CLOSE, with its code.
    owe_done: bool = false,
    owe_max_data: bool = false,
    owe_max_streams: bool = false,
    owe_max_uni: bool = false,
    owe_path: bool = false,
    path_data: u8[8] = [0; 8],
    owe_close: bool = false,
    close_app: bool = false,
    close_code: i64 = 0,
    close_frame: i64 = 0,
    close_sends: i64 = 0,
    close_until: i64 = 0,
    idle_at: i64 = 0,
    // Listed for a flush after this pass's datagrams, and its timer.
    touched: bool = false,
    timer_at: i64 = 0,
    // Past its idle timeout or its closing: the HTTP/3 layer's pass gives its
    // exchanges CLOSED and frees it.
    dead: bool = false,
}

reusable var h3conns: H3Conn[>..] = [];

// A connection's next timer, in a heap ordered by time; one whose connection
// has since moved its timer is skipped.
struct H3Timer { at: i64, conn: i32, gen: u32 }

// The worker's QUIC: connections by the Connection ID this side gave them,
// and by the client's first, which its Initials use until it hears this
// side's; the timers, a heap; the connections touched in a pass; and the
// datagrams received, and queued to send. A global that shrank could leave
// a reference the layers were handed dangling (spec §5.1), so these only
// grow, with the counts in use beside them, and the layers' scratch is the
// loop hooks' locals, handed down.
var h3by_cid: dictionary<u64, i32>;
var h3by_odcid: dictionary<u64, i32>;
var h3timers: H3Timer[>..] = [];
var h3timers_n: i64 = 0;
var h3touched: i32[>..] = [];
var h3touched_n: i64 = 0;
var h3rx: u8[>..] = [];
var h3rx_sizes: i32[H3_BATCH] = [0; H3_BATCH];
var h3rx_peers: UdpPeer[H3_BATCH] = [UdpPeer { len: 0, addr: [0; 28] }; H3_BATCH];
var h3q: u8[H3_TX_MAX * H3_DATAGRAM] = [0; H3_TX_MAX * H3_DATAGRAM];
var h3q_len: i64 = 0;
var h3tx_sizes: i32[H3_TX_MAX] = [0; H3_TX_MAX];
var h3tx_peers: UdpPeer[H3_TX_MAX] = [UdpPeer { len: 0, addr: [0; 28] }; H3_TX_MAX];
var h3tx_count: i64 = 0;
var h3tx_fd: i32 = -1;
var h3gso: bool = true;
var h3rng = rng { 0 };
var h3open: i64 = 0;
var h3stopping: bool = false;
// The listeners' UDP sockets, Config.port's first; -1 for one without h3.
var h3fds: i32[..MAX_LISTENERS + 1] = [];
// The most connections, as Config.max_conns.
var h3max_conns: i64 = 0;

// The keys its UDP sockets are armed with, below the listeners' tags on
// either loop; a later's key can't be one but at Config.max_conns' limit.
let H3_KEY_BASE: u64 = 0xFFFFFFFFFFFFFFF0;
fn h3_key(k: i64) -> u64 { H3_KEY_BASE - (k as u64) }

fn h3_space_key(s: i64) -> i64 { if s == 0 { tls::QUIC_INITIAL } else if s == 1 { tls::QUIC_HANDSHAKE } else { tls::QUIC_APP } }

// ---- Streams ----

fn strm_alloc(ci: i64, id: i64, kind: u8) -> i64 {
    let s = H3Strm { conn: ci as i32, id: id, kind: kind, rx: H3Rx { .. }, tx: H3Tx { .. }, .. };
    let k = h3strms.alloc_index(s);
    h3strms[k].gen = h3_next_gen();
    let c .= h3conns[ci];
    c.streams.push(k as i32);
    return k;
}

fn strm_find(c: const H3Conn&, id: i64) -> i64 {
    for k in c.streams { if h3strms[k].id == id { return k; } }
    return -1;
}

// Frees stream k, a request whose exchange is over: a client's stream
// closed gives its credit back once half of it is spent.
fn strm_close(ci: i64, k: i64) {
    let c .= h3conns[ci];
    let s .= h3strms[k];
    if s.kind == K_REQUEST {
        c.bidi_closed++;
        if c.bidi_max - c.bidi_closed <= H3_STREAMS / 2 { c.owe_max_streams = true; }
    }
    rx_free(s.rx);
    tx_free(s.tx);
    s.conn = -1;
    s.id = -1;
    var at = 0;
    while at < c.streams.len && c.streams[at] != k { at++; }
    if at < c.streams.len { c.streams.remove_at(at); }
    h3strms.free(k);
}

// ---- Connections ----

// A random 8-byte Connection ID no connection of this worker has.
fn h3_new_cid() -> u64 {
    loop {
        let v = rand_u64(h3rng);
        if v != 0 && !h3by_cid.contains(v) { return v; }
    }
}

fn h3_cid_bytes(v: u64, out: u8[..20]&) {
    out.clear();
    for i in 8 { out.push((v >> (56 - 8 * i)) as! u8); }
}

fn h3_cid_of(b: const u8[:]) -> u64 {
    var v: u64 = 0;
    for x in b[..min(b.len, 8)] { v = (v << 8) | x; }
    return v;
}

fn h3_odcid_key(b: const u8[:]) -> u64 { hash(b) }

// The transport parameters this side sends for a connection.
fn h3_params(odcid: const u8[:], cid: const u8[:], out: u8[>..]&) {
    quic_param_bytes(out, QT_ORIGINAL_DCID, odcid);
    quic_param_bytes(out, QT_INITIAL_SCID, cid);
    quic_param_int(out, QT_MAX_IDLE_TIMEOUT, H3_IDLE_MS);
    quic_param_int(out, QT_MAX_UDP_PAYLOAD_SIZE, H3_SLOT);
    quic_param_int(out, QT_INITIAL_MAX_DATA, H3_CONN_WINDOW);
    quic_param_int(out, QT_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, H3_STREAM_WINDOW);
    quic_param_int(out, QT_INITIAL_MAX_STREAM_DATA_UNI, H3_STREAM_WINDOW);
    quic_param_int(out, QT_INITIAL_MAX_STREAMS_BIDI, H3_STREAMS);
    quic_param_int(out, QT_INITIAL_MAX_STREAMS_UNI, H3_UNI_STREAMS);
    quic_param_int(out, QT_MAX_ACK_DELAY, H3_MAX_ACK_DELAY);
    qv_put(out, QT_DISABLE_ACTIVE_MIGRATION);
    qv_put(out, 0);
}

// A connection for a client's first Initial, as h3.dcid and h3.scid name
// it: its index, or -1 when the worker holds its most or TLS can't make one.
fn h3_accept(ctx: tls::Context, k: i64, h: const QHeader&, peer: const UdpPeer&, now: i64) -> i64 {
    guard h3open < h3max_conns && !h3stopping && h.dcid.len >= 8 else { return -1; }
    let cid = h3_new_cid();
    var cid_bytes: u8[..20] = [];
    h3_cid_bytes(cid, cid_bytes);
    var params: u8[>..] = [];
    h3_params(h.dcid, cid_bytes, params);
    let t = tls::quic_accept(ctx, h.dcid, params);
    guard tls::ok(t) else { return -1; }
    let ci = h3conns.alloc_index(H3Conn { sp: [H3Space { crypto_tx: H3Tx { .. }, crypto_rx: H3Rx { .. }, .. }; 3], .. });
    let c .= h3conns[ci];
    c.gen = h3_next_gen();
    c.live = true;
    c.listener = k as i32;
    c.peer = peer;
    c.t = t;
    c.cid = cid;
    for b in h.dcid { c.odcid.push(b); }
    for b in h.scid { c.client_scid.push(b); c.dcid.push(b); }
    c.odcid_key = h3_odcid_key(h.dcid);
    c.idle_at = now + H3_IDLE_MS;
    for &s in c.sp { s.crypto_rx.max = 1 << 16; }
    h3by_cid.insert(cid, ci as i32);
    h3by_odcid.insert(c.odcid_key, ci as i32);
    h3open++;
    return ci;
}

// Frees connection ci and everything it holds.
fn h3_free(ci: i64) {
    let c .= h3conns[ci];
    guard c.live else { return; }
    for s in 3 { sent_drop_space(ci, s); }
    let open = c.streams;
    for k in open { strm_close(ci, k); }
    for &s in c.sp {
        tx_free(s.crypto_tx);
        rx_free(s.crypto_rx);
    }
    tls::free(c.t);
    h3by_cid.remove(c.cid);
    let o = h3by_odcid.get(c.odcid_key);
    if o && o == ci as i32 { h3by_odcid.remove(c.odcid_key); }
    c.live = false;
    c.t = tls::Conn { .. };
    h3conns.free(ci);
    h3open--;
}

// The connection a packet's Destination Connection ID names, or -1.
fn h3_lookup(dcid: const u8[:], long: bool) -> i64 {
    if dcid.len == H3_CID_LEN {
        let k = h3by_cid.get(h3_cid_of(dcid));
        if k { return k; }
    }
    guard long else { return -1; }
    let o = h3by_odcid.get(h3_odcid_key(dcid));
    guard o else { return -1; }
    let ci: i64 = o;
    guard h3conns[ci].live && h3conns[ci].odcid == dcid else { return -1; }
    return ci;
}

// Ends connection ci with a CONNECTION_CLOSE of code (a transport one, or
// app's), and keeps it closing for three PTOs, answering what arrives with
// the close again (RFC 9000, section 10.2.1).
fn h3_close_conn(ci: i64, app: bool, code: i64, frame: i64, now: i64) {
    let c .= h3conns[ci];
    guard c.state == H3_OPEN else { return; }
    c.state = H3_CLOSING;
    c.owe_close = true;
    c.close_app = app;
    c.close_code = code;
    c.close_frame = frame;
    c.close_until = now + 3 * pto_ms(c, 2);
    h3_touch(ci);
}

fn h3_touch(ci: i64) {
    let c .= h3conns[ci];
    guard !c.touched else { return; }
    c.touched = true;
    if h3touched_n < h3touched.len { h3touched[h3touched_n] = ci as i32; } else { h3touched.push(ci as i32); }
    h3touched_n++;
}

// The timers' heap, by time, in h3timers[..h3timers_n].
fn h3_timer_push(t: H3Timer) {
    if h3timers_n < h3timers.len { h3timers[h3timers_n] = t; } else { h3timers.push(t); }
    var i = h3timers_n;
    h3timers_n++;
    while i > 0 {
        let up = (i - 1) / 2;
        guard h3timers[up].at > h3timers[i].at else { break; }
        let x = h3timers[up];
        h3timers[up] = h3timers[i];
        h3timers[i] = x;
        i = up;
    }
}

fn h3_timer_pop() -> H3Timer {
    let top = h3timers[0];
    h3timers_n--;
    h3timers[0] = h3timers[h3timers_n];
    var i = 0;
    loop {
        let l = 2 * i + 1;
        guard l < h3timers_n else { break; }
        let r = l + 1;
        let m = if r < h3timers_n && h3timers[r].at < h3timers[l].at { r } else { l };
        guard h3timers[m].at < h3timers[i].at else { break; }
        let x = h3timers[m];
        h3timers[m] = h3timers[i];
        h3timers[i] = x;
        i = m;
    }
    return top;
}

// ---- Loss recovery and congestion control (RFC 9002) ----

// The PTO's period for space s, without the backoff.
fn pto_ms(c: const H3Conn&, s: i64) -> i64 {
    var d = c.srtt + max(4 * c.rttvar, H3_GRANULARITY);
    if s == 2 { d += c.peer_params.max_ack_delay; }
    return d;
}

fn rtt_sample(c: H3Conn&, latest: i64, ack_delay: i64, now: i64) {
    c.latest_rtt = latest;
    if !c.has_rtt {
        c.has_rtt = true;
        c.min_rtt = latest;
        c.srtt = latest;
        c.rttvar = latest / 2;
        c.first_rtt_at = now;
        return;
    }
    c.min_rtt = min(c.min_rtt, latest);
    var adjusted = latest;
    let delay = if c.shaken { min(ack_delay, c.peer_params.max_ack_delay) } else { ack_delay };
    if latest >= c.min_rtt + delay { adjusted = latest - delay; }
    c.rttvar = (3 * c.rttvar + abs(c.srtt - adjusted)) / 4;
    c.srtt = (7 * c.srtt + adjusted) / 8;
}

// Appends sent packet p to the end of its space's list.
fn sent_add(ci: i64, s: i64, p: H3Sent) {
    let k = h3sent.alloc_index(p) as i32;
    let sp .= h3conns[ci].sp[s];
    if sp.tail >= 0 { h3sent[sp.tail].next = k; } else { sp.head = k; }
    sp.tail = k;
}

// Takes sent packet k, before it in prev, out of space s's list.
fn sent_unlink(ci: i64, s: i64, prev: i32, k: i32) {
    let sp .= h3conns[ci].sp[s];
    let next = h3sent[k].next;
    if prev >= 0 { h3sent[prev].next = next; } else { sp.head = next; }
    if sp.tail == k { sp.tail = prev; }
    let p .= h3sent[k];
    if p.refs_n > 0 { h3refs.free_slice(h3refs[p.refs_at..p.refs_at + p.refs_n]); }
    p.refs_n = 0;
    h3sent.free(k);
}

// Discards space s's sent packets, as its keys go: they no longer count in
// flight (RFC 9002, section 6.4).
fn sent_drop_space(ci: i64, s: i64) {
    let c .= h3conns[ci];
    var k = c.sp[s].head;
    while k >= 0 {
        let next = h3sent[k].next;
        if h3sent[k].in_flight { c.in_flight -= h3sent[k].size; }
        sent_unlink(ci, s, -1, k);
        k = next;
    }
    c.sp[s].eliciting_in_flight = 0;
    c.sp[s].loss_time = 0;
}

// A sent packet's frames, acknowledged.
fn refs_acked(ci: i64, s: i64, refs: const H3Ref[:]) {
    for r in refs {
        if r.kind == R_CRYPTO {
            tx_ack(h3conns[ci].sp[s].crypto_tx, r.off, r.off + r.len);
        } else if r.kind == R_STREAM {
            let st .= h3strms[r.stream];
            if st.conn == ci && st.gen == r.gen {
                tx_ack(st.tx, r.off, r.off + r.len);
                if r.fin { st.tx.fin_acked = true; }
            }
        }
    }
}

// A sent packet's frames, lost: sent again, with current values where they
// carry one.
fn refs_lost(ci: i64, s: i64, refs: const H3Ref[:]) {
    let c .= h3conns[ci];
    for r in refs {
        if r.kind == R_CRYPTO {
            tx_lost(c.sp[s].crypto_tx, r.off, r.off + r.len);
            continue;
        }
        if r.kind == R_HANDSHAKE_DONE { c.owe_done = true; continue; }
        if r.kind == R_MAX_DATA { c.owe_max_data = true; continue; }
        if r.kind == R_MAX_STREAMS {
            if r.fin { c.owe_max_uni = true; } else { c.owe_max_streams = true; }
            continue;
        }
        let st .= h3strms[r.stream];
        guard st.conn == ci && st.gen == r.gen else { continue; }
        match r.kind {
            R_STREAM => {
                if !st.tx_stopped {
                    if r.len > 0 { tx_lost(st.tx, r.off, r.off + r.len); }
                    if r.fin && !st.tx.fin_acked { st.tx.fin_sent = false; }
                }
            },
            R_MAX_STREAM_DATA => { st.owe_max = true; },
            R_RESET => { st.owe_reset = true; },
            R_STOP => { st.owe_stop = true; },
            _ => {},
        }
    }
}

// Space s's packets that RFC 9002's thresholds declare lost (section 6.1),
// with NewReno's response (section 7.3) and persistent congestion (7.6).
fn detect_lost(ci: i64, s: i64, now: i64) {
    let c .= h3conns[ci];
    let sp .= c.sp[s];
    sp.loss_time = 0;
    guard sp.largest_acked >= 0 else { return; }
    let delay = max((9 * max(c.latest_rtt, c.srtt)) / 8, H3_GRANULARITY);
    let lost_before = now - delay;
    var prev: i32 = -1;
    var k = sp.head;
    var any = false;
    var newest_lost: i64 = -1;
    var oldest_lost: i64 = 0x7fffffffffffffff;
    while k >= 0 {
        let p = h3sent[k];
        guard p.pn <= sp.largest_acked else { break; }
        if p.time <= lost_before || p.pn <= sp.largest_acked - H3_PACKET_THRESHOLD {
            if p.in_flight { c.in_flight -= p.size; }
            if p.eliciting {
                sp.eliciting_in_flight--;
                oldest_lost = min(oldest_lost, p.time);
                newest_lost = max(newest_lost, p.time);
            }
            refs_lost(ci, s, sent_refs(p));
            any = any || p.in_flight;
            let next = p.next;
            sent_unlink(ci, s, prev, k);
            k = next;
            continue;
        }
        let at = p.time + delay;
        sp.loss_time = if sp.loss_time == 0 { at } else { min(sp.loss_time, at) };
        prev = k;
        k = p.next;
    }
    guard any else { return; }
    if newest_lost > c.recovery_start {
        c.recovery_start = now;
        c.ssthresh = max(c.cwnd / 2, H3_MIN_WINDOW);
        c.cwnd = c.ssthresh;
    }
    let persistent = (c.srtt + max(4 * c.rttvar, H3_GRANULARITY) + c.peer_params.max_ack_delay) * 3;
    if c.has_rtt && oldest_lost > c.first_rtt_at && newest_lost - oldest_lost > persistent {
        c.cwnd = H3_MIN_WINDOW;
        c.recovery_start = now;
    }
}

// An ACK frame's ranges for space s, highest first, and its largest and
// delay: packets acknowledged leave flight, the RTT is sampled, NewReno
// grows, and the losses it reveals are detected. False for one that
// acknowledges a packet never sent, a PROTOCOL_VIOLATION.
fn on_ack(ci: i64, s: i64, ranges: const QRange[:], largest: i64, delay: i64, now: i64) -> bool {
    let c .= h3conns[ci];
    let sp .= c.sp[s];
    guard largest <= sp.largest_sent else { return false; }
    var newly_largest = false;
    var largest_time: i64 = 0;
    var largest_eliciting = false;
    var prev: i32 = -1;
    var k = sp.head;
    var acked_any = false;
    while k >= 0 {
        let p = h3sent[k];
        var hit = false;
        for g in ranges { if p.pn >= g.lo && p.pn <= g.hi { hit = true; } }
        if !hit {
            prev = k;
            k = p.next;
            continue;
        }
        acked_any = true;
        if p.pn == largest {
            newly_largest = true;
            largest_time = p.time;
            largest_eliciting = p.eliciting;
        }
        if p.in_flight {
            c.in_flight -= p.size;
            // NewReno grows outside recovery (section 7.3.2).
            if p.time > c.recovery_start {
                if c.cwnd < c.ssthresh { c.cwnd += p.size; }
                else { c.cwnd += H3_DATAGRAM * p.size / c.cwnd; }
            }
        }
        if p.eliciting { sp.eliciting_in_flight--; }
        refs_acked(ci, s, sent_refs(p));
        let next = p.next;
        sent_unlink(ci, s, prev, k);
        k = next;
    }
    guard acked_any else { return true; }
    if largest > sp.largest_acked { sp.largest_acked = largest; }
    if newly_largest && largest_eliciting {
        let exp = if s == 2 { c.peer_params.ack_delay_exponent } else { 0 };
        let delay_ms = if s == 2 { ((delay << exp) / 1000) } else { 0 };
        rtt_sample(c, max(now - largest_time, 0), delay_ms, now);
    }
    detect_lost(ci, s, now);
    // A client that still validates this side's address may be blocked by
    // the PTO's reset (section 6.2.1); a server's address needs no proof.
    c.pto_count = 0;
    return true;
}

// The connection's timer: the earliest of its ACK delay, its loss detection
// (RFC 9002, section 6.2.1), its idle timeout, its closing, and the end of
// its previous key phase.
fn h3_deadline(ci: i64, now: i64) -> i64 {
    let c .= h3conns[ci];
    if c.state != H3_OPEN { return c.close_until; }
    var at = c.idle_at;
    for s in 3 {
        let sp .= c.sp[s];
        if sp.ack_at > 0 { at = min(at, sp.ack_at); }
        if sp.loss_time > 0 { at = min(at, sp.loss_time); }
    }
    var pto: i64 = 0;
    // Before the client's address is validated, a server whose sending is
    // blocked by the anti-amplification limit arms no PTO.
    let blocked = !c.validated && c.tx_bytes >= 3 * c.rx_bytes;
    if !blocked {
        for s in 3 {
            let sp .= c.sp[s];
            if sp.eliciting_in_flight == 0 { continue; }
            if s == 2 && !c.shaken { continue; }
            let t = sp.last_eliciting + (pto_ms(c, s) << min(c.pto_count, 16));
            pto = if pto == 0 { t } else { min(pto, t) };
        }
    }
    if pto > 0 { at = min(at, pto); }
    if c.prev_until > 0 { at = min(at, c.prev_until); }
    return at;
}

// Lists connection ci's timer in the heap, if it moved.
fn h3_arm(ci: i64, now: i64) {
    let at = h3_deadline(ci, now);
    let c .= h3conns[ci];
    guard at != c.timer_at else { return; }
    c.timer_at = at;
    h3_timer_push(H3Timer { at: at, conn: ci as i32, gen: c.gen });
}

// Connection ci's timer is due: closes it past its end or its idle timeout,
// or detects losses, or sends probes for a PTO, or an ACK.
fn h3_expire(ci: i64, now: i64) {
    let c .= h3conns[ci];
    if (c.state != H3_OPEN && now >= c.close_until) || (c.state == H3_OPEN && now >= c.idle_at) {
        c.dead = true;
        h3_touch(ci);
        return;
    }
    if c.state != H3_OPEN { return; }
    if c.prev_until > 0 && now >= c.prev_until {
        tls::quic_drop(c.t, tls::QUIC_PREV);
        c.prev_until = 0;
    }
    var lost = false;
    for s in 3 {
        if c.sp[s].loss_time > 0 && now >= c.sp[s].loss_time {
            detect_lost(ci, s, now);
            lost = true;
        }
    }
    if !lost {
        // The PTO: probes in the space whose PTO came first, each with the
        // oldest data in flight sent again.
        var first = -1;
        var first_at: i64 = 0;
        for s in 3 {
            let sp .= c.sp[s];
            if sp.eliciting_in_flight == 0 || (s == 2 && !c.shaken) { continue; }
            let t = sp.last_eliciting + (pto_ms(c, s) << min(c.pto_count, 16));
            if t <= now && (first < 0 || t < first_at) {
                first = s;
                first_at = t;
            }
        }
        if first >= 0 {
            c.pto_count++;
            let sp .= c.sp[first];
            sp.probes = 2;
            let k = sp.head;
            if k >= 0 { refs_lost(ci, first, sent_refs(h3sent[k])); }
            // A handshake that's lost its flight sends all its CRYPTO again.
            if first < 2 { tx_lost(sp.crypto_tx, sp.crypto_tx.base, sp.crypto_tx.next); }
        }
    }
    h3_touch(ci);
}

// ---- Receiving ----

// The connections' generations, so a stream or sent packet of a freed one
// is told from its slot's next.
var h3gens: u32 = 0;
fn h3_next_gen() -> u32 {
    h3gens = h3gens + 1;
    return h3gens;
}

// The space a level's keys belong to.
fn h3_level_space(level: i64) -> i64 { if level == tls::QUIC_INITIAL { 0 } else if level == tls::QUIC_HANDSHAKE { 1 } else { 2 } }

// Queues what TLS has to send, as CRYPTO at its level.
fn h3_take_flight(ci: i64) {
    let c .= h3conns[ci];
    loop {
        var m: u8[>..] = [];
        let level = tls::quic_take(c.t, m);
        guard level >= 0 else { break; }
        tx_put(c.sp[h3_level_space(level)].crypto_tx, m);
    }
}

// The handshake's CRYPTO data at space s, as far as it arrived in order, fed
// to TLS: its answer queued at its levels, the client's transport parameters
// read once its ClientHello is in, and the handshake's end taken.
fn h3_crypto_in(ci: i64, s: i64, now: i64) {
    let c .= h3conns[ci];
    let ready = rx_ready(c.sp[s].crypto_rx);
    guard ready.len > 0 else { return; }
    var bytes: u8[>..] = [];
    bytes.append(ready);
    rx_take(c.sp[s].crypto_rx, bytes.len);
    let level = h3_space_key(s);
    var r = tls::quic_crypto(c.t, level, bytes);
    // A context that chooses at the ClientHello keeps this connection's.
    if r == tls::HELLO { r = tls::quic_crypto(c.t, level, ""); }
    h3_take_flight(ci);
    if r == tls::FAILED {
        h3_close_conn(ci, false, QE_CRYPTO + tls::quic_alert(c.t), QF_CRYPTO, now);
        return;
    }
    if !c.params_read {
        let pp = tls::quic_peer_params(c.t);
        if pp.len > 0 {
            c.params_read = true;
            guard quic_read_params(pp, c.peer_params, c.client_scid) else {
                h3_close_conn(ci, false, QE_TRANSPORT_PARAMETER_ERROR, 0, now);
                return;
            }
            c.tx_max = c.peer_params.initial_max_data;
            if c.peer_params.max_idle_timeout > 0 {
                c.idle_at = now + min(H3_IDLE_MS, c.peer_params.max_idle_timeout);
            }
        }
    }
    if r == 0 && !c.shaken { h3_shaken(ci, now); }
}

// The handshake is done, and so confirmed, at the server (RFC 9001, section
// 4.1.2): HANDSHAKE_DONE goes out, the Handshake keys go, and the control
// stream opens with this side's SETTINGS.
fn h3_shaken(ci: i64, now: i64) {
    let c .= h3conns[ci];
    c.shaken = true;
    c.owe_done = true;
    tls::quic_drop(c.t, tls::QUIC_HANDSHAKE);
    sent_drop_space(ci, 1);
    c.sp[1].ack_at = 0;
    c.sp[1].unacked = 0;
    c.pto_count = 0;
    guard c.peer_params.initial_max_streams_uni >= 1 else {
        h3_close_conn(ci, true, H3_STREAM_CREATION_ERROR, 0, now);
        return;
    }
    let k = strm_alloc(ci, 3, K_CONTROL_OUT);
    let st .= h3strms[k];
    st.tx.max = h3conns[ci].peer_params.initial_max_stream_data_uni;
    h3conns[ci].control_out = k as i32;
    var b: u8[>..] = [];
    qv_put(b, H3S_CONTROL);
    var settings: u8[>..] = [];
    qv_put(settings, H3_SETTING_QPACK_CAPACITY);
    qv_put(settings, 0);
    qv_put(settings, H3_SETTING_QPACK_BLOCKED);
    qv_put(settings, 0);
    qv_put(b, H3F_SETTINGS);
    qv_put(b, settings.len);
    b.append(settings);
    tx_put(st.tx, b);
}

// A STREAM frame's bytes for stream id: its stream opened as the client's
// limit allows, its final size and flow control checked (RFC 9000, sections
// 4 and 4.5), and its bytes kept for the HTTP/3 layer. A transport error
// code, or 0.
fn h3_stream_in(ci: i64, id: i64, off: i64, data: const u8[:], fin: bool) -> i64 {
    let c .= h3conns[ci];
    // The server's own streams are send-only here; it opens no bidirectional
    // one.
    guard id & 1 == 0 else { return QE_STREAM_STATE_ERROR; }
    var k = strm_find(c, id);
    if k < 0 {
        let uni = id & 2 != 0;
        let n = id >> 2;
        let next = if uni { c.uni_next } else { c.bidi_next };
        // A stream below those opened has closed.
        guard n >= next else { return 0; }
        guard n < (if uni { c.uni_max } else { c.bidi_max }) else { return QE_STREAM_LIMIT_ERROR; }
        // Opening n opens those below it too (section 2.1).
        for j in next..n + 1 {
            let kk = strm_alloc(ci, j * 4 + (id & 3), if uni { K_UNI } else { K_REQUEST });
            let s .= h3strms[kk];
            s.rx.max = H3_STREAM_WINDOW;
            s.tx.max = if uni { 0 } else { h3conns[ci].peer_params.initial_max_stream_data_bidi_local };
            if j == n { k = kk; }
        }
        let c2 .= h3conns[ci];
        if uni { c2.uni_next = n + 1; } else { c2.bidi_next = n + 1; }
    }
    let c3 .= h3conns[ci];
    let st .= h3strms[k];
    let end = off + data.len;
    guard end <= QUIC_VARINT_MAX else { return QE_FRAME_ENCODING_ERROR; }
    if st.rx.fin >= 0 {
        guard end <= st.rx.fin && (!fin || end == st.rx.fin) else { return QE_FINAL_SIZE_ERROR; }
    }
    if fin {
        guard end >= st.rx.high else { return QE_FINAL_SIZE_ERROR; }
        st.rx.fin = end;
    }
    let grew = max(end - st.rx.high, 0);
    c3.rx_total += grew;
    guard c3.rx_total <= c3.rx_max else { return QE_FLOW_CONTROL_ERROR; }
    if st.rx_stopped {
        st.rx.high = max(st.rx.high, end);
        guard st.rx.high <= st.rx.max else { return QE_FLOW_CONTROL_ERROR; }
        c3.rx_read += grew;
        return 0;
    }
    guard rx_put(st.rx, off, data) else { return QE_FLOW_CONTROL_ERROR; }
    st.readable = true;
    return 0;
}

// Bytes the HTTP/3 layer took from stream k: credit goes back to the client
// once half a window is spent, on the stream and on the connection.
fn h3_consumed(ci: i64, k: i64, n: i64) {
    guard n > 0 else { return; }
    let c .= h3conns[ci];
    let st .= h3strms[k];
    c.rx_read += n;
    if c.rx_max - c.rx_read < H3_CONN_WINDOW / 2 {
        c.rx_max = c.rx_read + H3_CONN_WINDOW;
        c.owe_max_data = true;
    }
    if st.rx.fin < 0 && st.rx.max - st.rx.read < H3_STREAM_WINDOW / 2 {
        st.rx.max = st.rx.read + H3_STREAM_WINDOW;
        st.owe_max = true;
    }
}

// A packet's frames (RFC 9000, section 19), in space s: whether any was
// ack-eliciting. A frame that breaks the protocol closes the connection.
fn h3_frames(ci: i64, s: i64, b: const u8[:], now: i64) -> bool {
    var r = QRd { at: 0, bad: false };
    var eliciting = false;

    fn fail(code: i64, frame: i64) {
        h3_close_conn(ci, false, code, frame, now);
        r.at = b.len;
    }

    while r.at < b.len {
        let t = qv(b, r);
        guard !r.bad else {
            fail(QE_FRAME_ENCODING_ERROR, 0);
            break;
        }
        if t != QF_PADDING && t != QF_ACK && t != QF_ACK_ECN && t != QF_CONNECTION_CLOSE && t != QF_CONNECTION_CLOSE_APP {
            eliciting = true;
        }
        // Initial and Handshake packets carry only these (section 12.4).
        if s < 2 && t != QF_PADDING && t != QF_PING && t != QF_ACK && t != QF_ACK_ECN && t != QF_CRYPTO &&
           t != QF_CONNECTION_CLOSE {
            fail(QE_PROTOCOL_VIOLATION, t);
            break;
        }
        if t == QF_PADDING {
            while r.at < b.len && b[r.at] == 0 { r.at++; }
        } else if t == QF_PING {
        } else if t == QF_ACK || t == QF_ACK_ECN {
            var ranges: QRange[..64] = [];
            let largest, delay, ok = quic_read_ack(b, r, t == QF_ACK_ECN) { lo, hi =>
                if ranges.len < 64 { ranges.push(QRange { lo: lo, hi: hi }); }
            };
            guard ok else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
            guard on_ack(ci, s, ranges, largest, delay, now) else { fail(QE_PROTOCOL_VIOLATION, t); break; }
        } else if t == QF_CRYPTO {
            let off = qv(b, r);
            let data = qtake(b, r, qv(b, r));
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
            guard rx_put(h3conns[ci].sp[s].crypto_rx, off, data) else { fail(QE_CRYPTO_BUFFER_EXCEEDED, t); break; }
            h3_crypto_in(ci, s, now);
        } else if t >= QF_STREAM && t <= 0x0f {
            let id = qv(b, r);
            let off = if t & 0x04 != 0 { qv(b, r) } else { 0 };
            let len = if t & 0x02 != 0 { qv(b, r) } else { b.len - r.at };
            let data = qtake(b, r, len);
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
            let e = h3_stream_in(ci, id, off, data, t & 0x01 != 0);
            guard e == 0 else { fail(e, t); break; }
        } else if t == QF_RESET_STREAM {
            let id = qv(b, r);
            let code = qv(b, r);
            let final = qv(b, r);
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
            let e = h3_reset_in(ci, id, code, final);
            guard e == 0 else { fail(e, t); break; }
        } else if t == QF_STOP_SENDING {
            let id = qv(b, r);
            let code = qv(b, r);
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
            guard id & 3 != 2 else { fail(QE_STREAM_STATE_ERROR, t); break; }
            let k = strm_find(h3conns[ci], id);
            if k >= 0 && !h3strms[k].tx_stopped {
                let st .= h3strms[k];
                st.tx_stopped = true;
                st.owe_reset = true;
                st.reset_code = code;
                st.tx.lost.s.clear();
                st.readable = true;
            }
        } else if t == QF_MAX_DATA {
            let v = qv(b, r);
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
            let c .= h3conns[ci];
            c.tx_max = max(c.tx_max, v);
        } else if t == QF_MAX_STREAM_DATA {
            let id = qv(b, r);
            let v = qv(b, r);
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
            guard id & 3 != 2 else { fail(QE_STREAM_STATE_ERROR, t); break; }
            let k = strm_find(h3conns[ci], id);
            if k >= 0 { h3strms[k].tx.max = max(h3strms[k].tx.max, v); }
        } else if t == QF_MAX_STREAMS_BIDI || t == QF_MAX_STREAMS_UNI {
            let v = qv(b, r);
            guard !r.bad && v <= 1 << 60 else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
        } else if t == QF_DATA_BLOCKED || t == QF_STREAMS_BLOCKED_BIDI || t == QF_STREAMS_BLOCKED_UNI {
            qv(b, r);
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
        } else if t == QF_STREAM_DATA_BLOCKED {
            qv(b, r);
            qv(b, r);
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
        } else if t == QF_NEW_CONNECTION_ID {
            let seq = qv(b, r);
            let retire = qv(b, r);
            let n = qbyte(b, r);
            let cid = qtake(b, r, n);
            qtake(b, r, 16);
            guard !r.bad && n >= 1 && n <= 20 && retire <= seq else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
            let c .= h3conns[ci];
            // The client asks for the one in use to go: move to this one.
            if retire > c.dcid_seq && seq >= retire {
                c.owe_retire = c.dcid_seq;
                c.dcid_seq = seq;
                c.dcid.clear();
                for x in cid { c.dcid.push(x); }
            }
        } else if t == QF_RETIRE_CONNECTION_ID {
            let seq = qv(b, r);
            guard !r.bad && seq == 0 else { fail(QE_PROTOCOL_VIOLATION, t); break; }
        } else if t == QF_PATH_CHALLENGE {
            let data = qtake(b, r, 8);
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
            let c .= h3conns[ci];
            for x, i in data { c.path_data[i] = x; }
            c.owe_path = true;
        } else if t == QF_PATH_RESPONSE {
            qtake(b, r, 8);
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
        } else if t == QF_CONNECTION_CLOSE || t == QF_CONNECTION_CLOSE_APP {
            qv(b, r);
            if t == QF_CONNECTION_CLOSE { qv(b, r); }
            qtake(b, r, qv(b, r));
            guard !r.bad else { fail(QE_FRAME_ENCODING_ERROR, t); break; }
            // The client closed: drain for three PTOs, sending nothing
            // (section 10.2.2).
            let c .= h3conns[ci];
            c.state = H3_DRAINING;
            c.close_until = now + 3 * pto_ms(c, 2);
            break;
        } else if t == QF_NEW_TOKEN || t == QF_HANDSHAKE_DONE {
            // Only a server sends these.
            fail(QE_PROTOCOL_VIOLATION, t);
            break;
        } else {
            fail(QE_FRAME_ENCODING_ERROR, t);
            break;
        }
        guard h3conns[ci].state == H3_OPEN else { break; }
    }
    return eliciting;
}

// A client's RESET_STREAM: the rest of the request won't come. A transport
// error code, or 0.
fn h3_reset_in(ci: i64, id: i64, code: i64, final: i64) -> i64 {
    guard id & 1 == 0 else { return QE_STREAM_STATE_ERROR; }
    let c .= h3conns[ci];
    let k = strm_find(c, id);
    guard k >= 0 else { return 0; }
    let st .= h3strms[k];
    guard final >= st.rx.high && (st.rx.fin < 0 || st.rx.fin == final) else { return QE_FINAL_SIZE_ERROR; }
    guard final <= st.rx.max else { return QE_FLOW_CONTROL_ERROR; }
    let grew = final - st.rx.high;
    c.rx_total += grew;
    c.rx_read += grew + (st.rx.high - st.rx.read);
    guard c.rx_total <= c.rx_max else { return QE_FLOW_CONTROL_ERROR; }
    st.rx.high = final;
    st.rx.fin = final;
    st.rx.read = final;
    st.rx.got.s.clear();
    st.rx_stopped = true;
    st.reset_code = code;
    st.readable = true;
    return 0;
}

// One packet of a datagram, pkt, whose packet number starts at pn_at: its
// protection taken off, its number decoded, and its frames taken (RFC 9000,
// section 12; RFC 9001, section 5).
fn h3_packet(ci: i64, h: const QHeader&, pkt: u8[:], pn_at: i64, now: i64) {
    let c .= h3conns[ci];
    guard c.state != H3_DRAINING else { return; }
    if c.state == H3_CLOSING {
        // Answered with the close again, less often as more arrive.
        c.close_sends++;
        if c.close_sends & (c.close_sends - 1) == 0 {
            c.owe_close = true;
            h3_touch(ci);
        }
        return;
    }
    // 0-RTT is never accepted: its packets are dropped.
    let s = if !h.long { 2 } else if h.kind == QP_INITIAL { 0 } else if h.kind == QP_HANDSHAKE { 1 } else { -1 };
    guard s >= 0 else { return; }
    var key = h3_space_key(s);
    guard tls::quic_has(c.t, key) else { return; }
    let first = tls::quic_unprotect(c.t, key, pkt, pn_at);
    guard first >= 0 else { return; }
    let pn_len = (first & 3) + 1;
    var truncated: i64 = 0;
    for i in pn_len { truncated = (truncated << 8) | pkt[pn_at + i]; }
    let sp .= c.sp[s];
    let pn = quic_decode_pn(quic_ranges_largest(sp.recv), truncated, pn_len);
    let hdr = pn_at + pn_len;
    var updating = false;
    if s == 2 && ((first >> 2) & 1) as! u8 != c.phase {
        if c.prev_until > 0 && pn < c.phase_first {
            key = tls::QUIC_PREV;
        } else {
            guard tls::quic_next(c.t) else { return; }
            key = tls::QUIC_NEXT;
            updating = true;
        }
    }
    let n = tls::quic_open(c.t, key, pkt, hdr, pn);
    if n < 0 {
        c.forged++;
        if c.forged >= H3_FORGERIES { h3_close_conn(ci, false, QE_AEAD_LIMIT_REACHED, 0, now); }
        return;
    }
    let reserved = if h.long { first & 0x0c } else { first & 0x18 };
    guard reserved == 0 else {
        h3_close_conn(ci, false, QE_PROTOCOL_VIOLATION, 0, now);
        return;
    }
    if updating {
        // The client updated its keys: this side follows (RFC 9001, section
        // 6.2), keeping the old phase's for late packets for three PTOs.
        tls::quic_rotate(c.t);
        c.phase = 1 - c.phase;
        c.phase_first = pn;
        c.prev_until = now + 3 * pto_ms(c, 2);
        c.sealed = 0;
    }
    let largest = quic_ranges_largest(sp.recv);
    guard quic_ranges_add(sp.recv, pn) else { return; }
    if pn > largest { sp.largest_at = now; }
    if s == 1 && !c.validated {
        // A Handshake packet proves the client's address, and that it has
        // the Handshake keys, so the Initial ones go (RFC 9001, section 4.9.1).
        c.validated = true;
        tls::quic_drop(c.t, tls::QUIC_INITIAL);
        sent_drop_space(ci, 0);
        c.sp[0].ack_at = 0;
        c.sp[0].unacked = 0;
        c.pto_count = 0;
    }
    c.idle_at = now + max(if c.peer_params.max_idle_timeout > 0 { min(H3_IDLE_MS, c.peer_params.max_idle_timeout) } else { H3_IDLE_MS },
                          3 * pto_ms(c, 2));
    let eliciting = h3_frames(ci, s, pkt[hdr..hdr + n], now);
    let c2 .= h3conns[ci];
    if eliciting && c2.state == H3_OPEN {
        let sp2 .= c2.sp[s];
        sp2.unacked++;
        // Initial and Handshake packets, every second packet, and one out of
        // order are acknowledged at once (RFC 9000, section 13.2.1); others
        // within max_ack_delay.
        if s < 2 || sp2.unacked >= 2 || pn < largest { sp2.ack_at = now; }
        else if sp2.ack_at == 0 { sp2.ack_at = now + H3_MAX_ACK_DELAY; }
    }
    h3_touch(ci);
}

// Answers a client that offers another version with the one this side
// speaks (RFC 9000, section 6).
fn h3_version_negotiation(h3tx: u8[>..]&, k: i64, h: const QHeader&, peer: const UdpPeer&) {
    guard h3_tx_begin(k, peer) else { return; }
    h3tx.clear();
    h3tx.push((0x80 | (rand_u64(h3rng) & 0x7f)) as! u8);
    for i in 4 { h3tx.push(0); }
    h3tx.push(h.scid.len as! u8);
    h3tx.append(h.scid);
    h3tx.push(h.dcid.len as! u8);
    h3tx.append(h.dcid);
    for i in 3 { h3tx.push(0); }
    h3tx.push(1);
    h3_tx_end(k, peer, h3tx);
}

// A datagram received on listener k from peer: each packet it coalesces
// (RFC 9000, section 12.2), the first Initial of a new connection accepted.
// h3tx is scratch for an answer to another version.
fn h3_datagram<S>(h3tx: u8[>..]&, srv: H3ServerOf<S>&, k: i64, d: u8[:], peer: const UdpPeer&, now: i64) {
    var at = 0;
    var ci: i64 = -1;
    while at < d.len {
        let h, ok = quic_header(d, at, H3_CID_LEN);
        guard ok else { break; }
        if h.long && h.version != QUIC_V1 {
            if at == 0 && d.len >= 1200 && h.version != 0 { h3_version_negotiation(h3tx, k, h, peer); }
            break;
        }
        let found = h3_lookup(h.dcid, h.long);
        if ci < 0 {
            ci = found;
            if ci < 0 {
                // A client's first Initial comes in a datagram of at least
                // 1,200 bytes (section 14.1).
                guard h.long && h.kind == QP_INITIAL && d.len >= 1200 else { break; }
                ci = h3_accept(srv.ctx, k, h, peer, now);
                guard ci >= 0 else { break; }
            }
            let c .= h3conns[ci];
            // The client may not move: this side disabled migration.
            let n = peer.len as i64;
            guard c.peer.len == peer.len && n <= 28 && c.peer.addr[..n] == peer.addr[..n] && c.listener == k else { break; }
            c.rx_bytes += d.len;
        } else if found != ci {
            break;
        }
        let end = h.end;
        h3_packet(ci, h, d[at..end], h.pn_at - at, now);
        at = end;
        guard h3conns[ci].live else { break; }
    }
}

// ---- Sending ----

// Sends the datagrams queued, in one call where the kernel takes them all:
// those it doesn't take wait for the next. GSO goes off for good where the
// kernel can't segment.
fn h3_send_now() {
    guard h3tx_count > 0 else { return; }
    var r = net_udp_send(h3tx_fd, h3q[..h3q_len], h3tx_sizes[..h3tx_count], h3tx_peers[..h3tx_count], h3gso);
    if (r == -EINVAL || r == -EIO) && h3gso {
        h3gso = false;
        r = net_udp_send(h3tx_fd, h3q[..h3q_len], h3tx_sizes[..h3tx_count], h3tx_peers[..h3tx_count], false);
    }
    guard r > 0 else { return; }
    if r >= h3tx_count {
        h3q_len = 0;
        h3tx_count = 0;
        return;
    }
    // Keep the rest, at the front.
    var sent = 0;
    for i in r { sent += h3tx_sizes[i]; }
    let rest = h3q_len - sent;
    for i in rest { h3q[i] = h3q[sent + i]; }
    h3q_len = rest;
    for i in h3tx_count - r {
        h3tx_sizes[i] = h3tx_sizes[r + i];
        h3tx_peers[i] = h3tx_peers[r + i];
    }
    h3tx_count -= r;
}

// Room for a datagram on listener k's socket: false when the queue is full
// and the kernel takes none of it.
fn h3_tx_begin(k: i64, peer: const UdpPeer&) -> bool {
    let fd = h3fds[k];
    if h3tx_count > 0 && h3tx_fd != fd { h3_send_now(); }
    if h3tx_count == H3_TX_MAX { h3_send_now(); }
    guard h3tx_count < H3_TX_MAX && (h3tx_count == 0 || h3tx_fd == fd) else { return false; }
    h3tx_fd = fd;
    return true;
}

// Queues datagram dg, at most H3_DATAGRAM bytes, for peer, once
// h3_tx_begin made room.
fn h3_tx_end(k: i64, peer: const UdpPeer&, dg: const u8[:]) {
    copy_into(h3q[h3q_len..h3q_len + dg.len], dg);
    h3q_len += dg.len;
    h3tx_sizes[h3tx_count] = dg.len as i32;
    h3tx_peers[h3tx_count] = peer;
    h3tx_count++;
}

// A packet laid out in a datagram before it's sealed: its space, where it
// starts, where its Length and packet number are, the number, and where its
// payload ends, before the tag's 16 bytes.
struct H3Built {
    space: i64,
    at: i64,
    len_at: i64,
    pn_at: i64,
    pn_len: i64,
    pn: i64,
    end: i64,
    eliciting: bool,
    padded: bool,
    refs_at: i64,
    refs_len: i64,
}

// Appends n as a big-endian number of k bytes.
fn put_be(w: u8[>..]&, n: i64, k: i64) {
    for i in k { w.push((n >> (8 * (k - 1 - i))) as! u8); }
}

fn h3_ref(h3refs_now: H3Ref[>..]&, kind: u8, stream: i64, gen: u32, off: i64, len: i64, fin: bool) {
    h3refs_now.push(H3Ref { kind: kind, fin: fin, stream: stream as i32, gen: gen, off: off, len: len });
}

// Writes CRYPTO or STREAM frames for t into the packet, up to end: what was
// lost first, then what's never been sent. For a stream, id is its ID and
// credit what the connection's flow control lets it send new; for CRYPTO,
// id is -1. Returns the new bytes sent, and whether it wrote any frame.
fn h3_data_frames(h3tx: u8[>..]&, h3refs_now: H3Ref[>..]&, t: H3Tx&, id: i64, k: i64, gen: u32, end: i64,
                  credit: i64) -> i64, bool {
    var wrote = false;
    // Lost ranges first.
    while t.lost.s.len > 0 {
        let g = t.lost.s[0];
        let room = end - h3tx.len;
        let head = if id < 0 { 1 + qv_len(g.lo) + qv_len(room) } else { quic_stream_head_len(id, g.lo, room) };
        guard room > head else { return 0, wrote; }
        let n = min(g.hi - g.lo, room - head);
        let fin = id >= 0 && t.fin && g.lo + n == t.end;
        if id < 0 { quic_write_crypto_head(h3tx, g.lo, n); } else { quic_write_stream_head(h3tx, id, g.lo, n, fin); }
        h3tx.append(tx_bytes(t, g.lo, g.lo + n));
        h3_ref(h3refs_now,if id < 0 { R_CRYPTO } else { R_STREAM }, k, gen, g.lo, n, fin);
        if fin { t.fin_sent = true; }
        spans_remove(t.lost, g.lo, g.lo + n);
        wrote = true;
    }
    var fresh = 0;
    let limit = if id < 0 { t.end } else { min(min(t.end, t.max), t.next + credit) };
    while t.next < limit || (id >= 0 && t.fin && !t.fin_sent && t.next == t.end) {
        let room = end - h3tx.len;
        let head = if id < 0 { 1 + qv_len(t.next) + qv_len(room) } else { quic_stream_head_len(id, t.next, room) };
        guard room > head || (room == head && t.next == t.end) else { break; }
        let n = min(limit - t.next, room - head);
        let fin = id >= 0 && t.fin && t.next + n == t.end;
        if id < 0 { quic_write_crypto_head(h3tx, t.next, n); } else { quic_write_stream_head(h3tx, id, t.next, n, fin); }
        h3tx.append(tx_bytes(t, t.next, t.next + n));
        h3_ref(h3refs_now,if id < 0 { R_CRYPTO } else { R_STREAM }, k, gen, t.next, n, fin);
        if fin { t.fin_sent = true; }
        t.next += n;
        fresh += n;
        wrote = true;
        if n == 0 { break; }
    }
    return fresh, wrote;
}

// Lays out one packet of space s for connection ci at h3tx's end, in at
// most room bytes: an ACK, when one is owed, and what it has to send that
// its flow control, its congestion window, and the anti-amplification limit
// allow. False, with nothing written, when there's nothing to send.
fn h3_packet_out(h3tx: u8[>..]&, h3refs_now: H3Ref[>..]&, ci: i64, s: i64, room: i64, now: i64,
                 built: H3Built[..3]&) -> bool {
    let c .= h3conns[ci];
    let sp .= c.sp[s];
    let at = h3tx.len;
    let pn = sp.next_pn;
    let pn_len = quic_pn_len(pn, sp.largest_acked);
    var len_at: i64 = -1;
    if s < 2 {
        h3tx.push((0xc0 | ((if s == 0 { QP_INITIAL } else { QP_HANDSHAKE }) << 4) | (pn_len - 1)) as! u8);
        put_be(h3tx, QUIC_V1, 4);
        h3tx.push(c.dcid.len as! u8);
        h3tx.append(c.dcid);
        h3tx.push(H3_CID_LEN);
        put_be(h3tx, c.cid as! i64, H3_CID_LEN);
        if s == 0 { h3tx.push(0); }
        len_at = h3tx.len;
        h3tx.push(0x40);
        h3tx.push(0);
    } else {
        h3tx.push((0x40 | ((c.phase as i64) << 2) | (pn_len - 1)) as! u8);
        h3tx.append(c.dcid);
    }
    let pn_at = h3tx.len;
    put_be(h3tx, pn, pn_len);
    let payload = h3tx.len;
    let end = at + room - 16;
    guard end > payload + 8 else {
        h3tx.resize(at, 0);
        return false;
    }
    h3refs_now.clear();
    var acked = false;
    if sp.unacked > 0 && sp.recv.r.len > 0 {
        quic_write_ack(h3tx, sp.recv, max(now - sp.largest_at, 0) * 1000);
        acked = true;
    }
    let ack_end = h3tx.len;
    // What's ack-eliciting goes within the congestion window, unless a PTO
    // asked for probes (RFC 9002, section 7).
    let window = if sp.probes > 0 { room } else { c.cwnd - c.in_flight };
    let eliciting_end = if window >= H3_DATAGRAM / 2 { end } else { payload };
    if s == 2 && h3tx.len < eliciting_end - 16 {
        if c.owe_done {
            h3tx.push(QF_HANDSHAKE_DONE);
            h3_ref(h3refs_now,R_HANDSHAKE_DONE, -1, 0, 0, 0, false);
            c.owe_done = false;
        }
        if c.owe_max_data {
            quic_write_frame1(h3tx, QF_MAX_DATA, c.rx_max);
            h3_ref(h3refs_now,R_MAX_DATA, -1, 0, 0, 0, false);
            c.owe_max_data = false;
        }
        if c.owe_max_streams {
            c.bidi_max = c.bidi_closed + H3_STREAMS;
            quic_write_frame1(h3tx, QF_MAX_STREAMS_BIDI, c.bidi_max);
            h3_ref(h3refs_now,R_MAX_STREAMS, -1, 0, 0, 0, false);
            c.owe_max_streams = false;
        }
        if c.owe_max_uni {
            quic_write_frame1(h3tx, QF_MAX_STREAMS_UNI, c.uni_max);
            h3_ref(h3refs_now,R_MAX_STREAMS, -1, 0, 0, 0, true);
            c.owe_max_uni = false;
        }
        if c.owe_path {
            h3tx.push(QF_PATH_RESPONSE);
            h3tx.append(c.path_data);
            c.owe_path = false;
        }
        if c.owe_retire >= 0 {
            quic_write_frame1(h3tx, QF_RETIRE_CONNECTION_ID, c.owe_retire);
            c.owe_retire = -1;
        }
        for k in c.streams {
            let st .= h3strms[k];
            if h3tx.len >= eliciting_end - 32 { break; }
            if st.owe_max {
                quic_write_frame2(h3tx, QF_MAX_STREAM_DATA, st.id, st.rx.max);
                h3_ref(h3refs_now,R_MAX_STREAM_DATA, k, st.gen, 0, 0, false);
                st.owe_max = false;
            }
            if st.owe_stop {
                quic_write_frame2(h3tx, QF_STOP_SENDING, st.id, st.stop_code);
                h3_ref(h3refs_now,R_STOP, k, st.gen, 0, 0, false);
                st.owe_stop = false;
            }
            if st.owe_reset {
                h3tx.push(QF_RESET_STREAM);
                qv_put(h3tx, st.id);
                qv_put(h3tx, st.reset_code);
                qv_put(h3tx, st.tx.next);
                h3_ref(h3refs_now,R_RESET, k, st.gen, 0, 0, false);
                st.owe_reset = false;
            }
        }
    }
    // CRYPTO: the handshake's, and at 1-RTT the session tickets.
    if h3tx.len < eliciting_end - 16 && tx_pending(sp.crypto_tx) {
        h3_data_frames(h3tx, h3refs_now, sp.crypto_tx, -1, s, 0, eliciting_end, 0);
    }
    // The streams' data, each in turn.
    if s == 2 && c.shaken {
        let n = c.streams.len;
        var j = 0;
        while j < n && h3tx.len < eliciting_end - 16 {
            let k: i64 = c.streams[(c.turn + j) % n];
            j++;
            let st .= h3strms[k];
            if st.tx_stopped || !tx_pending(st.tx) { continue; }
            let fresh, wrote = h3_data_frames(h3tx, h3refs_now, st.tx, st.id, k, st.gen, eliciting_end,
                                              c.tx_max - c.tx_total);
            c.tx_total += fresh;
        }
        if n > 0 { c.turn = (c.turn + 1) % n; }
    }
    var eliciting = h3tx.len > ack_end;
    if !eliciting && sp.probes > 0 && h3tx.len < end {
        h3tx.push(QF_PING);
        eliciting = true;
    }
    // Nothing, or an ACK that isn't due yet: no packet.
    if !eliciting && (!acked || sp.ack_at == 0 || sp.ack_at > now) {
        h3tx.resize(at, 0);
        return false;
    }
    // The header protection's sample needs the packet number and payload to
    // make 4 bytes (RFC 9001, section 5.4.2).
    while h3tx.len - pn_at < 4 { h3tx.push(QF_PADDING); }
    let payload_end = h3tx.len;
    for i in 16 { h3tx.push(0); }
    if acked {
        sp.unacked = 0;
        sp.ack_at = 0;
    }
    if eliciting && sp.probes > 0 { sp.probes--; }
    sp.next_pn++;
    let refs_at = h3refs_now.len;
    built.push(H3Built { space: s, at: at, len_at: len_at, pn_at: pn_at, pn_len: pn_len, pn: pn, end: payload_end,
                         eliciting: eliciting, padded: false, refs_at: 0, refs_len: refs_at });
    return true;
}

// Seals the packets laid out in a datagram and records them as sent.
fn h3_seal(h3tx: u8[>..]&, ci: i64, built: H3Built[..3]&, refs: const H3Ref[:], now: i64) {
    let c .= h3conns[ci];
    var used = 0;
    for b in built {
        let size = b.end + 16 - b.at;
        if b.len_at >= 0 { qv_put2_at(h3tx, b.len_at, b.end + 16 - b.pn_at); }
        let key = h3_space_key(b.space);
        tls::quic_seal(c.t, key, h3tx[b.at..b.end + 16], b.pn_at - b.at + b.pn_len, b.pn_len, b.pn);
        let sp .= c.sp[b.space];
        sp.largest_sent = b.pn;
        let in_flight = b.eliciting || b.padded;
        var at: i64 = 0;
        if b.refs_len > 0 {
            let r = h3refs.alloc_slice(b.refs_len);
            copy_into(r, refs[used..used + b.refs_len]);
            at = h3refs.index_of(r[0]);
        }
        used += b.refs_len;
        sent_add(ci, b.space, H3Sent { conn: ci as i32, gen: c.gen, pn: b.pn, time: now, size: size,
                                        eliciting: b.eliciting, in_flight: in_flight, refs_at: at, refs_n: b.refs_len });
        if b.eliciting {
            sp.last_eliciting = now;
            sp.eliciting_in_flight++;
        }
        if in_flight { c.in_flight += size; }
        if b.space == 2 { c.sealed++; }
    }
}

// Lays out, seals, and queues one datagram of connection ci, in h3tx, with
// its packets' frames in refs: false when it has nothing to send now.
fn h3_datagram_out(h3tx: u8[>..]&, h3refs_now: H3Ref[>..]&, refs: H3Ref[>..]&, ci: i64, now: i64) -> bool {
    let c .= h3conns[ci];
    guard h3_tx_begin(c.listener, c.peer) else { return false; }
    h3tx.clear();
    refs.clear();
    let start = 0;
    var room = H3_DATAGRAM;
    // Until the client's address is validated, at most three times what it
    // sent (RFC 9000, section 8.1).
    if !c.validated { room = min(room, 3 * c.rx_bytes - c.tx_bytes); }
    guard room >= 64 else { return false; }
    var built: H3Built[..3] = [];
    for s in 3 {
        let used = h3tx.len - start;
        if room - used < 64 { break; }
        if !tls::quic_can_seal(c.t, h3_space_key(s)) { continue; }
        let before = built.len;
        if h3_packet_out(h3tx, h3refs_now, ci, s, room - used, now, built) {
            built[before].refs_at = refs.len;
            refs.append(h3refs_now);
        }
    }
    guard built.len > 0 else { return false; }
    // A datagram with an ack-eliciting Initial is padded to 1,200 bytes
    // (RFC 9000, section 14.1), in its last packet before the tag.
    var initial = false;
    for b in built { initial = initial || (b.space == 0 && b.eliciting); }
    let size = h3tx.len - start;
    if initial && size < H3_DATAGRAM {
        let extra = H3_DATAGRAM - size;
        let last .= built[built.len - 1];
        for i in extra { h3tx.push(0); }
        last.end += extra;
        last.padded = true;
    }
    h3_seal(h3tx, ci, built, refs, now);
    h3conns[ci].tx_bytes += h3tx.len;
    h3_tx_end(c.listener, c.peer, h3tx);
    // The AEAD's limit closes the connection rather than wait on a key
    // update (RFC 9001, section 6.6).
    if h3conns[ci].sealed >= H3_AEAD_PACKETS { h3_close_conn(ci, false, QE_AEAD_LIMIT_REACHED, 0, now); }
    return true;
}

// The CONNECTION_CLOSE of a connection that's closing, at each level it has
// keys for: an application's close goes as a transport APPLICATION_ERROR
// (0x0c) outside 1-RTT (RFC 9000, section 10.2.3).
fn h3_close_out(h3tx: u8[>..]&, ci: i64, now: i64) {
    let c .= h3conns[ci];
    guard h3_tx_begin(c.listener, c.peer) else { return; }
    h3tx.clear();
    var built: H3Built[..3] = [];
    for s in 3 {
        if !tls::quic_can_seal(c.t, h3_space_key(s)) { continue; }
        if s == 2 && !c.shaken { continue; }
        let sp .= c.sp[s];
        let at = h3tx.len;
        let pn = sp.next_pn;
        let pn_len = quic_pn_len(pn, sp.largest_acked);
        var len_at: i64 = -1;
        if s < 2 {
            h3tx.push((0xc0 | ((if s == 0 { QP_INITIAL } else { QP_HANDSHAKE }) << 4) | (pn_len - 1)) as! u8);
            put_be(h3tx, QUIC_V1, 4);
            h3tx.push(c.dcid.len as! u8);
            h3tx.append(c.dcid);
            h3tx.push(H3_CID_LEN);
            put_be(h3tx, c.cid as! i64, H3_CID_LEN);
            if s == 0 { h3tx.push(0); }
            len_at = h3tx.len;
            h3tx.push(0x40);
            h3tx.push(0);
        } else {
            h3tx.push((0x40 | ((c.phase as i64) << 2) | (pn_len - 1)) as! u8);
            h3tx.append(c.dcid);
        }
        let pn_at = h3tx.len;
        put_be(h3tx, pn, pn_len);
        let app = c.close_app && s == 2;
        let code = if c.close_app && s < 2 { 0x0c } else { c.close_code };
        quic_write_close(h3tx, app, code, c.close_frame);
        while h3tx.len - pn_at < 4 { h3tx.push(QF_PADDING); }
        let payload_end = h3tx.len;
        for i in 16 { h3tx.push(0); }
        sp.next_pn++;
        built.push(H3Built { space: s, at: at, len_at: len_at, pn_at: pn_at, pn_len: pn_len, pn: pn, end: payload_end,
                             eliciting: false, padded: false, refs_at: 0, refs_len: 0 });
    }
    guard built.len > 0 else { return; }
    for b in built {
        if b.len_at >= 0 { qv_put2_at(h3tx, b.len_at, b.end + 16 - b.pn_at); }
        tls::quic_seal(c.t, h3_space_key(b.space), h3tx[b.at..b.end + 16], b.pn_at - b.at + b.pn_len, b.pn_len, b.pn);
    }
    h3_tx_end(c.listener, c.peer, h3tx);
}

// Sends what connection ci has, as many datagrams as it takes, each laid out
// in dg, with its packets' frames in refs.
fn h3_flush(ci: i64, now: i64) {
    var dg: u8[>..] = [];
    var refs_now: H3Ref[>..] = [];
    var refs: H3Ref[>..] = [];
    let c .= h3conns[ci];
    if c.state == H3_DRAINING { return; }
    if c.state == H3_CLOSING {
        if c.owe_close {
            c.owe_close = false;
            h3_close_out(dg, ci, now);
        }
        return;
    }
    for i in 256 {
        guard h3conns[ci].live && h3conns[ci].state == H3_OPEN && h3_datagram_out(dg, refs_now, refs, ci, now) else {
            break;
        }
    }
    let c2 .= h3conns[ci];
    if c2.live && c2.state == H3_CLOSING && c2.owe_close {
        c2.owe_close = false;
        h3_close_out(dg, ci, now);
    }
}

// ---- HTTP/3 ----

// A request stream's HTTP/3 state and its exchange, by the stream's index in
// h3strms: the frame being read, the request kept while its body gathers,
// as h2 gathers one, and the response's head while begin keeps it open.
struct H3Ex<S> {
    data_left: i64 = 0,
    skip_left: i64 = 0,
    headers: bool = false,
    called: bool = false,
    gathering: bool = false,
    length: i64 = -1,
    received: i64 = 0,
    method_len: i64 = 0,
    target_len: i64 = 0,
    rq: u8[:],
    held: u8[:],
    trailers: u8[:],
    head: u8[:],
    headers_sent: bool = false,
    ended: bool = false,
    x: Exchange<S>,
}

// A worker's HTTP/3: the context its connections are accepted from, and each
// request stream's exchange, by its stream's index.
struct H3ServerOf<S> {
    ctx: tls::Context,
    ex: H3Ex<S>[>..],
}

// A worker's HTTP/3 server on its own reference to ctx, which release frees,
// for a loop whose handler's state starts as fresh. ctx's ALPN protocols
// must list "h3".
fn h3_server<S>(ctx: tls::Context, fresh: S) -> H3ServerOf<S> {
    return H3ServerOf<S> { ctx: tls::share(ctx), .. };
}

// The server of serve(cfg, t, q) and serve_epoll(cfg, t, q), whose handler
// takes the whole request.
type H3Server = H3ServerOf<bool>;

fn h3_server(ctx: tls::Context) -> H3Server { h3_server(ctx, false) }

fn release<S>(q: H3ServerOf<S>&) {
    tls::free(q.ctx);
    q.ctx = tls::Context { .. };
}

fn h3_ex<S>(q: H3ServerOf<S>&, k: i64) -> H3Ex<S>& {
    while q.ex.len <= k { q.ex.push(H3Ex<S> { .. }); }
    return q.ex[k];
}


// Appends the QPACK field section of the HTTP/1.1 response head at text's
// front, once it's whole, as h2_head_block does for HPACK: the fields' names
// lowercased in text itself, and HTTP/1.1's connection fields dropped
// (RFC 9114, section 4.2). Returns the head's length with its blank line, or
// -1 while it isn't whole.
fn h3_head_block(fb: u8[>..]&, text: u8[:]) -> i64 {
    var start = 0;
    var at = 0;
    var line_end: i64 = -1;
    loop {
        let nl = position(text[at..], '\n');
        guard nl >= 0 else { return -1; }
        let e = at + nl;
        at = e + 1;
        guard e > start && text[e - 1] == '\r' else { continue; }
        if e - 1 == start { break; }
        if line_end < 0 { line_end = e - 1; }
        start = at;
    }
    let size = at;
    qpack_begin(fb);
    let line = if line_end > 0 { text[..line_end] } else { text[..0] };
    var status: i32 = 500;
    if line.len >= 12 && is_digit(line[9]) && is_digit(line[10]) && is_digit(line[11]) {
        let d0: i32 = line[9] - '0';
        let d1: i32 = line[10] - '0';
        let d2: i32 = line[11] - '0';
        status = d0 * 100 + d1 * 10 + d2;
    }
    qpack_status(fb, status);
    var pos = line.len + 2;
    while pos < size - 2 {
        let cr = pos + find(text[pos..], "\r\n");
        let l = text[pos..cr];
        pos = cr + 2;
        let colon = position(l, ':');
        if colon <= 0 { continue; }
        let name = l[..colon];
        for &ch in name { if ch >= 'A' && ch <= 'Z' { ch += 32; } }
        if name == "connection" || name == "keep-alive" || name == "proxy-connection" ||
           name == "transfer-encoding" || name == "upgrade" { continue; }
        qpack_encode(fb, name, trim(l[colon + 1..]));
    }
    return size;
}

// Queues an HTTP/3 frame of kind with payload on stream k.
fn h3_queue_frame(k: i64, kind: i64, payload: const u8[:]) {
    var head: u8[>..] = [];
    qv_put(head, kind);
    qv_put(head, payload.len);
    tx_put(h3strms[k].tx, head);
    tx_put(h3strms[k].tx, payload);
}

// Queues HEADERS for the HTTP/1.1 head at text's front, and DATA for what
// follows it, once the head is whole: false while it isn't.
fn h3_emit_head(k: i64, text: u8[:]) -> bool {
    var fb: u8[>..] = [];
    let size = h3_head_block(fb, text);
    guard size >= 0 else { return false; }
    h3_queue_frame(k, H3F_HEADERS, fb);
    if text.len > size { h3_queue_frame(k, H3F_DATA, text[size..]); }
    return true;
}

// Turns what the handler wrote for stream k into frames: the HTTP/1.1 head
// into HEADERS once it's whole, and the rest into DATA, with the stream's
// end once the response has ended.
fn h3_emit<S>(q: H3ServerOf<S>&, k: i64, bytes: u8[:]) {
    let e .= q.ex[k];
    let st .= h3strms[k];
    guard !e.ended && !st.tx_stopped else { return; }
    if !e.headers_sent {
        if e.head.len > 0 {
            let had = e.head.len;
            e.head = h3bytes.realloc_slice(e.head, had + bytes.len);
            copy_into(e.head[had..], bytes);
            guard h3_emit_head(k, e.head) else { return; }
            run_free(e.head);
            e.head = h3bytes[..0];
        } else if !h3_emit_head(k, bytes) {
            // begin's head, open until the first send.
            if bytes.len > 0 {
                e.head = h3bytes.alloc_slice(bytes.len);
                copy_into(e.head, bytes);
            }
            return;
        }
        e.headers_sent = true;
    } else if bytes.len > 0 && !e.x.head {
        h3_queue_frame(k, H3F_DATA, bytes);
    }
    if !e.x.stream.open {
        st.tx.fin = true;
        e.ended = true;
    }
}

// Calls H for ev on stream k's exchange, and turns what it wrote into
// frames. An exchange that waits gets TIMEOUT with NO_ROOM at once: HTTP/3
// has no timer table for later's yet. Returns whether it wrote anything.
fn h3_call<S, H>(q: H3ServerOf<S>&, ci: i64, k: i64, ev: Event, common: const u8[:]) -> bool {
    let wrote, waits = h3_call_once(q, ci, k, ev, common, H);
    guard waits else { return wrote; }
    let nothing = Request { .. };
    let more, again = h3_call_once(q, ci, k, Event { kind: TIMEOUT, req: nothing, data: "", whole: false, trailers: "",
                                                     tag: NO_ROOM }, common, H);
    return wrote || more;
}

// One call of H for ev: whether it wrote anything, and whether it asked to
// wait.
fn h3_call_once<S, H>(q: H3ServerOf<S>&, ci: i64, k: i64, ev: Event, common: const u8[:]) -> bool, bool {
    let e .= q.ex[k];
    let was_open = e.x.stream.open;
    e.x.stream.moved = false;
    var out: u8[>..] = [];
    H(ev, &e.x.state, Reply { buf: out, common: common, keep_alive: e.x.keep_alive, minor: H2_MINOR,
                              head: e.x.head, stream: e.x.stream, fd: -1 });
    let any = out.len > 0;
    let waits = e.x.stream.waiting;
    e.x.stream.waiting = false;
    e.x.stream.rearm = false;
    retire(e.x.stream);
    if !e.x.answered && !e.x.stream.open && (any || was_open) { e.x.answered = true; }
    if any || (was_open && !e.x.stream.open) { h3_emit(q, k, out); }
    if !e.x.keep_alive { h3conns[ci].goaway_owed = true; }
    return any, waits;
}

// Calls H with CLOSED for stream k's exchange, if it was owed another call,
// and gives back what it held.
fn h3_abandon<S, H>(q: H3ServerOf<S>&, k: i64) {
    let e .= q.ex[k];
    let x .= e.x;
    let owed = e.called && (x.stream.open || (!x.answered));
    retire(x.stream);
    if owed {
        var sink: u8[>..] = [];
        let none = Request { .. };
        H(Event { kind: CLOSED, req: none, data: "", whole: false, trailers: "" }, &x.state,
          Reply { buf: sink, common: "", keep_alive: x.keep_alive, minor: H2_MINOR, head: x.head, stream: x.stream,
                  fd: -1 });
        x.stream.open = false;
    }
    run_free(e.rq);
    run_free(e.held);
    run_free(e.trailers);
    run_free(e.head);
    q.ex[k] = H3Ex<S> { .. };
}

// Answers stream k with a refusal of status, if nothing of its response went
// yet, and stops the rest of its request.
fn h3_refuse<S, H>(q: H3ServerOf<S>&, k: i64, status: i32, common: const u8[:]) {
    let e .= q.ex[k];
    guard !e.x.answered && !e.x.stream.open && !e.headers_sent else { return; }
    h3_abandon(q, k, H);
    let e2 .= q.ex[k];
    e2.called = true;
    e2.x.answered = true;
    var out: u8[>..] = [];
    refuse(out, status, common);
    h3_emit(q, k, out);
    h3_stop_request(k);
}

// Stops the rest of stream k's request, which the response doesn't need.
fn h3_stop_request(k: i64) {
    let st .= h3strms[k];
    guard !st.rx_stopped && (st.rx.fin < 0 || st.rx.read < st.rx.fin) else { return; }
    st.rx_stopped = true;
    st.owe_stop = true;
    st.stop_code = H3_NO_ERROR;
}

// Resets stream k with code: a malformed request (RFC 9114, section 4.1.2),
// or one refused.
fn h3_reset<S, H>(q: H3ServerOf<S>&, k: i64, code: i64) {
    h3_abandon(q, k, H);
    let st .= h3strms[k];
    if !st.tx_stopped {
        st.tx_stopped = true;
        st.owe_reset = true;
        st.reset_code = code;
        st.tx.lost.s.clear();
    }
    if !st.rx_stopped {
        st.rx_stopped = true;
        st.owe_stop = true;
        st.stop_code = code;
    }
    q.ex[k].ended = true;
}

// The request kept while its body gathered.
fn h3_kept_request<S>(e: H3Ex<S>&) -> Request {
    let m = e.method_len;
    let t = m + e.target_len;
    return Request { method: e.rq[..m], target: e.rq[m..t], minor: 1, keep_alive: true,
                     body: max(e.length, 0), fields: e.rq[t..], .. };
}

// After a call that leaves the exchange owing an answer: one that did
// nothing gets 500, as HTTP/1.1's does.
fn h3_owe_answer<S, H>(q: H3ServerOf<S>&, k: i64, common: const u8[:]) {
    let e .= q.ex[k];
    if !e.x.answered && !e.x.stream.open { h3_refuse(q, k, 500, common, H); }
}

// A whole field section for stream k: the request (RFC 9114, section 4.3.1),
// checked as h2 checks one, or its trailers.
fn h3_field_section<S, H>(q: H3ServerOf<S>&, ci: i64, k: i64, fb: const u8[:], ended: bool, cfg: const Config&,
                         fresh: const S&, common: const u8[:], now: i64) {
    let trailers = q.ex[k].headers;
    var fields: u8[>..] = [];
    var pseudo: u8[>..] = [];
    var cookie: u8[>..] = [];
    var huff: u8[>..] = [];
    var bad = false;
    var regular = false;
    var size = 0;
    var m0 = -1; var m1 = -1;
    var p0 = -1; var p1 = -1;
    var a0 = -1; var a1 = -1;
    var scheme = false;
    var host = false;
    var length = -1;
    var expect = false;
    var unmet = false;
    let ok = qpack_decode(fb, huff) { name, value =>
        size += name.len + value.len + 32;
        if !bad {
            if name.len > 0 && name[0] == ':' {
                if regular || trailers { bad = true; }
                else if name == ":method" && m0 < 0 {
                    m0 = pseudo.len; pseudo.append(value); m1 = pseudo.len;
                } else if name == ":path" && p0 < 0 {
                    p0 = pseudo.len; pseudo.append(value); p1 = pseudo.len;
                } else if name == ":authority" && a0 < 0 {
                    a0 = pseudo.len; pseudo.append(value); a1 = pseudo.len;
                } else if name == ":scheme" && !scheme {
                    scheme = true;
                } else { bad = true; }
                if !h2_value_ok(value) { bad = true; }
            } else {
                regular = true;
                if !h2_name_ok(name) || !h2_value_ok(value) { bad = true; }
                else if name == "te" && value != "trailers" { bad = true; }
                else if name == "cookie" {
                    if cookie.len > 0 { cookie.append("; "); }
                    cookie.append(value);
                } else {
                    if name == "host" { host = true; }
                    if name == "expect" {
                        if eq_fold(value, "100-continue") { expect = true; } else { unmet = true; }
                    }
                    if name == "content-length" {
                        let n, nok = parse_int(value);
                        if !nok || n < 0 || (length >= 0 && n != length) { bad = true; }
                        length = n;
                    }
                    fields.append(name);
                    fields.append(": ");
                    fields.append(value);
                    fields.append("\r\n");
                }
            }
        }
    };
    guard ok else {
        h3_close_conn(ci, true, QPACK_DECOMPRESSION_FAILED, 0, now);
        return;
    }
    if cookie.len > 0 {
        fields.append("cookie: ");
        fields.append(cookie);
        fields.append("\r\n");
    }
    if trailers {
        guard !bad && ended else {
            h3_reset(q, k, H3_MESSAGE_ERROR, H);
            return;
        }
        let e .= q.ex[k];
        run_free(e.trailers);
        e.trailers = h3bytes.alloc_slice(fields.len);
        copy_into(e.trailers, fields);
        return;
    }
    let connect = m0 >= 0 && pseudo[m0..m1] == "CONNECT";
    if m0 < 0 || (connect && (a0 < 0 || scheme || p0 >= 0)) || (!connect && (!scheme || p0 < 0 || p1 == p0)) {
        bad = true;
    }
    if bad {
        h3_reset(q, k, H3_MESSAGE_ERROR, H);
        return;
    }
    let e .= q.ex[k];
    e.headers = true;
    e.called = false;
    e.x = Exchange<S> { state: fresh, .. };
    e.x.keep_alive = true;
    e.x.minor = H2_MINOR;
    e.x.since = now;
    e.x.began = now;
    e.x.stream.direct = false;
    e.length = length;
    if size > cfg.max_head { h3_refuse(q, k, 431, common, H); return; }
    if p1 - p0 > cfg.max_line { h3_refuse(q, k, 414, common, H); return; }
    if length > cfg.max_body { h3_refuse(q, k, 413, common, H); return; }
    if unmet { h3_refuse(q, k, 417, common, H); return; }
    if a0 >= 0 && !host {
        fields.append("host: ");
        fields.append(pseudo[a0..a1]);
        fields.append("\r\n");
    }
    let method = pseudo[m0..m1];
    let target = if connect { pseudo[a0..a1] } else { pseudo[p0..p1] };
    e.x.head = method == "HEAD";
    if ended {
        e.called = true;
        let req = Request { method: method, target: target, minor: 1, keep_alive: true, fields: fields, .. };
        h3_call(q, ci, k, Event { kind: REQUEST, req: req, data: "", whole: true, trailers: "" }, common, H);
        h3_owe_answer(q, k, common, H);
        return;
    }
    e.gathering = true;
    e.method_len = method.len;
    e.target_len = target.len;
    e.rq = h3bytes.alloc_slice(method.len + target.len + fields.len);
    copy_into(e.rq[..method.len], method);
    copy_into(e.rq[method.len..method.len + target.len], target);
    copy_into(e.rq[method.len + target.len..], fields);
}

// A piece of stream k's body.
fn h3_body<S, H>(q: H3ServerOf<S>&, ci: i64, k: i64, piece: const u8[:], cfg: const Config&,
                 common: const u8[:]) {
    let gone = Request { .. };
    let e .= q.ex[k];
    e.received += piece.len;
    if e.length >= 0 && e.received > e.length {
        h3_reset(q, k, H3_MESSAGE_ERROR, H);
        return;
    }
    if e.ended || e.x.answered && !e.x.stream.open { return; }
    if e.received > cfg.max_body {
        h3_refuse(q, k, 413, common, H);
        return;
    }
    if e.gathering {
        if e.held.len + piece.len <= min(cfg.max_head, H3_STREAM_WINDOW / 2) {
            let had = e.held.len;
            e.held = if had == 0 { h3bytes.alloc_slice(piece.len) } else { h3bytes.realloc_slice(e.held, had + piece.len) };
            copy_into(e.held[had..], piece);
            return;
        }
        // Too long to gather: REQUEST now, with what's held, and the body in
        // pieces.
        e.gathering = false;
        e.called = true;
        let req = h3_kept_request(e);
        h3_call(q, ci, k, Event { kind: REQUEST, req: req, data: "", whole: false, trailers: "" }, common, H);
        let e2 .= q.ex[k];
        if e2.held.len > 0 {
            h3_call(q, ci, k, Event { kind: BODY, req: gone, data: e2.held, whole: false, trailers: "" }, common, H);
            let e3 .= q.ex[k];
            run_free(e3.held);
            e3.held = h3bytes[..0];
        }
    }
    h3_call(q, ci, k, Event { kind: BODY, req: gone, data: piece, whole: false, trailers: "" }, common, H);
}

// The client's end of stream k's request: REQUEST with the body gathered,
// or END, and the content-length checked (RFC 9114, section 4.1.2).
fn h3_request_end<S, H>(q: H3ServerOf<S>&, ci: i64, k: i64, common: const u8[:]) {
    let gone = Request { .. };
    let e .= q.ex[k];
    guard !e.ended || !e.x.answered else { return; }
    if !e.headers {
        // A request stream that ended without its HEADERS.
        h3_reset(q, k, H3_REQUEST_INCOMPLETE, H);
        return;
    }
    if e.length >= 0 && e.received != e.length {
        h3_reset(q, k, H3_MESSAGE_ERROR, H);
        return;
    }
    if e.gathering {
        e.gathering = false;
        e.called = true;
        let req = h3_kept_request(e);
        h3_call(q, ci, k, Event { kind: REQUEST, req: req, data: e.held, whole: true, trailers: e.trailers }, common, H);
        let e2 .= q.ex[k];
        run_free(e2.held);
        e2.held = h3bytes[..0];
        h3_owe_answer(q, k, common, H);
        return;
    }
    if e.called && !e.x.answered || e.x.stream.open {
        h3_call(q, ci, k, Event { kind: END, req: gone, data: "", whole: false, trailers: e.trailers }, common, H);
        h3_owe_answer(q, k, common, H);
    }
}

// What stream k, a request, received: its frames (RFC 9114, section 7), the
// HEADERS to the handler and DATA as the body.
fn h3_request_in<S, H>(q: H3ServerOf<S>&, ci: i64, k: i64, cfg: const Config&, fresh: const S&,
                       common: const u8[:], now: i64) {
    let st .= h3strms[k];
    if st.rx_stopped || st.tx_stopped {
        // Reset by the client, or its response stopped: the exchange is over.
        if q.ex.len > k && !q.ex[k].ended { h3_reset(q, k, H3_REQUEST_CANCELLED, H); }
        return;
    }
    // A request after GOAWAY, or while the worker stops, is rejected
    // (section 5.2).
    if h3conns[ci].goaway_sent && !h3_ex(q, k).headers {
        h3_reset(q, k, H3_REQUEST_REJECTED, H);
        return;
    }
    h3_ex(q, k);
    loop {
        let st2 .= h3strms[k];
        guard !st2.rx_stopped && h3conns[ci].state == H3_OPEN else { return; }
        let bytes = rx_ready(st2.rx);
        let e .= q.ex[k];
        if e.data_left > 0 && bytes.len > 0 {
            let n = min(e.data_left, bytes.len);
            var piece: u8[>..] = [];
            piece.append(bytes[..n]);
            rx_take(h3strms[k].rx, n);
            h3_consumed(ci, k, n);
            e.data_left -= n;
            h3_body(q, ci, k, piece, cfg, common, H);
            continue;
        }
        if e.skip_left > 0 && bytes.len > 0 {
            let n = min(e.skip_left, bytes.len);
            rx_take(h3strms[k].rx, n);
            h3_consumed(ci, k, n);
            e.skip_left -= n;
            continue;
        }
        if bytes.len == 0 { break; }
        var r = QRd { at: 0, bad: false };
        let kind = qv(bytes, r);
        let len = qv(bytes, r);
        guard !r.bad else { break; }
        if kind == H3F_DATA {
            guard e.headers else {
                h3_close_conn(ci, true, H3_FRAME_UNEXPECTED, 0, now);
                return;
            }
            rx_take(h3strms[k].rx, r.at);
            h3_consumed(ci, k, r.at);
            e.data_left = len;
            continue;
        }
        if kind == H3F_HEADERS {
            guard len <= 2 * cfg.max_head + 1024 else {
                h3_close_conn(ci, true, H3_EXCESSIVE_LOAD, 0, now);
                return;
            }
            guard bytes.len - r.at >= len else { break; }
            var fb: u8[>..] = [];
            fb.append(bytes[r.at..r.at + len]);
            rx_take(h3strms[k].rx, r.at + len);
            h3_consumed(ci, k, r.at + len);
            let st3 .= h3strms[k];
            let ended = st3.rx.fin >= 0 && st3.rx.read == st3.rx.fin;
            h3_field_section(q, ci, k, fb, ended, cfg, fresh, common, now, H);
            continue;
        }
        if kind == H3F_CANCEL_PUSH || kind == H3F_SETTINGS || kind == H3F_PUSH_PROMISE || kind == H3F_GOAWAY ||
           kind == H3F_MAX_PUSH_ID || kind == 0x02 || kind == 0x06 || kind == 0x08 || kind == 0x09 {
            h3_close_conn(ci, true, H3_FRAME_UNEXPECTED, 0, now);
            return;
        }
        // An unknown frame is skipped (section 9).
        rx_take(h3strms[k].rx, r.at);
        h3_consumed(ci, k, r.at);
        q.ex[k].skip_left = len;
    }
    let st4 .= h3strms[k];
    if st4.rx.fin >= 0 && st4.rx.read == st4.rx.fin && !st4.rx_stopped {
        let e .= q.ex[k];
        if e.data_left > 0 || e.skip_left > 0 {
            h3_reset(q, k, H3_FRAME_ERROR, H);
            return;
        }
        if rx_ready(st4.rx).len == 0 && !e.ended {
            st4.rx_stopped = true;
            h3_request_end(q, ci, k, common, H);
        }
    }
}

// A client's control stream (RFC 9114, section 6.2.1): its SETTINGS first,
// then GOAWAY and the frames it may carry.
fn h3_control_in(ci: i64, k: i64, now: i64) {
    loop {
        let st .= h3strms[k];
        let bytes = rx_ready(st.rx);
        if bytes.len == 0 { break; }
        var r = QRd { at: 0, bad: false };
        let kind = qv(bytes, r);
        let len = qv(bytes, r);
        guard !r.bad else { break; }
        guard len <= 65536 else {
            h3_close_conn(ci, true, H3_EXCESSIVE_LOAD, 0, now);
            return;
        }
        guard bytes.len - r.at >= len else { break; }
        let body = bytes[r.at..r.at + len];
        let c .= h3conns[ci];
        if !c.settings_seen {
            guard kind == H3F_SETTINGS else {
                h3_close_conn(ci, true, H3_MISSING_SETTINGS, 0, now);
                return;
            }
            c.settings_seen = true;
            var s = QRd { at: 0, bad: false };
            while s.at < body.len {
                let id = qv(body, s);
                qv(body, s);
                // HTTP/2's settings have no place here (section 7.2.4.1).
                if id >= 0x02 && id <= 0x05 { s.bad = true; }
                if s.bad { break; }
            }
            guard !s.bad else {
                h3_close_conn(ci, true, H3_SETTINGS_ERROR, 0, now);
                return;
            }
        } else if kind == H3F_SETTINGS || kind == H3F_DATA || kind == H3F_HEADERS || kind == H3F_PUSH_PROMISE ||
                  kind == 0x02 || kind == 0x06 || kind == 0x08 || kind == 0x09 {
            h3_close_conn(ci, true, H3_FRAME_UNEXPECTED, 0, now);
            return;
        } else if kind == H3F_CANCEL_PUSH {
            // This side promises no push.
            h3_close_conn(ci, true, H3_ID_ERROR, 0, now);
            return;
        }
        rx_take(h3strms[k].rx, r.at + len);
        h3_consumed(ci, k, r.at + len);
    }
}

// What the client's unidirectional stream k received: its type first
// (section 6.2), then as that type says. Its critical streams may not close.
fn h3_uni_in(ci: i64, k: i64, now: i64) {
    let st .= h3strms[k];
    if st.kind == K_UNI {
        let bytes = rx_ready(st.rx);
        var r = QRd { at: 0, bad: false };
        let kind = qv(bytes, r);
        if r.bad { return; }
        rx_take(st.rx, r.at);
        h3_consumed(ci, k, r.at);
        let c .= h3conns[ci];
        if kind == H3S_CONTROL {
            guard c.control_in < 0 else { h3_close_conn(ci, true, H3_STREAM_CREATION_ERROR, 0, now); return; }
            c.control_in = k as i32;
            st.kind = K_CONTROL_IN;
        } else if kind == H3S_ENCODER {
            guard c.encoder_in < 0 else { h3_close_conn(ci, true, H3_STREAM_CREATION_ERROR, 0, now); return; }
            c.encoder_in = k as i32;
            st.kind = K_ENCODER_IN;
        } else if kind == H3S_DECODER {
            guard c.decoder_in < 0 else { h3_close_conn(ci, true, H3_STREAM_CREATION_ERROR, 0, now); return; }
            c.decoder_in = k as i32;
            st.kind = K_DECODER_IN;
        } else if kind == H3S_PUSH {
            // Only a server pushes.
            h3_close_conn(ci, true, H3_STREAM_CREATION_ERROR, 0, now);
            return;
        } else {
            st.kind = K_IGNORED_IN;
        }
    }
    let st2 .= h3strms[k];
    if st2.kind == K_CONTROL_IN {
        h3_control_in(ci, k, now);
    } else if st2.kind == K_ENCODER_IN {
        // The encoder may set the table's capacity to 0, what this side
        // allows, and nothing more (RFC 9204, section 4.3).
        loop {
            let bytes = rx_ready(h3strms[k].rx);
            if bytes.len == 0 { break; }
            guard bytes[0] & 0xe0 == 0x20 else {
                h3_close_conn(ci, true, QPACK_ENCODER_STREAM_ERROR, 0, now);
                return;
            }
            let cap, p = hpack_read_int(bytes, 0, 5);
            if p < 0 { break; }
            guard cap == 0 else {
                h3_close_conn(ci, true, QPACK_ENCODER_STREAM_ERROR, 0, now);
                return;
            }
            rx_take(h3strms[k].rx, p);
            h3_consumed(ci, k, p);
        }
    } else if st2.kind != K_UNI {
        // The decoder's instructions concern a dynamic table this side never
        // fills, and an unknown stream's bytes are dropped.
        let n = rx_ready(st2.rx).len;
        rx_take(h3strms[k].rx, n);
        h3_consumed(ci, k, n);
    }
    let st3 .= h3strms[k];
    let critical = st3.kind == K_CONTROL_IN || st3.kind == K_ENCODER_IN || st3.kind == K_DECODER_IN;
    if critical && (st3.rx_stopped || st3.rx.fin >= 0 && st3.rx.read >= st3.rx.fin) {
        h3_close_conn(ci, true, H3_CLOSED_CRITICAL_STREAM, 0, now);
    }
}

// Whether request stream k is done each way, its exchange over: then it
// closes.
fn h3_finished<S>(q: H3ServerOf<S>&, k: i64) -> bool {
    let st .= h3strms[k];
    let rx_done = st.rx_stopped || (st.rx.fin >= 0 && st.rx.read >= st.rx.fin);
    let tx_over = if st.tx_stopped { !st.owe_reset } else { tx_done(st.tx) };
    let open = q.ex.len > k && q.ex[k].x.stream.open;
    return rx_done && tx_over && !open && !st.owe_stop && !st.owe_max;
}

// The HTTP/3 layer's turn on connection ci, after its datagrams: each stream
// read, MORE for each response begun with begin while its stream has room,
// and the streams done closed.
fn h3_serve_conn<S, H>(q: H3ServerOf<S>&, ci: i64, cfg: const Config&, fresh: const S&,
                       common: const u8[:], now: i64) {
    let gone = Request { .. };
    let open = h3conns[ci].streams;
    for k in open {
        guard h3conns[ci].live && h3conns[ci].state == H3_OPEN else { return; }
        let st .= h3strms[k];
        if st.conn != ci || !st.readable { continue; }
        st.readable = false;
        if st.kind == K_REQUEST { h3_request_in(q, ci, k, cfg, fresh, common, now, H); }
        else if st.kind != K_CONTROL_OUT { h3_uni_in(ci, k, now); }
    }
    guard h3conns[ci].live && h3conns[ci].state == H3_OPEN else { return; }
    let again = h3conns[ci].streams;
    for k in again {
        let st .= h3strms[k];
        if st.conn != ci || st.kind != K_REQUEST || q.ex.len <= k { continue; }
        let e .= q.ex[k];
        if e.called && e.x.stream.open && !e.ended && !st.tx_stopped && st.tx.end - st.tx.next < H3_SEND_AHEAD &&
           st.rx.fin >= 0 && st.rx.read >= st.rx.fin {
            let wrote = h3_call(q, ci, k, Event { kind: MORE, req: gone, data: "", whole: false, trailers: "" },
                                common, H);
            let e2 .= q.ex[k];
            // A MORE that neither sends, ends, nor waits would be called
            // forever.
            if !wrote && !e2.x.stream.moved && e2.x.stream.open { h3_reset(q, k, H3_INTERNAL_ERROR, H); }
        }
    }
    let c .= h3conns[ci];
    // GOAWAY, once a handler ended its connection or the worker stops
    // (section 5.2): the streams already opened finish.
    if (c.goaway_owed || h3stopping) && !c.goaway_sent && c.control_out >= 0 {
        c.goaway_sent = true;
        var b: u8[>..] = [];
        qv_put(b, c.bidi_next * 4);
        h3_queue_frame(c.control_out, H3F_GOAWAY, b);
    }
    let last = h3conns[ci].streams;
    var requests = 0;
    for k in last {
        let st .= h3strms[k];
        if st.kind != K_REQUEST { continue; }
        if h3_finished(q, k) {
            if q.ex.len > k {
                run_free(q.ex[k].rq);
                run_free(q.ex[k].held);
                run_free(q.ex[k].trailers);
                run_free(q.ex[k].head);
                q.ex[k] = H3Ex<S> { .. };
            }
            strm_close(ci, k);
        } else {
            requests++;
        }
    }
    let c2 .= h3conns[ci];
    if c2.goaway_sent && requests == 0 && (h3stopping || c2.goaway_owed) && tx_done_or_empty(c2) {
        h3_close_conn(ci, true, H3_NO_ERROR, 0, now);
    }
}

// Whether connection ci's control stream has nothing left to send.
fn tx_done_or_empty(c: const H3Conn&) -> bool {
    guard c.control_out >= 0 else { return true; }
    let t .= h3strms[c.control_out].tx;
    return t.base >= t.end;
}

// ---- The loops' side ----

// The TLS of a loop's TCP listeners and the HTTP/3 of its UDP ones, which
// the loop takes in place of a TlsServer.
struct H3Pair<C, S> { t: TlsServerOf<C>&, h: H3ServerOf<S>& }

// serve_epoll(cfg, fresh, t), with the listeners with h3 serving it with q.
fn serve_epoll<S, C, H>(cfg: Config, fresh: S, t: TlsServerOf<C>&, q: H3ServerOf<S>&) -> Error {
    var p = H3Pair<C, S> { t: t, h: q };
    return epoll_loop(cfg, fresh, p, H);
}

// serve_epoll(cfg, t), with the listeners with h3 serving it with q.
fn serve_epoll<H>(cfg: Config, t: TlsServer&, q: H3Server&) -> Error {
    var p = H3Pair<OneContext, bool> { t: t, h: q };
    return epoll_loop(cfg, false, p) { ev, st, out => whole(ev, out, H); };
}

// serve(cfg, fresh, t), with the listeners with h3 serving it with q. On
// io_uring only: the emulated ring has no socket readiness (net_arm), and
// fails with ENOSYS on an h3 listener.
fn serve<S, C, H>(cfg: Config, fresh: S, t: TlsServerOf<C>&, q: H3ServerOf<S>&) -> Error {
    var p = H3Pair<C, S> { t: t, h: q };
    return ring_loop(cfg, fresh, p, H);
}

fn serve<H>(cfg: Config, t: TlsServer&, q: H3Server&) -> Error {
    var p = H3Pair<OneContext, bool> { t: t, h: q };
    return ring_loop(cfg, false, p) { ev, st, out => whole(ev, out, H); };
}

// The TCP listeners' TLS, as http.tls serves it.
fn tls_serves<C, S>(p: H3Pair<C, S>&) -> bool { tls_serves(p.t) }
fn tls_open<C, S>(p: H3Pair<C, S>&) -> i32 { tls_open(p.t) }
fn tls_ready<C, S>(p: H3Pair<C, S>&, k: i32) -> bool { tls_ready(p.t, k) }
fn tls_h2<C, S>(p: H3Pair<C, S>&, k: i32) -> bool { tls_h2(p.t, k) }
fn tls_recv<C, S>(p: H3Pair<C, S>&, k: i32, fd: i32, buf: u8[:]) -> i64, bool {
    let n, empty = tls_recv(p.t, k, fd, buf);
    return n, empty;
}
fn tls_take<C, S>(p: H3Pair<C, S>&, k: i32, bytes: const u8[:], out: u8[>..]&) -> bool { tls_take(p.t, k, bytes, out) }
fn tls_seal<C, S>(p: H3Pair<C, S>&, k: i32, w: u8[>..]&, from: i64, last: bool) -> bool { tls_seal(p.t, k, w, from, last) }
fn tls_close<C, S>(p: H3Pair<C, S>&, k: i32, fd: i32, clean: bool) { tls_close(p.t, k, fd, clean); }

fn h3_serves<C, S>(p: H3Pair<C, S>&) -> bool { true }

// Opens listener k's UDP socket on port, and watches it. The first opens the
// worker's QUIC.
fn h3_listen<C, S>(p: H3Pair<C, S>&, cfg: const Config&, k: i64, port: i32) -> Error {
    if h3rx.len == 0 {
        push_n(h3rx, 0, H3_BATCH * H3_SLOT);
        h3rng = rng { random_seed() };
        h3max_conns = cfg.max_conns;
        h3stopping = false;
    }
    while h3fds.len <= k { h3fds.push(-1); }
    var flags = REUSEPORT;
    var addr: u8[>..] = [];
    let text = cfg.address;
    var host = text;
    if text.len >= 2 && text[0] == '[' && text[text.len - 1] == ']' { host = text[1..text.len - 1]; }
    if host.len > 0 {
        let a, ok = address(host);
        guard ok else { return Error { call: "address", code: EINVAL }; }
        addr.append(a.ip);
        if cfg.ipv6_only { flags = flags | V6ONLY; }
    } else {
        // Every address, IPv6's too, where TCP's listener takes IPv4's: a QUIC
        // client that resolves localhost to ::1 first doesn't fall back to
        // 127.0.0.1, as a TCP client does when its connection is refused.
        push_n(addr, 0, 16);
    }
    let fd = net_udp_open(addr, port, flags);
    guard fd >= 0 else { return Error { call: "udp", code: -fd }; }
    h3fds[k] = fd;
    let r = net_arm(fd, EPOLLIN, h3_key(k));
    guard r == 0 else {
        net_close(fd);
        h3fds[k] = -1;
        return Error { call: "h3", code: -r };
    }
    return Error { call: "", code: 0 };
}

// The listener whose UDP socket key is armed for, or -1.
fn h3_listener<C, S>(p: H3Pair<C, S>&, key: u64) -> i64 {
    guard key <= H3_KEY_BASE && key > H3_KEY_BASE - (MAX_LISTENERS + 1) as u64 else { return -1; }
    let k = (H3_KEY_BASE - key) as i64;
    return if k < h3fds.len && h3fds[k] >= 0 { k } else { -1 };
}

// Every connection touched since the last pass: the HTTP/3 layer's turn,
// then what each has to send, and its timer.
fn h3_pass<S, H>(q: H3ServerOf<S>&, cfg: const Config&, fresh: const S&, common: const u8[:], now: i64) {
    var i = 0;
    while i < h3touched_n {
        let ci: i64 = h3touched[i];
        i++;
        guard h3conns[ci].live else { continue; }
        if h3conns[ci].dead {
            h3_kill(q, ci, H);
            continue;
        }
        h3_serve_conn(q, ci, cfg, fresh, common, now, H);
        if h3conns[ci].live { h3_flush(ci, now); }
    }
    for j in h3touched_n {
        let ci: i64 = h3touched[j];
        if h3conns[ci].live {
            h3conns[ci].touched = false;
            h3_arm(ci, now);
        }
    }
    h3touched_n = 0;
    h3_send_now();
}

// Listener k's socket is readable: its datagrams, a batch at a time, up to
// eight batches before the loop's other work; then its watch again, which
// fires at once if more wait.
fn h3_ready<C, S, H>(p: H3Pair<C, S>&, k: i64, cfg: const Config&, fresh: const S&, common: const u8[:], now: i64) {
    let fd = h3fds[k];
    guard fd >= 0 else { return; }
    var vn: u8[>..] = [];
    for round in 8 {
        let n = net_udp_recv(fd, h3rx, H3_SLOT, h3rx_sizes, h3rx_peers);
        if n == -EINTR { continue; }
        guard n > 0 else { break; }
        for i in n {
            let size: i64 = h3rx_sizes[i];
            if size > 0 { h3_datagram(vn, p.h, k, h3rx[i * H3_SLOT..i * H3_SLOT + size], h3rx_peers[i], now); }
        }
        h3_pass(p.h, cfg, fresh, common, now, H);
        if n < H3_BATCH { break; }
    }
    net_arm(fd, EPOLLIN, h3_key(k));
}

// Milliseconds until the worker's QUIC needs the loop again, up to limit: at
// once while datagrams wait to be sent.
fn h3_wait<C, S>(p: H3Pair<C, S>&, now: i64, limit: i32) -> i32 {
    if h3tx_count > 0 { return 0; }
    while h3timers_n > 0 {
        let t = h3timers[0];
        let c .= h3conns[t.conn];
        if c.live && c.gen == t.gen && c.timer_at == t.at { return min(max(t.at - now, 0), limit as i64) as i32; }
        h3_timer_pop();
    }
    return limit;
}

// The timers due, and the datagrams still to send.
fn h3_tick<C, S, H>(p: H3Pair<C, S>&, cfg: const Config&, fresh: const S&, common: const u8[:], now: i64) {
    while h3timers_n > 0 && h3timers[0].at <= now {
        let t = h3_timer_pop();
        let ci: i64 = t.conn;
        let c .= h3conns[ci];
        guard c.live && c.gen == t.gen && c.timer_at == t.at else { continue; }
        c.timer_at = 0;
        h3_expire(ci, now);
        if h3conns[ci].live { h3_touch(ci); }
    }
    if h3touched_n > 0 { h3_pass(p.h, cfg, fresh, common, now, H); }
    h3_send_now();
}

// The worker stops: each connection is sent GOAWAY, and closes once its
// requests are done; those not yet past their handshake close now.
fn h3_stop<C, S>(p: H3Pair<C, S>&, now: i64) {
    h3stopping = true;
    for ci in h3conns.len {
        let c .= h3conns[ci];
        guard c.live else { continue; }
        if !c.shaken { h3_close_conn(ci, false, QE_NO_ERROR, 0, now); }
        h3_touch(ci);
    }
}

fn h3_count<C, S>(p: H3Pair<C, S>&) -> i64 { h3open }

// Frees connection ci, after CLOSED to each exchange owed a call.
fn h3_kill<S, H>(q: H3ServerOf<S>&, ci: i64) {
    let open = h3conns[ci].streams;
    for k in open {
        if h3strms[k].kind == K_REQUEST && q.ex.len > k { h3_abandon(q, k, H); }
    }
    h3_free(ci);
}

// The loop returns: every connection goes, and the sockets close.
fn h3_end<C, S, H>(p: H3Pair<C, S>&) {
    h3_send_now();
    for ci in h3conns.len { if h3conns[ci].live { h3_kill(p.h, ci, H); } }
    for &fd in h3fds {
        if fd >= 0 {
            net_close(fd);
            fd = -1;
        }
    }
    h3q_len = 0;
    h3tx_count = 0;
    h3timers_n = 0;
    h3touched_n = 0;
}
