/* The io_uring calls of the server's io_uring loop, for src/ring.goose, over
   liburing 2.14. liburing's helpers are static inline functions, which an
   extern fn can't bind, so these wrap the ones the loop uses. goose build
   compiles this beside the program (src/main_uring.build), so it spells out
   the layouts it shares with Goose, per spec C.2.

   Needs Linux 6.1: multishot accept (5.19), multishot receive into a provided
   buffer ring (6.0), and IORING_SETUP_DEFER_TASKRUN (6.1).

   The kernel writes a receive's bytes and reads a send's after the call that
   queued them returns, and spec §7.10 forbids C to keep a Goose argument past
   a call. So the ring owns every buffer the kernel touches: receives land in
   its provided buffers, which ur_take copies out of, ur_send copies the
   bytes it's given, ur_send_shared copies those and holds references to
   the shared blobs it sends from, and ur_send_file splices a file through
   a pipe of its own. A send of UR_INLINE bytes or more that finds nothing queued on its
   fd first goes out with send(2) inside the call, and only what the socket
   doesn't take is copied. A ring is a number to Goose, the address of its
   struct ur, and belongs to the thread that created it
   (IORING_SETUP_SINGLE_ISSUER).

   Where io_uring_setup fails, as under Docker's default seccomp profile, or
   when asked, a ring is shim/ring_epoll.c's emulation over epoll instead:
   its address with the low bit set, which a struct ur's never has, and each
   call here passes it on. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE         /* F_SETPIPE_SZ */
#endif
#include <errno.h>
#include <fcntl.h>
#include <liburing.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

_Static_assert(ENOBUFS == 105 && ECANCELED == 125, "errno values differ from src/ring.goose");

/* The layouts shared with Goose, packed as Goose packs them (spec C.2): a
   u8[:], passed by value, ring::Completion, and a slice of it. */
#pragma pack(push, 1)
typedef struct { uint8_t *data; int64_t len; } ur_bytes;
typedef struct {
    uint64_t tag;
    int32_t res, buf;
    uint8_t more, send;
} ur_completion;
typedef struct { ur_completion *data; int64_t len; } ur_completions;
#pragma pack(pop)
_Static_assert(sizeof(ur_bytes) == sizeof(void *) + 8 && sizeof(ur_completion) == 18 &&
               sizeof(ur_completions) == sizeof(void *) + 8,
               "not packed as Goose packs them");

/* A request's user_data: a Goose tag shifted left 2 (UR_TAGGED), a send
   record's address (UR_SEND), UR_QUIET for cancels and closes, whose
   completions nobody needs, or an armed socket's index shifted left 2
   (UR_ARMED). Tags fit in 62 bits. */
#define UR_TAGGED 0
#define UR_SEND 1
#define UR_QUIET 2
#define UR_ARMED 3

/* A socket net_arm armed on the ring (ur_arm): a one-shot poll for the key of
   the exchange that waits for it. A key takes 64 bits, so it stays here, and
   the poll's completion reaches Goose as the ring's socket tag with the
   record's index in buf, for ur_socket to turn into the key. A record
   disarmed before its completion is read is stale: its completion is
   dropped, and ur_socket gives 0. */
enum { UR_ARM_FREE, UR_ARM_POLLING, UR_ARM_REPORTED, UR_ARM_STALE };
struct ur_arm {
    uint64_t key;
    int32_t state;
    int32_t next;           /* the next free record, or -1 */
};

/* A send's bytes, owned by the ring until the send's last completion.
   Records of up to UR_SMALL bytes come in UR_CLASSES powers of two from
   UR_MIN, each with its own free list, so that a ring's records of small
   responses, one for each send in flight, pack into few pages. Bigger ones,
   sized in UR_BIG steps, go back to another while it holds under UR_KEEP
   bytes: freed to malloc, a record that size goes back to the kernel, and
   the next one faults its pages in again. */
#define UR_MIN 256
#define UR_CLASSES 6
#define UR_SMALL (UR_MIN << (UR_CLASSES - 1))
#define UR_BIG 65536
#define UR_KEEP (4u << 20)
/* Below this, a syscall per send costs more than the copy it saves: sent
   inline at every size, tier B's responses of 0.3-13 KB lost 6-10% of their
   rate, and at 64 KB nothing (task 021). */
#define UR_INLINE 65536
struct ur_send {
    struct ur_send *next;   /* behind it on its fd, or on a free list */
    uint64_t tag;
    int32_t fd;
    uint32_t gen;           /* fd's generation when the send was queued */
    uint32_t len, off;
    uint32_t pre;           /* bytes ur_send sent itself, before data */
    uint32_t cap;           /* data's size */
    /* A file's send (ur_send_file) has no data: it splices the file into
       its pipe, and the pipe into the socket, one step at a time. */
    int32_t file;           /* -1 for a send of data */
    int32_t err;            /* why it failed before it started, or 0 */
    struct ur_pipe *pipe;
    int64_t foff, fleft;    /* what's left of the file to put in the pipe */
    uint32_t piped;         /* bytes in the pipe, still to send */
    /* A gathered send (ur_send_shared) has its bytes in claim, and data
       holds its sendmsg's header and vector (ur_gather_of). */
    struct shared_claim *claim;
    unsigned char data[];
};

