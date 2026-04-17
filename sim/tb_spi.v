/******************************************************************************/
// tb_spi — E2.  Wires the SPI-slave model to the DUT pads (pad[2]=SCK,
// pad[3]=MOSI, pad[4]=MISO, pad[5]=CS), runs the spi_master firmware,
// and cross-checks both directions:
//   - master TX bytes (stored in mailbox[12..15]) match what the slave
//     captured (rx_bytes)
//   - master RX bytes (stored in mailbox[8..11]) match the slave's
//     pre-loaded tx_pattern
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/spi_master/spi_master.hex"
`endif

module tb_spi;

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

    wire [15:0] pad_out;
    wire [15:0] pad_oe;
    wire [127:0] pad_ctl;
    wire        irq_to_host;

    /* DUT drives SCK=pad[2], MOSI=pad[3], CS=pad[5] (all outputs).
     * Slave drives MISO back into DUT on pad[4].  We build pad_in from
     * a combination: MISO on bit 4, everything else high. */
    wire miso;
    reg  [15:0] pad_in_base = 16'hFFFF;
    wire [15:0] pad_in = (pad_in_base & ~(16'h1 << 4)) | (miso << 4);

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

    /* SPI slave wired to pad_out[2/3/5] (sck/mosi/cs_n) and driving MISO. */
    spi_slave_model u_slave (
        .cs_n(pad_out[5]),
        .sck (pad_out[2]),
        .mosi(pad_out[3]),
        .miso(miso)
    );

    /* ---- Host bus tasks ---- */
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

    task wait_for_mailbox(input [9:0] addr, input [31:0] expected, input integer max_tries);
        integer tries;
        reg [31:0] val;
        begin
            tries = 0;
            while (tries < max_tries) begin
                host_read(addr, val);
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

    reg [31:0] fw_image [0:127];
    integer i;
    reg [31:0] rd;
    reg [7:0]  expected_tx [0:3];
    reg [7:0]  expected_rx [0:3];

    initial begin
        $dumpfile("tb_spi.vcd");
        $dumpvars(0, tb_spi);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        host_addr = 0; host_wdata = 0; host_wmask = 0;
        host_wen  = 0; host_ren  = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_spi: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            host_write(i * 4, fw_image[i]);

        $display("--- releasing IOP reset ---");
        host_write(10'h308, 32'h0);

        /* Wait for the "done" sentinel. 4 bytes * 16 clk_iop = 64 cycles
         * of shifting + some overhead; a few thousand host polls is
         * plenty of budget. */
        wait_for_mailbox(10'h200, 32'hA5A55A5A, 20000);
        $display("  firmware signalled 'SPI done'");

        /* Check what the firmware transmitted (mailbox[12..15], packed
         * little-endian into word @ 0x20C) against what the slave
         * captured (rx_bytes[]). */
        expected_tx[0] = 8'hDE; expected_tx[1] = 8'hAD;
        expected_tx[2] = 8'hBE; expected_tx[3] = 8'hEF;

        host_read(10'h20C, rd);
        for (i = 0; i < 4; i = i + 1) begin
            reg [7:0] got_tx;
            got_tx = rd[i*8 +: 8];
            if (got_tx !== expected_tx[i]) begin
                $display("FAIL: fw TX[%0d] stored = 0x%02h, expected 0x%02h",
                         i, got_tx, expected_tx[i]);
                $fatal;
            end
            if (u_slave.rx_bytes[i] !== expected_tx[i]) begin
                $display("FAIL: slave captured byte %0d = 0x%02h, expected 0x%02h",
                         i, u_slave.rx_bytes[i], expected_tx[i]);
                $fatal;
            end
        end
        $display("  PASS: master->slave bytes all match (DE AD BE EF)");

        /* Check the master RX (mailbox[8..11], packed @ 0x208). */
        expected_rx[0] = 8'h11; expected_rx[1] = 8'h22;
        expected_rx[2] = 8'h33; expected_rx[3] = 8'h44;
        host_read(10'h208, rd);
        for (i = 0; i < 4; i = i + 1) begin
            reg [7:0] got_rx;
            got_rx = rd[i*8 +: 8];
            if (got_rx !== expected_rx[i]) begin
                $display("FAIL: master RX[%0d] = 0x%02h, expected 0x%02h",
                         i, got_rx, expected_rx[i]);
                $fatal;
            end
        end
        $display("  PASS: slave->master bytes all match (11 22 33 44)");

        $display("ALL SPI TESTS PASSED");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
