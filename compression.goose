// Responses compressed on the fly by the request's Accept-Encoding (RFC 9110
// §12.5.3), with goose-compress's gzip, deflate (zlib), and zstd encoders
// (task 022). Only a program that imports this module needs that package,
// which its root file declares at the tag this file names:
//
//   import http from "github.com/kaitk/goose-http@<tag>";
//   import compress from "github.com/kaitk/goose-compress@v0.1.4";
//   import http.compression;
//
// A whole response:
//
//   http::respond_compressed(out, req, 200, "application/json", body);
//
// One sent in pieces, with a Compressed in the handler's state:
//
//   http::begin_compressed(out, req, 200, "text/event-stream", st.coded);
//   http::send_compressed(out, st.coded, piece);   // flushed: the client can read it whole
//   http::end_compressed(out, st.coded);
//   ...and at CLOSED, http::release_compressed(st.coded)
namespace http;

import std;
import compress from "github.com/kaitk/goose-compress@v0.1.4";
import message;
import media;

enum Coding { Identity, Gzip, Deflate, Zstd }

// What to compress, and how hard. Its own struct rather than fields of
// Config, so that a program without compression builds the loops as before.
struct Compression {
    // A body shorter than this goes uncompressed: its coding's header and
    // trailer would outweigh what it saves (docs/decisions.md, "Bodies from
    // 256 bytes are compressed").
    min_size: i64 = 256,
    // gzip's and deflate's level, 1 to 9, and zstd's, 1 to 22. Level 1 is
    // nginx's default, and the fastest of each.
    level: i64 = 1,
    zstd_level: i64 = 1,
    // Whether zstd is offered; gzip and deflate always are.
    zstd: bool = true,
}

// The coding a response to req takes: the one Accept-Encoding weighs
// highest, zstd before gzip before deflate at equal weights, or Identity
// where it takes none. deflate is never preferred over gzip, which every
// client that sends one takes.
fn coding_for(req: const Request&, c: Compression) -> Coding {
    let z = if c.zstd { coding_q(req, "zstd") } else { 0 };
    let g = coding_q(req, "gzip");
    let d = coding_q(req, "deflate");
    guard z > 0 || g > 0 || d > 0 else { return Coding.Identity; }
    return if z >= g && z >= d { Coding.Zstd } else if g >= d { Coding.Gzip } else { Coding.Deflate };
}

// The Content-Encoding field of a coding other than Identity.
fn coding_field(coding: Coding) -> const u8[:] {
    return match coding {
        Gzip => "Content-Encoding: gzip\r\n",
        Deflate => "Content-Encoding: deflate\r\n",
        Zstd => "Content-Encoding: zstd\r\n",
        Identity => "",
    };
}

// Whether a body of content_type is worth compressing: not images, audio,
// video, fonts already compressed, or archives, which are compressed
// already. image/svg+xml is text.
fn compressible(content_type: const u8[:]) -> bool {
    let m, ok = media_type(content_type);
    guard ok else { return true; }
    if eq_fold(m.top, "image") { return eq_fold(m.sub, "svg+xml"); }
    if eq_fold(m.top, "audio") || eq_fold(m.top, "video") { return false; }
    if eq_fold(m.top, "font") { return !eq_fold(m.sub, "woff") && !eq_fold(m.sub, "woff2"); }
    guard eq_fold(m.top, "application") else { return true; }
    let packed = ["zip", "gzip", "x-gzip", "zstd", "x-bzip2", "x-xz", "x-7z-compressed",
                  "vnd.rar", "x-rar-compressed", "octet-stream", "wasm"];
    for p in packed { if eq_fold(m.sub, p) { return false; } }
    return true;
}

// Appends data compressed whole with coding to out.
fn compress_whole(data: const u8[:], out: u8[>..]&, coding: Coding, c: Compression) {
    match coding {
        Gzip => { compress::compress(data, out, compress::GZIP, c.level); },
        Deflate => { compress::compress(data, out, compress::ZLIB, c.level); },
        Zstd => { compress::compress(data, out, compress::ZSTD, c.zstd_level); },
        Identity => { out.append(data); },
    }
}

// A whole response, as respond writes one, with its body compressed in the
// coding req takes best, and Content-Encoding and the compressed length.
// Left uncompressed: HEAD, which keeps the identity body's length, a status
// without a body or 206, a body under c.min_size, and a content_type that
// compressible refuses. Every response but the last kind gets
// Vary: Accept-Encoding, since the route could compress it.
fn respond_compressed(out: Reply, req: const Request&, status: i32, content_type: const u8[:],
                      body: const u8[:], c: Compression = Compression { .. }) {
    start(out, status);
    field(out, "Content-Type", content_type);
    guard compressible(content_type) else {
        finish(out, NO_TYPE,body);
        return;
    }
    out.buf.append("Vary: Accept-Encoding\r\n");
    let coding = if out.head || out.stream.bodyless || status == 206 || body.len < c.min_size {
        Coding.Identity
    } else {
        coding_for(req, c)
    };
    guard coding != Coding.Identity else {
        finish(out, NO_TYPE,body);
        return;
    }
    out.buf.append(coding_field(coding));
    // On the worker's data stack, which a global buffer wouldn't save on:
    // Goose can't tell that out.buf isn't the global, and won't clear it.
    var compressed: u8[>..] = [];
    compress_whole(body, compressed, coding, c);
    finish(out, NO_TYPE,compressed);
}

