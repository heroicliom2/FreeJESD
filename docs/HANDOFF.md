# Handoff notes (living doc, updated at each milestone boundary)

Written for whichever agent (or human) picks this project up next, most
likely with a fresh context window. Read this before touching Milestone 2+.
Keep it updated as milestones close — this is not a historical log, it's
"what you need to know right now."

## Status as of 2026-08-05

Milestones 0-3 (`instructions/06-BUILD-ROADMAP.md`) are **implemented and
verified** — `make test` passes end-to-end (10 testbenches):
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
  drives the full RX chain end-to-end, both SCR=0 and SCR=1, in one run

Milestone 4 (RX transport layer + multi-lane — `transport_rx.sv`,
`buffer_release.sv`, extend to `jesd204b_rx_top.sv` for L=2/4) has **not**
been started. That's the next task — see its starting-point section below,
which covers real unfinished business this milestone deliberately left for
it (the `/F//A/` marker-stripping gap in particular).

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
`elastic_buffer.sv` (Milestone 1) are 4-octet/32-bit-per-cycle (doc 00/01's
stated internal datapath convention). `datapath_rx.sv` bridges this with a
small internal octet->word packer — see its header comment. This assumes
CGS length and F*K are multiples of 4 (true for every config doc 00
targets); not a general-purpose arbitrary-length packer.

**`release_i` / `buffer_release.sv` is genuinely unresolved, on purpose.**
doc 02 §6 describes elastic-buffer release as "gated by the LMFC-zero
pulse" — read literally (one release per full `F*K`-cycle LMFC period),
that implies each `elastic_buffer.sv` needs to be deep enough to hold a
full multiframe (`F*K/4` words), which contradicts doc 03's own framing of
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

## Milestone 4 starting point

Next: `transport_rx.sv` + `tb_transport_rx.sv` (table-driven octet<->sample
mapping sweep, doc 02 §7 — flagged as the highest real-world JESD204B bug
rate area), `buffer_release.sv`, and extending to `jesd204b_rx_top.sv` for
L=2/L=4. Two things this milestone actually needs to resolve, not defer
further:
1. **The `/F//A/` marker-stripping gap.** `elastic_buffer.sv` has no `ctrl`
   port (doc 03), so the user-data octet stream reaching it still has
   `/F/`/`/A/` alignment markers interspersed (every 4th octet, for the
   doc 00 target F=4 config — meaning literally every packed 32-bit word
   contains exactly one marker octet, so "drop words containing a marker"
   is not viable, see `datapath_rx.sv`'s header). `transport_rx.sv`'s
   octet<->sample de-interleave logic already has to understand frame
   structure, so stripping the markers as part of that de-interleave is
   the natural place — but this hasn't been designed yet.
2. **`buffer_release.sv`'s actual release semantics** — see the unresolved
   `release_i` question directly above. Multi-lane deskew is the actual
   reason this module exists, so this milestone can't punt on it the way
   `tb_datapath_rx.sv` did.

## Makefile mechanics (for adding new test targets)

Don't hand-write new Makefile rules — append one line per new testbench:
```makefile
$(eval $(call TEST_RULE,<name>,<space-separated source file list, jesd_pkg.sv first>))
```
This wires up `build/<name>.vvp`, `build/<name>.log`, a `test_<name>` phony
target, and folds it into `make test` automatically.
