#!/usr/bin/env bash
# Run OpenSTA on the post-synthesis netlist.
set -e

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

STA="/nix/store/2ia51h09wfm9qpm9dg3zq52cr578ah61-opensta/bin/sta"

if [[ ! -x "$STA" ]]; then
    echo "ERROR: OpenSTA not found at $STA"
    exit 1
fi

if [[ ! -f "build/attoio_macro.syn.v" ]]; then
    echo "ERROR: build/attoio_macro.syn.v missing — run syn/run_synth.sh first."
    exit 1
fi

mkdir -p build

echo "=== Running OpenSTA ==="
$STA -no_init -no_splash -exit syn/sta.tcl 2>&1 | tee build/sta.log

echo
echo "=== STA log: build/sta.log ==="
