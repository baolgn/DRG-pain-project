/* boot establishes the ABI without assuming any nonzero register reset value. */
.attribute stack_align, 16
.section .text.boot,"ax",@progbits
.option push
.option norvc
.option norelax
.globl _start
.type _start,@function
_start:
    csrwi mie, 0
    csrci mstatus, 8
    la sp, __stack_top
    la gp, __global_pointer$
    li tp, 0
    la t0, trap_entry
    csrw mtvec, t0
    la t0, _start_iram
    jr t0
.size _start, .-_start
.option pop

/* initialized data and BSS are written by the CPU, never by the ELF loader. */
.section .text.startup.entry,"ax",@progbits
.balign 4
.globl _start_iram
.type _start_iram,@function
_start_iram:
#ifndef NEG_SKIP_DATA
    la t0, __data_load
    la t1, __data_start
    la t2, __data_end
/* copy the complete aligned load image before C observes its objects. */
1:
    beq t1, t2, 2f
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 1b
2:
#endif
#ifndef NEG_SKIP_BSS
    la t0, __bss_start
    la t1, __bss_end
/* clear every BSS byte even when physical RAM powers up nonzero. */
3:
    beq t0, t1, 4f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 3b
4:
#endif
    la t0, __stack_guard
    li t1, 0x6b8b4567
    sw t1, 0(t0)
    sw t1, 4(t0)
    sw t1, 8(t0)
    sw t1, 12(t0)
    la t0, boot_initialized
    li t1, 0xb007d00d
    sw t1, 0(t0)
.globl startup_complete
/* the marker follows data/BSS writes and precedes the first C call. */
startup_complete:
    call main
    li a1, 0xee
    call firmware_finish
.size _start_iram, .-_start_iram
