/*
 * AttoIO linker script (v2.1 — Phase 0.8 downsize).
 *
 * Memory map (IOP view, 11-bit byte addresses):
 *   0x000 .. 0x3FF   1024 B   SRAM A   (two 512 B banks, transparent)
 *   0x600 .. 0x67F    128 B   SRAM B   mailbox (host/IOP shared)
 *   0x700 .. 0x7FF    256 B   MMIO     peripheral registers
 *
 * Unmapped windows (0x400..0x5FF and 0x680..0x6FF) return 0 on reads
 * and silently drop writes.
 *
 * SRAM A holds .text + .rodata + .data + .bss + stack.  Banks are
 * transparent to the linker — one contiguous 1024-byte region.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM_A   (rwx) : ORIGIN = 0x00000000, LENGTH = 1024
    MAILBOX (rw)  : ORIGIN = 0x00000600, LENGTH = 128
    MMIO    (rw)  : ORIGIN = 0x00000700, LENGTH = 256
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

    /* Reserve 64 B of stack; verify we can fit. */
    _heap_end = _stack_top - 64;

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}

ASSERT(_ebss < _heap_end, "ERROR: bss + stack won't fit in SRAM A (1024 B)")
