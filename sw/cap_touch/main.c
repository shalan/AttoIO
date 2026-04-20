/*
 * cap_touch/main.c — E21.  Self-capacitance touch sensing by R-C
 * timing.
 *
 * For each sensor pad:
 *   1. Drive LOW for PRECHARGE cycles (discharge C to ground).
 *   2. Release (OE=0).  Pad becomes an input.  External resistor
 *      (notional — modelled by the TB) begins charging the pad
 *      capacitance back toward HIGH.
 *   3. Poll GPIO_IN for the pad bit; count clk_iop cycles until it
 *      reads HIGH, or give up at CAP_MAX.
 *   4. Count ~= C.  Larger count = more capacitance = finger
 *      present.
 *
 * Two sensors in this demo:
 *   pad[0] = sensor A (no touch in test — short rise time)
 *   pad[1] = sensor B (simulated touch — long rise time)
 *
 * Mailbox:
 *   word 0 = done sentinel (1)
 *   word 1 = count for sensor A
 *   word 2 = 0xC0DEC0DE once armed
 *   word 3 = count for sensor B
 *   word 4 = touched-mask (bit 0 = sensor A touched, bit 1 = sensor B)
 */

#include "../attoio.h"

#define SENSOR_A_PAD   0u
#define SENSOR_B_PAD   1u

#define PRECHARGE      10u     /* clk_iop cycles of discharge */
#define CAP_MAX        200u    /* give up after this many polls */
#define CAP_THRESHOLD  10u     /* count > threshold => touched */

static uint32_t measure_sensor(uint32_t pad) {
    uint32_t mask = 1u << pad;

    /* Phase 1: drive LOW for PRECHARGE cycles. */
    GPIO_OUT_CLR = mask;
    GPIO_OE_SET  = mask;

    for (volatile uint32_t d = 0; d < PRECHARGE; d++) { /* busy wait */ }

    /* Phase 2: release — pad becomes input. */
    GPIO_OE_CLR = mask;

    /* Phase 3: poll until HIGH or CAP_MAX. */
    uint32_t count = 0;
    while (count < CAP_MAX) {
        if ((GPIO_IN >> pad) & 1u) break;
        count++;
    }
    return count;
}

int main(void) {
    MAILBOX_W32[0] = 0;
    MAILBOX_W32[1] = 0;
    MAILBOX_W32[3] = 0;
    MAILBOX_W32[4] = 0;

    uint32_t count_a = measure_sensor(SENSOR_A_PAD);
    uint32_t count_b = measure_sensor(SENSOR_B_PAD);

    uint32_t mask = 0;
    if (count_a > CAP_THRESHOLD) mask |= 1u;
    if (count_b > CAP_THRESHOLD) mask |= 2u;

    MAILBOX_W32[1] = count_a;
    MAILBOX_W32[3] = count_b;
    MAILBOX_W32[4] = mask;

    MAILBOX_W32[2] = 0xC0DEC0DEu;
    MAILBOX_W32[0] = 1;   /* done sentinel */
    while (1) wfi();
}
