/******************************************************************************/
// tb_rpc — end-to-end test of the Phase H15 minimum RPC.
//
// Boots the rpc_demo firmware, then drives the APB as a pretend host to:
//   1. SYS.ping     — validates round-trip + version reply
//   2. PADCTL.set   — validates PADCTL register is actually written
//   3. PADCTL.get   — validates reply field in mbox[2]
//   4. INIT.gpio    — validates GPIO_OUT/OE bulk preset
//   5. Invalid op   — validates ENOTSUP path
//   6. Invalid pin  — validates EINVAL path
/******************************************************************************/

`timescale 1ns/1ps

module tb_rpc;

    reg         sysclk = 0;
    reg         clk_iop = 0;
    reg         rst_n = 0;

    reg  [10:0] PADDR = 0;
    reg         PSEL = 0, PENABLE = 0, PWRITE = 0;
    reg  [31:0] PWDATA = 0;
    reg  [3:0]  PSTRB = 0;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERR;

    reg  [15:0]  pad_in = 16'h0;
    wire [15:0]  pad_out, pad_oe;
    wire [127:0] pad_ctl;

    wire irq_to_host;

    always #5 sysclk = ~sysclk;
    localparam CLK_DIV = 2;
    reg [2:0] div_cnt = 0;
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

    // ---------- APB driver ----------
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

    // Mailbox helpers (host-visible mailbox is at PADDR 0x600)
    task mbx_write(input [4:0] wi, input [31:0] d);
        apb_write(11'h600 + (wi << 2), d, 4'hF);
    endtask
    task mbx_read(input [4:0] wi, output [31:0] d);
        apb_read(11'h600 + (wi << 2), d);
    endtask

    // ---------- RPC helper ----------
    localparam [31:0] RPC_REQ = 32'hA5A5_A5A5;
    localparam [31:0] RPC_ACK = 32'h0;

    // Complete an RPC call and collect status + reply.  Polls DOORBELL_C2H
    // (in attoio_ctrl, not SRAM B) to avoid starving the IOP's SRAM B
    // writes while it's trying to commit the ACK/status.
    task rpc_call(input [7:0] grp, input [7:0] op,
                  input [31:0] a0, input [31:0] a1,
                  output [31:0] status, output [31:0] r0);
        integer waited;
        reg [31:0] db_c2h;
        begin
            mbx_write(5'd2, a0);
            mbx_write(5'd3, a1);
            mbx_write(5'd1, {8'h01, 8'h00, grp, op});
            mbx_write(5'd0, RPC_REQ);                  // sentinel LAST
            apb_write(11'h700, 32'h1, 4'hF);           // ring HOST_DOORBELL

            // Wait for DOORBELL_C2H (IOP -> host) to go high.
            waited = 0;
            db_c2h = 32'h0;
            while (!db_c2h[0] && waited < 2000) begin
                apb_read(11'h704, db_c2h);             // DOORBELL_C2H
                waited = waited + 1;
            end
            if (!db_c2h[0]) begin
                $display("FAIL: rpc grp=%0h op=%0h: no C2H doorbell", grp, op);
                $fatal;
            end
            // Collect status + reply, then W1C the C2H bit.
            mbx_read(5'd31, status);
            mbx_read(5'd2,  r0);
            apb_write(11'h704, 32'h1, 4'hF);           // W1C DOORBELL_C2H
        end
    endtask

    task expect_eq32(input [255:0] label, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s  got=%08h  exp=%08h", label, got, exp);
                $fatal;
            end
        end
    endtask

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] status, reply, padctl_word;

    initial begin
        $dumpfile("tb_rpc.vcd");
        $dumpvars(0, tb_rpc);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_rpc: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);   // IOP_CTRL.reset = 0

        // Wait for firmware live sentinel (mbox[30])
        begin : wait_boot
            integer waited;
            reg [31:0] sentinel;
            waited = 0; sentinel = 0;
            while (sentinel !== 32'hC0DEC0DE && waited < 5000) begin
                mbx_read(5'd30, sentinel);
                waited = waited + 1;
            end
            if (sentinel !== 32'hC0DEC0DE) begin
                $display("FAIL: firmware didn't boot (sentinel=%08h)", sentinel);
                $fatal;
            end
            $display("  IOP firmware boot confirmed (waited %0d polls)", waited);
        end

        // ---------------- PHASE 1: SYS.ping ----------------
        rpc_call(8'h01, 8'h01, 32'h0, 32'h0, status, reply);
        expect_eq32("SYS.ping status",  status, 32'h0);
        expect_eq32("SYS.ping version", reply,  32'h01000000);
        $display("  PASS: SYS.ping -> v%08h", reply);

        // ---------------- PHASE 2: PADCTL.set ----------------
        rpc_call(8'h02, 8'h01, 32'd3, 32'hA5, status, reply);
        expect_eq32("PADCTL.set status", status, 32'h0);
        // Verify PADCTL[3] is actually 0xA5 via the flat pad_ctl bus
        if (pad_ctl[3*8 +: 8] !== 8'hA5) begin
            $display("FAIL: pad_ctl[3] = %02h, expected A5", pad_ctl[3*8 +: 8]);
            $fatal;
        end
        $display("  PASS: PADCTL.set(pin=3, flags=0xA5) verified on pad_ctl");

        // ---------------- PHASE 3: PADCTL.get ----------------
        rpc_call(8'h02, 8'h02, 32'd3, 32'h0, status, reply);
        expect_eq32("PADCTL.get status", status, 32'h0);
        expect_eq32("PADCTL.get reply",  reply,  32'hA5);
        $display("  PASS: PADCTL.get(pin=3) = %02h", reply);

        // ---------------- PHASE 4: INIT.gpio ----------------
        rpc_call(8'h03, 8'h01, 32'hF00F, 32'h00FF, status, reply);
        expect_eq32("INIT.gpio status", status, 32'h0);
        // Allow a few clk_iop cycles for the write to settle on the pad bus
        repeat (8) @(posedge sysclk);
        expect_eq32("GPIO_OUT propagation", {16'h0, pad_out & pad_oe}, 32'h000F);
        expect_eq32("GPIO_OE propagation",  {16'h0, pad_oe},           32'h00FF);
        $display("  PASS: INIT.gpio sets OUT+OE");

        // ---------------- PHASE 5: bad op ----------------
        rpc_call(8'h01, 8'hFE, 32'h0, 32'h0, status, reply);
        expect_eq32("bad op returns ENOTSUP", status, 32'h2);
        $display("  PASS: unknown op -> ENOTSUP");

        // ---------------- PHASE 6: bad pin ----------------
        rpc_call(8'h02, 8'h01, 32'd99, 32'h0, status, reply);
        expect_eq32("pin >= NGPIO returns EINVAL", status, 32'h1);
        $display("  PASS: out-of-range pin -> EINVAL");

        $display("ALL RPC TESTS PASSED");
        $finish;
    end

    initial begin
        #50_000_000 $display("TIMEOUT"); $fatal;
    end

endmodule
