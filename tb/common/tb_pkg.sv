// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// File: tb_pkg.sv
// Purpose: shared self-checking testbench macros (doc 04 "Self-checking
// convention" / "Makefile contract"). Compiled ahead of every tb/*.sv file in
// the Makefile's file list so these `define macros are visible everywhere in
// the single iverilog compilation unit — this file has no module of its own.
//
// Usage convention every testbench in this repo follows:
//   integer error_count = 0;
//   `CHECK(cond, "message")   ... as many times as needed ...
//   `TB_FINISH("tb_name")     at the very end of the main initial block
//   `TB_WATCHDOG(cycles)      once, at module scope, in parallel with the
//                             main test process
//
// DANGLING-ELSE TRAP: `CHECK expands to its own `if (!(cond)) begin...end`
// with no `else` of its own. Writing
//     if (X) `CHECK(a, "...") else `CHECK(b, "...")
// without explicit begin/end on the outer if/else lets the `else` bind to
// CHECK's *internal* if instead of the outer one you wrote — silently
// changes which branch runs, no compile error, no warning. Confirmed the
// hard way in tb_golden_model.sv (Milestone 2): every `CHECK used as a
// direct if/else-if/else arm must be wrapped in its own begin/end:
//     if (X) begin
//         `CHECK(a, "...")
//     end else begin
//         `CHECK(b, "...")
//     end

`ifndef TB_PKG_SV
`define TB_PKG_SV

`define CHECK(cond, msg) \
    if (!(cond)) begin \
        error_count = error_count + 1; \
        $display("FAIL: %s:%0d: %s", `__FILE__, `__LINE__, msg); \
    end

`define TB_FINISH(tb_name) \
    begin \
        if (error_count == 0) begin \
            $display("TESTBENCH PASSED: %s", tb_name); \
            $finish; \
        end else begin \
            $display("TESTBENCH FAILED: %s (%0d errors)", tb_name, error_count); \
            $fatal(1); \
        end \
    end

`define TB_WATCHDOG(cycles) \
    initial begin \
        #(cycles); \
        $display("FAIL: watchdog timeout after %0d time units", cycles); \
        $fatal(1); \
    end

`endif // TB_PKG_SV
