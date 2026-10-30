/* ring.goose's calls emulated over the shim's own readiness calls (net_epoll_*,
   net_accept, net_recv, net_send, net_close), for where there's no io_uring.
   On Linux, shim/uring.c falls back to it when io_uring_setup fails, as in a
   container whose seccomp profile blocks io_uring, and its functions are named
   urp_*. On macOS, built with RING_EPOLL_ONLY, it is the ring, named ur_*,
   over shim/kqueue.c's epoll calls.

   A multishot accept accepts until the listener's backlog is empty, and a
   multishot receive reads into the provided buffers until the socket is
   empty, both again at each edge-triggered event. On macOS the listener is
   level-triggered and net_accept declines past the worker's share
   (shim/kqueue.c), so the listener is watched only while an accept goes on.
   A send's bytes are copied and sent in the next ur_wait, and what the
   socket doesn't take waits for its writable edge, which is watched only
   then: kqueue reports EV_CLEAR's write filter as each ACK frees buffer
   space. Completions that don't fit in ur_wait's out wait in a queue for the
   next call. Every call returns the same Linux errno values as the rest of
   the shim. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef RING_EPOLL_ONLY
#define RP(name) ur_##name
#else
#define RP(name) urp_##name
#endif

/* Linux's errno values, which the net_* calls return on every platform, and
   src's ring.goose and sys.goose name. */
#define RP_EINTR 4
#define RP_EAGAIN 11
#define RP_ENOMEM 12
#define RP_ENOSYS 38
#define RP_ECONNABORTED 103
#define RP_ENOBUFS 105
#define RP_ECANCELED 125

/* sys.goose's flags, epoll bits, and epoll_ctl op. */
#define RP_NONBLOCK 1
#define RP_IN 0x001u
#define RP_OUT 0x004u
#define RP_ERR 0x008u
#define RP_HUP 0x010u
#define RP_RDHUP 0x2000u
#define RP_ET 0x80000000u
#define RP_CTL_ADD 1
#define RP_CTL_DEL 2
#define RP_CTL_MOD 3

/* The most listeners a ring accepts on, ring.goose's ring_listeners. */
#define RP_LISTENERS 4

/* Listener k's epoll tag, and the waker's. A connection's is its fd. */
#define RP_LISTENER(k) (UINT64_MAX - (uint64_t)(k))
#define RP_WAKER (UINT64_MAX - RP_LISTENERS)

/* The layouts shared with Goose, packed as Goose packs them (spec C.2): a
   u8[:], http::PollEvent, http::Completion, and slices of the last two. */
#pragma pack(push, 1)
typedef struct { uint8_t *data; int64_t len; } rp_bytes;
typedef struct { uint32_t events; uint64_t tag; } rp_event;
typedef struct { uint64_t tag; int32_t res, buf; uint8_t more, send; } rp_completion;
typedef struct { rp_event *data; int64_t len; } rp_events;
typedef struct { rp_completion *data; int64_t len; } rp_completions;
#pragma pack(pop)
_Static_assert(sizeof(rp_bytes) == sizeof(void *) + 8 && sizeof(rp_event) == 12 &&
               sizeof(rp_completion) == 18 && sizeof(rp_events) == sizeof(void *) + 8 &&
               sizeof(rp_completions) == sizeof(void *) + 8,
               "not packed as Goose packs them");

/* From shim/net.c or shim/kqueue.c. */
int32_t net_accept(int32_t fd, int32_t flags);
int64_t net_recv(int32_t fd, rp_bytes buf);
int64_t net_send(int32_t fd, rp_bytes data);
int32_t net_close(int32_t fd);
int32_t net_epoll_create(void);
int32_t net_epoll_ctl(int32_t ep, int32_t op, int32_t fd, uint32_t events, uint64_t tag);
int32_t net_epoll_wait(int32_t ep, rp_events out, int32_t timeout_ms);
int64_t net_waker(int32_t ep, uint64_t tag);
int64_t net_sendfile(int32_t s, int64_t fd, int64_t off, int64_t len);
void net_file_close(int64_t fd);

