// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_ilas_check
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 3 unit test for
// rtl/common/ilas_check.sv — a clean matching capture, a checksum-corrupted
// capture, a param-mismatched capture, and observe-only mode (enable_i=0
// still asserts cfg_valid_o despite a real error). Builds its own mf1
// stream directly with jesd_pkg::ilas_pack_config/ilas_checksum (the same
// functions tb_golden_model.sv already validated) rather than depending on
// the full golden model, keeping this a focused per-module test — the
// golden-model-driven end-to-end path is tb_datapath_rx.sv.

`timescale 1ns/1ps

module tb_ilas_check;
    import jesd_pkg::*;

    integer error_count = 0;
    `TB_WATCHDOG(200000)

    localparam int L_EXP = 1, F_EXP = 4, K_EXP = 32, M_EXP = 2, N_EXP = 16, NP_EXP = 16, S_EXP = 1;
    localparam bit SCR_EXP = 1'b1;
    localparam int CS_EXP = 0;
    localparam bit HD_EXP = 1'b0;
    localparam int CF_EXP = 0;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic       rst_n, valid_i, is_k_i, enable_i;
    logic [7:0] data_i;
    logic [1:0] mf_index_i;
    logic       cfg_valid_o, checksum_err_o, param_mismatch_o;
    logic [111:0] cfg_octets_o;

    ilas_check #(
        .L_EXP(L_EXP), .F_EXP(F_EXP), .K_EXP(K_EXP), .M_EXP(M_EXP), .N_EXP(N_EXP), .NP_EXP(NP_EXP), .S_EXP(S_EXP),
        .SCR_EXP(SCR_EXP), .CS_EXP(CS_EXP), .HD_EXP(HD_EXP), .CF_EXP(CF_EXP)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .valid_i(valid_i), .data_i(data_i), .is_k_i(is_k_i), .mf_index_i(mf_index_i), .enable_i(enable_i),
        .cfg_valid_o(cfg_valid_o), .cfg_octets_o(cfg_octets_o),
        .checksum_err_o(checksum_err_o), .param_mismatch_o(param_mismatch_o)
    );

    task automatic step(input logic [7:0] d, input logic k, input logic [1:0] mf);
        data_i     <= d;
        is_k_i     <= k;
        mf_index_i <= mf;
        valid_i    <= 1'b1;
        @(posedge clk);
        #1;
    endtask

    // Sends R, Q, then 13 config octets (with an /A/ marker spliced in to
    // exercise the skip logic) and a checksum octet, mirroring
    // jesd_golden_model.sv's mf1 layout exactly.
    task automatic send_mf1(input logic bad_checksum, input logic bad_l);
        logic [103:0] cfg13;
        logic [7:0]   octets [0:12];
        logic [7:0]   checksum;
        integer bi;
        cfg13 = ilas_pack_config(8'hA5, 8'h03, 8'h00, SCR_EXP,
                                  (bad_l ? 8'd99 : L_EXP[7:0]), F_EXP[7:0], K_EXP[7:0], M_EXP[7:0],
                                  CS_EXP[1:0], N_EXP[7:0], NP_EXP[7:0], S_EXP[7:0], HD_EXP, CF_EXP[4:0]);
        for (bi = 0; bi < 13; bi = bi + 1) octets[bi] = cfg13[8*bi +: 8];
        checksum = ilas_checksum(cfg13);
        if (bad_checksum) checksum = checksum ^ 8'h01;

        step(K_R, 1'b1, 2'd0); // R still reads mf_index=0 (matches link_fsm's registration timing)
        step(K_Q, 1'b1, 2'd1); // Q, mf_index now reads 1 -> triggers capture
        for (bi = 0; bi < 13; bi = bi + 1) begin
            if (bi == 6) step(K_A, 1'b1, 2'd1); // interspersed frame-boundary marker, must be skipped
            step(octets[bi], 1'b0, 2'd1);
        end
        step(checksum, 1'b0, 2'd1);
    endtask

    initial begin
        rst_n = 1'b0; valid_i = 1'b0; data_i = 8'h00; is_k_i = 1'b0;
        mf_index_i = 2'd0; enable_i = 1'b1;
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        #1;

        // --- nominal: everything matches ---
        send_mf1(1'b0, 1'b0);
        @(posedge clk); #1; // do_check fires one cycle after the last capture write
        `CHECK(cfg_valid_o === 1'b1, "cfg_valid_o expected on a clean, matching capture")
        `CHECK(checksum_err_o === 1'b0, "no checksum error expected")
        `CHECK(param_mismatch_o === 1'b0, "no param mismatch expected")

        // --- checksum corruption ---
        send_mf1(1'b1, 1'b0);
        @(posedge clk); #1;
        `CHECK(cfg_valid_o === 1'b0, "cfg_valid_o must not assert on checksum error (enable_i=1)")
        `CHECK(checksum_err_o === 1'b1, "checksum_err_o expected")

        // --- param mismatch (checksum itself still internally consistent) ---
        send_mf1(1'b0, 1'b1);
        @(posedge clk); #1;
        `CHECK(cfg_valid_o === 1'b0, "cfg_valid_o must not assert on param mismatch (enable_i=1)")
        `CHECK(param_mismatch_o === 1'b1, "param_mismatch_o expected")
        `CHECK(checksum_err_o === 1'b0, "checksum itself was valid; only params differ")

        // --- observe-only mode: cfg_valid_o must assert regardless of errors ---
        enable_i <= 1'b0;
        send_mf1(1'b1, 1'b0);
        @(posedge clk); #1;
        `CHECK(cfg_valid_o === 1'b1, "cfg_valid_o must assert in observe-only mode even with a checksum error")
        `CHECK(checksum_err_o === 1'b1, "checksum_err_o must still report the real error even when enable_i=0")

        `TB_FINISH("tb_ilas_check")
    end

endmodule
