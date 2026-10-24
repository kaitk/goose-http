/* The kernel calls the server makes on Linux, for src/sys.goose. goose build
   compiles this beside the program (the root file's sidecar), so it sees none
   of the generated C: it spells out the layouts it shares with Goose, per
   spec C.2.

   Every function returns what its syscall returns on success and -errno on
   failure. None of them keeps a pointer into Goose memory after it returns. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/sendfile.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* src/sys.goose spells these out as numbers; this keeps them honest on any
   target the C compiles for. */
_Static_assert(EINTR == 4 && EAGAIN == 11 && EPIPE == 32 && ECONNABORTED == 103 &&
               ECONNRESET == 104 && EADDRINUSE == 98 && EMFILE == 24 && ENFILE == 23 &&
               EINVAL == 22 && ENOENT == 2 && EACCES == 13 && ENOTDIR == 20 && EISDIR == 21 &&
               ENAMETOOLONG == 36 && EAFNOSUPPORT == 97 && ENOTCONN == 107 && ETIMEDOUT == 110 &&
               ECONNREFUSED == 111 && EINPROGRESS == 115,
               "errno values differ from src/sys.goose");
_Static_assert(EPOLLIN == 0x001 && EPOLLOUT == 0x004 && EPOLLERR == 0x008 &&
               EPOLLHUP == 0x010 && EPOLLRDHUP == 0x2000 && EPOLLET == 1u << 31,
               "epoll event bits differ from src/sys.goose");
_Static_assert(EPOLL_CTL_ADD == 1 && EPOLL_CTL_DEL == 2 && EPOLL_CTL_MOD == 3,
               "epoll_ctl ops differ from src/sys.goose");
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

/* epoll_wait converts this many kernel events per call at most. */
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
        return 0;
    }
    if (addr.len == 0 || (addr.len == 16 && memcmp(addr.data, mapped, 12) == 0)) {
        struct sockaddr_in *a = (struct sockaddr_in *)ss;
        a->sin_family = AF_INET;
        a->sin_port = htons((uint16_t)port);
        if (addr.len) memcpy(&a->sin_addr, addr.data + 12, 4);
        else a->sin_addr.s_addr = htonl(INADDR_ANY);
        *len = sizeof *a;
        return 0;
    }
    if (addr.len != 16) return EINVAL;
    struct sockaddr_in6 *a = (struct sockaddr_in6 *)ss;
    a->sin6_family = AF_INET6;
    a->sin6_port = htons((uint16_t)port);
    memcpy(&a->sin6_addr, addr.data, 16);
    *len = sizeof *a;
    return 0;
}

/* A listener on ss. A TCP one has TCP_NODELAY, which Linux copies to each
   accepted socket, so accept needs no setsockopt, and an IPv6 one takes IPv4
   clients unless NET_V6ONLY. A Unix socket's path is cleared first of a
   socket a server left there; anything else there fails the bind. */
static int32_t net_open_listener(struct sockaddr_storage *ss, socklen_t len, int32_t backlog,
                                 int32_t flags) {
    int fd = socket(ss->ss_family, SOCK_STREAM | SOCK_CLOEXEC |
                    (flags & NET_NONBLOCK ? SOCK_NONBLOCK : 0), 0);
    if (fd < 0) return -errno;
    int one = 1, v6only = (flags & NET_V6ONLY) != 0;
    int ok = 1;
    if (ss->ss_family == AF_UNIX) {
        struct stat st;
        const char *path = ((struct sockaddr_un *)ss)->sun_path;
        if (lstat(path, &st) == 0 && S_ISSOCK(st.st_mode)) unlink(path);
    } else {
        ok = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) == 0 &&
             (!(flags & NET_REUSEPORT) ||
              setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) == 0) &&
             setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) == 0 &&
             (ss->ss_family != AF_INET6 ||
              setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, sizeof v6only) == 0);
    }
    if (!ok || bind(fd, (struct sockaddr *)ss, len) < 0 || listen(fd, backlog) < 0) {
        int err = errno;
        close(fd);
        return -err;
    }
    return fd;
}

