/******************************************************************************/
// attoio_gpio — GPIO registers, PADCTL, input synchronizers, wake system
//
// MMIO register map (IOP view, offsets from 0x300):
//   0x00  GPIO_IN       RO    [15:0]  synchronized pad inputs
//   0x04  GPIO_OUT      RW    [15:0]  output data
//   0x08  GPIO_OE       RW    [15:0]  output enable
//   0x0C  GPIO_OUT_SET  W1S   [15:0]
//   0x10  GPIO_OUT_CLR  W1C   [15:0]
//   0x14  GPIO_OE_SET   W1S   [15:0]
//   0x18  GPIO_OE_CLR   W1C   [15:0]
//   0x20  PADCTL[0]     RW    [7:0]   ... through ...
//   0x5C  PADCTL[15]    RW    [7:0]
//   0x60  WAKE_LATCH    RO    [0]     = |(WAKE_FLAGS & WAKE_MASK).
//                                       Writing any value W1C-clears ALL
//                                       WAKE_FLAGS bits (legacy behavior).
//   0x64  WAKE_FLAGS    R/W1C [15:0]  per-pin sticky edge flag
//   0x68  WAKE_MASK     RW    [15:0]  per-pin enable (1 = contributes to
//                                       WAKE_LATCH and the IRQ OR)
//   0x6C  WAKE_EDGE     RW    [31:0]  per-pin edge mode: 2 bits per pad
//                                       00 = off, 01 = rising, 10 = falling,
//                                       11 = both edges
//
// Decode uses mmio_addr[7:2] (word offset within the 256 B MMIO page).
//
// Input synchronizers and wake flags run on sysclk.
// GPIO_OUT, GPIO_OE, PADCTL, WAKE_MASK, WAKE_EDGE run on clk_iop (config
// writes from firmware) but are sampled on sysclk. Because clk_iop edges
// are a strict subset of sysclk edges (external divider), no CDC flops
// are required — the config value is coherent on every sysclk tick.
/******************************************************************************/

