# Handoff notes (living doc, updated at each milestone boundary)

Written for whichever agent (or human) picks this project up next, most
likely with a fresh context window. Read this before touching Milestone 2+.
Keep it updated as milestones close — this is not a historical log, it's
"what you need to know right now."

## Status as of 2026-08-04

Milestones 0 and 1 (`instructions/06-BUILD-ROADMAP.md`) are **implemented
and verified** — `make test` passes end-to-end:
- `tb_smoke` — toolchain construct smoke test
- `tb_phy_8b10b` — exhaustive 256-value D-character sweep + 200 random + 5 K-chars
- `tb_scrambler` — 4000-vector streaming round-trip + K-passthrough check

Milestone 2 (golden model, `tb/common/jesd_golden_model.sv`) has **not**
been started. That's the next task.

## Toolchain (fixed, don't re-discover this every session)

- Icarus Verilog 14.0 (devel) at `C:\iverilog\bin`, not on PATH by default.
- GNU Make 4.4.1 at `C:\msys64\usr\bin\make.exe` (MSYS2), also not on PATH by
  default, and **separate from Git Bash** (the Bash tool's default shell) —
  MSYS2's own bash has these on PATH already; Git Bash doesn't.
- To run anything from the Bash tool in this project:
  ```bash
  export PATH="/c/iverilog/bin:/c/msys64/usr/bin:$PATH"
  make test
  ```
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

## Milestone 2 starting point

`instructions/02-PROTOCOL-REFERENCE.md` §3 lists the 14 ILAS
configuration-octet fields but does not give exact intra-octet bit offsets,
and explicitly says to cross-check the real JEDEC text rather than trust a
transcription — which isn't available in this environment. Resolution
(same pattern as the 8b/10b table): don't block on it. Pick a
self-consistent, documented bit layout in the golden model / `jesd_pkg.sv`,
used identically by both the golden model and (later) `ilas_check.sv` /
`link_tx.sv`, and verify it via the golden model's own pack→unpack→checksum
round trip in `tb`. `doc 00`'s non-goals already exclude third-party PHY
interop for v0.1, so bit-exact match to the real JEDEC table isn't required
for correctness here — only internal TX/RX self-consistency is, and that's
fully testable locally now that the toolchain works.

## Makefile mechanics (for adding new test targets)

Don't hand-write new Makefile rules — append one line per new testbench:
```makefile
$(eval $(call TEST_RULE,<name>,<space-separated source file list, jesd_pkg.sv first>))
```
This wires up `build/<name>.vvp`, `build/<name>.log`, a `test_<name>` phony
target, and folds it into `make test` automatically.
