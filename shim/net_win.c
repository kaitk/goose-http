/* The kernel calls the server makes on Windows, for src/sys.goose: the
   functions of shim/net.c, with the same arguments and results, over
   Winsock. goose build compiles this beside the program (the root file's
   sidecar), so it sees none of the generated C: it spells out the layouts it
   shares with Goose, per spec C.2.

   Every function returns what its call returns on success and -code on
   failure, where code is the Winsock or Win32 error translated to its Linux
   errno (net_win_err), the values src/sys.goose names. None of them keeps a
   pointer into Goose memory after it returns.

   A socket is a SOCKET handle, passed to Goose as an i32: 64-bit Windows
   keeps handle values within 32 bits, for 32-bit code, and a process holds
   at most 2^24 handles, so they fit.

   Windows has no epoll, so the net_epoll_* calls fail with ENOSYS, and the
   echo-epoll mode doesn't run here. The HTTP server's loop on Windows is the
   completion loop, over shim/iocp.c, which uses net_win_err and
   net_win_init too. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef SOMAXCONN_HINT
#define SOMAXCONN_HINT(b) (-(b))
#endif

/* Linux's errno values for the Winsock and Win32 errors that have one, as
   libuv's uv_translate_sys_error maps them. WSAESHUTDOWN, a send after
   shutdown, is EPIPE, as on Linux. */
static const struct { int32_t win, linux_errno; } net_win_errnos[] = {
    { WSAEINTR, 4 }, { WSAEBADF, 9 }, { WSAEACCES, 13 }, { WSAEFAULT, 14 },
    { WSAEINVAL, 22 }, { WSAEMFILE, 24 }, { WSAEWOULDBLOCK, 11 },
    { WSAEINPROGRESS, 115 }, { WSAEALREADY, 114 }, { WSAENOTSOCK, 88 },
    { WSAEDESTADDRREQ, 89 }, { WSAEMSGSIZE, 90 }, { WSAEPROTOTYPE, 91 },
    { WSAENOPROTOOPT, 92 }, { WSAEPROTONOSUPPORT, 93 }, { WSAESOCKTNOSUPPORT, 94 },
    { WSAEOPNOTSUPP, 95 }, { WSAEPFNOSUPPORT, 96 }, { WSAEAFNOSUPPORT, 97 },
    { WSAEADDRINUSE, 98 }, { WSAEADDRNOTAVAIL, 99 }, { WSAENETDOWN, 100 },
    { WSAENETUNREACH, 101 }, { WSAENETRESET, 102 }, { WSAECONNABORTED, 103 },
    { WSAECONNRESET, 104 }, { WSAENOBUFS, 105 }, { WSAEISCONN, 106 },
    { WSAENOTCONN, 107 }, { WSAESHUTDOWN, 32 }, { WSAETOOMANYREFS, 109 },
    { WSAETIMEDOUT, 110 }, { WSAECONNREFUSED, 111 }, { WSAELOOP, 40 },
    { WSAENAMETOOLONG, 36 }, { WSAEHOSTDOWN, 112 }, { WSAEHOSTUNREACH, 113 },
    { WSAENOTEMPTY, 39 }, { WSAEUSERS, 87 }, { WSAEDQUOT, 122 }, { WSAESTALE, 116 },
    { WSAEREMOTE, 66 }, { WSAECANCELLED, 125 }, { WSA_OPERATION_ABORTED, 125 },
    { WSA_NOT_ENOUGH_MEMORY, 12 }, { ERROR_OUTOFMEMORY, 12 },
    { ERROR_TOO_MANY_OPEN_FILES, 24 }, { ERROR_INVALID_HANDLE, 9 },
    { ERROR_ACCESS_DENIED, 13 }, { ERROR_FILE_NOT_FOUND, 2 },
    { ERROR_PATH_NOT_FOUND, 2 }, { ERROR_INVALID_NAME, 2 }, { ERROR_SHARING_VIOLATION, 13 }, { ERROR_INVALID_PARAMETER, 22 },
    { ERROR_NOT_SUPPORTED, 95 }, { ERROR_NETNAME_DELETED, 104 },
    { ERROR_CONNECTION_ABORTED, 103 }, { ERROR_CONNECTION_REFUSED, 111 },
    { ERROR_BROKEN_PIPE, 32 }, { ERROR_NO_DATA, 32 }, { ERROR_CALL_NOT_IMPLEMENTED, 38 },
};
#define NET_WIN_ERRNO_COUNT (int)(sizeof net_win_errnos / sizeof net_win_errnos[0])
/* A Windows error with no Linux number becomes this plus its own, clear of
   Linux's, as in shim/kqueue.c. */
