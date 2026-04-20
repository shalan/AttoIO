#!/usr/bin/env bash
# Standalone AttoRV32 reproducer for BUG-002.  No memmux, no macro.
set -e
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

FW="${FW:-core_hazard}"
TB="${TB:-core_hazard}"

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
    -o build/sim/tb_$TB.vvp \
    ../frv32/rtl/attorv32.v \
    sim/tb_$TB.v

cd build/sim && vvp tb_$TB.vvp
