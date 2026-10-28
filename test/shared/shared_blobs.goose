// Shared blobs (shared.goose, shim/shared.c): puts, ranges, refused ranges
// and handles, counted releases, a reference handed to another thread
// through a queue, read there and released; forged and stale handles
// refused, also once a stale handle's slot holds another blob; and threads
// that retain, read and release one blob while another puts and frees
// blobs in the slot of a handle they keep trying.
import std;
import http from "../../";
import http.shared;

struct Ref { b: http::Shared, from: i64, to: i64 }

thread_fn reader() {
    var out: u8[>..] = [];
    loop {
        let r = qget<Ref>();
        if r.to < 0 { break; }
        assert(http::shared_append(r.b, r.from, r.to, out));
        http::shared_release(r.b);
    }
    print("reader: ", out);
}

// Refused by every call, as a handle that names no live blob.
fn refused(b: http::Shared) -> bool {
    var out: u8[>..] = [];
    return http::shared_len(b) == -1 && !http::shared_retain(b, 1) && http::shared_release(b) == -1 &&
           !http::shared_append(b, 0, 0, out) && out.len == 0;
}

thread_fn hammer(b: http::Shared, dead: http::Shared, rounds: i64) {
    var out: u8[>..] = [];
    for i in rounds {
        assert(http::shared_retain(b, 2));
        out.clear();
        assert(http::shared_append(b, 0, 5, out) && out == "hello");
        assert(http::shared_release(b) >= 2 && http::shared_release(b) >= 1);
        assert(!http::shared_retain(dead, 1) && !http::shared_append(dead, 0, 1, out));
    }
}

thread_fn churn(rounds: i64) {
    for i in rounds {
        let b, e = http::shared_put("churn", 1);
        assert(e == 0 && http::shared_len(b) == 5 && http::shared_retain(b, 1));
        assert(http::shared_release(b) == 1 && http::shared_release(b) == 0 && refused(b));
    }
}

fn main() {
    let a, ea = http::shared_put("hello, shared", 1);
    let e, ee = http::shared_put("", 1);
    assert(ea == 0 && ee == 0 && a.h != e.h);
    assert(http::shared_len(a) == 13 && http::shared_len(e) == 0);
    assert(http::shared_len(http::Shared { .. }) == -1);
    let bad, eb = http::shared_put("x", 0);
    assert(eb < 0 && bad.h == 0);
    let big, eg = http::shared_put("x", 0x100000000);
    assert(eg < 0 && big.h == 0);
    print("put: lengths ", http::shared_len(a), " and ", http::shared_len(e));

    var out: u8[>..] = [];
    out.append(">");
    assert(http::shared_append(a, 0, 5, out) && out == ">hello");
    assert(http::shared_append(a, 7, 13, out) && out == ">helloshared");
    assert(!http::shared_append(a, 0, 14, out) && !http::shared_append(a, -1, 2, out));
    assert(!http::shared_append(a, 5, 4, out) && !http::shared_append(http::Shared { .. }, 0, 0, out));
    assert(out == ">helloshared");
    print("ranges: ", out);

    assert(http::shared_retain(a, 2) && !http::shared_retain(a, 0));
    assert(!http::shared_retain(a, 0xFFFFFFFF));
    assert(http::shared_release(a) == 2 && http::shared_release(a) == 1);
    assert(http::shared_release(e) == 0);
    print("counted: one reference left");

    // Forged: a generation no slot has had, a slot past the table's chunks,
    // a negative number, and bare slot numbers with no generation.
    assert(refused(http::Shared { h: (0x7FFFFFF0 << 32) | 1 }));
    assert(refused(http::Shared { h: (1 << 32) | 0xFFFFFFF0 }));
    assert(refused(http::Shared { h: -7 }));
    assert(refused(http::Shared { h: 12345 }));
    assert(refused(http::Shared { h: a.h & 0xFFFFFFFF }));
    print("forged: refused");

    // Stale: e's last release ended it, and its slot is the next put's.
    assert(refused(e));
    let c, ec = http::shared_put("second", 1);
    assert(ec == 0 && (c.h & 0xFFFFFFFF) == (e.h & 0xFFFFFFFF) && c.h != e.h);
    assert(refused(e));
    assert(http::shared_len(c) == 6 && http::shared_append(c, 0, 6, out) && out == ">hellosharedsecond");
    assert(http::shared_release(c) == 0 && refused(c));
    print("stale: refused, also in a reused slot");

    qlimit<Ref>(16);
    let t = thread_spawn(reader);
    assert(http::shared_retain(a, 2));
    qput(Ref { b: a, from: 0, to: 5 });
    qput(Ref { b: a, from: 5, to: 13 });
    qput(Ref { b: http::Shared { .. }, from: 0, to: -1 });
    thread_wait(t);

    // Threads at once: four on a's count, each trying c's stale handle, and
    // one putting and freeing blobs, in c's slot among others.
    let rounds = 20000;
    let churner = thread_spawn(churn, rounds);
    let h1 = thread_spawn(hammer, a, c, rounds);
    let h2 = thread_spawn(hammer, a, c, rounds);
    let h3 = thread_spawn(hammer, a, c, rounds);
    let h4 = thread_spawn(hammer, a, c, rounds);
    thread_wait(h1);
    thread_wait(h2);
    thread_wait(h3);
    thread_wait(h4);
    thread_wait(churner);
    assert(http::shared_len(a) == 13);
    assert(http::shared_release(a) == 0 && refused(a));
    print("threads: counts kept, stale handles refused");
    print("released");
}
