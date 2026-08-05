// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: datapath_rx
// Implements: instructions/03-MODULE-SPECS.md "datapath_rx.sv" — per-lane
// structural wrapper: octet_align -> link_fsm <-> ilas_check -> descrambler
// -> elastic_buffer.
//
// Width-mismatch resolution (a real architectural gap in doc 03, not just
// an implementation choice): octet_align.sv/link_fsm.sv/ilas_check.sv are
// specified with 1-octet-per-cycle [7:0] ports, but scrambler.sv/
// descrambler.sv/elastic_buffer.sv (Milestone 1) are DW_OCTETS-octets-per-
// cycle (doc 00/01's internal datapath convention, generalized to this
// project's width-flexibility requirement — DW_OCTETS = 2/4/8 for
// 16/32/64-bit, compile-time only, see scrambler.sv's header). This module
// bridges the two with a small internal octet->word packer between
// octet_align and descrambler (see `pack_*` below), gated to run only while
// `lane_ready_o` (SYNCED) — see the packer's own comment for why continuous
// packing is wrong (doc 02 §4: scrambling never applies to CGS/ILAS octets,
// and letting the descrambler process them corrupts its LFSR state before
// real user data even begins — caught by tb_datapath_rx.sv, not assumed).
// This assumes CGS length and F are multiples of DW_OCTETS (project
// convention — see the width-flexibility clarification in
// docs/HANDOFF.md) — not a general-purpose arbitrary-length packer.
//
// buffer_release.sv doesn't exist until Milestone 4 (multi-lane); for this
// single-lane milestone, `release_i` is accepted directly as an external
// input (the caller — a testbench here, jesd204b_rx_top.sv later — is
// responsible for release_i = lmfc_zero && (cross-lane AND, trivial for
// L=1)). lmfc_gen.sv itself is NOT instantiated inside this module — doc 01's
// block diagram shows it as a *shared* top-level resource across lanes, so
// it lives outside the per-lane datapath, consistent with buffer_release.sv
// also being shared.

