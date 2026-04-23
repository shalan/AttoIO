/******************************************************************************/
// tb_freq_counter — E22.  Drives a 10 kHz square wave on pad[7] and
// verifies the firmware's freq_counter reports ~20 rising edges per
// 2 ms gate window (edges per window = f_stim × T_gate).
//
// Multi-source ISR demo: TIMER CAPTURE (per edge) + TIMER MATCH0 (per
// gate) share a single __isr.  Passing this test is the strongest
// proof that the IRQ aggregation and per-source W1C pattern work
// end-to-end.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/freq_counter/freq_counter.hex"
`endif

module tb_freq_counter;

    parameter SYSCLK_PERIOD = 10;   /* 100 MHz -> clk_iop = 25 MHz */
    parameter CLK_DIV       = 4;

    /* 10 kHz square wave = 100 µs period = 50 µs per half. */
    parameter integer STIM_HALF_NS = 50000;   /* ns */
    parameter integer EXPECTED_EDGES_PER_GATE = 20;
    parameter integer TOL_EDGES              = 2;  /* off-by-one at
                                                    * window boundary */

    reg         sysclk  = 0;
    reg         clk_iop = 0;
    reg         rst_n   = 0;

    reg  [10:0] PADDR;
    reg         PSEL, PENABLE, PWRITE;
    reg  [31:0] PWDATA;
    reg  [3:0]  PSTRB;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERR;

    reg  [15:0] pad_in = 16'h0000;
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

    /* 10 kHz stimulus on pad[7] — enabled after FW reaches WFI. */
    reg stim_enable = 1'b0;
    initial begin : stim_gen
        forever begin
            if (stim_enable) begin
                pad_in[7] = 1'b1;
                #(STIM_HALF_NS);
                pad_in[7] = 1'b0;
                #(STIM_HALF_NS);
            end else begin
                pad_in[7] = 1'b0;
                #100;
            end
        end
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
                if (val === expected) begin
                    $display("  mailbox @0x%03h = %08h (waited %0d reads)",
                             addr, val, tries);
                    disable wait_for_mailbox;
                end
                tries = tries + 1;
            end
            $display("FAIL: mailbox @0x%03h never reached %08h (last=%08h)",
                     addr, expected, val);
            $fatal;
        end
    endtask

    task wait_for_at_least(input [10:0] addr, input [31:0] threshold,
                           input integer max_tries);
        integer tries;
        reg [31:0] val;
        begin
            tries = 0;
            while (tries < max_tries) begin
                apb_read(addr, val);
                if (val >= threshold) begin
                    $display("  mailbox @0x%03h = %0d (>= %0d, waited %0d reads)",
                             addr, val, threshold, tries);
                    disable wait_for_at_least;
                end
                tries = tries + 1;
            end
            $display("FAIL: mailbox @0x%03h never reached >= %0d (last=%0d)",
                     addr, threshold, val);
            $fatal;
        end
    endtask

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] count, widx;

    initial begin
        $dumpfile("tb_freq_counter.vcd");
        $dumpvars(0, tb_freq_counter);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_freq_counter: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed TIMER+CAP, now in WFI");

        /* Start the 10 kHz stimulus on pad[7]. */
        $display("--- starting 10 kHz stim on pad[7] ---");
        stim_enable = 1'b1;

        /* Wait for at least two full gate windows to complete so we
         * can inspect a stable measurement.  window_idx >= 3 means
         * windows 1 and 2 landed; window 3 is in flight. */
        wait_for_at_least(11'h604, 3, 1000000);

        apb_read(11'h600, count);
        apb_read(11'h604, widx);
        $display("  window %0d: count = %0d", widx, count);

        if (count < EXPECTED_EDGES_PER_GATE - TOL_EDGES ||
            count > EXPECTED_EDGES_PER_GATE + TOL_EDGES) begin
            $display("FAIL: count=%0d not within %0d ± %0d",
                     count, EXPECTED_EDGES_PER_GATE, TOL_EDGES);
            $fatal;
        end

        /* Grab one more window to confirm steady state. */
        wait_for_at_least(11'h604, widx + 1, 1000000);
        apb_read(11'h600, count);
        apb_read(11'h604, widx);
        $display("  window %0d: count = %0d (should match)", widx, count);
        if (count < EXPECTED_EDGES_PER_GATE - TOL_EDGES ||
            count > EXPECTED_EDGES_PER_GATE + TOL_EDGES) begin
            $display("FAIL: second window count=%0d drifted out of range",
                     count);
            $fatal;
        end

        $display("PASS: freq counter = 10 kHz (measured %0d edges per 2 ms gate, expected ~%0d)",
                 count, EXPECTED_EDGES_PER_GATE);
        $finish;
    end

    initial begin
        #15000000;       /* 15 ms cap */
        $display("TIMEOUT");
        $fatal;
    end

endmodule
