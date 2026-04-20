/*
 * pdm_dac/main.c — E14.  1-bit PDM (pulse-density-modulation) DAC
 * driven by a first-order sigma-delta modulator.
 *
 * Instead of varying the pulse WIDTH within a fixed period (PWM),
 * PDM emits a stream of fixed-width 1-bit pulses whose DENSITY over
 * time represents the sample value.  A 1-bit line fed through a
 * single-pole RC low-pass becomes analog audio; used on modern MEMS
 * microphones and class-D amps.
 *
 * 1st-order delta-sigma loop:
 *   acc += sample                     // each PDM cycle
 *   if (acc >= THRESHOLD) {
 *       pad = HIGH
 *       acc -= THRESHOLD
 *   } else {
 *       pad = LOW
 *   }
 *
 * Over many cycles, fraction of 1s converges to sample/THRESHOLD.
 *
 * Pin map:
 *   pad[8] = PDM 1-bit output
 *
 * Parameters:
 *   PDM_PERIOD = 250 clk_iop cycles (~100 kHz PDM at clk_iop=25 MHz)
 *   THRESHOLD  = 256
 *   4 sample values x 64 PDM pulses each = 256 pulses total
 *
 *     sample=64  -> expected density 25 % -> ~16 HIGH pulses / 64
 *     sample=128 ->                  50 % -> ~32
 *     sample=192 ->                  75 % -> ~48
 *     sample=255 -> almost 100%           -> ~64  (255/256 ratio)
 *
 * Mailbox:
 *   word 0 = total PDM pulse count (ISR-local)
 *   word 1 = current sample index
 *   word 2 = 0xC0DEC0DE once armed
 *   word 3 = 0x5A5ED0DE after the full sequence
 */

#include "../attoio.h"

#define PDM_PAD           8u
#define PDM_PERIOD        250u      /* clk_iop cycles per PDM bit */
#define THRESHOLD         256u
#define N_SAMPLES         4
#define PULSES_PER_SAMPLE 64u

static const uint16_t samples[N_SAMPLES] = { 64, 128, 192, 255 };

volatile uint32_t accumulator;
volatile uint32_t pulse_count;
volatile uint32_t pulses_in_sample;
volatile uint32_t sample_idx;
volatile uint32_t current_sample;

void __isr(void) {
    if (TIMER_STATUS & TIMER_STATUS_MATCH0) {
        uint32_t acc = accumulator + current_sample;
        if (acc >= THRESHOLD) {
            GPIO_OUT_SET = 1u << PDM_PAD;
            acc -= THRESHOLD;
        } else {
            GPIO_OUT_CLR = 1u << PDM_PAD;
        }
        accumulator = acc;

        uint32_t pc = pulse_count + 1;
        pulse_count = pc;

        uint32_t pis = pulses_in_sample + 1;
        if (pis >= PULSES_PER_SAMPLE) {
            uint32_t n = sample_idx + 1;
            if (n >= N_SAMPLES) {
                TIMER_CMP(0)   = 0;
                TIMER_CTL      = 0;
                GPIO_OUT_CLR   = 1u << PDM_PAD;
                MAILBOX_W32[1] = n;
                MAILBOX_W32[3] = 0x5A5ED0DEu;
                MAILBOX_W32[0] = pc;
                TIMER_STATUS   = TIMER_STATUS_MATCH0;
                return;
            }
            sample_idx       = n;
            current_sample   = samples[n];
            pulses_in_sample = 0;
            MAILBOX_W32[1]   = n;
        } else {
            pulses_in_sample = pis;
        }

        MAILBOX_W32[0] = pc;                 /* sentinel LAST */
        TIMER_STATUS   = TIMER_STATUS_MATCH0;
    }
}

int main(void) {
    accumulator      = 0;
    pulse_count      = 0;
    pulses_in_sample = 0;
    sample_idx       = 0;
    current_sample   = samples[0];
    MAILBOX_W32[0]   = 0;
    MAILBOX_W32[1]   = 0;
    MAILBOX_W32[3]   = 0;

    GPIO_OUT_CLR = 1u << PDM_PAD;
    GPIO_OE_SET  = 1u << PDM_PAD;

    __asm__ volatile ("csrsi mstatus, 8");

    TIMER_CMP(0)  = (PDM_PERIOD - 1) | TIMER_CMP_EN | TIMER_CMP_IRQ_EN;
    TIMER_CTL     = TIMER_CTL_EN | TIMER_CTL_RESET | TIMER_CTL_AUTO_RELOAD;
    TIMER_STATUS  = TIMER_STATUS_MATCH0;

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
