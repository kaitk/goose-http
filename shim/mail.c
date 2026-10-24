/* Mailboxes, for mail.goose, on every platform: bounded queues that any
   thread sends to and one thread, the box's owner, takes from. goose build
   compiles this beside the program, so it sees none of the generated C.

   A box is a ring of slots allocated at open and never grown, each a header
   and up to the box's slot size of message bytes. Sending is lock-free, after
   Vyukov's bounded queue: a sender claims a slot with one compare-and-swap on
   the enqueue position, retried only when another sender took it first,
   copies its message in, and publishes it with a release store of the slot's
   sequence number. The owner takes with no read-modify-write per message.

   A counter of messages pending wakes the owner only when a send moves it
   from 0 to 1, so a burst costs one wakeup. The owner subtracts what it
   took (mail_settle) and takes again if more came meanwhile, so no wakeup is
   lost: the count reaches 1 again only from 0, through a send that wakes.
   The wakeup is the platform shim's (net_waker_*: an eventfd on Linux,
   EVFILT_USER on macOS, a completion packet on Windows).

   A box is named by its slot in a table and the slot's generation, as a
   64-bit key: the generation above, the slot below (handle.goose). The table
   changes only at open and close, under an OS lock. A send raises its box's
   count of senders in flight while it copies; a close advances the
   generation, then yields until that count is 0 before it frees the slots,
   so no sender writes into freed memory, and a send that comes after the
   close finds the generation moved on and returns STALE.

   Every function returns 0 or more on success and -code on failure, where
   code is a Linux errno value, as the other shims' do. None keeps a pointer
   into Goose memory after it returns. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* The atomics: Interlocked* and winnt.h's ReadAcquire family for MSVC, which
   has no C11 atomics in C, and C11's for every other compiler, MinGW's gcc
   included. Each names its memory order; the seq_cst ones pair a sender's
   count with a close's generation (above). The lock and the yield are the
   platform's. */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static SRWLOCK mail_lock = SRWLOCK_INIT;
#define LOCK() AcquireSRWLockExclusive(&mail_lock)
#define UNLOCK() ReleaseSRWLockExclusive(&mail_lock)
#define YIELD() SwitchToThread()
#else
#include <pthread.h>
#include <sched.h>
static pthread_mutex_t mail_lock = PTHREAD_MUTEX_INITIALIZER;
#define LOCK() pthread_mutex_lock(&mail_lock)
#define UNLOCK() pthread_mutex_unlock(&mail_lock)
#define YIELD() sched_yield()
#endif

#ifdef _MSC_VER
typedef volatile LONG mail_a32;
typedef volatile LONG64 mail_a64;
#define LOAD32_RELAXED(p) ((uint32_t)ReadNoFence(p))
#define LOAD32_ACQUIRE(p) ((uint32_t)ReadAcquire(p))
#define STORE32_RELEASE(p, v) WriteRelease((p), (LONG)(v))
#define LOAD32_SEQ(p) ((uint32_t)InterlockedOr((p), 0))
#define STORE32_SEQ(p, v) InterlockedExchange((p), (LONG)(v))
/* Whether *p was e, and then is d; otherwise e becomes *p. */
static int mail_cas32(mail_a32 *p, uint32_t *e, uint32_t d) {
    LONG old = InterlockedCompareExchange(p, (LONG)d, (LONG)*e);
    if ((uint32_t)old == *e) return 1;
    *e = (uint32_t)old;
    return 0;
}
#define CAS32_RELAXED(p, e, d) mail_cas32((p), (e), (d))
#define ADD64(p, v) ((int64_t)InterlockedExchangeAdd64((p), (LONG64)(v)))
#define LOAD64_ACQUIRE(p) ((int64_t)ReadAcquire64(p))
#define LOAD64_SEQ(p) ((int64_t)InterlockedOr64((p), 0))
#define STORE64_SEQ(p, v) InterlockedExchange64((p), (LONG64)(v))
#define CAS64(p, e, d) (InterlockedCompareExchange64((p), (LONG64)(d), (LONG64)(e)) == (LONG64)(e))
#define PAUSE() YieldProcessor()
#else
#include <stdatomic.h>
typedef _Atomic uint32_t mail_a32;
typedef _Atomic int64_t mail_a64;
#define LOAD32_RELAXED(p) atomic_load_explicit((p), memory_order_relaxed)
#define LOAD32_ACQUIRE(p) atomic_load_explicit((p), memory_order_acquire)
#define STORE32_RELEASE(p, v) atomic_store_explicit((p), (v), memory_order_release)
#define LOAD32_SEQ(p) atomic_load((p))
#define STORE32_SEQ(p, v) atomic_store((p), (v))
#define CAS32_RELAXED(p, e, d) \
    atomic_compare_exchange_weak_explicit((p), (e), (d), memory_order_relaxed, memory_order_relaxed)
