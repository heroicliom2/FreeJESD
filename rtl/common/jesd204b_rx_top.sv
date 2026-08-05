// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: jesd204b_rx_top
// Implements: instructions/03-MODULE-SPECS.md "jesd204b_rx_top.sv" —
// instantiates L lanes of datapath_rx, one shared lmfc_gen, one shared
// buffer_release, and one transport_rx (doc 01's RX block diagram). This is
// the module that finally exercises buffer_release.sv's real cross-lane
// deskew semantics (single-lane Milestone 3 could not, by construction — see
// buffer_release.sv's header for the resolution) and transport_rx.sv's
// multi-lane octet<->sample mapping together, end to end.
//
// Per-lane release_i wiring: each lane's elastic_buffer reads continuously
// (one pop per available word) once the shared buffer_release_o latch has
// fired, gated by that lane's own level_o so it never underflows an
// empty/momentarily-behind buffer — `release_i[lane] = release_o &&
// (level_o[lane] > 0)`. This is exactly the single-lane Milestone 3
// testbench's `release_i = lane_ready_o && (level_o > 0)` simplification
// (see docs/HANDOFF.md), now correctly gated by the real cross-lane
// AND+LMFC-aligned latch instead of just this lane's own readiness — see
// buffer_release.sv's header for why a continuous post-release drain (not a
// recurring per-LMFC-period pulse) is the right semantics.
//
// `ready_o` is the shared buffer_release_o signal itself (i.e. "the link has
// reached its one-time deterministic-latency-aligned release point and user
// data is now flowing to transport_rx"), not just a per-lane SYNCED AND —
// the latter is separately observable per lane via `sync_n_o`.

`timescale 1ns/1ps

module jesd204b_rx_top #(
    parameter int DW_OCTETS = 4, // compile-time datapath width in octets (2/4/8), see scrambler.sv
    parameter int L  = 1,
    parameter int F  = 8,
    parameter int K  = 32,
    parameter int M  = 1,
    parameter int N  = 16,
    parameter int NP = 16,
    parameter int S  = 1,
    parameter bit SCR = 1'b1,
    parameter int CS  = 0,
    parameter bit HD  = 1'b0,
    parameter int CF  = 0,
    parameter int OCTET_ALIGN_STABLE_CNT  = 4,
    parameter int LINK_FSM_CGS_STABLE_CNT = 4,
    parameter int LINK_FSM_MAX_FAULT_CNT  = 8,
    parameter int ELASTIC_DEPTH           = 8,
    parameter int LOAD_OFFSET             = 0    // lmfc_gen's SYSREF reload offset (doc 02 §5)
) (
    input  logic            clk,
    input  logic            rst_n,
    input  logic            sysref_i,        // already resynchronized to clk upstream (doc 01)
    input  logic            ilas_check_en_i,

    input  logic [L-1:0]    lane_valid_i,
    input  logic [7:0]      lane_data_i [L],
    input  logic [L-1:0]    lane_is_k_i,

    output logic            ready_o,         // buffer_release's latched release_o (see header)
    output logic [L-1:0]    sync_n_o,
    output logic [L-1:0]    checksum_err_o,
    output logic [L-1:0]    param_mismatch_o,
    output logic [L-1:0]    overflow_o,
    output logic [L-1:0]    underflow_o,

    output logic [M-1:0]    converter_valid_o,
    output logic [NP*8-1:0] converter_data_o [M]
);

    logic [L-1:0]              lane_ready;
    logic [L-1:0]               rd_valid;
    logic [DW_OCTETS*8-1:0]     rd_data [0:L-1];
    logic [$clog2(ELASTIC_DEPTH):0] level [0:L-1];
    logic [L-1:0]               release_i_vec;

    logic lmfc_zero_w, release_o_w;

    genvar gl;
    generate
        for (gl = 0; gl < L; gl = gl + 1) begin : g_lane
            datapath_rx #(
                .DW_OCTETS(DW_OCTETS),
                .L_EXP(L), .F_EXP(F), .K_EXP(K), .M_EXP(M), .N_EXP(N), .NP_EXP(NP), .S_EXP(S),
                .SCR_EXP(SCR), .CS_EXP(CS), .HD_EXP(HD), .CF_EXP(CF),
                .OCTET_ALIGN_STABLE_CNT(OCTET_ALIGN_STABLE_CNT),
                .LINK_FSM_CGS_STABLE_CNT(LINK_FSM_CGS_STABLE_CNT),
                .LINK_FSM_MAX_FAULT_CNT(LINK_FSM_MAX_FAULT_CNT),
                .ELASTIC_DEPTH(ELASTIC_DEPTH)
            ) u_dp (
                .clk(clk), .rst_n(rst_n),
                .valid_i(lane_valid_i[gl]), .data_i(lane_data_i[gl]), .is_k_i(lane_is_k_i[gl]),
                .ilas_check_en_i(ilas_check_en_i), .release_i(release_i_vec[gl]),
                .state_o(), .mf_index_o(), .sync_n_o(sync_n_o[gl]), .lane_ready_o(lane_ready[gl]),
                .cfg_valid_o(), .cfg_octets_o(),
                .checksum_err_o(checksum_err_o[gl]), .param_mismatch_o(param_mismatch_o[gl]),
                .rd_data_o(rd_data[gl]), .rd_valid_o(rd_valid[gl]), .level_o(level[gl]),
                .overflow_o(overflow_o[gl]), .underflow_o(underflow_o[gl]),
                .descr_valid_o(), .descr_data_o(), .descr_ctrl_o()
            );

            assign release_i_vec[gl] = release_o_w && (level[gl] > 0);
        end
    endgenerate

    lmfc_gen #(.LMFC_CYCLES(F*K), .LOAD_OFFSET(LOAD_OFFSET)) u_lmfc (
        .clk(clk), .rst_n(rst_n), .sysref_i(sysref_i), .count_o(), .zero_o(lmfc_zero_w)
    );

    buffer_release #(.LANES(L)) u_brel (
        .clk(clk), .rst_n(rst_n),
        .lane_ready_i(lane_ready), .lmfc_zero_i(lmfc_zero_w),
        .release_o(release_o_w)
    );

    assign ready_o = release_o_w;

    transport_rx #(.DW_OCTETS(DW_OCTETS), .L(L), .F(F), .M(M), .S(S), .NP(NP)) u_transport (
        .clk(clk), .rst_n(rst_n),
        .lane_valid_i(rd_valid), .lane_data_i(rd_data),
        .converter_valid_o(converter_valid_o), .converter_data_o(converter_data_o)
    );

endmodule
