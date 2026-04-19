# LibreLane flow — `attoio_macro` (Phase H11)

Pushes the AttoIO macro through **LibreLane 3.x** to GDS.
**Flattened-DFFRAM** strategy: the `RAM128x32.nl.v` and `RAM32x32.nl.v`
netlists are fed in as gate-level Verilog and placed/routed alongside
the rest of the standard cells — no separate macro hardening step, no
`EXTRA_LEFS` or `MACRO_PLACEMENT_CFG`.

## Install

LibreLane is installed as a Python package in a local venv, and runs
its toolchain (Yosys, OpenROAD, Magic, KLayout, Netgen) inside the
official container via `--dockerized`.

```bash
cd flow/librelane
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip librelane
librelane --version     # confirm (expect 3.0.2+)
```

Docker Desktop must be running before invoking `run.sh` — the first
containerized invocation pulls the ~2 GB LibreLane image (one-time).

## Files

| File | Purpose |
|---|---|
| `config.json` | Design-under-test config: RTL file list, clocks, floorplan, density |
| `run.sh`      | Driver — activates venv, checks Docker, launches `librelane --dockerized …` |
| `venv/`       | (generated) Python venv with `librelane` — git-ignored |
| `runs/`       | (generated) LibreLane run directories, tagged by `--run-tag` |

## Config highlights

| Key | Value | Why |
|---|---|---|
| `DESIGN_NAME` | `attoio_macro` | top module in `rtl/attoio_macro.v` |
| `CLOCK_PORT` | `[sysclk, clk_iop]` | both are real inputs to the macro; macro treats them as asynchronous |
| `CLOCK_PERIOD` | `15.0` ns | ~67 MHz sysclk, ~1 ns margin over the −0.15 ns WNS observed in standalone STA at 13.333 ns |
| `FP_CORE_UTIL` | `35` | low starting utilization — the flattened DFFRAMs contribute ~48 k cells and we want the first pass to land without congestion hotspots |
| `PL_TARGET_DENSITY` | `0.50` | matched to the low core-util starting point |
| `DESIGN_IS_CORE` | `false` | hard macro for reuse, not a chip; skip IO ring + pads |

`VERILOG_DEFINES` pins the AttoRV32 micro-arch knobs (single-port
regfile, shared adder, serial shift).

## Running

```bash
# Full flow
flow/librelane/run.sh

# Stop after a specific step
flow/librelane/run.sh --to Yosys.Synthesis
flow/librelane/run.sh --to OpenROAD.Floorplan

# Resume an interrupted run
flow/librelane/run.sh --last-run
```

First run takes noticeably longer — the LibreLane container image has
to be pulled.  After that, iteration is fast.

## Expected output

On success, final artifacts land under
`flow/librelane/runs/attoio_macro_h11/final/`:

- `gds/attoio_macro.gds` — full-mask GDSII
- `lef/attoio_macro.lef` — abstract view for parent-SoC integration
- `lib/attoio_macro.lib` — timing model (Liberty)
- `nl/attoio_macro.nl.v` — synthesized gate-level Verilog
- `reports/` — DRC, LVS, timing, power summaries

Status tracked in `docs/tracker.md` under H11.
