/* The kernel calls the server makes on macOS, for src/sys.goose: the
   functions of shim/net.c, with the same arguments and results, over kqueue
   instead of epoll. goose build compiles this beside the program (the root
   file's sidecar), so it sees none of the generated C: it spells out the
   layouts it shares with Goose, per spec C.2.

   Every function returns what its syscall returns on success and -code on
   failure, where code is errno translated to its Linux number (net_err), the
   values src/sys.goose names. None of them keeps a pointer into Goose memory
   after it returns. */
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/qos.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* Unix V7's numbers, which macOS and Linux share up to 34. */
_Static_assert(EINTR == 4 && ENFILE == 23 && EMFILE == 24 && EPIPE == 32 && ERANGE == 34,
               "errno values below 35 differ from Linux's");

/* Linux's numbers for macOS's errno values from 35 up. 0 is an errno with no
   Linux counterpart. */
static const int16_t net_linux_errno[] = {
    [EAGAIN] = 11, [EINPROGRESS] = 115, [EALREADY] = 114, [ENOTSOCK] = 88,
    [EDESTADDRREQ] = 89, [EMSGSIZE] = 90, [EPROTOTYPE] = 91, [ENOPROTOOPT] = 92,
    [EPROTONOSUPPORT] = 93, [ESOCKTNOSUPPORT] = 94, [ENOTSUP] = 95, [EPFNOSUPPORT] = 96,
    [EAFNOSUPPORT] = 97, [EADDRINUSE] = 98, [EADDRNOTAVAIL] = 99, [ENETDOWN] = 100,
    [ENETUNREACH] = 101, [ENETRESET] = 102, [ECONNABORTED] = 103, [ECONNRESET] = 104,
    [ENOBUFS] = 105, [EISCONN] = 106, [ENOTCONN] = 107, [ESHUTDOWN] = 108,
    [ETOOMANYREFS] = 109, [ETIMEDOUT] = 110, [ECONNREFUSED] = 111, [ELOOP] = 40,
    [ENAMETOOLONG] = 36, [EHOSTDOWN] = 112, [EHOSTUNREACH] = 113, [ENOTEMPTY] = 39,
    [EUSERS] = 87, [EDQUOT] = 122, [ESTALE] = 116, [EREMOTE] = 66, [ENOLCK] = 37,
    [ENOSYS] = 38, [EOVERFLOW] = 75, [ECANCELED] = 125, [EIDRM] = 43, [ENOMSG] = 42,
    [EILSEQ] = 84, [ENOATTR] = 61, [EBADMSG] = 74, [EMULTIHOP] = 72, [ENODATA] = 61,
    [ENOLINK] = 67, [ENOSR] = 63, [ENOSTR] = 60, [EPROTO] = 71, [ETIME] = 62,
    [EOPNOTSUPP] = 95, [ENOTRECOVERABLE] = 131, [EOWNERDEAD] = 130,
};
#define NET_ERRNO_COUNT (int)(sizeof net_linux_errno / sizeof net_linux_errno[0])
/* An errno with no Linux number becomes this plus its own, clear of Linux's. */
#define NET_UNMAPPED 1000

static int net_err(int e) {
    if (e < 35) return e;
    if (e < NET_ERRNO_COUNT && net_linux_errno[e]) return net_linux_errno[e];
    return NET_UNMAPPED + e;
}

/* net_err's inverse, for strerror. ENOATTR and ENODATA share 61, and ENOTSUP
   and EOPNOTSUPP 95; either one's text will do. */
static int net_native(int code) {
    if (code < 35) return code;
    if (code >= NET_UNMAPPED) return code - NET_UNMAPPED;
    for (int e = 35; e < NET_ERRNO_COUNT; e++)
        if (net_linux_errno[e] == code) return e;
    return code;
}

/* src/sys.goose spells these out as numbers, as Linux has them; this shim
   translates them, so only the shutdown how has to match. */
_Static_assert(SHUT_WR == 1, "shutdown's how differs from src/sys.goose");

/* The layouts shared with Goose, packed as Goose packs them (spec C.2): a
   u8[:] and an i64[:], passed by value, sys::PollEvent, and a slice of it. */
#pragma pack(push, 1)
typedef struct { uint8_t *data; int64_t len; } net_bytes;
typedef struct { int64_t *data; int64_t len; } net_i64s;
typedef struct { uint32_t events; uint64_t tag; } net_event;
typedef struct { net_event *data; int64_t len; } net_events;
#pragma pack(pop)
_Static_assert(sizeof(net_bytes) == sizeof(void *) + 8 && sizeof(net_i64s) == sizeof(void *) + 8 &&
               sizeof(net_event) == 12 && sizeof(net_events) == sizeof(void *) + 8,
               "not packed as Goose packs them");

/* Flags of net_listen and net_accept; sys::NONBLOCK, REUSEPORT, UNIX, and
   V6ONLY. */
#define NET_NONBLOCK 1
#define NET_REUSEPORT 2
#define NET_UNIX 4
#define NET_V6ONLY 8

/* sys::IN, OUT, ERR, HUP, RDHUP, and ET: epoll's bits, as src/sys.goose
   names them. */
#define NET_IN 0x001u
#define NET_OUT 0x004u
#define NET_ERR 0x008u
#define NET_HUP 0x010u
#define NET_RDHUP 0x2000u
#define NET_ET 0x80000000u
/* sys::CTL_ADD, CTL_DEL, and CTL_MOD. */
#define NET_CTL_ADD 1
#define NET_CTL_DEL 2
#define NET_CTL_MOD 3

/* net_epoll_wait reads this many kernel events per call at most. */
#define NET_MAX_EVENTS 1024