/* Linux has no SO_REUSEPORT for Unix sockets, so with NET_REUSEPORT the
   workers share one per path, as on macOS, each with an fd of its own for
   it. The table holds the listener's own fd, and the last worker's net_close
   closes it and removes the socket's file. A worker shares one listener at
   most: the loops refuse Config.listeners with a Unix address, and TCP
   listeners have SO_REUSEPORT and aren't shared. */
#define NET_MAX_SHARED 16
static pthread_mutex_t net_shared_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    struct sockaddr_un addr;
    int32_t fd, sharers;    /* fd -1: a free entry */
} net_shared[NET_MAX_SHARED];
static int net_shared_count;
static _Thread_local int32_t net_my_lfd = -1;
static _Thread_local int net_my_entry;

static int32_t net_listen_shared(struct sockaddr_storage *ss, socklen_t len, int32_t backlog,
                                 int32_t flags) {
    const struct sockaddr_un *u = (struct sockaddr_un *)ss;
    pthread_mutex_lock(&net_shared_lock);
    int i = 0;
    while (i < net_shared_count &&
           (net_shared[i].fd < 0 || strcmp(net_shared[i].addr.sun_path, u->sun_path) != 0)) i++;
    int32_t r = 0;
    if (i == net_shared_count) {
        i = 0;
        while (i < net_shared_count && net_shared[i].fd >= 0) i++;
        if (i == NET_MAX_SHARED) {
            r = -ENOBUFS;
        } else {
            r = net_open_listener(ss, len, backlog, flags);
            if (r >= 0) {
                net_shared[i].addr = *u;
                net_shared[i].fd = r;
                net_shared[i].sharers = 0;
                if (i == net_shared_count) net_shared_count++;
            }
        }
    }
    if (r >= 0) {
        int fd = fcntl(net_shared[i].fd, F_DUPFD_CLOEXEC, 0);
        r = fd < 0 ? -errno : fd;
    }
    if (r >= 0) {
        net_shared[i].sharers++;
        net_my_lfd = r;
        net_my_entry = i;
    }
    pthread_mutex_unlock(&net_shared_lock);
    return r;
}

int32_t net_listen(net_bytes addr, int32_t port, int32_t backlog, int32_t flags) {
    struct sockaddr_storage ss;
    socklen_t len;
    int err = net_sockaddr(addr, port, flags, &ss, &len);
    if (err) return -err;
    if (flags & NET_UNIX && flags & NET_REUSEPORT) return net_listen_shared(&ss, len, backlog, flags);
    return net_open_listener(&ss, len, backlog, flags);
}

int32_t net_accept(int32_t fd, int32_t flags) {
    int r = accept4(fd, NULL, NULL,
                    SOCK_CLOEXEC | (flags & NET_NONBLOCK ? SOCK_NONBLOCK : 0));
    return r < 0 ? -errno : r;
}

int64_t net_recv(int32_t fd, net_bytes buf) {
    ssize_t r = recv(fd, buf.data, (size_t)buf.len, 0);
    return r < 0 ? -errno : r;
}

/* MSG_NOSIGNAL turns a write to a closed connection into -EPIPE instead of a
   SIGPIPE that would end the process. */
int64_t net_send(int32_t fd, net_bytes data) {
    ssize_t r = send(fd, data.data, (size_t)data.len, MSG_NOSIGNAL);
    return r < 0 ? -errno : r;
}

int32_t net_shutdown(int32_t fd, int32_t how) {
    return shutdown(fd, how) < 0 ? -errno : 0;
}

/* A worker's fd for a shared Unix socket goes back to the table (above). */
int32_t net_close(int32_t fd) {
    if (fd == net_my_lfd) {
        pthread_mutex_lock(&net_shared_lock);
        if (--net_shared[net_my_entry].sharers == 0) {
            close(net_shared[net_my_entry].fd);
            unlink(net_shared[net_my_entry].addr.sun_path);
            net_shared[net_my_entry].fd = -1;
        }
        pthread_mutex_unlock(&net_shared_lock);
        net_my_lfd = -1;
    }
    return close(fd) < 0 ? -errno : 0;
}

/* The peer of connected socket fd: its address into out[..16], an IPv4 one
   as IPv4-mapped IPv6 (::ffff:a.b.c.d), and its port as the result. */
