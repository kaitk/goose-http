// HTTP/2 with prior knowledge (h2c, RFC 9113) on a connection a loop hands
// over: frames in, through HPACK, to the handler's events, one exchange per
// stream; and the handler's HTTP/1.1 response back out as HEADERS and DATA,
// under the flow-control windows, the streams taking turns. A listener with
// Config.h2c (or a Listener's h2c) gives its connections here. Nothing here
// makes a system call: the loop reads and writes, and calls h2_answer with
// what it read, as it calls answer for HTTP/1.1.
namespace http;

import std;
import message;
import hpack;
import h2frame;
import timers;
import mail;

// The most streams a connection's H2Conn lists; Config.h2_max_streams is
// taken up to it.
let H2_STREAM_CAP = 256;
// The control frames a client may send in a burst, PING, SETTINGS, PRIORITY,
// RST_STREAM, WINDOW_UPDATE, and empty DATA and CONTINUATION, and how many
// a second it gets back, against floods of them (RFC 9113 §10.5). The same
// for resets of streams that hadn't been answered, the 2023 rapid reset
// attack. Past either, the connection ends with ENHANCE_YOUR_CALM. h2load,
// nghttp, and curl spend one control frame a connection, their SETTINGS, and
// a client that leaves a page resets every stream it has open, up to
// H2_STREAM_CAP: the bursts allow 100 times the one, and twice the other
// (task 014.01, "Flood budgets").
let H2_CONTROL_BURST = 100;
let H2_CONTROL_RATE = 10;
let H2_RESET_BURST = 2 * H2_STREAM_CAP;
let H2_RESET_RATE = 32;
// Streams this side reset lately, whose frames in flight are ignored
// rather than taken for a closed stream's (§5.1).
let H2_RECENT_RESETS = 16;

// An h2c connection: its pool element, which the loop's slot points to
// (EpollConn.h2).
struct H2Conn {
    ours: H2Settings = H2Settings { .. },
    peer: H2Settings = H2Settings { .. },
    dec: HpackTable = HpackTable { .. },
    enc: HpackTable = HpackTable { .. },
    // What this side may still send, and what the client may.
    send_window: i64 = H2_INITIAL_WINDOW,
    recv_window: i64 = H2_INITIAL_WINDOW,
    // Received since the last WINDOW_UPDATE for the connection.
    taken: i64 = 0,
    // The highest stream the client opened, and the preface, read with this
    // side's SETTINGS sent.
    last_stream: i64 = 0,
    started: bool = false,
    // A GOAWAY went out: no new streams.
    goaway: bool = false,
    // A DATA frame whose payload is still arriving: its stream, the bytes to
    // come with its padding, the padding, and whether END_STREAM ends it.
    data_stream: i64 = 0,
    data_left: i64 = 0,
    data_pad: i64 = 0,
    data_end: bool = false,
    // A frame longer than the read buffer, other than DATA, gathered: a run
    // of the spill pool, and how much of it has arrived.
    big: u8[:],
    big_got: i64 = 0,
    // A field block gathered from a HEADERS frame and its CONTINUATIONs: its
    // stream, whether the HEADERS ended the stream, and the bytes, a run of
    // the spill pool.
    fb_stream: i64 = 0,
    fb_end: bool = false,
    fb: u8[:],
    // The flood budgets, and when they last grew, and the streams this side
    // reset lately.
    control: i64 = H2_CONTROL_BURST,
    resets: i64 = H2_RESET_BURST,
    refilled: i64 = 0,
    recent: i64[H2_RECENT_RESETS] = [0; H2_RECENT_RESETS],
    recent_at: i64 = 0,
    // The streams open, as indexes into the stream pool, and where the
    // scheduler's turn starts.
    streams: i32[..H2_STREAM_CAP] = [],
    turn: i64 = 0,
}

// A stream, in the stream pool: its exchange, and what its frames left.
struct H2Stream<S> {
    id: i64 = 0,
    // The connection's slot in the loop's pool.
    slot: i64 = -1,
    send_window: i64 = 0,
    recv_window: i64 = 0,
    taken: i64 = 0,
    // END_STREAM came from the client, or went to it.
    remote_closed: bool = false,
    local_closed: bool = false,
    headers_sent: bool = false,
    // REQUEST was called, and whether the body is still being gathered for
    // it, as HTTP/1.1 gathers one that fits in the read buffer.
    called: bool = false,
    gathering: bool = false,
    // END is owed, after the body held while the exchange waited.
    end_owed: bool = false,
    // content-length, or -1, and the body's bytes so far.
    length: i64 = -1,
    received: i64 = 0,
    // While gathering, the request's method, target, and field lines, end
    // to end, which REQUEST's Request points into.
    method_len: i64 = 0,
    target_len: i64 = 0,
    rq: u8[:],
    // The response's head while begin keeps it open; DATA waiting for
    // window from out_at on, with END_STREAM after it where out_end; the body
    // gathered or held while the exchange waits; and the trailers, held.
    head: u8[:],
    out: u8[:],
    out_at: i64 = 0,
    out_end: bool = false,
    held: u8[:],
    trailers: u8[:],
    x: Exchange<S>,
}


// The settings this side sends, from cfg.
fn h2_settings_of(cfg: const Config&) -> H2Settings {
    return H2Settings {
        enable_push: false,
        max_concurrent_streams: clamp(cfg.h2_max_streams, 1, H2_STREAM_CAP),
        initial_window_size: clamp(cfg.h2_stream_window, 0, H2_MAX_WINDOW),
        max_header_list_size: cfg.max_head,
        no_rfc7540_priorities: true,
        ..
    };
}

// A new connection's state, for the loop to put in its pool at accept.
fn h2_conn(cfg: const Config&, now: i64) -> H2Conn {
    return H2Conn { ours: h2_settings_of(cfg), recv_window: H2_INITIAL_WINDOW, refilled: now, .. };
}

