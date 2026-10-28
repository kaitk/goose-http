/* Shared blobs, for shared.goose, on every platform: byte blobs any thread
   makes at run time and many threads read, counted so the last release frees
   them. A broker can encode a publication once and hand each subscriber's
   worker a reference, instead of a copy through each mailbox.

   A blob's bytes never change after shared_put, and a reference travels to
   another thread only through something that orders memory, such as a
   mailbox or queue, so readers need no lock. The count is atomic. A handle
   is the blob's address; the magic word catches most uses after the last
   release, not all, so the contract is the caller's: every retain is matched
   by one release, and no handle is used after its last.

   Every function returns 0 or more on success and -code on failure, where
   code is a Linux errno value, as the other shims' do. None keeps a pointer
   into Goose memory after it returns. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#ifndef _WIN32
#include <errno.h>
#include <sys/socket.h>
#include <sys/uio.h>
#endif

#include "goose.h"

#define SHARED_EINVAL 22
#define SHARED_ENOMEM 12
#define SHARED_MAGIC 0x5348415245444231ull   /* "SHAREDB1" */
#define SHARED_DEAD 0x4445414442454546ull    /* "DEADBEEF", once freed */

typedef struct { const uint8_t *data; int64_t len; } shared_bytes;

typedef struct {
    uint64_t magic;
    _Atomic int64_t refs;
    int64_t len;
    uint8_t data[];
} shared_blob;

static shared_blob *shared_of(int64_t h) {
    shared_blob *b = (shared_blob *)(intptr_t)h;
    return b && b->magic == SHARED_MAGIC ? b : NULL;
}

/* Copies data into a new blob with refs references and returns its handle,
   or -EINVAL for refs < 1, -ENOMEM. */
int64_t shared_put(shared_bytes data, int64_t refs) {
    if (data.len < 0 || refs < 1) return -SHARED_EINVAL;
    shared_blob *b = malloc(sizeof *b + (size_t)data.len);
    if (!b) return -SHARED_ENOMEM;
    b->magic = SHARED_MAGIC;
    atomic_init(&b->refs, refs);
    b->len = data.len;
    if (data.len) memcpy(b->data, data.data, (size_t)data.len);
    return (int64_t)(intptr_t)b;
}

/* The blob's length, or -EINVAL for a handle that isn't one. */
int64_t shared_len(int64_t h) {
    shared_blob *b = shared_of(h);
    return b ? b->len : -SHARED_EINVAL;
}

/* Adds n references, or -EINVAL. */
int32_t shared_retain(int64_t h, int64_t n) {
    shared_blob *b = shared_of(h);
    if (!b || n < 1) return -SHARED_EINVAL;
    atomic_fetch_add_explicit(&b->refs, n, memory_order_relaxed);
    return 0;
}

/* Drops one reference, freeing the blob with its last. Returns the
   references left, or -EINVAL. */
int64_t shared_release(int64_t h) {
    shared_blob *b = shared_of(h);
    if (!b) return -SHARED_EINVAL;
    int64_t left = atomic_fetch_sub_explicit(&b->refs, 1, memory_order_acq_rel) - 1;
    if (left == 0) {
        b->magic = SHARED_DEAD;
        free(b);
    }
    return left;
}

/* Appends bytes [from, to) of the blob to out. Returns 0, or -EINVAL for a
   handle that isn't one or a range outside it, with nothing appended. */
int32_t shared_append(int64_t h, int64_t from, int64_t to, gs_rref out) {
    shared_blob *b = shared_of(h);
    if (!b || from < 0 || to < from || to > b->len) return -SHARED_EINVAL;
    gs_bld_append(out, b->data + from, to - from);
    return 0;
}

