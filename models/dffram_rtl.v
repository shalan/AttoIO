// DFFRAM Behavioral RTL Model
// Matches the structural DFFRAM interface and timing behavior:
//   - 1-cycle read latency (EN0=1 + address -> Do0 valid next cycle)
//   - Byte-granularity write enable (WE0)
//   - Output holds when EN0=0 (clock-gated output register)
//
// SPDX-License-Identifier: Apache-2.0

module DFFRAM #(
    parameter WORDS = 256,
    parameter WSIZE = 1
) (
    input  wire                      CLK,
    input  wire [WSIZE-1:0]          WE0,
    input  wire                      EN0,
    input  wire [$clog2(WORDS)-1:0]  A0,
    input  wire [(WSIZE*8-1):0]      Di0,
    output reg  [(WSIZE*8-1):0]      Do0
);

    reg [(WSIZE*8-1):0] mem [0:WORDS-1];

    integer i;

    always @(posedge CLK) begin
        if (EN0) begin
            for (i = 0; i < WSIZE; i = i + 1) begin
                if (WE0[i])
                    mem[A0][i*8 +: 8] <= Di0[i*8 +: 8];
            end
            Do0 <= mem[A0];
        end
    end

endmodule
