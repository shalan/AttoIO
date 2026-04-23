/******************************************************************************/
// tb_coexist — Phase H16 coexistence demo.
//
// Demonstrates IOP autonomous bit-bang + host-peripheral bundle sharing the
// same pad ring simultaneously.
//
//   - IOP firmware: unmodified uart_tx — bit-bangs "Hello, AttoIO\r\n" on
//     pad[0] using TIMER CMP0 pacing.
//   - Host: sets PINMUX so pads 2, 3, 4 are driven by hp0_out/hp0_oe.
//     Then drives a 4-bit wiggle pattern on hp0_out[2..4] while the UART
//     is transmitting.
//
// Pass criteria:
//   1. UART RX model on pad[0] decodes the full "Hello, AttoIO\r\n" string
//      (proves the IOP's autonomous emulation kept running uninterrupted).
//   2. pad_out[2..4] tracks hp0_out[2..4] exactly during the host wiggle
//      (proves the PINMUX routing gives the host peripheral direct control
//      of those pads even while the IOP is busy).
//   3. pad[0] is NOT influenced by hp0 activity (PINMUX[0] = 00, so the
//      IOP's GPIO drive wins).
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/uart_tx/uart_tx.hex"
`endif

module tb_coexist;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;
    parameter UART_BIT_NS   = 8681;

    real   SAMPLE_HALF_NS = UART_BIT_NS / (2.0 * 16);
    reg    sample_clk     = 0;
    always #(SAMPLE_HALF_NS) sample_clk = ~sample_clk;

    reg         sysclk = 0;
    reg         clk_iop = 0;
    reg         rst_n = 0;

    reg  [10:0] PADDR = 0;
    reg         PSEL = 0, PENABLE = 0, PWRITE = 0;
    reg  [31:0] PWDATA = 0;
    reg  [3:0]  PSTRB = 0;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERR;

    reg  [15:0]  pad_in = 16'hFFFF;
    wire [15:0]  pad_out, pad_oe;
    wire [127:0] pad_ctl;
    wire irq_to_host;

    reg  [15:0] hp0_out = 16'h0, hp0_oe = 16'h0;
    reg  [15:0] hp1_out = 16'h0, hp1_oe = 16'h0;
    reg  [15:0] hp2_out = 16'h0, hp2_oe = 16'h0;
    wire [15:0] hp0_in, hp1_in, hp2_in;

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
        .hp0_out(hp0_out), .hp0_oe(hp0_oe), .hp0_in(hp0_in),
        .hp1_out(hp1_out), .hp1_oe(hp1_oe), .hp1_in(hp1_in),
        .hp2_out(hp2_out), .hp2_oe(hp2_oe), .hp2_in(hp2_in)
    );

    // UART RX model on pad_out[0] (same wiring as tb_uart)
    wire [7:0] rx_byte;
    wire       rx_valid;
    wire       rx_frame_err;
    uart_rx_model #(.SAMPLES_PER_BIT(16)) u_rx (
        .sample_clk (sample_clk),
        .rx_line    (pad_out[0]),
        .byte_out   (rx_byte),
        .byte_valid (rx_valid),
        .frame_err  (rx_frame_err)
    );

    // APB helpers
    task apb_write(input [10:0] a, input [31:0] d, input [3:0] s);
        begin
            @(posedge sysclk); #1;
            PADDR = a; PWDATA = d; PSTRB = s; PWRITE = 1; PSEL = 1;
            @(posedge sysclk); #1; PENABLE = 1;
            @(posedge sysclk); #1;
            while (!PREADY) @(posedge sysclk);
            @(posedge sysclk); #1;
            PSEL = 0; PENABLE = 0; PWRITE = 0; PSTRB = 0;
        end
    endtask

    task apb_read(input [10:0] a, output [31:0] d);
        begin
            @(posedge sysclk); #1;
            PADDR = a; PWRITE = 0; PSEL = 1;
            @(posedge sysclk); #1; PENABLE = 1;
            @(posedge sysclk); #1;
            while (!PREADY) @(posedge sysclk);
            d = PRDATA;
            @(posedge sysclk); #1;
            PSEL = 0; PENABLE = 0;
        end
    endtask

    // UART byte capture
    reg  [7:0] received [0:31];
    integer    rx_cnt;
    always @(posedge rx_valid) begin
        if (rx_cnt < 32) begin
            received[rx_cnt] = rx_byte;
            rx_cnt = rx_cnt + 1;
        end
    end

    // ---------- Host bundle host_peripheral driver ----------
    // Wiggle pads 2/3/4 via hp0 while the UART is transmitting.
    reg       hp_active = 1'b0;
    integer   wiggle_count;
    reg       pad_track_err;     // sticky mismatch flag (any pad, any cycle)

    initial wiggle_count = 0;
    initial pad_track_err = 1'b0;

    // Continuous check: while the bundle is active, pad_out[4:2] must
    // match hp0_out[4:2] on every sysclk.  (The 4:1 mux is combinational,
    // so this holds as soon as PINMUX is programmed.)
    always @(posedge sysclk) begin
        if (hp_active) begin
            if (pad_out[4:2] !== hp0_out[4:2]) pad_track_err <= 1'b1;
            hp0_out[4:2] <= hp0_out[4:2] + 3'd1;
            hp0_oe[4:2]  <= 3'b111;
            wiggle_count <= wiggle_count + 1;
        end
    end

    reg [31:0] fw_image [0:255];
    integer i;
    reg [255:0] expected = "Hello, AttoIO\r\n";
    reg         ok;
    reg [31:0]  rd;

    initial begin
        $dumpfile("tb_coexist.vcd");
        $dumpvars(0, tb_coexist);
        rx_cnt = 0;

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_coexist: loading uart_tx firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- programming PINMUX: pads 2,3,4 -> hp0 ---");
        // pinmux bits: pad p uses bits [2p+:2], 2'b01 = hp0
        // pads 2, 3, 4 -> 01_01_01 at bits 4, 6, 8 = shifted into LO word
        apb_write(11'h710, (32'b01 << 4) | (32'b01 << 6) | (32'b01 << 8), 4'hF);
        apb_read (11'h710, rd);
        if (rd !== 32'h00000150) begin
            $display("FAIL: PINMUX_LO readback got=%08h exp=00000150", rd);
            $fatal;
        end

        $display("--- releasing IOP reset + starting host hp0 wiggle ---");
        apb_write(11'h708, 32'h0, 4'hF);
        hp_active = 1'b1;

        // Wait for UART traffic to finish (sentinel at mbox[0])
        begin : wait_sentinel
            integer w;
            reg [31:0] s;
            w = 0; s = 0;
            while (s !== 32'hD0D0D0D0 && w < 100000) begin
                apb_read(11'h600, s);
                w = w + 1;
            end
            if (s !== 32'hD0D0D0D0) begin
                $display("FAIL: uart_tx didn't hit sentinel (got=%08h after %0d polls)",
                         s, w);
                $fatal;
            end
            $display("  uart_tx sentinel reached (waited %0d polls)", w);
        end

        hp_active = 1'b0;

        // Flush any trailing RX bits
        repeat (16) @(posedge sample_clk);

        // Check decoded UART matches expected string byte-by-byte
        ok = 1'b1;
        if (rx_cnt < 15) ok = 1'b0;
        if (received[ 0] !== "H") ok = 1'b0;
        if (received[ 1] !== "e") ok = 1'b0;
        if (received[ 2] !== "l") ok = 1'b0;
        if (received[ 3] !== "l") ok = 1'b0;
        if (received[ 4] !== "o") ok = 1'b0;
        if (received[ 5] !== ",") ok = 1'b0;
        if (received[ 6] !== " ") ok = 1'b0;
        if (received[ 7] !== "A") ok = 1'b0;
        if (received[ 8] !== "t") ok = 1'b0;
        if (received[ 9] !== "t") ok = 1'b0;
        if (received[10] !== "o") ok = 1'b0;
        if (received[11] !== "I") ok = 1'b0;
        if (received[12] !== "O") ok = 1'b0;
        if (received[13] !== 8'h0D) ok = 1'b0;  /* \r */
        if (received[14] !== 8'h0A) ok = 1'b0;  /* \n */

        $write("  decoded: ");
        for (i = 0; i < rx_cnt; i = i + 1) $write("%c", received[i]);
        $display("");

        if (!ok) begin
            $display("FAIL: UART decode mismatch (rx_cnt=%0d)", rx_cnt);
            $fatal;
        end
        $display("  PASS: UART decode OK (%0d bytes)", rx_cnt);

        // hp0 wiggle check
        if (pad_track_err) begin
            $display("FAIL: pad_out[4:2] did not track hp0_out[4:2] during wiggle");
            $fatal;
        end
        $display("  PASS: pad_out[4:2] tracked hp0_out[4:2] across %0d wiggles",
                 wiggle_count);

        $display("ALL COEXIST TESTS PASSED");
        $finish;
    end

    initial begin
        #3_000_000_000 $display("TIMEOUT"); $fatal;
    end

endmodule
