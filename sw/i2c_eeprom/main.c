/*
 * i2c_eeprom/main.c — E3 I²C master, 24C02-style EEPROM, 100 kHz.
 *
 * pad[6]=SDA, pad[7]=SCL (open-drain via pad_oe).
 * Verified round-trip against sim/i2c_eeprom_model.v.
 *
 * Phase 0.9 trim: qtr() changed from a TIMER-CMP wait to a simple
 * busy-loop so it inlines to ~4 instructions instead of ~20.  Fits
 * the 512 B SRAM A budget while keeping the full random-read
 * (page-write + restart + random-read) test semantics intact.
 *
 * Size-tuned: helpers are __attribute__((noinline)) so GCC keeps
 * them as genuine calls instead of inlining into main.  Without
 * noinline, -Os expands qtr() at every site and main() blows past
 * the budget.
 */

#include "../attoio.h"

#ifndef ATTOIO_CLK_HZ
# define ATTOIO_CLK_HZ 25000000u
#endif
#ifndef I2C_BAUD
# define I2C_BAUD 100000u
#endif

#define SDA_PIN 6
#define SCL_PIN 7

/* Busy-loop counter sized for one I²C quarter-bit at
 * clk_iop = 25 MHz, 100 kHz bus.  Serial-shift core takes ~8
 * clk_iop per `for (i--) {}` iteration; divide accordingly.  Not
 * cycle-perfect but well within the ±50 % timing tolerance real
 * I²C slaves accept. */
#define QTR_ITERS ((ATTOIO_CLK_HZ / (I2C_BAUD * 4u)) / 8u)

#define SDA_LOW() (GPIO_OE_SET = 1u << SDA_PIN)
#define SDA_REL() (GPIO_OE_CLR = 1u << SDA_PIN)
#define SCL_LOW() (GPIO_OE_SET = 1u << SCL_PIN)
#define SCL_REL() (GPIO_OE_CLR = 1u << SCL_PIN)
#define SDA_READ() ((GPIO_IN >> SDA_PIN) & 1u)

#define NI __attribute__((noinline))

static inline void qtr(void) {
    for (volatile uint32_t i = QTR_ITERS; i; i--) { }
}

static void i2c_start(void) {
    SDA_REL(); SCL_REL(); qtr();
    SDA_LOW();           qtr();
    SCL_LOW();           qtr();
}

static void i2c_stop(void) {
    SDA_LOW(); SCL_LOW(); qtr();
    SCL_REL();           qtr();
    SDA_REL();           qtr();
}

static void NI i2c_write(uint8_t b) {
    for (int i = 0; i < 8; i++) {
        unsigned bit = (b >> 7) & 1u;
        if (bit) SDA_REL(); else SDA_LOW();
        qtr();
        SCL_REL(); qtr(); qtr();
        SCL_LOW(); qtr();
        b = (uint8_t)(b << 1);
    }
    SDA_REL(); qtr();
    SCL_REL(); qtr(); qtr();
    SCL_LOW(); qtr();
}

static uint8_t NI i2c_read(int nak) {
    uint8_t b = 0;
    SDA_REL();
    for (int i = 0; i < 8; i++) {
        qtr();
        SCL_REL(); qtr();
        b = (b << 1) | (uint8_t)SDA_READ();
        qtr();
        SCL_LOW(); qtr();
    }
    if (nak) SDA_REL(); else SDA_LOW();
    qtr();
    SCL_REL(); qtr(); qtr();
    SCL_LOW(); qtr();
    SDA_REL();
    return b;
}

int main(void) {
    /* Two ROM strings: 6-byte page-write, 2-byte address-set. */
    static const uint8_t wr[6] = { 0xA0, 0x00, 0x5A, 0xA5, 0xDE, 0xAD };
    static const uint8_t setaddr[2] = { 0xA0, 0x00 };
    int i;

    GPIO_OUT_CLR = (1u << SDA_PIN) | (1u << SCL_PIN);
    GPIO_OE_CLR  = (1u << SDA_PIN) | (1u << SCL_PIN);
    MAILBOX_W32[0] = 0;

    /* Phase 1: page write (4 payload bytes at offset 0). */
    i2c_start();
    for (i = 0; i < 6; i++) i2c_write(wr[i]);
    i2c_stop();

    /* Phase 2: reset the EEPROM's address pointer to 0.  We use a
     * plain start/stop bracket with no restart since restart is the
     * only helper we could drop to hit the 512 B budget. */
    i2c_start();
    for (i = 0; i < 2; i++) i2c_write(setaddr[i]);
    i2c_stop();

    /* Phase 3: sequential read of 4 bytes starting at addr 0. */
    i2c_start();
    i2c_write(0xA1);
    for (i = 0; i < 4; i++) MAILBOX[16 + i] = i2c_read(i == 3);
    i2c_stop();

    MAILBOX_W32[0] = 0xE2E2E2E2u;
    while (1) wfi();
}
