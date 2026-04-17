/******************************************************************************/
// tb_wdt — validates the watchdog block end-to-end.
//
// Sequence:
//   1. Load wdt_test firmware; release reset.
//   2. Poll mailbox[0] for 0xAAAA0001 (firmware finished its 3 successful
//      pets). Failing to see it means the WDT fired prematurely.
//   3. Wait for mailbox[0] == 0xAAAA0002 (WDT expired, ISR ran).
//   4. Observe that irq_to_host pulsed at least once during the wait.
//   5. Read mailbox[4] (nmi_count) = 1 and mailbox[6] & 1 = expired bit.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/wdt_test/wdt_test.hex"
`endif

module tb_wdt;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    reg         sysclk  = 0;
    reg         clk_iop = 0;
    reg         rst_n   = 0;

    reg  [9:0]  host_addr;
    reg  [31:0] host_wdata;
    reg  [3:0]  host_wmask;
    reg         host_wen;
    reg         host_ren;
    wire [31:0] host_rdata;
    wire        host_ready;

    reg  [15:0] pad_in = 0;
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
        .host_addr(host_addr), .host_wdata(host_wdata), .host_wmask(host_wmask),
        .host_wen(host_wen), .host_ren(host_ren),
        .host_rdata(host_rdata), .host_ready(host_ready),
        .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe), .pad_ctl(pad_ctl),
        .irq_to_host(irq_to_host)
    );

    // --------------------------------------------------------------
    // Host-side IRQ pulse detector
    // --------------------------------------------------------------
    reg        irq_seen;
    reg        irq_prev;
    initial begin irq_seen = 1'b0; irq_prev = 1'b0; end
    always @(posedge sysclk) begin
        if (irq_to_host && !irq_prev)
            irq_seen <= 1'b1;
        irq_prev <= irq_to_host;
    end

    task host_write(input [9:0] addr, input [31:0] data);
        begin
            @(posedge sysclk); #1;
            host_addr = addr; host_wdata = data;
            host_wmask = 4'hF; host_wen = 1'b1; host_ren = 1'b0;
            @(posedge sysclk); #1;
            host_wen = 1'b0; host_wmask = 4'h0;
        end
    endtask

    task host_read(input [9:0] addr, output [31:0] data);
        begin
            @(posedge sysclk); #1;
            host_addr = addr; host_ren = 1'b1; host_wen = 1'b0;
            @(posedge sysclk); #1;
            host_ren = 1'b0;
            @(posedge sysclk); #1;
            data = host_rdata;
        end
    endtask

    task wait_for_mailbox(input [9:0] addr, input [31:0] expected);
        integer tries;
        reg [31:0] val;
        begin
            tries = 0;
            while (tries < 10000) begin
                host_read(addr, val);
                if (val === expected) begin
                    $display("  mailbox @0x%03h = %08h  (waited %0d reads)", addr, val, tries);
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
        $dumpfile("tb_wdt.vcd");
        $dumpvars(0, tb_wdt);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        host_addr = 0; host_wdata = 0; host_wmask = 0;
        host_wen  = 0; host_ren  = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_wdt: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            host_write(i * 4, fw_image[i]);

        $display("--- releasing IOP reset ---");
        host_write(10'h308, 32'h0);

        // --- Phase 1: firmware pets WDT 3x then reports success. ---
        wait_for_mailbox(10'h200, 32'hAAAA0001);
        $display("  PASS phase 1: firmware pet WDT 3x without expire");

        // --- Phase 2: firmware stops petting -> WDT expires ---
        wait_for_mailbox(10'h200, 32'hAAAA0002);
        $display("  PASS phase 2: WDT expired, ISR ran");

        // Verify irq_to_host was asserted
        if (!irq_seen) begin
            $display("FAIL: irq_to_host never pulsed during expire");
            $fatal;
        end
        $display("  PASS: irq_to_host pulsed to the host");

        host_read(10'h210, rd);  // mailbox[4]
        if (rd !== 32'd1) begin
            $display("FAIL: nmi_count = %0d, expected 1", rd);
            $fatal;
        end
        $display("  PASS: nmi_count = 1");

        host_read(10'h218, rd);  // mailbox[6]
        if ((rd & 32'h1) !== 32'h1) begin
            $display("FAIL: WDT_STATUS snapshot did not show expired (got %08h)", rd);
            $fatal;
        end
        $display("  PASS: WDT_STATUS.expired was set in ISR snapshot");

        $display("ALL WDT TESTS PASSED");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
