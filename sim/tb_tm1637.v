/******************************************************************************/
// tb_tm1637 — E6.  Runs the tm1637 firmware against a behavioral
// TM1637 slave.  Verifies the 7 bytes captured across 3 transactions
// match the expected sequence for "1234" at full brightness:
//   byte 0 : 0x40             (data cmd, auto-increment)
//   byte 1 : 0xC0             (address 0)
//   byte 2..5 : 06 5B 4F 66   (segments for 1,2,3,4)
//   byte 6 : 0x8F             (display on, brightness 7)
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/tm1637/tm1637.hex"
`endif

module tb_tm1637;

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

    wire [15:0] pad_out;
    wire [15:0] pad_oe;
    wire [127:0] pad_ctl;
    wire        irq_to_host;

    /* Open-drain: DUT pulls low via pad_oe; pullups on DIO/CLK. */
    wire dut_drive_dio_low = pad_oe[9]  & ~pad_out[9];
    wire dut_drive_clk_low = pad_oe[10] & ~pad_out[10];

    wire dio_wire;
    wire clk_wire;
    pullup dio_pup (dio_wire);
    pullup clk_pup (clk_wire);
    assign (strong0, highz1) dio_wire = dut_drive_dio_low ? 1'b0 : 1'bz;
    assign (strong0, highz1) clk_wire = dut_drive_clk_low ? 1'b0 : 1'bz;

    reg  [15:0] pad_in_base = 16'hFFFF;
    wire [15:0] pad_in = (pad_in_base
                        & ~(16'h1 << 9) & ~(16'h1 << 10))
                        | ((dio_wire ? 16'h1 : 16'h0) << 9)
                        | ((clk_wire ? 16'h1 : 16'h0) << 10);

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

    tm1637_slave_model u_tm (
        .dio(dio_wire),
        .clk(clk_wire)
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

    reg [31:0] fw_image [0:255];
    integer i;
    reg [7:0]  expected [0:6];

    initial begin
        $dumpfile("tb_tm1637.vcd");
        $dumpvars(0, tb_tm1637);

        expected[0] = 8'h40;
        expected[1] = 8'hC0;
        expected[2] = 8'h06; expected[3] = 8'h5B;
        expected[4] = 8'h4F; expected[5] = 8'h66;
        expected[6] = 8'h8F;

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_tm1637: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h600, 32'h13371337, 500000);
        $display("  firmware signalled 'TM1637 done'");

        if (u_tm.byte_cnt !== 7) begin
            $display("FAIL: expected 7 captured bytes, got %0d", u_tm.byte_cnt);
            $fatal;
        end
        for (i = 0; i < 7; i = i + 1) begin
            if (u_tm.bytes[i] !== expected[i]) begin
                $display("FAIL: byte %0d = 0x%02h, expected 0x%02h",
                         i, u_tm.bytes[i], expected[i]);
                $fatal;
            end
        end
        $display("PASS: TM1637 wrote 7 bytes: 40 C0 06 5B 4F 66 8F (\"1234\", full brightness)");
        $finish;
    end

    initial begin
        #30000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
