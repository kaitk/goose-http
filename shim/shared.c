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
    /* The slot outlives its blobs, so this reads no freed memory. A stale
       handle's last release and another put can come between the check and
       the read, so the generation is checked again after it. */
    int64_t len = atomic_load_explicit(&s->len, memory_order_relaxed);
    atomic_thread_fence(memory_order_acquire);
    w = atomic_load_explicit(&s->word, memory_order_relaxed);
    if ((uint32_t)(w >> 32) != gen || (uint32_t)w == 0) return -SHARED_EINVAL;
    return len;
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
