/*
 * irq_doorbell/main.c — verifies the host → IOP doorbell IRQ path.
 *
 * The host writes to the IOP_CTRL DOORBELL_H2C register (host-side
 * word 0, byte address 0x700) which sets the doorbell bit; that bit
 * feeds iop_irq via attoio_ctrl.  The ISR W1C-clears the bit (IOP
 * view of the same register lives at MMIO+0x80), records the host's
 * staged command word from the mailbox, then raises DOORBELL_C2H so
 * the testbench knows it's safe to inspect the mailbox.
 *
 * The C2H handshake exists to dodge a known SRAM B arbitration race:
 * when the host APB polls mailbox words during the IOP's ISR, the
 * shared sram_b0_do0 latch can be clobbered between when the IOP
 * issues a load and when it consumes the result.  Driving completion
 * via irq_to_host means the host stays out of SRAM B until the IOP
 * has finished and re-entered WFI.
 *
 * Mailbox layout:
 *   word  0 = doorbell ring count
 *   word  4 = snapshot of DOORBELL_H2C right when the ISR fired
 *   word  6 = echoed command (host-staged in mailbox word 16)
 *   word  2 = 0xC0DEC0DE sentinel once main() reaches WFI
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
        MAILBOX_W32[0] = doorbell_count;
        DOORBELL_H2C = 1u;                    /* W1C — drops iop_irq */
        doorbell_c2h_raise();                 /* tell host "done" */
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