#define NET_UNMAPPED 1000

/* The Linux errno for a Winsock or Win32 error. */
int32_t net_win_err(int err) {
    for (int i = 0; i < NET_WIN_ERRNO_COUNT; i++)
        if (net_win_errnos[i].win == err) return net_win_errnos[i].linux_errno;
    return NET_UNMAPPED + err;
}

/* glibc's texts for the Linux codes net_win_err gives, so that sys::report
   prints what it prints on Linux. */
static const struct { int32_t code; const char *text; } net_texts[] = {
    { 4, "Interrupted system call" }, { 9, "Bad file descriptor" },
    { 11, "Resource temporarily unavailable" }, { 12, "Cannot allocate memory" },
    { 13, "Permission denied" }, { 14, "Bad address" }, { 22, "Invalid argument" },
    { 23, "Too many open files in system" }, { 24, "Too many open files" },
    { 32, "Broken pipe" }, { 36, "File name too long" }, { 38, "Function not implemented" },
    { 39, "Directory not empty" }, { 40, "Too many levels of symbolic links" },
    { 66, "Object is remote" }, { 87, "Too many users" },
    { 88, "Socket operation on non-socket" }, { 89, "Destination address required" },
    { 90, "Message too long" }, { 91, "Protocol wrong type for socket" },
    { 92, "Protocol not available" }, { 93, "Protocol not supported" },
    { 94, "Socket type not supported" }, { 95, "Operation not supported" },
    { 96, "Protocol family not supported" },
    { 97, "Address family not supported by protocol" }, { 98, "Address already in use" },
    { 99, "Cannot assign requested address" }, { 100, "Network is down" },
    { 101, "Network is unreachable" }, { 102, "Network dropped connection on reset" },
    { 103, "Software caused connection abort" }, { 104, "Connection reset by peer" },
    { 105, "No buffer space available" }, { 106, "Transport endpoint is already connected" },
    { 107, "Transport endpoint is not connected" },
    { 108, "Cannot send after transport endpoint shutdown" },
    { 109, "Too many references: cannot splice" }, { 110, "Connection timed out" },
    { 111, "Connection refused" }, { 112, "Host is down" }, { 113, "No route to host" },
    { 114, "Operation already in progress" }, { 115, "Operation now in progress" },
    { 116, "Stale file handle" }, { 122, "Disk quota exceeded" },
    { 125, "Operation canceled" },
};
#define NET_TEXT_COUNT (int)(sizeof net_texts / sizeof net_texts[0])

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

/* src/sys.goose spells SHUT_WR out as Linux's 1, which is SD_SEND. */
_Static_assert(SD_SEND == 1, "shutdown's how differs from src/sys.goose");

#define NET_ENOSYS 38

static INIT_ONCE net_wsa_once = INIT_ONCE_STATIC_INIT;
static int net_wsa_error;

static BOOL CALLBACK net_wsa_start(PINIT_ONCE once, PVOID arg, PVOID *ctx) {
    (void)once, (void)arg, (void)ctx;
    WSADATA wsa;
    net_wsa_error = WSAStartup(MAKEWORD(2, 2), &wsa);
    return TRUE;
}

/* Starts Winsock once per process: 0, or -code if it failed. */
int32_t net_win_init(void) {
    InitOnceExecuteOnce(&net_wsa_once, net_wsa_start, NULL, NULL);
    return net_wsa_error ? -net_win_err(net_wsa_error) : 0;
}

static SOCKET net_socket(int32_t fd) { return (SOCKET)(intptr_t)fd; }

