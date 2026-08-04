# Toolchain

## Installed / verified

As of 2026-08-04, Icarus Verilog is installed at `C:\iverilog\bin` on this
dev machine:

```
$ iverilog -V
Icarus Verilog version 14.0 (devel) ()
```

**Not on `PATH` by default in a fresh shell** — either add `C:\iverilog\bin`
to `PATH`, or invoke the binaries by full path / prepend it per-session:

```
# bash / Git Bash
export PATH="/c/iverilog/bin:$PATH"

# PowerShell
$env:PATH = "C:\iverilog\bin;$env:PATH"
```

`make` itself is **not** installed in this environment (checked, not on
`PATH`, no `winget`/`choco` available to install it either). The Makefile
targets are correct and CI-ready wherever GNU Make is available, but in
*this* dev environment each target's two commands (`iverilog ... -o
build/<name>.vvp <sources>` then `vvp build/<name>.vvp | tee
build/<name>.log`) must be run directly — see each target's exact source
list in `Makefile`.

## Milestone 0/1 status: all passing

```
$ iverilog -g2012 -o build/smoke.vvp tb/common/tb_pkg.sv tb/smoke/tb_smoke.sv && vvp build/smoke.vvp
TESTBENCH PASSED: tb_smoke

$ iverilog -g2012 -o build/8b10b.vvp rtl/common/jesd_pkg.sv rtl/common/phy_8b10b_enc.sv rtl/common/phy_8b10b_dec.sv tb/common/tb_pkg.sv tb/unit/tb_phy_8b10b.sv && vvp build/8b10b.vvp
TESTBENCH PASSED: tb_phy_8b10b

$ iverilog -g2012 -o build/scrambler.vvp rtl/common/jesd_pkg.sv rtl/common/scrambler.sv rtl/common/descrambler.sv tb/common/tb_pkg.sv tb/unit/tb_scrambler.sv && vvp build/scrambler.vvp
TESTBENCH PASSED: tb_scrambler
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

"Constant selects in always_* processes are not fully supported" messages
(prefixed `sorry:`, not `error:`) appear throughout the codec/scrambler
files — these are non-fatal (compilation still succeeds, exit code 0);
iverilog just falls back to coarser sensitivity-list inference. No fix
needed.

## Verilator (secondary lint, doc 05)

Not checked yet in this environment. `make lint` no-ops with a clear message
when `verilator` is not on `PATH`, per doc 05's "skip rather than block"
guidance.
