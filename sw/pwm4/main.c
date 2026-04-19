/*
 * pwm4/main.c — E8.  IRQ-paced 4-channel soft PWM.
 *
 * The TIMER generates a periodic tick IRQ; the ISR maintains a
 * global tick counter (0..PERIOD-1 with wrap) and drives four pads
 * HIGH while `tick < duty[i]`, LOW otherwise.
 *
 * Pin map:
 *   pad[8]  = channel 0
 *   pad[9]  = channel 1
 *   pad[10] = channel 2
 *   pad[11] = channel 3
 *
 * Duties for this demo:
 *   ch0 = 25 %  (8 / 32 ticks)
 *   ch1 = 50 %  (16 / 32)
 *   ch2 = 75 %  (24 / 32)
 *   ch3 = 100 % (32 / 32, always HIGH)
 *
 * Timing (clk_iop = 25 MHz):
 *   tick  = 200 clk_iop = 8 µs
 *   PWM   = 32 ticks = 256 µs (~3.9 kHz carrier)
 *
 * Mailbox:
 *   word 0 = global tick counter (monotonic)
 *   word 2 = 0xC0DEC0DE sentinel once main() reaches WFI
 */

#include "../attoio.h"

#define TICK_CYCLES   200u
#define PWM_PERIOD    32u
#define NUM_CH        4
#define FIRST_PAD     8u

static const uint32_t duty[NUM_CH] = { 8, 16, 24, 32 };
static const uint32_t pad_mask[NUM_CH] = {
    1u << (FIRST_PAD + 0),
    1u << (FIRST_PAD + 1),
    1u << (FIRST_PAD + 2),
    1u << (FIRST_PAD + 3)
};

volatile uint32_t tick;

void __isr(void) {
    if (TIMER_STATUS & TIMER_STATUS_MATCH0) {
        uint32_t t = tick + 1u;
        if (t >= PWM_PERIOD) t = 0;
        tick = t;
        MAILBOX_W32[0] = t;

        /* Drive pads based on duty comparison.  Use SET/CLR aliases
         * so we only touch the pads we own; pad[0..7,12..15] are
         * untouched. */
        uint32_t set = 0, clr = 0;
        for (int i = 0; i < NUM_CH; i++) {
            if (t < duty[i]) set |= pad_mask[i];
            else             clr |= pad_mask[i];
        }
        if (set) GPIO_OUT_SET = set;
        if (clr) GPIO_OUT_CLR = clr;

        TIMER_STATUS = TIMER_STATUS_MATCH0;  /* W1C */
    }
}

int main(void) {
    tick = 0;
    MAILBOX_W32[0] = 0;

    /* All four pads as outputs, start LOW. */
    GPIO_OUT_CLR = (1u << FIRST_PAD)     | (1u << (FIRST_PAD + 1)) |
                   (1u << (FIRST_PAD + 2)) | (1u << (FIRST_PAD + 3));
    GPIO_OE_SET  = (1u << FIRST_PAD)     | (1u << (FIRST_PAD + 1)) |
                   (1u << (FIRST_PAD + 2)) | (1u << (FIRST_PAD + 3));

    __asm__ volatile ("csrsi mstatus, 8");

    /* Periodic tick IRQ, auto-reload. */
    TIMER_CMP(0) = (TICK_CYCLES - 1) | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET | TIMER_CTL_AUTO_RELOAD;
    TIMER_STATUS = TIMER_STATUS_MATCH0;

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
