/* Shared blobs, for shared.goose, on every platform: byte blobs any thread
   makes at run time and many threads read, counted so the last release frees
   them. A broker can encode a publication once and hand each subscriber's
   worker a reference, instead of a copy through each mailbox.

   A blob lives in a slot of one process-wide table, and a handle is the
   slot and the generation the slot had when the blob was put, as
   handle.goose's are: generation << 32 | slot, never 0 or negative. Each
   slot packs its generation and its blob's count in one atomic word, so
   every call checks the generation and changes the count in one
   compare-and-swap. The last release advances the generation in the same
   step, so a handle kept past it, or a forged one, is refused, even once
   the slot holds another blob, rather than read. The table grows in chunks
   that never move, so a lookup takes no lock; only a put and a last release
   take the free list's.

   A blob's bytes never change after shared_put, and a reference travels to
   another thread only through something that orders memory, such as a
   mailbox or queue, so readers need no lock. Every retain is still the
   caller's to match with one release.

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

typedef struct { const uint8_t *data; int64_t len; } shared_bytes;

/* A slot: word is generation << 32 | references, and a slot whose count is
   0 holds no blob. A slot's first generation is 1; one that was never used
   reads 0, which no handle has. Generations stay below 2^31, so that a
   handle is positive. */
typedef struct {
    _Atomic uint64_t word;
    _Atomic(uint8_t *) data;
    _Atomic int64_t len;
    uint32_t next;              /* the next free slot, under the lock */
} shared_slot;

#define SHARED_CHUNK 4096
#define SHARED_CHUNKS 4096      /* up to 16M blobs at once */
#define SHARED_NONE UINT32_MAX
#define SHARED_GEN_MAX 0x7FFFFFFFu

static _Atomic(shared_slot *) shared_chunks[SHARED_CHUNKS];
static uint32_t shared_free = SHARED_NONE;     /* under the lock */
static uint32_t shared_used;                   /* slots ever handed out, under the lock */

/* The lock guards only the free list: a put and a last release take it for
   a few instructions, and lookups never do. It's the platform's mutex, as
   mail.c's, not a spinlock: uncontended both cost one atomic, but a program
   often runs more threads than cores (Campfire: workers, its broker and a
   checkpointer on 4 CPUs), where a spinning waiter whose holder was
   preempted burns its whole time slice, and a new chunk's calloc and page
   faults (once per 4096 slots) run under the lock. A mutex sleeps instead. */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static SRWLOCK shared_lock = SRWLOCK_INIT;
static void shared_lock_take(void) { AcquireSRWLockExclusive(&shared_lock); }
static void shared_lock_drop(void) { ReleaseSRWLockExclusive(&shared_lock); }
#else
#include <pthread.h>
static pthread_mutex_t shared_lock = PTHREAD_MUTEX_INITIALIZER;
static void shared_lock_take(void) { pthread_mutex_lock(&shared_lock); }
static void shared_lock_drop(void) { pthread_mutex_unlock(&shared_lock); }
#endif

static uint32_t shared_next_gen(uint32_t gen) { return gen >= SHARED_GEN_MAX ? 1 : gen + 1; }

/* h's slot, or NULL for a handle that names none. Its generation is gen. */
static shared_slot *shared_slot_of(int64_t h, uint32_t *gen) {
    if (h <= 0) return NULL;
    uint32_t slot = (uint32_t)h;
    *gen = (uint32_t)((uint64_t)h >> 32);
    if (*gen == 0 || slot >= (uint32_t)SHARED_CHUNK * SHARED_CHUNKS) return NULL;
    shared_slot *chunk = atomic_load_explicit(&shared_chunks[slot / SHARED_CHUNK], memory_order_acquire);
    return chunk ? &chunk[slot % SHARED_CHUNK] : NULL;
}

/* Adds n references to h's blob, and returns its slot, or NULL for a handle
   that isn't a live blob's, or a count past 2^32 - 1. Acquire: the caller
   then reads the blob's bytes. */
