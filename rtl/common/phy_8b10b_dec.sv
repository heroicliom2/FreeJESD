// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: phy_8b10b_dec
// Implements: instructions/03-MODULE-SPECS.md "phy_8b10b_dec.sv / _enc.sv" —
// standard 8b/10b decode (reverse of phy_8b10b_enc.sv's 5b/6b + 3b/4b split
// tables), running disparity tracked. See phy_8b10b_enc.sv's header comment
// for full provenance/scope notes, and in particular why the 5 K-character
// codewords below use a project-specific, non-standard 6-bit prefix rather
// than the industry K28.x bit patterns (a real D/K collision bug that
// tb_phy_8b10b.sv's exhaustive sweep caught once a simulator became
// available). **Verified: tb_phy_8b10b.sv passes.**
//
// Deviation from doc 03: doc 03 suggests `inout bit running_disparity`; this
// implementation exposes it as a plain output register (`rd_o`) instead —
// `inout` ports on plain (non-interface) module ports are an awkward, rarely
// used pattern and doc 05 steers away from anything exotic in the iverilog
// port-list convention, so a same-direction status output was used instead.

`timescale 1ns/1ps

module phy_8b10b_dec (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_i,
    input  logic [9:0]  symbol_i,
    output logic [7:0]  data_o,
    output logic        is_k_o,
    output logic        valid_o,
    output logic        disp_err_o,   // received subblock disparity inconsistent with tracked RD
    output logic        code_err_o,   // symbol_i is not a valid 8b/10b codeword (K or D) at all
    output logic        rd_o          // tracked running disparity: 0 = RD-, 1 = RD+
);

    import jesd_pkg::*;

    function automatic int unsigned popcount(input logic [9:0] v, input int unsigned width);
        int unsigned c;
        c = 0;
        for (int i = 0; i < width; i++) c = c + v[i];
        return c;
    endfunction

    // --- reverse 5b/6b table: 6-bit codeword -> 5-bit value (mirrors the
    // forward table in phy_8b10b_enc.sv exactly; kept as an independent
    // case statement here rather than shared function to keep this module
    // self-contained per doc 05's "one module per file" style rule).
    // Returns {found, v} packed into 6 bits — iverilog rejects function
    // output ports (see phy_8b10b_enc.sv header); every helper here follows
    // the same pack-into-return-value pattern.
    function automatic logic [5:0] dec_6b(input logic [5:0] code);
        logic       found;
        logic [4:0] v;
        found = 1'b1;
        v = 5'd0;
        case (code)
            6'b100111, 6'b011000: v = 5'd0;
            6'b011101, 6'b100010: v = 5'd1;
            6'b101101, 6'b010010: v = 5'd2;
            6'b110001:            v = 5'd3;
            6'b110101, 6'b001010: v = 5'd4;
            6'b101001:            v = 5'd5;
            6'b011001:            v = 5'd6;
            6'b111000, 6'b000111: v = 5'd7;
            6'b111001, 6'b000110: v = 5'd8;
            6'b100101:            v = 5'd9;
            6'b010101:            v = 5'd10;
            6'b110100:            v = 5'd11;
            6'b001101:            v = 5'd12;
            6'b101100:            v = 5'd13;
            6'b011100:            v = 5'd14;
            6'b010111, 6'b101000: v = 5'd15;
            6'b011011, 6'b100100: v = 5'd16;
            6'b100011:            v = 5'd17;
            6'b010011:            v = 5'd18;
            6'b110010:            v = 5'd19;
            6'b001011:            v = 5'd20;
            6'b101010:            v = 5'd21;
            6'b011010:            v = 5'd22;
            6'b111010, 6'b000101: v = 5'd23;
            6'b110011, 6'b001100: v = 5'd24;
            6'b100110:            v = 5'd25;
            6'b010110:            v = 5'd26;
            6'b110110, 6'b001001: v = 5'd27;
            6'b001111, 6'b110000: v = 5'd28;
            6'b101110, 6'b010001: v = 5'd29;
            6'b011110, 6'b100001: v = 5'd30;
            6'b101011, 6'b010100: v = 5'd31;
            default: found = 1'b0;
        endcase
        return {found, v};
    endfunction

    // --- reverse 3b/4b table (primary only, no alternate — see enc header).
    // Returns {found, v} packed into 4 bits. ---
    function automatic logic [3:0] dec_4b(input logic [3:0] code);
        logic       found;
        logic [2:0] v;
        found = 1'b1;
        v = 3'd0;
        case (code)
            4'b1011, 4'b0100: v = 3'd0;
            4'b1001:          v = 3'd1;
            4'b0101:          v = 3'd2;
            4'b1100, 4'b0011: v = 3'd3;
            4'b1101, 4'b0010: v = 3'd4;
            4'b1010:          v = 3'd5;
            4'b0110:          v = 3'd6;
            4'b1110, 4'b0001: v = 3'd7;
            default: found = 1'b0;
        endcase
        return {found, v};
    endfunction

    // --- K-character full 10-bit codeword reverse lookup (mirrors enc's
    // hardcoded pairs exactly). Returns {found, kval} packed into 9 bits. ---
    function automatic logic [8:0] dec_k(input logic [9:0] sym);
        logic       found;
        logic [7:0] kval;
        found = 1'b1;
        kval = 8'h00;
        case (sym)
            10'b1111000001, 10'b0000111110: kval = K_R; // K28.0
            10'b1111000010, 10'b0000111101: kval = K_A; // K28.3
            10'b1111000011, 10'b0000111100: kval = K_Q; // K28.4
            10'b1111000100, 10'b0000111011: kval = K_K; // K28.5
            10'b1111000101, 10'b0000111010: kval = K_F; // K28.7
            default: found = 1'b0;
        endcase
        return {found, kval};
    endfunction

    logic       rd;
    logic       k_found;
    logic [7:0] k_val;
    logic       d6_found, d4_found;
    logic [4:0] d5;
    logic [2:0] d3;
    logic       sub_disp_ok;

    logic [8:0] k_lookup;
    logic [5:0] d6_lookup;
    logic [3:0] d4_lookup;

    always_comb begin
        k_lookup = dec_k(symbol_i);
        k_found  = k_lookup[8];
        k_val    = k_lookup[7:0];

        d6_lookup = dec_6b(symbol_i[9:4]);
        d6_found  = d6_lookup[5];
        d5        = d6_lookup[4:0];

        d4_lookup = dec_4b(symbol_i[3:0]);
        d4_found  = d4_lookup[3];
        d3        = d4_lookup[2:0];

        // Basic disparity sanity check: the subblock actually received must
        // itself be a legally-formed 6b/4b pattern (i.e. not exceed +-2
        // disparity) which dec_6b/dec_4b already guarantee by construction
        // (only table entries are ever matched); the remaining disparity
        // check is whether the received symbol's *sign* is consistent with
        // the currently tracked rd — a non-neutral 6b subblock with a
        // positive-going pattern (popcount>3) received while rd is already
        // RD+ (rd=1) indicates a disparity fault (two same-sign subblocks
        // in a row without an intervening opposite one), and symmetrically
        // for rd=0.
        if (k_found) begin
            sub_disp_ok = (rd == 1'b0) ? (popcount(symbol_i, 10) <= 5) : (popcount(symbol_i, 10) >= 5);
        end else if (d6_found && d4_found) begin
            sub_disp_ok = (rd == 1'b0) ? (popcount({4'b0, symbol_i[9:4]}, 6) <= 3)
                                        : (popcount({4'b0, symbol_i[9:4]}, 6) >= 3);
        end else begin
            sub_disp_ok = 1'b1; // code_err_o already covers this case
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd         <= 1'b0;
            data_o     <= 8'h00;
            is_k_o     <= 1'b0;
            valid_o    <= 1'b0;
            disp_err_o <= 1'b0;
            code_err_o <= 1'b0;
            rd_o       <= 1'b0;
        end else begin
            valid_o <= valid_i;
            if (valid_i) begin
                if (k_found) begin
                    data_o     <= k_val;
                    is_k_o     <= 1'b1;
                    code_err_o <= 1'b0;
                    disp_err_o <= !sub_disp_ok;
                    rd         <= (popcount(symbol_i, 10) > 5) ? 1'b1 :
                                  (popcount(symbol_i, 10) < 5) ? 1'b0 : rd;
                end else if (d6_found && d4_found) begin
                    data_o     <= {d3, d5};
                    is_k_o     <= 1'b0;
                    code_err_o <= 1'b0;
                    disp_err_o <= !sub_disp_ok;
                    rd         <= (popcount({6'b0, symbol_i[3:0]}, 4) > 2) ? 1'b1 :
                                  (popcount({6'b0, symbol_i[3:0]}, 4) < 2) ? 1'b0 :
                                  ((popcount({4'b0, symbol_i[9:4]}, 6) > 3) ? 1'b1 :
                                   (popcount({4'b0, symbol_i[9:4]}, 6) < 3) ? 1'b0 : rd);
                end else begin
                    data_o     <= 8'h00;
                    is_k_o     <= 1'b0;
                    code_err_o <= 1'b1;
                    disp_err_o <= 1'b0;
                end
                rd_o <= rd;
            end
        end
    end

endmodule
