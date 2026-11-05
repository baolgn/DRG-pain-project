/* exercise compiled firmware on local memories and retained machine interrupts. */
#include "platform.h"

volatile uint32_t boot_initialized, fw_phase, fw_checks, fw_signature;
volatile uint32_t sw_count, timer_count, ext_count, pin_count, exception_count;
volatile uint32_t stack_low_water;
volatile uint32_t initialized_words[5] = {0x12345678u, 0x89abcdefu, 3u, 0xffffffffu, 0x55aa00ffu};
volatile unsigned char initialized_bytes[7] = {0x80, 1, 0x7f, 0xff, 0x42, 9, 0xa5};
volatile uint32_t zero_words[37];
volatile int32_t signed_left = -123456789, signed_right = 321;
volatile uint32_t unsigned_left = 0xf1234567u, unsigned_right = 97;
static volatile uint32_t expected_cause, expected_pc, expected_resume, expected_mtval, expected_armed;
static volatile uint32_t failure_reason;

/* function symbols identify the exact fault and the permitted recovery instruction. */
extern void fault_ecall(uint32_t), resume_ecall(void);
extern void fault_ebreak(uint32_t), resume_ebreak(void);
extern void fault_illegal(uint32_t), resume_illegal(void);
extern void fault_misload(uint32_t), resume_misload(void);
extern void fault_misstore(uint32_t), resume_misstore(void);
extern void fault_load(uint32_t), resume_load(void);
extern void fault_store(uint32_t), resume_store(void);
/* reference the compressed probe only in a build that implements C. */
#if FW_COMPRESSED
extern void fault_compressed(uint32_t), resume_compressed(void);
#endif

/* output stores are word-wide even though the sink consumes one low byte. */
void output_char(char value) {
    MMIO32(OUTPUT_DATA) = (unsigned char)value;
}

/* print deterministic diagnostics without a hosted C library. */
static void output_text(const char *text) {
    /* a complete string is emitted before the final result store. */
    while (*text) {
        output_char(*text++);
    }
}

/* preserve a reason code even when a broken startup never reaches normal reporting. */
void firmware_finish(uint32_t ok, uint32_t reason) {
    irq_disable();
    __asm__ volatile ("csrwi mie, 0" ::: "memory");
    failure_reason = reason;
    /* success and failure use distinct diagnostics and final MMIO values. */
    if (ok) {
        output_text("DRG5 firmware pass\n");
    }
    /* failure diagnostics retain the exact independently assigned check code. */
    else {
        output_text("DRG5 firmware fail ");
        /* render all reason bits without division or formatting support. */
        for (unsigned shift = 32; shift != 0; shift -= 4) {
            unsigned digit = (reason >> (shift - 4)) & 15u;
            output_char((char)(digit < 10 ? '0' + digit : 'a' + digit - 10));
        }
        output_char('\n');
    }
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
    MMIO32(OUTPUT_RESULT) = ok ? 1u : 3u;
    /* completion remains stable until a qualified whole-platform reset. */
    for (;;) {
        __asm__ volatile ("wfi");
    }
}

/* checks have independent reason codes and a visible completed-check count. */
static void check(int condition, uint32_t reason) {
    /* stop at the first wrong result rather than concealing subsequent corruption. */
    if (!condition) {
        firmware_finish(0, reason);
    }
    ++fw_checks;
}

/* record real call depth without assuming untouched stack memory is zero. */
__attribute__((noinline)) static uint32_t recursive_sum(unsigned depth) {
    volatile uint32_t frame[13];
    uintptr_t stack;
    uint32_t sum = 0;
    __asm__ volatile ("mv %0, sp" : "=r"(stack));
    /* the lowest observed frame includes every recursive level. */
    if (stack < stack_low_water) {
        stack_low_water = stack;
    }
    /* every frame remains live across the recursive call. */
    for (unsigned i = 0; i < 13; ++i) {
        frame[i] = depth * 37u + i * 3u;
    }
    uint32_t child = depth ? recursive_sum(depth - 1) : 0;
    /* sum after return so a corrupted call frame changes the checked result. */
    for (unsigned i = 0; i < 13; ++i) {
        sum += frame[i];
    }
    return sum + child;
}

/* sorting exercises dependent indexed loads, stores, loops and nested calls. */
__attribute__((noinline)) static void sort(uint32_t *values, size_t count) {
    /* insertion sort retains every input element while shifting larger predecessors. */
    for (size_t i = 1; i < count; ++i) {
        uint32_t value = values[i];
        size_t j = i;
        /* stop at the start or the first already ordered predecessor. */
        while (j && values[j - 1] > value) {
            values[j] = values[j - 1];
            --j;
        }
        values[j] = value;
    }
}

