/*
 * i2c_eeprom_model — a minimal 256-byte I2C EEPROM behavioral model
 * for AttoIO testbenches. AT24C02-compatible at the *protocol* level
 * (device-addr byte + 8-bit word address + data). No write timing
 * (tWR) and no SDA setup/hold checks — this is a functional model
 * only, meant for round-trip verification of the I²C master firmware.
 *
 * If tighter timing checks are needed, drop a vendor model in
 * models/external/ and reference it from the testbench instead; see
 * models/external/README.md.
 *
 * Ports:
 *   sda  inout  I²C data line, open-drain (pulled high externally).
 *              The model drives a '0' by pulling sda low; to release,
 *              it tri-states sda to 'z'.
 *   scl  input  I²C clock from the master.
 *
 * Addressing (matches AT24C02 with A2:A1:A0 = 3'b000):
 *   device address byte = 7'b1010_000 + R/W bit
 *
 * Supported sequences:
 *   Write:
 *     START, 0xA0, (ack), word_addr, (ack), data0, (ack), ..., STOP
 *   Random read:
 *     START, 0xA0, (ack), word_addr, (ack), ReSTART, 0xA1, (ack),
 *       data0, (master-ack), data1, ..., (master-nak), STOP
 *   Current-address read:
 *     START, 0xA1, (ack), data, ..., (nak), STOP
 */

`default_nettype none

module i2c_eeprom_model #(
    parameter [6:0] DEVICE_ADDR = 7'b1010_000,
    parameter       MEM_SIZE    = 256
) (
    inout  wire sda,
    input  wire scl
);

    reg [7:0] mem [0:MEM_SIZE-1];
    reg [7:0] addr_ptr;

    /* --- open-drain SDA driver --------------------------------------- */
    reg sda_drive_low;   /* 1 = pull sda low, 0 = release (high-z) */
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    /* --- state & byte-assembly helpers ------------------------------- */
    reg        in_xfer;      /* set between START and STOP */
    reg        got_dev_byte; /* first byte since START was the dev-addr  */
    reg        is_read;      /* current transaction direction */
    reg        got_word_addr;

    /* --- initialisation --------------------------------------------- */
    integer ki;
    initial begin
        for (ki = 0; ki < MEM_SIZE; ki = ki + 1) mem[ki] = 8'h00;
        sda_drive_low = 1'b0;
        in_xfer       = 1'b0;
        got_dev_byte  = 1'b0;
        got_word_addr = 1'b0;
        is_read       = 1'b0;
        addr_ptr      = 8'h00;
    end

    /* --- START / STOP detection (change of SDA while SCL is high) ---- */
    always @(negedge sda) if (scl === 1'b1) begin
        /* START condition */
        in_xfer       = 1'b1;
        got_dev_byte  = 1'b0;
        got_word_addr = 1'b0;
        sda_drive_low = 1'b0;
    end

    always @(posedge sda) if (scl === 1'b1) begin
        /* STOP condition */
        in_xfer       = 1'b0;
        got_dev_byte  = 1'b0;
        got_word_addr = 1'b0;
        is_read       = 1'b0;
        sda_drive_low = 1'b0;
    end

    /* --- bit shifters -------------------------------------------------
     * One byte is 8 data bits followed by an ACK bit. We run a small
     * task that shifts 8 bits on rising SCL, then drives/samples the
     * ack on the 9th SCL pulse.
     */
    task do_ack_low;
        begin
            @(negedge scl);      /* pull SDA low before the ack SCL pulse */
            sda_drive_low = 1'b1;
            @(negedge scl);      /* release it on the next falling edge  */
            sda_drive_low = 1'b0;
        end
    endtask

    task read_byte(output [7:0] b);
        integer i;
        begin
            b = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin
                @(posedge scl);
                b = {b[6:0], sda};
            end
        end
    endtask

    /* Send 8 bits MSB-first, then sample master ack on bit 9. Returns
     * the master's ack bit (1 = NAK, 0 = ACK). */
    task send_byte(input [7:0] b, output ack_bit);
        integer i;
        reg [7:0] bb;
        begin
            bb = b;
            for (i = 0; i < 8; i = i + 1) begin
                @(negedge scl);
                sda_drive_low = ~bb[7];   /* MSB first */
                bb = {bb[6:0], 1'b0};
            end
            @(negedge scl);
            sda_drive_low = 1'b0;         /* release SDA for master ack */
            @(posedge scl);
            ack_bit = sda;                /* sample master's ack */
        end
    endtask

    /* --- main protocol FSM -----------------------------------------
     * We avoid @(posedge scl) races with the START/STOP detectors by
     * running this as a separate `initial forever` process that waits
     * for in_xfer to go high, then drives one transaction to STOP.
     */
    initial begin : proto
        reg [7:0] b;
        reg       ack;
        forever begin
            wait (in_xfer === 1'b1);

            /* ---- device-address byte ---- */
            read_byte(b);
            if (b[7:1] === DEVICE_ADDR) begin
                is_read      = b[0];
                got_dev_byte = 1'b1;
                do_ack_low();
            end else begin
                /* not for us — stay silent until STOP */
                wait (in_xfer === 1'b0);
            end

            if (in_xfer && !is_read) begin
                /* ---- word-address byte + payload ---- */
                read_byte(b);
                addr_ptr      = b;
                got_word_addr = 1'b1;
                do_ack_low();

                while (in_xfer) begin : write_loop
                    read_byte(b);
                    if (!in_xfer) disable write_loop;
                    mem[addr_ptr] = b;
                    addr_ptr      = (addr_ptr + 8'h01);
                    do_ack_low();
                end
            end

            if (in_xfer && is_read) begin
                /* ---- sequential read from addr_ptr ---- */
                while (in_xfer) begin : read_loop
                    send_byte(mem[addr_ptr], ack);
                    addr_ptr = (addr_ptr + 8'h01);
                    if (ack === 1'b1) begin
                        /* master NAKed — wait for STOP */
                        wait (in_xfer === 1'b0);
                        disable read_loop;
                    end
                end
            end

            /* On ReSTART (falling edge of SDA while SCL high re-enters
             * in_xfer via the START detector), the while loop above
             * will see in_xfer drop-then-rise and we'll come back to
             * the top naturally on the next iteration. */
            if (!in_xfer) ;
        end
    end

endmodule

`default_nettype wire
