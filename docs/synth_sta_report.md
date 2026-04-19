# AttoIO — Synthesis & STA Report

Post-synthesis area / timing / power results for the `attoio_macro`
hard macro with the **full DFFRAM netlists** flattened in.

## Toolchain & PDK

| Item          | Value                                                              |
|---------------|--------------------------------------------------------------------|
| Synthesizer   | Yosys 0.57 (Homebrew)                                              |
| STA           | OpenSTA 2.6.0 (Nix)                                                |
| PDK           | sky130A (volare @ `0fe599b2…54af`)                                 |
| Std-cell lib  | `sky130_fd_sc_hd__tt_025C_1v80.lib`                                |
| SRAM netlists | `models/dffram_gen/RAM128x32.nl.v`, `RAM32x32.nl.v`                |
| Corner        | TT, 1.80 V, 25 °C (pre-PnR sign-off)                               |

## Synthesis flow

1. Read sky130 liberty (blackbox stubs for all std cells).
2. Read generated DFFRAM netlists (`RAM128`, `RAM32` + submodules) and
   the parameterized `DFFRAM` wrapper (with `(* keep = "true" *)` on
   each `RAM128`/`RAM32` instance).
3. Mark `DFFRAM`, `RAM128`, `RAM32` as `keep_hierarchy` so the
   generator-crafted structure is not remapped.
4. Read all AttoIO RTL + AttoRV32 core.
5. `synth -top attoio_macro -flatten` (everything except DFFRAM subtree).
6. `dfflibmap -liberty …` → sky130 flops.
7. `abc -D 13333 -liberty … -script syn/abc.script` (custom `&`-flow).
8. `write_verilog build/attoio_macro.syn.v`.

## Clock constraints (`syn/attoio.sdc`)

| Clock    | Frequency | Period   | Uncertainty (setup / hold) |
|----------|-----------|----------|----------------------------|
| `sysclk` | 75 MHz    | 13.33 ns | 0.25 / 0.10 ns             |
| `clk_iop`| 30 MHz    | 33.33 ns | 0.40 / 0.15 ns             |

- Clock groups declared asynchronous (by architecture, clk_iop edges
  are a strict subset of sysclk edges).
- I/O delays: 30 % of period in/out on the host bus, 8 ns output to
  pads, 3 ns input from pads.
- Driving cell: `sky130_fd_sc_hd__inv_2` on all inputs;
  `sky130_fd_sc_hd__clkbuf_8` on clocks.
- Output load: 17.5 fF (fF unit via `set_cmd_units -capacitance fF`).

## Area / cell count (post-map, Phase 0.8)

| Module              | Instances | Cells / inst | Area (µm²) / inst | Total area (µm²) |
|---------------------|-----------|-------------:|------------------:|-----------------:|
| `RAM128` (512 B)    | 2         | 13,815       | 146,796           | 293,592          |
| `RAM32`  (128 B)    | 1         |  3,418       |  36,228           |  36,228          |
| `attoio_macro` glue | 1         |  6,658       |  68,778           |  68,778          |
| **Chip (top)**      |           |              |                   | **398,599** (≈ 0.399 mm²) |

SRAM share: **82.7 %** of macro area.
Glue / CPU share: 17.3 %.

Phase 0.8 comparison (vs Phase 0.7 / 0.6 layout with 3× RAM128 + 2× RAM32):

| Metric         | Phase 0.7 (computed) | **Phase 0.8** | Δ      |
|----------------|---------------------:|--------------:|-------:|
| RAM banks      | 3 + 2 = 5            | **2 + 1 = 3** | −2     |
| Chip area      | ~562,996 µm² (≈0.56 mm²) | **398,599 µm² (≈0.40 mm²)** | **−29 %** |
| Setup WNS      | −0.15 ns (VIOLATED)  | **+0.97 ns (MET)** | +1.12 ns |

## Timing

| Path group          | Setup WNS | Hold WNS | Verdict |
|---------------------|----------:|---------:|---------|
| `sysclk`  (75 MHz)  | **+0.97 ns** | +0.23 ns | **MET** |
| `clk_iop` (30 MHz)  | > +20 ns   | +0.20 ns | MET     |

The sysclk half-cycle clock-gating-check path that was marginal in
Phase 0.7 (−0.15 ns to the DFFRAM's latch-based CG) cleared by ~1.1 ns
after the downsize — removing one SRAM A bank and one SRAM B bank
shortens memmux's decode + enable tree enough to eliminate the
violation.

### Critical path (sysclk, violating)

```
host_wen (4 ns input delay)
  → memmux addr decode
  → sram_b0 enable buffer
  → RAM32.DEC0.AND0 → RAM16 → RAM8 → WORD[3] → BYTE[1].CGAND
  → dlclkp_1 (latch-based clock gate)
endpoint = clock gating check @ 6.67 ns (sysclk / 2)
required = 6.314 ns,  arrival = 6.468 ns  →  slack = −0.153 ns
```

The DFFRAM uses **latch-based clock gating** that expects the enable
stable half a clock before the capture edge. The 4 ns external input
delay leaves only ~2.7 ns of internal decode budget.

### Three ways to close the sysclk gap

1. Reduce the host-side input delay on the SDC (4.0 ns → 3.5 ns or
   less). Most conventional fix.
2. Drop sysclk slightly (75 → 72 MHz).
3. Add a host-bus input register inside the macro (costs 1 cycle of
   latency but decouples the CG check).

## Power (default 10 % switching activity, Phase 0.8)

| Group         | Internal | Switching | Leakage | Total   | %      |
|---------------|---------:|----------:|--------:|--------:|-------:|
| Sequential    | 13.6 mW  | 1.51 mW   | 92 nW   | 15.1 mW | 20.6 % |
| Combinational | 12.1 mW  | 40.2 mW   | 62 nW   | 52.3 mW | 71.3 % |
| Clock network | 3.84 mW  | 2.10 mW   | 21 nW   | 5.94 mW |  8.1 % |
| **Total**     | 29.5 mW  | 43.8 mW   | 175 nW  | **73.3 mW** | 100 % |

Upper-bound estimate — real workloads (idle host bus, bit-bang loops)
typically land 3–5× lower.

**Note on the Phase 0.8 jump** (33.9 mW → 73.3 mW).  The macro has
fewer cells and smaller area, but the reported standalone-STA power
roughly doubled.  Most likely cause: ABC was given more setup slack
(WNS went from −0.15 ns to +0.97 ns) and chose higher-drive cells
under the same `-D 13333` target.  The pre-PnR power number is an
upper bound and tends to shift with any change in cell mix; the
PnR-based estimate from LibreLane (Phase H11) is what the tape-out
story relies on.  Worth a follow-up pass with explicit area-oriented
ABC options if we want a tighter pre-PnR figure.

## Files

| Path                         | Contents                              |
|------------------------------|---------------------------------------|
| `syn/synth.ys`               | Yosys script                          |
| `syn/abc.script`             | ABC `&`-flow recipe                   |
| `syn/run_synth.sh`           | Synth driver                          |
| `syn/attoio.sdc`             | SDC constraints                       |
| `syn/sta.tcl`                | OpenSTA script                        |
| `syn/run_sta.sh`             | STA driver                            |
| `models/dffram_gen/*.v`      | Generated DFFRAM netlists + wrapper   |
| `build/attoio_macro.syn.v`   | Gate-level netlist (generated)        |
| `build/yosys.log`            | Full synthesis log (generated)        |
| `build/sta.log`              | Full STA log (generated)              |

## Reproduce

```bash
cd /path/to/attoio
bash syn/run_synth.sh
bash syn/run_sta.sh
```
