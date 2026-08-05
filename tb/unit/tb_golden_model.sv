// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_golden_model
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 2 exit criterion —
// generates a CGS -> 4-multiframe-ILAS -> scrambled-user-data sequence for
// the doc 00 target config (L=1,F=4,K=32,M=2) and checks it structurally.
// Goes beyond doc 06's literal "dump to a log for manual spot-check" (that
// dump is still produced below) by adding automated checks now that a
// simulator is available: CGS content, ILAS marker placement (R/Q/A) in all
// 4 multiframes, ILAS config-octet pack/unpack round trip + checksum, and a
// cross-check of the scrambled user-data payload against the ALREADY-
// VERIFIED rtl/common/descrambler.sv (Milestone 1) — this validates the
// golden model's independent bit-serial scrambler against the RTL's
// unrolled-parallel one without them sharing code, which is exactly the
// property doc 04 wants from keeping the two implementations separate.
//
// The descrambler cross-check is swept across DW_OCTETS in {2,4,8}
// (16/32/64-bit datapath widths, this project's width-flexibility
// requirement — see scrambler.sv's header): the golden model itself is
// octet-granular and width-agnostic, only how the cross-check packs its
// octet stream into words for feeding the RTL descrambler varies with
// width. One shared u_gm instance/stream (generated once), one descrambler
// instance per width, each width's own initial block waits for the shared
// stream+reset to be ready before running its own check.

