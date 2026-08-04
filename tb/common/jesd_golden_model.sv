// SPDX-License-Identifier: CERN-OHL-P-2.0
// FreeJESD — JESD204B Open-Source IP Core
//
// Module: jesd_golden_model
// Implements: instructions/03-MODULE-SPECS.md / 04-VERIFICATION-PLAN.md
// "jesd_golden_model.sv" — standalone CGS+ILAS+scrambled-user-data TX octet
// stream generator, independent of rtl/'s link_tx (doc 04: "used two ways:
// RX verification... TX verification..."). This is testbench infrastructure
// (tb/common/), not synthesizable RTL — `initial`/tasks are fine here per
// doc 05 (that restriction is for rtl/ only).
//
// Deliberately simpler/more literal than the RTL per doc 04 ("non-parallelized
// serial LFSR, straightforward per-octet loops... its simplicity is what
// makes it trustworthy"): the scrambler here is a plain bit-serial loop, a
// genuinely separate implementation from rtl/common/scrambler.sv's unrolled
// parallel block, sharing only the underlying G(x)=x^15+x^14+1 math and the
// same MSB-first bit/octet convention (see scrambler.sv's header) — not the
// same code, so a bug in one is very unlikely to be masked by the other.
//
// ILAS multiframe structure implemented (doc 02 §2, this project's own
// reading — doc 02's prose is explicit about multiframe 0 and 1's structure
// and says multiframes 2-3 have "the same structure as multiframe 0",
// interpreted here as: EVERY multiframe's very first octet is /R/, and
// multiframe 1 additionally has /Q/ immediately after its /R/; every frame
// in every multiframe ends in /A/; multiframe 1's non-R/Q/A positions are
// filled sequentially with the 14 ILAS config octets (doc 02 §3, layout
// defined in jesd_pkg.sv) then zero-padded; multiframes 0/2/3's non-R/A
// positions are zero (doc 02: "no meaningful payload").
//
// User-data phase (doc 02 §2's documented v0.1 simplification): every frame
// end is marked /F/ and every multiframe end is marked /A/ (the /A/ at a
// multiframe boundary takes priority over /F/ when they coincide), always
// inserted rather than only on repeated-data (deferred char-replacement
// refinement, consistent with doc 02 §2's own stated v0.1 simplification).
// Non-marker octets carry a free-running byte counter (0..255 wrapping) as a
// simple, deterministic, easy-to-eyeball "sample" payload — real converter
// data doesn't matter for what this generator is used to verify.
//
// **Verified: tb_golden_model.sv passes** (CGS content, ILAS marker
// placement across all 4 multiframes, config-octet pack/unpack round trip +
// checksum, user-data marker placement, and a scrambled-payload cross-check
// against the already-verified rtl/common/descrambler.sv). doc 06
// Milestone 2 exit criterion met.

