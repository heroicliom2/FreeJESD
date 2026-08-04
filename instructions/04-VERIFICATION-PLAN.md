# 04 — Verification Plan (iverilog-only, self-checking)

Neither reference repo gives us this for free: LiteJESD204B's tests are Python/Migen
unit tests (`./setup.py test`, simulating the Migen model, not the generated
Verilog directly), and ListenToJESD204B's verification is a Vivado-specific flow
built on the Xilinx JESD204C example testbench. **This project needs its own
iverilog-native self-checking suite from scratch** — that's the main thing this spec
pack adds beyond both references.

## Directory layout

```
tb/
  common/
    tb_pkg.sv          # shared tasks: clock gen, reset, checker macros, scoreboard
    jesd_golden_model.sv  # reference TX octet-stream generator (used to drive/check RX)
  unit/
    tb_phy_8b10b.sv
    tb_octet_align.sv
    tb_link_fsm.sv
    tb_ilas_check.sv
    tb_scrambler.sv       # round-trip property test (§3 below)
    tb_lmfc_gen.sv
    tb_elastic_buffer.sv
    tb_transport_rx.sv    # table-driven mapping test (highest bug-risk area)
    tb_transport_tx.sv
  integration/
    tb_datapath_rx.sv
    tb_link_tx_rx_loopback.sv   # link_tx -> link_rx same-process loopback, the
                                 # single most valuable test in the suite
    tb_fault_injection.sv       # CGS loss, ILAS corruption, lane skew overflow
  Makefile
```

## Self-checking convention (no waveform-reading required for pass/fail)

Every testbench:
1. Uses a shared `` `CHECK(cond, msg) `` macro (in `tb_pkg.sv`) that increments a
   `error_count` and `$display`s a `FAIL:` line with file/line/message on
   mismatch, and is silent (or prints `PASS:`) on success.
2. Ends with `if (error_count == 0) $display("TESTBENCH PASSED: %s", TB_NAME); else
   $display("TESTBENCH FAILED: %s (%0d errors)", TB_NAME, error_count);` then
   `$finish` — and, critically, **sets `$finish(1)` / uses `$fatal` semantics so the
   process exit code is nonzero on failure**, since `make test` needs to be
   CI-gateable without a human reading terminal output. (Icarus Verilog: `$fatal`
   forces nonzero exit; plain `$finish` after a manual error tally does not by
   itself set exit code, so the Makefile should `grep` for `TESTBENCH FAILED` in
   each log and fail the target if found — document this explicitly since it's an
   iverilog quirk that's easy to get wrong.)
3. Has a watchdog: `initial begin #WATCHDOG_CYCLES; $display("FAIL: watchdog
   timeout"); $finish; end` run in parallel with the main test process, so a stuck
   FSM hangs the sim for a bounded time instead of forever (important for CI).

## Golden model strategy

Rather than hand-writing expected octet sequences per test, build one
`jesd_golden_model.sv` (or even a small C/Python octet-stream generator invoked via
`$readmemh` fixture files, if that's easier to keep correct) that implements CGS +
ILAS + scrambling generation independently from the RTL `link_tx`, used two ways:

- **RX verification**: golden model drives the RX DUT directly (bypassing the need
  for a working `link_tx` first) — this lets RX unit/integration tests start before
  TX RTL exists, which matters for sequencing the roadmap (doc 06).
- **TX verification**: golden model's *checker* half (mirrors `ilas_check` +
  descrambler logic, written independently rather than by instantiating the RTL
  version) validates `link_tx`'s output — avoids the checker and the DUT sharing a
  bug because they share code.

Keep the golden model intentionally simpler/more literal than the RTL (e.g.
non-parallelized serial LFSR, straightforward per-octet loops) — it's a correctness
oracle, not a performance model, and its simplicity is what makes it trustworthy.

## Priority test list (highest verification value first)

1. **`tb_scrambler.sv`** — pure property test, no protocol context needed:
   `descramble(scramble(random_stream)) == random_stream` over thousands of random
   vectors, plus explicit "K-chars pass through unscrambled" check. Cheap to write,
   catches a large class of bugs early, and is a good "does the flow even work"
   smoke test for the iverilog setup itself.
2. **`tb_transport_rx.sv` / `_tx.sv`** — table-driven: for each `(L,M,F,S,Np)`
   config in a sweep list, feed a counting/known pattern per converter, verify
   exact octet positions in the lane stream (and the inverse). Doc 02 §7 flags this
   as the highest real-world bug rate area.
3. **`tb_link_fsm.sv`** — drive `aligned_i`/comma patterns and assert the *exact*
   state sequence (RESET→WAIT_PHY→CGS→ILAS→SYNCED) via the exposed `state_o`, plus
   the fault-reentry path (inject misalignment after SYNCED, assert return to CGS).
4. **`tb_link_tx_rx_loopback.sv`** — instantiate `link_tx` feeding `link_fsm`+
   `datapath_rx` directly (same-process, no PHY needed since both sides agree on
   the octet/K-char representation), sweep scrambling on/off and 1/2/4 lanes,
   check converter data recovered by RX == data injected at TX, bit-exact.
5. **`tb_fault_injection.sv`** — (a) drop CGS mid-link, confirm re-sync; (b) flip a
   bit in an ILAS config octet, confirm checksum fault detected and no false
   SYNCED; (c) add a lane delay exceeding `elastic_buffer` `DEPTH`, confirm
   `overflow_o` asserts rather than silent data corruption.

## Makefile contract

```
make test              # runs every tb/, aggregates pass/fail, nonzero exit on any failure
make test_<name>       # e.g. make test_scrambler — runs tb/unit/tb_scrambler.sv only
make lint               # verilator --lint-only (or iverilog -Wall) over rtl/
make clean
```

Each target: `iverilog -g2012 -o build/<name>.vvp <rtl deps> <tb file> && vvp
build/<name>.vvp | tee build/<name>.log && ! grep -q "TESTBENCH FAILED" build/<name>.log`

`-g2012` is required for the SystemVerilog-2012 constructs iverilog does support
(`always_ff`, `logic`, packed structs in limited form) — see doc 05 for exactly
which subset is safe.
