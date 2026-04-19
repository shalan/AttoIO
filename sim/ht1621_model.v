/*
 * ht1621_model — minimal HT1621 3-wire serial slave for tb_ht1621.
 *
 * Bit-level capture only — we record per-transaction bit count and bit
 * stream (MSB-first) so the testbench can verify the wire-level frames.
 * No segment-RAM modelling.
 *
 * Protocol summary (master -> slave):
 *   - Pull CS low to begin a transaction.
 *   - Each bit on DATA is sampled by the slave on the rising edge of WR.
 *   - Pull CS high to end the transaction.
 *
 * We store up to 8 transactions of up to 64 bits each.
 */

`default_nettype none

module ht1621_model (
    input wire cs,
    input wire wr,
    input wire data
);

    reg [63:0] frames    [0:7];
    integer    frame_len [0:7];
    integer    frame_cnt;

    reg [63:0] cur_bits;
    integer    cur_len;
    reg        in_xfer;
    reg        cs_was_high;   /* gate against the X→0/idle-setup phantom */

    integer i;
    initial begin
        for (i = 0; i < 8; i = i + 1) begin
            frames[i]    = 64'h0;
            frame_len[i] = 0;
        end
        frame_cnt   = 0;
        cur_bits    = 64'h0;
        cur_len     = 0;
        in_xfer     = 1'b0;
        cs_was_high = 1'b0;
    end

    /* Only count CS pulses after we've confirmed CS=1 once.  Filters
     * the X→0 phantom when GPIO out_r is initialised at reset. */
    always @(posedge cs) cs_was_high = 1'b1;

    /* CS falling: begin a fresh transaction. */
    always @(negedge cs) if (cs_was_high) begin
        cur_bits = 64'h0;
        cur_len  = 0;
        in_xfer  = 1'b1;
    end

    /* CS rising: end transaction, store. */
    always @(posedge cs) if (in_xfer) begin
        if (frame_cnt < 8) begin
            frames[frame_cnt]    = cur_bits;
            frame_len[frame_cnt] = cur_len;
            frame_cnt            = frame_cnt + 1;
        end
        in_xfer = 1'b0;
    end

    /* Sample DATA on each rising edge of WR while CS is asserted.
     * Bits accumulate MSB-first into the low bits of cur_bits. */
    always @(posedge wr) if (in_xfer) begin
        cur_bits = (cur_bits << 1) | (data ? 64'h1 : 64'h0);
        cur_len  = cur_len + 1;
    end

endmodule

`default_nettype wire
