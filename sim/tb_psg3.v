/******************************************************************************/
// tb_psg3 — E15.  Observes the three voice pads (pad[8], pad[9],
// pad[10]) over the full 200-sample PSG run and verifies each voice's
// rising-edge count matches its programmed pitch.
//
//   Voice 0 half=10 samples -> full period 20 samples -> 10 edges / 200
//   Voice 1 half=5  samples -> full period 10 samples -> 20 edges / 200
//   Voice 2 half=2  samples -> full period  4 samples -> 50 edges / 200
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/psg3/psg3.hex"
`endif

module tb_psg3;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    parameter integer N_SAMPLES       = 200;
    parameter integer EXPECTED_V0_EDGES = 10;   /* half=10 */
    parameter integer EXPECTED_V1_EDGES = 20;
    parameter integer EXPECTED_V2_EDGES = 50;
    parameter integer EDGE_TOL          = 2;

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

    /* Per-voice edge counters — latched during the measurement window. */
    integer v0_edges = 0, v1_edges = 0, v2_edges = 0;
    reg     prev_pad8 = 1'b0, prev_pad9 = 1'b0, prev_pad10 = 1'b0;
    reg     window_open = 1'b0;

    always @(posedge sysclk) begin
        if (window_open) begin
            if (pad_out[8]  && !prev_pad8)  v0_edges = v0_edges + 1;
            if (pad_out[9]  && !prev_pad9)  v1_edges = v1_edges + 1;
            if (pad_out[10] && !prev_pad10) v2_edges = v2_edges + 1;
        end
        prev_pad8  <= pad_out[8];
        prev_pad9  <= pad_out[9];
        prev_pad10 <= pad_out[10];
    end

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_psg3.vcd");
        $dumpvars(0, tb_psg3);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_psg3: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);
        apb_write(11'h708, 32'h0, 4'hF);

        /* Wait for armed sentinel, then open window. */
        begin : arm_wait
            integer tries;
            reg [31:0] val;
            tries = 0;
            while (tries < 5000) begin
                apb_read(11'h608, val);
                if (val === 32'hC0DEC0DE) disable arm_wait;
                tries = tries + 1;
            end
            $display("FAIL: firmware never published arm sentinel");
            $fatal;
        end
        $display("  firmware armed, PSG running (3 voices)");
        window_open = 1'b1;

        /* Run = N_SAMPLES * SAMPLE_PERIOD * CLK_DIV * sysclk_period
         *     = 200 * 250 * 4 * 10 ns  = 2.0 ms.  Pad with slack. */
        #2500000;
        window_open = 1'b0;

        apb_read(11'h60C, rd);
        if (rd !== 32'h5A5ED0DE) begin
            $display("FAIL: done sentinel = %08h, expected 5A5ED0DE", rd);
            $fatal;
        end
        $display("  PSG run complete");

        $display("");
        $display("================= Per-voice rising-edge audit =================");
        $display("  voice 0 (pad[8]) : %0d edges  (expect %0d +/- %0d)",
                 v0_edges, EXPECTED_V0_EDGES, EDGE_TOL);
        $display("  voice 1 (pad[9]) : %0d edges  (expect %0d +/- %0d)",
                 v1_edges, EXPECTED_V1_EDGES, EDGE_TOL);
        $display("  voice 2 (pad[10]): %0d edges  (expect %0d +/- %0d)",
                 v2_edges, EXPECTED_V2_EDGES, EDGE_TOL);

        begin : audit
            integer bad;
            bad = 0;
            if (v0_edges < EXPECTED_V0_EDGES - EDGE_TOL ||
                v0_edges > EXPECTED_V0_EDGES + EDGE_TOL) bad = bad + 1;
            if (v1_edges < EXPECTED_V1_EDGES - EDGE_TOL ||
                v1_edges > EXPECTED_V1_EDGES + EDGE_TOL) bad = bad + 1;
            if (v2_edges < EXPECTED_V2_EDGES - EDGE_TOL ||
                v2_edges > EXPECTED_V2_EDGES + EDGE_TOL) bad = bad + 1;
            if (bad == 0) begin
                $display("PASS: 3 voices producing expected independent pitches");
            end else begin
                $display("FAIL: %0d voice(s) outside edge tolerance", bad);
                $fatal;
            end
        end
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
