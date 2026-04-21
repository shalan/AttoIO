/******************************************************************************/
// tb_pdm_dac — E14.  Runs the 1-bit sigma-delta PDM firmware for the
// full 4-sample sequence and verifies the total number of HIGH
// pulses on pad[8] matches what the programmed sample table predicts
// (samples × PULSES_PER_SAMPLE / 256).
//
// We deliberately stay off the APB host bus while the firmware runs
// — continuous polling of the mailbox creates SRAM B contention that
// stalls the ISR enough to miss PDM cycles at high densities.  The
// TB waits on the IRQ_TO_HOST line (driven by DOORBELL_C2H), which
// the FW raises only once at end-of-sequence.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/pdm_dac/pdm_dac.hex"
`endif

module tb_pdm_dac;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    parameter integer N_SAMPLES         = 4;
    parameter integer PULSES_PER_SAMPLE = 64;
    parameter integer TOTAL_PULSES      = N_SAMPLES * PULSES_PER_SAMPLE;   /* 256 */
    parameter integer HIGH_TOL          = 2;

    /* Expected total HIGH count = sum over samples of
     * (sample_val / 256 * 64).  For [64, 128, 192, 255]:
     *   16 + 32 + 48 + 64 = 160.  Actually the 255 term is
     *   255/256 * 64 = 63.75 -> 63 HIGH (sigma-delta rounds down
     *   over 64 cycles). */
    parameter integer EXPECTED_HIGH = 16 + 32 + 48 + 63;   /* 159 */

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

    /* PDM density measurement: count sysclks with pad[8] HIGH while
     * the window is open.  Divide by sysclks-per-PDM-bit to convert
     * to "number of HIGH PDM pulses".  Rising-edge counting would
     * undercount at high density where pad stays HIGH across
     * consecutive PDM bits. */
    integer high_sysclks = 0;
    reg     window_open  = 1'b0;
    always @(posedge sysclk) begin
        if (window_open && pad_out[8]) high_sysclks = high_sysclks + 1;
    end
    /* 250 clk_iop per PDM bit × CLK_DIV sysclks per clk_iop. */
    localparam integer SYSCLK_PER_PDM = 250 * CLK_DIV;

    reg [31:0] fw_image [0:127];
    integer i;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_pdm_dac.vcd");
        $dumpvars(0, tb_pdm_dac);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_pdm_dac: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);
        apb_write(11'h708, 32'h0, 4'hF);

        /* Single mailbox check to confirm FW reached WFI. */
        begin : arm_wait
            integer tries;
            reg [31:0] val;
            tries = 0;
            while (tries < 5000) begin
                apb_read(11'h608, val);
                if (val === 32'hC0DEC0DE) disable arm_wait;
                tries = tries + 1;
            end
            $display("FAIL: firmware never published sentinel");
            $fatal;
        end
        $display("  firmware armed, PDM running");

        /* Open the density-measurement window and stay silent on
         * the bus until the FW signals completion.  TOTAL_PULSES ×
         * PDM_PERIOD × clk_iop_period = 256 × 250 × 40 ns = 2.56 ms.
         * Add slack for startup. */
        window_open = 1'b1;
        #2700000;    /* 2.7 ms — just past the 2.56 ms nominal end */
        window_open = 1'b0;

        apb_read(11'h60C, rd);
        if (rd !== 32'h5A5ED0DE) begin
            $display("FAIL: done sentinel = %08h, expected 5A5ED0DE", rd);
            $fatal;
        end
        apb_read(11'h604, rd);
        if (rd !== N_SAMPLES) begin
            $display("FAIL: final sample index = %0d, expected %0d",
                     rd, N_SAMPLES);
            $fatal;
        end
        $display("  PDM sequence finished (%0d samples played)", N_SAMPLES);

        $display("");
        $display("================= Total pulse-density audit =================");
        begin : audit
            integer measured_high_pulses;
            measured_high_pulses = high_sysclks / SYSCLK_PER_PDM;
            $display("  HIGH sysclks observed : %0d",    high_sysclks);
            $display("  sysclks per PDM bit   : %0d",    SYSCLK_PER_PDM);
            $display("  -> HIGH PDM pulses    : %0d",    measured_high_pulses);
            $display("  expected              : %0d +/- %0d", EXPECTED_HIGH, HIGH_TOL);
            if (measured_high_pulses < EXPECTED_HIGH - HIGH_TOL ||
                measured_high_pulses > EXPECTED_HIGH + HIGH_TOL) begin
                $display("FAIL: PDM density out of range");
                $fatal;
            end
            $display("PASS: sigma-delta density = %0d pulses (target %0d +/- %0d)",
                     measured_high_pulses, EXPECTED_HIGH, HIGH_TOL);
        end
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
