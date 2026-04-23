/******************************************************************************/
// tb_macro_hazard_isr — BUG-002 isolation step 4.
//
// Same store sequence as tb_macro_hazard, but this time the stores
// run inside an __isr fired by a host-side H2C doorbell.  The only
// thing that changes vs the step-2 TB is the INTERRUPT CONTEXT (crt0
// saves 8 regs to stack in SRAM A, then the ISR body runs, then
// restores + mret).
//
// If mailbox[3/5/7] drop here and they landed in tb_macro_hazard,
// the bug is specifically about the interrupt entry/exit interacting
// with back-to-back SRAM B stores.
//
// Two modes via +define+:
//   default    : ring the doorbell once, wait quietly, check mailbox
//   +POLL_HOST : host polls mailbox[2] sentinel after ringing
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/core_hazard_isr/core_hazard_isr.hex"
`endif

module tb_macro_hazard_isr;

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

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_macro_hazard_isr.vcd");
        $dumpvars(0, tb_macro_hazard_isr);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_macro_hazard_isr: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        /* Let the FW arm MIE and drop into WFI. */
        repeat (200) @(posedge sysclk);

        $display("--- ringing H2C doorbell (forces ISR context) ---");
        apb_write(11'h700, 32'h00000001, 4'hF);

`ifdef POLL_HOST
        $display("--- MODE: host polls mailbox[2] sentinel concurrently ---");
        begin : poll_loop
            integer tries;
            tries = 0;
            while (tries < 20000) begin
                apb_read(11'h608, rd);
                if (rd === 32'hC0DEC0DE) begin
                    $display("  sentinel observed after %0d polls", tries);
                    disable poll_loop;
                end
                tries = tries + 1;
            end
            $display("FAIL: sentinel never observed (last %08h)", rd);
            $fatal;
        end
`else
        $display("--- MODE: quiet host, just wait ---");
        repeat (20000) @(posedge sysclk);
`endif

        $display("");
        $display("================= Mailbox snapshot =================");
        apb_read(11'h600, rd); $display("  mailbox[0] = %08h  (expect AA01BEEF)", rd);
        apb_read(11'h604, rd); $display("  mailbox[1] = %08h  (expect AA02BEEF)", rd);
        apb_read(11'h608, rd); $display("  mailbox[2] = %08h  (expect C0DEC0DE)", rd);
        apb_read(11'h60C, rd); $display("  mailbox[3] = %08h  (expect AA03BEEF)  <-- BUG-002 edge", rd);
        apb_read(11'h614, rd); $display("  mailbox[5] = %08h  (expect AA05BEEF)", rd);
        apb_read(11'h61C, rd); $display("  mailbox[7] = %08h  (expect AA07BEEF)", rd);
        $display("----------------------------------------------------");

        begin : final_check
            integer bad;
            reg [31:0] got;
            bad = 0;
            apb_read(11'h600, got); if (got !== 32'hAA01BEEF) bad = bad + 1;
            apb_read(11'h604, got); if (got !== 32'hAA02BEEF) bad = bad + 1;
            apb_read(11'h608, got); if (got !== 32'hC0DEC0DE) bad = bad + 1;
            apb_read(11'h60C, got); if (got !== 32'hAA03BEEF) bad = bad + 1;
            apb_read(11'h614, got); if (got !== 32'hAA05BEEF) bad = bad + 1;
            apb_read(11'h61C, got); if (got !== 32'hAA07BEEF) bad = bad + 1;
            if (bad == 0) $display("PASS: all 6 mailbox slots correct");
            else          $display("FAIL: %0d mailbox slot(s) wrong", bad);
        end

        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