`timescale 1ns/1ps

module datapath_rx #(
    parameter int DW_OCTETS = 4, // compile-time datapath width in octets: 2/4/8 = 16/32/64-bit
    // ilas_check expected settings (doc 03)
    parameter int L_EXP  = 1,
    parameter int F_EXP  = 4,
    parameter int K_EXP  = 32,
    parameter int M_EXP  = 2,
    parameter int N_EXP  = 16,
    parameter int NP_EXP = 16,
    parameter int S_EXP  = 1,
    parameter bit SCR_EXP = 1'b1,
    parameter int CS_EXP  = 0,
    parameter bit HD_EXP  = 1'b0,
    parameter int CF_EXP  = 0,
    // sub-module tuning
    parameter int OCTET_ALIGN_STABLE_CNT   = 4,
    parameter int LINK_FSM_CGS_STABLE_CNT  = 4,
    parameter int LINK_FSM_MAX_FAULT_CNT   = 8,
    parameter int ELASTIC_DEPTH            = 8
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       valid_i,
    input  logic [7:0] data_i,
    input  logic       is_k_i,
    input  logic       ilas_check_en_i,
    input  logic       release_i,        // external: lmfc_zero && cross-lane-ready (shared, outside this module)

    output jesd_pkg::link_state_t state_o,
    output logic [1:0]  mf_index_o,
    output logic        sync_n_o,
    output logic        lane_ready_o,

    output logic        cfg_valid_o,      // ilas_check introspection (doc 03)
    output logic [111:0] cfg_octets_o,
    output logic        checksum_err_o,
    output logic        param_mismatch_o,

    output logic [DW_OCTETS*8-1:0] rd_data_o, // elastic_buffer output (this lane's descrambled, deskewed data)
    output logic        rd_valid_o,
    output logic [$clog2(ELASTIC_DEPTH):0] level_o,
    output logic        overflow_o,
    output logic        underflow_o,

    // Pre-elastic-buffer introspection: the descrambled octet stream still
    // carries its ctrl (is_k) bits, unlike elastic_buffer's output — doc 03
    // gives elastic_buffer no ctrl port at all, which means stripping the
    // /F//A/ alignment-marker octets out of the user-data stream has to
    // happen downstream (transport_rx.sv, Milestone 4, which already needs
    // to understand frame structure for its octet<->sample de-interleave).
    // Exposed here so a testbench can verify this module's own chain
    // (octet_align->link_fsm->ilas_check->descrambler) end-to-end without
    // needing that not-yet-built stripping logic.
    output logic        descr_valid_o,
    output logic [DW_OCTETS*8-1:0] descr_data_o,
    output logic [DW_OCTETS-1:0]   descr_ctrl_o
);

    import jesd_pkg::*;

    logic       oa_valid, oa_k, oa_aligned;
    logic [7:0] oa_data;

    octet_align #(.STABLE_CNT(OCTET_ALIGN_STABLE_CNT)) u_align (
        .clk(clk), .rst_n(rst_n),
        .valid_i(valid_i), .data_i(data_i), .is_k_i(is_k_i),
        .valid_o(oa_valid), .data_o(oa_data), .is_k_o(oa_k), .aligned_o(oa_aligned)
    );

    link_fsm #(
        .CGS_STABLE_CNT(LINK_FSM_CGS_STABLE_CNT), .MAX_FAULT_CNT(LINK_FSM_MAX_FAULT_CNT), .F(F_EXP), .K(K_EXP)
    ) u_fsm (
        .clk(clk), .rst_n(rst_n),
        .valid_i(oa_valid), .data_i(oa_data), .is_k_i(oa_k),
        .aligned_i(oa_aligned), .ilas_valid_i(cfg_valid_o),
        .state_o(state_o), .mf_index_o(mf_index_o), .sync_n_o(sync_n_o), .lane_ready_o(lane_ready_o)
    );

    ilas_check #(
        .L_EXP(L_EXP), .F_EXP(F_EXP), .K_EXP(K_EXP), .M_EXP(M_EXP), .N_EXP(N_EXP), .NP_EXP(NP_EXP), .S_EXP(S_EXP),
        .SCR_EXP(SCR_EXP), .CS_EXP(CS_EXP), .HD_EXP(HD_EXP), .CF_EXP(CF_EXP)
    ) u_ilas (
        .clk(clk), .rst_n(rst_n),
        .valid_i(oa_valid), .data_i(oa_data), .is_k_i(oa_k), .mf_index_i(mf_index_o), .enable_i(ilas_check_en_i),
        .cfg_valid_o(cfg_valid_o), .cfg_octets_o(cfg_octets_o),
        .checksum_err_o(checksum_err_o), .param_mismatch_o(param_mismatch_o)
    );

    // octet_align's 1-octet/cycle stream -> 4-octet/32-bit word packer.
    // Gated by lane_ready_o (SYNCED only) — doc 02 §4: "Applied only to the
    // user-data phase, never to CGS or ILAS octets" (this includes ILAS
    // multiframe 1's non-K config-octet payload, not just the K-marked
    // R/Q/A framing — those octets must never reach the descrambler either,
    // or its LFSR state advances on them and every real user-data octet
    // after that point descrambles wrong). This gating also happens to keep
    // pack_cnt's mod-4 phase cleanly aligned to the true start of user data,
    // rather than accumulating phase from however many CGS+ILAS octets
    // preceded it.
    localparam int PACK_CNT_BITS = (DW_OCTETS > 1) ? $clog2(DW_OCTETS) : 1;

    logic [DW_OCTETS*8-1:0]  pack_word;
    logic [DW_OCTETS-1:0]    pack_ctrl;
    logic                    pack_valid;
    logic [PACK_CNT_BITS-1:0] pack_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pack_cnt   <= '0;
            pack_word  <= '0;
            pack_ctrl  <= '0;
            pack_valid <= 1'b0;
        end else begin
            pack_valid <= 1'b0;
            if (oa_valid && lane_ready_o) begin
                pack_word[8*pack_cnt +: 8] <= oa_data;
                pack_ctrl[pack_cnt]        <= oa_k;
                if (pack_cnt == PACK_CNT_BITS'(DW_OCTETS - 1))
                    pack_valid <= 1'b1;
                pack_cnt <= pack_cnt + 1'b1;
            end
        end
    end

    logic                   descr_valid;
    logic [DW_OCTETS*8-1:0] descr_data;
    logic [DW_OCTETS-1:0]   descr_ctrl;

    descrambler #(.DW_OCTETS(DW_OCTETS)) u_descr (
        .clk(clk), .rst_n(rst_n),
        .valid_i(pack_valid), .data_i(pack_word), .ctrl_i(pack_ctrl), .enable_i(SCR_EXP),
        .valid_o(descr_valid), .data_o(descr_data), .ctrl_o(descr_ctrl)
    );

    assign descr_valid_o = descr_valid;
    assign descr_data_o  = descr_data;
    assign descr_ctrl_o  = descr_ctrl;

    elastic_buffer #(.DW_OCTETS(DW_OCTETS), .DEPTH(ELASTIC_DEPTH)) u_ebuf (
        .clk(clk), .rst_n(rst_n),
        .wr_valid_i(descr_valid), .wr_data_i(descr_data), .lane_ready_i(lane_ready_o),
        .release_i(release_i),
        .rd_data_o(rd_data_o), .rd_valid_o(rd_valid_o), .level_o(level_o),
        .overflow_o(overflow_o), .underflow_o(underflow_o)
    );

endmodule