/* A gathered send's sendmsg: up to UR_IOV of its claim's runs at a time,
   in its record's data, which stays put until the send's last completion. */
#define UR_IOV 64
struct ur_gather {
    struct msghdr m;
    struct iovec v[UR_IOV];
};
static struct ur_gather *ur_gather_of(struct ur_send *s) {
    return (struct ur_gather *)(((uintptr_t)s->data + 15) & ~(uintptr_t)15);
}
#define UR_GATHER_CAP (sizeof(struct ur_gather) + 15)

/* A pipe, which a file's send holds while it lasts. Empty ones are kept for
   the next file. */
struct ur_pipe {
    struct ur_pipe *next;
    int32_t rd, wr;
    uint32_t cap;
};
#define UR_PIPES 64
#define UR_PIPE_SIZE (1 << 20)

/* Per fd, its sends in order, the first in flight, and the number of times
   this ring closed it. One send at a time keeps a connection's bytes in
   order. A send's rest, or the next send, goes out only while its fd's
   generation is the send's: once the ring closes fd, the next accept, on any
   ring, may reuse the number. */
struct ur_fd {
    struct ur_send *head, *last;
    uint32_t gen;
};

struct ur {
    struct io_uring ring;
    struct io_uring_buf_ring *br;
    unsigned char *bufs;
    uint32_t nbufs, buflen;
    int given;              /* buffers given back since the last ur_wait */
    struct ur_send *free[UR_CLASSES];
    struct ur_send *big;
    uint32_t kept;          /* the bytes of big's records */
    struct ur_fd *fds;
    uint32_t nfds;
    struct ur_pipe *pipes;  /* empty, to reuse */
    uint32_t npipes;
    /* Sends ur_send finished itself, for the next ur_wait to report. */
    ur_completion *sent;
    int32_t nsent, capsent;
    /* The waker (ur_waker), its eventfd, and its completions' tag. */
    int64_t waker;
    int32_t wfd;
    uint64_t wtag;
    /* The armed sockets' records, those in use below narms, how many are
       polling or reported, and their completions' tag (ur_bind). */
    struct ur_arm *arms;
    int32_t narms, caparms, freearm, live;
    uint64_t stag;
};

/* The ring net_arm arms sockets on: the calling thread's, once ur_bind binds
   it. */
static _Thread_local struct ur *ur_bound;

/* From shim/net.c. */
int64_t net_waker(int32_t ep, uint64_t tag);
int32_t net_waker_fd(int64_t w);
void net_waker_clear(int64_t w);
void net_loop_ring(int32_t (*arm)(int32_t fd, uint32_t events, uint64_t tag), void (*disarm)(uint64_t tag));

/* shim/ring_epoll.c, built with its functions named urp_*. */
int64_t urp_create(int32_t entries, int32_t nbufs, int32_t buflen, int32_t flags);
void urp_accept(int64_t h, int32_t fd, uint64_t tag);
void urp_recv(int64_t h, int32_t fd, uint64_t tag);
int32_t urp_send(int64_t h, int32_t fd, uint64_t tag, ur_bytes data);
int32_t urp_send_file(int64_t h, int32_t fd, uint64_t tag, int64_t file, int64_t off, int64_t len);
int32_t urp_send_shared(int64_t h, int32_t fd, uint64_t tag, ur_bytes data);
void urp_cancel(int64_t h, uint64_t tag);
void urp_close(int64_t h, int32_t fd, uint64_t recv);
void urp_take(int64_t h, int32_t buf, int64_t off, ur_bytes dst);
void urp_give(int64_t h, int32_t buf);
int32_t urp_wait(int64_t h, ur_completions out, int32_t timeout_ms);
void urp_destroy(int64_t h);
int64_t urp_waker(int64_t h, uint64_t tag);
int32_t urp_listeners(void);

/* From shim/shared.c: a gathered send's claim on its bytes. */
struct shared_claim *shared_claim_take(const uint8_t *data, int64_t len);
int64_t shared_claim_len(const struct shared_claim *c);
int32_t shared_claim_iov(const struct shared_claim *c, int64_t off, struct iovec *v, int32_t max);
void shared_claim_free(struct shared_claim *c);

/* ur_create's flags, ring.goose's RING_EMULATE and RING_REQUIRE. */
#define UR_EMULATE 1
#define UR_REQUIRE 2

/* Whether h is an emulated ring, and the emulation's own handle for it. */
#define UR_EMULATED(h) (((h) & 1) != 0)
#define UR_POLL(h) ((h) & ~(int64_t)1)

static int64_t ur_emulate(int32_t entries, int32_t nbufs, int32_t buflen) {
    int64_t h = urp_create(entries, nbufs, buflen, 0);
    return h < 0 ? h : h | 1;
}

