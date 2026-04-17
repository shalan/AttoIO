/******************************************************************************/
// tb_fw_boot — Phase-0 acceptance test.
//
// Loads a compiled firmware image (hex format, one 32-bit word per line)
// into SRAM A via the host bus while IOP is held in reset, then releases
// reset and watches the core execute. The test passes when:
//   (1) the firmware is written correctly to SRAM A (readback),
//   (2) the core's PC progresses past the reset trampoline (> 0x004),
//   (3) the core reaches a steady state where PC is stable for at least
//       20 clk_iop cycles AND mem_rstrb=0 (i.e., at WFI or in a tight
//       loop with no fetch). AttoRV32 holds WFI in S_EXECUTE with
//       wfi_stall asserted — PC never advances, which is the signal.
//
// The hex file path can be overridden with -DFW_HEX=\"...\" on iverilog's
// command line; default is build/sw/empty/empty.hex.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/empty/empty.hex"
`endif

module tb_fw_boot;

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
    // Bus tasks
    // --------------------------------------------------------------
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

    // --------------------------------------------------------------
    // Hex image load
    // --------------------------------------------------------------
    reg [31:0] fw_image [0:127];      // 512 B / 4 B-per-word
    integer    i;
    reg [31:0] rd;
    integer    fw_words;

    initial begin
        $dumpfile("tb_fw_boot.vcd");
        $dumpvars(0, tb_fw_boot);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013; // nop
        $readmemh(`FW_HEX, fw_image);

        // Count significant words (first trailing all-zero run past word 4
        // still counts; use a simple heuristic of "stop at 128" for now).
        fw_words = 128;
        $display("--- tb_fw_boot: loading %0d words from %s ---", fw_words, `FW_HEX);

        // Reset release timing
        host_addr = 0; host_wdata = 0; host_wmask = 0;
        host_wen = 0; host_ren = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        // IOP starts in reset (IOP_CTRL.reset defaults to 1).
        // Load firmware via host bus.
        for (i = 0; i < fw_words; i = i + 1)
            host_write(i * 4, fw_image[i]);

        // Verify the first few words read back.
        for (i = 0; i < 8; i = i + 1) begin
            host_read(i * 4, rd);
            if (rd !== fw_image[i]) begin
                $display("FAIL: readback[%0d] = %08h, expected %08h",
                         i, rd, fw_image[i]);
                $fatal;
            end
        end
        $display("  firmware readback OK");

        // Release IOP from reset: IOP_CTRL @ byte 0x308, bit 0 = 0.
        host_write(10'h308, 32'h0);
        $display("  IOP reset released");

        // Wait up to 2000 clk_iop cycles for the core to reach main loop.
        // "Reached main" = PC stable for 20+ cycles past the trampoline.
        fork
            begin : pc_watch
                reg [9:0] last_pc;
                integer stable;
                integer deadline;
                stable   = 0;
                deadline = 0;
                last_pc  = 10'h3FF;
                while (deadline < 2000) begin
                    @(posedge clk_iop);
                    deadline = deadline + 1;
                    if (u_dut.core_pc_out > 10'h004 &&
                        u_dut.core_mem_rstrb == 1'b0) begin
                        if (u_dut.core_pc_out === last_pc)
                            stable = stable + 1;
                        else
                            stable = 0;
                        last_pc = u_dut.core_pc_out;
                        if (stable >= 20) begin
                            $display("PASS: core steady at PC=%03h (state=%0d) after %0d cycles",
                                     u_dut.core_pc_out, u_dut.u_core.state, deadline);
                            $finish;
                        end
                    end
                end
                $display("FAIL: core did not reach idle within %0d clk_iop cycles (PC=%03h state=%0d)",
                         deadline, u_dut.core_pc_out, u_dut.u_core.state);
                $fatal;
            end
        join
    end

    initial begin
        #2000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
