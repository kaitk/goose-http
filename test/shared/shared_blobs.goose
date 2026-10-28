// Shared blobs (shared.goose, shim/shared.c): puts, ranges, refused ranges
// and handles, counted releases, and a reference handed to another thread
// through a queue, read there and released.
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

fn main() {
    let a, ea = http::shared_put("hello, shared", 1);
    let e, ee = http::shared_put("", 1);
    assert(ea == 0 && ee == 0 && a.h != e.h);
    assert(http::shared_len(a) == 13 && http::shared_len(e) == 0);
    assert(http::shared_len(http::Shared { .. }) == -1);
    let bad, eb = http::shared_put("x", 0);
    assert(eb < 0 && bad.h == 0);
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
    assert(http::shared_release(a) == 2 && http::shared_release(a) == 1);
    assert(http::shared_release(e) == 0);
    print("counted: one reference left");

    qlimit<Ref>(16);
    let t = thread_spawn(reader);
    assert(http::shared_retain(a, 2));
    qput(Ref { b: a, from: 0, to: 5 });
    qput(Ref { b: a, from: 5, to: 13 });
    qput(Ref { b: http::Shared { .. }, from: 0, to: -1 });
    thread_wait(t);
    assert(http::shared_release(a) == 0);
    print("released");
}
