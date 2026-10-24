// QPACK, HTTP/3's field compression (RFC 9204), with the static table only:
// this side's SETTINGS give the dynamic table no capacity and no blocked
// streams, so the peer's encoder may refer to nothing else, and this side's
// encoder never inserts. Bytes alone, as hpack.goose, whose integers and
// Huffman code QPACK shares.
namespace http;

import std;
import hpack;

struct QpackStatic { name: const u8[:], value: const u8[:] }

let QPACK_STATIC_COUNT = 99;

let QPACK_STATIC: QpackStatic[QPACK_STATIC_COUNT] = [
    QpackStatic { name: ":authority", value: "" },
    QpackStatic { name: ":path", value: "/" },
    QpackStatic { name: "age", value: "0" },
    QpackStatic { name: "content-disposition", value: "" },
    QpackStatic { name: "content-length", value: "0" },
    QpackStatic { name: "cookie", value: "" },
    QpackStatic { name: "date", value: "" },
    QpackStatic { name: "etag", value: "" },
    QpackStatic { name: "if-modified-since", value: "" },
    QpackStatic { name: "if-none-match", value: "" },
    QpackStatic { name: "last-modified", value: "" },
    QpackStatic { name: "link", value: "" },
    QpackStatic { name: "location", value: "" },
    QpackStatic { name: "referer", value: "" },
    QpackStatic { name: "set-cookie", value: "" },
    QpackStatic { name: ":method", value: "CONNECT" },
    QpackStatic { name: ":method", value: "DELETE" },
    QpackStatic { name: ":method", value: "GET" },
    QpackStatic { name: ":method", value: "HEAD" },
    QpackStatic { name: ":method", value: "OPTIONS" },
    QpackStatic { name: ":method", value: "POST" },
    QpackStatic { name: ":method", value: "PUT" },
    QpackStatic { name: ":scheme", value: "http" },
    QpackStatic { name: ":scheme", value: "https" },
    QpackStatic { name: ":status", value: "103" },
    QpackStatic { name: ":status", value: "200" },
    QpackStatic { name: ":status", value: "304" },
    QpackStatic { name: ":status", value: "404" },
    QpackStatic { name: ":status", value: "503" },
    QpackStatic { name: "accept", value: "*/*" },
    QpackStatic { name: "accept", value: "application/dns-message" },
    QpackStatic { name: "accept-encoding", value: "gzip, deflate, br" },
    QpackStatic { name: "accept-ranges", value: "bytes" },
    QpackStatic { name: "access-control-allow-headers", value: "cache-control" },
    QpackStatic { name: "access-control-allow-headers", value: "content-type" },
    QpackStatic { name: "access-control-allow-origin", value: "*" },
    QpackStatic { name: "cache-control", value: "max-age=0" },
    QpackStatic { name: "cache-control", value: "max-age=2592000" },
    QpackStatic { name: "cache-control", value: "max-age=604800" },
    QpackStatic { name: "cache-control", value: "no-cache" },
    QpackStatic { name: "cache-control", value: "no-store" },
    QpackStatic { name: "cache-control", value: "public, max-age=31536000" },
    QpackStatic { name: "content-encoding", value: "br" },
    QpackStatic { name: "content-encoding", value: "gzip" },
    QpackStatic { name: "content-type", value: "application/dns-message" },
    QpackStatic { name: "content-type", value: "application/javascript" },
    QpackStatic { name: "content-type", value: "application/json" },
    QpackStatic { name: "content-type", value: "application/x-www-form-urlencoded" },
    QpackStatic { name: "content-type", value: "image/gif" },
    QpackStatic { name: "content-type", value: "image/jpeg" },
    QpackStatic { name: "content-type", value: "image/png" },
    QpackStatic { name: "content-type", value: "text/css" },
    QpackStatic { name: "content-type", value: "text/html; charset=utf-8" },
    QpackStatic { name: "content-type", value: "text/plain" },
    QpackStatic { name: "content-type", value: "text/plain;charset=utf-8" },
    QpackStatic { name: "range", value: "bytes=0-" },
    QpackStatic { name: "strict-transport-security", value: "max-age=31536000" },
    QpackStatic { name: "strict-transport-security", value: "max-age=31536000; includesubdomains" },
    QpackStatic { name: "strict-transport-security", value: "max-age=31536000; includesubdomains; preload" },
    QpackStatic { name: "vary", value: "accept-encoding" },
    QpackStatic { name: "vary", value: "origin" },
    QpackStatic { name: "x-content-type-options", value: "nosniff" },
    QpackStatic { name: "x-xss-protection", value: "1; mode=block" },
    QpackStatic { name: ":status", value: "100" },
    QpackStatic { name: ":status", value: "204" },
    QpackStatic { name: ":status", value: "206" },
    QpackStatic { name: ":status", value: "302" },
    QpackStatic { name: ":status", value: "400" },
    QpackStatic { name: ":status", value: "403" },
    QpackStatic { name: ":status", value: "421" },
    QpackStatic { name: ":status", value: "425" },
    QpackStatic { name: ":status", value: "500" },
    QpackStatic { name: "accept-language", value: "" },
    QpackStatic { name: "access-control-allow-credentials", value: "FALSE" },
    QpackStatic { name: "access-control-allow-credentials", value: "TRUE" },
    QpackStatic { name: "access-control-allow-headers", value: "*" },
    QpackStatic { name: "access-control-allow-methods", value: "get" },
    QpackStatic { name: "access-control-allow-methods", value: "get, post, options" },
    QpackStatic { name: "access-control-allow-methods", value: "options" },
    QpackStatic { name: "access-control-expose-headers", value: "content-length" },
    QpackStatic { name: "access-control-request-headers", value: "content-type" },
    QpackStatic { name: "access-control-request-method", value: "get" },
    QpackStatic { name: "access-control-request-method", value: "post" },
    QpackStatic { name: "alt-svc", value: "clear" },
    QpackStatic { name: "authorization", value: "" },
    QpackStatic { name: "content-security-policy", value: "script-src 'none'; object-src 'none'; base-uri 'none'" },
    QpackStatic { name: "early-data", value: "1" },
    QpackStatic { name: "expect-ct", value: "" },
    QpackStatic { name: "forwarded", value: "" },
    QpackStatic { name: "if-range", value: "" },
    QpackStatic { name: "origin", value: "" },
    QpackStatic { name: "purpose", value: "prefetch" },
    QpackStatic { name: "server", value: "" },
    QpackStatic { name: "timing-allow-origin", value: "*" },
    QpackStatic { name: "upgrade-insecure-requests", value: "1" },
    QpackStatic { name: "user-agent", value: "" },
    QpackStatic { name: "x-forwarded-for", value: "" },
    QpackStatic { name: "x-frame-options", value: "deny" },
    QpackStatic { name: "x-frame-options", value: "sameorigin" },
];

