#include <stdint.h>

int64_t silica_legacy_math_add_int64(int64_t left, int64_t right) {
    return left + right;
}

/* Recurses n deep on the caller's stack (the actor's runtime-managed stack when called from a
 * spawn_dangerous worker), returning the depth reached. volatile keeps the frames real. */
int64_t silica_legacy_math_recurse(int64_t n) {
    volatile int64_t pad[8];
    pad[0] = n;
    if (n <= 0) {
        return 0;
    }
    return silica_legacy_math_recurse(n - 1) + 1 + (pad[0] - n);
}

/* Chunk 15 phase 7 (FFI retention). silica_retain_keep keeps the pointer past the call: its sidecar
 * entry declares retains: [data_ptr], so the Silica caller must hand it an alloc_buf_retained buffer
 * (a node of the dangerous actor's state area, which never moves while the actor is pinned).
 * silica_retain_byte reads the kept bytes on a later dispatch. silica_call_only_sum is the contrasting
 * wrapper: it reads its buffer during the call only and keeps nothing. */
static const uint8_t *silica_retain_kept = 0;
static uint64_t silica_retain_kept_len = 0;

int64_t silica_retain_keep(const uint8_t *data, uint64_t len) {
    silica_retain_kept = data;
    silica_retain_kept_len = len;
    return (int64_t)len;
}

int64_t silica_retain_byte(int64_t index) {
    if (silica_retain_kept == 0 || index < 0 || (uint64_t)index >= silica_retain_kept_len) {
        return -1;
    }
    return (int64_t)silica_retain_kept[index];
}

int64_t silica_call_only_sum(const uint8_t *data, uint64_t len) {
    int64_t sum = 0;
    for (uint64_t i = 0; i < len; i++) {
        sum += (int64_t)data[i];
    }
    return sum;
}