/* The socket address net_listen's addr and port name, into ss: an
   IPv4-mapped address as IPv4, another 16 bytes as IPv6, or none as
   127.0.0.1. Windows Defender Firewall asks the user whether to allow each
   new program that listens on another address, so the default is loopback,
   where the tests run. Returns 0, or a Winsock error. */
static int net_sockaddr(net_bytes addr, int32_t port, struct sockaddr_storage *ss, int *len) {
    static const uint8_t mapped[12] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    memset(ss, 0, sizeof *ss);
    if (addr.len == 0 || (addr.len == 16 && memcmp(addr.data, mapped, 12) == 0)) {
        struct sockaddr_in *a = (struct sockaddr_in *)ss;
        a->sin_family = AF_INET;
        a->sin_port = htons((uint16_t)port);
        if (addr.len) memcpy(&a->sin_addr, addr.data + 12, 4);
        else a->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        *len = (int)sizeof *a;
        return 0;
    }
    if (addr.len != 16) return WSAEINVAL;
    struct sockaddr_in6 *a = (struct sockaddr_in6 *)ss;
    a->sin6_family = AF_INET6;
    a->sin6_port = htons((uint16_t)port);
    memcpy(&a->sin6_addr, addr.data, 16);
    *len = (int)sizeof *a;
    return 0;
}

/* A TCP listener on ss, which takes IPv4 clients too when it's IPv6, unless
   NET_V6ONLY. SO_EXCLUSIVEADDRUSE keeps a second server from binding the
   port, as Linux refuses it without SO_REUSEPORT; Windows' SO_REUSEADDR
   would let it take the port over. */
static int32_t net_open_listener(struct sockaddr_storage *ss, int len, int32_t backlog, int32_t flags) {
    SOCKET s = WSASocketW(ss->ss_family, SOCK_STREAM, IPPROTO_TCP, NULL, 0,
                          WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
    if (s == INVALID_SOCKET) return -net_win_err(WSAGetLastError());
    BOOL one = TRUE;
    DWORD v6only = (flags & NET_V6ONLY) != 0;
    u_long nb = (flags & NET_NONBLOCK) != 0;
    /* A backlog above 200 needs SOMAXCONN_HINT; a plain one is cut to 200.
       The hint raises anything below 200 to 200, so a smaller one stays plain. */
    if (setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&one, sizeof one) ||
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof one) ||
        (ss->ss_family == AF_INET6 &&
         setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, (const char *)&v6only, sizeof v6only)) ||
        ioctlsocket(s, FIONBIO, &nb) ||
        bind(s, (struct sockaddr *)ss, len) ||
        listen(s, backlog > 200 ? SOMAXCONN_HINT(backlog) : backlog)) {
        int err = WSAGetLastError();
        closesocket(s);
        return -net_win_err(err);
    }
    return (int32_t)s;
}

/* Windows has no SO_REUSEPORT, so the workers share one listener per port.
   Each worker's completion loop keeps an AcceptEx posted on it, and Windows
   hands each connection to one of them (shim/iocp.c). This table is the only
   state the shim keeps between calls. */
#define NET_MAX_SHARED 16
static SRWLOCK net_shared_lock = SRWLOCK_INIT;
static struct { struct sockaddr_storage addr; int len; int32_t fd, refs; } net_shared[NET_MAX_SHARED];
static int net_shared_count;

/* A listener where addr, port, and flags say (src/sys.goose); no Unix
   socket, which AcceptEx doesn't take. With NET_REUSEPORT, every call on an
   address and port returns the same listener, which the callers share:
   net_close closes it after the last caller closes it. */
int32_t net_listen(net_bytes addr, int32_t port, int32_t backlog, int32_t flags) {
    int32_t r = net_win_init();
    if (r < 0) return r;
    if (flags & NET_UNIX) return -net_win_err(WSAEAFNOSUPPORT);
    struct sockaddr_storage ss;
    int len;
    int err = net_sockaddr(addr, port, &ss, &len);
    if (err) return -net_win_err(err);
    if (!(flags & NET_REUSEPORT)) return net_open_listener(&ss, len, backlog, flags);
    AcquireSRWLockExclusive(&net_shared_lock);
    int i = 0;
    while (i < net_shared_count &&
           (net_shared[i].len != len || memcmp(&net_shared[i].addr, &ss, (size_t)len) != 0)) i++;
    if (i < net_shared_count) {
        r = net_shared[i].fd;
        net_shared[i].refs++;
    } else if (net_shared_count == NET_MAX_SHARED) {
        r = -net_win_err(WSAENOBUFS);
    } else {
        r = net_open_listener(&ss, len, backlog, flags);
        if (r >= 0) {
            net_shared[net_shared_count].addr = ss;
            net_shared[net_shared_count].len = len;
            net_shared[net_shared_count].fd = r;
            net_shared[net_shared_count].refs = 1;
            net_shared_count++;
        }
    }
    ReleaseSRWLockExclusive(&net_shared_lock);
    return r;
}