/* The socket address net_listen's addr, port, and flags name, into ss: a
   Unix socket's path, an IPv4-mapped address as IPv4, another 16 bytes as
   IPv6, or none as every IPv4 address. Returns 0, or an errno value. */
static int net_sockaddr(net_bytes addr, int32_t port, int32_t flags, struct sockaddr_storage *ss,
                        socklen_t *len) {
    static const uint8_t mapped[12] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    memset(ss, 0, sizeof *ss);
    if (flags & NET_UNIX) {
        struct sockaddr_un *u = (struct sockaddr_un *)ss;
        if (addr.len == 0 || memchr(addr.data, 0, (size_t)addr.len)) return EINVAL;
        if (addr.len >= (int64_t)sizeof u->sun_path) return ENAMETOOLONG;
        u->sun_family = AF_UNIX;
        memcpy(u->sun_path, addr.data, (size_t)addr.len);
        *len = sizeof *u;
    } else if (addr.len == 0 || (addr.len == 16 && memcmp(addr.data, mapped, 12) == 0)) {
        struct sockaddr_in *a = (struct sockaddr_in *)ss;
        a->sin_family = AF_INET;
        a->sin_port = htons((uint16_t)port);
        if (addr.len) memcpy(&a->sin_addr, addr.data + 12, 4);
        else a->sin_addr.s_addr = htonl(INADDR_ANY);
        *len = sizeof *a;
    } else if (addr.len == 16) {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)ss;
        a->sin6_family = AF_INET6;
        a->sin6_port = htons((uint16_t)port);
        memcpy(&a->sin6_addr, addr.data, 16);
        *len = sizeof *a;
    } else {
        return EINVAL;
    }
    ss->ss_len = (uint8_t)*len;
    return 0;
}

/* A listener on ss. A TCP one has TCP_NODELAY, and an IPv6 one takes IPv4
   clients unless NET_V6ONLY. A Unix socket's path is cleared first of a
   socket a server left there; anything else there fails the bind. */
static int32_t net_open_listener(struct sockaddr_storage *ss, socklen_t len, int32_t backlog,
                                 int32_t flags) {
    int fd = socket(ss->ss_family, SOCK_STREAM, 0);
    if (fd < 0) return -net_err(errno);
    int one = 1, v6only = (flags & NET_V6ONLY) != 0;
    int ok = fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 &&
             (!(flags & NET_NONBLOCK) || fcntl(fd, F_SETFL, O_NONBLOCK) == 0);
    if (ss->ss_family == AF_UNIX) {
        struct stat st;
        const char *path = ((struct sockaddr_un *)ss)->sun_path;
        if (lstat(path, &st) == 0 && S_ISSOCK(st.st_mode)) unlink(path);
    } else {
        ok = ok && setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) == 0 &&
             setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) == 0 &&
             (ss->ss_family != AF_INET6 ||
              setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, sizeof v6only) == 0);
    }
    if (!ok || bind(fd, (struct sockaddr *)ss, len) < 0 || listen(fd, backlog) < 0) {
        int err = errno;
        close(fd);
        return -net_err(err);
    }
    return fd;
}

/* macOS's SO_REUSEPORT doesn't spread connections across listeners: the
   last one bound gets them all. So the workers share one listener per port,
   which every worker's kqueue watches, and each gets its own fd for it.

   Left to the kernel, the worker already awake takes nearly every connection
   (108, 63, 63, and 24 of 256 across 4 workers), whether the listener is
   edge- or level-triggered. So each worker takes its share instead: it
   declines to accept while it has accepted more than one past the average,
   counted in sharers and accepted. Its kqueue watches the listener
   level-triggered, so a declined connection stays reported to every worker
   until one under the average takes it. When no worker takes it for
   NET_STALL_MS, as at the fd limit, the others stop declining, so they don't
   spin on the level-triggered watch, and reach the fd check, which disables
   it (net_accept). A worker at its connection limit,
   which stops calling accept, is woken by every wait while connections wait
   in the backlog.

   The table holds an fd of its own for each listener, and each worker a dup
   of it, which it gives back with net_close. The last one back closes the
   listener and frees the entry, so a loop started again opens a new one.

   This table, and the thread-local records below that tie a worker to its
   entries, are the only state the shim keeps between calls. */
#define NET_MAX_SHARED 16
static pthread_mutex_t net_shared_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    struct sockaddr_storage addr;   /* its address and port, or its path */
    socklen_t len;
    int32_t fd, sharers;            /* fd -1: a free entry */
    _Atomic int64_t accepted;
} net_shared[NET_MAX_SHARED];
static int net_shared_count;
/* The calling worker's record of each shared listener it serves, found by
   its fd: the entry, how many connections the worker has accepted from it,
   the accepted count it last declined at and since when, the kqueue and tag
   it watches the listener with, and whether net_accept disabled that watch
   at the fd limit. A worker serves up to NET_MAX_MINE ports at once, more
   than http::MAX_LISTENERS + 1. */
#define NET_MAX_MINE 8
#define NET_STALL_MS 2
struct net_mine {
    int32_t lfd;    /* -1: a free record */
    int entry;
    int64_t accepted, seen, seen_ms;
    int32_t kq;
    uint64_t tag;
    int paused;
};
static _Thread_local struct net_mine net_mine[NET_MAX_MINE];
static _Thread_local int net_mine_count;

/* The calling worker's record for fd, or NULL when fd isn't a shared
   listener of its own. */
static struct net_mine *net_mine_of(int32_t fd) {
    if (fd < 0) return NULL;
    for (int i = 0; i < net_mine_count; i++)
        if (net_mine[i].lfd == fd) return &net_mine[i];
    return NULL;
}

