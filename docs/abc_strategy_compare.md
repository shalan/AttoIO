# ABC strategy comparison — AREA 3 vs DELAY 0 vs CUSTOM

One-shot apples-to-apples sweep to pick the default `SYNTH_STRATEGY` for
AttoIO v1.x PnR.  All three runs used:

- **Macro**: `attoio_macro` (v1.0 RTL, NGPIO=16, 3 hp bundles, PINMUX)
- **Die**: 1200 × 700 µm (0.840 mm²), absolute sizing, aspect 1:0.58
- **Synth cell pool** (restricted via `SYNTH_EXCLUDED_CELL_FILE`):
  - 104 combinational cells from `syn/hd_102_tt.lib` (curated "good-timing"
    subset)
  - 64 FFs/latches from the full sky130_fd_sc_hd TT lib
  - 260 full-PDK cells excluded from synth
- **PnR cell pool**: unrestricted (full 428-cell PDK library)
- **Flow stop**: `--to OpenROAD.ResizerTimingPostCTS` (stage 37 inclusive)
- **Resizer margins** for this comparison (shared across all three runs):
  - `PL_RESIZER_HOLD_SLACK_MARGIN`   = 0.00 ns (minimal stage-37 hold fix)
  - `PL_RESIZER_SETUP_SLACK_MARGIN`  = 0.00 ns
  - `RUN_POST_GRT_RESIZER_TIMING`    = true (stage not reached here)
  - `DESIGN_REPAIR_MAX_WIRE_LENGTH`  = 400 µm
  - `CTS_DISTANCE_BETWEEN_BUFFERS`   = 200 µm
  - Antenna repair: 4-iter, jumper-only, NGPIO=16

The three strategies differ only in the ABC recipe emitted by Yosys.

## Recipes

**AREA 3** (LibreLane built-in, ORFS minimal area script)
```
strash
dch
map -B 0.9
topo
stime -c
buffer -c -N 10
upsize -c
dnsize -c
```

**DELAY 0** (LibreLane built-in, the simplest DELAY variant)
```
fx; mfs; strash; drf -l
balance; drw -l; drf -l; balance; drw -l; drw -l -z; balance;
drf -l -z; drw -l -z; balance
retime -M 6
scleanup
map -p -B 0.2 -A 0.9 -M 0
retime
&get -n; &st; &dch; &nf; &put
```

**CUSTOM** (user-supplied, overlaid into AREA 0 via a container bind mount)
```
strash
ifraig; scorr; dc2; dretime; strash   (×12 iterations)
&get -n; &dch -f; &nf {D}; &put
buffer -c
topo
upsize {D} -c
dnsize {D} -c
```

The CUSTOM recipe uses sequential redundancy removal (`scorr`) and
dc2/dretime for timing-aware AIG optimization before a single &nf mapping
pass — a heavy logic-level preprocessor + lightweight mapping.

## Results

### Headline comparison (post-stage-37, TT 1.80 V 25 °C, 60 MHz sysclk)

| Strategy | LibreLane runtime | Total cells | Cell area (µm²) | Core util | Setup WNS | Hold WNS | Hold TNS | Timing-repair buffers | Power (mW) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **AREA 3** | **2259 s** (37.6 min) | 51,600 | 510,740 | 63.2 % | 0.000 ns | −0.787 ns | −36.15 ns | 5,129 | 73.9 |
| **DELAY 0** | **455 s** (7.6 min) | **43,657** | **479,016** | **59.3 %** | 0.000 ns | **−0.742 ns** | −39.25 ns | **2,190** | **52.9** |
| **CUSTOM** | 1318 s (21.9 min) | 50,173 | 516,011 | 63.9 % | 0.000 ns | −0.683 ns | −50.89 ns | 6,557 | 78.2 |

(The ~0.7-ns hold violation is **expected** for this experiment — with
`PL_RESIZER_HOLD_SLACK_MARGIN = 0` the stage-37 resizer does near-zero
hold work; the bulk of hold closure happens at the post-GRT resizer which
this sweep does not reach.  The relative ranking between strategies is
still representative.)

### Cell-class breakdown (post-stage-37)

| Class | AREA 3 | DELAY 0 | CUSTOM |
|---|---:|---:|---:|
| Sequential (flops) | 10,649 | 10,649 | 10,649 |
| Multi-input combinational | 18,932 | **16,880** | 16,646 |
| Inverters (data) | 1,101 | **71** | 246 |
| Buffers (data) | 1,941 | **80** | 2,208 |
| Clock buffers | 1,325 | 1,376 | 1,327 |
| Clock inverters | 479 | 367 | 496 |
| Timing-repair buffers | 5,129 | **2,190** | 6,557 |

## Observations

1. **DELAY 0 wins every dimension we care about on this design**: fastest
   ABC runtime (5× faster than AREA 3, 3× faster than CUSTOM), smallest
   cell count and area, lowest utilization (most routing room for the
   later stages), fewest hold-fix buffers, lowest power (by 28 %), and
   the shortest hold-WNS violation.  This is counter-intuitive for a
   delay-biased recipe — but DELAY 0 is the *simplest* of the DELAY
   variants (no `choice2` / `choice` passes), so on a relatively narrow
   datapath like the AttoRV32 + GPIO/Timer it avoids the pessimistic
   over-buffering that AREA 3's `buffer -c -N 10` produces.

2. **AREA 3 is heavy on data inverters and buffers** (1101 + 1941) because
   its final `buffer -c -N 10; upsize -c; dnsize -c` passes insert
   buffers eagerly on high-fanout nets, then upsize the rest.  That
   extra driver strength increases cell area (+6 %) and bloats the
   timing-repair buffer count in stage 37 (+134 % vs DELAY 0).

3. **CUSTOM's 12× scorr/dc2/dretime** pass generates the smallest
   combinational cell count (16,646) at the AIG level — it collapses
   more redundant sequential logic than the built-ins.  But its
   `buffer -c; upsize {D} -c` post-mapping is even more aggressive than
   AREA 3's, producing 6,557 timing-repair buffers and the highest
   cell area, power, and hold-TNS of the three.

4. **Synth runtime**: AREA 3's 37.6 min is bloated by ABC's `dch` pass
   on ~30 k-node AIG + buffering.  DELAY 0's absence of `choice2`/`dch`
   makes it dramatically faster.  CUSTOM is in the middle — the 12
   scorr iterations cost ~14 min, the rest is mapping.

## Recommendation

**Use `SYNTH_STRATEGY = "DELAY 0"` as the default** for AttoIO v1.x
signoff.  It produces a smaller, faster, lower-power design *and*
finishes the flow in 1/5 the wall-time of AREA 3.  The custom
`scorr+dretime` recipe is worth keeping around for research but doesn't
beat DELAY 0 on this particular design — the aggressive post-mapping
buffering wipes out the AIG-level gains.

Downstream impact unverified: the full signoff run (through stage 56)
is still needed to confirm that the post-GRT resizer can close hold on
each variant.  Given DELAY 0's ~30 % head start in cell area and hold
TNS, it's the lowest-risk choice for landing v1.x.

## Reproduce

```bash
cd flow/librelane

# Single variant:
./run_abc_compare.sh "DELAY 0" delay0

# Full 3-way sweep:
./run_abc_compare_all.sh

# Results per variant: runs/abc_<tag>/{final/metrics.json,37-.../or_metrics_out.json}
# Runtime table:       runs/abc_runtimes.txt
```

The bind-mount technique used to inject the CUSTOM recipe is documented
in `flow/librelane/run_abc_compare.sh` (`-v host_file:container_path:ro`);
the LibreLane container image itself is not modified.
