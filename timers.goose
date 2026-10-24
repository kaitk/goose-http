// A timer table: up to a fixed number of deadlines, each with a 64-bit key
// the table doesn't read, in a min-heap. Its cells are added as timers need
// them, up to the capacity, and kept once added, so a table costs what its
// busiest moment armed, not its capacity. A timer is a Handle (handle.goose), so cancelling one that has
// fired, or whose cell a later timer took, does nothing. Nothing here knows
// HTTP: this file imports nothing of the package's HTTP side, so that it can
// move to a package of its own unchanged.
//
//   var t = http::timer_table(1024);
//   let h = http::arm(t, key, now + 5000);    // no timer (slot -1) when full
//   http::cancel(t, h);
//   let at, any = http::next_due(t);          // for the wait's timeout
//   http::expire(t, now) { key => ... };
namespace http;

import std;
import handle;

// One cell. A struct holds one resizable field, its last, so the heap is a
// column of the cells: cells[i].heap is the cell at the heap's position i.
// pos is the cell's own position in the heap, -1 while it's free, and next
// links the free cells.
struct TimerCell { at: i64, key: u64, gen: u32, pos: i64, heap: i64, next: i64 }

struct Timers {
    count: i64,         // armed timers, the heap's length
    free: i64,          // the first free cell, or -1
    capacity: i64,      // the most cells
    cells: TimerCell[>..],
}

// A table of capacity timers, all free.
fn timer_table(capacity: i64) -> Timers {
    return Timers { count: 0, free: -1, capacity: max(capacity, 0), cells: [] };
}

// Arms a timer that falls due at at, with key. Returns it, or a Handle with
// slot -1 when every cell is armed.
fn arm(t: Timers&, key: u64, at: i64) -> Handle {
    if t.free < 0 && t.cells.len < t.capacity {
        t.free = t.cells.len;
        t.cells.push(TimerCell { at: 0, key: 0, gen: 1, pos: -1, heap: 0, next: -1 });
    }
    let i = t.free;
    guard i >= 0 else { return Handle { .. }; }
    let c .= t.cells[i];
    t.free = c.next;
    c.at = at;
    c.key = key;
    c.pos = t.count;
    t.cells[t.count].heap = i;
    t.count++;
    sift_up(t, c.pos);
    return Handle { slot: i as i32, gen: c.gen };
}

// Whether h is armed: neither fired, cancelled, nor out of the table.
fn armed(t: const Timers&, h: Handle) -> bool {
    guard h.slot >= 0 && h.slot < t.cells.len else { return false; }
    let c = t.cells[h.slot];
    return c.gen == h.gen && c.pos >= 0;
}

// Disarms h. Returns false, doing nothing, if it wasn't armed.
fn cancel(t: Timers&, h: Handle) -> bool {
    guard armed(t, h) else { return false; }
    take_out(t, h.slot);
    return true;
}

// When the next timer falls due, and whether any is armed.
fn next_due(t: const Timers&) -> i64, bool {
    guard t.count > 0 else { return 0, false; }
    return t.cells[t.cells[0].heap].at, true;
}

// Calls F with the key of each timer due at now, earliest first, taking it
// out of the table before the call, so F may arm more. A timer F arms that
// is already due waits for the next call, so a block that re-arms at now
// can't keep this from returning.
fn expire<F>(t: Timers&, now: i64) {
    var n = t.count;
    while n > 0 && t.count > 0 {
        let i = t.cells[0].heap;
        guard t.cells[i].at <= now else { break; }
        let key = t.cells[i].key;
        take_out(t, i);
        F(key);
        n--;
    }
}

// Takes cell i out of the heap and frees it, advancing its generation.
fn take_out(t: Timers&, i: i64) {
    let p = t.cells[i].pos;
    t.count--;
    if p < t.count {
        let last = t.cells[t.count].heap;
        t.cells[p].heap = last;
        t.cells[last].pos = p;
        if p > 0 && t.cells[last].at < t.cells[t.cells[(p - 1) / 2].heap].at { sift_up(t, p); }
        else { sift_down(t, p); }
    }
    let c .= t.cells[i];
    c.pos = -1;
    c.gen = next_gen(c.gen);
    c.next = t.free;
    t.free = i;
}

fn sift_up(t: Timers&, from: i64) {
    var p = from;
    let i = t.cells[p].heap;
    let at = t.cells[i].at;
    while p > 0 {
        let q = (p - 1) / 2;
        let j = t.cells[q].heap;
        guard t.cells[j].at > at else { break; }
        t.cells[p].heap = j;
        t.cells[j].pos = p;
        p = q;
    }
    t.cells[p].heap = i;
    t.cells[i].pos = p;
}

fn sift_down(t: Timers&, from: i64) {
    var p = from;
    let i = t.cells[p].heap;
    let at = t.cells[i].at;
    loop {
        var q = 2 * p + 1;
        guard q < t.count else { break; }
        if q + 1 < t.count && t.cells[t.cells[q + 1].heap].at < t.cells[t.cells[q].heap].at { q++; }
        let j = t.cells[q].heap;
        guard t.cells[j].at < at else { break; }
        t.cells[p].heap = j;
        t.cells[j].pos = p;
        p = q;
    }
    t.cells[p].heap = i;
    t.cells[i].pos = p;
}
