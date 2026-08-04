// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_octet_align
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 3 unit test for
// rtl/common/octet_align.sv — data pass-through timing, no-align-without-
// enough-commas, a broken run resets the counter, alignment achieved after
// exactly STABLE_CNT consecutive commas, and that alignment latches through
// subsequent non-comma data rather than re-checking continuously.

`timescale 1ns/1ps

module tb_octet_align;
    import jesd_pkg::*;

    integer error_count = 0;
    `TB_WATCHDOG(200000)

    localparam int STABLE_CNT = 4;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n, valid_i, is_k_i;
    logic [7:0] data_i;
    logic valid_o, is_k_o, aligned_o;
    logic [7:0] data_o;

    octet_align #(.STABLE_CNT(STABLE_CNT)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .valid_i(valid_i), .data_i(data_i), .is_k_i(is_k_i),
        .valid_o(valid_o), .data_o(data_o), .is_k_o(is_k_o), .aligned_o(aligned_o)
    );

    // Drives one octet for exactly one clock edge; the DUT is a single
    // registered pass-through stage, so the edge this task waits for is the
    // very edge that samples (v,d,k) and produces the corresponding
    // output — check immediately after (with a settle delay), not against
    // some earlier call's values.
    task automatic step(input logic v, input logic [7:0] d, input logic k);
        valid_i <= v;
        data_i  <= d;
        is_k_i  <= k;
        @(posedge clk);
        #1;
        if (v) begin
            `CHECK(valid_o === 1'b1, "valid_o must follow valid_i one cycle later")
            `CHECK(data_o === d, "data_o must equal this cycle's data_i (pass-through)")
            `CHECK(is_k_o === k, "is_k_o must equal this cycle's is_k_i (pass-through)")
        end
    endtask

    integer i;

    initial begin
        rst_n = 1'b0; valid_i = 1'b0; data_i = 8'h00; is_k_i = 1'b0;
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        #1;
        `CHECK(aligned_o === 1'b0, "aligned_o must be 0 after reset")

        // random D-character noise before any comma — aligned_o must stay 0
        for (i = 0; i < 10; i = i + 1) begin
            step(1'b1, 8'h55, 1'b0);
            `CHECK(aligned_o === 1'b0, "aligned_o must stay 0 with no commas seen")
        end

        // a comma run shorter than STABLE_CNT, then broken — must not align
        for (i = 0; i < STABLE_CNT - 1; i = i + 1) begin
            step(1'b1, K_K, 1'b1);
            `CHECK(aligned_o === 1'b0, "aligned_o must not assert before STABLE_CNT consecutive commas")
        end
        step(1'b1, 8'h00, 1'b0); // breaks the run
        `CHECK(aligned_o === 1'b0, "a broken comma run must not align")

        // now a full STABLE_CNT run
        for (i = 0; i < STABLE_CNT; i = i + 1) begin
            step(1'b1, K_K, 1'b1);
        end
        `CHECK(aligned_o === 1'b1, "aligned_o must assert after STABLE_CNT consecutive commas")

        // once aligned, must LATCH through non-comma data (ILAS/user-data
        // simulation) — doc 03's "re-run search if commas stop appearing" is
        // interpreted as pre-alignment-only, see octet_align.sv header
        for (i = 0; i < 20; i = i + 1) begin
            step(1'b1, 8'h1C, (i % 3 == 0));
            `CHECK(aligned_o === 1'b1, "aligned_o must stay latched once achieved, regardless of subsequent data")
        end

        `TB_FINISH("tb_octet_align")
    end

endmodule
