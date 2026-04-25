# sim/common.sh — shared bits for every sim/run_<tb>.sh.
#
# Each run script does:
#
#   source "$(dirname "$0")/common.sh"
#   attoio_compile tb_<name> [extra sources ...]
#   attoio_run     tb_<name>
#
# VARIANT defaults to "dffram"; override with VARIANT=cfsram to run
# against the CFSRAM top.  Testbenches and run scripts are both
# variant-aware; a single run_*.sh supports both paths.

PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
VARIANT="${VARIANT:-dffram}"

attoio_build_fw () {
    local fw="$1"
    make -C "$PROJ_ROOT/sw" FW="$fw" VARIANT="$VARIANT" >/dev/null
    if [[ "$VARIANT" == "cfsram" ]]; then
        HEX="$PROJ_ROOT/build/sw/cfsram/$fw/$fw.hex"
    else
        HEX="$PROJ_ROOT/build/sw/$fw/$fw.hex"
    fi
    [[ -f "$HEX" ]] || { echo "ERROR: hex not found: $HEX"; return 1; }
    echo "$HEX"
}

attoio_variant_rtl_files () {
    if [[ "$VARIANT" == "cfsram" ]]; then
        echo "rtl/attoio_memmux_cfsram.v rtl/attoio_macro_cfsram.v rtl/cfsram_dffram_wrapper.v"
    else
        echo "rtl/attoio_memmux.v rtl/attoio_macro.v"
    fi
}

attoio_variant_defines () {
    if [[ "$VARIANT" == "cfsram" ]]; then
        echo "-DATTOIO_CFSRAM -DCFSRAM_BEHAVIORAL_SRAM"
    else
        echo ""
    fi
}

attoio_compile () {
    local tb="$1"; shift
    local hex="${HEX:-/dev/null}"
    mkdir -p "$PROJ_ROOT/build/sim"
    # shellcheck disable=SC2086 — deliberate word-splitting for $IVERILOG_EXTRA
    iverilog -g2012 -I "$PROJ_ROOT/sim" \
        -DBENCH \
        $(attoio_variant_defines) \
        -DNRV_SINGLE_PORT_REGF \
        -DNRV_SHARED_ADDER \
        -DNRV_SERIAL_SHIFT \
        -DFW_HEX="\"$hex\"" \
        ${IVERILOG_EXTRA:-} \
        -o "$PROJ_ROOT/build/sim/$tb.vvp" \
        $(attoio_variant_rtl_files) \
        "$PROJ_ROOT/rtl/attoio_gpio.v" \
        "$PROJ_ROOT/rtl/attoio_ctrl.v" \
        "$PROJ_ROOT/rtl/attoio_spi.v" \
        "$PROJ_ROOT/rtl/attoio_timer.v" \
        "$PROJ_ROOT/rtl/attoio_wdt.v" \
        "$PROJ_ROOT/rtl/attoio_apb_if.v" \
        "$PROJ_ROOT/models/dffram_rtl.v" \
        "$PROJ_ROOT/../frv32/rtl/attorv32.v" \
        "$@" \
        "$PROJ_ROOT/sim/$tb.v"
}

attoio_run () {
    local tb="$1"
    cd "$PROJ_ROOT/build/sim"
    vvp "$tb.vvp"
}