static shared_slot *shared_acquire(int64_t h, int64_t n) {
    uint32_t gen;
    shared_slot *s = shared_slot_of(h, &gen);
    if (!s || n < 1) return NULL;
    uint64_t w = atomic_load_explicit(&s->word, memory_order_relaxed);
    do {
        uint64_t refs = (uint32_t)w;
        if ((uint32_t)(w >> 32) != gen || refs == 0 || (uint64_t)n > UINT32_MAX - refs) return NULL;
    } while (!atomic_compare_exchange_weak_explicit(&s->word, &w, w + (uint64_t)n,
                                                    memory_order_acquire, memory_order_relaxed));
    return s;
}

/* Copies data into a new blob with refs references and returns its handle,
   or -EINVAL for refs < 1 or past 2^32 - 1, -ENOMEM. */
int64_t shared_put(shared_bytes data, int64_t refs) {
    if (data.len < 0 || refs < 1 || refs > (int64_t)UINT32_MAX) return -SHARED_EINVAL;
    uint8_t *bytes = malloc(data.len ? (size_t)data.len : 1);
    if (!bytes) return -SHARED_ENOMEM;
    if (data.len) memcpy(bytes, data.data, (size_t)data.len);
    shared_lock_take();
    uint32_t slot = shared_free;
    if (slot != SHARED_NONE) {
        shared_slot *chunk = atomic_load_explicit(&shared_chunks[slot / SHARED_CHUNK], memory_order_relaxed);
        shared_free = chunk[slot % SHARED_CHUNK].next;
    } else if (shared_used < (uint32_t)SHARED_CHUNK * SHARED_CHUNKS) {
        slot = shared_used;
        if (slot % SHARED_CHUNK == 0) {
            shared_slot *chunk = calloc(SHARED_CHUNK, sizeof *chunk);
            if (!chunk) slot = SHARED_NONE;
            else atomic_store_explicit(&shared_chunks[slot / SHARED_CHUNK], chunk, memory_order_release);
        }
        if (slot != SHARED_NONE) shared_used++;
    }
    shared_lock_drop();
    if (slot == SHARED_NONE) {
        free(bytes);
        return -SHARED_ENOMEM;
    }
    shared_slot *s = &atomic_load_explicit(&shared_chunks[slot / SHARED_CHUNK], memory_order_relaxed)[slot % SHARED_CHUNK];
    atomic_store_explicit(&s->data, bytes, memory_order_relaxed);
    atomic_store_explicit(&s->len, data.len, memory_order_relaxed);
    uint32_t gen = (uint32_t)(atomic_load_explicit(&s->word, memory_order_relaxed) >> 32);
    if (gen == 0) gen = 1;
    /* Release: whoever acquires the blob by this handle sees its bytes. */
    atomic_store_explicit(&s->word, (uint64_t)gen << 32 | (uint64_t)refs, memory_order_release);
    return (int64_t)((uint64_t)gen << 32 | slot);
}

/* The blob's length, or -EINVAL for a handle that isn't a live blob's. */
int64_t shared_len(int64_t h) {
    uint32_t gen;
    shared_slot *s = shared_slot_of(h, &gen);
    if (!s) return -SHARED_EINVAL;
    uint64_t w = atomic_load_explicit(&s->word, memory_order_acquire);
    if ((uint32_t)(w >> 32) != gen || (uint32_t)w == 0) return -SHARED_EINVAL;
    /* The slot outlives its blobs, so this reads no freed memory, and a
       blob put in it since has another generation. */
    return atomic_load_explicit(&s->len, memory_order_relaxed);
}

/* Adds n references, or -EINVAL for a handle that isn't a live blob's, n < 1,
   or a count past 2^32 - 1. */
int32_t shared_retain(int64_t h, int64_t n) {
    return shared_acquire(h, n) ? 0 : -SHARED_EINVAL;
}

/* Drops one reference, freeing the blob with its last, which advances the
   slot's generation and frees the slot. Returns the references left, or
   -EINVAL for a handle that isn't a live blob's. */
