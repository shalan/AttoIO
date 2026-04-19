/*
 * irq_timer/main.c — verifies the TIMER → iop_irq path.
 *
 * Configures TIMER channel 0 as an auto-reload periodic with
 * TIMER_CMP_IRQ_EN set (no pad output), enables MIE, and sleeps in
 * WFI.  Each match wakes the IOP, the ISR W1Cs MATCH0, and bumps a
 * mailbox counter.  Host TB just polls the counter and checks it
 * keeps growing.
 *
 * Mailbox layout:
 *   word 0 = tick count (post-IRQ)
 *   word 2 = 0xC0DEC0DE sentinel once main() reaches WFI
 */

#include "../attoio.h"

volatile uint32_t tick_count;

void __isr(void) {
    /* Even though TIMER is the only configured source here, read the
     * status flag and gate on it — that's the pattern firmware should
     * follow when more than one source is enabled. */
    if (TIMER_STATUS & TIMER_STATUS_MATCH0) {
        tick_count++;
        MAILBOX_W32[0] = tick_count;
        TIMER_STATUS = TIMER_STATUS_MATCH0;   /* W1C — drops iop_irq */
    }
}

int main(void) {
    tick_count = 0;
    MAILBOX_W32[0] = 0;

    /* Enable MSTATUS.MIE (bit 3). */
    __asm__ volatile ("csrsi mstatus, 8");

    /* CMP0 = 99 cycles → match every 100 clk_iop ticks (auto-reload). */
    TIMER_CMP(0) = 99u | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET | TIMER_CTL_AUTO_RELOAD;
    TIMER_STATUS = TIMER_STATUS_MATCH0;       /* clear any stale flag */

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
