# Handoff notes (living doc, updated at each milestone boundary)

Written for whichever agent (or human) picks this project up next, most
likely with a fresh context window. Read this before touching Milestone 2+.
Keep it updated as milestones close — this is not a historical log, it's
"what you need to know right now."

## Status as of 2026-08-05

Milestones 0-4 (`instructions/06-BUILD-ROADMAP.md`) are **implemented and
verified** — `make test` passes end-to-end (14 testbenches). Milestone 4
(`buffer_release.sv`, `transport_rx.sv`, `jesd204b_rx_top.sv` for L=1/2/4)
is documented in its own section below ("Milestone 4 resolution") — read
that before touching multi-lane or transport-layer code, it resolves two
real gaps left open after Milestone 3.

Milestones 0-3 testbenches (10 of the 14):
- `tb_smoke` — toolchain construct smoke test
- `tb_phy_8b10b` — exhaustive 256-value D-character sweep + 200 random + 5 K-chars
- `tb_scrambler` — 4000-vector streaming round-trip + K-passthrough check
- `tb_golden_model` — CGS/ILAS/user-data structural checks, ILAS config-octet
  pack/unpack + checksum round trip, scrambled payload cross-checked against
  `rtl/common/descrambler.sv`
- `tb_lmfc_gen` — free-run + SYSREF-edge reload (incl. negative LOAD_OFFSET)
- `tb_elastic_buffer` — FIFO order, underflow, overflow (no corruption),
  lane_ready_i write gating, simultaneous write+read while full
- `tb_octet_align` — pass-through timing, comma-run stability, latching
- `tb_link_fsm` — full state sequence, sync_n_o timing, ILAS multiframe
  tracking, checksum-fail path, alignment-loss fault re-entry
- `tb_ilas_check` — clean/checksum-fail/param-mismatch captures, observe-only mode
- `tb_datapath_rx` — **the real Milestone 3 integration test**: golden model
  drives the full RX chain end-to-end, all 6 combinations of SCR∈{0,1} x
  DW_OCTETS∈{2,4,8} (16/32/64-bit), in one run

Milestone 4 testbenches (the remaining 4):
- `tb_buffer_release` — directed test of the cross-lane latch semantics
  (LANES∈{1,4}): stays 0 until all lanes ready + an lmfc_zero pulse, stays
  latched across further lmfc_zero pulses, clears immediately on any lane
  dropping ready, re-arms correctly
- `tb_transport_rx` — **the real octet<->sample mapping test**: hand-built
  per-lane octet tables (marker position + expected mapping computed
  independently of the RTL) sweep L∈{1,2,4} x DW_OCTETS∈{2,4,8}, 9
  combinations in one run
- `tb_jesd204b_rx_top` — full link-level integration: L independent golden
  models drive `jesd204b_rx_top` end-to-end (no injected skew — lockstep
  smoke test), sweeping the same 9 L x DW_OCTETS combinations, checking
  fault-free operation and that `transport_rx` actually produces samples
- `tb_multilane_skew` — **the real Milestone 4 deskew test** (roadmap's
  explicit exit criterion): lane 1's entire stream delayed 37 cycles behind
  lane 0, confirms `buffer_release` still waits for both lanes and neither
  `elastic_buffer` overflows absorbing the skew

Milestone 4 (RX transport layer + multi-lane — `transport_rx.sv`,
`buffer_release.sv`, extend to `jesd204b_rx_top.sv` for L=2/4) has **not**
been started. That's the next task — see its starting-point section below,
which covers real unfinished business this milestone deliberately left for
it (the `/F//A/` marker-stripping gap in particular).

## Standing requirement: configurable datapath width (added 2026-08-05, after Milestone 3)

User requirement, not from the `instructions/` spec pack — confirmed via two
clarifying questions before implementing, both answered "recommended":
1. **Datapath width is a compile-time parameter**, `DW_OCTETS` (2/4/8 =
   16/32/64-bit octets/cycle), threaded through every module that has a
   multi-octet-wide port — same binding model as every other config in this
   project (L, F, K, M, SCR...). Not runtime-switchable; changing it means
   re-elaborating the core, not writing a register.
