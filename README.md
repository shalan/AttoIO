# AttoIO

A tiny I/O processor (IOP) delivered as a **single hard macro**, built
around the [AttoRV32](https://github.com/shalan/attoRV32) RV32EC core
and intended to be embedded inside a larger SoC.

## What it does

The host CPU loads a small firmware image into AttoIO's local RAM and
releases it from reset. The IOP then runs programs that:

- emulate peripherals in software (UART, I²C slave, SPI slave, GPIO
  expander, sensor decoders, …) by bit-banging 16 dedicated I/O pads,
- accelerate SPI transfers via a built-in byte shift helper (~10× vs
  bit-bang), and
- perform basic local processing on data exchanged with the host through
  a small shared mailbox.

Because the firmware is host-loadable, a single hardened AttoIO instance
can adopt a different "personality" per application without re-taping out.

## Architecture at a glance

- **Core:** AttoRV32 RV32EC (single-port RF, shared adder, serial
  shift) — compact configuration.
- **Memory:** 768 B total in three
  [DFFRAM](https://github.com/shalan/sky130_gen_dffram) macros —
  1× 128×32 (512 B private code/data/stack) + 2× 32×32 (256 B shared
  mailbox split into two banks for concurrent host/IOP access).
- **I/O:** 16 bidirectional pads, each with `in`, `out`, `out_en`, and
  8 bits of extended pad control.
- **Clocking:** dual-clock — `sysclk` (host side) + `clk_iop`
  (`sysclk/N`, externally divided). No internal CDC needed because
  `clk_iop` edges are a subset of `sysclk` edges by construction.
- **Arbitration:** host always wins the mailbox SRAM. Private SRAM is
  muxed to host during reset (firmware load), then exclusively
  IOP-owned.
- **Interrupts:** `DOORBELL_H2C` + `WAKE_LATCH` → IOP IRQ. `DOORBELL_C2H`
  → host IRQ.
- **Accelerator:** SPI shift helper with CPOL/CPHA, 16 `clk_iop` cycles
  per byte.

Macro pin count: 261 signals (host bus, 16 pads, 128-bit pad_ctl,
clocks, IRQ).

## Repository layout

```
attoio/
├── docs/               design spec, implementation plan, synth/STA report
├── rtl/                synthesizable Verilog for the macro
├── models/             behavioral and generated DFFRAM netlists
│   ├── dffram_rtl.v    behavioral model (simulation only)
│   └── dffram_gen/     real sky130 generated netlists (RAM128, RAM32)
├── sim/                end-to-end testbench (iverilog)
├── syn/                Yosys synthesis + OpenSTA scripts, SDC, ABC recipe
└── build/              (gitignored) synth/STA/sim outputs
```

## Status

| Milestone | Status |
|---|---|
| Architecture spec | ✅ frozen |
| RTL | ✅ complete (memmux, gpio, ctrl, spi, macro top) |
| End-to-end testbench | ✅ 24/24 passing |
| Yosys synthesis (sky130) | ✅ clean |
| OpenSTA sign-off | ✅ clk_iop MET, ⚠ sysclk half-cycle CG path needs input-delay retune |
| Firmware infrastructure (crt0, linker, headers) | ⏳ pending |
| PnR / tape-out flow | ⏳ pending |

## Quick numbers (sky130_fd_sc_hd, TT 1.80 V 25 °C)

With the real DFFRAM netlists flattened into the macro:

| Metric | Value |
|---|---|
| Total cells | **25,509** |
| Chip area | **~0.27 mm²** (269,416 µm²) |
| SRAM share | 219 k µm² (81 %) |
| Glue/CPU share | 50 k µm² (19 %) |
| Power @ 10 % activity (pessimistic) | ~33 mW |
| Setup WNS @ `clk_iop = 30 MHz` | +23 ns |
| Setup WNS @ `sysclk = 75 MHz` | −0.15 ns (CG path; retune I/O delay) |

See [`docs/synth_sta_report.md`](docs/synth_sta_report.md) for the
full report.

## Running the flow

```bash
# Simulation (icarus verilog)
bash sim/run_tb.sh

# Yosys synthesis
bash syn/run_synth.sh         # -> build/attoio_macro.syn.v

# OpenSTA
bash syn/run_sta.sh           # -> build/sta.log
```

The synthesis script targets
`$PDK/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib`
— edit `syn/run_synth.sh` if your PDK lives elsewhere.

## Dependencies

- [AttoRV32](https://github.com/shalan/attoRV32) — RV32EC core
  (consumed unmodified; cloned as `../frv32` alongside this repo).
- [sky130_gen_dffram](https://github.com/shalan/sky130_gen_dffram) —
  DFFRAM generator (the two netlists shipped under
  `models/dffram_gen/` were produced from it).
- [Yosys](https://github.com/YosysHQ/yosys), [OpenSTA](https://github.com/parallaxsw/OpenSTA),
  [Icarus Verilog](https://iverilog.icarus.com/), [Volare](https://github.com/efabless/volare)
  (or any sky130A PDK distribution).

## Author

Mohamed Shalan ([@shalan](https://github.com/shalan)) — <mshalan@aucegypt.edu>

## License

Apache-2.0 — see [LICENSE](LICENSE).
