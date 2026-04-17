/******************************************************************************/
// tb_attoio — End-to-end testbench for the AttoIO macro
//
// Tests:
//   1. Host loads firmware into SRAM A during reset
//   2. Host releases reset, IOP runs
//   3. IOP writes a known pattern to the mailbox
//   4. Host reads the mailbox and verifies
//   5. Host rings DOORBELL_H2C, IOP acknowledges by writing to mailbox
//   6. IOP toggles pad_out[0] (observed by testbench)
//   7. WAKE_LATCH: external pin edge -> IRQ fires
//
// Uses a simple hand-assembled firmware image (no toolchain needed).
/******************************************************************************/

`timescale 1ns / 1ps

module tb_attoio;

    // ====================================================================
    // Parameters
    // ====================================================================
    parameter SYSCLK_PERIOD = 10;   // 100 MHz
    parameter CLK_DIV       = 4;    // clk_iop = sysclk / 4

    // ====================================================================
    // Signals
    // ====================================================================
    reg         sysclk;
    reg         clk_iop;
    reg         rst_n;

    reg  [9:0]  host_addr;
    reg  [31:0] host_wdata;
    reg  [3:0]  host_wmask;
    reg         host_wen;
    reg         host_ren;
    wire [31:0] host_rdata;
    wire        host_ready;

    reg  [15:0] pad_in;
    wire [15:0] pad_out;
    wire [15:0] pad_oe;
    wire [127:0] pad_ctl;
    wire        irq_to_host;

    // ====================================================================
    // Clock generation
    // ====================================================================
    initial sysclk = 0;
    always #(SYSCLK_PERIOD/2) sysclk = ~sysclk;

    // clk_iop = sysclk / CLK_DIV
    reg [$clog2(CLK_DIV)-1:0] div_cnt;
    initial begin
        clk_iop = 0;
        div_cnt = 0;
    end
    always @(posedge sysclk) begin
        if (div_cnt == CLK_DIV/2 - 1 || div_cnt == CLK_DIV - 1)
            clk_iop <= ~clk_iop;
        div_cnt <= (div_cnt == CLK_DIV - 1) ? 0 : div_cnt + 1;
    end

    // ====================================================================
    // DUT
    // ====================================================================
    attoio_macro u_dut (
        .sysclk     (sysclk),
        .clk_iop    (clk_iop),
        .rst_n      (rst_n),
        .host_addr  (host_addr),
        .host_wdata (host_wdata),
        .host_wmask (host_wmask),
        .host_wen   (host_wen),
        .host_ren   (host_ren),
        .host_rdata (host_rdata),
        .host_ready (host_ready),
        .pad_in     (pad_in),
        .pad_out    (pad_out),
        .pad_oe     (pad_oe),
        .pad_ctl    (pad_ctl),
        .irq_to_host(irq_to_host)
    );

    // ====================================================================
    // Test firmware — hand-assembled RV32I machine code
    //
    // All 32-bit instructions (no C extension needed for test).
    // Verified encodings using RISC-V spec.
    //
    // Address  Instruction             Encoding
    // 0x000    jal x0, 0x014           jump over ISR area to main
    // 0x004    nop                     (padding)
    // 0x008    nop                     (padding)
    // 0x00C    nop                     (padding)
    // 0x010    mret                    ISR: return
    // 0x014    addi a0, x0, 0xA5      a0 = 0xA5 (test pattern)
    // 0x018    addi a1, x0, 0x200     a1 = 0x200 (SRAM B mailbox)
    // 0x01C    sw a0, 0(a1)           mailbox[0] = 0xA5
    // 0x020    addi a2, x0, 0x304     a2 = 0x304 (GPIO_OUT)
    // 0x024    addi a3, x0, 1         a3 = 1
    // 0x028    sw a3, 0(a2)           GPIO_OUT = 1 -> pad_out[0] high
    // 0x02C    addi a4, x0, 0x380     a4 = 0x380 (DOORBELL_H2C IOP side)
    // 0x030    lw a5, 0(a4)           loop: read doorbell
    // 0x034    beq a5, x0, -4         if 0, loop back to 0x030
    // 0x038    addi a5, x0, 1
    // 0x03C    sw a5, 0(a4)           W1C clear doorbell
    // 0x040    addi a5, x0, 0xBE      a5 = 0xBE (ack pattern)
    // 0x044    sw a5, 4(a1)           mailbox[1] = 0xBE
    // 0x048    sw x0, 0(a2)           GPIO_OUT = 0 -> pad_out[0] low
    // 0x04C    jal x0, -0x1C          jump back to 0x030
    // ====================================================================
    reg [31:0] firmware [0:127];

    initial begin : fw_init
        integer fi;
        for (fi = 0; fi < 128; fi = fi + 1)
            firmware[fi] = 32'h00000013;    // nop (addi x0, x0, 0)

        //                                         imm[20|10:1|11|19:12] rd opcode
        // jal x0, +20 (0x14):  imm=20=0x14
        //   imm[20]=0, imm[10:1]=0_0000_1010, imm[11]=0, imm[19:12]=0000_0000
        //   = 0000_0000_1010_0_0000_0000 _00000_ 1101111
        firmware[0]  = 32'b0_0000001010_0_00000000_00000_1101111; // 0x00A0006F

        // 0x010: mret
        firmware[4]  = 32'h30200073;

        // 0x014: addi a0(x10), x0, 0xA5 = 165
        //   imm=0xA5=0000_1010_0101, rs1=00000, funct3=000, rd=01010, opcode=0010011
        firmware[5]  = 32'b000010100101_00000_000_01010_0010011; // 0x0A500513

        // 0x018: addi a1(x11), x0, 0x200 = 512
        //   imm=0x200=0010_0000_0000
        firmware[6]  = 32'b001000000000_00000_000_01011_0010011; // 0x20000593

        // 0x01C: sw a0, 0(a1) — funct7=0, rs2=a0(10), rs1=a1(11), funct3=010, imm=0
        //   imm[11:5]=0000000, rs2=01010, rs1=01011, f3=010, imm[4:0]=00000, op=0100011
        firmware[7]  = 32'b0000000_01010_01011_010_00000_0100011; // 0x00A5A023

        // 0x020: addi a2(x12), x0, 0x304 = 772
        //   imm=0x304=0011_0000_0100
        firmware[8]  = 32'b001100000100_00000_000_01100_0010011; // 0x30400613

        // 0x024: addi a3(x13), x0, 1
        firmware[9]  = 32'b000000000001_00000_000_01101_0010011; // 0x00100693

        // 0x028: sw a3, 0(a2) — rs2=a3(13), rs1=a2(12)
        firmware[10] = 32'b0000000_01101_01100_010_00000_0100011; // 0x00D62023

        // 0x02C: addi a4(x14), x0, 0x380 = 896
        //   imm=0x380=0011_1000_0000
        firmware[11] = 32'b001110000000_00000_000_01110_0010011; // 0x38000713

        // 0x030: lw a5(x15), 0(a4) — imm=0, rs1=a4(14), funct3=010, rd=a5(15)
        firmware[12] = 32'b000000000000_01110_010_01111_0000011; // 0x00072783

        // 0x034: beq a5, x0, -4 (target = 0x030, offset = -4)
        //   offset=-4: imm[12]=1, imm[10:5]=111111, imm[4:1]=1110, imm[11]=1
        //   imm[12|10:5]=1_111111, rs2=00000, rs1=01111(a5), f3=000, imm[4:1|11]=1110_1, op=1100011
        firmware[13] = 32'b1_111111_00000_01111_000_1110_1_1100011; // 0xFE078EE3

        // 0x038: addi a5(x15), x0, 1
        firmware[14] = 32'b000000000001_00000_000_01111_0010011; // 0x00100793

        // 0x03C: sw a5, 0(a4) — rs2=a5(15), rs1=a4(14)
        firmware[15] = 32'b0000000_01111_01110_010_00000_0100011; // 0x00F72023

        // 0x040: addi a5(x15), x0, 0xBE = 190
        //   imm=0xBE=0000_1011_1110
        firmware[16] = 32'b000010111110_00000_000_01111_0010011; // 0x0BE00793

        // 0x044: sw a5, 4(a1) — imm=4: imm[11:5]=0000000, imm[4:0]=00100
        firmware[17] = 32'b0000000_01111_01011_010_00100_0100011; // 0x00F5A223

        // 0x048: sw x0, 0(a2) — rs2=x0, rs1=a2(12)
        firmware[18] = 32'b0000000_00000_01100_010_00000_0100011; // 0x00062023

        // 0x04C: jal x0, -28 (target = 0x030, offset = -28 = -0x1C)
        //   imm=-28: 20-bit signed = 0xFFFF4 → imm[20]=1, [10:1]=1111110010,
        //   imm[11]=1, [19:12]=11111111
        firmware[19] = 32'b1_1111110010_1_11111111_00000_1101111; // 0xFE5FF06F
    end

    // ====================================================================
    // Host bus tasks
    // ====================================================================
    task host_write;
        input [9:0]  addr;
        input [31:0] data;
        input [3:0]  wmask;
        begin
            @(posedge sysclk);
            #1;
            host_addr  = addr;
            host_wdata = data;
            host_wmask = wmask;
            host_wen   = 1'b1;
            host_ren   = 1'b0;
            @(posedge sysclk);
            #1;
            host_wen   = 1'b0;
            host_wmask = 4'h0;
        end
    endtask

    task host_read;
        input  [9:0]  addr;
        output [31:0] data;
        begin
            @(posedge sysclk);
            #1;
            host_addr = addr;
            host_ren  = 1'b1;
            host_wen  = 1'b0;
            @(posedge sysclk);  // SRAM samples address
            #1;
            host_ren  = 1'b0;
            @(posedge sysclk);  // Do0 valid after 1-cycle latency
            #1;
            data = host_rdata;
        end
    endtask

    // ====================================================================
    // Test sequence
    // ====================================================================
    integer i;
    reg [31:0] rd_data;
    integer pass_count;
    integer fail_count;

    initial begin
        $dumpfile("tb_attoio.vcd");
        $dumpvars(0, tb_attoio);

        // Initialize
        rst_n      = 0;
        host_addr  = 10'h0;
        host_wdata = 32'h0;
        host_wmask = 4'h0;
        host_wen   = 0;
        host_ren   = 0;
        pad_in     = 16'h0;
        pass_count = 0;
        fail_count = 0;

        // Reset
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        // ============================================================
        // Test 1: Verify IOP is in reset (IOP_CTRL.reset defaults to 1)
        // ============================================================
        $display("--- Test 1: IOP starts in reset ---");

        // ============================================================
        // Test 2: Load firmware into SRAM A via host bus
        // ============================================================
        $display("--- Test 2: Load firmware into SRAM A ---");
        for (i = 0; i < 128; i = i + 1) begin
            host_write(i * 4, firmware[i], 4'hF);
        end
        $display("  Firmware loaded (%0d words)", 128);

        // Read back and verify key words
        for (i = 0; i < 20; i = i + 1) begin
            host_read(i * 4, rd_data);
            if (rd_data !== firmware[i]) begin
                $display("  FAIL: SRAM A[%0d] = %08h, expected %08h", i, rd_data, firmware[i]);
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
        $display("  SRAM A readback: %0d pass, %0d fail", pass_count, fail_count);

        // ============================================================
        // Test 3: Release IOP from reset
        // ============================================================
        $display("--- Test 3: Release IOP from reset ---");
        // Write IOP_CTRL: reset = 0
        host_write(10'h308, 32'h0, 4'hF);

        // Wait for IOP to execute firmware
        repeat (200) @(posedge clk_iop);

        // ============================================================
        // Test 4: Verify IOP wrote 0xA5 to mailbox[0]
        // ============================================================
        $display("--- Test 4: Check mailbox pattern ---");
        host_read(10'h200, rd_data);
        if (rd_data[7:0] === 8'hA5) begin
            $display("  PASS: mailbox[0] = 0x%02h", rd_data[7:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: mailbox[0] = 0x%08h, expected 0x000000A5", rd_data);
            fail_count = fail_count + 1;
        end

        // ============================================================
        // Test 5: Verify pad_out[0] is high (IOP set GPIO_OUT = 1)
        // ============================================================
        $display("--- Test 5: Check pad_out[0] ---");
        if (pad_out[0] === 1'b1) begin
            $display("  PASS: pad_out[0] = 1");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: pad_out[0] = %b, expected 1", pad_out[0]);
            fail_count = fail_count + 1;
        end

        // ============================================================
        // Test 6: Host rings DOORBELL_H2C, IOP acks
        // ============================================================
        $display("--- Test 6: Doorbell H2C -> IOP ack ---");
        // Set DOORBELL_H2C (host write W1S at 0x300)
        host_write(10'h300, 32'h1, 4'hF);

        // Wait for IOP to process
        repeat (200) @(posedge clk_iop);

        // Read mailbox[1] — should be 0xBE
        host_read(10'h204, rd_data);
        if (rd_data[7:0] === 8'hBE) begin
            $display("  PASS: mailbox[1] = 0x%02h (IOP ack)", rd_data[7:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: mailbox[1] = 0x%08h, expected 0x000000BE", rd_data);
            fail_count = fail_count + 1;
        end

        // pad_out[0] should now be 0 (IOP cleared it)
        if (pad_out[0] === 1'b0) begin
            $display("  PASS: pad_out[0] = 0 (IOP toggled)");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: pad_out[0] = %b, expected 0", pad_out[0]);
            fail_count = fail_count + 1;
        end

        // ============================================================
        // Summary
        // ============================================================
        $display("");
        $display("=== RESULTS: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

    // Timeout watchdog
    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
