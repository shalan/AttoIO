/******************************************************************************/
// attoio_spi — Minimal SPI byte shift helper
//
// MMIO registers (IOP view, offsets from 0x300 base):
//   0x390  SPI_DATA    RW [7:0]  write = load TX + start; read = RX
//   0x394  SPI_CFG     RW [7:0]  [3:0]=SCK pin, [5:4]=MOSI pin(2 LSBs),
//                                 [6]=CPOL, [7]=CPHA
//   0x398  SPI_STATUS  RO [0]    bit 0 = busy
//
// Operation:
//   - Write SPI_CFG once to configure pin mapping and SPI mode.
//   - Write SPI_DATA to load a byte and start shifting.
//   - Shifts MSB-first onto MOSI pin, captures MISO (= MOSI pin + 1) on
//     opposite SCK edge.
//   - 16 clk_iop cycles per byte (2 per bit: SCK toggle + toggle).
//   - After 8 bits, busy clears. Read SPI_DATA for received byte.
//   - While busy, SCK and MOSI pins are overridden in attoio_gpio.
//
// Clocked by clk_iop.
/******************************************************************************/

module attoio_spi (
    input  wire        clk_iop,
    input  wire        rst_n,

    // ---- MMIO interface (clk_iop) ----
    input  wire [5:0]  mmio_woff,       // word offset within MMIO page
    input  wire [31:0] mmio_wdata,
    input  wire        mmio_wen,
    output reg  [31:0] mmio_rdata,
    input  wire        mmio_sel,        // 1 = addressing SPI range

    // ---- GPIO pin sampling (synchronized pad_in, clk_iop domain) ----
    input  wire [15:0] pad_in_sync,

    // ---- Pin override outputs to attoio_gpio ----
    output wire        spi_active,
    output wire [3:0]  spi_sck_pin,
    output wire [3:0]  spi_mosi_pin,
    output wire        spi_sck_val,
    output wire        spi_mosi_val
);

    // Register word offsets (within MMIO page)
    localparam W_SPI_DATA   = 6'h24;   // 0x390 -> offset 0x90 -> word 0x24
    localparam W_SPI_CFG    = 6'h25;   // 0x394 -> offset 0x94 -> word 0x25
    localparam W_SPI_STATUS = 6'h26;   // 0x398 -> offset 0x98 -> word 0x26

    // ====================================================================
    // Configuration register
    // ====================================================================
    reg [7:0] spi_cfg;
    wire [3:0] cfg_sck_pin  = spi_cfg[3:0];
    wire [3:0] cfg_mosi_pin = {2'b00, spi_cfg[5:4]};
    wire [3:0] cfg_miso_pin = cfg_mosi_pin + 4'd1;  // MISO = MOSI + 1
    wire       cfg_cpol     = spi_cfg[6];
    wire       cfg_cpha     = spi_cfg[7];

    // ====================================================================
    // Shift engine state
    // ====================================================================
    reg [7:0] tx_shift;
    reg [7:0] rx_shift;
    reg [3:0] bit_cnt;      // counts 0..15 (2 phases per bit)
    reg       busy;
    reg       sck_r;

    wire phase     = bit_cnt[0];    // 0 = first half, 1 = second half
    wire [2:0] bit_idx = 3'd7 - bit_cnt[3:1]; // MSB first

    // ====================================================================
    // MISO sampling — which SCK edge to capture on depends on CPHA
    // CPHA=0: capture on first (leading) edge of SCK
    // CPHA=1: capture on second (trailing) edge of SCK
    // ====================================================================
    wire capture_phase = cfg_cpha ? 1'b0 : 1'b1;
    wire shift_phase   = cfg_cpha ? 1'b1 : 1'b0;

    // ====================================================================
    // Shift engine (clk_iop)
    // ====================================================================
    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n) begin
            tx_shift <= 8'h0;
            rx_shift <= 8'h0;
            bit_cnt  <= 4'h0;
            busy     <= 1'b0;
            sck_r    <= 1'b0;
            spi_cfg  <= 8'h0;
        end else begin
            // Register writes
            if (mmio_wen && mmio_sel) begin
                case (mmio_woff)
                    W_SPI_CFG: spi_cfg <= mmio_wdata[7:0];
                    W_SPI_DATA: begin
                        if (!busy) begin
                            tx_shift <= mmio_wdata[7:0];
                            rx_shift <= 8'h0;
                            bit_cnt  <= 4'h0;
                            busy     <= 1'b1;
                            sck_r    <= cfg_cpol;   // idle polarity
                        end
                    end
                    default: ;
                endcase
            end

            // Shift engine
            if (busy) begin
                if (phase == shift_phase) begin
                    // Toggle SCK
                    sck_r <= ~sck_r;
                end else begin
                    // Toggle SCK back + capture MISO + advance
                    sck_r <= ~sck_r;
                    rx_shift[bit_idx] <= pad_in_sync[cfg_miso_pin];
                end

                bit_cnt <= bit_cnt + 4'd1;

                if (bit_cnt == 4'd15) begin
                    busy  <= 1'b0;
                    sck_r <= cfg_cpol;   // return to idle
                end
            end
        end
    end

    // ====================================================================
    // MMIO reads (combinational)
    // ====================================================================
    always @(*) begin
        mmio_rdata = 32'h0;
        case (mmio_woff)
            W_SPI_DATA:   mmio_rdata = {24'h0, busy ? tx_shift : rx_shift};
            W_SPI_CFG:    mmio_rdata = {24'h0, spi_cfg};
            W_SPI_STATUS: mmio_rdata = {31'h0, busy};
            default:      mmio_rdata = 32'h0;
        endcase
    end

    // ====================================================================
    // Pin override outputs
    // ====================================================================
    assign spi_active   = busy;
    assign spi_sck_pin  = cfg_sck_pin;
    assign spi_mosi_pin = cfg_mosi_pin;
    assign spi_sck_val  = sck_r;
    assign spi_mosi_val = tx_shift[7 - bit_cnt[3:1]]; // current MSB-first bit

endmodule
