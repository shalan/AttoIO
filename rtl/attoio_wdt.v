/******************************************************************************/
// attoio_wdt — 16-bit watchdog timer
//
// Clocked by clk_iop. Provides:
//   - 16-bit down-counter that decrements every clk_iop while enabled.
//   - "Pet" is simply a write to WDT_COUNT with the reload value.
//   - On expire (count == 0): sets sticky WDT_STATUS.expired, asserts
//     wdt_nmi for one clk_iop cycle (firmware NMI), and if WDT_CTL[1]
//     is set, also asserts wdt_host_alert for one clk_iop cycle.
//   - Firmware W1Cs WDT_STATUS[0] after handling.
//
// Register map (word offsets within the 0x300 MMIO page):
//   0x30  WDT_COUNT    RW   [15:0] write reload value (also pets);
//                            read returns current count.
//   0x31  WDT_CTL      RW   [0] enable, [1] host_alert_en
//   0x32  WDT_STATUS   R/W1C [0] expired (sticky)
//
// Notes:
// - Writing WDT_COUNT while enabled immediately reloads.
// - Disabling (WDT_CTL[0] <- 0) freezes the counter at its current
//   value but does NOT clear expired. Firmware must W1C the flag.
// - Expired is sticky through reset release so host can see "we booted
//   because the WDT fired" if wired into a top-level reset-cause bit.
/******************************************************************************/

module attoio_wdt (
    input  wire        clk_iop,
    input  wire        rst_n,

    // MMIO (slice of the 0x300 page)
    input  wire [5:0]  mmio_woff,
    input  wire [31:0] mmio_wdata,
    input  wire        mmio_wen,
    output reg  [31:0] mmio_rdata,

    // Events
    output wire        wdt_nmi,         // one-cycle pulse, clk_iop domain
    output wire        wdt_host_alert,  // one-cycle pulse, clk_iop domain
    output wire        wdt_expired      // sticky flag (for host read-back)
);

    localparam W_WDT_COUNT  = 6'h30;
    localparam W_WDT_CTL    = 6'h31;
    localparam W_WDT_STATUS = 6'h32;

    wire write_count  = mmio_wen && (mmio_woff == W_WDT_COUNT);
    wire write_ctl    = mmio_wen && (mmio_woff == W_WDT_CTL);
    wire write_status = mmio_wen && (mmio_woff == W_WDT_STATUS);

    reg [15:0] cnt;
    reg        en;
    reg        host_alert_en;
    reg        expired;

    // expire fires one cycle when cnt transitions from 1 to 0 while
    // enabled; gated off when firmware is writing a new reload value
    // (pet in the same cycle).
    wire will_expire = en && (cnt == 16'h0001) && !write_count;
    reg  expire_pulse;

    always @(posedge clk_iop or negedge rst_n) begin
        if (!rst_n) begin
            cnt           <= 16'h0;
            en            <= 1'b0;
            host_alert_en <= 1'b0;
            expired       <= 1'b0;
            expire_pulse  <= 1'b0;
        end else begin
            expire_pulse <= 1'b0;

            // Count update
            if (write_count) begin
                cnt <= mmio_wdata[15:0];
            end else if (en && cnt != 16'h0000) begin
                cnt <= cnt - 16'h1;
            end
            // When enabled and we hit zero, remain at zero until next pet.
            // (Implicit — cnt stays at 0 because of the != 0 guard.)

            // Expire detection
            if (will_expire) begin
                expire_pulse <= 1'b1;
                expired      <= 1'b1;
            end

            // CTL writes
            if (write_ctl) begin
                en            <= mmio_wdata[0];
                host_alert_en <= mmio_wdata[1];
            end

            // STATUS W1C
            if (write_status && mmio_wdata[0])
                expired <= 1'b0;
        end
    end

    // wdt_nmi is held while the expired flag is set; the core only accepts
    // NMI in S_EXECUTE, so a single-cycle pulse can be missed. The ISR
    // W1C-clears the flag, which deasserts the NMI line.
    assign wdt_nmi        = expired;
    assign wdt_host_alert = expire_pulse & host_alert_en;
    assign wdt_expired    = expired;

    always @(*) begin
        mmio_rdata = 32'h0;
        case (mmio_woff)
            W_WDT_COUNT:  mmio_rdata = {16'h0, cnt};
            W_WDT_CTL:    mmio_rdata = {30'h0, host_alert_en, en};
            W_WDT_STATUS: mmio_rdata = {31'h0, expired};
            default:      mmio_rdata = 32'h0;
        endcase
    end

endmodule
