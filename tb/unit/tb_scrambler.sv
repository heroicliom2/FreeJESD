// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_scrambler
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 1 "tb_scrambler.sv
// (property test, doc 04 § priority list item 1)" — the highest-priority
// test in the whole verification plan (doc 04): descramble(scramble(x))==x
// over thousands of random vectors, streamed back-to-back (no reset between
// vectors, exercising the self-synchronizing property directly), plus an
// explicit "K-characters pass through unscrambled" check.
//
// Swept across DW_OCTETS in {2,4,8} (16/32/64-bit datapath widths, this
// project's width-flexibility requirement — see scrambler.sv's header) via
// generate, all 3 widths verified in one run rather than three separate
// Makefile targets. Relies on tb_pkg.sv being compiled first (see Makefile
// / tb_pkg.sv header).

`timescale 1ns/1ps

module tb_scrambler;

    integer error_count = 0;

    `TB_WATCHDOG(12000000)

    logic clk = 1'b0;
    always #5 clk = ~clk;

    genvar gw;
    generate
        for (gw = 0; gw < 3; gw = gw + 1) begin : g_width
            localparam int DW = (gw == 0) ? 2 : (gw == 1) ? 4 : 8;

            logic        rst_n;
            logic        s_valid_i, s_enable_i;
            logic [DW*8-1:0] s_data_i;
            logic [DW-1:0]   s_ctrl_i;
            logic        s_valid_o;
            logic [DW*8-1:0] s_data_o;
            logic [DW-1:0]   s_ctrl_o;

            logic        d_valid_o;
            logic [DW*8-1:0] d_data_o;
            logic [DW-1:0]   d_ctrl_o;

            scrambler #(.DW_OCTETS(DW)) u_scr (
                .clk(clk), .rst_n(rst_n),
                .valid_i(s_valid_i), .data_i(s_data_i), .ctrl_i(s_ctrl_i), .enable_i(s_enable_i),
                .valid_o(s_valid_o), .data_o(s_data_o), .ctrl_o(s_ctrl_o)
            );

            descrambler #(.DW_OCTETS(DW)) u_descr (
                .clk(clk), .rst_n(rst_n),
                .valid_i(s_valid_o), .data_i(s_data_o), .ctrl_i(s_ctrl_o), .enable_i(s_enable_i),
                .valid_o(d_valid_o), .data_o(d_data_o), .ctrl_o(d_ctrl_o)
            );

            // Fixed-depth circular scoreboard (avoids SystemVerilog queue types
            // per doc 05's "avoid dynamic types where avoidable" guidance) —
            // 2-cycle pipeline (scrambler + descrambler each register once)
            // never needs more than a couple of entries in flight, depth 8 is
            // ample headroom.
            localparam int HIST_DEPTH = 8;
            logic [DW*8-1:0] hist_data [0:HIST_DEPTH-1];
            logic [DW-1:0]   hist_ctrl [0:HIST_DEPTH-1];
            int wr_ptr, rd_ptr, in_flight;

            logic [DW*8-1:0] rnd_data;
            logic [DW-1:0]   rnd_ctrl;
            logic [DW*8-1:0] exp_data;
            logic [DW-1:0]   exp_ctrl;
            logic [63:0]     rnd64;
            int i, b;
            logic [DW*8-1:0] all_ones_data;
            logic done;

            initial begin
                s_valid_i  = 1'b0;
                s_data_i   = '0;
                s_ctrl_i   = '0;
                s_enable_i = 1'b1;
                rst_n      = 1'b0;
                wr_ptr = 0; rd_ptr = 0; in_flight = 0;
                done = 1'b0;
                all_ones_data = {(DW*8){1'b1}};
                repeat (3) @(posedge clk);
                rst_n <= 1'b1;
                @(posedge clk);

                // --- explicit "K-characters pass through unscrambled" check ---
                // Each of scrambler/descrambler is a 1-cycle-latency stage whose
                // valid_o pulses for exactly 1 cycle right after the edge that
                // sampled valid_i=1 — check immediately after that edge, one edge
                // per pipeline stage, not one edge later (valid_o would have
                // already dropped back to 0 by then).
                s_valid_i <= 1'b1;
                s_data_i  <= all_ones_data;
                s_ctrl_i  <= {DW{1'b1}}; // all octets marked K
                @(posedge clk);
                s_valid_i <= 1'b0;
                #1;
                `CHECK(s_valid_o, "scrambler valid_o expected after K-octet send")
                `CHECK(s_data_o === all_ones_data, "K-marked octets must pass through scrambler unscrambled")
                @(posedge clk);
                #1;
                `CHECK(d_valid_o, "descrambler valid_o expected after K-octet send")
                `CHECK(d_data_o === all_ones_data, "K-marked octets must round-trip unchanged through descrambler")

                repeat (4) @(posedge clk); // let the pipeline fully drain before the streaming test

                // --- streaming round-trip property test: thousands of random
                // vectors, back-to-back valid_i every cycle (self-sync: no
                // reset, no gaps between vectors) ---
                for (i = 0; i < 4000; i = i + 1) begin
                    rnd64    = {$urandom, $urandom};
                    rnd_data = rnd64[DW*8-1:0];
                    for (b = 0; b < DW; b = b + 1) rnd_ctrl[b] = ($urandom_range(0, 7) == 0);
                    s_data_i  <= rnd_data;
                    s_ctrl_i  <= rnd_ctrl;
                    s_valid_i <= 1'b1;
                    hist_data[wr_ptr] = rnd_data;
                    hist_ctrl[wr_ptr] = rnd_ctrl;
                    wr_ptr = (wr_ptr + 1) % HIST_DEPTH;
                    in_flight = in_flight + 1;
                    `CHECK(in_flight <= HIST_DEPTH, "scoreboard overflow — HIST_DEPTH too small for pipeline depth")

                    @(posedge clk);
                    #1; // let this edge's nonblocking DUT outputs settle before sampling

                    if (d_valid_o) begin
                        exp_data = hist_data[rd_ptr];
                        exp_ctrl = hist_ctrl[rd_ptr];
                        rd_ptr    = (rd_ptr + 1) % HIST_DEPTH;
                        in_flight = in_flight - 1;
                        `CHECK(d_data_o === exp_data, "streaming round-trip data mismatch")
                        `CHECK(d_ctrl_o === exp_ctrl, "streaming round-trip ctrl mismatch")
                    end
                end
                s_valid_i <= 1'b0;

                // drain the remaining pipeline entries
                repeat (6) begin
                    @(posedge clk);
                    #1;
                    if (d_valid_o && in_flight > 0) begin
                        exp_data = hist_data[rd_ptr];
                        exp_ctrl = hist_ctrl[rd_ptr];
                        rd_ptr    = (rd_ptr + 1) % HIST_DEPTH;
                        in_flight = in_flight - 1;
                        `CHECK(d_data_o === exp_data, "drain round-trip data mismatch")
                        `CHECK(d_ctrl_o === exp_ctrl, "drain round-trip ctrl mismatch")
                    end
                end
                `CHECK(in_flight == 0, "scoreboard did not fully drain — latency assumption wrong")

                done = 1'b1;
            end
        end
    endgenerate

    initial begin
        wait (g_width[0].done && g_width[1].done && g_width[2].done);
        `TB_FINISH("tb_scrambler")
    end

endmodule
