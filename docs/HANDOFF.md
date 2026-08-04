# Handoff notes (living doc, updated at each milestone boundary)

Written for whichever agent (or human) picks this project up next, most
likely with a fresh context window. Read this before touching Milestone 2+.
Keep it updated as milestones close — this is not a historical log, it's
"what you need to know right now."

## Status as of 2026-08-04

Milestones 0, 1, and 2 (`instructions/06-BUILD-ROADMAP.md`) are
**implemented and verified** — `make test` passes end-to-end:
- `tb_smoke` — toolchain construct smoke test
- `tb_phy_8b10b` — exhaustive 256-value D-character sweep + 200 random + 5 K-chars
- `tb_scrambler` — 4000-vector streaming round-trip + K-passthrough check
- `tb_golden_model` — CGS/ILAS/user-data structural checks, ILAS config-octet
  pack/unpack + checksum round trip, scrambled payload cross-checked against
  `rtl/common/descrambler.sv`

Milestone 3 (RX link layer, single lane — `octet_align.sv`, `link_fsm.sv`,
`ilas_check.sv`, `elastic_buffer.sv`, `lmfc_gen.sv`, `datapath_rx.sv`) has
**not** been started. That's the next task.

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

## Milestone 3 starting point

Next: `octet_align.sv`, `link_fsm.sv`, `ilas_check.sv`, `elastic_buffer.sv`,
`lmfc_gen.sv`, `datapath_rx.sv` (doc 03), single lane, driven by the golden
model. Remember the K-character redesign note above when `octet_align.sv`
needs to recognize `/K/` (K28.5 / `jesd_pkg::K_K`'s *octet* value is
unchanged, 8'hBC — only the 10-bit `phy_8b10b` *symbol* encoding changed;
`octet_align.sv` operates on already-8b10b-decoded octets+is_k per doc 01's
layering, so this likely doesn't affect it directly, but double check
against `01-ARCHITECTURE.md`'s block diagram before assuming which layer
sees raw 10-bit symbols vs decoded octets).

## Makefile mechanics (for adding new test targets)

Don't hand-write new Makefile rules — append one line per new testbench:
```makefile
$(eval $(call TEST_RULE,<name>,<space-separated source file list, jesd_pkg.sv first>))
```
This wires up `build/<name>.vvp`, `build/<name>.log`, a `test_<name>` phony
target, and folds it into `make test` automatically.
