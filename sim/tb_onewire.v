/******************************************************************************/
// tb_onewire — E25.  Runs the 1-Wire master FW against a DS18B20
// behavioural slave and verifies the scratchpad bytes read match
// what the slave transmitted.
//
// Open-drain bus:
//   - Firmware toggles pad[3] OE to drive LOW / release.
//   - Slave drives LOW via its own open-drain pin on dq_wire.
//   - External pullup on dq_wire brings the line HIGH when nobody
//     drives.
//   - pad_in[3] is synthesised from dq_wire so the FW's GPIO_IN
//     sees the true bus state.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/onewire/onewire.hex"
`endif

module tb_onewire;

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

    /* Open-drain bus modelling — same pattern as tm1637 / i2c */
    wire dut_drive_low = pad_oe[3] & ~pad_out[3];

    wire dq_wire;
    pullup dq_pup (dq_wire);
    assign (strong0, highz1) dq_wire = dut_drive_low ? 1'b0 : 1'bz;

    /* Build pad_in from the bus */
    reg  [15:0] pad_in_base = 16'hFFFF;
    wire [15:0] pad_in = (pad_in_base & ~(16'h1 << 3)) |
                         ((dq_wire ? 16'h1 : 16'h0) << 3);

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

    ds18b20_slave_model u_slave (.dq(dq_wire));

`include "apb_host.vh"

    task wait_for_mailbox(input [10:0] addr, input [31:0] expected,
                          input integer max_tries);
        integer tries;
        reg [31:0] val;
        begin
            tries = 0;
            while (tries < max_tries) begin
                apb_read(addr, val);
                if (val === expected) disable wait_for_mailbox;
                tries = tries + 1;
            end
            $display("FAIL: mailbox @0x%03h never reached %08h (last=%08h)",
                     addr, expected, val);
            $fatal;
        end
    endtask

    reg [31:0] fw_image [0:127];
    integer i;
    reg [31:0] rd;
    reg [7:0]  expect_scratch [0:8];

    initial begin
        expect_scratch[0] = 8'h91;
        expect_scratch[1] = 8'h01;
        expect_scratch[2] = 8'h55;
        expect_scratch[3] = 8'h00;
        expect_scratch[4] = 8'h7F;
        expect_scratch[5] = 8'hFF;
        expect_scratch[6] = 8'h0C;
        expect_scratch[7] = 8'h10;
        expect_scratch[8] = 8'hA5;
    end

    initial begin
        $dumpfile("tb_onewire.vcd");
        $dumpvars(0, tb_onewire);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_onewire: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);
        apb_write(11'h708, 32'h0, 4'hF);

        /* FW writes the arm sentinel AFTER the whole 1-Wire sequence
         * completes, so waiting on it is a straightforward handshake. */
        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 2000000);
        $display("  firmware finished 1-Wire sequence");

        apb_read(11'h604, rd);
        $display("  presence = %0d  (expect 1)", rd);
        if (rd !== 32'h1) begin
            $display("FAIL: no presence pulse detected");
            $fatal;
        end

        /* Audit scratchpad bytes in mailbox[5..13]. */
        begin : check
            integer bad;
            bad = 0;
            for (i = 0; i < 9; i = i + 1) begin
                apb_read(11'h614 + (i * 4), rd);
                $display("  scratch[%0d] = %02h  (expect %02h)",
                         i, rd[7:0], expect_scratch[i]);
                if (rd[7:0] !== expect_scratch[i]) bad = bad + 1;
            end
            if (bad != 0) begin
                $display("FAIL: %0d byte(s) wrong", bad);
                $fatal;
            end
        end

        /* Temperature = little-endian byte[1]:byte[0] at mailbox[4]. */
        apb_read(11'h610, rd);
        $display("  temperature word = %04h  (expect 0x0191 = 25.0625 °C)", rd[15:0]);
        if (rd[15:0] !== 16'h0191) begin
            $display("FAIL: temperature mismatch");
            $fatal;
        end

        $display("PASS: 1-Wire reset + scratchpad read matched expected 9 bytes");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
