/* What shim/shared.c takes from the goose.h that goose build generates, for
   the C fixtures that build it without Goose: they never append to a Goose
   builder. */
#include <stdint.h>
#include <stdlib.h>

typedef struct { uint8_t *top; } gs_stack;
#pragma pack(push, 1)
typedef struct { uint8_t *base; int64_t len; } gs_rhdr;
typedef struct { gs_rhdr *hdr; gs_stack *stk; } gs_rref;
#pragma pack(pop)
static inline void gs_bld_append(gs_rref r, const void *d, int64_t n) {
    (void)r; (void)d; (void)n;
    abort();
}
