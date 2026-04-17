/*
 * mailbox.c — thin helpers around the host<->IOP mailbox.
 *
 * Memory layout (see docs/spec.md §7.3):
 *   0x200..0x21F  command   (host -> IOP)
 *   0x220..0x23F  response  (IOP -> host)
 *   0x240..0x2FF  bulk data (bi-dir)
 *
 * Access is performed directly via the MAILBOX pointer. These helpers
 * exist to keep call sites readable.
 */

#include <stdint.h>
#include "attoio.h"
#include "mailbox.h"

uint8_t  mbx_read_u8 (unsigned off)              { return MAILBOX[off & 0xFF]; }
uint32_t mbx_read_u32(unsigned off)              { return MAILBOX_W32[(off >> 2) & 0x3F]; }
void     mbx_write_u8 (unsigned off, uint8_t  v) { MAILBOX[off & 0xFF] = v; }
void     mbx_write_u32(unsigned off, uint32_t v) { MAILBOX_W32[(off >> 2) & 0x3F] = v; }