// A string literal (§4.1.2) whose length has an n-bit prefix after its H
// bit, at buf[pos], decoded into scratch when Huffman-coded: the string, a
// slice of buf or of scratch's tail, and the position after it; -1 where it's
// truncated, or its Huffman code is bad.
fn qpack_string(buf: const u8[:], pos: i64, n: i64, scratch: u8[>..]&) -> i64, i64, i64, bool {
    guard pos < buf.len else { return 0, 0, -1, false; }
    let huffman = (buf[pos] >> n) & 1 != 0;
    let len, p = hpack_read_int(buf, pos, n);
    guard p >= 0 && len <= buf.len - p else { return 0, 0, -1, false; }
    guard huffman else { return p, p + len, p + len, false; }
    let at = scratch.len;
    guard hpack_unhuffman(scratch, buf[p..p + len]) else { return 0, 0, -1, false; }
    return at, scratch.len, p + len, true;
}

// Decodes a field section (§4.5) that refers to the static table at most,
// calling F(name, value) for each field line in order; names and values point
// into fb, the static table, or scratch, and last until the call returns.
// False for one that can't be decoded with no dynamic table: the stream's
// QPACK_DECOMPRESSION_FAILED, a connection error (§2.2.3).
fn qpack_decode<F>(fb: const u8[:], scratch: u8[>..]&) -> bool {
    // The Required Insert Count must be 0: the table has no capacity.
    let ric, p0 = hpack_read_int(fb, 0, 8);
    guard p0 >= 0 && ric == 0 else { return false; }
    let base, p1 = hpack_read_int(fb, p0, 7);
    guard p1 >= 0 else { return false; }
    var pos = p1;
    while pos < fb.len {
        let b = fb[pos];
        if b & 0x80 != 0 {
            // An indexed field line: static only (T set).
            guard b & 0x40 != 0 else { return false; }
            let i, p = hpack_read_int(fb, pos, 6);
            guard p >= 0 && i < QPACK_STATIC_COUNT else { return false; }
            F(QPACK_STATIC[i].name, QPACK_STATIC[i].value);
            pos = p;
        } else if b & 0x40 != 0 {
            // A literal with a name reference, static only.
            guard b & 0x10 != 0 else { return false; }
            let i, p = hpack_read_int(fb, pos, 4);
            guard p >= 0 && i < QPACK_STATIC_COUNT else { return false; }
            let v0, v1, next, vh = qpack_string(fb, p, 7, scratch);
            guard next >= 0 else { return false; }
            let value = if vh { scratch[v0..v1] } else { fb[v0..v1] };
            F(QPACK_STATIC[i].name, value);
            pos = next;
        } else if b & 0x20 != 0 {
            // A literal with a literal name.
            let n0, n1, after, nh = qpack_string(fb, pos, 3, scratch);
            guard after >= 0 else { return false; }
            let v0, v1, next, vh = qpack_string(fb, after, 7, scratch);
            guard next >= 0 else { return false; }
            let name = if nh { scratch[n0..n1] } else { fb[n0..n1] };
            let value = if vh { scratch[v0..v1] } else { fb[v0..v1] };
            F(name, value);
            pos = next;
        } else {
            // Post-base references reach into the dynamic table.
            return false;
        }
    }
    return true;
}

