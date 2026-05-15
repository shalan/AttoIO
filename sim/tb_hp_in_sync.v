/******************************************************************************/
// tb_hp_in_sync — regression for the hp{0,1,2}_in synchronisation fix.
//
// Drives pad_in with a glitchy pattern that toggles between successive
// sysclk edges, then samples hp0_in / hp1_in / hp2_in on the sysclk
// (host bus) domain and asserts:
//
//   1. hp_in is never X — the 2-flop sync chain leaves the bundles
//      fully defined from reset onward.
//   2. hp_in matches a 2-cycle-delayed version of pad_in once a stable
//      value has been held for at least 2 sysclk edges.
//   3. All three bundles hp0_in / hp1_in / hp2_in mirror each other
//      (they tap the same sync chain).
//
// Variant-portable: runs against either attoio_macro or
// attoio_macro_cfsram via VARIANT={dffram,cfsram}.
/******************************************************************************/

`timescale 1ns/1ps
`include "attoio_variant.vh"

module tb_hp_in_sync;

    reg            sysclk  = 0;
    reg            clk_iop = 0;
    reg            rst_n   = 0;

    reg [`AW-1:0]  PADDR   = 0;
    reg            PSEL    = 0, PENABLE = 0, PWRITE = 0;
    reg  [31:0]    PWDATA  = 0;
    reg  [3:0]     PSTRB   = 0;
    wire [31:0]    PRDATA;
    wire           PREADY, PSLVERR;

    wire [15:0]    pad_out, pad_oe;
    wire [127:0]   pad_ctl;
    reg  [15:0]    pad_in_drv = 16'h0000;

    wire [15:0]    hp0_in, hp1_in, hp2_in;
    wire           irq_to_host;

    always #5 sysclk = ~sysclk;
    localparam CLK_DIV = 2;
    reg [2:0] div_cnt = 0;
    always @(posedge sysclk) begin
        if (div_cnt == CLK_DIV/2 - 1 || div_cnt == CLK_DIV - 1)
            clk_iop <= ~clk_iop;
        div_cnt <= (div_cnt == CLK_DIV - 1) ? 0 : div_cnt + 1;
    end

    `DUT_MOD u_dut (
        .sysclk(sysclk), .clk_iop(clk_iop), .rst_n(rst_n),
        .PADDR(PADDR), .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PWDATA(PWDATA), .PSTRB(PSTRB),
        .PRDATA(PRDATA), .PREADY(PREADY), .PSLVERR(PSLVERR),
        .pad_in(pad_in_drv), .pad_out(pad_out), .pad_oe(pad_oe), .pad_ctl(pad_ctl),
        .irq_to_host(irq_to_host),
        .hp0_out(16'h0), .hp0_oe(16'h0), .hp0_in(hp0_in),
        .hp1_out(16'h0), .hp1_oe(16'h0), .hp1_in(hp1_in),
        .hp2_out(16'h0), .hp2_oe(16'h0), .hp2_in(hp2_in)
    );

    /* Continuous "no X" assertion on the sysclk domain. */
    always @(posedge sysclk) begin
        if (rst_n) begin
            if (^hp0_in === 1'bx) begin
                $display("FAIL: hp0_in went X at t=%0t (= %h)", $time, hp0_in);
                $fatal;
            end
            if (^hp1_in === 1'bx) begin
                $display("FAIL: hp1_in went X at t=%0t (= %h)", $time, hp1_in);
                $fatal;
            end
            if (^hp2_in === 1'bx) begin
                $display("FAIL: hp2_in went X at t=%0t (= %h)", $time, hp2_in);
                $fatal;
            end
            if (hp0_in !== hp1_in || hp1_in !== hp2_in) begin
                $display("FAIL: hp_in bundles diverged at t=%0t  hp0=%h hp1=%h hp2=%h",
                         $time, hp0_in, hp1_in, hp2_in);
                $fatal;
            end
        end
    end

    integer i;
    reg [15:0] expected;

    initial begin
        $dumpfile("tb_hp_in_sync.vcd");
        $dumpvars(0, tb_hp_in_sync);

        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_hp_in_sync: pad_in -> hp_in 2-flop sync ---");

        /* Phase 1: glitchy pad — flip pad_in every sysclk edge for 50
         * cycles.  hp_in should remain defined throughout (assertion
         * above) but contents are intentionally undefined; the
         * always-block only enforces no-X and bundle agreement.
         */
        for (i = 0; i < 50; i = i + 1) begin
            pad_in_drv = $random;
            @(posedge sysclk);
        end

        /* Phase 2: hold a known value for 4 sysclk edges, sample hp_in
         * and assert it equals the held value (2-flop delay absorbed).
         */
        pad_in_drv = 16'hA5A5;
        repeat (4) @(posedge sysclk); #1;
        expected = 16'hA5A5;
        if (hp0_in !== expected) begin
            $display("FAIL: hp0_in=%h expected %h after settle", hp0_in, expected);
            $fatal;
        end

        pad_in_drv = 16'h5A5A;
        repeat (4) @(posedge sysclk); #1;
        expected = 16'h5A5A;
        if (hp0_in !== expected) begin
            $display("FAIL: hp0_in=%h expected %h after settle", hp0_in, expected);
            $fatal;
        end

        pad_in_drv = 16'hFFFF;
        repeat (4) @(posedge sysclk); #1;
        if (hp0_in !== 16'hFFFF) begin
            $display("FAIL: hp0_in=%h expected ffff after settle", hp0_in);
            $fatal;
        end

        pad_in_drv = 16'h0000;
        repeat (4) @(posedge sysclk); #1;
        if (hp0_in !== 16'h0000) begin
            $display("FAIL: hp0_in=%h expected 0000 after settle", hp0_in);
            $fatal;
        end

        /* Phase 3: edge-aligned timing — drive new value, sample 1 and
         * 2 sysclk edges later.  After exactly 2 edges the sync chain
         * must have propagated the new value.
         */
        pad_in_drv = 16'hCAFE;
        @(posedge sysclk); #1;
        @(posedge sysclk); #1;   /* 2 sysclk edges later */
        if (hp0_in !== 16'hCAFE) begin
            $display("FAIL: hp0_in=%h expected cafe after 2 sysclk edges", hp0_in);
            $fatal;
        end

        $display("ALL hp_in SYNC TESTS PASSED");
        $finish;
    end

    initial begin
        #50_000_000 $display("TIMEOUT"); $fatal;
    end

endmodule
