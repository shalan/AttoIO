/******************************************************************************/
// attoio_memmux — Memory mux, address decoder, and SRAM B arbiter
//
// Manages the three DFFRAM macros:
//   SRAM A  (128x32, 512 B) — IOP-private code/data/stack
//   SRAM B0 (32x32,  128 B) — mailbox low  (0x200–0x27F)
//   SRAM B1 (32x32,  128 B) — mailbox high (0x280–0x2FF)
//
// IOP address decode (ADDR_WIDTH=10):
//   mem_addr[9]   = 0         -> SRAM A    (A0 = mem_addr[8:2])
//   mem_addr[9:8] = 2'b10     -> SRAM B
//     mem_addr[7] = 0         -> SRAM B0   (A0 = mem_addr[6:2])
//     mem_addr[7] = 1         -> SRAM B1   (A0 = mem_addr[6:2])
//   mem_addr[9:8] = 2'b11     -> MMIO page (active low on mmio_sel)
//
// SRAM A: 2:1 port mux — host owns during reset, IOP owns after.
// SRAM B: host-priority arbiter — both masters may access; host wins on conflict.
/******************************************************************************/

module attoio_memmux (
    input  wire        sysclk,
    input  wire        clk_iop,
    input  wire        rst_n,

    // IOP_CTRL.reset — selects SRAM A owner
    input  wire        iop_reset,       // 1 = IOP in reset, SRAM A -> host

    // ---- IOP core memory interface (active on clk_iop) ----
    input  wire [9:0]  core_addr,       // byte address, 10 bits
    input  wire [31:0] core_wdata,
    input  wire [3:0]  core_wmask,
    input  wire        core_rstrb,      // read strobe (fetch or load)
    output reg  [31:0] core_rdata,
    output wire        core_rbusy,
    output wire        core_wbusy,

    // ---- Host bus interface (active on sysclk) ----
    input  wire [9:0]  host_addr,       // byte address, 10 bits
    input  wire [31:0] host_wdata,
    input  wire [3:0]  host_wmask,
    input  wire        host_wen,
    input  wire        host_ren,
    output reg  [31:0] host_rdata,
    output wire        host_ready,

    // ---- MMIO page select (active when core addresses 0x300-0x3FF) ----
    output wire        mmio_sel,        // 1 = core is accessing MMIO page
    input  wire [31:0] mmio_rdata,      // read data from MMIO page

    // ---- SRAM A ports (128x32 DFFRAM) ----
    output wire [6:0]  sram_a_a0,
    output wire [31:0] sram_a_di0,
    output wire [3:0]  sram_a_we0,
    output wire        sram_a_en0,
    input  wire [31:0] sram_a_do0,

    // ---- SRAM B0 ports (32x32 DFFRAM) ----
    output wire [4:0]  sram_b0_a0,
    output wire [31:0] sram_b0_di0,
    output wire [3:0]  sram_b0_we0,
    output wire        sram_b0_en0,
    input  wire [31:0] sram_b0_do0,

    // ---- SRAM B1 ports (32x32 DFFRAM) ----
    output wire [4:0]  sram_b1_a0,
    output wire [31:0] sram_b1_di0,
    output wire [3:0]  sram_b1_we0,
    output wire        sram_b1_en0,
    input  wire [31:0] sram_b1_do0
);

    // ====================================================================
    // IOP-side address decode
    // ====================================================================
    wire core_sel_a    = ~core_addr[9];                          // 0x000-0x1FF
    wire core_sel_b    =  core_addr[9] & ~core_addr[8];         // 0x200-0x2FF
    wire core_sel_b0   =  core_sel_b & ~core_addr[7];           // 0x200-0x27F
    wire core_sel_b1   =  core_sel_b &  core_addr[7];           // 0x280-0x2FF
    wire core_sel_mmio =  core_addr[9] &  core_addr[8];         // 0x300-0x3FF

    assign mmio_sel = core_sel_mmio;

    // Core is actively accessing memory
    wire core_active = core_rstrb | (|core_wmask);

    // Core wants SRAM B
    wire core_req_b = core_active & core_sel_b;

    // ====================================================================
    // Host-side address decode
    // ====================================================================
    wire host_sel_a  = ~host_addr[9];                            // 0x000-0x1FF
    wire host_sel_b  =  host_addr[9] & ~host_addr[8];           // 0x200-0x2FF
    wire host_sel_b0 =  host_sel_b & ~host_addr[7];             // 0x200-0x27F
    wire host_sel_b1 =  host_sel_b &  host_addr[7];             // 0x280-0x2FF
    wire host_sel_reg =  host_addr[9] &  host_addr[8];          // 0x300+ (host regs)

    wire host_active = host_wen | host_ren;

    // Host wants SRAM A (only allowed during iop_reset)
    wire host_req_a = host_active & host_sel_a & iop_reset;

    // Host wants SRAM B
    wire host_req_b = host_active & host_sel_b;

    // ====================================================================
    // SRAM A port mux — selected by iop_reset
    // During reset: host owns. After reset: IOP core owns.
    // ====================================================================
    assign sram_a_a0  = iop_reset ? host_addr[8:2] : core_addr[8:2];
    assign sram_a_di0 = iop_reset ? host_wdata     : core_wdata;
    assign sram_a_we0 = iop_reset ? (host_wen & host_sel_a ? host_wmask : 4'b0)
                                  : (core_sel_a ? core_wmask : 4'b0);
    assign sram_a_en0 = iop_reset ? (host_req_a)
                                  : (core_active & core_sel_a);

    // ====================================================================
    // SRAM B arbiter — host always wins
    // ====================================================================
    wire b_conflict = host_req_b & core_req_b;
    wire b_grant_host = host_req_b;         // host always wins
    wire b_grant_core = core_req_b & ~host_req_b;

    // Mux SRAM B0/B1 ports — select between host and core
    wire [4:0]  b_a0   = b_grant_host ? host_addr[6:2] : core_addr[6:2];
    wire [31:0] b_di0  = b_grant_host ? host_wdata     : core_wdata;
    wire [3:0]  b_we0_raw = b_grant_host ? (host_wen ? host_wmask : 4'b0)
                                         : core_wmask;

    // Sub-bank select
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

    // ====================================================================
    // Core stall — only when core wants SRAM B and host also wants it
    // ====================================================================
    assign core_rbusy = b_conflict & core_rstrb;
    assign core_wbusy = b_conflict & (|core_wmask);

    // ====================================================================
    // Core read-data mux
    // ====================================================================
    // Track which source the core was reading from (1-cycle SRAM latency)
    reg [1:0] core_rd_src;  // 0=SRAM A, 1=SRAM B0, 2=SRAM B1, 3=MMIO
    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n)
            core_rd_src <= 2'b00;
        else if (core_active & ~(core_rbusy | core_wbusy))
            core_rd_src <= core_sel_a    ? 2'b00 :
                           core_sel_b0   ? 2'b01 :
                           core_sel_b1   ? 2'b10 :
                                           2'b11;
    end

    always @(*) begin
        case (core_rd_src)
            2'b00:   core_rdata = sram_a_do0;
            2'b01:   core_rdata = sram_b0_do0;
            2'b10:   core_rdata = sram_b1_do0;
            2'b11:   core_rdata = mmio_rdata;
            default: core_rdata = 32'h0;
        endcase
    end

    // ====================================================================
    // Host read-data mux + ready
    // ====================================================================
    reg [1:0] host_rd_src;  // 0=SRAM A, 1=SRAM B0, 2=SRAM B1, 3=regs
    reg       host_access_pending;

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            host_rd_src <= 2'b00;
            host_access_pending <= 1'b0;
        end else begin
            host_access_pending <= host_active & (host_sel_a | host_sel_b);
            if (host_active)
                host_rd_src <= host_sel_a  ? 2'b00 :
                               host_sel_b0 ? 2'b01 :
                               host_sel_b1 ? 2'b10 :
                                             2'b11;
        end
    end

    // Host-side register read data (doorbells, IOP_CTRL) is provided
    // externally and muxed in attoio_macro.v. Here we just handle SRAM.
    always @(*) begin
        case (host_rd_src)
            2'b00:   host_rdata = sram_a_do0;
            2'b01:   host_rdata = sram_b0_do0;
            2'b10:   host_rdata = sram_b1_do0;
            2'b11:   host_rdata = 32'h0;   // placeholder — regs muxed at top
            default: host_rdata = 32'h0;
        endcase
    end

    // Ready: SRAM accesses take 1 cycle; register accesses are combinational
    assign host_ready = host_sel_reg ? host_active : host_access_pending;

endmodule
