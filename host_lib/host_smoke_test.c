/*
 * host_smoke_test.c — software smoke test for libattoio on the host side.
 *
 * Uses an in-process APB simulator: a 4 KB register map with a
 * handful of addresses (IOP_CTRL, doorbells, PINMUX) implementing
 * the v1.0 host-visible semantics, plus a trivial fake "IOP" that
 * answers RPC requests synchronously from attoio_wait_c2h().
 *
 * The point is to exercise the library's typed wrappers and their
 * transport glue — not to reproduce the real IOP.  The real IOP is
 * exercised by sim/tb_rpc.v.
 */

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libattoio.h"

/* --------------------- in-process fake AttoIO ------------------------- */
typedef struct {
    uint32_t reg[1024];     /* covers 4 KB of 32-bit words */
    uint32_t mbox[32];
} fake_t;

static uint32_t fake_read(void *vctx, uint32_t addr)
{
    fake_t *f = vctx;
    if (addr >= 0x600 && addr < 0x680) {
        return f->mbox[(addr - 0x600) >> 2];
    }
    return f->reg[addr >> 2];
}

static void fake_dispatch(fake_t *f)
{
    /* Emulate the IOP dispatcher: read mbox[0] sentinel, execute op,
     * write status + ack + raise C2H. */
    if (f->mbox[0] != ATTOIO_RPC_REQUEST) return;

    uint32_t cmd = f->mbox[1];
    uint8_t  grp = (cmd >> 8)  & 0xFFu;
    uint8_t  op  =  cmd        & 0xFFu;
    uint32_t status = ATTOIO_OK;

    switch ((grp << 8) | op) {
        case (RPC_GRP_SYS    << 8) | RPC_SYS_PING:
            f->mbox[2] = 0x01000000u;  /* v1.0.0 */
            break;
        case (RPC_GRP_PADCTL << 8) | RPC_PADCTL_SET:
            if (f->mbox[2] >= 16) status = ATTOIO_EINVAL;
            else                  f->reg[(0x720 + (f->mbox[2] << 2)) >> 2] = f->mbox[3];
            break;
        case (RPC_GRP_PADCTL << 8) | RPC_PADCTL_GET:
            if (f->mbox[2] >= 16) status = ATTOIO_EINVAL;
            else                  f->mbox[2] = f->reg[(0x720 + (f->mbox[2] << 2)) >> 2];
            break;
        case (RPC_GRP_INIT   << 8) | RPC_INIT_GPIO:
            f->reg[0x704 >> 2] = f->mbox[2];  /* fake GPIO_OUT */
            f->reg[0x708 >> 2] = f->mbox[3];  /* fake GPIO_OE */
            break;
        default: status = ATTOIO_ENOTSUP; break;
    }

    f->mbox[31] = status;
    f->mbox[0]  = ATTOIO_RPC_ACK;
    f->reg[ATTOIO_REG_C2H >> 2] = 1u;    /* fake IOP raises C2H */
}

static void fake_write(void *vctx, uint32_t addr, uint32_t data)
{
    fake_t *f = vctx;
    if (addr >= 0x600 && addr < 0x680) {
        f->mbox[(addr - 0x600) >> 2] = data;
        return;
    }
    switch (addr) {
        case ATTOIO_REG_H2C:
            /* Doorbell — dispatch immediately to emulate an IOP that
             * services requests synchronously. */
            if (data & 1u) fake_dispatch(f);
            break;
        case ATTOIO_REG_C2H:
            /* W1C */
            if (data & 1u) f->reg[ATTOIO_REG_C2H >> 2] = 0;
            break;
        default:
            f->reg[addr >> 2] = data;
            break;
    }
}

/* Fake IOP answers instantly, so no polling is needed in the library's
 * yield hook.  attoio_wait_c2h will just see the bit go high on the
 * very first read. */

/* ---------------------------- tests ---------------------------------- */
static fake_t g_fake;

static void init_fake(attoio_t *a)
{
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.reg[ATTOIO_REG_VERSION >> 2] = 0x01000000u;
    g_fake.reg[ATTOIO_REG_IOP_CTRL >> 2] = 1u;   /* reset asserted */
    a->ctx        = &g_fake;
    a->apb_write  = fake_write;
    a->apb_read   = fake_read;
    a->yield      = NULL;
    a->poll_limit = 1000;
}

int main(void)
{
    attoio_t a;
    init_fake(&a);

    /* 1. Version register read */
    uint32_t v = attoio_version(&a);
    if (v != 0x01000000u) { fprintf(stderr, "FAIL: version=%08x\n", v); return 1; }
    printf("  PASS: VERSION = 0x%08x\n", v);

    /* 2. Reset control */
    attoio_release_reset(&a);
    assert(g_fake.reg[ATTOIO_REG_IOP_CTRL >> 2] == 0);
    attoio_hold_reset(&a);
    assert(g_fake.reg[ATTOIO_REG_IOP_CTRL >> 2] == 1);
    printf("  PASS: reset toggle\n");

    /* 3. Firmware load */
    uint32_t img[4] = { 0xAAAA0001, 0xAAAA0002, 0xAAAA0003, 0xAAAA0004 };
    int rc = attoio_load_firmware(&a, img, 4);
    assert(rc == 0);
    for (int i = 0; i < 4; i++)
        assert(g_fake.reg[i] == img[i]);
    printf("  PASS: firmware load (4 words)\n");

    /* 4. PINMUX set + get */
    attoio_pinmux_set(&a, 0x01234567u);
    uint32_t pm = attoio_pinmux_get(&a);
    if (pm != 0x01234567u) {
        fprintf(stderr, "FAIL: PINMUX got=%08x exp=01234567\n", pm);
        return 1;
    }
    printf("  PASS: PINMUX set/get = 0x%08x\n", pm);

    /* 5. SYS.ping via RPC */
    uint32_t ver = attoio_sys_ping(&a);
    if (ver != 0x01000000u) { fprintf(stderr, "FAIL: ping=%08x\n", ver); return 1; }
    printf("  PASS: SYS.ping = 0x%08x\n", ver);

    /* 6. PADCTL.set + get round-trip */
    rc = attoio_padctl_set(&a, 5, 0xA5);
    assert(rc == 0);
    uint8_t flags = 0;
    rc = attoio_padctl_get(&a, 5, &flags);
    assert(rc == 0);
    if (flags != 0xA5) { fprintf(stderr, "FAIL: padctl get=%02x\n", flags); return 1; }
    printf("  PASS: PADCTL.set(5, 0xA5) + get = 0x%02x\n", flags);

    /* 7. INIT.gpio bulk preset */
    rc = attoio_gpio_init(&a, 0x0F00, 0xFFFF);
    assert(rc == 0);
    printf("  PASS: INIT.gpio(out=0x0F00, oe=0xFFFF)\n");

    /* 8. Bad pin returns error status */
    rc = attoio_padctl_set(&a, 99, 0x01);
    if (rc != (int)ATTOIO_EINVAL) {
        fprintf(stderr, "FAIL: expected EINVAL, got %d\n", rc);
        return 1;
    }
    printf("  PASS: bad pin -> EINVAL\n");

    printf("ALL LIBATTOIO SMOKE TESTS PASSED\n");
    return 0;
}
