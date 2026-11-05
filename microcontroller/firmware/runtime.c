/* compile the private freestanding runtime with the same ISA and ABI as callers. */
#include "platform.h"

/* copy bytes without alignment assumptions or compiler library substitution. */
void *memcpy(void *destination, const void *source, size_t count) {
    unsigned char *out = destination;
    const unsigned char *in = source;
    /* each destination byte is written exactly once. */
    for (size_t i = 0; i < count; ++i) {
        out[i] = in[i];
    }
    return destination;
}

/* initialize only the caller's requested byte range. */
void *memset(void *destination, int value, size_t count) {
    unsigned char *out = destination;
    /* conversion to byte matches the standard C interface. */
    for (size_t i = 0; i < count; ++i) {
        out[i] = (unsigned char)value;
    }
    return destination;
}

/* compare unsigned bytes without reading beyond the supplied objects. */
int memcmp(const void *left, const void *right, size_t count) {
    const unsigned char *a = left, *b = right;
    /* the first differing byte determines the result. */
    for (size_t i = 0; i < count; ++i) {
        /* equal prefixes require no further action. */
        if (a[i] != b[i]) {
            return (int)a[i] - (int)b[i];
        }
    }
    return 0;
}

/* restoring division avoids relying on hardware M in the I-only profile. */
static uint32_t divide(uint32_t numerator, uint32_t denominator, uint32_t *remainder) {
    uint32_t quotient = 0, residual = 0;
    /* a carried bit represents the 33rd remainder bit without 64-bit helpers. */
    for (unsigned bit = 32; bit != 0; --bit) {
        uint32_t carry = residual >> 31;
        residual = (residual << 1) | ((numerator >> (bit - 1)) & 1u);
        /* subtraction is valid when the widened remainder reaches the divisor. */
        if (carry || residual >= denominator) {
            residual -= denominator;
            quotient |= 1u << (bit - 1);
        }
    }
    *remainder = residual;
    return quotient;
}

/* this explicit library call keeps the software divider exercised in both builds. */
uint32_t runtime_udiv(uint32_t dividend, uint32_t divisor) {
    uint32_t remainder;
    return divide(dividend, divisor, &remainder);
}

/* the compiler's unsigned quotient helper follows architectural zero-divisor results. */
uint32_t __udivsi3(uint32_t dividend, uint32_t divisor) {
    return runtime_udiv(dividend, divisor);
}

/* retain the full dividend when the divisor is zero. */
uint32_t __umodsi3(uint32_t dividend, uint32_t divisor) {
    uint32_t remainder;
    (void)divide(dividend, divisor, &remainder);
    return remainder;
}

/* unsigned negation avoids undefined signed overflow at INT_MIN. */
int32_t __divsi3(int32_t dividend, int32_t divisor) {
    uint32_t a = (uint32_t)dividend, b = (uint32_t)divisor;
    uint32_t remainder;
    /* zero division has a fixed quotient independent of dividend sign. */
    if (b == 0) {
        return -1;
    }
    uint32_t quotient = divide(dividend < 0 ? 0u - a : a, divisor < 0 ? 0u - b : b, &remainder);
    return (int32_t)((dividend < 0) != (divisor < 0) ? 0u - quotient : quotient);
}

/* the remainder has the dividend's sign and truncation is toward zero. */
int32_t __modsi3(int32_t dividend, int32_t divisor) {
    uint32_t a = (uint32_t)dividend, b = (uint32_t)divisor;
    uint32_t remainder;
    (void)divide(dividend < 0 ? 0u - a : a, divisor < 0 ? 0u - b : b, &remainder);
    return (int32_t)(dividend < 0 ? 0u - remainder : remainder);
}

/* modular shift-and-add implements RV32 low multiplication without M. */
uint32_t __mulsi3(uint32_t left, uint32_t right) {
    uint32_t result = 0;
    /* unsigned wrap is intentional and matches the low 32 product bits. */
    while (right) {
        /* each set multiplier bit contributes its shifted multiplicand. */
        if (right & 1u) {
            result += left;
        }
        left <<= 1;
        right >>= 1;
    }
    return result;
}