`timescale 1ns/1ps

module jesd_golden_model #(
    parameter int L  = 1,    // lanes — this generator produces ONE lane's stream (doc 06 M2: single-lane first)
    parameter int F  = 4,    // octets per frame
    parameter int K  = 32,   // frames per multiframe
    parameter int M  = 2,    // converters per link (recorded in ILAS only, doesn't affect this generator's output shape)
    parameter int N  = 16,   // converter resolution, bits (ILAS only)
    parameter int NP = 16,   // N', octets-per-sample resolution, bits (ILAS only)
    parameter int S  = 1,    // samples/converter/frame (ILAS only)
    parameter bit SCR = 1'b1,
    parameter int CS  = 0,
    parameter bit HD  = 1'b0,
    parameter int CF  = 0,
    parameter logic [7:0] DID = 8'h00,
    parameter logic [7:0] BID = 8'h00,
    parameter logic [7:0] LID = 8'h00,
    parameter int CGS_LEN          = 16, // octets of CGS (/K/) before ILAS begins — this project's own TX convention, doc 02 doesn't mandate a length
    parameter int USER_MULTIFRAMES = 2   // multiframes of user data generated after ILAS
) ();

    import jesd_pkg::*;

    localparam int FRAME_LEN  = F * K;              // octets per multiframe
    localparam int ILAS_LEN   = 4 * FRAME_LEN;       // 4 multiframes, always
    localparam int USER_LEN   = USER_MULTIFRAMES * FRAME_LEN;
    localparam int TOTAL_LEN  = CGS_LEN + ILAS_LEN + USER_LEN;

    // Generated stream, one entry per octet. is_k[i]=1 => data[i] is a
    // K-character (CGS /K/, ILAS /R//Q//A/, or user-data /F//A/ marker).
    logic [7:0] data  [0:TOTAL_LEN-1];
    logic       is_k  [0:TOTAL_LEN-1];

    // Offsets into the arrays above, exposed so a testbench can slice the
    // stream by phase without recomputing the layout itself.
    int cgs_start, cgs_end;          // [cgs_start, cgs_end)
    int ilas_start, ilas_end;        // [ilas_start, ilas_end), 4 multiframes
    int mf_start [0:3], mf_end [0:3];// per-ILAS-multiframe bounds within ilas region
    int user_start, user_end;        // [user_start, user_end)

    // The 13 packed config octets + checksum, recorded for the testbench to
    // cross-check against jesd_pkg::ilas_unpack_config independently.
    logic [103:0] cfg_octets_packed;
    logic [7:0]   cfg_checksum;

    task automatic generate_stream();
        int wr_idx;
        int mf, pos, frame_idx, pos_in_frame;
        int cfg_idx;
        logic [7:0] cfg_flat [0:13];
        logic [14:0] lfsr_state;
        logic [7:0] user_counter;
        int frame_pos_in_user; // position within the current frame, user-data phase
        logic is_multiframe_end, is_frame_end;
        logic [7:0] scrambled;

        wr_idx = 0;

        // --- CGS: repeated /K/ (K28.5) ---
        cgs_start = wr_idx;
        for (int i = 0; i < CGS_LEN; i++) begin
            data[wr_idx] = K_K;
            is_k[wr_idx] = 1'b1;
            wr_idx = wr_idx + 1;
        end
        cgs_end = wr_idx;

        // --- ILAS config octets (multiframe 1 payload) ---
        cfg_octets_packed = ilas_pack_config(DID, BID, LID, SCR, L[7:0], F[7:0], K[7:0],
                                              M[7:0], CS[1:0], N[7:0], NP[7:0], S[7:0], HD, CF[4:0]);
        cfg_checksum = ilas_checksum(cfg_octets_packed);
        for (int i = 0; i < 13; i++) cfg_flat[i] = cfg_octets_packed[8*i +: 8];
        cfg_flat[13] = cfg_checksum;

        // --- ILAS: 4 multiframes ---
        ilas_start = wr_idx;
        for (mf = 0; mf < 4; mf = mf + 1) begin
            mf_start[mf] = wr_idx;
            cfg_idx = 0;
            for (pos = 0; pos < FRAME_LEN; pos = pos + 1) begin
                frame_idx    = pos / F;
                pos_in_frame = pos % F;
                if (pos == 0) begin
                    data[wr_idx] = K_R;
                    is_k[wr_idx] = 1'b1;
                end else if (mf == 1 && pos == 1) begin
                    data[wr_idx] = K_Q;
                    is_k[wr_idx] = 1'b1;
                end else if (pos_in_frame == F - 1) begin
                    data[wr_idx] = K_A;
                    is_k[wr_idx] = 1'b1;
                end else if (mf == 1 && cfg_idx < 14) begin
                    data[wr_idx] = cfg_flat[cfg_idx];
                    is_k[wr_idx] = 1'b0;
                    cfg_idx = cfg_idx + 1;
                end else begin
                    data[wr_idx] = 8'h00;
                    is_k[wr_idx] = 1'b0;
                end
                wr_idx = wr_idx + 1;
            end
            mf_end[mf] = wr_idx;
        end
        ilas_end = wr_idx;

        // --- User data: /F/ at each frame end, /A/ at each multiframe end
        // (multiframe end takes priority), scrambled payload elsewhere ---
        user_start = wr_idx;
        lfsr_state    = 15'd0;
        user_counter  = 8'h00;
        frame_pos_in_user = 0;
        for (int i = 0; i < USER_LEN; i = i + 1) begin
            is_frame_end      = (frame_pos_in_user == F - 1);
            is_multiframe_end = is_frame_end && (((i + 1) % FRAME_LEN) == 0);
            if (is_multiframe_end) begin
                data[wr_idx] = K_A;
                is_k[wr_idx] = 1'b1;
                // K-chars never scramble the LFSR state (doc 02 §4 / doc 03 scrambler.sv)
            end else if (is_frame_end) begin
                data[wr_idx] = K_F;
                is_k[wr_idx] = 1'b1;
            end else begin
                if (SCR) begin
                    scramble_octet_serial(lfsr_state, user_counter, scrambled);
                    data[wr_idx] = scrambled;
                end else begin
                    data[wr_idx] = user_counter;
                end
                is_k[wr_idx] = 1'b0;
                user_counter = user_counter + 8'd1;
            end
            frame_pos_in_user = (frame_pos_in_user == F - 1) ? 0 : (frame_pos_in_user + 1);
            wr_idx = wr_idx + 1;
        end
        user_end = wr_idx;
    endtask

    // Bit-serial self-synchronous scrambler, G(x)=x^15+x^14+1: state[0]
    // holds y[n-1] .. state[14] holds y[n-15]; y[n] = x[n] ^ y[n-14] ^
    // y[n-15] = x[n] ^ state[13] ^ state[14]. MSB-first per octet, matching
    // rtl/common/scrambler.sv's documented convention. inout works here
    // because this is a task, not a function — iverilog rejects output/inout
    // *function* arguments (see rtl/common/scrambler.sv header) but tasks
    // are unaffected.
    task automatic scramble_octet_serial(
        inout  logic [14:0] state,
        input  logic [7:0]  octet_in,
        output logic [7:0]  octet_out
    );
        logic bit_in, bit_out, tap;
        for (int b = 7; b >= 0; b = b - 1) begin
            bit_in  = octet_in[b];
            tap     = state[13] ^ state[14];
            bit_out = bit_in ^ tap;
            octet_out[b] = bit_out;
            state = {state[13:0], bit_out};
        end
    endtask

endmodule
