/*
 * dc_tacho/main.c — E11.  Brushed-DC driver with tacho feedback.
 *
 * The firmware simultaneously runs:
 *   - an IRQ-paced soft-PWM on pad[8] at a fixed 50 % duty (the
 *     "motor drive"), and
 *   - a tacho edge counter on pad[0] via TIMER CAPTURE (the speed
 *     sensor), with an auto-reloading gate that publishes the
 *     pulse count every 2 ms.
 *
 * Multi-source ISR dispatch:
 *   - TIMER CAPTURE  -> tacho_count++
 *   - TIMER MATCH0   -> bump PWM tick counter (and, once per PWM
 *                       cycle, publish tacho_count + clear).
 *
 * Pin map:
 *   pad[0]  = tacho input (open-collector, pulled up by external or
 *             TB; rising edges count)
 *   pad[8]  = PWM output to the H-bridge
 *   pad[9]  = direction (static, 0 = forward)
 *
 * Timing (clk_iop = 25 MHz):
 *   TIMER tick = 200 clk_iop = 8 µs
 *   PWM period = 32 ticks = 256 µs (~3.9 kHz)
 *   Gate      = 1 PWM period (published every ~256 µs)
 *
 * Mailbox:
 *   word 0 = last measured tacho count per gate window
 *   word 1 = global tick counter (monotonic, for debug)
 *   word 2 = 0xC0DEC0DE sentinel
 *
 * Deliberately small ISR: avoids the BUG-002 "many stores after
 * MMIO" pattern by only writing mailbox[0] + mailbox[1] per gate
 * and interleaving the MMIO writes (GPIO_OUT_SET / CLR) cleanly.
 */

#include "../attoio.h"

#define TACHO_PAD    0u
#define PWM_PAD      8u
#define DIR_PAD      9u

#define TICK_CYCLES  200u
#define PWM_PERIOD   32u
#define PWM_DUTY     16u    /* 50 % */

volatile uint32_t tick;
volatile uint32_t tacho_count;

void __isr(void) {
    uint32_t status = TIMER_STATUS;

    /* Capture: count a tacho pulse.  Handle first — a capture and a
     * gate tick can land in the same ISR invocation if they happen
     * on the same sysclk edge. */
    if (status & TIMER_STATUS_CAPTURE) {
        tacho_count++;
        TIMER_STATUS = TIMER_STATUS_CAPTURE;   /* W1C */
    }

    /* PWM tick: advance counter, drive the PWM pad.  On wrap-
     * around (once per PWM cycle) publish the tacho count and
     * clear it for the next window. */
    if (status & TIMER_STATUS_MATCH0) {
        uint32_t t = tick + 1u;
        if (t >= PWM_PERIOD) {
            t = 0;
            /* End-of-PWM-cycle: publish measurement.  Exactly two
             * mailbox writes — safely inside BUG-002's limit. */
            MAILBOX_W32[0] = tacho_count;
            tacho_count = 0;
        }
        tick = t;

        /* Drive the PWM pad based on tick vs. duty. */
        if (t < PWM_DUTY) GPIO_OUT_SET = 1u << PWM_PAD;
        else              GPIO_OUT_CLR = 1u << PWM_PAD;

        MAILBOX_W32[1] = t;
        TIMER_STATUS = TIMER_STATUS_MATCH0;     /* W1C */
    }
}

int main(void) {
    tick = 0;
    tacho_count = 0;
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;

    /* PWM + DIR as outputs (start LOW, DIR = 0 = forward). */
    GPIO_OUT_CLR = (1u << PWM_PAD) | (1u << DIR_PAD);
    GPIO_OE_SET  = (1u << PWM_PAD) | (1u << DIR_PAD);

    /* Tacho pin as input (OE already 0 by default). */
    GPIO_OE_CLR  = 1u << TACHO_PAD;

    __asm__ volatile ("csrsi mstatus, 8");

    /* CMP0 auto-reload tick. */
    TIMER_CMP(0) = (TICK_CYCLES - 1) | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;

    /* CAPTURE on pad[TACHO_PAD] rising edges, IRQ on capture. */
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET | TIMER_CTL_AUTO_RELOAD |
                   ((TACHO_PAD & 0xFu) << TIMER_CTL_CAP_PIN_SHIFT) |
                   (0x1u << TIMER_CTL_CAP_EDGE_SHIFT) |
                   TIMER_CTL_CAP_IRQ_EN;

    TIMER_STATUS = TIMER_STATUS_MATCH0 | TIMER_STATUS_CAPTURE;

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
