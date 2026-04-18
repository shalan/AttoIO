#!/usr/bin/env bash
# Build the empty firmware, then run the Phase-0 acceptance testbench.
set -e

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

FW="${FW:-empty}"

echo "=== Building firmware: $FW ==="
make -C sw FW="$FW" >/dev/null
HEX="$PROJ_ROOT/build/sw/$FW/$FW.hex"
[[ -f "$HEX" ]] || { echo "ERROR: hex not found: $HEX"; exit 1; }

mkdir -p build/sim

echo "=== Compiling testbench ==="
iverilog -g2005-sv -I sim \
    -DBENCH \
    -DNRV_SINGLE_PORT_REGF \
    -DNRV_SHARED_ADDER \
    -DNRV_SERIAL_SHIFT \
    -DFW_HEX=\"$HEX\" \
    -o build/sim/tb_fw_boot.vvp \
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
    sim/tb_fw_boot.v

echo "=== Running ==="
cd build/sim && vvp tb_fw_boot.vvp
