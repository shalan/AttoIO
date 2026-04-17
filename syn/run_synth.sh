#!/usr/bin/env bash
# Synthesize the AttoIO macro with Yosys against sky130_fd_sc_hd.
set -e

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

PDK_ROOT="/Users/mshalan/work/pdks/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A"
LIB_SYNTH="$PDK_ROOT/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"

if [[ ! -f "$LIB_SYNTH" ]]; then
    echo "ERROR: liberty file not found: $LIB_SYNTH"
    exit 1
fi

mkdir -p build

# Substitute the liberty path into the yosys script (avoids env-var quirks)
sed "s|LIBERTY_PATH|$LIB_SYNTH|g" syn/synth.ys > build/synth.ys

echo "=== Yosys synth -> build/attoio_macro.syn.v ==="
yosys -ql build/yosys.log build/synth.ys

echo
echo "=== DFFRAM instances in top-level netlist (kept hierarchical) ==="
grep -nE "^\s*DFFRAM\s+u_sram" build/attoio_macro.syn.v | head -10

echo
echo "=== Done. Netlist: build/attoio_macro.syn.v ==="