#define ADD64(p, v) atomic_fetch_add((p), (v))
#define LOAD64_ACQUIRE(p) atomic_load_explicit((p), memory_order_acquire)
#define LOAD64_SEQ(p) atomic_load((p))
#define STORE64_SEQ(p, v) atomic_store((p), (v))
static int mail_cas64(mail_a64 *p, int64_t e, int64_t d) { return atomic_compare_exchange_strong(p, &e, d); }
#define CAS64(p, e, d) mail_cas64((p), (e), (d))
#if defined(__x86_64__) || defined(__i386__)
#define PAUSE() __builtin_ia32_pause()
#elif defined(__aarch64__) && !defined(__TINYC__)
#define PAUSE() __asm__ __volatile__("yield")
#else
#define PAUSE() ((void)0)
#endif
#endif

/* Linux's errno values, which every shim returns. */
#define MAIL_EINVAL 22
#define MAIL_ENOMEM 12
#define MAIL_EMFILE 24

/* mail.goose's results of a send. */
#define MAIL_SENT 0
#define MAIL_FULL 1
#define MAIL_STALE 2
#define MAIL_TOO_LONG 3

/* From the platform's shim. A waker for ep, which a wake makes report tag,
   or for ep -1 one of its own that net_waker_wait waits on. */
int64_t net_waker(int32_t ep, uint64_t tag);
void net_waker_wake(int64_t w);
int32_t net_waker_wait(int64_t w, int32_t ms);
void net_waker_close(int64_t w);
int64_t net_clock_ms(void);

/* A u8[:] and an i64[:], packed as Goose packs them (spec C.2). */
#pragma pack(push, 1)
typedef struct { uint8_t *data; int64_t len; } mail_bytes;
typedef struct { int64_t *data; int64_t len; } mail_i64s;
#pragma pack(pop)
_Static_assert(sizeof(mail_bytes) == sizeof(void *) + 8 && sizeof(mail_i64s) == sizeof(void *) + 8,
               "not packed as Goose packs them");

/* A slot's header: its sequence number, and the message's key, tag, and
   length. The bytes follow. */
typedef struct {
    mail_a32 seq;
    int32_t tag;
    uint32_t len;
    uint32_t pad;
    uint64_t key;
} mail_slot;

/* The enqueue position, which senders contend for, and the owner's dequeue
   position are a cache line apart. */
typedef struct {
    mail_a32 enq;
    char pad1[60];
    uint32_t deq;
    uint32_t mask, size, stride;
    mail_a64 pending;
    mail_a32 stopped;
    int64_t waker;
    int own_waker;
    unsigned char *slots;
    mail_a64 *live;
    uint32_t live_count, key_shift;
} mail_box;

#define MAIL_MAX_BOXES 4096
static struct {
    mail_a32 gen;           /* the generation the next or current box has */
    mail_a64 senders;       /* sends in flight */
    mail_box *box;          /* NULL while free; read by senders only after the generation check */
} mail_table[MAIL_MAX_BOXES];

