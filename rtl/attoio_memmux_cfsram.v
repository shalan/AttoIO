/******************************************************************************/
// attoio_memmux_cfsram — memmux for the AttoIO-CFSRAM variant.
//
// 13-bit byte address space (8 KB total), 4 KB SRAM A hard macro
// (CF_SRAM_1024x32) + 128 B DFFRAM mailbox + 256 B MMIO page.
//
// Memory map:
//   0x0000 – 0x0FFF   4096 B   SRAM A  (CF_SRAM_1024x32, 1024 x 32)
//   0x1400 – 0x147F    128 B   SRAM B  (DFFRAM 32 x 32, mailbox)
//   0x1700 – 0x17FF    256 B   MMIO page (GPIO, SPI, TIMER, WDT, doorbells,
//                              PINMUX, VERSION)
//
// Unmapped windows (0x1000..0x13FF, 0x1480..0x16FF, 0x1800..0x1FFF) return
// zero on reads and silently drop writes.
//
// Address decode:
//   addr[12]       = 0       -> SRAM A (4 KB, 1024 words)
//   addr[12:7]     = 6'b1010_00 (0x1400..0x147F) -> SRAM B (128 B, 32 words)
//   addr[12:8]     = 5'b10111 (0x1700..0x17FF)   -> MMIO page
//
// SRAM A arbitration:
//   IOP_CTRL.reset = 1  ->  host owns SRAM A (firmware load path)
//   IOP_CTRL.reset = 0  ->  IOP core owns SRAM A exclusively
//
// SRAM B arbitration:
//   Host always wins on contention.  The core stalls via `core_rbusy`
//   or `core_wbusy` for that cycle (BUG-001 latch preserved).
/******************************************************************************/

