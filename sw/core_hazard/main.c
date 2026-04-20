/*
 * core_hazard/main.c — BUG-002 reproducer (no __isr needed).
 *
 * Replays the E10 BLDC ISR's store sequence as a linear main() body:
 *   1) a load from SRAM A       (the comm_seq lookup analog)
 *   2) two MMIO stores          (GPIO_OUT_CLR + GPIO_OUT_SET)
 *   3) a counter load+inc+store (comm_count)
 *   4) five SRAM B stores       (mailbox[0,1,3,5,7])
 *   5) the WAKE_FLAGS W1C analog
 *   6) sentinel + spin
 *
 * We run against a flat 2 KB memory in the testbench so there's no
 * memmux / SRAM-A-vs-SRAM-B banking, no clk domain cross.  If the
 * stores at [3], [5], [7] still disappear here, the bug is in the
 * AttoRV32 core itself.
 *
 * Magic values chosen so mismatches are unambiguous:
 *   mailbox[0] = 0xAA01BEEF
 *   mailbox[1] = 0xAA02BEEF
 *   mailbox[3] = 0xAA03BEEF   <-- first slot that failed in E10
 *   mailbox[5] = 0xAA05BEEF
 *   mailbox[7] = 0xAA07BEEF
 *   mailbox[2] = 0xC0DEC0DE   (sentinel, written AFTER the others,
 *                               so if mailbox[2] is live, all prior
 *                               stores should have been committed)
 */

#include <stdint.h>

#define MMIO_BASE    0x00000700u
#define GPIO_OUT_SET (*(volatile uint32_t *)(MMIO_BASE + 0x0C))
#define GPIO_OUT_CLR (*(volatile uint32_t *)(MMIO_BASE + 0x10))
#define WAKE_FLAGS   (*(volatile uint32_t *)(MMIO_BASE + 0x64))

#define MB_BASE      0x00000600u
#define MAILBOX_W32  ((volatile uint32_t *)(MB_BASE))

static const uint32_t lookup[6] = {
    0x0240, 0x0120, 0x0060, 0x0090, 0x0210, 0x0180
};

volatile uint32_t counter;

int main(void) {
    counter = 0;
    for (int i = 0; i < 8; i++) MAILBOX_W32[i] = 0;

    /* 1. SRAM A load (indexed). */
    uint32_t gate = lookup[0];   /* 0x240 */

    /* 2. MMIO stores. */
    GPIO_OUT_CLR = 0x3F0u;
    GPIO_OUT_SET = gate;

    /* 3. counter load + inc + store back. */
    counter++;

    /* 4. Five SRAM B stores — the BUG-002 danger zone. */
    MAILBOX_W32[0] = 0xAA01BEEFu;
    MAILBOX_W32[1] = 0xAA02BEEFu;
    MAILBOX_W32[3] = 0xAA03BEEFu;
    MAILBOX_W32[5] = 0xAA05BEEFu;
    MAILBOX_W32[7] = 0xAA07BEEFu;

    /* 5. MMIO W1C analog. */
    WAKE_FLAGS = 0x7u;

    /* 6. Sentinel — published LAST.  If mailbox[2] == 0xC0DEC0DE is
     *    observable while [3/5/7] still read 0, we've proven the
     *    earlier stores got dropped even though the core continued
     *    past them. */
    MAILBOX_W32[2] = 0xC0DEC0DEu;

    while (1) {
        __asm__ volatile ("wfi");
    }
}
