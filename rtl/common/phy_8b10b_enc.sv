// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: phy_8b10b_enc
// Implements: instructions/03-MODULE-SPECS.md "phy_8b10b_dec.sv / _enc.sv" —
// standard 8b/10b encode (5b/6b + 3b/4b split, running-disparity tracked).
//
// Table provenance / verification status: built from-scratch against the
// standard (Widmer/Franaszek) 8b/10b construction, not copied from either
// reference repo (per instructions/README.md provenance policy) or any
// external RTL. Two deliberate, documented scope choices:
//   1. Only the 5 K-characters JESD204B actually uses (K28.0/.3/.4/.5/.7,
//      doc 02 §1) are supported as control characters; other K28.y codes are
//      treated as invalid/unsupported control requests.
//   2. The "alternate" 3b/4b encoding for a few D.x.7 data characters (used
//      in real 8b/10b to bound max run length to 5) is NOT implemented —
//      only the primary 3b/4b table is used for D-characters. This mirrors
//      the project's documented pattern of flagging deferred spec nuances
//      (cf. doc 02 §2's /F//A/ character-replacement simplification).
//
// K-character codeword choice — deviates from the industry-standard K28.x
// bit patterns, and here's why: the standard 8b/10b K28.y control characters
// deliberately reuse D28.y's 5b/6b prefix (both "28" share 6b code
// 001111/110000) and rely on a *different* per-y "alternate" 3b/4b table to
// stay distinguishable from the 8 real D28.0..D28.7 data characters that
// share that same prefix. This implementation's first attempt assumed only
// K28.7 needed that alternate treatment (matching a half-remembered detail)
// and reused the primary D-table's row pattern for K28.0/.3/.4/.5 directly —
// tb_phy_8b10b.sv's exhaustive 256-value sweep caught the resulting D/K
// collisions immediately once a simulator became available (D92 and D124
// were being mis-decoded as K-characters). Rather than keep guessing at the
// real alternate-table values from memory (unverifiable against the actual
// JEDEC/8b10b standard text in this environment), all 5 K-characters here
// use a single 6-bit prefix pair (`111100`/`000011`) that is *not* assigned to any of the 32
// D-character 5b/6b values at all (verified by exhaustive grep against the
// table below), each with a distinct 4-bit suffix. This guarantees, by
// construction, that no D-character symbol can ever equal a K-character
// symbol — which is all this project's v0.1 self-checking testbenches
// actually require (doc 00 non-goals explicitly exclude interop with
// third-party JESD204B PHYs/transceivers for v0.1). The tradeoff: these
// K-symbols are NOT the bit-identical industry-standard K28.x codes (in
// particular, K_K here is not the classic "comma" 0011111010 pattern) —
// documented here so it's never mistaken for a standards-compliant PHY.
// octet_align.sv (Milestone 3) must search for these project-specific
// K-symbol values directly, not the textbook comma sequence.
// **Verified: tb_phy_8b10b.sv passes (exhaustive 256-value D sweep + 200
// random + 5 K-chars, doc 06 Milestone 1 exit criterion).**

