/* deliberate faults use named resume PCs instead of guessed instruction lengths. */
.attribute stack_align, 16
.section .text.faults,"ax",@progbits
.option push
.option norvc

/* the handler resumes at the instruction following this ecall probe. */
.balign 4
.globl fault_ecall, resume_ecall
.type fault_ecall,@function
fault_ecall:
    ecall
/* return to C after the handler selects the explicit recovery PC. */
resume_ecall:
    ret
.size fault_ecall, .-fault_ecall

/* the handler resumes at the instruction following this ebreak probe. */
.balign 4
.globl fault_ebreak, resume_ebreak
.type fault_ebreak,@function
fault_ebreak:
    ebreak
/* return only after breakpoint recovery redirects execution here. */
resume_ebreak:
    ret
.size fault_ebreak, .-fault_ebreak

/* the handler resumes at the instruction following this illegal probe. */
.balign 4
.globl fault_illegal, resume_illegal
.type fault_illegal,@function
fault_illegal:
    .word 0xffffffff
/* resume beyond the deliberately unsupported instruction encoding. */
resume_illegal:
    ret
.size fault_illegal, .-fault_illegal

/* the handler resumes at the instruction following this misload probe. */
.balign 4
.globl fault_misload, resume_misload
.type fault_misload,@function
fault_misload:
    lw a1, 0(a0)
/* return after the misaligned load has trapped without a register write. */
resume_misload:
    ret
.size fault_misload, .-fault_misload

/* the handler resumes at the instruction following this misstore probe. */
.balign 4
.globl fault_misstore, resume_misstore
.type fault_misstore,@function
fault_misstore:
    sw a1, 0(a0)
/* return after the misaligned store has trapped without a memory write. */
resume_misstore:
    ret
.size fault_misstore, .-fault_misstore

/* the handler resumes at the instruction following this load probe. */
.balign 4
.globl fault_load, resume_load
.type fault_load,@function
fault_load:
    lw zero, 0(a0)
/* resume after the rejected read even though its destination is x0. */
resume_load:
    ret
.size fault_load, .-fault_load

/* the handler resumes at the instruction following this store probe. */
.balign 4
.globl fault_store, resume_store
.type fault_store,@function
fault_store:
    sw a1, 0(a0)
/* resume after the rejected write leaves device state unchanged. */
resume_store:
    ret
.size fault_store, .-fault_store
.option pop

/* omit the two-byte probe when the selected ISA excludes C. */
#if FW_COMPRESSED
/* a compressed fault tests recovery from a two-byte instruction. */
.balign 2
.globl fault_compressed, resume_compressed
.type fault_compressed,@function
fault_compressed:
    c.ebreak
/* use the explicit two-byte recovery address rather than a fixed increment. */
resume_compressed:
    ret
.size fault_compressed, .-fault_compressed
#endif

