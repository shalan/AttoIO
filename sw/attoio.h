/*
 * attoio.h — Firmware-side register map and helpers for the AttoIO
 * hard macro. All offsets match docs/spec.md.
 *
 * Usage:
 *   #include "attoio.h"
 *   gpio_set_out(0, 1);
 *   while (!doorbell_h2c_pending()) { wfi(); }
 */

#ifndef ATTOIO_H
#define ATTOIO_H

#include <stdint.h>

/* ------------------------------------------------------------------ */
/*  Memory map                                                        */
/* ------------------------------------------------------------------ */
#define ATTOIO_MMIO_BASE    0x00000300u
#define ATTOIO_MAILBOX_BASE 0x00000200u

/* ------------------------------------------------------------------ */
/*  GPIO                                                              */
/* ------------------------------------------------------------------ */
#define GPIO_IN         (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x00))
#define GPIO_OUT        (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x04))
#define GPIO_OE         (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x08))
#define GPIO_OUT_SET    (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x0C))
#define GPIO_OUT_CLR    (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x10))
#define GPIO_OE_SET     (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x14))
#define GPIO_OE_CLR     (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x18))

#define PADCTL_BASE     (ATTOIO_MMIO_BASE + 0x20)
#define PADCTL(i)       (*(volatile uint32_t *)(PADCTL_BASE + ((i) << 2)))

/* ------------------------------------------------------------------ */
/*  Wake latch (combined pad-edge event)                              */
/* ------------------------------------------------------------------ */
#define WAKE_LATCH      (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x60))

/* ------------------------------------------------------------------ */
/*  Doorbells                                                         */
/* ------------------------------------------------------------------ */
#define DOORBELL_H2C    (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x80))  /* R/W1C */
#define DOORBELL_C2H    (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x84))  /* RW    */

/* ------------------------------------------------------------------ */
/*  SPI shift helper                                                  */
/* ------------------------------------------------------------------ */
#define SPI_DATA        (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x90))
#define SPI_CFG         (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x94))
#define SPI_STATUS      (*(volatile uint32_t *)(ATTOIO_MMIO_BASE + 0x98))

#define SPI_CFG_SCK_SHIFT   0
#define SPI_CFG_MOSI_SHIFT  4   /* MOSI pin = MOSI_SHIFT bits + bit 4 of SCK field */
#define SPI_CFG_CPOL        (1u << 6)
#define SPI_CFG_CPHA        (1u << 7)

#define SPI_STATUS_BUSY     (1u << 0)

/* ------------------------------------------------------------------ */
/*  Mailbox                                                           */
/* ------------------------------------------------------------------ */
#define MAILBOX         ((volatile uint8_t *) ATTOIO_MAILBOX_BASE)
#define MAILBOX_W32     ((volatile uint32_t *)ATTOIO_MAILBOX_BASE)

/* Conventional split (see docs/spec.md §7.3) */
#define MBX_CMD_BASE    0x200u   /* host -> IOP, 32 B */
#define MBX_RSP_BASE    0x220u   /* IOP -> host, 32 B */
#define MBX_DATA_BASE   0x240u   /* bulk, 192 B       */

/* ------------------------------------------------------------------ */
/*  Inline helpers                                                    */
/* ------------------------------------------------------------------ */
static inline void wfi(void) {
    __asm__ volatile ("wfi");
}

static inline void gpio_set(unsigned pin)   { GPIO_OUT_SET = 1u << (pin & 15); }
static inline void gpio_clear(unsigned pin) { GPIO_OUT_CLR = 1u << (pin & 15); }
static inline void gpio_oe(unsigned pin, int en) {
    if (en) GPIO_OE_SET = 1u << (pin & 15);
    else    GPIO_OE_CLR = 1u << (pin & 15);
}
static inline unsigned gpio_read(unsigned pin) {
    return (GPIO_IN >> (pin & 15)) & 1u;
}

static inline int doorbell_h2c_pending(void) { return DOORBELL_H2C & 1u; }
static inline void doorbell_h2c_ack(void)   { DOORBELL_H2C = 1u; }     /* W1C */
static inline void doorbell_c2h_raise(void) { DOORBELL_C2H = 1u; }
static inline void doorbell_c2h_clear(void) { DOORBELL_C2H = 0; }

/* Cycle-count busy wait. At 30 MHz clk_iop, ~33 ns per NOP. */
static inline void wait_cycles(uint32_t n) {
    while (n--) __asm__ volatile ("nop");
}

#endif /* ATTOIO_H */
