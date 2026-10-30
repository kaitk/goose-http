// Shared blobs: bytes any thread makes at run time and many threads read,
// one copy for the process, freed by the last release. A publisher encodes a
// message once and sends each subscriber's worker a reference through its
// mailbox, a few bytes, instead of the message: the worker then copies it
// once, into the connection's output, with send_shared.
//
// The contract: a blob's bytes never change; every reference is released
// once, the creator's included, and no handle is used after its last. Hand
// a reference to another thread only through something that orders memory:
// a mailbox, a queue, thread_spawn. Retain before sending a reference, and
// release it if the send fails. A handle is checked as handle.goose's are:
// one used after its blob's last release, or one never put, is refused,
// even once its slot holds another blob, rather than read.
//
// The blobs are C's (shim/shared.c), since Goose has no memory threads share.
//
//   import http.shared;
//   let b, err = http::shared_put(body, 1);       // the publisher's reference
//   http::shared_retain(b, 1);                    // one for the worker
//   http::mail_send(to, tag, bytes_of_handle);    // the worker:
//   http::send_shared(out, b, 0, http::shared_len(b)); http::shared_release(b);
namespace http;

import std;
import message;

// A blob: its slot in the process's table and the slot's generation, as
// shim/shared.c packs them; 0 is none. Flat, so it crosses thread_spawn,
// queues and mail.
struct Shared { h: i64 = 0 }

extern "shared_put" fn shared_put_c(data: const u8[:], refs: i64) -> i64;
extern "shared_len" fn shared_len_c(h: i64) -> i64;
extern "shared_retain" fn shared_retain_c(h: i64, n: i64) -> i32;
extern "shared_release" fn shared_release_c(h: i64) -> i64;
extern "shared_append" fn shared_append_c(h: i64, from: i64, to: i64, out: u8[>..]&) -> i32;
// A loop's gathered sends: shim/shared.c says what each does.
extern "shared_defer" fn shared_defer_c(h: i64, from: i64, to: i64, out: u8[>..]&) -> i32;
extern "shared_gather" fn shared_gather(on: bool, buf: u8[>..]&);
extern "shared_settle" fn shared_settle();
extern "shared_pending" fn shared_pending() -> i64;
extern "shared_flatten" fn shared_flatten(buf: const u8[:], skip: i64, out: u8[>..]&);
extern "shared_send" fn shared_send(fd: i32, buf: const u8[:], skip: i64) -> i64;

// Copies data into a new blob with refs references. Returns it, and 0 or
// -code: EINVAL for refs < 1 or past 2^32 - 1, which a blob's count is
// held to, ENOMEM, also past 16M blobs at once.
fn shared_put(data: const u8[:], refs: i64 = 1) -> Shared, i64 {
    let h = shared_put_c(data, refs);
    guard h > 0 else { return Shared { .. }, h; }
    return Shared { h: h }, 0;
}

// The length of b, or -1 for a handle that isn't a blob's.
fn shared_len(b: Shared) -> i64 {
    let n = shared_len_c(b.h);
    return if n < 0 { -1 } else { n };
}

// Adds n references to b. False for a handle that isn't a blob's, n < 1, or
// a count past 2^32 - 1.
inline fn shared_retain(b: Shared, n: i64 = 1) -> bool { shared_retain_c(b.h, n) == 0 }

// Drops one reference to b, freeing it with the last. Returns the references
// left, or -1 for a handle that isn't a blob's.
inline fn shared_release(b: Shared) -> i64 {
    let left = shared_release_c(b.h);
    return if left < 0 { -1 } else { left };
}

// Appends b's bytes from..to to out. False, with nothing appended, for a
// range outside b or a handle that isn't a blob's.
inline fn shared_append(b: Shared, from: i64, to: i64, out: u8[>..]&) -> bool {
    shared_append_c(b.h, from, to, out) == 0
}

// Sends b's bytes from..to on an upgraded connection, as send does data;
// after_drain counts them. Through out on a plain socket, the loop keeps a
// reference until they're sent, and sends them from b with the output; over
// TLS, or into a buffer of the handler's own, they're copied once into it.
// False, sending nothing, for a range outside b, a handle that
// isn't a blob's, or a stream that isn't open and upgraded.
fn send_shared(out: Reply, b: Shared, from: i64, to: i64) -> bool {
    let s .= out.stream;
    guard s.open && raw(s) else { return false; }
    let deferred = shared_defer_c(b.h, from, to, out.buf);
    guard deferred >= 0 else { return false; }
    if deferred == 0 { guard shared_append_c(b.h, from, to, out.buf) == 0 else { return false; } }
    if to > from { s.moved = true; }
    return true;
}
