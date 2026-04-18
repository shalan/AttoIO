/*
 * uart_rx_model — oversampling UART receiver model for testbenches.
 *
 * Samples rx_line on every posedge of a supplied `sample_clk` at
 * SAMPLES_PER_BIT ticks per UART bit (16 is standard).  The decoder
 * is a classic edge-of-start + mid-bit sampling state machine and is
 * therefore immune to re-entrancy problems of @(negedge) models.
 */

module uart_rx_model #(
    parameter integer SAMPLES_PER_BIT = 16
) (
    input  wire       sample_clk,
    input  wire       rx_line,
    output reg  [7:0] byte_out,
    output reg        byte_valid,
    output reg        frame_err
);

    localparam S_IDLE  = 3'd0;
    localparam S_START = 3'd1;
    localparam S_DATA  = 3'd2;
    localparam S_STOP  = 3'd3;

    reg [2:0]  state;
    reg [4:0]  sample_cnt;   /* 0..SAMPLES_PER_BIT-1 */
    reg [3:0]  bit_idx;      /* 0..8 */
    reg [7:0]  shreg;
    reg [4:0]  idle_cnt;     /* counts consecutive high samples before
                              * the model arms for a start bit */
    reg        armed;

    initial begin
        state      = S_IDLE;
        sample_cnt = 0;
        bit_idx    = 0;
        shreg      = 0;
        byte_out   = 0;
        byte_valid = 0;
        frame_err  = 0;
        idle_cnt   = 0;
        armed      = 1'b0;
    end

    always @(posedge sample_clk) begin
        byte_valid <= 1'b0;

        /* The model only starts looking for frames after rx_line has
         * been idle-high for at least one full bit-time (rejects the
         * spurious all-zero pseudo-frames that appear before the DUT
         * brings pad_out[0] high during boot). Once armed, stays
         * armed — between bytes the natural stop bit re-aligns us. */
        if (!armed) begin
            if (rx_line === 1'b1) begin
                if (idle_cnt < SAMPLES_PER_BIT)
                    idle_cnt <= idle_cnt + 1;
                else
                    armed <= 1'b1;
            end else begin
                idle_cnt <= 0;
            end
        end

        case (state)
            S_IDLE: begin
                if (armed && rx_line === 1'b0) begin
                    state      <= S_START;
                    sample_cnt <= 0;
                end
            end
            S_START: begin
                /* Mid-start-bit check at sample SAMPLES_PER_BIT/2. */
                if (sample_cnt == SAMPLES_PER_BIT / 2) begin
                    if (rx_line !== 1'b0) begin
                        /* Noise: return to idle. */
                        state <= S_IDLE;
                    end else begin
                        state      <= S_DATA;
                        sample_cnt <= 0;
                        bit_idx    <= 0;
                    end
                end else begin
                    sample_cnt <= sample_cnt + 1;
                end
            end
            S_DATA: begin
                if (sample_cnt == SAMPLES_PER_BIT - 1) begin
                    shreg      <= {rx_line, shreg[7:1]};   /* LSB first */
                    sample_cnt <= 0;
                    if (bit_idx == 4'd7) begin
                        state <= S_STOP;
                    end else begin
                        bit_idx <= bit_idx + 1;
                    end
                end else begin
                    sample_cnt <= sample_cnt + 1;
                end
            end
            S_STOP: begin
                if (sample_cnt == SAMPLES_PER_BIT - 1) begin
                    byte_out   <= shreg;
                    byte_valid <= 1'b1;
                    frame_err  <= (rx_line !== 1'b1);
                    sample_cnt <= 0;
                    state      <= S_IDLE;
                end else begin
                    sample_cnt <= sample_cnt + 1;
                end
            end
            default: state <= S_IDLE;
        endcase
    end

endmodule