/* Whether ur_create gets an io_uring ring here: 0, or the error that makes it
   fall back to the emulation. Sets up and tears down a small ring as
   ur_create sets up its own. */
int32_t ur_probe(void) {
    struct io_uring ring;
    struct io_uring_params p;
    memset(&p, 0, sizeof p);
    p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_SUBMIT_ALL;
    int r = io_uring_queue_init_params(2, &ring, &p);
    if (r < 0) return r;
    struct io_uring_buf_ring *br = io_uring_setup_buf_ring(&ring, 1, 0, 0, &r);
    if (br) io_uring_free_buf_ring(&ring, br, 1, 0);
    io_uring_queue_exit(&ring);
    return br ? 0 : r;
}

/* An io_uring ring takes any number of listeners, and the emulation it may
   fall back to takes this many. */
int32_t ur_listeners(void) { return urp_listeners(); }

/* An SQE, submitting what's queued first if the submission queue is full. */
static struct io_uring_sqe *ur_sqe(struct ur *u) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&u->ring);
    if (!sqe) {
        io_uring_submit(&u->ring);
        sqe = io_uring_get_sqe(&u->ring);
    }
    return sqe;
}

/* A ring of entries submission entries and four times as many completions,
   with nbufs provided buffers of buflen bytes in buffer group 0. nbufs must
   be a power of two. */
int64_t ur_create(int32_t entries, int32_t nbufs, int32_t buflen, int32_t flags) {
    if (flags & UR_EMULATE) return ur_emulate(entries, nbufs, buflen);
    struct ur *u = calloc(1, sizeof *u);
    if (!u) return -ENOMEM;
    struct io_uring_params p;
    memset(&p, 0, sizeof p);
    p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN |
              IORING_SETUP_SUBMIT_ALL | IORING_SETUP_CQSIZE;
    p.cq_entries = (unsigned)entries * 4;
    int r = io_uring_queue_init_params((unsigned)entries, &u->ring, &p);
    if (r < 0) {
        free(u);
        return flags & UR_REQUIRE ? r : ur_emulate(entries, nbufs, buflen);
    }
    u->nbufs = (uint32_t)nbufs;
    u->buflen = (uint32_t)buflen;
    u->bufs = aligned_alloc(4096, (size_t)nbufs * (size_t)buflen);
    if (!u->bufs) r = -ENOMEM;
    else u->br = io_uring_setup_buf_ring(&u->ring, (unsigned)nbufs, 0, 0, &r);
    if (!u->br) {
        io_uring_queue_exit(&u->ring);
        free(u->bufs);
        free(u);
        return r == -ENOMEM || (flags & UR_REQUIRE) ? r : ur_emulate(entries, nbufs, buflen);
    }
    int mask = io_uring_buf_ring_mask((unsigned)nbufs);
    for (int i = 0; i < nbufs; i++)
        io_uring_buf_ring_add(u->br, u->bufs + (size_t)i * u->buflen, u->buflen,
                              (unsigned short)i, mask, i);
    io_uring_buf_ring_advance(u->br, nbufs);
    return (int64_t)(intptr_t)u;
}

/* Queues a multishot accept on the listener fd. Accepted sockets are
   blocking, which io_uring doesn't need otherwise. */
void ur_accept(int64_t h, int32_t fd, uint64_t tag) {
    if (UR_EMULATED(h)) {
        urp_accept(UR_POLL(h), fd, tag);
        return;
    }
    struct ur *u = (struct ur *)(intptr_t)h;
    struct io_uring_sqe *sqe = ur_sqe(u);
    io_uring_prep_multishot_accept(sqe, fd, NULL, NULL, SOCK_CLOEXEC);
    io_uring_sqe_set_data64(sqe, tag << 2 | UR_TAGGED);
}

/* Queues a multishot receive into the provided buffers. */
void ur_recv(int64_t h, int32_t fd, uint64_t tag) {
    if (UR_EMULATED(h)) {
        urp_recv(UR_POLL(h), fd, tag);
        return;
    }
    struct ur *u = (struct ur *)(intptr_t)h;
    struct io_uring_sqe *sqe = ur_sqe(u);
    io_uring_prep_recv_multishot(sqe, fd, NULL, 0, 0);
    sqe->flags |= IOSQE_BUFFER_SELECT;
    sqe->buf_group = 0;
    io_uring_sqe_set_data64(sqe, tag << 2 | UR_TAGGED);
}

/* Queues s's next step: for data, a send of the rest; for a file, a splice
   of the file into the pipe while it's empty, else of the pipe into the
   socket, or a no-op to report err. */
