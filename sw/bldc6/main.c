/*
 * bldc6/main.c — E10.  BLDC 6-step commutation driven by 3 Hall-
 * sensor inputs on pads 0/1/2.
 *
 * Pin map:
 *   pad[0..2] = Hall A / B / C  (inputs, wake on both edges)
 *   pad[4..9] = U_H U_L V_H V_L W_H W_L
 *
 * Each Hall edge advances a commutation-sequence pointer and drives
 * the corresponding gate pattern; no GPIO_IN read is needed.
 *
 * Mailbox:
 *   word 0 = commutation count (bumps on every Hall edge)
 *   word 1 = current commutation idx (0..5)
 *   word 2 = 0xC0DEC0DE sentinel once armed
 *   word 3 = current gate pattern
 */

#include "../attoio.h"

#define HALL_A_PAD 0u
#define HALL_B_PAD 1u
#define HALL_C_PAD 2u
#define HALL_MASK  ((1u << HALL_A_PAD) | (1u << HALL_B_PAD) | (1u << HALL_C_PAD))

#define U_H (1u << 4)
#define U_L (1u << 5)
#define V_H (1u << 6)
#define V_L (1u << 7)
#define W_H (1u << 8)
#define W_L (1u << 9)
#define GATE_MASK (U_H | U_L | V_H | V_L | W_H | W_L)

static const uint32_t comm_seq[6] = {
    V_H | W_L,      /* 0: Hall 001 */
    W_H | U_L,      /* 1: Hall 010 */
    V_H | U_L,      /* 2: Hall 011 */
    U_H | V_L,      /* 3: Hall 100 */
    U_H | W_L,      /* 4: Hall 101 */
    W_H | V_L,      /* 5: Hall 110 */
};

volatile uint32_t comm_count;
volatile uint32_t comm_idx;

void __isr(void) {
    uint32_t flags = WAKE_FLAGS;
    if (flags & HALL_MASK) {
        uint32_t idx = comm_idx;
        idx++;
        if (idx >= 6) idx = 0;
        uint32_t gate = comm_seq[idx];

        GPIO_OUT_CLR = GATE_MASK;
        if (gate) GPIO_OUT_SET = gate;

        comm_count++;
        comm_idx        = idx;

        /* Publish data BEFORE the count — the host uses the count as
         * a "done" sentinel, so all payload stores must be visible
         * before it bumps.  Same pattern as sw/irq_doorbell/main.c. */
        MAILBOX_W32[1]  = idx;
        MAILBOX_W32[3]  = gate;
        WAKE_FLAGS      = flags & HALL_MASK;    /* W1C first too */
        MAILBOX_W32[0]  = comm_count;           /* <-- sentinel, LAST */
    }
}

int main(void) {
    comm_count = 0;
    comm_idx   = 5;   /* first edge advances to 0 */

    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;
    MAILBOX_W32[3] = 0;

    GPIO_OE_CLR  = HALL_MASK;
    GPIO_OUT_CLR = GATE_MASK;
    GPIO_OE_SET  = GATE_MASK;

    __asm__ volatile ("csrsi mstatus, 8");

    wake_set_edge(HALL_A_PAD, WAKE_EDGE_BOTH);
    wake_set_edge(HALL_B_PAD, WAKE_EDGE_BOTH);
    wake_set_edge(HALL_C_PAD, WAKE_EDGE_BOTH);
    wake_enable(HALL_A_PAD);
    wake_enable(HALL_B_PAD);
    wake_enable(HALL_C_PAD);

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
