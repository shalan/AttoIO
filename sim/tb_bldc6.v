/******************************************************************************/
// tb_bldc6 — E10.  Drives the 6 valid Hall states on pad[2:0] through
// two full rotor revolutions and verifies the firmware:
//   - advances the commutation index deterministically (0..5)
//   - drives pad_out[9:4] with the correct gate pattern per step
//   - publishes count as a "done" sentinel LAST (so polling the
//     count is a safe handshake for reading idx/gate)
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/bldc6/bldc6.hex"
`endif

module tb_bldc6;

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

    reg [2:0]  hall_seq    [0:5];
    reg [5:0]  expect_gate [0:5];   /* pad_out[9:4] per step */

    initial begin
        hall_seq[0]    = 3'b001; expect_gate[0] = 6'b100100;  /* V_H | W_L */
        hall_seq[1]    = 3'b010; expect_gate[1] = 6'b010010;  /* W_H | U_L */
        hall_seq[2]    = 3'b011; expect_gate[2] = 6'b000110;  /* V_H | U_L */
        hall_seq[3]    = 3'b100; expect_gate[3] = 6'b001001;  /* U_H | V_L */
        hall_seq[4]    = 3'b101; expect_gate[4] = 6'b100001;  /* U_H | W_L */
        hall_seq[5]    = 3'b110; expect_gate[5] = 6'b011000;  /* W_H | V_L */
    end

    task apply_hall(input [2:0] h);
        begin
            @(posedge sysclk);
            pad_in[2:0] = h;
            repeat (40) @(posedge sysclk);
        end
    endtask

    reg [31:0] fw_image [0:127];
    integer i, rev, s;
    reg [31:0] mb1, mb3;
    integer    expected_count;
    integer    expected_idx;
    reg [5:0]  expected_pads;

    initial begin
        $dumpfile("tb_bldc6.vcd");
        $dumpvars(0, tb_bldc6);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_bldc6: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);
        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed Hall wake + gate outputs, WFI");

        expected_count = 0;
        for (rev = 0; rev < 2; rev = rev + 1) begin
            for (s = 0; s < 6; s = s + 1) begin
                $display("--- rev %0d, step %0d, Hall=%03b ---",
                         rev, s, hall_seq[s]);
                apply_hall(hall_seq[s]);
                expected_count = expected_count + 1;

                /* Count is the "done" sentinel — ISR writes it last,
                 * so once count bumps we're guaranteed idx and gate
                 * are already committed.  Tight reads OK. */
                wait_for_at_least(11'h600, expected_count, 5000);

                expected_idx  = s;
                expected_pads = expect_gate[s];

                apb_read(11'h604, mb1);
                apb_read(11'h60C, mb3);

                if (mb1 !== {29'h0, expected_idx[2:0]}) begin
                    $display("FAIL rev %0d step %0d: mailbox[1] = %08h != idx %0d",
                             rev, s, mb1, expected_idx);
                    $fatal;
                end
                if (mb3 !== ({26'h0, expected_pads} << 4)) begin
                    $display("FAIL rev %0d step %0d: mailbox[3] = %08h != gate %08h",
                             rev, s, mb3, {26'h0, expected_pads} << 4);
                    $fatal;
                end
                if (pad_out[9:4] !== expected_pads) begin
                    $display("FAIL rev %0d step %0d: pad_out[9:4] = %06b != %06b",
                             rev, s, pad_out[9:4], expected_pads);
                    $fatal;
                end
                $display("  OK: idx=%0d gates=%06b", expected_idx, pad_out[9:4]);
            end
        end

        $display("PASS: 12 commutations over 2 full Hall revolutions");
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