/* From shim/shared.c: a gathered send's claim on its bytes. */
struct shared_claim *shared_claim_take(const uint8_t *data, int64_t len);
int64_t shared_claim_len(const struct shared_claim *c);
int64_t shared_claim_send(int32_t fd, const struct shared_claim *c, int64_t off);
void shared_claim_free(struct shared_claim *c);

/* A send's bytes, owned by the ring until they're sent, or a file's send
   (RP(send_file)), or a gathered one's (RP(send_shared)), which have none. */
struct rp_send {
    struct rp_send *next;
    uint64_t tag;
    uint32_t len, off;
    uint32_t cap;           /* data's size */
    int64_t file;           /* -1 for a send of data */
    int64_t foff, fleft;
    struct shared_claim *claim;     /* a gathered send's bytes, or NULL */
    unsigned char data[];
};

/* sendfile's most per call, so a completion's count fits its res. */
#define RP_FILE_PIECE (1 << 30)
#define RP_EIO 5

/* Sent records go back to free lists: those of up to RP_SMALL bytes, in
   RP_CLASSES powers of two from RP_MIN, always, and bigger ones, sized in
   RP_BIG steps, while the list holds under RP_KEEP bytes. Freed to malloc, a
   big record goes back to the kernel, and the next one faults its pages in
   again, as in shim/uring.c. */
#define RP_MIN 256
#define RP_CLASSES 6
#define RP_SMALL (RP_MIN << (RP_CLASSES - 1))
#define RP_BIG 65536
#define RP_KEEP (4u << 20)

/* What the ring knows of a socket, indexed by its fd. */
struct rp_fd {
    uint64_t tag;                   /* its receive's */
    struct rp_send *sends, *last;   /* queued in order, the first maybe partly sent */
    uint8_t added;                  /* registered with the epoll instance */
    uint8_t reading;                /* its multishot receive goes on */
    uint8_t readable;               /* may hold bytes: read until EAGAIN */
    uint8_t writable;               /* may take bytes: send until EAGAIN */
    uint8_t watch_out;              /* OUT is registered: set while a send waits */
    uint8_t queued;                 /* on the ready list */
};

/* A listener the ring accepts on. */
struct rp_listener {
    int32_t fd;                     /* -1 while unused */
    uint64_t tag;                   /* its accept's */
    uint8_t added, accepting, acceptable;
};

struct rp {
    int32_t ep;
    unsigned char *bufs;
    uint32_t nbufs, buflen;
    int32_t *free;                  /* the ids of free buffers, a stack */
    uint32_t nfree;
    struct rp_fd *fds;
    uint32_t nfds;
    int32_t *ready;                 /* fds with work for the next ur_wait */
    uint32_t nready, capready;
    rp_completion *done;            /* completions that didn't fit in out */
    uint32_t headdone, ndone, capdone;
    struct rp_listener l[RP_LISTENERS];
    uint64_t wtag;                  /* the waker's completions' (ur_waker) */
    int32_t err;                    /* -ENOMEM once the bookkeeping ran out, for ur_wait */
    struct rp_send *small[RP_CLASSES], *big;  /* sent records, to reuse */
    uint32_t kept;                  /* the bytes of big's records */
};

static struct rp_send *rp_send_alloc(struct rp *u, int64_t len) {
    struct rp_send *s = NULL;
    int k = 0;
    if (len <= RP_SMALL) {
        while ((RP_MIN << k) < len) k++;
        if (u->small[k]) {
            s = u->small[k];
            u->small[k] = s->next;
        }
    } else {
        for (struct rp_send **p = &u->big; *p; p = &(*p)->next) {
            if ((*p)->cap >= len) {
                s = *p;
                *p = s->next;
                u->kept -= s->cap;
                break;
            }
        }
    }
    if (!s) {
        size_t cap = len <= RP_SMALL ? (size_t)RP_MIN << k : ((size_t)len + RP_BIG - 1) / RP_BIG * RP_BIG;
        s = malloc(sizeof *s + cap);
        if (!s) return NULL;
        s->cap = (uint32_t)cap;
    }
    return s;
}

