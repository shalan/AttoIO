/*
 * onewire/main.c — E25.  Dallas 1-Wire master bit-banger.
 *
 * Talks to a single 1-Wire slave on pad[3]:
 *   1. Reset pulse + presence detect.
 *   2. Write a 1-byte "read scratchpad" command (0xBE; standard
 *      DS18B20-style scratchpad readout).
 *   3. Read 9 bytes of scratchpad data (LSB-first per byte).
 *   4. Publish bytes 0..1 (temperature, little-endian) to mailbox.
 *
 * The TB provides a minimal behavioral slave model that responds to
 * reset with a presence pulse, receives the command, and transmits
 * a hard-coded 9-byte scratchpad (temp = 0x0191 = 25.0625 °C).
 *
 * Pin map:
 *   pad[3] = DQ (open-drain; TB provides external pull-up).
 *
 * Timings scaled ~10× faster than real 1-Wire so the sim finishes
 * in ~1 ms (real 1-Wire bits are ~60 µs each; here ~7 µs).  All
 * values in clk_iop cycles at 25 MHz (40 ns).
 *
 * Mailbox layout:
 *   word 0 = frames-done sentinel (1 = scratchpad read complete)
 *   word 1 = presence-detected flag (1 = slave responded)
 *   word 2 = 0xC0DEC0DE once armed
 *   word 4 = scratchpad[1..0] packed as uint16 (the temperature)
 *   word 5+8 = raw scratchpad bytes for inspection
 */

#include "../attoio.h"

#define OW_PAD  3u
#define OW_MASK (1u << OW_PAD)

/* Scaled timings (clk_iop cycles, 40 ns each) */
#define T_RESET_LOW     1200u    /* 48 µs — master holds LOW for reset */
#define T_PRESENCE_WAIT 150u     /* 6 µs — wait before sampling for presence */
#define T_RESET_REST    1500u    /* 60 µs — remainder of reset slot */

#define T_SLOT          175u     /* 7 µs — full bit slot */
#define T_WRITE1_LOW    25u      /* 1 µs — short LOW for writing a 1 */
#define T_WRITE0_LOW    150u     /* 6 µs — long LOW for writing a 0 */
#define T_READ_LOW      12u      /* 480 ns — very short master-initiated LOW */
#define T_READ_SAMPLE   37u      /* 1.5 µs — sample point inside slot */
#define T_RECOVERY      15u      /* 600 ns — gap between slots */

/* ---------------- low-level bus helpers ---------------- */

static inline void ow_drive_low(void) { GPIO_OE_SET = OW_MASK; }
static inline void ow_release(void)   { GPIO_OE_CLR = OW_MASK; }

static inline uint32_t ow_sample(void) {
    return (GPIO_IN >> OW_PAD) & 1u;
}

static void delay_cycles(uint32_t n) {
    TIMER_CMP(0) = (n - 1) | TIMER_CMP_EN;   /* no IRQ needed */
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET;
    TIMER_STATUS = TIMER_STATUS_MATCH0;
    while (!(TIMER_STATUS & TIMER_STATUS_MATCH0)) { }
    TIMER_STATUS = TIMER_STATUS_MATCH0;
}

/* ---------------- 1-Wire primitives ---------------- */

static uint32_t ow_reset(void) {
    ow_drive_low();
    delay_cycles(T_RESET_LOW);
    ow_release();
    delay_cycles(T_PRESENCE_WAIT);
    uint32_t present = ow_sample() == 0 ? 1u : 0u;
    delay_cycles(T_RESET_REST);
    return present;
}

static void ow_write_bit(uint32_t bit) {
    ow_drive_low();
    if (bit) {
        delay_cycles(T_WRITE1_LOW);
        ow_release();
        delay_cycles(T_SLOT - T_WRITE1_LOW);
    } else {
        delay_cycles(T_WRITE0_LOW);
        ow_release();
        delay_cycles(T_SLOT - T_WRITE0_LOW);
    }
    delay_cycles(T_RECOVERY);
}

static uint32_t ow_read_bit(void) {
    ow_drive_low();
    delay_cycles(T_READ_LOW);
    ow_release();
    delay_cycles(T_READ_SAMPLE - T_READ_LOW);
    uint32_t bit = ow_sample();
    delay_cycles(T_SLOT - T_READ_SAMPLE);
    delay_cycles(T_RECOVERY);
    return bit;
}

static void ow_write_byte(uint8_t b) {
    for (int i = 0; i < 8; i++) {
        ow_write_bit(b & 1u);
        b >>= 1;
    }
}

static uint8_t ow_read_byte(void) {
    uint32_t b = 0;
    for (int i = 0; i < 8; i++) {
        b |= (ow_read_bit() << i);
    }
    return (uint8_t)b;
}

/* ---------------- main ---------------- */

int main(void) {
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;
    MAILBOX_W32[4] = 0;
    for (int i = 0; i < 9; i++) MAILBOX_W32[5 + i] = 0;

    /* pad[3] idle = released = HIGH via external pullup.  Pre-set
     * OUT=0 so that OE=1 will drive LOW. */
    GPIO_OUT_CLR = OW_MASK;
    GPIO_OE_CLR  = OW_MASK;

    /* Reset + presence */
    uint32_t present = ow_reset();
    MAILBOX_W32[1]   = present;

    if (present) {
        ow_write_byte(0xBE);   /* DS18B20 "read scratchpad" */

        uint8_t scratch[9];
        for (int i = 0; i < 9; i++) scratch[i] = ow_read_byte();

        /* Publish raw bytes for the TB to audit. */
        for (int i = 0; i < 9; i++) MAILBOX_W32[5 + i] = scratch[i];

        /* Temperature = little-endian byte[1]:byte[0]. */
        MAILBOX_W32[4] = (uint32_t)scratch[1] << 8 | scratch[0];
    }

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    MAILBOX_W32[0] = 1;   /* done sentinel */
    while (1) wfi();
}
