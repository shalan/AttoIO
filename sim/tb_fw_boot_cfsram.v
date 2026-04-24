/******************************************************************************/
// tb_fw_boot_cfsram — CFSRAM variant boot sanity test.
//
// Loads a compiled firmware image into the 4 KB CF_SRAM_1024x32 via the
// host APB while the IOP is held in reset, releases reset, then watches
// the core PC.  PASS = PC stable for 20 consecutive clk_iop cycles past
// the reset trampoline (PC > 0x004), i.e. core has reached steady idle.
//
// Uses the attoio_macro_cfsram top-level (13-bit PADDR, 4 KB SRAM A).
// IOP_CTRL register moves to APB 0x1708 in this variant.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/cfsram/empty/empty.hex"
`endif

module tb_fw_boot_cfsram;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;

    reg         sysclk  = 0;
    reg         clk_iop = 0;
    reg         rst_n   = 0;

    reg  [12:0] PADDR;
    reg         PSEL;
    reg         PENABLE;
    reg         PWRITE;
    reg  [31:0] PWDATA;
    reg  [3:0]  PSTRB;
    wire [31:0] PRDATA;
    wire        PREADY;
    wire        PSLVERR;

    reg  [15:0]  pad_in = 0;
    wire [15:0]  pad_out;
    wire [15:0]  pad_oe;
    wire [127:0] pad_ctl;
    wire         irq_to_host;

    always #(SYSCLK_PERIOD/2) sysclk = ~sysclk;

    reg [$clog2(CLK_DIV)-1:0] div_cnt = 0;
    always @(posedge sysclk) begin
        if (div_cnt == CLK_DIV/2 - 1 || div_cnt == CLK_DIV - 1)
            clk_iop <= ~clk_iop;
        div_cnt <= (div_cnt == CLK_DIV - 1) ? 0 : div_cnt + 1;
    end

    attoio_macro_cfsram u_dut (
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

    // 13-bit APB tasks (inline — apb_host.vh has 11-bit)
    task apb_write;
        input [12:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        begin
            @(posedge sysclk); #1;
            PADDR   = addr;
            PWDATA  = data;
            PSTRB   = strb;
            PWRITE  = 1'b1;
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            @(posedge sysclk); #1;
            PENABLE = 1'b1;
            @(posedge sysclk); #1;
            while (PREADY !== 1'b1) begin
                @(posedge sysclk); #1;
            end
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PSTRB   = 4'h0;
        end
    endtask

    task apb_read;
        input  [12:0] addr;
        output [31:0] data;
        begin
            @(posedge sysclk); #1;
            PADDR   = addr;
            PWRITE  = 1'b0;
            PSTRB   = 4'h0;
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            @(posedge sysclk); #1;
            PENABLE = 1'b1;
            @(posedge sysclk); #1;
            while (PREADY !== 1'b1) begin
                @(posedge sysclk); #1;
            end
            data    = PRDATA;
            PSEL    = 1'b0;
            PENABLE = 1'b0;
        end
    endtask

    reg [31:0] fw_image [0:1023];         // 4 KB / 4 = 1024 words
    integer    i;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_fw_boot_cfsram.vcd");
        $dumpvars(0, tb_fw_boot_cfsram);

        for (i = 0; i < 1024; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        $display("--- tb_fw_boot_cfsram: loading firmware from %s ---", `FW_HEX);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        for (i = 0; i < 1024; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        for (i = 0; i < 8; i = i + 1) begin
            apb_read(i * 4, rd);
            if (rd !== fw_image[i]) begin
                $display("FAIL: readback[%0d] = %08h, expected %08h",
                         i, rd, fw_image[i]);
                $fatal;
            end
        end
        $display("  firmware readback OK (CFSRAM, 4 KB)");

        apb_write(13'h1708, 32'h0, 4'hF);   // release IOP reset (IOP_CTRL @ MMIO+0x08)
        $display("  IOP reset released");

        fork
            begin : pc_watch
                reg [12:0] last_pc;
                integer    stable;
                integer    deadline;
                stable   = 0;
                deadline = 0;
                last_pc  = 13'h1FFF;
                while (deadline < 4000) begin
                    @(posedge clk_iop);
                    deadline = deadline + 1;
                    if (u_dut.core_pc_out > 13'h004 &&
                        u_dut.core_mem_rstrb == 1'b0) begin
                        if (u_dut.core_pc_out === last_pc)
                            stable = stable + 1;
                        else
                            stable = 0;
                        last_pc = u_dut.core_pc_out;
                        if (stable >= 20) begin
                            $display("PASS: core steady at PC=%04h after %0d cycles",
                                     u_dut.core_pc_out, deadline);
                            $finish;
                        end
                    end
                end
                $display("FAIL: core did not reach idle within %0d clk_iop cycles (PC=%04h)",
                         deadline, u_dut.core_pc_out);
                $fatal;
            end
        join
    end

    initial begin
        #30000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
