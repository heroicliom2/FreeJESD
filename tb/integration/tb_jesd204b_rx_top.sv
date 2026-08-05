// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Testbench: tb_jesd204b_rx_top
// Implements: instructions/06-BUILD-ROADMAP.md Milestone 4's link-level
// integration test — L independent jesd_golden_model instances (one per
// lane, each an independent CGS/ILAS/scrambled-user-data stream, doc 04's
// "used two ways: RX verification...") drive rtl/common/jesd204b_rx_top.sv
// directly, checking every lane reaches SYNCED cleanly, buffer_release.sv's
// real cross-lane release_o eventually latches, no elastic_buffer
// over/underflows anywhere, and transport_rx.sv actually produces
// converter_valid_o pulses once data is flowing — the first test in this
// project that exercises buffer_release.sv and transport_rx.sv wired
// together, which tb_transport_rx.sv (fed hand-built octet tables) and
// tb_buffer_release.sv (directly driven) could not do standalone. This test
// does NOT re-check exact converter_data_o sample values against a known
// pattern (tb_transport_rx.sv's directed table test already owns that); the
// L golden models here each generate their own independent free-running
// counter payload (not a coordinated cross-lane sample pattern), so this
// test's job is "does the full multi-lane chain run fault-free and actually
// deliver samples downstream", not bit-exact sample checking.
//
// ELASTIC_DEPTH note: with buffer_release.sv's real one-time-latch release
// (see its header), each lane's elastic_buffer must survive the gap between
// that lane reaching SYNCED and the *next* lmfc_zero_i pulse — up to one
// full LMFC period (F*K octets) in the worst case, not just inter-lane skew.
// ELASTIC_DEPTH=256 words here comfortably covers F_CFG*K_CFG=256 octets at
// the narrowest DW_OCTETS=2 (128 words) swept below. A real integration
// needs to size ELASTIC_DEPTH off its own F*K/DW_OCTETS, not just its
// expected inter-lane skew — a real conclusion this test surfaces, not
// asserted by any one module in isolation.
//
// Swept across L in {1,2,4} x DW_OCTETS in {2,4,8}, SCR fixed at 1 (already
// covered for both SCR values at single-lane scale by tb_datapath_rx.sv;
// this test's job is the multi-lane wiring, not re-proving the scrambler).
// NP_CFG=7 (not a "real" ADC width) is chosen purely so M_CFG=L, S=1 keeps
// transport_rx.sv's (F-1)*L==M*S*NP constraint satisfied uniformly across
// every L in the sweep without per-L tuning (matches tb_transport_rx.sv's
// own config choice).

