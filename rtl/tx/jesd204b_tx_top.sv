// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: jesd204b_tx_top
// Description: Top-level transmit path (placeholder)
// Author: FreeJESD Contributors

`timescale 1ns/1ps

module jesd204b_tx_top #(
    parameter int M = 1,   // Number of converters
    parameter int L = 1,   // Number of lanes
    parameter int F = 2,   // Octets per frame
    parameter int K = 32   // Frames per multiframe
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sysref,

    // Converter data input
    input  logic [15:0] conv_data [M-1:0],
    input  logic        conv_valid,

    // Serial lane outputs (pre-serializer)
    output logic [9:0]  lane_data [L-1:0],
    output logic        lane_valid,

    // Sync input from receiver
    input  logic        sync_n
);

    // TODO: Implement TX link layer state machine
    assign lane_valid = 1'b0;

endmodule
