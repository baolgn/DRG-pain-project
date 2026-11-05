/* supervise complete blocks; capture, timestamps and raw movement remain hardware responsibilities. */
#include <stdint.h>
#include "kernel.h"

volatile uint32_t boot_initialized;
volatile uint32_t pending_block;
static volatile uint32_t *const registers = (volatile uint32_t *)UINT32_C(0x40000000);

/* an unexpected return or exception becomes a visible terminal platform fault. */
void firmware_finish(uint32_t unused, uint32_t reason) {
    (void)unused;
    registers[11] = reason;
    /* fault reporting must not resume acquisition or manufacture a completed result. */
    for (;;) __asm__ volatile ("wfi");
}

/* retain the complete linked processing routine as the measured DSP ownership interval. */
__attribute__((noinline)) static void process_block(uint32_t id) {
    int32_t samples[16];
    volatile const int32_t *const aperture = (volatile const int32_t *)UINT32_C(0x50001000);
    registers[2] = id;
    /* read only channel zero at frames zero, sixteen, through two hundred forty. */
    for (uint32_t index = 0; index < 16; ++index) samples[index] = aperture[index * 16];
    struct synthetic_result result = synthetic_kernel(samples, registers[15]);
    registers[3] = result.energy;
    registers[4] = result.signature;
    registers[5] = result.quotient;
    registers[6] = id;
}

/* a non-nested leaf ISR records one descriptor; foreground code owns all arithmetic. */
int main(void) {
    uint32_t previous = 0;
    __asm__ volatile ("li t0,0x888; csrw mie,t0; csrsi mstatus,8" ::: "t0", "memory");
    __asm__ volatile ("ecall" ::: "memory");
    registers[7] = UINT32_C(0x51a7c0de);
    /* polling avoids an acknowledgement-to-WFI race and keeps fetch pressure explicit in this fixture. */
    for (;;) {
        uint32_t next = pending_block;
        /* each announced block executes once; missing notification is detected by the platform deadline. */
        if (next != previous) {
            process_block(next);
            previous = next;
        }
    }
}