// A streamed response's coding, and the encoder it holds from the worker's
// pool, in the handler's state: one per exchange that streams compressed.
struct Compressed {
    coding: Coding = Coding.Identity,
    slot: i64 = -1,     // its encoder, in deflaters or zstds by coding
}

// Each worker's encoders for streamed responses. An encoder is built once,
// which copies its arrays several times (goose-compress's README), and
// reset for each response; the pool grows to the most streams compressed at
// once, and busy marks the slots a stream holds. Goose won't let a handler
// shrink a global while it holds out, so no free list is popped.
var deflaters: compress::Encoder[>..];
var zstds: compress::ZstdEncoder[>..];
var deflaters_busy: bool[>..];
var zstds_busy: bool[>..];

// The first slot of busy that isn't, marked busy, or busy.len for a new one.
fn lend(busy: bool[>..]&) -> i64 {
    for b, i in busy {
        if !b {
            busy[i] = true;
            return i;
        }
    }
    busy.push(true);
    return busy.len - 1;
}

// Starts a response whose body the handler sends in pieces, as begin does,
// chunked, compressed in the coding req takes best, with Content-Type and
// Vary as respond_compressed writes them. HEAD, a status without a body, 206,
// and a content_type that compressible refuses go uncompressed; so does
// HTTP/1.0, which can't take chunks and would have the connection end the
// body. Each send_compressed is flushed, so the client can decompress all it
// has: a Server-Sent Event arrives whole.
fn begin_compressed(out: Reply, req: const Request&, status: i32, content_type: const u8[:], z: Compressed&,
                    c: Compression = Compression { .. }) {
    release_compressed(z);
    begin(out, status, -1);
    field(out, "Content-Type", content_type);
    guard compressible(content_type) else { return; }
    out.buf.append("Vary: Accept-Encoding\r\n");
    guard !out.head && !out.stream.bodyless && status != 206 && out.minor > 0 else { return; }
    let coding = coding_for(req, c);
    guard coding != Coding.Identity else { return; }
    out.buf.append(coding_field(coding));
    take_compressed(z, coding, c);
}

// Takes an encoder for coding from the worker's pool into z, reset for a new
// body, for a program that writes the response's head itself, with
// coding_field's line; begin_compressed is both. z holds none yet: a fresh
// Compressed, or one release_compressed gave back. For Identity, z takes
// none, and send_compressed sends the pieces as they are.
inline fn take_compressed(z: Compressed&, coding: Coding, c: Compression = Compression { .. }) {
    guard coding != Coding.Identity else { return; }
    z.coding = coding;
    if coding == Coding.Zstd {
        z.slot = lend(zstds_busy);
        if z.slot == zstds.len { zstds.push(compress::zstd_encoder(c.zstd_level)); }
        compress::reset(zstds[z.slot], c.zstd_level);
    } else {
        z.slot = lend(deflaters_busy);
        if z.slot == deflaters.len { deflaters.push(compress::encoder()); }
        compress::reset(deflaters[z.slot], if coding == Coding.Gzip { compress::GZIP } else { compress::ZLIB }, c.level);
    }
}

// Sends the next piece of the body begin_compressed started, compressed and
// flushed, as one chunk.
fn send_compressed(out: Reply, z: Compressed&, data: const u8[:]) {
    guard z.slot >= 0 else {
        send(out, data);
        return;
    }
    guard data.len > 0 else { return; }
    var piece: u8[>..] = [];
    if z.coding == Coding.Zstd {
        compress::write(zstds[z.slot], data, piece);
        compress::flush(zstds[z.slot], piece);
    } else {
        compress::write(deflaters[z.slot], data, piece);
        compress::flush(deflaters[z.slot], piece);
    }
    send(out, piece);
}

// Ends the response begin_compressed started: the stream's trailer, then
// end's last chunk and trailers. The encoder goes back to the pool.
fn end_compressed(out: Reply, z: Compressed&, trailers: const u8[:] = "") {
    if z.slot >= 0 {
        var piece: u8[>..] = [];
        if z.coding == Coding.Zstd { compress::finish(zstds[z.slot], piece); }
        else { compress::finish(deflaters[z.slot], piece); }
        send(out, piece);
    }
    release_compressed(z);
    end(out, trailers);
}

// Gives z's encoder back to the pool, for an exchange that ends without
// end_compressed: call it at CLOSED. Harmless when z holds none.
fn release_compressed(z: Compressed&) {
    if z.slot >= 0 {
        if z.coding == Coding.Zstd { zstds_busy[z.slot] = false; } else { deflaters_busy[z.slot] = false; }
    }
    z.slot = -1;
    z.coding = Coding.Identity;
}
