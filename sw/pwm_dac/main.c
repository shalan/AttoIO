/*
 * pwm_dac/main.c — E13.  8-bit PWM DAC, soft-PWM construction:
 *
 *   - CMP0 = PERIOD - 1, IRQ only, auto-reload (marks end of period)
 *   - CMP1 = duty value,  IRQ only                (intra-period toggle)
 *
 * ISR drives pad[8]:
 *   - on CMP0 match: pad HIGH, advance sample if its hold expired,
 *                    reprogram CMP1 with the new sample's duty.
 *   - on CMP1 match: pad LOW.
 *
 * We use a LARGE PERIOD (2048 clk_iop cycles, ~82 µs = 12.2 kHz
 * carrier at clk_iop = 25 MHz) so the ~80-cycle ISR overhead is
 * negligible relative to the duty resolution.  External RC on pad[8]
 * recovers analog audio.
 *
 * Pin map:
 *   pad[8] = PWM audio output
 *
 * Sample table: triangle through 8 points, each held for 1 carrier
 * period, 8 periods total = ~655 µs sim time.
 *
 * Mailbox:
 *   word 0 = period count (bumps every CMP0 match, used as sentinel)
 *   word 1 = current sample index
 *   word 2 = 0xC0DEC0DE once armed
 *   word 3 = 0x5A5ED0DE after the full sequence
 */

#include "../attoio.h"

#define PWM_PAD      8u
#define PERIOD       2048u
#define N_SAMPLES    8
#define HOLD_PERIODS 1

/* Duty = HIGH cycles per period.  Values kept well inside
 * [ISR_overhead .. PERIOD - ISR_overhead] so the measurement is
 * clean. */
static const uint16_t sample_duty[N_SAMPLES] = {
    256, 512, 1024, 1792, 1024, 512, 256, 128
};

volatile uint32_t period_count;
volatile uint32_t sample_idx;
volatile uint32_t hold_remaining;

void __isr(void) {
    uint32_t status = TIMER_STATUS;

    if (status & TIMER_STATUS_MATCH0) {
        /* Period boundary: drive pad HIGH. */
        GPIO_OUT_SET = 1u << PWM_PAD;

        uint32_t pc = period_count + 1;
        period_count = pc;

        uint32_t h = hold_remaining;
        if (h > 1) {
            hold_remaining = h - 1;
        } else {
            uint32_t n = sample_idx + 1;
            if (n >= N_SAMPLES) {
                /* Done — disable compares, leave pad in whatever
                 * state it's in (we drop it LOW explicitly). */
                TIMER_CMP(0) = 0;
                TIMER_CMP(1) = 0;
                TIMER_CTL    = 0;
                GPIO_OUT_CLR = 1u << PWM_PAD;
                MAILBOX_W32[1] = n;
                MAILBOX_W32[3] = 0x5A5ED0DEu;
                MAILBOX_W32[0] = pc;
                TIMER_STATUS = TIMER_STATUS_MATCH0;
                return;
            }
            sample_idx     = n;
            hold_remaining = HOLD_PERIODS;
            /* Program the next sample's duty.  No pad toggle — we
             * only want the IRQ. */
            TIMER_CMP(1) = sample_duty[n] |
                           TIMER_CMP_EN | TIMER_CMP_IRQ_EN;
            MAILBOX_W32[1] = n;
        }

        MAILBOX_W32[0] = pc;               /* sentinel LAST */
        TIMER_STATUS   = TIMER_STATUS_MATCH0;
    }

    if (status & TIMER_STATUS_MATCH1) {
        /* Duty point: drive pad LOW. */
        GPIO_OUT_CLR = 1u << PWM_PAD;
        TIMER_STATUS = TIMER_STATUS_MATCH1;
    }
}

int main(void) {
    period_count   = 0;
    sample_idx     = 0;
    hold_remaining = HOLD_PERIODS;
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;
    MAILBOX_W32[3] = 0;

    /* pad[8] as output, start HIGH so the first carrier period's
     * leading HIGH interval is present before the first CMP1. */
    GPIO_OUT_SET = 1u << PWM_PAD;
    GPIO_OE_SET  = 1u << PWM_PAD;

    __asm__ volatile ("csrsi mstatus, 8");

    /* Arm CMP0 (period) and CMP1 (first sample's duty). */
    TIMER_CMP(0)  = (PERIOD - 1) | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;
    TIMER_CMP(1)  = sample_duty[0] | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;
    TIMER_CTL     = TIMER_CTL_EN | TIMER_CTL_RESET | TIMER_CTL_AUTO_RELOAD;
    TIMER_STATUS  = TIMER_STATUS_MATCH0 | TIMER_STATUS_MATCH1;

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