int32_t net_peer(int32_t fd, net_bytes out) {
    struct sockaddr_storage ss;
    socklen_t len = sizeof ss;
    if (out.len < 16) return -EINVAL;
    if (getpeername(fd, (struct sockaddr *)&ss, &len) < 0) return -errno;
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
    return -EAFNOSUPPORT;
}

/* The local port of socket fd, as bound. */
int32_t net_port(int32_t fd) {
    struct sockaddr_storage ss;
    socklen_t len = sizeof ss;
    if (getsockname(fd, (struct sockaddr *)&ss, &len) < 0) return -errno;
    if (ss.ss_family == AF_INET) return ntohs(((struct sockaddr_in *)&ss)->sin_port);
    if (ss.ss_family == AF_INET6) return ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
    return -EAFNOSUPPORT;
}

/* ---- UDP, for QUIC (h3.goose) ---- */

/* A datagram's peer, as sys.goose's UdpPeer: its socket address, as the
   kernel gave it, and that address's length. */
typedef struct { int32_t len; uint8_t addr[28]; } net_udp_peer;
typedef struct { net_udp_peer *data; int64_t len; } net_udp_peers;
typedef struct { int32_t *data; int64_t len; } net_i32s;
_Static_assert(sizeof(net_udp_peer) == 32 && sizeof(struct sockaddr_in6) <= 28, "UdpPeer's layout");

/* The most datagrams one call takes or gives, and the most segments one
   UDP_SEGMENT send carries, the kernel's UDP_MAX_SEGMENTS. */
#define NET_UDP_BATCH 64
#define NET_GSO_SEGMENTS 64
#ifndef UDP_SEGMENT
#define UDP_SEGMENT 103
#endif

/* A non-blocking UDP socket bound to what addr, port, and flags name, as
   net_listen's do, with SO_REUSEPORT under NET_REUSEPORT, so that each
   worker has its own and the kernel keeps a peer's datagrams on one. Its
   buffers are asked for at 4 MB, which the kernel caps at net.core's
   rmem_max and wmem_max, and its datagrams aren't fragmented (RFC 9000,
   section 14). */
int32_t net_udp_open(net_bytes addr, int32_t port, int32_t flags) {
    struct sockaddr_storage ss;
    socklen_t len;
    int err = net_sockaddr(addr, port, flags & ~NET_UNIX, &ss, &len);
    if (err) return -err;
    int fd = socket(ss.ss_family, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) return -errno;
    int one = 1, v6only = (flags & NET_V6ONLY) != 0, size = 4 << 20, pmtu = IP_PMTUDISC_PROBE;
    int ok = (!(flags & NET_REUSEPORT) || setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) == 0) &&
             (ss.ss_family != AF_INET6 || setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, sizeof v6only) == 0);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof size);
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof size);
    if (ss.ss_family == AF_INET) setsockopt(fd, IPPROTO_IP, IP_MTU_DISCOVER, &pmtu, sizeof pmtu);
    else setsockopt(fd, IPPROTO_IPV6, IPV6_MTU_DISCOVER, &pmtu, sizeof pmtu);
    if (!ok || bind(fd, (struct sockaddr *)&ss, len) < 0) {
        int e = errno;
        close(fd);
        return -e;
    }
    return fd;
}

/* Receives up to sizes.len datagrams, each into its slot bytes of buf, from
   slot * i: their sizes into sizes, and their peers into peers, which must be
   as long. A datagram longer than its slot is cut short, and its size given
   as 0. Returns how many, or -errno: EAGAIN once none waits. */
