# Known Hardware Bugs

Active issues in the RTL that have surfaced during verification but
have not yet been fixed.  Each entry lists the symptom, the root
cause with file/line citations, the workaround firmware/testbenches
use today, and the proposed fix.

---

## BUG-001 — SRAM B `Do0` clobbered by host polling during IOP reads

**Severity:** correctness; observable any time the host polls SRAM B
while the IOP is reading SRAM B.

**Symptom.**  An IOP load from SRAM B (the mailbox region, addresses
`0x600`–`0x6FF`) returns the value the *host* most recently read from
SRAM B, instead of the value actually stored in the addressed cell.
First seen while building `tb_irq_doorbell`: the host wrote `0xCAFE0001`
to mailbox word 16 (byte `0x640`), rang the doorbell, then polled
mailbox word 0 (byte `0x600`) waiting for the ISR's completion count.
The ISR's `lw a4, 1600(zero)` returned the value last latched into
`sram_b0_do0` by the host's polling read (`mem[0]` = the count
register's previous value), not `mem[16] = 0xCAFE0001`.

**Root cause.**  `attoio_memmux.v:165-184` arbitrates SRAM B between
the host (sysclk domain) and the core (clk_iop domain) cycle by
cycle, with host priority.  The DFFRAM `Do0` output is registered
**inside the SRAM** on every sysclk edge where `EN0=1`
(`models/dffram_rtl.v:25-33` for the behavioural model; same on real
silicon).  When the IOP issues a load:

1. clk_iop edge T: core asserts `core_addr`, `core_rstrb`, `core_active`.
   Combinationally `b_grant_core=1`, `sram_b0_a0 = core_addr[6:2]`,
   `sram_b0_en0=1`.
2. On the next sysclk edge, `sram_b0_do0 <= mem[core_addr[6:2]]`.
3. Before clk_iop edge T+1 (where the core consumes `core_rdata`),
   another sysclk edge can fire while the host APB is in an ACCESS
   phase targeting SRAM B.  When that happens, `b_grant_host=1`,
   `sram_b0_a0` is now the host's address, and `sram_b0_do0` is
   overwritten with `mem[host_addr[6:2]]`.
4. clk_iop edge T+1: the core reads `core_rdata = sram_b0_do0` —
   the host's value, not what the core asked for.

The same hazard does *not* affect writes: `core_wbusy =
b_conflict & |core_wmask` (`attoio_memmux.v:190`) stalls the core
until it owns the bank, so writes always commit eventually.

**Reproducer.**  Earlier revisions of `sim/tb_irq_doorbell.v` exhibited
this directly: an `apb_read` polling loop on byte `0x600` was running
at the moment the IOP's ISR did `lw a4, 0x640`.  The IOP saw the host's
mailbox-word-0 value instead of the staged command word.  Probing
`u_dut.u_sram_b0.mem[16]` confirmed the cell held the right value;
probing `u_dut.sram_b0_do0` at the consumption edge showed it had been
overwritten with `mem[0]`.

**Workaround.**  Firmware that needs the host to read mailbox values
written by an ISR uses an explicit completion handshake instead of
inviting the host to poll:

```c
void __isr(void) {
    /* ... handle the source, write results into mailbox ... */
    doorbell_c2h_raise();    /* tell host "results are ready" */
}
```

The host then waits on `irq_to_host` (driven by `DOORBELL_C2H` in
`attoio_ctrl.v:149`) — a sysclk-only signal that doesn't touch SRAM B
— before reading the mailbox:

```verilog
while (irq_to_host !== 1'b1) @(posedge sysclk);
apb_write(11'h704, 32'h1, 4'hF);   /* W1C C2H */
apb_read(11'h618, rd);             /* now safe */
```

`tb_irq_doorbell.v` and `tb_irq_aggregate.v` both follow this pattern
and pass cleanly.

**Proposed fix.**  Add a one-cycle latch in `attoio_memmux.v` that
captures `sram_b0_do0`/`sram_b1_do0` on the sysclk edge immediately
following the core's read issuance, and drives `core_rdata` from that
latch instead of the live SRAM output.  The latch is qualified by
`b_grant_core` so it only updates on cycles where the core actually
owned the bank:

```verilog
reg [31:0] core_b0_rdata_q, core_b1_rdata_q;
always @(posedge sysclk or negedge rst_n) begin
    if (!rst_n) begin core_b0_rdata_q <= 0; core_b1_rdata_q <= 0; end
    else begin
        if (b_grant_core & core_sel_b0) core_b0_rdata_q <= sram_b0_do0;
        if (b_grant_core & core_sel_b1) core_b1_rdata_q <= sram_b1_do0;
    end
end
```

Then the `core_rd_src` mux selects `core_b0_rdata_q` for `SRC_B0` (and
similarly for B1) instead of the live `sram_b0_do0`.  Cost: 64 flops
(two 32-bit registers).  No timing impact on critical path — the
existing `core_rd_src` register already adds a clk_iop hop.

