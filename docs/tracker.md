# AttoIO Development Tracker

Single source of truth for what's done, what's in flight, and what's
next. Updated at every phase boundary.

Legend: ☐ = not started · ◐ = in progress · ☑ = done · ✗ = won't do

---

## Hardware (macro itself)

| Phase | Deliverable | Status | Notes |
|---|---|---|---|
| H0 | RTL: memmux, GPIO, ctrl (doorbells/IOP_CTRL/IRQ), SPI shift helper, macro top, DFFRAM wrappers | ☑ | In `rtl/` |
| H1 | End-to-end testbench (`tb_attoio.v`) | ☑ | 24/24 passing (see `sim/`) |
| H2 | Yosys synthesis flow (sky130_fd_sc_hd) | ☑ | `syn/synth.ys`, clean |
| H3 | OpenSTA flow (SDC @ 75 / 30 MHz) | ☑ | clk_iop MET; sysclk half-cycle CG path needs I/O-delay retune |
| H4 | Real DFFRAM netlists in-tree (`models/dffram_gen/`) | ☑ | 25,509 cells, 0.27 mm², ~33.9 mW (10 % act.) |
| H5 | **TIMER block** (24-bit CNT + 4×CMP + 1 capture + PWM-out) | ☑ | Phase 0.5a — `rtl/attoio_timer.v`, +1256 cells, tb_timer PASS |
| H6 | **Per-pin WAKE flags + mask** (replace combined `WAKE_LATCH`) | ☐ | Phase 0.5b |
| H7 | **Watchdog timer** (magic-key arm, overflow → NMI + host alert) | ☐ | Phase 0.5c |

---

## Firmware infra (`sw/`)

| Phase | Deliverable | Status | Notes |
|---|---|---|---|
| P0.1 | `sw/link.ld` — memory map + sections | ☑ | SRAM A 512 B / MAILBOX 256 B / MMIO 256 B |
| P0.2 | `sw/crt0.S` — reset vector, trap stub, stack init | ☑ | Weak `__isr` default |
| P0.3 | `sw/attoio.h` — MMIO register map + helpers | ☑ | Matches `docs/spec.md` §8.1 |
| P0.4 | `sw/Makefile` — build / objcopy / hex-for-`$readmemh` | ☑ | `riscv64-unknown-elf-gcc -march=rv32ec_zicsr -mabi=ilp32e` |
| P0.5 | `sw/common/{mailbox.c, timing.c}` | ☑ | + `sw/empty/main.c` smoke target |
| P0.6 | Empty `main()` builds, fits in SRAM A, runs in boot tb | ☑ | **90 B** code, core reaches WFI @ PC=0x060 in 42 clk_iop cycles. Test: `sim/run_fw_boot.sh` |

---

## Example peripherals

Plan: `docs/examples_plan.md` · each example links to its firmware
+ testbench once landed.

### Tier 1 — MVP

| # | Example | Status | Commit |
|---|---|---|---|
| E1 | UART TX + RX (9600 – 1 Mbaud) | ☐ | — |
| E2 | SPI master | ☐ | — |
| E3 | I²C master | ☐ | — |
| E4 | WS2812 LED driver | ☐ | — |

### Tier 2 — Displays

| # | Example | Status | Commit |
|---|---|---|---|
| E5 | HD44780 character LCD | ☐ | — |
| E6 | TM1637 7-seg | ☐ | — |
| E7 | HT1621 segment LCD | ☐ | — |

### Tier 3 — Motor / power

| # | Example | Status | Commit |
|---|---|---|---|
| E8 | 4-ch PWM (RC servo / DC / LED fade) | ☐ | — |
| E9 | Stepper driver (STEP/DIR w/ ramp) | ☐ | — |
| E10 | BLDC 6-step w/ Hall sensors | ☐ | — |
| E11 | Brushed DC closed-loop | ☐ | — |

### Tier 4 — Audio