int32_t net_udp_recv(int32_t fd, net_bytes buf, int32_t slot, net_i32s sizes, net_udp_peers peers) {
    int64_t n = sizes.len < peers.len ? sizes.len : peers.len;
    if (slot <= 0) return -EINVAL;
    if (n > buf.len / slot) n = buf.len / slot;
    if (n > NET_UDP_BATCH) n = NET_UDP_BATCH;
    if (n <= 0) return -EINVAL;
    struct mmsghdr msgs[NET_UDP_BATCH];
    struct iovec iov[NET_UDP_BATCH];
    memset(msgs, 0, sizeof(struct mmsghdr) * (size_t)n);
    for (int64_t i = 0; i < n; i++) {
        iov[i].iov_base = buf.data + i * slot;
        iov[i].iov_len = (size_t)slot;
        msgs[i].msg_hdr.msg_name = peers.data[i].addr;
        msgs[i].msg_hdr.msg_namelen = sizeof peers.data[i].addr;
        msgs[i].msg_hdr.msg_iov = &iov[i];
        msgs[i].msg_hdr.msg_iovlen = 1;
    }
    int r;
    do r = recvmmsg(fd, msgs, (unsigned)n, MSG_DONTWAIT, NULL);
    while (r < 0 && errno == EINTR);
    if (r < 0) return -errno;
    for (int i = 0; i < r; i++) {
        sizes.data[i] = (msgs[i].msg_hdr.msg_flags & MSG_TRUNC) ? 0 : (int32_t)msgs[i].msg_len;
        peers.data[i].len = (int32_t)msgs[i].msg_hdr.msg_namelen;
    }
    return r;
}

/* Sends the datagrams that lie end to end in buf, sizes.len of them, each to
   its peer in peers. With gso, a run of datagrams to one peer, each as long
   as the first but the last, which may be shorter, goes as one send with
   UDP_SEGMENT. Returns how many datagrams the kernel took, in order, or
   -errno for none: EAGAIN when the socket's buffer is full, and EINVAL or
   EIO where the kernel or the device can't segment, when the caller sends
   again without gso. */
int32_t net_udp_send(int32_t fd, net_bytes buf, net_i32s sizes, net_udp_peers peers, uint8_t gso) {
    struct mmsghdr msgs[NET_UDP_BATCH];
    struct iovec iov[NET_UDP_BATCH];
    char cbuf[NET_UDP_BATCH][CMSG_SPACE(sizeof(uint16_t))];
    int counts[NET_UDP_BATCH];
    int64_t i = 0, at = 0;
    int32_t total = 0;
    if (sizes.len > peers.len) return -EINVAL;
    while (i < sizes.len) {
        int m = 0;
        while (m < NET_UDP_BATCH && i < sizes.len) {
            int64_t first = i, seg = sizes.data[i], len = 0;
            net_udp_peer *p = &peers.data[i];
            do {
                len += sizes.data[i];
                i++;
            } while (gso && i < sizes.len && i - first < NET_GSO_SEGMENTS && sizes.data[i - 1] == seg &&
                     sizes.data[i] <= seg && len + sizes.data[i] <= 65000 && peers.data[i].len == p->len &&
                     memcmp(peers.data[i].addr, p->addr, (size_t)p->len) == 0);
            if (at + len > buf.len) return -EINVAL;
            memset(&msgs[m], 0, sizeof msgs[m]);
            iov[m].iov_base = buf.data + at;
            iov[m].iov_len = (size_t)len;
            msgs[m].msg_hdr.msg_name = p->addr;
            msgs[m].msg_hdr.msg_namelen = (socklen_t)p->len;
            msgs[m].msg_hdr.msg_iov = &iov[m];
            msgs[m].msg_hdr.msg_iovlen = 1;
            counts[m] = (int)(i - first);
            if (counts[m] > 1) {
                msgs[m].msg_hdr.msg_control = cbuf[m];
                msgs[m].msg_hdr.msg_controllen = sizeof cbuf[m];
                struct cmsghdr *cm = CMSG_FIRSTHDR(&msgs[m].msg_hdr);
                cm->cmsg_level = SOL_UDP;
                cm->cmsg_type = UDP_SEGMENT;
                cm->cmsg_len = CMSG_LEN(sizeof(uint16_t));
                uint16_t s = (uint16_t)seg;
                memcpy(CMSG_DATA(cm), &s, sizeof s);
            }
            at += len;
            m++;
        }
        int done = 0;
        while (done < m) {
            int r = sendmmsg(fd, msgs + done, (unsigned)(m - done), 0);
            if (r < 0) {
                if (errno == EINTR) continue;
                return total > 0 ? total : -errno;
            }
            for (int k = done; k < done + r; k++) total += counts[k];
            done += r;
        }
    }
    return total;
}

