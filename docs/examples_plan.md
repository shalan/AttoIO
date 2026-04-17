# AttoIO Example Peripherals — Proposal & Plan

This document proposes a set of example "personalities" (firmware images)
that demonstrate the AttoIO macro's capabilities, along with a phased
implementation plan.

## Resource budget per example

Every example must fit inside the hard macro's resources:

| Resource | Budget |
|---|---|
| Code (.text in SRAM A) | ≤ ~400 B (≤ 200 × 16-bit C-instructions) |
| Globals + stack (SRAM A) | ≤ ~110 B |
| Mailbox to host (SRAM B) | ≤ 256 B (split host-private / IOP-shared) |
| Registers | 16 (RV32E) |
| `clk_iop` | 30 MHz (nominal; any N divider of `sysclk`) |
| No M, no F — multiplication/division via shift-add in firmware |

Implication: C code compiled `-Os -march=rv32ec_zicsr` + hand-tuned asm
for the inner timing loop of each peripheral.

---

## Proposed example list

### Tier 1 — MVP (ship first, covers the design's range)

| # | Name | Pins used | Demo-value |
|---|------|-----------|------------|
| **E1** | **UART** (TX + RX, 115200-9600 baud) | 2 (TXD, RXD) | Canonical peripheral. RX uses `WAKE_LATCH` on RXD edge + half-bit timing. `DOORBELL_C2H` signals "line received". Validates the whole firmware/host/IRQ path. |
| **E2** | **SPI master** (up to ~1.9 MHz) | 4 (SCK, MOSI, MISO, CS) | Showcases the hardware SPI shift helper. Target: SD-card-style commands or an 8-pin flash. |
| **E3** | **I²C master** (100 kHz / 400 kHz) | 2 (SDA, SCL) | Bit-bang with `pad_oe` for open-drain. Target: a BME280 or 24Cxx EEPROM. Exercises multi-byte transfers and ACK handling. |
| **E4** | **WS2812 LED strip driver** | 1 (DIN) | Tight 350/700/250 ns bit timing. Uses `pad_ctl` for slew-rate boost. Very visual demo; tests the deterministic-cycle model. |

These four span: async-serial + event-driven (UART), hardware-accelerated
sync serial (SPI), bit-banged sync multi-master (I²C), hard real-time
output (WS2812).

### Tier 2 — Second batch (once Tier 1 lands)

Three complementary display controllers (all segment/character, no
framebuffer streaming needed — small mailbox traffic, simple firmware):

| # | Name | Pins | Interface | Why |
|---|------|------|-----------|-----|
| E5 | **HD44780 character LCD** (4-bit mode) | 6 (RS, E, D4–D7) | Parallel, slow, command-oriented | Classic alphanumeric LCD. Demos `pad_ctl` drive strength for long traces and slow parallel strobes. ~40 µs per command, 1.5 ms for clear/home. |
| E6 | **TM1637 4-digit 7-seg** | 2 (DIO, CLK) | 2-wire custom serial (I²C-like but not I²C) | Tiniest code, ideal "first custom firmware" tutorial. START / 8-bit LSB-first / ACK / STOP; address + brightness commands. |
| E7 | **HT1621 segment LCD** (meter/pedometer style) | 3 (CS, WR, DATA) | 3-wire proprietary | Segmented LCD used in digital multimeters, calorie counters, cheap clocks. 9-bit command frames + 3-bit ID / 6-bit addr / 4-bit data writes; up to 128 segments. Low-power display demo. |

After these three land:

| # | Name | Pins | Why |
|---|------|------|-----|
| E8 | **4×4 matrix keypad scanner** | 8 (4 rows drive, 4 cols read) | Periodic scan at ~50 Hz. Change-of-state → `DOORBELL_C2H`. Uses `pad_oe` toggle (strobe pattern) + `pad_in` read. |
| E9 | **Quadrature encoder + button** | 3 (A, B, SW) | Edge events via `WAKE_LATCH`. State machine counts position. |
| E10 | **4-channel software PWM** | 4 | 8-bit duty, 1 kHz carrier. Demonstrates the timer IRQ (firmware loop on `clk_iop`) and pin-grouping. |

### Tier 3 — Advanced / interesting (pick per interest)

| # | Name | Pins | Why |
|---|------|------|-----|
| E11 | **I²C slave** (exposes mailbox as a 256-B EEPROM) | 2 | Most complex — needs sub-microsecond response to START/STOP. Proves AttoIO can be a slave peripheral itself. |
| E12 | **IR remote decoder** (NEC protocol) | 1 | Timestamp-based edge decode, 32-bit frame assembly. Uses `WAKE_LATCH` + firmware timer. |
| E13 | **1-Wire master** (DS18B20 temperature) | 1 | Timing-sensitive slow protocol. Good teaching example of weak/strong pull-up using `pad_oe`. |
| E14 | **Simple logic analyzer** (2-pin, timestamped) | 2 | Captures pad edges to mailbox with `clk_iop` timestamps. Useful for debugging the other examples. |

