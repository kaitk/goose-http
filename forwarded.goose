// Client addresses: the peer of a request's connection, and the client that
// a proxy the program trusts forwarded the request for, from Forwarded (RFC
// 7239) or X-Forwarded-For.
//
//   // Once, before serving:
//   let proxies, ok = http::network("10.0.0.0/8");
//   // In the handler, at REQUEST:
//   let a, known = http::client(req, out, [proxies]);
//   var text: u8[>..] = [];
//   if known { http::format_address(text, a); }
namespace http;

import std;
import message;
import media;
import sys;

// An IPv4 or IPv6 address, an IPv4 one as IPv4-mapped IPv6
// (::ffff:192.0.2.1), and a port, 0 when not known.
struct Address { ip: u8[16] = [0; 16], port: i32 = 0 }

// The addresses whose first bits bits are ip's, as "10.0.0.0/8" or
// "fd00::/8"; an IPv4 network's bits count the 96 of the IPv4-mapped prefix.
struct Network { ip: u8[16] = [0; 16], bits: i32 = 0 }

// The address of out's connection's peer, and whether it has one: a request
// that a loop didn't give, or a peer without an IP address, has none. A
// getpeername, made only when called; on a direct descriptor
// (Config.ring_direct), the address its accept kept.
fn peer(out: Reply) -> Address, bool {
    var a = Address { .. };
    guard out.fd >= 0 else { return a, false; }
    let port = net_peer(out.fd, a.ip);
    guard port >= 0 else { return a, false; }
    a.port = port;
    return a, true;
}

// The client req came from, and whether it is known. That is the peer,
// unless the peer is in trusted: then it's the nearest address in the
// request's Forwarded fields, or without one in its X-Forwarded-For, that
// isn't in trusted, or the farthest if all are. A hop that isn't an
// address, as Forwarded's "unknown" or an obfuscated name, ends the walk at
// the trusted hop before it.
fn client(req: const Request&, out: Reply, trusted: const Network[:]) -> Address, bool {
    let p, ok = peer(out);
    guard ok else { return p, false; }
    return forwarded_client(req, p, trusted), true;
}

// client, for a request from peer p.
fn forwarded_client(req: const Request&, p: Address, trusted: const Network[:]) -> Address {
    guard within(p, trusted) else { return p; }
    // The hops come farthest first. The walk from the nearest ends at the
    // first hop that isn't trusted; read in order, the client is the last
    // such hop, unless a hop that can't be read comes after it.
    var best = p;
    var from_peer = true;
    fn hop(text: const u8[:]) {
        let a, ok = node(text);
        if !ok {
            best = p;
            from_peer = true;
        } else if !within(a, trusted) || from_peer {
            best = a;
            from_peer = false;
        }
    }
    let forwarded = has_field(req, "forwarded");
    var pos = 0;
    while pos < req.fields.len {
        let n, v, next = field_at(req.fields, pos);
        pos = next;
        if forwarded && same_name(n, "forwarded") {
            var at = 0;
            loop {
                let f, end, ok = forwarded_for(v, at);
                if !ok {
                    // An element that can't be read hides the hops before it.
                    best = p;
                    from_peer = true;
                    break;
                }
                hop(f);
                if end == v.len { break; }
                at = end + 1;
            }
        } else if !forwarded && same_name(n, "x-forwarded-for") {
            var at = 0;
            loop {
                let c = position(v[at..], ',');
                let end = if c < 0 { v.len } else { at + c };
                hop(trim_ows(v[at..end]));
                if end == v.len { break; }
                at = end + 1;
            }
        }
    }
    return best;
}

fn has_field(req: const Request&, name: const u8[:]) -> bool {
    let v, found = field_of(req, name);
    return found;
}

