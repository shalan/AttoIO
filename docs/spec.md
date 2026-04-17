# AttoIO — I/O Processor Subsystem Specification

## 1. Purpose

AttoIO is a tiny I/O processor (IOP) built around the **AttoRV32** core,
delivered as a single hard macro intended to be embedded inside a larger
SoC. The host CPU loads firmware into AttoIO's local RAM and releases it
from reset; the IOP then runs small programs that emulate peripherals
(UART, I²C slave, SPI slave, GPIO expander, sensor decoders, …) and/or
perform basic local processing on behalf of the host, exchanging data
with the host through a shared mailbox.

Firmware is host-loadable, so a single hardened AttoIO instance can take
on a different "personality" per application without re-taping-out.

## 2. Design principles

- **MMIO is only for real hardware registers.** A bit belongs in MMIO if
  and only if it physically drives a pin, samples a pin, or captures an
  asynchronous event the CPU cannot poll fast enough. Everything else
  (masks, counters, FIFOs, mode flags, byte parsers) lives in RAM.
- **Host always wins the bus.** The IOP is a helper, never a bottleneck
  for the host.
- **Separate mailbox SRAM for concurrent access.** The mailbox is the only
  memory contested between host and IOP. Putting it in its own physical
  SRAM confines arbitration to that one bank, while the IOP's private
  SRAM (code + data + stack) is never stalled by the host.
- **Core is unmodified.** All IOP-specific logic lives around the core,
  never inside it. The existing `mem_rbusy` / `mem_wbusy` handshake is
  enough to stall the core cleanly when the host holds the mailbox.
- **Single macro.** CPU, RAM, GPIO, arbitration, doorbells, and SPI shift
  helper are all inside one hard macro with a clean pin interface.

## 3. Macro boundary

### 3.1 Block diagram

```
┌───────────────────────── attoio_macro ──────────────────────────┐
│                                                                 │
│  ┌──────────────┐                                               │
│  │              │──── SRAM A (128×32 DFFRAM, 512 B) ─────────  │
│  │  AttoRV32    │         private (code + data + stack)         │
│  │  (RV32EC)    │                                               │
│  │              │──── SRAM B0 (32×32 DFFRAM, 128 B) ┐          │
│  │  ADDR_WIDTH  │                                    ├─ ARB ───┤── host bus
│  │  = 10        │──── SRAM B1 (32×32 DFFRAM, 128 B) ┘          │
│  │              │         mailbox (256 B combined)              │
│  │              │                                               │
│  │              │──── MMIO page ────────────────────────────── │
│  │              │     GPIO, PADCTL, doorbells, SPI shifter     │
│  │              │                                               │
│  │ interrupt_rq │◄── DOORBELL_H2C | WAKE_LATCH                 │
│  │ nmi          │◄── IOP_CTRL.nmi                              │
│  │ reset        │◄── IOP_CTRL.reset                            │
│  │ dbg_halt_req │◄── 1'b0                                      │
│  └──────────────┘                                               │
│        clk = clk_iop                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 External pin interface

| Group | Signal | Dir | Width | Description |
|---|---|---|---:|---|
| **Clock** | `sysclk` | in | 1 | System clock — SRAM B, arbiter, doorbells, input sync, wake latch |
| | `clk_iop` | in | 1 | IOP clock (`sysclk / N`, generated externally) — core, SRAM A, GPIO/PADCTL regs, SPI shifter |
| **Reset** | `rst_n` | in | 1 | Active-low, synchronous to `sysclk` |
| **Host bus** | `host_addr[9:0]` | in | 10 | Address within AttoIO space |
| | `host_wdata[31:0]` | in | 32 | Write data |
| | `host_rdata[31:0]` | out | 32 | Read data |
| | `host_wen` | in | 1 | Write strobe |
| | `host_ren` | in | 1 | Read strobe |
| | `host_wmask[3:0]` | in | 4 | Per-byte write enable |
| | `host_ready` | out | 1 | Access complete (single-cycle for regs, may wait for SRAM B arbitration) |
| **Pads** | `pad_in[15:0]` | in | 16 | Pad inputs (async; synchronized inside the macro) |
| | `pad_out[15:0]` | out | 16 | Pad outputs |
| | `pad_oe[15:0]` | out | 16 | Pad output enables (1 = drive) |
| | `pad_ctl[127:0]` | out | 128 | Per-pad 8-bit extended control (`pad_ctl[i*8 +: 8]` → pad `i`) |
| **IRQ** | `irq_to_host` | out | 1 | From DOORBELL_C2H — active high |
| | | | **261** | total signal pins (+ VDD / VSS) |

### 3.3 What is inside the macro

- AttoRV32 core (RV32EC, `NRV_SINGLE_PORT_REGF`, `NRV_SHARED_ADDER`,
  `NRV_SERIAL_SHIFT`, no M, no perf CSRs, no debug)
- 3 DFFRAM macros (1× 128×32, 2× 32×32)
- Memory mux + address decoder
- SRAM A port mux (reset/run)
- SRAM B host-priority arbiter
- GPIO registers (OUT, OE, SET/CLR aliases)
- 16× 2-flop input synchronizers (on `sysclk`)
- WAKE_LATCH (edge detect on `sysclk`)
- PADCTL registers (16 × 8 b)
- SPI shift helper (TX/RX shift registers + auto-clock)
- Doorbells (H2C, C2H)
- IOP_CTRL register

## 4. Physical memory

Total SRAM: **768 bytes** in three
[DFFRAM](https://github.com/shalan/sky130_gen_dffram) macros.

| Macro | DFFRAM config | Size | Module | Contents |
|---|---|---:|---|---|
| **SRAM A** | 128×32 | 512 B | `DFFRAM #(.WORDS(128), .WSIZE(4))` | Code, data, stack (IOP-private) |
| **SRAM B0** | 32×32 | 128 B | `DFFRAM #(.WORDS(32), .WSIZE(4))` | Mailbox low half (`0x200–0x27F`) |
| **SRAM B1** | 32×32 | 128 B | `DFFRAM #(.WORDS(32), .WSIZE(4))` | Mailbox high half (`0x280–0x2FF`) |

