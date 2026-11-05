/* exact prototype capacities; an oversized test is a reported build failure. */
OUTPUT_ARCH("riscv")
ENTRY(rvtest_entry_point)
MEMORY
{
  iram (rwx) : ORIGIN = 0x00010000, LENGTH = 0x10000
  dram (rw)  : ORIGIN = 0x20000000, LENGTH = 0x8000
}
PROVIDE(__stack_size = 0x1000);
PROVIDE(__num_harts = 1);

/* fixed model text placement keeps reference and DUT test addresses equal. */
SECTIONS
{
  .text.init 0x00010000 : { *(.text.init) } > iram
  .text.rvtest : { *(.text.rvtest) *(.text.rvtest.*) } > iram
  ASSERT(. <= 0x0001e000, "ACT4 test code exceeds the 56 KiB test allocation")
  .text.rvmodel 0x0001e000 :
  {
    *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*)
  } > iram
  ASSERT(. <= 0x00020000, "ACT4 model code exceeds the 8 KiB model allocation")

  /* signatures and input data remain in non-executable DRAM. */
  .rodata 0x20000000 : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) } > dram
  .data : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) } > dram
  .bss (NOLOAD) :
  {
    . = ALIGN(16);
    __bss_start = .;
    *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } > dram
  .stack (NOLOAD) :
  {
    . = ALIGN(16);
    __stack_bottom = .;
    . += __stack_size * __num_harts;
    __stack_top = .;
  } > dram
  _end = .;
  ASSERT(_end <= 0x20008000, "ACT4 data and stack exceed the 32 KiB DRAM")
}
