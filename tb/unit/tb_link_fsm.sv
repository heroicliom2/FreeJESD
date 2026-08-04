// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_link_fsm
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 3 unit test for
// rtl/common/link_fsm.sv, per doc 04 priority list item 3: drive
// aligned_i/comma patterns and assert the *exact* state sequence
// (RESET->WAIT_PHY->CGS->ILAS->SYNCED) via state_o, plus the fault-reentry
// path (inject misalignment after SYNCED, assert return to CGS). Also
// covers the ILAS-checksum-fail path (ilas_valid_i=0 at completion ->
// re-enter CGS instead of SYNCED).
//
// Uses small F/K (not the doc 00 target config) with hand-crafted stimulus
// — link_fsm only inspects /R/ content and total octet count (doc 03: no Q/A
// inspection), so a full realistic ILAS framing isn't needed here; the real
// end-to-end shape is covered by tb_datapath_rx.sv via the golden model.

`timescale 1ns/1ps

module tb_link_fsm;
    import jesd_pkg::*;

    integer error_count = 0;
    `TB_WATCHDOG(200000)

    localparam int CGS_STABLE_CNT = 4;
    localparam int MAX_FAULT_CNT  = 8;
    localparam int F = 2;
    localparam int K = 4;
    localparam int FRAME_LEN  = F * K;      // 8
    localparam int ILAS_TOTAL = 4 * FRAME_LEN; // 32

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic       rst_n, valid_i, is_k_i, aligned_i, ilas_valid_i;
    logic [7:0] data_i;
    link_state_t state_o;
    logic [1:0] mf_index_o;
    logic       sync_n_o, lane_ready_o;

    link_fsm #(.CGS_STABLE_CNT(CGS_STABLE_CNT), .MAX_FAULT_CNT(MAX_FAULT_CNT), .F(F), .K(K)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .valid_i(valid_i), .data_i(data_i), .is_k_i(is_k_i),
        .aligned_i(aligned_i), .ilas_valid_i(ilas_valid_i),
        .state_o(state_o), .mf_index_o(mf_index_o), .sync_n_o(sync_n_o), .lane_ready_o(lane_ready_o)
    );

    task automatic step(input logic al, input logic v, input logic [7:0] d, input logic k, input logic iv);
        aligned_i    <= al;
        valid_i      <= v;
        data_i       <= d;
        is_k_i       <= k;
        ilas_valid_i <= iv;
        @(posedge clk);
        #1;
    endtask

    integer mf, i;

    initial begin
        rst_n = 1'b0; valid_i = 1'b0; data_i = 8'h00; is_k_i = 1'b0;
        aligned_i = 1'b0; ilas_valid_i = 1'b0;
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        #1;
        `CHECK(state_o === LINK_RESET, "state must be LINK_RESET while held in reset")

        // first post-reset edge: RESET auto-advances to WAIT_FOR_PHY
        step(1'b0, 1'b0, 8'h00, 1'b0, 1'b0);
        `CHECK(state_o === LINK_WAIT_FOR_PHY, "state must advance to WAIT_FOR_PHY one cycle after reset release")

        // stay in WAIT_FOR_PHY while unaligned
        for (i = 0; i < 5; i = i + 1) begin
            step(1'b0, 1'b0, 8'h00, 1'b0, 1'b0);
            `CHECK(state_o === LINK_WAIT_FOR_PHY, "state must stay in WAIT_FOR_PHY while aligned_i=0")
        end

        // aligned_i asserted -> CGS
        step(1'b1, 1'b0, 8'h00, 1'b0, 1'b0);
        `CHECK(state_o === LINK_CGS, "state must advance to CGS once aligned_i asserts")
        `CHECK(sync_n_o === 1'b1, "sync_n_o must be deasserted (1) before CGS stability is reached")

        // some non-comma noise first, must stay in CGS, no progress on stability
        step(1'b1, 1'b1, 8'h55, 1'b0, 1'b0);
        `CHECK(state_o === LINK_CGS, "state must stay in CGS on non-comma data")

        // CGS_STABLE_CNT consecutive commas -> sync_n_o asserts (goes low)
        for (i = 0; i < CGS_STABLE_CNT - 1; i = i + 1) begin
            step(1'b1, 1'b1, K_K, 1'b1, 1'b0);
            `CHECK(sync_n_o === 1'b1, "sync_n_o must stay deasserted before the full stable count is reached")
        end
        step(1'b1, 1'b1, K_K, 1'b1, 1'b0);
        `CHECK(sync_n_o === 1'b0, "sync_n_o must assert (go low) after CGS_STABLE_CNT consecutive commas")
        `CHECK(state_o === LINK_CGS, "state must still be CGS — no R seen yet")

        // R -> ILAS on the next cycle; mf_index must be 0
        step(1'b1, 1'b1, K_R, 1'b1, 1'b0);
        `CHECK(state_o === LINK_ILAS, "state must advance to ILAS on seeing R")
        `CHECK(mf_index_o === 2'd0, "mf_index must be 0 for the first ILAS multiframe")

        // feed the remaining FRAME_LEN-1 filler octets of mf0 (R already consumed above)
        for (i = 1; i < FRAME_LEN; i = i + 1) begin
            step(1'b1, 1'b1, 8'h00, 1'b0, 1'b0);
            `CHECK(state_o === LINK_ILAS, "state must remain ILAS through mf0")
        end

        // mf1, mf2, mf3: each starts with R (mf_index increments), then filler
        for (mf = 1; mf < 4; mf = mf + 1) begin
            step(1'b1, 1'b1, K_R, 1'b1, 1'b0);
            `CHECK(mf_index_o === mf[1:0], "mf_index must increment at each new multiframe's R")
            for (i = 1; i < FRAME_LEN; i = i + 1) begin
                // ilas_valid_i only matters/is-sampled on the very last ILAS octet;
                // drive it true throughout this nominal pass
                step(1'b1, 1'b1, 8'h00, 1'b0, (mf == 3 && i == FRAME_LEN - 1) ? 1'b1 : 1'b0);
            end
        end
        `CHECK(state_o === LINK_SYNCED, "state must advance to SYNCED after 4 valid ILAS multiframes")
        `CHECK(lane_ready_o === 1'b1, "lane_ready_o must assert in SYNCED")

        // --- fault-reentry: misalignment injected while SYNCED must force a
        // return to CGS after MAX_FAULT_CNT consecutive unaligned cycles,
        // not before ---
        for (i = 0; i < MAX_FAULT_CNT - 1; i = i + 1) begin
            step(1'b0, 1'b1, 8'h00, 1'b0, 1'b0);
            `CHECK(state_o === LINK_SYNCED, "state must tolerate misalignment below MAX_FAULT_CNT")
        end
        step(1'b0, 1'b1, 8'h00, 1'b0, 1'b0);
        `CHECK(state_o === LINK_CGS, "state must re-enter CGS after MAX_FAULT_CNT consecutive unaligned cycles")
        `CHECK(sync_n_o === 1'b1, "sync_n_o must deassert again after a fault re-sync")
        `CHECK(lane_ready_o === 1'b0, "lane_ready_o must deassert after leaving SYNCED")

        // --- ILAS checksum/param fail path: re-run CGS->ILAS from scratch,
        // this time with ilas_valid_i=0 at completion — must re-enter CGS,
        // never reach SYNCED (doc 02 §2's documented fault path) ---
        step(1'b1, 1'b0, 8'h00, 1'b0, 1'b0); // re-establish alignment
        `CHECK(state_o === LINK_CGS, "state must be CGS again after re-aligning post-fault")
        for (i = 0; i < CGS_STABLE_CNT; i = i + 1) begin
            step(1'b1, 1'b1, K_K, 1'b1, 1'b0);
        end
        step(1'b1, 1'b1, K_R, 1'b1, 1'b0);
        `CHECK(state_o === LINK_ILAS, "state must reach ILAS again for the checksum-fail pass")
        for (mf = 0; mf < 4; mf = mf + 1) begin
            if (mf > 0) step(1'b1, 1'b1, K_R, 1'b1, 1'b0);
            for (i = 1; i < FRAME_LEN; i = i + 1) begin
                // ilas_valid_i=0 on the final octet this time
                step(1'b1, 1'b1, 8'h00, 1'b0, 1'b0);
            end
        end
        `CHECK(state_o === LINK_CGS, "checksum/param failure at ILAS completion must re-enter CGS, not SYNCED")
        `CHECK(lane_ready_o === 1'b0, "lane_ready_o must not assert after a checksum-fail non-sync")

        `TB_FINISH("tb_link_fsm")
    end

endmodule