static void ur_prep_send(struct ur *u, struct ur_send *s) {
    struct io_uring_sqe *sqe = ur_sqe(u);
    if (s->claim) {
        struct ur_gather *g = ur_gather_of(s);
        g->m = (struct msghdr){ .msg_iov = g->v, .msg_iovlen = (size_t)shared_claim_iov(s->claim, s->off, g->v, UR_IOV) };
        io_uring_prep_sendmsg(sqe, s->fd, &g->m, MSG_NOSIGNAL);
    } else if (s->file < 0) {
        io_uring_prep_send(sqe, s->fd, s->data + s->off, s->len - s->off, MSG_NOSIGNAL);
    } else if (s->err) {
        io_uring_prep_nop(sqe);
    } else if (s->piped > 0) {
        io_uring_prep_splice(sqe, s->pipe->rd, -1, s->fd, -1, s->piped, 0);
    } else {
        uint32_t n = s->fleft < s->pipe->cap ? (uint32_t)s->fleft : s->pipe->cap;
        io_uring_prep_splice(sqe, s->file, s->foff, s->pipe->wr, -1, n, 0);
    }
    io_uring_sqe_set_data64(sqe, (uint64_t)(uintptr_t)s | UR_SEND);
}

/* fd's record, or NULL when out of memory. */
static struct ur_fd *ur_fd_of(struct ur *u, int32_t fd) {
    if ((uint32_t)fd >= u->nfds) {
        uint32_t n = u->nfds ? u->nfds : 1024;
        while (n <= (uint32_t)fd) n *= 2;
        struct ur_fd *g = realloc(u->fds, n * sizeof *g);
        if (!g) return NULL;
        memset(g + u->nfds, 0, (n - u->nfds) * sizeof *g);
        u->fds = g;
        u->nfds = n;
    }
    return &u->fds[fd];
}

/* Appends s to f's sends, and queues it if it's first. */
static void ur_enqueue(struct ur *u, struct ur_fd *f, struct ur_send *s) {
    s->gen = f->gen;
    s->next = NULL;
    if (f->last) {
        f->last->next = s;
        f->last = s;
        return;
    }
    f->head = f->last = s;
    ur_prep_send(u, s);
}

/* Copies data and queues a send of it, with MSG_NOSIGNAL, behind the sends
   on fd before it. One that waits takes data into its own record when it
   has room, and then reports both: one copy, one send. A short send is
   queued again for the rest inside ur_wait, which reports the send once. */
int32_t ur_send(int64_t h, int32_t fd, uint64_t tag, ur_bytes data) {
    if (UR_EMULATED(h)) return urp_send(UR_POLL(h), fd, tag, data);
    struct ur *u = (struct ur *)(intptr_t)h;
    struct ur_send *s;
    struct ur_fd *f = ur_fd_of(u, fd);
    if (!f) return -ENOMEM;
    s = f->last;
    if (s && s != f->head && s->file < 0 && !s->claim && s->cap - s->len >= data.len) {
        memcpy(s->data + s->len, data.data, (size_t)data.len);
        s->len += (uint32_t)data.len;
        return 0;
    }
    s = NULL;
    uint32_t pre = 0;
    if (!f->head && data.len >= UR_INLINE) {
        /* The completion's slot comes first: once every byte has gone out,
           the send can't fail. */
        if (u->nsent == u->capsent) {
            int32_t cap = u->capsent ? u->capsent * 2 : 64;
            ur_completion *g = realloc(u->sent, (size_t)cap * sizeof *g);
            if (!g) return -ENOMEM;
            u->sent = g;
            u->capsent = cap;
        }
        ssize_t w = send(fd, data.data, (size_t)data.len, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (w == data.len) {
            u->sent[u->nsent++] = (ur_completion){ .tag = tag, .res = (int32_t)w, .buf = -1, .more = 0, .send = 1 };
            return 0;
        }
        if (w > 0) {
            pre = (uint32_t)w;
            data.data += w;
            data.len -= w;
        }
    }
    int k = 0;
    if (data.len <= UR_SMALL) {
        while ((UR_MIN << k) < data.len) k++;
        if (u->free[k]) {
            s = u->free[k];
            u->free[k] = s->next;
        }
    } else {
        for (struct ur_send **p = &u->big; *p; p = &(*p)->next) {
            if ((*p)->cap >= data.len) {
                s = *p;
                *p = s->next;
                u->kept -= s->cap;
                break;
            }
        }
    }
    if (!s) {
        size_t cap = data.len <= UR_SMALL ? (size_t)UR_MIN << k : ((size_t)data.len + UR_BIG - 1) / UR_BIG * UR_BIG;
        s = malloc(sizeof *s + cap);
        if (!s) return -ENOMEM;
        s->cap = (uint32_t)cap;
    }
    s->tag = tag;
    s->fd = fd;
    s->len = (uint32_t)data.len;
    s->off = 0;
    s->pre = pre;
    s->file = -1;
    s->claim = NULL;
    memcpy(s->data, data.data, (size_t)data.len);
    ur_enqueue(u, f, s);
    return 0;
}

/* Gathers sends here: ring.goose's ring_gathers. */
uint8_t ur_gathers(int64_t h) {
    (void)h;
    return 1;
}

/* Queues a send of data and the ranges shared_defer deferred into it, with
   one sendmsg a step, behind the sends on fd before it, and takes the
   ranges' references (shim/shared.c), which the record holds until its last
   completion. Only data is copied. A short send is queued again for the
   rest inside ur_wait, as ur_send's is. */
int32_t ur_send_shared(int64_t h, int32_t fd, uint64_t tag, ur_bytes data) {
    if (UR_EMULATED(h)) return urp_send_shared(UR_POLL(h), fd, tag, data);
    struct ur *u = (struct ur *)(intptr_t)h;
    struct shared_claim *c = shared_claim_take(data.data, data.len);
    if (!c) return -ENOMEM;
    struct ur_fd *f = ur_fd_of(u, fd);
    int k = 0;
    while ((UR_MIN << k) < (int64_t)UR_GATHER_CAP) k++;
    struct ur_send *s = NULL;
    if (f && u->free[k]) {
        s = u->free[k];
        u->free[k] = s->next;
    } else if (f) {
        s = malloc(sizeof *s + ((size_t)UR_MIN << k));
        if (s) s->cap = (uint32_t)UR_MIN << k;
    }
    if (!s) {
        shared_claim_free(c);
        return -ENOMEM;
    }
    s->tag = tag;
    s->fd = fd;
    s->len = (uint32_t)shared_claim_len(c);
    s->off = s->pre = 0;
    s->file = -1;
    s->claim = c;
    ur_enqueue(u, f, s);
    return 0;
}

/* An empty pipe, as big as the system lets it grow up to UR_PIPE_SIZE, or
   NULL with errno set. */
static struct ur_pipe *ur_pipe_get(struct ur *u) {
    struct ur_pipe *p = u->pipes;
    if (p) {
        u->pipes = p->next;
        u->npipes--;
        return p;
    }
    p = malloc(sizeof *p);
    if (!p) return NULL;
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) < 0) {
        int e = errno;
        free(p);
        errno = e;
        return NULL;
    }
    p->rd = fds[0];
    p->wr = fds[1];
    fcntl(p->wr, F_SETPIPE_SZ, UR_PIPE_SIZE);
    int cap = fcntl(p->wr, F_GETPIPE_SZ);
    p->cap = cap > 0 ? (uint32_t)cap : 65536;
    return p;
}

