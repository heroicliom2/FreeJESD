// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: transport_rx
// Implements: instructions/03-MODULE-SPECS.md "transport_rx.sv" — the
// lane<->converter octet de-interleave (doc 02 §7), the module doc 02 itself
// flags as "the single most common JESD204B implementation error in
// practice." Consumes L lanes' already-deskewed (post buffer_release),
// already-descrambled octet streams (each DW_OCTETS octets/cycle — this
// project's width-flexibility requirement, see scrambler.sv's header) and
// reassembles per-converter sample words.
//
// --- Two real gaps this module resolves (both flagged unresolved in
// docs/HANDOFF.md after Milestone 3), neither of which has literal JEDEC
// Table text available in this environment (same situation as jesd_pkg.sv's
// ILAS config-octet layout) — resolved the same way: define a self-
// consistent, documented, project-own convention, verified by a directed
// table test (tb_transport_rx.sv) rather than trusting an unavailable spec
// table, acceptable since doc00 excludes third-party PHY interop for v0.1.
//
// 1. THE /F//A/ MARKER-STRIPPING GAP: elastic_buffer.sv has no ctrl port
//    (doc 03), so by the time octets reach this module their is_k bit is
//    long gone — markers can't be identified by content. But doc 02 §2's
//    documented v0.1 simplification ("always insert alignment chars, receiver
//    strips them") makes marker POSITION fully deterministic: every frame's
//    last octet (local frame-position F-1, F octets/frame, same convention as
//    ilas_check.sv/link_fsm.sv and tb/common/jesd_golden_model.sv's user-data
//    generator) is always a marker, never real data — so this module strips
//    by counting position, not by inspecting content. This relies on each
//    lane's per-lane octet position staying correctly phase-locked to F once
//    SYNCED; since elastic_buffer is a pure order-preserving FIFO (no
//    reordering/duplication short of an overflow fault, which is a separate
//    hard-fault signal), and the first word this module ever sees from a
//    lane is guaranteed to be that lane's frame-position 0 (datapath_rx's
//    packer only starts once lane_ready_o asserts, exactly at the ILAS->
//    SYNCED frame boundary — see datapath_rx.sv's header), a free-running
//    per-lane word counter reset only at rst_n is sufficient; no realignment
//    logic is needed.
//
// 2. THE OCTET<->SAMPLE MAPPING ITSELF: doc 02 §7 describes the mapping only
//    in prose ("coarse then fine mapping tables") without reproducing JEDEC's
//    actual tables. This module defines its own explicit, documented mapping
//    (verified by the directed table test doc 03 asks for, not derived from
//    an unavailable reference): treat one link-frame's real (non-marker)
//    data octets as a flat sequence of gidx = 0 .. (F-1)*L-1 (F-1, not F,
//    because of the always-one-marker-per-lane-frame convention above),
//    formed by a lane-round-robin interleave of each lane's F-1 real octets:
//    gidx = local_octet_pos * L + lane   (local_octet_pos in [0, F-2], the
//    real-data-only position within a lane's own frame, skipping F-1).
//    That flat sequence is then read converter-major / sample-major /
//    byte-minor, matching how the golden model already lays out real data
//    for a single lane and generalizing it across lanes:
//      converter = gidx / (S*NP)     rem = gidx % (S*NP)
//      (byte_idx = gidx % NP is algebraically the same as rem % NP, used
//       directly below since S*NP is by construction a multiple of NP)
//    byte_idx 0 is the MOST SIGNIFICANT octet of the NP-octet sample (MSB-
//    first, matching this project's existing octet/bit convention elsewhere,
//    e.g. jesd_pkg.sv's checksum octet-0-first layout).
//    Required relationship (elaboration-time, documented not asserted, same
//    convention as F being a multiple of DW_OCTETS elsewhere in this
//    project): (F-1)*L == M*S*NP. F must also be a multiple of DW_OCTETS
//    (existing project-wide convention, see scrambler.sv's header).
//
// --- Deviation from doc 03's literal port list: `converter_valid_o` is
// [M-1:0], one strobe per converter (not a single shared valid), and
// `converter_data_o[m]` updates independently, pulsing every time converter
// m's own latest sample completes. doc 03's single shared `converter_valid_o`
// implicitly assumes S=1 (one sample/converter/frame, so all M converters
// complete "together"); for S>1 the M converters' successive samples don't
// generally complete on the same cycle (the gidx sequence is converter-major,
// so converter 0 finishes all S of its samples long before converter M-1
// starts), so a single shared valid can't mean "all M converters' data is
// simultaneously fresh" without deep, doc03-unspecified per-converter output
// buffering. Per-converter independent strobes are the direct, doc03-
// intended "changing L/M/F/S doesn't require new code" generality without
// inventing buffering doc 03 never asked for — documented here the same way
// link_fsm.sv's added F/K params were documented as a deviation.
//
// KNOWN EDGE CASE (not fully resolved, flagged honestly rather than hidden):
// per-converter byte-write ordering within this module assumes all L lanes'
// per-lane word counters stay in lockstep (true in nominal operation, since
// jesd204b_rx_top.sv's buffer_release.sv gates all lanes' elastic_buffer
// reads from the same shared release_o). If one lane's read stalls
// independently for a cycle (e.g. transient emptiness from residual skew)
// while others don't, a converter whose sample octets span that lane
// boundary within the same original frame could see its bytes committed out
// of temporal order for configurations where multiple lanes' octets land on
// the same converter within a single cycle. Not exercised by
// tb_transport_rx.sv's directed test (which drives all lanes in lockstep,
// matching the buffer_release-gated normal case) or jesd204b_rx_top.sv's
// integration test.

