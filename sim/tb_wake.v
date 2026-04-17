/******************************************************************************/
// tb_wake — validates the per-pin wake system.
//
// Sequence:
//   1. Load wake_test firmware, release reset.
//   2. Wait until firmware writes C0DEC0DE sentinel to mailbox[2] (word 2
//      = byte 0x208). That proves the firmware has configured WAKE_MASK
//      and WAKE_EDGE and entered WFI.
//   3. Drive a rising edge on pad[5]. Expect:
//        mailbox[0] (word count) > 0,
//        mailbox[4] contains bit 5 set.
//   4. Drive a falling edge on pad[9]. Expect:
//        mailbox[0] increments,
//        mailbox[4] contains bit 9 set.
//   5. Drive an edge on pad[0] (not enabled). Expect mailbox[0] unchanged.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/wake_test/wake_test.hex"
`endif

module tb_wake;

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
            while (tries < 5000) begin
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

    integer prev_count;

    initial begin
        $dumpfile("tb_wake.vcd");
        $dumpvars(0, tb_wake);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        host_addr = 0; host_wdata = 0; host_wmask = 0;
        host_wen  = 0; host_ren  = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_wake: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            host_write(i * 4, fw_image[i]);

        $display("--- releasing IOP reset ---");
        host_write(10'h308, 32'h0);

        // Wait for firmware to reach WFI (sentinel = 0xC0DEC0DE @ mailbox word 2)
        wait_for_mailbox(10'h208, 32'hC0DEC0DE);
        $display("  firmware configured wake, now idle in WFI");

        // ---- Test A: rising edge on pad[5] ----
        $display("--- Test A: pad[5] rising edge ---");
        host_read(10'h200, rd); prev_count = rd;
        @(posedge sysclk); pad_in = 16'h0020; // bit 5 = 1
        repeat (1500) @(posedge sysclk);
        host_read(10'h200, rd);
        if (rd === prev_count) begin $display("FAIL: count unchanged after rise on pad[5] (count=%0d)", rd); $fatal; end
        host_read(10'h210, rd);
        if ((rd & 32'h20) != 32'h20) begin
            $display("FAIL: expected bit 5 in WAKE_FLAGS snapshot, got %08h", rd);
            $fatal;
        end
        $display("  PASS: pad[5] rise triggered IRQ, flag[5] set");

        // ---- Test B: falling edge on pad[9] ----
        $display("--- Test B: pad[9] falling edge ---");
        host_read(10'h200, rd); prev_count = rd;
        @(posedge sysclk); pad_in = 16'h0220; // bit 5 still high, bit 9 = 1
        repeat (1500) @(posedge sysclk);        // let pad[9] rise settle (no wake because falling only)
        host_read(10'h200, rd);
        if (rd !== prev_count) begin
            $display("FAIL: wake count bumped on pad[9] rise (falling-only should ignore)");
            $fatal;
        end
        @(posedge sysclk); pad_in = 16'h0020; // bit 9 = 0 (falling)
        repeat (1500) @(posedge sysclk);
        host_read(10'h200, rd);
        if (rd === prev_count) begin $display("FAIL: count unchanged after fall on pad[9]"); $fatal; end
        host_read(10'h210, rd);
        if ((rd & 32'h200) != 32'h200) begin
            $display("FAIL: expected bit 9 in WAKE_FLAGS snapshot, got %08h", rd);
            $fatal;
        end
        $display("  PASS: pad[9] fall triggered IRQ, flag[9] set");

        // ---- Test C: edge on pad[0] (not masked) ----
        $display("--- Test C: pad[0] edges ignored (mask=0) ---");
        host_read(10'h200, rd); prev_count = rd;
        @(posedge sysclk); pad_in = 16'h0021; // add bit 0
        repeat (1500) @(posedge sysclk);
        @(posedge sysclk); pad_in = 16'h0020; // drop bit 0
        repeat (1500) @(posedge sysclk);
        host_read(10'h200, rd);
        if (rd !== prev_count) begin
            $display("FAIL: wake count bumped on pad[0] edges (mask=0 should ignore); count=%0d prev=%0d", rd, prev_count);
            $fatal;
        end
        $display("  PASS: pad[0] edges ignored (mask=0)");

        $display("ALL WAKE TESTS PASSED");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
