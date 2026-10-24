// The kernel calls the loops make, implemented in shim/net.c on Linux, in
// shim/kqueue.c on macOS, which gives the epoll calls below over kqueue, and
// in shim/net_win.c on Windows, where the epoll calls fail with ENOSYS.
// Each returns what its syscall returns on success and -code on failure,
// where code is one of the constants below, Linux's errno values on every
// platform. A caller compares against them negated: `if n == -http::EAGAIN`.
//
// Spec §7.10 leaves C three obligations: keep the types of what it writes
// through an argument, keep no argument after the call, and only append to a
// builder. The shim keeps no argument; where a call writes into an argument,
// its comment says how much.
namespace http;

import os;

// One readiness event, in a layout of the package's own (shim/net.c). On
// macOS it holds every filter kqueue reported for the fd in that wait.
struct PollEvent { events: u32, tag: u64 }

// Flags of net_listen and net_accept.
let NONBLOCK: i32 = 1;
let REUSEPORT: i32 = 2;   // net_listen only
let UNIX: i32 = 4;        // net_listen only: addr is a Unix socket's path
let V6ONLY: i32 = 8;      // net_listen only: an IPv6 listener takes no IPv4 clients

// The error codes the loops tell apart, Linux's errno values. shim/net.c
// asserts each one, shim/kqueue.c translates macOS's errno to them, and
// shim/net_win.c Winsock's and Win32's errors.
let ENOENT = 2;
let EINTR = 4;
let EIO = 5;
let EAGAIN = 11;
let EACCES = 13;
let ENOTDIR = 20;
let EISDIR = 21;
let EINVAL = 22;
let ENFILE = 23;
let EMFILE = 24;
let EPIPE = 32;
let ENAMETOOLONG = 36;
let ENOSYS = 38;
let EAFNOSUPPORT = 97;
let EADDRINUSE = 98;
let ECONNABORTED = 103;
let ECONNRESET = 104;
let ENOTCONN = 107;
let ETIMEDOUT = 110;
let ECONNREFUSED = 111;
let EINPROGRESS = 115;

// epoll event bits and epoll_ctl ops, also asserted in shim/net.c, and
// mapped to kqueue's filters in shim/kqueue.c.
let EPOLLIN: u32 = 0x001;
let EPOLLOUT: u32 = 0x004;
let EPOLLERR: u32 = 0x008;
let EPOLLHUP: u32 = 0x010;
let EPOLLRDHUP: u32 = 0x2000;
let EPOLLET: u32 = 0x80000000;
let EPOLL_CTL_ADD: i32 = 1;
let EPOLL_CTL_DEL: i32 = 2;
let EPOLL_CTL_MOD: i32 = 3;

// shutdown's how, asserted in shim/net.c.
let SHUT_WR: i32 = 1;

// A TCP listener on addr, 16 bytes as Address.ip holds them, with
// SO_REUSEADDR and TCP_NODELAY, which accepted sockets inherit. An
// IPv4-mapped address listens on IPv4, any other on IPv6, where :: takes IPv4
// clients too unless V6ONLY; an empty addr is every IPv4 address, or
// 127.0.0.1 on Windows, where the listener has SO_EXCLUSIVEADDRUSE. With
// UNIX, addr is a path, and the listener a Unix socket there, made after
// removing a socket file left at the path; port is unused. With REUSEPORT,
// each worker gets a TCP listener of its own on Linux, and the workers share
// one on macOS and Windows, and for a Unix socket everywhere, which net_close
// closes after the last worker closes it, removing a Unix socket's file.
// EAFNOSUPPORT for a Unix socket on Windows.
extern fn net_listen(addr: const u8[:], port: i32, backlog: i32, flags: i32) -> i32;
// flags must be the listener's NONBLOCK: macOS takes it from the listener. On
// macOS a shared listener's net_accept also fails with EAGAIN while the
// calling worker has taken more than its share of the connections.
extern fn net_accept(fd: i32, flags: i32) -> i32;
// Writes up to buf.len bytes into buf; 0 means the peer closed.
extern fn net_recv(fd: i32, buf: u8[:]) -> i64;
// Sends with MSG_NOSIGNAL: a closed peer is -EPIPE, never SIGPIPE.
extern fn net_send(fd: i32, data: const u8[:]) -> i64;
extern fn net_shutdown(fd: i32, how: i32) -> i32;
extern fn net_close(fd: i32) -> i32;
// The peer of connected socket fd: writes its address into out[..16], an
// IPv4 one as IPv4-mapped IPv6, and returns its port. EAFNOSUPPORT for a peer
// with no IP address.
extern fn net_peer(fd: i32, out: u8[:]) -> i32;
// The local port of socket fd, such as a listener's bound to port 0.
extern fn net_port(fd: i32) -> i32;

// UDP, for QUIC (h3.goose), on Linux and macOS; ENOSYS on Windows. A
// datagram's peer: its socket address as the kernel gave it, len bytes of
// addr.
struct UdpPeer { len: i32, addr: u8[28] }
// A non-blocking UDP socket on addr and port, as net_listen takes them, with
// SO_REUSEPORT under REUSEPORT and V6ONLY as for a listener.
extern fn net_udp_open(addr: const u8[:], port: i32, flags: i32) -> i32;
// Receives up to sizes.len datagrams, the i-th into buf[i * slot..], with
// its size into sizes[i], 0 for one cut short, and its peer into peers[i]:
// how many, or -EAGAIN once none waits.
extern fn net_udp_recv(fd: i32, buf: u8[:], slot: i32, sizes: i32[:], peers: UdpPeer[:]) -> i32;
// Sends the datagrams that lie end to end in buf, sizes[i] bytes each, to
// peers[i]; with gso, those to one peer of one size together where Linux
// segments them (UDP_SEGMENT). How many the kernel took, in order, or
// -EAGAIN for none, and -EINVAL or -EIO where it can't segment them.
extern fn net_udp_send(fd: i32, buf: const u8[:], sizes: const i32[:], peers: const UdpPeer[:], gso: bool) -> i32;

