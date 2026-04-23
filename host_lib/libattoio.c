/*
 * libattoio.c — host-side helpers for an AttoIO macro instance.
 *
 * See libattoio.h for the callback contract.  This file is stateless
 * apart from the attoio_t the caller owns.
 */

#include "libattoio.h"

/* ------------- tiny wrappers around the transport callbacks ------------ */
static inline void W(attoio_t *a, uint32_t addr, uint32_t data)
{
    a->apb_write(a->ctx, addr, data);
}
static inline uint32_t R(attoio_t *a, uint32_t addr)
{
    return a->apb_read(a->ctx, addr);
}
static inline void Y(attoio_t *a)
{
    if (a->yield) a->yield(a->ctx);
}

/* ---------------------- IOP reset / doorbells ------------------------- */

void attoio_hold_reset   (attoio_t *a) { W(a, ATTOIO_REG_IOP_CTRL, 1u); }
void attoio_release_reset(attoio_t *a) { W(a, ATTOIO_REG_IOP_CTRL, 0u); }
void attoio_pulse_nmi    (attoio_t *a) { W(a, ATTOIO_REG_IOP_CTRL, 2u); }

void attoio_raise_h2c    (attoio_t *a) { W(a, ATTOIO_REG_H2C, 1u); }

int  attoio_wait_c2h(attoio_t *a)
{
    unsigned n = 0;
    while (1) {
        if (R(a, ATTOIO_REG_C2H) & 1u) {
            W(a, ATTOIO_REG_C2H, 1u);   /* W1C */
            return 0;
        }
        if (a->poll_limit && ++n >= a->poll_limit) return -1;
        Y(a);
    }
}

/* ---------------------- Firmware load path ----------------------------- */

int attoio_load_firmware(attoio_t *a, const uint32_t *image, size_t nwords)
{
    if (nwords > 256) return -1;           /* SRAM A = 256 words (1 KB) */
    attoio_hold_reset(a);
    for (size_t i = 0; i < nwords; i++) {
        W(a, ATTOIO_ADDR_SRAM_A_BASE + (uint32_t)(i << 2), image[i]);
    }
    return 0;
}

/* ---------------------- PINMUX ---------------------------------------- */

void attoio_pinmux_set(attoio_t *a, uint32_t pinmux)
{
    W(a, ATTOIO_REG_PINMUX_LO,  pinmux        & 0xFFFFu);
    W(a, ATTOIO_REG_PINMUX_HI, (pinmux >> 16) & 0xFFFFu);
}
uint32_t attoio_pinmux_get(attoio_t *a)
{
    uint32_t lo = R(a, ATTOIO_REG_PINMUX_LO) & 0xFFFFu;
    uint32_t hi = R(a, ATTOIO_REG_PINMUX_HI) & 0xFFFFu;
    return lo | (hi << 16);
}

uint32_t attoio_version(attoio_t *a) { return R(a, ATTOIO_REG_VERSION); }

/* ---------------------- Generic RPC call ------------------------------- */

int attoio_rpc(attoio_t *a, uint8_t group, uint8_t op,
               const uint32_t *args, unsigned nargs,
               uint32_t *reply, unsigned nreply,
               uint32_t *status_out)
{
    /* Pack args into mbox[2..2+nargs-1] */
    for (unsigned i = 0; i < nargs; i++)
        W(a, ATTOIO_ADDR_MAILBOX_WORD(2 + i), args[i]);

    /* Command word — version | flags | group | op */
    uint32_t cmd = attoio_rpc_cmd(group, op, 0);
    W(a, ATTOIO_ADDR_MAILBOX_WORD(1), cmd);

    /* Sentinel LAST */
    W(a, ATTOIO_ADDR_MAILBOX_WORD(0), ATTOIO_RPC_REQUEST);

    /* Ring doorbell */
    attoio_raise_h2c(a);

    /* Wait for ACK (C2H) */
    if (attoio_wait_c2h(a) != 0) {
        if (status_out) *status_out = 0xFFFFFFFFu;
        return -1;                         /* timeout */
    }

    uint32_t st = R(a, ATTOIO_ADDR_MAILBOX_WORD(31));
    if (status_out) *status_out = st;

    if (reply) {
        for (unsigned i = 0; i < nreply; i++)
            reply[i] = R(a, ATTOIO_ADDR_MAILBOX_WORD(2 + i));
    }

    return (st == ATTOIO_OK) ? 0 : (int)st;
}

/* ---------------------- Typed wrappers -------------------------------- */

uint32_t attoio_sys_ping(attoio_t *a)
{
    uint32_t reply = 0, st = 0;
    int rc = attoio_rpc(a, RPC_GRP_SYS, RPC_SYS_PING,
                        0, 0, &reply, 1, &st);
    return (rc == 0) ? reply : 0;
}

int attoio_padctl_set(attoio_t *a, unsigned pin, uint8_t flags)
{
    uint32_t args[2] = { pin, flags };
    uint32_t st = 0;
    return attoio_rpc(a, RPC_GRP_PADCTL, RPC_PADCTL_SET,
                      args, 2, 0, 0, &st);
}

int attoio_padctl_get(attoio_t *a, unsigned pin, uint8_t *flags_out)
{
    uint32_t args[1] = { pin };
    uint32_t reply = 0, st = 0;
    int rc = attoio_rpc(a, RPC_GRP_PADCTL, RPC_PADCTL_GET,
                        args, 1, &reply, 1, &st);
    if (rc == 0 && flags_out) *flags_out = (uint8_t)(reply & 0xFFu);
    return rc;
}

int attoio_gpio_init(attoio_t *a, uint32_t out_mask, uint32_t oe_mask)
{
    uint32_t args[2] = { out_mask, oe_mask };
    uint32_t st = 0;
    return attoio_rpc(a, RPC_GRP_INIT, RPC_INIT_GPIO,
                      args, 2, 0, 0, &st);
}
