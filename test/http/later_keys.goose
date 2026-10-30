// Later keys (later_base): an HTTP/1.1 exchange's key counts the requests
// on its connection, so an address held while 2^20 more requests go by on
// it, where the key's 20-bit number of the request repeated, stays STALE,
// and the exchange that waits then gets the reply. Its close moves the
// worker's counter past its keys, so the slot's next connection starts past
// them. The counter's own wrap stays at or above SOCKET_KEYS.
import std;
import http from "../../";
import check from "../";

struct WaitingConn { fd: i32, state: u8, x: http::Exchange<bool> }

fn sent(r: i32) -> const u8[:] { if r == http::SENT { "SENT" } else if r == http::STALE { "STALE" } else { "other" } }

fn handle(ev: http::Event, st: bool&, out: http::Reply) {
    if ev.kind == http::REQUEST && ev.req.target == "/wait" { http::later(out, 1000); }
    else { http::respond(out, 200, "text/plain", "ok"); }
}

fn main() {
    let box, err = http::mail_open(2, 8, 0, 1, 44);
    assert(err.code == 0);
    let nothing = http::Request { .. };
    let none = http::Event { kind: http::NO_EVENT, req: nothing, .. };
    let woken = http::Event { kind: http::WAKE, req: nothing, .. };
    let cfg = http::Config { write_buffer: 1 << 30, .. };
    let fresh = false;
    var out: u8[>..] = [];
    var input: u8[>..] = [];
    var c = WaitingConn { fd: 1, state: http::OPEN, .. };
    c.x.stream.later = http::address(box, http::later_base(0) | http::later_draw());

    input.append("GET /wait HTTP/1.1\r\nHost: x\r\n\r\n");
    http::answer(c, input, input.len, out, check::COMMON, cfg, fresh, false, 0, none, handle) { false };
    let held = c.x.stream.later;
    assert(c.x.stream.waiting && http::mail_live(held));
    // As the loop's delivered does.
    c.x.stream.waiting = false;
    http::answer(c, input, 0, out, check::COMMON, cfg, fresh, false, 0, woken, handle) { false };
    assert(!http::mail_live(held));

    // The request 2^20 after the held one waits, last in the last batch.
    let batch = 4096;
    input.clear();
    for i in batch { input.append("GET / HTTP/1.1\r\nHost: x\r\n\r\n"); }
    var last: u8[>..] = [];
    last.append(input[..input.len - 27]);
    last.append("GET /wait HTTP/1.1\r\nHost: x\r\n\r\n");
    for i in (1 << 20) / batch {
        out.clear();
        let final = i == (1 << 20) / batch - 1;
        let rest, done, full = http::answer(c, if final { last } else { input }, if final { last.len } else { input.len },
                                            out, check::COMMON, cfg, fresh, false, 0, none, handle) { false };
        assert(rest == 0 && done == batch);
    }
    let next = c.x.stream.later;
    assert(c.x.stream.waiting);
    print("2^20 requests on: the held address ", sent(http::mail_send(held, 0, "old")),
          ", the waiting one's ", sent(http::mail_send(next, 0, "new")));

    http::abandon(c) { ev, st, out => };
    let after = http::later_base(0) | http::later_draw();
    print("the slot's next connection starts past it: ", after > next.key);

    http::later_n = http::LATER_LAST - 1;
    let last = http::later_draw();
    let first = http::later_draw();
    print("past the last number: ", if last == http::LATER_LAST && first == http::SOCKET_KEYS { "SOCKET_KEYS again" } else { "wrong" });
    http::mail_close(box);
}