// The key of a stream's later: its connection's slot, a generation from the
// counter connections draw theirs from, and its index in the stream pool
// (decisions, "An h2 stream is an exchange").
fn h2_key(slot: i64, gen: u64, index: i64) -> u64 {
    return later_base(slot, gen) | ((index as u64) & 0xFFFFF);
}
fn h2_key_index(key: u64) -> i64 { (key & 0xFFFFF) as i64 }

// Whether stream st of the connection in slot waits for a message to key.
fn h2_waits_for(st, slot: i64, key: u64) -> bool {
    return st.slot == slot && st.id > 0 && st.x.stream.waiting && st.x.stream.later.key == key;
}

// Gives back what the connection holds: its streams, with CLOSED to each
// handler owed a call, its runs, and its pool element. The loop calls it as
// the connection closes.
fn h2_release<S, H>(h: H2Conn&, streams: H2Stream<S>[>..]&, spill: u8[>..]&, timers: Timers&, fd: i32) {
    let open = h.streams;
    for k in open {
        let st .= streams[k];
        h2_abandon(st, fd, H);
        h2_free(st, spill, timers);
        streams.free(k);
    }
    h.streams.clear();
    if h.big.len > 0 { spill.free_slice(h.big); }
    if h.fb.len > 0 { spill.free_slice(h.fb); }
    h.big = h.big[..0];
    h.fb = h.fb[..0];
}

// Ends a wait that no WAKE or TIMEOUT ends, as its stream closes or its
// handler answers: io_uring's poll of a socket wait_socket armed for it would
// hold the socket open after the handler hangs it up.
fn h2_unwait(s: Stream&) {
    guard s.waiting else { return; }
    s.waiting = false;
    net_disarm(s.later.key);
}

// Calls H with CLOSED for stream st, if it was owed another call.
fn h2_abandon<S, H>(st: H2Stream<S>&, fd: i32) {
    let x .= st.x;
    let owed = st.called && (x.stream.open || x.stream.waiting || (!st.remote_closed && !x.answered) || st.end_owed);
    h2_unwait(x.stream);
    retire(x.stream);
    guard owed else { return; }
    var sink: u8[>..] = [];
    let none = Request { .. };
    H(Event { kind: CLOSED, req: none, data: "", whole: false, trailers: "" }, &x.state,
      Reply { buf: sink, common: "", keep_alive: x.keep_alive, minor: H2_MINOR, head: x.head, stream: x.stream,
              fd: fd });
    x.stream.open = false;
}

// Gives back a stream's runs and timer; the caller frees its pool element.
fn h2_free(st, spill: u8[>..]&, timers: Timers&) {
    cancel(timers, st.x.timer);
    h2_unwait(st.x.stream);
    retire(st.x.stream);
    if st.rq.len > 0 { spill.free_slice(st.rq); }
    if st.head.len > 0 { spill.free_slice(st.head); }
    if st.out.len > 0 { spill.free_slice(st.out); }
    if st.held.len > 0 { spill.free_slice(st.held); }
    if st.trailers.len > 0 { spill.free_slice(st.trailers); }
    st.rq = st.rq[..0];
    st.head = st.head[..0];
    st.out = st.out[..0];
    st.held = st.held[..0];
    st.trailers = st.trailers[..0];
    st.id = 0;
    st.slot = -1;
}

// Whether a request's field name, not a pseudo-field, is one HTTP/2 allows:
// no uppercase, no byte at or below space, no colon, nothing past ASCII
// (§8.2.1), and none of the fields of HTTP/1.1's connection (§8.2.2).
fn h2_name_ok(name: const u8[:]) -> bool {
    guard name.len > 0 else { return false; }
    for c in name {
        guard c > ' ' && c < 0x7f && !(c >= 'A' && c <= 'Z') && c != ':' else { return false; }
    }
    return name != "connection" && name != "keep-alive" && name != "proxy-connection" &&
           name != "transfer-encoding" && name != "upgrade";
}

// Whether a field value is one HTTP/2 allows: no NUL, CR, or LF, and no
// whitespace at either end (§8.2.1).
fn h2_value_ok(value: const u8[:]) -> bool {
    for c in value { guard c != 0 && c != '\r' && c != '\n' else { return false; } }
    guard value.len > 0 else { return true; }
    let a = value[0];
    let z = value[value.len - 1];
    return a != ' ' && a != '\t' && z != ' ' && z != '\t';
}

// Whether a request's :method and :path, as HTTP/1.1's request line has
// them (parse): a token, and visible ASCII with whole escapes, from '/' or
// "*" for OPTIONS (§8.3.1); a CONNECT has no :path.
fn h2_request_ok(method: const u8[:], path: const u8[:], connect: bool) -> bool {
    guard method.len > 0 else { return false; }
    for c in method { guard is_tchar(c) else { return false; } }
    guard !connect else { return true; }
    for c in path { guard c > ' ' && c < 0x7f else { return false; } }
    return escapes_ok(path) && (path[0] == '/' || path == "*" && method == "OPTIONS");
}

// How many of a response head's line ends h2_head_block keeps from its
// search for the blank line; it searches again for any past them.
let H2_HEAD_LINES = 16;

