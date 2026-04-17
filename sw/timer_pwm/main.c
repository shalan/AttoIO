/*
 * timer_pwm/main.c — exercises the TIMER hardware.
 *
 * Behavior:
 *   1. Configure TIMER with auto-reload mode (CMP0 defines the period).
 *   2. CMP0 matches every 40 counts and toggles pad[3].
 *      That produces a pad[3] square wave with period = 2 * 40 = 80
 *      clk_iop cycles (each half-period is 40 counts).
 *      At clk_iop = 30 MHz that would be 80 / 30e6 ≈ 2.67 µs per period
 *      (375 kHz). In the testbench we only need the ratio — 80 cycles.
 *   3. Write a sentinel into mailbox[0] so the host knows we started.
 *   4. Spin forever with WFI.
 */

#include "../attoio.h"

int main(void) {
    /* Drive pad[3] as output so the scope can see the PWM waveform.
     * (The timer will force OE high on its selected pad, but setting it
     *  here too matches the usual "GPIO then TIMER" pattern.) */
    GPIO_OE_SET = 1u << 3;

    /* CMP0 defines the period and toggles pad[3].
     *   match every 40 counts -> 80-cycle square wave. */
    timer_cmp_pwm(0, 40 - 1, 3);

    /* Sentinel for the testbench. */
    MAILBOX_W32[0] = 0xCAFEBABEu;

    /* Turn on the counter with auto-reload. */
    TIMER_CTL = TIMER_CTL_EN | TIMER_CTL_AUTO_RELOAD;

    while (1) wfi();
}
