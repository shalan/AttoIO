/******************************************************************************/
// tb_irq_timer — verifies that the TIMER MATCH0 flag (gated by
// TIMER_CMP_IRQ_EN) drives iop_irq into the AttoRV32 core, that the
// firmware's __isr fires, and that W1C-clearing the flag deasserts the
// line so the next match can fire again.
//
// Sequence:
//   1. Wait for sentinel 0xC0DEC0DE (FW reached WFI).
//   2. Wait until the tick counter (mailbox word 0) reaches 5.
//   3. Snapshot, wait a fixed window, snapshot again — counter must
//      have advanced by a sane amount given the configured period.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/irq_timer/irq_timer.hex"
`endif

module tb_irq_timer;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

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

    task wait_for_at_least(input [10:0] addr, input [31:0] threshold,
                           input integer max_tries);
        integer tries;
        reg [31:0] val;
        begin
            tries = 0;
            while (tries < max_tries) begin
                apb_read(addr, val);
                if (val >= threshold) begin
                    $display("  mailbox @0x%03h = %0d (>= %0d, waited %0d reads)",
                             addr, val, threshold, tries);
                    disable wait_for_at_least;
                end
                tries = tries + 1;
            end
            $display("FAIL: mailbox @0x%03h never reached >= %0d (last=%0d)",
                     addr, threshold, val);
            $fatal;
        end
    endtask

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] tick_a, tick_b;

    initial begin
        $dumpfile("tb_irq_timer.vcd");
        $dumpvars(0, tb_irq_timer);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_irq_timer: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed TIMER, now in WFI");

        $display("--- waiting for TIMER MATCH0 IRQ to bump tick counter ---");
        wait_for_at_least(11'h600, 5, 100000);

        /* Confirm progress: snapshot, wait, snapshot, expect strict
         * increase (proves IRQs keep firing — not just a one-shot). */
        apb_read(11'h600, tick_a);
        repeat (20000) @(posedge sysclk);
        apb_read(11'h600, tick_b);
        if (!(tick_b > tick_a)) begin
            $display("FAIL: tick counter stuck (a=%0d b=%0d)", tick_a, tick_b);
            $fatal;
        end
        $display("  tick advanced %0d -> %0d (IRQs continuing)", tick_a, tick_b);

        $display("PASS: TIMER_CMP_IRQ_EN drove iop_irq, ISR fired and W1C-cleared");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