/* Ends a file's send: closes the file, and keeps its pipe if it's empty. */
static void ur_file_end(struct ur *u, struct ur_send *s) {
    close(s->file);
    s->file = -1;
    struct ur_pipe *p = s->pipe;
    s->pipe = NULL;
    if (!p) return;
    if (s->piped == 0 && u->npipes < UR_PIPES) {
        p->next = u->pipes;
        u->pipes = p;
        u->npipes++;
        return;
    }
    close(p->rd);
    close(p->wr);
    free(p);
}

/* Queues a send of len bytes of file from off behind the sends on fd before
   it, spliced through a pipe, so the bytes never reach the program. The ring
   owns file from here on, also when this fails. Without a pipe, the send
   still goes in the queue, to fail in its turn. */
int32_t ur_send_file(int64_t h, int32_t fd, uint64_t tag, int64_t file, int64_t off, int64_t len) {
    if (UR_EMULATED(h)) return urp_send_file(UR_POLL(h), fd, tag, file, off, len);
    struct ur *u = (struct ur *)(intptr_t)h;
    struct ur_fd *f = ur_fd_of(u, fd);
    struct ur_send *s = NULL;
    if (f && u->free[0]) {
        s = u->free[0];
        u->free[0] = s->next;
    } else if (f) {
        s = malloc(sizeof *s + UR_MIN);
        if (s) s->cap = UR_MIN;
    }
    if (!s) {
        close((int)file);
        return -ENOMEM;
    }
    s->tag = tag;
    s->fd = fd;
    s->len = s->off = s->pre = 0;
    s->claim = NULL;
    s->file = (int32_t)file;
    s->foff = off;
    s->fleft = len;
    s->piped = 0;
    s->pipe = ur_pipe_get(u);
    s->err = s->pipe ? 0 : -errno;
    ur_enqueue(u, f, s);
    return 0;
}

static void ur_send_free(struct ur *u, struct ur_send *s);

/* A step of file send s completed with res. Queues the next, or ends the
   send. Returns whether it wrote a completion into c: one for each piece
   that went out, and one for an error. */
static int ur_file_step(struct ur *u, struct ur_send *s, int32_t res, ur_completion *c) {
    struct ur_fd *f = &u->fds[s->fd];
    int live = s->gen == f->gen;
    int32_t err = live ? s->err : -ECANCELED;
    int more = 0;
    if (!err && s->piped == 0) {
        if (res > 0) {
            s->piped = (uint32_t)res;
            s->foff += res;
            s->fleft -= res;
            ur_prep_send(u, s);
            return 0;
        }
        err = res < 0 ? res : -EIO;     /* the file ended early */
    } else if (!err) {
        if (res <= 0) {
            err = res < 0 ? res : -EPIPE;
        } else {
            s->piped -= (uint32_t)res;
            more = s->piped > 0 || s->fleft > 0;
            if (more) ur_prep_send(u, s);
        }
    }
    c->tag = s->tag;
    c->res = err ? err : res;
    c->buf = -1;
    c->more = (uint8_t)more;
    c->send = 1;
    if (more) return 1;
    ur_file_end(u, s);
    if (live) {
        f->head = s->next;
        if (f->head) ur_prep_send(u, f->head);
        else f->last = NULL;
    }
    ur_send_free(u, s);
    return 1;
}

