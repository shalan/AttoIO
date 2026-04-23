/*
 * libattoio.h — host-side helper library for an AttoIO macro instance.
 *
 * Provides typed wrappers for the minimum v1.0 RPC plus direct helpers
 * for the host-owned registers (reset, doorbells, PINMUX).  The library
 * is transport-agnostic: the caller supplies two callbacks that read
 * and write 32-bit words at an APB byte address.  On a real host CPU
 * those usually translate to MMIO accesses into the AttoIO APB window;
 * in simulation they can drive an APB testbench driver.
 *
 * All RPC helpers block until the IOP posts DOORBELL_C2H (ACK).  A
 * non-blocking variant may be added in a later release.
 */

#ifndef LIBATTOIO_H
#define LIBATTOIO_H

#include <stddef.h>
#include <stdint.h>

#include "../sw/common/attoio_rpc.h"

/* ----------------------------------------------------------------- */
/*  Transport — caller supplies these                                */
/* ----------------------------------------------------------------- */
typedef struct {
    /* `ctx` is passed back to both callbacks so drivers can keep
     * per-instance state (e.g. the AttoIO base address). */
    void     *ctx;
    void    (*apb_write)(void *ctx, uint32_t addr, uint32_t data);
    uint32_t (*apb_read) (void *ctx, uint32_t addr);
    /* Optional: small delay between polls while waiting for the ACK
     * doorbell.  If NULL the library spins as fast as it can. */
    void    (*yield)(void *ctx);
    /* Max number of poll iterations before giving up. 0 means unbounded. */
    unsigned  poll_limit;
} attoio_t;

/* ----------------------------------------------------------------- */
/*  Bring-up helpers (host-direct, no IOP involvement)                */
/* ----------------------------------------------------------------- */

/* Hold the IOP in reset (bit 0 of IOP_CTRL = 1). */
void attoio_hold_reset   (attoio_t *a);
/* Release the IOP — it starts executing at PC=0. */
void attoio_release_reset(attoio_t *a);
/* Fire a one-cycle NMI at the IOP. */
void attoio_pulse_nmi    (attoio_t *a);

/* Burst-write a firmware image into SRAM A.  The IOP must already be
 * held in reset (attoio_hold_reset() first).  `image` is little-endian
 * 32-bit words; `nwords` must not exceed 256 (= 1024 B). */
int  attoio_load_firmware(attoio_t *a, const uint32_t *image, size_t nwords);

/* Program PINMUX for all pads at once.  `pinmux` layout matches the
 * PINMUX_LO/HI register pair (2 bits per pad, pad p at bits [2p+:2]).
 * 00 = attoio, 01/10/11 = hp0/hp1/hp2. */
void attoio_pinmux_set   (attoio_t *a, uint32_t pinmux);
uint32_t attoio_pinmux_get(attoio_t *a);

/* Read the RO version register (expected 0x01_00_00_00 for v1.0). */
uint32_t attoio_version  (attoio_t *a);

/* Blocking wait for the C2H doorbell to fire, then W1C it.  Returns
 * zero on success, non-zero on poll-limit timeout. */
int  attoio_wait_c2h     (attoio_t *a);
void attoio_raise_h2c    (attoio_t *a);

/* ----------------------------------------------------------------- */
/*  RPC helpers (go through the mailbox + doorbell dispatcher)        */
/* ----------------------------------------------------------------- */

/* Generic blocking RPC call.
 *   group, op    — see attoio_rpc.h
 *   args/nargs   — copied into mbox[2..] before the request
 *   reply/nreply — copied from mbox[2..] after the ack
 *   *status_out  — raw status from mbox[31] (0 on success, ATTOIO_E* on fail)
 *
 * Returns 0 on success (ACK received, status == 0), non-zero on timeout
 * or on a non-zero status (with *status_out populated).
 */
int attoio_rpc(attoio_t *a, uint8_t group, uint8_t op,
               const uint32_t *args, unsigned nargs,
               uint32_t *reply, unsigned nreply,
               uint32_t *status_out);

/* ---- Typed convenience wrappers ---- */

/* Returns the IOP-reported version, or 0 on failure. */
uint32_t attoio_sys_ping (attoio_t *a);

/* Configure pad `pin`'s 8-bit PADCTL byte (pull/drive/slew/schmitt/...).
 * Returns 0 on success. */
int attoio_padctl_set    (attoio_t *a, unsigned pin, uint8_t flags);

/* Read pad `pin`'s PADCTL byte into *flags_out.  Returns 0 on success. */
int attoio_padctl_get    (attoio_t *a, unsigned pin, uint8_t *flags_out);

/* Preset GPIO_OUT and GPIO_OE before the IOP starts its emulation. */
int attoio_gpio_init     (attoio_t *a, uint32_t out_mask, uint32_t oe_mask);

/* ----------------------------------------------------------------- */
/*  Register offsets (exposed for direct access when needed)          */
/* ----------------------------------------------------------------- */
#define ATTOIO_REG_H2C            0x700
#define ATTOIO_REG_C2H            0x704
#define ATTOIO_REG_IOP_CTRL       0x708
#define ATTOIO_REG_VERSION        0x70C
#define ATTOIO_REG_PINMUX_LO      0x710
#define ATTOIO_REG_PINMUX_HI      0x714
#define ATTOIO_ADDR_SRAM_A_BASE   0x000
#define ATTOIO_ADDR_MAILBOX_BASE  0x600
#define ATTOIO_ADDR_MAILBOX_WORD(n)  (ATTOIO_ADDR_MAILBOX_BASE + ((n) << 2))

#endif /* LIBATTOIO_H */
