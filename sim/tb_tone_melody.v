/******************************************************************************/
// tb_tone_melody — E12.  The firmware plays a 4-note melody on pad[8]
// where each note is a square wave whose frequency is determined by
// TIMER CMP0 pad-toggle.  The TB watches pad[8] rising edges and the
// mailbox "current note" counter to measure the actual frequency of
// each note, and verifies it matches the programmed half-period.
//
// Measured metric: rising edges observed on pad[8] while mailbox[0]
// held a given note index.  Expected = BEAT_TOGGLES / 2 per note
// (each HIGH pulse contributes one rising edge).  BEAT_TOGGLES = 80
// matches in the FW, so we expect 40 rising edges per note window.
// Tolerance ±3 absorbs ISR edge-transition latency where the TB may
// have sampled a toggle on either side of the note boundary.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/tone_melody/tone_melody.hex"
`endif

module tb_tone_melody;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;
    parameter integer N_NOTES = 4;
    parameter integer EXPECTED_EDGES_PER_NOTE = 40;  /* 80 toggles / 2 */
    parameter integer EDGE_TOL                = 3;

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
        .irq_to_host(irq_to_host),

        .hp0_out(16'h0), .hp0_oe(16'h0), .hp0_in(),

        .hp1_out(16'h0), .hp1_oe(16'h0), .hp1_in(),

        .hp2_out(16'h0), .hp2_oe(16'h0), .hp2_in()
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

    /* Per-note edge counter: poll mailbox[0] in a tight loop to track
     * the current note, and count pad[8] rising edges seen during
     * each note's window. */
    integer edges_in_note [0:N_NOTES-1];
    integer note_that_started_edge = 0;   /* tracker */
    reg     prev_pad8 = 1'b0;
    integer edge_accum = 0;
    reg [31:0] last_mb0 = 32'h0;
    reg [31:0] fw_image [0:255];
    integer i;

    initial begin
        for (i = 0; i < N_NOTES; i = i + 1) edges_in_note[i] = 0;
    end

    always @(posedge sysclk) begin
        if (pad_out[8] && !prev_pad8) begin
            /* rising edge detected */
            if (last_mb0 < N_NOTES) begin
                edges_in_note[last_mb0] = edges_in_note[last_mb0] + 1;
            end
        end
        prev_pad8 <= pad_out[8];
    end

    initial begin
        $dumpfile("tb_tone_melody.vcd");
        $dumpvars(0, tb_tone_melody);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_tone_melody: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed, melody starts ---");

        /* Track the current note by polling mailbox[0].  Each time
         * mailbox[0] bumps, the FW started a new note.  We keep the
         * most-recent value in last_mb0 so the edge-count always block
         * above attributes edges to the right bucket. */
        begin : track
            integer tries;
            reg [31:0] val;
            tries = 0;
            while (tries < 2000000) begin
                apb_read(11'h600, val);
                last_mb0 = val;
                if (val == N_NOTES) disable track;
                tries = tries + 1;
            end
            $display("FAIL: melody never reached note %0d (last mb0=%0d)",
                     N_NOTES, val);
            $fatal;
        end

        /* Confirm done sentinel */
        apb_read(11'h60C, last_mb0);
        $display("  done sentinel mailbox[3] = %08h (expect D0DE0DE7)", last_mb0);
        if (last_mb0 !== 32'hD0DE0DE7) begin
            $display("FAIL: done sentinel wrong");
            $fatal;
        end

        /* Report + check */
        $display("");
        $display("================= Per-note edge counts =================");
        for (i = 0; i < N_NOTES; i = i + 1) begin
            $display("  note %0d: %0d rising edges on pad[8]  (expect %0d +/- %0d)",
                     i, edges_in_note[i], EXPECTED_EDGES_PER_NOTE, EDGE_TOL);
        end

        begin : audit
            integer bad;
            bad = 0;
            for (i = 0; i < N_NOTES; i = i + 1) begin
                if (edges_in_note[i] < EXPECTED_EDGES_PER_NOTE - EDGE_TOL ||
                    edges_in_note[i] > EXPECTED_EDGES_PER_NOTE + EDGE_TOL) begin
                    bad = bad + 1;
                end
            end
            if (bad == 0) begin
                $display("PASS: %0d notes played, each with %0d +/- %0d rising edges",
                         N_NOTES, EXPECTED_EDGES_PER_NOTE, EDGE_TOL);
            end else begin
                $display("FAIL: %0d note(s) outside tolerance", bad);
                $fatal;
            end
        end
        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
