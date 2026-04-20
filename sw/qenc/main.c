/*
 * qenc/main.c — E20.  Quadrature encoder with push-button.
 *
 * Pin map:
 *   pad[0] = A   channel
 *   pad[1] = B   channel
 *   pad[2] = button (active-LOW, press = falling edge)
 *
 * The A/B channel edges tile through a 4-phase gray-code cycle.
 * State is encoded `curr = (B << 1) | A` (A in bit 0, B in bit 1):
 *   CW  (A leads B):  00 → 01 → 11 → 10 → 00
 *   CCW (B leads A):  00 → 10 → 11 → 01 → 00
 *
 * We wake on BOTH edges of A and B, and on the falling edge of the
 * button.  Every wake triggers the ISR; it reads the current AB
 * state, looks up the direction delta from the 16-entry transition
 * LUT, and advances a signed position counter.
 *
 * Mailbox:
 *   word 0 = wake count (bumps every ISR)
 *   word 1 = current position (signed int32)
 *   word 2 = 0xC0DEC0DE once armed
 *   word 3 = button-press count
 *   word 4 = last AB state read
 */

#include "../attoio.h"

#define A_PAD   0u
#define B_PAD   1u
#define BTN_PAD 2u
#define A_MASK  (1u << A_PAD)
#define B_MASK  (1u << B_PAD)
#define BTN_MASK (1u << BTN_PAD)
#define AB_MASK (A_MASK | B_MASK)

/* Direction LUT indexed by (prev<<2 | curr) where prev and curr are
 * each the 2-bit AB state {B_bit, A_bit} = (pad1<<1) | pad0.
 * +1 = CW, -1 = CCW, 0 = no change or invalid transition. */
static const int8_t q_lut[16] = {
    /* (prev << 2) | curr                              */
    /* 00 -> 00 */  0,
    /* 00 -> 01 */ +1,      /* CW : A rose                */
    /* 00 -> 10 */ -1,      /* CCW: B rose                */
    /* 00 -> 11 */  0,      /* invalid (both changed)     */
    /* 01 -> 00 */ -1,      /* reverse of CW step         */
    /* 01 -> 01 */  0,
    /* 01 -> 10 */  0,      /* invalid                    */
    /* 01 -> 11 */ +1,      /* CW : B rose                */
    /* 10 -> 00 */ +1,      /* CW : B fell                */
    /* 10 -> 01 */  0,      /* invalid                    */
    /* 10 -> 10 */  0,
    /* 10 -> 11 */ -1,      /* CCW: A rose                */
    /* 11 -> 00 */  0,      /* invalid                    */
    /* 11 -> 01 */ -1,      /* CCW: B fell                */
    /* 11 -> 10 */ +1,      /* CW : A fell                */
    /* 11 -> 11 */  0
};

volatile uint32_t wake_count;
volatile int32_t  position;
volatile uint32_t prev_ab;
volatile uint32_t btn_count;

void __isr(void) {
    uint32_t flags = WAKE_FLAGS;

    if (flags & AB_MASK) {
        uint32_t in = GPIO_IN;
        uint32_t curr = ((in >> A_PAD) & 1u) | (((in >> B_PAD) & 1u) << 1);
        uint32_t idx  = (prev_ab << 2) | curr;
        int32_t  dir  = q_lut[idx & 0xF];
        position      = position + dir;
        prev_ab       = curr;
        MAILBOX_W32[4] = curr;
    }

    if (flags & BTN_MASK) {
        btn_count++;
        MAILBOX_W32[3] = btn_count;
    }

    wake_count++;
    MAILBOX_W32[1] = (uint32_t)position;
    MAILBOX_W32[0] = wake_count;           /* sentinel LAST */

    WAKE_FLAGS = flags & (AB_MASK | BTN_MASK);
}

int main(void) {
    wake_count = 0;
    position   = 0;
    prev_ab    = 0;
    btn_count  = 0;
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;
    MAILBOX_W32[3] = 0;
    MAILBOX_W32[4] = 0;

    GPIO_OE_CLR = AB_MASK | BTN_MASK;

    __asm__ volatile ("csrsi mstatus, 8");

    wake_set_edge(A_PAD,   WAKE_EDGE_BOTH);
    wake_set_edge(B_PAD,   WAKE_EDGE_BOTH);
    wake_set_edge(BTN_PAD, WAKE_EDGE_FALL);
    wake_enable(A_PAD);
    wake_enable(B_PAD);
    wake_enable(BTN_PAD);

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
