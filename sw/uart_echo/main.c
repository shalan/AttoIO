/*
 * uart_echo/main.c — echoes bytes from pad[1] (RX) back on pad[0] (TX).
 *
 * Phase 1b of E1.  Exercises both UART directions using the TIMER:
 *   TX: polls CMP0 match flag between bit transitions (same as 1a).
 *   RX: after detecting the start edge, uses CMP1 for a one-shot
 *       1.5-bit delay to land in the center of bit 0, then CMP0
 *       auto-reload for the remaining 7 samples.
 *
 * 8-N-1 @ 115200 baud.  Pin map: pad[0] = TXD, pad[1] = RXD.
 *
 * Mailbox:
 *   [0]  byte counter (number of echoes so far)
 *   [1]  most recently received byte
 */

#include "../attoio.h"

#ifndef ATTOIO_CLK_HZ
# define ATTOIO_CLK_HZ 25000000u
#endif
#ifndef UART_BAUD
# define UART_BAUD 115200u
#endif

#define TXD_PIN        0
#define RXD_PIN        1
#define BIT_CYCLES     (ATTOIO_CLK_HZ / UART_BAUD)

static inline void wait_match0(void) {
    while (!(TIMER_STATUS & TIMER_STATUS_MATCH0)) { }
    TIMER_STATUS = TIMER_STATUS_MATCH0;
}
static inline void wait_match1(void) {
    while (!(TIMER_STATUS & TIMER_STATUS_MATCH1)) { }
    TIMER_STATUS = TIMER_STATUS_MATCH1;
}

static inline void drive_tx(int v) {
    if (v) GPIO_OUT_SET = 1u << TXD_PIN;
    else   GPIO_OUT_CLR = 1u << TXD_PIN;
}

static void uart_tx_byte(uint8_t b) {
    /* Align to a fresh bit period so the start edge isn't cut short. */
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_AUTO_RELOAD | TIMER_CTL_RESET;
    TIMER_CMP(0) = (BIT_CYCLES - 1) | TIMER_CMP_EN;
    TIMER_STATUS = TIMER_STATUS_MATCH0;

    drive_tx(0); wait_match0();                     /* start */
    for (int i = 0; i < 8; i++) {
        drive_tx(b & 1); wait_match0();
        b >>= 1;
    }
    drive_tx(1); wait_match0();                     /* stop */
}

static uint8_t uart_rx_byte(void) {
    uint8_t b = 0;

    /* Poll RXD for the start-bit falling edge. */
    while (gpio_read(RXD_PIN)) { }

    /* Reset TIMER, disable CMP0 during the one-shot 1.5-bit delay so
     * its auto-reload doesn't wrap CNT. CMP1 fires at 1.5 × BIT_CYCLES
     * — the middle of data bit 0. */
    TIMER_CMP(0) = 0;                               /* disable CMP0 */
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_AUTO_RELOAD | TIMER_CTL_RESET;
    TIMER_CMP(1) = ((BIT_CYCLES + BIT_CYCLES / 2) - 1) | TIMER_CMP_EN;
    TIMER_STATUS = TIMER_STATUS_MATCH0 | TIMER_STATUS_MATCH1;

    wait_match1();
    TIMER_CMP(1) = 0;                               /* disable CMP1 */

    /* Sample bit 0 at the middle. */
    b |= gpio_read(RXD_PIN) << 0;

    /* Re-arm CMP0 with auto-reload; reset CNT so the first match lands
     * exactly one bit time from now (center of bit 1). */
    TIMER_CMP(0) = (BIT_CYCLES - 1) | TIMER_CMP_EN;
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_AUTO_RELOAD | TIMER_CTL_RESET;
    TIMER_STATUS = TIMER_STATUS_MATCH0;

    for (int i = 1; i < 8; i++) {
        wait_match0();
        b |= gpio_read(RXD_PIN) << i;
    }
    /* Skip past stop bit so the next start-edge poll doesn't see the
     * trailing end of this frame. */
    wait_match0();
    return b;
}

int main(void) {
    /* TXD output, idle-high.  RXD is input by default (OE=0). */
    GPIO_OE_SET  = 1u << TXD_PIN;
    GPIO_OUT_SET = 1u << TXD_PIN;

    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;

    uint32_t count = 0;
    while (1) {
        uint8_t b = uart_rx_byte();
        MAILBOX_W32[1] = b;
        uart_tx_byte(b);
        count++;
        MAILBOX_W32[0] = count;
    }
}
