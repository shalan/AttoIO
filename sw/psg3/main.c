/*
 * psg3/main.c — E15.  3-voice PSG-style square-wave synth.
 *
 * Mimics the tone generators of classic sound chips (SN76489 /
 * AY-3-8910 / POKEY):
 *   - 3 independent voices, each a square wave with its own period
 *   - Voices are software-maintained in the TIMER sample-clock ISR
 *   - Each voice has its own output pad (pads 8, 9, 10)
 *
 * Sample clock = 100 kHz (250 clk_iop at clk_iop=25 MHz).
 * Each ISR increments each voice's phase counter; when the counter
 * reaches the voice's half-period, the voice flips its output bit
 * and resets the phase.
 *
 * Voice pitches (at 100 kHz sample rate):
 *   voice 0 half=10  ->  5.0 kHz tone  (pad[8])
 *   voice 1 half=5   -> 10.0 kHz tone  (pad[9])
 *   voice 2 half=2   -> 25.0 kHz tone  (pad[10])
 *
 * The FW runs exactly N_SAMPLES sample clocks then disables the
 * TIMER and publishes the done sentinel.  TB observes pad rising
 * edges and verifies each voice's frequency.
 *
 * Mailbox:
 *   word 0 = sample count (bumps every ISR, used as sentinel)
 *   word 1 = live voice_bits snapshot  (debug aid)
 *   word 2 = 0xC0DEC0DE once armed
 *   word 3 = 0x5A5ED0DE after the full sequence
 */

#include "../attoio.h"

#define V0_PAD 8u
#define V1_PAD 9u
#define V2_PAD 10u
#define V_MASK ((1u << V0_PAD) | (1u << V1_PAD) | (1u << V2_PAD))

#define SAMPLE_PERIOD 250u     /* clk_iop per sample (~100 kHz) */
#define N_SAMPLES     200u     /* total run length in samples */

#define V0_HALF 10u
#define V1_HALF 5u
#define V2_HALF 2u

volatile uint32_t sample_count;
volatile uint32_t v_phase0, v_phase1, v_phase2;
volatile uint32_t v_out0,   v_out1,   v_out2;

void __isr(void) {
    if (TIMER_STATUS & TIMER_STATUS_MATCH0) {
        /* Voice 0 */
        uint32_t p0 = v_phase0 + 1;
        if (p0 >= V0_HALF) {
            p0 = 0;
            if (v_out0) {
                v_out0 = 0;
                GPIO_OUT_CLR = 1u << V0_PAD;
            } else {
                v_out0 = 1;
                GPIO_OUT_SET = 1u << V0_PAD;
            }
        }
        v_phase0 = p0;

        /* Voice 1 */
        uint32_t p1 = v_phase1 + 1;
        if (p1 >= V1_HALF) {
            p1 = 0;
            if (v_out1) {
                v_out1 = 0;
                GPIO_OUT_CLR = 1u << V1_PAD;
            } else {
                v_out1 = 1;
                GPIO_OUT_SET = 1u << V1_PAD;
            }
        }
        v_phase1 = p1;

        /* Voice 2 */
        uint32_t p2 = v_phase2 + 1;
        if (p2 >= V2_HALF) {
            p2 = 0;
            if (v_out2) {
                v_out2 = 0;
                GPIO_OUT_CLR = 1u << V2_PAD;
            } else {
                v_out2 = 1;
                GPIO_OUT_SET = 1u << V2_PAD;
            }
        }
        v_phase2 = p2;

        uint32_t sc = sample_count + 1;
        sample_count = sc;

        if (sc >= N_SAMPLES) {
            /* End of run — disable TIMER, drop all voice pads LOW,
             * publish done sentinel. */
            TIMER_CMP(0)   = 0;
            TIMER_CTL      = 0;
            GPIO_OUT_CLR   = V_MASK;
            MAILBOX_W32[3] = 0x5A5ED0DEu;
            MAILBOX_W32[0] = sc;
            TIMER_STATUS   = TIMER_STATUS_MATCH0;
            return;
        }

        MAILBOX_W32[0] = sc;         /* sentinel LAST */
        TIMER_STATUS   = TIMER_STATUS_MATCH0;
    }
}

int main(void) {
    sample_count = 0;
    v_phase0 = v_phase1 = v_phase2 = 0;
    v_out0   = v_out1   = v_out2   = 0;
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[3] = 0;

    /* All three voice pads as outputs, starting LOW. */
    GPIO_OUT_CLR = V_MASK;
    GPIO_OE_SET  = V_MASK;

    __asm__ volatile ("csrsi mstatus, 8");

    TIMER_CMP(0)  = (SAMPLE_PERIOD - 1) | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;
    TIMER_CTL     = TIMER_CTL_EN | TIMER_CTL_RESET | TIMER_CTL_AUTO_RELOAD;
    TIMER_STATUS  = TIMER_STATUS_MATCH0;

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