static void ur_send_free(struct ur *u, struct ur_send *s) {
    if (s->claim) {
        shared_claim_free(s->claim);
        s->claim = NULL;
    }
    if (s->cap <= UR_SMALL) {
        int k = 0;
        while ((UR_MIN << k) < s->cap) k++;
        s->next = u->free[k];
        u->free[k] = s;
    } else if (u->kept + s->cap <= UR_KEEP) {
        s->next = u->big;
        u->big = s;
        u->kept += s->cap;
    } else {
        free(s);
    }
}

/* Queues a cancel of the request queued with tag. */
void ur_cancel(int64_t h, uint64_t tag) {
    if (UR_EMULATED(h)) {
        urp_cancel(UR_POLL(h), tag);
        return;
    }
    struct ur *u = (struct ur *)(intptr_t)h;
    struct io_uring_sqe *sqe = ur_sqe(u);
    io_uring_prep_cancel64(sqe, tag << 2 | UR_TAGGED, 0);
    io_uring_sqe_set_data64(sqe, UR_QUIET);
    sqe->flags |= IOSQE_CQE_SKIP_SUCCESS;
}

/* Queues a cancel of the receive queued on fd with tag recv, unless recv is
   0, and of the send in flight on fd, then fd's close. A queued request
   holds a reference to the socket, so closing fd alone would leave the
   connection open until the request ended. The sends waiting behind the one
   in flight are dropped, with no completion. */
void ur_close(int64_t h, int32_t fd, uint64_t recv) {
    if (UR_EMULATED(h)) {
        urp_close(UR_POLL(h), fd, recv);
        return;
    }
    struct ur *u = (struct ur *)(intptr_t)h;
    /* By user_data, which the kernel finds by hash, and only what's there: a
       cancel by fd walks every bucket of the ring's poll table. */
    if (recv) ur_cancel(h, recv);
    if ((uint32_t)fd < u->nfds) {
        struct ur_fd *f = &u->fds[fd];
        if (f->head) {
            for (struct ur_send *s = f->head->next, *next; s; s = next) {
                next = s->next;
                if (s->file >= 0) ur_file_end(u, s);
                ur_send_free(u, s);
            }
            f->head->next = NULL;
            /* A splice may be filling its pipe: not empty, so not reused. */
            if (f->head->file >= 0) f->head->piped = 1;
            struct io_uring_sqe *sqe = ur_sqe(u);
            io_uring_prep_cancel64(sqe, (uint64_t)(uintptr_t)f->head | UR_SEND, 0);
            io_uring_sqe_set_data64(sqe, UR_QUIET);
            sqe->flags |= IOSQE_CQE_SKIP_SUCCESS;
        }
        f->head = f->last = NULL;
        f->gen++;
    }
    struct io_uring_sqe *sqe = ur_sqe(u);
    io_uring_prep_close(sqe, fd);
    io_uring_sqe_set_data64(sqe, UR_QUIET);
    sqe->flags |= IOSQE_CQE_SKIP_SUCCESS;
}

static void ur_poll_waker(struct ur *u) {
    struct io_uring_sqe *sqe = ur_sqe(u);
    io_uring_prep_poll_multishot(sqe, u->wfd, POLLIN);
    io_uring_sqe_set_data64(sqe, u->wtag << 2 | UR_TAGGED);
}

/* A waker (shim/mail.c) on the ring: an eventfd of its own, which a
   multishot poll watches, so each wake ends the ring's wait with a
   completion of tag, res 0, and no buffer. ur_wait empties the eventfd. The
   waker is closed after the ring is destroyed, which ends the poll. */
int64_t ur_waker(int64_t h, uint64_t tag) {
    if (UR_EMULATED(h)) return urp_waker(UR_POLL(h), tag);
    struct ur *u = (struct ur *)(intptr_t)h;
    int64_t w = net_waker(-1, 0);
    if (w < 0) return w;
    u->waker = w;
    u->wfd = net_waker_fd(w);
    u->wtag = tag;
    ur_poll_waker(u);
    return w;
}

/* Queues a one-shot poll of fd for events, POLLIN or POLLOUT, which are
   EPOLLIN and EPOLLOUT, on the bound ring, for key: net_arm's, while
   ur_bind binds it. */
