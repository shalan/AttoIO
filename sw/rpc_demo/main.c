/*
 * rpc_demo/main.c — minimum RPC demo firmware.
 *
 * This firmware does nothing autonomous — it just enables interrupts
 * and sleeps.  The weak __isr in sw/common/attoio_rpc.c services
 * host-driven RPC calls for SYS/PADCTL/INIT.
 *
 * Host-side test pattern:
 *   attoio_sys_ping()                 -> returns version
 *   attoio_padctl_set(pin, flags)     -> configures a pad
 *   attoio_gpio_init(out, oe)         -> bulk GPIO preset
 *
 * Firmware size budget (post-link): ~250-300 B of SRAM A, leaving
 * ~700 B free for an app that wants to add its own __isr (overriding
 * the weak default) while still linking attoio_rpc_service() for
 * host-side setup calls.
 */

#include "../attoio.h"
#include "attoio_rpc.h"

extern void attoio_rpc_init(void);
extern int  attoio_rpc_service(void);

void __isr(void)
{
    (void)attoio_rpc_service();
}

int main(void)
{
    /* Sentinel: once reached, the firmware is live and waiting. */
    MAILBOX_W32[30] = 0xC0DEC0DEu;

    attoio_rpc_init();   /* csrsi mstatus, 8 -- enable interrupts */

    while (1) wfi();
}