int64_t shared_release(int64_t h) {
    uint32_t gen;
    shared_slot *s = shared_slot_of(h, &gen);
    if (!s) return -SHARED_EINVAL;
    uint64_t w = atomic_load_explicit(&s->word, memory_order_relaxed);
    uint64_t next;
    do {
        uint32_t refs = (uint32_t)w;
        if ((uint32_t)(w >> 32) != gen || refs == 0) return -SHARED_EINVAL;
        next = refs == 1 ? (uint64_t)shared_next_gen(gen) << 32 : w - 1;
    } while (!atomic_compare_exchange_weak_explicit(&s->word, &w, next,
                                                    memory_order_acq_rel, memory_order_relaxed));
    if ((uint32_t)next != 0) return (uint32_t)next;
    free(atomic_load_explicit(&s->data, memory_order_relaxed));
    atomic_store_explicit(&s->data, NULL, memory_order_relaxed);
    shared_lock_take();
    s->next = shared_free;
    shared_free = (uint32_t)h;
    shared_lock_drop();
    return 0;
}

/* Appends bytes [from, to) of the blob to out. Returns 0, or -EINVAL for a
   handle that isn't a live blob's or a range outside it, with nothing
   appended. It holds a reference of its own while it copies: a caller's
   would do, but a stale handle has none, and another thread's last release
   could free the bytes mid-copy. */
int32_t shared_append(int64_t h, int64_t from, int64_t to, gs_rref out) {
    shared_slot *s = shared_acquire(h, 1);
    if (!s) return -SHARED_EINVAL;
    int64_t len = atomic_load_explicit(&s->len, memory_order_relaxed);
    int32_t r = -SHARED_EINVAL;
    if (from >= 0 && to >= from && to <= len) {
        gs_bld_append(out, atomic_load_explicit(&s->data, memory_order_relaxed) + from, to - from);
        r = 0;
    }
    shared_release(h);
    return r;
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
   ends, so none outlives the connection it was deferred on. A piece's
   reference keeps its bytes, d, in place until its release. */
typedef struct { int64_t at; int64_t h; const uint8_t *d; int64_t n; } shared_piece;
static _Thread_local struct { shared_piece *p; int64_t n, cap, bytes; int on; } gather;

void shared_settle(void) {
    for (int64_t i = 0; i < gather.n; i++) shared_release(gather.p[i].h);
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
    if (gather.on && gather.n == gather.cap) {
        int64_t cap = gather.cap ? 2 * gather.cap : 64;
        shared_piece *p = realloc(gather.p, (size_t)cap * sizeof *p);
        if (p) {
            gather.p = p;
            gather.cap = cap;
        }
    }
    /* Not gathering, or out of memory: the caller copies the range. */
    if (!gather.on || gather.n == gather.cap) {
        int64_t len = shared_len(h);
        return len >= 0 && from >= 0 && to >= from && to <= len ? 0 : -SHARED_EINVAL;
    }
    shared_slot *s = shared_acquire(h, 1);
    if (!s) return -SHARED_EINVAL;
    int64_t len = atomic_load_explicit(&s->len, memory_order_relaxed);
    if (from < 0 || to < from || to > len || to == from) {
        shared_release(h);
        return to == from && from >= 0 && from <= len ? 1 : -SHARED_EINVAL;
    }
    gather.p[gather.n++] = (shared_piece){ at, h, atomic_load_explicit(&s->data, memory_order_relaxed) + from, to - from };
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
            else if (i < gather.n) { d = gather.p[i].d; n = gather.p[i].n; }
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
    int64_t *refs;          /* the ranges' handles */
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
    shared_claim *c = malloc(sizeof *c + runs * sizeof(shared_run) + (size_t)n * sizeof(int64_t) + (size_t)len);
    if (!c) {
        shared_settle();
        return NULL;
    }
    c->refs = (int64_t *)(void *)(c->runs + runs);
    uint8_t *copy = (uint8_t *)(c->refs + n);
    if (len) memcpy(copy, data, (size_t)len);
    c->len = len + gather.bytes;
    c->nruns = 0;
    shared_runs((shared_bytes){ copy, len }, 0, shared_claim_run, c);
    for (int64_t i = 0; i < n; i++) c->refs[i] = gather.p[i].h;
    c->nrefs = n;
    gather.n = 0;
    gather.bytes = 0;
    return c;
}

int64_t shared_claim_len(const shared_claim *c) { return c->len; }

/* Releases the claim's references, and frees it. */
void shared_claim_free(shared_claim *c) {
    for (int64_t i = 0; i < c->nrefs; i++) shared_release(c->refs[i]);
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