static int32_t ur_arm(int32_t fd, uint32_t events, uint64_t key) {
    struct ur *u = ur_bound;
    int32_t k;
    if (u->freearm) {
        k = u->freearm - 1;
        u->freearm = u->arms[k].next + 1;
    } else {
        if (u->narms == u->caparms) {
            int32_t cap = u->caparms ? u->caparms * 2 : 16;
            struct ur_arm *g = realloc(u->arms, (size_t)cap * sizeof *g);
            if (!g) return -ENOMEM;
            u->arms = g;
            u->caparms = cap;
        }
        k = u->narms++;
    }
    u->arms[k] = (struct ur_arm){ .key = key, .state = UR_ARM_POLLING, .next = -1 };
    u->live++;
    struct io_uring_sqe *sqe = ur_sqe(u);
    io_uring_prep_poll_add(sqe, fd, (events & (POLLIN | POLLOUT)) | POLLRDHUP);
    io_uring_sqe_set_data64(sqe, (uint64_t)k << 2 | UR_ARMED);
    return 0;
}

static void ur_disarm_bound(uint64_t key);

/* Makes net_arm and net_disarm, on the calling thread, arm sockets on ring h,
   with completions of tag, until h is destroyed. The emulation isn't bound,
   and net_arm stays ENOSYS on it. */
void ur_bind(int64_t h, uint64_t tag) {
    if (UR_EMULATED(h)) return;
    struct ur *u = (struct ur *)(intptr_t)h;
    u->stag = tag;
    ur_bound = u;
    net_loop_ring(ur_arm, ur_disarm_bound);
}

static void ur_arm_free(struct ur *u, int32_t k) {
    u->arms[k].state = UR_ARM_FREE;
    u->arms[k].next = u->freearm - 1;
    u->freearm = k + 1;
}

/* Makes stale every socket armed for a key whose bits under mask are key's,
   and cancels its poll if it's still in the kernel, which holds the socket
   open until then. */
void ur_disarm(int64_t h, uint64_t key, uint64_t mask) {
    if (UR_EMULATED(h)) return;
    struct ur *u = (struct ur *)(intptr_t)h;
    if (!u->live) return;
    for (int32_t k = 0; k < u->narms; k++) {
        struct ur_arm *a = &u->arms[k];
        if ((a->state != UR_ARM_POLLING && a->state != UR_ARM_REPORTED) || ((a->key ^ key) & mask)) continue;
        if (a->state == UR_ARM_POLLING) {
            struct io_uring_sqe *sqe = ur_sqe(u);
            io_uring_prep_cancel64(sqe, (uint64_t)k << 2 | UR_ARMED, 0);
            io_uring_sqe_set_data64(sqe, UR_QUIET);
            sqe->flags |= IOSQE_CQE_SKIP_SUCCESS;
        }
        a->state = UR_ARM_STALE;
        u->live--;
    }
}

/* net_disarm's: the sockets armed for key on the bound ring. */
static void ur_disarm_bound(uint64_t key) {
    ur_disarm((int64_t)(intptr_t)ur_bound, key, ~(uint64_t)0);
}

/* The key of the armed socket whose completion had buf k, or 0 when it was
   disarmed since. Frees the record. */
uint64_t ur_socket(int64_t h, int32_t k) {
    struct ur *u = (struct ur *)(intptr_t)h;
    uint64_t key = u->arms[k].state == UR_ARM_REPORTED ? u->arms[k].key : 0;
    if (key) u->live--;
    ur_arm_free(u, k);
    return key;
}

/* Copies dst.len bytes of provided buffer buf from off into dst. */
void ur_take(int64_t h, int32_t buf, int64_t off, ur_bytes dst) {
    if (UR_EMULATED(h)) {
        urp_take(UR_POLL(h), buf, off, dst);
        return;
    }
    struct ur *u = (struct ur *)(intptr_t)h;
    memcpy(dst.data, u->bufs + (size_t)buf * u->buflen + off, (size_t)dst.len);
}

/* Gives provided buffer buf back to the kernel, at the next ur_wait. */
void ur_give(int64_t h, int32_t buf) {
    if (UR_EMULATED(h)) {
        urp_give(UR_POLL(h), buf);
        return;
    }
    struct ur *u = (struct ur *)(intptr_t)h;
    io_uring_buf_ring_add(u->br, u->bufs + (size_t)buf * u->buflen, u->buflen,
                          (unsigned short)buf, io_uring_buf_ring_mask(u->nbufs), u->given++);
}

/* Submits what's queued, waits up to timeout_ms (-1: no limit) for at least
   one completion, and writes up to out.len of them into out. Leaves any
   others for the next call. */
