/* An inline send on a native io_uring ring reserves its completion before
   any byte goes out: a failed reservation sends nothing, and a successful
   one completes once. Built with shim/ring_epoll.c, shim/net.c, and
   shim/mail.c, and liburing. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

static int fail_realloc;
static void *test_realloc(void *p, size_t n) {
    if (fail_realloc) {
        fail_realloc = 0;
        return NULL;
    }
    return realloc(p, n);
}
#define realloc test_realloc
#include "../../shim/uring.c"
#undef realloc

/* Waits for one completion, tag's send, and returns its result. */
static int32_t complete(int64_t h, uint64_t tag) {
    ur_completion c[4];
    int32_t n = ur_wait(h, (ur_completions){c, 4}, 1000, 0);
    assert(n == 1 && c[0].tag == tag && c[0].send && !c[0].more && c[0].buf == -1);
    return c[0].res;
}

static int64_t drain(int fd) {
    static unsigned char buf[1 << 16];
    int64_t got = 0;
    ssize_t r;
    while ((r = recv(fd, buf, sizeof buf, MSG_DONTWAIT)) > 0) got += r;
    assert(r < 0 && errno == EAGAIN);
    return got;
}

int main(void) {
    int32_t e = ur_probe();
    if (e < 0) {
        printf("skipped: no io_uring here (%s)\n", strerror(-e));
        return 0;
    }
    int sv[2];
    int big = 1 << 20;
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    assert(setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &big, sizeof big) == 0);
    int64_t h = ur_create(8, 8, 4096, UR_REQUIRE);
    assert(h > 0 && !UR_EMULATED(h));

    /* A small send, which queues, takes fd's record, so that the inline
       send's realloc is the slot's. */
    unsigned char small[] = "abc", data[UR_INLINE];
    memset(data, 'a', sizeof data);
    assert(ur_send(h, sv[0], 1, (ur_bytes){small, 3}) == 0);
    assert(complete(h, 1) == 3);
    assert(drain(sv[1]) == 3);
    assert(((struct ur *)(intptr_t)h)->capsent == 0);

    fail_realloc = 1;
    assert(ur_send(h, sv[0], 2, (ur_bytes){data, sizeof data}) == -ENOMEM);
    assert(!fail_realloc && drain(sv[1]) == 0);
    ur_completion c;
    assert(ur_wait(h, (ur_completions){&c, 1}, 0, 0) == 0);

    assert(ur_send(h, sv[0], 3, (ur_bytes){data, sizeof data}) == 0);
    assert(drain(sv[1]) == (int64_t)sizeof data);
    assert(complete(h, 3) == (int32_t)sizeof data);
    assert(ur_wait(h, (ur_completions){&c, 1}, 0, 0) == 0);

    ur_destroy(h);
    puts("uring inline send reserves its completion before sending");
}
