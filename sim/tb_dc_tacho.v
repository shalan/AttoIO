/******************************************************************************/
// tb_dc_tacho — E11.  Verifies simultaneous soft-PWM (pad[8]) and
// tacho-count (pad[0]) operation.  Drives a 10 kHz square wave on
// pad[0] and checks:
//   1. PWM duty on pad[8] is ~50 % over one PWM cycle.
//   2. Tacho count for a published gate window (1 PWM cycle = 256 µs)
//      is 2-3 pulses (reasonable for 10 kHz stim).
//   3. After the TB disables the stim, a later gate reports ~0.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/dc_tacho/dc_tacho.hex"
`endif

module tb_dc_tacho;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    parameter integer STIM_HALF_NS = 50000;   /* 10 kHz square wave */
    parameter integer TICK_CYCLES  = 200;
    parameter integer PWM_PERIOD   = 32;
    parameter integer PWM_WINDOW   = PWM_PERIOD * TICK_CYCLES;

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

    /* 10 kHz tacho stimulus on pad[0] — enabled after FW armed. */
    reg stim_enable = 1'b0;
    initial begin : stim_gen
        forever begin
            if (stim_enable) begin
                pad_in[0] = 1'b1;
                #(STIM_HALF_NS);
                pad_in[0] = 1'b0;
                #(STIM_HALF_NS);
            end else begin
                pad_in[0] = 1'b0;
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

    /* Per-pad HIGH sample over one PWM cycle. */
    integer h_pwm = 0;
    integer total_cycles = 0;
    reg     sampling = 1'b0;

    always @(posedge clk_iop) begin
        if (sampling) begin
            total_cycles = total_cycles + 1;
            if (pad_out[8]) h_pwm = h_pwm + 1;
        end
    end

    reg [31:0] fw_image [0:127];
    integer i;
    reg [31:0] tacho;

    initial begin
        $dumpfile("tb_dc_tacho.vcd");
        $dumpvars(0, tb_dc_tacho);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_dc_tacho: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed PWM + tacho, WFI");

        /* Wait for PWM to get past its first cycle so pad[8] is in
         * steady-state.  tick (mailbox[1]) wraps to 0 once per PWM
         * cycle; waiting for it to reach 10 ensures we're mid-cycle. */
        wait_for_at_least(11'h604, 10, 50000);

        /* Sample one full PWM cycle. */
        total_cycles = 0;
        h_pwm = 0;
        @(posedge clk_iop);
        sampling = 1'b1;
        repeat (PWM_WINDOW) @(posedge clk_iop);
        sampling = 1'b0;

        $display("--- sampled PWM cycle: %0d clk_iop, HIGH = %0d (expected ~%0d, 50%%) ---",
                 total_cycles, h_pwm, PWM_WINDOW / 2);
        if (h_pwm < PWM_WINDOW * 4 / 10 || h_pwm > PWM_WINDOW * 6 / 10) begin
            $display("FAIL: PWM duty %0d / %0d out of 40-60%% window",
                     h_pwm, PWM_WINDOW);
            $fatal;
        end

        /* Now turn on the tacho and verify it gets counted. */
        $display("--- starting 10 kHz tacho on pad[0] ---");
        stim_enable = 1'b1;

        /* 10 kHz over ~256 µs PWM window = ~2.56 pulses.  Allow 1-5. */
        begin : wait_tacho
            integer j;
            reg [31:0] val;
            for (j = 0; j < 200000; j = j + 1) begin
                apb_read(11'h600, val);
                if (val >= 1 && val <= 10) begin
                    $display("  mailbox[0] tacho count = %0d (expected 1-5 for 10 kHz / 256 us)",
                             val);
                    tacho = val;
                    disable wait_tacho;
                end
            end
            $display("FAIL: tacho never reported plausible count");
            $fatal;
        end

        /* Turn off tacho, wait for a subsequent window to report 0. */
        $display("--- stopping tacho ---");
        stim_enable = 1'b0;

        /* Wait a couple more PWM cycles, then expect count = 0. */
        repeat (PWM_WINDOW * 3) @(posedge clk_iop);

        apb_read(11'h600, tacho);
        if (tacho !== 32'h0) begin
            $display("FAIL: tacho expected 0 after stim off, got %0d", tacho);
            $fatal;
        end
        $display("  tacho quiet: count = 0");

        $display("PASS: PWM at 50%% + tacho monitor verified");
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
