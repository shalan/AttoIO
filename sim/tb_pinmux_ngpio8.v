/******************************************************************************/
// tb_pinmux_ngpio8 — sanity test at NGPIO=8.
//
// Instantiates attoio_macro #(.NGPIO(8)) and verifies:
//   1. Module elaborates and boots cleanly.
//   2. PINMUX_LO register readback works; PINMUX_HI is ignored at NGPIO=8.
//   3. Per-pad 4:1 mux routes between attoio and hp0/hp1/hp2 on all 8 pads.
//   4. VERSION register returns 0x01000000.
/******************************************************************************/

`timescale 1ns/1ps

module tb_pinmux_ngpio8;

    reg         sysclk = 0;
    reg         clk_iop = 0;
    reg         rst_n = 0;

    reg  [10:0] PADDR = 0;
    reg         PSEL = 0, PENABLE = 0, PWRITE = 0;
    reg  [31:0] PWDATA = 0;
    reg  [3:0]  PSTRB = 0;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERR;

    wire [7:0]  pad_out, pad_oe;
    wire [63:0] pad_ctl;       // 8 pads × 8 bits
    reg  [7:0]  pad_in = 8'h0;

    reg  [7:0]  hp0_out = 8'h0, hp0_oe = 8'h0;
    reg  [7:0]  hp1_out = 8'h0, hp1_oe = 8'h0;
    reg  [7:0]  hp2_out = 8'h0, hp2_oe = 8'h0;
    wire [7:0]  hp0_in, hp1_in, hp2_in;

    wire irq_to_host;

    always #5 sysclk = ~sysclk;
    localparam CLK_DIV = 2;
    reg [2:0] div_cnt = 0;
    always @(posedge sysclk) begin
        if (div_cnt == CLK_DIV/2 - 1 || div_cnt == CLK_DIV - 1)
            clk_iop <= ~clk_iop;
        div_cnt <= (div_cnt == CLK_DIV - 1) ? 0 : div_cnt + 1;
    end

    attoio_macro #(.NGPIO(8)) u_dut (
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

    task expect_eq(input [127:0] label, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s  got=%08h  exp=%08h", label, got, exp);
                $fatal;
            end
        end
    endtask

    reg [31:0] rd;

    initial begin
        $dumpfile("tb_pinmux_ngpio8.vcd");
        $dumpvars(0, tb_pinmux_ngpio8);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_pinmux_ngpio8: NGPIO=8 smoke test ---");

        /* VERSION readback */
        apb_read(11'h70C, rd);
        expect_eq("VERSION", rd, 32'h01000000);

        /* PINMUX_LO reset default = 0 */
        apb_read(11'h710, rd);
        expect_eq("PINMUX_LO reset", rd, 32'h0);

        /* Route all 8 pads to hp0 (01 repeated in low 16 bits) */
        apb_write(11'h710, 32'h5555, 4'hF);
        apb_read(11'h710, rd);
        expect_eq("PINMUX_LO=5555 readback", rd, 32'h5555);

        hp0_out = 8'hA5; hp0_oe = 8'hFF;
        hp1_out = 8'h5A; hp1_oe = 8'hFF;
        hp2_out = 8'hC3; hp2_oe = 8'hFF;
        repeat (3) @(posedge sysclk); #1;
        expect_eq("pad_out all-hp0", {24'h0, pad_out}, 32'hA5);
        expect_eq("pad_oe  all-hp0", {24'h0, pad_oe},  32'hFF);

        /* Route to hp1 */
        apb_write(11'h710, 32'hAAAA, 4'hF);
        repeat (3) @(posedge sysclk); #1;
        expect_eq("pad_out all-hp1", {24'h0, pad_out}, 32'h5A);

        /* Route to hp2 */
        apb_write(11'h710, 32'hFFFF, 4'hF);
        repeat (3) @(posedge sysclk); #1;
        expect_eq("pad_out all-hp2", {24'h0, pad_out}, 32'hC3);

        /* PINMUX_HI is writable but inert at NGPIO=8 */
        apb_write(11'h714, 32'hFFFF, 4'hF);
        repeat (3) @(posedge sysclk); #1;
        expect_eq("pad_out unaffected by HI", {24'h0, pad_out}, 32'hC3);

        /* hp*_in mirrors pad_in */
        pad_in = 8'h93;
        repeat (2) @(posedge sysclk); #1;
        expect_eq("hp0_in mirrors pad_in", {24'h0, hp0_in}, 32'h93);
        expect_eq("hp1_in mirrors pad_in", {24'h0, hp1_in}, 32'h93);
        expect_eq("hp2_in mirrors pad_in", {24'h0, hp2_in}, 32'h93);

        $display("ALL NGPIO=8 TESTS PASSED");
        $finish;
    end

    initial begin
        #50_000_000 $display("TIMEOUT"); $fatal;
    end

endmodule