static uint32_t mail_next_gen(uint32_t gen) { return gen == 0xFFFFFFFFu ? 1 : gen + 1; }

static mail_slot *mail_at(mail_box *b, uint32_t pos) {
    return (mail_slot *)(b->slots + (size_t)(pos & b->mask) * b->stride);
}

/* Opens a box of slots slots, a power of two of at least 2, each taking a
   message of up to size bytes. One slot can't work: once filled, its sequence
   number equals the next send's position, which mail_send reads as free.
   waker is the platform's waker the box wakes, which the box then
   owns, or 0 for one of the box's own, for mail_wait. live_count is the number
   of keys the owner can mark, indexed by key >> key_shift; 0 disables key
   tracking. Returns the box's key. */
int64_t mail_open(int32_t slots, int32_t size, int64_t waker, int32_t live_count, int32_t key_shift) {
    if (slots < 2 || (slots & (slots - 1)) || size < 0 || live_count < 0 ||
        key_shift < 0 || key_shift > 63) return -MAIL_EINVAL;
    mail_box *b = calloc(1, sizeof *b);
    if (!b) return -MAIL_ENOMEM;
    b->mask = (uint32_t)slots - 1;
    b->size = (uint32_t)size;
    b->stride = (uint32_t)((sizeof(mail_slot) + (size_t)size + 7) & ~(size_t)7);
    b->slots = malloc((size_t)slots * b->stride);
    if (!b->slots) {
        free(b);
        return -MAIL_ENOMEM;
    }
    for (uint32_t i = 0; i < (uint32_t)slots; i++) STORE32_RELEASE(&mail_at(b, i)->seq, i);
    b->live_count = (uint32_t)live_count;
    b->key_shift = (uint32_t)key_shift;
    /* calloc's zeroes need no stores of their own, which would commit every page
       of a table sized for the most connections: senders reach the box only
       through the key returned below, as they reach b itself. */
    if (live_count) {
        b->live = calloc((size_t)live_count, sizeof *b->live);
        if (!b->live) {
            free(b->slots);
            free(b);
            return -MAIL_ENOMEM;
        }
    }
    b->own_waker = waker == 0;
    b->waker = waker ? waker : net_waker(-1, 0);
    if (b->waker < 0) {
        int64_t err = b->waker;
        free(b->live);
        free(b->slots);
        free(b);
        return err;
    }
    LOCK();
    int i = 0;
    while (i < MAIL_MAX_BOXES && mail_table[i].box) i++;
    if (i == MAIL_MAX_BOXES) {
        UNLOCK();
        if (b->own_waker) net_waker_close(b->waker);
        free(b->live);
        free(b->slots);
        free(b);
        return -MAIL_EMFILE;
    }
    uint32_t gen = LOAD32_RELAXED(&mail_table[i].gen);
    if (gen == 0) {
        gen = 1;
        STORE32_SEQ(&mail_table[i].gen, gen);
    }
    mail_table[i].box = b;
    UNLOCK();
    return (int64_t)(((uint64_t)gen << 32) | (uint32_t)i);
}

/* The box of key for its owner, which holds a key that's current. */
static mail_box *mail_own(uint64_t key) {
    uint32_t i = (uint32_t)key;
    return i < MAIL_MAX_BOXES ? mail_table[i].box : NULL;
}

/* Closes the box of key: sends from then on return STALE, and what it holds
   is dropped. Its waker is closed too. */
void mail_close(uint64_t key) {
    uint32_t i = (uint32_t)key;
    if (i >= MAIL_MAX_BOXES) return;
    LOCK();
    mail_box *b = mail_table[i].box;
    if (!b || LOAD32_RELAXED(&mail_table[i].gen) != (uint32_t)(key >> 32)) {
        UNLOCK();
        return;
    }
    STORE32_SEQ(&mail_table[i].gen, mail_next_gen((uint32_t)(key >> 32)));
    while (LOAD64_ACQUIRE(&mail_table[i].senders) != 0) YIELD();
    mail_table[i].box = NULL;
    UNLOCK();
    net_waker_close(b->waker);
    free(b->live);
    free(b->slots);
    free(b);
}

