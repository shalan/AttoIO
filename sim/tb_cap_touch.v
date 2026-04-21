/******************************************************************************/
// tb_cap_touch — E21.  Emulates two capacitive sensors by scheduling
// delayed rising edges on pad_in[0] and pad_in[1] after the FW
// releases each pad (OE→0).  pad[0] gets a short delay (no touch),
// pad[1] gets a long delay (simulated touch).
//
// FW is expected to:
//   - measure a small count for pad[0] (below threshold → "not touched")
//   - measure a large count for pad[1] (above threshold → "touched")
//   - publish touched_mask = 0b10 in mailbox[4]
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/cap_touch/cap_touch.hex"
`endif

module tb_cap_touch;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    /* R-C rise delays per sensor, in ns.  Loop iteration in the FW
     * takes ~600 ns on this serial-shift core (GPIO_IN load + compare
     * + branch + increment), so pick delays that give well-separated
     * measured counts: A ≈ 2, B ≈ 80. */
    parameter integer RISE_A_NS = 1500;   /* no-touch */
    parameter integer RISE_B_NS = 50000;  /* touched  */

    reg         sysclk  = 0;
    reg         clk_iop = 0;
    reg         rst_n   = 0;

    reg  [10:0] PADDR;
    reg         PSEL, PENABLE, PWRITE;
    reg  [31:0] PWDATA;
    reg  [3:0]  PSTRB;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERR;

    reg  [15:0] pad_in = 16'h0000;   /* start LOW so "discharged" state matches */
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

    /* Emulate sensor rise after release: on negedge pad_oe, force the
     * input LOW (discharged state the FW's pre-charge drove it to),
     * then after the R-C time constant drive it HIGH.  No posedge
     * handler needed — FW drives OE high during pre-charge; whatever
     * pad_in is during that phase doesn't matter since the next
     * negedge resets it. */
    always @(negedge pad_oe[0]) begin
        pad_in[0] = 1'b0;
        #(RISE_A_NS);
        pad_in[0] = 1'b1;
    end

    always @(negedge pad_oe[1]) begin
        pad_in[1] = 1'b0;
        #(RISE_B_NS);
        pad_in[1] = 1'b1;
    end

    reg [31:0] fw_image [0:127];
    integer i;
    reg [31:0] count_a, count_b, mask;

    initial begin
        $dumpfile("tb_cap_touch.vcd");
        $dumpvars(0, tb_cap_touch);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_cap_touch: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h600, 32'h1, 100000);
        $display("  firmware finished cap-touch measurement");

        apb_read(11'h604, count_a);
        apb_read(11'h60C, count_b);
        apb_read(11'h610, mask);

        $display("  sensor A count = %0d  (low, not touched)",  count_a);
        $display("  sensor B count = %0d  (high, touched)",     count_b);
        $display("  touched mask   = 0b%b  (expect 0b10)",      mask[1:0]);

        /* Sensor separation matters more than absolute counts — the
         * real-world threshold would be empirically calibrated.
         * Require B's count to be at least 5× A's so the
         * discrimination is robust. */
        if (count_a > 5) begin
            $display("FAIL: sensor A count %0d too high — should indicate no touch",
                     count_a);
            $fatal;
        end
        if (count_b < count_a * 5 + 5) begin
            $display("FAIL: sensor B (%0d) not sufficiently separated from A (%0d)",
                     count_b, count_a);
            $fatal;
        end
        if (mask[1:0] !== 2'b10) begin
            $display("FAIL: touched mask wrong — expected 0b10 (B only), got 0b%b",
                     mask[1:0]);
            $fatal;
        end

        $display("PASS: cap-touch discrimination — B touched (count=%0d), A not touched (count=%0d)",
                 count_b, count_a);
        $finish;
    end

    initial begin
        #2000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
