/*
 * wdt_test/main.c — exercises the watchdog.
 *
 * Behavior:
 *   1. Configure WDT with reload = 200, enable + host_alert.
 *   2. Pet it 3 times on a short interval — counter should never hit 0.
 *   3. Stop petting. WDT expires. NMI fires, ISR logs to mailbox.
 *   4. Host testbench also observes irq_to_host pulse from the alert.
 *
 * Mailbox layout:
 *   [0]  phase marker:
 *          0xAAAA0000 after init, before main loop
 *          0xAAAA0001 after successful 3-pet phase
 *          0xAAAA0002 when ISR fires
 *   [4]  wake/nmi count (incremented each ISR entry)
 *   [6]  WDT_STATUS snapshot taken in ISR
 */

#include "../attoio.h"

volatile uint32_t nmi_count;

/* Override weak __isr from crt0 — serves BOTH normal IRQ and NMI.
 * AttoRV32 redirects both to the same MTVEC; firmware distinguishes
 * via mcause if needed. For our test, any trap entry means "WDT fired"
 * because nothing else is configured to interrupt. */
void __isr(void) {
    nmi_count++;
    MAILBOX_W32[4] = nmi_count;
    MAILBOX_W32[6] = WDT_STATUS;

    /* Clear the expired flag and disable so we don't NMI again
     * while the host checks things. */
    WDT_STATUS = WDT_STATUS_EXPIRED;
    WDT_CTL    = 0;

    /* Set the "ISR ran" sentinel LAST so the host only observes
     * it after mailbox[4]/[6] have been written. */
    MAILBOX_W32[0] = 0xAAAA0002u;
}

int main(void) {
    nmi_count      = 0;
    MAILBOX_W32[0] = 0xAAAA0000u;
    MAILBOX_W32[4] = 0;
    MAILBOX_W32[6] = 0;

    /* Enable MSTATUS.MIE (NMI bypasses MIE but set anyway). */
    __asm__ volatile ("csrsi mstatus, 8");

    /* Configure WDT: reload = 2000 clk_iop cycles; enable + host alert.
     * The wait_cycles(100) loop below runs ~400 clk_iop cycles, so 3
     * pet gaps are ~1200 cycles — well under the 2000-cycle budget. */
    wdt_pet(2000);
    wdt_enable(/*host_alert=*/ 1);

    for (int i = 0; i < 3; i++) {
        wait_cycles(100);
        wdt_pet(2000);
    }

    MAILBOX_W32[0] = 0xAAAA0001u;

    /* Now stop petting. WDT expires ~200 cycles later -> NMI -> ISR. */
    while (1) {
        /* Just spin — do NOT WFI here; on AttoRV32 the NMI wakes the
         * core out of WFI but we also want to prove that expire works
         * during active execution. */
    }
}