`timescale 1ns/1ps

module tb_golden_model;
    import jesd_pkg::*;

    integer error_count = 0;
    `TB_WATCHDOG(6000000)

    localparam int L_CFG  = 1;
    localparam int F_CFG  = 4;
    localparam int K_CFG  = 32;
    localparam int M_CFG  = 2;
    localparam int N_CFG  = 16;
    localparam int NP_CFG = 16;
    localparam int S_CFG  = 1;
    localparam bit SCR_CFG = 1'b1;
    localparam int CS_CFG = 0;
    localparam bit HD_CFG = 1'b0;
    localparam int CF_CFG = 0;
    localparam logic [7:0] DID_CFG = 8'hA5;
    localparam logic [7:0] BID_CFG = 8'h03;
    localparam logic [7:0] LID_CFG = 8'h00;
    localparam int CGS_LEN_CFG = 16;
    localparam int USER_MF_CFG = 2;

    jesd_golden_model #(
        .L(L_CFG), .F(F_CFG), .K(K_CFG), .M(M_CFG), .N(N_CFG), .NP(NP_CFG), .S(S_CFG),
        .SCR(SCR_CFG), .CS(CS_CFG), .HD(HD_CFG), .CF(CF_CFG),
        .DID(DID_CFG), .BID(BID_CFG), .LID(LID_CFG),
        .CGS_LEN(CGS_LEN_CFG), .USER_MULTIFRAMES(USER_MF_CFG)
    ) u_gm ();

    localparam int FRAME_LEN = F_CFG * K_CFG;

    integer f, i, mf, pos, frame_idx, pos_in_frame, cfg_idx;
    integer rel, fpos;
    logic [7:0] cfg_extract [0:13];
    logic [103:0] cfg_extract_packed;
    logic [88:0]  unpacked;

    logic clk = 1'b0;
    logic rst_n;
    logic ready; // asserted once reset + stream generation + structural checks are done
    always #5 clk = ~clk;

    genvar gw;
    generate
        for (gw = 0; gw < 3; gw = gw + 1) begin : g_width
            localparam int DW = (gw == 0) ? 2 : (gw == 1) ? 4 : 8;

            logic            d_valid_i, d_enable_i;
            logic [DW*8-1:0] d_data_i;
            logic [DW-1:0]   d_ctrl_i;
            logic            d_valid_o;
            logic [DW*8-1:0] d_data_o;
            logic [DW-1:0]   d_ctrl_o;

            descrambler #(.DW_OCTETS(DW)) u_descr (
                .clk(clk), .rst_n(rst_n),
                .valid_i(d_valid_i), .data_i(d_data_i), .ctrl_i(d_ctrl_i), .enable_i(d_enable_i),
                .valid_o(d_valid_o), .data_o(d_data_o), .ctrl_o(d_ctrl_o)
            );

            integer word_idx, n_words, base, w_octet;
            logic [7:0] exp_counter;
            logic done;

            initial begin
                d_valid_i = 1'b0; d_data_i = '0; d_ctrl_i = '0; d_enable_i = 1'b1;
                done = 1'b0;
                wait (ready);

                n_words = (u_gm.user_end - u_gm.user_start) / DW;
                `CHECK(((u_gm.user_end - u_gm.user_start) % DW) == 0,
                       "user-data length must be a multiple of DW_OCTETS for this cross-check")

                exp_counter = 8'h00;
                for (word_idx = 0; word_idx < n_words; word_idx = word_idx + 1) begin
                    base = u_gm.user_start + word_idx * DW;
                    for (w_octet = 0; w_octet < DW; w_octet = w_octet + 1) begin
                        d_data_i[8*w_octet +: 8] <= u_gm.data[base + w_octet];
                        d_ctrl_i[w_octet]        <= u_gm.is_k[base + w_octet];
                    end
                    d_valid_i <= 1'b1;
                    @(posedge clk);
                    #1;
                    if (d_valid_o) begin
                        for (w_octet = 0; w_octet < DW; w_octet = w_octet + 1) begin
                            if (!d_ctrl_o[w_octet]) begin
                                `CHECK(((d_data_o >> (8*w_octet)) & 8'hFF) === exp_counter,
                                       "descrambled user-data payload octet doesn't match expected counter")
                                exp_counter = exp_counter + 8'd1;
                            end
                        end
                    end
                end
                d_valid_i <= 1'b0;

                // drain final pipeline word
                @(posedge clk);
                #1;
                if (d_valid_o) begin
                    for (w_octet = 0; w_octet < DW; w_octet = w_octet + 1) begin
                        if (!d_ctrl_o[w_octet]) begin
                            `CHECK(((d_data_o >> (8*w_octet)) & 8'hFF) === exp_counter,
                                   "descrambled user-data payload octet doesn't match expected counter (drain)")
                            exp_counter = exp_counter + 8'd1;
                        end
                    end
                end

                done = 1'b1;
            end
        end
    endgenerate

    initial begin
        rst_n = 1'b0;
        ready = 1'b0;

        u_gm.generate_stream();

        // --- dump for manual spot-check (doc 06's literal exit criterion) ---
        $display("--- jesd_golden_model dump: CGS[%0d,%0d) ILAS[%0d,%0d) USER[%0d,%0d) ---",
                  u_gm.cgs_start, u_gm.cgs_end, u_gm.ilas_start, u_gm.ilas_end, u_gm.user_start, u_gm.user_end);
        for (i = u_gm.cgs_start; i < u_gm.cgs_start + 8; i = i + 1)
            $display("  CGS[%0d] = %02h is_k=%0d", i, u_gm.data[i], u_gm.is_k[i]);
        for (mf = 0; mf < 4; mf = mf + 1)
            $display("  mf%0d starts at %0d: octet=%02h is_k=%0d", mf, u_gm.mf_start[mf],
                      u_gm.data[u_gm.mf_start[mf]], u_gm.is_k[u_gm.mf_start[mf]]);
        for (i = u_gm.user_start; i < u_gm.user_start + 8; i = i + 1)
            $display("  USER[%0d] = %02h is_k=%0d", i, u_gm.data[i], u_gm.is_k[i]);

        // === CGS check ===
        for (i = u_gm.cgs_start; i < u_gm.cgs_end; i = i + 1) begin
            `CHECK(u_gm.data[i] === K_K, "CGS octet must be K28.5")
            `CHECK(u_gm.is_k[i] === 1'b1, "CGS octet must be flagged is_k")
        end
        `CHECK((u_gm.cgs_end - u_gm.cgs_start) == CGS_LEN_CFG, "CGS length mismatch")

        // === ILAS structural check, independently re-derived (doesn't call
        // the DUT's own generation loop logic) ===
        for (mf = 0; mf < 4; mf = mf + 1) begin
            cfg_idx = 0;
            for (pos = 0; pos < FRAME_LEN; pos = pos + 1) begin
                frame_idx    = pos / F_CFG;
                pos_in_frame = pos % F_CFG;
                i = u_gm.mf_start[mf] + pos;
                if (pos == 0) begin
                    `CHECK(u_gm.data[i] === K_R, "every ILAS multiframe must start with R")
                    `CHECK(u_gm.is_k[i] === 1'b1, "R octet must be is_k")
                end else if (mf == 1 && pos == 1) begin
                    `CHECK(u_gm.data[i] === K_Q, "mf1 second octet must be Q")
                    `CHECK(u_gm.is_k[i] === 1'b1, "Q octet must be is_k")
                end else if (pos_in_frame == F_CFG - 1) begin
                    `CHECK(u_gm.data[i] === K_A, "every ILAS frame must end with A")
                    `CHECK(u_gm.is_k[i] === 1'b1, "A octet must be is_k")
                end else if (mf == 1 && cfg_idx < 14) begin
                    `CHECK(u_gm.is_k[i] === 1'b0, "ILAS config octet must not be flagged is_k")
                    cfg_extract[cfg_idx] = u_gm.data[i];
                    cfg_idx = cfg_idx + 1;
                end else begin
                    `CHECK(u_gm.data[i] === 8'h00, "non-config ILAS filler octet must be zero")
                    `CHECK(u_gm.is_k[i] === 1'b0, "filler octet must not be flagged is_k")
                end
            end
            `CHECK((mf != 1) || (cfg_idx == 14), "mf1 must contain exactly 14 config octets")
        end

        // === ILAS config-octet pack/unpack round trip + checksum ===
        for (i = 0; i < 13; i = i + 1) cfg_extract_packed[8*i +: 8] = cfg_extract[i];
        `CHECK(ilas_checksum(cfg_extract_packed) === cfg_extract[13],
               "ILAS checksum mismatch between extracted octets and transmitted checksum octet")
        `CHECK(u_gm.cfg_checksum === cfg_extract[13], "golden model's recorded checksum disagrees with the ILAS stream")

        unpacked = ilas_unpack_config(cfg_extract_packed);
        `CHECK(unpacked[88:81] === DID_CFG, "unpacked DID mismatch")
        `CHECK(unpacked[80:73] === BID_CFG, "unpacked BID mismatch")
        `CHECK(unpacked[72:65] === LID_CFG, "unpacked LID mismatch")
        `CHECK(unpacked[64]    === SCR_CFG, "unpacked SCR mismatch")
        `CHECK(unpacked[63:56] === L_CFG[7:0], "unpacked L mismatch")
        `CHECK(unpacked[55:48] === F_CFG[7:0], "unpacked F mismatch")
        `CHECK(unpacked[47:40] === K_CFG[7:0], "unpacked K mismatch")
        `CHECK(unpacked[39:32] === M_CFG[7:0], "unpacked M mismatch")
        `CHECK(unpacked[31:30] === CS_CFG[1:0], "unpacked CS mismatch")
        `CHECK(unpacked[29:22] === N_CFG[7:0], "unpacked N mismatch")
        `CHECK(unpacked[21:14] === NP_CFG[7:0], "unpacked N' mismatch")
        `CHECK(unpacked[13:6]  === S_CFG[7:0], "unpacked S mismatch")
        `CHECK(unpacked[5]     === HD_CFG, "unpacked HD mismatch")
        `CHECK(unpacked[4:0]   === CF_CFG[4:0], "unpacked CF mismatch")

        // (mf0/mf2/mf3 all-zero filler outside R/A is already checked by the
        // ILAS structural loop's final `else` branch above, since it only
        // takes the config-octet branch when mf==1.)

        // === user-data marker placement, independently re-derived ===
        for (i = u_gm.user_start; i < u_gm.user_end; i = i + 1) begin
            rel  = i - u_gm.user_start;
            fpos = rel % F_CFG;
            if (fpos == F_CFG - 1) begin
                // `CHECK expands to its own `if (!(cond)) begin...end` with no
                // else — an outer if/`CHECK/else/`CHECK without explicit
                // begin/end is a dangling-else trap: the else silently binds
                // to CHECK's *internal* if instead of this one. Always brace
                // both arms when a `CHECK sits directly in an if/else branch.
                if (((rel + 1) % FRAME_LEN) == 0) begin
                    `CHECK(u_gm.data[i] === K_A && u_gm.is_k[i] === 1'b1, "user-data multiframe end must be A")
                end else begin
                    `CHECK(u_gm.data[i] === K_F && u_gm.is_k[i] === 1'b1, "user-data frame end must be F")
                end
            end else begin
                `CHECK(u_gm.is_k[i] === 1'b0, "user-data payload octet must not be flagged is_k")
            end
        end

        // Reset+release, then let the per-width cross-check blocks run.
        rst_n <= 1'b0;
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
        ready = 1'b1;
    end

    initial begin
        wait (g_width[0].done && g_width[1].done && g_width[2].done);
        `TB_FINISH("tb_golden_model")
    end

endmodule
