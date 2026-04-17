/******************************************************************************/
// attoio_gpio — GPIO registers, PADCTL, input synchronizers, WAKE_LATCH
//
// MMIO register map (IOP view, offsets from 0x300):
//   0x00  GPIO_IN       RO   [15:0]  synchronized pad inputs
//   0x04  GPIO_OUT      RW   [15:0]  output data
//   0x08  GPIO_OE       RW   [15:0]  output enable
//   0x0C  GPIO_OUT_SET  W1S  [15:0]  atomic set
//   0x10  GPIO_OUT_CLR  W1C  [15:0]  atomic clear
//   0x14  GPIO_OE_SET   W1S  [15:0]  atomic set
//   0x18  GPIO_OE_CLR   W1C  [15:0]  atomic clear
//   0x20  PADCTL[0]     RW   [7:0]   ... through ...
//   0x5C  PADCTL[15]    RW   [7:0]
//   0x60  WAKE_LATCH    R/W1C [0]
//
// Decode uses mmio_addr[7:2] (word offset within the 256 B MMIO page).
//
// Input synchronizers and WAKE_LATCH run on sysclk.
// GPIO_OUT, GPIO_OE, PADCTL run on clk_iop.
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
    // WAKE_LATCH (sysclk domain)
    // Set when any pad edge is detected. Cleared by IOP W1C.
    // ====================================================================
    reg wake_latch_r;
    wire [15:0] edges = pad_in_sync2 ^ pad_in_prev;
    wire edge_any = |edges;

    // W1C clear from IOP — need to synchronize the clear pulse from
    // clk_iop to sysclk. Since clk_iop edges are a subset of sysclk
    // edges, the pulse is inherently aligned.
    reg wake_clear;

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n)
            wake_latch_r <= 1'b0;
        else if (wake_clear)
            wake_latch_r <= 1'b0;
        else if (edge_any)
            wake_latch_r <= 1'b1;
    end

    assign wake_latch = wake_latch_r;

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
    localparam W_WAKE_LATCH   = 6'h18;   // 0x360 -> offset 0x60

    // PADCTL index
    wire [3:0] padctl_idx = word_off[3:0]; // 0..15 within PADCTL range
    wire padctl_sel = (word_off >= W_PADCTL_BASE) && (word_off <= W_PADCTL_END);

    // ====================================================================
    // Writes (clk_iop domain)
    // ====================================================================
    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n) begin
            gpio_out_r <= 16'h0;
            gpio_oe_r  <= 16'h0;
            wake_clear <= 1'b0;
            for (k = 0; k < 16; k = k + 1)
                padctl_r[k] <= 8'h0;
        end else begin
            wake_clear <= 1'b0;

            if (mmio_wen) begin
                case (word_off)
                    W_GPIO_OUT:     gpio_out_r <= mmio_wdata[15:0];
                    W_GPIO_OE:      gpio_oe_r  <= mmio_wdata[15:0];
                    W_GPIO_OUT_SET: gpio_out_r <= gpio_out_r | mmio_wdata[15:0];
                    W_GPIO_OUT_CLR: gpio_out_r <= gpio_out_r & ~mmio_wdata[15:0];
                    W_GPIO_OE_SET:  gpio_oe_r  <= gpio_oe_r  | mmio_wdata[15:0];
                    W_GPIO_OE_CLR:  gpio_oe_r  <= gpio_oe_r  & ~mmio_wdata[15:0];
                    W_WAKE_LATCH: begin
                        if (mmio_wdata[0])
                            wake_clear <= 1'b1;
                    end
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
            W_GPIO_OUT_SET: mmio_rdata = {16'h0, gpio_out_r};  // reads as OUT
            W_GPIO_OUT_CLR: mmio_rdata = {16'h0, gpio_out_r};  // reads as OUT
            W_GPIO_OE_SET:  mmio_rdata = {16'h0, gpio_oe_r};   // reads as OE
            W_GPIO_OE_CLR:  mmio_rdata = {16'h0, gpio_oe_r};   // reads as OE
            W_WAKE_LATCH:   mmio_rdata = {31'h0, wake_latch_r};
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