// A non-blocking TCP socket, or with UNIX a Unix socket's, whose connect to
// addr and port, as net_listen takes them, has started or finished; an
// empty addr is EINVAL. net_connected says which: 0 once connected,
// -EINPROGRESS while it goes on, or its error, given once.
extern fn net_connect(addr: const u8[:], port: i32, flags: i32) -> i32;
// The addresses host names, from getaddrinfo, each 16 bytes into out as
// net_connect takes them, in the resolver's order: how many, or -ENOENT for a
// name with none, -EAGAIN for a lookup that failed for now, or -EINVAL. It
// blocks until the lookup ends, so only a thread that may block calls it.
extern fn net_resolve(host: const u8[:], out: u8[:]) -> i32;
extern fn net_connected(fd: i32) -> i32;
// Waits up to ms (-1: no limit) for fd to be ready for events, EPOLLIN and
// EPOLLOUT. Returns the bits it's ready for, EPOLLERR and EPOLLHUP among
// them, or 0 at the time limit, or for a signal, which is the caller's to
// wait out again.
extern fn net_poll(fd: i32, events: u32, ms: i32) -> i32;
// The poller of the loop running on the calling thread, or -1 for none,
// which net_arm adds to: epoll_loop's, while it runs.
extern fn net_loop_bind(ep: i32);
// Watches fd on that poller for events once: the next event carries tag,
// and fd raises none after it until it's armed again. Without one, on the
// io_uring ring that ring_bind bound on Linux, with a one-shot poll. -ENOSYS
// on a thread that runs neither.
extern fn net_arm(fd: i32, events: u32, tag: u64) -> i32;
// Cancels what net_arm armed for tag on that io_uring ring, whose poll holds
// the socket open until its event. Nothing elsewhere: closing a socket takes
// it out of an epoll or kqueue poller.
extern fn net_disarm(tag: u64);

extern fn net_epoll_create() -> i32;
// The kernel keeps tag with fd's registration and returns it in PollEvent.tag.
// It's a number, not a reference into Goose memory.
extern fn net_epoll_ctl(ep: i32, op: i32, fd: i32, events: u32, tag: u64) -> i32;
// Writes the ready events into out[..n], n at most out.len and 1024.
extern fn net_epoll_wait(ep: i32, out: PollEvent[:], timeout_ms: i32) -> i32;

// Monotonic milliseconds, precise, which the loops' timers fall due by; and
// wall-clock seconds since the epoch, up to one scheduler tick old.
extern fn net_clock_ms() -> i64;
extern fn net_time_s() -> i64;

// Readies the calling thread to run a loop. On macOS it gets the
// user-interactive QoS class, which keeps it on the performance cores: Apple
// Silicon has no CPU affinity. Nothing elsewhere.
extern fn net_worker_start();
// The worker count when Config.workers is 0: the performance cores on macOS,
// and 0 elsewhere, for one worker per hardware thread.
extern fn net_default_workers() -> i32;

// Writes the C library's text for an error code (positive) into out, cut to
// fit, and returns its length.
extern fn net_strerror(err: i64, out: u8[:]) -> i64;

// Stops every loop running in the process: each closes its listener and its
// idle connections, answers the next request on each other connection with
// Connection: close, and returns once they have closed, or after
// cfg.grace_ms, with an Error whose code is 0. Each loop's waker, which
// net_stop_watch lists, ends its wait at once. A loop started after the stop
// runs. Any thread may call it.
extern "net_stop" fn stop();
// Lists and unlists a loop's waker (mail.goose's net_waker, ring.goose's
// ring_waker) for stop to wake. net_stop_watch returns 0, or -EMFILE when the
// list is full, and then the loop sees a stop at its next timeout, within a
// second.
extern fn net_stop_watch(waker: i64) -> i32;
extern fn net_stop_unwatch(waker: i64);
// Closes a waker no box owns.
extern fn net_waker_close(waker: i64);
extern fn net_stop_on_signals() -> i32;
// How many times stop has run; a loop stops once it differs from what it was
// at the loop's start.
extern "net_stops" fn stops() -> i64;

// Writes "call: text of the error" to stderr, or "stopped" for a loop that
// stop ended.
fn report(e: Error) {
    if e.code == 0 {
        write_stderr("stopped\n");
        return;
    }
    var msg: u8[>..] = [];
    format(msg, e.call, ": ");
    var text: u8[128] = [0; 128];
    let n = net_strerror(e.code, text);
    msg.append(text[..n]);
    msg.push('\n');
    write_stderr(msg);
}

// Reports e and ends the process with status 1, unless e's code is 0: for a
// call's error in main, or a loop's in a worker that ends the process.
fn exit_on_error(e: Error) {
    guard e.code != 0 else { return; }
    report(e);
    exit(1);
}

// Makes SIGTERM and SIGINT, or on Windows Ctrl+C and Ctrl+Break, call stop
// instead of ending the process. The Error's code is 0 when they do.
fn stop_on_signals() -> Error {
    let s = net_stop_on_signals();
    return Error { call: "sigaction", code: -s };
}