// Appends the field section prefix (§4.5.1): no dynamic table, so a Required
// Insert Count and a Base of 0.
fn qpack_begin(out: u8[>..]&) {
    out.push(0);
    out.push(0);
}

// Appends s as a string literal with an n-bit prefix after its H bit, the
// bits above taken from flags, Huffman-coded unless that's longer.
fn qpack_put_string(out: u8[>..]&, flags: u8, n: i64, s: const u8[:]) {
    let h = hpack_huffman_len(s);
    if h < s.len {
        hpack_int(out, flags | (1 << n) as! u8, n, h);
        hpack_huffman(out, s);
    } else {
        hpack_int(out, flags, n, s.len);
        out.append(s);
    }
}

// The static table's index for a status's :status, or -1.
fn qpack_status_index(status: i32) -> i64 {
    match status {
        200 => 25, 404 => 27, 304 => 26, 204 => 64, 206 => 65, 302 => 66, 400 => 67, 403 => 68,
        500 => 71, 503 => 28, 103 => 24, 100 => 63, 421 => 69, 425 => 70,
        _ => -1,
    }
}

// The static table's entry for name and value, and the first for name
// alone; -1 for none.
fn qpack_find(name: const u8[:], value: const u8[:]) -> i64, i64 {
    var at = hpack_name_hash(name);
    var k: i64 = 0;
    loop {
        k = QPACK_NAMES[at];
        guard k > 0 else { return -1, -1; }
        if QPACK_STATIC[k - 1].name == name { break; }
        at = (at + 1) % HPACK_NAME_SLOTS;
    }
    let named = k - 1;
    var i = named;
    loop {
        if QPACK_STATIC[i].value == value { return i, named; }
        let n: i64 = QPACK_NEXT[i];
        guard n > 0 else { return -1, named; }
        i = n - 1;
    }
}

// Each name's first entry, plus one, in slots by hpack_name_hash; and each
// entry's next with the same name, plus one, or 0: a name's entries aren't
// next to each other in QPACK's table, as they are in HPACK's.
let QPACK_NAMES = qpack_names();
let QPACK_NEXT = qpack_next();

fn qpack_names() -> u8[HPACK_NAME_SLOTS] {
    var slots: u8[HPACK_NAME_SLOTS] = [0; HPACK_NAME_SLOTS];
    for k in QPACK_STATIC_COUNT {
        var at = hpack_name_hash(QPACK_STATIC[k].name);
        var seen = false;
        while slots[at] != 0 {
            if QPACK_STATIC[slots[at] - 1].name == QPACK_STATIC[k].name { seen = true; }
            at = (at + 1) % HPACK_NAME_SLOTS;
        }
        if !seen { slots[at] = (k + 1) as u8; }
    }
    return slots;
}

fn qpack_next() -> u8[QPACK_STATIC_COUNT] {
    var next: u8[QPACK_STATIC_COUNT] = [0; QPACK_STATIC_COUNT];
    for k in QPACK_STATIC_COUNT {
        for j in k + 1..QPACK_STATIC_COUNT {
            if QPACK_STATIC[j].name == QPACK_STATIC[k].name {
                next[k] = (j + 1) as u8;
                break;
            }
        }
    }
    return next;
}

// Appends a field line for name, lowercase, and value (§4.5): the static
// table's whole entry where there is one, else a literal with its name
// from the table where it has the name, else a literal with a literal name.
// None is ever added to a table, so the N bit stays clear.
fn qpack_encode(out: u8[>..]&, name: const u8[:], value: const u8[:]) {
    let exact, named = qpack_find(name, value);
    if exact >= 0 {
        hpack_int(out, 0xc0, 6, exact);
    } else if named >= 0 {
        hpack_int(out, 0x50, 4, named);
        qpack_put_string(out, 0, 7, value);
    } else {
        qpack_put_string(out, 0x20, 3, name);
        qpack_put_string(out, 0, 7, value);
    }
}

// Appends :status for status.
fn qpack_status(out: u8[>..]&, status: i32) {
    let i = qpack_status_index(status);
    if i >= 0 {
        hpack_int(out, 0xc0, 6, i);
        return;
    }
    var digits: u8[..3] = [];
    format(digits, status);
    hpack_int(out, 0x50, 4, 24);
    qpack_put_string(out, 0, 7, digits);
}