/* A non-blocking socket connecting to what addr, port, and NET_UNIX in flags
   name, as net_listen's do, but for an empty addr, which names no peer. A TCP
   one has TCP_NODELAY, as libpq's has. Returns the fd once connect has
   started or finished; net_connected says which, and how it ended. */
int32_t net_connect(net_bytes addr, int32_t port, int32_t flags) {
    struct sockaddr_storage ss;
    socklen_t len;
    if (addr.len == 0) return -EINVAL;
    int err = net_sockaddr(addr, port, flags & NET_UNIX, &ss, &len);
    if (err) return -err;
    int fd = socket(ss.ss_family, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) return -errno;
    int one = 1;
    if ((ss.ss_family != AF_UNIX && setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) < 0) ||
        (connect(fd, (struct sockaddr *)&ss, len) < 0 && errno != EINPROGRESS)) {
        err = errno;
        close(fd);
        return -err;
    }
    return fd;
}

/* The addresses host names, from getaddrinfo, in its order: each 16 bytes
   into out, an IPv4 one IPv4-mapped, as net_connect takes them, at most
   out.len / 16. Returns how many, or -ENOENT for a name with no address,
   -EAGAIN for a lookup that failed for now, or -EINVAL for text that can't
   be a name. Blocks for as long as the lookup takes. */
int32_t net_resolve(net_bytes host, net_bytes out) {
    char name[256];
    if (host.len <= 0 || host.len >= (int64_t)sizeof name || memchr(host.data, 0, (size_t)host.len))
        return -EINVAL;
    memcpy(name, host.data, (size_t)host.len);
    name[host.len] = 0;
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM, .ai_flags = AI_ADDRCONFIG };
    struct addrinfo *list;
    int r = getaddrinfo(name, NULL, &hints, &list);
    if (r == EAI_SYSTEM) return -errno;
    if (r == EAI_AGAIN || r == EAI_FAIL) return -EAGAIN;
    if (r == EAI_NONAME || r == EAI_NODATA) return -ENOENT;
    if (r) return -EINVAL;
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
    return n ? n : -ENOENT;
}

/* How net_connect's connect on fd ended: 0 once connected, -EINPROGRESS
   while it goes on, or its error, which SO_ERROR gives once: a second call
   after a failure finds the socket unconnected and returns -ENOTCONN. */
int32_t net_connected(int32_t fd) {
    int err = 0;
    socklen_t len = sizeof err;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0) return -errno;
    if (err) return -err;
    struct sockaddr_storage ss;
    len = sizeof ss;
    if (getpeername(fd, (struct sockaddr *)&ss, &len) == 0) return 0;
    if (errno != ENOTCONN) return -errno;
    /* A connect still going on leaves the socket unwritable. */
    struct pollfd p = { .fd = fd, .events = POLLOUT };
    return poll(&p, 1, 0) == 0 ? -EINPROGRESS : -ENOTCONN;
}

/* Waits up to ms (-1: no limit) for fd to be ready for events, epoll's IN
   and OUT bits, which poll's share on Linux. Returns the bits it is ready
   for, with ERR and HUP, or 0 at the time limit; EINTR is 0 too, and the
   caller waits again for what's left of its limit. */
int32_t net_poll(int32_t fd, uint32_t events, int32_t ms) {
    struct pollfd p = { .fd = fd, .events = (short)(events & (POLLIN | POLLOUT)) };
    int n = poll(&p, 1, ms);
    if (n < 0) return errno == EINTR ? 0 : -errno;
    return n > 0 ? p.revents : 0;
}

/* The epoll instance of the loop the calling thread runs, which net_arm adds
   to: epoll_loop sets it while it runs, and -1 after. */
static _Thread_local int32_t net_loop_ep = -1;

void net_loop_bind(int32_t ep) {
    net_loop_ep = ep;
}

/* How the io_uring ring the calling thread runs arms a socket and disarms a
   key, if it runs one: shim/uring.c's ur_bind sets them, so a program
   without uring.c, such as a mail test, links. */
static _Thread_local int32_t (*net_loop_arm)(int32_t fd, uint32_t events, uint64_t tag);
static _Thread_local void (*net_loop_disarm)(uint64_t tag);