// The for parameter of the Forwarded element at value[at..], without its
// quotes, where the element ends (a comma outside a quoted string, or the
// end), and whether the element can be read. An element without for gives
// "", which isn't an address.
fn forwarded_for(value: const u8[:], at: i64) -> const u8[:], i64, bool {
    var f = value[at..at];
    var i = at;
    loop {
        while i < value.len && (value[i] == ' ' || value[i] == '\t') { i++; }
        let n0 = i;
        while i < value.len && is_tchar(value[i]) { i++; }
        guard i > n0 && i < value.len && value[i] == '=' else { return f, i, false; }
        let name = value[n0..i];
        i++;
        var v = value[i..i];
        if i < value.len && value[i] == '"' {
            let q = quoted_end(value, i);
            guard q > 0 else { return f, i, false; }
            v = value[i + 1..q - 1];
            i = q;
        } else {
            let v0 = i;
            while i < value.len && is_tchar(value[i]) { i++; }
            guard i > v0 else { return f, i, false; }
            v = value[v0..i];
        }
        if same_name(name, "for") { f = v; }
        while i < value.len && (value[i] == ' ' || value[i] == '\t') { i++; }
        if i == value.len || value[i] == ',' { return f, i, true; }
        guard value[i] == ';' else { return f, i, false; }
        i++;
    }
}

// The address in a hop, and whether it is one: an IPv4 address or a
// bracketed IPv6 one, either with a ":port" after it, or a bare IPv6 one, as
// some proxies write in X-Forwarded-For.
fn node(text: const u8[:]) -> Address, bool {
    var a = Address { .. };
    var host = text;
    var port = text[..0];
    if text.len > 0 && text[0] == '[' {
        let close = position(text, ']');
        guard close > 0 else { return a, false; }
        host = text[1..close];
        let rest = text[close + 1..];
        if rest.len > 0 {
            guard rest[0] == ':' else { return a, false; }
            port = rest[1..];
            guard port.len > 0 else { return a, false; }
        }
        guard ipv6_into(host, a.ip) else { return a, false; }
    } else {
        let colon = position(text, ':');
        if colon >= 0 && position(text[colon + 1..], ':') < 0 {
            host = text[..colon];
            port = text[colon + 1..];
            guard port.len > 0 else { return a, false; }
        }
        let ok = if position(host, ':') >= 0 { ipv6_into(host, a.ip) } else { ipv4_into(host, a.ip) };
        guard ok else { return a, false; }
    }
    if port.len > 0 {
        guard port.len <= 5 && digits_only(port) else { return a, false; }
        let n, ok = parse_int(port);
        guard ok && n <= 65535 else { return a, false; }
        a.port = n as i32;
    }
    return a, true;
}

// The address text names, IPv4 dotted or IPv6 (RFC 4291 §2.2), without a
// port or a zone, and whether it is one.
fn address(text: const u8[:]) -> Address, bool {
    var a = Address { .. };
    let ok = if position(text, ':') >= 0 { ipv6_into(text, a.ip) } else { ipv4_into(text, a.ip) };
    return a, ok;
}

// The network text names, an address with "/bits" or alone for that one
// address, and whether it is one.
fn network(text: const u8[:]) -> Network, bool {
    var n = Network { .. };
    let slash = position(text, '/');
    let host = if slash < 0 { text } else { text[..slash] };
    let a, ok = address(host);
    guard ok else { return n, false; }
    n.ip = a.ip;
    let v4 = position(host, ':') < 0;
    let most = if v4 { 32 } else { 128 };
    var bits = most;
    if slash >= 0 {
        let b = text[slash + 1..];
        guard b.len > 0 && b.len <= 3 && digits_only(b) else { return n, false; }
        let v, good = parse_int(b);
        guard good && v <= most else { return n, false; }
        bits = v;
    }
    let total = if v4 { 96 + bits } else { bits };
    n.bits = total as i32;
    return n, true;
}

// Whether a is in network n.
fn in_network(a: Address, n: Network) -> bool {
    let whole = n.bits / 8;
    for i in whole { guard a.ip[i] == n.ip[i] else { return false; } }
    let rest = n.bits % 8;
    guard rest > 0 else { return true; }
    let mask = (0xff00 >> rest) as! u8;
    return (a.ip[whole] & mask) == (n.ip[whole] & mask);
}

// Whether a is in any of nets.
fn within(a: Address, nets: const Network[:]) -> bool {
    for n in nets { if in_network(a, n) { return true; } }
    return false;
}

