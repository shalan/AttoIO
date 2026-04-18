/******************************************************************************/
// tb_uart — E1 / Phase 1a, v2 with APB host.
//
// Runs the uart_tx firmware and decodes what it sends on pad_out[0]
// with a UART RX model at 115200 baud. Verifies the decoded string
// matches "Hello, AttoIO\r\n" and the done-sentinel arrives in
// mailbox[0] (now @ APB 0x600 under the v2 memory map).
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/uart_tx/uart_tx.hex"
`endif

module tb_uart;

    parameter SYSCLK_PERIOD = 10;   /* 100 MHz */
    parameter CLK_DIV       = 4;    /* clk_iop = 25 MHz */
    parameter UART_BIT_NS   = 8681; /* 115200 baud */

    /* Oversample clock at 16 × bit rate for the RX model */
    real   SAMPLE_HALF_NS = UART_BIT_NS / (2.0 * 16);
    reg    sample_clk     = 0;
    always #(SAMPLE_HALF_NS) sample_clk = ~sample_clk;

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

    reg  [15:0] pad_in = 16'hFFFF;
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

    wire [7:0] rx_byte;
    wire       rx_valid;
    wire       rx_err;
    uart_rx_model #(.SAMPLES_PER_BIT(16)) u_rx_model (
        .sample_clk(sample_clk),
        .rx_line(pad_out[0]),
        .byte_out(rx_byte),
        .byte_valid(rx_valid),
        .frame_err(rx_err)
    );

`include "apb_host.vh"

    reg [7:0] rx_buf [0:63];
    integer   rx_count;
    initial   rx_count = 0;

    always @(posedge rx_valid) begin
        if (rx_count < 64) begin
            rx_buf[rx_count] = rx_byte;
            rx_count = rx_count + 1;
            $display("  rx: byte %0d = 0x%02h '%c'  (frame_err=%b)",
                     rx_count - 1, rx_byte,
                     (rx_byte >= 8'h20 && rx_byte < 8'h7f) ? rx_byte : "?",
                     rx_err);
        end
    end

    reg [31:0] fw_image [0:383];
    integer i;
    reg [31:0] rd;

    task wait_for_mailbox(input [10:0] addr, input [31:0] expected,
                          input integer max_tries);
        integer tries;
        reg [31:0] val;
        begin
            tries = 0;
            while (tries < max_tries) begin
                apb_read(addr, val);
                if (val === expected) begin
                    $display("  mailbox @0x%03h = %08h  (waited %0d reads)",
                             addr, val, tries);
                    disable wait_for_mailbox;
                end
                tries = tries + 1;
            end
            $display("FAIL: mailbox @0x%03h never reached %08h (last=%08h)",
                     addr, expected, val);
            $fatal;
        end
    endtask

    initial begin
        $dumpfile("tb_uart.vcd");
        $dumpvars(0, tb_uart);

        for (i = 0; i < 384; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        PADDR = 0; PWDATA = 0; PSTRB = 0;
        PSEL = 0; PENABLE = 0; PWRITE = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_uart: loading firmware ---");
        for (i = 0; i < 384; i = i + 1)
            apb_write(i * 4, fw_image[i], 4'hF);

        $display("--- releasing IOP reset ---");
        apb_write(11'h708, 32'h0, 4'hF);

        wait_for_mailbox(11'h600, 32'hD0D0D0D0, 200000);
        $display("  firmware signalled 'TX complete'");

        begin : check_string
            integer j;
            reg [7:0] expected [0:14];
            expected[0]  = "H"; expected[1]  = "e"; expected[2]  = "l";
            expected[3]  = "l"; expected[4]  = "o"; expected[5]  = ",";
            expected[6]  = " "; expected[7]  = "A"; expected[8]  = "t";
            expected[9]  = "t"; expected[10] = "o"; expected[11] = "I";
            expected[12] = "O"; expected[13] = 8'h0D; expected[14] = 8'h0A;

            if (rx_count !== 15) begin
                $display("FAIL: expected 15 bytes, got %0d", rx_count);
                $fatal;
            end
            for (j = 0; j < 15; j = j + 1) begin
                if (rx_buf[j] !== expected[j]) begin
                    $display("FAIL: byte %0d = 0x%02h, expected 0x%02h",
                             j, rx_buf[j], expected[j]);
                    $fatal;
                end
            end
        end
        $display("PASS: received 'Hello, AttoIO\\r\\n' on pad[0]");
        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