All three are single-port, single-clock. SRAM B0 and B1 together form a
contiguous 256 B mailbox; the two-macro split is invisible to firmware.

### 4.1 DFFRAM port interface

```verilog
DFFRAM #(.WORDS(N), .WSIZE(4)) u_sram (
    .CLK  (clk),          // positive-edge clock
    .WE0  (we),           // [3:0]  per-byte write enable
    .EN0  (en),           // chip select (Do0 holds when 0)
    .A0   (addr),         // [$clog2(N)-1:0] word address
    .Di0  (wdata),        // [31:0] write data
    .Do0  (rdata)         // [31:0] read data (1-cycle latency)
);
```

Port mapping to AttoRV32 core signals:

| DFFRAM | AttoRV32 | Notes |
|---|---|---|
| `WE0[3:0]` | `mem_wmask[3:0]` | Identical semantics — per-byte enable |
| `Di0[31:0]` | `mem_wdata[31:0]` | Direct wire |
| `Do0[31:0]` | `mem_rdata[31:0]` | Through read-data mux |
| `A0` | `mem_addr` bits | Word address (strip `mem_addr[1:0]`) |
| `EN0` | derived | `mem_rstrb \| (\|mem_wmask)` |

Read latency is 1 cycle; `Do0` holds its value when `EN0 = 0`.

### 4.2 Why two macros for the mailbox

DFFRAM does not support 64-word configurations. Supported word counts are
32, 128, 256, 512, 1024, 2048. Two 32×32 macros compose a 256 B mailbox
using only standard DFFRAM sizes.

### 4.3 Why separate SRAMs for private and mailbox

The AttoRV32 core serializes instruction fetch and data access in its
state machine — it never does both in the same cycle. Therefore splitting
code and data into separate physical banks gains nothing. The only reason
to have separate physical SRAMs is to allow two masters (host and IOP)
to access concurrently. That situation exists only for the mailbox.

## 5. Memory map (IOP view)

Total address space: 1 KiB (`ADDR_WIDTH = 10`).

| Range | Size | Maps to | Notes |
|---|---:|---|---|
| `0x000 – 0x1FF` | 512 B | SRAM A (private) | Reset vector at `0x000`, ISR at `MTVEC_ADDR = 0x010` |
| `0x200 – 0x27F` | 128 B | SRAM B0 (mailbox low) | ┐ contiguous 256 B mailbox |
| `0x280 – 0x2FF` | 128 B | SRAM B1 (mailbox high) | ┘ shared with host |
| `0x300 – 0x3FF` | 256 B | MMIO page | GPIO, PADCTL, doorbells, SPI shifter — IOP-only |