void net_loop_ring(int32_t (*arm)(int32_t fd, uint32_t events, uint64_t tag), void (*disarm)(uint64_t tag)) {
    net_loop_arm = arm;
    net_loop_disarm = disarm;
}

/* Cancels what net_arm armed for tag on the calling thread's io_uring ring,
   whose poll would hold the socket open. Nothing on epoll: closing a socket
   takes it out of the poller. */
void net_disarm(uint64_t tag) {
    if (net_loop_disarm) net_loop_disarm(tag);
}

/* Watches fd on the calling thread's loop for events once: its next event
   carries tag, and then fd raises none until it is armed again. Level-
   triggered, so a socket ready already raises it at once. On an io_uring
   loop, a one-shot poll (net_loop_arm). -ENOSYS on a thread that runs
   neither. */
int32_t net_arm(int32_t fd, uint32_t events, uint64_t tag) {
    if (net_loop_ep < 0) return net_loop_arm ? net_loop_arm(fd, events, tag) : -ENOSYS;
    struct epoll_event ev = { .events = (events & (EPOLLIN | EPOLLOUT)) | EPOLLRDHUP | EPOLLONESHOT,
                              .data.u64 = tag };
    if (epoll_ctl(net_loop_ep, EPOLL_CTL_MOD, fd, &ev) == 0) return 0;
    if (errno != ENOENT) return -errno;
    return epoll_ctl(net_loop_ep, EPOLL_CTL_ADD, fd, &ev) < 0 ? -errno : 0;
}

int32_t net_epoll_create(void) {
    int r = epoll_create1(EPOLL_CLOEXEC);
    return r < 0 ? -errno : r;
}

int32_t net_epoll_ctl(int32_t ep, int32_t op, int32_t fd, uint32_t events, uint64_t tag) {
    struct epoll_event ev;
    ev.events = events;
    ev.data.u64 = tag;
    return epoll_ctl(ep, op, fd, &ev) < 0 ? -errno : 0;
}

/* The kernel's struct epoll_event is packed on x86-64 and padded to 16 bytes
   on arm64, so the kernel writes into a local array of it and the events are
   copied out into sys::PollEvent, whose layout is the same everywhere. */
int32_t net_epoll_wait(int32_t ep, net_events out, int32_t timeout_ms) {
    struct epoll_event kev[NET_MAX_EVENTS];
    int max = out.len < NET_MAX_EVENTS ? (int)out.len : NET_MAX_EVENTS;
    int n = epoll_wait(ep, kev, max, timeout_ms);
    if (n < 0) return -errno;
    for (int i = 0; i < n; i++) {
        out.data[i].events = kev[i].events;
        out.data[i].tag = kev[i].data.u64;
    }
    return n;
}

/* The loops' timers fall due by this clock, so it's the precise one, read
   through the vDSO once per pass: the coarse clock is the last scheduler
   tick, 1 to 4 ms old by the kernel's HZ, and made a timer that late. The
   wall clock, read for whole seconds, stays coarse. */
int64_t net_clock_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int64_t net_time_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME_COARSE, &ts);
    return (int64_t)ts.tv_sec;
}

/* Blocks SIGPIPE in the loop's thread: sendfile, unlike send, has no
   MSG_NOSIGNAL, and a client that leaves mid-file would kill the process. A
   blocked SIGPIPE raised by the thread's own call stays pending, harmless. */
void net_worker_start(void) {
    sigset_t s;
    sigemptyset(&s);
    sigaddset(&s, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &s, NULL);
}

int32_t net_default_workers(void) {
    return 0;
}

/* Writes the C library's text for an errno value into out, cut to fit, and
   returns its length. */
int64_t net_strerror(int64_t err, net_bytes out) {
    const char *s = strerror((int)err);
    size_t n = strlen(s);
    if (n > (size_t)out.len) n = (size_t)out.len;
    memcpy(out.data, s, n);
    return (int64_t)n;
}

/* How many times net_stop has run in the process. A loop reads it at its
   start, and stops once it has moved on. An atomic counter, and not a flag, so
   that a loop started after a stop runs. A signal handler may call net_stop:
   a lock-free atomic add is async-signal-safe, and so is the eventfd write
   that each loop's waker gets (shim/mail.c), which makes the stop
   immediate. */
static _Atomic int64_t net_stop_count;