`timescale 1ns/1ps

module tb_jesd204b_rx_top;
    import jesd_pkg::*;

    integer error_count = 0;
    `TB_WATCHDOG(8000000)

    localparam int F_CFG = 8, K_CFG = 32, N_CFG = 16, NP_CFG = 7, S_CFG = 1;
    localparam bit SCR_CFG = 1'b1;
    localparam int CS_CFG = 0;
    localparam bit HD_CFG = 1'b0;
    localparam int CF_CFG = 0;
    localparam logic [7:0] DID_CFG = 8'hA5, BID_CFG = 8'h03;
    localparam int CGS_LEN_CFG = 16;
    localparam int USER_MF_CFG = 1;
    localparam int ELASTIC_DEPTH = 256;

    localparam int FRAME_LEN = F_CFG * K_CFG;
    localparam int ILAS_LEN  = 4 * FRAME_LEN;
    localparam int USER_LEN  = USER_MF_CFG * FRAME_LEN;
    localparam int TOTAL_LEN = CGS_LEN_CFG + ILAS_LEN + USER_LEN;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    genvar gL, gdw;
    generate
        for (gL = 0; gL < 3; gL = gL + 1) begin : g_L
            localparam int L = (gL == 0) ? 1 : (gL == 1) ? 2 : 4;
            localparam int M_CFG = L;

            for (gdw = 0; gdw < 3; gdw = gdw + 1) begin : g_dw
                localparam int DW = (gdw == 0) ? 2 : (gdw == 1) ? 4 : 8;

                logic            rst_n, sysref_i;
                logic [L-1:0]    lane_valid_i, lane_is_k_i;
                logic [7:0]      lane_data_i [L];
                logic            ready_o;
                logic [L-1:0]    sync_n_o, checksum_err_o, param_mismatch_o, overflow_o, underflow_o;
                logic [M_CFG-1:0] converter_valid_o;
                logic [NP_CFG*8-1:0] converter_data_o [M_CFG];

                jesd204b_rx_top #(
                    .DW_OCTETS(DW), .L(L), .F(F_CFG), .K(K_CFG), .M(M_CFG), .N(N_CFG), .NP(NP_CFG), .S(S_CFG),
                    .SCR(SCR_CFG), .CS(CS_CFG), .HD(HD_CFG), .CF(CF_CFG),
                    .ELASTIC_DEPTH(ELASTIC_DEPTH)
                ) u_top (
                    .clk(clk), .rst_n(rst_n), .sysref_i(sysref_i), .ilas_check_en_i(1'b1),
                    .lane_valid_i(lane_valid_i), .lane_data_i(lane_data_i), .lane_is_k_i(lane_is_k_i),
                    .ready_o(ready_o), .sync_n_o(sync_n_o),
                    .checksum_err_o(checksum_err_o), .param_mismatch_o(param_mismatch_o),
                    .overflow_o(overflow_o), .underflow_o(underflow_o),
                    .converter_valid_o(converter_valid_o), .converter_data_o(converter_data_o)
                );

                // Up to 4 statically-instantiated golden models (one per possible
                // lane index); only the first L are used. Named instances rather
                // than a genvar-indexed array so the driver `initial` block below
                // can copy their generated streams with a *runtime* lane index
                // (SystemVerilog forbids indexing a genvar-named generate scope
                // with a non-constant expression).
                if (L > 0) begin : g_gm0
                    jesd_golden_model #(
                        .L(L), .F(F_CFG), .K(K_CFG), .M(M_CFG), .N(N_CFG), .NP(NP_CFG), .S(S_CFG),
                        .SCR(SCR_CFG), .CS(CS_CFG), .HD(HD_CFG), .CF(CF_CFG),
                        .DID(DID_CFG), .BID(BID_CFG), .LID(8'h00),
                        .CGS_LEN(CGS_LEN_CFG), .USER_MULTIFRAMES(USER_MF_CFG)
                    ) u_gm ();
                end
                if (L > 1) begin : g_gm1
                    jesd_golden_model #(
                        .L(L), .F(F_CFG), .K(K_CFG), .M(M_CFG), .N(N_CFG), .NP(NP_CFG), .S(S_CFG),
                        .SCR(SCR_CFG), .CS(CS_CFG), .HD(HD_CFG), .CF(CF_CFG),
                        .DID(DID_CFG), .BID(BID_CFG), .LID(8'h01),
                        .CGS_LEN(CGS_LEN_CFG), .USER_MULTIFRAMES(USER_MF_CFG)
                    ) u_gm ();
                end
                if (L > 2) begin : g_gm2
                    jesd_golden_model #(
                        .L(L), .F(F_CFG), .K(K_CFG), .M(M_CFG), .N(N_CFG), .NP(NP_CFG), .S(S_CFG),
                        .SCR(SCR_CFG), .CS(CS_CFG), .HD(HD_CFG), .CF(CF_CFG),
                        .DID(DID_CFG), .BID(BID_CFG), .LID(8'h02),
                        .CGS_LEN(CGS_LEN_CFG), .USER_MULTIFRAMES(USER_MF_CFG)
                    ) u_gm ();
                end
                if (L > 3) begin : g_gm3
                    jesd_golden_model #(
                        .L(L), .F(F_CFG), .K(K_CFG), .M(M_CFG), .N(N_CFG), .NP(NP_CFG), .S(S_CFG),
                        .SCR(SCR_CFG), .CS(CS_CFG), .HD(HD_CFG), .CF(CF_CFG),
                        .DID(DID_CFG), .BID(BID_CFG), .LID(8'h03),
                        .CGS_LEN(CGS_LEN_CFG), .USER_MULTIFRAMES(USER_MF_CFG)
                    ) u_gm ();
                end

                logic [7:0] gm_data [0:L-1][0:TOTAL_LEN-1];
                logic       gm_is_k [0:L-1][0:TOTAL_LEN-1];

                integer i, cpi, ln, m;
                integer conv_pulses;
                logic saw_ready;
                logic done;

                initial begin
                    rst_n        = 1'b0;
                    sysref_i     = 1'b0;
                    lane_valid_i = '0;
                    lane_is_k_i  = '0;
                    for (ln = 0; ln < L; ln = ln + 1) lane_data_i[ln] = 8'h00;
                    saw_ready    = 1'b0;
                    conv_pulses  = 0;
                    done         = 1'b0;
                    repeat (3) @(posedge clk);
                    rst_n <= 1'b1;
                    #1;

                    if (L > 0) g_gm0.u_gm.generate_stream();
                    if (L > 1) g_gm1.u_gm.generate_stream();
                    if (L > 2) g_gm2.u_gm.generate_stream();
                    if (L > 3) g_gm3.u_gm.generate_stream();

                    for (cpi = 0; cpi < TOTAL_LEN; cpi = cpi + 1) begin
                        if (L > 0) begin
                            gm_data[0][cpi] = g_gm0.u_gm.data[cpi];
                            gm_is_k[0][cpi] = g_gm0.u_gm.is_k[cpi];
                        end
                        if (L > 1) begin
                            gm_data[1][cpi] = g_gm1.u_gm.data[cpi];
                            gm_is_k[1][cpi] = g_gm1.u_gm.is_k[cpi];
                        end
                        if (L > 2) begin
                            gm_data[2][cpi] = g_gm2.u_gm.data[cpi];
                            gm_is_k[2][cpi] = g_gm2.u_gm.is_k[cpi];
                        end
                        if (L > 3) begin
                            gm_data[3][cpi] = g_gm3.u_gm.data[cpi];
                            gm_is_k[3][cpi] = g_gm3.u_gm.is_k[cpi];
                        end
                    end

                    for (i = 0; i < TOTAL_LEN; i = i + 1) begin
                        for (ln = 0; ln < L; ln = ln + 1) begin
                            lane_data_i[ln] <= gm_data[ln][i];
                            lane_is_k_i[ln] <= gm_is_k[ln][i];
                        end
                        lane_valid_i <= {L{1'b1}};
                        @(posedge clk);
                        #1;

                        `CHECK(checksum_err_o === '0, "unexpected ILAS checksum error on some lane")
                        `CHECK(param_mismatch_o === '0, "unexpected ILAS param mismatch on some lane")
                        `CHECK(overflow_o === '0, "unexpected elastic_buffer overflow on some lane")
                        `CHECK(underflow_o === '0, "unexpected elastic_buffer underflow on some lane")

                        if (ready_o) saw_ready = 1'b1;
                        for (m = 0; m < M_CFG; m = m + 1) begin
                            if (converter_valid_o[m]) conv_pulses = conv_pulses + 1;
                        end
                    end
                    lane_valid_i <= '0;

                    // Drain: keep clocking (with lmfc still free-running) until
                    // release_o has latched and at least some samples have come
                    // through transport_rx, or give up after a bounded wait.
                    i = 0;
                    while (!(saw_ready && conv_pulses > 0) && i < FRAME_LEN * 2) begin
                        @(posedge clk);
                        #1;
                        `CHECK(overflow_o === '0, "unexpected elastic_buffer overflow during drain")
                        `CHECK(underflow_o === '0, "unexpected elastic_buffer underflow during drain")
                        if (ready_o) saw_ready = 1'b1;
                        for (m = 0; m < M_CFG; m = m + 1) begin
                            if (converter_valid_o[m]) conv_pulses = conv_pulses + 1;
                        end
                        i = i + 1;
                    end

                    `CHECK(saw_ready, "buffer_release's release_o must eventually latch high")
                    `CHECK(conv_pulses > 0, "transport_rx must produce at least one converter_valid_o pulse")

                    done = 1'b1;
                end
            end
        end
    endgenerate

    initial begin
        wait (g_L[0].g_dw[0].done && g_L[0].g_dw[1].done && g_L[0].g_dw[2].done &&
              g_L[1].g_dw[0].done && g_L[1].g_dw[1].done && g_L[1].g_dw[2].done &&
              g_L[2].g_dw[0].done && g_L[2].g_dw[1].done && g_L[2].g_dw[2].done);
        `TB_FINISH("tb_jesd204b_rx_top")
    end

endmodule
