// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_transport_rx
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 4's directed,
// table-driven unit test for rtl/common/transport_rx.sv (doc 03: "feed known
// converter sample values in, check exact octet positions out"). Known
// per-converter, per-frame sample values are computed independently here
// (`expected_byte`/`expected_sample`, a fresh implementation of this
// project's documented gidx mapping — see transport_rx.sv's header — not a
// call into the RTL), placed into each lane's per-frame octet array at the
// positions that same mapping predicts, with a marker octet (content
// irrelevant — this module strips by position, not content, see
// transport_rx.sv's header) always at the last position of every frame, then
// streamed into the DUT DW_OCTETS octets/lane/cycle. Every time
// converter_valid_o[m] pulses, converter_data_o[m] is checked against the
// independently-computed expected sample for the frame currently being
// streamed.
//
// Swept across L in {1,2,4} (this milestone's stated multi-lane target) x
// DW_OCTETS in {2,4,8} (this project's width-flexibility requirement, see
// scrambler.sv's header) — 9 combinations in one run via nested generate,
// same pattern as tb_datapath_rx.sv. F=8 (a multiple of 2/4/8) and NP=7 are
// held fixed with M=L, S=1 so (F-1)*L == M*S*NP == 7*L holds for every L in
// the sweep without per-combination tuning.

`timescale 1ns/1ps

module tb_transport_rx;

    integer error_count = 0;
    `TB_WATCHDOG(2000000)

    localparam int F       = 8;
    localparam int S       = 1;
    localparam int NP      = 7;
    localparam int NFRAMES = 3;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    // Independent reference model of transport_rx.sv's documented mapping
    // (gidx = local_pos*L + lane, converter = gidx/(S*NP), byte = gidx%NP,
    // byte 0 = MSB) — written fresh here, not shared code with the RTL.
    function automatic logic [7:0] expected_byte(input int conv, input int frame, input int byte_idx);
        expected_byte = 8'((conv * 17 + frame * 7 + byte_idx * 3 + 11) & 32'h000000FF);
    endfunction

    function automatic logic [NP*8-1:0] expected_sample(input int conv, input int frame);
        logic [NP*8-1:0] w;
        for (int b = 0; b < NP; b = b + 1) begin
            w[NP*8-1-b*8 -: 8] = expected_byte(conv, frame, b);
        end
        expected_sample = w;
    endfunction

    genvar gL, gdw;
    generate
        for (gL = 0; gL < 3; gL = gL + 1) begin : g_L
            localparam int L = (gL == 0) ? 1 : (gL == 1) ? 2 : 4;
            localparam int M = L;

            for (gdw = 0; gdw < 3; gdw = gdw + 1) begin : g_dw
                localparam int DW = (gdw == 0) ? 2 : (gdw == 1) ? 4 : 8;
                localparam int WORDS_PER_FRAME = F / DW;

                logic             rst_n;
                logic [L-1:0]     lane_valid_i;
                logic [DW*8-1:0]  lane_data_i [L];
                logic [M-1:0]     converter_valid_o;
                logic [NP*8-1:0]  converter_data_o [M];

                transport_rx #(.DW_OCTETS(DW), .L(L), .F(F), .M(M), .S(S), .NP(NP)) u_dut (
                    .clk(clk), .rst_n(rst_n),
                    .lane_valid_i(lane_valid_i), .lane_data_i(lane_data_i),
                    .converter_valid_o(converter_valid_o), .converter_data_o(converter_data_o)
                );

                logic [7:0]      frame_octet [0:L-1][0:F-1];
                logic [DW*8-1:0] word_tmp;
                integer          fr, ln, pos, wc, oi, m, b;
                integer          gidx, conv, byte_idx;
                integer          pulse_count [0:M-1];
                logic            done;

                initial begin
                    rst_n        = 1'b0;
                    lane_valid_i = '0;
                    for (ln = 0; ln < L; ln = ln + 1) lane_data_i[ln] = '0;
                    for (m = 0; m < M; m = m + 1) pulse_count[m] = 0;
                    done = 1'b0;
                    repeat (3) @(posedge clk);
                    rst_n <= 1'b1;
                    #1;

                    for (fr = 0; fr < NFRAMES; fr = fr + 1) begin
                        // --- build this frame's per-lane octet arrays ---
                        for (ln = 0; ln < L; ln = ln + 1) begin
                            for (pos = 0; pos < F; pos = pos + 1) begin
                                if (pos == F - 1) begin
                                    frame_octet[ln][pos] = 8'hFC; // marker; value irrelevant to the DUT
                                end else begin
                                    gidx     = pos * L + ln;
                                    conv     = gidx / NP;
                                    byte_idx = gidx % NP;
                                    frame_octet[ln][pos] = expected_byte(conv, fr, byte_idx);
                                end
                            end
                        end

                        // --- stream WORDS_PER_FRAME cycles, DW octets/lane/cycle ---
                        for (wc = 0; wc < WORDS_PER_FRAME; wc = wc + 1) begin
                            for (ln = 0; ln < L; ln = ln + 1) begin
                                word_tmp = '0;
                                for (oi = 0; oi < DW; oi = oi + 1) begin
                                    word_tmp[8*oi +: 8] = frame_octet[ln][wc*DW + oi];
                                end
                                lane_data_i[ln] <= word_tmp;
                            end
                            lane_valid_i <= {L{1'b1}};
                            @(posedge clk);
                            #1;

                            for (m = 0; m < M; m = m + 1) begin
                                if (converter_valid_o[m]) begin
                                    `CHECK(converter_data_o[m] === expected_sample(m, fr),
                                           "transport_rx sample mismatch")
                                    pulse_count[m] = pulse_count[m] + 1;
                                end
                            end
                        end
                    end

                    lane_valid_i <= '0;
                    repeat (3) begin
                        @(posedge clk);
                        #1;
                        `CHECK(converter_valid_o === '0, "no stray converter_valid_o pulses once lane_valid_i drops")
                    end

                    for (m = 0; m < M; m = m + 1) begin
                        `CHECK(pulse_count[m] == NFRAMES, "each converter must complete exactly one sample/frame (S=1)")
                    end

                    done = 1'b1;
                end
            end
        end
    endgenerate

    initial begin
        wait (g_L[0].g_dw[0].done && g_L[0].g_dw[1].done && g_L[0].g_dw[2].done &&
              g_L[1].g_dw[0].done && g_L[1].g_dw[1].done && g_L[1].g_dw[2].done &&
              g_L[2].g_dw[0].done && g_L[2].g_dw[1].done && g_L[2].g_dw[2].done);
        `TB_FINISH("tb_transport_rx")
    end

endmodule
