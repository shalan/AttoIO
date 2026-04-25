// ------------------------------------------------------------------------
// apb_host.vh — testbench-side APB master helper (include-style).
//
// Drop `include "apb_host.vh"` *inside a module* (not at top level) — it
// declares reg ports + two tasks (apb_write, apb_read) that drive the
// DUT's APB slave through a standard SETUP → ACCESS → wait-for-PREADY
// sequence.
//
// Expected signals in the enclosing module:
//   reg         sysclk;        // PCLK
//   reg         rst_n;         // PRESETn
//   reg  [10:0] PADDR;
//   reg         PSEL, PENABLE, PWRITE;
//   reg  [31:0] PWDATA;
//   reg  [3:0]  PSTRB;
//   wire [31:0] PRDATA;
//   wire        PREADY;
//
// Usage:
//   apb_write(11'h708, 32'h0, 4'hF);     // word write
//   apb_read (11'h600, rd);              // word read; rd becomes a reg
//
// The tasks advance on posedge sysclk and satisfy APB4 timing:
//   cycle 1 (SETUP):  PSEL=1, PENABLE=0, PADDR/PWDATA/PWRITE/PSTRB stable
//   cycle 2 (ACCESS): PENABLE=1, wait while PREADY=0, end on PREADY=1
// ------------------------------------------------------------------------

task apb_write;
    input [`AW-1:0] addr;
    input [31:0] data;
    input [3:0]  strb;
    begin
        @(posedge sysclk); #1;
        PADDR   = addr;
        PWDATA  = data;
        PSTRB   = strb;
        PWRITE  = 1'b1;
        PSEL    = 1'b1;
        PENABLE = 1'b0;          // SETUP
        @(posedge sysclk); #1;
        PENABLE = 1'b1;          // ACCESS begins — must last >=1 cycle
        @(posedge sysclk); #1;   // first ACCESS cycle (PREADY evaluated here on)
        while (PREADY !== 1'b1) begin
            @(posedge sysclk); #1;
        end
        PSEL    = 1'b0;
        PENABLE = 1'b0;
        PWRITE  = 1'b0;
        PSTRB   = 4'h0;
    end
endtask

task apb_read;
    input  [`AW-1:0] addr;
    output [31:0] data;
    begin
        @(posedge sysclk); #1;
        PADDR   = addr;
        PWRITE  = 1'b0;
        PSTRB   = 4'h0;
        PSEL    = 1'b1;
        PENABLE = 1'b0;          // SETUP
        @(posedge sysclk); #1;
        PENABLE = 1'b1;          // ACCESS begins — must last >=1 cycle
        @(posedge sysclk); #1;   // first ACCESS cycle (PREADY evaluated here on)
        while (PREADY !== 1'b1) begin
            @(posedge sysclk); #1;
        end
        data    = PRDATA;
        PSEL    = 1'b0;
        PENABLE = 1'b0;
    end
endtask