/* An accepted socket inherits TCP_NODELAY and the blocking mode from the
   listener; the mode asked for is set on it. */
int32_t net_accept(int32_t fd, int32_t flags) {
    SOCKET s = accept(net_socket(fd), NULL, NULL);
    if (s == INVALID_SOCKET) return -net_win_err(WSAGetLastError());
    u_long nb = (flags & NET_NONBLOCK) != 0;
    if (ioctlsocket(s, FIONBIO, &nb)) {
        int err = WSAGetLastError();
        closesocket(s);
        return -net_win_err(err);
    }
    return (int32_t)s;
}

int64_t net_recv(int32_t fd, net_bytes buf) {
    int n = buf.len > INT_MAX ? INT_MAX : (int)buf.len;
    int r = recv(net_socket(fd), (char *)buf.data, n, 0);
    return r == SOCKET_ERROR ? -net_win_err(WSAGetLastError()) : r;
}

/* Windows raises no signal for a send to a closed connection. */
int64_t net_send(int32_t fd, net_bytes data) {
    int n = data.len > INT_MAX ? INT_MAX : (int)data.len;
    int r = send(net_socket(fd), (const char *)data.data, n, 0);
    return r == SOCKET_ERROR ? -net_win_err(WSAGetLastError()) : r;
}

int32_t net_shutdown(int32_t fd, int32_t how) {
    return shutdown(net_socket(fd), how) ? -net_win_err(WSAGetLastError()) : 0;
}

/* The peer of connected socket fd, as shim/net.c's: an accepted socket has
   one once SO_UPDATE_ACCEPT_CONTEXT ties it to its listener. */
int32_t net_peer(int32_t fd, net_bytes out) {
    SOCKADDR_STORAGE ss;
    int len = sizeof ss;
    if (out.len < 16) return -22;
    if (getpeername(net_socket(fd), (struct sockaddr *)&ss, &len))
        return -net_win_err(WSAGetLastError());
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
    return -97;
}

/* A shared listener stays open while another caller of net_listen holds it. */
int32_t net_close(int32_t fd) {
    AcquireSRWLockExclusive(&net_shared_lock);
    int i = 0;
    while (i < net_shared_count && net_shared[i].fd != fd) i++;
    int keep = i < net_shared_count && --net_shared[i].refs > 0;
    if (i < net_shared_count && !keep) net_shared[i] = net_shared[--net_shared_count];
    ReleaseSRWLockExclusive(&net_shared_lock);
    if (keep) return 0;
    return closesocket(net_socket(fd)) ? -net_win_err(WSAGetLastError()) : 0;
}

/* The local port of socket fd, as bound. */
int32_t net_port(int32_t fd) {
    SOCKADDR_STORAGE ss;
    int len = sizeof ss;
    if (getsockname(net_socket(fd), (struct sockaddr *)&ss, &len))
        return -net_win_err(WSAGetLastError());
    if (ss.ss_family == AF_INET) return ntohs(((struct sockaddr_in *)&ss)->sin_port);
    if (ss.ss_family == AF_INET6) return ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
    return -97;
}

/* UDP, for QUIC: not on Windows yet, where serve fails on an h3 listener. */
typedef struct { int32_t len; uint8_t addr[28]; } net_udp_peer;
typedef struct { net_udp_peer *data; int64_t len; } net_udp_peers;
typedef struct { int32_t *data; int64_t len; } net_i32s;

int32_t net_udp_open(net_bytes addr, int32_t port, int32_t flags) {
    (void)addr, (void)port, (void)flags;
    return -38;
}

