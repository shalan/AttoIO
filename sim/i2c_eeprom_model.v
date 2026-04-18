/*
 * i2c_eeprom_model — minimal 256 B I²C EEPROM behavioral model for
 * AttoIO testbenches. 24C02-compatible at the protocol level.
 *
 * Features:
 *   - START / RESTART / STOP detection
 *   - Device address byte (7'b1010_000 + R/W) + ACK
 *   - Word-address byte + payload writes (sequential, auto-increment)
 *   - Sequential reads from the current pointer
 *   - Master ACK/NAK during reads
 *
 * Robust against RESTART mid-transaction: every START event sets
 * `start_pulse` and `disable`s the proto block, which is re-entered
 * immediately — effectively aborting any in-flight read/write-byte.
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

    reg sda_drive_low;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    reg in_xfer;
    reg start_pulse;   /* strobed on every START / RESTART */

    integer ki;
    initial begin
        for (ki = 0; ki < MEM_SIZE; ki = ki + 1) mem[ki] = 8'h00;
        sda_drive_low = 1'b0;
        in_xfer       = 1'b0;
        start_pulse   = 1'b0;
        addr_ptr      = 8'h00;
    end

    /* ---- START / RESTART detector ---- */
    always @(negedge sda) if (scl === 1'b1) begin
        in_xfer       = 1'b1;
        start_pulse   = 1'b1;
        sda_drive_low = 1'b0;
    end

    /* ---- STOP detector ---- */
    always @(posedge sda) if (scl === 1'b1) begin
        in_xfer       = 1'b0;
        sda_drive_low = 1'b0;
    end

    /* ---- Byte shifters ---- */
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

    task do_ack_low;
        begin
            @(negedge scl);
            sda_drive_low = 1'b1;
            @(negedge scl);
            sda_drive_low = 1'b0;
        end
    endtask

    /* Slave -> master byte. MSB driven immediately, subsequent bits
     * updated after the master has sampled the previous bit (wait for
     * posedge then negedge each iteration — makes the sync work for
     * both the first byte after ACK and subsequent bytes, where there
     * would otherwise be a stray ACK-phase negedge between bytes). */
    task send_byte(input [7:0] b, output ack_bit);
        integer i;
        reg [7:0] bb;
        begin
            bb            = b;
            sda_drive_low = ~bb[7];
            bb            = {bb[6:0], 1'b0};
            for (i = 1; i < 8; i = i + 1) begin
                @(posedge scl);        /* master samples bit (7-i+1) */
                @(negedge scl);        /* end of that bit's SCL pulse */
                sda_drive_low = ~bb[7];
                bb            = {bb[6:0], 1'b0};
            end
            @(posedge scl);            /* master samples LSB */
            @(negedge scl);            /* end of LSB pulse */
            sda_drive_low = 1'b0;      /* release SDA for master ACK */
            @(posedge scl);            /* ACK SCL high */
            ack_bit = sda;             /* sample master's ack */
        end
    endtask

    /* ---- Protocol watchdog: abort proto on RESTART ----
     * start_pulse fires for every negedge SDA with SCL high. On
     * RESTART (inside an xfer) we want the proto block to abandon
     * whatever it was doing and re-enter from the top.
     */
    always @(posedge start_pulse) begin
        disable proto.proto_body;
    end

    /* ---- Main protocol ---- */
    initial begin : proto
        reg [7:0] b;
        reg       ack;
        reg       is_read;

        forever begin : proto_body
            start_pulse = 1'b0;
            wait (in_xfer === 1'b1);

            read_byte(b);
            if (b[7:1] !== DEVICE_ADDR) begin
                /* Not us — wait for STOP or another START. */
                wait (in_xfer === 1'b0 || start_pulse === 1'b1);
                disable proto_body;
            end
            is_read = b[0];
            do_ack_low();

            if (!is_read) begin
                /* Word-address byte. */
                read_byte(b);
                addr_ptr = b;
                do_ack_low();

                /* Payload bytes until STOP or RESTART. */
                while (in_xfer) begin
                    read_byte(b);
                    mem[addr_ptr] = b;
                    addr_ptr      = addr_ptr + 8'h01;
                    do_ack_low();
                end
            end else begin
                /* Read from current addr_ptr until master NAKs. */
                while (in_xfer) begin
                    send_byte(mem[addr_ptr], ack);
                    addr_ptr = addr_ptr + 8'h01;
                    if (ack === 1'b1) begin
                        wait (in_xfer === 1'b0 || start_pulse === 1'b1);
                        disable proto_body;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
