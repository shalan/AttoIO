/*
 * AttoIO C runtime startup.
 *
 * Layout:
 *   0x000  .reset     tiny trampoline -> _start
 *   0x010  .isr       MTVEC entry; jumps to __isr (C handler, weak default = mret)
 *   _start            set sp, clear bss, call main, spin if main returns
 */

    .section .reset, "ax"
    .globl  _start
_start:
    j       _init              /* 2-byte C.J is fine; assembler picks encoding */

    .section .isr, "ax"
    .align  2
    .globl  __trap_entry
__trap_entry:
    /* On a minimal RV32EC with no nested interrupts, the handler is a
     * leaf function we call with plain C ABI. We save the caller-saved
     * regs we actually clobber. AttoRV32 uses RV32E (16 regs) so x16-31
     * don't exist. */
    addi    sp, sp, -32
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)
    sw      a1, 20(sp)
    sw      a2, 24(sp)
    sw      a3, 28(sp)

    call    __isr

    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      a0, 16(sp)
    lw      a1, 20(sp)
    lw      a2, 24(sp)
    lw      a3, 28(sp)
    addi    sp, sp, 32
    mret

    .section .text.startup, "ax"
    .align  2
    .globl  _init
_init:
    /* 1. Set stack pointer. */
    la      sp, _stack_top

    /* 2. Clear .bss. */
    la      a0, _sbss
    la      a1, _ebss
1:  beq     a0, a1, 2f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       1b
2:

    /* 3. Run main(). */
    call    main

    /* 4. If main returns, spin with interrupts enabled (allows host to
     *    doorbell-reset us via IOP_CTRL without the core running off into
     *    the weeds). */
9:  wfi
    j       9b

    /* Weak default ISR: return immediately. Override in C with
     *    void __isr(void) { ... } */
    .weak   __isr
    .globl  __isr
__isr:
    ret
