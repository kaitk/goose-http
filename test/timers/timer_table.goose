// The timer table (timers.goose): expiry in order, a full table, stale
// handles, and a timer armed while others expire. The package is declared by
// timers.goose alone, so this compiles only if the timer table reaches
// nothing of the HTTP side.
import std;
import timers from "../../";

fn same(got: const u64[:], want: const i64[:]) -> bool {
    guard got.len == want.len else { return false; }
    for k, i in got { guard k == want[i] as u64 else { return false; } }
    return true;
}

fn test_order() {
    var t = http::timer_table(8);
    let _, any = http::next_due(t);
    assert(!any);
    for at in [50, 10, 40, 30, 20] { http::arm(t, (at * 2) as u64, at); }
    let at, some = http::next_due(t);
    assert(some && at == 10);
    var got: u64[>..] = [];
    http::expire(t, 35) { key => got.push(key); };
    assert(same(got, [20, 40, 60]));
    http::expire(t, 1000) { key => got.push(key); };
    assert(same(got, [20, 40, 60, 80, 100]));
    assert(t.count == 0);
    print("order: ", got);
}

fn test_full_and_stale() {
    var t = http::timer_table(3);
    let a = http::arm(t, 1, 100);
    let b = http::arm(t, 2, 200);
    let c = http::arm(t, 3, 300);
    let d = http::arm(t, 4, 400);
    assert(a.slot >= 0 && b.slot >= 0 && c.slot >= 0 && d.slot == -1);
    assert(http::cancel(t, b) && !http::cancel(t, b) && !http::armed(t, b));
    // b's cell goes to the next timer, under a new generation: b stays dead.
    let e = http::arm(t, 5, 50);
    assert(e.slot == b.slot && e.gen != b.gen);
    assert(!http::cancel(t, b) && http::armed(t, e));
    var got: u64[>..] = [];
    http::expire(t, 100) { key => got.push(key); };
    assert(same(got, [5, 1]));
    // A fired timer can't be cancelled, nor can a handle from no table.
    assert(!http::cancel(t, a) && !http::cancel(t, e) && !http::cancel(t, http::Handle { .. }));
    assert(!http::cancel(t, http::Handle { slot: 9, gen: 1 }));
    let empty = http::timer_table(0);
    assert(!http::armed(empty, a));
    print("full and stale: fired ", got);
}

// A block that arms a timer already due doesn't keep expire from returning,
// and the new timer fires at the next call.
fn test_rearm() {
    var t = http::timer_table(4);
    http::arm(t, 1, 10);
    var fired = 0;
    http::expire(t, 10) { key =>
        fired++;
        http::arm(t, key + 1, 10);
    };
    assert(fired == 1 && t.count == 1);
    http::expire(t, 10) { key => assert(key == 2); fired++; };
    assert(fired == 2 && t.count == 0);
    print("rearm: ", fired, " fired over two calls");
}

// A table adds cells only as timers need them, reuses a freed cell before
// adding one, and adds none past its capacity.
fn test_growth() {
    var t = http::timer_table(1 << 20);
    assert(t.cells.len == 0);
    let a = http::arm(t, 1, 10);
    let b = http::arm(t, 2, 20);
    assert(t.cells.len == 2);
    http::cancel(t, a);
    let c = http::arm(t, 3, 30);
    assert(c.slot == a.slot && t.cells.len == 2 && http::armed(t, b));
    var small = http::timer_table(2);
    for k in 5 { http::arm(small, k as u64, k); }
    assert(small.cells.len == 2 && small.count == 2);
    print("growth: ", t.cells.len, " cells for ", t.count, " timers");
}

fn main() {
    test_order();
    test_full_and_stale();
    test_rearm();
    test_growth();
}