static void rp_send_free(struct rp *u, struct rp_send *s) {
    if (s->file >= 0) net_file_close(s->file);
    s->file = -1;
    if (s->claim) shared_claim_free(s->claim);
    s->claim = NULL;
    if (s->cap <= RP_SMALL) {
        int k = 0;
        while ((RP_MIN << k) < s->cap) k++;
        s->next = u->small[k];
        u->small[k] = s;
    } else if (u->kept + s->cap <= RP_KEEP) {
        s->next = u->big;
        u->big = s;
        u->kept += s->cap;
    } else {
        free(s);
    }
}

/* fd's record, made on its first request, or NULL when out of memory. */
static struct rp_fd *rp_fd_of(struct rp *u, int32_t fd) {
    if ((uint32_t)fd >= u->nfds) {
        uint32_t n = u->nfds ? u->nfds : 1024;
        while (n <= (uint32_t)fd) n *= 2;
        struct rp_fd *f = realloc(u->fds, n * sizeof *f);
        if (!f) {
            u->err = -RP_ENOMEM;
            return NULL;
        }
        memset(f + u->nfds, 0, (n - u->nfds) * sizeof *f);
        u->fds = f;
        u->nfds = n;
    }
    return &u->fds[fd];
}

static void rp_queue(struct rp *u, int32_t fd) {
    struct rp_fd *f = &u->fds[fd];
    if (f->queued) return;
    if (u->nready == u->capready) {
        uint32_t n = u->capready ? u->capready * 2 : 1024;
        int32_t *r = realloc(u->ready, n * sizeof *r);
        if (!r) {
            u->err = -RP_ENOMEM;
            return;
        }
        u->ready = r;
        u->capready = n;
    }
    u->ready[u->nready++] = fd;
    f->queued = 1;
}

/* Adds a completion to out, or to the queue behind the ones already
   waiting, which keeps a connection's completions in order. */
static void rp_emit(struct rp *u, rp_completions out, int32_t *n, uint64_t tag, int32_t res,
                    int32_t buf, int more, int send) {
    rp_completion c = { tag, res, buf, (uint8_t)more, (uint8_t)send };
    if (u->headdone == u->ndone && *n < out.len) {
        out.data[(*n)++] = c;
        return;
    }
    if (u->ndone == u->capdone) {
        if (u->headdone > 0) {
            memmove(u->done, u->done + u->headdone, (u->ndone - u->headdone) * sizeof c);
            u->ndone -= u->headdone;
            u->headdone = 0;
        } else {
            uint32_t m = u->capdone ? u->capdone * 2 : 256;
            rp_completion *d = realloc(u->done, m * sizeof c);
            if (!d) {
                u->err = -RP_ENOMEM;
                return;
            }
            u->done = d;
            u->capdone = m;
        }
    }
    u->done[u->ndone++] = c;
}

/* The completions of calls that return nothing, for the next ur_wait. */
static void rp_later(struct rp *u, uint64_t tag, int32_t res) {
    int32_t n = 0;
    rp_completions none = { NULL, 0 };
    rp_emit(u, none, &n, tag, res, -1, 0, 0);
}

static int32_t rp_add(struct rp *u, int32_t fd, struct rp_fd *f) {
    if (f->added) return 0;
    int32_t r = net_epoll_ctl(u->ep, RP_CTL_ADD, fd, RP_IN | RP_RDHUP | RP_ET, (uint64_t)fd);
    if (r < 0) return r;
    f->added = 1;
    f->writable = 1;
    return 0;
}

