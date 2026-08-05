// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_elastic_buffer
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 3 unit test for
// rtl/common/elastic_buffer.sv — nominal FIFO order, underflow, overflow
// (and that overflow doesn't corrupt existing contents), lane_ready_i write
// gating, and simultaneous write+read while full (doc 04: overflow/underflow
// "never asserted in nominal tests, and *are* asserted in the directed
// skew-overflow fault test" — the overflow/underflow-triggering cases here
// are this module's own directed fault tests, ahead of the full link-level
// fault injection in Milestone 6).
//
// Swept across DW_OCTETS in {2,4,8} (16/32/64-bit) via generate, matching
// this project's width-flexibility requirement (see scrambler.sv's header).
// Test values are built as {marker_octet, i} rather than hardcoded 32-bit
// literals so they scale to any width — the marker occupies the top octet,
// i the bottom bits, for a per-phase-distinguishable, per-width-safe pattern.

`timescale 1ns/1ps

module tb_elastic_buffer;

    integer error_count = 0;
    `TB_WATCHDOG(600000)

    localparam int DEPTH = 8;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    genvar gw;
    generate
        for (gw = 0; gw < 3; gw = gw + 1) begin : g_width
            localparam int DW = (gw == 0) ? 2 : (gw == 1) ? 4 : 8;

            logic rst_n;
            logic wr_valid_i, lane_ready_i, release_i;
            logic [DW*8-1:0] wr_data_i;
            logic [DW*8-1:0] rd_data_o;
            logic rd_valid_o;
            logic [$clog2(DEPTH):0] level_o;
            logic overflow_o, underflow_o;

            elastic_buffer #(.DW_OCTETS(DW), .DEPTH(DEPTH)) u_dut (
                .clk(clk), .rst_n(rst_n),
                .wr_valid_i(wr_valid_i), .wr_data_i(wr_data_i), .lane_ready_i(lane_ready_i),
                .release_i(release_i),
                .rd_data_o(rd_data_o), .rd_valid_o(rd_valid_o), .level_o(level_o),
                .overflow_o(overflow_o), .underflow_o(underflow_o)
            );

            integer i;
            logic [DW*8-1:0] mark_a, mark_b, mark_c, all_ones;
            logic done;

            task automatic do_write(input logic [DW*8-1:0] d);
                wr_data_i    <= d;
                wr_valid_i   <= 1'b1;
                lane_ready_i <= 1'b1;
                release_i    <= 1'b0;
                @(posedge clk);
                #1;
                wr_valid_i <= 1'b0;
            endtask

            task automatic do_release();
                release_i  <= 1'b1;
                wr_valid_i <= 1'b0;
                @(posedge clk);
                #1;
                release_i <= 1'b0;
            endtask

            initial begin
                rst_n        = 1'b0;
                wr_valid_i   = 1'b0;
                wr_data_i    = '0;
                lane_ready_i = 1'b1;
                release_i    = 1'b0;
                done         = 1'b0;
                mark_a   = {8'hA0, {(DW*8-8){1'b0}}};
                mark_b   = {8'hB0, {(DW*8-8){1'b0}}};
                mark_c   = {8'hC0, {(DW*8-8){1'b0}}};
                all_ones = {(DW*8){1'b1}};
                repeat (3) @(posedge clk);
                rst_n <= 1'b1;
                #1;
                `CHECK(level_o === '0, "level must be 0 after reset")

                // --- nominal fill + drain, FIFO order preserved ---
                for (i = 0; i < DEPTH; i = i + 1) begin
                    do_write(mark_a + i);
                end
                `CHECK(level_o === DEPTH, "level must equal DEPTH after filling exactly to capacity")
                `CHECK(overflow_o === 1'b0, "no overflow expected while filling to exactly DEPTH")

                for (i = 0; i < DEPTH; i = i + 1) begin
                    do_release();
                    `CHECK(rd_valid_o === 1'b1, "rd_valid_o expected on release with data present")
                    `CHECK(rd_data_o === (mark_a + i), "FIFO order mismatch on drain")
                end
                `CHECK(level_o === '0, "level must be 0 after full drain")
                `CHECK(underflow_o === 1'b0, "no underflow expected during nominal drain")

                // --- underflow: release on an empty buffer ---
                do_release();
                `CHECK(underflow_o === 1'b1, "underflow_o expected when releasing an empty buffer")
                `CHECK(rd_valid_o === 1'b0, "rd_valid_o must not assert on underflow")

                // --- overflow: fill to DEPTH, then write one more without releasing ---
                for (i = 0; i < DEPTH; i = i + 1) begin
                    do_write(mark_b + i);
                end
                `CHECK(overflow_o === 1'b0, "no overflow yet, exactly at DEPTH")
                do_write(all_ones); // must be dropped
                `CHECK(overflow_o === 1'b1, "overflow_o expected when writing while already full")
                `CHECK(level_o === DEPTH, "level must stay at DEPTH after a dropped overflow write")

                for (i = 0; i < DEPTH; i = i + 1) begin
                    do_release();
                    `CHECK(rd_data_o === (mark_b + i), "overflow must not corrupt existing FIFO contents")
                end
                `CHECK(level_o === '0, "level must be 0 after drain following overflow test")

                // --- lane_ready_i gating: write attempted with lane_ready_i=0 must not write ---
                wr_data_i    <= all_ones;
                wr_valid_i   <= 1'b1;
                lane_ready_i <= 1'b0;
                release_i    <= 1'b0;
                @(posedge clk);
                #1;
                wr_valid_i <= 1'b0;
                `CHECK(level_o === '0, "lane_ready_i=0 must gate off the write entirely")
                lane_ready_i <= 1'b1;

                // --- simultaneous write+read while full: must not overflow, a slot frees ---
                for (i = 0; i < DEPTH; i = i + 1) begin
                    do_write(mark_c + i);
                end
                `CHECK(level_o === DEPTH, "must be full before the simultaneous write+read test")
                wr_data_i    <= mark_c + DEPTH;
                wr_valid_i   <= 1'b1;
                lane_ready_i <= 1'b1;
                release_i    <= 1'b1;
                @(posedge clk);
                #1;
                wr_valid_i <= 1'b0;
                release_i  <= 1'b0;
                `CHECK(overflow_o === 1'b0, "simultaneous write+read while full must not overflow")
                `CHECK(rd_data_o === mark_c, "simultaneous read must return the oldest entry")
                `CHECK(level_o === DEPTH, "level must remain DEPTH after simultaneous write+read (net zero change)")

                for (i = 1; i <= DEPTH; i = i + 1) begin
                    do_release();
                    `CHECK(rd_data_o === (mark_c + i), "post-simultaneous drain order mismatch")
                end
                `CHECK(level_o === '0, "level must be 0 after final drain")

                done = 1'b1;
            end
        end
    endgenerate

    initial begin
        wait (g_width[0].done && g_width[1].done && g_width[2].done);
        `TB_FINISH("tb_elastic_buffer")
    end

endmodule
