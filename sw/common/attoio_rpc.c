/*
 * attoio_rpc.c — IOP-side dispatcher for the minimum RPC protocol.
 *
 * Plugged into the default __isr via attoio_rpc_init(): the module
 * reserves the host-doorbell IRQ for RPC service.  Apps that want
 * additional ISR work should call attoio_rpc_service() themselves
 * from their __isr instead of calling attoio_rpc_init().
 *
 * Code footprint target: ~200 B.  Only SYS + PADCTL + INIT groups are
 * implemented in v1.0; everything else returns ENOTSUP.
 */

#include <stdint.h>
#include "attoio_rpc.h"
#include "../attoio.h"

#ifndef ATTOIO_NGPIO
#define ATTOIO_NGPIO 16
#endif

#define MBOX_WORD(n)   (MAILBOX_W32[(n)])
#define MBOX_STATUS    (MAILBOX_W32[31])

/* ---- SYS ---- */
static uint32_t rpc_sys(uint8_t op)
{
    switch (op) {
        case RPC_SYS_PING:
            /* Return version info at mbox[2]. Caller already put args
             * in mbox[2..]; we overwrite them with the reply. */
            MBOX_WORD(2) = 0x01000000u;   /* v1.0.0 */
            return ATTOIO_OK;
        case RPC_SYS_RESET_ACK:
            return ATTOIO_OK;
        default:
            return ATTOIO_ENOTSUP;
    }
}

/* ---- PADCTL ---- */
static uint32_t rpc_padctl(uint8_t op)
{
    uint32_t pin = MBOX_WORD(2);
    if (pin >= ATTOIO_NGPIO) return ATTOIO_EINVAL;

    switch (op) {
        case RPC_PADCTL_SET: {
            uint32_t flags = MBOX_WORD(3);
            if (flags & ~0xFFu) return ATTOIO_EINVAL;
            PADCTL(pin) = flags;
            return ATTOIO_OK;
        }
        case RPC_PADCTL_GET:
            MBOX_WORD(2) = PADCTL(pin);
            return ATTOIO_OK;
        default:
            return ATTOIO_ENOTSUP;
    }
}

/* ---- INIT ---- */
static uint32_t rpc_init(uint8_t op)
{
    switch (op) {
        case RPC_INIT_GPIO: {
            uint32_t out = MBOX_WORD(2);
            uint32_t oe  = MBOX_WORD(3);
            GPIO_OUT = out;
            GPIO_OE  = oe;
            return ATTOIO_OK;
        }
        default:
            return ATTOIO_ENOTSUP;
    }
}

/* Service one RPC request if the host doorbell is pending.  Returns
 * non-zero if a request was consumed.  Safe to call from any ISR. */
int attoio_rpc_service(void)
{
    if (!doorbell_h2c_pending()) return 0;
    doorbell_h2c_ack();                   /* drop iop_irq */

    if (MBOX_WORD(0) != ATTOIO_RPC_REQUEST) {
        /* Doorbell rang but no valid RPC request — ignore. */
        return 1;
    }

    uint32_t cmd = MBOX_WORD(1);
    uint8_t  ver = (cmd >> 24) & 0xFFu;
    uint8_t  grp = (cmd >>  8) & 0xFFu;
    uint8_t  op  =  cmd        & 0xFFu;
    uint32_t status;

    if (ver != ATTOIO_API_VERSION) {
        status = ATTOIO_EVER;
    } else {
        switch (grp) {
            case RPC_GRP_SYS:    status = rpc_sys(op);    break;
            case RPC_GRP_PADCTL: status = rpc_padctl(op); break;
            case RPC_GRP_INIT:   status = rpc_init(op);   break;
            default:             status = ATTOIO_ENOTSUP; break;
        }
    }

    MBOX_STATUS = status;
    __asm__ volatile ("" ::: "memory");
    MBOX_WORD(0) = ATTOIO_RPC_ACK;        /* ack LAST */
    doorbell_c2h_raise();                 /* notify host (the signal
                                             the host library polls) */
    return 1;
}

/* Enable the IOP's MIE bit.  Apps are expected to define a __isr that
 * invokes attoio_rpc_service() in its body; we deliberately do NOT
 * provide a default here, so that applications with their own __isr
 * (most of the Phase 0.x examples) don't hit a multiply-defined
 * symbol when linked against this object. */
void attoio_rpc_init(void)
{
    __asm__ volatile ("csrsi mstatus, 8");
}