/* A listener where addr, port, and flags say (src/sys.goose). macOS copies
   TCP_NODELAY and O_NONBLOCK from the listener to each accepted socket. With
   NET_REUSEPORT, every call on an address and port, or a path, returns an fd
   for the same listener, and the calling worker takes its share of the
   listener's connections (above). */
int32_t net_listen(net_bytes addr, int32_t port, int32_t backlog, int32_t flags) {
    struct sockaddr_storage ss;
    socklen_t len;
    int err = net_sockaddr(addr, port, flags, &ss, &len);
    if (err) return -net_err(err);
    if (!(flags & NET_REUSEPORT)) return net_open_listener(&ss, len, backlog, flags);
    int k = 0;
    while (k < net_mine_count && net_mine[k].lfd >= 0) k++;
    if (k == NET_MAX_MINE) return -net_err(ENOBUFS);
    pthread_mutex_lock(&net_shared_lock);
    int32_t r = 0;
    int i = 0;
    while (i < net_shared_count &&
           (net_shared[i].fd < 0 || net_shared[i].len != len || memcmp(&net_shared[i].addr, &ss, len) != 0)) i++;
    if (i == net_shared_count) {
        /* A new listener, in a free entry. */
        i = 0;
        while (i < net_shared_count && net_shared[i].fd >= 0) i++;
        if (i == NET_MAX_SHARED) {
            r = -net_err(ENOBUFS);
        } else {
            r = net_open_listener(&ss, len, backlog, flags);
            if (r >= 0) {
                net_shared[i].addr = ss;
                net_shared[i].len = len;
                net_shared[i].fd = r;
                net_shared[i].sharers = 0;
                atomic_store_explicit(&net_shared[i].accepted, 0, memory_order_relaxed);
                if (i == net_shared_count) net_shared_count++;
            }
        }
    }
    if (r >= 0) {
        int fd = fcntl(net_shared[i].fd, F_DUPFD_CLOEXEC, 0);
        r = fd < 0 ? -net_err(errno) : fd;
    }
    if (r >= 0) {
        net_shared[i].sharers++;
        net_mine[k] = (struct net_mine){ .lfd = r, .entry = i, .kq = -1 };
        if (k == net_mine_count) net_mine_count++;
    }
    pthread_mutex_unlock(&net_shared_lock);
    return r;
}

int64_t net_clock_ms(void);

/* Changes the calling worker's watch of one of its shared listeners. */
static void net_watch_listener(struct net_mine *m, uint16_t flags) {
    struct kevent ch;
    EV_SET(&ch, m->lfd, EVFILT_READ, flags, 0, 0, (void *)m->tag);
    kevent(m->kq, &ch, 1, NULL, 0, NULL);
}

/* The highest fd accept has returned, and the fds a check (below) allows
   for accepts in flight on other threads. */
static _Atomic int32_t net_high_fd;
#define NET_FD_MARGIN 64
static pthread_mutex_t net_fd_lock = PTHREAD_MUTEX_INITIALIZER;

/* macOS drops a connection whose accept fails with EMFILE, where Linux leaves
   it in the backlog. So near the fd limit, this first checks that an fd is
   free, and fails without accepting when none is: the client keeps its place
   in the backlog. The check and the accept hold a lock, so two workers can't
   both pass the check for the last free fd. The check costs two syscalls, so
   it starts only once an accepted fd
   came within NET_FD_MARGIN of getdtablesize(), and from then on always runs:
   fds go to the lowest free number, so the highest fd seen, and not the last,
   tells how close the limit is. The system-wide limit (ENFILE) isn't checked
   for; a connection that reaches it is dropped.

   flags must be the listener's NONBLOCK, as every caller's is: macOS gives the
   accepted socket the listener's O_NONBLOCK, as it does TCP_NODELAY.

   On a shared listener, -EAGAIN also means the worker has taken more than its
   share. At the fd limit, the level-triggered watch would wake the worker
   at once on every wait, so it's disabled until the worker's next try. */
int32_t net_accept(int32_t fd, int32_t flags) {
    (void)flags;
    struct net_mine *m = net_mine_of(fd);
    if (m) {
        if (m->paused) {
            net_watch_listener(m, EV_ENABLE);
            m->paused = 0;
        }
        int64_t n = net_shared[m->entry].sharers;
        int64_t total = atomic_load_explicit(&net_shared[m->entry].accepted,
                                             memory_order_relaxed);
        if (m->accepted * n > total + n) {
            int64_t now = net_clock_ms();
            if (total != m->seen) {
                m->seen = total;
                m->seen_ms = now;
            }
            if (now - m->seen_ms < NET_STALL_MS) return -net_err(EAGAIN);
        }
    }
    static _Atomic int32_t limit;
    int32_t lim = atomic_load_explicit(&limit, memory_order_relaxed);
    if (lim == 0) {
        lim = getdtablesize();
        atomic_store_explicit(&limit, lim, memory_order_relaxed);
    }
    int near = atomic_load_explicit(&net_high_fd, memory_order_relaxed) + NET_FD_MARGIN >= lim;
    if (near) {
        pthread_mutex_lock(&net_fd_lock);
        int spare = fcntl(fd, F_DUPFD_CLOEXEC, 0);
        if (spare < 0) {
            int err = errno;
            pthread_mutex_unlock(&net_fd_lock);
            if (m && m->kq >= 0) {
                net_watch_listener(m, EV_DISABLE);
                m->paused = 1;
            }
            return -net_err(err);
        }
        close(spare);
    }
    int r = accept(fd, NULL, NULL);
    int err = errno;
    if (near) pthread_mutex_unlock(&net_fd_lock);
    if (r < 0) return -net_err(err);
    int32_t high = atomic_load_explicit(&net_high_fd, memory_order_relaxed);
    while (r > high && !atomic_compare_exchange_weak_explicit(&net_high_fd, &high, r,
                                                              memory_order_relaxed,
                                                              memory_order_relaxed)) {}
    if (m) {
        m->accepted++;
        atomic_fetch_add_explicit(&net_shared[m->entry].accepted, 1, memory_order_relaxed);
    }
    if (fcntl(r, F_SETFD, FD_CLOEXEC) < 0) {
        int err = errno;
        close(r);
        return -net_err(err);
    }
    return r;
}