int64_t RP(create)(int32_t entries, int32_t nbufs, int32_t buflen, int32_t flags) {
    (void)entries, (void)flags;
    struct rp *u = calloc(1, sizeof *u);
    if (!u) return -RP_ENOMEM;
    u->ep = net_epoll_create();
    if (u->ep < 0) {
        int32_t r = u->ep;
        free(u);
        return r;
    }
    u->nbufs = (uint32_t)nbufs;
    u->buflen = (uint32_t)buflen;
    u->bufs = malloc((size_t)nbufs * (size_t)buflen);
    u->free = malloc((size_t)nbufs * sizeof *u->free);
    if (!u->bufs || !u->free) {
        net_close(u->ep);
        free(u->bufs);
        free(u->free);
        free(u);
        return -RP_ENOMEM;
    }
    for (int32_t i = 0; i < nbufs; i++) u->free[i] = nbufs - 1 - i;
    u->nfree = (uint32_t)nbufs;
    for (int k = 0; k < RP_LISTENERS; k++) u->l[k].fd = -1;
    return (int64_t)(intptr_t)u;
}

int32_t RP(listeners)(void) { return RP_LISTENERS; }

/* Accepts on the listener fd at each of its events, until a cancel or an
   error, starting in the next ur_wait: the backlog may hold clients already.
   Past RP_LISTENERS listeners, it completes with ENOSYS. */
void RP(accept)(int64_t h, int32_t fd, uint64_t tag) {
    struct rp *u = (struct rp *)(intptr_t)h;
    int k = 0;
    while (k < RP_LISTENERS && u->l[k].fd != fd) k++;
    if (k == RP_LISTENERS) {
        k = 0;
        while (k < RP_LISTENERS && (u->l[k].added || u->l[k].accepting)) k++;
        if (k == RP_LISTENERS) {
            rp_later(u, tag, -RP_ENOSYS);
            return;
        }
    }
    struct rp_listener *l = &u->l[k];
    if (!l->added || l->fd != fd) {
        int32_t r = net_epoll_ctl(u->ep, RP_CTL_ADD, fd, RP_IN | RP_ET, RP_LISTENER(k));
        if (r < 0) {
            rp_later(u, tag, r);
            return;
        }
        l->added = 1;
    }
    l->fd = fd;
    l->tag = tag;
    l->accepting = 1;
    l->acceptable = 1;
}

/* Reads fd into the provided buffers at each of its events, until a cancel,
   the end of the stream, or no buffer left, starting in the next ur_wait:
   bytes may be waiting already. */
void RP(recv)(int64_t h, int32_t fd, uint64_t tag) {
    struct rp *u = (struct rp *)(intptr_t)h;
    struct rp_fd *f = rp_fd_of(u, fd);
    if (!f) return;
    int32_t r = rp_add(u, fd, f);
    if (r < 0) {
        rp_later(u, tag, r);
        return;
    }
    f->tag = tag;
    f->reading = 1;
    f->readable = 1;
    rp_queue(u, fd);
}

/* Copies data, to send it in the next ur_wait after any sends queued before
   it on fd. */
int32_t RP(send)(int64_t h, int32_t fd, uint64_t tag, rp_bytes data) {
    struct rp *u = (struct rp *)(intptr_t)h;
    struct rp_fd *f = rp_fd_of(u, fd);
    if (!f) return -RP_ENOMEM;
    int32_t r = rp_add(u, fd, f);
    if (r < 0) return r;
    struct rp_send *s = rp_send_alloc(u, data.len);
    if (!s) return -RP_ENOMEM;
    s->next = NULL;
    s->tag = tag;
    s->len = (uint32_t)data.len;
    s->off = 0;
    s->file = -1;
    s->claim = NULL;
    memcpy(s->data, data.data, (size_t)data.len);
    if (f->last) f->last->next = s;
    else f->sends = s;
    f->last = s;
    rp_queue(u, fd);
    return 0;
}

/* Sends len bytes of file from off with sendfile, in the next ur_wait after
   any sends queued before it on fd, with a completion for each call that
   sends some. The ring owns file from here on, also when this fails. */
int32_t RP(send_file)(int64_t h, int32_t fd, uint64_t tag, int64_t file, int64_t off, int64_t len) {
    struct rp *u = (struct rp *)(intptr_t)h;
    struct rp_fd *f = rp_fd_of(u, fd);
    int32_t r = f ? rp_add(u, fd, f) : -RP_ENOMEM;
    struct rp_send *s = r < 0 ? NULL : rp_send_alloc(u, 0);
    if (!s) {
        net_file_close(file);
        return r < 0 ? r : -RP_ENOMEM;
    }
    s->next = NULL;
    s->tag = tag;
    s->len = s->off = 0;
    s->file = file;
    s->foff = off;
    s->fleft = len;
    s->claim = NULL;
    if (f->last) f->last->next = s;
    else f->sends = s;
    f->last = s;
    rp_queue(u, fd);
    return 0;
}

