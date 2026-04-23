#!/usr/bin/env bash
# tb_pinmux — exercises the Phase H13 PINMUX register + per-pad 4:1 mux.
# IOP firmware is irrelevant (core held in reset), so we pick any stub.
set -e
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

FW="${FW:-empty}"
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
    -o build/sim/tb_pinmux.vvp \
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
    sim/tb_pinmux.v

cd build/sim && vvp tb_pinmux.vvp