int64_t net_recv(int32_t fd, net_bytes buf) {
    ssize_t r = recv(fd, buf.data, (size_t)buf.len, 0);
    return r < 0 ? -net_err(errno) : r;
}

/* MSG_NOSIGNAL turns a write to a closed connection into -EPIPE instead of a
   SIGPIPE that would end the process. */
int64_t net_send(int32_t fd, net_bytes data) {
    ssize_t r = send(fd, data.data, (size_t)data.len, MSG_NOSIGNAL);
    return r < 0 ? -net_err(errno) : r;
}

int32_t net_shutdown(int32_t fd, int32_t how) {
    return shutdown(fd, how) < 0 ? -net_err(errno) : 0;
}

/* The peer of connected socket fd: its address into out[..16], an IPv4 one
   as IPv4-mapped IPv6 (::ffff:a.b.c.d), and its port as the result. */
int32_t net_peer(int32_t fd, net_bytes out) {
    struct sockaddr_storage ss;
    socklen_t len = sizeof ss;
    if (out.len < 16) return -net_err(EINVAL);
    if (getpeername(fd, (struct sockaddr *)&ss, &len) < 0) return -net_err(errno);
    if (ss.ss_family == AF_INET) {
        struct sockaddr_in *a = (struct sockaddr_in *)&ss;
        memset(out.data, 0, 10);
        out.data[10] = out.data[11] = 0xff;
        memcpy(out.data + 12, &a->sin_addr, 4);
        return ntohs(a->sin_port);
    }
    if (ss.ss_family == AF_INET6) {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)&ss;
        memcpy(out.data, &a->sin6_addr, 16);
        return ntohs(a->sin6_port);
    }
    return -net_err(EAFNOSUPPORT);
}

/* A worker's fd for a shared listener goes back to the table (above). */
int32_t net_close(int32_t fd) {
    struct net_mine *m = net_mine_of(fd);
    if (m) {
        pthread_mutex_lock(&net_shared_lock);
        if (--net_shared[m->entry].sharers == 0) {
            close(net_shared[m->entry].fd);
            if (net_shared[m->entry].addr.ss_family == AF_UNIX)
                unlink(((struct sockaddr_un *)&net_shared[m->entry].addr)->sun_path);
            net_shared[m->entry].fd = -1;
        }
        pthread_mutex_unlock(&net_shared_lock);
        m->lfd = -1;
        m->kq = -1;
    }
    return close(fd) < 0 ? -net_err(errno) : 0;
}

/* The local port of socket fd, as bound. */
int32_t net_port(int32_t fd) {
    struct sockaddr_storage ss;
    socklen_t len = sizeof ss;
    if (getsockname(fd, (struct sockaddr *)&ss, &len) < 0) return -net_err(errno);
    if (ss.ss_family == AF_INET) return ntohs(((struct sockaddr_in *)&ss)->sin_port);
    if (ss.ss_family == AF_INET6) return ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
    return -net_err(EAFNOSUPPORT);
}

/* ---- UDP, for QUIC (h3.goose): shim/net.c's, a datagram per call ---- */

typedef struct { int32_t len; uint8_t addr[28]; } net_udp_peer;
typedef struct { net_udp_peer *data; int64_t len; } net_udp_peers;
typedef struct { int32_t *data; int64_t len; } net_i32s;
_Static_assert(sizeof(net_udp_peer) == 32 && sizeof(struct sockaddr_in6) <= 28, "UdpPeer's layout");

/* macOS's SO_REUSEPORT gives a unicast datagram to one of the sockets
   bound, so a program serving h3 on macOS runs one worker. */
int32_t net_udp_open(net_bytes addr, int32_t port, int32_t flags) {
    struct sockaddr_storage ss;
    socklen_t len;
    int err = net_sockaddr(addr, port, flags & ~NET_UNIX, &ss, &len);
    if (err) return -net_err(err);
    int fd = socket(ss.ss_family, SOCK_DGRAM, 0);
    if (fd < 0) return -net_err(errno);
    int one = 1, v6only = (flags & NET_V6ONLY) != 0, size = 4 << 20;
    int ok = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 &&
             (!(flags & NET_REUSEPORT) || setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) == 0) &&
             (ss.ss_family != AF_INET6 || setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, sizeof v6only) == 0);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof size);
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof size);
    /* Its datagrams aren't fragmented (RFC 9000, section 14), so a path MTU
       probe too large for the path is refused or dropped, not carried. */
    if (ss.ss_family == AF_INET6) setsockopt(fd, IPPROTO_IPV6, IPV6_DONTFRAG, &one, sizeof one);
    else setsockopt(fd, IPPROTO_IP, IP_DONTFRAG, &one, sizeof one);
    if (!ok || bind(fd, (struct sockaddr *)&ss, len) < 0) {
        int e = errno;
        close(fd);
        return -net_err(e);
    }
    return fd;
}

