/*
 * stepper/main.c — E9.  STEP/DIR stepper driver with a trapezoidal
 * velocity ramp (accelerate, cruise, decelerate).
 *
 * Pin map:
 *   pad[8]  = STEP   (rising edge = one step)
 *   pad[9]  = DIR    (level: 0 = forward, 1 = reverse)
 *
 * TIMER is used as a one-shot interval timer: the ISR pulses STEP
 * HIGH briefly, bumps step_count, and reprograms CMP0 with the
 * next interval from a precomputed table before self-resetting.
 *
 * Ramp profile (30 steps total, all forward):
 *   steps 0..9    accel    200 → 65 clk_iop cycles per step
 *   steps 10..19  cruise   60 clk_iop
 *   steps 20..29  decel    65 → 200 clk_iop
 *
 * Mailbox layout:
 *   word 0 = step count
 *   word 1 = done sentinel (0 during motion, 0xDONE when stopped)
 *   word 2 = 0xC0DEC0DE once main() armed
 *   word 3 = last interval used (for TB inspection)
 *
 * Total motion ~3700 clk_iop = ~150 µs @ 25 MHz, so the sim
 * finishes fast.
 */

#include "../attoio.h"

#define STEP_PAD   8u
#define DIR_PAD    9u
#define N_STEPS    30
#define DONE_MAGIC 0x57EDD07Eu   /* STED DOTE — stepper motion complete */

static const uint16_t intervals[N_STEPS] = {
    /* accel */  200, 180, 160, 140, 120, 100,  85,  75,  70,  65,
    /* cruise*/   60,  60,  60,  60,  60,  60,  60,  60,  60,  60,
    /* decel */   65,  70,  75,  85, 100, 120, 140, 160, 180, 200
};

volatile uint32_t step_count;

void __isr(void) {
    if (TIMER_STATUS & TIMER_STATUS_MATCH0) {
        uint32_t s = step_count;

        /* Pulse STEP briefly — the driver latches on the rising edge;
         * two consecutive SET/CLR writes are more than enough setup
         * time for any sane downstream driver. */
        GPIO_OUT_SET = 1u << STEP_PAD;
        GPIO_OUT_CLR = 1u << STEP_PAD;

        s++;
        step_count     = s;
        MAILBOX_W32[0] = s;

        TIMER_STATUS = TIMER_STATUS_MATCH0;   /* W1C first */

        if (s < N_STEPS) {
            /* Arm the next interval.  CMP_EN + IRQ_EN; no pad toggle. */
            uint32_t ival = intervals[s];
            MAILBOX_W32[3] = ival;
            TIMER_CMP(0)   = (ival - 1) | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;
            TIMER_CTL      = TIMER_CTL_EN | TIMER_CTL_RESET;
        } else {
            /* Motion complete — stop the timer and signal done. */
            TIMER_CMP(0)   = 0;                 /* disable */
            TIMER_CTL      = 0;
            MAILBOX_W32[1] = DONE_MAGIC;
        }
    }
}

int main(void) {
    step_count = 0;
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;
    MAILBOX_W32[3] = 0;

    /* STEP + DIR as outputs, start LOW; DIR=0 (forward). */
    GPIO_OUT_CLR = (1u << STEP_PAD) | (1u << DIR_PAD);
    GPIO_OE_SET  = (1u << STEP_PAD) | (1u << DIR_PAD);

    __asm__ volatile ("csrsi mstatus, 8");

    /* Arm the first step's interval.  TIMER_CTL_RESET zeroes CNT,
     * CMP0 will fire after `intervals[0]` clk_iop cycles. */
    TIMER_CMP(0)  = (intervals[0] - 1) | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;
    TIMER_CTL     = TIMER_CTL_EN | TIMER_CTL_RESET;
    TIMER_STATUS  = TIMER_STATUS_MATCH0;

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
