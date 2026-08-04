// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_smoke
// Purpose: Milestone 0 toolchain smoke test (instructions/06-BUILD-ROADMAP.md).
// Exercises every construct doc 05 lists as "safe to use" that the rest of
// this project depends on: always_ff, packed struct, generate/genvar,
// immediate assert, $urandom, plus tb_pkg.sv's own CHECK/FINISH/WATCHDOG
// macros. Run this FIRST once a simulator is on PATH (see docs/TOOLCHAIN.md)
// before trusting any other milestone's testbench output.

`timescale 1ns/1ps

module tb_smoke;

    integer error_count = 0;

    `TB_WATCHDOG(1000)

    // --- packed struct ---
    typedef struct packed {
        logic [7:0] a;
        logic [7:0] b;
    } pair_t;

    pair_t p;

    // --- always_ff + generate/genvar ---
    localparam int N_COUNTERS = 4;
    logic clk = 0;
    logic rst_n = 0;
    logic [7:0] count [N_COUNTERS-1:0];

    always #5 clk = ~clk;

    genvar gi;
    generate
        for (gi = 0; gi < N_COUNTERS; gi = gi + 1) begin : g_counter
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    count[gi] <= 8'd0;
                else
                    count[gi] <= count[gi] + gi + 1;
            end
        end
    endgenerate

    initial begin
        // packed struct: field access and whole-vector view
        p.a = 8'hAA;
        p.b = 8'h55;
        `CHECK(p.a == 8'hAA, "packed struct field a mismatch")
        `CHECK(p.b == 8'h55, "packed struct field b mismatch")
        `CHECK(p[15:8] == 8'hAA, "packed struct whole-vector slice mismatch")

        // immediate assert
        assert (p.a != p.b) else $error("smoke: p.a should differ from p.b");

        // reset, then let the generate-loop always_ff counters run.
        // Nonblocking assignment matters here: a blocking rst_n=1 executed
        // right after the same @(posedge clk) that DUT always_ff blocks
        // trigger on races against those blocks' sampling of rst_n at that
        // same edge (simulator-order-dependent whether they see old or new
        // value) — nonblocking guarantees they still see the old value.
        rst_n <= 1'b0;
        repeat (2) @(posedge clk);
        rst_n <= 1'b1;
        repeat (10) @(posedge clk);
        #1; // let this edge's nonblocking count updates settle (NBA region) before sampling
        for (int i = 0; i < N_COUNTERS; i = i + 1) begin
            `CHECK(count[i] == (i + 1) * 10,
                   "generate-loop always_ff counter value mismatch")
        end

        // $urandom
        begin
            int unsigned r1, r2;
            r1 = $urandom;
            r2 = $urandom;
            `CHECK(r1 !== r2,
                   "$urandom returned identical back-to-back values (check PRNG)")
        end

        `TB_FINISH("tb_smoke")
    end

endmodule