int32_t net_udp_recv(int32_t fd, net_bytes buf, int32_t slot, net_i32s sizes, net_udp_peers peers) {
    int64_t n = sizes.len < peers.len ? sizes.len : peers.len;
    if (slot <= 0) return -net_err(EINVAL);
    if (n > buf.len / slot) n = buf.len / slot;
    if (n <= 0) return -net_err(EINVAL);
    int32_t got = 0;
    while (got < n) {
        socklen_t len = sizeof peers.data[got].addr;
        ssize_t r = recvfrom(fd, buf.data + (int64_t)got * slot, (size_t)slot, MSG_DONTWAIT | MSG_TRUNC,
                             (struct sockaddr *)peers.data[got].addr, &len);
        if (r < 0) {
            if (errno == EINTR) continue;
            if (got > 0) break;
            return -net_err(errno);
        }
        sizes.data[got] = r > slot ? 0 : (int32_t)r;
        peers.data[got].len = (int32_t)len;
        got++;
    }
    return got;
}

int32_t net_udp_send(int32_t fd, net_bytes buf, net_i32s sizes, net_udp_peers peers, uint8_t gso) {
    (void)gso;
    int64_t at = 0;
    int32_t sent = 0;
    if (sizes.len > peers.len) return -net_err(EINVAL);
    for (int64_t i = 0; i < sizes.len; i++) {
        if (at + sizes.data[i] > buf.len) return -net_err(EINVAL);
        ssize_t r;
        do r = sendto(fd, buf.data + at, (size_t)sizes.data[i], 0, (struct sockaddr *)peers.data[i].addr,
                      (socklen_t)peers.data[i].len);
        while (r < 0 && errno == EINTR);
        if (r < 0) return sent > 0 ? sent : -net_err(errno);
        at += sizes.data[i];
        sent++;
    }
    return sent;
}

/* A non-blocking socket connecting to what addr, port, and NET_UNIX in flags
   name, as net_listen's do, but for an empty addr, which names no peer. A TCP
   one has TCP_NODELAY, as libpq's has. Returns the fd once connect has
   started or finished; net_connected says which, and how it ended. It counts
   toward the highest fd, which net_accept's check near the limit reads. */
int32_t net_connect(net_bytes addr, int32_t port, int32_t flags) {
    struct sockaddr_storage ss;
    socklen_t len;
    if (addr.len == 0) return -net_err(EINVAL);
    int err = net_sockaddr(addr, port, flags & NET_UNIX, &ss, &len);
    if (err) return -net_err(err);
    int fd = socket(ss.ss_family, SOCK_STREAM, 0);
    if (fd < 0) return -net_err(errno);
    int one = 1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0 ||
        (ss.ss_family != AF_UNIX && setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) < 0) ||
        (connect(fd, (struct sockaddr *)&ss, len) < 0 && errno != EINPROGRESS)) {
        err = errno;
        close(fd);
        return -net_err(err);
    }
    int32_t high = atomic_load_explicit(&net_high_fd, memory_order_relaxed);
    while (fd > high && !atomic_compare_exchange_weak_explicit(&net_high_fd, &high, fd,
                                                               memory_order_relaxed,
                                                               memory_order_relaxed)) {}
    return fd;
}

/* The addresses host names, as shim/net.c's net_resolve gives them, with
   Linux's error numbers. */
int32_t net_resolve(net_bytes host, net_bytes out) {
    char name[256];
    if (host.len <= 0 || host.len >= (int64_t)sizeof name || memchr(host.data, 0, (size_t)host.len))
        return -net_err(EINVAL);
    memcpy(name, host.data, (size_t)host.len);
    name[host.len] = 0;
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM, .ai_flags = AI_ADDRCONFIG };
    struct addrinfo *list;
    int r = getaddrinfo(name, NULL, &hints, &list);
    if (r == EAI_SYSTEM) return -net_err(errno);
    if (r == EAI_AGAIN || r == EAI_FAIL) return -net_err(EAGAIN);
    if (r == EAI_NONAME || r == EAI_NODATA) return -net_err(ENOENT);
    if (r) return -net_err(EINVAL);
    int32_t n = 0;
    for (struct addrinfo *a = list; a && (int64_t)(n + 1) * 16 <= out.len; a = a->ai_next) {
        uint8_t *p = out.data + n * 16;
        if (a->ai_family == AF_INET) {
            memset(p, 0, 10);
            p[10] = p[11] = 0xff;
            memcpy(p + 12, &((struct sockaddr_in *)a->ai_addr)->sin_addr, 4);
            n++;
        } else if (a->ai_family == AF_INET6) {
            memcpy(p, &((struct sockaddr_in6 *)a->ai_addr)->sin6_addr, 16);
            n++;
        }
    }
    freeaddrinfo(list);
    return n ? n : -net_err(ENOENT);
}

/* How net_connect's connect on fd ended: 0 once connected, -EINPROGRESS
   while it goes on, or its error, which SO_ERROR gives once: a second call
   after a failure finds the socket unconnected and returns -ENOTCONN. */
int32_t net_connected(int32_t fd) {
    int err = 0;
    socklen_t len = sizeof err;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0) return -net_err(errno);
    if (err) return -net_err(err);
    struct sockaddr_storage ss;
    len = sizeof ss;
    if (getpeername(fd, (struct sockaddr *)&ss, &len) == 0) return 0;
    if (errno != ENOTCONN) return -net_err(errno);
    /* A connect still going on leaves the socket unwritable. */
    struct pollfd p = { .fd = fd, .events = POLLOUT };
    return poll(&p, 1, 0) == 0 ? -net_err(EINPROGRESS) : -net_err(ENOTCONN);
}

