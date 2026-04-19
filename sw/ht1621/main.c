/*
 * ht1621/main.c — Phase 5c / E7: HT1621 segment-LCD driver, 3-wire mode.
 *
 * The HT1621 is a 32x4 segment LCD driver chip with a proprietary
 * 3-wire serial interface (CS, WR, DATA — no clock from master to
 * slave for reads, just for writes).  It frames every transaction
 * with a 3-bit "type ID" sent MSB-first:
 *
 *   100  WRITE          (followed by 6-bit address + N x 4-bit data)
 *   101  READ           (we don't use this)
 *   110  READ-MODIFY-WR (we don't use this)
 *   111  SPECIAL CMD    (followed by 8-bit cmd code + 1 don't-care)
 *
 * Wait — that's the older datasheet.  Many vendor breakouts use:
 *   100  WRITE
 *   101  READ
 *   110  READ-MODIFY-WRITE
 *   111  COMMAND  (8 bits + 1 don't-care)
 *
 * We use the latter mapping (the one shipped on most "HT1621B" boards).
 * Bits are MSB-first throughout, including the per-nibble data bits.
 *
 * Pin map (all push-pull):
 *   pad[ 9] = CS   (active low; held low for the entire transaction)
 *   pad[10] = WR   (data shifted on its rising edge)
 *   pad[11] = DATA (master -> slave; we don't read back)
 *
 * Demo: SYS EN, LCD ON, then a single WRITE transaction to address 0x00
 * containing the 4-nibble payload 0x1, 0x2, 0x3, 0x4 (16 data bits).
 *
 * Sentinel: MAILBOX[0] = 0x16216216 when done.
 */

#include "../attoio.h"

#define CS_PIN   9
#define WR_PIN   10
#define DATA_PIN 11

#define ALL_MASK ((1u << CS_PIN) | (1u << WR_PIN) | (1u << DATA_PIN))

#define NI __attribute__((noinline))

/* TIMER-paced delay in clk_iop cycles. */
static void NI delay_cycles(uint32_t n) {
    if (n == 0) return;
    TIMER_CMP(0) = (n - 1) | TIMER_CMP_EN;
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET;
    TIMER_STATUS = TIMER_STATUS_MATCH0;
    while (!(TIMER_STATUS & TIMER_STATUS_MATCH0)) { }
    TIMER_STATUS = TIMER_STATUS_MATCH0;
}

/* HT1621 max clock ~ 1 MHz.  T_HALF = TIMER cycles per WR half-period.
 * The TIMER setup overhead (write CMP, write CTL/RESET, write STATUS,
 * then poll) doesn't fit cleanly under ~16 cycles — values < 16 cause
 * the match to be cleared *after* it has already fired and the count
 * has run past CMP, so the poll never sees the next match.  32 keeps
 * us comfortably above that floor.  Real HW would likely run faster
 * once a shadow-CMP / one-shot HW pulse mode lands. */
#define T_HALF  32u

static void NI ht_send_bits(uint32_t bits, unsigned nbits) {
    /* Emit MSB-first.  WR idle is high; we drive WR low, set DATA, then
     * raise WR — the slave samples DATA on the rising edge. */
    for (int i = (int)nbits - 1; i >= 0; --i) {
        unsigned bit = (bits >> i) & 1u;
        GPIO_OUT_CLR = 1u << WR_PIN;            /* WR low                    */
        if (bit) GPIO_OUT_SET = 1u << DATA_PIN; /* present DATA              */
        else     GPIO_OUT_CLR = 1u << DATA_PIN;
        delay_cycles(T_HALF);
        GPIO_OUT_SET = 1u << WR_PIN;            /* WR high — slave samples   */
        delay_cycles(T_HALF);
    }
}

/* COMMAND transaction: type 111 + 8-bit cmd + 1 don't-care = 12 bits.   */
static void NI ht_cmd(uint8_t cmd) {
    GPIO_OUT_CLR = 1u << CS_PIN;
    delay_cycles(T_HALF);
    /* Pack as 12 MSB-first bits: [111][cmd[7:0]][0]. */
    uint32_t frame = (0x7u << 9) | ((uint32_t)cmd << 1) | 0u;
    ht_send_bits(frame, 12);
    GPIO_OUT_SET = 1u << CS_PIN;
    delay_cycles(T_HALF);
}

/* WRITE transaction: type 100 + 6-bit addr + N x 4-bit nibbles.        *
 * `payload` carries 4*nnibs MSB-first bits.                            */
static void NI ht_write(uint8_t addr6, uint32_t payload, unsigned nnibs) {
    GPIO_OUT_CLR = 1u << CS_PIN;
    delay_cycles(T_HALF);
    /* Type ID + address: 3 + 6 = 9 bits MSB-first. */
    uint32_t header = (0x4u << 6) | (addr6 & 0x3Fu);
    ht_send_bits(header, 9);
    ht_send_bits(payload, 4u * nnibs);
    GPIO_OUT_SET = 1u << CS_PIN;
    delay_cycles(T_HALF);
}

int main(void) {
    /* Idle: CS high, WR high, DATA low. */
    GPIO_OUT_CLR = ALL_MASK;
    GPIO_OUT_SET = (1u << CS_PIN) | (1u << WR_PIN);
    GPIO_OE_SET  = ALL_MASK;
    MAILBOX_W32[0] = 0;

    /* Init: SYS EN (0x03) then LCD ON (0x07). */
    ht_cmd(0x03);
    ht_cmd(0x07);

    /* Write 4 nibbles 0x1 0x2 0x3 0x4 at address 0. */
    ht_write(0x00, 0x1234u, 4);

    MAILBOX_W32[0] = 0x16216216u;
    while (1) wfi();
}