2. **F (octets/frame) must be a multiple of `DW_OCTETS`.** Doc 03's F range
   (1-256) already covers real ADC bit widths (8/16/32-bit converters) —
   that part needed no change. The width requirement only affects how many
   octets get packed into one datapath word per cycle; constraining F to a
   multiple of the chosen width avoids partial-word handling at every frame
   boundary, which real ADC configs don't typically need anyway.

**Retrofitted** (all re-verified passing, `DW_OCTETS` swept in {2,4,8}
everywhere it applies): `scrambler.sv`, `descrambler.sv` (data/ctrl ports
and the `process_block` function's octet loop now scale with `DW_OCTETS`;
`STATE_WIDTH`/LFSR math unaffected — unrelated to datapath width),
`elastic_buffer.sv` (word width only; `DEPTH`, entry count, is independent
of `DW_OCTETS`), `datapath_rx.sv` (packer width + `DW_OCTETS` passed through
to its `descrambler`/`elastic_buffer` instances). **Not touched, and don't
need to be**: `octet_align.sv`, `link_fsm.sv`, `ilas_check.sv` — these
already operate one octet per cycle by design (doc 03's own port widths for
them), which is inherently width-agnostic; the datapath-width concept only
exists from the packer boundary onward. `jesd_pkg.sv`, `phy_8b10b_enc/dec.sv`
are similarly untouched (K-chars and 8b/10b symbols are octet/10-bit-level,
not datapath-word-level).

If you're touching any module downstream of the packer boundary in a later
milestone (`transport_rx.sv`, `link_tx.sv`, `transport_tx.sv`, etc.), add
`DW_OCTETS` to it from the start and sweep {2,4,8} in its testbench — don't
build it 32-bit-only and retrofit later like this pass had to.

## Toolchain (fixed, don't re-discover this every session)

- Icarus Verilog 14.0 (devel) at `C:\iverilog\bin`.
- GNU Make 4.4.1 at `C:\msys64\usr\bin\make.exe` (MSYS2).
- **Both are permanently on the User `PATH`** as of 2026-08-04 (persistent
  registry env var, not per-session) — any shell/terminal opened after that
  date should just have `iverilog`/`vvp`/`make` available directly. If a
  particular tool session doesn't (e.g. it was already running before the
  PATH change, or it's a sandboxed/isolated shell), fall back to:
  ```bash
  export PATH="/c/iverilog/bin:/c/msys64/usr/bin:$PATH"
  make test
  ```
- One-time machine setup gotcha: iverilog can error `Error opening temporary
  file C:\TEMP\...` even with `$TMP`/`$TEMP` set correctly — fix is
  `mkdir -p /c/TEMP` once (see docs/TOOLCHAIN.md). Already done on this
  machine; only matters if working from a different machine/container.
- Verilator is not installed; `make lint` no-ops cleanly (this is expected,
  not a bug).
- Full bug log from getting Milestone 0/1 actually running: see
  `docs/TOOLCHAIN.md`.

## Established conventions that deviate from instructions/

The `instructions/` spec pack is the build plan, but two things were
overridden by explicit user decision early on — don't "fix" these back
toward the spec pack's suggestion:

