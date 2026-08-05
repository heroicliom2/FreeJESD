// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: buffer_release
// Implements: instructions/03-MODULE-SPECS.md "buffer_release.sv" — shared,
// one per link. doc 03 literally: "release_o = &lane_ready_i qualified by
// lmfc_zero_i". This resolves the question docs/HANDOFF.md flagged as
// genuinely unresolved after Milestone 3 (single-lane tb_datapath_rx.sv used
// a testbench-side release_i simplification, explicitly NOT the real
// semantics).
//
// Resolution: release_o is a LATCH, not a recurring per-LMFC-period pulse.
// Read literally, "&lane_ready_i qualified by lmfc_zero_i" is ambiguous
// between (a) release_o pulses high for one cycle every time both conditions
// are true (i.e. once per LMFC period, F*K cycles), or (b) release_o
// transitions 0->1 once, at the first LMFC-zero after all lanes are ready,
// and then stays 1. Interpretation (a) contradicts doc 03's own elastic_buffer
// DEPTH framing ("skew tolerance", not multiframe capacity): writes into each
// elastic_buffer happen continuously (one word every DW_OCTETS octets) from
// the moment a lane reaches SYNCED, so gating reads to once per F*K cycles
// would require DEPTH >= F*K/DW_OCTETS words just to avoid overflowing while
// waiting for the next gate — far deeper than a skew buffer needs to be.
// Interpretation (b) is what subclass 1's "deterministic latency" is actually
// about: all lanes must *begin* emitting deskewed data at the same
// LMFC-aligned instant (so downstream sample timing is repeatable across
// power cycles), not that data trickles out once per multiframe. Once that
// one-time alignment point has occurred, each elastic_buffer just drains
// continuously (one read per available word) same as the single-lane
// Milestone 3 testbench already did — this module's job is only to pick the
// correct *starting* cycle for that continuous drain, in lockstep across all
// lanes. See jesd204b_rx_top.sv for how release_o is combined with each
// lane's own level_o to form each elastic_buffer's actual release_i.
//
// release_o drops back to 0 immediately if any lane's ready deasserts (fault
// re-entry per link_fsm.sv) — re-arms and waits for the next lmfc_zero_i
// once all lanes are ready again, so a lane that faults and resyncs doesn't
// leave the link releasing against stale alignment.

`timescale 1ns/1ps

module buffer_release #(
    parameter int LANES = 1
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [LANES-1:0] lane_ready_i,
    input  logic             lmfc_zero_i,
    output logic             release_o
);

    logic all_ready;
    assign all_ready = &lane_ready_i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            release_o <= 1'b0;
        end else if (!all_ready) begin
            release_o <= 1'b0;
        end else if (lmfc_zero_i) begin
            release_o <= 1'b1;
        end
    end

endmodule
