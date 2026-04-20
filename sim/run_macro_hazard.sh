#!/usr/bin/env bash
# BUG-002 isolation: same core_hazard FW, but wrapped in attoio_macro.
# Pass --poll to enable concurrent host polling of mailbox during run.
set -e
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

FW="core_hazard"
TB="macro_hazard"
POLL=""
[[ "${1:-}" == "--poll" ]] && POLL="-DPOLL_HOST"

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
    $POLL \
    -o build/sim/tb_$TB.vvp \
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
    sim/tb_$TB.v

cd build/sim && vvp tb_$TB.vvp
