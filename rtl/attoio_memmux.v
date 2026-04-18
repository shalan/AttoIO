/******************************************************************************/
// attoio_memmux — v2: 11-bit address space, 3-bank SRAM A, host/core
// arbitration for mailbox SRAM B.
//
// Memory map (11-bit byte address):
//   0x000 – 0x1FF  SRAM A0  (128x32 DFFRAM, 512 B)
//   0x200 – 0x3FF  SRAM A1  (128x32 DFFRAM, 512 B)
//   0x400 – 0x5FF  SRAM A2  (128x32 DFFRAM, 512 B)
//   0x600 – 0x67F  SRAM B0  (32x32 DFFRAM,  128 B)  mailbox low
//   0x680 – 0x6FF  SRAM B1  (32x32 DFFRAM,  128 B)  mailbox high
//   0x700 – 0x7FF  MMIO page (256 B, combinational slave)
//
// Address decode:
//   addr[10:9] = 00 / 01 / 10  -> SRAM A0 / A1 / A2
//   addr[10:8] = 110            -> SRAM B (bit [7] picks B0 vs B1)
//   addr[10:8] = 111            -> MMIO
//
// SRAM A arbitration:
//   IOP_CTRL.reset = 1  ->  host owns SRAM A (firmware load path)
//   IOP_CTRL.reset = 0  ->  IOP core owns SRAM A exclusively
//
// SRAM B arbitration:
//   Host always wins on contention.  The core stalls via `core_rbusy`
//   or `core_wbusy` for that cycle.
//
// SRAM A banks share one address/data/we tree; `EN0` is gated per bank
// so only the selected bank toggles — reduces dynamic power vs a
// single bigger RAM.
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

    /* ---- SRAM A0..A2 (three RAM128 instances) ---- */
    output wire [6:0]  sram_a0_a0,
    output wire [31:0] sram_a0_di0,
    output wire [3:0]  sram_a0_we0,
    output wire        sram_a0_en0,
    input  wire [31:0] sram_a0_do0,

    output wire [6:0]  sram_a1_a0,
    output wire [31:0] sram_a1_di0,
    output wire [3:0]  sram_a1_we0,
    output wire        sram_a1_en0,
    input  wire [31:0] sram_a1_do0,

    output wire [6:0]  sram_a2_a0,
    output wire [31:0] sram_a2_di0,
    output wire [3:0]  sram_a2_we0,
    output wire        sram_a2_en0,
    input  wire [31:0] sram_a2_do0,

    /* ---- SRAM B0 / B1 (two RAM32 instances) ---- */
    output wire [4:0]  sram_b0_a0,
    output wire [31:0] sram_b0_di0,
    output wire [3:0]  sram_b0_we0,
    output wire        sram_b0_en0,
    input  wire [31:0] sram_b0_do0,

    output wire [4:0]  sram_b1_a0,
    output wire [31:0] sram_b1_di0,
    output wire [3:0]  sram_b1_we0,
    output wire        sram_b1_en0,
    input  wire [31:0] sram_b1_do0
);

    /* ============================================================== */
    /*  Address decode                                                */
    /* ============================================================== */
    wire core_sel_a0   = (core_addr[10:9] == 2'b00);
    wire core_sel_a1   = (core_addr[10:9] == 2'b01);
    wire core_sel_a2   = (core_addr[10:9] == 2'b10);
    wire core_sel_a    = core_sel_a0 | core_sel_a1 | core_sel_a2;
    wire core_sel_b    = (core_addr[10:8] == 3'b110);
    wire core_sel_b0   = core_sel_b & ~core_addr[7];
    wire core_sel_b1   = core_sel_b &  core_addr[7];
    wire core_sel_mmio = (core_addr[10:8] == 3'b111);

    assign mmio_sel = core_sel_mmio;

    wire core_active = core_rstrb | (|core_wmask);
    wire core_req_b  = core_active & core_sel_b;

    wire host_sel_a0   = (host_addr[10:9] == 2'b00);
    wire host_sel_a1   = (host_addr[10:9] == 2'b01);
    wire host_sel_a2   = (host_addr[10:9] == 2'b10);
    wire host_sel_a    = host_sel_a0 | host_sel_a1 | host_sel_a2;
    wire host_sel_b    = (host_addr[10:8] == 3'b110);
    wire host_sel_b0   = host_sel_b & ~host_addr[7];
    wire host_sel_b1   = host_sel_b &  host_addr[7];
    wire host_sel_reg  = (host_addr[10:8] == 3'b111);

    wire host_active = host_wen | host_ren;
    wire host_req_a  = host_active & host_sel_a & iop_reset;
    wire host_req_b  = host_active & host_sel_b;

    /* ============================================================== */
    /*  SRAM A port mux (3 banks)                                      */
    /*   - During iop_reset, the host drives all banks (only the       */
    /*     selected one is enabled).                                   */
    /*   - After reset release, the core drives all banks.             */
    /* ============================================================== */
    wire [6:0]  a_word_addr = iop_reset ? host_addr[8:2] : core_addr[8:2];
    wire [31:0] a_wdata     = iop_reset ? host_wdata     : core_wdata;

    /* Per-bank write-enable and chip-enable */
    wire a0_en_host = host_req_a & host_sel_a0;
    wire a1_en_host = host_req_a & host_sel_a1;
    wire a2_en_host = host_req_a & host_sel_a2;
    wire a0_en_core = ~iop_reset & core_active & core_sel_a0;
    wire a1_en_core = ~iop_reset & core_active & core_sel_a1;
    wire a2_en_core = ~iop_reset & core_active & core_sel_a2;

    wire [3:0] a0_we = iop_reset ? ((a0_en_host & host_wen) ? host_wmask : 4'b0)
                                 : (a0_en_core ? core_wmask : 4'b0);
    wire [3:0] a1_we = iop_reset ? ((a1_en_host & host_wen) ? host_wmask : 4'b0)
                                 : (a1_en_core ? core_wmask : 4'b0);
    wire [3:0] a2_we = iop_reset ? ((a2_en_host & host_wen) ? host_wmask : 4'b0)
                                 : (a2_en_core ? core_wmask : 4'b0);

    assign sram_a0_a0  = a_word_addr;
    assign sram_a0_di0 = a_wdata;
    assign sram_a0_we0 = a0_we;
    assign sram_a0_en0 = iop_reset ? a0_en_host : a0_en_core;

    assign sram_a1_a0  = a_word_addr;
    assign sram_a1_di0 = a_wdata;
    assign sram_a1_we0 = a1_we;
    assign sram_a1_en0 = iop_reset ? a1_en_host : a1_en_core;

    assign sram_a2_a0  = a_word_addr;
    assign sram_a2_di0 = a_wdata;
    assign sram_a2_we0 = a2_we;
    assign sram_a2_en0 = iop_reset ? a2_en_host : a2_en_core;

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
    wire b_sel_b0 = b_grant_host ? host_sel_b0 : core_sel_b0;
    wire b_sel_b1 = b_grant_host ? host_sel_b1 : core_sel_b1;

    assign sram_b0_a0  = b_a0;
    assign sram_b0_di0 = b_di0;
    assign sram_b0_we0 = b_sel_b0 ? b_we0_raw : 4'b0;
    assign sram_b0_en0 = b_sel_b0 & (b_grant_host | b_grant_core);

    assign sram_b1_a0  = b_a0;
    assign sram_b1_di0 = b_di0;
    assign sram_b1_we0 = b_sel_b1 ? b_we0_raw : 4'b0;
    assign sram_b1_en0 = b_sel_b1 & (b_grant_host | b_grant_core);

    /* ============================================================== */
    /*  Core stall (SRAM B conflict only — SRAM A is owner-exclusive)  */
    /* ============================================================== */
    assign core_rbusy = b_conflict & core_rstrb;
    assign core_wbusy = b_conflict & (|core_wmask);

    /* ============================================================== */
    /*  Core read-data mux (tracks source over 1-cycle SRAM latency)   */
    /* ============================================================== */
    localparam [2:0] SRC_A0   = 3'd0;
    localparam [2:0] SRC_A1   = 3'd1;
    localparam [2:0] SRC_A2   = 3'd2;
    localparam [2:0] SRC_B0   = 3'd3;
    localparam [2:0] SRC_B1   = 3'd4;
    localparam [2:0] SRC_MMIO = 3'd5;

    reg [2:0] core_rd_src;
    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n)
            core_rd_src <= SRC_A0;
        else if (core_active & ~(core_rbusy | core_wbusy))
            core_rd_src <= core_sel_a0   ? SRC_A0  :
                           core_sel_a1   ? SRC_A1  :
                           core_sel_a2   ? SRC_A2  :
                           core_sel_b0   ? SRC_B0  :
                           core_sel_b1   ? SRC_B1  :
                                           SRC_MMIO;
    end

    always @(*) begin
        case (core_rd_src)
            SRC_A0:   core_rdata = sram_a0_do0;
            SRC_A1:   core_rdata = sram_a1_do0;
            SRC_A2:   core_rdata = sram_a2_do0;
            SRC_B0:   core_rdata = sram_b0_do0;
            SRC_B1:   core_rdata = sram_b1_do0;
            SRC_MMIO: core_rdata = mmio_rdata;
            default:  core_rdata = 32'h0;
        endcase
    end

    /* ============================================================== */
    /*  Host read-data mux + ready                                     */
    /* ============================================================== */
    reg [2:0] host_rd_src;
    reg       host_access_pending;

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            host_rd_src         <= SRC_A0;
            host_access_pending <= 1'b0;
        end else begin
            host_access_pending <= host_active &
                                   (host_sel_a | host_sel_b);
            if (host_active)
                host_rd_src <= host_sel_a0  ? SRC_A0 :
                               host_sel_a1  ? SRC_A1 :
                               host_sel_a2  ? SRC_A2 :
                               host_sel_b0  ? SRC_B0 :
                               host_sel_b1  ? SRC_B1 :
                                              SRC_MMIO;
        end
    end

    always @(*) begin
        case (host_rd_src)
            SRC_A0:   host_rdata = sram_a0_do0;
            SRC_A1:   host_rdata = sram_a1_do0;
            SRC_A2:   host_rdata = sram_a2_do0;
            SRC_B0:   host_rdata = sram_b0_do0;
            SRC_B1:   host_rdata = sram_b1_do0;
            default:  host_rdata = 32'h0;   /* reg-page host data is
                                              muxed at the macro top */
        endcase
    end

    /* Registers respond combinationally; SRAM takes 1 sysclk cycle.
     * APB wrapper stretches ACCESS until PREADY is high. */
    assign host_ready = host_sel_reg ? host_active : host_access_pending;

endmodule
