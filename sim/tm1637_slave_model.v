/*
 * tm1637_slave_model — minimal TM1637 behavioral slave for tb_tm1637.
 *
 * Captures each transaction's bytes into `bytes[]` (up to 16 bytes).
 * Pulses an ACK low on DIO for the 9th clock of each received byte.
 *
 * Detects START (DIO falls while CLK high) and STOP (DIO rises while
 * CLK high) to delimit transactions.  Uses a `disable`-on-start pattern
 * so mid-byte STARTs (won't happen for TM1637 but doesn't hurt) abort
 * cleanly.
 */

`default_nettype none

module tm1637_slave_model (
    inout  wire dio,
    input  wire clk
);

    reg        dio_drive_low;
    assign     dio = dio_drive_low ? 1'b0 : 1'bz;

    /* Captured bytes across all transactions. */
    reg [7:0]  bytes [0:15];
    integer    byte_cnt;

    /* Per-transaction flags. */
    reg        in_xfer;
    reg        start_pulse;

    integer k;
    initial begin
        for (k = 0; k < 16; k = k + 1) bytes[k] = 8'h00;
        dio_drive_low = 1'b0;
        in_xfer       = 1'b0;
        start_pulse   = 1'b0;
        byte_cnt      = 0;
    end

    /* START / RESTART — DIO falls while CLK high. */
    always @(negedge dio) if (clk === 1'b1) begin
        in_xfer       = 1'b1;
        start_pulse   = 1'b1;
        dio_drive_low = 1'b0;
    end
    /* STOP — DIO rises while CLK high. */
    always @(posedge dio) if (clk === 1'b1) begin
        in_xfer       = 1'b0;
        dio_drive_low = 1'b0;
    end

    /* Read one byte LSB-first across 8 posedges of clk; slave ACKs
     * on the 9th clock by pulling DIO low during the high phase. */
    task read_byte_and_ack;
        output [7:0] b;
        integer i;
        begin
            b = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin
                @(posedge clk);
                b = {dio, b[7:1]};   /* LSB first */
            end
            /* 9th clock: ACK low. */
            @(negedge clk);
            dio_drive_low = 1'b1;
            @(negedge clk);
            dio_drive_low = 1'b0;
        end
    endtask

    always @(posedge start_pulse) begin
        disable proto.body;
    end

    initial begin : proto
        reg [7:0] b;
        forever begin : body
            start_pulse = 1'b0;
            wait (in_xfer === 1'b1);

            while (in_xfer) begin
                read_byte_and_ack(b);
                if (in_xfer && byte_cnt < 16) begin
                    bytes[byte_cnt] = b;
                    byte_cnt        = byte_cnt + 1;
                end
            end
        end
    end

endmodule

`default_nettype wire
