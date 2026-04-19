/*
 * tm1637/main.c — Phase 5a / E6: TM1637 4-digit 7-seg display driver.
 *
 * Protocol: custom 2-wire, superficially I²C-like but LSB-first with
 * a slave-ACK low pulse on the 9th clock.
 *
 *   pad[9]  = DIO (open-drain, external pullup)
 *   pad[10] = CLK (open-drain, external pullup)
 *
 * A TM1637 update is three transactions:
 *   1. START  0x40  STOP        — "data cmd: auto-increment address"
 *   2. START  0xC0  d0 d1 d2 d3  STOP  — address 0, then 4 segment bytes
 *   3. START  0x88|bright  STOP — "display on, brightness 0..7"
 *
 * Demo pattern: display "1234" (segment bytes 0x06, 0x5B, 0x4F, 0x66).
 *
 * Sentinel: MAILBOX[0] = 0x13371337 when done.
 */

#include "../attoio.h"

#ifndef ATTOIO_CLK_HZ
# define ATTOIO_CLK_HZ 25000000u
#endif
#ifndef TM1637_BAUD
# define TM1637_BAUD 250000u   /* clock frequency, Hz */
#endif

#define DIO_PIN 9
#define CLK_PIN 10
#define QTR_CYCLES (ATTOIO_CLK_HZ / (TM1637_BAUD * 4u))

#define DIO_LOW()  (GPIO_OE_SET = 1u << DIO_PIN)
#define DIO_REL()  (GPIO_OE_CLR = 1u << DIO_PIN)
#define CLK_LOW()  (GPIO_OE_SET = 1u << CLK_PIN)
#define CLK_REL()  (GPIO_OE_CLR = 1u << CLK_PIN)

#define NI __attribute__((noinline))

/* TIMER-paced quarter-bit delay.  Out-of-line so the compiler doesn't
 * duplicate the polling body at every call site. */
static void NI qtr(void) {
    TIMER_CMP(0) = (QTR_CYCLES - 1) | TIMER_CMP_EN;
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET;
    TIMER_STATUS = TIMER_STATUS_MATCH0;
    while (!(TIMER_STATUS & TIMER_STATUS_MATCH0)) { }
    TIMER_STATUS = TIMER_STATUS_MATCH0;
}

/* START: DIO falls while CLK high. */
static void NI tm_start(void) {
    DIO_REL(); CLK_REL(); qtr();
    DIO_LOW();            qtr();
    CLK_LOW();            qtr();
}

/* STOP: DIO rises while CLK high. */
static void NI tm_stop(void) {
    CLK_LOW(); DIO_LOW(); qtr();
    CLK_REL();            qtr();
    DIO_REL();            qtr();
}

/* Send one byte LSB-first; consume the slave's ACK low pulse. */
static void NI tm_write(uint8_t b) {
    for (int i = 0; i < 8; i++) {
        unsigned bit = b & 1u;
        if (bit) DIO_REL(); else DIO_LOW();
        qtr();
        CLK_REL(); qtr(); qtr();
        CLK_LOW(); qtr();
        b >>= 1;
    }
    /* ACK slot: release DIO, pulse CLK once.  TM1637 pulls DIO low
     * during CLK high.  We don't check it (non-fatal if the slave
     * is absent in sim). */
    DIO_REL(); qtr();
    CLK_REL(); qtr(); qtr();
    CLK_LOW(); qtr();
}

int main(void) {
    /* Open-drain idle: OUT=0, OE=0 (pullup drives high). */
    GPIO_OUT_CLR = (1u << DIO_PIN) | (1u << CLK_PIN);
    GPIO_OE_CLR  = (1u << DIO_PIN) | (1u << CLK_PIN);
    MAILBOX_W32[0] = 0;

    /* Segment patterns for 1, 2, 3, 4. */
    static const uint8_t digits[4] = { 0x06, 0x5B, 0x4F, 0x66 };

    /* Transaction 1: data command (auto-increment). */
    tm_start();
    tm_write(0x40);
    tm_stop();

    /* Transaction 2: address 0 then 4 digit bytes. */
    tm_start();
    tm_write(0xC0);
    for (int i = 0; i < 4; i++) tm_write(digits[i]);
    tm_stop();

    /* Transaction 3: display on, brightness = 7. */
    tm_start();
    tm_write(0x88 | 0x07);
    tm_stop();

    MAILBOX_W32[0] = 0x13371337u;
    while (1) wfi();
}
