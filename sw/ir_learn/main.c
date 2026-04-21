/*
 * ir_learn/main.c — E18.  Universal learning remote.
 *
 * Two phases:
 *   1. LEARN — TIMER CAPTURE on both edges of pad[3] records the
 *      timestamps of N incoming edges into an in-memory buffer.
 *   2. REPLAY — after capture completes, the FW reconstructs the
 *      inter-edge deltas and emits the same pattern on pad[8] using
 *      absolute-time scheduling (like E17).
 *
 * Buffer holds N_EDGES timestamps, so N_EDGES-1 inter-edge deltas
 * are reproduced.  The first replay edge fires immediately at
 * replay start; subsequent edges fire at cumulative delta offsets.
 *
 * No hard-coded protocol — same FW works for NEC, Sony SIRC, RC-5,
 * or any raw edge pattern (up to N_EDGES transitions).  The TB
 * picks a short canned pattern so the whole capture + replay fits
 * in ~500 µs of sim time.
 *
 * Pin map:
 *   pad[3] = demodulated IR input (both edges)
 *   pad[8] = replay output
 *
 * Mailbox:
 *   word 0 = phase sentinel (1 = LEARN done, 2 = REPLAY done)
 *   word 1 = number of edges captured
 *   word 2 = 0xC0DEC0DE once armed
 *   word 3 = first captured timestamp (debug)
 *   word 4 = last  captured timestamp (debug)
 */

#include "../attoio.h"

#define IN_PAD   3u
#define OUT_PAD  8u
#define OUT_MASK (1u << OUT_PAD)

#define N_EDGES  4    /* 4 edges → 3 inter-edge deltas reproduced */

/* 16-bit timestamps save 8 B of BSS vs uint32_t; deltas up to 65535
 * clk_iop cycles (~2.6 ms @ 25 MHz) cover any reasonable IR frame
 * after protocol-scaling. */
volatile uint16_t cap_times[N_EDGES];
volatile uint8_t  cap_idx;          /* fits 0..N_EDGES easily */
volatile uint8_t  capture_done;

static inline void wait_until(uint32_t target) {
    TIMER_CMP(0)  = (target - 1u) | TIMER_CMP_EN;
    TIMER_STATUS  = TIMER_STATUS_MATCH0;
    while (!(TIMER_STATUS & TIMER_STATUS_MATCH0)) { }
    TIMER_STATUS  = TIMER_STATUS_MATCH0;
}

void __isr(void) {
    if (TIMER_STATUS & TIMER_STATUS_CAPTURE) {
        uint32_t i = cap_idx;
        if (i < N_EDGES) {
            cap_times[i] = (uint16_t)TIMER_CAP;
            i++;
            cap_idx = i;
            if (i >= N_EDGES) capture_done = 1;
        }
        TIMER_STATUS = TIMER_STATUS_CAPTURE;
    }
}

int main(void) {
    cap_idx      = 0;
    capture_done = 0;

    MAILBOX_W32[0] = 0;

    /* pad[3] as input, pad[8] as output (starting LOW). */
    GPIO_OE_CLR  = 1u << IN_PAD;
    GPIO_OUT_CLR = OUT_MASK;
    GPIO_OE_SET  = OUT_MASK;

    __asm__ volatile ("csrsi mstatus, 8");

    /* -------- Phase 1: LEARN -------- */
    TIMER_CTL = TIMER_CTL_EN | TIMER_CTL_RESET |
                ((IN_PAD & 0xFu) << TIMER_CTL_CAP_PIN_SHIFT) |
                (0x3u << TIMER_CTL_CAP_EDGE_SHIFT) |   /* both edges */
                TIMER_CTL_CAP_IRQ_EN;
    TIMER_STATUS = TIMER_STATUS_CAPTURE;

    MAILBOX_W32[2] = 0xC0DEC0DEu;

    while (!capture_done) wfi();

    MAILBOX_W32[0] = 1;    /* LEARN done */

    /* -------- Phase 2: REPLAY -------- */
    /* Reset TIMER and drop CAP IRQ so spurious pad[3] edges during
     * replay can't re-enter the ISR. */
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET;
    TIMER_STATUS = TIMER_STATUS_MATCH0 | TIMER_STATUS_CAPTURE;

    uint32_t t = 0;
    uint32_t state = 0;     /* pad[8] current level */

    for (int i = 0; i < N_EDGES; i++) {
        if (i > 0) {
            t += (cap_times[i] - cap_times[i - 1]);
            wait_until(t);
        }
        /* Toggle pad[8]. */
        if (state) {
            GPIO_OUT_CLR = OUT_MASK;
            state = 0;
        } else {
            GPIO_OUT_SET = OUT_MASK;
            state = 1;
        }
    }

    /* End replay — leave pad[8] in whatever final state the last
     * edge set it to, consistent with the input waveform's tail. */
    TIMER_CTL      = 0;
    MAILBOX_W32[0] = 2;    /* REPLAY done */

    while (1) wfi();
}
