// serve_cached: a file read once into the worker's cache and sent from it,
// read again when it's replaced, a copy chosen by Accept-Encoding, and files
// served from the disk past the budget or past FILE_PIECE. Writes files into
// the working directory, and deletes them.
import std;
import http from "../../";
import check from "../";

// Prints the body serve_cached answers GET name with, with fields and a
// cache of budget bytes, and whether it came from the disk.
fn get(label: const u8[:], name: const u8[:], fields: const u8[:], budget: i64) {
    var rb: u8[>..] = [];
    let req = check::request("GET", fields, rb);
    var out: u8[>..] = [];
    var keep = true;
    var st = http::Stream { .. };
    var body = http::FileBody { .. };
    let reply = http::Reply { buf: out, common: check::COMMON, keep_alive: keep, minor: 1, head: false, stream: st };
    assert(http::serve_cached(req, reply, name, "text/plain", budget, body) == 200);
    let disk = body.fd >= 0;
    while http::send_file(reply, body) {}
    http::end(reply);
    let at = find(out, "\r\n\r\n");
    assert(at >= 0);
    let rest = out[at + 4..];
    if rest.len > 16 { print(label, ": ", rest.len, " bytes, from the disk: ", disk); }
    else { print(label, ": '", rest, "', from the disk: ", disk); }
}

fn main() {
    let a = "test_cache_a.tmp";
    let b = "test_cache_b.tmp";
    let c = "test_cache_c.tmp";
    for n in [a, b, c] { assert(write_file(n, "12345")); }

    // A budget of a's and b's paths and bytes: c doesn't fit.
    let budget = a.len + 5 + b.len + 5;
    get("a, read in", a, "", budget);
    get("b, read in", b, "", budget);
    get("c, past the budget", c, "", budget);
    get("a, from the cache", a, "", budget);
    get("a's bytes 1 to 2", a, "Range: bytes=1-2\r\n", budget);

    // Replaced, as a deploy replaces a file: the same length, a new inode.
    assert(write_file("test_cache.new", "abcde"));
    assert(rename_file("test_cache.new", a));
    get("a, replaced", a, "", budget);
    get("a, again", a, "", budget);

    // A copy as open_precompressed picks it, cached as a file of its own.
    assert(write_file(str(b, ".br"), "br"));
    get("b as br", b, "Accept-Encoding: br\r\n", 1 << 20);
    get("b as br, cached", b, "Accept-Encoding: br\r\n", 1 << 20);
    get("b without", b, "", 1 << 20);

    // One byte past FILE_PIECE.
    var big: u8[>..] = [];
    for i in 65537 { big.push('x'); }
    assert(write_file(c, big));
    get("c, past FILE_PIECE", c, "", 1 << 20);

    for n in [a, b, c, str(b, ".br")] { assert(delete_file(n)); }
}
