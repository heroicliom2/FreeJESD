// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_lmfc_gen
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 3 unit test for
// rtl/common/lmfc_gen.sv.

`timescale 1ns/1ps

module tb_lmfc_gen;

    integer error_count = 0;
    `TB_WATCHDOG(200000)

    logic clk = 1'b0;
    always #5 clk = ~clk;

    // --- DUT 1: LOAD_OFFSET=0, small cycle count for fast free-run testing ---
    localparam int CYCLES_A = 8;
    logic rst_n_a, sysref_a;
    logic [$clog2(CYCLES_A)-1:0] count_a;
    logic zero_a;

    lmfc_gen #(.LMFC_CYCLES(CYCLES_A), .LOAD_OFFSET(0)) u_dut_a (
        .clk(clk), .rst_n(rst_n_a), .sysref_i(sysref_a), .count_o(count_a), .zero_o(zero_a)
    );

    // --- DUT 2: negative LOAD_OFFSET, to exercise the mod-normalization path ---
    localparam int CYCLES_B = 10;
    localparam int OFFSET_B = -3; // expect RELOAD_VAL = ((-3 % 10) + 10) % 10 = 7
    logic rst_n_b, sysref_b;
    logic [$clog2(CYCLES_B)-1:0] count_b;
    logic zero_b;

    lmfc_gen #(.LMFC_CYCLES(CYCLES_B), .LOAD_OFFSET(OFFSET_B)) u_dut_b (
        .clk(clk), .rst_n(rst_n_b), .sysref_i(sysref_b), .count_o(count_b), .zero_o(zero_b)
    );

    integer i;

    initial begin
        rst_n_a = 1'b0; sysref_a = 1'b0;
        rst_n_b = 1'b0; sysref_b = 1'b0;
        repeat (3) @(posedge clk);
        rst_n_a <= 1'b1;
        rst_n_b <= 1'b1;
        #1; // no clock edge crossed yet — count_a should still read its reset value
        `CHECK(count_a === '0, "count_a must be 0 immediately after reset")
        `CHECK(zero_a === 1'b1, "zero_a must be asserted when count_a==0")

        // --- free-run: confirm count_a cycles 0..CYCLES_A-1 repeatedly, and
        // zero_a pulses exactly once per period, at the right cycle ---
        for (i = 0; i < 3 * CYCLES_A + 3; i = i + 1) begin
            `CHECK(count_a === (i % CYCLES_A), "count_a free-run value mismatch")
            `CHECK(zero_a === ((i % CYCLES_A) == 0), "zero_a must pulse exactly at count_a==0")
            @(posedge clk);
            #1;
        end

        // --- SYSREF reload: assert sysref_a mid-count, confirm reload to 0
        // (LOAD_OFFSET=0) after the internal 2-cycle edge detect. Two edges
        // needed: edge 1 latches sysref_d1<=1 (sysref_edge still 0, since
        // sysref_d2 hasn't caught up yet); edge 2 sees sysref_d1=1/sysref_d2=0
        // (values as of just after edge 1) -> sysref_edge=1 -> reload applied,
        // visible right after edge 2. Deasserting sysref_a between edge 1 and
        // edge 2 doesn't affect this — edge 2's sysref_edge depends only on
        // the D1/D2 flops' already-latched values, not on sysref_i itself.
        `CHECK(count_a !== '0, "test setup: expected mid-count before sysref assertion")
        sysref_a <= 1'b1;
        @(posedge clk); #1; // edge 1: sysref_d1 <= 1, no reload yet
        sysref_a <= 1'b0;
        @(posedge clk); #1; // edge 2: reload applied, visible now
        `CHECK(count_a === '0, "count_a must reload to 0 (LOAD_OFFSET=0) after the sysref edge is detected")
        `CHECK(zero_a === 1'b1, "zero_a must assert on the reload cycle")

        // confirm free-run resumes correctly from the reload point
        for (i = 1; i < CYCLES_A; i = i + 1) begin
            @(posedge clk); #1;
            `CHECK(count_a === i, "count_a must resume normal counting after reload")
        end

        // --- DUT B: confirm negative LOAD_OFFSET normalizes correctly ---
        for (i = 0; i < 2 * CYCLES_B; i = i + 1) begin
            @(posedge clk); #1;
        end
        sysref_b <= 1'b1;
        @(posedge clk); #1; // edge 1
        sysref_b <= 1'b0;
        @(posedge clk); #1; // edge 2: reload applied
        `CHECK(count_b === 7, "count_b must reload to ((-3 % 10)+10)%10 = 7")

        `TB_FINISH("tb_lmfc_gen")
    end

endmodule
