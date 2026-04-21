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
| H6 | **Per-pin WAKE flags + mask** (replace combined `WAKE_LATCH`) | ☑ | Phase 0.5b — `attoio_gpio.v` extended with `WAKE_FLAGS` / `WAKE_MASK` / `WAKE_EDGE`; legacy `WAKE_LATCH` preserved |
| H7 | **Watchdog timer** (16-bit reload, NMI + host alert on expire) | ☑ | Phase 0.5c — `attoio_wdt.v`; MMIO @ 0x3C0/4/8 (now 0x7C0 in v2) |
| H8 | **Memory map v2 + APB4 slave** (1536 B SRAM A in 3 banks; 11-bit address space; AMBA APB4 host interface) | ☑ | Phase 0.6 — `attoio_apb_if.v`, rewritten `attoio_memmux.v` with 3-bank SRAM A. AttoRV32 ADDR_WIDTH=11. Mailbox @ 0x600, MMIO @ 0x700. Setup WNS turned positive (+0.58 ns) because APB ACCESS register stage breaks the old `host_wen → CG` path. |
| H9 | **IRQ verification suite** (TIMER, host doorbell, multi-source aggregation) | ☑ | Phase 0.6b — three new `sim/tb_irq_*.v` testbenches close the gap between `attoio_macro.v:430-431` IRQ wiring and prior coverage. Surfaced **BUG-001** (SRAM B `Do0` race during host polling, see `docs/known_bugs.md`); workaround = C2H-handshake pattern, real fix shipped in Phase 0.7. |
| H10 | **BUG-001 fix** — SRAM B `Do0` capture latches in memmux | ☑ | Phase 0.7 — `attoio_memmux.v` adds `core_b0_rdata_q`/`core_b1_rdata_q` sysclk-domain registers gated by a 1-cycle-delayed `b_grant_core & core_sel_b{0,1}`. Cost: 66 flops, no critical path impact. `tb_irq_doorbell.v` rewritten to use the polling pattern that originally tripped the bug; passes. **Full regression: 14/14 testbenches.** |
| H11 | **LibreLane RTL→GDS flow (flattened DFFRAMs)** | ◐ | Phase H11 — `flow/librelane/` holds `config.json`, `run.sh`, `README.md`. Uses LibreLane 3.0.2 via `--dockerized` against the existing volare sky130A snapshot. Flattened strategy feeds `dffram_gen/dffram_combined.nl.v` as gate-level Verilog; `ERROR_ON_SYNTH_CHECKS: false` lets the flow past the DFFRAM tri-state multi-driver warnings. **Density ceiling (with flattened hand-laid DFFRAMs) is ~50–55%**: 75 % fails DPL-0036 at stage 32, 60 % fails after CTS at stage 35, 35 % completes cleanly through post-CTS with WNS +2.04 ns @ 15 ns sysclk. Floorplan-only snapshots: 35 %→1.74 mm², 60 %→1.02 mm², 75 %→0.82 mm² (die). Full flow not yet run to completion — noted for follow-up (either finish at ~50 % util, or switch to hardened-DFFRAM macro flow to restore the standalone-synth 0.27 mm² area). |
| H12 | **RAM downsize** — 1024 B SRAM A + 128 B mailbox | ☑ | Phase 0.8 — dropped 1× RAM128 and 1× RAM32 (from 3×RAM128+2×RAM32 to 2×RAM128+1×RAM32). Total SRAM 1792 B → 1152 B. `rtl/attoio_memmux.v` rewritten: 3-bank A mux → 2-bank, B0/B1 arbitration → single bank, BUG-001 Do0 latch halved (64→32 flops). `rtl/attoio_macro.v` drops `u_sram_a2` + `u_sram_b1` instances. `sw/link.ld` RAM_A 1536→1024, MAILBOX 256→128. Memory map shifts: SRAM A now 0x000-0x3FF, mailbox 0x600-0x67F. All 15 testbenches' `fw_image [0:383]`→`[0:255]`. **Full regression: 14/14 PASS.** Largest FW (`i2c_eeprom` 654 B) fits with 306 B headroom over 64 B stack reservation. Expected macro-cell drop: 49 k → ~32 k (−35 %). `docs/spec.md` §3/§4/§5/§6 rewritten to v2.1 layout. |

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
| E1 | UART TX + RX (9600 – 1 Mbaud) | ☑ | 1a: TX "Hello, AttoIO" @ 115200. 1b: RX via CMP1 1.5-bit offset + CMP0 auto-reload, echo "ABCD" round-trip. |
| E2 | SPI master | ☑ | Mode 0 @ pad[2-5]; 4-byte TX/RX round-trip with slave model; uses SPI shift helper (16 clk_iop/byte). |
| E3 | I²C master | ☑ | `bdde1d5` — 24C-style EEPROM model: 16-byte block write + 16-byte sequential read, byte-for-byte verified. |
| E4 | WS2812 LED driver | ◐ | `841624b` — TIMER pad-toggle + bootstrap to fix polarity; framework + waveform shape verified, strict per-bit timing needs shadow-CMP1 HW assist (45/71 within ±8 cycles). |

