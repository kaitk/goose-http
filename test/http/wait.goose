// Exchanges that wait: a later key's liveness through start_wait, abandon,
// and answer, and an upgraded exchange that gets the client's bytes while it
// waits.
import std;
import http from "../../";
import check from "../";

let GET = "GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n";

struct WaitingConn { fd: i32, state: u8, x: http::Exchange<bool> }

fn test_wait_liveness() {
    let box, err = http::mail_open(2, 8, 0, 1, 44);
    assert(err.code == 0);
    var c = WaitingConn { fd: 1, state: http::OPEN, .. };
    c.x.stream.later = http::address(box, http::later_base(0) | http::later_draw());
    var out: u8[>..] = [];
    var keep = true;
    let reply = http::Reply { buf: out, common: check::COMMON, keep_alive: keep, minor: 1, head: false, stream: c.x.stream };
    let to = http::later(reply, 1000);
    assert(http::mail_live(to));
    assert(http::mail_send(to, 0, "now") == http::SENT);
    var timers = http::timer_table(0);
    assert(http::start_wait(c, timers, 0));
    assert(!http::mail_live(to) && http::mail_send(to, 0, "late") == http::STALE);
    http::later(reply, 1000);
    var closed = false;
    http::abandon(c) { ev, st, out =>
        assert(ev.kind == http::CLOSED && !http::mail_live(to));
        closed = true;
    };
    assert(closed && !http::mail_live(to));
    print("start_wait and abandon: the key goes stale");
    c.x = http::Exchange<bool> { .. };
    c.x.stream.later = to;
    var input: u8[>..] = [];
    input.append(GET);
    out.clear();
    fn answer_now(ev: http::Event, st: bool&, out: http::Reply) {
        let to = http::later(out, 1000);
        assert(http::mail_live(to));
        http::respond(out, 200, "text/plain", "ready");
    }
    let nothing = http::Request { .. };
    let cfg = http::Config { .. };
    let ev = http::Event { req: nothing, .. };
    let fresh = false;
    let rest, done, full = http::answer(c, input, input.len, out, check::COMMON, cfg, fresh, false, 0, ev, answer_now) { false };
    assert(done == 1 && !c.x.stream.waiting && !http::mail_live(c.x.stream.later));
    print("an answer at once: the key goes stale");
    // A reply in pieces: the key stays live through WAKE while the handler
    // waits again, and goes stale once it answers.
    c.x = http::Exchange<bool> { .. };
    c.x.stream.later = to;
    out.clear();
    fn piece_by_piece(ev: http::Event, st: bool&, out: http::Reply) {
        if ev.kind == http::WAKE { assert(http::mail_live(out.stream.later)); }
        if ev.kind == http::REQUEST || ev.data == "more" { http::later(out, 1000); }
        else { http::respond(out, 200, "text/plain", "done"); }
    }
    http::answer(c, input, input.len, out, check::COMMON, cfg, fresh, false, 0, ev, piece_by_piece) { false };
    let pieces = c.x.stream.later;
    assert(c.x.stream.waiting && http::mail_live(pieces));
    let more = http::Event { kind: http::WAKE, req: nothing, data: "more", .. };
    http::answer(c, input, 0, out, check::COMMON, cfg, fresh, false, 0, more, piece_by_piece) { false };
    assert(c.x.stream.waiting && http::mail_live(pieces));
    let last = http::Event { kind: http::WAKE, req: nothing, data: "last", .. };
    http::answer(c, input, 0, out, check::COMMON, cfg, fresh, false, 0, last, piece_by_piece) { false };
    assert(!c.x.stream.waiting && !http::mail_live(pieces));
    http::mail_close(box);
    print("a reply in pieces: live through WAKE, stale once answered");
}

// A waiting exchange holds back the requests pipelined behind it, but an
// upgraded one gets the client's bytes as BODY, and end stops its wait.
fn test_upgraded_wait() {
    let nothing = http::Request { .. };
    let cfg = http::Config { .. };
    let none = http::Event { kind: http::NO_EVENT, req: nothing, .. };
    let fresh = false;
    var out: u8[>..] = [];
    var input: u8[>..] = [];

    var held = WaitingConn { fd: 1, state: http::OPEN, .. };
    input.append(GET);
    input.append(GET);
    fn wait_now(ev: http::Event, st: bool&, out: http::Reply) { http::later(out, 1000); }
    let rest, done, full = http::answer(held, input, input.len, out, check::COMMON, cfg, fresh, false, 0, none, wait_now) { false };
    assert(done == 1 && rest == GET.len && held.x.stream.waiting && out.len == 0);
    print("waiting: the pipelined request is held back");

    var c = WaitingConn { fd: 1, state: http::OPEN, .. };
    input.clear();
    input.append("GET /chat HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\nping");
    fn echo(ev: http::Event, st: bool&, out: http::Reply) {
        if ev.kind == http::REQUEST {
            http::upgrade(out, "echo");
            http::later(out, 1000);
        } else if ev.kind == http::BODY || ev.kind == http::WAKE {
            http::send(out, ev.data);
            if ev.data == "bye" { http::end(out); }
        }
    }
    let r1, d1, f1 = http::answer(c, input, input.len, out, check::COMMON, cfg, fresh, false, 0, none, echo) { false };
    assert(r1 == 0 && d1 == 2 && c.x.stream.waiting && ends_with(out, "\r\n\r\nping"));
    input.clear();
    input.append("pong");
    out.clear();
    let r2, d2, f2 = http::answer(c, input, input.len, out, check::COMMON, cfg, fresh, false, 0, none, echo) { false };
    assert(r2 == 0 && d2 == 1 && c.x.stream.waiting && out == "pong");
    // As the loop does, before WAKE.
    c.x.stream.waiting = false;
    let reply = http::Event { kind: http::WAKE, req: nothing, data: "reply", .. };
    out.clear();
    http::answer(c, input, 0, out, check::COMMON, cfg, fresh, false, 0, reply, echo) { false };
    assert(!c.x.stream.waiting && out == "reply" && c.state == http::OPEN);
    // Waiting again, the client says goodbye: end closes, and stops the wait.
    c.x.stream.waiting = true;
    input.clear();
    input.append("bye");
    out.clear();
    http::answer(c, input, input.len, out, check::COMMON, cfg, fresh, false, 0, none, echo) { false };
    assert(!c.x.stream.waiting && out == "bye" && c.state == http::CLOSING);
    print("upgraded: ping, pong, reply, bye");
}

fn main() {
    test_wait_liveness();
    test_upgraded_wait();
}