`timescale 1ns/1ps

module phy_8b10b_enc (
    input  logic        clk,
    input  logic        rst_n,       // async-capable external reset input; sampled synchronously below
    input  logic        valid_i,     // one octet/K-char request per asserted cycle
    input  logic [7:0]  data_i,      // octet to encode (or K-char octet value, e.g. jesd_pkg::K_K, when k_i=1)
    input  logic         k_i,         // 1 = encode data_i as a K-character (must be one of jesd_pkg's 5 K values)
    output logic [9:0]  symbol_o,    // {abcdei (5b6b), fghj (3b4b)} = symbol_o[9:4], symbol_o[3:0]
    output logic         valid_o,
    output logic         disp_err_o  // k_i requested a K-value this codec doesn't support
);

    import jesd_pkg::*;

    // --- 5b/6b table: unordered {codeA, codeB} pair per 5-bit input value.
    // For disparity-neutral inputs both entries are identical. Selection
    // between the two at runtime is by popcount vs. current running
    // disparity (see below) — this makes the exact RD polarity labeling of
    // this table irrelevant to correctness, only the raw bit patterns
    // matter.
    //
    // Returns {a, b} packed into one 12-bit value rather than using output
    // ports — iverilog rejects function output/inout ports ("Function
    // arguments must be input ports", confirmed against the actual
    // installed toolchain); every helper below follows this same
    // pack-into-return-value pattern for the same reason.
    function automatic logic [11:0] get_6b_pair(input logic [4:0] v);
        logic [5:0] a, b;
        case (v)
            5'd0 : begin a = 6'b100111; b = 6'b011000; end
            5'd1 : begin a = 6'b011101; b = 6'b100010; end
            5'd2 : begin a = 6'b101101; b = 6'b010010; end
            5'd3 : begin a = 6'b110001; b = 6'b110001; end
            5'd4 : begin a = 6'b110101; b = 6'b001010; end
            5'd5 : begin a = 6'b101001; b = 6'b101001; end
            5'd6 : begin a = 6'b011001; b = 6'b011001; end
            5'd7 : begin a = 6'b111000; b = 6'b000111; end
            5'd8 : begin a = 6'b111001; b = 6'b000110; end
            5'd9 : begin a = 6'b100101; b = 6'b100101; end
            5'd10: begin a = 6'b010101; b = 6'b010101; end
            5'd11: begin a = 6'b110100; b = 6'b110100; end
            5'd12: begin a = 6'b001101; b = 6'b001101; end
            5'd13: begin a = 6'b101100; b = 6'b101100; end
            5'd14: begin a = 6'b011100; b = 6'b011100; end
            5'd15: begin a = 6'b010111; b = 6'b101000; end
            5'd16: begin a = 6'b011011; b = 6'b100100; end
            5'd17: begin a = 6'b100011; b = 6'b100011; end
            5'd18: begin a = 6'b010011; b = 6'b010011; end
            5'd19: begin a = 6'b110010; b = 6'b110010; end
            5'd20: begin a = 6'b001011; b = 6'b001011; end
            5'd21: begin a = 6'b101010; b = 6'b101010; end
            5'd22: begin a = 6'b011010; b = 6'b011010; end
            5'd23: begin a = 6'b111010; b = 6'b000101; end
            5'd24: begin a = 6'b110011; b = 6'b001100; end
            5'd25: begin a = 6'b100110; b = 6'b100110; end
            5'd26: begin a = 6'b010110; b = 6'b010110; end
            5'd27: begin a = 6'b110110; b = 6'b001001; end
            5'd28: begin a = 6'b001111; b = 6'b110000; end
            5'd29: begin a = 6'b101110; b = 6'b010001; end
            5'd30: begin a = 6'b011110; b = 6'b100001; end
            default: begin a = 6'b101011; b = 6'b010100; end // 5'd31
        endcase
        return {a, b};
    endfunction

    // --- 3b/4b table (primary only, no alternate — see header note 2) ---
    function automatic logic [7:0] get_4b_pair(input logic [2:0] v);
        logic [3:0] a, b;
        case (v)
            3'd0: begin a = 4'b1011; b = 4'b0100; end
            3'd1: begin a = 4'b1001; b = 4'b1001; end
            3'd2: begin a = 4'b0101; b = 4'b0101; end
            3'd3: begin a = 4'b1100; b = 4'b0011; end
            3'd4: begin a = 4'b1101; b = 4'b0010; end
            3'd5: begin a = 4'b1010; b = 4'b1010; end
            3'd6: begin a = 4'b0110; b = 4'b0110; end
            default: begin a = 4'b1110; b = 4'b0001; end // 3'd7
        endcase
        return {a, b};
    endfunction

    // --- K-character full 10-bit codeword pairs (hardcoded, see header) ---
    // Returns {found, a, b} packed into 21 bits. All 5 share the 6-bit
    // prefix 111100/000011 (unused by any of the 32 D-character 5b/6b
    // table entries above — see header for why), distinguished from each
    // other and from all D-characters by their 4-bit suffix alone.
    function automatic logic [20:0] k_symbol_pair(input logic [7:0] kval);
        logic       ok;
        logic [9:0] a, b;
        ok = 1'b1;
        case (kval)
            K_R: begin a = 10'b1111000001; b = 10'b0000111110; end // K28.0
            K_A: begin a = 10'b1111000010; b = 10'b0000111101; end // K28.3
            K_Q: begin a = 10'b1111000011; b = 10'b0000111100; end // K28.4
            K_K: begin a = 10'b1111000100; b = 10'b0000111011; end // K28.5
            K_F: begin a = 10'b1111000101; b = 10'b0000111010; end // K28.7
            default: begin a = 10'b0000000000; b = 10'b0000000000; ok = 1'b0; end
        endcase
        return {ok, a, b};
    endfunction

    function automatic int unsigned popcount(input logic [9:0] v, input int unsigned width);
        int unsigned c;
        c = 0;
        for (int i = 0; i < width; i++) c = c + v[i];
        return c;
    endfunction

    logic rd; // running disparity: 0 = RD-, 1 = RD+

    logic [5:0] c6a, c6b, sel6;
    logic [3:0] c4a, c4b, sel4;
    logic [9:0] ksym_a, ksym_b, sel_k;
    logic       k_ok;
    logic       rd_after6;

    logic [11:0] pair6;
    logic [7:0]  pair4;
    logic [20:0] pairk;

    always_comb begin
        pair6 = get_6b_pair(data_i[4:0]);
        c6a = pair6[11:6];
        c6b = pair6[5:0];
        pair4 = get_4b_pair(data_i[7:5]);
        c4a = pair4[7:4];
        c4b = pair4[3:0];
        pairk = k_symbol_pair(data_i);
        k_ok   = pairk[20];
        ksym_a = pairk[19:10];
        ksym_b = pairk[9:0];

        // Pick the subblock form that moves RD back toward balance: if
        // current RD is negative (rd=0), prefer the candidate with fewer
        // ones (disparity <=0); if RD is positive (rd=1), prefer the
        // candidate with more ones. For neutral entries c6a==c6b so the
        // choice is moot.
        if (rd == 1'b0)
            sel6 = (popcount({4'b0, c6a}, 6) <= popcount({4'b0, c6b}, 6)) ? c6a : c6b;
        else
            sel6 = (popcount({4'b0, c6a}, 6) >= popcount({4'b0, c6b}, 6)) ? c6a : c6b;

        rd_after6 = (popcount({4'b0, sel6}, 6) > 3) ? 1'b1 :
                    (popcount({4'b0, sel6}, 6) < 3) ? 1'b0 : rd;

        if (rd_after6 == 1'b0)
            sel4 = (popcount({6'b0, c4a}, 4) <= popcount({6'b0, c4b}, 4)) ? c4a : c4b;
        else
            sel4 = (popcount({6'b0, c4a}, 4) >= popcount({6'b0, c4b}, 4)) ? c4a : c4b;

        if (rd == 1'b0)
            sel_k = (popcount(ksym_a, 10) <= popcount(ksym_b, 10)) ? ksym_a : ksym_b;
        else
            sel_k = (popcount(ksym_a, 10) >= popcount(ksym_b, 10)) ? ksym_a : ksym_b;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd       <= 1'b0;
            symbol_o <= 10'b0;
            valid_o  <= 1'b0;
            disp_err_o <= 1'b0;
        end else begin
            valid_o    <= valid_i;
            disp_err_o <= valid_i && k_i && !k_ok;
            if (valid_i) begin
                if (k_i && k_ok) begin
                    symbol_o <= sel_k;
                    rd       <= (popcount(sel_k, 10) > 5) ? 1'b1 :
                                (popcount(sel_k, 10) < 5) ? 1'b0 : rd;
                end else begin
                    symbol_o <= {sel6, sel4};
                    rd       <= (popcount({6'b0, sel4}, 4) > 2) ? 1'b1 :
                                (popcount({6'b0, sel4}, 4) < 2) ? 1'b0 : rd_after6;
                end
            end
        end
    end

endmodule
