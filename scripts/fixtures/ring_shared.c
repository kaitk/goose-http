/* A ring's gathered send (ur_send_shared), on the emulation and, where
   there is one, on io_uring: inline bytes and a blob's ranges arrive in
   order through short sends, the completion counts them all, and the ring
   releases the ranges' references once the send ends, or once a close drops
   the sends queued and cancels the one in flight. Built with shim/uring.c,
   shim/shared.c, shim/ring_epoll.c, shim/net.c, and shim/mail.c, and
   liburing. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef struct { uint8_t *data; int64_t len; } bytes;
typedef struct { uint64_t tag; int32_t res, buf; uint8_t more, send; } __attribute__((packed)) completion;
typedef struct { completion *data; int64_t len; } completions;

int64_t ur_create(int32_t entries, int32_t nbufs, int32_t buflen, int32_t flags);
int32_t ur_probe(void);
int32_t ur_send_shared(int64_t h, int32_t fd, uint64_t tag, bytes data);
int32_t ur_wait(int64_t h, completions out, int32_t timeout_ms);
void ur_close(int64_t h, int32_t fd, uint64_t recv);
void ur_destroy(int64_t h);
int64_t shared_put(bytes data, int64_t refs);
int32_t shared_retain(int64_t h, int64_t n);
int64_t shared_release(int64_t h);
int32_t shared_defer(int64_t h, int64_t from, int64_t to, int64_t at);
void shared_gather(uint8_t on);
int64_t shared_pending(void);

#define N (1 << 20)

static int64_t refs(int64_t b) {
    assert(shared_retain(b, 1) == 0);
    return shared_release(b);
}

static int64_t ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void run(int64_t h, const char *name) {
    static uint8_t data[N], want[N + 2], got[N + 2];
    for (int i = 0; i < N; i++) data[i] = (uint8_t)(i * 7 % 251);
    int64_t b = shared_put((bytes){ data, N }, 1);
    assert(b > 0);
    int sv[2], small = 4096;
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    assert(setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &small, sizeof small) == 0);
    /* As each ring's accepted sockets are: the emulation's non-blocking, for
       it sends until EAGAIN, and io_uring's blocking, for io_uring would end
       a send on a non-blocking one with EAGAIN rather than wait. */
    if (h & 1) assert(fcntl(sv[0], F_SETFL, O_NONBLOCK) == 0);

    /* "a", the first 1000 bytes, "b", the rest. */
    want[0] = 'a';
    memcpy(want + 1, data, 1000);
    want[1001] = 'b';
    memcpy(want + 1002, data + 1000, N - 1000);
    uint8_t wbuf[] = "ab";
    shared_gather(1);
    assert(shared_defer(b, 0, 1000, 1) == 1);
    assert(shared_defer(b, 1000, N, 2) == 1);
    assert(shared_pending() == N && refs(b) == 3);
    assert(ur_send_shared(h, sv[0], 7, (bytes){ wbuf, 2 }) == 0);
    assert(shared_pending() == 0 && refs(b) == 3);
    int64_t n = 0, deadline = ms() + 10000;
    int done = 0;
    while (!done || n < N + 2) {
        assert(ms() < deadline);
        completion c[4];
        int32_t k = ur_wait(h, (completions){ c, 4 }, 1);
        for (int32_t i = 0; i < k; i++) {
            assert(c[i].tag == 7 && c[i].send && !done);
            assert(c[i].res == N + 2);
            done = 1;
        }
        ssize_t r;
        while (n < N + 2 && (r = recv(sv[1], got + n, (size_t)(N + 2 - n), MSG_DONTWAIT)) > 0) n += r;
    }
    assert(memcmp(got, want, N + 2) == 0);
    assert(refs(b) == 1);

    /* Two sends the peer doesn't read: the first starts and stalls, the
       second waits behind it. A close releases both. */
    assert(shared_defer(b, 0, N, 0) == 1);
    assert(ur_send_shared(h, sv[0], 8, (bytes){ wbuf, 0 }) == 0);
    assert(shared_defer(b, 0, N, 0) == 1);
    assert(ur_send_shared(h, sv[0], 9, (bytes){ wbuf, 0 }) == 0);
    shared_gather(0);
    assert(refs(b) == 3);
    completion c[4];
    assert(ur_wait(h, (completions){ c, 4 }, 50) == 0);
    ur_close(h, sv[0], 0);
    deadline = ms() + 5000;
    while (refs(b) > 1) {
        assert(ms() < deadline);
        int32_t k = ur_wait(h, (completions){ c, 4 }, 10);
        for (int32_t i = 0; i < k; i++) assert(c[i].tag == 8 && c[i].send);
    }
    assert(shared_release(b) == 0);
    close(sv[1]);
    printf("%s: gathered sends arrive in order, and release their ranges\n", name);
}

int main(void) {
    /* A ring that loses bytes can block in a wait: fail, rather than hang. */
    alarm(60);
    int64_t h = ur_create(64, 8, 4096, 1);
    assert(h > 0);
    run(h, "emulated ring");
    ur_destroy(h);
    int32_t e = ur_probe();
    if (e < 0) {
        printf("io_uring skipped: no io_uring here (%s)\n", strerror(-e));
        return 0;
    }
    h = ur_create(64, 8, 4096, 2);
    assert(h > 0 && !(h & 1));
    run(h, "io_uring");
    ur_destroy(h);
}
