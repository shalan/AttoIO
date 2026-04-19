/*
 * hd44780_model — minimal HD44780-compatible slave for tb_hd44780.
 *
 * Assumes 4-bit mode from t=0 (the firmware skips the canonical 8-bit
 * "0x3 0x3 0x3 0x2" preamble — see sw/hd44780/main.c for the comment
 * block describing what real silicon would need).
 *
 * On every falling edge of E we sample {RS, D7..D4}.  Two consecutive
 * nibbles compose a byte (high then low) which is appended to bytes[],
 * with the corresponding RS captured into rs_flags[].
 *
 * No execution side-effects are modelled — we just record the wire-level
 * traffic so the testbench can byte-match against what the firmware
 * meant to send.
 */

`default_nettype none

module hd44780_model (
    input wire rs,
    input wire e,
    input wire d4,
    input wire d5,
    input wire d6,
    input wire d7
);

    /* Captured byte stream and per-byte RS. */
    reg [7:0]  bytes    [0:31];
    reg        rs_flags [0:31];
    integer    byte_cnt;

    /* Nibble assembly state. */
    reg [3:0]  high_nib;
    reg        have_high;
    reg        rs_high_nib;
    reg        e_was_high;   /* gate against the X→0 phantom at reset */

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) begin
            bytes[i]    = 8'h00;
            rs_flags[i] = 1'b0;
        end
        byte_cnt    = 0;
        have_high   = 1'b0;
        high_nib    = 4'h0;
        rs_high_nib = 1'b0;
        e_was_high  = 1'b0;
    end

    wire [3:0] sampled_nib = {d7, d6, d5, d4};

    /* Only consider an E pulse "real" once we've actually seen E=1.  This
     * filters the X→0 phantom transition that occurs at reset deassert
     * when GPIO_OUT is initialised to 0. */
    always @(posedge e) e_was_high = 1'b1;

    /* HD44780 latches data on the falling edge of E. */
    always @(negedge e) if (e_was_high) begin
        if (!have_high) begin
            high_nib    = sampled_nib;
            rs_high_nib = rs;
            have_high   = 1'b1;
        end else begin
            if (byte_cnt < 32) begin
                bytes[byte_cnt]    = {high_nib, sampled_nib};
                /* RS should be stable across both nibbles for a given
                 * byte; we record the high-nibble RS to make that
                 * explicit. */
                rs_flags[byte_cnt] = rs_high_nib;
                byte_cnt           = byte_cnt + 1;
            end
            have_high = 1'b0;
        end
    end

endmodule

`default_nettype wire
