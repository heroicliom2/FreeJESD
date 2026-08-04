// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: link_fsm
// Implements: instructions/03-MODULE-SPECS.md "link_fsm.sv" — the 5-state
// link bring-up FSM (doc 02 §2): RESET -> WAIT_FOR_PHY -> CGS -> ILAS ->
// SYNCED, with a fault path back to CGS.
//
// Deviations from doc 03's minimal port list (documented, not accidental):
//   - Added params F, K so this module can self-derive the total ILAS
//     length (4*F*K octets) and detect ILAS completion internally, instead
//     of needing an external `ilas_done_i` input as doc 03 suggests — one
//     less signal to wire up correctly in datapath_rx.sv, and F/K are
//     already needed elsewhere in the same per-lane datapath.
//   - No separate `ilas_done_i` port as a result of the above.
//
// State-transition design decisions (doc 02's prose leaves some of this
// implementation-defined, since it describes protocol *behavior*, not RTL
// signal timing):
//   - CGS -> ILAS is content-driven: the transition happens the instant a
//     /R/ (K28.0) octet is seen while in CGS, not purely from this lane's
//     own CGS_STABLE_CNT counter reaching threshold. Real JESD204B expects
//     the TX to react to this lane's (and every other lane's) SYNC~ request
//     before starting ILAS; this project's golden-model TX (Milestone 2)
//     is open-loop and sends CGS for a fixed length regardless, so the RX
//     side has to follow the stream's actual content rather than assume a
//     round-trip handshake exists. CGS_STABLE_CNT still gates `sync_n_o`
//     (this lane's own readiness signal) independently.
//   - ILAS -> SYNCED (or -> CGS on fault) is gated by `ilas_valid_i` (from
//     ilas_check.sv, Milestone 3) exactly at the last of the 4*F*K ILAS
//     octets — checksum/param mismatch re-enters CGS rather than SYNCED,
//     per doc 02 §2's documented fault path.
//   - Alignment-loss fault path (doc 04's "inject misalignment after
//     SYNCED, assert return to CGS" test): `aligned_i` dropping while in
//     CGS/ILAS/SYNCED is tolerated for up to MAX_FAULT_CNT consecutive
//     cycles (content-driven logic pauses meanwhile, since data_i isn't
//     trustworthy without alignment) before forcing a re-entry to CGS.
//     octet_align.sv's own aligned_o normally latches permanently once
//     achieved (see its header) — aligned_i actually dropping here is
//     expected only in a directed fault-injection testbench driving it
//     artificially, not from octet_align.sv itself in normal operation.

