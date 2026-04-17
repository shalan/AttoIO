#ifndef ATTOIO_MAILBOX_H
#define ATTOIO_MAILBOX_H

#include <stdint.h>

uint8_t  mbx_read_u8 (unsigned off);
uint32_t mbx_read_u32(unsigned off);
void     mbx_write_u8 (unsigned off, uint8_t  v);
void     mbx_write_u32(unsigned off, uint32_t v);

#endif
