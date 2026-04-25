/******************************************************************************/
// tb_ir_learn — E18.  Drives a known 4-edge pattern on pad_in[3],
// waits for the FW to capture + replay, then verifies the 3 inter-
// edge deltas on pad_out[8] match the original input within ±2 µs.
//
// Test pattern (edges on pad[3], ns from start of stimulus):
//   t = 10 000   rising   (mark start)
//   t = 30 000   falling  (mark end;   mark = 20 µs HIGH)
//   t = 40 000   rising   (next mark;  space = 10 µs LOW)
//   t = 60 000   falling  (mark end;   mark = 20 µs HIGH)
//
// Inter-edge deltas:  20, 10, 20 (µs)
// Replay must produce the same 3 deltas on pad_out[8].
/******************************************************************************/

`timescale 1ns/1ps
`include "attoio_variant.vh"

`ifndef FW_HEX
 `define FW_HEX "build/sw/ir_learn/ir_learn.hex"
`endif

module tb_ir_learn;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;
    parameter integer N_EDGES = 4;
    parameter integer DELTA_TOL_NS = 2000;   /* ±2 µs — CMP setup + APB jitter */

    /* Expected inter-edge deltas (ns).  Indices [0..2] = 3 deltas. */
    integer expected_delta [0:N_EDGES-2];
    initial begin
        expected_delta[0] = 20_000;
        expected_delta[1] = 10_000;
        expected_delta[2] = 20_000;
    end

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
                if (val === expected) disable wait_for_mailbox;
                tries = tries + 1;
            end
            $display("FAIL: mailbox @0x%03h never reached %08h (last=%08h)",
                     addr, expected, val);
            $fatal;
        end
    endtask

    task drive_pattern;
        begin
            /* Stimulus timings in ns from t=0 of this task call. */
            #10_000; pad_in[3] = 1'b1;
            #20_000; pad_in[3] = 1'b0;
            #10_000; pad_in[3] = 1'b1;
            #20_000; pad_in[3] = 1'b0;
        end
    endtask

    /* Edge observer on pad_out[8] — timestamp every transition.
     * Gated by observer_en so the armed-state settling transitions
     * don't count as replay edges. */
    integer replay_t [0:N_EDGES-1];
    integer replay_n = 0;
    reg     prev_pad8 = 1'b0;
    reg     observer_en = 1'b0;
    always @(posedge clk_iop) begin
        if (observer_en && pad_out[8] !== prev_pad8) begin
            if (replay_n < N_EDGES) begin
                replay_t[replay_n] = $time;
                replay_n = replay_n + 1;
            end
        end
        prev_pad8 <= pad_out[8];
    end

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] rd;
    integer measured;

    initial begin
        $dumpfile("tb_ir_learn.vcd");
        $dumpvars(0, tb_ir_learn);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_ir_learn: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);
        apb_write(`REG(11'h008), 32'h0, 4'hF);

        wait_for_mailbox(`MBX(11'h008), 32'hC0DEC0DE, 50000);
        $display("  firmware armed, entering LEARN phase");

        /* Drive the input pattern. */
        drive_pattern();

        /* Wait for LEARN phase to complete (mailbox[0] = 1). */
        wait_for_mailbox(`MBX(11'h000), 32'h1, 500000);
        $display("  LEARN complete (FW reached LEARN-done sentinel)");

        /* Only now that LEARN is done, enable the replay edge observer
         * so any pad[8] setup / capture-phase transients don't count. */
        observer_en = 1'b1;

        /* Wait for REPLAY phase to complete (mailbox[0] = 2). */
        wait_for_mailbox(`MBX(11'h000), 32'h2, 500000);
        $display("  REPLAY complete, %0d pad[8] transitions observed", replay_n);

        if (replay_n !== N_EDGES) begin
            $display("FAIL: expected %0d replay edges, got %0d",
                     N_EDGES, replay_n);
            $fatal;
        end

        $display("");
        $display("================= Inter-edge delta audit =================");
        begin : audit
            integer bad;
            bad = 0;
            for (i = 0; i < N_EDGES - 1; i = i + 1) begin
                measured = replay_t[i + 1] - replay_t[i];
                $display("  delta %0d: %0d ns (expect %0d ± %0d)",
                         i, measured, expected_delta[i], DELTA_TOL_NS);
                if (measured < expected_delta[i] - DELTA_TOL_NS ||
                    measured > expected_delta[i] + DELTA_TOL_NS) begin
                    bad = bad + 1;
                end
            end
            if (bad != 0) begin
                $display("FAIL: %0d delta(s) outside tolerance", bad);
                $fatal;
            end
        end

        $display("PASS: 6-edge waveform learned on pad[3], replayed on pad[8]");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
