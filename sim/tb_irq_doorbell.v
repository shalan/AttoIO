/******************************************************************************/
// tb_irq_doorbell — verifies the host → IOP doorbell IRQ path:
//   APB write to host-side DOORBELL_H2C (byte 0x700, W1S) sets the
//   doorbell bit, which is wired into iop_irq via attoio_ctrl.  The
//   firmware's __isr W1Cs the bit (via IOP-view MMIO 0x780), reads a
//   host-staged command word from mailbox[16], and echoes it.
//
// This test deliberately polls mailbox[0] from the host side while
// the ISR runs and reads SRAM B — exactly the access pattern that
// surfaced BUG-001.  A clean PASS confirms the BUG-001 fix in
// attoio_memmux.v (the SRAM B Do0 capture latch) is working.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/irq_doorbell/irq_doorbell.hex"
`endif

module tb_irq_doorbell;

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

    reg [31:0] fw_image [0:127];
    integer i;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_irq_doorbell.vcd");
        $dumpvars(0, tb_irq_doorbell);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_irq_doorbell: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed MIE, now in WFI");

        // -------------------------------------------------------------
        // Ring 1 — host stages cmd, rings doorbell, polls count
        // -------------------------------------------------------------
        $display("--- Ring 1: stage cmd 0xCAFE0001, then write H2C=1 ---");
        apb_write(11'h640, 32'hCAFE0001, 4'hF);
        apb_write(11'h700, 32'h00000001, 4'hF);

        /* Tight polling — exactly the BUG-001 reproducer pattern. */
        wait_for_mailbox(11'h600, 32'h00000001, 5000);

        apb_read(11'h610, rd);
        if ((rd & 32'h1) !== 32'h1) begin
            $display("FAIL: snapshot didn't see H2C bit set (got %08h)", rd);
            $fatal;
        end
        apb_read(11'h618, rd);
        if (rd !== 32'hCAFE0001) begin
            $display("FAIL: cmd echo wrong (got %08h, expected cafe0001)", rd);
            $fatal;
        end
        apb_read(11'h700, rd);
        if (rd[0] !== 1'b0) begin
            $display("FAIL: H2C still set after ISR (got %08h)", rd);
            $fatal;
        end
        $display("  PASS Ring 1: count=1, snap ok, cmd echoed, H2C cleared");

        // -------------------------------------------------------------
        // Ring 2 — different cmd, same polling pattern
        // -------------------------------------------------------------
        $display("--- Ring 2: stage cmd 0xBEEF0002, then write H2C=1 ---");
        apb_write(11'h640, 32'hBEEF0002, 4'hF);
        apb_write(11'h700, 32'h00000001, 4'hF);

        wait_for_mailbox(11'h600, 32'h00000002, 5000);
        apb_read(11'h618, rd);
        if (rd !== 32'hBEEF0002) begin
            $display("FAIL: Ring 2 cmd echo wrong (got %08h)", rd);
            $fatal;
        end
        $display("  PASS Ring 2: count=2, cmd echoed");

        $display("PASS: DOORBELL_H2C drove iop_irq through both rings (BUG-001 fix verified)");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