/* Gathered sends, on a loop's thread: while the loop turns gathering on for
   a connection, shared_defer records a blob's range at an offset into the
   loop's write buffer, retained, instead of copying it there. epoll's loop
   sends the buffer and the ranges with one sendmsg, and what the socket
   doesn't take, shared_flatten copies out; either way shared_settle
   releases the ranges. A ring's loop hands the buffer and the ranges to its
   send as a claim (shared_claim_take), which the ring frees once the bytes
   have gone or the connection closed. The loops gather only while they
   drive a connection, and settle or hand on every range before the turn
   ends, so none outlives the connection it was deferred on. */
typedef struct { int64_t at; shared_blob *b; int64_t from, to; } shared_piece;
static _Thread_local struct { shared_piece *p; int64_t n, cap, bytes; int on; } gather;

void shared_settle(void) {
    for (int64_t i = 0; i < gather.n; i++) shared_release((int64_t)(intptr_t)gather.p[i].b);
    gather.n = 0;
    gather.bytes = 0;
}

/* Settles, then gathers the next turn's ranges if on. */
void shared_gather(uint8_t on) {
    shared_settle();
    gather.on = on;
}

/* Bytes deferred since the last settle. */
int64_t shared_pending(void) { return gather.bytes; }

/* Defers bytes [from, to) of the blob at offset at of the write buffer.
   Returns 1, or 0 when the loop isn't gathering, for the caller to copy, or
   -EINVAL as shared_append. */
int32_t shared_defer(int64_t h, int64_t from, int64_t to, int64_t at) {
    shared_blob *b = shared_of(h);
    if (!b || from < 0 || to < from || to > b->len) return -SHARED_EINVAL;
    if (!gather.on) return 0;
    if (to == from) return 1;
    if (gather.n == gather.cap) {
        int64_t cap = gather.cap ? 2 * gather.cap : 64;
        shared_piece *p = realloc(gather.p, (size_t)cap * sizeof *p);
        if (!p) return 0;
        gather.p = p; gather.cap = cap;
    }
    atomic_fetch_add_explicit(&b->refs, 1, memory_order_relaxed);
    gather.p[gather.n++] = (shared_piece){ at, b, from, to };
    gather.bytes += to - from;
    return 1;
}

/* Calls f for each run of the write buffer buf and the deferred ranges,
   in order, from offset skip of the whole; stops when f returns 0. */
static void shared_runs(shared_bytes buf, int64_t skip, int (*f)(void *, const uint8_t *, int64_t), void *arg) {
    int64_t at = 0;
    for (int64_t i = 0; i <= gather.n; i++) {
        int64_t end = i < gather.n ? gather.p[i].at : buf.len;
        for (int k = 0; k < 2; k++) {
            const uint8_t *d; int64_t n;
            if (k == 0) { d = buf.data + at; n = end - at; at = end; }
            else if (i < gather.n) { d = gather.p[i].b->data + gather.p[i].from; n = gather.p[i].to - gather.p[i].from; }
            else break;
            if (skip >= n) { skip -= n; continue; }
            if (!f(arg, d + skip, n - skip)) return;
            skip = 0;
        }
    }
}

static int shared_copy_run(void *out, const uint8_t *d, int64_t n) {
    gs_bld_append(*(gs_rref *)out, d, n);
    return 1;
}

/* Appends the write buffer and deferred ranges from offset skip of the
   whole to out, then settles. */
void shared_flatten(shared_bytes buf, int64_t skip, gs_rref out) {
    shared_runs(buf, skip, shared_copy_run, &out);
    shared_settle();
}

/* A ring's gathered send (shim/uring.c, shim/ring_epoll.c), which outlives
   the call that queued it: a copy of the write buffer, and the deferred
   ranges' references, moved from the loop's list, all in one allocation.
   runs, in order, point into the copy and the blobs. shared_claim_free
   releases the references once the ring is done with the bytes. */
typedef struct { const uint8_t *d; int64_t n; } shared_run;
typedef struct shared_claim {
    int64_t len;
    int64_t nruns, nrefs;
    shared_blob **refs;
    shared_run runs[];
} shared_claim;

static int shared_claim_run(void *arg, const uint8_t *d, int64_t n) {
    shared_claim *c = arg;
    if (n > 0) c->runs[c->nruns++] = (shared_run){ d, n };
    return 1;
}

