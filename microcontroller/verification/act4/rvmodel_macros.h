/* ACT4 platform operations use ordered, word-only MMIO. */
#ifndef DRG5_RVMODEL_MACROS_H
#define DRG5_RVMODEL_MACROS_H

/* standard machine initialization includes zero HPM placeholders. */
#define STANDARD_SM_SUPPORTED
#define RVMODEL_DATA_SECTION
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x30000000

/* completion is observed after the store response and retirement. */
#define RVMODEL_HALT_PASS \
  li t0, 0x40000000;      \
  li t1, 1;              \
  sw t1, 0(t0);          \
1: j 1b
#define RVMODEL_HALT_FAIL \
  li t0, 0x40000000;      \
  li t1, 3;              \
  sw t1, 0(t0);          \
1: j 1b

/* emit a terminated string through the word-only console. */
#define RVMODEL_IO_INIT(_R1, _R2, _R3)
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \
1: lbu _R1, 0(_STR_PTR);                            \
  beqz _R1, 2f;                                    \
  li _R2, 0x40000004;                               \
  sw _R1, 0(_R2);                                   \
  addi _STR_PTR, _STR_PTR, 1;                        \
  j 1b;                                            \
2:

/* ACT4 counts wait instructions; this exceeds the bounded RTL IRQ delay. */
#define RVMODEL_INTERRUPT_LATENCY 128
#define RVMODEL_TIMER_INT_SOON_DELAY 4096
#define RVMODEL_MTIME_ADDRESS 0x40001000
#define RVMODEL_MTIMECMP_ADDRESS 0x40001008
#define RVMODEL_MSIP_ADDRESS 0x40001010

/* enable and latch event bit one; acquisition queue bit zero is independent. */
#define RVMODEL_SET_MEXT_INT(_R1, _R2) \
  li _R1, 2;                         \
  li _R2, 0x40001018;                \
  sw _R1, 0(_R2);                    \
  li _R1, 1;                         \
  li _R2, 0x40000008;                \
  sw _R1, 0(_R2)

/* acknowledge the retained external event without altering the queue. */
#define RVMODEL_CLR_MEXT_INT(_R1, _R2) \
  li _R1, 2;                         \
  li _R2, 0x40001014;                \
  sw _R1, 0(_R2)

#endif