`timescale 1ns/1ps

module transport_rx #(
    parameter int DW_OCTETS = 4, // compile-time datapath width in octets (2/4/8), see scrambler.sv
    parameter int L  = 1,  // lanes
    parameter int F  = 8,  // octets/frame per lane, including the one marker octet (position F-1)
    parameter int M  = 1,  // converters
    parameter int S  = 1,  // samples/converter/frame
    parameter int NP = 7   // N', octets/sample
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [L-1:0]            lane_valid_i,
    input  logic [DW_OCTETS*8-1:0]  lane_data_i [L],

    output logic [M-1:0]            converter_valid_o,
    output logic [NP*8-1:0]         converter_data_o [M]
);

    localparam int WORDS_PER_FRAME = F / DW_OCTETS;
    localparam int WCNT_BITS = (WORDS_PER_FRAME > 1) ? $clog2(WORDS_PER_FRAME) : 1;

    logic [WCNT_BITS-1:0] word_cnt [0:L-1];
    logic [NP*8-1:0]      samp_acc      [0:M-1];
    logic [NP*8-1:0]      samp_acc_next [0:M-1];
    logic [M-1:0]         sample_done_next;

    logic [NP*8-1:0]        acc_tmp;
    logic [DW_OCTETS*8-1:0] lane_word;
    logic [7:0]              octet_val;

    integer ln, oi, m;
    integer local_pos;
    integer gidx;
    integer converter_idx, byte_idx;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (ln = 0; ln < L; ln = ln + 1) word_cnt[ln] <= '0;
            for (m = 0; m < M; m = m + 1) begin
                samp_acc[m]         <= '0;
                converter_data_o[m] <= '0;
            end
            converter_valid_o <= '0;
        end else begin
            for (m = 0; m < M; m = m + 1) samp_acc_next[m] = samp_acc[m];
            sample_done_next = '0;

            // oi outer, lane inner: for a fixed octet-in-word position, gidx
            // increases consecutively across lanes (gidx = local_pos*L+lane);
            // matches this module's documented gidx ordering (see header) as
            // long as all lanes' word_cnt stay in lockstep this cycle.
            for (oi = 0; oi < DW_OCTETS; oi = oi + 1) begin
                for (ln = 0; ln < L; ln = ln + 1) begin
                    if (lane_valid_i[ln]) begin
                        local_pos = word_cnt[ln] * DW_OCTETS + oi;
                        if (local_pos != F - 1) begin
                            gidx          = local_pos * L + ln;
                            converter_idx = gidx / (S * NP);
                            byte_idx      = gidx % NP;

                            lane_word = lane_data_i[ln];
                            octet_val = lane_word[8*oi +: 8];

                            acc_tmp = samp_acc_next[converter_idx];
                            acc_tmp[NP*8-1-byte_idx*8 -: 8] = octet_val;
                            samp_acc_next[converter_idx] = acc_tmp;

                            if (byte_idx == NP - 1) sample_done_next[converter_idx] = 1'b1;
                        end
                    end
                end
            end

            for (m = 0; m < M; m = m + 1) begin
                samp_acc[m]          <= samp_acc_next[m];
                converter_valid_o[m] <= sample_done_next[m];
                if (sample_done_next[m]) converter_data_o[m] <= samp_acc_next[m];
            end

            for (ln = 0; ln < L; ln = ln + 1) begin
                if (lane_valid_i[ln]) begin
                    word_cnt[ln] <= (word_cnt[ln] == WCNT_BITS'(WORDS_PER_FRAME - 1))
                                    ? '0 : word_cnt[ln] + 1'b1;
                end
            end
        end
    end

endmodule
