/******************************************************************************/
// tb_timer — validates the TIMER block by running firmware that sets up
// a 40-count auto-reloading PWM on pad[3] and then measuring the pad
// toggle period.
//
// Passes when:
//   (1) mailbox[0] reads 0xCAFEBABE   (firmware reached the config point)
//   (2) pad_out[3] toggles at least 8 times within 800 clk_iop cycles
//   (3) each observed half-period is 40 ± 1 clk_iop cycles
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/timer_pwm/timer_pwm.hex"
`endif

module tb_timer;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    reg         sysclk  = 0;
    reg         clk_iop = 0;
    reg         rst_n   = 0;

    reg  [9:0]  host_addr;
    reg  [31:0] host_wdata;
    reg  [3:0]  host_wmask;
    reg         host_wen;
    reg         host_ren;
    wire [31:0] host_rdata;
    wire        host_ready;

    reg  [15:0] pad_in = 0;
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
        .host_addr(host_addr), .host_wdata(host_wdata), .host_wmask(host_wmask),
        .host_wen(host_wen), .host_ren(host_ren),
        .host_rdata(host_rdata), .host_ready(host_ready),
        .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe), .pad_ctl(pad_ctl),
        .irq_to_host(irq_to_host)
    );

    // Bus tasks (same pattern as other TBs)
    task host_write(input [9:0] addr, input [31:0] data);
        begin
            @(posedge sysclk); #1;
            host_addr = addr; host_wdata = data;
            host_wmask = 4'hF; host_wen = 1'b1; host_ren = 1'b0;
            @(posedge sysclk); #1;
            host_wen = 1'b0; host_wmask = 4'h0;
        end
    endtask

    task host_read(input [9:0] addr, output [31:0] data);
        begin
            @(posedge sysclk); #1;
            host_addr = addr; host_ren = 1'b1; host_wen = 1'b0;
            @(posedge sysclk); #1;
            host_ren = 1'b0;
            @(posedge sysclk); #1;
            data = host_rdata;
        end
    endtask

    // --------------------------------------------------------------
    // Measurement: watch pad_out[3] and log half-period lengths
    // --------------------------------------------------------------
    integer  edge_count;
    integer  cycles_this_half;
    integer  last_half;
    integer  all_good;
    reg      pad3_prev;

    initial begin
        edge_count = 0;
        cycles_this_half = 0;
        last_half = 0;
        all_good = 1;
        pad3_prev = 1'b0;
    end

    // Skip edges that happen before the timer is stably configured.
    // The first 2 edges can reflect transient pad state + startup.
    // Counter counts non-edge clk_iop cycles between two pad_out[3]
    // transitions. With CMP=39 and auto-reload, the true period is 40
    // cycles, but this counter increments 39 times between toggles
    // (39 "else" branches). Expected = 39 ±1.
    // Skip edges 1..3 (pre-config startup) before applying the tolerance.
    always @(posedge clk_iop) begin
        if (pad_out[3] !== pad3_prev) begin
            edge_count = edge_count + 1;
            if (edge_count > 3) begin
                if (cycles_this_half < 38 || cycles_this_half > 40) begin
                    $display("  WARN: half-period #%0d reported=%0d non-edge cycles (expected ~39)",
                             edge_count - 1, cycles_this_half);
                    all_good = 0;
                end
            end
            cycles_this_half = 0;
        end else begin
            cycles_this_half = cycles_this_half + 1;
        end
        pad3_prev = pad_out[3];
    end

    // --------------------------------------------------------------
    // Firmware loader + runner
    // --------------------------------------------------------------
    reg [31:0] fw_image [0:127];
    integer i;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_timer.vcd");
        $dumpvars(0, tb_timer);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        host_addr = 0; host_wdata = 0; host_wmask = 0;
        host_wen  = 0; host_ren  = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_timer: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            host_write(i * 4, fw_image[i]);

        $display("--- releasing IOP reset ---");
        host_write(10'h308, 32'h0);

        // Wait for the firmware to run enough edges.
        repeat (800) @(posedge clk_iop);

        // Verify sentinel
        host_read(10'h200, rd);
        if (rd !== 32'hCAFEBABE) begin
            $display("FAIL: mailbox[0] = %08h, expected CAFEBABE", rd);
            $fatal;
        end
        $display("  sentinel OK: mailbox[0] = %08h", rd);

        // Verify edge count + period
        if (edge_count < 8) begin
            $display("FAIL: only %0d pad_out[3] edges seen in 800 clk_iop cycles",
                     edge_count);
            $fatal;
        end
        if (!all_good) begin
            $display("FAIL: one or more half-periods out of tolerance");
            $fatal;
        end
        $display("PASS: pad_out[3] toggled %0d times, all half-periods 39 +/- 1 non-edge cycles (40-cycle period)",
                 edge_count);
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
