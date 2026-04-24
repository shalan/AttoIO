/*
 * AttoIO-CFSRAM linker script.
 *
 * Memory map (IOP view, 13-bit byte addresses):
 *   0x0000 .. 0x0FFF   4096 B   SRAM A   (CF_SRAM_1024x32 hard macro)
 *   0x1400 .. 0x147F    128 B   SRAM B   mailbox (DFFRAM 32 x 32)
 *   0x1700 .. 0x17FF    256 B   MMIO     peripheral registers
 *
 * Unmapped windows (0x1000..0x13FF, 0x1480..0x16FF, 0x1800..0x1FFF)
 * return 0 on reads and silently drop writes.
 *
 * SRAM A holds .text + .rodata + .data + .bss + stack.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM_A   (rwx) : ORIGIN = 0x00000000, LENGTH = 4096
    MAILBOX (rw)  : ORIGIN = 0x00001400, LENGTH = 128
    MMIO    (rw)  : ORIGIN = 0x00001700, LENGTH = 256
}

_stack_top = ORIGIN(RAM_A) + LENGTH(RAM_A);
_mailbox   = ORIGIN(MAILBOX);

SECTIONS
{
    .reset 0x000 : {
        KEEP(*(.reset))
    } > RAM_A

    .isr 0x010 : {
        KEEP(*(.isr))
    } > RAM_A

    .text : ALIGN(4) {
        *(.text.startup)
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > RAM_A

    .data : ALIGN(4) {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        _edata = .;
    } > RAM_A

    .bss (NOLOAD) : ALIGN(4) {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _ebss = .;
    } > RAM_A

    /* Reserve 256 B stack for the CFSRAM variant — plenty of room now. */
    _heap_end = _stack_top - 256;

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}

ASSERT(_ebss < _heap_end, "ERROR: bss + stack won't fit in SRAM A (4096 B)")
