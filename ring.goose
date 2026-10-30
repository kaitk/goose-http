// The io_uring calls of http::serve's loop, implemented in shim/uring.c over
// liburing, on Windows in shim/iocp.c over a completion port, and on macOS in
// shim/ring_epoll.c over kqueue. A ring is the shim's, and owns every buffer
// the kernel reads or writes after a call returns: receives land in its
// provided buffers, and a send copies what of its bytes the socket didn't take
// during the call. Calls that can fail return -errno, as net_*'s do.
namespace http;

// One completion. tag is what its request was queued with. For a receive,
// buf is the provided buffer holding its res bytes, or -1 for none, and the
// buffer goes back to the ring with ring_give. more is whether a multishot
// request goes on. A send's completion has send set, and res is every byte
// it was given, or its error: the shim queues a short send's rest itself. A
// send waiting behind another on its fd may take in the ones after it, and
// then res counts their bytes too. A file's send (ring_send_file) completes
// once per piece that went out, with more set until its last.
struct Completion { tag: u64, res: i32, buf: i32, more: bool, send: bool }

// The errno values of completions, beyond sys.goose's. shim/uring.c asserts
// them, and shim/iocp.c returns them.
let ENOBUFS = 105;
let ECANCELED = 125;

// A ring of entries submission entries, with nbufs provided buffers of
// buflen bytes; nbufs is a power of two. A tag fits in 62 bits. On Linux the
// ring is shim/ring_epoll.c's emulation over epoll where io_uring_setup
// fails, or with RING_EMULATE in flags; on macOS it always is, over kqueue.
// With RING_REQUIRE, Linux returns io_uring's error instead of emulating.
extern "ur_create" fn ring_create(entries: i32, nbufs: i32, buflen: i32, flags: i32) -> i64;

// ring_create's flags.
let RING_EMULATE: i32 = 1;
let RING_REQUIRE: i32 = 2;

// Whether ring_create gets the platform's own ring: 0, or -code for why it
// falls back to the emulation (ENOSYS on macOS, which has no other). A
// program can call it at startup to say which ring serve runs on.
extern "ur_probe" fn ring_probe() -> i32;

// The most listeners a ring accepts on: one on Windows, more elsewhere.
extern "ur_listeners" fn ring_listeners() -> i32;

// Queue requests, which go to the kernel at the next wait.
extern "ur_accept" fn ring_accept(r: i64, fd: i32, tag: u64);
extern "ur_recv" fn ring_recv(r: i64, fd: i32, tag: u64);
// A send goes out after those queued before it on fd, one at a time.
extern "ur_send" fn ring_send(r: i64, fd: i32, tag: u64, data: const u8[:]) -> i32;
// Whether ring_send_shared works on r: everywhere but Windows.
extern "ur_gathers" fn ring_gathers(r: i64) -> bool;
// ring_send, of data and the shared ranges send_shared deferred into it
// (shared.goose), which the ring sends from their blobs with the bytes
// around them. It takes over their references and releases them once the
// send ends or fd closes, also when this fails. Its completions count every
// byte, data's and the ranges'.
extern "ur_send_shared" fn ring_send_shared(r: i64, fd: i32, tag: u64, data: const u8[:]) -> i32;
// Sends len bytes of file, a handle net_file_open returned, from off, after
// those queued before it on fd, without copying them through the program:
// with splice through a pipe on io_uring, TransmitFile on Windows, and
// sendfile on the emulation. The ring keeps file, and closes it after the
// last piece, on an error, at ring_close of fd, or at ring_destroy, also
// when this fails. A file that ends early fails the send with EIO.
extern "ur_send_file" fn ring_send_file(r: i64, fd: i32, tag: u64, file: i64, off: i64, len: i64) -> i32;
extern "ur_cancel" fn ring_cancel(r: i64, tag: u64);
// Cancels every request on fd, then closes it. recv is the tag of fd's
// receive while one is queued, until its completion without more, and 0
// otherwise: io_uring cancels the receive by it. Sends not yet started are
// dropped, with no completion.
extern "ur_close" fn ring_close(r: i64, fd: i32, recv: u64);
// Writes dst.len bytes of provided buffer buf, from off, into dst.
extern "ur_take" fn ring_take(r: i64, buf: i32, off: i64, dst: u8[:]);
extern "ur_give" fn ring_give(r: i64, buf: i32);
// A waker (net_waker, mail.goose) on the ring: each wake ends the ring's
// wait with a completion of tag, res 0, and no buffer. Returns it, or -code.
// The box that owns it is closed after the ring is destroyed.
extern "ur_waker" fn ring_waker(r: i64, tag: u64) -> i64;
// Makes net_arm (wait_socket) on this thread arm sockets on ring r, until
// it's destroyed: a socket's readiness completes with tag, and buf the
// index ring_socket turns into net_arm's key. Only io_uring's ring takes
// it: on the others net_arm stays ENOSYS, and these three do nothing.
extern "ur_bind" fn ring_bind(r: i64, tag: u64);
// The key of the socket whose completion had buf k, or 0 for none: it was
// disarmed after its completion was queued.
extern "ur_socket" fn ring_socket(r: i64, k: i32) -> u64;
// Cancels the readiness of each socket armed for a key whose bits under
// mask are key's. A completion already queued for one comes as ring_socket's
// 0.
extern "ur_disarm" fn ring_disarm(r: i64, key: u64, mask: u64);
// Tears the ring down, with whatever is still queued on it. Windows keeps a
// completion port's memory: it completes the cancels of closed sockets'
// requests later (shim/iocp.c).
extern "ur_destroy" fn ring_destroy(r: i64);
// Submits what's queued, waits up to timeout_ms (-1: no limit) for a
// completion, and writes up to out.len completions into out.
extern "ur_wait" fn ring_wait(r: i64, out: Completion[:], timeout_ms: i32) -> i32;
