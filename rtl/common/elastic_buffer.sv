// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: elastic_buffer
// Implements: instructions/03-MODULE-SPECS.md "elastic_buffer.sv" — per-lane
// circular FIFO absorbing inter-lane skew, released on the shared LMFC
// boundary (doc 02 §6).
//
// DEPTH must be a power of 2 (doc 03) — wr_ptr/rd_ptr rely on natural
// $clog2(DEPTH)-bit register wraparound to double as the circular-buffer
// index wrap, which is only correct at a power-of-2 depth.
//
// Simultaneous write+read in the same cycle when the buffer is momentarily
// "full" is allowed (a slot frees up the same cycle a new one is written),
// matching how a real synchronous FIFO behaves — see wr_happens/rd_happens
// below. rd_data_o on a read always reflects the buffer's contents from
// *before* this cycle's write (standard nonblocking-assignment FIFO
// semantics, not a special case that needed extra logic).

`timescale 1ns/1ps

module elastic_buffer #(
    parameter int DEPTH = 8 // power of 2; >= max tolerated inter-lane skew (doc 02 §6)
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        wr_valid_i,
    input  logic [31:0] wr_data_i,
    input  logic        lane_ready_i, // from link_fsm; gates write-enable
    input  logic        release_i,    // from shared buffer_release; pops one entry per pulse
    output logic [31:0] rd_data_o,
    output logic        rd_valid_o,
    output logic [$clog2(DEPTH):0] level_o, // fill level, 0..DEPTH inclusive
    output logic        overflow_o,   // hard fault: write attempted while full and no slot freed this cycle
    output logic        underflow_o   // hard fault: release_i pulsed while empty
);

    localparam int PTR_BITS = $clog2(DEPTH);

    logic [31:0] mem [0:DEPTH-1];
    logic [PTR_BITS-1:0]   wr_ptr, rd_ptr;
    logic [PTR_BITS:0]     level;

    logic do_write, do_read;
    logic wr_happens, rd_happens;
    logic full_now;

    assign do_write = wr_valid_i && lane_ready_i;
    assign do_read  = release_i;
    assign full_now = (level == DEPTH);

    always_comb begin
        rd_happens = do_read && (level > 0);
        wr_happens = do_write && (!full_now || rd_happens);
    end

    assign level_o = level;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr      <= '0;
            rd_ptr      <= '0;
            level       <= '0;
            rd_data_o   <= '0;
            rd_valid_o  <= 1'b0;
            overflow_o  <= 1'b0;
            underflow_o <= 1'b0;
        end else begin
            rd_valid_o  <= 1'b0;
            overflow_o  <= 1'b0;
            underflow_o <= 1'b0;

            if (wr_happens) begin
                mem[wr_ptr] <= wr_data_i;
                wr_ptr      <= wr_ptr + 1'b1;
            end else if (do_write) begin
                overflow_o <= 1'b1;
            end

            if (rd_happens) begin
                rd_data_o  <= mem[rd_ptr];
                rd_valid_o <= 1'b1;
                rd_ptr     <= rd_ptr + 1'b1;
            end else if (do_read) begin
                underflow_o <= 1'b1;
            end

            level <= level + (wr_happens ? 1'b1 : 1'b0) - (rd_happens ? 1'b1 : 1'b0);
        end
    end

endmodule