| # | Example | Status | Commit |
|---|---|---|---|
| E12 | Tone / buzzer melody | ☐ | — |
| E13 | 8-bit PWM-DAC music | ☐ | — |
| E14 | PDM 1-bit DAC | ☐ | — |
| E15 | PSG-style 3-voice synth | ☐ | — |

### Tier 5 — IR

| # | Example | Status | Commit |
|---|---|---|---|
| E16 | IR RX (NEC / SIRC / RC-5 auto-detect) | ☐ | — |
| E17 | IR TX (NEC + Sony) | ☐ | — |
| E18 | Universal learning remote | ☐ | — |

### Tier 6 — Input / sensing

| # | Example | Status | Commit |
|---|---|---|---|
| E19 | 4×4 matrix keypad scanner | ☐ | — |
| E20 | Quadrature encoder + button | ☐ | — |
| E21 | Capacitive touch (self-cap R-C timing) | ☐ | — |
| E22 | Frequency / period counter | ☐ | — |
| E23 | Ultrasonic range finder (HC-SR04) | ☐ | — |
| E24 | Rotary-dial phone decoder | ☐ | — |

### Tier 7 — Legacy protocols

| # | Example | Status | Commit |
|---|---|---|---|
| E25 | 1-Wire master (DS18B20) | ☐ | — |
| E26 | PS/2 keyboard RX | ☐ | — |
| E27 | PS/2 mouse RX | ☐ | — |
| E28 | Modbus-RTU slave over UART | ☐ | — |

### Tier 8 — Slave roles

| # | Example | Status | Commit |
|---|---|---|---|
| E29 | I²C slave (mailbox as EEPROM) | ☐ | — |
| E30 | SPI slave (mailbox as flash) | ☐ | — |
| E31 | Logic analyzer (2-pin timestamped) | ☐ | — |
| E32 | Generic data logger | ☐ | — |

### Tier 9 — Showcases

| # | Example | Status | Commit |
|---|---|---|---|
| E33 | Morse-code keyer | ☐ | — |
| E34 | Charlieplexed 12-LED meter | ☐ | — |
| E35 | Discrete-PWM RGB mixer | ☐ | — |
| E36 | LDR-based ambient/sun tracker | ☐ | — |

---

## Build-environment decisions (frozen once set)

| Decision | Choice | Notes |
|---|---|---|
| Toolchain | `riscv64-unknown-elf-gcc` (Homebrew `riscv-gnu-toolchain`) with `-march=rv32ec_zicsr -mabi=ilp32e` | 13.2.0 verified |
| Default pin map | `pad[0..1]` UART · `[2..5]` SPI · `[6..7]` I²C · `[8]` WS2812 · `[9..14]` display / custom · `[15]` spare | Overridable per example in `sw/examples/<name>/config.h` |
| Testbench style | Real C → objcopy → `$readmemh` hex | Applies from Phase 0 onward; `tb_attoio.v` keeps its hand-assembled image for historical reference |
| Git commits | Author: Mohamed Shalan `<mshalan@aucegypt.edu>`. No co-author footer. | |

---

## Release history

| Tag | Date | Contents |
|---|---|---|
| (none yet) | — | v0.1 target: infra + TIMER/WAKE/WDT additions + Tier-1 examples |

## Area / timing history

| Phase | Cells (glue) | Area (top)     | Setup WNS (sysclk) | Hold WNS | Power @10% |
|---|---:|---:|---:|---:|---:|
| H4 (real DFFRAM) | 4,858 | 269,416 µm² | −0.15 ns | +0.19 ns | 33.9 mW |
| H5 (+ TIMER)    | 6,114 | 282,029 µm² | −0.17 ns | +0.20 ns | 37.1 mW |

The sysclk violation (153 ps) is pre-existing — same host-bus →
SRAM-B clock-gating-check path we identified in H3. TIMER is purely on
the clk_iop domain and adds zero delay there.
