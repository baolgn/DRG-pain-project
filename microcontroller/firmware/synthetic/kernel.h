/* admit one channel at sixteen-frame stride, with unsigned modulo-32 energy arithmetic. */
#ifndef DRG5_SYNTHETIC_KERNEL_H
#define DRG5_SYNTHETIC_KERNEL_H
#include <stdint.h>

/* these derived values do not replace or mutate the raw acquisition record. */
struct synthetic_result {
    uint32_t energy;
    uint32_t signature;
    uint32_t quotient;
};

/* generate signed eighteen-bit deterministic samples without signed overflow. */
static inline int32_t synthetic_sample(uint32_t epoch, uint32_t block, uint32_t frame, uint32_t channel) {
    uint32_t value = epoch * UINT32_C(0x9e3779b9) ^ block * UINT32_C(0x045d9f3b) ^
                     frame * UINT32_C(0x27d4eb2d) ^ channel * UINT32_C(0x165667b1);
    value ^= value >> 13;
    value *= UINT32_C(0x85ebca6b);
    value ^= value >> 16;
    return (int32_t)(value & UINT32_C(0x3ffff)) - 131072;
}

/* apply the three-tap second difference, then accumulate wrapped energy and a position signature. */
static inline struct synthetic_result synthetic_kernel(const int32_t samples[16], uint32_t divisor) {
    int32_t previous = 0, earlier = 0;
    /* every block starts with zeroed modulo-32 accumulators. */
    struct synthetic_result result = {0, 0, 0};
    /* signed intermediate limits are within plus or minus 524286; products explicitly wrap unsigned. */
    for (uint32_t index = 0; index < 16; ++index) {
        int32_t filtered = samples[index] - 2 * previous + earlier;
        uint32_t value = (uint32_t)filtered;
        result.energy += value * value;
        result.signature += value * (index + 1);
        earlier = previous;
        previous = samples[index];
    }
    result.quotient = divisor ? result.energy / divisor : UINT32_MAX;
    return result;
}
#endif
