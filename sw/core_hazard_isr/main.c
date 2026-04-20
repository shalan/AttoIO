/*
 * core_hazard_isr/main.c — BUG-002 isolation step 3.
 *
 * Same store sequence as core_hazard, but this time triggered from an
 * __isr fired by a host-side doorbell.  We're isolating whether the
 * INTERRUPT CONTEXT is what surfaces the bug (stack spill of
 * caller-saved regs across bank boundaries + then the main body of
 * SRAM B stores).
 */

#include "../attoio.h"

static const uint32_t lookup[6] = {
    0x0240, 0x0120, 0x0060, 0x0090, 0x0210, 0x0180
};

volatile uint32_t counter;
volatile uint32_t isr_done;

void __isr(void) {
    uint32_t db = DOORBELL_H2C;
    if (db & 1u) {
        /* Mirror the E10 BLDC ISR pattern exactly. */
        uint32_t gate = lookup[0];

        GPIO_OUT_CLR = 0x3F0u;
        GPIO_OUT_SET = gate;

        counter++;

        MAILBOX_W32[0] = 0xAA01BEEFu;
        MAILBOX_W32[1] = 0xAA02BEEFu;
        MAILBOX_W32[3] = 0xAA03BEEFu;
        MAILBOX_W32[5] = 0xAA05BEEFu;
        MAILBOX_W32[7] = 0xAA07BEEFu;

        DOORBELL_H2C = 1u;         /* W1C */

        MAILBOX_W32[2] = 0xC0DEC0DEu;  /* sentinel */
        isr_done = 1;
    }
}

int main(void) {
    counter = 0;
    isr_done = 0;
    for (int i = 0; i < 8; i++) MAILBOX_W32[i] = 0;

    __asm__ volatile ("csrsi mstatus, 8");

    while (1) {
        __asm__ volatile ("wfi");
    }
}
