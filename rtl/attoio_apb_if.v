/******************************************************************************/
// attoio_apb_if — APB4 slave wrapper around the internal host bus.
//
// Translates a standard AMBA APB4 transaction into the single-cycle
// `host_wen`/`host_ren` + `host_ready` protocol the memmux expects.
// Thin combinational glue; timing is governed by the internal ready
// line, which is zero-wait for register accesses and one-wait for
// SRAM accesses.
//
// Parameter widths:
//   PADDR = ADDR_WIDTH bits  (11 for DFFRAM variant, 13 for CFSRAM)
//   PWDATA/PRDATA = 32 bits
//   PSTRB = 4 bits (byte-enable; routed 1:1 to host_wmask)
//
// PSLVERR is tied low — no out-of-range detection needed; memmux
// simply returns 0 for unmapped reads.
/******************************************************************************/

`default_nettype none

module attoio_apb_if #(
    parameter ADDR_WIDTH = 11
) (
    input  wire                   PCLK,
    input  wire                   PRESETn,

    // ---- APB4 slave ----
    input  wire [ADDR_WIDTH-1:0]  PADDR,
    input  wire                   PSEL,
    input  wire                   PENABLE,
    input  wire                   PWRITE,
    input  wire [31:0]            PWDATA,
    input  wire [3:0]             PSTRB,
    output wire [31:0]            PRDATA,
    output wire                   PREADY,
    output wire                   PSLVERR,

    // ---- Internal "host bus" to memmux ----
    output wire [ADDR_WIDTH-1:0]  host_addr,
    output wire [31:0]            host_wdata,
    output wire [3:0]             host_wmask,
    output wire                   host_wen,
    output wire                   host_ren,
    input  wire [31:0]            host_rdata,
    input  wire                   host_ready
);

    wire access = PSEL & PENABLE;

    /* Unused for now — keep the port so the signal is available if
     * future SoC integration ever drives APB from a different clock. */
    wire _pclk_unused = PCLK;
    wire _prst_unused = PRESETn;

    assign host_addr  = PADDR;
    assign host_wdata = PWDATA;
    assign host_wmask = PSTRB;
    assign host_wen   = access &  PWRITE;
    assign host_ren   = access & ~PWRITE;

    assign PRDATA  = host_rdata;
    /* Outside of an ACCESS phase PREADY is don't-care; drive it high
     * so idle masters never see a stall. During ACCESS, mirror the
     * memmux ready. */
    assign PREADY  = access ? host_ready : 1'b1;
    assign PSLVERR = 1'b0;

endmodule

`default_nettype wire
