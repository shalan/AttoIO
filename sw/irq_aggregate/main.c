/*
 * irq_aggregate/main.c — verifies multi-source IRQ aggregation.
 *
 * Two sources are armed simultaneously:
 *   - TIMER channel 0 with auto-reload + IRQ enable (periodic IRQ).
 *   - GPIO wake on pad[5] rising edge.
 *
 * Both feed iop_irq through the macro's flat OR (no PIC), so the ISR
 * doesn't get told *which* source fired — it has to poll each
 * source's status register and W1C-clear what it found.
 *
 * Mailbox layout:
 *   word 0 = timer-tick count
 *   word 1 = wake count
 *   word 2 = 0xC0DEC0DE sentinel once main() reaches WFI
 *   word 4 = snapshot of WAKE_FLAGS at the most-recent wake IRQ
 *   word 5 = snapshot of TIMER_STATUS at the most-recent timer IRQ
 *
 * After each ISR run we pulse C2H so the host can read the mailbox
 * without racing the IOP's loads (see tb_irq_doorbell for the SRAM-B
 * arbitration race that motivates this pattern).
 */

#include "../attoio.h"

volatile uint32_t timer_count;
volatile uint32_t wake_count;

void __isr(void) {
    /* Poll each source.  Order doesn't matter — we handle all that
     * are pending in this single entry. */
    int handled = 0;

    uint32_t ts = TIMER_STATUS;
    if (ts & TIMER_STATUS_MATCH0) {
        timer_count++;
        MAILBOX_W32[5] = ts;
        MAILBOX_W32[0] = timer_count;
        TIMER_STATUS = TIMER_STATUS_MATCH0;
        handled = 1;
    }

    uint32_t wf = WAKE_FLAGS;
    if (wf) {
        wake_count++;
        MAILBOX_W32[4] = wf;
        MAILBOX_W32[1] = wake_count;
        WAKE_FLAGS = wf;          /* W1C all reported flags */
        handled = 1;
    }

    if (handled) doorbell_c2h_raise();
}

int main(void) {
    timer_count = 0;
    wake_count  = 0;
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;

    __asm__ volatile ("csrsi mstatus, 8");

    /* TIMER: slow auto-reload (~10000 cycles per tick) so the host has
     * time to wedge a WAKE in between ticks. */
    TIMER_CMP(0)  = (10000u - 1u) | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;
    TIMER_CTL     = TIMER_CTL_EN | TIMER_CTL_RESET | TIMER_CTL_AUTO_RELOAD;
    TIMER_STATUS  = TIMER_STATUS_MATCH0;

    /* WAKE: rising edge on pad[5]. */
    wake_set_edge(5, WAKE_EDGE_RISE);
    wake_enable(5);

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