1. **Project name stays "FreeJESD"**, license stays **CERN-OHL-P v2** (not
   the spec pack's suggested "OpenJESD204B" / Apache-2.0/Solderpad-0.51) —
   the repo root (README/LICENSE/CONTRIBUTING) predates the spec pack and
   the user chose to keep that branding.
2. **Reset is active-low `rst_n`**, synchronous, not doc 05's suggested
   active-high `rst` — matches the pre-existing `rtl/` stub files' style.
   Everything else in doc 05 (the `valid/data/ctrl` streaming convention,
   no `interface`/`modport`, no class-based constructs, etc.) is followed
   as written.

## iverilog gotchas — apply these from the start, don't rediscover them

1. **No function `output`/`inout` ports.** Every helper function must
   return a single packed value; callers slice it apart. See
   `phy_8b10b_enc.sv`'s `get_6b_pair` for the pattern.
2. **No unpacked-dimension subroutine ports** (e.g. `input logic [7:0]
   octets[13]` as literally written in doc 03 for `ilas_checksum` does not
   compile). Pass a single packed vector instead and slice with `+:`
   part-selects — see `jesd_pkg.sv::ilas_checksum`.
3. **Same-edge NBA sampling race.** Reading a DUT signal immediately after
   the `@(posedge clk)` that causes the DUT to update it (via nonblocking
   assignment) reads the *pre-update* value — the DUT's `always_ff` hasn't
   reached the NBA region yet in that same time step. Always add `#1;`
   before sampling a DUT output right after the edge that produces it, or
   restructure to check exactly one edge after the producing edge (see any
   `send_and_check`-style task in `tb/unit/` for the pattern). This bit
   every single testbench on first pass — assume it'll bite the next one
   too and write the settle delay in from the start.
4. **Testbench `rst_n` must use nonblocking (`rst_n <= ...`)**, never
   blocking (`rst_n = ...`) — same NBA-race family as #3.
5. `"sorry: constant selects in always_* processes..."` messages are
   non-fatal (compile still succeeds, exit 0) — don't try to fix these.
6. **`` `CHECK `` in an if/else arm without explicit begin/end is a
   dangling-else trap.** `` `CHECK `` expands to its own `if (!(cond))
   begin...end` with no `else`. Writing
   `if (X) \`CHECK(a,"...") else \`CHECK(b,"...")` lets the `else` silently
   bind to CHECK's *internal* if instead of the outer one — no compile
   error, no warning, just the wrong branch running (confirmed the hard way
   in `tb_golden_model.sv`: it made a correctly-generated multiframe-end `A`
   marker get checked against the *frame*-end `F` condition instead, purely
   because the `else` attached to the wrong `if`). Always wrap **both** arms
   in `begin...end` when a `` `CHECK `` is a direct if/else-if/else arm. See
   `tb_pkg.sv`'s header for the fully-expanded example.
7. **A same-time-step bug can look nondeterministic if you're not careful
   while debugging it.** Adding/removing an unrelated `$display` appeared to
   flip a real bug (#6 above) between pass/fail across a couple of runs
   while investigating — it wasn't actually nondeterministic (rebuilding
   from scratch multiple times reproduced the same result every time), the
   apparent flip was misleading. If a failure seems to depend on debug
   prints, rebuild clean 2-3 times before trusting either outcome, and look
   for a structural cause (like #6) rather than assuming a race.

## The 8b/10b K-character redesign (important for Milestone 3's octet_align.sv)

`phy_8b10b_enc.sv`/`_dec.sv`'s 5 K-characters (K28.0/.3/.4/.5/.7) do **not**
use the industry-standard 10-bit K28.x bit patterns. The first attempt did,
and `tb_phy_8b10b`'s exhaustive sweep caught real D/K collisions (D92 and
D124 were decoding as K-characters) — reusing the primary D-table row for a
K-character's index isn't actually safe without the real standard's
"alternate" disambiguation table, which wasn't reliably reconstructible from
memory. The fix: all 5 K-chars now share a 6-bit prefix (`111100`/`000011`)
that's provably unused by any of the 32 D-character 5b/6b table entries,
guaranteeing D/K disjointness by construction. Consequence: **`K_K` is not
the classic 0011111010 "comma" pattern.** When Milestone 3's
`octet_align.sv` needs to search for a comma/alignment pattern in the bit
stream, it must search for *this project's* actual K-symbol values (defined
in `phy_8b10b_enc.sv`'s `k_symbol_pair` function), not the textbook comma
sequence from a JESD204B reference or datasheet.

## Milestone 2 resolution (for Milestone 3 to reuse, don't re-derive)

`instructions/02-PROTOCOL-REFERENCE.md` §3's ILAS config-octet bit layout
ambiguity (no exact intra-octet offsets given, real JEDEC text not
available in this environment) was resolved by defining a self-consistent,
documented, project-own layout in `jesd_pkg.sv`
(`ilas_pack_config`/`ilas_unpack_config`, see that file's header for the
exact bit table) — NOT the literal JEDEC Table 12 positions. Verified via
round trip in `tb_golden_model.sv`. Milestone 3's `ilas_check.sv` must call
`jesd_pkg::ilas_unpack_config` (already written, don't reimplement the
layout) rather than hand-rolling its own field extraction — that's the
"single source of truth" doc 03 asks for.

Also reusable from Milestone 2: `tb/common/jesd_golden_model.sv` is exactly
the TX octet-stream source doc 04 says to drive `datapath_rx`/`link_fsm`
with directly for Milestone 3's RX testbenches (`tb_datapath_rx.sv` etc.) —
instantiate it, call `.generate_stream()`, then feed `u_gm.data[]`/`is_k[]`
(sliced into 32-bit/4-octet words, `ctrl[o]` = `is_k[base+o]`) into the RX
DUT. Its exposed offsets (`cgs_start`/`cgs_end`, `ilas_start`/`ilas_end`,
`mf_start[0:3]`/`mf_end[0:3]`, `user_start`/`user_end`) are there precisely
so an RX testbench can assert the DUT's FSM state transitions against known
phase boundaries without recomputing them.

## Milestone 3 resolution (for Milestone 4 to reuse, don't re-derive)

Confirmed: `octet_align.sv` operates on already-8b10b-decoded octets+is_k
(doc 03's alternate signature), not raw 10-bit symbols — the K-character
redesign note above turned out not to matter here, since `jesd_pkg::K_K`'s
*octet* value (8'hBC) never changed, only the 10-bit `phy_8b10b` symbol
encoding underneath it. Only relevant again if something ever needs to
inspect raw 10-bit symbols directly (nothing in this project does).

**Two real design bugs found by `tb_datapath_rx.sv`** (not caught by any
individual module's own unit test, because each module's unit test drove it
with idealized, hand-crafted timing — this is exactly why doc 04 calls the
golden-model-driven integration test "the single most valuable test in the
suite"):

1. **`link_fsm.sv` sampled a transient pulse too late.**
   `ilas_check.sv`'s `cfg_valid_o` is a single-cycle pulse that fires
   shortly after multiframe 1's capture completes (~octet 160 of a
   512-octet ILAS phase for the doc 00 target config) — but `link_fsm.sv`
   only checked `ilas_valid_i` once, at the *last* ILAS octet (position
   511). By then the pulse was long gone, so it always read 0 and bounced
   back to CGS, never reaching SYNCED. Fixed by latching: `ilas_ok` gets
   set the moment `ilas_valid_i` pulses during LINK_ILAS, reset on
   (re-)entering ILAS, and it's `ilas_ok` (not the instantaneous
   `ilas_valid_i`) that gates the SYNCED transition at completion.
   **Generalize this**: any time one FSM samples another module's
   single-cycle "done/valid" pulse at a *different* cycle than when it
   fires, that's a latch, not a same-cycle read — check for this pattern
   before wiring modules together, don't wait for the integration test to
   find it.
2. **Scrambling was applied to ILAS octets, corrupting the descrambler's
   LFSR state before real user data even began.** doc 02 §4 is explicit:
   scrambling "is applied only to the user-data phase, never to CGS or ILAS
   octets." `datapath_rx.sv`'s octet->word packer (see width-mismatch note
   below) was originally free-running from reset, feeding *everything*
   (CGS, ILAS's R/Q/A markers, and — critically — ILAS mf1's 14 non-K
   config octets) into the descrambler. The K-marked octets pass through
   descrambler unscrambled by design (doesn't touch LFSR state), but mf1's
   config octets are NOT K-marked (they're real data by protocol
   definition) — so they got LFSR-processed as if they were user data,
   leaving the LFSR in the wrong state by the time real user data arrived.
   Fixed by gating the packer itself on `lane_ready_o` (SYNCED only) — this
   also happens to keep the packer's mod-4 word-phase counter cleanly
   aligned to the true start of user data instead of accumulating phase
   from however many CGS+ILAS octets preceded it.

**A real architectural gap in doc 03** (not a bug, a genuine spec-pack
inconsistency): `octet_align.sv`/`link_fsm.sv`/`ilas_check.sv` are specified
with 1-octet-per-cycle `[7:0]` ports, but `scrambler.sv`/`descrambler.sv`/
`elastic_buffer.sv` (Milestone 1) are multi-octet-per-cycle (`DW_OCTETS`,
this project's own width-flexibility requirement as of 2026-08-05 — see
that section above). `datapath_rx.sv` bridges this with a small internal
octet->word packer — see its header comment. This assumes F is a multiple
of `DW_OCTETS` (project convention); not a general-purpose arbitrary-length
packer. (Earlier note in this file said "F*K multiples of 4" — superseded:
the packer is gated to SYNCED-only now, so only F, not CGS length or F*K,
constrains it.)

**`release_i` / `buffer_release.sv` is genuinely unresolved, on purpose.**
doc 02 §6 describes elastic-buffer release as "gated by the LMFC-zero
pulse" — read literally (one release per full `F*K`-cycle LMFC period),
that implies each `elastic_buffer.sv` needs to be deep enough to hold a
full multiframe (`F*K/DW_OCTETS` words), which contradicts doc 03's own framing of
`DEPTH` as sized to *skew tolerance*, not multiframe capacity. For this
single-lane milestone there's no other lane to deskew against anyway, so
`tb_datapath_rx.sv` just drives `release_i = lane_ready_o && (level_o > 0)`
(continuous drain once SYNCED, no LMFC gating at all) as a testbench-side
simplification — **not** a resolution of the real question. Milestone 4
(`buffer_release.sv`, real cross-lane deskew) has to actually decide this;
don't assume `tb_datapath_rx.sv`'s `release_i` wiring reflects the intended
production behavior.

Also reusable: `tb/common/jesd_golden_model.sv` (Milestone 2) is exactly the
TX source Milestone 4's `tb_transport_rx.sv`/`jesd204b_rx_top.sv` tests
should keep driving directly — instantiate it, call `.generate_stream()`,
feed `u_gm.data[]`/`is_k[]` in per the pattern in `tb_datapath_rx.sv`.

## Milestone 4 resolution (for Milestone 5 to reuse, don't re-derive)

Both real gaps flagged after Milestone 3 are now resolved, not deferred:

1. **`buffer_release.sv`'s real release semantics** (see its own header for
   the full reasoning): `release_o` is a **one-time latch**, not a recurring
   per-LMFC-period pulse. It sets on the first `lmfc_zero_i` seen while all
   `lane_ready_i` are 1, then stays 1 (drops immediately if any lane's ready
   deasserts, re-arms for the next `lmfc_zero_i`). Reading doc 03's
   "`release_o = &lane_ready_i` qualified by `lmfc_zero_i`" as a *recurring*
   gate (one read per LMFC period) would force every `elastic_buffer.sv` to
   be sized for a full multiframe (`F*K/DW_OCTETS` words) just to survive
   the wait between releases — the "skew tolerance" framing doc 03 actually
   gives `DEPTH` never intended that. The one-time-latch reading matches
   what "deterministic latency" is actually about: all lanes *start*
   emitting deskewed data at the same LMFC-aligned instant; after that,
   each lane's `elastic_buffer` just drains continuously
   (`release_i[lane] = release_o && (level_o[lane] > 0)`, same pattern
   Milestone 3's single-lane `tb_datapath_rx.sv` used as a simplification —
   now it's the real thing, gated by the real cross-lane condition).
   **Real consequence surfaced by `tb_jesd204b_rx_top.sv`**: even with this
   resolution, each lane's `elastic_buffer` still must survive the gap
   between *that lane* reaching SYNCED and the *next* `lmfc_zero_i` — up to
   one full LMFC period in the worst case, not just inter-lane skew. Size
   `ELASTIC_DEPTH` off `F*K/DW_OCTETS`, not just expected skew, in any real
   instantiation (`jesd204b_rx_top.sv`'s testbenches use `ELASTIC_DEPTH=256`
   for exactly this reason, at `F*K=256`).
2. **The `/F//A/` marker-stripping gap**, resolved in `transport_rx.sv`:
   since doc 02 §2's v0.1 simplification always inserts a marker at every
   frame's last octet (not just on data repeats), marker position is fully
   deterministic — strip by counting position (`local_pos == F-1`), not by
   inspecting content (`elastic_buffer.sv` has no ctrl port, so content-based
   stripping isn't even possible this far downstream). See
   `transport_rx.sv`'s header for the full per-lane counter reasoning
   (why a free-running counter reset only at `rst_n` stays correctly
   phase-locked, including under lane skew — verified by
   `tb_multilane_skew.sv`).
3. **The octet<->sample mapping itself** also has no literal JEDEC table
   available in this environment (same situation as the ILAS config-octet
   layout, doc 02 §3) — resolved the same way: a self-consistent, documented,
   project-own convention (`gidx = local_pos*L + lane`, read
   converter-major/byte-minor, MSB-first), verified by `tb_transport_rx.sv`'s
   directed table test rather than trusting an unavailable reference. See
   `transport_rx.sv`'s header for the exact formula before touching it.
4. **Deviation from doc 03's port list**: `transport_rx.sv`'s
   `converter_valid_o` is `[M-1:0]` (one strobe per converter, each pulsing
   independently as that converter's own latest sample completes), not
   doc 03's single shared valid — doc 03's single valid only makes sense for
   S=1 (every converter's one sample/frame completes "together"); for S>1 the
   converter-major gidx ordering makes different converters' samples
   complete at genuinely different cycles. See `transport_rx.sv`'s header
   for the full justification (same spirit as `link_fsm.sv`'s F/K param
   deviation in Milestone 3).
5. **Known, documented, NOT resolved**: `transport_rx.sv`'s per-converter
   byte-write ordering assumes all L lanes' internal word counters stay in
   lockstep once data is flowing (true in nominal operation — proven fine
   even under *initial* lane skew by `tb_multilane_skew.sv`, since
   `buffer_release.sv` only ever starts draining once every lane already has
   its frame-position-0 word buffered). What's NOT exercised: a lane
   stalling *after* release has begun (e.g. transient emptiness from
   residual skew) relative to the others — see `transport_rx.sv`'s header
   for the exact scenario. Flagged honestly rather than silently assumed
   away, same practice as every other real gap in this file.

Also reusable: `jesd204b_rx_top.sv`'s per-lane wiring pattern
(`datapath_rx` → `buffer_release`-gated `release_i` → `transport_rx`) is the
template Milestone 5's `jesd204b_tx_top.sv` should mirror on the TX side
(mirrored roles: `link_tx` generates what `datapath_rx` consumes, etc.).

## Milestone 5 starting point

Next per `instructions/06-BUILD-ROADMAP.md`: `transport_tx.sv`, `link_tx.sv`,
`jesd204b_tx_top.sv`, then `tb_link_tx_rx_loopback.sv` — feed `link_tx`
straight into this milestone's own `datapath_rx`/`jesd204b_rx_top`, no golden
model needed on the check side since the already-validated RX core itself is
now the checker. Per the standing width-flexibility requirement, give every
new TX module `DW_OCTETS` from the start and sweep {2,4,8} in its
testbench — don't retrofit later. `link_tx.sv` will need to generate the same
`/F//A/`-every-frame-boundary pattern `transport_rx.sv` now strips
positionally (see Milestone 4 resolution item 2 above) — reuse that same
convention on the TX side rather than inventing a second one.

## Makefile mechanics (for adding new test targets)

Don't hand-write new Makefile rules — append one line per new testbench:
```makefile
$(eval $(call TEST_RULE,<name>,<space-separated source file list, jesd_pkg.sv first>))
```
This wires up `build/<name>.vvp`, `build/<name>.log`, a `test_<name>` phony
target, and folds it into `make test` automatically.
