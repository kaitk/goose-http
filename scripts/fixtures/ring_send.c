/* Deterministic socket outcomes check ownership and deferred completions. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t copied;
static int fail_alloc;
static void *count_copy(void *dst, const void *src, size_t n) {
    copied += n;
    return memcpy(dst, src, n);
}
static void *test_malloc(size_t n) {
    if (fail_alloc) { fail_alloc = 0; return NULL; }
    return malloc(n);
}
#define memcpy count_copy
#define malloc test_malloc
#include "../../shim/ring_epoll.c"
#undef malloc
#undef memcpy

static unsigned char received[1024];
static size_t received_len;
static int64_t outcomes[16];
static int outcome_count, outcome_at, calls, writable_edge, file_closed;
static uint32_t watching;

int32_t net_accept(int32_t fd, int32_t flags) { return -RP_EAGAIN; }
int64_t net_recv(int32_t fd, rp_bytes buf) { return -RP_EAGAIN; }
int64_t net_send(int32_t fd, rp_bytes data) {
    calls++;
    int64_t n = outcome_at < outcome_count ? outcomes[outcome_at++] : data.len;
    if (n > data.len) n = data.len;
    if (n > 0) {
        assert(received_len + n <= sizeof received);
        memcpy(received + received_len, data.data, (size_t)n);
        received_len += (size_t)n;
    }
    return n;
}
int32_t net_close(int32_t fd) { return 0; }
int32_t net_epoll_create(void) { return 100; }
int32_t net_epoll_ctl(int32_t ep, int32_t op, int32_t fd, uint32_t events, uint64_t tag) {
    watching = events;
    return 0;
}
int32_t net_epoll_wait(int32_t ep, rp_events out, int32_t timeout_ms) {
    if (writable_edge && (watching & RP_OUT)) {
        writable_edge = 0;
        out.data[0] = (rp_event){RP_OUT, 7};
        return 1;
    }
    return 0;
}
int64_t net_waker(int32_t ep, uint64_t tag) { return -RP_ENOSYS; }
int64_t net_sendfile(int32_t s, int64_t fd, int64_t off, int64_t len) {
    unsigned char bytes[] = "FILE";
    assert(off + len <= 4);
    return net_send(s, (rp_bytes){bytes + off, len});
}
void net_file_close(int64_t fd) { file_closed++; }

static int64_t setup(void) {
    received_len = copied = 0;
    outcome_count = outcome_at = calls = writable_edge = file_closed = 0;
    watching = 0;
    int64_t h = RP(create)(8, 2, 64, 0);
    assert(h > 0);
    return h;
}
static void expect(rp_completion c, uint64_t tag, int32_t res) {
    assert(c.tag == tag && c.res == res && c.buf == -1 && !c.more && c.send);
}
static void full_and_ordered(void) {
    int64_t h = setup();
    unsigned char a[] = "abc", b[] = "def";
    rp_completion c[2] = {0};
    assert(RP(send)(h, 7, 11, (rp_bytes){a, 3}) == 0);
    assert(copied == 0 && received_len == 3 && calls == 1);
    assert(RP(send)(h, 7, 12, (rp_bytes){b, 3}) == 0);
    assert(copied == 3 && calls == 1);
    memset(a, 'x', 3); memset(b, 'x', 3);
    /* A one-slot result must preserve overflow completion order. */
    assert(RP(wait)(h, (rp_completions){c, 1}, 0) == 1);
    expect(c[0], 11, 3);
    assert(received_len == 6 && memcmp(received, "abcdef", 6) == 0);
    assert(RP(wait)(h, (rp_completions){c, 1}, 0) == 1);
    expect(c[0], 12, 3);
    assert(RP(wait)(h, (rp_completions){c, 1}, 0) == 0);
    RP(destroy)(h);
}
static void stalled_tail(int64_t first) {
    int64_t h = setup();
    unsigned char a[] = "abcdef", b[] = "ghi";
    rp_completion c[2];
    outcomes[0] = first;
    outcomes[1] = -RP_EAGAIN;
    outcome_count = first > 0 ? 2 : 1;
    assert(RP(send)(h, 7, 21, (rp_bytes){a, 6}) == 0);
    assert(copied == (size_t)(first > 0 ? 6 - first : 6));
    assert(RP(send)(h, 7, 22, (rp_bytes){b, 3}) == 0);
    assert(calls == 1);
    memset(a, 'x', 6); memset(b, 'x', 3);
    assert(RP(wait)(h, (rp_completions){c, 2}, 0) == 0);
    assert(watching & RP_OUT);
    writable_edge = 1;
    assert(RP(wait)(h, (rp_completions){c, 2}, 0) == 2);
    expect(c[0], 21, 6); expect(c[1], 22, 3);
    assert(received_len == 9 && memcmp(received, "abcdefghi", 9) == 0);
    assert(!(watching & RP_OUT));
    RP(destroy)(h);
}
static void errors_and_close(void) {
    int64_t h = setup();
    unsigned char a[] = "abc";
    rp_completion c;
    outcomes[0] = -RP_EINTR; outcome_count = 1;
    assert(RP(send)(h, 7, 31, (rp_bytes){a, 3}) == 0);
    assert(copied == 3);
    assert(RP(wait)(h, (rp_completions){&c, 1}, 0) == 1);
    expect(c, 31, 3);
    outcomes[1] = outcomes[2] = -32; outcome_count = 3;
    assert(RP(send)(h, 7, 32, (rp_bytes){a, 3}) == 0);
    assert(RP(wait)(h, (rp_completions){&c, 1}, 0) == 1);
    expect(c, 32, -32);
    assert(RP(send)(h, 7, 33, (rp_bytes){a, 3}) == 0);
    RP(close)(h, 7);
    assert(RP(wait)(h, (rp_completions){&c, 1}, 0) == 0);
    outcomes[3] = -RP_EAGAIN; outcome_count = 4;
    assert(RP(send)(h, 7, 34, (rp_bytes){a, 3}) == 0);
    RP(close)(h, 7);
    assert(RP(wait)(h, (rp_completions){&c, 1}, 0) == 0);
    RP(destroy)(h);
}
static void files_and_allocation(void) {
    int64_t h = setup();
    rp_completion c[2];
    unsigned char a[] = "end";
    fail_alloc = 1;
    assert(RP(send)(h, 7, 40, (rp_bytes){a, 3}) == -RP_ENOMEM);
    assert(calls == 0 && received_len == 0);
    assert(RP(send_file)(h, 7, 41, 101, 0, 4) == 0);
    assert(RP(send)(h, 7, 42, (rp_bytes){a, 3}) == 0);
    assert(calls == 0 && copied == 3);
    memset(a, 'x', 3);
    assert(RP(wait)(h, (rp_completions){c, 2}, 0) == 2);
    expect(c[0], 41, 4); expect(c[1], 42, 3);
    assert(received_len == 7 && memcmp(received, "FILEend", 7) == 0 && file_closed == 1);
    RP(destroy)(h);
}
int main(void) {
    full_and_ordered();
    stalled_tail(2);
    stalled_tail(-RP_EAGAIN);
    errors_and_close();
    files_and_allocation();
    puts("ring send ownership, ordering, backpressure, and completion tests passed");
}
