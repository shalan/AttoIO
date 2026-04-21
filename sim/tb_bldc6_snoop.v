/******************************************************************************/
// tb_bldc6_snoop — instrumented reproducer for the original E10 BLDC
// failure.  Same stimulus as the (deleted) failing tb_bldc6, but with
// full bus snooping across the core ↔ memmux boundary so we can see
// exactly which stores make it to SRAM B and which don't.
//
// Snoop points (all hooked into u_dut hierarchically):
//   - core_mem_*  : what the core actually drives to memmux
//   - sram_b_*    : what memmux drives to the SRAM B macro
//   - b_conflict  : memmux arbitration conflicts (host wins, core waits)
//
// If the core emits a store to 0x60C but no sram_b_we0 pulse on word 3
// ever fires → memmux drops it.  If the core never emits that store in
// the first place → the bug is in the core's LSU scheduling.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/bldc6/bldc6.hex"
`endif

module tb_bldc6_snoop;

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

    /* -------------------------------------------------------------- */
    /*  Core-side store snoop (clk_iop domain).                        */
    /* -------------------------------------------------------------- */
    integer core_stores = 0;
    reg core_store_trace_en = 1'b0;

    always @(posedge clk_iop) begin
        if (core_store_trace_en && (|u_dut.core_mem_wmask)) begin
            core_stores = core_stores + 1;
            $display("[%8t] core_sw  #%0d  addr=%03h  wmask=%b  data=%08h",
                     $time, core_stores,
                     u_dut.core_mem_addr[10:0],
                     u_dut.core_mem_wmask,
                     u_dut.core_mem_wdata);
        end
    end

    /* -------------------------------------------------------------- */
    /*  SRAM B writes + arbitration events (sysclk domain).            */
    /* -------------------------------------------------------------- */
    integer sram_b_writes = 0;
    integer arbiter_conflicts = 0;
    reg b_trace_en = 1'b0;

    always @(posedge sysclk) begin
        if (b_trace_en) begin
            if (u_dut.u_memmux.sram_b_en0) begin
                if (|u_dut.u_memmux.sram_b_we0) begin
                    sram_b_writes = sram_b_writes + 1;
                    $display("[%8t] sram_b W a0=%02h  di=%08h  we=%b  grant=%s",
                             $time,
                             u_dut.u_memmux.sram_b_a0,
                             u_dut.u_memmux.sram_b_di0,
                             u_dut.u_memmux.sram_b_we0,
                             u_dut.u_memmux.b_grant_host ? "HOST" : "CORE");
                end else begin
                    $display("[%8t] sram_b R a0=%02h                      grant=%s  do0=%08h",
                             $time,
                             u_dut.u_memmux.sram_b_a0,
                             u_dut.u_memmux.b_grant_host ? "HOST" : "CORE",
                             u_dut.u_memmux.sram_b_do0);
                end
            end
            if (u_dut.u_memmux.b_conflict) begin
                arbiter_conflicts = arbiter_conflicts + 1;
            end
        end
    end

    /* -------------------------------------------------------------- */
    /*  Stimulus / checker.                                            */
    /* -------------------------------------------------------------- */
    reg [2:0]  hall_seq    [0:5];
    reg [5:0]  expect_gate [0:5];

    initial begin
        hall_seq[0]    = 3'b001; expect_gate[0] = 6'b100100;
        hall_seq[1]    = 3'b010; expect_gate[1] = 6'b010010;
        hall_seq[2]    = 3'b011; expect_gate[2] = 6'b000110;
        hall_seq[3]    = 3'b100; expect_gate[3] = 6'b001001;
        hall_seq[4]    = 3'b101; expect_gate[4] = 6'b100001;
        hall_seq[5]    = 3'b110; expect_gate[5] = 6'b011000;
    end

    task apply_hall(input [2:0] h);
        begin
            @(posedge sysclk);
            pad_in[2:0] = h;
            repeat (40) @(posedge sysclk);
        end
    endtask

    reg [31:0] fw_image [0:127];
    integer i;
    reg [31:0] mb0, mb1, mb3;
    integer    expected_count;

    initial begin
        $dumpfile("tb_bldc6_snoop.vcd");
        $dumpvars(0, tb_bldc6_snoop);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_bldc6_snoop: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        apb_write(11'h708, 32'h0, 4'hF);
        wait_for_mailbox(11'h608, 32'hC0DEC0DE, 50000);
        $display("  firmware armed, WFI");
        $display("");
        $display("================= Snoop: first Hall edge =================");

        /* Enable tracing ONLY around the first wake event so the log
         * stays tight. */
        /* Trace across the first TWO edges — that's where we saw the
         * drop.  After that, stop tracing so the full 12-edge sweep
         * stays readable. */
        core_store_trace_en = 1'b1;
        b_trace_en          = 1'b1;

        apply_hall(hall_seq[0]);
        expected_count = 1;
        wait_for_at_least(11'h600, expected_count, 5000);
        repeat (400) @(posedge sysclk);

        $display("");
        $display("================= Snoop: second Hall edge =================");
        apply_hall(hall_seq[1]);
        expected_count = 2;
        wait_for_at_least(11'h600, expected_count, 5000);
        repeat (400) @(posedge sysclk);

        $display("");
        $display("================= Snoop: third Hall edge =================");
        apply_hall(hall_seq[2]);
        expected_count = 3;
        wait_for_at_least(11'h600, expected_count, 5000);
        repeat (400) @(posedge sysclk);

        $display("");
        $display("================= Snoop: fourth Hall edge (0.3 — the failing one) =================");
        apply_hall(hall_seq[3]);
        expected_count = 4;
        wait_for_at_least(11'h600, expected_count, 5000);
        repeat (400) @(posedge sysclk);

        $display("");
        $display("================= Reading edge-3 mailbox state ===============");
        apb_read(11'h600, mb0);
        $display("  --> mailbox[0] = %08h  (expected count = 4)", mb0);
        apb_read(11'h604, mb1);
        $display("  --> mailbox[1] = %08h  (expected idx   = 3)", mb1);
        apb_read(11'h60C, mb3);
        $display("  --> mailbox[3] = %08h  (expected gate  = 90 = U_H|V_L)", mb3);

        core_store_trace_en = 1'b0;
        b_trace_en          = 1'b0;

        /* Now cycle through the remaining edges of two revolutions
         * without tracing but WITH per-step verification. */
        begin : full_cycle
            integer rev, s;
            reg [31:0] got_gate;
            reg [5:0]  expected_pads;
            integer    expected_idx;
            for (rev = 0; rev < 2; rev = rev + 1) begin
                for (s = (rev == 0) ? 4 : 0; s < 6; s = s + 1) begin
                    apply_hall(hall_seq[s]);
                    expected_count = expected_count + 1;
                    wait_for_at_least(11'h600, expected_count, 5000);

                    expected_idx  = s;
                    expected_pads = expect_gate[s];

                    apb_read(11'h604, mb1);
                    apb_read(11'h60C, mb3);

                    if (mb1 !== {29'h0, expected_idx[2:0]}) begin
                        $display("FAIL edge %0d.%0d: mailbox[1] = %08h != idx %0d",
                                 rev, s, mb1, expected_idx);
                        $fatal;
                    end
                    if (mb3 !== ({26'h0, expected_pads} << 4)) begin
                        $display("FAIL edge %0d.%0d: mailbox[3] = %08h != gate %08h",
                                 rev, s, mb3, {26'h0, expected_pads} << 4);
                        $fatal;
                    end
                    if (pad_out[9:4] !== expected_pads) begin
                        $display("FAIL edge %0d.%0d: pad_out[9:4] = %06b != %06b",
                                 rev, s, pad_out[9:4], expected_pads);
                        $fatal;
                    end
                end
            end
        end

        /* Final snapshot of the first-edge state */
        apb_read(11'h600, mb0);

        $display("");
        $display("================= Results =================");
        $display("  final comm_count     : %0d (expected %0d)", mb0, expected_count);
        $display("  core_stores observed : %0d (first-edge window)", core_stores);
        $display("  sram_b writes obs    : %0d (first-edge window)", sram_b_writes);
        $display("  arbiter conflicts    : %0d (first-edge window)", arbiter_conflicts);
        if (mb0 == expected_count) begin
            $display("PASS: 12 commutations over 2 Hall revolutions — bug NOT reproduced.");
        end else begin
            $display("FAIL: commutation count mismatch");
            $fatal;
        end
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
