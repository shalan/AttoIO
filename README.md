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
- **Memory (640 B total in two
  [DFFRAM](https://github.com/shalan/sky130_gen_dffram) macros, Phase 0.9):**
  - 1 × 128×32 (**512 B** private SRAM A, single bank) — code + data + stack
  - 1 × 32×32 (**128 B** shared mailbox, single bank, host-priority
    arbitrated)
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

### Memory map (11-bit PADDR / IOP address, Phase 0.9)

| Range | Size | Contents |
|---|---:|---|
| `0x000 – 0x1FF` | 512 B | SRAM A (private, RAM128, single bank) |
| `0x200 – 0x5FF` | — | *unmapped — reads return 0* |
| `0x600 – 0x67F` | 128 B | SRAM B (mailbox, RAM32) |
| `0x680 – 0x6FF` | — | *unmapped* |
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
| Architecture spec (v2.2 — Phase 0.9 downsize) | ✅ frozen |
| RTL: memmux, GPIO, ctrl, SPI, TIMER, WDT, APB IF, macro top | ✅ |
| Firmware infrastructure (crt0, link.ld, attoio.h, Makefile) | ✅ |
| **Regression (28 testbenches)** | ✅ all pass |
| Tier-1 examples (UART TX/RX, SPI master, I²C master) | ✅ |
| Tier-2 examples (WS2812, TM1637, HD44780, HT1621) | ✅ |
| Tier-3 examples (4-ch PWM, stepper, BLDC, brushed DC) | ✅ |
| Tier-4 examples (tone melody, PWM-DAC, PDM-DAC, PSG 3-voice) | ✅ |
| Tier-5 examples (IR RX, IR TX, learning remote) | ✅ |
| Tier-6 examples (freq counter, cap touch, quad encoder) | ◐ 3 of 5 |
| Tier-7 examples (1-Wire master) | ◐ 1 of 4 |
| Yosys synthesis + OpenSTA (sky130) | ✅ **WNS +1.25 ns @ 75 MHz, 0.25 mm²** |
| LibreLane 3.0.2 flow scaffolding | ◐ config + driver in `flow/librelane/`, first full PnR pending |
| PnR / tape-out flow | ⏳ |

## Example firmwares

All firmwares are stand-alone — one `main.c`, no shared code beyond
`crt0.S` + `attoio.h`.  They're grouped by theme below.

All measurements are `text + data + bss` from
`riscv64-unknown-elf-size -d`, against the Phase 0.9 SRAM A budget
of **512 bytes** (with 64 B reserved for stack → 448 B usable for
text + data + bss).  One historical example (`i2c_eeprom`, 584 B)
exceeds this budget and is excluded from the default regression
sweep — see notes at the end of this section.

### Tier 0 — Core / IRQ infrastructure

| Example | FW size | Testbench | What it demonstrates |
|---|---:|---|---|
| `empty` | 90 B | `tb_fw_boot` | Smallest viable firmware — boots to `wfi` |
| `timer_pwm` | 126 B | `tb_timer` | Hardware PWM via TIMER CMP0 pad-toggle |
| `wake_test` | 204 B | `tb_wake` | Per-pin GPIO WAKE edge detection → IRQ |
| `wdt_test` | 210 B | `tb_wdt` | 16-bit watchdog pet-on-write + NMI on expire |
| `irq_timer` | 176 B | `tb_irq_timer` | TIMER CMP_IRQ_EN drives `iop_irq` cleanly |
| `irq_doorbell` | 174 B | `tb_irq_doorbell` | Host → IOP doorbell IRQ (also verifies BUG-001 fix) |
| `irq_aggregate` | 272 B | `tb_irq_aggregate` | Multi-source ISR dispatch (TIMER + WAKE together) |

### Tier 1 — Bit-bang peripherals

| Example | FW size | Testbench | What it demonstrates |
|---|---:|---|---|
| `uart_tx` | 240 B | `tb_uart` | UART TX bit-bang (decodes `"Hello, AttoIO\r\n"`) |
| `uart_echo` | 326 B | `tb_uart_echo` | Full-duplex UART — RX sync + mid-bit sample + echo TX |
| `spi_master` | 252 B | `tb_spi` | SPI master using the on-chip byte-shift accelerator |
| `i2c_eeprom` | 584 B | `tb_i2c` | I²C master exercising a 24C02-style EEPROM model — **does not fit in Phase 0.9's 512 B SRAM A; archival only, excluded from default regression** |

### Tier 2 — Displays

| Example | FW size | Testbench | What it demonstrates |
|---|---:|---|---|
| `ws2812` | 361 B | `tb_ws2812` | WS2812 3-LED frame via TIMER pad-toggle (partial demo) |
| `tm1637` | 414 B | `tb_tm1637` | TM1637 4-digit 7-seg, "1234" at full brightness |
| `hd44780` | 362 B | `tb_hd44780` | HD44780 LCD in 4-bit mode |
| `ht1621` | 350 B | `tb_ht1621` | HT1621 segment LCD, 3-wire serial |

### Tier 3 — Motor / power

| Example | FW size | Testbench | What it demonstrates |
|---|---:|---|---|
| `pwm4` | 268 B | `tb_pwm4` | 4-channel IRQ-paced soft-PWM at 25 / 50 / 75 / 100 % duty |
| `stepper` | 328 B | `tb_stepper` | STEP/DIR driver with 30-step trapezoidal velocity ramp |
| `bldc6` | 320 B | `tb_bldc6` | BLDC 6-step commutation driven by 3 Hall-sensor wakes |
| `dc_tacho` | 274 B | `tb_dc_tacho` | Brushed DC speed measurement via TIMER CAPTURE |

### Tier 4 — Audio

| Example | FW size | Testbench | What it demonstrates |
|---|---:|---|---|
| `tone_melody` | 280 B | `tb_tone_melody` | 4-note buzzer melody at 10/12/15/20 kHz |
| `pwm_dac` | 380 B | `tb_pwm_dac` | 8-bit PWM DAC, soft dual-compare |
| `pdm_dac` | 376 B | `tb_pdm_dac` | 1-bit PDM via first-order ΣΔ modulator |
| `psg3` | 426 B | `tb_psg3` | PSG-style 3-voice square-wave synth |

### Tier 5 — IR

| Example | FW size | Testbench | What it demonstrates |
|---|---:|---|---|
| `ir_rx` | 366 B | `tb_ir_rx` | NEC 32-bit decoder using TIMER CAPTURE Δ-classification |
| `ir_tx` | 306 B | `tb_ir_tx` | NEC 32-bit envelope transmitter, absolute-time edge scheduling |
| `ir_learn` | 416 B | `tb_ir_learn` | Universal learning remote — capture N edges, replay the waveform |

### Tier 6 — Input / sensing (partial)

| Example | FW size | Testbench | What it demonstrates |
|---|---:|---|---|
| `freq_counter` | 248 B | `tb_freq_counter` | Frequency counter — TIMER CAPTURE + MATCH multi-source ISR |
| `cap_touch` | 232 B | `tb_cap_touch` | Self-capacitance touch via discharge/rise-time measurement |
| `qenc` | 348 B | `tb_qenc` | Quadrature encoder + button, WAKE-driven with signed-LUT state machine |

### Tier 7 — Legacy protocols (partial)

| Example | FW size | Testbench | What it demonstrates |
|---|---:|---|---|
| `onewire` | 432 B | `tb_onewire` | Dallas 1-Wire master — reset/presence, byte I/O, DS18B20 scratchpad |

### Headroom

Largest currently-fitting firmware is `onewire` at 432 B, leaving
**16 B headroom** under the 448 B effective code budget (512 B SRAM A
minus 64 B reserved stack).  Tighter than Phase 0.8's 306 B, but
real — most peripheral demos cluster around 200-400 B.  If a future
demo needs more code space, the RTL can be reverted to a 1024 B
SRAM A by re-adding `u_sram_a1` + the second-bank case in memmux
(Phase 0.8 layout).

The `i2c_eeprom` example (584 B) sits above the budget and is kept
as archival only — its source is in-tree and `tb_i2c.v` works
against it under the Phase 0.8 1024 B layout, but it is **excluded
from the default 28-test regression sweep**.

## Testbenches (28 passing)

Every example above has a matching `sim/tb_*.v` testbench (plus
`run_*.sh` driver).  Full regression:

```bash
for s in sim/run_*.sh; do bash "$s"; done
```

Four extra diagnostic testbenches (`tb_core_hazard`, `tb_macro_hazard`,
`tb_macro_hazard_isr`, `tb_bldc6_snoop`) ship in the tree as cold-case
probes for future store-sequence debugging.  They're not part of the
default regression but are runnable standalone.

## Key numbers (Phase 0.9, sky130_fd_sc_hd, TT 1.80 V 25 °C)

| Metric | Value |
|---|---|
| Chip area | ≈ **0.25 mm²** (250,918 µm²) |
| Private SRAM (SRAM A, 1 × 128×32) | **512 B** |
| Mailbox (SRAM B, 1 × 32×32) | **128 B** |
| Power @ 10 % activity | **38.2 mW** (down from 73.3 mW @ Phase 0.8) |
| Setup WNS @ `clk_iop = 30 MHz` | > +20 ns |
| Setup WNS @ `sysclk = 75 MHz` | **+1.25 ns** (MET — was +0.97 in Phase 0.8) |

Phase progression so far:

| Phase | DFFRAMs | SRAM total | Chip area | Setup WNS @ 75 MHz |
|---|---|---|---|---|
| 0.6 (initial) | 5 | 1792 B | ≈ 0.56 mm² | −0.15 ns ❌ |
| **0.8** | 3 | 1152 B | ≈ 0.40 mm² | +0.97 ns ✅ |
| **0.9** | **2** | **640 B** | **≈ 0.25 mm²** | **+1.25 ns ✅** |

Full post-synth/STA breakdown is in
[`docs/synth_sta_report.md`](docs/synth_sta_report.md).

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
