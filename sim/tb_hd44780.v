/******************************************************************************/
// tb_hd44780 — E5.  Runs the hd44780 firmware against a behavioural
// HD44780 4-bit-mode model.  Verifies the byte stream:
//
//   cmd  0x28          Function set (4-bit, 2 lines, 5x8)
//   cmd  0x0C          Display on, cursor off, blink off
//   cmd  0x01          Clear display
//   cmd  0x06          Entry mode: increment, no shift
//   cmd  0x80          DDRAM addr = 0
//   data 'A' 't' 't' 'o' 'I' 'O' '!'
//
// 5 commands + 7 data bytes = 12 captured bytes total.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/hd44780/hd44780.hex"
`endif

module tb_hd44780;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    reg         sysclk  = 0;
    reg         clk_iop = 0;
    reg         rst_n   = 0;

    reg  [10:0] PADDR;
    reg         PSEL, PENABLE, PWRITE;
    reg  [31:0] PWDATA;
    reg  [3:0]  PSTRB;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERR;

    reg  [15:0] pad_in = 16'hFFFF;
    wire [15:0] pad_out;
    wire [15:0] pad_oe;
    wire [127:0] pad_ctl;
    wire        irq_to_host;

    always #(SYSCLK_PERIOD/2) sysclk = ~sysclk;
    reg [$clog2(CLK_DIV)-1:0] div_cnt = 0;
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
        .irq_to_host(irq_to_host)
    );

    /* Push-pull pad observation — value is whatever the DUT drives when
     * OE=1.  When OE=0, the pad floats; for HD44780 we only sample on
     * E falling edge, when OE is unconditionally asserted by the FW. */
    wire rs_w = pad_out[9];
    wire e_w  = pad_out[10];
    wire d4_w = pad_out[11];
    wire d5_w = pad_out[12];
    wire d6_w = pad_out[13];
    wire d7_w = pad_out[14];

    hd44780_model u_lcd (
        .rs(rs_w), .e(e_w),
        .d4(d4_w), .d5(d5_w), .d6(d6_w), .d7(d7_w)
    );

`include "apb_host.vh"

    task wait_for_mailbox(input [10:0] addr, input [31:0] expected, input integer max_tries);
        integer tries;
        reg [31:0] val;
        begin
            tries = 0;
            while (tries < max_tries) begin
                apb_read(addr, val);
                if (val === expected) begin
                    $display("  mailbox @0x%03h = %08h (waited %0d reads)", addr, val, tries);
                    disable wait_for_mailbox;
                end
                tries = tries + 1;
            end
            $display("FAIL: mailbox @0x%03h never reached %08h (last=%08h)", addr, expected, val);
            $fatal;
        end
    endtask

    reg [31:0] fw_image [0:127];
    integer i;
    reg [7:0] expected_b   [0:11];
    reg       expected_rs  [0:11];

    initial begin
        $dumpfile("tb_hd44780.vcd");
        $dumpvars(0, tb_hd44780);

        /* 5 commands then 7 data chars. */
        expected_b[0]  = 8'h28; expected_rs[0]  = 1'b0;
        expected_b[1]  = 8'h0C; expected_rs[1]  = 1'b0;
        expected_b[2]  = 8'h01; expected_rs[2]  = 1'b0;
        expected_b[3]  = 8'h06; expected_rs[3]  = 1'b0;
        expected_b[4]  = 8'h80; expected_rs[4]  = 1'b0;
        expected_b[5]  = "A";   expected_rs[5]  = 1'b1;
        expected_b[6]  = "t";   expected_rs[6]  = 1'b1;
        expected_b[7]  = "t";   expected_rs[7]  = 1'b1;
        expected_b[8]  = "o";   expected_rs[8]  = 1'b1;
        expected_b[9]  = "I";   expected_rs[9]  = 1'b1;
        expected_b[10] = "O";   expected_rs[10] = 1'b1;
        expected_b[11] = "!";   expected_rs[11] = 1'b1;

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_hd44780: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h600, 32'hA110A110, 500000);
        $display("  firmware signalled 'LCD done'");

        if (u_lcd.byte_cnt !== 12) begin
            $display("FAIL: expected 12 captured bytes, got %0d", u_lcd.byte_cnt);
            $fatal;
        end
        for (i = 0; i < 12; i = i + 1) begin
            if (u_lcd.bytes[i] !== expected_b[i] ||
                u_lcd.rs_flags[i] !== expected_rs[i]) begin
                $display("FAIL: byte %0d = (rs=%0d, 0x%02h '%c'), expected (rs=%0d, 0x%02h '%c')",
                         i,
                         u_lcd.rs_flags[i], u_lcd.bytes[i], u_lcd.bytes[i],
                         expected_rs[i],    expected_b[i],  expected_b[i]);
                $fatal;
            end
        end
        $display("PASS: HD44780 wrote 5 commands + 'AttoIO!' (12 bytes verified)");
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
