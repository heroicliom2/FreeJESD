// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: scrambler
// Implements: instructions/03-MODULE-SPECS.md "scrambler.sv / descrambler.sv"
// — self-synchronous multiplicative scrambler, JESD204B polynomial
// G(x) = x^15 + x^14 + 1 (instructions/02-PROTOCOL-REFERENCE.md §4),
// parallelized to DW_OCTETS octets per cycle per doc 03's "unroll N serial
// shifts into one combinational block" guidance.
//
// DW_OCTETS is this project's compile-time internal-datapath-width knob
// (project requirement, not from the instructions/ spec pack): 2/4/8 octets
// = 16/32/64-bit. A synthesis-time parameter like every other config in this
// project (L, F, K, M, SCR...), not runtime-switchable — picking a width is
// a re-elaborate-the-core decision, not a register write. F (octets/frame)
// is expected to be a multiple of DW_OCTETS (project convention, keeps
// frame/multiframe boundaries aligned to word boundaries everywhere in the
// link layer — see datapath_rx.sv) — not enforced here since this module
// doesn't know F, but assumed throughout the rest of the RTL.
//
// Bit/octet ordering convention (not specified bit-exactly by doc 02/03,
// chosen and documented here as the single source of truth for this
// project): octet 0 = data[7:0] .. octet (DW_OCTETS-1) = data[DW_OCTETS*8-1:DW_OCTETS*8-8],
// processed in that order; within each octet, bit 7 (MSB) is processed
// first. This is an internal convention only — scrambler.sv and
// descrambler.sv agree with each other by construction (same process_block
// function shape), which is what doc 04's round-trip property test actually
// exercises; doc 00 non-goals exclude interop with third-party JESD204B
// silicon for v0.1, so bit-exact match to an external reference's octet/bit
// order is not required here.
//
// **Verified: tb_scrambler.sv passes** at DW_OCTETS=4 (32-bit, the doc 06
// Milestone 1 default) and swept across DW_OCTETS in {2,4,8} (16/32/64-bit)
// for the width-flexibility requirement.

`timescale 1ns/1ps

module scrambler #(
    parameter int DW_OCTETS = 4,                             // datapath width in octets: 2=16-bit, 4=32-bit, 8=64-bit
    parameter int STATE_WIDTH = 15,                          // LFSR depth (JESD204B: 15, per G(x) degree)
    parameter logic [STATE_WIDTH-1:0] TAPS = 15'b110000000000000 // bit(WIDTH-1)|bit(WIDTH-2) = delay-15/delay-14 taps;
                                                               // override together with STATE_WIDTH for toy polynomials
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_i,
    input  logic [DW_OCTETS*8-1:0] data_i,
    input  logic [DW_OCTETS-1:0]   ctrl_i,    // 1 bit/octet: 1 = K-character (passed through unscrambled, doc 02 §4)
    input  logic        enable_i,  // 0 = pure passthrough, LFSR state frozen
    output logic        valid_o,
    output logic [DW_OCTETS*8-1:0] data_o,
    output logic [DW_OCTETS-1:0]   ctrl_o
);

    // Processes one DW_OCTETS-octet block through the LFSR. K-marked octets
    // (kmask[octet]=1) pass through unscrambled AND do not touch state —
    // doc 03: "advancing internal LFSR state only on non-K octets".
    //
    // Returns {dout, state_out} packed into one (DW_OCTETS*8+STATE_WIDTH)-bit
    // value rather than using output ports — iverilog rejects function
    // output ports ("Function arguments must be input ports", confirmed
    // against the actual installed toolchain; see phy_8b10b_enc.sv for the
    // same pattern applied there).
    function automatic logic [DW_OCTETS*8+STATE_WIDTH-1:0] process_block(
        input logic [DW_OCTETS*8-1:0] din,
        input logic [DW_OCTETS-1:0]   kmask,
        input logic [STATE_WIDTH-1:0] state_in
    );
        logic [DW_OCTETS*8-1:0] dout;
        logic [STATE_WIDTH-1:0] st;
        logic in_bit, tap_xor, out_bit;
        int octet, bitpos;
        st = state_in;
        dout = din;
        for (octet = 0; octet < DW_OCTETS; octet = octet + 1) begin
            if (!kmask[octet]) begin
                for (bitpos = 7; bitpos >= 0; bitpos = bitpos - 1) begin
                    in_bit  = din[octet*8 + bitpos];
                    tap_xor = ^(st & TAPS);
                    out_bit = in_bit ^ tap_xor;
                    dout[octet*8 + bitpos] = out_bit;
                    st = {st[STATE_WIDTH-2:0], out_bit}; // scrambler: state fed by the OUTPUT (scrambled) bit
                end
            end
        end
        return {dout, st};
    endfunction

    logic [STATE_WIDTH-1:0]              lfsr_state;
    logic [DW_OCTETS*8-1:0]              block_dout;
    logic [STATE_WIDTH-1:0]              block_state_next;
    logic [DW_OCTETS*8+STATE_WIDTH-1:0]  block_result;

    always_comb begin
        block_result     = process_block(data_i, ctrl_i, lfsr_state);
        block_dout       = block_result[DW_OCTETS*8+STATE_WIDTH-1 -: DW_OCTETS*8];
        block_state_next = block_result[STATE_WIDTH-1:0];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr_state <= '0;
            valid_o    <= 1'b0;
            data_o     <= '0;
            ctrl_o     <= '0;
        end else begin
            valid_o <= valid_i;
            ctrl_o  <= ctrl_i;
            if (valid_i) begin
                if (enable_i) begin
                    data_o     <= block_dout;
                    lfsr_state <= block_state_next;
                end else begin
                    data_o <= data_i; // passthrough, state frozen
                end
            end
        end
    end

endmodule
