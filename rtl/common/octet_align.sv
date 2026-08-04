// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: octet_align
// Implements: instructions/03-MODULE-SPECS.md "octet_align.sv" — per doc 02
// §2's WAIT_FOR_PHY description ("wait for PHY-level lock (word/comma
// alignment...)").
//
// Design note (this project's own reading, doc 03 offers two alternative
// port signatures — raw 10-bit symbol_i, or already-8b10b-decoded
// [7:0]+is_k): this project's phy_8b10b_dec.sv (Milestone 1) already
// requires its symbol_i input to be bit/word-aligned (it has no internal
// bit-rotation search — real SerDes/CDR is explicitly out of scope, doc 00
// non-goals), so real bit-level symbol alignment is assumed to already be
// correct by the time this module sees data. octet_align.sv is therefore
// implemented against the post-8b10b-decode [7:0]+is_k signature, and its
// remaining job is: detect the initial run of CGS /K/ (K28.5) characters
// that marks the link as genuinely up, and latch `aligned_o` permanently
// once seen — doc 03's "re-run alignment search if commas stop appearing"
// is interpreted as applying only to the pre-alignment search phase (any
// non-K28.5 octet resets the running count), not as continuously
// re-validating alignment after it's achieved (K28.5 stops appearing
// entirely once CGS ends, by design — see doc 02 §2), matching how a real
// PHY's physical alignment is a one-time-achieved property, independent of
// higher-layer protocol content. Passes data straight through, 1 cycle
// latency, matching every other module's convention.

`timescale 1ns/1ps

module octet_align #(
    parameter int STABLE_CNT = 4 // consecutive K28.5 octets required before declaring alignment (doc 03 default)
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       valid_i,
    input  logic [7:0] data_i,
    input  logic       is_k_i,
    output logic       valid_o,
    output logic [7:0] data_o,
    output logic       is_k_o,
    output logic       aligned_o
);

    import jesd_pkg::*;

    localparam int CNT_BITS = $clog2(STABLE_CNT + 1);

    logic [CNT_BITS-1:0] run_cnt;
    logic                is_comma;

    assign is_comma = is_k_i && (data_i == K_K);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            run_cnt   <= '0;
            aligned_o <= 1'b0;
            valid_o   <= 1'b0;
            data_o    <= '0;
            is_k_o    <= 1'b0;
        end else begin
            valid_o <= valid_i;
            data_o  <= data_i;
            is_k_o  <= is_k_i;

            if (!aligned_o && valid_i) begin
                if (is_comma) begin
                    if (run_cnt == STABLE_CNT - 1) begin
                        aligned_o <= 1'b1;
                    end else begin
                        run_cnt <= run_cnt + 1'b1;
                    end
                end else begin
                    run_cnt <= '0;
                end
            end
        end
    end

endmodule
