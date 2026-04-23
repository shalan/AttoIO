#!/usr/bin/env bash
# tb_coexist — Phase H16 IOP-autonomy + host-peripheral-bundle coexistence.
# Runs the uart_tx firmware on the IOP while the host drives hp0 for
# pads 2/3/4.  Verifies UART decode AND pad tracking simultaneously.
set -e
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

FW="${FW:-uart_tx}"
make -C sw FW="$FW" >/dev/null
HEX="$PROJ_ROOT/build/sw/$FW/$FW.hex"
[[ -f "$HEX" ]] || { echo "ERROR: hex not found: $HEX"; exit 1; }

mkdir -p build/sim
iverilog -g2012 -I sim \
    -DBENCH \
    -DNRV_SINGLE_PORT_REGF \
    -DNRV_SHARED_ADDER \
    -DNRV_SERIAL_SHIFT \
    -DFW_HEX=\"$HEX\" \
    -o build/sim/tb_coexist.vvp \
    rtl/attoio_memmux.v \
    rtl/attoio_gpio.v \
    rtl/attoio_ctrl.v \
    rtl/attoio_spi.v \
    rtl/attoio_timer.v \
    rtl/attoio_wdt.v \
    rtl/attoio_apb_if.v \
    rtl/attoio_macro.v \
    models/dffram_rtl.v \
    ../frv32/rtl/attorv32.v \
    sim/uart_rx_model.v \
    sim/tb_coexist.v

cd build/sim && vvp tb_coexist.vvp