`timescale 1ns/1ps

module link_fsm #(
    parameter int CGS_STABLE_CNT = 4, // consecutive /K/ before this lane declares itself ready (doc 03 default)
    parameter int MAX_FAULT_CNT  = 8, // consecutive misaligned cycles tolerated before forcing CGS re-entry
    parameter int F = 4,
    parameter int K = 32
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       valid_i,
    input  logic [7:0] data_i,
    input  logic       is_k_i,
    input  logic       aligned_i,     // from octet_align.sv
    input  logic       ilas_valid_i,  // from ilas_check.sv: checksum+params OK
    output jesd_pkg::link_state_t state_o,
    output logic [1:0] mf_index_o,    // which of the 4 ILAS multiframes, for ilas_check.sv
    output logic       sync_n_o,      // this lane's SYNC~ request, active low (0 = ready)
    output logic       lane_ready_o   // 1 only in SYNCED
);

    import jesd_pkg::*;

    localparam int ILAS_TOTAL     = 4 * F * K;
    localparam int ILAS_CNT_BITS  = $clog2(ILAS_TOTAL + 1);
    localparam int CGS_CNT_BITS   = $clog2(CGS_STABLE_CNT + 1);
    localparam int FAULT_CNT_BITS = $clog2(MAX_FAULT_CNT + 1);

    link_state_t state;
    logic [CGS_CNT_BITS-1:0]   cgs_run_cnt;
    logic                      cgs_stable;
    logic [1:0]                mf_index;
    logic [ILAS_CNT_BITS-1:0]  ilas_cnt;
    logic [FAULT_CNT_BITS-1:0] fault_cnt;
    logic                      ilas_ok; // latched: did ilas_check ever report a valid capture during this ILAS pass?

    logic is_comma, is_r;
    assign is_comma = valid_i && is_k_i && (data_i == K_K);
    assign is_r     = valid_i && is_k_i && (data_i == K_R);

    logic in_active_state;
    assign in_active_state = (state == LINK_CGS) || (state == LINK_ILAS) || (state == LINK_SYNCED);

    logic fault_trip;
    assign fault_trip = in_active_state && !aligned_i && (fault_cnt == FAULT_CNT_BITS'(MAX_FAULT_CNT - 1));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state       <= LINK_RESET;
            cgs_run_cnt <= '0;
            cgs_stable  <= 1'b0;
            mf_index    <= '0;
            ilas_cnt    <= '0;
            fault_cnt   <= '0;
            ilas_ok     <= 1'b0;
        end else begin
            // ilas_check.cfg_valid_o is a single-cycle pulse that fires
            // shortly after multiframe 1's capture completes — nowhere near
            // the end of the full 4*F*K ILAS phase. Latch it so the
            // completion check below (at the *last* ILAS octet) sees
            // whether a valid capture happened at all during this pass,
            // not the near-always-0 instantaneous value at that late cycle.
            if (state == LINK_ILAS && ilas_valid_i)
                ilas_ok <= 1'b1;
            // Fault-counter bookkeeping is independent of (and evaluated
            // ahead of) the content-driven state logic below.
            if (in_active_state) begin
                if (!aligned_i)
                    fault_cnt <= fault_trip ? FAULT_CNT_BITS'(0) : fault_cnt + 1'b1;
                else
                    fault_cnt <= FAULT_CNT_BITS'(0);
            end

            if (fault_trip) begin
                state       <= LINK_CGS;
                cgs_run_cnt <= '0;
                cgs_stable  <= 1'b0;
            end else begin
                case (state)
                    LINK_RESET: begin
                        state <= LINK_WAIT_FOR_PHY;
                    end

                    LINK_WAIT_FOR_PHY: begin
                        if (aligned_i) begin
                            state       <= LINK_CGS;
                            cgs_run_cnt <= '0;
                            cgs_stable  <= 1'b0;
                        end
                    end

                    LINK_CGS: begin
                        if (aligned_i) begin
                            if (is_comma) begin
                                if (cgs_run_cnt != CGS_CNT_BITS'(CGS_STABLE_CNT - 1))
                                    cgs_run_cnt <= cgs_run_cnt + 1'b1;
                                else
                                    cgs_stable <= 1'b1;
                            end
                            if (is_r) begin
                                state    <= LINK_ILAS;
                                mf_index <= 2'd0;
                                ilas_cnt <= ILAS_CNT_BITS'(1); // this R is ILAS octet #0, already consumed
                                ilas_ok  <= 1'b0;
                            end
                        end
                    end

                    LINK_ILAS: begin
                        if (aligned_i && valid_i) begin
                            if (is_r && (ilas_cnt != ILAS_CNT_BITS'(0)))
                                mf_index <= mf_index + 1'b1;

                            if (ilas_cnt == ILAS_CNT_BITS'(ILAS_TOTAL - 1)) begin
                                ilas_cnt <= '0;
                                if (ilas_ok || ilas_valid_i) begin
                                    state <= LINK_SYNCED;
                                end else begin
                                    state       <= LINK_CGS;
                                    cgs_run_cnt <= '0;
                                    cgs_stable  <= 1'b0;
                                end
                            end else begin
                                ilas_cnt <= ilas_cnt + 1'b1;
                            end
                        end
                    end

                    LINK_SYNCED: begin
                        // no content-driven transitions in v0.1 beyond the
                        // fault_trip path handled above
                    end

                    default: state <= LINK_RESET;
                endcase
            end
        end
    end

    assign state_o     = state;
    assign mf_index_o   = mf_index;
    assign sync_n_o     = ~cgs_stable;
    assign lane_ready_o = (state == LINK_SYNCED);

endmodule