/* no automatic initialization may mask a broken data copy or BSS clear. */
static void test_startup(void) {
    check(boot_initialized == 0xb007d00du, 0x101);
    check(initialized_words[0] == 0x12345678u && initialized_words[1] == 0x89abcdefu &&
          initialized_words[2] == 3 && initialized_words[3] == 0xffffffffu &&
          initialized_words[4] == 0x55aa00ffu, 0x102);
    check(initialized_bytes[0] == 0x80 && initialized_bytes[6] == 0xa5, 0x103);
    check(fw_phase == 0 && sw_count == 0 && timer_count == 0 && ext_count == 0 && pin_count == 0 &&
          exception_count == 0 && expected_armed == 0, 0x104);
    /* every byte of the test array must have been cleared by startup stores. */
    for (unsigned i = 0; i < 37; ++i) {
        check(zero_words[i] == 0, 0x110 + i);
    }
    fw_phase = 1;
    stack_low_water = (uintptr_t)__stack_top;
}

/* verify real stack frames, private-library calls and natural narrow accesses. */
static void test_calls_and_arrays(void) {
    uint32_t values[17] = {16, 5, 12, 3, 9, 0, 14, 7, 2, 11, 6, 15, 1, 10, 4, 13, 8};
    unsigned char copied[21], source[21];
    volatile int8_t signed_byte = -101;
    volatile uint8_t unsigned_byte = 203;
    volatile int16_t signed_half = -30001;
    volatile uint16_t unsigned_half = 60001;
    check(recursive_sum(6) == 11739u, 0x201);
    check(stack_low_water >= (uintptr_t)__stack_bottom && stack_low_water < (uintptr_t)__stack_top - 256, 0x202);
    sort(values, 17);
    /* an independent ascending sequence detects lost or duplicated array elements. */
    for (unsigned i = 0; i < 17; ++i) {
        check(values[i] == i, 0x210 + i);
    }
    /* memory helpers must preserve canaries outside their requested byte ranges. */
    for (unsigned i = 0; i < 21; ++i) {
        source[i] = (unsigned char)(i * 7u + 3u);
    }
    memset(copied, 0xa5, sizeof copied);
    memcpy(copied + 1, source + 1, 19);
    check(copied[0] == 0xa5 && copied[20] == 0xa5 && memcmp(copied + 1, source + 1, 19) == 0, 0x230);
    check(signed_byte == -101 && unsigned_byte == 203 && signed_half == -30001 && unsigned_half == 60001, 0x231);
    fw_phase = 2;
}

/* volatile inputs prevent folding away arithmetic and division operations. */
static void test_arithmetic(void) {
    int32_t left = signed_left, right = signed_right;
    uint32_t a = unsigned_left, b = unsigned_right;
    check(left / right == -384600 && left % right == -189, 0x301);
    check(a / b == 41707428u && a % b == 67u, 0x302);
    check(a * b == 0x5e5d4c07u, 0x303);
    check(runtime_udiv(0xffffffffu, 97) == 44278013u, 0x304);
    check(runtime_udiv(123u, 0) == 0xffffffffu, 0x305);
    check((a + 0x20000000u) == 0x11234567u && (left < 0) && a > 0x7fffffffu, 0x306);
    /* direct helper calls cover cases where a C division expression would be undefined. */
    check(__divsi3(INT32_MIN, -1) == INT32_MIN && __modsi3(INT32_MIN, -1) == 0, 0x307);
    check(__divsi3(-123, 0) == -1 && __modsi3(-123, 0) == -123, 0x308);
    check(__divsi3(123, -7) == -17 && __modsi3(123, -7) == 4, 0x309);
    check(__divsi3(-123, 7) == -17 && __modsi3(-123, 7) == -4, 0x30a);
    check(__umodsi3(0x87654321u, 0) == 0x87654321u, 0x30b);
    check(runtime_udiv(0x80000000u, 0xffffffffu) == 0 && __umodsi3(0x80000000u, 0xffffffffu) == 0x80000000u, 0x30c);
    check(__mulsi3(0xffffffffu, 17u) == 0xffffffefu, 0x30d);
    fw_signature = (a ^ (uint32_t)left) + 0x1020304u;
    fw_phase = 3;
}

/* an unanticipated trap is fatal; only explicitly armed sites may recover. */
void trap_dispatch(struct trap_frame *frame) {
    /* all interrupted stacks obey ILP32 alignment and the reserved bounds. */
    if ((frame->gpr[2] & 15u) || frame->gpr[2] > (uintptr_t)__stack_top ||
        (uintptr_t)frame < (uintptr_t)__stack_bottom || (frame->mstatus & MSTATUS_MIE)) {
        firmware_finish(0, 0xe01);
    }
    /* interrupt entry never acknowledges a peripheral implicitly. */
    if (frame->mcause & 0x80000000u) {
        uint32_t cause = frame->mcause & 0x7fffffffu;
        /* each source is serviced at its retaining platform register. */
        if (cause == 3) {
            MMIO32(TIMER_BASE + 0x10) = 0;
            ++sw_count;
        }
        /* move the timer compare beyond every finite fixture runtime. */
        else if (cause == 7) {
            timer_compare(UINT64_MAX);
            ++timer_count;
        }
        /* preserve distinct external sources until their explicit acknowledgement. */
        else if (cause == 11) {
            uint32_t pending = MMIO32(TIMER_BASE + 0x14) & MMIO32(TIMER_BASE + 0x18);
            /* the fixture supplies both a software-injected event and a physical pin. */
            if (pending & 2u) {
                ++ext_count;
            }
            /* count serviced pin events; repeated pending pulses may coalesce. */
            if (pending & 4u) {
                ++pin_count;
            }
            /* unsupported sources cannot be mistaken for the expected events. */
            if (!pending || (pending & ~6u)) {
                firmware_finish(0, 0xe02);
            }
            MMIO32(TIMER_BASE + 0x14) = pending;
        }
        /* no unsupported interrupt can be reported as a successful test source. */
        else {
            firmware_finish(0, 0xe03);
        }
        return;
    }
    /* preserve the real instruction-start PC and compare fault-specific mtval. */
    if (!expected_armed || frame->mcause != expected_cause || frame->mepc != expected_pc || frame->mtval != expected_mtval) {
        firmware_finish(0, 0xe10 | (frame->mcause << 8));
    }
    frame->mepc = expected_resume;
    expected_armed = 0;
    ++exception_count;
}

