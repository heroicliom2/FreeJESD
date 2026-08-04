// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: lmfc_gen
// Implements: instructions/03-MODULE-SPECS.md "lmfc_gen.sv" — free-running
// Local Multiframe Clock counter, phase-set by SYSREF (doc 02 §5).
//
// sysref_i is assumed already resynchronized to clk upstream (doc 01: "SYSREF
// ... resynchronized with a 2-flop MultiReg-style synchronizer at the
// boundary" — that synchronizer lives outside this module, at the top level,
// per doc 01's clock domain policy). This module only does its own 2-cycle
// edge detect on the (already-synchronous) sysref_i to find the rising edge,
// matching doc 03's "edge-detected internally, 2-FF delay same as
// LiteJESD204B's LMFC class" note.

`timescale 1ns/1ps

module lmfc_gen #(
    parameter int LMFC_CYCLES = 128,  // = F*K
    parameter int LOAD_OFFSET = 0     // signed, pipeline-latency compensation (doc 02 §5); reload value = LOAD_OFFSET mod LMFC_CYCLES
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          sysref_i,
    output logic [$clog2(LMFC_CYCLES)-1:0] count_o,
    output logic                          zero_o
);

    localparam int CBITS = $clog2(LMFC_CYCLES);

    // (LOAD_OFFSET mod LMFC_CYCLES), computed to always land in [0, LMFC_CYCLES)
    // regardless of LOAD_OFFSET's sign, evaluated at elaboration time.
    localparam int RELOAD_VAL = ((LOAD_OFFSET % LMFC_CYCLES) + LMFC_CYCLES) % LMFC_CYCLES;

    logic sysref_d1, sysref_d2;
    logic sysref_edge;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sysref_d1 <= 1'b0;
            sysref_d2 <= 1'b0;
        end else begin
            sysref_d1 <= sysref_i;
            sysref_d2 <= sysref_d1;
        end
    end

    assign sysref_edge = sysref_d1 && !sysref_d2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count_o <= '0;
        end else if (sysref_edge) begin
            count_o <= RELOAD_VAL[CBITS-1:0];
        end else if (count_o == (LMFC_CYCLES - 1)) begin
            count_o <= '0;
        end else begin
            count_o <= count_o + 1'b1;
        end
    end

    assign zero_o = (count_o == '0);

endmodule