module attoio_memmux_cfsram (
    input  wire        sysclk,
    input  wire        clk_iop,
    input  wire        rst_n,

    input  wire        iop_reset,          /* 1 -> host owns SRAM A */

    /* ---- IOP core memory interface (clk_iop) ---- */
    input  wire [12:0] core_addr,
    input  wire [31:0] core_wdata,
    input  wire [3:0]  core_wmask,
    input  wire        core_rstrb,
    output reg  [31:0] core_rdata,
    output wire        core_rbusy,
    output wire        core_wbusy,

    /* ---- Host bus interface (sysclk / APB) ---- */
    input  wire [12:0] host_addr,
    input  wire [31:0] host_wdata,
    input  wire [3:0]  host_wmask,
    input  wire        host_wen,
    input  wire        host_ren,
    output reg  [31:0] host_rdata,
    output wire        host_ready,

    /* ---- MMIO page select (core-side) ---- */
    output wire        mmio_sel,
    input  wire [31:0] mmio_rdata,

    /* ---- SRAM A (CF_SRAM_1024x32 via DFFRAM-shaped wrapper) ---- */
    output wire [9:0]  sram_a_a0,
    output wire [31:0] sram_a_di0,
    output wire [3:0]  sram_a_we0,
    output wire        sram_a_en0,
    input  wire [31:0] sram_a_do0,

    /* ---- SRAM B (1 x RAM32 DFFRAM, mailbox) ---- */
    output wire [4:0]  sram_b_a0,
    output wire [31:0] sram_b_di0,
    output wire [3:0]  sram_b_we0,
    output wire        sram_b_en0,
    input  wire [31:0] sram_b_do0
);

    /* ============================================================== */
    /*  Address decode                                                 */
    /* ============================================================== */
    wire core_sel_a    = (core_addr[12]    == 1'b0);                        /* 0x0000..0x0FFF */
    wire core_sel_b    = (core_addr[12:7]  == 6'b101000);                   /* 0x1400..0x147F */
    wire core_sel_mmio = (core_addr[12:8]  == 5'b10111);                    /* 0x1700..0x17FF */

    assign mmio_sel = core_sel_mmio;

    wire core_active = core_rstrb | (|core_wmask);
    wire core_req_b  = core_active & core_sel_b;

    wire host_sel_a   = (host_addr[12]    == 1'b0);
    wire host_sel_b   = (host_addr[12:7]  == 6'b101000);
    wire host_sel_reg = (host_addr[12:8]  == 5'b10111);

    wire host_active = host_wen | host_ren;
    wire host_req_a  = host_active & host_sel_a & iop_reset;
    wire host_req_b  = host_active & host_sel_b;

    /* ============================================================== */
    /*  SRAM A port mux (single 1024-word macro)                       */
    /* ============================================================== */
    wire [9:0]  a_word_addr = iop_reset ? host_addr[11:2] : core_addr[11:2];
    wire [31:0] a_wdata     = iop_reset ? host_wdata     : core_wdata;

    wire a_en_host = host_req_a;
    wire a_en_core = ~iop_reset & core_active & core_sel_a;

    wire [3:0] a_we = iop_reset ? ((a_en_host & host_wen) ? host_wmask : 4'b0)
                                : (a_en_core ? core_wmask : 4'b0);

    assign sram_a_a0  = a_word_addr;
    assign sram_a_di0 = a_wdata;
    assign sram_a_we0 = a_we;
    assign sram_a_en0 = iop_reset ? a_en_host : a_en_core;

    /* ============================================================== */
    /*  SRAM B arbiter — host priority                                 */
    /* ============================================================== */
    wire b_conflict   = host_req_b & core_req_b;
    wire b_grant_host = host_req_b;
    wire b_grant_core = core_req_b & ~host_req_b;

    wire [4:0]  b_a0      = b_grant_host ? host_addr[6:2] : core_addr[6:2];
    wire [31:0] b_di0     = b_grant_host ? host_wdata     : core_wdata;
    wire [3:0]  b_we0_raw = b_grant_host ? (host_wen ? host_wmask : 4'b0)
                                         : core_wmask;

    assign sram_b_a0  = b_a0;
    assign sram_b_di0 = b_di0;
    assign sram_b_we0 = b_we0_raw;
    assign sram_b_en0 = b_grant_host | b_grant_core;

    assign core_rbusy = b_conflict & core_rstrb;
    assign core_wbusy = b_conflict & (|core_wmask);

    /* ============================================================== */
    /*  Core read-data mux (tracks source over 1-cycle SRAM latency)   */
    /* ============================================================== */
    localparam [1:0] SRC_A    = 2'd0;
    localparam [1:0] SRC_B    = 2'd1;
    localparam [1:0] SRC_MMIO = 2'd2;

    reg [1:0] core_rd_src;
    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n)
            core_rd_src <= SRC_A;
        else if (core_active & ~(core_rbusy | core_wbusy))
            core_rd_src <= core_sel_a   ? SRC_A  :
                           core_sel_b   ? SRC_B  :
                                          SRC_MMIO;
    end

    /* ------------------------------------------------------------- */
    /*  SRAM B Do0 capture latch (BUG-001 fix, unchanged from v1.x)  */
    /* ------------------------------------------------------------- */
    reg [31:0] core_b_rdata_q;
    reg        core_b_grant_q;

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            core_b_grant_q <= 1'b0;
            core_b_rdata_q <= 32'h0;
        end else begin
            core_b_grant_q <= b_grant_core;
            if (core_b_grant_q) core_b_rdata_q <= sram_b_do0;
        end
    end

    always @(*) begin
        case (core_rd_src)
            SRC_A:    core_rdata = sram_a_do0;
            SRC_B:    core_rdata = core_b_rdata_q;
            SRC_MMIO: core_rdata = mmio_rdata;
            default:  core_rdata = 32'h0;
        endcase
    end

    /* ============================================================== */
    /*  Host read-data mux + ready                                     */
    /* ============================================================== */
    reg [1:0] host_rd_src;
    reg       host_access_pending;

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            host_rd_src         <= SRC_A;
            host_access_pending <= 1'b0;
        end else begin
            host_access_pending <= host_active &
                                   (host_sel_a | host_sel_b);
            if (host_active)
                host_rd_src <= host_sel_a ? SRC_A :
                               host_sel_b ? SRC_B :
                                            SRC_MMIO;
        end
    end

    always @(*) begin
        case (host_rd_src)
            SRC_A:   host_rdata = sram_a_do0;
            SRC_B:   host_rdata = sram_b_do0;
            default: host_rdata = 32'h0;
        endcase
    end

    assign host_ready = host_sel_reg ? host_active : host_access_pending;

endmodule
