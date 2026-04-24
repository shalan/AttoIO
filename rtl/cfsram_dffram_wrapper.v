/******************************************************************************/
// cfsram_dffram_wrapper — adapts CF_SRAM_1024x32's port shape to the
// DFFRAM-style interface the rest of AttoIO expects.  Keeps memmux and
// surrounding logic unchanged across variants.
//
// DFFRAM interface (how the rest of AttoIO thinks about the SRAM):
//     CLK, EN0, WE0[3:0], A0[A-1:0], Di0[31:0], Do0[31:0]
//       - EN0          1 = this cycle's access valid (read or write)
//       - WE0[i]       1 = write byte i (byte-granularity)
//       - implicit read when EN0 && !(|WE0)
//
// CF_SRAM_1024x32 interface:
//     CLKin, EN, R_WB, AD[9:0], BEN[31:0], DI[31:0], DO[31:0]
//       - EN           1 = access valid
//       - R_WB         1 = read, 0 = write
//       - BEN[i]       1 = write bit i (bit-granularity)
//
// Mapping:
//     R_WB       = ~(|WE0)            // any write-enable bit → write
//     BEN[7:0]   = {8{WE0[0]}}        // byte 0
//     BEN[15:8]  = {8{WE0[1]}}        // byte 1
//     BEN[23:16] = {8{WE0[2]}}        // byte 2
//     BEN[31:24] = {8{WE0[3]}}        // byte 3
//
// Simulation-vs-PnR selection:
//
//   `define CFSRAM_BEHAVIORAL_SRAM  -> uses the RTL DFFRAM (1024x32) as
//        a simple behavioral model.  Clean 1-cycle semantics, no timing
//        checks, no power-domain logic.  Tests pass trivially; Icarus
//        needs this.
//
//   Otherwise -> instantiates the real CF_SRAM_1024x32 hard macro for
//        synthesis + LibreLane flow (the vendor model is timing-checked
//        and carries all the PDN pins).
//
// Both paths see the same outward-facing DFFRAM interface; the rest of
// AttoIO is unchanged.
/******************************************************************************/

module cfsram_dffram_wrapper (
    input  wire        CLK,
    input  wire        EN0,
    input  wire [3:0]  WE0,
    input  wire [9:0]  A0,
    input  wire [31:0] Di0,
    output wire [31:0] Do0
);

`ifdef CFSRAM_BEHAVIORAL_SRAM

    // ----------------------------------------------------------------
    // Simulation path: reuse the parameterized behavioral DFFRAM RTL.
    // 1024 words of 32 bits, same byte-write-enable shape.
    // ----------------------------------------------------------------
    DFFRAM #(.WORDS(1024), .WSIZE(4)) u_sram (
        .CLK (CLK),
        .WE0 (WE0),
        .EN0 (EN0),
        .A0  (A0),
        .Di0 (Di0),
        .Do0 (Do0)
    );

`else

    // ----------------------------------------------------------------
    // Synthesis / PnR path: the real CF_SRAM_1024x32 hard macro.
    // ----------------------------------------------------------------
    wire        r_wb = ~(|WE0);
    wire [31:0] ben  = { {8{WE0[3]}}, {8{WE0[2]}}, {8{WE0[1]}}, {8{WE0[0]}} };

    CF_SRAM_1024x32 u_sram (
        .CLKin     (CLK),
        .EN        (EN0),
        .R_WB      (r_wb),
        .AD        (A0),
        .BEN       (ben),
        .DI        (Di0),
        .DO        (Do0),

        // Tie-offs for scan, test, wordline-bias, and the scan chain.
        .SM        (1'b0),
        .TM        (1'b0),
        .WLBI      (1'b0),
        .WLOFF     (1'b0),
        .ScanInCC  (1'b0),
        .ScanInDL  (1'b0),
        .ScanInDR  (1'b0),
        .ScanOutCC (),

        // PDN pins routed by LibreLane at the macro level.
        .vpwrac    (1'b1),
        .vpwrpc    (1'b1)
    );

`endif

endmodule