// Whether a is an IPv4 address, IPv4-mapped.
fn is_ipv4(a: Address) -> bool {
    for i in 10 { guard a.ip[i] == 0 else { return false; } }
    return a.ip[10] == 0xff && a.ip[11] == 0xff;
}

// Appends a's address to out, without its port: IPv4 dotted, and IPv6 as
// RFC 5952 §4 has it, in lowercase with the longest run of two or more zero
// groups, the first of equal ones, as "::".
fn format_address(out: u8[>..]&, a: Address) {
    if is_ipv4(a) {
        for i in 4 {
            if i > 0 { out.push('.'); }
            format(out, a.ip[12 + i]);
        }
        return;
    }
    var run = -1;
    var run_len = 0;
    var i = 0;
    while i < 8 {
        var j = i;
        while j < 8 && a.ip[2 * j] == 0 && a.ip[2 * j + 1] == 0 { j++; }
        if j - i > run_len && j - i >= 2 {
            run = i;
            run_len = j - i;
        }
        i = if j > i { j } else { i + 1 };
    }
    i = 0;
    while i < 8 {
        if i == run {
            out.append("::");
            i += run_len;
            continue;
        }
        if i > 0 && i != run + run_len { out.push(':'); }
        hex_size(out, ((a.ip[2 * i] as i64) << 8) | a.ip[2 * i + 1]);
        i++;
    }
}

// Writes the IPv4 address in s, as four decimal octets without leading
// zeros (RFC 3986's dec-octet), into ip as IPv4-mapped IPv6.
fn ipv4_into(s: const u8[:], ip: u8[16]&) -> bool {
    var i = 0;
    for k in 4 {
        if k > 0 {
            guard i < s.len && s[i] == '.' else { return false; }
            i++;
        }
        let d0 = i;
        var n = 0;
        while i < s.len && is_digit(s[i]) && i - d0 < 3 {
            n = n * 10 + (s[i] - '0');
            i++;
        }
        guard i > d0 && n <= 255 && (i - d0 == 1 || s[d0] != '0') else { return false; }
        ip[12 + k] = n as! u8;
    }
    guard i == s.len else { return false; }
    for k in 10 { ip[k] = 0; }
    ip[10] = 0xff;
    ip[11] = 0xff;
    return true;
}

// Writes the IPv6 address in s, of hex groups with at most one "::" and an
// IPv4 address in its last 32 bits allowed, into ip.
fn ipv6_into(s: const u8[:], ip: u8[16]&) -> bool {
    var n = 0;          // bytes written
    var gap = -1;       // where "::" stands, in bytes
    var i = 0;
    if s.len >= 2 && s[0] == ':' && s[1] == ':' {
        gap = 0;
        i = 2;
    }
    while i < s.len {
        let g0 = i;
        var v = 0;
        while i < s.len && is_hex(s[i]) && i - g0 < 4 {
            v = v * 16 + hex(s[i]);
            i++;
        }
        guard i > g0 else { return false; }
        if i < s.len && s[i] == '.' {
            // The last 32 bits, as IPv4.
            guard n <= 12 else { return false; }
            var v4: u8[16] = [0; 16];
            guard ipv4_into(s[g0..], v4) else { return false; }
            for k in 4 { ip[n + k] = v4[12 + k]; }
            n += 4;
            i = s.len;
            break;
        }
        guard n <= 14 else { return false; }
        ip[n] = (v >> 8) as! u8;
        ip[n + 1] = (v & 0xff) as! u8;
        n += 2;
        if i == s.len { break; }
        guard s[i] == ':' else { return false; }
        i++;
        if i < s.len && s[i] == ':' {
            guard gap < 0 else { return false; }
            gap = n;
            i++;
        } else {
            guard i < s.len else { return false; }
        }
    }
    if gap < 0 { return n == 16; }
    // "::" stands for one or more zero groups.
    guard n <= 14 else { return false; }
    let tail = n - gap;
    var k = tail;
    while k > 0 {
        k--;
        ip[16 - tail + k] = ip[gap + k];
    }
    for z in 16 - tail - gap { ip[gap + z] = 0; }
    return true;
}