void net_stop_wake_all(void);

void net_stop(void) {
    atomic_fetch_add_explicit(&net_stop_count, 1, memory_order_relaxed);
    net_stop_wake_all();
}

/* A waker, which shim/mail.c's boxes wake their owner with: an eventfd. On a
   loop's epoll instance ep it's registered edge-triggered with tag, and every
   wake raises a new edge, so the loop needn't read it. With ep -1 it's the
   waker's own, for net_waker_wait, or for shim/uring.c to poll. Any thread
   may wake it. */
struct net_waker { int fd, ep; };

int64_t net_waker(int32_t ep, uint64_t tag) {
    struct net_waker *w = malloc(sizeof *w);
    if (!w) return -ENOMEM;
    w->ep = ep;
    w->fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (w->fd < 0) {
        int err = errno;
        free(w);
        return -err;
    }
    if (ep >= 0) {
        struct epoll_event ev = { .events = EPOLLIN | EPOLLET, .data.u64 = tag };
        if (epoll_ctl(ep, EPOLL_CTL_ADD, w->fd, &ev) < 0) {
            int err = errno;
            close(w->fd);
            free(w);
            return -err;
        }
    }
    return (int64_t)(intptr_t)w;
}

/* The eventfd, for shim/uring.c. */
int32_t net_waker_fd(int64_t h) {
    return ((struct net_waker *)(intptr_t)h)->fd;
}

void net_waker_wake(int64_t h) {
    struct net_waker *w = (struct net_waker *)(intptr_t)h;
    uint64_t one = 1;
    ssize_t r = write(w->fd, &one, sizeof one);
    (void)r;   /* EAGAIN only once the count nears 2^64: it's readable then */
}

/* Empties the eventfd's count. */
void net_waker_clear(int64_t h) {
    struct net_waker *w = (struct net_waker *)(intptr_t)h;
    uint64_t n;
    ssize_t r = read(w->fd, &n, sizeof n);
    (void)r;
}

/* Waits up to ms (-1: no limit) for a wake of a waker of its own. Returns 1
   for a wake, which it takes, and 0 at the time limit. */
int32_t net_waker_wait(int64_t h, int32_t ms) {
    struct net_waker *w = (struct net_waker *)(intptr_t)h;
    struct pollfd p = { .fd = w->fd, .events = POLLIN };
    int n = poll(&p, 1, ms);
    if (n < 0) return errno == EINTR ? 0 : -errno;
    if (n > 0) net_waker_clear(h);
    return n > 0;
}

/* A waker on a loop's epoll instance is closed before the instance. */
void net_waker_close(int64_t h) {
    struct net_waker *w = (struct net_waker *)(intptr_t)h;
    if (w->ep >= 0) epoll_ctl(w->ep, EPOLL_CTL_DEL, w->fd, NULL);
    close(w->fd);
    free(w);
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
    if (sigaction(SIGTERM, &sa, NULL) < 0 || sigaction(SIGINT, &sa, NULL) < 0) return -errno;
    return 0;
}

#define ERR(e) (e)

/* Opens path, which holds no NUL, for reading: a regular file, else -EISDIR
   for a directory and -EINVAL for anything else. O_NONBLOCK keeps a FIFO from
   blocking the open; a regular file's reads ignore it. Writes its size to
   info[0] and its modification time, in seconds since the epoch, to info[1]. */
int64_t net_file_open(net_bytes path, net_i64s info) {
    char p[4096];
    if (path.len >= (int64_t)sizeof p) return -ERR(ENAMETOOLONG);
    if (memchr(path.data, 0, (size_t)path.len)) return -ERR(ENOENT);
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
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
    if (info.len >= 2) {
        info.data[0] = (int64_t)st.st_size;
        info.data[1] = (int64_t)st.st_mtime;
    }
    return fd;
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
   through the program. Returns the bytes sent, 0 at the file's end, or -errno:
   EAGAIN when s takes no more now. */
int64_t net_sendfile(int32_t s, int64_t fd, int64_t off, int64_t len) {
    off_t o = (off_t)off;
    ssize_t n = sendfile(s, (int)fd, &o, (size_t)len);
    return n < 0 ? -ERR(errno) : n;
}
