/*
 * ws2812/main.c — Phase 4 / E4: WS2812 LED strip driver.
 *
 * Pin:   pad[8] = DIN (output, driven directly by TIMER pad-toggle)
 * Clock: clk_iop = 25 MHz (testbench) — bit period = 31 cycles ≈ 1.24 µs.
 *
 *   '0' bit : 10 cycles HIGH (400 ns) + 21 cycles LOW (840 ns)
 *   '1' bit : 20 cycles HIGH (800 ns) + 11 cycles LOW (440 ns)
 *   Reset   : >50 µs LOW between frames.
 *
 * Strategy:
 *   - CMP0 auto-reload at BIT_PERIOD-1; pad-toggle on pin 8 → pad flips
 *     LOW→HIGH at every bit boundary.
 *   - CMP1 at HIGH_DURATION-1; pad-toggle on pin 8 → pad flips HIGH→LOW
 *     mid-bit.
 *   - Firmware must update CMP1 before the NEXT bit reaches that CNT
 *     value.  Worst-case window is BIT_PERIOD - H_curr + H_next cycles,
 *     which for adjacent '1'→'0' is 11+10 = 21 cycles — tight.  To
 *     keep the update path branch-free we pre-flatten the 72 H values
 *     into a byte array and index with the bit counter.
 *
 * Test pattern: 3 LEDs in GRB order:
 *   LED 0: G=0xFF R=0x00 B=0x00
 *   LED 1: G=0x00 R=0xFF B=0x00
 *   LED 2: G=0x00 R=0x00 B=0xFF
 *
 * Mailbox[0] = 0xB572B572 when done.
 */

#include "../attoio.h"

#ifndef ATTOIO_CLK_HZ
# define ATTOIO_CLK_HZ 50000000u   /* tb_ws2812 runs clk_iop at 50 MHz */
#endif

#define DIN_PIN       8
#define BIT_PERIOD    62u          /* 1240 ns */
#define T0H           20u          /* 400 ns */
#define T1H           40u          /* 800 ns */

#define CMP_CFG (TIMER_CMP_EN | TIMER_CMP_PAD_TOGGLE | TIMER_CMP_PAD(DIN_PIN))

int main(void) {
    static const uint8_t frame[9] = {
        0xFF, 0x00, 0x00,
        0x00, 0xFF, 0x00,
        0x00, 0x00, 0xFF,
    };

    /* Pre-flatten to one byte per bit.  Each byte is either T0H or T1H
     * so the loop body is a single load + subtract + MMIO store. */
    uint8_t h_table[72];
    for (int i = 0; i < 72; i++) {
        unsigned byte_i = i >> 3;
        unsigned bit_i  = 7u - (i & 7);
        unsigned bit    = (frame[byte_i] >> bit_i) & 1u;
        h_table[i] = bit ? (uint8_t)T1H : (uint8_t)T0H;
    }

    GPIO_OE_SET  = 1u << DIN_PIN;
    MAILBOX_W32[0] = 0;

    /* Bootstrap: timer_pad_val_r resets to 0 (LOW).  We want bit 0 to
     * START with pad HIGH, so pulse a CMP1 match at CNT=0 to flip the
     * internal pad register to 1 before the main loop starts.  Then
     * disable and reconfigure for the real WS2812 sequence. */
    TIMER_CMP(1) = 0u | CMP_CFG;                  /* match immediately */
    TIMER_CMP(0) = 0x00FFFFFFu;                   /* CMP0 far in the future */
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET;
    __asm__ volatile ("nop; nop; nop; nop");      /* let match fire and toggle */
    TIMER_CTL    = 0;
    TIMER_STATUS = TIMER_STATUS_MATCH0 | TIMER_STATUS_MATCH1;

    /* Now pad_val_r[DIN_PIN] = 1 (HIGH).  Configure for real frame. */
    TIMER_CMP(1) = (h_table[0] - 1u) | CMP_CFG;
    TIMER_CMP(0) = (BIT_PERIOD - 1u) | CMP_CFG;
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_AUTO_RELOAD | TIMER_CTL_RESET;
    TIMER_STATUS = TIMER_STATUS_MATCH0 | TIMER_STATUS_MATCH1;

    for (int total = 0; total < 72; total++) {
        while (!(TIMER_STATUS & TIMER_STATUS_MATCH1)) { }
        TIMER_STATUS = TIMER_STATUS_MATCH1;

        if (total < 71) {
            TIMER_CMP(1) = ((uint32_t)h_table[total + 1] - 1u) | CMP_CFG;
        }

        while (!(TIMER_STATUS & TIMER_STATUS_MATCH0)) { }
        TIMER_STATUS = TIMER_STATUS_MATCH0;
    }

    TIMER_CTL    = 0;
    TIMER_CMP(0) = 0;
    TIMER_CMP(1) = 0;
    GPIO_OUT_CLR = 1u << DIN_PIN;

    MAILBOX_W32[0] = 0xB572B572u;
    while (1) wfi();
}
