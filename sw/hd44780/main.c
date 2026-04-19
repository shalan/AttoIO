/*
 * hd44780/main.c — Phase 5b / E5: HD44780 character LCD driver, 4-bit mode.
 *
 * Pin map (push-pull, R/W tied low externally — write-only):
 *   pad[ 9] = RS    (0 = command, 1 = data)
 *   pad[10] = E     (active-high enable strobe; latches on falling edge)
 *   pad[11] = D4    (LSB of nibble)
 *   pad[12] = D5
 *   pad[13] = D6
 *   pad[14] = D7    (MSB of nibble)
 *
 * Notes on init:
 *   A real HD44780 needs the canonical 8-bit "0x3, 0x3, 0x3, 0x2" preamble
 *   to get out of an unknown-state-on-power-on into 4-bit mode.  The
 *   behavioural model we test against assumes 4-bit mode from t=0, so
 *   we skip the preamble in sim — the comment block below shows the
 *   real-HW additions (3 single-nibble strobes + a 0x2 nibble) for
 *   anyone porting this to a physical panel.
 *
 * Demo: writes "AttoIO!" to row 0 starting at column 0.
 *
 * Sentinel: MAILBOX[0] = 0xA110A110 when done ("Allo Allo").
 */

#include "../attoio.h"

#ifndef ATTOIO_CLK_HZ
# define ATTOIO_CLK_HZ 25000000u
#endif

#define RS_PIN  9
#define E_PIN   10
#define D4_PIN  11
#define D5_PIN  12
#define D6_PIN  13
#define D7_PIN  14

#define DATA_MASK  ((1u << D4_PIN) | (1u << D5_PIN) | \
                    (1u << D6_PIN) | (1u << D7_PIN))
#define ALL_MASK   (DATA_MASK | (1u << RS_PIN) | (1u << E_PIN))

#define NI __attribute__((noinline))

/* TIMER-paced delay; n is number of cycles at ATTOIO_CLK_HZ. */
static void NI delay_cycles(uint32_t n) {
    if (n == 0) return;
    TIMER_CMP(0) = (n - 1) | TIMER_CMP_EN;
    TIMER_CTL    = TIMER_CTL_EN | TIMER_CTL_RESET;
    TIMER_STATUS = TIMER_STATUS_MATCH0;
    while (!(TIMER_STATUS & TIMER_STATUS_MATCH0)) { }
    TIMER_STATUS = TIMER_STATUS_MATCH0;
}

/* HD44780 timings — radically shortened for sim, but kept proportional.
 *  E pulse high  >= 230 ns   -> ~16 cycles @ 25 MHz
 *  E cycle time  >= 500 ns   -> ~32 cycles
 *  Most cmd exec >= 37 µs    -> ~32 cycles in sim (we are not driving real silicon)
 *  Clear/Home    >= 1.52 ms  -> ~64 cycles in sim                                   */
#define T_E_HIGH    16u
#define T_E_LOW     16u
#define T_CMD       32u
#define T_LONG      64u

static void NI lcd_pulse_e(void) {
    GPIO_OUT_SET = 1u << E_PIN;
    delay_cycles(T_E_HIGH);
    GPIO_OUT_CLR = 1u << E_PIN;
    delay_cycles(T_E_LOW);
}

/* Drive D4..D7 with the low 4 bits of `n`. */
static void NI lcd_drive_nibble(uint8_t n) {
    uint32_t set_bits = 0;
    if (n & 0x1u) set_bits |= 1u << D4_PIN;
    if (n & 0x2u) set_bits |= 1u << D5_PIN;
    if (n & 0x4u) set_bits |= 1u << D6_PIN;
    if (n & 0x8u) set_bits |= 1u << D7_PIN;
    /* Clear-then-set keeps glitches minimal; both are single MMIO writes. */
    GPIO_OUT_CLR = DATA_MASK;
    GPIO_OUT_SET = set_bits;
}

static void NI lcd_send(uint8_t b, int rs) {
    if (rs) GPIO_OUT_SET = 1u << RS_PIN;
    else    GPIO_OUT_CLR = 1u << RS_PIN;
    lcd_drive_nibble((uint8_t)(b >> 4));
    lcd_pulse_e();
    lcd_drive_nibble((uint8_t)(b & 0x0Fu));
    lcd_pulse_e();
    delay_cycles(T_CMD);
}

static void NI lcd_cmd (uint8_t c) { lcd_send(c, 0); }
static void NI lcd_data(uint8_t d) { lcd_send(d, 1); }

int main(void) {
    /* Drive all six pads as push-pull outputs, idle low. */
    GPIO_OUT_CLR = ALL_MASK;
    GPIO_OE_SET  = ALL_MASK;
    MAILBOX_W32[0] = 0;

    /* --- Real-HW init preamble (commented out for sim) ---
     *   delay_cycles(40 ms-equivalent);
     *   lcd_drive_nibble(0x3); lcd_pulse_e(); delay_cycles(5 ms-equiv);
     *   lcd_drive_nibble(0x3); lcd_pulse_e(); delay_cycles(150 us-equiv);
     *   lcd_drive_nibble(0x3); lcd_pulse_e(); delay_cycles(150 us-equiv);
     *   lcd_drive_nibble(0x2); lcd_pulse_e();   // now in 4-bit mode
     */

    lcd_cmd(0x28);   /* Function set: 4-bit, 2 lines, 5x8 font            */
    lcd_cmd(0x0C);   /* Display control: display on, cursor off, blink off */
    lcd_cmd(0x01);   /* Clear display                                      */
    delay_cycles(T_LONG);
    lcd_cmd(0x06);   /* Entry mode: increment, no shift                    */
    lcd_cmd(0x80);   /* DDRAM address = 0x00 (row 0, col 0)                */

    static const char msg[] = "AttoIO!";
    for (const char *p = msg; *p; ++p) lcd_data((uint8_t)*p);

    MAILBOX_W32[0] = 0xA110A110u;
    while (1) wfi();
}
