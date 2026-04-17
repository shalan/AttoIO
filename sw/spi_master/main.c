/*
 * spi_master/main.c — E2 SPI master using the SPI shift helper.
 *
 * Pin map (from the frozen plan, §tracker):
 *   pad[2] = SCK    (driven by SPI helper while active)
 *   pad[3] = MOSI   (driven by SPI helper while active)
 *   pad[4] = MISO   (input; SPI helper samples it; auto-selected as MOSI+1)
 *   pad[5] = CS     (manually driven by GPIO, firmware-controlled)
 *
 * SPI mode 0: CPOL=0, CPHA=0. SCK idle low, master samples on rising
 * SCK edge.
 *
 * Behavior:
 *   1. Drop CS.
 *   2. Transmit 4 bytes {0xDE, 0xAD, 0xBE, 0xEF} one at a time; capture
 *      whatever the slave shifts back on MISO.
 *   3. Raise CS.
 *   4. Write the 4 received bytes to mailbox[8..11] (byte offsets 0x208..0x20B).
 *   5. Write the 4 transmitted bytes to mailbox[12..15] (0x20C..0x20F) for
 *      testbench cross-check.
 *   6. Write 0xA5A55A5A to mailbox[0] as the "done" sentinel.
 */

#include "../attoio.h"

#define SCK_PIN   2
#define MOSI_PIN  3
/* MISO is sampled automatically at MOSI + 1 = pad[4] */
#define CS_PIN    5

static inline void cs_low(void)  { GPIO_OUT_CLR = 1u << CS_PIN; }
static inline void cs_high(void) { GPIO_OUT_SET = 1u << CS_PIN; }

static uint8_t spi_xfer(uint8_t tx) {
    SPI_DATA = tx;
    while (SPI_STATUS & SPI_STATUS_BUSY) { }
    return (uint8_t)SPI_DATA;
}

int main(void) {
    /* Drive SCK, MOSI, and CS as outputs; MISO stays input (OE=0).
     * While the SPI helper is busy it forces OE high on its pins, but
     * setting them explicitly matches the usual pattern. */
    GPIO_OE_SET  = (1u << SCK_PIN) | (1u << MOSI_PIN) | (1u << CS_PIN);
    GPIO_OUT_SET = (1u << CS_PIN);     /* CS idle high */

    /* Configure SPI: SCK on pad 2, MOSI on pad 3, mode 0.
     * SPI_CFG[3:0] = SCK pin (4 bits).
     * SPI_CFG[5:4] = MOSI pin (2 bits — limits MOSI to pads 0..3).
     * SPI_CFG[6]   = CPOL.
     * SPI_CFG[7]   = CPHA. */
    SPI_CFG = (SCK_PIN & 0xF) | ((MOSI_PIN & 0x3) << 4); /* CPOL=0, CPHA=0 */

    static const uint8_t tx_pattern[4] = { 0xDE, 0xAD, 0xBE, 0xEF };
    uint8_t rx[4];

    cs_low();
    for (int i = 0; i < 4; i++)
        rx[i] = spi_xfer(tx_pattern[i]);
    cs_high();

    /* Byte-wise mailbox writes: MAILBOX[8..11] = rx, MAILBOX[12..15] = tx */
    for (int i = 0; i < 4; i++) {
        MAILBOX[8  + i] = rx[i];
        MAILBOX[12 + i] = tx_pattern[i];
    }
    MAILBOX_W32[0] = 0xA5A55A5Au;

    while (1) wfi();
}
