/******************************************************************************/
// tb_qenc — E20.  Drives pad[0]=A, pad[1]=B through CW then CCW
// rotations to exercise the quadrature decoder, plus presses the
// button on pad[2] to verify the BTN wake path.
//
// Expected behaviour after the full stimulus:
//   - 3 full CW rotations (12 edges)    -> position increases by 12
//   - 3 full CCW rotations (12 edges)   -> position returns to 0
//   - 2 button presses (2 falling edges)-> btn_count == 2
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/qenc/qenc.hex"
`endif

module tb_qenc;

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

    reg  [15:0] pad_in = 16'b100;    /* button idle HIGH, A=B=0 */
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
                if (val === expected) disable wait_for_mailbox;
                tries = tries + 1;
            end
            $display("FAIL: mailbox @0x%03h never reached %08h (last=%08h)",
                     addr, expected, val);
            $fatal;
        end
    endtask

    task wait_for_at_least(input [10:0] addr, input [31:0] threshold,
                           input integer max_tries);
        integer tries;
        reg [31:0] val;
        begin
            tries = 0;
            while (tries < max_tries) begin
                apb_read(addr, val);
                if (val >= threshold) disable wait_for_at_least;
                tries = tries + 1;
            end
            $display("FAIL: mailbox @0x%03h never reached >= %0d (last=%0d)",
                     addr, threshold, val);
            $fatal;
        end
    endtask

    task set_ab(input [1:0] ab);
        begin
            @(posedge sysclk);
            pad_in[1:0] = ab;
            /* ISR needs ~200 clk_iop cycles on serial-shift core to
             * complete + clear WAKE_FLAGS before the next edge; wait
             * 1000 sysclks (250 clk_iop = ~10 µs) for comfortable
             * margin. */
            repeat (1000) @(posedge sysclk);
        end
    endtask

    /* State = {B, A} in pad_in[1:0].
     * CW  (A leads B): 00 → 01 → 11 → 10 → 00
     * CCW (B leads A): 00 → 10 → 11 → 01 → 00 */
    task cw_rotation;
        begin
            set_ab(2'b01);
            set_ab(2'b11);
            set_ab(2'b10);
            set_ab(2'b00);
        end
    endtask

    task ccw_rotation;
        begin
            set_ab(2'b10);
            set_ab(2'b11);
            set_ab(2'b01);
            set_ab(2'b00);
        end
    endtask

    task press_button;
        begin
            @(posedge sysclk);
            pad_in[2] = 1'b0;
            repeat (1000) @(posedge sysclk);
            pad_in[2] = 1'b1;
            repeat (1000) @(posedge sysclk);
        end
    endtask

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] rd;

    initial begin
        $dumpfile("tb_qenc.vcd");
        $dumpvars(0, tb_qenc);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_qenc: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed");

        /* 3 CW rotations — position should increment by 12. */
        $display("--- 3 CW rotations ---");
        cw_rotation();
        cw_rotation();
        cw_rotation();

        apb_read(11'h600, rd);
        $display("  wake_count after CW = %0d  (expect 12)", rd);
        apb_read(11'h610, rd);
        $display("  last AB state seen  = %0d", rd);
        apb_read(11'h604, rd);
        $display("  position after CW   = %0d  (expect 12)", $signed(rd));
        if ($signed(rd) !== 12) begin
            $display("FAIL: CW position mismatch");
            $fatal;
        end

        /* 3 CCW rotations — position should return to 0. */
        $display("--- 3 CCW rotations ---");
        ccw_rotation();
        ccw_rotation();
        ccw_rotation();

        apb_read(11'h604, rd);
        $display("  position after CCW = %0d  (expect 0)", $signed(rd));
        if ($signed(rd) !== 0) begin
            $display("FAIL: CCW position mismatch");
            $fatal;
        end

        /* Button presses. */
        $display("--- 2 button presses ---");
        press_button();
        press_button();

        wait_for_at_least(11'h60C, 2, 5000);
        apb_read(11'h60C, rd);
        $display("  button count = %0d  (expect 2)", rd);
        if (rd !== 2) begin
            $display("FAIL: button count mismatch");
            $fatal;
        end

        $display("PASS: quadrature encoder + button verified (CW, CCW, 2 presses)");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