// Appends the HPACK of the HTTP/1.1 response head at text's front, its status
// line and field lines, through enc, once the head is whole: the fields'
// names lowercased in text itself, and those of HTTP/1.1's connection
// dropped (§8.2.2). Returns the head's length with its blank line, or -1,
// with nothing appended, while the head isn't whole, as begin's isn't until
// its first send: a field can't be taken back from the table.
fn h2_head_block(enc: HpackTable&, fb: u8[>..]&, text: u8[:]) -> i64 {
    var ends: i32[..H2_HEAD_LINES] = [];
    var start = 0;
    var at = 0;
    loop {
        let nl = position(text[at..], '\n');
        guard nl >= 0 else { return -1; }
        let e = at + nl;
        at = e + 1;
        guard e > start && text[e - 1] == '\r' else { continue; }
        if e - 1 == start { break; }
        if ends.len < H2_HEAD_LINES { ends.push((e - 1) as i32); }
        start = at;
    }
    let size = at;
    hpack_begin(enc, fb);
    let line = if ends.len > 0 { text[..ends[0] as i64] } else { text[..0] };
    var status: i32 = 500;
    if line.len >= 12 && is_digit(line[9]) && is_digit(line[10]) && is_digit(line[11]) {
        let d0: i32 = line[9] - '0';
        let d1: i32 = line[10] - '0';
        let d2: i32 = line[11] - '0';
        status = d0 * 100 + d1 * 10 + d2;
    }
    var digits: u8[..3] = [];
    format(digits, status);
    hpack_encode(enc, fb, ":status", digits);
    var i = 1;
    var pos = line.len + 2;
    while pos < size - 2 {
        let cr = if i < ends.len { ends[i] as i64 } else { pos + find(text[pos..], "\r\n") };
        i++;
        let l = text[pos..cr];
        pos = cr + 2;
        let colon = position(l, ':');
        if colon <= 0 { continue; }
        let name = l[..colon];
        for &c in name { if c >= 'A' && c <= 'Z' { c += 32; } }
        if name == "connection" || name == "keep-alive" || name == "proxy-connection" ||
           name == "transfer-encoding" || name == "upgrade" { continue; }
        hpack_encode(enc, fb, name, trim(l[colon + 1..]));
    }
    return size;
}

