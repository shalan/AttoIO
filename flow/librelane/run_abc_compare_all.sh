#!/usr/bin/env bash
# Runs three ABC strategies sequentially, stopping each at the
# ResizerTimingPostCTS stage, then prints a comparison table.
set -e
FLOW_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$FLOW_DIR"

# strategy, tag, label
variants=(
    "AREA 3|area3|AREA 3 (built-in)"
    "DELAY 0|delay0|DELAY 0 (built-in)"
    "AREA 0|custom|CUSTOM (user recipe via AREA 0)"
)

# -- run each --
rm -f runs/abc_runtimes.txt
for v in "${variants[@]}"; do
    strategy="${v%%|*}"
    rest="${v#*|}"
    tag="${rest%%|*}"
    label="${rest#*|}"

    echo
    echo "################################################################"
    echo "# $label"
    echo "################################################################"
    t0=$(date +%s)
    set +e
    ./run_abc_compare.sh "$strategy" "$tag" 2>&1 | tail -3
    rc=$?
    set -e
    elapsed=$(( $(date +%s) - t0 ))
    status="ok"
    [[ $rc -ne 0 ]] && status="FAILED(rc=$rc)"
    echo "  $status  elapsed=${elapsed}s"
    echo "$tag $elapsed $status" >> runs/abc_runtimes.txt
done

echo
echo "################################################################"
echo "# Comparison (post-CTS resizer — stage 37)"
echo "################################################################"
python3 - <<'PY'
import json, os
runs = [
    ("area3",  "AREA 3"),
    ("delay0", "DELAY 0"),
    ("custom", "CUSTOM"),
]
runtimes = {}
if os.path.exists("runs/abc_runtimes.txt"):
    for ln in open("runs/abc_runtimes.txt"):
        parts = ln.split()
        if len(parts) >= 2:
            runtimes[parts[0]] = parts[1] + "s"
rows = []
for tag, label in runs:
    d = f"runs/abc_{tag}/37-openroad-resizertimingpostcts/or_metrics_out.json"
    if not os.path.exists(d):
        print(f"  skip {label}: no metrics (run may have failed)")
        continue
    m = json.load(open(d))
    rows.append((label,
        runtimes.get(tag, "?"),
        m.get("design__instance__count", -1),
        f"{m.get('design__instance__area', -1):.0f}",
        f"{m.get('design__die__area', -1):.0f}",
        f"{m.get('design__core__area', -1):.0f}",
        f"{m.get('design__instance__utilization', -1):.3f}",
        m.get("timing__setup__wns__corner:nom_tt_025C_1v80", 0),
        m.get("timing__hold__wns__corner:nom_tt_025C_1v80", 0),
        m.get("timing__setup__tns__corner:nom_tt_025C_1v80", 0),
        m.get("timing__hold__tns__corner:nom_tt_025C_1v80", 0),
        m.get("design__instance__count__class:timing_repair_buffer", 0),
    ))
hdr = ("strategy","runtime","cells","cell_area","die_area","core_area","util",
       "setup_wns","hold_wns","setup_tns","hold_tns","repair_bufs")
print()
print("| " + " | ".join(hdr) + " |")
print("|" + "|".join(["---"]*len(hdr)) + "|")
for r in rows:
    print("| " + " | ".join(str(x) for x in r) + " |")
PY