int32_t net_udp_recv(int32_t fd, net_bytes buf, int32_t slot, net_i32s sizes, net_udp_peers peers) {
    (void)fd, (void)buf, (void)slot, (void)sizes, (void)peers;
    return -38;
}

int32_t net_udp_send(int32_t fd, net_bytes buf, net_i32s sizes, net_udp_peers peers, uint8_t gso) {
    (void)fd, (void)buf, (void)sizes, (void)peers, (void)gso;
    return -38;
}

/* A non-blocking socket connecting to what addr and port name, as shim/net.c's:
   no Unix socket (EAFNOSUPPORT), and no empty addr, which names no peer. */
int32_t net_connect(net_bytes addr, int32_t port, int32_t flags) {
    int32_t r = net_win_init();
    if (r < 0) return r;
    if (flags & NET_UNIX) return -97;
    if (addr.len == 0) return -22;
    struct sockaddr_storage ss;
    int len;
    int err = net_sockaddr(addr, port, &ss, &len);
    if (err) return -net_win_err(err);
    SOCKET s = WSASocketW(ss.ss_family, SOCK_STREAM, IPPROTO_TCP, NULL, 0,
                          WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
    if (s == INVALID_SOCKET) return -net_win_err(WSAGetLastError());
    BOOL one = TRUE;
    u_long nb = 1;
    if (setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof one) ||
        ioctlsocket(s, FIONBIO, &nb) ||
        (connect(s, (struct sockaddr *)&ss, len) && WSAGetLastError() != WSAEWOULDBLOCK)) {
        err = WSAGetLastError();
        closesocket(s);
        return -net_win_err(err);
    }
    return (int32_t)s;
}

/* The addresses host names, as shim/net.c's net_resolve gives them:
   -ENOENT, -EAGAIN, or -EINVAL from Winsock's own codes for those cases. */
int32_t net_resolve(net_bytes host, net_bytes out) {
    int32_t r = net_win_init();
    if (r < 0) return r;
    char name[256];
    if (host.len <= 0 || host.len >= (int64_t)sizeof name || memchr(host.data, 0, (size_t)host.len))
        return -22;
    memcpy(name, host.data, (size_t)host.len);
    name[host.len] = 0;
    struct addrinfo hints = { 0 };
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_ADDRCONFIG;
    struct addrinfo *list;
    int err = getaddrinfo(name, NULL, &hints, &list);
    if (err == WSATRY_AGAIN || err == WSANO_RECOVERY) return -11;
    if (err == WSAHOST_NOT_FOUND || err == WSANO_DATA) return -2;
    if (err) return -net_win_err(err);
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
    return n ? n : -2;
}

/* How net_connect's connect on fd ended, as shim/net.c's: 0, -EINPROGRESS,
   or its error, which SO_ERROR gives. */
int32_t net_connected(int32_t fd) {
    SOCKET s = net_socket(fd);
    int err = 0, len = sizeof err;
    if (getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&err, &len)) return -net_win_err(WSAGetLastError());
    if (err) return -net_win_err(err);
    SOCKADDR_STORAGE ss;
    len = sizeof ss;
    if (getpeername(s, (struct sockaddr *)&ss, &len) == 0) return 0;
    err = WSAGetLastError();
    if (err != WSAENOTCONN) return -net_win_err(err);
    WSAPOLLFD p = { .fd = s, .events = POLLWRNORM };
    return WSAPoll(&p, 1, 0) == 0 ? -115 : -107;
}

/* Waits up to ms (-1: no limit) for fd to be ready for events, epoll's IN
   (1) and OUT (4) bits, as shim/net.c's. Returns those it is ready for, with
   ERR (8) and HUP (16), or 0 at the time limit. */
int32_t net_poll(int32_t fd, uint32_t events, int32_t ms) {
    WSAPOLLFD p = { .fd = net_socket(fd),
                    .events = (SHORT)((events & 1 ? POLLRDNORM : 0) | (events & 4 ? POLLWRNORM : 0)) };
    int n = WSAPoll(&p, 1, ms);
    if (n == SOCKET_ERROR) return -net_win_err(WSAGetLastError());
    if (n == 0) return 0;
    return (p.revents & POLLRDNORM ? 1 : 0) | (p.revents & POLLWRNORM ? 4 : 0) |
           (p.revents & (POLLERR | POLLNVAL) ? 8 : 0) | (p.revents & POLLHUP ? 16 : 0);
}