/* Waits up to ms (-1: no limit) for fd to be ready for events, epoll's IN
   and OUT bits. Returns the bits it is ready for, with ERR and HUP, or 0 at
   the time limit; EINTR is 0 too, and the caller waits again for what's left
   of its limit. */
int32_t net_poll(int32_t fd, uint32_t events, int32_t ms) {
    struct pollfd p = { .fd = fd, .events = (short)((events & NET_IN ? POLLIN : 0) |
                                                    (events & NET_OUT ? POLLOUT : 0)) };
    int n = poll(&p, 1, ms);
    if (n < 0) return errno == EINTR ? 0 : -net_err(errno);
    if (n == 0) return 0;
    return (p.revents & POLLIN ? NET_IN : 0) | (p.revents & POLLOUT ? NET_OUT : 0) |
           (p.revents & (POLLERR | POLLNVAL) ? NET_ERR : 0) | (p.revents & POLLHUP ? NET_HUP : 0);
}

/* The kqueue of the loop the calling thread runs, which net_arm adds to:
   epoll_loop sets it while it runs, and -1 after. */
static _Thread_local int32_t net_loop_kq = -1;

void net_loop_bind(int32_t ep) {
    net_loop_kq = ep;
}

/* Watches fd on the calling thread's loop for events once: EV_ONESHOT
   filters, whose next event carries tag, and which go once it fires. A
   socket ready already raises it at once. A filter not asked for is
   deleted. -ENOSYS on a thread that runs no kqueue loop. */
int32_t net_arm(int32_t fd, uint32_t events, uint64_t tag) {
    if (net_loop_kq < 0) return -net_err(ENOSYS);
    struct kevent ch[2], res[2];
    uint16_t add = EV_ADD | EV_ONESHOT | EV_RECEIPT, del = EV_DELETE | EV_RECEIPT;
    EV_SET(&ch[0], fd, EVFILT_READ, events & NET_IN ? add : del, 0, 0, (void *)tag);
    EV_SET(&ch[1], fd, EVFILT_WRITE, events & NET_OUT ? add : del, 0, 0, (void *)tag);
    int got = kevent(net_loop_kq, ch, 2, res, 2, NULL);
    if (got < 0) return -net_err(errno);
    for (int i = 0; i < got; i++) {
        int err = res[i].flags & EV_ERROR ? (int)res[i].data : 0;
        int asked = res[i].filter == EVFILT_READ ? events & NET_IN : events & NET_OUT;
        if (err && (asked || err != ENOENT)) return -net_err(err);
    }
    return 0;
}

/* Nothing to cancel: closing a socket deletes its filters. */
void net_disarm(uint64_t tag) { (void)tag; }

int32_t net_epoll_create(void) {
    int r = kqueue();
    if (r < 0) return -net_err(errno);
    if (fcntl(r, F_SETFD, FD_CLOEXEC) < 0) {
        int err = errno;
        close(r);
        return -net_err(err);
    }
    return r;
}

/* An epoll registration as kevent changes: IN is EVFILT_READ, OUT is
   EVFILT_WRITE, and ET is EV_CLEAR on both, except on the worker's shared
   listeners, which are always level-triggered (net_listen). kqueue reports a
   peer's close unasked, so RDHUP needs no filter. A filter not asked for is
   deleted, and deleting one that isn't registered is no error. */
int32_t net_epoll_ctl(int32_t ep, int32_t op, int32_t fd, uint32_t events, uint64_t tag) {
    struct net_mine *m = net_mine_of(fd);
    if (m) {
        m->kq = op == NET_CTL_DEL ? -1 : ep;
        m->tag = tag;
    }
    uint16_t add = EV_ADD | EV_RECEIPT | (events & NET_ET && !m ? EV_CLEAR : 0);
    uint16_t del = EV_DELETE | EV_RECEIPT;
    struct kevent ch[2], res[2];
    if (op != NET_CTL_ADD && op != NET_CTL_DEL && op != NET_CTL_MOD) return -net_err(EINVAL);
    int n = 0;
    if (op == NET_CTL_DEL || events & NET_IN || op == NET_CTL_MOD)
        EV_SET(&ch[n++], fd, EVFILT_READ,
               op != NET_CTL_DEL && events & NET_IN ? add : del, 0, 0, (void *)tag);
    if (op == NET_CTL_DEL || events & NET_OUT || op == NET_CTL_MOD)
        EV_SET(&ch[n++], fd, EVFILT_WRITE,
               op != NET_CTL_DEL && events & NET_OUT ? add : del, 0, 0, (void *)tag);
    if (n == 0) return 0;
    int got = kevent(ep, ch, n, res, n, NULL);
    if (got < 0) return -net_err(errno);
    for (int i = 0; i < got; i++) {
        int err = res[i].flags & EV_ERROR ? (int)res[i].data : 0;
        int deleting = res[i].filter == ch[0].filter ? ch[0].flags & EV_DELETE
                                                     : ch[n - 1].flags & EV_DELETE;
        if (err && !(err == ENOENT && deleting)) return -net_err(err);
    }
    return 0;
}

/* struct kevent is 32 bytes on arm64, so the kernel writes into a local
   array of it and the events are copied out into http::PollEvent. kqueue reports
   each filter apart, and epoll one event per fd holding both, so the events
   of one fd are merged: the loop frees a connection's slot on the event that
   closes it, and a second event for it in the same batch would find the slot
   freed. EV_EOF is RDHUP on the read filter and HUP on the write filter, and
   its fflags, when set, is the socket's error. */
