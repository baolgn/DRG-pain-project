/* save every register changed by this leaf handler; keep the ISR free of sample loops and division. */
.attribute stack_align, 16
.section .text.trap,"ax",@progbits
.balign 4
.globl trap_entry
.type trap_entry,@function
trap_entry:
    addi sp, sp, -16
    sw t0, 0(sp)
    sw t1, 4(sp)
    sw t2, 8(sp)
    /* distinguish external, timer and software interrupt causes before the ecall path. */
    csrr t0, mcause
    li t1, 0x8000000b
    li t2, 0x40000000
    beq t0, t1, block_irq
    li t1, 0x80000007
    beq t0, t1, timer_irq
    li t1, 0x80000003
    beq t0, t1, software_irq
    li t1, 11
    bne t0, t1, unexpected_trap
    /* advance a machine ecall by four bytes and report recovery to the fixture. */
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    sw zero, 40(t2)
    j trap_restore
/* acknowledge one descriptor only after storing its foreground notification. */
block_irq:
    lw t0, 0(t2)
    la t1, pending_block
    sw t0, 0(t1)
    sw t0, 4(t2)
    j trap_restore
/* timer events remain level-pending until this bounded acknowledgement. */
timer_irq:
    sw zero, 32(t2)
    j trap_restore
/* software events have independent pending state and service accounting. */
software_irq:
    sw zero, 36(t2)
    j trap_restore
/* unsupported traps expose their cause and retain control rather than skipping unknown instructions. */
unexpected_trap:
    sw t0, 44(t2)
    j unexpected_trap
/* restore the interrupted caller exactly, including temporary operands and stack alignment. */
trap_restore:
    lw t0, 0(sp)
    lw t1, 4(sp)
    lw t2, 8(sp)
    addi sp, sp, 16
    mret
.size trap_entry, .-trap_entry