static int mail_key_live(mail_box *b, uint64_t key) {
    if (!b->live_count) return 1;
    uint64_t i = key >> b->key_shift;
    return key != 0 && i < b->live_count && (uint64_t)LOAD64_ACQUIRE(&b->live[i]) == key;
}

/* Only the owner marks keys. Zero is reserved for an empty entry; the high
   bits above key_shift select the entry, and the whole key must match. */
void mail_mark(uint64_t box, uint64_t key, int32_t live) {
    mail_box *b = mail_own(box);
    if (!b || !b->live_count || !key) return;
    uint64_t i = key >> b->key_shift;
    if (i >= b->live_count) return;
    if (live) STORE64_SEQ(&b->live[i], (int64_t)key);
    else CAS64(&b->live[i], (int64_t)key, 0);
}

/* Whether a send would pass the address check: 0 for a stale address, a
   stopped box, or a tracked key not marked live. A snapshot, protected against
   a concurrent close as a send is. A key cleared after this read can still
   have a send in flight or queued. */
int32_t mail_live(uint64_t to, uint64_t key) {
    uint32_t i = (uint32_t)to;
    if (i >= MAIL_MAX_BOXES) return 0;
    ADD64(&mail_table[i].senders, 1);
    mail_box *b = LOAD32_SEQ(&mail_table[i].gen) == (uint32_t)(to >> 32) ? mail_table[i].box : NULL;
    int32_t live = b && !LOAD32_SEQ(&b->stopped) && mail_key_live(b, key);
    ADD64(&mail_table[i].senders, -1);
    return live;
}

/* Copies data, with key and tag, into the box of to, at once: SENT, FULL for
   no free slot, TOO_LONG for data longer than a slot, or STALE for a box
   closed, reopened, or a tracked key not marked live. */
int32_t mail_send(uint64_t to, uint64_t key, int32_t tag, mail_bytes data) {
    uint32_t i = (uint32_t)to;
    if (i >= MAIL_MAX_BOXES) return MAIL_STALE;
    ADD64(&mail_table[i].senders, 1);
    int32_t r = MAIL_STALE;
    mail_box *b = LOAD32_SEQ(&mail_table[i].gen) == (uint32_t)(to >> 32) ? mail_table[i].box : NULL;
    if (b && !LOAD32_SEQ(&b->stopped) && mail_key_live(b, key)) {
        r = data.len > (int64_t)b->size ? MAIL_TOO_LONG : MAIL_FULL;
        if (r == MAIL_FULL) {
            uint32_t pos = LOAD32_RELAXED(&b->enq);
            mail_slot *s;
            for (;;) {
                s = mail_at(b, pos);
                int32_t dif = (int32_t)(LOAD32_ACQUIRE(&s->seq) - pos);
                if (dif == 0) {
                    if (CAS32_RELAXED(&b->enq, &pos, pos + 1)) break;
                } else if (dif < 0) {
                    s = NULL;
                    break;
                } else {
                    pos = LOAD32_RELAXED(&b->enq);
                }
            }
            if (s) {
                s->key = key;
                s->tag = tag;
                s->len = (uint32_t)data.len;
                if (data.len) memcpy(s + 1, data.data, (size_t)data.len);
                STORE32_RELEASE(&s->seq, pos + 1);
                if (ADD64(&b->pending, 1) == 0) net_waker_wake(b->waker);
                r = MAIL_SENT;
            }
        }
    }
    ADD64(&mail_table[i].senders, -1);
    return r;
}

/* Stops the box of to, from any thread: sends from then on return STALE, and
   its owner is woken. A flag, not a message, so a full box can't refuse it.
   Protected against a concurrent close as a send is. */
