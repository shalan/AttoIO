/******************************************************************************/
// tb_ir_rx — E16.  Drives a NEC-style demodulated IR waveform on
// pad[3] carrying a known 32-bit payload, waits for the FW to decode
// and publish it via mailbox[4], and verifies the received value
// matches.
//
// Scaled-down NEC timings (50× faster than the real protocol, so
// this sim finishes in ~2 ms):
//   header mark   180 µs HIGH
//   header space   90 µs LOW
//   bit mark      11.2 µs HIGH   (same for bit 0 and bit 1)
//   bit-0 space   11.2 µs LOW    (total bit period 22.4 µs)
//   bit-1 space   33.8 µs LOW    (total bit period 45 µs)
//   trailer mark  11.2 µs HIGH   (provides closing rising edge)
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/ir_rx/ir_rx.hex"
`endif

module tb_ir_rx;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    parameter integer HEADER_MARK_NS  = 180_000;
    parameter integer HEADER_SPACE_NS = 90_000;
    parameter integer BIT_MARK_NS     = 11_200;
    parameter integer BIT0_SPACE_NS   = 11_200;
    parameter integer BIT1_SPACE_NS   = 33_800;

    parameter [31:0] TEST_FRAME = 32'hABCD1234;

    reg         sysclk  = 0;
    reg         clk_iop = 0;
    reg         rst_n   = 0;

    reg  [10:0] PADDR;
    reg         PSEL, PENABLE, PWRITE;
    reg  [31:0] PWDATA;
    reg  [3:0]  PSTRB;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERR;

    reg  [15:0] pad_in = 16'h0;
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

    task send_nec_frame(input [31:0] data);
        integer i;
        begin
            /* Header */
            pad_in[3] = 1'b1;
            #(HEADER_MARK_NS);
            pad_in[3] = 1'b0;
            #(HEADER_SPACE_NS);

            /* 32 data bits, MSB first. */
            for (i = 31; i >= 0; i = i - 1) begin
                pad_in[3] = 1'b1;
                #(BIT_MARK_NS);
                pad_in[3] = 1'b0;
                if (data[i]) #(BIT1_SPACE_NS);
                else         #(BIT0_SPACE_NS);
            end

            /* Trailer — one more rising edge so the FW can measure the
             * 32nd bit's full period. */
            pad_in[3] = 1'b1;
            #(BIT_MARK_NS);
            pad_in[3] = 1'b0;
        end
    endtask

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_ir_rx.vcd");
        $dumpvars(0, tb_ir_rx);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_ir_rx: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed, IR capture running");

        /* Wait a bit so pad_in is stable before driving the frame. */
        #50000;

        $display("--- sending NEC frame 0x%08h ---", TEST_FRAME);
        send_nec_frame(TEST_FRAME);

        /* Wait for frame-received sentinel. */
        wait_for_mailbox(11'h600, 32'h00000001, 5000);

        apb_read(11'h610, rd);
        $display("  decoded frame = %08h  (expected %08h)", rd, TEST_FRAME);
        if (rd !== TEST_FRAME) begin
            $display("FAIL: decoded frame mismatch");
            $fatal;
        end

        $display("PASS: NEC 32-bit frame decoded correctly (%08h)", TEST_FRAME);
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