### 5.1 Address decode

```
mem_addr[9]   = 0  →  SRAM A           A0 = mem_addr[8:2]  (7-bit, 128 words)
mem_addr[9:8] = 10 →  SRAM B0 / B1
                       mem_addr[7] = 0  →  SRAM B0   A0 = mem_addr[6:2]  (5-bit, 32 words)
                       mem_addr[7] = 1  →  SRAM B1   A0 = mem_addr[6:2]  (5-bit, 32 words)
mem_addr[9:8] = 11 →  MMIO page        decoded by mem_addr[7:2]
```

### 5.2 SRAM A layout (IOP-private, 512 B)

```
0x000           .reset      reset trampoline (≤ 16 B)
0x010           .isr        ISR entry (MTVEC_ADDR = 0x10)
0x014 ...       .text       program code
 ...            .rodata     constants (immediately after .text)
 ...            .data       initialized data
 ...            .bss        zero-initialized data
 ...
0x1FF           stack top   stack grows down
```

**Code budget:** after the reset trampoline (~16 B), ISR entry (~32 B),
and reserving ~80 B for `.data`/`.bss` and ~80 B for stack, roughly
**~300–350 B of `.text`** remains (≈150–175 RV32C instructions). This
comfortably fits a single peripheral emulator (UART / I²C slave / GPIO
expander / SPI slave).

### 5.3 SRAM B layout (mailbox, 256 B)

Layout is a software contract between host firmware and IOP firmware. No
hardware enforcement. The B0/B1 macro boundary at `0x280` is invisible
to software. A typical convention:

```
0x200 – 0x21F  command / request block     (host → IOP)
0x220 – 0x23F  response / status block     (IOP → host)
0x240 – 0x2FF  bulk data buffer            (bidirectional)
```

## 6. Memory map (host view)