/* save the caller, then test every GPR across an actual software interrupt. */
.section .text.irq_probe,"ax",@progbits
.balign 4
.globl irq_register_probe
.type irq_register_probe,@function
irq_register_probe:
    addi sp, sp, -256
    sw x1, 4(sp)
    sw x3, 12(sp)
    sw x4, 16(sp)
    sw x5, 20(sp)
    sw x6, 24(sp)
    sw x7, 28(sp)
    sw x8, 32(sp)
    sw x9, 36(sp)
    sw x10, 40(sp)
    sw x11, 44(sp)
    sw x12, 48(sp)
    sw x13, 52(sp)
    sw x14, 56(sp)
    sw x15, 60(sp)
    sw x16, 64(sp)
    sw x17, 68(sp)
    sw x18, 72(sp)
    sw x19, 76(sp)
    sw x20, 80(sp)
    sw x21, 84(sp)
    sw x22, 88(sp)
    sw x23, 92(sp)
    sw x24, 96(sp)
    sw x25, 100(sp)
    sw x26, 104(sp)
    sw x27, 108(sp)
    sw x28, 112(sp)
    sw x29, 116(sp)
    sw x30, 120(sp)
    sw x31, 124(sp)
    addi t0, sp, 256
    sw t0, 8(sp)
    /* pend the software interrupt while machine interrupts remain masked. */
    li t0, 0x40001010
    li t1, 1
    sw t1, 0(t0)
    /* unique canaries include gp, tp, ra, caller-saved and callee-saved registers. */
    li x1, 0x12340001
    li x3, 0x12340003
    li x4, 0x12340004
    li x5, 0x12340005
    li x6, 0x12340006
    li x7, 0x12340007
    li x8, 0x12340008
    li x9, 0x12340009
    li x10, 0x1234000a
    li x11, 0x1234000b
    li x12, 0x1234000c
    li x13, 0x1234000d
    li x14, 0x1234000e
    li x15, 0x1234000f
    li x16, 0x12340010
    li x17, 0x12340011
    li x18, 0x12340012
    li x19, 0x12340013
    li x20, 0x12340014
    li x21, 0x12340015
    li x22, 0x12340016
    li x23, 0x12340017
    li x24, 0x12340018
    li x25, 0x12340019
    li x26, 0x1234001a
    li x27, 0x1234001b
    li x28, 0x1234001c
    li x29, 0x1234001d
    li x30, 0x1234001e
    li x31, 0x1234001f
    /* expose the pending interrupt only after every canary is installed. */
    csrsi mstatus, 8
    /* enough independent instructions separate eligibility from the mask write. */
    .rept 24
    nop
    .endr
    csrci mstatus, 8
    /* capture without changing any register until all interrupted values are saved. */
    sw x1, 132(sp)
    sw x2, 136(sp)
    sw x3, 140(sp)
    sw x4, 144(sp)
    sw x5, 148(sp)
    sw x6, 152(sp)
    sw x7, 156(sp)
    sw x8, 160(sp)
    sw x9, 164(sp)
    sw x10, 168(sp)
    sw x11, 172(sp)
    sw x12, 176(sp)
    sw x13, 180(sp)
    sw x14, 184(sp)
    sw x15, 188(sp)
    sw x16, 192(sp)
    sw x17, 196(sp)
    sw x18, 200(sp)
    sw x19, 204(sp)
    sw x20, 208(sp)
    sw x21, 212(sp)
    sw x22, 216(sp)
    sw x23, 220(sp)
    sw x24, 224(sp)
    sw x25, 228(sp)
    sw x26, 232(sp)
    sw x27, 236(sp)
    sw x28, 240(sp)
    sw x29, 244(sp)
    sw x30, 248(sp)
    sw x31, 252(sp)
    li a0, 1
    addi t0, sp, 132
    li t1, 0x12340001
    li t2, 1
    /* all non-SP values must match; SP is checked against the caller's saved value. */
1:
    li t3, 2
    beq t2, t3, 2f
    lw t3, 0(t0)
    bne t3, t1, 4f
    /* advance the canary and capture pointers, including the separately checked SP. */
2:
    addi t0, t0, 4
    addi t1, t1, 1
    addi t2, t2, 1
    li t3, 32
    bltu t2, t3, 1b
    lw t0, 136(sp)
    addi t0, t0, 256
    lw t1, 8(sp)
    bne t0, t1, 4f
    j 5f
    /* the returned zero names a corrupted asynchronous context. */
4:
    li a0, 0
    /* restore the original C caller while returning the comparison result in a0. */
5:
    lw x1, 4(sp)
    lw x3, 12(sp)
    lw x4, 16(sp)
    lw x5, 20(sp)
    lw x6, 24(sp)
    lw x7, 28(sp)
    lw x8, 32(sp)
    lw x9, 36(sp)
    lw x11, 44(sp)
    lw x12, 48(sp)
    lw x13, 52(sp)
    lw x14, 56(sp)
    lw x15, 60(sp)
    lw x16, 64(sp)
    lw x17, 68(sp)
    lw x18, 72(sp)
    lw x19, 76(sp)
    lw x20, 80(sp)
    lw x21, 84(sp)
    lw x22, 88(sp)
    lw x23, 92(sp)
    lw x24, 96(sp)
    lw x25, 100(sp)
    lw x26, 104(sp)
    lw x27, 108(sp)
    lw x28, 112(sp)
    lw x29, 116(sp)
    lw x30, 120(sp)
    lw x31, 124(sp)
    lw sp, 8(sp)
    ret
.size irq_register_probe, .-irq_register_probe

