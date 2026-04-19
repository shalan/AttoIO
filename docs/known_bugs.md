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

**Status:** open.  All three `tb_irq_*` tests use the C2H handshake
workaround.  No production firmware uses host-polls-during-ISR
patterns.  Fix is queued as a Phase 0.7 RTL touch-up.
