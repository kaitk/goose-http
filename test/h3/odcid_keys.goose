// h3by_odcid's keys for clients' first DCIDs are keyed by the worker's
// secret: DCIDs a client chose so that std's hash, which has no secret,
// places them all at one slot, spread out like random ones. Each step of
// std's hash of 8 bytes and of its hash_mix can be undone, which is how the
// client chooses them.
import std;
import dictionary;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;
import http.h3;

let C1: u64 = 11400714819323198485;
let C2: u64 = 15485907386658061715;

fn inverse(a: u64) -> u64 {
    var x = a;
    for i in 6 { x = x * (2 - a * x); }
    assert(a * x == 1);
    return x;
}

fn unshift(y: u64) -> u64 { y ^ (y >> 32) }

// An 8-byte DCID whose std hash, hashed again as a dictionary's u64 key,
// is want.
fn dcid_for(want: u64, out: u8[..20]&) {
    let key = unshift(want) * inverse(C1);
    var h = unshift(key) * inverse(C2);
    h = unshift(h) * inverse(C1);
    let w = h ^ 8 * C1;
    out.clear();
    for i in 8 { out.push((w >> (8 * i)) as! u8); }
}

// The longest run of used slots, which a probe for a key placed in it walks.
fn longest_run(d: dictionary<u64, i32>&) -> i64 {
    var best = 0;
    var run = 0;
    for s in d.slots {
        run = if s.tag != 0 { run + 1 } else { 0 };
        best = max(best, run);
    }
    return best;
}

fn main() {
    http::h3odcid_k = [0x243f6a8885a308d3, 0x13198a2e03707344];
    var d: u8[..20] = [];
    let n = 4096;
    for i in n {
        // The same low 32 bits: one home slot at every table size.
        dcid_for(((i + 1) as u64) << 32 | 0x1234567, d);
        assert(hash(hash(d)) & 0xffffffff == 0x1234567);
        http::h3by_odcid.insert(http::h3_odcid_key(d), i as i32);
    }
    print(n, " DCIDs that std's hash puts at one slot: the longest run under 64 ", longest_run(http::h3by_odcid) < 64);
}
