/*
 * wake_test/main.c — exercises the per-pin wake system.
 *
 * Configure pad[5] = rising-edge wake, pad[9] = falling-edge wake.
 * Enable both pins in WAKE_MASK. Loop with WFI. On every wake IRQ:
 *   - snapshot WAKE_FLAGS into mailbox word 4
 *   - clear those flags (W1C)
 *   - increment the wake-count sentinel in mailbox word 0
 *
 * Host testbench drives pad_in edges and reads the mailbox back.
 */

#include "../attoio.h"

volatile uint32_t wake_count;

/* Override the weak __isr from crt0.S */
void __isr(void) {
    uint32_t flags = WAKE_FLAGS;
    MAILBOX_W32[4] = flags;          /* word @ 0x210 */
    MAILBOX_W32[0] = ++wake_count;   /* word @ 0x200 */
    WAKE_FLAGS = flags;              /* W1C */
}

int main(void) {
    wake_count = 0;
    MAILBOX_W32[0] = 0;

    /* Enable MSTATUS.MIE (bit 3). */
    __asm__ volatile ("csrsi mstatus, 8");

    /* Per-pin edge config + enable */
    wake_set_edge(5, WAKE_EDGE_RISE);
    wake_set_edge(9, WAKE_EDGE_FALL);
    wake_enable(5);
    wake_enable(9);

    /* Sentinel so host can see we reached the idle loop */
    MAILBOX_W32[2] = 0xC0DEC0DEu;

    while (1) wfi();
}
