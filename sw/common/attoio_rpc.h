/*
 * attoio_rpc.h — AttoIO minimum RPC protocol (v1.0).
 *
 * Shared by the IOP-side firmware (sw/common/attoio_rpc.c) and the
 * host-side library (host_lib/libattoio.*).  The protocol is a thin
 * layer on top of the mailbox + doorbell primitives.
 *
 * Transport
 * ---------
 *     mbox[0]        = sentinel token
 *                        ATTOIO_RPC_REQUEST  while request pending
 *                        ATTOIO_RPC_ACK      once the IOP has processed it
 *     mbox[1]        = [31:24] api_version
 *                      [23:16] flags
 *                      [15: 8] group
 *                      [ 7: 0] op
 *     mbox[2..N]     = args (group/op specific)
 *     mbox[31]       = status (written by IOP before clearing sentinel)
 *
 * Round-trip (blocking)
 *   1. host fills args, then sentinel LAST = REQUEST
 *   2. host rings HOST_DOORBELL (APB 0x700)
 *   3. IOP ISR runs dispatcher, executes, writes status at mbox[31],
 *      writes mbox[0] = ACK LAST, then rings IOP_DOORBELL (APB 0x704)
 *   4. host waits for mbox[0] == ACK (or polls IOP_DOORBELL and W1C)
 *
 * The same host can issue the next call by rewriting mbox[2..N] and
 * flipping mbox[0] back to REQUEST.
 */

#ifndef ATTOIO_RPC_H
#define ATTOIO_RPC_H

#include <stdint.h>

#define ATTOIO_RPC_REQUEST   0xA5A5A5A5u
#define ATTOIO_RPC_ACK       0x00000000u

#define ATTOIO_API_VERSION   0x01u             /* v1 */

/* ---- Groups (byte [15:8] of mbox[1]) ---- */
#define RPC_GRP_SYS     0x01
#define RPC_GRP_PADCTL  0x02
#define RPC_GRP_INIT    0x03

/* ---- SYS ops ---- */
#define RPC_SYS_PING        0x01   /* args: none.  returns: mbox[2]=VERSION */
#define RPC_SYS_RESET_ACK   0x02   /* args: none.  returns: 0 */

/* ---- PADCTL ops ---- */
#define RPC_PADCTL_SET      0x01   /* args: pin, flags. returns: - */
#define RPC_PADCTL_GET      0x02   /* args: pin.        returns: flags */

/* ---- INIT ops ---- */
#define RPC_INIT_GPIO       0x01   /* args: out_mask, oe_mask.  returns: - */

/* ---- Status codes (mbox[31]) ---- */
#define ATTOIO_OK           0x00000000u
#define ATTOIO_EINVAL       0x00000001u
#define ATTOIO_ENOTSUP      0x00000002u
#define ATTOIO_EBUSY        0x00000003u
#define ATTOIO_EVER         0x00000004u

/* Helper to pack the mbox[1] command word. */
static inline uint32_t attoio_rpc_cmd(uint8_t group, uint8_t op, uint8_t flags)
{
    return ((uint32_t)ATTOIO_API_VERSION << 24)
         | ((uint32_t)flags              << 16)
         | ((uint32_t)group              <<  8)
         |  (uint32_t)op;
}

#endif /* ATTOIO_RPC_H */
