/******************************************************************************/
// attoio_ctrl — Host-visible control regs, doorbells, IOP_CTRL, PINMUX, IRQ
//
// Host-side register map (byte offset within the 0x700 MMIO page, i.e.
// APB addresses 0x700..0x7FF). Reads of unmapped offsets return 0.
//
//   0x00  DOORBELL_H2C   W1S (host), R/W1C (IOP)  — host -> IOP doorbell
//   0x04  DOORBELL_C2H   R/W1C (host), RW (IOP)   — IOP -> host doorbell
//   0x08  IOP_CTRL       RW (host only)
//                          bit 0: reset  (1 = IOP held in reset)
//                          bit 1: nmi    (write 1 = pulse, self-clearing)
//   0x0C  VERSION        RO  — { 8'h01, 8'h00, 8'h00, 8'h00 } = v1.0.0
//   0x10  PINMUX_LO      RW  — pads 0-7, 2 bits each, little-endian
//                          00 = attoio-owned, 01 = hp0, 10 = hp1, 11 = hp2
//   0x14  PINMUX_HI      RW  — pads 8-15, 2 bits each
//
// IOP-side MMIO register offsets (within the 0x700 MMIO page, word
// offsets for the IOP memory bus):
//   word 0x20  DOORBELL_H2C   R/W1C
//   word 0x21  DOORBELL_C2H   RW
//
// All state flops on sysclk. IOP reads/writes arrive on clk_iop edges which
// are a subset of sysclk edges — inherently safe, no synchronizer needed.
/******************************************************************************/

