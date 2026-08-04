// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: ilas_check
// Implements: instructions/03-MODULE-SPECS.md "ilas_check.sv" — captures
// the 14 ILAS config octets from multiframe 1 (doc 02 §3), computes/compares
// the checksum, and compares the decoded parameters against this lane's
// expected configuration.
//
// Params are plain scalars (expected L/F/K/M/N/N'/S/SCR/CS/HD/CF), not a
// jesd_settings_t struct parameter as doc 03 suggests — consistent with
// avoiding struct types across module boundaries elsewhere in this project
// after hitting iverilog struct-assignment quirks (see phy_8b10b_enc.sv,
// jesd_pkg.sv headers). DID/BID/LID are intentionally NOT compared — they
// identify the specific device/bank/lane rather than being a negotiated
// link parameter, so doc 03's "compare against expected settings" is read
// as covering jesd_settings_t's fields only.
//
// Capture trigger: this module does its own independent /Q/ detection
// (gated by mf_index_i==1) rather than assuming a fixed cycle offset from
// link_fsm.sv's R detection — link_fsm's mf_index_o is a *registered*
// output that reads 1 starting from the cycle immediately after it
// processes multiframe 1's /R/, which (by construction, one octet later)
// is exactly the cycle multiframe 1's /Q/ appears on data_i. Capturing
// starts on seeing that /Q/ while mf_index_i==1, then takes the next 14
// non-K octets (K-marked /A/ frame-boundary octets within multiframe 1 are
// skipped, not counted) as the config data — matching
// tb/common/jesd_golden_model.sv's generation layout exactly (doc 02 §3
// field layout is jesd_pkg.sv's ilas_pack_config/ilas_unpack_config, the
// single source of truth both sides use).

`timescale 1ns/1ps

module ilas_check #(
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
    parameter int CF_EXP  = 0
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       valid_i,
    input  logic [7:0] data_i,
    input  logic       is_k_i,
    input  logic [1:0] mf_index_i,  // from link_fsm.sv
    input  logic       enable_i,    // 0 = observe-only, cfg_valid_o always asserts after capture
    output logic        cfg_valid_o,      // pulses for 1 cycle when a capture completes
    output logic [111:0] cfg_octets_o,     // {checksum[111:104], 13 config octets[103:0]}, octet0 at bits[7:0]
    output logic        checksum_err_o,
    output logic        param_mismatch_o
);

    import jesd_pkg::*;

    logic capturing;
    logic [3:0] cfg_idx; // 0..13
    logic [7:0] cfg_bytes [0:13];
    logic       do_check;

    logic [103:0] cfg13_packed;
    logic [7:0]   computed_checksum;
    logic [88:0]  unpacked;
    logic         settings_match;

    integer bidx;

    always_comb begin
        cfg13_packed = '0;
        for (bidx = 0; bidx < 13; bidx = bidx + 1)
            cfg13_packed[8*bidx +: 8] = cfg_bytes[bidx];
        computed_checksum = ilas_checksum(cfg13_packed);
        unpacked = ilas_unpack_config(cfg13_packed);
        settings_match = (unpacked[63:56] == L_EXP[7:0])  &&
                          (unpacked[55:48] == F_EXP[7:0])  &&
                          (unpacked[47:40] == K_EXP[7:0])  &&
                          (unpacked[39:32] == M_EXP[7:0])  &&
                          (unpacked[29:22] == N_EXP[7:0])  &&
                          (unpacked[21:14] == NP_EXP[7:0]) &&
                          (unpacked[13:6]  == S_EXP[7:0])  &&
                          (unpacked[64]    == SCR_EXP)     &&
                          (unpacked[31:30] == CS_EXP[1:0]) &&
                          (unpacked[5]     == HD_EXP)      &&
                          (unpacked[4:0]   == CF_EXP[4:0]);
    end

    logic is_q;
    assign is_q = valid_i && is_k_i && (data_i == K_Q);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            capturing        <= 1'b0;
            cfg_idx          <= '0;
            do_check         <= 1'b0;
            cfg_valid_o      <= 1'b0;
            checksum_err_o   <= 1'b0;
            param_mismatch_o <= 1'b0;
            cfg_octets_o     <= '0;
        end else begin
            cfg_valid_o <= 1'b0;
            do_check    <= 1'b0;

            if (!capturing) begin
                if (valid_i && (mf_index_i == 2'd1) && is_q) begin
                    capturing <= 1'b1;
                    cfg_idx   <= '0;
                end
            end else if (valid_i) begin
                if (!is_k_i) begin
                    cfg_bytes[cfg_idx] <= data_i;
                    if (cfg_idx == 4'd13) begin
                        capturing <= 1'b0;
                        do_check  <= 1'b1; // fires next cycle; cfg_bytes fully populated by then
                    end
                    cfg_idx <= cfg_idx + 1'b1;
                end
                // is_k_i=1 (an /A/ frame-boundary marker within mf1): skip, don't advance
            end

            if (do_check) begin
                checksum_err_o   <= (computed_checksum !== cfg_bytes[13]);
                param_mismatch_o <= !settings_match;
                cfg_valid_o      <= enable_i ? (settings_match && (computed_checksum === cfg_bytes[13])) : 1'b1;
                cfg_octets_o     <= {cfg_bytes[13], cfg13_packed};
            end
        end
    end

endmodule
