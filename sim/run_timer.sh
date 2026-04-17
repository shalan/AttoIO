#!/usr/bin/env bash
# Build timer_pwm firmware + run tb_timer.
set -e

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

make -C sw FW=timer_pwm >/dev/null
HEX="$PROJ_ROOT/build/sw/timer_pwm/timer_pwm.hex"
[[ -f "$HEX" ]] || { echo "ERROR: hex not found: $HEX"; exit 1; }

mkdir -p build/sim

iverilog -g2005-sv \
    -DBENCH \
    -DNRV_SINGLE_PORT_REGF \
    -DNRV_SHARED_ADDER \
    -DNRV_SERIAL_SHIFT \
    -DFW_HEX=\"$HEX\" \
    -o build/sim/tb_timer.vvp \
    rtl/attoio_memmux.v \
    rtl/attoio_gpio.v \
    rtl/attoio_ctrl.v \
    rtl/attoio_spi.v \
    rtl/attoio_timer.v \
    rtl/attoio_macro.v \
    models/dffram_rtl.v \
    ../frv32/rtl/attorv32.v \
    sim/tb_timer.v

cd build/sim && vvp tb_timer.vvp
