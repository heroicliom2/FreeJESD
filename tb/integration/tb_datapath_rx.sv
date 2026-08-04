// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_datapath_rx
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 3's real
// integration test — the golden model (Milestone 2) drives datapath_rx.sv
// directly, asserting the FSM visits every expected state
// (WAIT_FOR_PHY->CGS->ILAS->SYNCED), that ilas_check reports a clean
// capture, and that the descrambled user-data payload matches the golden
// model's known free-running-counter pattern (see
// datapath_rx.sv's header for why this checks descr_data_o/descr_ctrl_o —
// pre-elastic-buffer — rather than elastic_buffer's own rd_data_o).
// Doc 06 exit criterion: passes for both SCR=0 and SCR=1 — implemented here
// as two parallel instances (generate) in a single run rather than two
// separate Makefile targets.

`timescale 1ns/1ps

module tb_datapath_rx;
    import jesd_pkg::*;

    integer error_count = 0;
    `TB_WATCHDOG(5000000)

    localparam int L_CFG = 1, F_CFG = 4, K_CFG = 32, M_CFG = 2, N_CFG = 16, NP_CFG = 16, S_CFG = 1;
    localparam int CS_CFG = 0;
    localparam bit HD_CFG = 1'b0;
    localparam int CF_CFG = 0;
    localparam logic [7:0] DID_CFG = 8'hA5, BID_CFG = 8'h03, LID_CFG = 8'h00;
    localparam int CGS_LEN_CFG = 16;
    localparam int USER_MF_CFG = 2;
    localparam int EDEPTH = 8;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    genvar gscr;
    generate
        for (gscr = 0; gscr < 2; gscr = gscr + 1) begin : g_scr
            localparam bit SCR_CFG = (gscr == 1);

            jesd_golden_model #(
                .L(L_CFG), .F(F_CFG), .K(K_CFG), .M(M_CFG), .N(N_CFG), .NP(NP_CFG), .S(S_CFG),
                .SCR(SCR_CFG), .CS(CS_CFG), .HD(HD_CFG), .CF(CF_CFG),
                .DID(DID_CFG), .BID(BID_CFG), .LID(LID_CFG),
                .CGS_LEN(CGS_LEN_CFG), .USER_MULTIFRAMES(USER_MF_CFG)
            ) u_gm ();

            logic       rst_n, valid_i, is_k_i, release_i;
            logic [7:0] data_i;
            link_state_t state_o;
            logic [1:0] mf_index_o;
            logic       sync_n_o, lane_ready_o;
            logic       cfg_valid_o, checksum_err_o, param_mismatch_o;
            logic [111:0] cfg_octets_o;
            logic [31:0] rd_data_o;
            logic       rd_valid_o;
            logic [$clog2(EDEPTH):0] level_o;
            logic       overflow_o, underflow_o;
            logic       descr_valid_o;
            logic [31:0] descr_data_o;
            logic [3:0] descr_ctrl_o;

            datapath_rx #(
                .L_EXP(L_CFG), .F_EXP(F_CFG), .K_EXP(K_CFG), .M_EXP(M_CFG), .N_EXP(N_CFG), .NP_EXP(NP_CFG), .S_EXP(S_CFG),
                .SCR_EXP(SCR_CFG), .CS_EXP(CS_CFG), .HD_EXP(HD_CFG), .CF_EXP(CF_CFG),
                .ELASTIC_DEPTH(EDEPTH)
            ) u_dut (
                .clk(clk), .rst_n(rst_n),
                .valid_i(valid_i), .data_i(data_i), .is_k_i(is_k_i),
                .ilas_check_en_i(1'b1), .release_i(release_i),
                .state_o(state_o), .mf_index_o(mf_index_o), .sync_n_o(sync_n_o), .lane_ready_o(lane_ready_o),
                .cfg_valid_o(cfg_valid_o), .cfg_octets_o(cfg_octets_o),
                .checksum_err_o(checksum_err_o), .param_mismatch_o(param_mismatch_o),
                .rd_data_o(rd_data_o), .rd_valid_o(rd_valid_o), .level_o(level_o),
                .overflow_o(overflow_o), .underflow_o(underflow_o),
                .descr_valid_o(descr_valid_o), .descr_data_o(descr_data_o), .descr_ctrl_o(descr_ctrl_o)
            );

            // lmfc_gen is instantiated (doc 06 Milestone 3 deliverable, exercised
            // here) but does NOT gate release_i in this test: doc 02 §6's
            // "read out together, gated by the LMFC-zero pulse" describes the
            // *cross-lane* deskew release (Milestone 4's buffer_release.sv,
            // not built yet) — gating every single release on one lmfc_zero
            // pulse per F*K cycles would need an elastic_buffer deep enough to
            // hold a full multiframe (F*K/4 words), not the skew-sized depth
            // doc 03 actually specifies elastic_buffer.sv's DEPTH for. For this
            // single-lane milestone there's no other lane to deskew against,
            // so release continuously once ready — matches ELASTIC_DEPTH=8.
            logic lmfc_zero;
            logic [$clog2(F_CFG*K_CFG)-1:0] lmfc_count;
            lmfc_gen #(.LMFC_CYCLES(F_CFG*K_CFG), .LOAD_OFFSET(0)) u_lmfc (
                .clk(clk), .rst_n(rst_n), .sysref_i(1'b0), .count_o(lmfc_count), .zero_o(lmfc_zero)
            );
            // Only pop when there's actually something buffered — a
            // continuous level-1 release_i (whenever lane_ready_o) fires
            // every cycle regardless of arrival rate, and the packer only
            // produces a new word every 4 octets, so most cycles the buffer
            // would be empty. Gating on level_o > 0 naturally settles to the
            // write rate without ever underflowing.
            assign release_i = lane_ready_o && (level_o > 0);

            integer i, oi;
            logic [7:0] exp_counter;
            logic saw_wait_phy, saw_cgs, saw_ilas, saw_synced, cfg_valid_seen;
            logic done;

            initial begin
                rst_n = 1'b0;
                valid_i = 1'b0; data_i = 8'h00; is_k_i = 1'b0;
                saw_wait_phy = 1'b0; saw_cgs = 1'b0; saw_ilas = 1'b0; saw_synced = 1'b0;
                cfg_valid_seen = 1'b0;
                exp_counter = 8'h00;
                done = 1'b0;
                repeat (3) @(posedge clk);
                rst_n <= 1'b1;
                #1;

                u_gm.generate_stream();

                for (i = u_gm.cgs_start; i < u_gm.user_end; i = i + 1) begin
                    data_i  <= u_gm.data[i];
                    is_k_i  <= u_gm.is_k[i];
                    valid_i <= 1'b1;
                    @(posedge clk);
                    #1;

                    case (state_o)
                        LINK_WAIT_FOR_PHY: saw_wait_phy = 1'b1;
                        LINK_CGS:          saw_cgs      = 1'b1;
                        LINK_ILAS:         saw_ilas     = 1'b1;
                        LINK_SYNCED:       saw_synced   = 1'b1;
                        default: ;
                    endcase

                    if (cfg_valid_o) begin
                        cfg_valid_seen = 1'b1;
                        `CHECK(checksum_err_o === 1'b0, "unexpected ILAS checksum error")
                        `CHECK(param_mismatch_o === 1'b0, "unexpected ILAS param mismatch")
                    end

                    `CHECK(overflow_o === 1'b0, "unexpected elastic_buffer overflow")
                    `CHECK(underflow_o === 1'b0, "unexpected elastic_buffer underflow")

                    if (descr_valid_o) begin
                        for (oi = 0; oi < 4; oi = oi + 1) begin
                            if (!descr_ctrl_o[oi]) begin
                                `CHECK(((descr_data_o >> (8*oi)) & 8'hFF) === exp_counter,
                                       "descrambled user-data payload octet doesn't match expected counter")
                                exp_counter = exp_counter + 8'd1;
                            end
                        end
                    end
                end
                valid_i <= 1'b0;

                repeat (4) begin
                    @(posedge clk);
                    #1;
                    `CHECK(overflow_o === 1'b0, "unexpected elastic_buffer overflow (drain)")
                    `CHECK(underflow_o === 1'b0, "unexpected elastic_buffer underflow (drain)")
                    if (descr_valid_o) begin
                        for (oi = 0; oi < 4; oi = oi + 1) begin
                            if (!descr_ctrl_o[oi]) begin
                                `CHECK(((descr_data_o >> (8*oi)) & 8'hFF) === exp_counter,
                                       "descrambled user-data payload octet doesn't match expected counter (drain)")
                                exp_counter = exp_counter + 8'd1;
                            end
                        end
                    end
                end

                `CHECK(saw_wait_phy, "FSM must have visited WAIT_FOR_PHY")
                `CHECK(saw_cgs, "FSM must have visited CGS")
                `CHECK(saw_ilas, "FSM must have visited ILAS")
                `CHECK(saw_synced, "FSM must have reached SYNCED")
                `CHECK(cfg_valid_seen, "ilas_check must have reported a valid capture")

                done = 1'b1;
            end
        end
    endgenerate

    initial begin
        wait (g_scr[0].done && g_scr[1].done);
        `TB_FINISH("tb_datapath_rx")
    end

endmodule
