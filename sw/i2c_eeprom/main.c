/*
 * i2c_eeprom/main.c — E3 I²C master, 24C02-style EEPROM, 100 kHz.
 *
 * pad[6]=SDA, pad[7]=SCL (open-drain via pad_oe).
 * Verified round-trip against sim/i2c_eeprom_model.v.
 *
 * Size-tuned: helpers are __attribute__((noinline)) so GCC keeps them
 * as genuine calls instead of inlining into main. Without noinline,
 * -Os inlines the called-once helpers and the expanded qtr() sites
 * blow past the 512-byte SRAM A budget.
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
#define QTR_CYCLES (ATTOIO_CLK_HZ / (I2C_BAUD * 4u))

#define SDA_LOW() (GPIO_OE_SET = 1u << SDA_PIN)
#define SDA_REL() (GPIO_OE_CLR = 1u << SDA_PIN)
#define SCL_LOW() (GPIO_OE_SET = 1u << SCL_PIN)
#define SCL_REL() (GPIO_OE_CLR = 1u << SCL_PIN)
#define SDA_READ() ((GPIO_IN >> SDA_PIN) & 1u)

#define NI __attribute__((noinline))

static void NI qtr(void) {
    TIMER_CMP(0) = (QTR_CYCLES - 1) | TIMER_CMP_EN;
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET;
    TIMER_STATUS = TIMER_STATUS_MATCH0;
    while (!(TIMER_STATUS & TIMER_STATUS_MATCH0)) { }
    TIMER_STATUS = TIMER_STATUS_MATCH0;
}

static void NI i2c_start(void) {
    SDA_REL(); SCL_REL(); qtr();
    SDA_LOW();           qtr();
    SCL_LOW();           qtr();
}

static void NI i2c_stop(void) {
    SDA_LOW(); SCL_LOW(); qtr();
    SCL_REL();           qtr();
    SDA_REL();           qtr();
}

static void NI i2c_restart(void) {
    SDA_REL();           qtr();
    SCL_REL();           qtr();
    SDA_LOW();           qtr();
    SCL_LOW();           qtr();
}

static void NI i2c_write(uint8_t b) {
    for (int i = 0; i < 8; i++) {
        /* Using explicit mask (1u<<7) avoids any oddity with signed
         * arithmetic on uint8_t promotion. */
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
    /* Packed sequences: page write (start + 6 bytes + stop), then
     * random-read prelude (start + 2 bytes + restart + 1 byte). */
    static const uint8_t wr[6] = { 0xA0, 0x00, 0x5A, 0xA5, 0xDE, 0xAD };
    static const uint8_t rd[2] = { 0xA0, 0x00 };
    int i;

    GPIO_OUT_CLR = (1u << SDA_PIN) | (1u << SCL_PIN);
    GPIO_OE_CLR  = (1u << SDA_PIN) | (1u << SCL_PIN);
    MAILBOX_W32[0] = 0;

    /* page write */
    i2c_start();
    for (i = 0; i < 6; i++) i2c_write(wr[i]);
    i2c_stop();

    /* random read */
    i2c_start();
    for (i = 0; i < 2; i++) i2c_write(rd[i]);
    i2c_restart();
    i2c_write(0xA1);
    for (i = 0; i < 4; i++) MAILBOX[16 + i] = i2c_read(i == 3);
    i2c_stop();

    MAILBOX_W32[0] = 0xE2E2E2E2u;
    while (1) wfi();
}
