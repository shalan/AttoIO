#!/usr/bin/env bash
# CFSRAM-variant boot sanity: loads firmware into the 4 KB CF_SRAM_1024x32
# through APB (13-bit PADDR), releases IOP reset, checks core reaches
# steady PC.
set -e
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

FW="${FW:-empty}"
make -C sw FW="$FW" VARIANT=cfsram >/dev/null
HEX="$PROJ_ROOT/build/sw/cfsram/$FW/$FW.hex"
[[ -f "$HEX" ]] || { echo "ERROR: hex not found: $HEX"; exit 1; }

mkdir -p build/sim
iverilog -g2012 -I sim \
    -DBENCH \
    -DCFSRAM_BEHAVIORAL_SRAM \
    -DNRV_SINGLE_PORT_REGF \
    -DNRV_SHARED_ADDER \
    -DNRV_SERIAL_SHIFT \
    -DFW_HEX=\"$HEX\" \
    -o build/sim/tb_fw_boot_cfsram.vvp \
    rtl/attoio_memmux_cfsram.v \
    rtl/attoio_gpio.v \
    rtl/attoio_ctrl.v \
    rtl/attoio_spi.v \
    rtl/attoio_timer.v \
    rtl/attoio_wdt.v \
    rtl/attoio_apb_if.v \
    rtl/attoio_macro_cfsram.v \
    rtl/cfsram_dffram_wrapper.v \
    models/dffram_rtl.v \
    ../frv32/rtl/attorv32.v \
    sim/tb_fw_boot_cfsram.v

cd build/sim && vvp tb_fw_boot_cfsram.vvp
