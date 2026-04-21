/*
 * ir_tx/main.c — E17.  NEC-protocol IR transmitter.
 *
 * Drives pad[8] with the demodulated NEC envelope for a known
 * 32-bit payload.  Same 50x-scaled timings as E16 (tb_ir_rx) so the
 * two examples can be cross-verified with the same TB-side
 * measurement framework.
 *
 * Real NEC uses an ~38 kHz carrier on the mark intervals; here we
 * emit only the envelope (what a real IR receiver would produce
 * after demodulation).  Generating the carrier is a trivial add-on:
 * a second TIMER CMP in pad-toggle mode on a separate pad, gated by
 * the envelope via a sw pad-select bit — left as an exercise since
 * E12 tone_melody already shows the carrier-generation pattern.
 *
 * Absolute-time scheduling: we start TIMER CNT once at frame start
 * and schedule every edge at a computed absolute CNT value.  This
 * way the CUMULATIVE FW overhead (MMIO writes, loop bookkeeping)
 * doesn't drift the bit timings — a small ±few-cycle jitter at each
 * transition, not an accumulating error.
 *
 * Pin map:
 *   pad[8] = NEC envelope out  (idle LOW, mark = HIGH)
 *
 * Mailbox:
 *   word 0 = done sentinel (1 when the frame has finished)
 *   word 1 = payload transmitted (debug readback)
 *   word 2 = 0xC0DEC0DE once armed
 */

#include "../attoio.h"

#define TX_PAD              8u
#define TX_MASK             (1u << TX_PAD)

#define HEADER_MARK_CYC     4500u   /* 180 µs @ clk_iop = 25 MHz */
#define HEADER_SPACE_CYC    2250u   /*  90 µs */
#define BIT_MARK_CYC         280u   /*  11.2 µs */
#define BIT0_SPACE_CYC       280u   /*  11.2 µs */
#define BIT1_SPACE_CYC       845u   /*  33.8 µs */

#define TX_FRAME            0xABCD1234u

static inline void wait_until(uint32_t target) {
    TIMER_CMP(0)  = (target - 1u) | TIMER_CMP_EN;
    TIMER_STATUS  = TIMER_STATUS_MATCH0;
    while (!(TIMER_STATUS & TIMER_STATUS_MATCH0)) { }
    TIMER_STATUS  = TIMER_STATUS_MATCH0;
}

int main(void) {
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = TX_FRAME;

    /* pad[8] as output, start LOW. */
    GPIO_OUT_CLR = TX_MASK;
    GPIO_OE_SET  = TX_MASK;

    MAILBOX_W32[2] = 0xC0DEC0DEu;

    /* Start the TIMER free-running (no auto-reload) — we'll program
     * CMP0 with successive absolute target values for each edge. */
    TIMER_CMP(0) = 0;
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET;

    uint32_t t = 0;

    /* ----- Header ----- */
    GPIO_OUT_SET = TX_MASK;            /* rising edge (header mark start) */
    t = HEADER_MARK_CYC;
    wait_until(t);
    GPIO_OUT_CLR = TX_MASK;            /* end of header mark */
    t += HEADER_SPACE_CYC;
    wait_until(t);

    /* ----- 32 data bits, MSB first ----- */
    for (int i = 31; i >= 0; i--) {
        GPIO_OUT_SET = TX_MASK;        /* bit mark start */
        t += BIT_MARK_CYC;
        wait_until(t);
        GPIO_OUT_CLR = TX_MASK;        /* mark end, space start */
        if ((TX_FRAME >> i) & 1u) t += BIT1_SPACE_CYC;
        else                      t += BIT0_SPACE_CYC;
        wait_until(t);
    }

    /* ----- Trailer mark (final closing pulse for RX decoders) ----- */
    GPIO_OUT_SET = TX_MASK;
    t += BIT_MARK_CYC;
    wait_until(t);
    GPIO_OUT_CLR = TX_MASK;

    /* Stop TIMER, publish done sentinel LAST. */
    TIMER_CTL      = 0;
    MAILBOX_W32[0] = 1;

    while (1) wfi();
}
