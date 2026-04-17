/*
 * timing.c — cycle-accurate delay helpers. At 30 MHz clk_iop, the
 * wait_us/wait_ns functions assume that frequency; adjust ATTOIO_CLK_HZ
 * in config.h of a firmware if it differs.
 *
 * These are deliberately written to be simple rather than zero-overhead
 * accurate: loop+decrement is ~5 cycles on RV32EC shared-adder.
 */

#include <stdint.h>
#include "timing.h"

#ifndef ATTOIO_CLK_HZ
#define ATTOIO_CLK_HZ 30000000u
#endif

/* cycles per loop iteration of wait_cycles(); derived empirically from
 * disasm — tune per-toolchain if it changes. */
#define CYCLES_PER_LOOP 5u

void wait_us(uint32_t us) {
    uint32_t cycles = (uint32_t)((uint64_t)us * ATTOIO_CLK_HZ / 1000000u);
    /* Remove the rough cost of the loop itself. */
    if (cycles > CYCLES_PER_LOOP) cycles /= CYCLES_PER_LOOP;
    while (cycles--) __asm__ volatile ("nop");
}

void wait_ns(uint32_t ns) {
    uint32_t cycles = (uint32_t)((uint64_t)ns * ATTOIO_CLK_HZ / 1000000000u);
    if (cycles < 1) return;
    while (cycles--) __asm__ volatile ("nop");
}