void mail_stop(uint64_t to) {
    uint32_t i = (uint32_t)to;
    if (i >= MAIL_MAX_BOXES) return;
    ADD64(&mail_table[i].senders, 1);
    mail_box *b = LOAD32_SEQ(&mail_table[i].gen) == (uint32_t)(to >> 32) ? mail_table[i].box : NULL;
    if (b && !LOAD32_SEQ(&b->stopped)) {
        STORE32_SEQ(&b->stopped, 1);
        net_waker_wake(b->waker);
    }
    ADD64(&mail_table[i].senders, -1);
}

/* For the owner: 1 once the box is stopped and holds nothing, so that a lane
   ends with every message sent before the stop taken. A send that read the
   flag before the stop raised the senders count first (seq_cst both), so
   once the owner has read the flag set, that send is either still counted or
   already pending. The count also holds every other call in flight on the
   table's entry, mail_live, mail_slot_size, mail_queued, and sends that
   return STALE, so the owner waits it out here, yielding, rather than
   return 0 to a lane that would only call again at once; then pending,
   read after the count reaches 0, holds every send from before the stop. */
int32_t mail_stopped(uint64_t key) {
    mail_box *b = mail_own(key);
    if (!b) return 1;
    uint32_t i = (uint32_t)key;
    if (!LOAD32_SEQ(&b->stopped) || LOAD64_SEQ(&b->pending) != 0) return 0;
    while (LOAD64_SEQ(&mail_table[i].senders) != 0) YIELD();
    return LOAD64_SEQ(&b->pending) == 0;
}

/* The messages the box of key has counted and not yet settled: one load. */
int64_t mail_pending(uint64_t key) {
    mail_box *b = mail_own(key);
    return b ? LOAD64_ACQUIRE(&b->pending) : 0;
}

/* The messages the box of to holds, for any thread, or -1 for a stale
   address or a stopped box. A snapshot, protected against a close as a
   send is: a sender picks the least busy of several boxes by it. */
int64_t mail_queued(uint64_t to, uint64_t key) {
    uint32_t i = (uint32_t)to;
    if (i >= MAIL_MAX_BOXES) return -1;
    ADD64(&mail_table[i].senders, 1);
    mail_box *b = LOAD32_SEQ(&mail_table[i].gen) == (uint32_t)(to >> 32) ? mail_table[i].box : NULL;
    int64_t n = b && !LOAD32_SEQ(&b->stopped) && mail_key_live(b, key) ? LOAD64_ACQUIRE(&b->pending) : -1;
    ADD64(&mail_table[i].senders, -1);
    return n;
}

/* The box's slot size, for the buffer mail_take_one copies into. */
int32_t mail_size(uint64_t key) {
    mail_box *b = mail_own(key);
    return b ? (int32_t)b->size : 0;
}

/* The slot size for any thread, or -1 for a stale address or a stopped box. It
   checks the box, stop flag, and key as mail_send does, holding off a close
   while it reads. */
int32_t mail_slot_size(uint64_t to, uint64_t key) {
    uint32_t i = (uint32_t)to;
    if (i >= MAIL_MAX_BOXES) return -1;
    ADD64(&mail_table[i].senders, 1);
    mail_box *b = LOAD32_SEQ(&mail_table[i].gen) == (uint32_t)(to >> 32) ? mail_table[i].box : NULL;
    int32_t size = b && !LOAD32_SEQ(&b->stopped) && mail_key_live(b, key) ? (int32_t)b->size : -1;
    ADD64(&mail_table[i].senders, -1);
    return size;
}

/* Takes the box's next message: writes its bytes into out[..n], its key to
   head[0], and its tag to head[1], and returns n, or -1 when no message is
   there. out holds at least the box's slot size; head 2. */
