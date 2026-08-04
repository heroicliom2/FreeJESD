# Toolchain

## Installed / verified

As of 2026-08-04, Icarus Verilog is installed at `C:\iverilog\bin` on this
dev machine:

```
$ iverilog -V
Icarus Verilog version 14.0 (devel) ()
```

**Permanently added to the User `PATH`** (2026-08-04, via
`[Environment]::SetEnvironmentVariable("PATH", ..., "User")`) — both
`C:\iverilog\bin` and `C:\msys64\usr\bin` (GNU Make 4.4.1, `make.exe`) are
in the persistent registry-backed PATH now, so **any new shell/terminal/IDE
session** (opened after 2026-08-04) has `iverilog`/`vvp`/`make` available
with no setup. This only affects *new* processes — a shell that was already
running before the change won't see it until restarted. If a tool session
in this repo doesn't have them on PATH, it's an old/pre-existing shell; the
old per-session workaround still works as a fallback:
```
# bash / Git Bash
export PATH="/c/iverilog/bin:/c/msys64/usr/bin:$PATH"

# PowerShell
$env:PATH = "C:\iverilog\bin;C:\msys64\usr\bin;$env:PATH"
```

**Environment quirk:** iverilog can fail with `Error opening temporary file
C:\TEMP\ivrlgXXXXX` / `Please check TMP or TMPDIR` even though `$TMP`/`$TEMP`
are correctly set in the shell — it seems to want a literal `C:\TEMP`
sometimes regardless. Fix: `mkdir -p /c/TEMP` once per machine. Not a code
issue, just a one-time local setup step.

## Milestone 0-3 status: all passing (`make test`, 10 testbenches)

```
$ make test
...
TESTBENCH PASSED: tb_smoke
TESTBENCH PASSED: tb_phy_8b10b
TESTBENCH PASSED: tb_scrambler
TESTBENCH PASSED: tb_golden_model
TESTBENCH PASSED: tb_lmfc_gen
TESTBENCH PASSED: tb_elastic_buffer
TESTBENCH PASSED: tb_octet_align
TESTBENCH PASSED: tb_link_fsm
TESTBENCH PASSED: tb_ilas_check
TESTBENCH PASSED: tb_datapath_rx
All testbenches passed.
```

## Real bugs this toolchain caught on first run (kept here for reference —
## the same classes of bug are worth watching for in every later milestone)

1. **Same-edge NBA sampling races** — reading a signal that a DUT updates via
   nonblocking assignment immediately after the `@(posedge clk)` that
   triggered that update, in the *same* simulation time step, reads the
   *pre*-update value (the DUT's own `always_ff` hasn't reached the NBA
   region yet). Fixed everywhere by adding a `#1;` settle delay (or
   restructuring to check exactly one edge after the edge that produces the
   value) before reading any DUT output. Also applies to testbench-driven
   `rst_n` — use `rst_n <= ...` (nonblocking), never `rst_n = ...`
   (blocking), for the same reason.
2. **iverilog does not support function `output`/`inout` ports** ("Function
   arguments must be input ports") — every helper function of the form
   `function automatic void f(input ..., output ...)` had to be rewritten to
   pack all results into a single wide return value instead
   (`function automatic logic [N:0] f(input ...); ... return {a,b}; endfunction`,
   sliced apart by the caller). Affects `phy_8b10b_enc.sv`,
   `phy_8b10b_dec.sv`, `scrambler.sv`, `descrambler.sv`.
3. **iverilog does not support unpacked-dimension subroutine ports**
   ("Subroutine ports with unpacked dimensions are not yet supported") — doc
   03's literal `ilas_checksum(bit [7:0] octets[13])` signature doesn't
   compile; `jesd_pkg.sv` takes a single packed `logic [103:0]` instead and
   slices it with `octets[8*i +: 8]`.
4. **A real 8b/10b table bug**, not a toolchain quirk: the first
   implementation of `phy_8b10b_enc/dec`'s K-character codewords reused the
   primary D-character 3b/4b table's row pattern for K28.0/.3/.4/.5, which
   `tb_phy_8b10b.sv`'s exhaustive 256-value sweep caught immediately (D92 and
   D124 were decoding as K-characters). Fixed by moving all 5 JESD204B
   K-characters onto a 6-bit prefix unused by any D-character — see
   `phy_8b10b_enc.sv`'s header comment for the full explanation and the
   tradeoff (these are no longer the industry-standard K28.x bit patterns).
5. **`iverilog -o build/<name>.vvp` fails with a misleading `error: Code
   generator failure: -1`** (no actual syntax/semantic error reported) if
   the `build/` output directory doesn't exist yet — it can't write the
   output file and the resulting error message doesn't say that clearly.
   Always `mkdir -p build` (or just use `make`, whose `TEST_RULE` already
   has the `| $(BUILD)` order-only prerequisite) before invoking `iverilog`
   directly by hand.
6. **A real testbench logic bug**: `tb_golden_model.sv`'s dangling-else trap
   with the `` `CHECK `` macro (see `tb_pkg.sv` gotcha #6 in
   `docs/HANDOFF.md`) — silently checked the wrong condition at ILAS/user-data
   multiframe boundaries. Looked briefly like nondeterminism while debugging
   (adding an unrelated `$display` appeared to change the result) but wasn't;
   rebuilding clean repeatedly showed the real, consistent bug. Root-caused
   and fixed by wrapping both arms of the `if`/`else` in explicit
   `begin`/`end`.
7. **Two real design bugs, Milestone 3**, both caught by `tb_datapath_rx.sv`
   (the full-chain integration test) and by neither module's own unit test
   individually — see `docs/HANDOFF.md`'s "Milestone 3 resolution" section
   for the full explanation: (a) `link_fsm.sv` sampled `ilas_check.sv`'s
   single-cycle `cfg_valid_o` pulse at the wrong cycle (needed a latch, not
   a same-cycle read); (b) `datapath_rx.sv`'s octet->word packer ran from
   reset instead of being gated to the user-data phase only, so ILAS's
   non-K config octets got fed into the descrambler and corrupted its LFSR
   state before real user data even began (doc 02 §4: scrambling never
   applies to CGS/ILAS octets).

"Constant selects in always_* processes are not fully supported" messages
(prefixed `sorry:`, not `error:`) appear throughout the codec/scrambler
files — these are non-fatal (compilation still succeeds, exit code 0);
iverilog just falls back to coarser sensitivity-list inference. No fix
needed.

## Verilator (secondary lint, doc 05)

Not checked yet in this environment. `make lint` no-ops with a clear message
when `verilator` is not on `PATH`, per doc 05's "skip rather than block"
guidance.