// Answers what connection c, an h2c one in slot, has in rbuf[..rlen], into
// wbuf, as answer does for HTTP/1.1, and moves the rest of rbuf to its
// front: frames in, the handler called for each stream's events, and the
// streams' output written while wbuf is under limit: cfg.write_buffer on
// epoll, and what cfg.max_queued leaves on the completion loop. wake, unless
// its kind is NO_EVENT, is a WAKE or TIMEOUT for stream wake_at, which
// stopped waiting. A connection error writes GOAWAY and leaves c CLOSING.
// Returns the bytes left in rbuf, and whether wbuf filled with output still
// to write. gen numbers the streams' keys for later. The worker's scratch,
// which this reuses: bout, the handler's response; bfields and bpseudo, the
// request's field lines and its pseudo-fields' values; bcookie, its cookies
// joined; bhuff, HPACK's Huffman-decoded strings; and bfb, a field block to
// send.
fn h2_answer<S, H, C>(c: C&, slot: i64, h: H2Conn&, streams: H2Stream<S>[>..]&, spill: u8[>..]&,
                      rbuf: u8[:], rlen: i64, wbuf: u8[>..]&, limit: i64, bout: u8[>..]&, bfields: u8[>..]&,
                      bpseudo: u8[>..]&, bcookie: u8[>..]&, bhuff: u8[>..]&, bfb: u8[>..]&,
                      common: const u8[:],
                      cfg: const Config&, fresh: const S&, stopping: bool, now: i64, wake: const Event&,
                      wake_at: i64, timers: Timers&, overdue: u64[>..]&, gen: u64&) -> i64, bool {
    var off = 0;
    var dead = false;
    var closed_now = 0;
    let max_frame = h.ours.max_frame_size;
    let gone = Request { .. };

    // The budgets grow back with time.
    let grown = now - h.refilled;
    if grown >= 1000 / H2_CONTROL_RATE {
        h.control = min(H2_CONTROL_BURST, h.control + grown * H2_CONTROL_RATE / 1000);
        h.resets = min(H2_RESET_BURST, h.resets + grown * H2_RESET_RATE / 1000);
        h.refilled = now;
    }

    // Ends the connection with a GOAWAY of code, and CLOSED to the handlers
    // owed a call.
    fn conn_error(code: u32) {
        guard !dead else { return; }
        dead = true;
        h2_write_goaway(wbuf, h.last_stream, code);
        h.goaway = true;
        h2_release(h, streams, spill, timers, c.fd, H);
        c.state = CLOSING;
        off = rlen;
    }

    // Spends a unit of a budget, and ends the connection when it's spent.
    fn spend_control() {
        h.control--;
        if h.control < 0 { conn_error(H2_ENHANCE_YOUR_CALM); }
    }

    fn remember_reset(id: i64) {
        h.recent[h.recent_at] = id;
        h.recent_at = (h.recent_at + 1) % H2_RECENT_RESETS;
    }

    fn was_reset(id: i64) -> bool {
        for r in h.recent { if r == id { return true; } }
        return false;
    }

    // The pool index of stream id, or -1 for one not open.
    fn stream_at(id: i64) -> i64 {
        for k in h.streams { if streams[k].id == id { return k; } }
        return -1;
    }

    // Closes stream k: its pool element and its place in the list.
    fn close_stream(k: i64) {
        h2_free(streams[k], spill, timers);
        var at = 0;
        while at < h.streams.len && h.streams[at] != k { at++; }
        if at < h.streams.len { h.streams.remove_at(at); }
        streams.free(k);
        closed_now++;
    }

    // A stream error: RST_STREAM with code, CLOSED to its handler if it was
    // owed a call, and the stream closed.
    fn reset(k: i64, code: u32) {
        let st .= streams[k];
        h2_write_rst_stream(wbuf, st.id, code);
        remember_reset(st.id);
        h2_abandon(st, c.fd, H);
        close_stream(k);
    }

    // DATA frames for st, as many as the windows and data allow; the last
    // with END_STREAM when end and all of data went. Returns what went.
    fn data_frames(st: H2Stream<S>&, data: const u8[:], end: bool) -> i64 {
        var at = 0;
        loop {
            let n = min(min(data.len - at, h.peer.max_frame_size), min(st.send_window, h.send_window));
            let last = end && at + max(n, 0) == data.len;
            guard n > 0 || (last && data.len == at) else { return at; }
            h2_write_data(wbuf, st.id, data[at..at + n], last);
            at += n;
            st.send_window -= n;
            h.send_window -= n;
            if last { return at; }
            if at == data.len { return at; }
        }
    }

    // This side's END_STREAM went out: the stream closes once the client's
    // has come, and if it hasn't, the rest of the body isn't wanted (§8.1).
    fn local_end(k: i64) {
        let st .= streams[k];
        st.local_closed = true;
        if st.remote_closed {
            close_stream(k);
            return;
        }
        h2_write_rst_stream(wbuf, st.id, H2_NO_ERROR);
        remember_reset(st.id);
        close_stream(k);
    }

    // Queues body bytes for stream k's DATA, written now as far as the
    // windows allow, with END_STREAM after them where end.
    fn queue(k: i64, data: const u8[:], end: bool) {
        let st .= streams[k];
        guard !st.local_closed else { return; }
        if st.out.len - st.out_at == 0 {
            let sent = data_frames(st, data, end);
            if sent == data.len {
                if end { local_end(k); }
                return;
            }
            if st.out.len > 0 { spill.free_slice(st.out); }
            st.out = spill.alloc_slice(data.len - sent);
            copy_into(st.out, data[sent..]);
            st.out_at = 0;
            st.out_end = end;
            return;
        }
        // Behind DATA already waiting: appended to it.
        let rest = st.out.len - st.out_at;
        if st.out_at > 0 {
            copy_into(st.out[..rest], st.out[st.out_at..]);
            st.out_at = 0;
        }
        st.out = spill.realloc_slice(st.out, rest + data.len);
        copy_into(st.out[rest..], data);
        st.out_end = st.out_end || end;
    }

    // A whole response head, in bfb, and the body bytes after it: HEADERS,
    // with END_STREAM where the response ended with no body, then DATA.
    fn head_done(k: i64, body: const u8[:], ended: bool) {
        let st .= streams[k];
        h2_write_headers(wbuf, st.id, bfb, ended && body.len == 0, h.peer.max_frame_size);
        st.headers_sent = true;
        if ended && body.len == 0 {
            local_end(k);
            return;
        }
        queue(k, body, ended);
    }

    // Turns what the handler wrote into stream k's output: the HTTP/1.1
    // head into HEADERS, once it's whole, and the rest into DATA, with
    // END_STREAM once the response has ended. The head's names are
    // lowercased in bytes.
    fn emit(k: i64, bytes: u8[:]) {
        let st .= streams[k];
        guard !st.local_closed else { return; }
        let ended = !st.x.stream.open;
        if st.headers_sent {
            queue(k, bytes, ended);
            return;
        }
        if st.head.len == 0 {
            bfb.clear();
            let size = h2_head_block(h.enc, bfb, bytes);
            if size >= 0 {
                head_done(k, bytes[size..], ended);
                return;
            }
            // begin's head, open until the first send.
            if bytes.len > 0 {
                st.head = spill.alloc_slice(bytes.len);
                copy_into(st.head, bytes);
            }
            return;
        }
        let had = st.head.len;
        st.head = spill.realloc_slice(st.head, had + bytes.len);
        copy_into(st.head[had..], bytes);
        bfb.clear();
        let size = h2_head_block(h.enc, bfb, st.head);
        guard size >= 0 else { return; }
        // The head leaves the stream before head_done, which may close it.
        let text = st.head;
        st.head = st.head[..0];
        head_done(k, text[size..], ended);
        spill.free_slice(text);
    }

    // Calls H for ev on stream k, and turns what it wrote into frames.
    // Returns whether it wrote anything.
    fn call(k: i64, ev: Event) -> bool {
        // bout is empty between calls; it's cleared after the call, once
        // nothing of ev, which the checker can't tell from bout, is used.
        let st .= streams[k];
        let was_open = st.x.stream.open;
        st.x.stream.moved = false;
        H(ev, &st.x.state, Reply { buf: bout, common: common, keep_alive: st.x.keep_alive, minor: H2_MINOR,
                                   head: st.x.head, stream: st.x.stream, fd: c.fd });
        let wrote = bout.len > 0;
        if (wrote || was_open) && st.x.stream.waiting && !st.x.stream.open {
            h2_unwait(st.x.stream);
            st.x.stream.rearm = false;
        }
        retire(st.x.stream);
        if !st.x.answered && !st.x.stream.open && (wrote || was_open) { st.x.answered = true; }
        let ending = !st.x.keep_alive;
        if wrote || (was_open && !st.x.stream.open) { emit(k, bout); }
        bout.clear();
        // As HTTP/1.1's Connection: close, a handler that clears keep_alive
        // ends the connection, once the streams the client opened are done.
        if ending && !h.goaway {
            h2_write_goaway(wbuf, h.last_stream, H2_NO_ERROR);
            h.goaway = true;
        }
        return wrote;
    }

    // Answers stream k with a refusal of status, if nothing of its response
    // went yet, which closes the stream: CLOSED first to its handler, if it
    // was owed a call, as for a reset.
    fn refuse_stream(k: i64, status: i32) {
        let st .= streams[k];
        guard !st.x.answered && !st.x.stream.open && !st.headers_sent else { return; }
        h2_abandon(st, c.fd, H);
        bout.clear();
        refuse(bout, status, common);
        st.x.answered = true;
        emit(k, bout);
        bout.clear();
    }

    // Answers a stream that never opened with status, and resets it if the
    // client still has a body to send.
    fn refuse_new(id: i64, status: i32, end_stream: bool) {
        bout.clear();
        refuse(bout, status, common);
        bfb.clear();
        h2_head_block(h.enc, bfb, bout);
        h2_write_headers(wbuf, id, bfb, true, h.peer.max_frame_size);
        bout.clear();
        if !end_stream {
            h2_write_rst_stream(wbuf, id, H2_NO_ERROR);
            remember_reset(id);
        }
    }

    // The request of stream k, from what was kept while its body gathered.
    fn kept_request(st: H2Stream<S>&) -> Request {
        let m = st.method_len;
        let t = m + st.target_len;
        return Request { method: st.rq[..m], target: st.rq[m..t], minor: 1, keep_alive: true,
                         body: max(st.length, 0), fields: st.rq[t..], .. };
    }

    // After a call that the body's end leaves owing an answer: one that did
    // nothing gets 500, as HTTP/1.1's does.
    fn owe_answer(k: i64) {
        let st .= streams[k];
        guard st.id > 0 && !st.local_closed else { return; }
        if !st.x.answered && !st.x.stream.open && !st.x.stream.waiting { refuse_stream(k, 500); }
    }

    // Starts the timers later asked for, after the calls, as the HTTP/1.1
    // loops do: a stream with no timer is owed TIMEOUT (overdue), not 500.
    fn start_waits() {
        let open = h.streams;
        for k in open {
            let st .= streams[k];
            if st.x.stream.rearm && start_wait(st, timers, now) { overdue.push(st.x.stream.later.key); }
        }
    }

    // The body's pieces held while the exchange waited, then END if the
    // client's has come. Stops while the exchange waits.
    fn pump(k: i64) {
        loop {
            let st .= streams[k];
            guard st.id > 0 && st.called && !st.local_closed && !st.x.stream.waiting else { return; }
            if st.held.len > 0 {
                let id = st.id;
                let n = st.held.len;
                // The piece goes to the handler from the spill pool, which its
                // call may grow but never moves.
                call(k, Event { kind: BODY, req: gone, data: st.held, whole: false, trailers: "" });
                guard streams[k].id == id else { return; }
                let s2 .= streams[k];
                spill.free_slice(s2.held);
                s2.held = s2.held[..0];
                s2.taken += n;
                continue;
            }
            if st.end_owed {
                st.end_owed = false;
                let id = st.id;
                call(k, Event { kind: END, req: gone, data: "", whole: false, trailers: st.trailers });
                guard streams[k].id == id else { return; }
                owe_answer(k);
            }
            return;
        }
    }

    // A piece of stream k's body, from the client.
    fn body(k: i64, piece: const u8[:]) {
        let st .= streams[k];
        st.received += piece.len;
        if st.length >= 0 && st.received > st.length {
            reset(k, H2_PROTOCOL_ERROR);
            return;
        }
        if st.local_closed { return; }
        if st.received > cfg.max_body {
            refuse_stream(k, 413);
            return;
        }
        if st.gathering {
            // Within half the stream's window too, as a gathered body's
            // window comes back only once it's whole.
            if st.held.len + piece.len <= min(cfg.max_head, h.ours.initial_window_size / 2) {
                let had = st.held.len;
                st.held = spill.realloc_slice(st.held, had + piece.len);
                copy_into(st.held[had..], piece);
                return;
            }
            // Too long to gather: REQUEST now, and the body in pieces.
            st.gathering = false;
            st.called = true;
            let id = st.id;
            let req = kept_request(st);
            call(k, Event { kind: REQUEST, req: req, data: "", whole: false, trailers: "" });
            guard streams[k].id == id else { return; }
        }
        let s .= streams[k];
        if s.x.stream.waiting || s.held.len > 0 {
            let had = s.held.len;
            s.held = spill.realloc_slice(s.held, had + piece.len);
            copy_into(s.held[had..], piece);
            pump(k);
            return;
        }
        s.taken += piece.len;
        call(k, Event { kind: BODY, req: gone, data: piece, whole: false, trailers: "" });
    }

    // The client's END_STREAM on stream k: REQUEST with the body gathered,
    // or END, and the content-length checked (§8.1.1).
    fn remote_end(k: i64) {
        let st .= streams[k];
        st.remote_closed = true;
        if st.length >= 0 && st.received != st.length {
            reset(k, H2_PROTOCOL_ERROR);
            return;
        }
        if st.local_closed {
            close_stream(k);
            return;
        }
        let id = st.id;
        if st.gathering {
            st.gathering = false;
            st.called = true;
            st.taken += st.held.len;
            let req = kept_request(st);
            call(k, Event { kind: REQUEST, req: req, data: st.held, whole: true, trailers: st.trailers });
            guard streams[k].id == id else { return; }
            let s .= streams[k];
            if s.held.len > 0 {
                spill.free_slice(s.held);
                s.held = s.held[..0];
            }
            owe_answer(k);
            return;
        }
        st.end_owed = true;
        pump(k);
    }

    // A whole field block for stream id: a request, or a stream's trailers.
    fn field_block(id: i64, fb: const u8[:], end_stream: bool) {
        let k = stream_at(id);
        bfields.clear();
        bpseudo.clear();
        bcookie.clear();
        bhuff.clear();
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
        let trailers = k >= 0;
        // One byte of the block can stand for a table entry of 4 KB, so
        // nothing is kept past max_head.
        let ok = hpack_decode(h.dec, fb, bhuff) { name, value =>
            size += name.len + value.len + 32;
            if !bad && size <= cfg.max_head {
                if name.len > 0 && name[0] == ':' {
                    if regular || trailers { bad = true; }
                    else if name == ":method" && m0 < 0 {
                        m0 = bpseudo.len; bpseudo.append(value); m1 = bpseudo.len;
                    } else if name == ":path" && p0 < 0 {
                        p0 = bpseudo.len; bpseudo.append(value); p1 = bpseudo.len;
                    } else if name == ":authority" && a0 < 0 {
                        a0 = bpseudo.len; bpseudo.append(value); a1 = bpseudo.len;
                    } else if name == ":scheme" && !scheme {
                        scheme = true;
                    } else { bad = true; }
                    if !h2_value_ok(value) { bad = true; }
                } else {
                    regular = true;
                    if !h2_name_ok(name) || !h2_value_ok(value) { bad = true; }
                    else if name == "te" && value != "trailers" { bad = true; }
                    else if name == "cookie" {
                        if bcookie.len > 0 { bcookie.append("; "); }
                        bcookie.append(value);
                    } else {
                        if name == "host" { host = true; }
                        if name == "expect" {
                            // 100-continue is the only expectation (RFC 9110 §10.1.1).
                            if eq_fold(value, "100-continue") { expect = true; } else { unmet = true; }
                        }
                        if name == "content-length" {
                            let n, nok = parse_int(value);
                            if !nok || n < 0 || (length >= 0 && n != length) { bad = true; }
                            length = n;
                        }
                        bfields.append(name);
                        bfields.append(": ");
                        bfields.append(value);
                        bfields.append("\r\n");
                    }
                }
            }
        };
        guard ok else {
            conn_error(H2_COMPRESSION_ERROR);
            return;
        }
        if bcookie.len > 0 {
            bfields.append("cookie: ");
            bfields.append(bcookie);
            bfields.append("\r\n");
        }
        if trailers {
            // A stream's second field block ends it (§8.1).
            guard !bad && end_stream && size <= cfg.max_head else {
                reset(k, H2_PROTOCOL_ERROR);
                return;
            }
            let st .= streams[k];
            if st.trailers.len > 0 { spill.free_slice(st.trailers); }
            st.trailers = spill.alloc_slice(bfields.len);
            copy_into(st.trailers, bfields);
            remote_end(k);
            return;
        }
        guard !h.goaway else { return; }
        // A stream this call closed still counts: the client learns of its
        // end only once what this call writes reaches it.
        if h.streams.len + closed_now >= h.ours.max_concurrent_streams {
            h2_write_rst_stream(wbuf, id, H2_REFUSED_STREAM);
            remember_reset(id);
            return;
        }
        let connect = m0 >= 0 && bpseudo[m0..m1] == "CONNECT";
        if m0 < 0 || (connect && (a0 < 0 || scheme || p0 >= 0)) || (!connect && (!scheme || p0 < 0 || p1 == p0)) {
            bad = true;
        } else if !h2_request_ok(bpseudo[m0..m1], if connect { bpseudo[..0] } else { bpseudo[p0..p1] }, connect) {
            bad = true;
        }
        // A head past max_head was kept only in part, and gets 431 below.
        if bad && size <= cfg.max_head {
            h2_write_rst_stream(wbuf, id, H2_PROTOCOL_ERROR);
            remember_reset(id);
            return;
        }
        if size > cfg.max_head {
            refuse_new(id, 431, end_stream);
            return;
        }
        if p1 - p0 > cfg.max_line {
            refuse_new(id, 414, end_stream);
            return;
        }
        if length > cfg.max_body {
            refuse_new(id, 413, end_stream);
            return;
        }
        if unmet {
            refuse_new(id, 417, end_stream);
            return;
        }
        if a0 >= 0 && !host {
            bfields.append("host: ");
            bfields.append(bpseudo[a0..a1]);
            bfields.append("\r\n");
        }
        let method = bpseudo[m0..m1];
        let target = if connect { bpseudo[a0..a1] } else { bpseudo[p0..p1] };

        gen = gen % 0xFFFFFF + 1;
        let k2 = streams.alloc_index(H2Stream<S> { x: Exchange<S> { state: fresh, .. }, .. });
        h.streams.push(k2 as i32);
        let st .= streams[k2];
        st.id = id;
        st.slot = slot;
        st.send_window = h.peer.initial_window_size;
        st.recv_window = h.ours.initial_window_size;
        st.length = length;
        st.x.keep_alive = true;
        st.x.head = method == "HEAD";
        st.x.minor = H2_MINOR;
        st.x.since = now;
        st.x.began = now;
        st.x.stream.direct = false;
        // Without a box the key still finds the stream for its TIMEOUT.
        st.x.stream.later = MailAddress { box: c.x.stream.later.box, key: h2_key(slot, gen, k2) };
        if end_stream {
            st.remote_closed = true;
            st.called = true;
            let req = Request { method: method, target: target, minor: 1, keep_alive: true, fields: bfields, .. };
            call(k2, Event { kind: REQUEST, req: req, data: "", whole: true, trailers: "" });
            owe_answer(k2);
            return;
        }
        st.gathering = true;
        st.method_len = method.len;
        st.target_len = target.len;
        st.rq = spill.alloc_slice(method.len + target.len + bfields.len);
        copy_into(st.rq[..method.len], method);
        copy_into(st.rq[method.len..method.len + target.len], target);
        copy_into(st.rq[method.len + target.len..], bfields);
        // The client may wait for this before it sends the body; the
        // handler is called only once some of it has come.
        if expect {
            bfb.clear();
            hpack_encode(h.enc, bfb, ":status", "100");
            h2_write_headers(wbuf, id, bfb, false, h.peer.max_frame_size);
        }
    }

    // The client's settings (§6.5.3), acknowledged.
    fn settings(f: const H2Frame&) {
        if f.flags & H2_ACK != 0 { return; }
        spend_control();
        guard !dead else { return; }
        let before = h.peer.initial_window_size;
        let code = h2_apply_settings(h.peer, f.data);
        guard code == H2_NO_ERROR else {
            conn_error(code);
            return;
        }
        hpack_limit(h.enc, h.peer.header_table_size);
        let delta = h.peer.initial_window_size - before;
        if delta != 0 {
            let open = h.streams;
            for k in open {
                streams[k].send_window += delta;
                if streams[k].send_window > H2_MAX_WINDOW {
                    conn_error(H2_FLOW_CONTROL_ERROR);
                    return;
                }
            }
        }
        h2_write_settings_ack(wbuf);
    }

    // A whole frame other than DATA.
    fn frame(buf: const u8[:]) {
        let f, size, err = h2_parse(buf, max_frame);
        if err.code != 0 {
            if err.stream == 0 {
                conn_error(err.code);
                return;
            }
            let k = stream_at(err.stream);
            if k >= 0 { reset(k, err.code); }
            else {
                h2_write_rst_stream(wbuf, err.stream, err.code);
                remember_reset(err.stream);
            }
            return;
        }
        let id = f.stream;
        if h.fb_stream != 0 && (f.kind != H2_CONTINUATION || id != h.fb_stream) {
            conn_error(H2_PROTOCOL_ERROR);
            return;
        }
        match f.kind {
            H2_HEADERS => {
                guard h2_client_stream(id) else { conn_error(H2_PROTOCOL_ERROR); return; }
                let k = stream_at(id);
                if k >= 0 {
                    if streams[k].remote_closed { conn_error(H2_STREAM_CLOSED); return; }
                } else if id <= h.last_stream {
                    conn_error(H2_STREAM_CLOSED); return;
                } else {
                    h.last_stream = id;
                }
                let end = f.flags & H2_END_STREAM != 0;
                if f.flags & H2_END_HEADERS != 0 {
                    field_block(id, f.data, end);
                } else {
                    h.fb_stream = id;
                    h.fb_end = end;
                    h.fb = spill.alloc_slice(f.data.len);
                    copy_into(h.fb, f.data);
                }
            },
            H2_CONTINUATION => {
                guard h.fb_stream != 0 else { conn_error(H2_PROTOCOL_ERROR); return; }
                if f.data.len == 0 && f.flags & H2_END_HEADERS == 0 { spend_control(); }
                guard !dead else { return; }
                let had = h.fb.len;
                guard had + f.data.len <= 2 * cfg.max_head + max_frame else {
                    conn_error(H2_ENHANCE_YOUR_CALM); return;
                }
                h.fb = spill.realloc_slice(h.fb, had + f.data.len);
                copy_into(h.fb[had..], f.data);
                if f.flags & H2_END_HEADERS != 0 {
                    let sid = h.fb_stream;
                    h.fb_stream = 0;
                    field_block(sid, h.fb, h.fb_end);
                    if h.fb.len > 0 { spill.free_slice(h.fb); }
                    h.fb = h.fb[..0];
                }
            },
            H2_PRIORITY => { spend_control(); },
            H2_RST_STREAM => {
                guard id <= h.last_stream else { conn_error(H2_PROTOCOL_ERROR); return; }
                let k = stream_at(id);
                guard k >= 0 else { return; }
                if !streams[k].x.answered {
                    h.resets--;
                    if h.resets < 0 { conn_error(H2_ENHANCE_YOUR_CALM); return; }
                }
                // The client's frames after its own reset are STREAM_CLOSED
                // (§5.1), so the stream isn't remembered as one this side
                // reset.
                h2_abandon(streams[k], c.fd, H);
                close_stream(k);
                // The client knows this one closed (closed_now).
                closed_now--;
            },
            H2_SETTINGS => { settings(f); },
            H2_PUSH_PROMISE => { conn_error(H2_PROTOCOL_ERROR); },
            H2_PING => {
                if f.flags & H2_ACK == 0 {
                    spend_control();
                    if !dead { h2_write_ping(wbuf, f.data, true); }
                }
            },
            H2_GOAWAY => {
                // The client opens no more streams; those open finish.
                h.goaway = true;
            },
            H2_WINDOW_UPDATE => {
                if id == 0 {
                    h.send_window += f.increment;
                    if h.send_window > H2_MAX_WINDOW { conn_error(H2_FLOW_CONTROL_ERROR); return; }
                } else {
                    guard id <= h.last_stream else { conn_error(H2_PROTOCOL_ERROR); return; }
                    let k = stream_at(id);
                    guard k >= 0 else { return; }
                    streams[k].send_window += f.increment;
                    if streams[k].send_window > H2_MAX_WINDOW { reset(k, H2_FLOW_CONTROL_ERROR); }
                }
            },
            _ => {},
        }
    }

    // A DATA frame's header at rbuf[off..], which must hold it and, if
    // PADDED, its pad length. Returns false to wait for more bytes.
    fn data_head() -> bool {
        let len = h2_be24(rbuf, off);
        let flags = rbuf[off + 4];
        let id = h2_stream_id(rbuf, off + 5);
        let padded = flags & H2_PADDED != 0;
        guard !padded || rlen - off >= H2_HEAD + 1 else { return false; }
        guard id != 0 else {
            conn_error(H2_PROTOCOL_ERROR);
            return true;
        }
        if h.fb_stream != 0 {
            conn_error(H2_PROTOCOL_ERROR);
            return true;
        }
        var padding = 0;
        if padded {
            guard len >= 1 else {
                conn_error(H2_FRAME_SIZE_ERROR);
                return true;
            }
            padding = rbuf[off + H2_HEAD];
            guard padding <= len - 1 else {
                conn_error(H2_PROTOCOL_ERROR);
                return true;
            }
        }
        guard len <= h.recv_window else {
            conn_error(H2_FLOW_CONTROL_ERROR);
            return true;
        }
        h.recv_window -= len;
        let end = flags & H2_END_STREAM != 0;
        if len == 0 && !end { spend_control(); }
        guard !dead else { return true; }
        var target = id;
        let k = stream_at(id);
        if k < 0 {
            if id > h.last_stream {
                conn_error(H2_PROTOCOL_ERROR);
                return true;
            }
            if !was_reset(id) {
                conn_error(H2_STREAM_CLOSED);
                return true;
            }
            target = 0;
        } else if streams[k].remote_closed {
            reset(k, H2_STREAM_CLOSED);
            target = 0;
        } else if len > streams[k].recv_window {
            reset(k, H2_FLOW_CONTROL_ERROR);
            target = 0;
        } else {
            streams[k].recv_window -= len;
            // The pad length counts against the window as the padding does.
            if padded { streams[k].taken += 1; }
        }
        off += H2_HEAD + (if padded { 1 } else { 0 });
        h.data_stream = target;
        h.data_left = len - (if padded { 1 } else { 0 });
        h.data_pad = padding;
        h.data_end = end;
        h.taken += if padded { 1 } else { 0 };
        if h.data_left == 0 { data_done(); }
        return true;
    }

    // What of the DATA frame in progress rbuf holds.
    fn data_take() {
        let n = min(rlen - off, h.data_left);
        let payload = max(0, min(n, h.data_left - h.data_pad));
        let piece = rbuf[off..off + payload];
        off += n;
        h.data_left -= n;
        h.taken += n;
        if h.data_stream != 0 {
            let k = stream_at(h.data_stream);
            if k >= 0 {
                if n > payload { streams[k].taken += n - payload; }
                if payload > 0 { body(k, piece); }
            }
        }
        if h.data_left == 0 { data_done(); }
    }

    fn data_done() {
        let id = h.data_stream;
        h.data_stream = 0;
        guard id != 0 && h.data_end else { return; }
        let k = stream_at(id);
        if k >= 0 { remote_end(k); }
    }

    // WINDOW_UPDATEs for what the client sent and the handlers took, once
    // half a window has gone.
    fn give_back() {
        if h.taken > 0 && h.taken >= cfg.h2_conn_window / 2 {
            h2_write_window_update(wbuf, 0, h.taken);
            h.recv_window += h.taken;
            h.taken = 0;
        }
        for k in h.streams {
            let st .= streams[k];
            if !st.remote_closed && st.taken > 0 && st.taken >= h.ours.initial_window_size / 2 {
                h2_write_window_update(wbuf, st.id, st.taken);
                st.recv_window += st.taken;
                st.taken = 0;
            }
        }
    }

    // The streams' waiting DATA, a frame each in turn, and MORE for the
    // responses begun with begin, until wbuf holds limit. Returns whether it
    // stopped there with more to write.
    fn schedule() -> bool {
        loop {
            var moved = false;
            let order = h.streams;
            let n = order.len;
            for j in n {
                if wbuf.len >= limit { return true; }
                let k: i64 = order[(h.turn + j) % n];
                let st .= streams[k];
                if st.slot != slot || st.id == 0 { continue; }
                let left = st.out.len - st.out_at;
                if left > 0 || (st.out_end && st.out.len > 0) {
                    let room = min(min(left, h.peer.max_frame_size), min(st.send_window, h.send_window));
                    if room > 0 {
                        let last = st.out_end && room == left;
                        h2_write_data(wbuf, st.id, st.out[st.out_at..st.out_at + room], last);
                        st.out_at += room;
                        st.send_window -= room;
                        h.send_window -= room;
                        moved = true;
                        if st.out_at == st.out.len {
                            spill.free_slice(st.out);
                            st.out = st.out[..0];
                            st.out_at = 0;
                            if st.out_end { local_end(k); }
                        }
                    }
                    continue;
                }
                // MORE, as HTTP/1.1 offers it: once the body has ended, while
                // the stream's window is open.
                if st.called && st.x.stream.open && !st.x.stream.waiting && st.remote_closed && st.held.len == 0 &&
                   !st.local_closed && st.send_window > 0 && h.send_window > 0 {
                    let id = st.id;
                    let wrote = call(k, Event { kind: MORE, req: gone, data: "", whole: false, trailers: "" });
                    guard streams[k].id == id else {
                        moved = true;
                        continue;
                    }
                    let s .= streams[k];
                    if !wrote && !s.x.stream.moved && s.x.stream.open && !s.x.stream.waiting {
                        reset(k, H2_INTERNAL_ERROR);
                    }
                    moved = true;
                }
            }
            if n > 0 { h.turn = (h.turn + 1) % n; }
            guard moved && !dead else { return false; }
        }
    }

    if !h.started {
        let p = h2_preface(rbuf[..rlen]);
        if p == 0 { return rlen, false; }
        if p < 0 {
            conn_error(H2_PROTOCOL_ERROR);
            return 0, false;
        }
        h.started = true;
        off = p;
        h2_write_settings(wbuf, h.ours);
        if cfg.h2_conn_window > H2_INITIAL_WINDOW {
            let more = min(cfg.h2_conn_window, H2_MAX_WINDOW) - H2_INITIAL_WINDOW;
            h2_write_window_update(wbuf, 0, more);
            h.recv_window += more;
        }
    }

    if wake.kind != NO_EVENT && wake_at >= 0 && streams[wake_at].slot == slot {
        let id = streams[wake_at].id;
        call(wake_at, wake);
        if streams[wake_at].id == id {
            let st .= streams[wake_at];
            if st.remote_closed && !st.end_owed && st.held.len == 0 { owe_answer(wake_at); }
            pump(wake_at);
        }
    }

    while off < rlen && !dead {
        if h.data_left > 0 {
            data_take();
            continue;
        }
        if h.big_got > 0 {
            let n = min(rlen - off, h.big.len - h.big_got);
            copy_into(h.big[h.big_got..h.big_got + n], rbuf[off..off + n]);
            h.big_got += n;
            off += n;
            if h.big_got == h.big.len {
                frame(h.big);
                if h.big.len > 0 { spill.free_slice(h.big); }
                h.big = h.big[..0];
                h.big_got = 0;
            }
            continue;
        }
        guard rlen - off >= H2_HEAD else { break; }
        let len = h2_be24(rbuf, off);
        guard len <= max_frame else {
            conn_error(H2_FRAME_SIZE_ERROR);
            break;
        }
        if rbuf[off + 3] == H2_DATA {
            guard data_head() else { break; }
            continue;
        }
        let size = H2_HEAD + len;
        if size > rlen - off {
            guard size > rbuf.len else { break; }
            h.big = spill.alloc_slice(size);
            let n = rlen - off;
            copy_into(h.big[..n], rbuf[off..rlen]);
            h.big_got = n;
            off = rlen;
            break;
        }
        frame(rbuf[off..off + size]);
        if !dead { off += size; }
    }
    var full = false;
    if !dead {
        give_back();
        full = schedule();
        start_waits();
        if stopping && !h.goaway {
            h2_write_goaway(wbuf, h.last_stream, H2_NO_ERROR);
            h.goaway = true;
        }
        if h.goaway && h.streams.len == 0 && !full { c.state = CLOSING; }
    }
    let rest = if dead { 0 } else { rlen - off };
    if rest > 0 && off > 0 { copy_into(rbuf[..rest], rbuf[off..rlen]); }
    return rest, full;
}
