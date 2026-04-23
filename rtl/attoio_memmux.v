/******************************************************************************/
// attoio_memmux — v3.0: 11-bit address space, single-bank SRAM A (1 KB),
// single-bank mailbox SRAM B (Phase 1.0 restore).
//
// Memory map (11-bit byte address):
//   0x000 – 0x3FF  SRAM A   (256x32 DFFRAM, 1024 B)
//   0x600 – 0x67F  SRAM B   (32x32 DFFRAM,  128 B)  mailbox
//   0x700 – 0x7FF  MMIO page (256 B, combinational slave)
//
// Addresses 0x400–0x5FF and 0x680–0x6FF are unmapped — reads return 0,
// writes drop silently.
//
// Address decode:
//   addr[10]    = 0       -> SRAM A (single bank, 1024 B)
//   addr[10:7]  = 4'b1100 -> SRAM B (single bank, 128 B)
//   addr[10:8]  = 3'b111  -> MMIO page
//
// SRAM A arbitration:
//   IOP_CTRL.reset = 1  ->  host owns SRAM A (firmware load path)
//   IOP_CTRL.reset = 0  ->  IOP core owns SRAM A exclusively
//
// SRAM B arbitration:
//   Host always wins on contention.  The core stalls via `core_rbusy`
//   or `core_wbusy` for that cycle.
/******************************************************************************/

module attoio_memmux (
    input  wire        sysclk,
    input  wire        clk_iop,
    input  wire        rst_n,

    input  wire        iop_reset,          /* 1 -> host owns SRAM A */

    /* ---- IOP core memory interface (clk_iop) ---- */
    input  wire [10:0] core_addr,
    input  wire [31:0] core_wdata,
    input  wire [3:0]  core_wmask,
    input  wire        core_rstrb,
    output reg  [31:0] core_rdata,
    output wire        core_rbusy,
    output wire        core_wbusy,

    /* ---- Host bus interface (sysclk / APB) ---- */
    input  wire [10:0] host_addr,
    input  wire [31:0] host_wdata,
    input  wire [3:0]  host_wmask,
    input  wire        host_wen,
    input  wire        host_ren,
    output reg  [31:0] host_rdata,
    output wire        host_ready,

    /* ---- MMIO page select (core-side) ---- */
    output wire        mmio_sel,
    input  wire [31:0] mmio_rdata,

    /* ---- SRAM A (single RAM256 instance) ---- */
    output wire [7:0]  sram_a_a0,
    output wire [31:0] sram_a_di0,
    output wire [3:0]  sram_a_we0,
    output wire        sram_a_en0,
    input  wire [31:0] sram_a_do0,

    /* ---- SRAM B (single RAM32 instance) ---- */
    output wire [4:0]  sram_b_a0,
    output wire [31:0] sram_b_di0,
    output wire [3:0]  sram_b_we0,
    output wire        sram_b_en0,
    input  wire [31:0] sram_b_do0
);

    /* ============================================================== */
    /*  Address decode                                                */
    /* ============================================================== */
    wire core_sel_a    = (core_addr[10]    == 1'b0);     /* 0x000–0x3FF */
    wire core_sel_b    = (core_addr[10:7]  == 4'b1100);  /* 0x600–0x67F */
    wire core_sel_mmio = (core_addr[10:8]  == 3'b111);   /* 0x700–0x7FF */

    assign mmio_sel = core_sel_mmio;

    wire core_active = core_rstrb | (|core_wmask);
    wire core_req_b  = core_active & core_sel_b;

    wire host_sel_a   = (host_addr[10]    == 1'b0);
    wire host_sel_b   = (host_addr[10:7]  == 4'b1100);
    wire host_sel_reg = (host_addr[10:8]  == 3'b111);

    wire host_active = host_wen | host_ren;
    wire host_req_a  = host_active & host_sel_a & iop_reset;
    wire host_req_b  = host_active & host_sel_b;

    /* ============================================================== */
    /*  SRAM A port mux (single bank, 256 words)                       */
    /*   - During iop_reset, the host drives it (FW load path).        */
    /*   - After reset release, the core drives it exclusively.        */
    /* ============================================================== */
    wire [7:0]  a_word_addr = iop_reset ? host_addr[9:2] : core_addr[9:2];
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

    /* ============================================================== */
    /*  Core stall (SRAM B conflict only — SRAM A is owner-exclusive)  */
    /* ============================================================== */
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
    /*  SRAM B Do0 capture latch (BUG-001 fix)                       */
    /*                                                               */
    /*  The DFFRAM Do0 output is single-buffered and shared with the */
    /*  host port.  Without this latch, a host APB read of SRAM B    */
    /*  that lands on a sysclk edge between the core's read issuance */
    /*  and consumption overwrites Do0 with the host's value and the */
    /*  core silently reads the wrong data.                          */
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
            default: host_rdata = 32'h0;   /* reg-page host data is
                                              muxed at the macro top */
        endcase
    end

    /* Registers respond combinationally; SRAM takes 1 sysclk cycle.
     * APB wrapper stretches ACCESS until PREADY is high. */
    assign host_ready = host_sel_reg ? host_active : host_access_pending;

endmodule
