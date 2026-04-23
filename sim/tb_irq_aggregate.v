/******************************************************************************/
// tb_irq_aggregate — verifies that two IRQ sources (TIMER MATCH0 and
// GPIO WAKE on pad[5]) both feed iop_irq through the macro's flat OR,
// and that a single ISR can dispatch on both by polling status regs.
//
// Strategy:
//   - Wait for the firmware to enter WFI.
//   - Wait for at least 2 timer ticks (proves the timer IRQ path on
//     its own, before the wake source is ever active).
//   - Drive a rising edge on pad[5]; expect the wake counter to bump
//     and the wake-flag snapshot to show bit 5 set.
//   - After each interesting host-visible state change, wait on
//     irq_to_host (set by the ISR's C2H pulse) before reading the
//     mailbox — this avoids the SRAM-B Do0 race documented in
//     tb_irq_doorbell.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/irq_aggregate/irq_aggregate.hex"
`endif

module tb_irq_aggregate;

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

    /* Wait for a fresh irq_to_host edge.  Caller must clear C2H first
     * (or have just cleared it via a previous wait); we wait for it to
     * go high again, then W1C-clear so the next ISR can re-pulse. */
    task wait_for_irq_to_host(input integer max_cycles);
        integer waited;
        begin
            waited = 0;
            while (irq_to_host !== 1'b1 && waited < max_cycles) begin
                @(posedge sysclk);
                waited = waited + 1;
            end
            if (irq_to_host !== 1'b1) begin
                $display("FAIL: irq_to_host never asserted (waited %0d sysclk)",
                         waited);
                $fatal;
            end
            apb_write(11'h704, 32'h00000001, 4'hF);   /* W1C C2H */
        end
    endtask

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] rd;
    reg [31:0] timer_a, timer_b;
    reg [31:0] wake_a, wake_b;

    initial begin
        $dumpfile("tb_irq_aggregate.vcd");
        $dumpvars(0, tb_irq_aggregate);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_irq_aggregate: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed both IRQ sources, now in WFI");

        // ---------------------------------------------------------------
        // Phase A: timer alone — wait for several ticks
        // ---------------------------------------------------------------
        $display("--- Phase A: timer ticks (no WAKE active yet) ---");
        /* Drain a few C2H pulses (one per tick) and confirm the
         * timer counter advanced. */
        wait_for_irq_to_host(200000);
        wait_for_irq_to_host(200000);
        wait_for_irq_to_host(200000);
        apb_read(11'h600, timer_a);
        apb_read(11'h604, wake_a);
        $display("  after 3 C2H pulses: timer_count=%0d wake_count=%0d",
                 timer_a, wake_a);
        if (timer_a < 3) begin
            $display("FAIL: timer_count too low (=%0d, expected >=3)", timer_a);
            $fatal;
        end
        if (wake_a !== 0) begin
            $display("FAIL: wake_count nonzero before pad[5] edge (=%0d)", wake_a);
            $fatal;
        end

        // ---------------------------------------------------------------
        // Phase B: drive a rising edge on pad[5] → wake source fires
        // ---------------------------------------------------------------
        $display("--- Phase B: rising edge on pad[5] ---");
        @(posedge sysclk); pad_in = 16'h0020;   /* bit 5 high */

        /* Wait for the WAKE-handling ISR specifically.  We may absorb
         * 1-2 timer ticks first (those also pulse C2H); keep draining
         * until wake_count goes positive. */
        begin : drain_until_wake
            integer tries;
            tries = 0;
            while (tries < 10) begin
                wait_for_irq_to_host(200000);
                repeat (10) @(posedge sysclk);
                apb_read(11'h604, wake_b);
                if (wake_b > 0) disable drain_until_wake;
                tries = tries + 1;
            end
            $display("FAIL: wake_count never advanced after pad[5] edge");
            $fatal;
        end

        apb_read(11'h610, rd);
        if ((rd & 32'h20) !== 32'h20) begin
            $display("FAIL: WAKE_FLAGS snap missing bit 5 (got %08h)", rd);
            $fatal;
        end
        $display("  PASS: wake_count=%0d, snap[5]=1", wake_b);

        // ---------------------------------------------------------------
        // Phase C: confirm timer keeps firing after the wake event
        // ---------------------------------------------------------------
        $display("--- Phase C: timer keeps ticking after wake ---");
        apb_read(11'h600, timer_a);
        wait_for_irq_to_host(200000);
        wait_for_irq_to_host(200000);
        repeat (10) @(posedge sysclk);
        apb_read(11'h600, timer_b);
        if (!(timer_b > timer_a)) begin
            $display("FAIL: timer counter stuck after wake (a=%0d b=%0d)",
                     timer_a, timer_b);
            $fatal;
        end
        $display("  timer advanced %0d -> %0d after wake", timer_a, timer_b);

        $display("PASS: TIMER MATCH0 + GPIO WAKE both feed iop_irq, ISR dispatches both");
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
