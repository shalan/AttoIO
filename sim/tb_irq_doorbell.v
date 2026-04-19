/******************************************************************************/
// tb_irq_doorbell — verifies the host → IOP doorbell IRQ path:
//   APB write to host-side DOORBELL_H2C (byte 0x700, W1S) sets the
//   doorbell bit, which is wired into iop_irq via attoio_ctrl.  The
//   firmware's __isr W1Cs the bit (via IOP-view MMIO 0x780), records
//   data in the mailbox, and pulses DOORBELL_C2H so the host can
//   safely inspect the mailbox once the ISR is done.
//
// We deliberately wait on `irq_to_host` (driven by C2H) instead of
// polling mailbox[0]: tight host APB polling of SRAM B during the
// IOP's ISR can clobber the shared sram_b0_do0 latch (a known RTL
// arbitration race), causing the IOP's mailbox loads to return wrong
// values.  Real software using this hardware should follow the same
// "IRQ-to-host then read" pattern.
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

    /* (Earlier debug: probing u_dut.u_sram_b0.mem[*] and
     * u_dut.sram_b0_do0 around an ISR load is what surfaced the SRAM B
     * Do0 race documented in docs/known_bugs.md BUG-001.  See the
     * commit history for the full instrumentation.) */
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

    /* Wait for irq_to_host to assert (i.e. firmware raised C2H), then
     * W1C-clear it on the host side so the next ring can re-arm.
     * Done in clk-cycle terms (no APB poll) so we never touch SRAM B
     * while the IOP is mid-ISR. */
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
            $display("  irq_to_host asserted (waited %0d sysclk)", waited);
            /* W1C-clear C2H from the host side (host word 1 = byte 0x704). */
            apb_write(11'h704, 32'h00000001, 4'hF);
        end
    endtask

    reg [31:0] fw_image [0:383];
    integer i;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_irq_doorbell.vcd");
        $dumpvars(0, tb_irq_doorbell);

        for (i = 0; i < 384; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_irq_doorbell: loading firmware ---");
        for (i = 0; i < 384; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed MIE, now in WFI");

        // -------------------------------------------------------------
        // Ring 1
        // -------------------------------------------------------------
        $display("--- Ring 1: stage cmd 0xCAFE0001, then write H2C=1 ---");
        apb_write(11'h640, 32'hCAFE0001, 4'hF);
        repeat (50) @(posedge sysclk);
        apb_write(11'h700, 32'h00000001, 4'hF);

        wait_for_irq_to_host(5000);
        repeat (10) @(posedge sysclk);

        apb_read(11'h600, rd);
        if (rd !== 32'h00000001) begin
            $display("FAIL: count = %08h (expected 1)", rd); $fatal;
        end
        apb_read(11'h610, rd);
        if ((rd & 32'h1) !== 32'h1) begin
            $display("FAIL: snapshot didn't see H2C bit (got %08h)", rd); $fatal;
        end
        apb_read(11'h618, rd);
        if (rd !== 32'hCAFE0001) begin
            $display("FAIL: cmd echo wrong (got %08h)", rd); $fatal;
        end
        apb_read(11'h700, rd);
        if (rd[0] !== 1'b0) begin
            $display("FAIL: H2C still set after ISR (got %08h)", rd); $fatal;
        end
        $display("  PASS Ring 1: count=1, snapshot ok, cmd echoed, H2C cleared");

        // -------------------------------------------------------------
        // Ring 2
        // -------------------------------------------------------------
        $display("--- Ring 2: stage cmd 0xBEEF0002, then write H2C=1 ---");
        apb_write(11'h640, 32'hBEEF0002, 4'hF);
        repeat (50) @(posedge sysclk);
        apb_write(11'h700, 32'h00000001, 4'hF);

        wait_for_irq_to_host(5000);
        repeat (10) @(posedge sysclk);

        apb_read(11'h600, rd);
        if (rd !== 32'h00000002) begin
            $display("FAIL: count = %08h (expected 2)", rd); $fatal;
        end
        apb_read(11'h618, rd);
        if (rd !== 32'hBEEF0002) begin
            $display("FAIL: Ring 2 cmd echo wrong (got %08h)", rd); $fatal;
        end
        $display("  PASS Ring 2: count=2, cmd echoed");

        $display("PASS: DOORBELL_H2C drove iop_irq through both rings");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
