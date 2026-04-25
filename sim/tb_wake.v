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
`include "attoio_variant.vh"

`ifndef FW_HEX
 `define FW_HEX "build/sw/wake_test/wake_test.hex"
`endif

module tb_wake;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    reg         sysclk  = 0;
    reg         clk_iop = 0;
    reg         rst_n   = 0;

    reg  [`AW-1:0] PADDR;
    reg         PSEL;
    reg         PENABLE;
    reg         PWRITE;
    reg  [31:0] PWDATA;
    reg  [3:0]  PSTRB;
    wire [31:0] PRDATA;
    wire        PREADY;
    wire        PSLVERR;

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

    `DUT_MOD u_dut (
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
    task wait_for_mailbox(input [`AW-1:0] addr, input [31:0] expected);
        integer tries;
        reg [31:0] val;
        begin
            tries = 0;
            while (tries < 5000) begin
                apb_read(addr, val);
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

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] rd;

    integer prev_count;

    initial begin
        $dumpfile("tb_wake.vcd");
        $dumpvars(0, tb_wake);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_wake: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(`REG(11'h008), 32'h0, 4'hF);

        // Wait for firmware to reach WFI (sentinel = 0xC0DEC0DE @ mailbox word 2)
        wait_for_mailbox(`MBX(11'h008), 32'hC0DEC0DE);
        $display("  firmware configured wake, now idle in WFI");

        // ---- Test A: rising edge on pad[5] ----
        $display("--- Test A: pad[5] rising edge ---");
        apb_read(`MBX(11'h000), rd); prev_count = rd;
        @(posedge sysclk); pad_in = 16'h0020; // bit 5 = 1
        repeat (1500) @(posedge sysclk);
        apb_read(`MBX(11'h000), rd);
        if (rd === prev_count) begin $display("FAIL: count unchanged after rise on pad[5] (count=%0d)", rd); $fatal; end
        apb_read(`MBX(11'h010), rd);
        if ((rd & 32'h20) != 32'h20) begin
            $display("FAIL: expected bit 5 in WAKE_FLAGS snapshot, got %08h", rd);
            $fatal;
        end
        $display("  PASS: pad[5] rise triggered IRQ, flag[5] set");

        // ---- Test B: falling edge on pad[9] ----
        $display("--- Test B: pad[9] falling edge ---");
        apb_read(`MBX(11'h000), rd); prev_count = rd;
        @(posedge sysclk); pad_in = 16'h0220; // bit 5 still high, bit 9 = 1
        repeat (1500) @(posedge sysclk);        // let pad[9] rise settle (no wake because falling only)
        apb_read(`MBX(11'h000), rd);
        if (rd !== prev_count) begin
            $display("FAIL: wake count bumped on pad[9] rise (falling-only should ignore)");
            $fatal;
        end
        @(posedge sysclk); pad_in = 16'h0020; // bit 9 = 0 (falling)
        repeat (1500) @(posedge sysclk);
        apb_read(`MBX(11'h000), rd);
        if (rd === prev_count) begin $display("FAIL: count unchanged after fall on pad[9]"); $fatal; end
        apb_read(`MBX(11'h010), rd);
        if ((rd & 32'h200) != 32'h200) begin
            $display("FAIL: expected bit 9 in WAKE_FLAGS snapshot, got %08h", rd);
            $fatal;
        end
        $display("  PASS: pad[9] fall triggered IRQ, flag[9] set");

        // ---- Test C: edge on pad[0] (not masked) ----
        $display("--- Test C: pad[0] edges ignored (mask=0) ---");
        apb_read(`MBX(11'h000), rd); prev_count = rd;
        @(posedge sysclk); pad_in = 16'h0021; // add bit 0
        repeat (1500) @(posedge sysclk);
        @(posedge sysclk); pad_in = 16'h0020; // drop bit 0
        repeat (1500) @(posedge sysclk);
        apb_read(`MBX(11'h000), rd);
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
