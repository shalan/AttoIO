/*
 * irq_doorbell/main.c — verifies the host → IOP doorbell IRQ path.
 *
 * The host writes to the IOP_CTRL DOORBELL_H2C register (host-side
 * word 0, byte address 0x700) which sets the doorbell bit; that bit
 * feeds iop_irq via attoio_ctrl.  The ISR W1C-clears the bit (IOP
 * view of the same register lives at MMIO+0x80).
 *
 * Mailbox layout:
 *   word 0 = doorbell ring count
 *   word 4 = snapshot of DOORBELL_H2C right when the ISR fired
 *   word 6 = echoed command (host-staged in mailbox word 16)
 *   word 2 = 0xC0DEC0DE sentinel once main() reaches WFI
 *
 * This test does NOT use the C2H handshake — the host polls
 * mailbox[0] directly while the ISR runs and reads from mailbox[16].
 * That's the access pattern that originally surfaced BUG-001 (SRAM B
 * Do0 race).  Passing this test cleanly validates the BUG-001 fix in
 * attoio_memmux.v.
 */

#include "../attoio.h"

volatile uint32_t doorbell_count;

void __isr(void) {
    uint32_t db = DOORBELL_H2C;
    if (db & 1u) {
        doorbell_count++;
        uint32_t cmd = MAILBOX_W32[16];      /* host-staged cmd @ 0x640 */
        MAILBOX_W32[4] = db;
        MAILBOX_W32[6] = cmd;
        DOORBELL_H2C = 1u;                    /* W1C — drops iop_irq */
        /* Write count LAST so the host's "wait for count to bump" loop
         * is also a "ISR fully completed" signal — H2C is already
         * cleared by the time count becomes visible. */
        MAILBOX_W32[0] = doorbell_count;
    }
}

int main(void) {
    doorbell_count = 0;
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[4] = 0;
    MAILBOX_W32[6] = 0;

    __asm__ volatile ("csrsi mstatus, 8");

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    while (1) wfi();
}