/* Sends data and the ranges shared_defer deferred into it, with sendmsg, in
   the next ur_wait after any sends queued before it on fd. Copies only data,
   and holds the ranges' references (shim/shared.c) until the send ends or
   fd closes. */
int32_t RP(send_shared)(int64_t h, int32_t fd, uint64_t tag, rp_bytes data) {
    struct rp *u = (struct rp *)(intptr_t)h;
    struct shared_claim *c = shared_claim_take(data.data, data.len);
    if (!c) return -RP_ENOMEM;
    struct rp_fd *f = rp_fd_of(u, fd);
    int32_t r = f ? rp_add(u, fd, f) : -RP_ENOMEM;
    struct rp_send *s = r < 0 ? NULL : rp_send_alloc(u, 0);
    if (!s) {
        shared_claim_free(c);
        return r < 0 ? r : -RP_ENOMEM;
    }
    s->next = NULL;
    s->tag = tag;
    s->len = (uint32_t)shared_claim_len(c);
    s->off = 0;
    s->file = -1;
    s->claim = c;
    if (f->last) f->last->next = s;
    else f->sends = s;
    f->last = s;
    rp_queue(u, fd);
    return 0;
}

/* Ends the accept: a level-triggered listener left watched would end every
   wait at once while clients wait in the backlog. */
static void rp_stop_accept(struct rp *u, struct rp_listener *l) {
    l->accepting = 0;
    if (l->added && net_epoll_ctl(u->ep, RP_CTL_DEL, l->fd, 0, 0) >= 0) l->added = 0;
}

/* Ends the accept or the receive started with tag, with an ECANCELED
   completion. */
void RP(cancel)(int64_t h, uint64_t tag) {
    struct rp *u = (struct rp *)(intptr_t)h;
    for (int k = 0; k < RP_LISTENERS; k++) {
        if (u->l[k].accepting && u->l[k].tag == tag) {
            rp_stop_accept(u, &u->l[k]);
            rp_later(u, tag, -RP_ECANCELED);
            return;
        }
    }
    for (uint32_t fd = 0; fd < u->nfds; fd++) {
        struct rp_fd *f = &u->fds[fd];
        if (f->reading && f->tag == tag) {
            f->reading = 0;
            rp_later(u, tag, -RP_ECANCELED);
            return;
        }
    }
}

/* Closes fd. Its sends not yet made are dropped, with no completion. Its
   receive ends with it, so recv isn't needed. */
void RP(close)(int64_t h, int32_t fd, uint64_t recv) {
    struct rp *u = (struct rp *)(intptr_t)h;
    if ((uint32_t)fd < u->nfds) {
        struct rp_fd *f = &u->fds[fd];
        for (struct rp_send *s = f->sends, *next; s; s = next) {
            next = s->next;
            rp_send_free(u, s);
        }
        uint8_t queued = f->queued;
        memset(f, 0, sizeof *f);
        f->queued = queued;
    }
    net_close(fd);
}

/* A waker (shim/mail.c) on the ring: each wake ends the ring's wait with a
   completion of tag, res 0, and no buffer. It's closed with net_waker_close
   after the ring is destroyed, which deletes nothing still registered. */
int64_t RP(waker)(int64_t h, uint64_t tag) {
    struct rp *u = (struct rp *)(intptr_t)h;
    u->wtag = tag;
    return net_waker(u->ep, RP_WAKER);
}

#ifdef RING_EPOLL_ONLY
/* There's no io_uring to probe for: the ring is always this emulation. */
int32_t ur_probe(void) { return -RP_ENOSYS; }

/* Gathers sends (RP(send_shared)): ring.goose's ring_gathers. */
uint8_t ur_gathers(int64_t h) { return 1; }

