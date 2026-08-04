# 05 — Coding & Tooling Guidelines

## Why this doc exists

The whole point of this project (per the user's ask) is that everything must
**actually run under `iverilog`/`vvp`**. Icarus Verilog implements a *subset* of
SystemVerilog-2012/2017 — targeting full UVM-style SV (as e.g. commercial-flow
JESD204B testbenches like Xilinx's example, which ListenToJESD204B's own testbench
is built on, tend to assume) will silently steer the agent toward code that
doesn't compile. This doc is the safety rail.

## iverilog SystemVerilog support — use / avoid list

**Safe to use (compiles reliably with `iverilog -g2012`):**
- `logic`, `bit` types; packed arrays/structs; `typedef`; `enum`
- `always_comb`, `always_ff @(posedge clk)`, `always_latch`
- `unique case` / `priority case` (basic usage)
- `generate`/`genvar`, parameters, `localparam`, functions, tasks
- Unpacked arrays of the above, including arrays of module instances
- `$display`, `$monitor`, `$readmemh`/`$readmemb`, `$random`/`$urandom`
  (basic PRNG calls are fine — it's the class-based `randomize()`/constraint
  machinery that's unsupported, not simple `$urandom` calls)
- Immediate assertions (`assert (cond) else $error(...)`) inside `always`/
  `initial` blocks — supported in reasonably recent iverilog (v11+)
- Basic `interface` blocks *without* relying on advanced modport/virtual-interface
  patterns — but see below, still recommend avoiding them in v0.1

**Avoid — do not use, will not compile / behaves unreliably:**
- `class` / `extends` / `randomize()` / `constraint` blocks — **no UVM, no
  class-based testbenches at all**. This is the biggest divergence from how a
  "normal" commercial JESD204B testbench (like the Xilinx one ListenToJESD204B's
  own flow is built around) would be structured — self-checking here means
  plain modules + tasks + `` `CHECK `` macros (doc 04), not a UVM environment.
- `program` blocks, `clocking` blocks
- Concurrent assertions (`property`/`sequence`, `assert property (@(posedge clk)
  ...)`) — support is inconsistent; if timing-relationship checks are needed,
  write them as explicit `always_ff` checker logic instead, not SVA.
- Dynamic types beyond simple queues/assoc arrays where avoidable — unpacked
  fixed-size arrays are safer and sufficient for this project's needs
  (parameters are all compile-time known).
- `interface`/`modport` for the main RTL ports — **use plain port lists**
  (the `valid/data/ctrl` convention in doc 01) instead. Interfaces work
  partially in iverilog but are a frequent source of "works in Verilator/
  commercial sim, fails in iverilog" bugs; not worth the risk for this project.
- `virtual interface`, anything DPI-related unless explicitly decided otherwise.

**When in doubt:** write the smallest possible standalone `.sv` file exercising
the construct, compile it with the exact `iverilog` invocation from doc 04's
Makefile, and confirm it works *before* using that construct across the RTL. Don't
assume based on general SystemVerilog knowledge — Icarus's supported subset has
changed across versions and is genuinely narrower than Verilator's or a commercial
simulator's.

## Icarus version target

Assume **Icarus Verilog v12.0** (current stable as of writing) unless the user's
environment reports otherwise — first roadmap milestone (doc 06) includes
`iverilog -V` version check and a short capability smoke-test file, precisely so
the rest of the project isn't built on wrong assumptions about what compiles.

## Style rules

- One module per file, filename == module name (`link_fsm.sv` → `module
  link_fsm`).
- `snake_case` for signals/modules, `SCREAMING_SNAKE` for parameters,
  `UpperCamel` avoided entirely (keep it uniform, this isn't a class-based
  language here).
- Every module file starts with a header comment: purpose, one-line summary of
  which doc-03 spec section it implements, and the SPDX license identifier.
- Every port has an inline comment when its meaning isn't obvious from the name
  alone (especially `ctrl`/K-char masks and anything with implicit units,
  e.g. "in octets" vs "in cycles").
- No `initial` blocks in synthesizable RTL files (`rtl/`) — only in `tb/`.
- Reset: synchronous, active-high `rst`, applied via `always_ff @(posedge clk)`
  with `if (rst) ... else ...` at the top of every sequential block — keep this
  completely uniform across the codebase so agents (and reviewers) don't have to
  re-derive reset polarity/style per file.
- Parametrize everything that doc 00's config table lists as parametrized
  (`L, F, K, M, N, Np, S, SCR`) via SystemVerilog `parameter`, not `` `define ``.

## Linting

`make lint` should run `verilator --lint-only -Wall` (if available in the
environment) as a *secondary* check even though Icarus is the primary target —
Verilator's lint catches width mismatches and latch inference that iverilog
won't flag, and its supported syntax is a superset of Icarus's, so anything that
fails Verilator lint is worth fixing even if iverilog would compile it silently.
If Verilator isn't available in the sandbox, skip this step rather than blocking
on it, and note that in the milestone's completion report.
