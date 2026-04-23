/******************************************************************************/
// tb_pinmux — exercise the Phase H13 PINMUX + hp bundle mux.
//
// Tests, for each pad p in 0..15:
//   1. pinmux[p] = 00 (attoio-owned): confirm pad_out follows the IOP's
//      GPIO_OUT register.
//   2. pinmux[p] = 01/10/11: confirm pad_out follows hp{0,1,2}_out[p] and
//      pad_oe follows hp{0,1,2}_oe[p]; ignores the attoio drive.
//   3. hp*_in mirrors pad_in regardless of pinmux selection.
//   4. PINMUX register writes via APB to 0x710/0x714 take effect and
//      readback at the same offsets returns the committed value.
//
// Firmware: uses the stock `gpio_blink`/`empty` image if present, but
// the test only needs the IOP to set GPIO_OE=0xFFFF and a known value
// on GPIO_OUT.  We drive everything from the TB via the host APB
// instead — the IOP stays in reset the whole time, so pad_out with
// pinmux=0 tracks hp*_out = 0 (through attoio_pad_out's reset value of
// 0).  The test therefore only verifies the MUX selection, independent
// of the IOP state machine.
/******************************************************************************/

`timescale 1ns/1ps

module tb_pinmux;

    reg         sysclk = 0;
    reg         clk_iop = 0;
    reg         rst_n = 0;

    reg  [10:0] PADDR = 0;
    reg         PSEL = 0, PENABLE = 0, PWRITE = 0;
    reg  [31:0] PWDATA = 0;
    reg  [3:0]  PSTRB = 0;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERR;

    wire [15:0] pad_out, pad_oe;
    wire [127:0] pad_ctl;
    reg  [15:0] pad_in = 16'h0;

    reg  [15:0] hp0_out = 16'h0, hp0_oe = 16'h0;
    reg  [15:0] hp1_out = 16'h0, hp1_oe = 16'h0;
    reg  [15:0] hp2_out = 16'h0, hp2_oe = 16'h0;
    wire [15:0] hp0_in, hp1_in, hp2_in;

    wire irq_to_host;

    always #5 sysclk = ~sysclk;   // 100 MHz sysclk for the test

    // clk_iop = sysclk/2
    localparam CLK_DIV = 2;
    reg [2:0] div_cnt = 0;
    always @(posedge sysclk) begin
        if (div_cnt == CLK_DIV/2 - 1 || div_cnt == CLK_DIV - 1)
            clk_iop <= ~clk_iop;
        div_cnt <= (div_cnt == CLK_DIV - 1) ? 0 : div_cnt + 1;
    end

    attoio_macro u_dut (
        .sysclk(sysclk), .clk_iop(clk_iop), .rst_n(rst_n),
        .PADDR(PADDR), .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PWDATA(PWDATA), .PSTRB(PSTRB),
        .PRDATA(PRDATA), .PREADY(PREADY), .PSLVERR(PSLVERR),
        .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe), .pad_ctl(pad_ctl),
        .irq_to_host(irq_to_host),
        .hp0_out(hp0_out), .hp0_oe(hp0_oe), .hp0_in(hp0_in),
        .hp1_out(hp1_out), .hp1_oe(hp1_oe), .hp1_in(hp1_in),
        .hp2_out(hp2_out), .hp2_oe(hp2_oe), .hp2_in(hp2_in)
    );

    task apb_write(input [10:0] a, input [31:0] d, input [3:0] s);
        begin
            @(posedge sysclk); #1;
            PADDR = a; PWDATA = d; PSTRB = s; PWRITE = 1; PSEL = 1;
            @(posedge sysclk); #1; PENABLE = 1;
            @(posedge sysclk); #1;
            while (!PREADY) @(posedge sysclk);
            @(posedge sysclk); #1;
            PSEL = 0; PENABLE = 0; PWRITE = 0; PSTRB = 0;
        end
    endtask

    task apb_read(input [10:0] a, output [31:0] d);
        begin
            @(posedge sysclk); #1;
            PADDR = a; PWRITE = 0; PSEL = 1;
            @(posedge sysclk); #1; PENABLE = 1;
            @(posedge sysclk); #1;
            while (!PREADY) @(posedge sysclk);
            d = PRDATA;
            @(posedge sysclk); #1;
            PSEL = 0; PENABLE = 0;
        end
    endtask

    task expect_eq32(input [255:0] label, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s  got=%08h  exp=%08h", label, got, exp);
                $fatal;
            end
        end
    endtask

    integer p;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_pinmux.vcd");
        $dumpvars(0, tb_pinmux);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        /* IOP stays in reset — we only care about PINMUX + pad mux. */
        $display("--- tb_pinmux: PINMUX register readback ---");

        /* Default after reset = 0. */
        apb_read(11'h710, rd); expect_eq32("PINMUX_LO reset", rd, 32'h0);
        apb_read(11'h714, rd); expect_eq32("PINMUX_HI reset", rd, 32'h0);

        /* Write pattern — all pads routed to hp0 (01 repeated). */
        apb_write(11'h710, 32'h5555, 4'hF);
        apb_write(11'h714, 32'h5555, 4'hF);
        apb_read(11'h710, rd); expect_eq32("PINMUX_LO=5555", rd, 32'h5555);
        apb_read(11'h714, rd); expect_eq32("PINMUX_HI=5555", rd, 32'h5555);

        /* --- PHASE 1: all pads point at hp0 --- */
        hp0_out = 16'hA5A5;
        hp0_oe  = 16'hFFFF;
        hp1_out = 16'h5A5A; hp1_oe = 16'hFFFF;
        hp2_out = 16'hFFFF; hp2_oe = 16'hFFFF;
        repeat (3) @(posedge sysclk); #1;
        expect_eq32("pad_out for all-hp0 = A5A5", {16'h0, pad_out}, 32'hA5A5);
        expect_eq32("pad_oe  for all-hp0 = FFFF", {16'h0, pad_oe},  32'hFFFF);

        /* --- PHASE 2: all pads point at hp1 (10 repeated) --- */
        apb_write(11'h710, 32'hAAAA, 4'hF);
        apb_write(11'h714, 32'hAAAA, 4'hF);
        repeat (3) @(posedge sysclk); #1;
        expect_eq32("pad_out for all-hp1 = 5A5A", {16'h0, pad_out}, 32'h5A5A);

        /* --- PHASE 3: all pads point at hp2 (11 repeated) --- */
        apb_write(11'h710, 32'hFFFF, 4'hF);
        apb_write(11'h714, 32'hFFFF, 4'hF);
        repeat (3) @(posedge sysclk); #1;
        expect_eq32("pad_out for all-hp2 = FFFF", {16'h0, pad_out}, 32'hFFFF);

        /* --- PHASE 4: mix — pads [0..3]=hp0, [4..7]=hp1, [8..11]=hp2,
                                [12..15]=attoio (=0 in reset) --- */
        apb_write(11'h710, 32'hAA55, 4'hF);        // pads 0-3 = 01, 4-7 = 10
        apb_write(11'h714, 32'h00FF, 4'hF);        // pads 8-11 = 11, 12-15 = 00
        hp0_out = 16'h000F;  hp0_oe = 16'h000F;
        hp1_out = 16'h00F0;  hp1_oe = 16'h00F0;
        hp2_out = 16'h0F00;  hp2_oe = 16'h0F00;
        repeat (3) @(posedge sysclk); #1;
        /* Expected pad_out = hp0[3:0] | hp1[7:4] | hp2[11:8] | 0[15:12] */
        expect_eq32("pad_out mixed", {16'h0, pad_out}, 32'h0FFF);
        expect_eq32("pad_oe  mixed", {16'h0, pad_oe},  32'h0FFF);

        /* --- PHASE 5: hp*_in mirrors pad_in regardless of sel --- */
        pad_in = 16'hA5A5;
        repeat (2) @(posedge sysclk); #1;
        expect_eq32("hp0_in mirrors pad_in", {16'h0, hp0_in}, 32'hA5A5);
        expect_eq32("hp1_in mirrors pad_in", {16'h0, hp1_in}, 32'hA5A5);
        expect_eq32("hp2_in mirrors pad_in", {16'h0, hp2_in}, 32'hA5A5);

        /* --- PHASE 6: VERSION register --- */
        apb_read(11'h70C, rd);
        expect_eq32("VERSION = 01_00_00_00", rd, 32'h01000000);

        $display("ALL PINMUX TESTS PASSED");
        $finish;
    end

    initial begin
        #50_000_000 $display("TIMEOUT"); $fatal;
    end

endmodule