/* net_arm arms no socket on the emulation: shim/kqueue.c's stays ENOSYS on
   it. */
void ur_bind(int64_t h, uint64_t tag) {}
uint64_t ur_socket(int64_t h, int32_t k) { return 0; }
void ur_disarm(int64_t h, uint64_t key, uint64_t mask) {}
#endif

void RP(take)(int64_t h, int32_t buf, int64_t off, rp_bytes dst) {
    struct rp *u = (struct rp *)(intptr_t)h;
    memcpy(dst.data, u->bufs + (size_t)buf * u->buflen + off, (size_t)dst.len);
}

void RP(give)(int64_t h, int32_t buf) {
    struct rp *u = (struct rp *)(intptr_t)h;
    u->free[u->nfree++] = buf;
}

/* Accepts, sends, and reads what the listener and the queued sockets allow,
   and makes their completions. */
static void rp_work(struct rp *u, rp_completions out, int32_t *n) {
    for (int k = 0; k < RP_LISTENERS; k++) {
        struct rp_listener *l = &u->l[k];
        while (l->accepting && l->acceptable) {
            int32_t fd = net_accept(l->fd, RP_NONBLOCK);
            if (fd == -RP_EAGAIN) {
                l->acceptable = 0;
                break;
            }
            if (fd == -RP_EINTR || fd == -RP_ECONNABORTED) continue;
            /* EMFILE or ENFILE ends the accept, as io_uring's does, and
               leaves the backlog to the accept queued after it. */
            if (fd < 0) rp_stop_accept(u, l);
            rp_emit(u, out, n, l->tag, fd, -1, fd >= 0, 0);
        }
    }
    for (uint32_t i = 0; i < u->nready; i++) {
        int32_t fd = u->ready[i];
        struct rp_fd *f = &u->fds[fd];
        f->queued = 0;
        while (f->sends && f->writable) {
            struct rp_send *s = f->sends;
            if (s->file >= 0) {
                int64_t want = s->fleft < RP_FILE_PIECE ? s->fleft : RP_FILE_PIECE;
                int64_t r = net_sendfile(fd, s->file, s->foff, want);
                if (r == -RP_EAGAIN) {
                    f->writable = 0;
                    break;
                }
                if (r == -RP_EINTR) continue;
                if (r > 0) {
                    s->foff += r;
                    s->fleft -= r;
                }
                int more = r > 0 && s->fleft > 0;
                /* 0 is the file's end, short of what's left. */
                rp_emit(u, out, n, s->tag, r > 0 ? (int32_t)r : r == 0 ? -RP_EIO : (int32_t)r, -1, more, 1);
                if (more) continue;
                f->sends = s->next;
                if (!f->sends) f->last = NULL;
                rp_send_free(u, s);
                continue;
            }
            rp_bytes rest = { s->data + s->off, (int64_t)(s->len - s->off) };
            int64_t r = rest.len <= 0 ? 0 : s->claim ? shared_claim_send(fd, s->claim, s->off) : net_send(fd, rest);
            if (r == -RP_EAGAIN) {
                f->writable = 0;
                break;
            }
            if (r == -RP_EINTR) continue;
            if (r >= 0) s->off += (uint32_t)r;
            if (r >= 0 && s->off < s->len) continue;
            rp_emit(u, out, n, s->tag, r < 0 ? (int32_t)r : (int32_t)s->len, -1, 0, 1);
            f->sends = s->next;
            if (!f->sends) f->last = NULL;
            rp_send_free(u, s);
        }
        uint8_t want = f->sends != NULL;
        if (f->added && want != f->watch_out) {
            uint32_t ev = RP_IN | RP_RDHUP | RP_ET | (want ? RP_OUT : 0);
            int32_t r = net_epoll_ctl(u->ep, RP_CTL_MOD, fd, ev, (uint64_t)fd);
            if (r >= 0) {
                f->watch_out = want;
            } else if (want) {
                /* The send would wait for an edge nobody watches: fail it. */
                struct rp_send *s = f->sends;
                rp_emit(u, out, n, s->tag, r, -1, 0, 1);
                f->sends = s->next;
                if (!f->sends) f->last = NULL;
                rp_send_free(u, s);
            }
        }
        while (f->reading && f->readable) {
            if (u->nfree == 0) {
                /* As io_uring ends a multishot receive that finds no buffer.
                   The socket stays readable for the receive queued next. */
                f->reading = 0;
                rp_emit(u, out, n, f->tag, -RP_ENOBUFS, -1, 0, 0);
                break;
            }
            int32_t b = u->free[--u->nfree];
            rp_bytes into = { u->bufs + (size_t)b * u->buflen, u->buflen };
            int64_t r = net_recv(fd, into);
            if (r == -RP_EAGAIN || r == -RP_EINTR) u->free[u->nfree++] = b;
            if (r == -RP_EAGAIN) {
                f->readable = 0;
                break;
            }
            if (r == -RP_EINTR) continue;
            if (r <= 0) {
                /* The end of the stream, or an error. */
                u->free[u->nfree++] = b;
                f->reading = 0;
                f->readable = 0;
                rp_emit(u, out, n, f->tag, (int32_t)r, -1, 0, 0);
                break;
            }
            rp_emit(u, out, n, f->tag, (int32_t)r, b, 1, 0);
        }
    }
    u->nready = 0;
}

