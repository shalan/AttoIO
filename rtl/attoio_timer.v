/******************************************************************************/
// attoio_timer — 24-bit free-running timer + 4 compares + 1 input capture.
//
// Clocked by clk_iop. Provides:
//   - Free-running 24-bit counter with optional auto-reload on CMP0 match
//     (gives a periodic carrier useful for PWM / sample-rate ISR).
//   - 4 independent compare channels. Each can:
//       * raise a per-channel match flag (sticky, R/W1C),
//       * request an IRQ (OR'd into timer_irq),
//       * toggle one of the 16 pads (implements hardware PWM / carrier).
//   - 1 input-capture channel: on the selected pad's rising, falling, or
//     both edges, CNT is copied into CAP and the capture flag raises.
//
// Register map (word offsets within the 0x300 MMIO page):
//   0x28  TIMER_CNT      RO   [23:0] current count
//   0x29  TIMER_CTL      RW   [0]=enable  [1]=write-1 reset  [2]=auto_reload
//                             [6:3]=capture pad idx  [8:7]=cap edge
//                             [9]=capture IRQ enable
//   0x2A  TIMER_STATUS   RW1C [0..3]=match_flag0..3  [4]=capture flag
//   0x2B  TIMER_CAP      RO   [23:0] last captured count
//   0x2C  TIMER_CMP0     RW   [23:0]=match value  [27:24]=pad idx
//                             [28]=enable   [29]=IRQ en   [30]=pad toggle en
//   0x2D  TIMER_CMP1     RW   same layout
//   0x2E  TIMER_CMP2     RW   same layout
//   0x2F  TIMER_CMP3     RW   same layout
//
// IRQ is asserted while any (match_flag_i & cmp_irq_en_i) or (cap_flag &
// cap_irq_en) is set.
//
// Pad driving: for each CMP channel with cmp_pad_tog_en=1, the output
// pad timer_pad_drive[pad_idx] is toggled on every match pulse. That
// pad is also flagged in timer_pad_sel[] so the macro top-level can
// override the normal GPIO_OUT path with timer_pad_val on that pin.
/******************************************************************************/

