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

## Area / cell count (post-map, Phase 0.9)

| Module              | Instances | Area (µm²) / inst | Total area (µm²) |
|---------------------|-----------|------------------:|-----------------:|
| `RAM128` (512 B)    | 1         | 146,796           | 146,796          |
| `RAM32`  (128 B)    | 1         |  36,228           |  36,228          |
| `attoio_macro` glue | 1         |  67,894           |  67,894          |
| **Chip (top)**      |           |                   | **250,918** (≈ 0.251 mm²) |

SRAM share: **72.9 %** of macro area.
Glue / CPU share: 27.1 %.

Phase progression:

| Metric            | Phase 0.7 (3+2)  | Phase 0.8 (2+1)  | **Phase 0.9 (1+1)**       |
|-------------------|-----------------:|-----------------:|--------------------------:|
| DFFRAMs           | 5                | 3                | **2**                     |
| Chip area         | ≈ 0.56 mm²       | ≈ 0.40 mm²       | **≈ 0.251 mm²**           |
| Δ from previous   | —                | −29 %            | **−37 %**                 |
| Setup WNS @ 75 MHz| −0.15 ns ❌      | +0.97 ns ✅      | **+1.25 ns ✅**           |
| Power @ 10 % act. | 33.9 mW (Yosys hyped) | 73.3 mW          | **38.2 mW**               |

## Timing

| Path group          | Setup WNS    | Hold WNS  | Verdict |
|---------------------|-------------:|----------:|---------|
| `sysclk`  (75 MHz)  | **+1.25 ns** | +0.23 ns  | **MET** |
| `clk_iop` (30 MHz)  | > +20 ns     | +0.20 ns  | MET     |

The Phase 0.9 downsize bought another ~280 ps of setup margin on
sysclk vs Phase 0.8 — the further-shortened memmux decode + enable
tree (single-bank SRAM A → no `core_sel_a0/a1` mux) is the source.

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

## Power (default 10 % switching activity, Phase 0.9)

| Group         | Total       | %      |
|---------------|------------:|-------:|
| Sequential    |  ~7 mW      | ~18 %  |
| Combinational | ~28 mW      | ~73 %  |
| Clock network | ~3 mW       | ~8 %   |
| **Total**     | **38.2 mW** | 100 %  |

Upper-bound estimate — real workloads (idle host bus, bit-bang loops)
typically land 3–5× lower.  Down ~48 % from Phase 0.8's 73.3 mW —
the dropped RAM128 bank accounts for the bulk of the savings.

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
