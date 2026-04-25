/******************************************************************************/
// tb_pwm4 — E8.  Verifies 4-channel IRQ-paced soft PWM on pads
// 8/9/10/11 with duties 25 / 50 / 75 / 100 %.
//
// After the FW reaches WFI we wait for the tick counter (mailbox[0])
// to hit PWM_PERIOD, then sample pad_out over exactly one PWM cycle
// (PWM_PERIOD × TICK_CYCLES clk_iop cycles) and measure each pad's
// HIGH duty cycle.  Tolerance absorbs the ~1-tick ISR latency before
// the GPIO_OUT_SET/CLR writes land.
/******************************************************************************/

`timescale 1ns/1ps
`include "attoio_variant.vh"

`ifndef FW_HEX
 `define FW_HEX "build/sw/pwm4/pwm4.hex"
`endif

module tb_pwm4;

    parameter SYSCLK_PERIOD = 10;   /* 100 MHz -> clk_iop = 25 MHz */
    parameter CLK_DIV       = 4;

    parameter integer TICK_CYCLES = 200;
    parameter integer PWM_PERIOD  = 32;
    parameter integer TOL         = 2;   /* tick units of tolerance */

    reg         sysclk  = 0;
    reg         clk_iop = 0;
    reg         rst_n   = 0;

    reg  [`AW-1:0] PADDR;
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

`include "apb_host.vh"

    task wait_for_mailbox(input [`AW-1:0] addr, input [31:0] expected,
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

    task wait_for_at_least(input [`AW-1:0] addr, input [31:0] threshold,
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

    /* Per-pad HIGH-cycle counters sampled on every clk_iop edge. */
    integer h_ch0 = 0, h_ch1 = 0, h_ch2 = 0, h_ch3 = 0;
    integer total_cycles = 0;
    reg     sampling = 1'b0;

    always @(posedge clk_iop) begin
        if (sampling) begin
            total_cycles = total_cycles + 1;
            if (pad_out[8])  h_ch0 = h_ch0 + 1;
            if (pad_out[9])  h_ch1 = h_ch1 + 1;
            if (pad_out[10]) h_ch2 = h_ch2 + 1;
            if (pad_out[11]) h_ch3 = h_ch3 + 1;
        end
    end

    reg [31:0] fw_image [0:255];
    integer i;
    integer exp_ch0, exp_ch1, exp_ch2, exp_ch3;
    integer window_cycles;

    initial begin
        $dumpfile("tb_pwm4.vcd");
        $dumpvars(0, tb_pwm4);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_pwm4: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(`REG(11'h008), 32'h0, 4'hF);

        wait_for_mailbox(`MBX(11'h008), 32'hC0DEC0DE, 50000);
        $display("  firmware armed PWM, now in WFI");

        /* Wait for tick to wrap once — that means at least one full
         * PWM cycle has passed and the pads are in their steady
         * pattern. */
        wait_for_at_least(`MBX(11'h000), 5, 500000);

        /* Start sampling.  Window = exactly PWM_PERIOD × TICK_CYCLES
         * clk_iop edges. */
        window_cycles = PWM_PERIOD * TICK_CYCLES;
        @(posedge clk_iop);
        sampling = 1'b1;
        repeat (window_cycles) @(posedge clk_iop);
        sampling = 1'b0;

        $display("--- sampled %0d clk_iop cycles ---", total_cycles);
        $display("  ch0 HIGH: %0d / %0d  (expected ~%0d)",
                 h_ch0, total_cycles,  8 * TICK_CYCLES);
        $display("  ch1 HIGH: %0d / %0d  (expected ~%0d)",
                 h_ch1, total_cycles, 16 * TICK_CYCLES);
        $display("  ch2 HIGH: %0d / %0d  (expected ~%0d)",
                 h_ch2, total_cycles, 24 * TICK_CYCLES);
        $display("  ch3 HIGH: %0d / %0d  (expected ~%0d)",
                 h_ch3, total_cycles, 32 * TICK_CYCLES);

        /* Expected HIGH cycles per channel, with ±TOL ticks tolerance. */
        exp_ch0 =  8 * TICK_CYCLES;
        exp_ch1 = 16 * TICK_CYCLES;
        exp_ch2 = 24 * TICK_CYCLES;
        exp_ch3 = 32 * TICK_CYCLES;

        if (h_ch0 < exp_ch0 - TOL*TICK_CYCLES || h_ch0 > exp_ch0 + TOL*TICK_CYCLES) begin
            $display("FAIL: ch0 HIGH %0d outside %0d ± %0d*%0d",
                     h_ch0, exp_ch0, TOL, TICK_CYCLES);
            $fatal;
        end
        if (h_ch1 < exp_ch1 - TOL*TICK_CYCLES || h_ch1 > exp_ch1 + TOL*TICK_CYCLES) begin
            $display("FAIL: ch1 HIGH %0d outside %0d ± %0d*%0d",
                     h_ch1, exp_ch1, TOL, TICK_CYCLES);
            $fatal;
        end
        if (h_ch2 < exp_ch2 - TOL*TICK_CYCLES || h_ch2 > exp_ch2 + TOL*TICK_CYCLES) begin
            $display("FAIL: ch2 HIGH %0d outside %0d ± %0d*%0d",
                     h_ch2, exp_ch2, TOL, TICK_CYCLES);
            $fatal;
        end
        if (h_ch3 < exp_ch3 - TOL*TICK_CYCLES || h_ch3 > exp_ch3 + TOL*TICK_CYCLES) begin
            $display("FAIL: ch3 HIGH %0d outside %0d ± %0d*%0d",
                     h_ch3, exp_ch3, TOL, TICK_CYCLES);
            $fatal;
        end

        $display("PASS: 4-channel PWM at 25/50/75/100%% duty verified over 1 PWM cycle");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
