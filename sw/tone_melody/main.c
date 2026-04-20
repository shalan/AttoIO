/*
 * tone_melody/main.c — E12.  Bit-banged buzzer melody: hardware pad-
 * toggle on TIMER CMP0 sets the *pitch*, a periodic IRQ on TIMER CMP1
 * sets the *beat* and advances a note table.
 *
 * Pin map:
 *   pad[8] = buzzer / piezo (square-wave out)
 *
 * Two TIMER channels co-operate — CMP0 auto-reloads on every match
 * so CNT resets to 0, CMP1 is therefore a fixed milestone in the
 * same CNT that fires once per reload cycle and never again because
 * CMP0 restarts the timer first.  We don't use CMP1 that way:
 * instead, we use CMP0 alone for the pitch (auto-reload + pad
 * toggle) and a DIFFERENT CMP channel for the beat, with explicit
 * count resets.
 *
 * Actually simplest: run a global CNT that CMP0 auto-reloads each
 * half-period.  That means the CNT never reaches any CMP1 value we'd
 * pick.  Solution: don't use AUTO_RELOAD.  Instead keep the counter
 * free-running (no reset on CMP0 match), and set CMP0 to toggle pad
 * every 2*half_period cycles — no, the CMP0 match is only *one*
 * edge.
 *
 * Cleanest: run the counter free (no auto-reload), let CMP0 fire at
 * a value and software advances CMP0 forward by the half-period in
 * its own IRQ.  But we already saturate ISR bandwidth at 10 kHz+.
 *
 * Practical compromise for this demo: use CMP0 pad-toggle WITH
 * auto-reload for the pitch (so pad flips every half-period), and
 * use the ALREADY-FREE CMP1 in a loose *software pacing* mode —
 * main() busy-loops on the TIMER CNT rolling over N times to
 * schedule note advancement.  That keeps the ISR tight.
 *
 * Even simpler: precompute note_half_period[i] and use a long wfi /
 * csrr cycle counter path.  But we don't have cycle CSRs.
 *
 * Final simple design we actually ship:
 *   - CMP0 = half-period | PAD_TOGGLE | AUTO_RELOAD  (pitch)
 *   - Each note lasts a fixed BEAT_TOGGLES number of pad-toggles
 *     (proportional to pitch, so higher pitches get more "beats" but
 *     same wall-clock duration).
 *   - CMP0 also fires an IRQ; the ISR counts its own invocations and
 *     when the per-note threshold is reached, switches to the next
 *     note's half-period.
 *
 * Pin out:
 *   pad[8] = square-wave output (auto-toggled by hardware)
 *
 * Mailbox:
 *   word 0 = current note index (0..NOTES)
 *   word 2 = 0xC0DEC0DE once armed
 *   word 3 = done sentinel = 0xD0NE0DE7 when melody finished
 */

#include "../attoio.h"

#define BUZZ_PAD 8u
#define NOTES    4

/* Half-periods in clk_iop cycles at clk_iop = 25 MHz.
 * Frequency = clk_iop / (2 * half_period).
 *   1249 → ~10.0 kHz
 *   1041 → ~12.0 kHz
 *    833 → ~15.0 kHz
 *    624 → ~20.0 kHz
 */
static const uint16_t half_period[NOTES] = { 1249, 1041, 833, 624 };

/* Per-note duration expressed as number of CMP0 matches.  We target
 * ~2 ms per note: at the highest frequency (20 kHz, 40 kHz toggle
 * rate) that's 80 toggles; at 10 kHz that's 40.  We use the high-
 * frequency count so every note lasts *at least* 2 ms — simpler than
 * a per-note scaling table, and the slower notes just last longer
 * (fine for a demo). */
#define BEAT_TOGGLES 80

volatile uint32_t toggle_count;
volatile uint32_t note_idx;

void __isr(void) {
    if (TIMER_STATUS & TIMER_STATUS_MATCH0) {
        uint32_t tc = toggle_count + 1;
        toggle_count = tc;

        if (tc >= BEAT_TOGGLES) {
            uint32_t n = note_idx + 1;
            note_idx     = n;
            toggle_count = 0;

            if (n >= NOTES) {
                /* Melody done: disable CMP0 so the pad stops toggling. */
                TIMER_CMP(0) = 0;
                TIMER_CTL    = 0;
                MAILBOX_W32[3] = 0xD0DE0DE7u;   /* magic */
                MAILBOX_W32[0] = n;             /* sentinel last */
            } else {
                /* Reprogram CMP0 for the next pitch.  Keep pad toggle +
                 * IRQ + enable bits set. */
                TIMER_CMP(0) = (half_period[n] - 1) |
                               TIMER_CMP_PAD(BUZZ_PAD) |
                               TIMER_CMP_EN |
                               TIMER_CMP_IRQ_EN |
                               TIMER_CMP_PAD_TOGGLE;
                MAILBOX_W32[0] = n;              /* sentinel last */
            }
        }

        TIMER_STATUS = TIMER_STATUS_MATCH0;      /* W1C */
    }
}

int main(void) {
    toggle_count = 0;
    note_idx     = 0;
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[3] = 0;

    /* pad[8] as an output, start LOW. */
    GPIO_OUT_CLR = 1u << BUZZ_PAD;
    GPIO_OE_SET  = 1u << BUZZ_PAD;

    __asm__ volatile ("csrsi mstatus, 8");

    /* Arm CMP0 with the first note's half-period. */
    TIMER_CMP(0) = (half_period[0] - 1) |
                   TIMER_CMP_PAD(BUZZ_PAD) |
                   TIMER_CMP_EN |
                   TIMER_CMP_IRQ_EN |
                   TIMER_CMP_PAD_TOGGLE;
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET | TIMER_CTL_AUTO_RELOAD;
    TIMER_STATUS = TIMER_STATUS_MATCH0;

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
