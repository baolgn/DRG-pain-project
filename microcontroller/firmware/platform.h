/* describe the local machine platform and its complete trap frame. */
#ifndef DRG5_PLATFORM_H
#define DRG5_PLATFORM_H
#include <stdint.h>
#include <stddef.h>

#define MMIO32(address) (*(volatile uint32_t *)(uintptr_t)(address))
#define OUTPUT_RESULT 0x40000000u
#define OUTPUT_DATA 0x40000004u
#define EVENT_INJECT 0x40000008u
#define TIMER_BASE 0x40001000u
#define MSTATUS_MIE 8u
#define MIE_MSIE 8u
#define MIE_MTIE 128u
#define MIE_MEIE 2048u

/* offsets match trap.S; the final padding retains 16-byte stack alignment. */
struct trap_frame {
    uint32_t gpr[32];
    uint32_t mepc, mstatus, mcause, mtval;
    uint32_t padding[4];
};
_Static_assert(sizeof(struct trap_frame) == 160, "trap frame size");
_Static_assert(offsetof(struct trap_frame, mepc) == 128, "trap PC offset");
_Static_assert(sizeof(void *) == 4 && sizeof(long) == 4, "ILP32 required");

extern volatile uint32_t boot_initialized, fw_phase, fw_checks, fw_signature;
extern volatile uint32_t sw_count, timer_count, ext_count, pin_count, exception_count;
extern volatile uint32_t stack_low_water;
extern unsigned char __stack_guard[], __stack_bottom[], __stack_top[];
extern void trap_entry(void);
void trap_dispatch(struct trap_frame *frame);
void firmware_finish(uint32_t ok, uint32_t reason) __attribute__((noreturn));
void output_char(char value);
void *memcpy(void *destination, const void *source, size_t count);
void *memset(void *destination, int value, size_t count);
int memcmp(const void *left, const void *right, size_t count);
uint32_t runtime_udiv(uint32_t dividend, uint32_t divisor);
int32_t __divsi3(int32_t dividend, int32_t divisor);
int32_t __modsi3(int32_t dividend, int32_t divisor);
uint32_t __umodsi3(uint32_t dividend, uint32_t divisor);
uint32_t __mulsi3(uint32_t left, uint32_t right);
int irq_register_probe(void);

/* each CSR operation uses the implemented machine profile and explicit ordering. */
static inline void irq_disable(void) {
    __asm__ volatile ("csrci mstatus, 8" ::: "memory");
}

/* enable pending interrupts only after their handlers and state are ready. */
static inline void irq_enable(void) {
    __asm__ volatile ("csrsi mstatus, 8" ::: "memory");
}

/* read a rollover-safe timer value without a hardware snapshot latch. */
static inline uint64_t timer_now(void) {
    uint32_t high, low, again;
    /* retry when the low half rolled over between the high-half reads. */
    do {
        high = MMIO32(TIMER_BASE + 4);
        low = MMIO32(TIMER_BASE);
        again = MMIO32(TIMER_BASE + 4);
    } while (high != again);
    return ((uint64_t)high << 32) | low;
}

/* prevent a transient early match while updating the split comparator. */
static inline void timer_compare(uint64_t value) {
    MMIO32(TIMER_BASE + 8) = 0xffffffffu;
    MMIO32(TIMER_BASE + 12) = (uint32_t)(value >> 32);
    MMIO32(TIMER_BASE + 8) = (uint32_t)value;
}
#endif
