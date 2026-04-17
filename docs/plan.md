# AttoIO — Implementation Plan

This plan builds the AttoIO macro in phases with **approval gates**
between them.

---

## Phase 1 — RTL: memory system

**Goal:** three-DFFRAM-macro memory system with SRAM A reset/run mux,
SRAM B0/B1 host-priority arbiter, and address decoder.

**Deliverables:**
- `rtl/attoio_memmux.v` — address decode, SRAM A port mux, SRAM B
  arbiter with B0/B1 sub-bank select, read-data mux, `mem_rbusy` /
  `mem_wbusy` generation.
- `sim/tb_memmux.v` — directed tests:
  - Host loads SRAM A while IOP in reset.
  - IOP fetches from SRAM A after reset deassert (host locked out).
  - IOP reads/writes SRAM B0 and SRAM B1.
  - Simultaneous host + IOP on SRAM B (host wins, IOP stalls).
  - IOP on SRAM A while host on SRAM B (concurrent, no stall).

**Verification:** iverilog + vvp, using DFFRAM behavioral model.

**Approval gate:** arbitration waveforms reviewed.

---

## Phase 2 — RTL: GPIO, PADCTL, and WAKE_LATCH

**Goal:** MMIO GPIO registers, SET/CLR aliases, PADCTL, input
synchronizers (on `sysclk`), and WAKE_LATCH edge detector.

**Deliverables:**
- `rtl/attoio_gpio.v` — GPIO_IN/OUT/OE, SET/CLR aliases, PADCTL[0..15],
  2-flop synchronizers (on `sysclk`), WAKE_LATCH (edge detect on
  `sysclk`, R/W1C from IOP on `clk_iop`).
- Pad-side ports: `pad_out[15:0]`, `pad_oe[15:0]`, `pad_in[15:0]`,
  `pad_ctl[127:0]`.
- `sim/tb_gpio.v` — write/readback, SET/CLR, PADCTL, synchronizer
  propagation, WAKE_LATCH set on async edge + clear by IOP.

**Verification:** tb_gpio passes.

**Approval gate:** register decode, pad bundle, and WAKE_LATCH behavior
reviewed.

---

## Phase 3 — RTL: doorbells, IOP_CTRL, IRQ

**Goal:** host ↔ IOP signaling glue and control register.

**Deliverables:**
- `rtl/attoio_ctrl.v` — DOORBELL_H2C (W1S host, R/W1C IOP),
  DOORBELL_C2H (RW IOP, R/W1C host), IOP_CTRL (reset + NMI).
  IRQ routing: `interrupt_request = H2C | WAKE_LATCH`.
  NMI: self-clearing pulse from `IOP_CTRL.nmi`.
  `irq_to_host` output from C2H.
- `sim/tb_ctrl.v` — H2C set/clear/IRQ, C2H set/clear, NMI pulse,
  reset hold/release.

**Verification:** tb_ctrl passes.

**Approval gate:** IRQ timing and clearing semantics reviewed.

---

## Phase 4 — RTL: SPI shift helper

**Goal:** byte-oriented SPI master shift engine in the MMIO page.

**Deliverables:**
- `rtl/attoio_spi.v` — TX/RX shift registers, auto-clock-toggle,
  pin override logic, SPI_DATA / SPI_CFG / SPI_STATUS registers.
  Clocked by `clk_iop`.
- `sim/tb_spi.v` — load byte, verify SCK toggling + MOSI bit stream +
  MISO capture. Test CPOL/CPHA modes. Verify GPIO_OUT override during
  shift and revert after idle.

**Verification:** tb_spi passes; waveform shows correct SPI mode 0/1/2/3.

**Approval gate:** SPI pin override logic and timing reviewed.

---

## Phase 5 — RTL: macro top-level

**Goal:** `attoio_macro.v` — the single hard macro.

**Deliverables:**
- `rtl/attoio_macro.v` — instantiates AttoRV32 core + 3 DFFRAM macros +
  attoio_memmux + attoio_gpio + attoio_ctrl + attoio_spi.
