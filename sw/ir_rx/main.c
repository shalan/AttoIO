/*
 * ir_rx/main.c — E16.  Consumer-IR receiver: decodes a
 * NEC-protocol 32-bit frame from a demodulated IR stream on pad[3]
 * using the TIMER CAPTURE input.
 *
 * The TIMER's CNT runs free (auto-reload disabled), and every rising
 * edge on pad[3] latches CNT into TIMER_CAP and fires an IRQ.  The
 * ISR computes the delta from the previous capture and classifies it:
 *
 *   delta >= HEADER_MIN  -> frame header, reset bit collector
 *   HEADER_MIN > d >= BIT_THRESH -> bit 1 (longer space)
 *   d < BIT_THRESH       -> bit 0
 *
 * Timings are scaled 50x faster than real NEC so the sim finishes
 * quickly.  Real NEC header = 13.5 ms, bit-0 = 1.12 ms, bit-1 =
 * 2.25 ms; here we use 270 us, 22.4 us, 45 us (in clk_iop cycles at
 * 25 MHz: 6750, 560, 1125).
 *
 * Pin map:
 *   pad[3] = demodulated IR input (active HIGH; idle = LOW)
 *
 * Mailbox:
 *   word 0 = number of complete frames received
 *   word 1 = current bit count (progress indicator)
 *   word 2 = 0xC0DEC0DE once armed
 *   word 4 = last received frame (32-bit, MSB-first = bit received first)
 */

#include "../attoio.h"

#define CAP_PAD        3u

/* Classification thresholds in clk_iop cycles (25 MHz).  Chosen well
 * inside each band so capture jitter doesn't misclassify. */
#define HEADER_MIN     2000u   /* header delta ~6750, bit-1 ~1125 */
#define BIT_THRESH      842u   /* mid between bit-0 (560) and bit-1 (1125) */

volatile uint32_t frame;
volatile uint32_t bit_count;
volatile uint32_t last_cap;
volatile uint32_t state;       /* 0 = idle; 1 = collecting bits */
volatile uint32_t edge_count;
volatile uint32_t frames_received;

void __isr(void) {
    if (TIMER_STATUS & TIMER_STATUS_CAPTURE) {
        uint32_t cap = TIMER_CAP;
        uint32_t ec  = edge_count + 1;
        edge_count   = ec;

        if (ec == 1) {
            /* First edge after boot: no valid delta yet.  Just record
             * the timestamp and wait. */
            last_cap = cap;
            TIMER_STATUS = TIMER_STATUS_CAPTURE;
            return;
        }

        uint32_t delta = (cap - last_cap) & 0xFFFFFFu;
        last_cap = cap;

        if (delta >= HEADER_MIN) {
            /* Header detected — start a new frame collection. */
            frame      = 0;
            bit_count  = 0;
            state      = 1;
        } else if (state == 1 && bit_count < 32) {
            uint32_t bit = (delta >= BIT_THRESH) ? 1u : 0u;
            frame = (frame << 1) | bit;
            bit_count++;
            MAILBOX_W32[1] = bit_count;          /* progress */
            if (bit_count == 32) {
                MAILBOX_W32[4] = frame;
                uint32_t fr = frames_received + 1;
                frames_received = fr;
                state = 0;
                MAILBOX_W32[0] = fr;             /* sentinel LAST */
            }
        }

        TIMER_STATUS = TIMER_STATUS_CAPTURE;     /* W1C */
    }
}

int main(void) {
    frame            = 0;
    bit_count        = 0;
    last_cap         = 0;
    state            = 0;
    edge_count       = 0;
    frames_received  = 0;

    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;
    MAILBOX_W32[4] = 0;

    /* pad[3] as input (default, but be explicit). */
    GPIO_OE_CLR = 1u << CAP_PAD;

    __asm__ volatile ("csrsi mstatus, 8");

    /* Configure TIMER as free-running counter with capture on rising
     * edges of pad[3], capture IRQ enabled.  No CMP channels used. */
    TIMER_CTL = TIMER_CTL_EN | TIMER_CTL_RESET |
                ((CAP_PAD & 0xFu) << TIMER_CTL_CAP_PIN_SHIFT) |
                (0x1u << TIMER_CTL_CAP_EDGE_SHIFT) |   /* rising */
                TIMER_CTL_CAP_IRQ_EN;

    TIMER_STATUS = TIMER_STATUS_CAPTURE;              /* clear any stale */

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
