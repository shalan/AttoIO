/******************************************************************************/
// tb_i2c — E3.  Runs the i2c_eeprom firmware against an in-tree
// behavioral I²C EEPROM model wired to pad[6]=SDA, pad[7]=SCL, with
// pull-ups modeled by default-high pad_in bits.
//
// Verifies:
//   - page-written bytes {5A, A5, DE, AD} land in EEPROM addresses 0..3
//   - random-read at address 0 returns the same bytes
//   - mailbox[16..19] matches the readback
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/i2c_eeprom/i2c_eeprom.hex"
`endif

module tb_i2c;

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

    wire [15:0] pad_out;
    wire [15:0] pad_oe;
    wire [127:0] pad_ctl;
    wire        irq_to_host;

    /* ---- open-drain bus modeling ----
     * SDA/SCL are open-drain: master and slave can each pull low, both
     * released = high (pull-up).  pad_in[i] for the bus pin is the
     * wired-AND of master drive (pad_oe=1 -> low) and slave drive
     * (model drives low or z).  */
    wire dut_drive_sda_low = pad_oe[6] & ~pad_out[6];
    wire dut_drive_scl_low = pad_oe[7] & ~pad_out[7];

    wire sda_wire;   /* bus-level SDA (external) */
    wire scl_wire;

    /* DUT pulls SDA/SCL low via open-drain, then model drives sda_wire
     * or tri-states it. Bus is 'pull-up' by default. */
    pullup  sda_pup (sda_wire);
    pullup  scl_pup (scl_wire);

    /* DUT's open-drain pull-down on SDA */
    assign (strong0, highz1) sda_wire = dut_drive_sda_low ? 1'b0 : 1'bz;
    assign (strong0, highz1) scl_wire = dut_drive_scl_low ? 1'b0 : 1'bz;

    /* pad_in mirrors the bus-level value back into the DUT inputs. All
     * other pins read high-idle. */
    reg  [15:0] pad_in_base = 16'hFFFF;
    wire [15:0] pad_in = (pad_in_base
                         & ~(16'h1 << 6) & ~(16'h1 << 7))
                         | ((sda_wire ? 16'h1 : 16'h0) << 6)
                         | ((scl_wire ? 16'h1 : 16'h0) << 7);

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

    i2c_eeprom_model u_eeprom (
        .sda(sda_wire),
        .scl(scl_wire)
    );

    /* ---- Host bus tasks ---- */
`include "apb_host.vh"
    task wait_for_mailbox(input [10:0] addr, input [31:0] expected, input integer max_tries);
        integer tries;
        reg [31:0] val;
        begin
            tries = 0;
            while (tries < max_tries) begin
                apb_read(addr, val);
                if (val === expected) begin
                    $display("  mailbox @0x%03h = %08h  (waited %0d reads)", addr, val, tries);
                    disable wait_for_mailbox;
                end
                tries = tries + 1;
            end
            $display("FAIL: mailbox @0x%03h never reached %08h (last=%08h)", addr, expected, val);
            $fatal;
        end
    endtask

    reg [31:0] fw_image [0:255];
    integer i;
    reg [31:0] rd;
    reg [7:0]  expected [0:3];

    initial begin
        $dumpfile("tb_i2c.vcd");
        $dumpvars(0, tb_i2c);

        for (i = 0; i < 256; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_i2c: loading firmware ---");
        for (i = 0; i < 256; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        /* Phase 0.9 FW uses a 3-phase write / set-address / read (no
         * restart needed) — same 4-byte round-trip coverage.  NOTE:
         * this example does not fit in Phase 0.9's 512 B SRAM A
         * budget and is excluded from default regression; it's kept
         * as archival for anyone running a larger-RAM variant. */
        wait_for_mailbox(11'h600, 32'hE2E2E2E2, 500000);
        $display("  firmware signalled 'I2C done'");

        /* Cross-check EEPROM contents (slave side). */
        expected[0] = 8'h5A; expected[1] = 8'hA5;
        expected[2] = 8'hDE; expected[3] = 8'hAD;
        for (i = 0; i < 4; i = i + 1) begin
            if (u_eeprom.mem[i] !== expected[i]) begin
                $display("FAIL: EEPROM mem[%0d] = 0x%02h, expected 0x%02h",
                         i, u_eeprom.mem[i], expected[i]);
                $fatal;
            end
        end
        $display("  PASS: EEPROM memory matches master writes (5A A5 DE AD)");

        /* Cross-check master readback via mailbox word @ 0x610 (bytes 16..19). */
        apb_read(11'h610, rd);
        for (i = 0; i < 4; i = i + 1) begin : readcheck
            reg [7:0] got;
            got = rd[i*8 +: 8];
            if (got !== expected[i]) begin
                $display("FAIL: master rx[%0d] = 0x%02h, expected 0x%02h",
                         i, got, expected[i]);
                $fatal;
            end
        end
        $display("  PASS: master readback matches (5A A5 DE AD)");

        $display("ALL I2C TESTS PASSED");
        $finish;
    end

    initial begin
        #30000000;      /* 30 ms cap */
        $display("TIMEOUT");
        $fatal;
    end

endmodule
