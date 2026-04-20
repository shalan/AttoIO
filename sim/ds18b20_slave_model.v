/*
 * ds18b20_slave_model — minimal behavioural 1-Wire slave.
 *
 * Open-drain: drives DQ LOW via `drive_low`, releases otherwise
 * (pullup brings the line HIGH).  The TB wires a pullup on DQ and
 * muxes master + slave open-drain outputs together.
 *
 * Features implemented (enough to pass tb_onewire):
 *   1. Reset/presence: detects a LOW ≥ RESET_MIN and responds with
 *      a LOW presence pulse of PRESENCE_LEN.
 *   2. Command byte receive (LSB first, 8 bits).
 *   3. After 0xBE ("read scratchpad"), transmits 9 fixed bytes,
 *      LSB first, on the master's read slots.
 *
 * Scratchpad content:
 *   [0] 0x91  \  temperature = 0x0191 (25.0625 °C)
 *   [1] 0x01  /
 *   [2] 0x55         TH
 *   [3] 0x00         TL
 *   [4] 0x7F         config
 *   [5] 0xFF         reserved
 *   [6] 0x0C
 *   [7] 0x10
 *   [8] 0xA5         CRC (placeholder — not verified by TB)
 */

`timescale 1ns/1ps
`default_nettype none

module ds18b20_slave_model #(
    parameter integer RESET_MIN     = 20000, /* ns; reset LOW (48 µs) vs writes (≤6 µs) */
    parameter integer PRESENCE_WAIT = 1500,  /* wait after master releases */
    parameter integer PRESENCE_LEN  = 8000,  /* LOW width of presence pulse */
    parameter integer SLOT_TOTAL    = 10000, /* full slot + recovery; generous for FW overhead */
    parameter integer READ_SAMPLE   = 5000,  /* sample here after falling edge (write-1 LOW ~2.6 µs, write-0 LOW ~7 µs) */
    parameter integer READ_DRIVE    = 7000   /* hold LOW long enough for master's sample (~5.7 µs in after overhead) */
)(
    inout  wire dq
);

    reg drive_low;
    assign dq = drive_low ? 1'b0 : 1'bz;

    reg [7:0]  scratchpad [0:8];
    integer    tx_byte_idx;   /* next scratchpad byte to transmit */
    reg [7:0]  rx_byte;
    integer    k;

    initial begin
        drive_low = 1'b0;
        tx_byte_idx = 0;

        scratchpad[0] = 8'h91;
        scratchpad[1] = 8'h01;
        scratchpad[2] = 8'h55;
        scratchpad[3] = 8'h00;
        scratchpad[4] = 8'h7F;
        scratchpad[5] = 8'hFF;
        scratchpad[6] = 8'h0C;
        scratchpad[7] = 8'h10;
        scratchpad[8] = 8'hA5;
    end

    /* Detect reset: master holds DQ LOW for RESET_MIN+ */
    task do_presence;
        begin
            /* Wait for master to release (dq goes HIGH via pullup) */
            @(posedge dq);
            #(PRESENCE_WAIT);
            /* Drive presence pulse */
            drive_low = 1'b1;
            #(PRESENCE_LEN);
            drive_low = 1'b0;
        end
    endtask

    /* Read one bit from master (master pulls LOW, holds for duration
     * encoding bit value, then releases).  We sample at READ_SAMPLE
     * ns after the falling edge. */
    task read_bit(output reg b);
        begin
            @(negedge dq);
            #(READ_SAMPLE);
            b = dq;                     /* LOW = 0, HIGH = 1 */
            /* Use a fixed slot-remainder delay rather than waiting
             * for @(posedge dq), because on a write-1 the line is
             * HIGH the whole rest of the slot and a posedge never
             * arrives. */
            #(SLOT_TOTAL - READ_SAMPLE);
        end
    endtask

    /* Transmit one bit on a master-initiated read slot.  Master pulls
     * LOW briefly (~500 ns).  We respond: bit=0 → keep driving LOW
     * through the slot; bit=1 → release immediately. */
    task write_bit(input b);
        begin
            @(negedge dq);
            if (b === 1'b0) begin
                drive_low = 1'b1;
                #(READ_DRIVE);
                drive_low = 1'b0;
            end
            /* bit=1: line returns HIGH once master releases its brief pull. */
            #(SLOT_TOTAL);
        end
    endtask

    /* Main protocol loop.  On every reset cycle, respond and prepare
     * to receive a command byte, then act on it. */
    initial begin : proto
        reg [7:0] cmd;
        reg       bit_v;
        integer   i, j;
        reg [31:0] t0, t1;
        #100;   /* let the bus pullup settle before watching edges */
        forever begin
            /* Wait for master to pull dq LOW (reset begins). */
            @(negedge dq);
            t0 = $time;
            @(posedge dq);
            t1 = $time;
            if ((t1 - t0) >= RESET_MIN) begin
                /* Genuine reset — send presence. */
                #(PRESENCE_WAIT);
                drive_low = 1'b1;
                #(PRESENCE_LEN);
                drive_low = 1'b0;

                /* Receive command byte, LSB-first. */
                cmd = 8'h00;
                for (i = 0; i < 8; i = i + 1) begin
                    read_bit(bit_v);
                    cmd = {bit_v, cmd[7:1]};
                end

                if (cmd == 8'hBE) begin
                    for (i = 0; i < 9; i = i + 1) begin
                        for (j = 0; j < 8; j = j + 1) begin
                            write_bit(scratchpad[i][j]);
                        end
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
