# 06 — Build Roadmap

Work through these milestones in order. Each has an explicit exit criterion that
must pass under `iverilog`/`vvp` before moving to the next — don't let scope creep
forward (e.g. don't start TX before RX unit tests are green).

## Milestone 0 — Environment sanity
- Check `iverilog -V` / `vvp -V`, record version in `docs/TOOLCHAIN.md`.
- Write and run one trivial `.sv` file per doc 05's "safe to use" list item that
  the project will actually rely on (`always_ff`, packed struct, generate loop,
  immediate assert, `$urandom`) to confirm the target toolchain handles them.
- **Exit:** smoke-test file compiles and runs, output captured in
  `docs/TOOLCHAIN.md`.

## Milestone 1 — Foundations
- `jesd_pkg.sv` (K-chars, settings struct, checksum function).
- `phy_8b10b_enc.sv` / `_dec.sv` + `tb_phy_8b10b.sv` (round-trip + known-vector
  table test).
- `scrambler.sv` / `descrambler.sv` + `tb_scrambler.sv` (property test, doc 04 §
  priority list item 1 — do this one early, it's cheap and validates the whole
  toolchain flow on "real" protocol logic).
- **Exit:** `make test_8b10b test_scrambler` both pass.

## Milestone 2 — Golden model
- `tb/common/jesd_golden_model.sv`: standalone CGS+ILAS+scramble TX octet-stream
  generator, independent of any RTL `link_tx` (doc 04).
- Self-test the golden model against doc 02's field-layout description by hand
  (dump a short generated sequence and manually verify the K-char placement and
  ILAS config-octet checksum in review, since this file *is* the oracle and has
  no oracle of its own).
- **Exit:** golden model produces a CGS→4-multiframe-ILAS→scrambled-user-data
  sequence for a chosen (L=1,F=4,K=32,M=2) config, dumped to a log for manual
  spot-check.

## Milestone 3 — RX link layer, single lane
- `octet_align.sv`, `link_fsm.sv`, `ilas_check.sv`, `elastic_buffer.sv`,
  `lmfc_gen.sv`, `datapath_rx.sv` + one unit TB each.
- `tb_datapath_rx.sv`: golden model drives `datapath_rx` directly, assert exact
  FSM state sequence and correct descrambled output, single lane.
- **Exit:** `make test_datapath_rx` passes for both `SCR=0` and `SCR=1`.

## Milestone 4 — RX transport layer + multi-lane
- `transport_rx.sv` + `tb_transport_rx.sv` (table-driven sweep, doc 04 §2).
- `buffer_release.sv`, extend `datapath_rx` instantiation to `jesd204b_rx_top.sv`
  for L=2 and L=4.
- Multi-lane skew test: stagger golden-model lane outputs by N cycles, confirm
  `buffer_release` still produces bit-exact, simultaneously-released converter
  data.
- **Exit:** `make test_transport_rx` and top-level 2-lane/4-lane loopback (golden
  model → `jesd204b_rx_top`) pass.

## Milestone 5 — TX side
- `transport_tx.sv`, `link_tx.sv`, `jesd204b_tx_top.sv`.
- `tb_link_tx_rx_loopback.sv`: **this is the milestone's real test** — `link_tx`
  feeding straight into Milestone 3/4's `datapath_rx`/`jesd204b_rx_top` in the
  same process, no golden model needed on the RX-check side since the RX core
  itself, already validated, is now the checker.
- **Exit:** loopback passes for L∈{1,2,4}, SCR∈{0,1}, bit-exact converter data
  round-trip.

## Milestone 6 — Fault injection & robustness
- `tb_fault_injection.sv`: CGS loss mid-link, ILAS checksum corruption, skew
  exceeding buffer depth (doc 04 §5 item 5).
- Confirm every fault produces a *defined* response (documented re-sync or
  documented error flag), never silent data corruption or an unbounded hang
  (watchdog from doc 04 should catch the latter automatically).
- **Exit:** all three fault scenarios pass with the expected, documented
  behavior; update doc 03's module specs with the exact fault-flag semantics as
  they're finalized (spec docs should track what actually got built).

## Milestone 7 — STPL self-test infra + polish
- `stpl_gen.sv`/`stpl_checker.sv` (doc 03), wired as an optional top-level
  self-test mode, matching LiteJESD204B's built-in STPL feature — gives
  downstream users of this IP an interop self-check without needing this
  project's own testbenches.
- `make lint` pass (Verilator, if available).
- Write `docs/ARCHITECTURE.md` reflecting what was actually built (diagrams,
  parameter table, any deviations from this spec pack, e.g. simplifications
  taken in the `/F//A/` character-replacement handling per doc 02 §2).
- `THIRD_PARTY_NOTICES.md` crediting both reference repos.
- **Exit:** `make test` (full suite) green, `make lint` clean or documented
  exceptions, README for the new repo written.

## Stretch (post-v0.1, not required for "done")
- Multi-clock-domain CDC (PHY clock ≠ link clock), matching LiteJESD204B's fuller
  `LiteJESD204BTXCDC`/`RXCDC` design.
- Subclass 0 / Subclass 2.
- CSR/register-file wrapper (AXI4-Lite), matching LiteJESD204B's
  `LiteJESD204BCoreControl`.
- Full `/F//A/` character-replacement-on-repeated-data (deferred simplification
  from doc 02 §2).
