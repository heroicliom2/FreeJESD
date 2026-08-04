// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: descrambler
// Implements: instructions/03-MODULE-SPECS.md "scrambler.sv / descrambler.sv"
// — mirror of scrambler.sv. Self-synchronizing: the LFSR state is built
// purely from the received (still-scrambled) octet stream, so no explicit
// sync signal or shared state with the far-end scrambler is needed — see
// scrambler.sv's header for the shared bit/octet ordering convention and
// verification status (both apply identically here).

`timescale 1ns/1ps

module descrambler #(
    parameter int STATE_WIDTH = 15,
    parameter logic [STATE_WIDTH-1:0] TAPS = 15'b110000000000000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_i,
    input  logic [31:0] data_i,   // scrambled octet stream
    input  logic [3:0]  ctrl_i,
    input  logic        enable_i,
    output logic        valid_o,
    output logic [31:0] data_o,   // descrambled octet stream
    output logic [3:0]  ctrl_o
);

    // Identical structure to scrambler.sv's process_block, except the LFSR
    // state is fed by the received (input, already-scrambled) bit rather
    // than the computed output bit — this is the self-synchronizing
    // property: state depends only on data_i, never on the recovered dout.
    // Returns {dout, state_out} packed (see scrambler.sv header — iverilog
    // rejects function output ports).
    function automatic logic [31+STATE_WIDTH:0] process_block(
        input logic [31:0]            din,
        input logic [3:0]             kmask,
        input logic [STATE_WIDTH-1:0] state_in
    );
        logic [31:0]            dout;
        logic [STATE_WIDTH-1:0] st;
        logic in_bit, tap_xor, out_bit;
        int octet, bitpos;
        st = state_in;
        dout = din;
        for (octet = 0; octet < 4; octet = octet + 1) begin
            if (!kmask[octet]) begin
                for (bitpos = 7; bitpos >= 0; bitpos = bitpos - 1) begin
                    in_bit  = din[octet*8 + bitpos];
                    tap_xor = ^(st & TAPS);
                    out_bit = in_bit ^ tap_xor;
                    dout[octet*8 + bitpos] = out_bit;
                    st = {st[STATE_WIDTH-2:0], in_bit}; // descrambler: state fed by the INPUT (scrambled) bit
                end
            end
        end
        return {dout, st};
    endfunction

    logic [STATE_WIDTH-1:0]  lfsr_state;
    logic [31:0]             block_dout;
    logic [STATE_WIDTH-1:0]  block_state_next;
    logic [31+STATE_WIDTH:0] block_result;

    always_comb begin
        block_result     = process_block(data_i, ctrl_i, lfsr_state);
        block_dout       = block_result[31+STATE_WIDTH -: 32];
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
                    data_o <= data_i;
                end
            end
        end
    end

endmodule
