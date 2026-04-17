/*
 * AttoIO linker script.
 *
 * Memory map (IOP view):
 *   0x000 .. 0x1FF   SRAM A   512 B   code + data + stack (IOP-private)
 *   0x200 .. 0x2FF   SRAM B   256 B   mailbox with host (R/W, arbitrated)
 *   0x300 .. 0x3FF   MMIO     256 B   peripheral regs
 *
 * Linked image must fit entirely in SRAM A. The host writes the program
 * into SRAM A while IOP is held in reset, then releases reset; the core
 * starts executing at 0x000.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM_A   (rwx) : ORIGIN = 0x00000000, LENGTH = 512
    MAILBOX (rw)  : ORIGIN = 0x00000200, LENGTH = 256
    MMIO    (rw)  : ORIGIN = 0x00000300, LENGTH = 256
}

_stack_top = ORIGIN(RAM_A) + LENGTH(RAM_A);
_mailbox   = ORIGIN(MAILBOX);

SECTIONS
{
    /* Reset trampoline lives at 0x000; MTVEC ISR lands at 0x010. */
    .reset 0x000 : {
        KEEP(*(.reset))
    } > RAM_A

    .isr 0x010 : {
        KEEP(*(.isr))
    } > RAM_A

    /* Main code + constant data. */
    .text : ALIGN(4) {
        *(.text.startup)
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > RAM_A

    /* Initialised data — copied from ROM image by crt0 if used; in this
     * flow, host loads the whole image verbatim into SRAM A, so .data
     * is already in place. Keep a separate section for clarity. */
    .data : ALIGN(4) {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        _edata = .;
    } > RAM_A

    /* Zero-initialised. crt0 clears this. */
    .bss (NOLOAD) : ALIGN(4) {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _ebss = .;
    } > RAM_A

    /* Stack grows down from _stack_top; keep a lower bound check. */
    _heap_end = _stack_top - 32;  /* reserve 32 B minimum stack */

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}

ASSERT(_ebss < _heap_end, "ERROR: bss + stack won't fit in SRAM A (512 B)")
