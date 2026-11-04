// A session's deadline, against a server thread in the program that sends a
// byte at a time, each well within the session's limit on a wait: a response
// whose head drips, one whose body drips, a server that never answers, a TLS
// handshake that never ends, and a deadline already past, each failing with
// ETIMEDOUT by the deadline; and a slow response that the limit on each wait
// alone lets through, as it does under a deadline it ends before.
import std;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.client;

// Each byte of a drip comes this long after the last.
let DRIP_MS = 20;

fn listener() -> i32, i32 {
    let a, ok = http::address("127.0.0.1");
    assert(ok);
    let fd = http::net_listen(a.ip, 0, 16, 0);
    assert(fd >= 0);
    return fd, http::net_port(fd);
}

// Sends text, and false once the client has gone.
fn send_text(fd: i32, text: const u8[:]) -> bool {
    var at = 0;
    while at < text.len {
        let n = http::net_send(fd, text[at..]);
        guard n > 0 else { return false; }
        at += n;
    }
    return true;
}

// Sends n bytes x, one every DRIP_MS, and false once the client has gone.
fn drip(fd: i32, n: i64) -> bool {
    for i in n {
        sleep_ms(DRIP_MS);
        guard send_text(fd, "x") else { return false; }
    }
    return true;
}

// Serves one connection after another, by the request's path: /drip-head
// sends a field's value a byte at a time, /drip-body a body of 100 bytes, and
// /short 10 bytes the same way; /quit ends the server. Anything else, such as
// /silent or a TLS hello, gets no answer until the client hangs up.
thread_fn server(lfd: i32) {
    var buf: u8[>..] = [];
    buf.resize(16384, 0);
    loop {
        let fd = http::net_accept(lfd, 0);
        assert(fd >= 0);
        var head: u8[>..] = [];
        var open = true;
        while find(head, "\r\n\r\n") < 0 {
            let n = http::net_recv(fd, buf);
            if n <= 0 { open = false; break; }
            head.append(buf[..n]);
        }
        if open && starts_with(head, "GET /quit ") {
            http::net_close(fd);
            break;
        }
        if open && starts_with(head, "GET /drip-head ") {
            if send_text(fd, "HTTP/1.1 200 OK\r\nConnection: close\r\nX-Padding: ") && drip(fd, 100) {
                send_text(fd, "\r\nContent-Length: 2\r\n\r\nok");
            }
        } else if open && starts_with(head, "GET /drip-body ") {
            if send_text(fd, "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 100\r\n\r\n") { drip(fd, 100); }
        } else if open && starts_with(head, "GET /short ") {
            if send_text(fd, "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 10\r\n\r\n") { drip(fd, 10); }
        } else {
            while open && http::net_recv(fd, buf) > 0 {}
        }
        http::net_close(fd);
    }
    http::net_close(lfd);
}

// What a request gave, and whether it ended between from and until
// milliseconds after it started.
fn timed(session: http::Session&, url: const u8[:], from: i64, until: i64) {
    let started = http::net_clock_ms();
    let r, e = http::get(session, url);
    let took = http::net_clock_ms() - started;
    if e.code == 0 { print(r.status, " ", r.body); }
    else { print("failed: ", e.call, " ", if e.code == http::ETIMEDOUT { "ETIMEDOUT" } else { "another code" }); }
    print("  in time: ", took >= from && took < until);
}

fn main() {
    let lfd, port = listener();
    let t = thread_spawn(server, lfd);
    var base: u8[>..] = [];
    format(base, "http://127.0.0.1:", port);

    // 10 bytes over 200 ms, none of them later than the limit on each wait.
    var session = http::session(1000);
    print("== no deadline");
    timed(session, str(base, "/short"), 150, 1000);

    print("== a deadline 300 ms away");
    session.deadline = http::deadline(300);
    timed(session, str(base, "/drip-head"), 250, 1000);
    session.deadline = http::deadline(300);
    timed(session, str(base, "/drip-body"), 250, 1000);
    // The time left, not the limit on each wait, ends this one.
    var patient = http::session(5000);
    patient.deadline = http::deadline(300);
    timed(patient, str(base, "/silent"), 250, 1000);
    // The handshake waits for a server that never speaks TLS.
    patient.deadline = http::deadline(300);
    timed(patient, str("https://127.0.0.1:", port, "/"), 250, 1000);

    print("== a deadline past");
    session.deadline = http::deadline(0) - 1;
    timed(session, str(base, "/short"), 0, 100);

    print("== a deadline that leaves time");
    session.deadline = http::deadline(5000);
    timed(session, str(base, "/short"), 150, 1000);

    session.deadline = -1;
    let r, e = http::get(session, str(base, "/quit"));
    thread_wait(t);
    http::free(session);
    http::free(patient);
}
