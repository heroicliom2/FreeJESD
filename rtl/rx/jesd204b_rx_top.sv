// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: jesd204b_rx_top
// Description: Top-level receive path (placeholder)
// Author: FreeJESD Contributors

`timescale 1ns/1ps

module jesd204b_rx_top #(
    parameter int M = 1,   // Number of converters
    parameter int L = 1,   // Number of lanes
    parameter int F = 2,   // Octets per frame
    parameter int K = 32   // Frames per multiframe
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sysref,

    // Serial lane inputs (post-deserializer)
    input  logic [9:0]  lane_data [L-1:0],
    input  logic        lane_valid,

    // Converter data output
    output logic [15:0] conv_data [M-1:0],
    output logic        conv_valid,

    // Sync output to transmitter
    output logic        sync_n
);

    // TODO: Implement RX link layer state machine
    assign sync_n    = 1'b0;
    assign conv_valid = 1'b0;

endmodule
