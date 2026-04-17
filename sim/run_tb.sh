#!/bin/bash
# Run the AttoIO end-to-end testbench
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJ_DIR/build/sim"
FRV32_DIR="$(dirname "$PROJ_DIR")/frv32"

mkdir -p "$BUILD_DIR"

echo "=== Compiling AttoIO testbench ==="
iverilog -g2005-sv \
    -DBENCH \
    -DNRV_SINGLE_PORT_REGF \
    -DNRV_SHARED_ADDER \
    -DNRV_SERIAL_SHIFT \
    -I"$PROJ_DIR/rtl" \
    -o "$BUILD_DIR/tb_attoio.vvp" \
    "$PROJ_DIR/sim/tb_attoio.v" \
    "$PROJ_DIR/rtl/attoio_macro.v" \
    "$PROJ_DIR/rtl/attoio_memmux.v" \
    "$PROJ_DIR/rtl/attoio_timer.v" \
    "$PROJ_DIR/rtl/attoio_wdt.v" \
    "$PROJ_DIR/rtl/attoio_gpio.v" \
    "$PROJ_DIR/rtl/attoio_ctrl.v" \
    "$PROJ_DIR/rtl/attoio_spi.v" \
    "$PROJ_DIR/models/dffram_rtl.v" \
    "$FRV32_DIR/rtl/attorv32.v"

echo "=== Running simulation ==="
cd "$BUILD_DIR"
vvp tb_attoio.vvp

echo "=== Done ==="
