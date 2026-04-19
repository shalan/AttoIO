/******************************************************************************/
// tb_fw_boot — Phase-0 acceptance test (v2: APB host, 11-bit address).
//
// Loads a compiled firmware image into SRAM A via the host APB while
// the IOP is held in reset, releases reset, then watches the core PC.
// PASS = PC stable for 20 consecutive clk_iop cycles past the reset
// trampoline (PC > 0x004) — i.e. the core has reached steady idle
// (e.g. wfi loop in main).
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

    reg  [10:0] PADDR;
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

    attoio_macro u_dut (
        .sysclk(sysclk), .clk_iop(clk_iop), .rst_n(rst_n),
        .PADDR(PADDR), .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PWDATA(PWDATA), .PSTRB(PSTRB),
        .PRDATA(PRDATA), .PREADY(PREADY), .PSLVERR(PSLVERR),
        .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe), .pad_ctl(pad_ctl),
        .irq_to_host(irq_to_host)
    );

`include "apb_host.vh"

    reg [31:0] fw_image [0:255];      // 1024 B / 4 = 256 words
    integer    i;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_fw_boot.vcd");
        $dumpvars(0, tb_fw_boot);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        $display("--- tb_fw_boot: loading firmware from %s ---", `FW_HEX);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        for (i = 0; i < 8; i = i + 1) begin
            apb_read(i * 4, rd);
            if (rd !== fw_image[i]) begin
                $display("FAIL: readback[%0d] = %08h, expected %08h",
                         i, rd, fw_image[i]);
                $fatal;
            end
        end
        $display("  firmware readback OK");

        apb_write(11'h708, 32'h0, 4'hF);    // release IOP reset
        $display("  IOP reset released");

        fork
            begin : pc_watch
                reg [10:0] last_pc;
                integer    stable;
                integer    deadline;
                stable   = 0;
                deadline = 0;
                last_pc  = 11'h7FF;
                while (deadline < 4000) begin
                    @(posedge clk_iop);
                    deadline = deadline + 1;
                    if (u_dut.core_pc_out > 11'h004 &&
                        u_dut.core_mem_rstrb == 1'b0) begin
                        if (u_dut.core_pc_out === last_pc)
                            stable = stable + 1;
                        else
                            stable = 0;
                        last_pc = u_dut.core_pc_out;
                        if (stable >= 20) begin
                            $display("PASS: core steady at PC=%03h (state=%0d) after %0d cycles",
                                     u_dut.core_pc_out,
                                     u_dut.u_core.state,
                                     deadline);
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
        #10000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
