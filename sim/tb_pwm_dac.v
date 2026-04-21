/******************************************************************************/
// tb_pwm_dac — E13.  Measures HIGH cycle count on pad[8] during each
// PWM period and verifies it matches the programmed duty (which
// varies across 8 triangle-wave samples, each held for 2 periods =>
// 16 periods total).
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/pwm_dac/pwm_dac.hex"
`endif

module tb_pwm_dac;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;
    parameter integer PERIOD       = 2048;
    parameter integer N_SAMPLES    = 8;
    parameter integer HOLD_PERIODS = 1;
    parameter integer N_PERIODS    = N_SAMPLES * HOLD_PERIODS;   /* 8 */
    parameter integer DUTY_TOL     = 32;   /* ±32 clk_iop out of 2048 */

    /* Expected HIGH cycles per carrier period — one per sample. */
    reg [15:0] expected_duty [0:N_PERIODS-1];
    initial begin
        expected_duty[0] =  256;
        expected_duty[1] =  512;
        expected_duty[2] = 1024;
        expected_duty[3] = 1792;
        expected_duty[4] = 1024;
        expected_duty[5] =  512;
        expected_duty[6] =  256;
        expected_duty[7] =  128;
    end

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

    /* Per-period HIGH cycle counter on pad[8].  A "period" begins on
     * a rising edge of pad[8] (CMP0 match sets the pad HIGH) and ends
     * on the next rising edge.  HIGH cycles accumulate while pad=1,
     * LOW cycles while pad=0.  We record duty=HIGH_cycles. */
    integer period_idx   = -1;       /* -1 = before first CMP0 match */
    integer high_cycles  = 0;
    integer measured_duty[0:63];
    reg     prev_pad8    = 1'b0;

    initial begin : init_measured
        integer k;
        for (k = 0; k < 64; k = k + 1) measured_duty[k] = 0;
    end

    always @(posedge clk_iop) begin
        /* Rising edge = start of new period */
        if (pad_out[8] && !prev_pad8) begin
            if (period_idx >= 0 && period_idx < 64) begin
                measured_duty[period_idx] = high_cycles;
            end
            period_idx  = period_idx + 1;
            high_cycles = 0;
        end
        if (pad_out[8]) high_cycles = high_cycles + 1;
        prev_pad8 <= pad_out[8];
    end

    reg [31:0] fw_image [0:127];
    integer i;

    initial begin
        $dumpfile("tb_pwm_dac.vcd");
        $dumpvars(0, tb_pwm_dac);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_pwm_dac: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed, PWM running");

        /* Wait for "done" sentinel 0x5A5ED0DE in mailbox[3]. */
        wait_for_mailbox(11'h60C, 32'h5A5ED0DE, 500000);
        $display("  PWM sequence finished");

        /* Give the measurement a brief tail to record the final pad
         * state (since the FW ends with pad LOW and no further rising
         * edge will close the 16th period). */
        repeat (2 * PERIOD) @(posedge clk_iop);

        $display("");
        $display("================= Per-period HIGH counts =================");
        begin : audit
            integer bad;
            bad = 0;
            /* Skip period 0 (contaminated by main()'s initial HIGH
             * pulse before TIMER is running) and the last period
             * (never closed — no rising edge follows it because the
             * FW disables the TIMER and drives pad LOW on "done").
             * The interior 6 periods are the real measurement. */
            for (i = 1; i < N_PERIODS - 1 && i < 64; i = i + 1) begin
                $display("  period %0d: HIGH = %0d (expect %0d +/- %0d)",
                         i, measured_duty[i],
                         expected_duty[i], DUTY_TOL);
                if (measured_duty[i] < expected_duty[i] - DUTY_TOL ||
                    measured_duty[i] > expected_duty[i] + DUTY_TOL) begin
                    bad = bad + 1;
                end
            end
            if (bad == 0) begin
                $display("PASS: %0d interior PWM periods match programmed duty within +/- %0d",
                         N_PERIODS - 2, DUTY_TOL);
            end else begin
                $display("FAIL: %0d period(s) outside tolerance", bad);
                $fatal;
            end
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
