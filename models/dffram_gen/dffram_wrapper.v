// Parameterized DFFRAM wrapper that dispatches to the real
// sky130_gen_dffram generated netlist for the two geometries used
// by AttoIO: 128x32 and 32x32.
//
// (* keep *) prevents Yosys / ABC from optimizing away the SRAM
// instance even if some outputs look dead from the caller's side.
//
// The `RAM128` and `RAM32` modules are defined in dffram_combined.nl.v.

module DFFRAM #(
    parameter WORDS = 128,
    parameter WSIZE = 4
) (
    input  wire                      CLK,
    input  wire [WSIZE-1:0]          WE0,
    input  wire                      EN0,
    input  wire [$clog2(WORDS)-1:0]  A0,
    input  wire [(WSIZE*8-1):0]      Di0,
    output wire [(WSIZE*8-1):0]      Do0
);

    generate
        if (WORDS == 128 && WSIZE == 4) begin : gen_128x32
            (* keep = "true" *)
            RAM128 u_ram (
                .CLK (CLK),
                .WE0 (WE0),
                .EN0 (EN0),
                .A0  (A0),
                .Di0 (Di0),
                .Do0 (Do0)
            );
        end
        else if (WORDS == 32 && WSIZE == 4) begin : gen_32x32
            (* keep = "true" *)
            RAM32 u_ram (
                .CLK (CLK),
                .WE0 (WE0),
                .EN0 (EN0),
                .A0  (A0),
                .Di0 (Di0),
                .Do0 (Do0)
            );
        end
        else begin : gen_unsupported
            initial begin
                $display("ERROR: DFFRAM wrapper only supports WORDS=128 or 32 with WSIZE=4; got WORDS=%0d, WSIZE=%0d", WORDS, WSIZE);
                $finish;
            end
        end
    endgenerate

endmodule
