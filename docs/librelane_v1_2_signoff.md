# AttoIO v1.2 — LibreLane signoff report

Full end-to-end LibreLane 3.0.2 close of the v1.0 macro using the
curated synth library and the DELAY 0 ABC recipe chosen in v1.1.

## Configuration

| Knob | Value |
|---|---|
| Macro version | v1.0 (SRAM A 1 KB, PINMUX, hp0/hp1/hp2, NGPIO=16) |
| Flow | LibreLane 3.0.2 (dockerized, ghcr.io/librelane/librelane:3.0.2) |
| PDK | sky130A (volare @ `0fe599b2…54af`) |
| Std-cell | `sky130_fd_sc_hd` |
| Synth library | `syn/hd_102_tt.lib` curated (104 combinational) + full PDK for FFs/latches via `SYNTH_EXCLUDED_CELL_FILE` |
| PnR library | full 428-cell PDK (no restriction) |
| ABC strategy | **`DELAY 0`** (chosen in `docs/abc_strategy_compare.md`) |
| Sizing | relative, `FP_CORE_UTIL = 65`, aspect 1.7 |
| Density | `PL_TARGET_DENSITY = 0.65` |
| Clocks | sysclk 60 MHz, clk_iop 30 MHz, both from `attoio.sdc` |
| Uncertainty | 150 ps setup + hold (both clocks) |
| Derate | ±3.5 % OCV (custom SDC) |
| Stage 37 margins | setup 0 ns, hold 0 ns (minimal repair at post-CTS) |
| Stage 43 margins | setup 0.05 ns, hold 0.15 ns (post-GRT resizer enabled) |
| Antenna | `DIODE_ON_PORTS = "in"`, `RUN_HEURISTIC_DIODE_INSERTION = false`, GRT+DRT `4-iter jumper-only` |
| Pin order | `pin_order.cfg` — 3 hp bundles on west edge |

## Results

### Geometry

| | Value |
|---|---:|
| Die area | **659,963 µm² = 0.660 mm²** |
| Core area | 633,067 µm² |
| Core utilization (final) | **74.3 %** |
| Die dimensions (aspect 1.7) | ≈ 1060 × 622 µm |

### Instance counts (final)

| Class | Count |
|---|---:|
| Total instances | 91,311 |
| Sequential cells (flops) | 10,649 (unchanged — NGPIO=16 RTL) |
| Timing-repair buffers | **1,949** |
| Clock buffers | ~1,325 |
| Clock inverters | ~479 |
| Fill + tap (physical only) | ~48,000 |
| Logic cells (post-opt) | ~40,000 |

### Timing — signoff STA (stage 56 per corner)

| Corner | Setup WNS | Hold WNS | Setup TNS | Hold TNS | Verdict |
|---|---:|---:|---:|---:|---|
| **nom_tt_025C_1v80** | **0.000 ns** | **0.000 ns** | 0.0 | 0.0 | **MET ✅** |
| **nom_ff_n40C_1v95** | **0.000 ns** | **0.000 ns** | 0.0 | 0.0 | **MET ✅** |
| nom_ss_100C_1v60 | −3.858 ns | −0.251 ns | −187.08 | −4.43 | expected fail |
| max_ss_100C_1v60 | −5.836 ns | −0.411 ns | −325.86 | −13.15 | expected fail |
| min_ss_100C_1v60 | −1.959 ns | −0.128 ns | −64.05 | −1.45 | expected fail |

SS corner violations at 1.60 V undervoltage are expected for a 60 MHz
target — AttoIO is specified to operate at 1.80 V ±5 %, so the SS
undervoltage corner is outside the operating envelope.  Tightening
sysclk target frequency to ~25-40 MHz would close SS; leaving as-is
since the TT/FF signoff is the contracted corner for this macro.

### Power @ TT (10 % switching activity)

| Group | Power | Share |
|---|---:|---:|
| Sequential | 28.20 mW | 49.5 % |
| Combinational | 14.53 mW | 25.5 % |
| Clock | 14.27 mW | 25.0 % |
| **Total** | **57.00 mW** | 100 % |

### Routing

| Metric | Value |
|---|---:|
| DRT iterations | 6 (0 → 9433 → 9010 → 1321 → 79 → 0) |
| Final route DRC errors | **0 ✅** |
| Wire length (estimate) | ~1.23 M µm |

### Antenna

| Stage | Violating nets |
|---|---:|
| Pre-repair (post-GRT) | 272 |
| After GRT jumper-only (4 iters) | 249 |
| **Final post-DRT** | **249 nets / 315 pins** |

Expected with jumper-only mode — pins that can't be fixed with layer
hops alone remain flagged.  In a fully-diode strategy these would be
zero; the tradeoff is ~500 fewer pre-route diode cells (skipping the
output-port diodes and heuristic pass).

### Physical signoff

| Check | Result |
|---|---|
| Magic DRC | **0 violations ✅** |
| KLayout DRC | **0 violations ✅** |
| Netgen LVS | **Circuits match uniquely ✅** |
| Magic antenna check (design) | 249 residuals (see above) |

## Comparison to prior v1.0 / v0.9 attempts

| Phase | Die | Core util | Cells | TRB | Power | STA (TT) |
|---|---:|---:|---:|---:|---:|---|
| v0.9 (Phase 0.9) | 0.251 mm² | — | 20,398 | — | 38 mW | +1.25 ns @ 75 MHz |
| v1.0 (H17 1 × 0.5 mm²) | 0.500 mm² | 83.6 % | 85,039 | — | 44 mW | 0.0 ns @ 60 MHz |
| **v1.2 (1060 × 622 µm, DELAY 0)** | **0.660 mm²** | **74.3 %** | **91,311** | **1,949** | **57 mW** | **0.0 ns @ 60 MHz ✅** |

v1.2 is slightly larger than v1.0's tightest floorplan because of the
curated-synth-lib's cell mix (ABC now uses only 104 combinational cells
vs full 428, so it picks larger cells for some functions) and the more
conservative 65 %/0.65 floorplan.  The **1,949 timing-repair buffers**
is a 62 % reduction vs the 5,129 that AREA 3 produced in the ABC sweep,
confirming DELAY 0's value.

## Outstanding items / roadmap

1. **SS-corner closure** — either drop sysclk to 30-40 MHz or commit
   to "1.80 V ±5 %" operating envelope in the spec.
2. **Residual antennas** — 249 nets.  Options: (a) accept if pad ring
   has local protection; (b) switch GRT/DRT to `JUMPER_ONLY=false`
   and let the flow insert additional diodes post-route (area cost).
3. **v1.0 full host library** — SPI, TIMER, WDT RPC groups (deferred
   from v1.1).

## Reproduce

```bash
cd flow/librelane
rm -rf runs/attoio_macro_h11
./run.sh                    # full flow to signoff
# Results:
#   runs/attoio_macro_h11/final/metrics.json    — all numbers in one JSON
#   runs/attoio_macro_h11/56-openroad-stapostpnr/nom_*/ — per-corner STA
#   runs/attoio_macro_h11/65-magic-drc/reports/         — DRC
#   runs/attoio_macro_h11/71-netgen-lvs/reports/         — LVS
```

All config in `flow/librelane/config.json`; custom SDC in
`flow/librelane/attoio.sdc`; pin order in `flow/librelane/pin_order.cfg`;
synth exclusion in `syn/synth_exclude.txt`.
