/* freeze the boot, executable, data and guarded-stack capacities. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
/* all target storage is local and has a fixed byte capacity. */
MEMORY {
    ROM (rx) : ORIGIN = 0x00000000, LENGTH = 8K
    IRAM (rwx) : ORIGIN = 0x00010000, LENGTH = 64K
    DRAM (rw) : ORIGIN = 0x20000000, LENGTH = 32K
}
/* separate loaded bytes from the uninitialized DRAM segment. */
PHDRS {
    boot PT_LOAD FLAGS(5);
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
    zero PT_LOAD FLAGS(6);
}
/* preserve explicit runtime and physical-load addresses. */
SECTIONS {
    /* reset executes ROM instructions before any initialized RAM state is used. */
    .boot : ALIGN(4) { KEEP(*(.text.boot)) } > ROM :boot
    /* code and constants are preloaded only into local instruction RAM. */
    .text : ALIGN(4) {
        /* build.py selects supported instruction padding for the active profile. */
#if FW_COMPRESSED
        FILL(0x01000100)
        /* use full-width NOP padding when compressed instructions are disabled. */
#else
        FILL(0x13000000)
#endif
        __text_start = .;
        KEEP(*(.text.startup.entry))
        KEEP(*(.text.trap))
        *(.text .text.*)
        . = ALIGN(4);
        __text_end = .;
    } > IRAM :text
    /* constants share the executable memory's read-only load segment. */
    .rodata : ALIGN(4) {
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    } > IRAM :text
    /* startup copies the ROM image in IRAM to each initialized data byte. */
    .data : ALIGN(4) {
        __data_start = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > DRAM AT> IRAM :data
    __data_load = LOADADDR(.data);
    __global_pointer$ = __data_start + 0x800;
    /* no loader supplies BSS zeros; the startup loop must write them. */
    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DRAM :zero
    /* reserve four guard words below a 4 KiB downward-growing stack. */
    __stack_top = ORIGIN(DRAM) + LENGTH(DRAM);
    __stack_bottom = __stack_top - 4096;
    __stack_guard = __stack_bottom - 16;
    __heap_start = __bss_end;
    __heap_end = __stack_guard;
    /* metadata remains inspectable without adding executable target bytes. */
    .riscv.attributes 0 : { *(.riscv.attributes) }
    /* the freestanding runtime has no unwinder or hosted stack metadata. */
    /DISCARD/ : { *(.comment .note.GNU-stack .eh_frame .eh_frame.*) }
}
ASSERT(SIZEOF(.boot) <= LENGTH(ROM), "boot ROM overflow")
ASSERT(__data_load + SIZEOF(.data) <= ORIGIN(IRAM) + LENGTH(IRAM), "IRAM overflow")
ASSERT(__bss_end <= __stack_guard, "data overlaps stack guard")
ASSERT((__stack_top & 15) == 0, "stack alignment")
ASSERT((trap_entry & 3) == 0, "direct trap alignment")
