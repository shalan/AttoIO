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

module attoio_gpio (
    input  wire        sysclk,
    input  wire        clk_iop,
    input  wire        rst_n,

    // ---- IOP MMIO bus (active on clk_iop) ----
    input  wire [7:0]  mmio_addr,       // byte offset within 0x300 page
    input  wire [31:0] mmio_wdata,
    input  wire [3:0]  mmio_wmask,
    input  wire        mmio_wen,        // write enable
    input  wire        mmio_ren,        // read enable
    output reg  [31:0] mmio_rdata,

    // ---- Wake latch output (active on sysclk) ----
    output wire        wake_latch,

    // ---- SPI pin override (from attoio_spi) ----
    input  wire        spi_active,
    input  wire [3:0]  spi_sck_pin,     // which GPIO pin is SCK
    input  wire [3:0]  spi_mosi_pin,    // which GPIO pin is MOSI
    input  wire        spi_sck_val,
    input  wire        spi_mosi_val,

    // ---- Pad interface ----
    input  wire [15:0] pad_in,
    output wire [15:0] pad_out,
    output wire [15:0] pad_oe,
    output wire [127:0] pad_ctl
);

    // ====================================================================
    // GPIO registers (clk_iop domain)
    // ====================================================================
    reg [15:0] gpio_out_r;
    reg [15:0] gpio_oe_r;

    // PADCTL: 16 x 8 bits
    reg [7:0] padctl_r [0:15];

    integer k;

    // ====================================================================
    // Input synchronizers (sysclk domain) — 2-flop
    // ====================================================================
    reg [15:0] pad_in_sync1;
    reg [15:0] pad_in_sync2;
    reg [15:0] pad_in_prev;     // for edge detection

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            pad_in_sync1 <= 16'h0;
            pad_in_sync2 <= 16'h0;
            pad_in_prev  <= 16'h0;
        end else begin
            pad_in_sync1 <= pad_in;
            pad_in_sync2 <= pad_in_sync1;
            pad_in_prev  <= pad_in_sync2;
        end
    end

    // ====================================================================
    // Wake system (sysclk domain)
    // ====================================================================
    //   WAKE_FLAGS[p]  sets when the configured edge on pad[p] occurs,
    //                  cleared by W1C or by a legacy write to WAKE_LATCH.
    //   WAKE_MASK[p]   per-pin enable. Wake contributes to the IRQ OR
    //                  only if mask[p] = 1.
    //   WAKE_EDGE[2p+1:2p]  00=off 01=rise 10=fall 11=both.
    // ====================================================================
    reg  [15:0] wake_flags_r;
    reg  [15:0] wake_mask_r;
    reg  [31:0] wake_edge_r;

    // Per-pin edge event computed on sysclk
    wire [15:0] rise_evt = pad_in_sync2 & ~pad_in_prev;
    wire [15:0] fall_evt = ~pad_in_sync2 &  pad_in_prev;

    reg  [15:0] wake_event;   // combinational: which pins had a qualifying edge
    integer     pi;
    always @(*) begin
        for (pi = 0; pi < 16; pi = pi + 1) begin
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
    reg        wake_clear_all;    // legacy WAKE_LATCH write clears all flags
    reg [15:0] wake_clear_mask;   // per-pin W1C on WAKE_FLAGS

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n)
            wake_flags_r <= 16'h0;
        else begin
            // W1C takes priority, but sticky flags still set on same edge.
            wake_flags_r <= (wake_flags_r &
                             ~(wake_clear_all ? 16'hFFFF : wake_clear_mask))
                            | wake_event;
        end
    end

    assign wake_latch = |(wake_flags_r & wake_mask_r);

    // ====================================================================
    // MMIO register decode (word offset = mmio_addr[7:2])
    // ====================================================================
    wire [5:0] word_off = mmio_addr[7:2];

    // Word offsets within the MMIO page:
    localparam W_GPIO_IN      = 6'h00;   // 0x300 -> offset 0x00
    localparam W_GPIO_OUT     = 6'h01;   // 0x304 -> offset 0x04
    localparam W_GPIO_OE      = 6'h02;   // 0x308 -> offset 0x08
    localparam W_GPIO_OUT_SET = 6'h03;   // 0x30C -> offset 0x0C
    localparam W_GPIO_OUT_CLR = 6'h04;   // 0x310 -> offset 0x10
    localparam W_GPIO_OE_SET  = 6'h05;   // 0x314 -> offset 0x14
    localparam W_GPIO_OE_CLR  = 6'h06;   // 0x318 -> offset 0x18
    // PADCTL[0..15] at word offsets 0x08..0x17 (0x320..0x35C)
    localparam W_PADCTL_BASE  = 6'h08;   // 0x320 -> offset 0x20
    localparam W_PADCTL_END   = 6'h17;   // 0x35C -> offset 0x5C
    localparam W_WAKE_LATCH   = 6'h18;   // 0x360 -> offset 0x60 (legacy RO + clear-all W1C)
    localparam W_WAKE_FLAGS   = 6'h19;   // 0x364 -> per-pin sticky flags (R/W1C)
    localparam W_WAKE_MASK    = 6'h1A;   // 0x368 -> per-pin enable (RW)
    localparam W_WAKE_EDGE    = 6'h1B;   // 0x36C -> per-pin edge mode (RW)

    // PADCTL index
    wire [3:0] padctl_idx = word_off[3:0]; // 0..15 within PADCTL range
    wire padctl_sel = (word_off >= W_PADCTL_BASE) && (word_off <= W_PADCTL_END);

    // ====================================================================
    // Writes (clk_iop domain)
    // ====================================================================
    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n) begin
            gpio_out_r      <= 16'h0;
            gpio_oe_r       <= 16'h0;
            wake_clear_all  <= 1'b0;
            wake_clear_mask <= 16'h0;
            wake_mask_r     <= 16'h0;
            wake_edge_r     <= 32'h0;
            for (k = 0; k < 16; k = k + 1)
                padctl_r[k] <= 8'h0;
        end else begin
            // pulse defaults
            wake_clear_all  <= 1'b0;
            wake_clear_mask <= 16'h0;

            if (mmio_wen) begin
                case (word_off)
                    W_GPIO_OUT:     gpio_out_r <= mmio_wdata[15:0];
                    W_GPIO_OE:      gpio_oe_r  <= mmio_wdata[15:0];
                    W_GPIO_OUT_SET: gpio_out_r <= gpio_out_r | mmio_wdata[15:0];
                    W_GPIO_OUT_CLR: gpio_out_r <= gpio_out_r & ~mmio_wdata[15:0];
                    W_GPIO_OE_SET:  gpio_oe_r  <= gpio_oe_r  | mmio_wdata[15:0];
                    W_GPIO_OE_CLR:  gpio_oe_r  <= gpio_oe_r  & ~mmio_wdata[15:0];
                    W_WAKE_LATCH:   wake_clear_all  <= 1'b1;        // legacy clear-all
                    W_WAKE_FLAGS:   wake_clear_mask <= mmio_wdata[15:0]; // per-pin W1C
                    W_WAKE_MASK:    wake_mask_r     <= mmio_wdata[15:0];
                    W_WAKE_EDGE:    wake_edge_r     <= mmio_wdata;
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
    always @(*) begin
        mmio_rdata = 32'h0;
        case (word_off)
            W_GPIO_IN:      mmio_rdata = {16'h0, pad_in_sync2};
            W_GPIO_OUT:     mmio_rdata = {16'h0, gpio_out_r};
            W_GPIO_OE:      mmio_rdata = {16'h0, gpio_oe_r};
            W_GPIO_OUT_SET: mmio_rdata = {16'h0, gpio_out_r};
            W_GPIO_OUT_CLR: mmio_rdata = {16'h0, gpio_out_r};
            W_GPIO_OE_SET:  mmio_rdata = {16'h0, gpio_oe_r};
            W_GPIO_OE_CLR:  mmio_rdata = {16'h0, gpio_oe_r};
            W_WAKE_LATCH:   mmio_rdata = {31'h0, wake_latch};
            W_WAKE_FLAGS:   mmio_rdata = {16'h0, wake_flags_r};
            W_WAKE_MASK:    mmio_rdata = {16'h0, wake_mask_r};
            W_WAKE_EDGE:    mmio_rdata = wake_edge_r;
            default: begin
                if (padctl_sel)
                    mmio_rdata = {24'h0, padctl_r[padctl_idx]};
            end
        endcase
    end

    // ====================================================================
    // Pad outputs — SPI override when active
    // ====================================================================
    reg [15:0] gpio_out_final;
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
        for (g = 0; g < 16; g = g + 1) begin : gen_padctl
            assign pad_ctl[g*8 +: 8] = padctl_r[g];
        end
    endgenerate

endmodule
