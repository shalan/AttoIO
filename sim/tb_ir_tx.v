/******************************************************************************/
// tb_ir_tx — E17.  Observes pad_out[8], measures each mark/space
// interval, reconstructs the NEC 32-bit payload from the pulse
// widths, and verifies it matches what the FW intended to transmit.
//
// Matching TX decoder: timing uses the same 50x scaling as
// sw/ir_rx + tb_ir_rx, so a future loopback test (pad_out[8] wired
// into the same or another IOP's pad_in[3] running ir_rx) would
// just work.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/ir_tx/ir_tx.hex"
`endif

module tb_ir_tx;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    parameter [31:0] EXPECTED_FRAME = 32'hABCD1234;

    /* Expected nominal timings in ns. */
    parameter integer HEADER_MARK_NS  = 180_000;
    parameter integer HEADER_SPACE_NS = 90_000;
    parameter integer BIT_MARK_NS     = 11_200;
    parameter integer BIT0_SPACE_NS   = 11_200;
    parameter integer BIT1_SPACE_NS   = 33_800;

    /* Decoder thresholds (in ns) between bit-0 and bit-1 SPACE. */
    parameter integer BIT_THRESH_NS = 20_000;

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

    /* Edge capture: timestamp every rising/falling edge of pad[8]. */
    integer rise_t [0:34];     /* room for 1 header + 32 bits + 1 trailer */
    integer fall_t [0:34];
    integer rise_n = 0;
    integer fall_n = 0;
    reg     prev_pad8 = 1'b0;

    always @(posedge clk_iop) begin
        if (pad_out[8] && !prev_pad8) begin
            if (rise_n < 35) begin
                rise_t[rise_n] = $time;
                rise_n = rise_n + 1;
            end
        end
        if (!pad_out[8] && prev_pad8) begin
            if (fall_n < 35) begin
                fall_t[fall_n] = $time;
                fall_n = fall_n + 1;
            end
        end
        prev_pad8 <= pad_out[8];
    end

    reg [31:0] fw_image [0:255];
    integer i;
    integer header_mark_ns, header_space_ns;
    integer space_ns;
    reg [31:0] decoded;

    initial begin
        $dumpfile("tb_ir_tx.vcd");
        $dumpvars(0, tb_ir_tx);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_ir_tx: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed — TX frame 0x%08h", EXPECTED_FRAME);

        /* Wait for done sentinel. */
        wait_for_mailbox(11'h600, 32'h1, 500000);
        $display("  TX finished");

        $display("");
        $display("=============== TX envelope audit ===============");
        $display("  rising edges captured:  %0d (expect 34)", rise_n);
        $display("  falling edges captured: %0d (expect 34)", fall_n);
        if (rise_n != 34 || fall_n != 34) begin
            $display("FAIL: unexpected edge count");
            $fatal;
        end

        /* Header widths */
        header_mark_ns  = fall_t[0]   - rise_t[0];    /* first mark */
        header_space_ns = rise_t[1]   - fall_t[0];    /* first space */
        $display("  header mark  = %0d ns  (expect ~%0d)", header_mark_ns,  HEADER_MARK_NS);
        $display("  header space = %0d ns  (expect ~%0d)", header_space_ns, HEADER_SPACE_NS);

        /* Decode 32 bits MSB-first.  Bit N's SPACE duration is
         * rise_t[1 + (N + 1)] - fall_t[1 + N]  ... but the indexing
         * is cleaner if we step through bits by their rise-to-fall
         * and fall-to-rise pairs starting at index 1. */
        decoded = 32'h0;
        for (i = 0; i < 32; i = i + 1) begin
            /* Bit i occupies rising edge at index i+1 (its mark start)
             * and falling edge at index i+1 (mark end), space ending
             * at rising edge i+2. */
            space_ns = rise_t[i + 2] - fall_t[i + 1];
            if (space_ns > BIT_THRESH_NS) decoded[31 - i] = 1'b1;
            else                          decoded[31 - i] = 1'b0;
        end

        $display("  decoded frame = %08h", decoded);
        $display("  expected      = %08h", EXPECTED_FRAME);
        if (decoded !== EXPECTED_FRAME) begin
            $display("FAIL: frame mismatch");
            $fatal;
        end

        /* Sanity-check header widths within ±25 % (FW overhead jitter). */
        if (header_mark_ns < HEADER_MARK_NS * 3 / 4 ||
            header_mark_ns > HEADER_MARK_NS * 5 / 4) begin
            $display("FAIL: header mark width out of range");
            $fatal;
        end
        if (header_space_ns < HEADER_SPACE_NS * 3 / 4 ||
            header_space_ns > HEADER_SPACE_NS * 5 / 4) begin
            $display("FAIL: header space width out of range");
            $fatal;
        end

        $display("PASS: NEC 32-bit frame %08h transmitted and decoded correctly",
                 EXPECTED_FRAME);
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
