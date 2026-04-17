/*
 * spi_slave_model — a minimal SPI mode-0 slave for testbenches.
 *
 *   CPOL = 0  (SCK idle low)
 *   CPHA = 0  (master & slave sample on rising SCK edge, MISO/MOSI
 *              change on falling edge; MSB of first byte is presented
 *              before the first rising edge — exactly when CS falls)
 *
 * Behavior:
 *   negedge cs_n : load byte 0 into tx_shift, present its MSB on MISO
 *   posedge sck  : master samples MISO; slave samples MOSI into
 *                  rx_shift.  After bit 7 of a byte, rx_bytes[byte_idx]
 *                  is written.
 *   negedge sck  : if we just finished 8 bits, load next byte and
 *                  present its MSB; otherwise shift tx_shift left and
 *                  present the new bit 7.
 */

module spi_slave_model (
    input  wire       cs_n,
    input  wire       sck,
    input  wire       mosi,
    output reg        miso
);

    /* Fixed pattern returned to the master, one byte per transaction. */
    reg [7:0] tx_pattern [0:3];
    /* Captured master->slave bytes. */
    reg [7:0] rx_bytes   [0:3];
    integer   byte_idx;
    integer   bit_cnt;       /* counts 0..7 within the current byte */
    reg [7:0] tx_shift;
    reg [7:0] rx_shift;

    initial begin
        tx_pattern[0] = 8'h11;
        tx_pattern[1] = 8'h22;
        tx_pattern[2] = 8'h33;
        tx_pattern[3] = 8'h44;
        rx_bytes[0]   = 8'h00;
        rx_bytes[1]   = 8'h00;
        rx_bytes[2]   = 8'h00;
        rx_bytes[3]   = 8'h00;
        byte_idx      = 0;
        bit_cnt       = 0;
        tx_shift      = 8'h00;
        rx_shift      = 8'h00;
        miso          = 1'b0;
    end

    /* CS assertion: first byte setup. */
    always @(negedge cs_n) begin
        byte_idx = 0;
        bit_cnt  = 0;
        rx_shift = 8'h00;
        tx_shift = tx_pattern[0];
        miso     = tx_shift[7];
    end

    /* Rising SCK: master sampling point.  Slave captures MOSI; after
     * 8 bits, stashes the received byte. */
    always @(posedge sck) begin
        if (!cs_n) begin
            rx_shift = {rx_shift[6:0], mosi};
            if (bit_cnt == 7 && byte_idx < 4)
                rx_bytes[byte_idx] = rx_shift;
        end
    end

    /* Falling SCK: slave updates MISO for the next rising edge.
     * At the byte boundary (bit_cnt == 7), load the next pattern byte
     * and present its MSB; otherwise just shift left. */
    always @(negedge sck) begin
        if (!cs_n) begin
            if (bit_cnt == 7) begin
                bit_cnt  = 0;
                byte_idx = byte_idx + 1;
                tx_shift = (byte_idx < 4) ? tx_pattern[byte_idx] : 8'h00;
            end else begin
                tx_shift = {tx_shift[6:0], 1'b0};
                bit_cnt  = bit_cnt + 1;
            end
            miso = tx_shift[7];
        end
    end

endmodule
