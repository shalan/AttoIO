/******************************************************************************/
// tb_ht1621 — E7.  Runs the ht1621 firmware against a behavioural HT1621
// slave model and verifies three transactions worth of wire traffic
// (bits accumulated MSB-first into the low end of cur_bits):
//
//   1) COMMAND  type=111  cmd=0x03 (SYS EN) + 1 don't-care = 12 bits
//      → 1110 0000 0110  =  0x000_E06
//   2) COMMAND  type=111  cmd=0x07 (LCD ON)                  12 bits
//      → 1110 0000 1110  =  0x000_E0E
//   3) WRITE    type=100  addr6=0x00  data=0x1234           9 + 16 = 25 bits
//      → 1_0000_0000_0001_0010_0011_0100  = 0x100_1234
/******************************************************************************/

`timescale 1ns/1ps
`include "attoio_variant.vh"

`ifndef FW_HEX
 `define FW_HEX "build/sw/ht1621/ht1621.hex"
`endif

module tb_ht1621;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    reg         sysclk  = 0;
    reg         clk_iop = 0;
    reg         rst_n   = 0;

    reg  [`AW-1:0] PADDR;
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

    `DUT_MOD u_dut (
        .sysclk(sysclk), .clk_iop(clk_iop), .rst_n(rst_n),
        .PADDR(PADDR), .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PWDATA(PWDATA), .PSTRB(PSTRB),
        .PRDATA(PRDATA), .PREADY(PREADY), .PSLVERR(PSLVERR),
        .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe), .pad_ctl(pad_ctl),
        .irq_to_host(irq_to_host),

        .hp0_out(16'h0), .hp0_oe(16'h0), .hp0_in(),

        .hp1_out(16'h0), .hp1_oe(16'h0), .hp1_in(),

        .hp2_out(16'h0), .hp2_oe(16'h0), .hp2_in()
    );

    /* Push-pull observation. The model only acts while CS is low, which
     * the firmware never asserts before driving idle values, so we
     * don't need any X→0 reset filtering. */
    wire cs_w   = pad_out[9];
    wire wr_w   = pad_out[10];
    wire data_w = pad_out[11];

    ht1621_model u_lcd (.cs(cs_w), .wr(wr_w), .data(data_w));

`include "apb_host.vh"

    task wait_for_mailbox(input [`AW-1:0] addr, input [31:0] expected, input integer max_tries);
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

    reg [31:0] fw_image [0:255];
    integer i;

    reg [63:0] exp_bits [0:2];
    integer    exp_len  [0:2];

    initial begin
        $dumpfile("tb_ht1621.vcd");
        $dumpvars(0, tb_ht1621);

        /* Frame 1: 111 + 0000_0011 + 0  = 12 bits, MSB-first */
        exp_bits[0] = 64'hE06;  exp_len[0] = 12;
        /* Frame 2: 111 + 0000_0111 + 0  = 12 bits */
        exp_bits[1] = 64'hE0E;  exp_len[1] = 12;
        /* Frame 3: 100 + 000000 + 0001_0010_0011_0100 = 25 bits */
        exp_bits[2] = 64'h1001234; exp_len[2] = 25;

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_ht1621: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(`REG(11'h008), 32'h0, 4'hF);

        wait_for_mailbox(`MBX(11'h000), 32'h16216216, 500000);
        $display("  firmware signalled 'HT1621 done'");

        if (u_lcd.frame_cnt !== 3) begin
            $display("FAIL: expected 3 transactions, got %0d", u_lcd.frame_cnt);
            $fatal;
        end
        for (i = 0; i < 3; i = i + 1) begin
            if (u_lcd.frame_len[i] !== exp_len[i] ||
                u_lcd.frames[i]    !== exp_bits[i]) begin
                $display("FAIL: frame %0d = %0d bits 0x%h, expected %0d bits 0x%h",
                         i, u_lcd.frame_len[i], u_lcd.frames[i],
                            exp_len[i],         exp_bits[i]);
                $fatal;
            end
        end
        $display("PASS: HT1621 sent 3 frames: SYS_EN, LCD_ON, WRITE@0=0x1234");
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
