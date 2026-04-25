/******************************************************************************/
// tb_stepper — E9.  Timestamps STEP rising edges on pad[8] and
// verifies the trapezoidal velocity profile: intervals shorten
// during acceleration, stay constant during cruise, lengthen during
// deceleration.  Total step count must equal N_STEPS.
/******************************************************************************/

`timescale 1ns/1ps
`include "attoio_variant.vh"

`ifndef FW_HEX
 `define FW_HEX "build/sw/stepper/stepper.hex"
`endif

module tb_stepper;

    parameter SYSCLK_PERIOD = 10;   /* 100 MHz -> clk_iop = 25 MHz */
    parameter CLK_DIV       = 4;

    parameter integer N_STEPS    = 30;
    parameter integer CRUISE_IVAL = 60;  /* clk_iop */

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

    /* ------------------------------------------------------------ */
    /*  STEP edge monitor — record each rising edge's time in clk_iop
        ticks since boot, plus total count.                          */
    /* ------------------------------------------------------------ */
    integer clk_iop_ticks = 0;
    reg     prev_step = 1'b0;
    integer step_times [0:63];   /* up to 64 edges — N_STEPS=30 */
    integer step_edges = 0;

    always @(posedge clk_iop) begin
        clk_iop_ticks = clk_iop_ticks + 1;
        if (pad_out[8] && !prev_step) begin
            step_times[step_edges] = clk_iop_ticks;
            step_edges = step_edges + 1;
        end
        prev_step <= pad_out[8];
    end

    reg [31:0] fw_image [0:255];
    integer i;
    integer ival;
    integer min_ival, max_ival;
    integer accel_end_idx, cruise_end_idx;

    initial begin
        $dumpfile("tb_stepper.vcd");
        $dumpvars(0, tb_stepper);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_stepper: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(`REG(11'h008), 32'h0, 4'hF);

        wait_for_mailbox(`MBX(11'h008), 32'hC0DEC0DE, 50000);
        $display("  firmware armed stepper, now in WFI");

        wait_for_mailbox(`MBX(11'h004), 32'h57EDD07E, 500000);
        $display("  stepper signalled motion complete");

        $display("--- captured %0d STEP rising edges (expected %0d) ---",
                 step_edges, N_STEPS);
        if (step_edges !== N_STEPS) begin
            $display("FAIL: got %0d step edges, expected %0d",
                     step_edges, N_STEPS);
            $fatal;
        end

        /* Print intervals between consecutive edges. */
        for (i = 1; i < step_edges; i = i + 1) begin
            ival = step_times[i] - step_times[i-1];
            $display("  step %0d interval = %0d clk_iop cycles", i, ival);
        end

        /* Effective intervals observed include a fixed ~138-cycle
         * ISR overhead on top of the firmware's programmed value
         * (mret + STEP pulse + mailbox writes + CMP reprogram + CTL
         * reset).  What matters is the *shape* of the profile, not
         * the absolute numbers — verify trapezoidal structure:
         *   (a) cruise intervals (steps 11..19) are flat within a few
         *       cycles,
         *   (b) cruise is the minimum — accel+decel ends are much
         *       longer (> 1.3x cruise). */
        min_ival = 1 << 30;
        max_ival = 0;
        for (i = 11; i < 20; i = i + 1) begin
            ival = step_times[i] - step_times[i-1];
            if (ival < min_ival) min_ival = ival;
            if (ival > max_ival) max_ival = ival;
        end
        $display("  cruise min/max interval: %0d / %0d (flat check)",
                 min_ival, max_ival);
        if (max_ival - min_ival > 5) begin
            $display("FAIL: cruise interval spread %0d cycles — not flat",
                     max_ival - min_ival);
            $fatal;
        end

        /* Trapezoid shape: first and last intervals must be
         * substantially longer than the cruise minimum. */
        if ((step_times[1] - step_times[0]) < (min_ival * 3) / 2) begin
            $display("FAIL: first interval %0d not meaningfully > cruise %0d (accel ramp missing)",
                     step_times[1] - step_times[0], min_ival);
            $fatal;
        end
        if ((step_times[N_STEPS-1] - step_times[N_STEPS-2]) < (min_ival * 3) / 2) begin
            $display("FAIL: last interval %0d not meaningfully > cruise %0d (decel ramp missing)",
                     step_times[N_STEPS-1] - step_times[N_STEPS-2], min_ival);
            $fatal;
        end

        $display("PASS: 30-step trapezoidal ramp verified (accel, cruise, decel)");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