int32_t ur_wait(int64_t h, ur_completions out, int32_t timeout_ms) {
    if (UR_EMULATED(h)) return urp_wait(UR_POLL(h), out, timeout_ms);
    struct ur *u = (struct ur *)(intptr_t)h;
    if (u->given) {
        io_uring_buf_ring_advance(u->br, u->given);
        u->given = 0;
    }
    struct io_uring_cqe *cqe;
    int r;
    if (u->nsent > 0) {
        r = io_uring_submit_and_get_events(&u->ring);
    } else if (timeout_ms < 0) {
        r = io_uring_submit_and_wait(&u->ring, 1);
    } else {
        struct __kernel_timespec ts = { timeout_ms / 1000, (long long)(timeout_ms % 1000) * 1000000 };
        r = io_uring_submit_and_wait_timeout(&u->ring, &cqe, 1, &ts, NULL);
    }
    if (r < 0 && r != -ETIME) return r;
    int32_t n = u->nsent < out.len ? u->nsent : (int32_t)out.len;
    memcpy(out.data, u->sent, (size_t)n * sizeof *u->sent);
    u->nsent -= n;
    memmove(u->sent, u->sent + n, (size_t)u->nsent * sizeof *u->sent);
    unsigned head, seen = 0;
    io_uring_for_each_cqe(&u->ring, head, cqe) {
        if (n == out.len) break;
        seen++;
        uint64_t ud = cqe->user_data;
        ur_completion *c = &out.data[n];
        /* UR_QUIET and UR_ARMED in one test, which receives and sends don't
           pass. */
        if (ud & 2) {
            if ((ud & 3) == UR_QUIET) continue;
            int32_t k = (int32_t)(ud >> 2);
            if (u->arms[k].state == UR_ARM_STALE) {
                ur_arm_free(u, k);
                continue;
            }
            u->arms[k].state = UR_ARM_REPORTED;
            *c = (ur_completion){ .tag = u->stag, .res = cqe->res, .buf = k, .more = 0, .send = 0 };
            n++;
            continue;
        }
        if ((ud & 3) == UR_SEND) {
            struct ur_send *s = (struct ur_send *)(uintptr_t)(ud & ~(uint64_t)3);
            if (s->file >= 0) {
                n += ur_file_step(u, s, cqe->res, c);
                continue;
            }
            struct ur_fd *f = &u->fds[s->fd];
            int live = s->gen == f->gen;
            int rest = cqe->res > 0 && s->off + (uint32_t)cqe->res < s->len;
            if (rest && live) {
                s->off += (uint32_t)cqe->res;
                ur_prep_send(u, s);
                continue;
            }
            c->tag = s->tag;
            c->res = rest ? -ECANCELED : cqe->res < 0 ? cqe->res : (int32_t)(s->len + s->pre);
            c->buf = -1;
            c->more = 0;
            c->send = 1;
            if (live) {
                f->head = s->next;
                if (f->head) ur_prep_send(u, f->head);
                else f->last = NULL;
            }
            ur_send_free(u, s);
        } else if (u->waker && ud >> 2 == u->wtag) {
            /* The poll ends on an error or an overflow of the completion
               queue; it's queued again, and the wake reported either way. */
            net_waker_clear(u->waker);
            if (!(cqe->flags & IORING_CQE_F_MORE)) ur_poll_waker(u);
            c->tag = u->wtag;
            c->res = 0;
            c->buf = -1;
            c->more = 1;
            c->send = 0;
        } else {
            c->tag = ud >> 2;
            c->res = cqe->res;
            c->buf = cqe->flags & IORING_CQE_F_BUFFER ? (int32_t)(cqe->flags >> IORING_CQE_BUFFER_SHIFT) : -1;
            c->more = (cqe->flags & IORING_CQE_F_MORE) != 0;
            c->send = 0;
        }
        n++;
    }
    io_uring_cq_advance(&u->ring, seen);
    return n;
}

/* Tears the ring down, with whatever is still queued on it. The records of
   sends in flight aren't freed: only a completion says when the kernel is
   done with one, so a gathered one keeps its blobs' references too. Those
   waiting behind them are freed, and release theirs. Their files and pipes are
   closed, as the kernel holds its own reference to one in use, except those
   of a file's send in flight when ur_close dropped its fd. */
void ur_destroy(int64_t h) {
    if (UR_EMULATED(h)) {
        urp_destroy(UR_POLL(h));
        return;
    }
    struct ur *u = (struct ur *)(intptr_t)h;
    io_uring_free_buf_ring(&u->ring, u->br, u->nbufs, 0);
    io_uring_queue_exit(&u->ring);
    for (uint32_t fd = 0; fd < u->nfds; fd++) {
        if (!u->fds[fd].head) continue;
        if (u->fds[fd].head->file >= 0) {
            u->fds[fd].head->piped = 1;     /* not empty: close the pipe */
            ur_file_end(u, u->fds[fd].head);
        }
        for (struct ur_send *s = u->fds[fd].head->next, *next; s; s = next) {
            next = s->next;
            if (s->file >= 0) ur_file_end(u, s);
            if (s->claim) shared_claim_free(s->claim);
            free(s);
        }
    }
    while (u->pipes) {
        struct ur_pipe *p = u->pipes;
        u->pipes = p->next;
        close(p->rd);
        close(p->wr);
        free(p);
    }
    for (int k = 0; k < UR_CLASSES; k++) {
        while (u->free[k]) {
            struct ur_send *s = u->free[k];
            u->free[k] = s->next;
            free(s);
        }
    }
    while (u->big) {
        struct ur_send *s = u->big;
        u->big = s->next;
        free(s);
    }
    free(u->bufs);
    free(u->fds);
    free(u->sent);
    free(u->arms);
    if (ur_bound == u) {
        ur_bound = NULL;
        net_loop_ring(NULL, NULL);
    }
    free(u);
}