int32_t net_epoll_wait(int32_t ep, net_events out, int32_t timeout_ms) {
    struct kevent kev[NET_MAX_EVENTS];
    uintptr_t fds[NET_MAX_EVENTS];
    struct timespec ts, *tp = NULL;
    if (timeout_ms >= 0) {
        ts.tv_sec = timeout_ms / 1000;
        ts.tv_nsec = (long)(timeout_ms % 1000) * 1000000;
        tp = &ts;
    }
    int max = out.len < NET_MAX_EVENTS ? (int)out.len : NET_MAX_EVENTS;
    int n = kevent(ep, NULL, 0, kev, max, tp);
    if (n < 0) return -net_err(errno);
    int m = 0;
    for (int i = 0; i < n; i++) {
        uint32_t bits;
        if (kev[i].filter == EVFILT_READ) bits = NET_IN | (kev[i].flags & EV_EOF ? NET_RDHUP : 0);
        else if (kev[i].filter == EVFILT_WRITE) bits = NET_OUT | (kev[i].flags & EV_EOF ? NET_HUP : 0);
        else if (kev[i].filter == EVFILT_USER) bits = NET_IN;   /* a waker's (net_waker) */
        else continue;
        if (kev[i].flags & EV_EOF && kev[i].fflags) bits |= NET_ERR;
        int j = m;
        while (j > 0 && fds[j - 1] != kev[i].ident) j--;
        if (j > 0) {
            out.data[j - 1].events |= bits;
        } else {
            fds[m] = kev[i].ident;
            out.data[m].events = bits;
            out.data[m].tag = (uint64_t)kev[i].udata;
            m++;
        }
    }
    return m;
}

/* A waker, which shim/mail.c's boxes wake their owner with: an EVFILT_USER
   event, identified by the waker's own address, with EV_CLEAR, so a trigger
   stays reported until a wait takes it and no wake is lost between a check
   and a wait. On a loop's kqueue its event comes out of net_epoll_wait as IN
   with the waker's tag; with ep -1 the waker has a kqueue of its own, for
   net_waker_wait. Any thread may wake it. Each change to a knote replaces
   its udata, the trigger's too, so the trigger passes the tag again. */
struct net_waker { int kq, own; uint64_t tag; };

int64_t net_waker(int32_t ep, uint64_t tag) {
    struct net_waker *w = malloc(sizeof *w);
    if (!w) return -net_err(ENOMEM);
    w->own = ep < 0;
    w->tag = tag;
    w->kq = w->own ? net_epoll_create() : ep;
    if (w->kq < 0) {
        int32_t r = w->kq;
        free(w);
        return r;
    }
    struct kevent ch;
    EV_SET(&ch, (uintptr_t)w, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, (void *)tag);
    if (kevent(w->kq, &ch, 1, NULL, 0, NULL) < 0) {
        int err = errno;
        if (w->own) close(w->kq);
        free(w);
        return -net_err(err);
    }
    return (int64_t)(intptr_t)w;
}

void net_waker_wake(int64_t h) {
    struct net_waker *w = (struct net_waker *)(intptr_t)h;
    struct kevent ch;
    EV_SET(&ch, (uintptr_t)w, EVFILT_USER, 0, NOTE_TRIGGER, 0, (void *)w->tag);
    kevent(w->kq, &ch, 1, NULL, 0, NULL);
}

/* Waits up to ms (-1: no limit) for a wake of a waker with a kqueue of its
   own. Returns 1 for a wake, 0 at the time limit. */
int32_t net_waker_wait(int64_t h, int32_t ms) {
    struct net_waker *w = (struct net_waker *)(intptr_t)h;
    struct timespec ts, *tp = NULL;
    if (ms >= 0) {
        ts.tv_sec = ms / 1000;
        ts.tv_nsec = (long)(ms % 1000) * 1000000;
        tp = &ts;
    }
    struct kevent ev;
    int n = kevent(w->kq, NULL, 0, &ev, 1, tp);
    if (n < 0) return errno == EINTR ? 0 : -net_err(errno);
    return n;
}

/* A waker on a loop's kqueue is closed before the kqueue. */
void net_waker_close(int64_t h) {
    struct net_waker *w = (struct net_waker *)(intptr_t)h;
    struct kevent ch;
    EV_SET(&ch, (uintptr_t)w, EVFILT_USER, EV_DELETE, 0, 0, NULL);
    kevent(w->kq, &ch, 1, NULL, 0, NULL);
    if (w->own) close(w->kq);
    free(w);
}

/* The loops' timers fall due by this clock, so it's the precise one, read
   without a syscall: CLOCK_MONOTONIC_RAW_APPROX, the value cached at the
   last context switch, is up to about 2 ms old. macOS reads CLOCK_REALTIME
   without a syscall too. */
int64_t net_clock_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int64_t net_time_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec;
}

/* Apple Silicon has no CPU affinity; the QoS class is what keeps a thread
   on the performance cores. The thread also blocks SIGPIPE: sendfile, unlike
   send, has no MSG_NOSIGNAL, and a client that leaves mid-file would kill the
   process. A blocked SIGPIPE that the thread's own call raises stays pending,
   harmless. Blocking covers every socket at once, where SO_NOSIGPIPE would
   take a setsockopt on each accepted one, as macOS doesn't document that
   accept copies it from the listener. */
void net_worker_start(void) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    sigset_t s;
    sigemptyset(&s);
    sigaddset(&s, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &s, NULL);
}

/* The performance cores' logical CPUs (8 on an M1 Pro), or 0 where the
   sysctl doesn't exist, as on Intel Macs. */