Host sees AttoIO as a single peripheral block. Host-side layout
(offsets within the block's base address):

| Offset | Size | Contents | Access |
|---|---:|---|---|
| `0x000 – 0x1FF` | 512 B | SRAM A (private) | RW only while `IOP_CTRL.reset = 1` |
| `0x200 – 0x2FF` | 256 B | SRAM B0 + B1 (mailbox) | RW always (arbitrated) |
| `0x300` | 4 B | `DOORBELL_H2C` | W1S (host sets, IOP clears) |
| `0x304` | 4 B | `DOORBELL_C2H` | R / W1C (IOP sets, host clears) |
| `0x308` | 4 B | `IOP_CTRL` | RW (host-only control register) |

The IOP's MMIO page (GPIO, PADCTL, SPI shifter) is **not** visible to
the host. Pad control is entirely the IOP's domain.

### 6.1 SRAM A host access gating

While `IOP_CTRL.reset = 1`, the SRAM A port is muxed to the host bus
(the IOP is not running, so no contention). When `IOP_CTRL.reset = 0`,
SRAM A is exclusively owned by the IOP — host accesses to `0x000–0x1FF`
are ignored (or return zero).

This eliminates all arbitration logic on SRAM A. A 2:1 port mux selected
by the reset bit is the only hardware cost (~40 cells).

If the host needs to inspect SRAM A contents after boot (debug), it
re-asserts `IOP_CTRL.reset`, reads, and re-releases.

## 7. Bus arbitration

### 7.1 SRAM A — no arbiter

During reset: host owns the port (mux selects host).
After reset: IOP owns the port (mux selects core).
No arbitration, no stalls on SRAM A, ever.

### 7.2 SRAM B0 / B1 — host-priority arbiter

Both mailbox macros share a single arbiter — the address decode selects
which macro's `EN0` fires, but the grant decision is the same for both:

```
host_req & core_req  → host wins
                        grant → host
                        core sees mem_rbusy=1 (or mem_wbusy=1)
host_req only        → grant → host
core_req only        → grant → core
idle                 → idle
```

On a host-granted cycle, the host address bit `[7]` selects B0 or B1
and the host's `A0[4:0]` / `WE0` / `Di0` are routed to the selected
macro. On a core-granted cycle, the core's signals are routed instead.

The core stalls via `mem_rbusy` / `mem_wbusy` only when it is actively
accessing the mailbox AND the host accesses it in the same cycle.

### 7.3 MMIO page

Single-master (IOP only). No arbitration.

### 7.4 Core RTL impact

Zero. The existing `mem_rbusy` / `mem_wbusy` handshake is used as
designed. All arbitration and muxing is external to the core.

## 8. GPIO and pad interface

16 I/O pads. Each pad exposes:

| Signal | Direction | Width | Description |
|---|---|---:|---|
| `pad_out[i]` | IOP → pad | 1 | Output data |
| `pad_oe[i]` | IOP → pad | 1 | Output enable (1 = drive) |
| `pad_in[i]` | pad → IOP | 1 | Input (async, 2-flop synchronized) |
| `pad_ctl[i]` | IOP → pad | 8 | Extended control (drive strength, pull, slew, schmitt, …) |

### 8.1 MMIO register map (IOP view, offsets within `0x300` page)

```
GPIO — hot path (bit-parallel)
  0x300  GPIO_IN       RO   [15:0]   live synchronized pad inputs
  0x304  GPIO_OUT      RW   [15:0]   output data
  0x308  GPIO_OE       RW   [15:0]   output enable

GPIO — atomic set/clear aliases (same flops as OUT / OE)
  0x30C  GPIO_OUT_SET  W1S  [15:0]   bits written 1 set GPIO_OUT bits
  0x310  GPIO_OUT_CLR  W1C  [15:0]   bits written 1 clear GPIO_OUT bits
  0x314  GPIO_OE_SET   W1S  [15:0]
  0x318  GPIO_OE_CLR   W1C  [15:0]

PADCTL — per-pad extended control
  0x320  PADCTL[0]     RW   [7:0]
  0x324  PADCTL[1]     RW   [7:0]
   ...
  0x35C  PADCTL[15]    RW   [7:0]

Wake (per-pin)
  0x360  WAKE_LATCH    RO   [0]      combined = |(WAKE_FLAGS & WAKE_MASK).
                                      Any write W1C-clears ALL flags (legacy).
  0x364  WAKE_FLAGS    R/W1C [15:0]  per-pin sticky edge flag
  0x368  WAKE_MASK     RW   [15:0]   per-pin enable (1 = contributes to
                                      WAKE_LATCH and the IRQ OR)
  0x36C  WAKE_EDGE     RW   [31:0]   2 bits per pad: 00=off, 01=rise,
                                      10=fall, 11=both edges

Doorbells
  0x380  DOORBELL_H2C  R/W1C [0]     host → IOP doorbell
  0x384  DOORBELL_C2H  RW    [0]     IOP → host doorbell

SPI shift helper
  0x390  SPI_DATA      RW   [7:0]    write = load TX + start; read = RX shift reg
  0x394  SPI_CFG       RW   [7:0]    pin select + CPOL/CPHA (see §10)
  0x398  SPI_STATUS    RO   [0]      bit 0 = busy

TIMER — 24-bit counter + 4 compares + 1 capture (see §11)
  0x3A0  TIMER_CNT     RO    [23:0]   current count
  0x3A4  TIMER_CTL     RW    see §11  enable / reset / auto-reload /
                                       capture pad+edge / capture IRQ en
  0x3A8  TIMER_STATUS  R/W1C [4:0]    match0..3 flags + capture flag
  0x3AC  TIMER_CAP     RO    [23:0]   snapshot of CNT on selected pad edge
  0x3B0  TIMER_CMP0    RW    see §11  compare + pad index + en / IRQ / toggle
  0x3B4  TIMER_CMP1    RW
  0x3B8  TIMER_CMP2    RW
  0x3BC  TIMER_CMP3    RW
```

### 8.2 No pin-change interrupt registers

`GPIO_IEN`, `GPIO_IES`, `GPIO_ISTS` (per-pin interrupt mask, edge
select, and latched-edge status) are **deliberately absent**. They are
software state by the design principle in §2.

Edge detection, when needed, is done in firmware:

```c
uint16_t new_in   = GPIO_IN;
uint16_t edges    = new_in ^ last_in;   // last_in lives in SRAM A
uint16_t rising   = edges &  new_in;
uint16_t falling  = edges & ~new_in;
last_in = new_in;
```

### 8.3 Input synchronizer

2-flop synchronizer on every `pad_in[i]`, clocked by **`sysclk`** (not
`clk_iop`). This ensures no edge is metastability-trapped and that edges
happening between IOP ticks are visible at the next IOP read.

### 8.4 Wake system (per-pin edge detection)

Per-pin sticky edge flags with individual mask and edge-mode selection.
Replaces the old single-bit `WAKE_LATCH` without breaking firmware that
only uses the combined bit.

```
WAKE_FLAGS[15:0]   sticky, R/W1C — each bit p is set the cycle the
                   configured edge on pad_in[p] is detected, cleared by
                   writing 1 to that bit
WAKE_MASK[15:0]    RW — only pins with mask[p] = 1 contribute to the
                   combined wake / IRQ
WAKE_EDGE[31:0]    RW — 2 bits per pad (bits [2p+1:2p]):
                         00 = off      01 = rising
                         10 = falling  11 = both edges
WAKE_LATCH[0]      RO — reads as |(WAKE_FLAGS & WAKE_MASK);
                   writing any value clears all flags (legacy).
```

Firmware ISR pattern:

```c
void __isr(void) {
    uint32_t f = WAKE_FLAGS & WAKE_MASK;   // pins that fired
    if (f & (1u << 5)) { /* handle pad[5] edge */ }
    if (f & (1u << 9)) { /* handle pad[9] edge */ }
    WAKE_FLAGS = f;                        // W1C
}
```

Edge detection runs on `sysclk` (from the 2-flop synchronized inputs);
firmware configuration (mask, edge mode) is written from `clk_iop` but
is stable on every `sysclk` edge because `clk_iop` edges are a subset of
`sysclk` edges — no CDC flops needed.

### 8.4.1 Legacy WAKE_LATCH

A single flop, clocked by `sysclk`, that latches any edge on any of the
16 synchronized `pad_in` signals. The edge detector compares consecutive
synchronizer outputs and OR-reduces across all 16 pins.

```verilog
// on sysclk
wire [15:0] edge_any = pad_in_sync ^ pad_in_sync_prev;
wire        wake_set = |edge_any;
// WAKE_LATCH: set by wake_set, cleared by IOP W1C
```

Contributes to `interrupt_request`:
```verilog
assign interrupt_request = DOORBELL_H2C | WAKE_LATCH;
```

Firmware reads `WAKE_LATCH` in the ISR; if set, reads `GPIO_IN` and
compares to `last_in` (in RAM) to determine which pin(s) changed.
Firmware W1C-clears `WAKE_LATCH` after handling.

### 8.5 `PADCTL` reset defaults

TBD — per-pad 8-bit reset value should come from the padframe vendor's
recommended safe state. Typical default: input, pull-up, low drive.

## 9. Interrupts

### 9.1 Core interrupt connections

```verilog
assign core.interrupt_request = DOORBELL_H2C | WAKE_LATCH;
assign core.nmi               = iop_ctrl_nmi;   // from IOP_CTRL, self-clearing
assign core.dbg_halt_req      = 1'b0;            // unused
```

Both `DOORBELL_H2C` and `WAKE_LATCH` are flops that hold the level until
firmware W1C-clears them, matching the core's non-sticky level-sensitive
requirement.

### 9.2 Firmware-maskable by design

Bit-banged protocols require predictable cycle timing. Firmware masks
IRQs during timing-critical sections:

```c
__asm__ volatile("csrci mstatus, 8");   // MIE = 0
bit_bang_critical_section();
__asm__ volatile("csrsi mstatus, 8");   // MIE = 1 — pending IRQ fires now
```

### 9.3 NMI

Reserved for host watchdog / abort. Not used for normal commands.

### 9.4 IRQ to host

`irq_to_host` output pin directly reflects the `DOORBELL_C2H` flop.
The IOP firmware sets it; the host clears it via W1C on its side of the
doorbell.

## 10. SPI shift helper

A minimal byte-oriented SPI master engine inside the MMIO page, intended
to accelerate SPI bit-banging without replacing general-purpose GPIO.

### 10.1 Registers

| Offset | Name | Access | Width | Description |
|---:|---|---|---|---|
| `0x390` | `SPI_DATA` | RW | [7:0] | Write: load TX shift reg, start shifting. Read: RX shift reg contents. |
| `0x394` | `SPI_CFG` | RW | [7:0] | `[3:0]` = SCK pin, `[5:4]` = MOSI pin (2 LSBs), `[6]` = CPOL, `[7]` = CPHA |
| `0x398` | `SPI_STATUS` | RO | [0] | Bit 0 = busy (1 while shifting) |

### 10.2 Operation

1. Firmware writes `SPI_CFG` once at init to select which GPIO pins
   serve as SCK, MOSI, and MISO (MISO pin = MOSI pin + 1 by convention,
   or a separate config field if needed).
2. Firmware writes a byte to `SPI_DATA`. This loads the TX shift register
   and starts the shift engine.
3. The engine shifts MSB-first onto the MOSI pin, one bit per `clk_iop`
   cycle, auto-toggling the SCK pin. Simultaneously captures MISO into
   the RX shift register on the opposite SCK edge.
4. After 8 bits (16 `clk_iop` edges for the clock toggle), `SPI_STATUS.busy`
   clears. Firmware reads `SPI_DATA` to get the received byte.

**Throughput:** 8 bits in 16 `clk_iop` cycles. At `clk_iop` = 25 MHz →
~1.5 Mbps. Software bit-bang would be ~150 kbps. ~10× speedup.

### 10.3 Interaction with GPIO

While the shift engine is busy, it **overrides** `GPIO_OUT` for the SCK
and MOSI pins only. All other pins remain under normal GPIO control.
When idle, the pins revert to whatever `GPIO_OUT` / `GPIO_OE` say.
`GPIO_OE` for SCK and MOSI must be set to output by firmware before
starting a transfer.

CS management is firmware's responsibility via normal `GPIO_OUT_CLR` /
`GPIO_OUT_SET`.

### 10.4 Resource cost

~80 cells, ~20 flops (two 8-bit shift registers + 4-bit counter + control).

## 10A. TIMER block

A minimal 24-bit timer with four compare channels and one input-capture
channel, clocked by `clk_iop`. Unlocks hardware-assisted PWM (motors,
LEDs, audio carriers), precise bit-time generation (UART, I²C, WS2812),
and edge-timestamping (IR decoder, ultrasonic, quadrature).

### 10A.1 Registers

| Offset | Name | Access | Layout |
|---:|---|---|---|
| `0x3A0` | `TIMER_CNT` | RO | `[23:0]` current count |
| `0x3A4` | `TIMER_CTL` | RW | `[0]` enable, `[1]` write-1 reset, `[2]` auto-reload (CNT←0 on CMP0 match), `[6:3]` capture pad idx, `[8:7]` capture edge (00=off, 01=rise, 10=fall, 11=both), `[9]` capture IRQ enable |
| `0x3A8` | `TIMER_STATUS` | R/W1C | `[0..3]` CMP0..3 match flags, `[4]` capture flag |
| `0x3AC` | `TIMER_CAP` | RO | `[23:0]` CNT snapshot at last capture event |
| `0x3B0` | `TIMER_CMP0` | RW | `[23:0]` match value, `[27:24]` pad idx, `[28]` enable, `[29]` IRQ enable, `[30]` toggle pad on match |
| `0x3B4` | `TIMER_CMP1` | RW | same layout |
| `0x3B8` | `TIMER_CMP2` | RW | same layout |
| `0x3BC` | `TIMER_CMP3` | RW | same layout |

### 10A.2 Operation

- Free-running 24-bit counter clocked by `clk_iop`, incrementing when
  `TIMER_CTL.enable = 1`. At 30 MHz, full wrap ≈ 0.56 s; plenty for any
  single-frame IR / audio / motor cadence.
- Writing `TIMER_CTL[1] = 1` clears `CNT` on the same edge.
- **Auto-reload mode** (`TIMER_CTL[2]`) resets `CNT` to 0 the cycle CMP0
  matches, giving a periodic carrier.
- Each CMP channel with `enable = 1`:
  - raises its match flag on `CNT == value` (sticky, R/W1C);
  - if `IRQ enable` is set, contributes to `timer_irq`;
  - if `toggle pad` is set, XORs the selected pad's output flop on
    every match. The pad's `pad_oe` is forced high while the channel is
    enabled so the toggle reaches the external pin.
- **Input capture**: on the selected pad's selected edge, `CNT` is
  sampled into `TIMER_CAP` and the capture flag fires. Edge detection
  uses the `clk_iop`-synchronized pad input.

### 10A.3 IRQ routing

`timer_irq` = OR of `(match_flag_i & IRQ_enable_i)` for i in 0..3,
plus `(capture_flag & capture IRQ enable)`.

The macro's `iop_irq` into the core is now
`DOORBELL_H2C | WAKE_LATCH | timer_irq`.

### 10A.4 Reset behavior

The timer is reset on either global `rst_n` **or** `IOP_CTRL.reset = 1`.
This ensures every IOP firmware boot starts with a clean counter, no
enabled channels, and no pad drivers overriding GPIO.

### 10A.5 Example use-cases

| Use | Configuration |
|---|---|
| 38 kHz IR carrier | CMP0 = `clk_iop/(2*38000)` − 1, auto-reload, toggle-pad on CMP0 |
| 4-ch PWM @ 1 kHz, 8-bit duty | CMP0 defines period (reloaded), CMP1/2/3 set duty edges via IRQ ISR |
| UART bit timing | CMP0 = baud-period, auto-reload, IRQ fires bit sample/shift |
| IR RX / HC-SR04 / encoder tachometer | capture channel on the input pin, edge = both |
| Periodic ISR (e.g. motor control) | auto-reload + CMP0 IRQ, no pad toggle |

### 10A.6 Resource cost (estimate)

~250 cells — 24-bit counter + 4×(24-bit comparator + per-channel
control) + 1 capture register + edge-detect on 16-pin bus + pad mux.

## 11. Clocking

### 11.1 Dual-clock architecture

The macro receives two clocks from the system, both generated externally:

- **`sysclk`** — the system clock.
- **`clk_iop`** — the IOP clock, equal to `sysclk / N` for some integer
  `N` (typically 2, 4, or 8). Generated by an external clock divider.

Since `clk_iop` is a synchronous integer division of `sysclk`, every
`clk_iop` rising edge is also a `sysclk` rising edge. **No asynchronous
CDC is needed** — signals crossing between domains are inherently
aligned.

### 11.2 Clock domain assignment

| Block | Clock | Rationale |
|---|---|---|
| AttoRV32 core | `clk_iop` | Runs at IOP rate, unmodified |
| SRAM A (private) | `clk_iop` | IOP-only, 1-cycle read at IOP rate |
| GPIO regs (OUT, OE, PADCTL) | `clk_iop` | Written by IOP |
| SPI shift helper | `clk_iop` | Shifts at IOP rate |
| Input synchronizers (2-flop) | `sysclk` | Must catch edges between IOP ticks |
| WAKE_LATCH edge detect | `sysclk` | Must see edges at full system rate |
| SRAM B0 / B1 (mailbox) | `sysclk` | Host accesses at full rate |
| SRAM B arbiter | `sysclk` | Arbitrates at system rate |
| Doorbells (H2C, C2H) | `sysclk` | Host sets on sysclk; IOP reads on `clk_iop` (synchronous subset) |
| IOP_CTRL | `sysclk` | Host-only |

### 11.3 Cross-domain timing

**`sysclk` → `clk_iop`** (e.g., `DOORBELL_H2C`, `SRAM B Do0`): the
signal is set on a `sysclk` edge. The core samples it on the next
`clk_iop` edge, which is N−1 or more `sysclk` cycles later. The signal
has been stable for ages. No synchronizer needed.

**`clk_iop` → `sysclk`** (e.g., core's `mem_addr` reaching the SRAM B
arbiter): the signal changes on a `clk_iop` edge, which IS a `sysclk`
edge. The arbiter sees it on the very next `sysclk` edge. No synchronizer
needed.

### 11.4 Bit-bang performance vs ratio

Rough toggle rates (sysclk = 100 MHz, baseline CPI ≈ 3.7):

| N | IOP clk | Max toggle | Usable for |
|---:|---:|---:|---|
| 1 | 100 MHz | ~9 MHz | SPI slave ≤ 4 MHz, everything else |
| 2 | 50 MHz | ~4.5 MHz | SPI slave ≤ 2 MHz |
| 4 | 25 MHz | ~2.2 MHz | UART ≤ 230 kbaud, I²C 100/400 kHz, SPI ≤ 1 MHz |
| 8 | 12.5 MHz | ~1.1 MHz | UART ≤ 115 kbaud, I²C 100 kHz |

With SPI shift helper at N=4: ~1.5 Mbps SPI throughput.

## 12. Boot and reset

### 12.1 Boot sequence

1. Host asserts `IOP_CTRL.reset` (keeps IOP in reset; SRAM A port
   muxed to host bus).
2. Host writes firmware image into SRAM A (`0x000 – 0x1FF` in host
   view).
3. Host optionally pre-populates the mailbox (SRAM B0/B1) with initial
   parameters.
4. Host deasserts `IOP_CTRL.reset` (SRAM A port switches to IOP).
5. IOP begins fetching at `0x000`, runs its reset trampoline,
   initializes `.data`/`.bss`, and enters main loop.
6. Host and IOP communicate via mailbox + doorbells.

### 12.2 PADCTL initialization

Host cannot write `PADCTL` directly — it is IOP-only MMIO. Two
strategies:

- **Firmware-driven (recommended):** the IOP's `crt0.S` or early `main`
  configures `PADCTL` from constants compiled into the firmware or from
  parameters the host pre-placed in the mailbox.
- **Hardware reset defaults:** pads come up in a safe state defined by
  the `PADCTL` reset value (§8.5).

### 12.3 IOP_CTRL register (host-side, `0x308`)

```
Bit     Name        Access   Reset   Description
  0     reset       RW       1       1 = IOP held in reset, SRAM A → host
  1     nmi         RW/SC    0       write 1 = pulse NMI to IOP (self-clearing)
 31:2   (reserved)  —        0
```

## 13. Host interface

Generic register slave. The host bus signals (`host_addr`, `host_wdata`,
`host_rdata`, `host_wen`, `host_ren`, `host_wmask`, `host_ready`) form a
simple synchronous interface, easily wrapped with a thin shim for
AHB-Lite, APB, or Wishbone if the target SoC requires it.

All host accesses are on `sysclk`. Single-cycle for register reads/writes
(`DOORBELL`, `IOP_CTRL`). SRAM accesses (A during reset, B always) are
single-cycle when uncontested; SRAM B access may wait one `sysclk` cycle
if the IOP is simultaneously accessing the mailbox (rare).

## 14. Resolved decisions

| ID | Decision | Resolution | Rationale |
|---|---|---|---|
| PD-1 | Polling vs event-driven | **Event-driven with WAKE_LATCH** | Allows `wfi` sleep between events; single flop captures fast edges on `sysclk` |
| PD-2 | Clock divider | **Two external clocks** (`sysclk` + `clk_iop`) | No internal divider; eliminates CE-gating complexity; system controls ratio |
| PD-3 | Host bus protocol | **Generic register slave** | Smallest; AHB/APB/WB shim built externally if needed |
| PD-4 | SET/CLR aliases | **Keep** | 35% inner-loop speedup + atomicity; ~30 cells, zero new flops |
| PD-5 | PADCTL reset defaults | **Deferred** | Depends on padframe vendor |
| PD-6 | NMI source | **Host-only** via `IOP_CTRL.nmi` | No dedicated pin |
| PD-7 | SPI shift helper | **Yes** | ~80 cells; ~10× SPI throughput vs bit-bang; pins revert to GPIO when idle |

## 15. Resource budget (estimate)

Sky130 HD, pre-PnR, excluding SRAM macros:

| Block | Cells (est.) | Flops (est.) |
|---|---:|---:|
| AttoRV32 core (RV32EC, 1p regf, shared adder, serial shift) | ~5,000 | ~700 |
| SRAM A port mux (reset/run select) | ~40 | ~2 |
| SRAM B arbiter + B0/B1 decode + read mux | ~50 | ~6 |
| Bus address decode + top read-data mux | ~80 | ~10 |
| GPIO (OUT, OE, SET/CLR aliases, 2-flop sync) | ~400 | ~64 |
| WAKE_LATCH (edge detect + latch) | ~40 | ~18 |
| PADCTL (16 × 8 b) | ~300 | ~128 |
| SPI shift helper | ~80 | ~20 |
| Doorbells + IOP_CTRL | ~60 | ~6 |
| Host-side register slave | ~200 | ~40 |
| **Total (excl. SRAM)** | **~6,250** | **~994** |

SRAM macros (DFFRAM, Sky130):

| Macro | Config | Instances |
|---|---|---:|
| 128×32 | `DFFRAM #(.WORDS(128), .WSIZE(4))` | 1 (SRAM A) |
| 32×32 | `DFFRAM #(.WORDS(32), .WSIZE(4))` | 2 (SRAM B0, B1) |

## 16. Out of scope

- Debug UART and GDB stub. Firmware is developed and debugged on the
  host side before being loaded; silicon-level debug uses host observation
  of SRAM and mailbox contents.
- M extension (MUL/DIV). `NRV_M` remains off.
- Performance CSRs. `NRV_PERF_CSR` off.
- Multiple IOP instances.
- Bus protocol wrappers (AHB-Lite, APB, Wishbone) — external shims.
- Clock divider — external to the macro.
