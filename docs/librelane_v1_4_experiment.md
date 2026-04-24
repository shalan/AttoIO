# AttoIO v1.4 experiment — aggressive hold overfix at PnR

Experimental run exploring whether a tighter PnR hold margin closes
the SS-corner hold residual that v1.3 left open.  **Not tagged** — the
experiment revealed a trade-off that left the design strictly worse than
v1.3, so the main branch stays at v1.3 configuration.  This doc records
what we tried and what we learned.

## Hypothesis

v1.3 closed setup at all 5 corners (using an overconstrained PnR SDC)
but left a small SS hold gap: −0.27 .. −0.43 ns.  The Post-GRT resizer
was running with a 150 ps hold margin; we thought raising it to 300 ps
at GRT (and 100 ps at PL-time) plus lifting the `ALLOW_SETUP_VIOS`
safety flag would let the resizer insert enough hold cells to close
SS hold.

## Configuration change vs v1.3

```diff
-"PL_RESIZER_HOLD_SLACK_MARGIN":  0.00,
+"PL_RESIZER_HOLD_SLACK_MARGIN":  0.10,
-"GRT_RESIZER_HOLD_SLACK_MARGIN": 0.15,
+"GRT_RESIZER_HOLD_SLACK_MARGIN": 0.30,
+"GRT_RESIZER_ALLOW_SETUP_VIOS":  true,
```

All other knobs unchanged (util 72 %, density 0.73, aspect 1.6, PnR
55/28 MHz, signoff 50/25 MHz, DELAY 0 synth, curated lib).

## Results

### Signoff STA per corner (50/25 MHz signoff SDC)

| Corner | v1.3 setup | **v1.4 setup** | v1.3 hold | **v1.4 hold** | Δ hold |
|---|---:|---:|---:|---:|---:|
| TT 025C 1v80  | 0.000 | **0.000** ✅ | 0.000 | **0.000** ✅ | 0 |
| FF -040C 1v95 | 0.000 | **0.000** ✅ | 0.000 | **0.000** ✅ | 0 |
| SS nom 1v60   | 0.000 ✅ | **−0.923** ❌ | −0.266 | **−0.140** | +126 ps |
| SS max 1v60   | 0.000 ✅ | **−1.422** ❌ | −0.434 | **−0.304** | +130 ps |
| SS min 1v60   | 0.000 ✅ | **−0.132** ❌ | −0.136 | **−0.022** | +114 ps |

**Hold improved as predicted** (~125 ps average, scaling the 300 ps
PnR overfix through the 1.6× SS slowdown).  **Setup regressed badly**
at SS (worst case −1.42 ns at max_ss).  TT/FF unchanged — the setup
regression is SS-only.

### Design state

| Metric | v1.3 | **v1.4** | Delta |
|---|---:|---:|---:|
| Cells | 73,760 | 72,699 | −1.4 % |
| Die area | 0.597 mm² | 0.597 mm² | same |
| Core util | 81.8 % | **82.9 %** | +1.1 pp |
| Timing-repair buffers | 1,949 | 2,475 | **+27 %** |
| Dedicated hold buffers | ~200 | **645** | **+223 %** |
| Power @ TT | 57.0 mW | 56.9 mW | −0.2 % |

### Physical checks (all pass)

| Check | Result |
|---|---|
| Magic DRC | 0 ✅ |
| KLayout DRC | 0 ✅ |
| Route DRC | 0 ✅ |
| Netgen LVS | Circuits match uniquely ✅ |
| Residual antennas | 247 nets (v1.3: 248) |

## Root cause of the setup regression

`GRT_RESIZER_ALLOW_SETUP_VIOS=true` tells `repair_timing` to not veto
a hold-fix buffer even if it degrades a setup path.  Combined with
the 300 ps hold margin target, the resizer inserted **645 hold
buffers** (up from ~200 in v1.3).  Each hold buffer stretches some
data path by one cell delay.

At **TT**, the 55 MHz PnR over-constraint gave us ~1.8 ns of setup
slack on each path — easily absorbed the buffer insertion.  STA at
the 50 MHz signoff SDC showed setup WNS = 0 (MET).

At **SS 1.60 V**, cell delays inflate ~1.6×.  The same hold-buffer
chain now stretches data paths much more than it did at TT, pushing
the AttoRV32 decode-to-writeback chain (`_43317_/Q → rf_rdata[30]`)
from +0 ns slack at TT to −1.4 ns at max_ss.

In short: **hold buffers that were free at TT became setup killers
at SS.** The `ALLOW_SETUP_VIOS` flag made the resizer short-sighted
about cross-corner timing impact.

## Lesson / next steps

For v1.5:
- **Revert** `GRT_RESIZER_ALLOW_SETUP_VIOS` to false (default).
- **Keep** the higher hold margins (`PL=0.10`, `GRT=0.30`).
  Without the setup-vio waiver, the resizer will still insert hold
  buffers up to the margin target but will *stop* whenever a given
  buffer would damage setup.  Because the 55 MHz over-constraint
  already provides generous setup slack at TT, the resizer should
  be able to place most of the hold cells it wants without veto.
- Expect a result that sits between v1.3 and v1.4: hold slightly
  better than v1.3 (maybe +50-80 ps at SS, not the +130 we got here),
  setup held at clean MET at all 5 corners.

## Artifacts

Run dir: `runs/attoio_macro_h11/` (to be overwritten on v1.5 launch).
Signoff STA reports: `runs/attoio_macro_h11/56-openroad-stapostpnr/*/`.
LVS: `runs/attoio_macro_h11/71-netgen-lvs/reports/lvs.netgen.rpt`.
DRC: `runs/attoio_macro_h11/65-magic-drc/reports/drc.magic.rpt`.
