/******************************************************************************/
// tb_uart_echo — drives UART frames into pad_in[1], decodes echoes on
// pad_out[0] via uart_rx_model, verifies round-trip byte-for-byte.
/******************************************************************************/

`timescale 1ns/1ps

`ifndef FW_HEX
 `define FW_HEX "build/sw/uart_echo/uart_echo.hex"
`endif

module tb_uart_echo;

    parameter SYSCLK_PERIOD = 10;
    parameter CLK_DIV       = 4;
    parameter UART_BIT_NS   = 8681;     /* 115200 baud */

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

    reg  [15:0] pad_in = 16'hFFFF;      /* RX line idle-high */
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

    /* Oversample clock (16× bit rate) */
    real SAMPLE_HALF_NS = UART_BIT_NS / (2.0 * 16);
    reg  sample_clk = 0;
    always #(SAMPLE_HALF_NS) sample_clk = ~sample_clk;

    attoio_macro u_dut (
        .sysclk(sysclk), .clk_iop(clk_iop), .rst_n(rst_n),
        .host_addr(host_addr), .host_wdata(host_wdata), .host_wmask(host_wmask),
        .host_wen(host_wen), .host_ren(host_ren),
        .host_rdata(host_rdata), .host_ready(host_ready),
        .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe), .pad_ctl(pad_ctl),
        .irq_to_host(irq_to_host)
    );

    wire [7:0] rx_byte;
    wire       rx_valid, rx_err;
    uart_rx_model #(.SAMPLES_PER_BIT(16)) u_rx_model (
        .sample_clk(sample_clk),
        .rx_line(pad_out[0]),
        .byte_out(rx_byte),
        .byte_valid(rx_valid),
        .frame_err(rx_err)
    );

    /* ---- Drive one 8-N-1 UART frame into pad_in[1] ---- */
    task uart_drive_byte(input [7:0] b);
        integer k;
        begin
            /* start */
            pad_in[1] = 1'b0; #(UART_BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                pad_in[1] = b[k];
                #(UART_BIT_NS);
            end
            /* stop + a bit of idle */
            pad_in[1] = 1'b1; #(UART_BIT_NS);
            #(UART_BIT_NS / 4);
        end
    endtask

    task host_write(input [9:0] addr, input [31:0] data);
        begin
            @(posedge sysclk); #1;
            host_addr = addr; host_wdata = data;
            host_wmask = 4'hF; host_wen = 1'b1; host_ren = 1'b0;
            @(posedge sysclk); #1;
            host_wen = 1'b0; host_wmask = 4'h0;
        end
    endtask

    /* ---- Collect echoed bytes ---- */
    reg [7:0] rx_buf [0:63];
    integer   rx_count = 0;
    always @(posedge rx_valid) begin
        if (rx_count < 64) begin
            rx_buf[rx_count] = rx_byte;
            $display("  echo rx: byte %0d = 0x%02h '%c'", rx_count, rx_byte,
                     (rx_byte >= 8'h20 && rx_byte < 8'h7f) ? rx_byte : "?");
            rx_count = rx_count + 1;
        end
    end

    reg [31:0] fw_image [0:127];
    integer i;
    reg [7:0] tx_pattern [0:3];

    initial begin
        $dumpfile("tb_uart_echo.vcd");
        $dumpvars(0, tb_uart_echo);

        for (i = 0; i < 128; i = i + 1) fw_image[i] = 32'h00000013;
        $readmemh(`FW_HEX, fw_image);

        host_addr = 0; host_wdata = 0; host_wmask = 0;
        host_wen  = 0; host_ren  = 0;
        repeat (10) @(posedge sysclk);
        rst_n = 1;
        repeat (5) @(posedge sysclk);

        $display("--- tb_uart_echo: loading firmware ---");
        for (i = 0; i < 128; i = i + 1)
            host_write(i * 4, fw_image[i]);

        $display("--- releasing IOP reset ---");
        host_write(10'h308, 32'h0);

        /* Give the firmware a moment to reach the main loop. */
        #100000;

        /* Drive 4 bytes: "ABCD". */
        tx_pattern[0] = "A";
        tx_pattern[1] = "B";
        tx_pattern[2] = "C";
        tx_pattern[3] = "D";

        for (i = 0; i < 4; i = i + 1) begin
            $display("  tx: byte %0d = 0x%02h '%c'", i, tx_pattern[i], tx_pattern[i]);
            uart_drive_byte(tx_pattern[i]);
            /* Let firmware echo back before sending next (rough upper bound). */
            #(15 * UART_BIT_NS);
        end

        /* Wait a bit more for any trailing echo. */
        #(20 * UART_BIT_NS);

        if (rx_count !== 4) begin
            $display("FAIL: expected 4 echoed bytes, got %0d", rx_count);
            $fatal;
        end
        for (i = 0; i < 4; i = i + 1) begin
            if (rx_buf[i] !== tx_pattern[i]) begin
                $display("FAIL: echo[%0d] = 0x%02h, expected 0x%02h",
                         i, rx_buf[i], tx_pattern[i]);
                $fatal;
            end
        end
        $display("PASS: echoed 'ABCD' round-trip");
        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT");
        $fatal;
    end

endmodule
