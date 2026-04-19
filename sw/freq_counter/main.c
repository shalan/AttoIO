/*
 * freq_counter/main.c — E22.  Edge-counting frequency counter on
 * pad[7], fully IRQ-driven.
 *
 * Stimulus: an external square wave on pad[7].
 *
 * TIMER configuration:
 *   - CMP0 = GATE_CYCLES-1, auto-reload, IRQ on match   (gate window)
 *   - CAP  = rising edges on pad[7], IRQ on capture     (event source)
 *
 * ISR (multi-source):
 *   - CAPTURE flag set?  -> edge_count++, log last CAP timestamp
 *   - MATCH0 flag set?   -> publish edge_count as "measurement",
 *                           increment window index, zero count for
 *                           the next gate window.
 *
 * Mailbox layout:
 *   word 0 = last measured count (edges per GATE window)
 *   word 1 = window index (monotonic)
 *   word 2 = 0xC0DEC0DE sentinel once main() reaches WFI
 *   word 3 = last CAP timestamp (for debug / TB inspection)
 *
 * Gate: 2 ms at clk_iop = 25 MHz -> 50,000 cycles.  At a 10 kHz
 * stimulus this window should count ~20 rising edges.
 */

#include "../attoio.h"

#define CAP_PAD        7u
#define GATE_CYCLES    50000u     /* 2 ms @ 25 MHz clk_iop */

volatile uint32_t edge_count;
volatile uint32_t window_idx;

void __isr(void) {
    uint32_t status = TIMER_STATUS;

    /* Handle capture first — count every edge before the gate tick
     * potentially overwrites it. */
    if (status & TIMER_STATUS_CAPTURE) {
        MAILBOX_W32[3] = TIMER_CAP;   /* last timestamp, debug aid */
        edge_count++;
        TIMER_STATUS = TIMER_STATUS_CAPTURE;   /* W1C */
    }

    /* Gate tick: publish the count and start fresh. */
    if (status & TIMER_STATUS_MATCH0) {
        MAILBOX_W32[0] = edge_count;           /* measurement */
        edge_count    = 0;
        window_idx++;
        MAILBOX_W32[1] = window_idx;
        TIMER_STATUS  = TIMER_STATUS_MATCH0;   /* W1C */
    }
}

int main(void) {
    edge_count = 0;
    window_idx = 0;
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;
    MAILBOX_W32[3] = 0;

    /* Make sure pad[7] is an input (OE=0, OUT=0 — default at reset). */
    GPIO_OE_CLR  = 1u << CAP_PAD;
    GPIO_OUT_CLR = 1u << CAP_PAD;

    /* Enable MSTATUS.MIE (bit 3). */
    __asm__ volatile ("csrsi mstatus, 8");

    /* Arm CMP0 as periodic gate with IRQ (no pad toggle). */
    TIMER_CMP(0)  = (GATE_CYCLES - 1) | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;

    /* Arm CAPTURE on pad[CAP_PAD] rising edges, IRQ on capture. */
    TIMER_CTL     = TIMER_CTL_EN | TIMER_CTL_RESET | TIMER_CTL_AUTO_RELOAD |
                    ((CAP_PAD & 0xFu) << TIMER_CTL_CAP_PIN_SHIFT) |
                    (0x1u << TIMER_CTL_CAP_EDGE_SHIFT) |   /* rising only */
                    TIMER_CTL_CAP_IRQ_EN;

    TIMER_STATUS  = TIMER_STATUS_MATCH0 | TIMER_STATUS_CAPTURE;  /* clear */

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