int64_t mail_take_one(uint64_t key, mail_bytes out, mail_i64s head) {
    mail_box *b = mail_own(key);
    if (!b || head.len < 2) return -1;
    mail_slot *s = mail_at(b, b->deq);
    if ((int32_t)(LOAD32_ACQUIRE(&s->seq) - (b->deq + 1)) < 0) return -1;
    int64_t n = s->len;
    if (n > out.len) n = out.len;
    if (n) memcpy(out.data, s + 1, (size_t)n);
    head.data[0] = (int64_t)s->key;
    head.data[1] = s->tag;
    STORE32_RELEASE(&s->seq, b->deq + b->mask + 1);
    b->deq++;
    return n;
}

/* Tells the box its owner took n messages since the last call. Returns
   whether more are counted, which the owner takes before it waits. */
int32_t mail_settle(uint64_t key, int64_t n) {
    mail_box *b = mail_own(key);
    if (!b) return 0;
    if (n == 0) return LOAD64_ACQUIRE(&b->pending) > 0;
    return ADD64(&b->pending, -n) - n > 0;
}

/* For a box with a waker of its own: waits up to ms (-1: no limit) for a
   message. Spins on the count for a few microseconds first, then sleeps in
   the kernel. A wake can find nothing pending, when the spin or an earlier
   take got its message first and the wake stayed reported; the wait then goes
   on for the rest of ms. Returns 1 when a message is pending, 0 at the time
   limit or once the box is stopped. */
int32_t mail_wait(uint64_t key, int32_t ms) {
    mail_box *b = mail_own(key);
    if (!b) return -MAIL_EINVAL;
    for (int k = 0; k < 2000; k++) {
        if (LOAD64_ACQUIRE(&b->pending) > 0) return 1;
        if (LOAD32_SEQ(&b->stopped)) return 0;
        PAUSE();
    }
    int64_t until = ms >= 0 ? net_clock_ms() + ms : 0;
    for (;;) {
        if (LOAD64_ACQUIRE(&b->pending) > 0) return 1;
        if (LOAD32_SEQ(&b->stopped)) return 0;
        int32_t left = ms;
        if (ms >= 0) {
            int64_t now = net_clock_ms();
            if (now >= until && ms > 0) return 0;
            left = (int32_t)(until > now ? until - now : 0);
        }
        int32_t r = net_waker_wait(b->waker, left);
        if (r < 0) return r;
        if (r == 0) return LOAD64_ACQUIRE(&b->pending) > 0;
    }
}

/* The wakers of the loops running, which net_stop wakes so that a stop takes
   effect at once rather than at a loop's next timeout. net_stop may run in a
   signal handler, so the list is a fixed array changed and read with atomics
   only, and an unwatch waits out any wake in flight before the loop frees
   its waker. */
#define MAIL_MAX_WATCHED 1024
static mail_a64 mail_watched[MAIL_MAX_WATCHED];
static mail_a64 mail_waking;

/* Adds waker w to the list; -EMFILE when the list is full, and then a stop
   reaches the loop at its next timeout. */
int32_t net_stop_watch(int64_t w) {
    for (int i = 0; i < MAIL_MAX_WATCHED; i++)
        if (CAS64(&mail_watched[i], 0, w)) return 0;
    return -MAIL_EMFILE;
}

/* Takes w off the list, once no wake of it is in flight. */
void net_stop_unwatch(int64_t w) {
    for (int i = 0; i < MAIL_MAX_WATCHED; i++)
        if (LOAD64_SEQ(&mail_watched[i]) == w) STORE64_SEQ(&mail_watched[i], 0);
    while (LOAD64_SEQ(&mail_waking) != 0) YIELD();
}

/* Wakes every waker on the list: each platform's net_stop calls it. */
void net_stop_wake_all(void) {
    ADD64(&mail_waking, 1);
    for (int i = 0; i < MAIL_MAX_WATCHED; i++) {
        int64_t w = LOAD64_SEQ(&mail_watched[i]);
        if (w) net_waker_wake(w);
    }
    ADD64(&mail_waking, -1);
}