module attoio_timer (
    input  wire        clk_iop,
    input  wire        rst_n,

    // MMIO (slice of the 0x300 page; only responds when mmio_is_timer = 1)
    input  wire [5:0]  mmio_woff,       // word offset within the MMIO page
    input  wire [31:0] mmio_wdata,
    input  wire [3:0]  mmio_wmask,      // unused — word writes only
    input  wire        mmio_wen,
    input  wire        mmio_ren,        // unused — read is combinational
    output reg  [31:0] mmio_rdata,

    // Synchronized pad inputs (from attoio_gpio.pad_in_sync_iop)
    input  wire [15:0] pad_in_sync,

    // Interrupt
    output wire        timer_irq,

    // Pad override — the macro top-level picks these up when
    // timer_pad_sel[p] is 1, using timer_pad_val[p] as the pad value.
    output wire [15:0] timer_pad_sel,
    output wire [15:0] timer_pad_val
);

    // ================================================================
    // Addressing
    // ================================================================
    localparam W_TIMER_CNT    = 6'h28;
    localparam W_TIMER_CTL    = 6'h29;
    localparam W_TIMER_STATUS = 6'h2A;
    localparam W_TIMER_CAP    = 6'h2B;
    localparam W_TIMER_CMP0   = 6'h2C;
    localparam W_TIMER_CMP1   = 6'h2D;
    localparam W_TIMER_CMP2   = 6'h2E;
    localparam W_TIMER_CMP3   = 6'h2F;

    wire in_range = (mmio_woff >= 6'h28) && (mmio_woff <= 6'h2F);

    // ================================================================
    // Counter + control
    // ================================================================
    reg [23:0] cnt;
    reg        en;
    reg        auto_reload;
    reg [3:0]  cap_pad_idx;
    reg [1:0]  cap_edge;
    reg        cap_irq_en;

    // ================================================================
    // Capture
    // ================================================================
    reg [23:0] cap_val;
    reg        cap_flag;

    // Previous pad_in_sync, for edge detection on the selected pin
    reg [15:0] pad_in_prev;
    wire       cap_pin       = pad_in_sync[cap_pad_idx];
    wire       cap_pin_prev  = pad_in_prev[cap_pad_idx];
    wire       cap_rise      = cap_pin & ~cap_pin_prev;
    wire       cap_fall      = ~cap_pin & cap_pin_prev;
    wire       cap_event     = (cap_edge == 2'b01 && cap_rise) ||
                               (cap_edge == 2'b10 && cap_fall) ||
                               (cap_edge == 2'b11 && (cap_rise | cap_fall));

    // ================================================================
    // Compare channels
    // ================================================================
    reg [23:0] cmp_val       [0:3];
    reg [3:0]  cmp_pad_idx   [0:3];
    reg        cmp_en        [0:3];
    reg        cmp_irq_en    [0:3];
    reg        cmp_pad_tog   [0:3];
    reg        cmp_flag      [0:3];

    // Per-pad timer output value (flip-flop per pad, toggled by compare
    // events). Also per-pad selection bitmap (OR of all cmp_pad_tog for
    // channels that target this pad).
    reg  [15:0] pad_val_r;
    wire [15:0] pad_sel_r;

    genvar p;
    generate
        for (p = 0; p < 16; p = p + 1) begin : gen_pad_sel
            assign pad_sel_r[p] =
                (cmp_en[0] && cmp_pad_tog[0] && cmp_pad_idx[0] == p[3:0]) ||
                (cmp_en[1] && cmp_pad_tog[1] && cmp_pad_idx[1] == p[3:0]) ||
                (cmp_en[2] && cmp_pad_tog[2] && cmp_pad_idx[2] == p[3:0]) ||
                (cmp_en[3] && cmp_pad_tog[3] && cmp_pad_idx[3] == p[3:0]);
        end
    endgenerate

    assign timer_pad_sel = pad_sel_r;
    assign timer_pad_val = pad_val_r;

    // ================================================================
    // Match detection
    // ================================================================
    wire match0 = en & cmp_en[0] & (cnt == cmp_val[0]);
    wire match1 = en & cmp_en[1] & (cnt == cmp_val[1]);
    wire match2 = en & cmp_en[2] & (cnt == cmp_val[2]);
    wire match3 = en & cmp_en[3] & (cnt == cmp_val[3]);

    // ================================================================
    // Per-pad match aggregation (which pad toggles this cycle)
    // ================================================================
    reg  [15:0] pad_toggle_mask;
    integer ch;
    always @(*) begin
        pad_toggle_mask = 16'h0;
        if (match0 && cmp_pad_tog[0]) pad_toggle_mask[cmp_pad_idx[0]] = 1'b1;
        if (match1 && cmp_pad_tog[1]) pad_toggle_mask[cmp_pad_idx[1]] = 1'b1;
        if (match2 && cmp_pad_tog[2]) pad_toggle_mask[cmp_pad_idx[2]] = 1'b1;
        if (match3 && cmp_pad_tog[3]) pad_toggle_mask[cmp_pad_idx[3]] = 1'b1;
        // suppress lint: ch is used below
        ch = 0;
    end

    // ================================================================
    // Writes / state updates
    // ================================================================
    integer i;
    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n) begin
            cnt         <= 24'h0;
            en          <= 1'b0;
            auto_reload <= 1'b0;
            cap_pad_idx <= 4'h0;
            cap_edge    <= 2'b00;
            cap_irq_en  <= 1'b0;
            cap_val     <= 24'h0;
            cap_flag    <= 1'b0;
            pad_in_prev <= 16'h0;
            pad_val_r   <= 16'h0;
            for (i = 0; i < 4; i = i + 1) begin
                cmp_val[i]     <= 24'h0;
                cmp_pad_idx[i] <= 4'h0;
                cmp_en[i]      <= 1'b0;
                cmp_irq_en[i]  <= 1'b0;
                cmp_pad_tog[i] <= 1'b0;
                cmp_flag[i]    <= 1'b0;
            end
        end else begin
            // ----- Counter advance (combined with reset-on-write and auto-reload)
            if (en) begin
                if (auto_reload && match0)
                    cnt <= 24'h0;
                else
                    cnt <= cnt + 24'h1;
            end

            // ----- Edge-detect: sample previous pad values for capture
            pad_in_prev <= pad_in_sync;

            // ----- Capture
            if (cap_event) begin
                cap_val  <= cnt;
                cap_flag <= 1'b1;
            end

            // ----- Match flags set (sticky)
            if (match0) cmp_flag[0] <= 1'b1;
            if (match1) cmp_flag[1] <= 1'b1;
            if (match2) cmp_flag[2] <= 1'b1;
            if (match3) cmp_flag[3] <= 1'b1;

            // ----- Pad toggle on match
            pad_val_r <= pad_val_r ^ pad_toggle_mask;

            // ----- Writes
            if (mmio_wen && in_range) begin
                case (mmio_woff)
                    W_TIMER_CTL: begin
                        en          <= mmio_wdata[0];
                        if (mmio_wdata[1]) cnt <= 24'h0;   // write-1 reset
                        auto_reload <= mmio_wdata[2];
                        cap_pad_idx <= mmio_wdata[6:3];
                        cap_edge    <= mmio_wdata[8:7];
                        cap_irq_en  <= mmio_wdata[9];
                    end
                    W_TIMER_STATUS: begin
                        // R/W1C
                        if (mmio_wdata[0]) cmp_flag[0] <= 1'b0;
                        if (mmio_wdata[1]) cmp_flag[1] <= 1'b0;
                        if (mmio_wdata[2]) cmp_flag[2] <= 1'b0;
                        if (mmio_wdata[3]) cmp_flag[3] <= 1'b0;
                        if (mmio_wdata[4]) cap_flag    <= 1'b0;
                    end
                    W_TIMER_CMP0: begin
                        cmp_val[0]     <= mmio_wdata[23:0];
                        cmp_pad_idx[0] <= mmio_wdata[27:24];
                        cmp_en[0]      <= mmio_wdata[28];
                        cmp_irq_en[0]  <= mmio_wdata[29];
                        cmp_pad_tog[0] <= mmio_wdata[30];
                    end
                    W_TIMER_CMP1: begin
                        cmp_val[1]     <= mmio_wdata[23:0];
                        cmp_pad_idx[1] <= mmio_wdata[27:24];
                        cmp_en[1]      <= mmio_wdata[28];
                        cmp_irq_en[1]  <= mmio_wdata[29];
                        cmp_pad_tog[1] <= mmio_wdata[30];
                    end
                    W_TIMER_CMP2: begin
                        cmp_val[2]     <= mmio_wdata[23:0];
                        cmp_pad_idx[2] <= mmio_wdata[27:24];
                        cmp_en[2]      <= mmio_wdata[28];
                        cmp_irq_en[2]  <= mmio_wdata[29];
                        cmp_pad_tog[2] <= mmio_wdata[30];
                    end
                    W_TIMER_CMP3: begin
                        cmp_val[3]     <= mmio_wdata[23:0];
                        cmp_pad_idx[3] <= mmio_wdata[27:24];
                        cmp_en[3]      <= mmio_wdata[28];
                        cmp_irq_en[3]  <= mmio_wdata[29];
                        cmp_pad_tog[3] <= mmio_wdata[30];
                    end
                    default: ;
                endcase
            end
        end
    end

    // ================================================================
    // Reads (combinational)
    // ================================================================
    always @(*) begin
        mmio_rdata = 32'h0;
        case (mmio_woff)
            W_TIMER_CNT:    mmio_rdata = {8'h0, cnt};
            W_TIMER_CTL:    mmio_rdata = {22'h0, cap_irq_en, cap_edge,
                                          cap_pad_idx, auto_reload,
                                          1'b0 /* reset is W1, reads 0 */,
                                          en};
            W_TIMER_STATUS: mmio_rdata = {27'h0, cap_flag,
                                          cmp_flag[3], cmp_flag[2],
                                          cmp_flag[1], cmp_flag[0]};
            W_TIMER_CAP:    mmio_rdata = {8'h0, cap_val};
            W_TIMER_CMP0:   mmio_rdata = {1'b0, cmp_pad_tog[0], cmp_irq_en[0],
                                          cmp_en[0], cmp_pad_idx[0], cmp_val[0]};
            W_TIMER_CMP1:   mmio_rdata = {1'b0, cmp_pad_tog[1], cmp_irq_en[1],
                                          cmp_en[1], cmp_pad_idx[1], cmp_val[1]};
            W_TIMER_CMP2:   mmio_rdata = {1'b0, cmp_pad_tog[2], cmp_irq_en[2],
                                          cmp_en[2], cmp_pad_idx[2], cmp_val[2]};
            W_TIMER_CMP3:   mmio_rdata = {1'b0, cmp_pad_tog[3], cmp_irq_en[3],
                                          cmp_en[3], cmp_pad_idx[3], cmp_val[3]};
            default:        mmio_rdata = 32'h0;
        endcase
    end

    // ================================================================
    // IRQ
    // ================================================================
    assign timer_irq =
        (cmp_flag[0] & cmp_irq_en[0]) |
        (cmp_flag[1] & cmp_irq_en[1]) |
        (cmp_flag[2] & cmp_irq_en[2]) |
        (cmp_flag[3] & cmp_irq_en[3]) |
        (cap_flag    & cap_irq_en);

endmodule
