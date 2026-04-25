// ---------------------------------------------------------------------
// attoio_variant.vh — testbench-side variant switch.
//
// Define ATTOIO_CFSRAM on the compile line to select the CFSRAM top.
// Default (no define) = DFFRAM variant, matching the v1.x behaviour.
//
// Exposes:
//   `DUT_MOD        module name of the top to instantiate
//   `AW             APB PADDR / host_addr width (bits)
//   `REG(off)       absolute APB address for MMIO offset `off`
//   `MBX(off)       absolute APB address for mailbox offset `off`
//   `SRA(off)       absolute APB address for SRAM A offset `off`
//
// Testbenches replace every hard-coded 11'hXXX / 11'h6XX / 11'h7XX
// literal with the matching REG/MBX/SRA macro so they work on either
// variant without further change.
// ---------------------------------------------------------------------

`ifndef ATTOIO_VARIANT_VH
`define ATTOIO_VARIANT_VH

`ifdef ATTOIO_CFSRAM
    `define DUT_MOD         attoio_macro_cfsram
    `define AW              13
    `define REG(off)        (13'h1700 + (off))
    `define MBX(off)        (13'h1400 + (off))
    `define SRA(off)        (13'h0000 + (off))
`else
    `define DUT_MOD         attoio_macro
    `define AW              11
    `define REG(off)        (11'h700 + (off))
    `define MBX(off)        (11'h600 + (off))
    `define SRA(off)        (11'h000 + (off))
`endif

`endif