### Tier 2 — Displays

| # | Example | Status | Commit |
|---|---|---|---|
| E5 | HD44780 character LCD | ☑ | Phase 5b — 4-bit mode, RS/E/D4-D7 on pads 9-14; 5 init commands + "AttoIO!" data (12 bytes) verified against behavioural model. 362 B code. |
| E6 | TM1637 7-seg | ☑ | `922975a` — 4-digit display "1234" @ full brightness; 7 bytes (40 C0 06 5B 4F 66 8F) verified against behavioral slave with restart-aware FSM. |
| E7 | HT1621 segment LCD | ☑ | Phase 5c — 3-wire mode (CS/WR/DATA on pads 9-11); 3 transactions verified bit-for-bit: SYS_EN (0xE06), LCD_ON (0xE0E), WRITE@0=0x1234 (25 bits 0x1001234). |

### Tier 3 — Motor / power

| # | Example | Status | Commit |
|---|---|---|---|
| E8 | 4-ch PWM (RC servo / DC / LED fade) | ☑ | Phase E8 — `sw/pwm4`, `sim/tb_pwm4.v`. Soft-PWM at 25/50/75/100 % duty, sampled HIGH counts within 1.1 % of expected. Commit `b9305fb`. |
| E9 | Stepper driver (STEP/DIR w/ ramp) | ☑ | Phase E9 — `sw/stepper`, `sim/tb_stepper.v`. 30-step trapezoid (accel/cruise/decel), timestamped edges confirm monotonic profile. Commit `cb7a83e`. |
| E10 | BLDC 6-step w/ Hall sensors | ☑ | Phase E10 — `sw/bldc6`, `sim/tb_bldc6.v`. Six-state commutation table advanced by per-pin WAKE edges; all 12 commutations across 2 revolutions PASS. Surfaced and retired **BUG-002** (was FW write-order race, not HW — see `docs/known_bugs.md`). |
| E11 | Brushed DC closed-loop | ☑ | Phase E11 — see commit `9703357`. |

### Tier 4 — Audio

| # | Deliverable | Status | Notes |
|---|---|---|---|
| E12 | Tone / buzzer melody | ☑ | Phase E12 — `sw/tone_melody`. TIMER CMP0 pad-toggle + IRQ pacing. 4-note demo at 10/12/15/20 kHz, exactly 40 rising edges per note. Commit `42b1254`. |
| E13 | 8-bit PWM-DAC music | ☑ | Phase E13 — `sw/pwm_dac`. Dual-compare soft-PWM (CMP0 period + CMP1 duty, ISR drives pad). 2048-cycle carrier, 8-sample triangle. 6 interior periods within ±32/2048 (1.6 %). Commit `afbdc27`. |
| E14 | PDM 1-bit DAC | ☑ | Phase E14 — `sw/pdm_dac`. First-order sigma-delta at 100 kHz bit rate. Expected 159 HIGH pulses, measured 158. Commit `3c0cd7f`. |
| E15 | PSG-style 3-voice synth | ☑ | Phase E15 — `sw/psg3`. 3 independent voice phase counters in one ISR, pads 8/9/10, pitches 5/10/25 kHz at 100 kHz sample rate. Exact edge counts (10/20/50). Commit `09fadb7`. |