/* Takes the write buffer, len bytes at data, and the deferred ranges into a claim, leaving
   none deferred. NULL when out of memory, with the ranges settled. */
shared_claim *shared_claim_take(const uint8_t *data, int64_t len) {
    int64_t n = gather.n;
    size_t runs = (size_t)(2 * n + 1);
    shared_claim *c = malloc(sizeof *c + runs * sizeof(shared_run) + (size_t)n * sizeof(shared_blob *) + (size_t)len);
    if (!c) {
        shared_settle();
        return NULL;
    }
    c->refs = (shared_blob **)(void *)(c->runs + runs);
    uint8_t *copy = (uint8_t *)(c->refs + n);
    if (len) memcpy(copy, data, (size_t)len);
    c->len = len + gather.bytes;
    c->nruns = 0;
    shared_runs((shared_bytes){ copy, len }, 0, shared_claim_run, c);
    for (int64_t i = 0; i < n; i++) c->refs[i] = gather.p[i].b;
    c->nrefs = n;
    gather.n = 0;
    gather.bytes = 0;
    return c;
}

int64_t shared_claim_len(const shared_claim *c) { return c->len; }

/* Releases the claim's references, and frees it. */
void shared_claim_free(shared_claim *c) {
    for (int64_t i = 0; i < c->nrefs; i++) shared_release((int64_t)(intptr_t)c->refs[i]);
    free(c);
}

#ifndef _WIN32
#define SHARED_IOV 64
typedef struct { struct iovec v[SHARED_IOV]; int n; } shared_iovs;

/* Fills v with up to max runs of the claim from offset off. Returns how
   many. */
int32_t shared_claim_iov(const shared_claim *c, int64_t off, struct iovec *v, int32_t max) {
    int32_t k = 0;
    for (int64_t i = 0; i < c->nruns && k < max; i++) {
        int64_t n = c->runs[i].n;
        if (off >= n) {
            off -= n;
            continue;
        }
        v[k++] = (struct iovec){ (void *)(c->runs[i].d + off), (size_t)(n - off) };
        off = 0;
    }
    return k;
}

/* Maps a failed send's errno to the Linux numbers the loops tell apart
   (sys.goose). */
static int64_t shared_send_err(void) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return -11;
    if (errno == EINTR) return -4;
    return -32;
}

/* Sends the claim from offset off on socket fd, in one sendmsg of up to 64
   runs. Returns the bytes sent, or -errno as shared_send. */
int64_t shared_claim_send(int32_t fd, const shared_claim *c, int64_t off) {
    struct iovec v[SHARED_IOV];
    struct msghdr m = { .msg_iov = v, .msg_iovlen = (size_t)shared_claim_iov(c, off, v, SHARED_IOV) };
    ssize_t r = sendmsg(fd, &m, MSG_NOSIGNAL);
    return r >= 0 ? r : shared_send_err();
}

static int shared_iov_run(void *arg, const uint8_t *d, int64_t n) {
    shared_iovs *iov = arg;
    if (n == 0) return 1;
    iov->v[iov->n++] = (struct iovec){ (void *)d, (size_t)n };
    return iov->n < SHARED_IOV;
}

/* Sends what follows offset skip of the write buffer and deferred ranges on
   socket fd, in one sendmsg of up to 64 runs. Returns the bytes sent, or
   -errno. */
int64_t shared_send(int32_t fd, shared_bytes buf, int64_t skip) {
    shared_iovs iov = { .n = 0 };
    shared_runs(buf, skip, shared_iov_run, &iov);
    struct msghdr m = { .msg_iov = iov.v, .msg_iovlen = (size_t)iov.n };
    ssize_t r = sendmsg(fd, &m, MSG_NOSIGNAL);
    return r >= 0 ? r : shared_send_err();
}
#else
int64_t shared_send(int32_t fd, shared_bytes buf, int64_t skip) { (void)fd; (void)buf; (void)skip; return -38; }
#endif
