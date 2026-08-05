// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_buffer_release
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 4 unit test for
// rtl/common/buffer_release.sv — directly drives lane_ready_i/lmfc_zero_i
// (no lmfc_gen instance needed; the timing relationship this module cares
// about is purely "did lmfc_zero_i pulse while all lanes were ready", not
// LMFC counter mechanics, which lmfc_gen.sv already has its own testbench
// for). Verifies the one-time-latch resolution documented in
// buffer_release.sv's header: release_o sets on the first lmfc_zero_i seen
// while all lanes are ready, STAYS set across later lmfc_zero_i pulses
// (doesn't need re-gating every LMFC period), and drops immediately the
// moment any lane's ready deasserts, re-arming for the next lmfc_zero_i.
//
// Swept across LANES in {1,4} — LANES=1 covers the trivial single-lane
// AND-reduce case, LANES=4 exercises the real cross-lane AND.

`timescale 1ns/1ps

module tb_buffer_release;

    integer error_count = 0;
    `TB_WATCHDOG(200000)

    logic clk = 1'b0;
    always #5 clk = ~clk;

    genvar gl;
    generate
        for (gl = 0; gl < 2; gl = gl + 1) begin : g_lanes
            localparam int LANES = (gl == 0) ? 1 : 4;

            logic rst_n;
            logic [LANES-1:0] lane_ready_i;
            logic lmfc_zero_i;
            logic release_o;

            buffer_release #(.LANES(LANES)) u_dut (
                .clk(clk), .rst_n(rst_n),
                .lane_ready_i(lane_ready_i), .lmfc_zero_i(lmfc_zero_i),
                .release_o(release_o)
            );

            logic done;

            task automatic tick();
                @(posedge clk);
                #1;
            endtask

            initial begin
                rst_n        = 1'b0;
                lane_ready_i = '0;
                lmfc_zero_i  = 1'b0;
                done         = 1'b0;
                repeat (3) @(posedge clk);
                rst_n <= 1'b1;
                #1;
                `CHECK(release_o === 1'b0, "release_o must be 0 immediately after reset")

                // --- lmfc_zero pulses while not all lanes ready: must stay 0 ---
                lmfc_zero_i <= 1'b1;
                tick();
                `CHECK(release_o === 1'b0, "release_o must not set while lanes aren't all ready")
                lmfc_zero_i <= 1'b0;
                tick();
                `CHECK(release_o === 1'b0, "release_o must still be 0, no ready lanes yet")

                // --- all lanes ready, but no lmfc_zero yet: must stay 0 ---
                lane_ready_i <= {LANES{1'b1}};
                tick();
                `CHECK(release_o === 1'b0, "release_o must not set on ready alone, without lmfc_zero")
                tick();
                `CHECK(release_o === 1'b0, "release_o must not set without an lmfc_zero pulse")

                // --- lmfc_zero pulses with all lanes ready: must latch to 1 ---
                lmfc_zero_i <= 1'b1;
                tick();
                lmfc_zero_i <= 1'b0;
                `CHECK(release_o === 1'b1, "release_o must set the cycle after lmfc_zero with all lanes ready")

                // --- must STAY 1 across further cycles with no further lmfc_zero pulses ---
                repeat (5) begin
                    tick();
                    `CHECK(release_o === 1'b1, "release_o must stay latched high between lmfc_zero pulses")
                end

                // --- a later lmfc_zero pulse (still all ready) must not disturb it ---
                lmfc_zero_i <= 1'b1;
                tick();
                lmfc_zero_i <= 1'b0;
                `CHECK(release_o === 1'b1, "release_o must remain 1 across a later lmfc_zero pulse")

                // --- one lane dropping ready must clear release_o immediately (next cycle) ---
                lane_ready_i[0] <= 1'b0;
                tick();
                `CHECK(release_o === 1'b0, "release_o must clear as soon as any lane drops ready")

                // --- staying not-all-ready across an lmfc_zero pulse must not re-set it ---
                lmfc_zero_i <= 1'b1;
                tick();
                lmfc_zero_i <= 1'b0;
                `CHECK(release_o === 1'b0, "release_o must not re-set while a lane is still not-ready")

                // --- re-ready without a fresh lmfc_zero: must stay 0 (re-arm, don't re-fire stale) ---
                lane_ready_i[0] <= 1'b1;
                tick();
                tick();
                `CHECK(release_o === 1'b0, "release_o must wait for a fresh lmfc_zero after re-ready")

                // --- fresh lmfc_zero after re-ready: must set again ---
                lmfc_zero_i <= 1'b1;
                tick();
                lmfc_zero_i <= 1'b0;
                `CHECK(release_o === 1'b1, "release_o must re-latch on the next lmfc_zero after re-arming")

                done = 1'b1;
            end
        end
    endgenerate

    initial begin
        wait (g_lanes[0].done && g_lanes[1].done);
        `TB_FINISH("tb_buffer_release")
    end

endmodule
