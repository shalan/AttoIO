/******************************************************************************/
// attoio_macro — AttoIO single hard macro (v2)
//
// Contents:
//   - AttoRV32 core (RV32EC, ADDR_WIDTH=11)
//   - 3 × SRAM A (RAM128 DFFRAM)          → 1536 B of private SRAM
//   - 2 × SRAM B (RAM32 DFFRAM)           →  256 B of host/IOP mailbox
//   - APB4 slave interface on the host side
//   - Memory mux + address decoder + SRAM B arbiter
//   - GPIO + PADCTL + WAKE (per-pin) + SPI shift helper + TIMER + WDT
//   - Doorbells + IOP_CTRL + IRQ routing
//
// Memory map (from both IOP and APB views; ADDR_WIDTH = 11):
//   0x000 – 0x1FF  SRAM A0 (RAM128)
//   0x200 – 0x3FF  SRAM A1 (RAM128)
//   0x400 – 0x5FF  SRAM A2 (RAM128)
//   0x600 – 0x67F  SRAM B0 mailbox
//   0x680 – 0x6FF  SRAM B1 mailbox
//   0x700 – 0x7FF  MMIO page
/******************************************************************************/

module attoio_macro (
    // ---- Clocks ----
    input  wire         sysclk,
    input  wire         clk_iop,

    // ---- Reset ----
    input  wire         rst_n,

    // ---- APB4 slave (host / system bus, sysclk domain) ----
    //      PCLK tied to sysclk internally (simpler for v2).
    input  wire [10:0]  PADDR,
    input  wire         PSEL,
    input  wire         PENABLE,
    input  wire         PWRITE,
    input  wire [31:0]  PWDATA,
    input  wire [3:0]   PSTRB,
    output wire [31:0]  PRDATA,
    output wire         PREADY,
    output wire         PSLVERR,

    // ---- Pad interface ----
    input  wire [15:0]  pad_in,
    output wire [15:0]  pad_out,
    output wire [15:0]  pad_oe,
    output wire [127:0] pad_ctl,

    // ---- IRQ to host ----
    output wire         irq_to_host
);

    // ====================================================================
    // Internal "host bus" driven by the APB wrapper
    // ====================================================================
    wire [10:0] host_addr;
    wire [31:0] host_wdata;
    wire [3:0]  host_wmask;
    wire        host_wen;
    wire        host_ren;
    wire [31:0] host_rdata;
    wire        host_ready;

    attoio_apb_if u_apb (
        .PCLK        (sysclk),
        .PRESETn     (rst_n),
        .PADDR       (PADDR),
        .PSEL        (PSEL),
        .PENABLE     (PENABLE),
        .PWRITE      (PWRITE),
        .PWDATA      (PWDATA),
        .PSTRB       (PSTRB),
        .PRDATA      (PRDATA),
        .PREADY      (PREADY),
        .PSLVERR     (PSLVERR),

        .host_addr   (host_addr),
        .host_wdata  (host_wdata),
        .host_wmask  (host_wmask),
        .host_wen    (host_wen),
        .host_ren    (host_ren),
        .host_rdata  (host_rdata),
        .host_ready  (host_ready)
    );

    // ====================================================================
    // Internal wires
    // ====================================================================
    wire        iop_reset;
    wire        iop_irq_base;
    wire        iop_irq;
    wire        iop_nmi_base;
    wire        iop_nmi;
    wire        wdt_nmi;
    wire        wdt_host_alert;
    wire        wdt_expired;
    wire        wake_latch;

    wire [31:0] core_mem_addr;
    wire [31:0] core_mem_wdata;
    wire [3:0]  core_mem_wmask;
    wire [31:0] core_mem_rdata;
    wire        core_mem_rstrb;
    wire        core_mem_rbusy;
    wire        core_mem_wbusy;

    wire [10:0] core_pc_out;    /* ADDR_WIDTH = 11 */

    /* SRAM A banks */
    wire [6:0]  sram_a0_a0;  wire [31:0] sram_a0_di0;
    wire [3:0]  sram_a0_we0; wire        sram_a0_en0;
    wire [31:0] sram_a0_do0;

    wire [6:0]  sram_a1_a0;  wire [31:0] sram_a1_di0;
    wire [3:0]  sram_a1_we0; wire        sram_a1_en0;
    wire [31:0] sram_a1_do0;

    wire [6:0]  sram_a2_a0;  wire [31:0] sram_a2_di0;
    wire [3:0]  sram_a2_we0; wire        sram_a2_en0;
    wire [31:0] sram_a2_do0;

    /* SRAM B banks */
    wire [4:0]  sram_b0_a0;  wire [31:0] sram_b0_di0;
    wire [3:0]  sram_b0_we0; wire        sram_b0_en0;
    wire [31:0] sram_b0_do0;

    wire [4:0]  sram_b1_a0;  wire [31:0] sram_b1_di0;
    wire [3:0]  sram_b1_we0; wire        sram_b1_en0;
    wire [31:0] sram_b1_do0;

    wire        mmio_sel;
    wire [31:0] mmio_rdata;

    wire [31:0] memmux_host_rdata;
    wire        memmux_host_ready;

    wire [31:0] gpio_mmio_rdata;
    wire [31:0] spi_mmio_rdata;
    wire [31:0] ctrl_iop_mmio_rdata;
    wire [31:0] timer_mmio_rdata;
    wire [31:0] wdt_mmio_rdata;
    wire [31:0] ctrl_host_rdata;

    /* Host-side register-page select: MMIO page @ 0x700 (addr[10:8] = 111) */
    wire host_sel_reg = (host_addr[10:8] == 3'b111);

    // ====================================================================
    // Core MMIO decode
    // ====================================================================
    wire [7:0]  mmio_addr   = core_mem_addr[7:0];
    wire [5:0]  mmio_woff   = core_mem_addr[7:2];
    wire        core_active = core_mem_rstrb | (|core_mem_wmask);
    wire        mmio_wen    = mmio_sel & (|core_mem_wmask);
    wire        mmio_ren    = mmio_sel & core_mem_rstrb;

    /* Sub-block selects — word offsets within the 256 B MMIO page are
     * unchanged from v1; only the page base moved (0x300 → 0x700). */
    wire mmio_is_gpio  = (mmio_woff <= 6'h1B);
    wire mmio_is_ctrl  = (mmio_woff >= 6'h20) && (mmio_woff <= 6'h21);
    wire mmio_is_spi   = (mmio_woff >= 6'h24) && (mmio_woff <= 6'h26);
    wire mmio_is_timer = (mmio_woff >= 6'h28) && (mmio_woff <= 6'h2F);
    wire mmio_is_wdt   = (mmio_woff >= 6'h30) && (mmio_woff <= 6'h32);

    assign mmio_rdata = mmio_is_gpio  ? gpio_mmio_rdata :
                        mmio_is_ctrl  ? ctrl_iop_mmio_rdata :
                        mmio_is_spi   ? spi_mmio_rdata :
                        mmio_is_timer ? timer_mmio_rdata :
                        mmio_is_wdt   ? wdt_mmio_rdata :
                        32'h0;

    /* Host read-data + ready muxing */
    assign host_rdata = host_sel_reg ? ctrl_host_rdata : memmux_host_rdata;
    assign host_ready = host_sel_reg ? (host_wen | host_ren) : memmux_host_ready;

    // ====================================================================
    // AttoRV32 core
    // ====================================================================
    AttoRV32 #(
        .ADDR_WIDTH (11),
        .RV32E      (1),
        .MTVEC_ADDR (11'h010)
    ) u_core (
        .clk               (clk_iop),
        .reset             (~iop_reset & rst_n),
        .mem_addr          (core_mem_addr),
        .mem_wdata         (core_mem_wdata),
        .mem_wmask         (core_mem_wmask),
        .mem_rdata         (core_mem_rdata),
        .mem_rstrb         (core_mem_rstrb),
        .mem_rbusy         (core_mem_rbusy),
        .mem_wbusy         (core_mem_wbusy),
        .interrupt_request (iop_irq),
        .nmi               (iop_nmi),
        .dbg_halt_req      (1'b0),
        .pc_out            (core_pc_out)
    );

    // ====================================================================
    // SRAM A — three 128x32 DFFRAM banks (sysclk)
    // ====================================================================
    DFFRAM #(.WORDS(128), .WSIZE(4)) u_sram_a0 (
        .CLK (sysclk),
        .WE0 (sram_a0_we0),
        .EN0 (sram_a0_en0),
        .A0  (sram_a0_a0),
        .Di0 (sram_a0_di0),
        .Do0 (sram_a0_do0)
    );
    DFFRAM #(.WORDS(128), .WSIZE(4)) u_sram_a1 (
        .CLK (sysclk),
        .WE0 (sram_a1_we0),
        .EN0 (sram_a1_en0),
        .A0  (sram_a1_a0),
        .Di0 (sram_a1_di0),
        .Do0 (sram_a1_do0)
    );
    DFFRAM #(.WORDS(128), .WSIZE(4)) u_sram_a2 (
        .CLK (sysclk),
        .WE0 (sram_a2_we0),
        .EN0 (sram_a2_en0),
        .A0  (sram_a2_a0),
        .Di0 (sram_a2_di0),
        .Do0 (sram_a2_do0)
    );

    // ====================================================================
    // SRAM B — mailbox (sysclk)
    // ====================================================================
    DFFRAM #(.WORDS(32), .WSIZE(4)) u_sram_b0 (
        .CLK (sysclk),
        .WE0 (sram_b0_we0),
        .EN0 (sram_b0_en0),
        .A0  (sram_b0_a0),
        .Di0 (sram_b0_di0),
        .Do0 (sram_b0_do0)
    );
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
        .sysclk      (sysclk),
        .clk_iop     (clk_iop),
        .rst_n       (rst_n),
        .iop_reset   (iop_reset),

        .core_addr   (core_mem_addr[10:0]),
        .core_wdata  (core_mem_wdata),
        .core_wmask  (core_mem_wmask),
        .core_rstrb  (core_mem_rstrb),
        .core_rdata  (core_mem_rdata),
        .core_rbusy  (core_mem_rbusy),
        .core_wbusy  (core_mem_wbusy),

        .host_addr   (host_addr),
        .host_wdata  (host_wdata),
        .host_wmask  (host_wmask),
        .host_wen    (host_wen & ~host_sel_reg),
        .host_ren    (host_ren & ~host_sel_reg),
        .host_rdata  (memmux_host_rdata),
        .host_ready  (memmux_host_ready),

        .mmio_sel    (mmio_sel),
        .mmio_rdata  (mmio_rdata),

        .sram_a0_a0  (sram_a0_a0),
        .sram_a0_di0 (sram_a0_di0),
        .sram_a0_we0 (sram_a0_we0),
        .sram_a0_en0 (sram_a0_en0),
        .sram_a0_do0 (sram_a0_do0),

        .sram_a1_a0  (sram_a1_a0),
        .sram_a1_di0 (sram_a1_di0),
        .sram_a1_we0 (sram_a1_we0),
        .sram_a1_en0 (sram_a1_en0),
        .sram_a1_do0 (sram_a1_do0),

        .sram_a2_a0  (sram_a2_a0),
        .sram_a2_di0 (sram_a2_di0),
        .sram_a2_we0 (sram_a2_we0),
        .sram_a2_en0 (sram_a2_en0),
        .sram_a2_do0 (sram_a2_do0),

        .sram_b0_a0  (sram_b0_a0),
        .sram_b0_di0 (sram_b0_di0),
        .sram_b0_we0 (sram_b0_we0),
        .sram_b0_en0 (sram_b0_en0),
        .sram_b0_do0 (sram_b0_do0),

        .sram_b1_a0  (sram_b1_a0),
        .sram_b1_di0 (sram_b1_di0),
        .sram_b1_we0 (sram_b1_we0),
        .sram_b1_en0 (sram_b1_en0),
        .sram_b1_do0 (sram_b1_do0)
    );

    // ====================================================================
    // GPIO + PADCTL + wake
    // ====================================================================
    wire        spi_active;
    wire [3:0]  spi_sck_pin;
    wire [3:0]  spi_mosi_pin;
    wire        spi_sck_val;
    wire        spi_mosi_val;

    wire [15:0] gpio_pad_out;
    wire [15:0] gpio_pad_oe;
    wire [15:0] timer_pad_sel;
    wire [15:0] timer_pad_val;

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
        .pad_out    (gpio_pad_out),
        .pad_oe     (gpio_pad_oe),
        .pad_ctl    (pad_ctl)
    );

    /* Timer pad override mux */
    assign pad_out = (gpio_pad_out & ~timer_pad_sel) |
                     (timer_pad_val &  timer_pad_sel);
    assign pad_oe  =  gpio_pad_oe | timer_pad_sel;

    // ====================================================================
    // Control — doorbells + IOP_CTRL
    // ====================================================================
    wire irq_to_host_ctrl;
    attoio_ctrl u_ctrl (
        .sysclk         (sysclk),
        .rst_n          (rst_n),

        .host_reg_addr  (host_addr[3:0]),
        .host_reg_wdata (host_wdata),
        .host_reg_wen   (host_wen & host_sel_reg),
        .host_reg_ren   (host_ren & host_sel_reg),
        .host_reg_rdata (ctrl_host_rdata),

        .iop_mmio_woff  (mmio_woff),
        .iop_mmio_wdata (core_mem_wdata),
        .iop_mmio_wen   (mmio_wen),
        .iop_mmio_rdata (ctrl_iop_mmio_rdata),
        .iop_mmio_sel   (mmio_is_ctrl),

        .wake_latch     (wake_latch),

        .iop_reset      (iop_reset),
        .iop_nmi        (iop_nmi_base),
        .iop_irq        (iop_irq_base),
        .irq_to_host    (irq_to_host_ctrl)
    );

    assign irq_to_host = irq_to_host_ctrl | wdt_host_alert;

    // ====================================================================
    // SPI shift helper — synchronize pad_in onto clk_iop first
    // ====================================================================
    reg [15:0] pad_in_iop_sync;
    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n) pad_in_iop_sync <= 16'h0;
        else        pad_in_iop_sync <= pad_in;
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

    // ====================================================================
    // TIMER
    // ====================================================================
    wire timer_irq;
    attoio_timer u_timer (
        .clk_iop       (clk_iop),
        .rst_n         (rst_n & ~iop_reset),

        .mmio_woff     (mmio_woff),
        .mmio_wdata    (core_mem_wdata),
        .mmio_wmask    (core_mem_wmask),
        .mmio_wen      (mmio_wen & mmio_is_timer),
        .mmio_ren      (mmio_ren & mmio_is_timer),
        .mmio_rdata    (timer_mmio_rdata),

        .pad_in_sync   (pad_in_iop_sync),

        .timer_irq     (timer_irq),

        .timer_pad_sel (timer_pad_sel),
        .timer_pad_val (timer_pad_val)
    );

    assign iop_irq = iop_irq_base | timer_irq;
    assign iop_nmi = iop_nmi_base | wdt_nmi;

    // ====================================================================
    // WDT
    // ====================================================================
    attoio_wdt u_wdt (
        .clk_iop        (clk_iop),
        .rst_n          (rst_n & ~iop_reset),
        .mmio_woff      (mmio_woff),
        .mmio_wdata     (core_mem_wdata),
        .mmio_wen       (mmio_wen & mmio_is_wdt),
        .mmio_rdata     (wdt_mmio_rdata),
        .wdt_nmi        (wdt_nmi),
        .wdt_host_alert (wdt_host_alert),
        .wdt_expired    (wdt_expired)
    );

endmodule
