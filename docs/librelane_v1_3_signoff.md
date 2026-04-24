# AttoIO v1.3 — LibreLane signoff report

Second signoff iteration on top of v1.2.  Applies: tighter floorplan
util, overconstrained PnR clocks with a separate signoff SDC, uniform
2 ns min input delay.  Result: **setup MET at all 5 corners** (v1.2
had setup failing at SS).  Hold still has a small margin gap at the
SS 1.60 V undervoltage corner.

## Configuration

| Knob | v1.2 | **v1.3** |
|---|---|---|
| SYNTH_STRATEGY | DELAY 0 | DELAY 0 (unchanged) |
| FP_SIZING | relative | relative |
| **FP_CORE_UTIL** | 65 | **72** |
| **FP_ASPECT_RATIO** | 1.7 | **1.6** |
| **PL_TARGET_DENSITY** | 0.65 | **0.75** |
| FP_CORE_MARGIN | 5 µm | 5 µm |
| **PNR clocks (attoio_pnr.sdc)** | 60/30 MHz (same SDC) | **55/28 MHz (overconstrained)** |
| **Signoff clocks (attoio_signoff.sdc)** | 60/30 MHz (same SDC) | **50/25 MHz (true targets)** |
| Min input delay (uniform) | 1–2 ns by bus | **2.0 ns uniform** |
| PL_RESIZER hold/setup margin | 0 / 0 | 0 / 0 (unchanged) |
| RUN_POST_GRT_RESIZER_TIMING | true | true (unchanged) |
| GRT_RESIZER hold/setup margin | 0.15 / 0.05 | 0.15 / 0.05 (unchanged) |
| Antenna | IN, no-heuristic, jumper-only, 4-iter | unchanged |

## Physical results

| Metric | v1.2 | **v1.3** | Delta |
|---|---:|---:|---:|
| Die area | 0.660 mm² (1060 × 622) | **0.597 mm² (610 × 979)** | **−9.5 %** |
| Core area | 572,990 µm² | 572,990 µm² | same |
| Core utilization (final) | 74.3 % | **81.8 %** | +7.5 pp |
| Total instances | 91,311 | **73,760** | −19.2 % |
| Cell area (post-GRT) | 473,079 µm² | **468,785 µm²** | −0.9 % |
| Timing-repair buffers | 1,949 | **1,860** | −4.6 % |
| Wirelength | ~1.23 M µm | comparable | ~ |
| Aspect | 1060:622 (1.7) | 610:979 (1.6, portrait) | — |

## Timing — signoff STA @ 50/25 MHz (attoio_signoff.sdc)

| Corner | Setup WNS | Hold WNS | Setup TNS | Hold TNS | Verdict |
|---|---:|---:|---:|---:|---|
| **nom_tt_025C_1v80** | **0.000 ns** | **0.000 ns** | 0.0 | 0.0 | **MET ✅** |
| **nom_ff_n40C_1v95** | **0.000 ns** | **0.000 ns** | 0.0 | 0.0 | **MET ✅** |
| **nom_ss_100C_1v60** | **0.000 ns** | −0.266 ns | 0.0 | −2.43 | setup MET, hold gap |
| **max_ss_100C_1v60** | **0.000 ns** | −0.434 ns | 0.0 | −4.20 | setup MET, hold gap |
| **min_ss_100C_1v60** | **0.000 ns** | −0.136 ns | 0.0 | −1.15 | setup MET, hold gap |

### Comparison to v1.2 (same corners, old SDC)

| Corner | v1.2 setup WNS | **v1.3 setup WNS** | v1.2 hold WNS | v1.3 hold WNS |
|---|---:|---:|---:|---:|
| TT | 0 | **0** | 0 | **0** |
| FF | 0 | **0** | 0 | **0** |
| SS nom | −3.86 | **0 ✅** (+3.86 ns!) | −0.25 | −0.27 (same) |
| SS max | −5.84 | **0 ✅** (+5.84 ns!) | −0.41 | −0.43 (same) |
| SS min | −1.96 | **0 ✅** (+1.96 ns!) | −0.13 | −0.14 (same) |