module attoio_gpio #(
    parameter NGPIO = 16
) (
    input  wire                    sysclk,
    input  wire                    clk_iop,
    input  wire                    rst_n,

    // ---- IOP MMIO bus (active on clk_iop) ----
    input  wire [7:0]              mmio_addr,
    input  wire [31:0]             mmio_wdata,
    input  wire [3:0]              mmio_wmask,
    input  wire                    mmio_wen,
    input  wire                    mmio_ren,
    output reg  [31:0]             mmio_rdata,

    // ---- Wake latch output (active on sysclk) ----
    output wire                    wake_latch,

    // ---- SPI pin override (from attoio_spi) ----
    input  wire                    spi_active,
    input  wire [$clog2(NGPIO)-1:0] spi_sck_pin,
    input  wire [$clog2(NGPIO)-1:0] spi_mosi_pin,
    input  wire                    spi_sck_val,
    input  wire                    spi_mosi_val,

    // ---- Pad interface ----
    input  wire [NGPIO-1:0]        pad_in,
    output wire [NGPIO-1:0]        pad_out,
    output wire [NGPIO-1:0]        pad_oe,
    output wire [NGPIO*8-1:0]      pad_ctl
);

    initial begin
        if (NGPIO != 8 && NGPIO != 16) begin
            $display("attoio_gpio: NGPIO must be 8 or 16, got %0d", NGPIO);
            $fatal;
        end
    end

    // ====================================================================
    // GPIO registers (clk_iop domain)
    // ====================================================================
    reg [NGPIO-1:0] gpio_out_r;
    reg [NGPIO-1:0] gpio_oe_r;

    // PADCTL: NGPIO x 8 bits
    reg [7:0] padctl_r [0:NGPIO-1];

    integer k;

    // ====================================================================
    // Input synchronizers (sysclk domain) — 2-flop
    // ====================================================================
    reg [NGPIO-1:0] pad_in_sync1;
    reg [NGPIO-1:0] pad_in_sync2;
    reg [NGPIO-1:0] pad_in_prev;     // for edge detection

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            pad_in_sync1 <= {NGPIO{1'b0}};
            pad_in_sync2 <= {NGPIO{1'b0}};
            pad_in_prev  <= {NGPIO{1'b0}};
        end else begin
            pad_in_sync1 <= pad_in;
            pad_in_sync2 <= pad_in_sync1;
            pad_in_prev  <= pad_in_sync2;
        end
    end

    // ====================================================================
    // Wake system (sysclk domain)
    // ====================================================================
    //   WAKE_FLAGS[p]       set on configured edge; cleared by W1C
    //   WAKE_MASK[p]        per-pin enable into wake_latch OR
    //   WAKE_EDGE[2p+1:2p]  00=off 01=rise 10=fall 11=both
    // ====================================================================
    reg  [NGPIO-1:0]     wake_flags_r;
    reg  [NGPIO-1:0]     wake_mask_r;
    reg  [NGPIO*2-1:0]   wake_edge_r;

    // Per-pin edge event computed on sysclk
    wire [NGPIO-1:0] rise_evt = pad_in_sync2 & ~pad_in_prev;
    wire [NGPIO-1:0] fall_evt = ~pad_in_sync2 &  pad_in_prev;

    reg  [NGPIO-1:0] wake_event;
    integer     pi;
    always @(*) begin
        for (pi = 0; pi < NGPIO; pi = pi + 1) begin
            case (wake_edge_r[2*pi +: 2])
                2'b01:   wake_event[pi] = rise_evt[pi];
                2'b10:   wake_event[pi] = fall_evt[pi];
                2'b11:   wake_event[pi] = rise_evt[pi] | fall_evt[pi];
                default: wake_event[pi] = 1'b0;
            endcase
        end
    end

    // W1C clear pulses from IOP — set for one clk_iop cycle when firmware
    // writes. Because clk_iop edges align with sysclk edges, sysclk picks
    // up the same cycle's value deterministically.
    reg              wake_clear_all;    // legacy WAKE_LATCH write clears all flags
    reg [NGPIO-1:0]  wake_clear_mask;   // per-pin W1C on WAKE_FLAGS

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n)
            wake_flags_r <= {NGPIO{1'b0}};
        else begin
            // W1C takes priority, but sticky flags still set on same edge.
            wake_flags_r <= (wake_flags_r &
                             ~(wake_clear_all ? {NGPIO{1'b1}} : wake_clear_mask))
                            | wake_event;
        end
    end

    assign wake_latch = |(wake_flags_r & wake_mask_r);

    // ====================================================================
    // MMIO register decode (word offset = mmio_addr[7:2])
    // ====================================================================
    wire [5:0] word_off = mmio_addr[7:2];

    // Word offsets within the MMIO page:
    localparam W_GPIO_IN      = 6'h00;
    localparam W_GPIO_OUT     = 6'h01;
    localparam W_GPIO_OE      = 6'h02;
    localparam W_GPIO_OUT_SET = 6'h03;
    localparam W_GPIO_OUT_CLR = 6'h04;
    localparam W_GPIO_OE_SET  = 6'h05;
    localparam W_GPIO_OE_CLR  = 6'h06;
    // PADCTL[0..NGPIO-1] begins at word 0x08 (byte offset 0x20).
    localparam W_PADCTL_BASE  = 6'h08;
    localparam [5:0] W_PADCTL_END = 6'h08 + NGPIO - 1;  // 0x17 @ NGPIO=16, 0x0F @ 8
    localparam W_WAKE_LATCH   = 6'h18;
    localparam W_WAKE_FLAGS   = 6'h19;
    localparam W_WAKE_MASK    = 6'h1A;
    localparam W_WAKE_EDGE    = 6'h1B;

    // PADCTL index — low log2(NGPIO) bits of the word offset.
    localparam PINW = $clog2(NGPIO);
    wire [PINW-1:0] padctl_idx = word_off[PINW-1:0];
    wire padctl_sel = (word_off >= W_PADCTL_BASE) && (word_off <= W_PADCTL_END);

    // ====================================================================
    // Writes (clk_iop domain)
    // ====================================================================
    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n) begin
            gpio_out_r      <= {NGPIO{1'b0}};
            gpio_oe_r       <= {NGPIO{1'b0}};
            wake_clear_all  <= 1'b0;
            wake_clear_mask <= {NGPIO{1'b0}};
            wake_mask_r     <= {NGPIO{1'b0}};
            wake_edge_r     <= {(NGPIO*2){1'b0}};
            for (k = 0; k < NGPIO; k = k + 1)
                padctl_r[k] <= 8'h0;
        end else begin
            // pulse defaults
            wake_clear_all  <= 1'b0;
            wake_clear_mask <= {NGPIO{1'b0}};

            if (mmio_wen) begin
                case (word_off)
                    W_GPIO_OUT:     gpio_out_r <= mmio_wdata[NGPIO-1:0];
                    W_GPIO_OE:      gpio_oe_r  <= mmio_wdata[NGPIO-1:0];
                    W_GPIO_OUT_SET: gpio_out_r <= gpio_out_r | mmio_wdata[NGPIO-1:0];
                    W_GPIO_OUT_CLR: gpio_out_r <= gpio_out_r & ~mmio_wdata[NGPIO-1:0];
                    W_GPIO_OE_SET:  gpio_oe_r  <= gpio_oe_r  | mmio_wdata[NGPIO-1:0];
                    W_GPIO_OE_CLR:  gpio_oe_r  <= gpio_oe_r  & ~mmio_wdata[NGPIO-1:0];
                    W_WAKE_LATCH:   wake_clear_all  <= 1'b1;
                    W_WAKE_FLAGS:   wake_clear_mask <= mmio_wdata[NGPIO-1:0];
                    W_WAKE_MASK:    wake_mask_r     <= mmio_wdata[NGPIO-1:0];
                    W_WAKE_EDGE:    wake_edge_r     <= mmio_wdata[NGPIO*2-1:0];
                    default: begin
                        if (padctl_sel)
                            padctl_r[padctl_idx] <= mmio_wdata[7:0];
                    end
                endcase
            end
        end
    end

    // ====================================================================
    // Reads (combinational, clk_iop domain)
    // ====================================================================
    // Zero-pad widths (32 - NGPIO for most, 32 - 2*NGPIO for WAKE_EDGE).
    localparam NPAD  = 32 - NGPIO;
    localparam EPAD  = 32 - 2*NGPIO;

    always @(*) begin
        mmio_rdata = 32'h0;
        case (word_off)
            W_GPIO_IN:      mmio_rdata = {{NPAD{1'b0}}, pad_in_sync2};
            W_GPIO_OUT:     mmio_rdata = {{NPAD{1'b0}}, gpio_out_r};
            W_GPIO_OE:      mmio_rdata = {{NPAD{1'b0}}, gpio_oe_r};
            W_GPIO_OUT_SET: mmio_rdata = {{NPAD{1'b0}}, gpio_out_r};
            W_GPIO_OUT_CLR: mmio_rdata = {{NPAD{1'b0}}, gpio_out_r};
            W_GPIO_OE_SET:  mmio_rdata = {{NPAD{1'b0}}, gpio_oe_r};
            W_GPIO_OE_CLR:  mmio_rdata = {{NPAD{1'b0}}, gpio_oe_r};
            W_WAKE_LATCH:   mmio_rdata = {31'h0, wake_latch};
            W_WAKE_FLAGS:   mmio_rdata = {{NPAD{1'b0}}, wake_flags_r};
            W_WAKE_MASK:    mmio_rdata = {{NPAD{1'b0}}, wake_mask_r};
            W_WAKE_EDGE:    mmio_rdata = {{EPAD{1'b0}}, wake_edge_r};
            default: begin
                if (padctl_sel)
                    mmio_rdata = {24'h0, padctl_r[padctl_idx]};
            end
        endcase
    end

    // ====================================================================
    // Pad outputs — SPI override when active
    // ====================================================================
    reg [NGPIO-1:0] gpio_out_final;
    integer p;
    always @(*) begin
        gpio_out_final = gpio_out_r;
        if (spi_active) begin
            gpio_out_final[spi_sck_pin]  = spi_sck_val;
            gpio_out_final[spi_mosi_pin] = spi_mosi_val;
        end
    end

    assign pad_out = gpio_out_final;
    assign pad_oe  = gpio_oe_r;

    // PADCTL flat output
    genvar g;
    generate
        for (g = 0; g < NGPIO; g = g + 1) begin : gen_padctl
            assign pad_ctl[g*8 +: 8] = padctl_r[g];
        end
    endgenerate

endmodule