/* Makes what's queued, collects events, waiting up to timeout_ms (-1: no
   limit) only if that made no completion, and writes up to out.len
   completions into out. Events are collected on every call: a few busy
   connections that always make completions would otherwise keep the ones
   waiting for an edge from ever seeing it. */
int32_t RP(wait)(int64_t h, rp_completions out, int32_t timeout_ms) {
    struct rp *u = (struct rp *)(intptr_t)h;
    if (u->err) return u->err;
    int32_t n = 0;
    while (n < out.len && u->headdone < u->ndone) out.data[n++] = u->done[u->headdone++];
    if (u->headdone == u->ndone) u->headdone = u->ndone = 0;
    rp_work(u, out, &n);
    rp_event evs[256];
    rp_events in = { evs, 256 };
    int32_t got = net_epoll_wait(u->ep, in, n > 0 ? 0 : timeout_ms);
    if (got < 0) return got;
    for (int32_t i = 0; i < got; i++) {
        if (evs[i].tag > RP_WAKER) {
            u->l[UINT64_MAX - evs[i].tag].acceptable = 1;
            continue;
        }
        if (evs[i].tag == RP_WAKER) {
            rp_emit(u, out, &n, u->wtag, 0, -1, 1, 0);
            continue;
        }
        int32_t fd = (int32_t)evs[i].tag;
        struct rp_fd *f = &u->fds[fd];
        if (!f->added) continue;
        if (evs[i].events & (RP_IN | RP_RDHUP | RP_HUP | RP_ERR)) f->readable = 1;
        if (evs[i].events & (RP_OUT | RP_HUP | RP_ERR)) f->writable = 1;
        rp_queue(u, fd);
    }
    rp_work(u, out, &n);
    return u->err ? u->err : n;
}

/* Tears the ring down, with the sends still queued on it. */
void RP(destroy)(int64_t h) {
    struct rp *u = (struct rp *)(intptr_t)h;
    for (uint32_t fd = 0; fd < u->nfds; fd++) {
        struct rp_send *s = u->fds[fd].sends;
        while (s) {
            struct rp_send *next = s->next;
            if (s->file >= 0) net_file_close(s->file);
            if (s->claim) shared_claim_free(s->claim);
            free(s);
            s = next;
        }
    }
    for (int k = 0; k < RP_CLASSES; k++) {
        while (u->small[k]) {
            struct rp_send *s = u->small[k];
            u->small[k] = s->next;
            free(s);
        }
    }
    while (u->big) {
        struct rp_send *s = u->big;
        u->big = s->next;
        free(s);
    }
    net_close(u->ep);
    free(u->bufs);
    free(u->free);
    free(u->fds);
    free(u->ready);
    free(u->done);
    free(u);
}