### Tier 5 — IR

| # | Example | Status | Notes |
|---|---|---|---|
| E16 | IR RX (NEC decoder via TIMER CAPTURE) | ☑ | Phase E16 — `sw/ir_rx`. TIMER CNT free-running, CAP rising-edge IRQ; ISR computes Δ from last capture, classifies header vs bit-0 vs bit-1. NEC frame 0xABCD1234 decoded cleanly, 50× scaled timings. Commit `23960f5`. |
| E17 | IR TX (NEC envelope) | ☑ | Phase E17 — `sw/ir_tx`. Absolute-time edge scheduling via TIMER CMP0 polling so per-edge jitter doesn't accumulate. Header 181.12 µs (target 180, +0.6 %), frame 0xABCD1234 decoded cleanly from TB-side envelope timing. Commit `fc9351b`. |
| E18 | Universal learning remote | ☑ | Phase E18 — `sw/ir_learn`. Two-phase: LEARN uses TIMER CAPTURE on both edges of pad[3] to record N timestamps, REPLAY toggles pad[8] at cumulative delta offsets. 5 inter-edge deltas replayed within ±2.4 % of the captured values. Commit pending. |

### Tier 6 — Input / sensing (partial)

| # | Example | Status | Notes |
|---|---|---|---|
| E20 | Quadrature encoder + button | ☑ | Phase E20 — `sw/qenc`. WAKE on both edges of A/B + falling edge of button; 16-entry signed-delta LUT resolves CW/CCW. 3 CW = +12, 3 CCW = 0, 2 button presses counted. Commit `740917b`. |
| E21 | Capacitive touch (self-cap R-C) | ☑ | Phase E21 — `sw/cap_touch`. Discharge + release + poll-until-HIGH. 2-sensor demo: A (fast rise) counts 2, B (slow rise = touched) counts 23, mask = 0b10. Commit `f050208`. |

### Tier 7 — Legacy protocols (partial)

| # | Example | Status | Notes |
|---|---|---|---|
| E25 | 1-Wire master (DS18B20) | ☑ | Phase E25 — `sw/onewire` + `sim/ds18b20_slave_model.v`. Bit-bang reset/presence + write/read byte. Reads 9-byte scratchpad, temperature decoded as 0x0191 (25.0625 °C). Commit `24f2c5a`. |

### Tier 6 — Input / sensing

| # | Example | Status | Commit |
|---|---|---|---|
| E19 | 4×4 matrix keypad scanner | ☐ | — |
| E20 | Quadrature encoder + button | ☐ | — |
| E21 | Capacitive touch (self-cap R-C timing) | ☐ | — |
| E22 | Frequency / period counter | ☑ | Phase E22 — `sw/freq_counter`, `sim/tb_freq_counter.v`. TIMER CAPTURE + CMP0 IRQ multi-source ISR. 10 kHz stimulus measured as 20 ± 2 edges / 2 ms gate across two consecutive windows. Commit `bcbf3f1`. |
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
| H6 (+ per-pin WAKE) | 6,442 | 285,230 µm² | −0.25 ns | +0.20 ns | 38.2 mW |
| H7 (+ WDT) | 6,564 | 286,378 µm² | −0.15 ns | +0.23 ns | 37.6 mW |
| H8 (v2: APB + 1536 B SRAM A, 3 banks) | 6,710 | 580,995 µm² | **+0.58 ns** ✓ | +0.23 ns | 87.7 mW |

The sysclk violation (153 ps) is pre-existing — same host-bus →
SRAM-B clock-gating-check path we identified in H3. TIMER is purely on
the clk_iop domain and adds zero delay there.
