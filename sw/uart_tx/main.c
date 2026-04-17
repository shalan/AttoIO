/*
 * uart_tx/main.c — bit-banged UART transmitter (Phase 1a of E1).
 *
 * Transmits the fixed string "Hello, AttoIO\r\n" on pad[0] at 115200
 * baud (8-N-1).  Bit timing comes from the TIMER block (CMP0 paced at
 * the bit-period count) — not cycle-counted loops, which would drift
 * with any firmware change.
 *
 * Protocol:
 *   - TX idle level is high (pad[0] = 1).
 *   - For each byte: start bit (0), 8 data bits LSB-first, stop bit (1).
 *   - Firmware polls TIMER_STATUS.MATCH0 between bits.  The timer runs
 *     throughout, so the first bit may be slightly late; all subsequent
 *     bits are clock-locked.
 *
 * Sentinel: writes 0xD0D0D0D0 to mailbox[0] when done.
 */

#include "../attoio.h"

#ifndef ATTOIO_CLK_HZ
# define ATTOIO_CLK_HZ 25000000u
#endif
#ifndef UART_BAUD
# define UART_BAUD     115200u
#endif

#define TXD_PIN        0
#define BIT_CYCLES     (ATTOIO_CLK_HZ / UART_BAUD)  /* 217 @ 25 MHz/115200 */

static inline void wait_bit(void) {
    /* spin until the match flag comes up, then W1C-clear it */
    while (!(TIMER_STATUS & TIMER_STATUS_MATCH0)) { }
    TIMER_STATUS = TIMER_STATUS_MATCH0;
}

static inline void drive_tx(int v) {
    if (v) GPIO_OUT_SET = 1u << TXD_PIN;
    else   GPIO_OUT_CLR = 1u << TXD_PIN;
}

static void uart_tx_byte(uint8_t b) {
    drive_tx(0);  wait_bit();               /* start */
    for (int i = 0; i < 8; i++) {
        drive_tx(b & 1); wait_bit();
        b >>= 1;
    }
    drive_tx(1);  wait_bit();               /* stop */
}

int main(void) {
    /* TXD: idle high, output-enable on. */
    GPIO_OE_SET  = 1u << TXD_PIN;
    GPIO_OUT_SET = 1u << TXD_PIN;

    /* TIMER: CMP0 matches every BIT_CYCLES clk_iop ticks, auto-reloads.
     * No pad-toggle and no IRQ — firmware just polls MATCH0 flag. */
    TIMER_CMP(0) = TIMER_CMP_VAL(BIT_CYCLES - 1) | TIMER_CMP_EN;
    TIMER_STATUS = TIMER_STATUS_MATCH0;     /* clear any stale flag */
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_AUTO_RELOAD;

    /* Discard the first match so the next wait_bit() lands exactly one
     * full bit-period after the start edge. */
    wait_bit();

    static const char msg[] = "Hello, AttoIO\r\n";
    for (int i = 0; msg[i]; i++)
        uart_tx_byte((uint8_t)msg[i]);

    MAILBOX_W32[0] = 0xD0D0D0D0u;

    while (1) wfi();
}
