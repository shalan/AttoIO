#!/usr/bin/env bash
#
# Phase H11 — LibreLane driver for attoio_macro (flattened-DFFRAM flow).
#
# Runs LibreLane 3.x inside its official container (via --dockerized),
# pointing at our existing volare PDK snapshot.  Outputs land under
# ./runs/<tag>/ next to this script.
#
# Usage:
#   flow/librelane/run.sh                   # full flow
#   flow/librelane/run.sh --to Yosys.Synthesis
#                                           # extra flags pass through
#
# Env overrides:
#   LIBRELANE_VENV  path to python venv with librelane installed
#                   (default: ./venv next to this script)
#   PDK_ROOT        path to volare root
#                   (default: /Users/mshalan/work/pdks/volare)

set -e

FLOW_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBRELANE_VENV="${LIBRELANE_VENV:-$FLOW_DIR/venv}"
PDK_ROOT="${PDK_ROOT:-/Users/mshalan/work/pdks/volare}"
CONFIG="$FLOW_DIR/config.json"

[[ -x "$LIBRELANE_VENV/bin/librelane" ]] || { echo "ERROR: librelane not found in venv: $LIBRELANE_VENV"; exit 1; }
[[ -f "$CONFIG"                        ]] || { echo "ERROR: config.json not found: $CONFIG";            exit 1; }
[[ -d "$PDK_ROOT/sky130"              ]] || { echo "ERROR: sky130 missing in PDK_ROOT: $PDK_ROOT";      exit 1; }

# Docker daemon must be up for --dockerized.
docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon not running.  Start Docker Desktop first."; exit 1; }

echo "--- LibreLane flow for attoio_macro ---"
echo "  venv:      $LIBRELANE_VENV"
echo "  pdk_root:  $PDK_ROOT"
echo "  config:    $CONFIG"
echo "  run_dir:   $FLOW_DIR/runs/"
echo

# LibreLane needs to mount the AttoRV32 source (one level up from the
# attoio checkout) so the dir::../../../frv32 path in config.json
# resolves inside the container.
FRV32_DIR="$(cd "$FLOW_DIR/../../../frv32" && pwd)"

cd "$FLOW_DIR"
source "$LIBRELANE_VENV/bin/activate"
exec librelane \
    --docker-no-tty \
    --docker-mount "$FRV32_DIR" \
    --dockerized \
    --pdk-root "$PDK_ROOT" \
    --run-tag attoio_macro_h11 \
    "$@" \
    "$CONFIG"