/* polling has a finite software limit and never relies on an acquisition interrupt. */
static void await_count(volatile uint32_t *count, uint32_t reason) {
    /* each loop observes the volatile handler update after returning from the trap. */
    for (unsigned n = 0; n < 200000; ++n) {
        /* exactly one service is required for each retained test event. */
        if (*count == 1) {
            return;
        }
    }
    firmware_finish(0, reason);
}

/* retained software, timer and external sources are each tested through real handlers. */
static void test_interrupts(void) {
    irq_disable();
    __asm__ volatile ("csrw mie, %0" :: "r"(MIE_MSIE) : "memory");
    MMIO32(TIMER_BASE + 0x10) = 1;
    check(sw_count == 0, 0x401);
    check(irq_register_probe(), 0x402);
    check(sw_count == 1 && MMIO32(TIMER_BASE + 0x10) == 0, 0x403);
    MMIO32(TIMER_BASE + 0x18) = 2;
    __asm__ volatile ("csrw mie, %0" :: "r"(MIE_MEIE) : "memory");
    MMIO32(EVENT_INJECT) = 1;
    check(ext_count == 0 && (MMIO32(TIMER_BASE + 0x14) & 2u), 0x404);
    irq_enable();
    await_count(&ext_count, 0x405);
    irq_disable();
    MMIO32(TIMER_BASE + 0x18) = 4;
    output_char('R');
    irq_enable();
    await_count(&pin_count, 0x406);
    irq_disable();
    check(MMIO32(TIMER_BASE + 0x14) == 0, 0x407);
    MMIO32(TIMER_BASE + 0x18) = 0;
    __asm__ volatile ("csrw mie, %0" :: "r"(MIE_MTIE) : "memory");
    timer_compare(timer_now() + 20000u);
    irq_enable();
    __asm__ volatile ("wfi" ::: "memory");
    await_count(&timer_count, 0x408);
    irq_disable();
    __asm__ volatile ("csrwi mie, 0" ::: "memory");
    check(sw_count == 1 && timer_count == 1 && ext_count == 1 && pin_count == 1, 0x409);
    fw_phase = 4;
}

/* explicit labels permit recovery from both 16-bit and 32-bit instructions. */
static void recover(void (*fault)(uint32_t), void (*resume)(void), uint32_t cause, uint32_t address, uint32_t value) {
    expected_cause = cause;
    expected_pc = (uintptr_t)fault;
    expected_resume = (uintptr_t)resume;
    expected_mtval = value;
    expected_armed = 1;
    fault(address);
    check(expected_armed == 0, 0x501 + cause);
}

/* fault responses must leave the caller's stack and return address intact. */
static void test_exceptions(void) {
    recover(fault_ecall, resume_ecall, 11, 0, 0);
    recover(fault_ebreak, resume_ebreak, 3, 0, (uintptr_t)fault_ebreak);
    recover(fault_illegal, resume_illegal, 2, 0, 0);
    recover(fault_misload, resume_misload, 4, 0x20000001u, 0x20000001u);
    recover(fault_misstore, resume_misstore, 6, 0x20000001u, 0x20000001u);
    recover(fault_load, resume_load, 5, 0x4000000cu, 0x4000000cu);
    recover(fault_store, resume_store, 7, 0x4000000cu, 0x4000000cu);
    /* verify two-byte breakpoint recovery only in the compressed profile. */
#if FW_COMPRESSED
    recover(fault_compressed, resume_compressed, 3, 0, (uintptr_t)fault_compressed);
#endif
    check(exception_count == (FW_COMPRESSED ? 8u : 7u), 0x520);
    fw_phase = 5;
}

/* the final result depends only on the local CPU platform and its test event pin. */
int main(void) {
    test_startup();
    test_calls_and_arrays();
    test_arithmetic();
    test_interrupts();
    test_exceptions();
    /* recursion and trap entry must not consume the reserved stack guard. */
    for (unsigned i = 0; i < 4; ++i) {
        check(((volatile uint32_t *)(void *)__stack_guard)[i] == 0x6b8b4567u, 0x600 + i);
    }
    fw_phase = 6;
    firmware_finish(1, 0);
}
