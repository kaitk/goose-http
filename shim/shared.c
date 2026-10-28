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
