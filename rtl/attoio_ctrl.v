/******************************************************************************/
// attoio_ctrl — Doorbells, IOP_CTRL, IRQ routing
//
// Host-side registers (byte offsets within the MMIO page, which lives
// at APB base 0x700 under the v2 memory map):
//   +0x00  DOORBELL_H2C   W1S (host), R/W1C (IOP)   — host -> IOP doorbell
//   +0x04  DOORBELL_C2H   R/W1C (host), RW (IOP)    — IOP -> host doorbell
//   +0x08  IOP_CTRL       RW (host only)
//          bit 0: reset  (1 = IOP held in reset)
//          bit 1: nmi    (write 1 = pulse, self-clearing)
//
// IOP-side registers (within MMIO page, word-offset decode):
//   word 0x20  DOORBELL_H2C   R/W1C
//   word 0x21  DOORBELL_C2H   RW
//
// All flops on sysclk. IOP reads/writes arrive on clk_iop edges which
// are a subset of sysclk edges — inherently safe, no synchronizer needed.
/******************************************************************************/

module attoio_ctrl (
    input  wire        sysclk,
    input  wire        rst_n,

    // ---- Host-side interface (sysclk) ----
    input  wire [3:0]  host_reg_addr,   // register select (word offset 0..2)
    input  wire [31:0] host_reg_wdata,
    input  wire        host_reg_wen,
    input  wire        host_reg_ren,
    output reg  [31:0] host_reg_rdata,

    // ---- IOP-side MMIO interface (clk_iop, subset of sysclk) ----
    input  wire [5:0]  iop_mmio_woff,   // word offset within MMIO page
    input  wire [31:0] iop_mmio_wdata,
    input  wire        iop_mmio_wen,
    output reg  [31:0] iop_mmio_rdata,
    input  wire        iop_mmio_sel,    // 1 = IOP addressing doorbell range

    // ---- Wake latch input (from attoio_gpio) ----
    input  wire        wake_latch,

    // ---- Outputs ----
    output wire        iop_reset,       // to memmux + core reset
    output wire        iop_nmi,         // to core nmi
    output wire        iop_irq,         // to core interrupt_request
    output wire        irq_to_host      // IOP -> host interrupt
);

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
    // Host-side writes (sysclk)
    // ====================================================================
    // Host register offsets (word): 0 = H2C, 1 = C2H, 2 = IOP_CTRL
    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            doorbell_h2c <= 1'b0;
            doorbell_c2h <= 1'b0;
            ctrl_reset   <= 1'b1;   // IOP starts in reset
            ctrl_nmi     <= 1'b0;
            ctrl_nmi_pulse <= 1'b0;
        end else begin
            // Self-clearing NMI pulse
            ctrl_nmi_pulse <= 1'b0;

            if (host_reg_wen) begin
                case (host_reg_addr[3:2])
                    2'b00: begin // DOORBELL_H2C — W1S
                        if (host_reg_wdata[0])
                            doorbell_h2c <= 1'b1;
                    end
                    2'b01: begin // DOORBELL_C2H — W1C
                        if (host_reg_wdata[0])
                            doorbell_c2h <= 1'b0;
                    end
                    2'b10: begin // IOP_CTRL
                        ctrl_reset <= host_reg_wdata[0];
                        if (host_reg_wdata[1]) begin
                            ctrl_nmi <= 1'b1;
                            ctrl_nmi_pulse <= 1'b1;
                        end
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
        case (host_reg_addr[3:2])
            2'b00: host_reg_rdata = {31'h0, doorbell_h2c};
            2'b01: host_reg_rdata = {31'h0, doorbell_c2h};
            2'b10: host_reg_rdata = {30'h0, ctrl_nmi, ctrl_reset};
            default: host_reg_rdata = 32'h0;
        endcase
    end

    // ====================================================================
    // Output assignments
    // ====================================================================
    assign iop_reset  = ctrl_reset;
    assign iop_nmi    = ctrl_nmi;
    assign iop_irq    = doorbell_h2c | wake_latch;
    assign irq_to_host = doorbell_c2h;

endmodule
