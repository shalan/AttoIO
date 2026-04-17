/******************************************************************************/
// attoio_macro — AttoIO single hard macro
//
// Contains:
//   - AttoRV32 core (RV32EC, minimal config)
//   - SRAM A  (128x32 DFFRAM, 512 B, IOP-private)
//   - SRAM B0 (32x32 DFFRAM, 128 B, mailbox low)
//   - SRAM B1 (32x32 DFFRAM, 128 B, mailbox high)
//   - Memory mux + address decoder + SRAM B arbiter
//   - GPIO + PADCTL + input synchronizers + WAKE_LATCH
//   - SPI shift helper
//   - Doorbells + IOP_CTRL
//
// External interface: see spec.md §3.2
/******************************************************************************/

module attoio_macro (
    // ---- Clocks ----
    input  wire         sysclk,
    input  wire         clk_iop,

    // ---- Reset ----
    input  wire         rst_n,          // active-low, synchronous to sysclk

    // ---- Host bus (generic register slave, sysclk domain) ----
    input  wire [9:0]   host_addr,
    input  wire [31:0]  host_wdata,
    input  wire [3:0]   host_wmask,
    input  wire         host_wen,
    input  wire         host_ren,
    output wire [31:0]  host_rdata,
    output wire         host_ready,

    // ---- Pad interface ----
    input  wire [15:0]  pad_in,
    output wire [15:0]  pad_out,
    output wire [15:0]  pad_oe,
    output wire [127:0] pad_ctl,

    // ---- IRQ to host ----
    output wire         irq_to_host
);

    // ====================================================================
    // Internal wires
    // ====================================================================

    // IOP control signals
    wire        iop_reset;
    wire        iop_nmi;
    wire        iop_irq;
    wire        wake_latch;

    // Core memory interface
    wire [31:0] core_mem_addr;
    wire [31:0] core_mem_wdata;
    wire [3:0]  core_mem_wmask;
    wire [31:0] core_mem_rdata;
    wire        core_mem_rstrb;
    wire        core_mem_rbusy;
    wire        core_mem_wbusy;

    // Core PC output (unused — no hardware breakpoints)
    wire [9:0]  core_pc_out;

    // SRAM A ports
    wire [6:0]  sram_a_a0;
    wire [31:0] sram_a_di0;
    wire [3:0]  sram_a_we0;
    wire        sram_a_en0;
    wire [31:0] sram_a_do0;

    // SRAM B0 ports
    wire [4:0]  sram_b0_a0;
    wire [31:0] sram_b0_di0;
    wire [3:0]  sram_b0_we0;
    wire        sram_b0_en0;
    wire [31:0] sram_b0_do0;

    // SRAM B1 ports
    wire [4:0]  sram_b1_a0;
    wire [31:0] sram_b1_di0;
    wire [3:0]  sram_b1_we0;
    wire        sram_b1_en0;
    wire [31:0] sram_b1_do0;

    // MMIO page
    wire        mmio_sel;
    wire [31:0] mmio_rdata;

    // Memmux host-side rdata (SRAM only)
    wire [31:0] memmux_host_rdata;
    wire        memmux_host_ready;

    // GPIO MMIO
    wire [31:0] gpio_mmio_rdata;

    // SPI MMIO
    wire [31:0] spi_mmio_rdata;

    // Ctrl MMIO (doorbell reads from IOP side)
    wire [31:0] ctrl_iop_mmio_rdata;

    // Host register interface
    wire        host_sel_reg = host_addr[9] & host_addr[8];  // 0x300+
    wire [31:0] ctrl_host_rdata;

    // ====================================================================
    // Core MMIO bus signals
    // ====================================================================
    wire [7:0]  mmio_addr   = core_mem_addr[7:0];
    wire [5:0]  mmio_woff   = core_mem_addr[7:2];
    wire        core_active = core_mem_rstrb | (|core_mem_wmask);
    wire        mmio_wen    = mmio_sel & (|core_mem_wmask);
    wire        mmio_ren    = mmio_sel & core_mem_rstrb;

    // MMIO sub-block select based on word offset
    // GPIO: 0x00..0x18 (word 0x00..0x06), PADCTL: 0x08..0x17, WAKE: 0x18
    // Doorbells: 0x20..0x21 (0x380, 0x384)
    // SPI: 0x24..0x26 (0x390, 0x394, 0x398)
    wire mmio_is_gpio = (mmio_woff <= 6'h18);
    wire mmio_is_ctrl = (mmio_woff >= 6'h20) && (mmio_woff <= 6'h21);
    wire mmio_is_spi  = (mmio_woff >= 6'h24) && (mmio_woff <= 6'h26);

    // ====================================================================
    // MMIO read-data mux
    // ====================================================================
    assign mmio_rdata = mmio_is_gpio ? gpio_mmio_rdata :
                        mmio_is_ctrl ? ctrl_iop_mmio_rdata :
                        mmio_is_spi  ? spi_mmio_rdata :
                        32'h0;

    // ====================================================================
    // Host read-data mux — SRAM vs registers
    // ====================================================================
    assign host_rdata = host_sel_reg ? ctrl_host_rdata : memmux_host_rdata;
    assign host_ready = host_sel_reg ? (host_wen | host_ren) : memmux_host_ready;

    // ====================================================================
    // AttoRV32 core
    // ====================================================================
    AttoRV32 #(
        .ADDR_WIDTH (10),
        .RV32E      (1),
        .MTVEC_ADDR (10'h010)
    ) u_core (
        .clk               (clk_iop),
        .reset              (~iop_reset & rst_n),   // active-low
        .mem_addr           (core_mem_addr),
        .mem_wdata          (core_mem_wdata),
        .mem_wmask          (core_mem_wmask),
        .mem_rdata          (core_mem_rdata),
        .mem_rstrb          (core_mem_rstrb),
        .mem_rbusy          (core_mem_rbusy),
        .mem_wbusy          (core_mem_wbusy),
        .interrupt_request  (iop_irq),
        .nmi                (iop_nmi),
        .dbg_halt_req       (1'b0),
        .pc_out             (core_pc_out)
    );

    // ====================================================================
    // SRAM A — 128x32 DFFRAM (sysclk)
    // Clocked by sysclk so host can write during reset at full speed.
    // Core signals only change on clk_iop edges (subset of sysclk edges),
    // so this is inherently safe — SRAM sees stable inputs most cycles.
    // ====================================================================
    DFFRAM #(.WORDS(128), .WSIZE(4)) u_sram_a (
        .CLK (sysclk),
        .WE0 (sram_a_we0),
        .EN0 (sram_a_en0),
        .A0  (sram_a_a0),
        .Di0 (sram_a_di0),
        .Do0 (sram_a_do0)
    );

    // ====================================================================
    // SRAM B0 — 32x32 DFFRAM (sysclk)
    // ====================================================================
    DFFRAM #(.WORDS(32), .WSIZE(4)) u_sram_b0 (
        .CLK (sysclk),
        .WE0 (sram_b0_we0),
        .EN0 (sram_b0_en0),
        .A0  (sram_b0_a0),
        .Di0 (sram_b0_di0),
        .Do0 (sram_b0_do0)
    );

    // ====================================================================
    // SRAM B1 — 32x32 DFFRAM (sysclk)
    // ====================================================================
    DFFRAM #(.WORDS(32), .WSIZE(4)) u_sram_b1 (
        .CLK (sysclk),
        .WE0 (sram_b1_we0),
        .EN0 (sram_b1_en0),
        .A0  (sram_b1_a0),
        .Di0 (sram_b1_di0),
        .Do0 (sram_b1_do0)
    );

    // ====================================================================
    // Memory mux
    // ====================================================================
    attoio_memmux u_memmux (
        .sysclk         (sysclk),
        .clk_iop        (clk_iop),
        .rst_n          (rst_n),
        .iop_reset      (iop_reset),

        // Core interface
        .core_addr      (core_mem_addr[9:0]),
        .core_wdata     (core_mem_wdata),
        .core_wmask     (core_mem_wmask),
        .core_rstrb     (core_mem_rstrb),
        .core_rdata     (core_mem_rdata),
        .core_rbusy     (core_mem_rbusy),
        .core_wbusy     (core_mem_wbusy),

        // Host interface
        .host_addr      (host_addr),
        .host_wdata     (host_wdata),
        .host_wmask     (host_wmask),
        .host_wen       (host_wen & ~host_sel_reg),
        .host_ren       (host_ren & ~host_sel_reg),
        .host_rdata     (memmux_host_rdata),
        .host_ready     (memmux_host_ready),

        // MMIO page select
        .mmio_sel       (mmio_sel),
        .mmio_rdata     (mmio_rdata),

        // SRAM A ports
        .sram_a_a0      (sram_a_a0),
        .sram_a_di0     (sram_a_di0),
        .sram_a_we0     (sram_a_we0),
        .sram_a_en0     (sram_a_en0),
        .sram_a_do0     (sram_a_do0),

        // SRAM B0 ports
        .sram_b0_a0     (sram_b0_a0),
        .sram_b0_di0    (sram_b0_di0),
        .sram_b0_we0    (sram_b0_we0),
        .sram_b0_en0    (sram_b0_en0),
        .sram_b0_do0    (sram_b0_do0),

        // SRAM B1 ports
        .sram_b1_a0     (sram_b1_a0),
        .sram_b1_di0    (sram_b1_di0),
        .sram_b1_we0    (sram_b1_we0),
        .sram_b1_en0    (sram_b1_en0),
        .sram_b1_do0    (sram_b1_do0)
    );

    // ====================================================================
    // GPIO + PADCTL + WAKE_LATCH
    // ====================================================================

    // SPI pin override signals
    wire        spi_active;
    wire [3:0]  spi_sck_pin;
    wire [3:0]  spi_mosi_pin;
    wire        spi_sck_val;
    wire        spi_mosi_val;

    attoio_gpio u_gpio (
        .sysclk     (sysclk),
        .clk_iop    (clk_iop),
        .rst_n      (rst_n),

        .mmio_addr  (mmio_addr),
        .mmio_wdata (core_mem_wdata),
        .mmio_wmask (core_mem_wmask),
        .mmio_wen   (mmio_wen & mmio_is_gpio),
        .mmio_ren   (mmio_ren & mmio_is_gpio),
        .mmio_rdata (gpio_mmio_rdata),

        .wake_latch (wake_latch),

        .spi_active   (spi_active),
        .spi_sck_pin  (spi_sck_pin),
        .spi_mosi_pin (spi_mosi_pin),
        .spi_sck_val  (spi_sck_val),
        .spi_mosi_val (spi_mosi_val),

        .pad_in     (pad_in),
        .pad_out    (pad_out),
        .pad_oe     (pad_oe),
        .pad_ctl    (pad_ctl)
    );

    // ====================================================================
    // Control — doorbells + IOP_CTRL
    // ====================================================================
    attoio_ctrl u_ctrl (
        .sysclk         (sysclk),
        .rst_n          (rst_n),

        // Host-side registers
        .host_reg_addr  (host_addr[3:0]),
        .host_reg_wdata (host_wdata),
        .host_reg_wen   (host_wen & host_sel_reg),
        .host_reg_ren   (host_ren & host_sel_reg),
        .host_reg_rdata (ctrl_host_rdata),

        // IOP-side doorbell access
        .iop_mmio_woff  (mmio_woff),
        .iop_mmio_wdata (core_mem_wdata),
        .iop_mmio_wen   (mmio_wen),
        .iop_mmio_rdata (ctrl_iop_mmio_rdata),
        .iop_mmio_sel   (mmio_is_ctrl),

        .wake_latch     (wake_latch),

        .iop_reset      (iop_reset),
        .iop_nmi        (iop_nmi),
        .iop_irq        (iop_irq),
        .irq_to_host    (irq_to_host)
    );

    // ====================================================================
    // SPI shift helper
    // ====================================================================
    // Provide synchronized pad_in to SPI (use gpio's sync output)
    // We need to tap the synchronized value from attoio_gpio. Since the
    // sync regs are internal to gpio, we re-synchronize here on clk_iop
    // for the SPI module. This is safe because pad_in_sync2 on sysclk
    // is stable for N clk_iop cycles.
    reg [15:0] pad_in_iop_sync;
    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n)
            pad_in_iop_sync <= 16'h0;
        else
            pad_in_iop_sync <= pad_in;  // single-flop sufficient: already
                                         // 2-flop synced in gpio on sysclk
    end

    attoio_spi u_spi (
        .clk_iop    (clk_iop),
        .rst_n      (rst_n),

        .mmio_woff  (mmio_woff),
        .mmio_wdata (core_mem_wdata),
        .mmio_wen   (mmio_wen & mmio_is_spi),
        .mmio_rdata (spi_mmio_rdata),
        .mmio_sel   (mmio_is_spi),

        .pad_in_sync  (pad_in_iop_sync),

        .spi_active   (spi_active),
        .spi_sck_pin  (spi_sck_pin),
        .spi_mosi_pin (spi_mosi_pin),
        .spi_sck_val  (spi_sck_val),
        .spi_mosi_val (spi_mosi_val)
    );

endmodule
