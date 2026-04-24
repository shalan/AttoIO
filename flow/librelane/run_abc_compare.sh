#!/usr/bin/env bash
# Run LibreLane with a patched construct_abc_script.py bind-mounted over
# the container's stock copy. Stop at stage 38 (post-CTS-resizer STA) so
# we can extract the cell-count / area / WNS / TNS comparison metrics.
#
# Usage:
#   run_abc_compare.sh <strategy> <tag_suffix>
#     strategy     = one of "AREA 0" (our custom), "AREA 3", "DELAY 0"
#     tag_suffix   = short label for the run dir (e.g. "custom", "area3", "delay0")
#
# The container path to override is sky130-image-specific; we lifted it
# from a `docker exec ... ls` while the container was running.

set -e

STRATEGY="${1:-AREA 0}"
TAG_SUFFIX="${2:-custom}"
RUN_TAG="abc_${TAG_SUFFIX}"

FLOW_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBRELANE_VENV="${LIBRELANE_VENV:-$FLOW_DIR/venv}"
PDK_ROOT="${PDK_ROOT:-/Users/mshalan/work/pdks/volare}"
CONFIG="$FLOW_DIR/config.json"

CONTAINER_ABC_PATH=/nix/store/ql4nbdxqdd9ph8x1k8awi7yklk8rx51j-python3-3.13.9-env/lib/python3.13/site-packages/librelane/scripts/pyosys/construct_abc_script.py
HOST_ABC_FILE="$FLOW_DIR/custom_construct_abc_script.py"
FRV32_DIR="$(cd "$FLOW_DIR/../../../frv32" && pwd)"

[[ -f "$HOST_ABC_FILE" ]] || { echo "missing $HOST_ABC_FILE"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon not running"; exit 1; }

rm -rf "$FLOW_DIR/runs/$RUN_TAG"
mkdir -p "$FLOW_DIR/runs"

echo "=============================================================="
echo "  ABC comparison run"
echo "    strategy:  $STRATEGY"
echo "    run_tag:   $RUN_TAG"
echo "    abc patch: $HOST_ABC_FILE"
echo "               -> $CONTAINER_ABC_PATH"
echo "    stop at:   OpenROAD.STAMidPNR-2 (post-CTS-resizer STA)"
echo "=============================================================="

exec docker run --rm -i \
    --name "abc-compare-$TAG_SUFFIX-$$" \
    -v /Users/mshalan:/Users/mshalan \
    -v "$PDK_ROOT:$PDK_ROOT" \
    -v "$FRV32_DIR:$FRV32_DIR" \
    -v "$HOST_ABC_FILE:$CONTAINER_ABC_PATH:ro" \
    -e PDK_ROOT="$PDK_ROOT" \
    -w "$FLOW_DIR" \
    ghcr.io/librelane/librelane:3.0.2 \
    python3 -m librelane \
        --pdk-root "$PDK_ROOT" \
        --run-tag "$RUN_TAG" \
        --to OpenROAD.ResizerTimingPostCTS \
        -c "SYNTH_STRATEGY=$STRATEGY" \
        "$CONFIG"