- External ports per `spec.md` §3.2 (261 signals).
- Dual-clock wiring per `spec.md` §11.2.
- `sim/tb_macro_lint.v` — elaboration-only testbench (checks no
  unconnected nets, no width mismatches).

**Verification:** elaboration clean on iverilog; lint clean.

**Approval gate:** port list and clock domain wiring reviewed.

---

## Phase 6 — Firmware infrastructure

**Goal:** minimal toolchain to build IOP firmware.

**Deliverables:**
- `sw/link.ld` — `.text`/`.rodata` in SRAM A, `.data`/`.bss`/stack in
  upper SRAM A. Mailbox by absolute address.
- `sw/crt0.S` — reset trampoline, `.bss` zero-fill, jump to `main`.
- `sw/isr.S` + `sw/isr.c` — ISR: check DOORBELL_H2C, WAKE_LATCH,
  dispatch.
- `sw/attoio.h` — all MMIO addresses, inline accessors.
- `sw/Makefile` — builds `.elf` / `.hex` / `.bin`.
- `sw/fw_smoke.c` — writes mailbox pattern, toggles `pad_out[0]`.

**Verification:** `fw_smoke.bin` fits in SRAM A with headroom.

**Approval gate:** firmware layout and header reviewed.

---

## Phase 7 — System testbench + example firmware

**Goal:** end-to-end verification of the complete macro.

**Deliverables:**
- `sim/tb_attoio.v` — host loads firmware via SRAM A during reset,
  releases reset, exchanges mailbox traffic, observes pad toggling.
  Drives `sysclk` and `clk_iop` at configurable ratio.
- `sw/fw_uart.c` — emulated UART TX via bit-bang.
- `sim/tb_attoio_uart.v` — host + UART RX model; byte check.
- `sw/fw_spi_master.c` — SPI master using the shift helper: sends a
  byte, reads back via SPI_DATA.
- `sim/tb_attoio_spi.v` — host + SPI slave model; byte check.

**Verification:** all tbs pass.

**Approval gate:** full review before physical implementation.

---

## Phase 8 — Synthesis and characterization

**Goal:** Sky130A synthesis numbers for the macro.

**Deliverables:**
- `syn/attoio_syn.tcl` — yosys flow.
- `syn/attoio_sta.tcl` — OpenSTA.
- `syn/run_attoio_syn.sh` — sweep driver.
- DFFRAM structural netlists for the three macros.
- `docs/synthesis.md` — cells / flops / area / WNS.

**Verification:** timing closed; area within estimate.

**Approval gate:** final sign-off.

---

## Out of scope

- Debug UART / GDB stub / hardware breakpoints.
- Multiple IOP instances.
- Place-and-route, GDS, DRC/LVS.
- Bus protocol wrappers (AHB-Lite, APB, Wishbone).
- Clock divider (external to macro).

---

## Directory layout at completion

```
attoio/
├── README.md
├── docs/
│   ├── spec.md
│   ├── plan.md
│   └── synthesis.md             (Phase 8)
├── rtl/
│   ├── attoio_macro.v           (top-level hard macro)
│   ├── attoio_memmux.v
│   ├── attoio_gpio.v
│   ├── attoio_ctrl.v
│   └── attoio_spi.v
├── sim/
│   ├── tb_memmux.v
│   ├── tb_gpio.v
│   ├── tb_ctrl.v
│   ├── tb_spi.v
│   ├── tb_macro_lint.v
│   ├── tb_attoio.v
│   ├── tb_attoio_uart.v
│   ├── tb_attoio_spi.v
│   └── run_*.sh
├── sw/
│   ├── Makefile
│   ├── link.ld
│   ├── crt0.S
│   ├── isr.c
│   ├── attoio.h
│   ├── fw_smoke.c
│   ├── fw_uart.c
│   └── fw_spi_master.c
└── syn/
    ├── attoio_syn.tcl
    ├── attoio_sta.tcl
    └── run_attoio_syn.sh
```

Dependencies:
- **AttoRV32** core RTL — vendored or submoduled from `frv32`.
- **DFFRAM** behavioral model + structural netlists from
  `sky130_gen_dffram`.