module attoio_ctrl #(
    parameter NGPIO = 16
) (
    input  wire              sysclk,
    input  wire              rst_n,

    // ---- Host-side interface (sysclk) ----
    input  wire [7:0]        host_reg_addr,   // byte offset within 0x700 page
    input  wire [31:0]       host_reg_wdata,
    input  wire [3:0]        host_reg_wstrb,
    input  wire              host_reg_wen,
    input  wire              host_reg_ren,
    output reg  [31:0]       host_reg_rdata,

    // ---- IOP-side MMIO interface (clk_iop, subset of sysclk) ----
    input  wire [5:0]        iop_mmio_woff,
    input  wire [31:0]       iop_mmio_wdata,
    input  wire              iop_mmio_wen,
    output reg  [31:0]       iop_mmio_rdata,
    input  wire              iop_mmio_sel,

    // ---- Wake latch input (from attoio_gpio) ----
    input  wire              wake_latch,

    // ---- Outputs ----
    output wire              iop_reset,
    output wire              iop_nmi,
    output wire              iop_irq,
    output wire              irq_to_host,

    // ---- PINMUX bits out to macro pad mux (2 bits per pad) ----
    output wire [NGPIO*2-1:0] pinmux
);

    initial begin
        if (NGPIO != 8 && NGPIO != 16) begin
            $display("attoio_ctrl: NGPIO must be 8 or 16, got %0d", NGPIO);
            $fatal;
        end
    end

    localparam [31:0] ATTOIO_VERSION = 32'h0100_0000;  // v1.0.0
    localparam PMW = NGPIO * 2;   // PINMUX total width (16 at NGPIO=8, 32 at =16)

    // ====================================================================
    // DOORBELL_H2C — host sets (W1S), IOP clears (W1C)
    // ====================================================================
    reg doorbell_h2c;

    // ====================================================================
    // DOORBELL_C2H — IOP sets (write), host clears (W1C)
    // ====================================================================
    reg doorbell_c2h;

    // ====================================================================
    // IOP_CTRL
    // ====================================================================
    reg ctrl_reset;
    reg ctrl_nmi;
    reg ctrl_nmi_pulse;  // 1-cycle pulse

    // ====================================================================
    // PINMUX
    // ====================================================================
    // pinmux_r is always 32 bits internally (storage cheap). Only the
    // low PMW bits drive the output. At NGPIO=8 the top 16 bits are
    // writable but inert (they don't feed any mux).
    reg [31:0] pinmux_r;
    assign pinmux = pinmux_r[PMW-1:0];

    // ====================================================================
    // Host-side writes (sysclk)
    // ====================================================================
    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            doorbell_h2c   <= 1'b0;
            doorbell_c2h   <= 1'b0;
            ctrl_reset     <= 1'b1;   // IOP starts in reset
            ctrl_nmi       <= 1'b0;
            ctrl_nmi_pulse <= 1'b0;
            pinmux_r       <= 32'h0;  // all pads attoio-owned at reset
        end else begin
            // Self-clearing NMI pulse
            ctrl_nmi_pulse <= 1'b0;

            if (host_reg_wen) begin
                case (host_reg_addr)
                    8'h00: begin // DOORBELL_H2C — W1S
                        if (host_reg_wdata[0])
                            doorbell_h2c <= 1'b1;
                    end
                    8'h04: begin // DOORBELL_C2H — W1C
                        if (host_reg_wdata[0])
                            doorbell_c2h <= 1'b0;
                    end
                    8'h08: begin // IOP_CTRL
                        ctrl_reset <= host_reg_wdata[0];
                        if (host_reg_wdata[1]) begin
                            ctrl_nmi       <= 1'b1;
                            ctrl_nmi_pulse <= 1'b1;
                        end
                    end
                    8'h10: begin // PINMUX_LO — pads 0..7 (bits [15:0])
                        if (host_reg_wstrb[0]) pinmux_r[ 7: 0] <= host_reg_wdata[ 7:0];
                        if (host_reg_wstrb[1]) pinmux_r[15: 8] <= host_reg_wdata[15:8];
                    end
                    8'h14: begin // PINMUX_HI — pads 8..15 (bits [31:16], ignored at NGPIO=8)
                        if (host_reg_wstrb[0]) pinmux_r[23:16] <= host_reg_wdata[ 7:0];
                        if (host_reg_wstrb[1]) pinmux_r[31:24] <= host_reg_wdata[15:8];
                    end
                    default: ;
                endcase
            end

            // NMI auto-clear after one cycle
            if (ctrl_nmi && !ctrl_nmi_pulse)
                ctrl_nmi <= 1'b0;

            // IOP-side W1C for H2C (IOP writes on clk_iop edge = sysclk edge)
            if (iop_mmio_wen && iop_mmio_sel && iop_mmio_woff == 6'h20) begin
                if (iop_mmio_wdata[0])
                    doorbell_h2c <= 1'b0;
            end

            // IOP-side write for C2H
            if (iop_mmio_wen && iop_mmio_sel && iop_mmio_woff == 6'h21) begin
                doorbell_c2h <= iop_mmio_wdata[0];
            end
        end
    end

    // ====================================================================
    // IOP-side reads (combinational)
    // ====================================================================
    always @(*) begin
        iop_mmio_rdata = 32'h0;
        case (iop_mmio_woff)
            6'h20: iop_mmio_rdata = {31'h0, doorbell_h2c};   // DOORBELL_H2C
            6'h21: iop_mmio_rdata = {31'h0, doorbell_c2h};   // DOORBELL_C2H
            default: iop_mmio_rdata = 32'h0;
        endcase
    end

    // ====================================================================
    // Host-side reads (combinational)
    // ====================================================================
    always @(*) begin
        host_reg_rdata = 32'h0;
        case (host_reg_addr)
            8'h00:   host_reg_rdata = {31'h0, doorbell_h2c};
            8'h04:   host_reg_rdata = {31'h0, doorbell_c2h};
            8'h08:   host_reg_rdata = {30'h0, ctrl_nmi, ctrl_reset};
            8'h0C:   host_reg_rdata = ATTOIO_VERSION;
            8'h10:   host_reg_rdata = {16'h0, pinmux_r[15:0]};
            8'h14:   host_reg_rdata = {16'h0, pinmux_r[31:16]};
            default: host_reg_rdata = 32'h0;
        endcase
    end

    // ====================================================================
    // Output assignments
    // ====================================================================
    assign iop_reset   = ctrl_reset;
    assign iop_nmi     = ctrl_nmi;
    assign iop_irq     = doorbell_h2c | wake_latch;
    assign irq_to_host = doorbell_c2h;

endmodule