int32_t net_default_workers(void) {
    int32_t n = 0;
    size_t len = sizeof n;
    if (sysctlbyname("hw.perflevel0.logicalcpu", &n, &len, NULL, 0) < 0) return 0;
    return n;
}

/* dst.len bytes of src into dst; net_copy has checked the lengths. */
void net_move(net_bytes dst, net_bytes src) {
    if (dst.len > 0) memmove(dst.data, src.data, (size_t)dst.len);
}

/* Writes the C library's text for an error code into out, cut to fit, and
   returns its length. */
int64_t net_strerror(int64_t err, net_bytes out) {
    const char *s = strerror(net_native((int)err));
    size_t n = strlen(s);
    if (n > (size_t)out.len) n = (size_t)out.len;
    memcpy(out.data, s, n);
    return (int64_t)n;
}

/* How many times net_stop has run in the process. A loop reads it at its
   start, and stops once it has moved on. An atomic counter, and not a flag, so
   that a loop started after a stop runs. A signal handler may call net_stop:
   a lock-free atomic add is async-signal-safe, and so, in practice, is the
   kevent each loop's waker gets (shim/mail.c), which makes the stop
   immediate. */
static _Atomic int64_t net_stop_count;

void net_stop_wake_all(void);

void net_stop(void) {
    atomic_fetch_add_explicit(&net_stop_count, 1, memory_order_relaxed);
    net_stop_wake_all();
}

int64_t net_stops(void) {
    return atomic_load_explicit(&net_stop_count, memory_order_relaxed);
}

static void net_on_signal(int sig) {
    (void)sig;
    net_stop();
}

/* Makes SIGTERM and SIGINT call net_stop instead of ending the process. */
int32_t net_stop_on_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = net_on_signal;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGTERM, &sa, NULL) < 0 || sigaction(SIGINT, &sa, NULL) < 0) return -net_err(errno);
    return 0;
}

#define ERR(e) net_err(e)

/* path as a C string in p, or -code. */
static int64_t file_cpath(net_bytes path, char p[4096]) {
    if (path.len >= 4096) return -ERR(ENAMETOOLONG);
    if (memchr(path.data, 0, (size_t)path.len)) return -ERR(ENOENT);
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    return 0;
}

/* Writes st's size to info[0], its modification time in seconds since the
   epoch to info[1], and, where info has room, that time's nanoseconds to
   info[2] and the inode to info[3], which tell a replaced file apart. */
static void file_info(const struct stat *st, net_i64s info) {
    if (info.len >= 2) {
        info.data[0] = (int64_t)st->st_size;
        info.data[1] = (int64_t)st->st_mtime;
    }
    if (info.len >= 4) {
        info.data[2] = (int64_t)st->st_mtimespec.tv_nsec;
        info.data[3] = (int64_t)st->st_ino;
    }
}

/* Opens path, which holds no NUL, for reading: a regular file, else -EISDIR
   for a directory and -EINVAL for anything else. O_NONBLOCK keeps a FIFO from
   blocking the open; a regular file's reads ignore it. Writes info as
   file_info does. */
int64_t net_file_open(net_bytes path, net_i64s info) {
    char p[4096];
    int64_t e0 = file_cpath(path, p);
    if (e0 < 0) return e0;
    int fd = open(p, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -ERR(errno);
    struct stat st;
    if (fstat(fd, &st) < 0) {
        int e = errno;
        close(fd);
        return -ERR(e);
    }
    if (!S_ISREG(st.st_mode)) {
        close(fd);
        return S_ISDIR(st.st_mode) ? -ERR(EISDIR) : -ERR(EINVAL);
    }
    file_info(&st, info);
    return fd;
}

/* What net_file_open would answer for path, without opening it: 0 and info,
   or -code. */
int64_t net_file_stat(net_bytes path, net_i64s info) {
    char p[4096];
    int64_t e0 = file_cpath(path, p);
    if (e0 < 0) return e0;
    struct stat st;
    if (stat(p, &st) < 0) return -ERR(errno);
    if (!S_ISREG(st.st_mode)) return S_ISDIR(st.st_mode) ? -ERR(EISDIR) : -ERR(EINVAL);
    file_info(&st, info);
    return 0;
}

/* Reads buf.len bytes of fd at off into buf, fewer only at the file's end.
   Returns how many, or -code. */
int64_t net_file_read(int64_t fd, net_bytes buf, int64_t off) {
    int64_t got = 0;
    while (got < buf.len) {
        ssize_t n = pread((int)fd, buf.data + got, (size_t)(buf.len - got), (off_t)(off + got));
        if (n < 0) {
            if (errno == EINTR) continue;
            return -ERR(errno);
        }
        if (n == 0) break;
        got += n;
    }
    return got;
}

void net_file_close(int64_t fd) {
    close((int)fd);
}

/* Sends up to len bytes of file fd from off on socket s, without copying them
   through the program. Returns the bytes sent, 0 at the file's end, or
   -code: EAGAIN when s takes no more now. macOS's sendfile takes the file
   first and returns the count through len, which it sets also when it fails
   with EAGAIN after sending some, so that counts as a send. A len of 0 would
   ask it for the rest of the file. fd -1 is EBADF, not ENOSYS: the loop asks
   with it whether sendfile exists. */
int64_t net_sendfile(int32_t s, int64_t fd, int64_t off, int64_t len) {
    if (fd < 0) return -net_err(EBADF);
    if (len <= 0) return 0;
    off_t n = (off_t)len;
    int r = sendfile((int)fd, s, (off_t)off, &n, NULL, 0);
    if (r < 0 && n == 0) return -net_err(errno);
    return (int64_t)n;
}
