# AttoIO

A tiny I/O processor (IOP) delivered as a **single hard macro**, built
around the [AttoRV32](https://github.com/shalan/attoRV32) RV32EC core
and intended to be embedded inside a larger SoC as an **APB4 slave**.

## What it does

The host CPU writes a small firmware image into AttoIO's local RAM over
APB, then releases the IOP from reset. The IOP runs programs that:

- emulate peripherals in software (UART, I²C, SPI, GPIO expander,
  sensor decoders, …) by bit-banging 16 dedicated I/O pads,
- accelerate SPI transfers via a built-in byte shift helper (~10× vs
  bit-bang),
- schedule precise events via a 24-bit TIMER with 4 compare channels and
  pad-toggle output (software PWM, baud generation, protocol bit clocks,
  IR carriers),
- perform basic local processing on data exchanged with the host
  through a 256 B shared mailbox (with concurrent-access split across
  two banks).

Because the firmware is host-loadable, a single hardened AttoIO instance
can adopt a different "personality" per application without re-taping out.

## Architecture at a glance

- **Core:** AttoRV32 RV32EC (single-port RF, shared adder, serial
  shift) — compact configuration, `ADDR_WIDTH = 11` (2 KB address
  space).
- **Memory (1792 B total in five
  [DFFRAM](https://github.com/shalan/sky130_gen_dffram) macros):**
  - 3 × 128×32 (3 × 512 B = **1536 B** private SRAM A, 3-bank for
    reduced dynamic power) — code + data + stack
  - 2 × 32×32 (2 × 128 B = 256 B shared mailbox, split for concurrent
    host/IOP access)
- **Host interface:** AMBA **APB4 slave** (PADDR 11-bit, PWDATA/PRDATA
  32-bit, PSTRB byte-enables, PREADY wait-state).
- **I/O:** 16 bidirectional pads, each with `in`, `out`, `out_en`, and
  an 8-bit extended pad-control (drive strength, slew, pull).
- **Clocking:** dual-clock — `sysclk` (APB bus side) + `clk_iop`
  (`sysclk/N`, externally divided). No internal CDC required —
  `clk_iop` edges are a strict subset of `sysclk` edges by construction.
- **Arbitration:** host always wins the mailbox SRAM. Private SRAM A is
  muxed to the APB host during reset (firmware load), then exclusively
  IOP-owned.
- **IRQ routing:** `DOORBELL_H2C` + `WAKE_FLAGS & MASK` + `TIMER_IRQ`
  feed the core IRQ. `WDT_NMI` feeds the core NMI. `DOORBELL_C2H` +
  `WDT_host_alert` drive `irq_to_host`.
- **Accelerators:**
  - SPI byte shift helper (CPOL/CPHA, 16 `clk_iop` cycles per byte).
  - 24-bit TIMER with 4 compares, pad-toggle outputs, 1 input capture.
  - Per-pin wake-edge detector (rise/fall/both + mask).
  - 16-bit watchdog (pet-on-write semantics, NMI + host alert on
    expire).

### v2 memory map (11-bit PADDR / IOP address)

| Range | Size | Contents |
|---|---:|---|
| `0x000 – 0x1FF` | 512 B | SRAM A bank 0 (RAM128) |
| `0x200 – 0x3FF` | 512 B | SRAM A bank 1 (RAM128) |
| `0x400 – 0x5FF` | 512 B | SRAM A bank 2 (RAM128) |
| `0x600 – 0x67F` | 128 B | SRAM B0 (mailbox low) |
| `0x680 – 0x6FF` | 128 B | SRAM B1 (mailbox high) |
| `0x700 – 0x7FF` | 256 B | MMIO page (GPIO, SPI, TIMER, WAKE, WDT, doorbells) |

## Repository layout

```
attoio/
├── docs/               design spec, implementation plan, tracker,
│                       synth/STA report
├── rtl/                synthesizable Verilog for the macro
│   ├── attoio_apb_if.v    APB4 slave wrapper
│   ├── attoio_memmux.v    address decoder + SRAM arbiter
│   ├── attoio_macro.v     top level
│   ├── attoio_gpio.v      GPIO + PADCTL + per-pin WAKE
│   ├── attoio_spi.v       SPI shift helper
│   ├── attoio_timer.v     TIMER + compares + capture
│   ├── attoio_wdt.v       watchdog
│   └── attoio_ctrl.v      doorbells + IOP_CTRL + IRQ routing
├── sw/                 firmware: crt0.S, link.ld, attoio.h, Makefile,
│                       plus example firmwares (empty, uart_tx,
│                       uart_echo, spi_master, i2c_eeprom, …)
├── models/             behavioral and generated DFFRAM netlists
│   ├── dffram_rtl.v    behavioral model (simulation only)
│   └── dffram_gen/     real sky130 generated netlists (RAM128, RAM32)
├── sim/                testbenches (iverilog) with APB host helper,
│                       UART-RX, SPI-slave, I²C-EEPROM models
├── syn/                Yosys synthesis + OpenSTA scripts, SDC, ABC recipe
└── build/              (gitignored) synth/STA/sim outputs
```

## Status

| Milestone | Status |
|---|---|
| Architecture spec (v2) | ✅ frozen |
| RTL: memmux, GPIO, ctrl, SPI, TIMER, WDT, APB IF, macro top | ✅ |
| Firmware infrastructure (crt0, link.ld, attoio.h, Makefile) | ✅ |
| Regression (8 testbenches) | ✅ all pass |
| Example E1 (UART TX + RX echo) | ✅ |
| Example E2 (SPI master) | ✅ |
| Example E3 (I²C master + 24C02 EEPROM) | ✅ |
| Yosys synthesis (sky130) | ✅ clean |
| OpenSTA sign-off @ v1 map | ✅ clk_iop MET, ⚠ sysclk half-cycle CG path |
| Re-synth/STA on v2 APB map | ⏳ pending |
| Tier-2 examples (E4 WS2812, E5–E7 displays) | ⏳ planned |
| PnR / tape-out flow | ⏳ pending |

## Testbenches (all passing)

```
tb_fw_boot      empty firmware loads and reaches WFI
tb_timer        TIMER PWM pad toggle at 40-cycle period
tb_wake         per-pin wake edge detection (3/3 scenarios)
tb_wdt          watchdog pet + expire + host alert (5/5 checks)
tb_spi          SPI master round-trip with slave model
tb_uart         UART TX decodes "Hello, AttoIO\r\n" on pad_out[0]
tb_uart_echo    UART RX → echo TX round-trip ("ABCD")
tb_i2c          I²C master writes+random-reads a 24C02-style EEPROM
```

## Key numbers (pre-v2-resynth, sky130_fd_sc_hd, TT 1.80 V 25 °C)

| Metric | Value |
|---|---|
| Total cells (incl. all DFFRAMs) | **~55 k** (estimate after v2) |
| Chip area | ≈ **0.58 mm²** (estimate after v2) |
| SRAM share | ~88 % |
| Glue/CPU share | ~12 % |
| Private SRAM (SRAM A, 3 banks) | 1536 B |
| Mailbox (SRAM B) | 256 B |
| Setup WNS @ `clk_iop = 30 MHz` | +23 ns (v1) |
| Setup WNS @ `sysclk = 75 MHz` | −0.15 ns (v1 — v2 retune pending) |

The v1 snapshot (25,509 cells, 0.27 mm², 33.9 mW) is captured in
[`docs/synth_sta_report.md`](docs/synth_sta_report.md). A v2 refresh
is pending.

## Running the flow

```bash
# Build an example firmware (crt0 + linker + one of sw/<name>/main.c)
make -C sw FW=uart_echo

# Run any testbench
bash sim/run_i2c.sh                       # I²C EEPROM round-trip
bash sim/run_uart.sh                      # UART TX
FW=uart_echo TB=uart_echo bash sim/run_uart.sh
bash sim/run_spi.sh
bash sim/run_timer.sh
bash sim/run_wake.sh
bash sim/run_wdt.sh
bash sim/run_fw_boot.sh

# Yosys synthesis + OpenSTA
bash syn/run_synth.sh                     # → build/attoio_macro.syn.v
bash syn/run_sta.sh                       # → build/sta.log
```

The synthesis script targets
`$PDK/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib`
— edit `syn/run_synth.sh` if your PDK lives elsewhere.

## Dependencies

- [AttoRV32](https://github.com/shalan/attoRV32) — RV32EC core
  (consumed unmodified; cloned as `../frv32` alongside this repo).
- [sky130_gen_dffram](https://github.com/shalan/sky130_gen_dffram) —
  DFFRAM generator (the netlists shipped under `models/dffram_gen/`
  were produced from it).
- [Yosys](https://github.com/YosysHQ/yosys),
  [OpenSTA](https://github.com/parallaxsw/OpenSTA),
  [Icarus Verilog](https://iverilog.icarus.com/),
  [Volare](https://github.com/efabless/volare) (or any sky130A PDK
  distribution).
- RISC-V toolchain (`riscv64-unknown-elf-gcc` via Homebrew works;
  builds with `-march=rv32ec_zicsr -mabi=ilp32e`).

## Author

Mohamed Shalan ([@shalan](https://github.com/shalan)) — <mshalan@aucegypt.edu>

## License

Apache-2.0 — see [LICENSE](LICENSE).