/* Windows has no epoll loop, so no socket is watched on one: http::serve's
   completion loop doesn't watch outbound sockets yet. */
void net_loop_bind(int32_t ep) { (void)ep; }

int32_t net_arm(int32_t fd, uint32_t events, uint64_t tag) {
    (void)fd, (void)events, (void)tag;
    return -NET_ENOSYS;
}

void net_disarm(uint64_t tag) { (void)tag; }

int32_t net_epoll_create(void) { return -NET_ENOSYS; }

int32_t net_epoll_ctl(int32_t ep, int32_t op, int32_t fd, uint32_t events, uint64_t tag) {
    (void)ep, (void)op, (void)fd, (void)events, (void)tag;
    return -NET_ENOSYS;
}

int32_t net_epoll_wait(int32_t ep, net_events out, int32_t timeout_ms) {
    (void)ep, (void)out, (void)timeout_ms;
    return -NET_ENOSYS;
}

/* GetTickCount64 advances with the timer interrupt, every 15.6 ms by
   default, without reading the hardware counter, as Linux's coarse clocks
   do. std's clock_ns and time_ns are the precise ones. */
int64_t net_clock_ms(void) {
    return (int64_t)GetTickCount64();
}

/* FILETIME counts 100 ns intervals since 1601. */
int64_t net_time_s(void) {
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    uint64_t t = (uint64_t)ft.dwHighDateTime << 32 | ft.dwLowDateTime;
    return (int64_t)((t - 116444736000000000ull) / 10000000ull);
}

void net_worker_start(void) {}

int32_t net_default_workers(void) {
    return 0;
}

/* dst.len bytes of src into dst; net_copy has checked the lengths. */
void net_move(net_bytes dst, net_bytes src) {
    if (dst.len > 0) memmove(dst.data, src.data, (size_t)dst.len);
}

/* Writes the text for an error code into out, cut to fit, and returns its
   length: glibc's text for a Linux code, and Windows' own, in UTF-8, for an
   error with no Linux number. */
int64_t net_strerror(int64_t err, net_bytes out) {
    char buf[512];
    const char *s = NULL;
    for (int i = 0; i < NET_TEXT_COUNT; i++)
        if (net_texts[i].code == err) s = net_texts[i].text;
    if (!s) {
        WCHAR w[256];
        DWORD n = err >= NET_UNMAPPED
            ? FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL,
                             (DWORD)(err - NET_UNMAPPED), 0, w, 256, NULL)
            : 0;
        while (n > 0 && (w[n - 1] == L'\r' || w[n - 1] == L'\n' || w[n - 1] == L' ' ||
                         w[n - 1] == L'.'))
            n--;
        int k = n ? WideCharToMultiByte(CP_UTF8, 0, w, (int)n, buf, sizeof buf - 1, NULL, NULL) : 0;
        if (k <= 0) k = snprintf(buf, sizeof buf, "Unknown error %d", (int)err);
        buf[k] = 0;
        s = buf;
    }
    size_t n = strlen(s);
    if (n > (size_t)out.len) n = (size_t)out.len;
    memcpy(out.data, s, n);
    return (int64_t)n;
}

/* How many times net_stop has run in the process. A loop reads it at its
   start, and stops once it has moved on. A counter, and not a flag, so that a
   loop started after a stop runs. Each loop's waker gets a completion packet
   (shim/mail.c, shim/iocp.c), which makes the stop immediate. */
static volatile LONG64 net_stop_count;

void net_stop_wake_all(void);

void net_stop(void) {
    InterlockedIncrement64(&net_stop_count);
    net_stop_wake_all();
}

int64_t net_stops(void) {
    return InterlockedCompareExchange64(&net_stop_count, 0, 0);
}

/* Windows calls this on a thread of its own, not in a signal's context. */
static BOOL WINAPI net_on_console(DWORD event) {
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT) return FALSE;
    net_stop();
    return TRUE;
}