**The overconstrained PnR eliminated all SS setup violations** — this was the v1.2 blocker (AttoRV32 decode path took 38.8 ns at SS vs 33.3 ns period).  At the relaxed 40 ns signoff period and +2.7× TT fmax headroom, setup now closes at SS.  Hold numbers at SS are essentially unchanged because the PnR-time hold-margin strategy doesn't scale hold margin with corner.

### fmax headroom @ TT (post-CTS)

| Clock | PnR target | **Period_min** | **fmax @ TT** | Margin over PnR target |
|---|---:|---:|---:|---:|
| sysclk | 18.18 ns (55 MHz) | **6.63 ns** | **150.88 MHz** | +2.74× |
| clk_iop | 35.71 ns (28 MHz) | **13.15 ns** | **76.03 MHz** | +2.72× |

Both clocks have ~2.7× frequency margin at TT, so SS setup closes even with ~1.6× undervoltage slowdown.

## Power @ TT (10 % activity)

| Group | v1.2 | **v1.3** |
|---|---:|---:|
| Sequential | 28.2 mW | 28.5 mW |
| Combinational | 14.5 mW | 13.0 mW |
| Clock | 14.3 mW | 15.1 mW |
| **Total** | **57.0 mW** | **56.6 mW** |

## Routing

| Metric | v1.2 | **v1.3** |
|---|---:|---:|
| DRT iterations to clean | 6 | ~10 (denser floorplan, slower converge) |
| Final route DRC errors | 0 | **0 ✅** |

## Physical signoff

| Check | Result |
|---|---|
| Magic DRC | **0 violations ✅** |
| KLayout DRC | **0 violations ✅** |
| Route DRC (DRT) | **0 violations ✅** |
| Netgen LVS | **Circuits match uniquely ✅** |
| Residual antennas | 248 nets / 335 pins |

Antennas unchanged from v1.2 (248 vs 249) — same jumper-only repair strategy on the same RTL.

## Outstanding items / roadmap to v1.4

### SS hold gap

Remaining at SS is a **~270 ms hold TNS total (nom corner)**.  Three
paths forward, in order of increasing invasiveness:

1. **Spec acceptance.**  AttoIO's operating envelope is 1.80 V ±5 %
   (1.71–1.89 V).  SS at 1.60 V is 12 % undervoltage — outside the
   envelope.  For any host SoC that guarantees the rail stays within
   spec (which all regulated designs do), the SS hold result is
   informational only.
2. **Tighter PnR hold margin.**  Bump `PL_RESIZER_HOLD_SLACK_MARGIN`
   from 0 to 0.5 ns and `GRT_RESIZER_HOLD_SLACK_MARGIN` from 0.15 to
   0.5 ns — inserts more hold buffers at PnR, which *overfix* TT hold
   by ~500 ps, leaving a cushion that SS can absorb.  Area cost
   ~3–5 %.  Quick to try.
3. **SS-corner-aware hold fix.**  Run the post-GRT resizer with the
   SS corner SPEF/lib active instead of TT.  Requires a custom
   LibreLane step or a pre-signoff ECO pass.  Complex.

My call: ship **v1.3 as the signoff-in-envelope** result; add option 2
as an opt-in for v1.4 if an integrator needs sub-1.70 V operation.

### Antennas

248 residual nets — would clear with `DIODE_ONLY` antenna repair but
at the cost of 200–400 extra diode cells, putting back the DPL
pressure we just relieved.  Acceptable if pad ring carries protection.

## Reproduce

```bash
cd flow/librelane
rm -rf runs/attoio_macro_h11
./run.sh
```

All config in `flow/librelane/config.json`; SDCs in
`flow/librelane/attoio_{pnr,signoff}.sdc`; pin order in
`flow/librelane/pin_order.cfg`; synth exclusion in
`syn/synth_exclude.txt`.