---

## What gets built first (recommendation)

**MVP set = E1 UART + E2 SPI + E3 I²C + E4 WS2812.**

Reason: those four cover the entire design-space the macro is meant for.
If all four work under the resource budget and hit their timing, the
architecture is validated. Tier 2/3 become straightforward variations.

---

## Phased implementation plan

Each phase ends with an approval gate. Nothing from phase N+1 starts
until phase N is reviewed and signed off.

### Phase 0 — Firmware infrastructure (prerequisite) ✅ DONE

Landed the missing `sw/` scaffolding.

**Delivered:**
- `sw/link.ld` — 512 B SRAM A code/data/stack + 256 B mailbox + 256 B MMIO.
- `sw/crt0.S` — `_start` trampoline at 0x000, `__trap_entry` at 0x010, `_init` clears `.bss` and calls `main`, weak `__isr`.
- `sw/attoio.h` — MMIO map matching `docs/spec.md` §8.1 + inline helpers (`gpio_set`, `doorbell_*`, `wait_cycles`).
- `sw/Makefile` — `make FW=<name>` builds `.elf` / `.bin` / `.hex`. Uses `riscv64-unknown-elf-gcc -march=rv32ec_zicsr -mabi=ilp32e -Os -ffreestanding -nostdlib`.
- `sw/common/{mailbox,timing}.{c,h}` — shared helpers.
- `sw/empty/main.c` — the smoke-test firmware (just `while(1) wfi();`).

**New testbench:** `sim/tb_fw_boot.v` + `sim/run_fw_boot.sh` — loads the compiled hex via `$readmemh`, releases reset, verifies the core reaches a steady PC (WFI) past the reset trampoline.

**Acceptance hit:** Empty firmware compiles to **90 B** (well under the 512 B budget), loads correctly, boots, reaches `wfi` at PC=0x060 within 42 `clk_iop` cycles. ✅

### Phase 1 — E1 UART

**RTL impact:** none.

**Firmware:**
- Pin mapping (configurable at build time): TXD = pad[0], RXD = pad[1].
- TX: busy-wait bit-banger. 8-N-1. Baud selectable at 9600 / 115200.
- RX: `WAKE_LATCH` on falling edge of RXD → trap → sample midpoints of 8 bits → push byte into a 32-B ring buffer in SRAM B → set `DOORBELL_C2H`.
- Host sees bytes via mailbox and can send bytes back (host writes tail index + byte → firmware polls → TX).

**Verification:**
- New testbench `sim/tb_uart.v`: drives RXD from a reference UART model, checks TXD against the same. Host side reads bytes through host bus and verifies them match.
- Bidirectional echo test: host writes "ABCD" → firmware UART-TX → testbench UART model receives → feeds back to RXD → firmware RX → host reads "ABCD".

**Acceptance:**
- Testbench passes at both 9600 and 115200.
- Code size < 400 B.

### Phase 2 — E2 SPI master

**RTL impact:** none (SPI shift helper already present).

**Firmware:**
- Thin wrapper around `SPI_DATA`/`SPI_CFG`/`SPI_STATUS` registers.
- API: `spi_begin(mode, cs)`, `spi_xfer(byte)`, `spi_end()`.
- Mailbox protocol: host writes a command descriptor (CS pin, mode, tx-byte-count, rx-byte-count, tx bytes…), firmware executes, writes rx bytes back, rings doorbell.

**Verification:**
- `sim/tb_spi.v`: a minimal SPI-slave model (shift register loopback). Firmware runs a 16-byte exchange; testbench checks mode timing and byte integrity for all 4 CPOL/CPHA combos.

**Acceptance:**
- Loopback passes for all modes.
- Byte rate ≥ 1.5 MB/s at `clk_iop` = 30 MHz.

### Phase 3 — E3 I²C master

**RTL impact:** none. Relies on open-drain (host sets `pad_oe[SDA/SCL]` = 1
when driving low, = 0 to release — external pull-ups).

**Firmware:**
- Bit-bang master at 100 kHz and 400 kHz.
- API: `i2c_start`, `i2c_stop`, `i2c_write_byte` (returns ACK), `i2c_read_byte(ack)`.
- Mailbox protocol: descriptor-driven multi-byte transactions.