/* Makes Ctrl+C and Ctrl+Break, Windows' console signals, call net_stop
   instead of ending the process. */
int32_t net_stop_on_signals(void) {
    return SetConsoleCtrlHandler(net_on_console, TRUE) ? 0 : -net_win_err((int)GetLastError());
}

/* Opens path, UTF-8, for reading, as a HANDLE: a file on disk, else -EISDIR
   for a directory and -EINVAL for anything else. Other programs may read,
   write, rename, and delete it meanwhile, as on POSIX. Writes its size to
   info[0] and its modification time, in seconds since the epoch, to info[1],
   and, where info has room, that time's nanoseconds to info[2] and the file
   ID to info[3]. */
int64_t net_file_open(net_bytes path, net_i64s info) {
    WCHAR w[4096];
    if (path.len >= 4096 || memchr(path.data, 0, (size_t)path.len)) return -2;
    int n = path.len == 0 ? 0 : MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)path.data,
                                                    (int)path.len, w, 4095);
    if (n == 0) return -2;
    w[n] = 0;
    DWORD attrs = GetFileAttributesW(w);
    if (attrs == INVALID_FILE_ATTRIBUTES) return -net_win_err(GetLastError());
    if (attrs & FILE_ATTRIBUTE_DIRECTORY) return -21;
    HANDLE h = CreateFileW(w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return -net_win_err(GetLastError());
    BY_HANDLE_FILE_INFORMATION fi;
    if (GetFileType(h) != FILE_TYPE_DISK || !GetFileInformationByHandle(h, &fi)) {
        CloseHandle(h);
        return -22;
    }
    uint64_t t = (uint64_t)fi.ftLastWriteTime.dwHighDateTime << 32 | fi.ftLastWriteTime.dwLowDateTime;
    if (info.len >= 2) {
        info.data[0] = (int64_t)((uint64_t)fi.nFileSizeHigh << 32 | fi.nFileSizeLow);
        info.data[1] = (int64_t)((t - 116444736000000000ull) / 10000000ull);
    }
    if (info.len >= 4) {
        info.data[2] = (int64_t)((t - 116444736000000000ull) % 10000000ull * 100);
        info.data[3] = (int64_t)((uint64_t)fi.nFileIndexHigh << 32 | fi.nFileIndexLow);
    }
    return (int64_t)(intptr_t)h;
}

/* What net_file_open would answer for path: 0 and info, or -code. The file
   ID that info[3] holds needs a handle, so this opens the file too. */
int64_t net_file_stat(net_bytes path, net_i64s info) {
    int64_t h = net_file_open(path, info);
    if (h < 0) return h;
    CloseHandle((HANDLE)(intptr_t)h);
    return 0;
}

/* Reads buf.len bytes of the file at off into buf, fewer only at the file's
   end. Returns how many, or -code. The handle isn't opened for overlapped
   I/O, so the OVERLAPPED only gives the offset, and the read is synchronous. */
int64_t net_file_read(int64_t fd, net_bytes buf, int64_t off) {
    int64_t got = 0;
    while (got < buf.len) {
        OVERLAPPED ov;
        memset(&ov, 0, sizeof ov);
        uint64_t at = (uint64_t)(off + got);
        ov.Offset = (DWORD)at;
        ov.OffsetHigh = (DWORD)(at >> 32);
        int64_t want = buf.len - got;
        DWORD n = 0;
        if (!ReadFile((HANDLE)(intptr_t)fd, buf.data + got, want > 1 << 30 ? 1 << 30 : (DWORD)want, &n, &ov)) {
            DWORD e = GetLastError();
            if (e == ERROR_HANDLE_EOF) break;
            return -net_win_err(e);
        }
        if (n == 0) break;
        got += n;
    }
    return got;
}

void net_file_close(int64_t fd) {
    CloseHandle((HANDLE)(intptr_t)fd);
}

/* There's no epoll loop on Windows to call it. */
int64_t net_sendfile(int32_t s, int64_t fd, int64_t off, int64_t len) {
    (void)s, (void)fd, (void)off, (void)len;
    return -NET_ENOSYS;
}
