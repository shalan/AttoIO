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

## Area / cell count (post-map)

| Module              | Cells  | Area (µm²)   |
|---------------------|--------|--------------|
| `RAM128` (×1, 512 B)| 13,815 | 146,796      |
| `RAM32`  (×2, 256 B)| 3,418 ea. | 72,457    |
| `attoio_macro` glue | 4,858  | 50,163       |
| **Chip (top)**      | **25,509** | **269,416** (≈ 0.269 mm²) |

SRAM share: **81.4 %** of macro area.
Glue / CPU share: 18.6 %.

## Timing

| Path group          | Setup WNS  | Hold WNS | Verdict |
|---------------------|-----------:|---------:|---------|
| `sysclk` (75 MHz)   | **−0.15 ns** | +0.20 ns | VIOLATED by 153 ps |
| `clk_iop` (30 MHz)  | **+23.17 ns** | +0.20 ns | MET |

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

## Power (default 10 % switching activity)

| Group         | Internal | Switching | Leakage | Total  | %      |
|---------------|---------:|----------:|--------:|-------:|-------:|
| Sequential    | 6.49 mW  | 0.66 mW   | 61 nW   | 7.15 mW | 21.1 %|
| Combinational | 5.35 mW  | 17.4 mW   | 42 nW   | 22.7 mW | 67.1 %|
| Clock network | 2.57 mW  | 1.41 mW   | 14 nW   | 3.98 mW | 11.7 %|
| **Total**     | 14.4 mW  | 19.5 mW   | 117 nW  | **33.9 mW** | 100 %|

Upper-bound estimate — real workloads (idle host bus, bit-bang loops)
typically land 3-5× lower.

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