**Status:** **fixed in Phase 0.7** (`attoio_memmux.v`, see commit
history).  The fix added `core_b0_rdata_q` / `core_b1_rdata_q`
sysclk-domain capture latches gated by a one-cycle-delayed
`b_grant_core & core_sel_b{0,1}`, exactly as proposed above.  Cost
landed as 64 + 2 flops.  Verification: `tb_irq_doorbell.v` was
rewritten to drop the C2H-handshake workaround and instead poll
mailbox[0] directly while the ISR runs and reads SRAM B (the
original BUG-001 reproducer).  It passes cleanly on the fixed RTL.
Full regression — 14/14 testbenches — confirms no functional
side-effects.

`tb_irq_aggregate.v` still uses the C2H pattern, but that's now a
stylistic choice (cleanest way to wait on "ISR completed" rather
than racing to spot a counter bump); the underlying hazard it was
working around is gone.

---

## BUG-002 — retired: **NOT a hardware bug** (firmware write-ordering race)

**Status:** **retired 2026-04-20.**  Thorough isolation (see below)
proved this was a firmware/testbench contract violation, not silicon.
E10 BLDC (`sw/bldc6/main.c`, `sim/tb_bldc6.v`) now passes cleanly
after a one-line FW reorder, with no RTL changes.  Full regression:
**19/19 testbenches PASS.**

**Original symptom (as initially reported).**  While building E10
BLDC, the ISR wrote `MAILBOX_W32[0] = comm_count; MAILBOX_W32[1] =
idx; MAILBOX_W32[3] = gate;` — but the testbench read back the
*previous* commutation's values for `mailbox[1]` and `mailbox[3]`.

**Isolation ladder.**  Five progressively wider reproducers were
built to localize the fault (all preserved in the tree under
`sw/core_hazard*` + `sim/tb_{core,macro}_hazard*`).

| # | Scope                                     | Result |
|---|-------------------------------------------|--------|
| 1 | AttoRV32 core alone, flat 2 KB memory      | all 5 mailbox stores fire with correct data (`sim/tb_core_hazard.v`) |
| 2 | Full `attoio_macro`, linear `main()`, quiet host | all correct (`sim/tb_macro_hazard.v`) |
| 3 | Full `attoio_macro`, linear `main()`, host polls mailbox[2] concurrently | all correct |
| 4 | Full `attoio_macro`, doorbell-triggered `__isr`, quiet host | all correct (`sim/tb_macro_hazard_isr.v`) |
| 5 | Full `attoio_macro`, doorbell-triggered `__isr`, concurrent polling | all correct |
| 6 | Instrumented E10 reproducer with bus snoop at core↔memmux boundary | **bug reproduced — and captured the real cause** (`sim/tb_bldc6_snoop.v`) |

Step 6 showed core stores and memmux SRAM-B writes are emitted
correctly with the right addresses and data *every single time*.
What fails is the testbench's read timing: the ISR writes
`mailbox[0]` (count) *first*, then `mailbox[1]`, then `mailbox[3]`.
The TB polls `mailbox[0]` as a "done" sentinel — so when it sees
the count bump and immediately reads `mailbox[1]`, the ISR has not
yet stored the idx.  The TB reads a stale value.

**Why this looked like a store drop.**  With `NRV_SERIAL_SHIFT`
loads and stores take ~200 sysclks each; between "mailbox[0]
bumps" and "mailbox[1] actually commits" there's a ~200 ns window.
The TB's APB read after `wait_for_at_least` fires inside that
window.  On the *next* edge's check loop, the TB sees the (now
committed) value of the *previous* edge — perfectly consistent
with an off-by-one-edge pattern.

**The fix.**  Write the payload BEFORE the sentinel.  Exactly the
same rule already documented in `sw/irq_doorbell/main.c`:

```c
void __isr(void) {
    /* ... */
    MAILBOX_W32[1]  = idx;        /* payload */
    MAILBOX_W32[3]  = gate;       /* payload */
    WAKE_FLAGS      = flags;      /* MMIO W1C */
    MAILBOX_W32[0]  = comm_count; /* sentinel — LAST */
}
```

Once the FW publishes the count last, the TB's "wait for count
bump → tight read" pattern is race-free.  No RTL change needed.

**Artifacts kept for future regression.**  The five `tb_*_hazard*`
testbenches stay in the tree (runnable via
`sim/run_{core,macro}_hazard*.sh`) as canonical store-sequence
probes.  They're not part of the default regression suite — they're
diagnostic tools should a similar complaint ever arise again.

**Lesson codified.**  All future ISRs that publish structured
results through the mailbox must follow the rule: **write the
count/sentinel last, all payload slots before it.**  The same
rule already applies to host-to-IOP doorbell ISRs
(`sw/irq_doorbell/main.c`, committed 2026-04-20 Phase 0.7 follow-on).
