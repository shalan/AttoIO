/******************************************************************************/
// tb_core_hazard — BUG-002 reproducer.
//
// Instantiates the AttoRV32 core directly (no memmux, no macro) with a
// flat 2 KB RAM that behaves exactly like the DFFRAM interface (1-cycle
// synchronous read, byte-maskable write, EN0-gated output register).
// A bus snooper logs every store transaction that reaches the memory
// interface.
//
// The firmware (sw/core_hazard/main.c) is a linear replay of the E10
// BLDC ISR body.  If all five mailbox stores land, the core is
// innocent and the bug is downstream (memmux).  If a subset drops,
// the bug is in the core.
//
// Expected writes (target byte addresses):
//   0x704 -- GPIO_OUT_SET
//   0x710 -- GPIO_OUT_CLR
//   <counter++ BSS address>
//   0x600 -- mailbox[0]   = 0xAA01BEEF
//   0x604 -- mailbox[1]   = 0xAA02BEEF
//   0x60C -- mailbox[3]   = 0xAA03BEEF   <-- BUG-002 boundary
//   0x614 -- mailbox[5]   = 0xAA05BEEF
//   0x61C -- mailbox[7]   = 0xAA07BEEF
//   0x764 -- WAKE_FLAGS
//   0x608 -- mailbox[2]   = 0xC0DEC0DE  (sentinel, published last)
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/core_hazard/core_hazard.hex"
`endif

module tb_core_hazard;

    parameter SYSCLK_PERIOD = 10;    /* 100 MHz host sysclk */
    parameter CLK_DIV       = 4;     /* core clk_iop = 25 MHz */

    reg clk_iop = 0;
    reg rst_n   = 0;   /* core expects active-LOW */

    /* ---- AttoRV32 mem bus ---- */
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wmask;
    wire [31:0] mem_rdata;
    wire        mem_rstrb;
    wire        mem_rbusy = 1'b0;
    wire        mem_wbusy = 1'b0;

    /* clk_iop directly — no sysclk division needed for this isolation run */
    always #(SYSCLK_PERIOD * CLK_DIV / 2) clk_iop = ~clk_iop;

    AttoRV32 #(
        .ADDR_WIDTH (11),
        .RV32E      (1),
        .MTVEC_ADDR (11'h010)
    ) u_core (
        .clk               (clk_iop),
        .reset             (rst_n),
        .mem_addr          (mem_addr),
        .mem_wdata         (mem_wdata),
        .mem_wmask         (mem_wmask),
        .mem_rdata         (mem_rdata),
        .mem_rstrb         (mem_rstrb),
        .mem_rbusy         (mem_rbusy),
        .mem_wbusy         (mem_wbusy),
        .interrupt_request (1'b0),
        .nmi               (1'b0),
        .dbg_halt_req      (1'b0)
    );

    /* Flat 2 KB RAM, DFFRAM-style interface (sync read with output hold). */
    reg [31:0] mem [0:511];
    reg [31:0] mem_rdata_r;
    wire [8:0] word_addr = mem_addr[10:2];

    assign mem_rdata = mem_rdata_r;

    always @(posedge clk_iop) begin
        if (mem_rstrb | (|mem_wmask)) begin
            if (mem_wmask[0]) mem[word_addr][ 7: 0] <= mem_wdata[ 7: 0];
            if (mem_wmask[1]) mem[word_addr][15: 8] <= mem_wdata[15: 8];
            if (mem_wmask[2]) mem[word_addr][23:16] <= mem_wdata[23:16];
            if (mem_wmask[3]) mem[word_addr][31:24] <= mem_wdata[31:24];
            mem_rdata_r <= mem[word_addr];
        end
    end

    /* ----------------------------------------------------------- */
    /* Bus snooper — every store that appears on the bus.          */
    /* ----------------------------------------------------------- */
    integer store_count = 0;
    integer seen_mb0 = 0, seen_mb1 = 0, seen_mb2 = 0;
    integer seen_mb3 = 0, seen_mb5 = 0, seen_mb7 = 0;
    reg [31:0] d_mb0, d_mb1, d_mb2, d_mb3, d_mb5, d_mb7;

    always @(posedge clk_iop) begin
        if (|mem_wmask) begin
            store_count = store_count + 1;
            $display("[%8t] STORE #%0d  addr=%08h  wmask=%b  data=%08h",
                     $time, store_count, mem_addr, mem_wmask, mem_wdata);
            case (mem_addr[10:0])
                11'h600: begin seen_mb0 = 1; d_mb0 = mem_wdata; end
                11'h604: begin seen_mb1 = 1; d_mb1 = mem_wdata; end
                11'h608: begin seen_mb2 = 1; d_mb2 = mem_wdata; end
                11'h60C: begin seen_mb3 = 1; d_mb3 = mem_wdata; end
                11'h614: begin seen_mb5 = 1; d_mb5 = mem_wdata; end
                11'h61C: begin seen_mb7 = 1; d_mb7 = mem_wdata; end
                default: ;
            endcase
        end
    end

    /* Firmware load + run. */
    reg [31:0] fw_image [0:127];
    integer i;

    initial begin
        $dumpfile("tb_core_hazard.vcd");
        $dumpvars(0, tb_core_hazard);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);
        for (i = 0; i < 128; i = i + 1) mem[i] = fw_image[i];

        rst_n = 0;
        repeat (5) @(posedge clk_iop);
        rst_n = 1;
        repeat (2) @(posedge clk_iop);

        $display("--- tb_core_hazard: reset released, core starts ---");

        /* Give the core plenty of cycles to execute main() and reach
         * wfi.  10000 clk_iop is ~400 µs — vastly more than needed. */
        repeat (10000) @(posedge clk_iop);

        $display("");
        $display("================= Store audit =================");
        $display("  total stores observed: %0d", store_count);
        $display("  mailbox[0] (0x600) %s data=%08h",
                 seen_mb0 ? "SEEN " : "MISS ", d_mb0);
        $display("  mailbox[1] (0x604) %s data=%08h",
                 seen_mb1 ? "SEEN " : "MISS ", d_mb1);
        $display("  mailbox[2] (0x608) %s data=%08h  (sentinel)",
                 seen_mb2 ? "SEEN " : "MISS ", d_mb2);
        $display("  mailbox[3] (0x60C) %s data=%08h  <- BUG-002 edge",
                 seen_mb3 ? "SEEN " : "MISS ", d_mb3);
        $display("  mailbox[5] (0x614) %s data=%08h",
                 seen_mb5 ? "SEEN " : "MISS ", d_mb5);
        $display("  mailbox[7] (0x61C) %s data=%08h",
                 seen_mb7 ? "SEEN " : "MISS ", d_mb7);
        $display("-----------------------------------------------");

        if (seen_mb0 && seen_mb1 && seen_mb3 && seen_mb5 && seen_mb7 &&
            d_mb0 === 32'hAA01BEEF && d_mb1 === 32'hAA02BEEF &&
            d_mb3 === 32'hAA03BEEF && d_mb5 === 32'hAA05BEEF &&
            d_mb7 === 32'hAA07BEEF) begin
            $display("RESULT: all 5 SRAM B stores fired with correct data.");
            $display("        → BUG-002 is downstream of the core (memmux or");
            $display("          SRAM arbiter).");
        end else begin
            $display("RESULT: at least one SRAM B store MISSING or CORRUPT.");
            $display("        → BUG-002 is in the AttoRV32 core LSU/FSM.");
        end

        $finish;
    end

endmodule
