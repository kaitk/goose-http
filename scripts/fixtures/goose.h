/* What shim/shared.c takes from the goose.h that goose build generates, for
   the C fixtures that build it without Goose: they never append to a Goose
   builder. */
#include <stdint.h>
#include <stdlib.h>

typedef struct { void *p; } gs_rref;
static inline void gs_bld_append(gs_rref r, const void *d, int64_t n) {
    (void)r; (void)d; (void)n;
    abort();
}