**Verification:**
- `sim/tb_i2c.v`: 24C02 EEPROM model (page write, random read).
- Firmware writes 16 bytes, then reads them back.
- Host checks both the bus waveform (START/ACK/STOP positions via timestamps) and the returned data.

**Acceptance:**
- EEPROM round-trip matches at 100 kHz and 400 kHz.
- Bus timing meets I²C spec (`tSU`, `tHD` limits).

### Phase 4 — E4 WS2812

**RTL impact:** potentially bump the default `pad_ctl[slew]` bit so DIN
has a fast slew. Verify the `pad_ctl` plumbing works end-to-end.

**Firmware:**
- Ultra-tight inner loop: 3 pad writes per bit (high / data / low) at
  precise `clk_iop` counts. At 30 MHz: ~10 cycles for T0H, ~21 for T1H,
  ~25 for T0L, ~15 for T1L. Pure asm required.
- API: `ws2812_push(*rgb_buffer, n)`.

**Verification:**
- `sim/tb_ws2812.v`: sampler monitoring DIN, asserts edges fall within WS2812 spec windows. 8 LEDs × 3 bytes = 24 bytes of patterns, verified.

**Acceptance:**
- All 24 bytes transmitted with edge timing inside ±150 ns of nominal.
- Works while running from a firmware image that also responds to the
  host (proves the "foreground loop + mailbox polling" pattern).

### Phase 5 — Display-controller family (E5 / E6 / E7)

Three small, segment/character-only display examples:

**Phase 5a — E5 HD44780** *(parallel, slow)*
- Firmware pushes nibble-pairs on D4–D7, with RS latching char/cmd and E rising-edge strobing the write. Busy waits between writes (cheap alternative: fixed-delay waits derived from `clk_iop`).
- Host protocol: mailbox holds a 32-byte write-through text buffer; host writes ASCII, firmware pushes diffs on cursor-position commands.
- `sim/tb_hd44780.v`: monitors RS/E and reconstructs each byte; asserts host-supplied string appears in the virtual DDRAM.

**Phase 5b — E6 TM1637** *(2-wire custom serial)*
- Firmware implements: START (DIO↓ while CLK high), 8 bits LSB-first with clock toggles, ACK sample, STOP.
- Commands: 0x40 data-cmd, 0xC0..C5 address, 0x88|brightness display-ctrl.
- Host API: write 4 digits (or raw 7-seg patterns) + brightness into the mailbox; firmware reshapes and sends.
- `sim/tb_tm1637.v`: shift-register decoder + 4-digit model.

**Phase 5c — E7 HT1621** *(3-wire proprietary)*
- Firmware sends 9-bit command frames (1000b-prefix + 8-bit code) and 3-bit "101" + 6-bit address + 4-bit data write frames, all MSB-first clocked on WR rising edge with CS low.
- Supports multi-address burst writes (HT1621 auto-increments address).
- Host API: write a 32-byte segment image into the mailbox; firmware burst-writes the whole display RAM.
- `sim/tb_ht1621.v`: shift-register + 32×4-bit RAM mirror; host-side check asserts firmware wrote the expected segment pattern.

### Phase 6 — Consolidation

- Refactor shared helpers into `sw/common/` (`mailbox.c`, `timing.c`).
- Add `sw/examples/README.md` summarizing which pins each example uses
  and the host→IOP mailbox protocol for each.
- Release v0.2.

### Phase 7 — Remaining Tier 2 (E8 / E9 / E10, optional)

Matrix keypad, quadrature encoder, 4-channel PWM. Each ≤1 day once the
infra and display examples exist.

### Phase 8 — Tier 3 (optional, advanced)

Revisit the macro spec if `clk_iop` needs to rise for E11 (I²C slave)
and E12 (IR decoder).

---

## Open questions

1. **Toolchain** — which riscv32 GCC (homebrew's `riscv64-unknown-elf-gcc` + `-march=rv32ec`, or a dedicated `riscv32-unknown-elf` build)? Please confirm which you have installed; I'll adapt the Makefile.
2. **Pin assignment** — propose a default: pad[0..1] = UART, pad[2..5] = SPI, pad[6..7] = I²C, pad[8] = WS2812, pad[9..15] = user GPIO. Override per example. OK?
3. **Testbench style** — keep hand-assembled imageless testbenches (like `tb_attoio.v`), or always compile a real `.hex` via the Makefile and `$readmemh`? The latter is cleaner but requires the toolchain on every CI machine. I recommend the latter.
4. **Example ordering** — accept the proposed Tier-1 set (UART → SPI → I²C → WS2812), or reshuffle?

Pending sign-off on this plan, I'll start with **Phase 0 (infra)**.
