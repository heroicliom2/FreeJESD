// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_phy_8b10b
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 1 —
// "tb_phy_8b10b.sv (round-trip + known-vector table test)" for
// rtl/common/phy_8b10b_enc.sv / phy_8b10b_dec.sv.
// Relies on tb_pkg.sv's CHECK/TB_FINISH/TB_WATCHDOG macros being compiled
// ahead of this file (see Makefile — do not add an explicit `include here,
// tb_pkg.sv documents why).

`timescale 1ns/1ps

module tb_phy_8b10b;
    import jesd_pkg::*;

    integer error_count = 0;

    `TB_WATCHDOG(200000)

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic       e_valid_i, e_k_i;
    logic [7:0] e_data_i;
    logic [9:0] e_symbol_o;
    logic       e_valid_o, e_disp_err_o;

    logic       d_valid_o, d_is_k_o, d_disp_err_o, d_code_err_o, d_rd_o;
    logic [7:0] d_data_o;

    phy_8b10b_enc u_enc (
        .clk(clk), .rst_n(rst_n),
        .valid_i(e_valid_i), .data_i(e_data_i), .k_i(e_k_i),
        .symbol_o(e_symbol_o), .valid_o(e_valid_o), .disp_err_o(e_disp_err_o)
    );

    phy_8b10b_dec u_dec (
        .clk(clk), .rst_n(rst_n),
        .valid_i(e_valid_o), .symbol_i(e_symbol_o),
        .data_o(d_data_o), .is_k_o(d_is_k_o), .valid_o(d_valid_o),
        .disp_err_o(d_disp_err_o), .code_err_o(d_code_err_o), .rd_o(d_rd_o)
    );

    // Drives one octet through enc->dec and checks the round trip 3 clock
    // edges later (1 cycle enc latency + 1 cycle dec latency + the send
    // edge itself — see derivation in this file's development notes).
    task automatic send_and_check(input logic [7:0] data, input logic k, input string tag);
        @(posedge clk);
        e_data_i  <= data;
        e_k_i     <= k;
        e_valid_i <= 1'b1;
        @(posedge clk);
        e_valid_i <= 1'b0;
        @(posedge clk);
        #1; // let this edge's nonblocking dec outputs settle (NBA region) before sampling
        `CHECK(d_valid_o, {"expected dec valid_o for ", tag})
        `CHECK(!d_code_err_o, {"unexpected code_err_o for ", tag})
        `CHECK(!d_disp_err_o, {"unexpected disp_err_o for ", tag})
        `CHECK(d_data_o === data, {"round-trip data mismatch for ", tag})
        `CHECK(d_is_k_o === k, {"is_k_o mismatch for ", tag})
    endtask

    initial begin
        e_valid_i = 1'b0;
        e_data_i  = 8'h00;
        e_k_i     = 1'b0;
        rst_n     <= 1'b0;
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // known-vector table test: the 5 K-characters JESD204B uses (doc 02 §1)
        send_and_check(K_R, 1'b1, "K28.0");
        send_and_check(K_A, 1'b1, "K28.3");
        send_and_check(K_Q, 1'b1, "K28.4");
        send_and_check(K_K, 1'b1, "K28.5");
        send_and_check(K_F, 1'b1, "K28.7");

        // exhaustive D-character round-trip: all 256 octet values
        for (int v = 0; v < 256; v++) begin
            send_and_check(v[7:0], 1'b0, $sformatf("D%0d", v));
        end

        // randomized re-sweep (doc 05: plain $urandom calls are fine)
        for (int i = 0; i < 200; i++) begin
            send_and_check($urandom_range(0, 255), 1'b0, "random D");
        end

        `TB_FINISH("tb_phy_8b10b")
    end

endmodule
